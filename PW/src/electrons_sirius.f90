subroutine electrons_sirius()
  use sirius
  use ions_base,            only : nat, nsp, ityp
  use uspp_param,           only : upf, nhm, nh
  use gvect,                only : mill, ngm, gg
  use wvfct,                only : nbnd, wg, et
  use gvecw,                only : ecutwfc
  use klist,                only : kset_id, nelec, nks, nkstot, lgauss, wk
  use io_global,            only : stdout
  use control_flags,        only : conv_elec, ethr, gamma_only, iprint, iverbosity, mixing_beta, niter,&
                                   nmix, llondon, lxdm, lmd
  use gvect,                only : nl,nlm
  use scf,                  only : scf_type, rho, rho_core, rhog_core, create_scf_type, open_mix_file, scf_type_copy,&
                                   bcast_scf_type, close_mix_file, destroy_scf_type, v, vltot, vxc, v_of_0
  use io_files,             only : iunmix
  use mp_bands,             only : intra_bgrp_comm
  use mp_pools,             only : root_pool, my_pool_id, inter_pool_comm, npool
  use mp,                   only : mp_bcast, mp_sum
  use parallel_include
  use symm_base,            only : nosym
  use ener,                 only : etot, hwf_energy, eband, deband, ehart, &
                                   vtxc, etxc, etxcc, ewld, demet, epaw, &
                                   elondon, ef_up, ef_dw, exdm
  use noncollin_module,     only : nspin_mag
  use uspp,                 only : okvan, deeq, qq, becsum
  use fft_base,             only : dfftp
  use paw_variables,        only : okpaw, total_core_energy
  use force_mod,            only : force
  use wavefunctions_module, only : psic
  use fft_interfaces,       only : fwfft, invfft
  use input_parameters,     only : conv_thr, sirius_cfg
  use funct,                only : dft_is_hybrid
  use ldaU,                 only : eth
  use extfield,             only : tefield, etotefield
  use paw_variables,        only : okpaw, ddd_paw, total_core_energy, only_paw
  use paw_onecenter,        only : PAW_potential
  use lsda_mod,             only : nspin
  use constants, only : eps8
  !
  implicit none
  integer iat, ia, i, j, num_gvec, num_fft_grid_points, ik, iter, ig, li, lj, ijv, ilast, ir, l, mb, nb, is
  real(8), allocatable :: vloc(:), dion(:,:), tmp(:)
  real(8), allocatable :: bnd_occ(:,:), band_e(:,:), wk_tmp(:), xk_tmp(:,:)
  real(8) a1(3), a2(3), a3(3), maxocc, rms
  type (scf_type) :: rhoin ! used to store rho_in of current/next iteration
  real(8) :: dr2, etmp
  logical exst
  integer ierr, rank, use_sirius_mixer, use_sirius_veff, num_ranks_k, dims(3), ih, jh, ijh, na
  real(8) vlat(3, 3), vlat_inv(3, 3), v2(3), bg_inv(3, 3), charge
  integer kmesh(3), kshift(3), printout, vt(3)
  integer, external :: global_kpoint_index
  real(8), allocatable :: qij(:,:,:), deeq_tmp(:,:)
  complex(8), allocatable :: dens_mtrx(:,:), vxcg(:)
  integer, allocatable :: nk_loc(:)
  real(8) :: etot_cmp_paw(nat,2,2)
  !---------------
  ! paw one elec
  !---------------
  real(8) :: paw_one_elec_energy

  call sirius_start_timer(c_str("qe|electrons|init"))

  if ( dft_is_hybrid() ) then
    printout = 0  ! do not print etot and energy components at each scf step
  else if ( lmd ) then
    printout = 1  ! print etot, not energy components at each scf step
  else
    printout = 2  ! print etot and energy components at each scf step
  end if

  use_sirius_mixer = 0
  use_sirius_veff = 0
  
  ! create Density class
  call sirius_create_density()
   
  ! create Potential class
  call sirius_create_potential()

  ! initialize ground-state class
  call sirius_create_ground_state(kset_id)

  ! generate initial density from atomic densities rho_at
  call sirius_generate_initial_density()

  ! generate effective potential
  call sirius_generate_effective_potential()

  ! initialize subspace before calling "sirius_find_eigen_states"
  call sirius_initialize_subspace(kset_id)

  ! initialize internal library mixer
  if (use_sirius_mixer.eq.1) then
    call sirius_density_mixer_initialize()
  endif

  write(stdout, 9002)
  !CALL flush_unit( stdout )

  call create_scf_type(rhoin)
  call sirius_get_pw_coeffs(c_str("rho"), rho%of_g(1, 1), ngm, mill(1, 1), intra_bgrp_comm)
  call scf_type_copy(rho, rhoin)
  call open_mix_file(iunmix, 'mix', exst)

  call sirius_stop_timer(c_str("qe|electrons|init"))

  call sirius_start_timer(c_str("qe|electrons"))

  conv_elec = .false.

  allocate(dens_mtrx(nhm, nhm))
  allocate(deeq_tmp(nhm, nhm))
  allocate(vxcg(ngm))

  call set_rhoc_sirius
  !call set_vloc_sirius
  !CALL setlocal()
  call sirius_get_pw_coeffs(c_str("vloc"), vxcg(1), ngm, mill(1, 1), intra_bgrp_comm)
  psic(:) = 0.d0
  psic(nl(:)) = vxcg(:)
  if (gamma_only) psic(nlm(:)) = conjg(vxcg(:))
  call invfft('Dense', psic, dfftp)
  vltot(:) = dble(psic(:)) * 2 ! convert to Ry
  v_of_0=0.d0
  IF (gg(1) < eps8) v_of_0 = dble(vxcg(1))
  !
  CALL mp_sum( v_of_0, intra_bgrp_comm )


  do iter = 1, niter
    write(stdout, 9010)iter, ecutwfc, mixing_beta

    if (iter.gt.1) then
       !
       if (iter.eq.2) then
          ethr = 1.D-2
       else
          ethr = min(ethr, 0.1d0 * dr2 / max(1.d0, nelec))
          ! ... do not allow convergence threshold to become too small:
          ! ... iterative diagonalization may become unstable
          ethr = max(ethr, 1.d-13)
       endif
       !
       call sirius_set_iterative_solver_tolerance(ethr)
    end if

    ! solve H\spi = E\psi
    call sirius_find_eigen_states(kset_id, precompute=1)

!    ! use sirius to calculate band occupancies
!     CALL sirius_find_band_occupancies(kset_id)
!     CALL sirius_get_energy_fermi(kset_id, ef)
!     ef = ef * 2.d0

    allocate(band_e(nbnd, nkstot))
    ! get band energies
    do ik = 1, nkstot
      call sirius_get_band_energies(kset_id, ik, band_e(1, ik))
    end do

    do ik = 1, nks
      ! convert to Ry
      et(:, ik) = 2.d0 * band_e(:, global_kpoint_index ( nkstot, ik ))
    enddo

    deallocate(band_e)

    ! compute band weights
    call weights()

    ! compute occupancies
    allocate(bnd_occ(nbnd, nkstot ))
    bnd_occ = 0.d0
    ! define a maximum band occupancy (2 in case of spin-unpolarized, 1 in case of spin-polarized)
    maxocc = 2.d0
    do ik = 1, nks
      bnd_occ(:, global_kpoint_index ( nkstot, ik )) = maxocc * wg(:, ik) / wk(ik)
    enddo
    call mpi_allreduce(MPI_IN_PLACE, bnd_occ(1, 1), nbnd * nkstot, MPI_DOUBLE, MPI_SUM, inter_pool_comm, ierr)

    ! set band occupancies
    do ik = 1, nkstot
      call sirius_set_band_occupancies(kset_id, ik, bnd_occ(1, ik))
    enddo
    deallocate(bnd_occ)

    !  generate valence density
    call sirius_generate_valence_density(kset_id)

    if (.not.nosym) call sirius_symmetrize_density()
    
    call sirius_start_timer(c_str("qe|mix"))
    ! mix density with SIRIUS
    if (use_sirius_mixer.eq.1) then
      call sirius_mix_density(rms)
      call sirius_get_density_dr2(dr2)
    endif
    ! get rho(G)
    call sirius_get_pw_coeffs(c_str("rho"), rho%of_g(1, 1), ngm, mill(1, 1), intra_bgrp_comm)
    ! get density matrix
    do iat = 1, nsp
      do na = 1, nat
        if (ityp(na).eq.iat.and.allocated(rho%bec)) then
          rho%bec(:, na, :) = 0.d0
          call sirius_get_density_matrix(na, dens_mtrx(1, 1), nhm)
          ijh = 0
          do ih = 1, nh(iat)
            do jh = ih, nh(iat)
              ijh = ijh + 1
              rho%bec(ijh, na, 1) = dens_mtrx(ih, jh)
              ! off-diagonal elements
              if (ih.ne.jh) then
                rho%bec(ijh, na, 1) = rho%bec(ijh, na, 1) * 2.d0
              endif
            enddo
          enddo
        endif
      enddo
    enddo
    ! mix density with QE
    if (use_sirius_mixer.eq.0) then
      ! mix density
      call mix_rho(rho, rhoin, mixing_beta, dr2, 0.d0, iter, nmix, iunmix, conv_elec)
      ! broadcast
      call bcast_scf_type(rhoin, root_pool, inter_pool_comm)
      call scf_type_COPY(rhoin, rho)
      call mp_bcast(dr2,       root_pool, inter_pool_comm)
      call mp_bcast(conv_elec, root_pool, inter_pool_comm)
      ! set new (mixed) rho(G)
      call sirius_set_pw_coeffs(c_str("rho"), rho%of_g(1, 1), ngm, mill(1, 1), intra_bgrp_comm)
      ! set new (mixed) density matrix
    endif
    call sirius_stop_timer(c_str("qe|mix"))
    
    ! generate effective potential
    call sirius_start_timer(c_str("qe|veff"))
    if (use_sirius_veff.eq.1) then
      call sirius_generate_effective_potential()
      call sirius_get_energy_exc(etxc)
      etxc = etxc * 2.d0
      call sirius_get_energy_vxc(vtxc)
      vtxc = vtxc * 2.d0
      call sirius_get_energy_vha(ehart) ! E_Ha = 0.5 <V_Ha|rho> in Hartree units = <V_Ha|rho> in Ry units
    else
      ! transform density to real-space  
      do is = 1, nspin_mag
         psic(:) = 0.d0
         psic(nl(:)) = rho%of_g(:,is)
         if (gamma_only) psic(nlm(:)) = conjg(rho%of_g(:,is))
         call invfft('Dense', psic, dfftp)
         rho%of_r(:,is) = dble(psic(:))
      end do

      ! calculate potential (Vha + Vxc)
      call v_of_rho(rho, rho_core, rhog_core, ehart, etxc, vtxc, eth, etotefield, charge, v)
      ! calculate PAW potential
      if (okpaw) then
        call PAW_potential(rho%bec, ddd_PAW, epaw, etot_cmp_paw)
      endif

      ! add local part of the potential and transform to PW domain
      psic(:) = v%of_r(:, 1) + vltot(:)
      call fwfft('Dense', psic, dfftp)
      ! convert to Hartree
      do ig = 1, ngm
         v%of_g(ig, 1) = psic(nl(ig)) * 0.5d0
      enddo
      ! set effective potential
      call sirius_set_pw_coeffs(c_str("veff"),v%of_g(1, 1), ngm, mill(1, 1), intra_bgrp_comm)

      ! convert Vxc to plane-wave domain
      if (nspin.eq.1.or.nspin.eq.4) then
         do ir = 1, dfftp%nnr
            psic(ir) = vxc(ir, 1)
         enddo
      else
         do ir = 1, dfftp%nnr
            psic(ir) = 0.5d0 * (vxc(ir, 1) + vxc(ir, 2))
         enddo
      endif
      call fwfft('Dense', psic, dfftp)
      ! convert to Hartree
      do ig = 1, ngm
         vxcg(ig) = psic(nl(ig)) * 0.5d0
      end do
      ! set XC potential
      call sirius_set_pw_coeffs(c_str("vxc"), vxcg(1), ngm, mill(1, 1), intra_bgrp_comm)

      ! update D-operator matrix
      call sirius_generate_d_operator_matrix()
      if (okpaw) then
        ! get D-operator matrix
        do ia = 1, nat
          call sirius_get_d_operator_matrix(ia, deeq(1, 1, ia, 1), nhm)
          ! convert to Ry
          deeq(:, :, ia, :) = deeq(:, :, ia, :) * 2
        enddo
        call add_paw_to_deeq(deeq)
        do ia = 1, nat
          deeq_tmp(:, :) = deeq(:, :, ia, 1) / 2.d0 ! convert to Ha
          call sirius_set_d_operator_matrix(ia, deeq_tmp(1, 1), nhm)
        enddo
      endif
    endif
    call sirius_stop_timer(c_str("qe|veff"))

    call sirius_get_energy_ewald(ewld)
    call sirius_get_evalsum(eband)
    call sirius_get_energy_veff(deband)
    call sirius_get_energy_vloc(etmp)
    ewld = ewld * 2.d0
    eband = eband * 2.d0
    deband = -(deband - etmp) * 2.d0
    
    !!== ! ... the Harris-Weinert-Foulkes energy is computed here using only
    !!== ! ... quantities obtained from the input density
    !!== !
    !!== hwf_energy = eband + deband_hwf + (etxc - etxcc) + ewld + ehart + demet
    !!== If ( okpaw ) hwf_energy = hwf_energy + epaw
    !!== IF ( lda_plus_u ) hwf_energy = hwf_energy + eth

    if (conv_elec) write(stdout, 9101)

    if (conv_elec.or.mod(iter, iprint).eq.0) then
       write(stdout, 9101)
       !IF ( lda_plus_U .AND. iverbosity == 0 ) THEN
       !   IF (noncolin) THEN
       !      CALL write_ns_nc()
       !   ELSE
       !      CALL write_ns()
       !   ENDIF
       !ENDIF

       ! get band energies
       do ik = 1, nkstot
         call sirius_get_band_energies(kset_id, ik, et(1, ik))
       enddo
       et = et * 2.d0
       call print_ks_energies()
    endif

    ! total energy
    etot = eband + (etxc - etxcc) + ewld + ehart + deband + demet !+ descf

    if (okpaw) then
      if (use_sirius_veff.eq.1) then
        call sirius_get_paw_total_energy(epaw)
        call sirius_get_paw_one_elec_energy(paw_one_elec_energy)
        epaw = epaw * 2.0;
        paw_one_elec_energy = paw_one_elec_energy * 2.0;
        etot = etot - paw_one_elec_energy + epaw
      endif
      if (use_sirius_veff.eq.0) then
        etot = etot + epaw - sum(ddd_paw(:, :, :) * rho%bec(:, :, :))
      endif
    endif

    ! TODO: this has to be called correcly - there are too many dependencies
    call print_energies(printout)

    if (dr2 .lt. conv_thr .and. use_sirius_mixer.eq.1) then
      conv_elec=.true.
    endif

    if (conv_elec) then
       !
       ! ... if system is charged add a Makov-Payne correction to the energy
       !
       !!IF ( do_makov_payne ) CALL makov_payne( etot )
       !
       ! ... print out ESM potentials if desired
       !
       !!IF ( do_comp_esm ) CALL esm_printpot()
       !
       write(stdout, 9110) iter
       !
       ! ... jump to the end
       !
       GO TO 10
       !
    end if

  enddo
  write(stdout, 9101)
  write(stdout, 9120) iter

10 continue

  call sirius_stop_timer(c_str("qe|electrons"))

  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  !probably calculate forces here
  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
  call sirius_calc_forces(force(1,1))

  do ia = 1, nat
    do i = 1, 3
      force(i, ia) = 2.0 * force(i, ia)
    enddo
  enddo

  deallocate(dens_mtrx)
  deallocate(deeq_tmp)
  deallocate(vxcg)


  !
  !!IF ( ABS( charge - nelec ) / charge > 1.D-7 ) THEN
  !!   WRITE( stdout, 9050 ) charge, nelec
  !!   IF ( ABS( charge - nelec ) / charge > 1.D-3 ) THEN
  !!      IF (.not.lgauss) THEN
  !!         CALL errore( 'electrons', 'charge is wrong: smearing is needed', 1 )
  !!      ELSE
  !!         CALL errore( 'electrons', 'charge is wrong', 1 )
  !!      END IF
  !!   END IF
  !!END IF
  !!!
  !!!
  !!IF (okpaw) etot = etot + epaw
  !!IF ( lda_plus_u ) etot = etot + eth
  !!!
  !!IF ( lelfield ) etot = etot + en_el
  !!! not sure about the HWF functional in the above case
  !!IF( textfor ) THEN
  !!   eext = alat*compute_eextfor()
  !!   etot = etot + eext
  !!   hwf_energy = hwf_energy + eext
  !!END IF
  !!IF (llondon) THEN
  !!   etot = etot + elondon
  !!   hwf_energy = hwf_energy + elondon
  !!END IF
  !!! calculate the xdm energy contribution with converged density
  !!if (lxdm .and. conv_elec) then
  !!   exdm = energy_xdm()
  !!   etot = etot + exdm
  !!   hwf_energy = hwf_energy + exdm
  !!end if
  !!IF (ts_vdw) THEN
  !!   ! factor 2 converts from Ha to Ry units
  !!   etot = etot + 2.0d0*EtsvdW
  !!   hwf_energy = hwf_energy + 2.0d0*EtsvdW
  !!END IF
  !!!
  !!IF ( tefield ) THEN
  !!   etot = etot + etotefield
  !!   hwf_energy = hwf_energy + etotefield
  !!END IF
  !!!
  !!IF ( lfcpopt .or. lfcpdyn ) THEN
  !!   etot = etot + ef * tot_charge
  !!   hwf_energy = hwf_energy + ef * tot_charge
  !!ENDIF
  !!!
  !!! ... adds possible external contribution from plugins to the energy
  !!!
  !!etot = etot + plugin_etot 
  !!!
  !!CALL print_energies ( printout )
  !!!
  !!IF ( conv_elec ) THEN
  !!   !
  !!   ! ... if system is charged add a Makov-Payne correction to the energy
  !!   !
  !!   IF ( do_makov_payne ) CALL makov_payne( etot )
  !!   !
  !!   ! ... print out ESM potentials if desired
  !!   !
  !!   IF ( do_comp_esm ) CALL esm_printpot()
  !!   !
  !!   WRITE( stdout, 9110 ) iter
  !!   !
  !!   ! ... jump to the end
  !!   !
  !!   GO TO 10
  !!   !
  !!END IF

  call close_mix_file(iunmix, 'delete')
  call destroy_scf_type(rhoin)

  do ia = 1, nat
    call sirius_get_d_operator_matrix(ia, deeq(1, 1, ia, 1), nhm)
    ! convert to Ry
    deeq(:, :, ia, :) = deeq(:, :, ia, :) * 2
  enddo
  do iat = 1, nsp
    call sirius_get_q_operator_matrix(iat, qq(1, 1, iat), nhm)
  enddo

  !do iat = 1, nsp
  !   if ( upf(iat)%tvanp ) then
  !      do na = 1, nat
  !         if (ityp(na)==iat) then
  !            ijh = 0
  !            do ih = 1, nh(iat)
  !               do jh = ih, nh(iat)
  !                  ijh = ijh + 1
  !                  call sirius_get_density_matrix(ih, jh, na, becsum(ijh, na, 1))
  !                  ! off-diagonal elements
  !                  if (ih.ne.jh) becsum(ijh, na, 1) = becsum(ijh, na, 1) * 2
  !               end do
  !            end do
  !         endif
  !      enddo
  !   endif
  !enddo

  ! transform density to real-space  
  do is = 1, nspin_mag
     psic(:) = ( 0.d0, 0.d0 )
     psic(nl(:)) = rho%of_g(:,is)
     if ( gamma_only ) psic(nlm(:)) = conjg( rho%of_g(:,is) )
     call invfft ('Dense', psic, dfftp)
     rho%of_r(:,is) = psic(:)
     !
  end do

  allocate(band_e(nbnd, nkstot))
  ! get band energies
  do ik = 1, nkstot
    call sirius_get_band_energies(kset_id, ik, band_e(1, ik))
  end do
  do ik = 1, nks
    ! convert to ry
    et(:, ik) = 2.d0 * band_e(:, global_kpoint_index ( nkstot, ik ))
  enddo
  deallocate(band_e)

  !CALL sirius_print_timers()
  !CALL sirius_write_json_output()
  
  !call sirius_delete_ground_state()
  !call sirius_delete_kset(kset_id)
  !call sirius_delete_density()
  !call sirius_delete_potential()
  !call sirius_delete_simulation_context()

  !CALL sirius_clear()

9000 format(/'     total cpu time spent up to now is ',F10.1,' secs' )
9001 format(/'     per-process dynamical memory: ',f7.1,' Mb' )
9002 format(/'     Self-consistent Calculation' )
9010 format(/'     iteration #',I3,'     ecut=', F9.2,' Ry',5X,'beta=',F4.2 )
9050 format(/'     WARNING: integrated charge=',F15.8,', expected=',F15.8 )
9101 format(/'     End of self-consistent calculation' )
9110 format(/'     convergence has been achieved in ',i3,' iterations' )
9120 format(/'     convergence NOT achieved after ',i3,' iterations: stopping' )
    contains

     !-----------------------------------------------------------------------
     subroutine print_energies ( printout )
       !-----------------------------------------------------------------------
       !
       use constants, only : eps8
       integer, intent (IN) :: printout
       !
       if ( printout == 0 ) return
       if ( ( conv_elec .or. mod(iter,iprint) == 0 ) .and. printout > 1 ) then
          !
          if ( dr2 > eps8 ) then
             write(stdout, 9081) etot, hwf_energy, dr2
          else
             write(stdout, 9083) etot, hwf_energy, dr2
          end if
          !!IF ( only_paw ) WRITE( stdout, 9085 ) etot+total_core_energy
          !
          write( stdout, 9060 ) &
               ( eband + deband ), ehart, ( etxc - etxcc ), ewld
          !
          if ( llondon ) write ( stdout , 9074 ) elondon
          if ( lxdm )    write ( stdout , 9075 ) exdm
          !!IF ( ts_vdw )  WRITE ( stdout , 9076 ) 2.0d0*EtsvdW
          !!IF ( textfor)  WRITE ( stdout , 9077 ) eext
       !!   IF ( tefield )            WRITE( stdout, 9061 ) etotefield
       !!   IF ( lda_plus_u )         WRITE( stdout, 9065 ) eth
       !!   IF ( ABS (descf) > eps8 ) WRITE( stdout, 9069 ) descf
          if ( okpaw )              write( stdout, 9067 ) epaw
       !!   !
       !!   ! ... With Fermi-Dirac population factor, etot is the electronic
       !!   ! ... free energy F = E - TS , demet is the -TS contribution
       !!   !
          if ( lgauss ) write( stdout, 9070 ) demet
       !!   !
       !!   ! ... With Fictitious charge particle (FCP), etot is the grand
       !!   ! ... potential energy Omega = E - muN, -muN is the potentiostat
       !!   ! ... contribution.
       !!   !
       !!   IF ( lfcpopt .or. lfcpdyn ) WRITE( stdout, 9072 ) ef*tot_charge
       !!   !
        else if ( conv_elec ) then
          !
          if ( dr2 > eps8 ) then
             write( stdout, 9081 ) etot, hwf_energy, dr2
          else
             write( stdout, 9083 ) etot, hwf_energy, dr2
          end if
          !
       else
          !
          if ( dr2 > eps8 ) then
             write( stdout, 9080 ) etot, hwf_energy, dr2
          else
             write( stdout, 9082 ) etot, hwf_energy, dr2
          end if
       end if
       
       call plugin_print_energies()
       !!!
       !!IF ( lsda ) WRITE( stdout, 9017 ) magtot, absmag
       !!!
       !!IF ( noncolin .AND. domag ) &
       !!     WRITE( stdout, 9018 ) magtot_nc(1:3), absmag
       !!!
       !!IF ( i_cons == 3 .OR. i_cons == 4 )  &
       !!     WRITE( stdout, 9071 ) bfield(1), bfield(2), bfield(3)
       !!IF ( i_cons /= 0 .AND. i_cons < 4 ) &
       !!     WRITE( stdout, 9073 ) lambda
       !!!
       !CALL flush_unit( stdout )
       !
       return
       !
9017 format(/'     total magnetization       =', F9.2,' Bohr mag/cell', &
            /'     absolute magnetization    =', F9.2,' Bohr mag/cell' )
9018 format(/'     total magnetization       =',3F9.2,' Bohr mag/cell' &
       &   ,/'     absolute magnetization    =', F9.2,' Bohr mag/cell' )
9060 format(/'     The total energy is the sum of the following terms:',/,&
            /'     one-electron contribution =',F17.8,' Ry' &
            /'     hartree contribution      =',F17.8,' Ry' &
            /'     xc contribution           =',F17.8,' Ry' &
            /'     ewald contribution        =',F17.8,' Ry' )
9061 format( '     electric field correction =',F17.8,' Ry' )
9065 format( '     Hubbard energy            =',F17.8,' Ry' )
9067 format( '     one-center paw contrib.   =',F17.8,' Ry' )
9069 format( '     scf correction            =',F17.8,' Ry' )
9070 format( '     smearing contrib. (-TS)   =',F17.8,' Ry' )
9071 format( '     Magnetic field            =',3F12.7,' Ry' )
9072 format( '     pot.stat. contrib. (-muN) =',F17.8,' Ry' )
9073 format( '     lambda                    =',F11.2,' Ry' )
9074 format( '     Dispersion Correction     =',F17.8,' Ry' )
9075 format( '     Dispersion XDM Correction =',F17.8,' Ry' )
9076 format( '     Dispersion T-S Correction =',F17.8,' Ry' )
9077 format( '     External forces energy    =',F17.8,' Ry' )
9080 format(/'     total energy              =',0PF17.8,' Ry' &
            /'     Harris-Foulkes estimate   =',0PF17.8,' Ry' &
            /'     estimated scf accuracy    <',0PF17.8,' Ry' )
9081 format(/'!    total energy              =',0PF17.8,' Ry' &
            /'     Harris-Foulkes estimate   =',0PF17.8,' Ry' &
            /'     estimated scf accuracy    <',0PF17.8,' Ry' )
9082 format(/'     total energy              =',0PF17.8,' Ry' &
            /'     Harris-Foulkes estimate   =',0PF17.8,' Ry' &
            /'     estimated scf accuracy    <',1PE17.1,' Ry' )
9083 format(/'!    total energy              =',0PF17.8,' Ry' &
            /'     Harris-Foulkes estimate   =',0PF17.8,' Ry' &
            /'     estimated scf accuracy    <',1PE17.1,' Ry' )
9085 format(/'     total all-electron energy =',0PF17.6,' Ry' )

  end subroutine print_energies

end subroutine

subroutine invert_mtrx(vlat, vlat_inv)
  implicit none
  real(8), intent(in) :: vlat(3,3)
  real(8), intent(out) :: vlat_inv(3, 3)
  real(8) d1

  d1 = vlat(1,2)*vlat(2,3)*vlat(3,1)-vlat(1,3)*vlat(2,2)*vlat(3,1)+vlat(1,3)*vlat(2,1)*vlat(3,2) &
   &-vlat(1,1)*vlat(2,3)*vlat(3,2)+vlat(1,1)*vlat(2,2)*vlat(3,3)-vlat(1,2)*vlat(2,1)*vlat(3,3)
  d1 = 1.d0 / d1
  vlat_inv(1,1)=(vlat(2,2)*vlat(3,3)-vlat(2,3)*vlat(3,2))*d1
  vlat_inv(1,2)=(vlat(1,3)*vlat(3,2)-vlat(1,2)*vlat(3,3))*d1
  vlat_inv(1,3)=(vlat(1,2)*vlat(2,3)-vlat(1,3)*vlat(2,2))*d1
  vlat_inv(2,1)=(vlat(2,3)*vlat(3,1)-vlat(2,1)*vlat(3,3))*d1
  vlat_inv(2,2)=(vlat(1,1)*vlat(3,3)-vlat(1,3)*vlat(3,1))*d1
  vlat_inv(2,3)=(vlat(1,3)*vlat(2,1)-vlat(1,1)*vlat(2,3))*d1
  vlat_inv(3,1)=(vlat(2,1)*vlat(3,2)-vlat(2,2)*vlat(3,1))*d1
  vlat_inv(3,2)=(vlat(1,2)*vlat(3,1)-vlat(1,1)*vlat(3,2))*d1
  vlat_inv(3,3)=(vlat(1,1)*vlat(2,2)-vlat(1,2)*vlat(2,1))*d1
end subroutine

