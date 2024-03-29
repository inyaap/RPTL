program main
use constants
use variables
use FMFD, only: DET_POWER, INTRA_PIN_DTMC
use FMFD_HEADER, only: p_fmfd, k_fmfd, fmfdon, cmfdon, nfm
use ENTROPY,    only : mprupon, entrp0
use TH_HEADER, only: th_on
use simulation 
use DEPLETION_MODULE
use omp_lib
use mpi
use transient
use TEMPERATURE, only: TEMP_DISTRIBUTE
use TALLY, only: k_eff, tallyon
use PCQS, only : n_pcqs_totcyc, solve_PKE, n_pcqs_act, PKE_init

!use ace_header, only: udelta, Emin, ugrid, nugrid

implicit none

integer :: i,j, ierg, iso 
integer :: provide 
real(8) :: time1, time2, time3, time4, time5, time6, time_dep, time_dep_done
real(8) :: k_sum 
logical :: isopened
real(8) :: tt1, tt2, tt3
integer :: jj, kk
real(8),allocatable :: tally_val(:,:)
integer :: nsize
real(8), allocatable :: ttemp(:,:,:)
real(8) :: erg, ipfac
character(100) :: filename
real(8) :: kavg, kstd
character(80) :: dfile, dfile1

!> Preparation for parallelization ===============================================
!call omp_set_num_threads(14)
call MPI_Init_thread(MPI_THREAD_SINGLE, provide, ierr)
core = MPI_COMM_WORLD
call MPI_COMM_RANK(core,icore,ierr)
call MPI_COMM_SIZE(core,ncore,ierr)

!> PreMC : Read input / Initialize / Set Random Seed etc. ========================
call premc
call TIME_MEASURE


!> Stead-state Simlulation Start =================================================
call START_MSG

curr_bat = 0
BATCH : do

    if ( n_batch == 1 ) curr_bat = 1
    if ( n_batch > 1 ) call BATCH_MSG(curr_bat)


BURNUP : do

    time3 = omp_get_wtime()
    if (do_ueg) then
        time1 = omp_get_wtime()
        call setMacroXS(istep_burnup/=0)
        time2 = omp_get_wtime()
        call MPI_BARRIER(MPI_COMM_WORLD, ierr)
        if (icore==score) print *, '    UEG', do_ueg, nuni
        if (icore==score) print *, '    MAT XS BUILD DONE'
        if (icore==score) print *, '    Elapsed Time [s]:', time2-time1
    endif
    if ( do_burn ) then
        call INIT_BURNUP
        if (icore==score) call BURNUP_MSG
    end if
	
	if( tally_switch > 0 .and. icore == score .and. .not. do_transient) then
		open(prt_flux,file="flux.out",action="write",status="replace")
		open(prt_powr,file="power.out",action="write",status="replace")
	end if
	
	
	if (do_DMC) open(prt_dynamic,file="dynamicMC.out",action="write",status="replace")
	if (do_DMC)open(prt_wgt ,file="tetstop.out",action="write",status="replace")
	
	
	if (do_gmsh_vrc) then 
		do i = 1, n_timestep
			if (i < 10) then 
				write (filename, "(A22,I1,A4)") "./tet_vrc/data/tet_vrc", i, ".dat"
			elseif (i < 100) then 
				write (filename, "(A22,I2,A4)") "./tet_vrc/data/tet_vrc", i, ".dat"
			elseif (i < 1000) then 
				write (filename, "(A22,I3,A4)") "./tet_vrc/data/tet_vrc", i, ".dat"
			else 
				print *, "ERROR :: TOO MANY ACTIVE CYCLES FOR GMSH_VRC - ", n_timestep
				stop
			endif 
			open(prt_tet_vrc, file=trim(filename), action="write",status="replace")
			close(prt_tet_vrc)
		enddo 
	endif 
	
	if (do_DMC .and. tally_switch > 0 .and. icore == score) then 
		call system("mkdir -p ./DMC_data/") 
		do i = 1, n_timestep
			if (i < 10) then 
				write (filename, "(A22,I1,A4)") "./DMC_data/power", i, ".out"
			elseif (i < 100) then                           
				write (filename, "(A22,I2,A4)") "./DMC_data/power", i, ".out"
			elseif (i < 1000) then                          
				write (filename, "(A22,I3,A4)") "./DMC_data/power", i, ".out"
			else 
				print *, "ERROR :: TOO MANY timesteps for DMC TET - ", n_timestep
				stop
			endif 
			open(prt_powr, file=trim(filename), action="write",status="replace")
			close(prt_powr)
		enddo 
	endif
    if(do_fuel_mv) open(prt_fuel_mv,file=trim(title)//'_MSR_prec',action='write',status='unknown')	
	
TH : do
	
    ! steady-state calculation
    CYC: Do curr_cyc = 1, n_totcyc
        curr_act = curr_cyc - n_inact
        !> history wise transport simulation
        time1 = omp_get_wtime()
        call simulate_history(curr_bat,curr_cyc)
        time2 = omp_get_wtime()
        if ( icore == score ) t_tot(curr_bat,curr_cyc) = time2-time1
        call RUN_MSG(curr_bat)
		if (curr_cyc <= n_inact) cycle CYC
		if (.not. do_DMC) cycle CYC
		
		curr_time = 0 
		call normalizeInitialSource()
		cyc_power0 = 0
		w_tot = sum(fission_bank(:)%wgt) 
		call save_condition() 
		!call save_MG_XS()	! ------------------------------ save MG XS for perturbation 
		Do curr_timestep = 1, n_timestep
			!write (prt_dynamic, *) "========== NEW TIME STEP ",curr_timestep," =========="
			!call adjust_MG_XS() ! -------------------------- Adjust MG XS accordingly
			!call adjust_CE_MAT() ! CE mat number density change
			call condition_change()
			time1 = omp_get_wtime()
			call Dynamic_MC()
			curr_time = curr_time + del_t
			time2 = omp_get_wtime()
			if ( icore == score ) &
			print '(I3,f9.5,e13.4,a18,f9.1,a)', curr_timestep, DMC_keff, cyc_power &
										  ,' | elapsed time : ', time2-time1, " sec"
			if (icore==score) write(prt_dynamic, *) curr_timestep, DMC_keff, cyc_power
		Enddo 
		!call restore_MG_XS() ! ----------------------------- Restore MG XS for the next cycle 
		call restore_condition()
		call finalize_src()
    Enddo CYC
	
	if (do_DMC) then 
		close(prt_dynamic)
		!close(prt_wgt)
	endif 

    if(do_fuel_mv) close(prt_fuel_mv)	

    if (do_mgtally) then
        do i = 1, n_mg
            if(icore==score) print *, i, micro_flux(i), micro_flux(i)/sum(micro_flux)
        enddo
!        if(icore==score) print *, 'TOTXS', ogtot/ogflx
!        if(icore==score) print *, 'FISXS', ogfis/ogflx
!        if(icore==score) print *, 'CAPXS', ogcap/ogflx
!        if(icore==score) print *, 'ABSXS', ogabs/ogflx
    endif
	
	
	!> PCQS Transient MC =============================================================================
	if (.not. do_PCQS) goto 99
	!open(prt_dynamic,file="PCQS.out",action="write",status="replace")
	open(prt_wgt,file="PCQS_power.out",action="write",status="replace")
	open(prt_prec,file="PCQS_wgt.out",action="write",status="replace")
	open(prt_delayed,file="PCQS_corrector.out",action="write",status="replace")
	
	curr_time = 0
	call PKE_init() 
	call PCQS_INIT()
	!PCQS_keff = AVG(k_eff(curr_bat,n_inact+1:n_totcyc))
	call save_condition() 
	curr_timestep = 0 
	if ( icore == score ) print *, 'timestep ', curr_timestep
	Do curr_cyc = 1, n_pcqs_totcyc
		call PCQS_MC() 
	Enddo 
	call solve_PKE() 
	
	Do curr_timestep = 1, n_timestep
		
		if ( icore == score ) then
			print *, '' 
			print '(a10,I)', ' Timestep ', curr_timestep
		endif
		call condition_change()
		cyc_power0 = 0
		
		!> Predictor 
		corrector = .false. 
		Do curr_cyc = 1, n_pcqs_totcyc
			call PCQS_MC() 
		Enddo 
		
		!> Solve PKE (Corrector) 
		call solve_PKE() 
		
		
		kavg = sum(PCQS_keff_cyc(:))/n_pcqs_act
		kstd = sqrt(dot_product((PCQS_keff_cyc(:)-kavg),(PCQS_keff_cyc(:)-kavg))/(n_pcqs_act*(n_pcqs_act-1)))
		
		
		if (icore==score) write(prt_delayed,'(E11.3,2F16.6, F15.2, 3E15.5)') &
						curr_time, PKE_keff, kavg, kstd*1d5, PKE_amp, PCQS_power(curr_timestep,1)*PKE_f, 100d0*PCQS_power(curr_timestep,2)/PCQS_power(curr_timestep,1)
		
		curr_time = curr_time + del_t
		
		
		!> Zero tally bank 
		PKE_beta_tally1 = 0;  PKE_beta_tally2 = 0;
		PKE_lambda_tally1 = 0; PKE_lambda_tally2 = 0;
		PKE_prec_tally1 = 0;  PKE_prec_tally2 = 0;
		PKE_gen_tally1 = 0;  PKE_gen_tally2 = 0;
		PKE_keff_tally = 0; PKE_Z_tally1 = 0
		
		
	Enddo 
	
	call restore_condition()
	call finalize_src()
	!close(prt_dynamic)
	close(prt_wgt)
	close(prt_prec)
	close(prt_delayed)
	
	!> End of PCQS 
	! ===============================================================================================
	
	
	
99  if (do_gmsh_vrc) close(prt_tet_vrc)
	!close(prt_wgt)
    time4 = omp_get_wtime()
    call END_MSG(curr_bat)
    call CYCLE_TALLY_MSG(curr_bat)
	
    if ( th_on ) then
        if ( icore == score ) then
        allocate(ttemp(nfm(1),nfm(2),nfm(3)))
        do ii = 1, nfm(1)
        do jj = 1, nfm(2)
        do kk = 1, nfm(3)
            ttemp(ii,jj,kk) = AVG(p_fmfd(curr_bat,:,ii,jj,kk))
        end do
        end do
        end do
        call DET_POWER(ttemp(:,:,:))
        call TEMP_SOLVE
        call TEMP_DISTRIBUTE
        call TEMP_CONVERGE
        deallocate(ttemp)
        end if
    else
        exit
    end if

end do TH



    !> Check burnup loop exit condition
    if ( do_burn ) then
        time_dep = omp_get_wtime() 
		!> Gather Burnup Tallies
		call MPI_reduce_burnup()
        
        !> Intra-pin flux distribution for iDTMC
        if ( fmfdon ) call INTRA_PIN_DTMC

		!> Make & Solve depletion matrix
		call depletion
	    time_dep_done = omp_get_wtime()
        if ( istep_burnup > nstep_burnup ) exit BURNUP
    else
        exit BURNUP
    end if
    call MPI_BARRIER(core,ierr)
    if(icore==score) print *, 'TIME FOR BU[s]: ', time_dep_done-time_dep
end do BURNUP

    if ( curr_bat == n_batch ) then
        if ( n_batch > 1 ) call BATCH_TALLY_MSG
        exit BATCH
    end if
    curr_bat = curr_bat + 1
    if ( n_batch > 1 .and. curr_bat == 1 ) then
        n_inact  = t_inact
        n_totcyc = t_totcyc
    end if

end do BATCH


if (allocated(source_bank)) deallocate(source_bank)
inquire(unit=prt_flux, opened=isopened)
if ( isopened ) close(prt_flux)
inquire(unit=prt_powr, opened=isopened)
if ( isopened ) close(prt_powr)
write(prt_keff, *) AVG(k_eff(curr_bat,n_inact+1:n_totcyc)), PCM(STD_M(k_eff(curr_bat,n_inact+1:n_totcyc)))
close(prt_keff)

if ( tally_switch > 0 .and. icore == score .and. .not. do_transient) then
	nsize = size(TallyFlux)
	allocate(tally_val(1:nsize, 1:n_act))
	
	open(prt_flux,file="flux.out",action="read",status="old")
	do i = 1, n_act 
		read(prt_flux, '(<nsize>ES15.7)') tally_val(:,i)
	enddo 
	close(prt_flux)
	open(prt_flux,file="flux.out",action="write",status="replace")
	do i = 1, nsize
		write(prt_flux, '(2ES15.7)') sum(tally_val(i,:))/n_act, STD_M(tally_val(i,:))
	enddo 
	close(prt_flux) 
	
	
	open(prt_powr,file="power.out",action="read",status="old")
	do i = 1, n_act 
		read(prt_powr, '(<nsize>ES15.7)') tally_val(:,i)
	enddo 
	close(prt_powr)
	open(prt_powr,file="power.out",action="write",status="replace")
	do i = 1, nsize
		write(prt_powr, '(2ES15.7)') sum(tally_val(i,:))/n_act, STD_M(tally_val(i,:))
	enddo 
	close(prt_powr) 
	deallocate(tally_val)
endif 



if ( tally_switch > 0 .and. icore == score .and. do_transient) then


	nsize = size(TallyPower)
	allocate(tally_val(1:nsize, 1:n_act))
	
	do curr_timestep = 1, n_timestep
		if (curr_timestep < 10) then 
			write (filename, "(A22,I1,A4)") "./DMC_data/power", curr_timestep, ".out"
		elseif (curr_timestep < 100) then                           
			write (filename, "(A22,I2,A4)") "./DMC_data/power", curr_timestep, ".out"
		elseif (curr_timestep < 1000) then                          
			write (filename, "(A22,I3,A4)") "./DMC_data/power", curr_timestep, ".out"
		endif 
		open(prt_powr,file=trim(filename),action="read",status="old")
		do i = 1, n_act 
			read(prt_powr, '(<nsize>ES15.7)') tally_val(:,i)
		enddo 
		close(prt_powr)
		
		open(prt_powr,file=trim(filename),action="write",status="replace")
		do i = 1, nsize
			write(prt_powr, '(2ES15.7)') sum(tally_val(i,:))/n_act, STD_M(tally_val(i,:))
		enddo 
		close(prt_powr) 
	enddo 
	deallocate(tally_val)
	
endif 

call process_MSR_prec()

call MPI_FINALIZE(ierr)

contains



function AVG(val)
    real(8):: avg
    real(8), intent(in):: val(:)

    avg = sum(val)/size(val)

end function

function PCM(val)
    real(8):: pcm
    real(8), intent(in):: val

    pcm = val*1E5

end function

function STD_M(val) ! STD of the sample mean
    real(8):: std_m
    real(8), intent(in):: val(:)
    integer:: length
    real(8):: avg

    length = size(val)
    avg = sum(val)/length
    std_m = sqrt(dot_product((val-avg),(val-avg))/(length*(length-1)))
    if ( isnan(std_m) ) std_m = 0

end function

function STD_S(val) ! sample STD
    real(8):: std_s
    real(8), intent(in):: val(:)
    integer:: length
    real(8):: avg

    length = size(val)
    avg = sum(val)/length
    std_s = sqrt(dot_product((val-avg),(val-avg))/(length-1))
    if ( isnan(std_s) ) std_s = 0

end function

function STD_P(val) ! STD for the power distribution
    real(8):: std_p
    real(8), intent(in):: val(:,:,:,:)
    real(8), allocatable:: std_(:,:,:)
    integer:: mm, nn, oo

    allocate(std_(nfm(1),nfm(2),nfm(3)))

    do mm = 1, nfm(1)
    do nn = 1, nfm(2)
    do oo = 1, nfm(3)
        std_(mm,nn,oo) = std_m(val(:,mm,nn,oo))
    end do
    end do
    end do

    std_p = sum(std_)/(nfm(1)*nfm(2)*nfm(3))
    if ( isnan(std_p) ) std_p = 0

    deallocate(std_)

end function

function STD_PS(val) ! sample STD for the power distribution
    real(8):: std_ps
    real(8), intent(in):: val(:,:,:,:)
    real(8), allocatable:: std_(:,:,:)
    integer:: mm, nn, oo

    allocate(std_(nfm(1),nfm(2),nfm(3)))

    do mm = 1, nfm(1)
    do nn = 1, nfm(2)
    do oo = 1, nfm(3)
        std_(mm,nn,oo) = std_s(val(:,mm,nn,oo))
    end do
    end do
    end do

    std_ps = sum(std_)/(nfm(1)*nfm(2)*nfm(3))
    if ( isnan(std_ps) ) std_ps = 0

    deallocate(std_)

end function

subroutine TIME_MEASURE
    use SIMULATION_HEADER, only: t_MC, t_det, t_tot
    implicit none
    allocate(t_MC(0:n_batch,n_totcyc))
    allocate(t_det(0:n_batch,n_totcyc))
    allocate(t_tot(0:n_batch,n_totcyc))
    t_MC  = 0
    t_det = 0

end subroutine

subroutine NORM_DIST(dist)
    real(8), intent(inout):: dist(1:,1:,:,:,:) ! (bat,cyc,x,y,z)

    do ii = 1, n_batch
    do jj = 1, n_act
        dist(ii,jj,:,:,:) = dist(ii,jj,:,:,:)/AVG_P(dist(ii,jj,:,:,:))
    end do
    end do

end subroutine

function AVG_P(val)
    real(8):: avg_p
    real(8), intent(in):: val(:,:,:)
    integer:: sz

    sz = size(val)
    avg_p = sum(val)/dble(sz)

end function

! =============================================================================
! BATCH_MSG
! =============================================================================
subroutine BATCH_MSG(curr_bat)
    integer, intent(in):: curr_bat

    if ( icore /= score ) return

    write(*,10), '   =========================================='
    write(*,11), '    Batch calculation #', curr_bat
    write(*,10), '   =========================================='
    write(*,*)

    10 format(A)
    11 format(A,i3)

end subroutine

! =============================================================================
! START_MSG
! =============================================================================
subroutine START_MSG
    use FMFD_HEADER, only: n_fake, pfmfdon, fmfd2mc
    implicit none

if ( icore==score ) then  

    write(*,*)
    write(*,*)
    write(*,10), '  > Num of Threads per Node   ', omp_get_max_threads()
    write(*,10), '  > Num of MPI Nodes          ', ncore
    write(*,10), '  > Num of Histories per Cycle', ngen
    write(*,11), '  > Skip Cycles:',n_inact , &
                 '  /  Active Cycles:', n_totcyc-n_inact
    write(*,*)
!    if (tally_switch > 0) then 
!        write(*,*), ' > Tally is On :: See tally.inp'
!    else 
!        write(*,*), ' > Tally is OFF' 
!    endif 

    if ( tallyon ) then
        write(*,*), ' > Tally is on'
    end if

    if (do_burn) then
        select case(depopt)
        case(0) ! Direct
            write(*,*) ' > DIRECT METHOD for DEP'
        case(2) ! Hybrid
            write(*,*) ' > HYBRID METHOD for DEP'
        case(7) ! Whole
            write(*,*) ' > Multi-Binning METHOD for DEP'
        case default
        endselect
    endif

    if ( mprupon ) then
    if ( ccrt == 1 .and. scrt == 1 ) then
        write(*,14), '  > m-PRUP is on', rampup, "  (1)", crt1c, "  (2)", crt2c
    else if ( ccrt == 1 .and. scrt == 2 ) then
        write(*,15), '  > m-PRUP is on', rampup, "  (1)", crt1c, "  (2)", crt2c
    else if ( ccrt == 2 .and. scrt == 1 ) then
        write(*,16), '  > m-PRUP is on', rampup, "  (1)", crt1c, "  (2)", crt2c
    else
        write(*,17), '  > m-PRUP is on', rampup, "  (1)", crt1c, "  (2)", crt2c
    end if
    else
        write(*,*), ' > m-PRUP is OFF'
    end if

    if ( fake_MC ) then
        write(*,13), '  > Fake MC is On ( No. of skips : ', n_fake, ' )'
    end if

    if ( fmfdon ) then
        if ( fmfd2mc ) then
        if ( pfmfdon ) then
        if ( cmfdon ) then
        write(*,*), ' > pFMFD with CMFD is On'
        else
        write(*,*), ' > pFMFD is On'
        end if
        else
        if ( cmfdon ) then
        write(*,*), ' > FMFD with CMFD is On'
        else
        write(*,*), ' > FMFD is On'
        end if
        end if
        else
        if ( pfmfdon ) then
        if ( cmfdon ) then
        write(*,*), ' > pFMFD with CMFD is On (w/o feedback)'
        else
        write(*,*), ' > pFMFD is On (w/o feedback)'
        end if
        else
        if ( cmfdon ) then
        write(*,*), ' > FMFD with CMFD is On (w/o feedback)'
        else
        write(*,*), ' > FMFD is On (w/o feedback)'
        end if
        end if
        end if
        write(*,18), '  >> accumulation length = ', n_acc
    else
        write(*,*), ' > FMFD is OFF'
    end if

    write(*,*)
    write(*,*), '   Transport Simulation Starts...' 

endif

10 format(A30,I9)
11 format(A16,I5,A19,I5)
12 format(A16)
13 format(A,I2,A)
14 format(A,I10,2(A,ES10.2))
15 format(A,I10,A,ES10.2,A,F10.1)
16 format(A,I10,A,F4.1,A,ES10.2)
17 format(A,I10,A,F4.1,A,F10.1)
18 format(A,i4)

end subroutine

! =============================================================================
! BURNUP_MSG
! =============================================================================
subroutine BURNUP_MSG
    write(*,10), '   =========================================='
    write(*,11), '      Burnup step', istep_burnup, '/',nstep_burnup
    write(*,12), burn_step(istep_burnup)/86400.d0, ' CUMULATIVE DAYS'
    write(*,10), '   =========================================='

    10 format(A45)
    11 format(A17,I4,A1,I4)
    12 format(F14.2,A16)

end subroutine


! =============================================================================
! RUN_MSG
! =============================================================================
subroutine RUN_MSG(bat)
use ENTROPY, only: up_sign
implicit none
integer:: bat
    
if ( icore == score ) then
    if ( curr_cyc <= n_inact .or. bat == 0 ) then
    if ( up_sign ) then
    write(*,10), curr_cyc, time2-time1, "sec", entrp0, " | ", "keff", keff, &
                 "//", ngen
    up_sign = .false.
    else
    write(*,11), curr_cyc, time2-time1, "sec", entrp0, " | ", "keff", keff
    end if
    else
        k_eff(bat,curr_cyc) = keff
        write(*,12), curr_cyc, time2-time1, "sec", entrp0, " | ", &
            "keff", keff, &
            "avg", AVG(k_eff(bat,n_inact+1:curr_cyc)), &
            "SD", PCM(STD_M(k_eff(bat,n_inact+1:curr_cyc)))
    end if
    !write(*,13), fetall(:)
    !write(8,13), curr_cyc, entrp0, fetall(:)
end if

10 format(i8,f9.2,1x,a,f10.5,1x,a,1x,a,f9.5,2x,a,i10)
11 format(i8,f9.2,1x,a,f10.5,1x,a,1x,a,f9.5)
12 format(i8,f9.2,1x,a,f10.5,1x,a,1x,2(a,f9.5,3x),a,f9.3)
13 format(I5,10ES15.7)

end subroutine


! =============================================================================
! END_MSG
! =============================================================================
subroutine END_MSG(bat)
    implicit none
    integer:: bat

if ( icore == score ) then
    if ( n_batch > 1 .and. bat == 0 ) then
        write(*,*)
        return
    end if
    write(*,*)
    write(*,*), '   Simulation of Burnup Step Terminated...'
    write(*,10), "    - Elapsed time    : ", &
        time4 - time3, 'sec', (time4-time3)/60, 'min'
    write(*,11), "    - Step Final keff : ", &
        AVG(k_eff(bat,n_inact+1:n_totcyc)), "+/-", &
        PCM(STD_M(k_eff(bat,n_inact+1:n_totcyc)))
    write(*,*)
    
	! (TSOH-IFP)	! TSOH-IFP: PRINT OUT ADJOINT INFORMATION (ALWAYS)
    ! (TSOH-IFP)	write(prt_adjoint,*)
    ! (TSOH-IFP)	write(prt_adjoint,13), '    GENT',AVG(genarr)*1E9,'+/-',STD_M(genarr)*1E9,' scale:1E-9'
    ! (TSOH-IFP)	write(prt_adjoint,22), ' BETASUM',PCM(AVG(betaarr(1:n_act-latent,0))),'+/-',PCM(STD_M(betaarr(1:n_act-latent,0))),' scale:1E-5'
    ! (TSOH-IFP)	write(prt_adjoint,22), 'BETASUMO',PCM(AVG(betad(0,1:n_act))), '+/-', PCM(STD_M(betad(0,1:n_act))), ' scale:1E-5'
    ! (TSOH-IFP)	do i = 1,8
    ! (TSOH-IFP)	    write(prt_adjoint,12), '  BETA',i,PCM(AVG(betaarr(1:n_act-latent,i))),'+/-',PCM(STD_M(betaarr(1:n_act-latent,i))),' scale:1E-5'
    ! (TSOH-IFP)	    write(prt_adjoint,12), 'BETAOG',i,PCM(AVG(betad(i,1:n_act))),'+/-',PCM(STD_M(betad(i,1:n_act))),' scale:1E-5'
    ! (TSOH-IFP)	enddo
	
	!> ADJOINT RELATED (TSOH-IFP) NOW PRINT IN THE LOG FILE
	IF(n_act >= 30) THEN
		write(*,13), '    GENT',AVG(genarr)*1E9,'+/-',STD_M(genarr)*1E9,' scale:1E-9'
		write(*,22), ' BETASUM',PCM(AVG(betaarr(1:n_act-latent,0))),'+/-', PCM(STD_M(betaarr(1:n_act-latent,0))),' scale:1E-5'
		write(*,22), 'BETASUMO',PCM(AVG(betad  (0,1:n_act))),       '+/-', PCM(STD_M(betad  (0,1:n_act))),       ' scale:1E-5'
		do i = 1,8
			write(*,12), '  BETA',i,PCM(AVG(betaarr(1:n_act-latent,i))),'+/-',PCM(STD_M(betaarr(1:n_act-latent,i))),' scale:1E-5'
			write(*,12), 'BETAOG',i,PCM(AVG(betad(i,1:n_act))),'+/-',PCM(STD_M(betad(i,1:n_act))),' scale:1E-5'
		enddo
		write(*,14), '  ALPHA',AVG(alphaarr)*1E-6,'+/-',STD_M(alphaarr)*1E-6,' scale:1E6'		
	!> Insufficient number of active cycles / Only print out the conventional (non-adjoint weighted) values
	ELSE
		write(*,22), 'BETASUMO',PCM(AVG(betad  (0,1:n_act))),  '+/-',PCM(STD_M(betad(0,1:n_act))),' scale:1E-5'
		do i = 1,8
			write(*,12), 'BETAOG',i,PCM(AVG(betad(i,1:n_act))),'+/-',PCM(STD_M(betad(i,1:n_act))),' scale:1E-5'
		enddo
	END IF

    10 format(A,F10.3,A4,F8.2,A4)
    11 format(A,F10.6,A4,F8.3)

    12 format(A,i1,F10.3,A4,F8.5,A) !GROUPWISE BETA
    15 format(A,i1,F10.5,A4,F8.5,A) !GROUPWISE LAMBDA

    22 format(A,F10.3,A4,F8.5,A) !
    13 format(A,F12.3,A4,F10.5,A) !Generation time
    14 format(A,F10.5,A4,F8.5,A) !Rossi-Alpha
end if

end subroutine

subroutine CYCLE_TALLY_MSG(bat)
    use tally, only: MC_tally
    use TH_HEADER, only: th_on, t_fuel, t_bulk
    use FMFD_HEADER, only: p_dep_mc, p_dep_dt, k_real, p_dep_dt_pert
    use MATERIAL_HEADER, only: materials, n_materials
    use PERTURBATION, only: perton
    use COSAMPLING, only: n_pert
    implicit none
    integer, intent(in):: bat
    integer:: cc, mm, nn, rr, ci
    real(8), allocatable:: zavgf(:,:,:,:), zavgp(:,:,:,:)  ! (c,i,j,r)
    integer:: nsum
    real(8):: vsum
    logical:: yes
    real(8), allocatable :: p_mc(:,:,:), s_mc(:,:,:)

    if ( icore /= score ) return
    if ( .not. (fmfdon .or. tallyon)) return

    ! multiplication factor
    if ( fmfdon .and. bat /= 0 ) then
        write(*,*)
        write(*,*), "   DTMC keff"
        do ii = 1, n_inact
            write(*,10), ii, k_fmfd(bat,ii)
        end do
        do ii = n_inact+1, n_totcyc
            if ( ii == n_totcyc ) then
            if ( preco == 1 ) then
                ! predictor
                if ( porc == 1 ) then
                write(*,11), ii, k_fmfd(bat,ii), AVG(k_fmfd(bat,n_inact+1:ii)), &
                        PCM(STD_M(k_fmfd(bat,n_inact+1:ii))), "iDTMC (predictor)"
    
                ! corrector
                elseif ( porc == 2 ) then
                write(*,11), ii, k_fmfd(bat,ii), AVG(k_fmfd(bat,n_inact+1:ii)), &
                        PCM(STD_M(k_fmfd(bat,n_inact+1:ii))), "iDTMC (corrector)"
    
                end if
            else
                write(*,11), ii, k_fmfd(bat,ii), AVG(k_fmfd(bat,n_inact+1:ii)), &
                        PCM(STD_M(k_fmfd(bat,n_inact+1:ii))), "iDTMC"
            end if
            else
            write(*,12), ii, k_fmfd(bat,ii), AVG(k_fmfd(bat,n_inact+1:ii)), &
                        PCM(STD_M(k_fmfd(bat,n_inact+1:ii)))
            end if
        end do
        if(perton) then
            do ii = n_inact+1,n_totcyc
                write(*,'(A,I5,I5,F10.6,F10.2)') 'REAL', istep_burnup, ii-n_inact, &
                    AVG(k_real(bat,ii,1:n_pert)), &
                    PCM(STD_S(k_real(bat,ii,1:n_pert)))
            enddo
            write(*,*)
        endif
    end if

    if ( bat == n_batch ) then
    ! power distribution normalization
        !if ( tallyon ) &
        !    call NORM_DIST(MC_tally(1:n_batch,1:n_act,1,1,:,:,:))
        if ( fmfdon ) &
            call NORM_DIST(p_fmfd(1:n_batch,1:n_act,:,:,:))
    end if

    ! computing time
    !if ( bat == 1 .and. .not. do_burn ) then

    t_MC = t_tot - t_det
    write(*,*)
    write(*,*), "   Computing time"
    do ii = 1, n_totcyc
        write(*,15), ii, AVG(t_MC(1:,ii)), AVG(t_det(1:,ii)), AVG(t_tot(1:,ii))
    end do
    write(*,*)

    ! bunrup dependent pin power distribution
    if ( DO_BURN ) then
    if ( DTMCBU .and. .not. MCBU ) then
        if ( istep_burnup == 0 .or. .not. do_burn) then
        ! find if the file exists
            nsum = 0
            dfile = 'dep_dt0.out'
            do
                inquire(file=trim(dfile),exist=yes)
                if ( yes ) then
                    nsum = nsum + 1
                    if ( nsum < 10 ) then
                        write(dfile,'(a,i1,a)'), 'dep_dt',nsum,'.out'
                    else
                        write(dfile,'(a,i2,a)'), 'dep_dt',nsum,'.out'
                    end if
            
                else
                    exit
                end if
            end do
            ! open a new file
            open(46,file=trim(dfile))
            close(46)
        end if
        ! parameter generation
        do ii = 1, n_act
        ! --- average
            do jj = 1, nfm(1)
                do kk = 1, nfm(2)
                    p_dep_dt(ii,jj,kk,1) = AVG(p_dep_dt(ii,jj,kk,1:nfm(3)))
                    if(.not. perton) cycle
                    do mm = 1,n_pert
                        p_dep_dt_pert(ii,mm,jj,kk,1) = &
                            AVG(p_dep_dt_pert(ii,mm,jj,kk,1:nfm(3)))
                    enddo
                end do
            end do
            ! --- summation
            vsum = 0; nsum = 0
            do jj = 1, nfm(1)
                do kk = 1, nfm(2)
                    if ( isnan(p_dep_dt(ii,jj,kk,1)) ) cycle
                    nsum = nsum + 1
                    vsum = vsum + p_dep_dt(ii,jj,kk,1)
                end do
            end do
            p_dep_dt(ii,:,:,1) = p_dep_dt(ii,:,:,1)*nsum/dble(vsum)
            
            if(perton) then
            vsum = 0; nsum = 0
            do jj = 1, nfm(1)
                do kk = 1, nfm(2)
                    if ( isnan(sum(p_dep_dt_pert(ii,:,jj,kk,1))) ) cycle
                    nsum = nsum + n_act
                    vsum = vsum + sum(p_dep_dt_pert(ii,:,jj,kk,1))
                end do
            end do
            endif
            p_dep_dt_pert(ii,:,:,:,1) = p_dep_dt_pert(ii,:,:,:,1)*nsum/dble(vsum)
        
        end do

        open(46,file=trim(dfile),access='append',status='old')
        do jj = nfm(2), 1, -1
            write(46,1), (AVG(p_dep_dt(1:n_act,ii,jj,1)), ii = 1, nfm(1))
        end do
        write(46,*)
        
        if (perton) then
            write(*,*) 'PERTURBED AVG'
            do jj = nfm(2), 1, -1
                write(46,1), (AVG(p_dep_dt_pert(1,1:n_pert,ii,jj,1)), ii = 1, nfm(1))
            end do
            write(46,*)
            do jj = nfm(2), 1, -1
                write(46,1), (AVG(p_dep_dt_pert(n_act,1:n_pert,ii,jj,1)), ii = 1, nfm(1))
            end do
            write(46,*)
        endif
    
    !    write(46,*), " HERE : SD of pin power"
        write(*,*) 'APPARENT SD'
        do jj = nfm(2), 1, -1
            write(46,1), (STD_M(p_dep_dt(1:n_act,ii,jj,1)) &
                /AVG(p_dep_dt(1:n_act,ii,jj,1)), ii = 1, nfm(1))
        end do
        write(46,*)
        
        if (perton) then
        write(*,*) 'PERTURBED SD'
        do jj = nfm(2), 1, -1
            write(46,1), (STD_S(p_dep_dt_pert(1,1:n_pert,ii,jj,1)) &
                /AVG(p_dep_dt_pert(1,1:n_pert,ii,jj,1)), ii = 1, nfm(1))
        end do
        write(46,*)
        do jj = nfm(2), 1, -1
            write(46,1), (STD_S(p_dep_dt_pert(n_act,1:n_pert,ii,jj,1)) &
                /AVG(p_dep_dt_pert(n_act,1:n_pert,ii,jj,1)), ii = 1, nfm(1))
        end do
        write(46,*)
        endif
        
        close(46)
    
        write(*,*) 'WRITTEN DEP_DT FILE: ', trim(dfile)
        else
            if ( istep_burnup == 0 ) then
                ! find if the file exists
                nsum = 1
                dfile = 'dep_mc1.out'
                do
                inquire(file=trim(dfile),exist=yes)
                if ( yes ) then
                    nsum = nsum + 1
                    if ( nsum < 10 ) then
                        write(dfile,'(a,i1,a)'), 'dep_mc',nsum,'.out'
                    else
                        write(dfile,'(a,i2,a)'), 'dep_mc',nsum,'.out'
                    end if
            
                else
                    exit
                end if
                end do
                ! open a new file
                open(45,file=trim(dfile))
                close(45)
            end if
            ! parameter generation
            do ii = 1, n_act
            ! --- average
                do jj = 1, nfm(1)
                    do kk = 1, nfm(2)
                        p_dep_mc(ii,jj,kk,1) = AVG(p_dep_mc(ii,jj,kk,1:nfm(3)))
                    end do
                end do
            ! --- summation
                vsum = 0; nsum = 0
                do jj = 1, nfm(1)
                    do kk = 1, nfm(2)
                        if ( isnan(p_dep_mc(ii,jj,kk,1)) ) cycle
                        nsum = nsum + 1
                        vsum = vsum + p_dep_mc(ii,jj,kk,1)
                    end do
                end do
                p_dep_mc(ii,:,:,1) = p_dep_mc(ii,:,:,1)*nsum/dble(vsum)
            end do
            print *, 'DFILE?: ', trim(dfile)
            open(45,file=trim(dfile),access='append',status='old')
            !write(45,*), " HERE : pin power", " | step : ", istep_burnup
            do jj = nfm(2), 1, -1
                write(45,1), (p_dep_mc(1,ii,jj,1), ii = 1, nfm(1))
            end do
            
            write(45,*)
        
            do jj = nfm(2), 1, -1
                write(45,1), (STD_M(p_dep_mc(1:n_act,ii,jj,1)) &
                    /AVG(p_dep_mc(1:n_act,ii,jj,1)), ii = 1, nfm(1))
            end do
            write(45,*)

            close(45)
        end if
    elseif(fmfdon)then
        do ii = 1, nfm(3)
            do jj = 1, nfm(2)
                write(*,21), p_fmfd(1,1,:,jj,ii)
            end do
        end do
		
	! (TSOH-IFP): WILL PRODUCE A TXT FILE FOR RECORDING POWER DISTRIBUTION
    elseif (tallyon ) then
		open(9999, file= "MESH_POWER_MC_AVG.out",action="write",status="replace")
		open(99999,file= "MESH_POWER_MC_STD.out",action="write",status="replace")
        allocate(p_mc(nfm(1), nfm(2), nfm(3)))
        allocate(s_mc(nfm(1), nfm(2), nfm(3)))
        do ii = 1, nfm(1)
        do jj = 1, nfm(2)
        do kk = 1, nfm(3)
            p_mc(ii,jj,kk) = AVG  (MC_tally(1,:,1,1,ii,jj,kk)) 
            s_mc(ii,jj,kk) = STD_M(MC_tally(1,:,1,1,ii,jj,kk)) ! SHOULD USE STD_M
        enddo
        enddo
        enddo

        ! write(*,*) 'AVG POWER:'
        ! do kk = 1, nfm(3)
        ! do jj = 1, nfm(2)
        !     write(*, 21), p_mc(:, jj, kk)
        ! enddo
        ! enddo
		! 
        ! write(*,*) 'STD:'
        ! do kk = 1, nfm(3)
        ! do jj = 1, nfm(2)
        !     write(*, 21) s_mc(:, jj, kk)
        ! enddo
        ! enddo
		
		! TSOH-IFP: CHANGE IN THE PRINTING OUT OPTION
		WRITE(*,*), ""
		write(*,*), "   Printing MC power distribution"
		write( 9999,14), p_mc(:,:,:)
		write(99999,14), s_mc(:,:,:)
		close( 9999)
		close(99999)

        deallocate(p_mc)
		DEALLOCATE(s_mc)
    endif

    1 format(1000ES15.7)
    2 format(2I4,1000ES15.7)
    10 format(1X,I5,F10.6)
    11 format(1X,I5,2F10.6,F10.2,2X,A)
    12 format(1X,I5,2F10.6,F10.2,2X)
    16 format(4X,2F10.6,F10.2,2x,a)
    14 format(<nfm(1)>ES15.7)
    15 format(4X,I4,3F12.3)
    21 format(<nfm(1)>es15.7)

end subroutine CYCLE_TALLY_MSG

! =============================================================================
! BATCH_TALLY_MSG
! =============================================================================
subroutine BATCH_TALLY_MSG
    use TALLY, only: n_type, ttally, MC_tally, ttally, MC_tally
    implicit none
    real(8), allocatable:: k_avg(:,:)
    real(8), allocatable:: t_avg(:,:,:,:,:)
    integer:: xx, yy, zz

    if ( icore /= score ) return

    allocate(k_avg(n_batch,n_act))
    allocate(t_avg(n_batch,n_act,nfm(1),nfm(2),nfm(3)))

    ! apparent standard deviatino of the multiplication factor
    write(*,11), '   =========================================='
    write(*,*), "   Apparent standard deviation of the multiplication factor"
    if ( .not. fmfdon ) then
    write(*,*), "   MC"
    do ii = 1, n_batch
    do jj = 1, n_act
        k_avg(ii,jj) = PCM(STD_M(k_eff(ii,n_inact+1:n_inact+jj)))
    end do
    end do
    do ii = 1, n_act
        write(*,10), ii, AVG(k_avg(1:n_batch,ii))
    end do
    write(*,*)
    else
    write(*,*), "   FMFD"
    do ii = 1, n_batch
    do jj = 1, n_act
        k_avg(ii,jj) = PCM(STD_M(k_fmfd(ii,n_inact+1:n_inact+jj)))
    end do
    end do
    do ii = 1, n_act
        write(*,10), ii, AVG(k_avg(1:n_batch,ii))
    end do
    write(*,*)
    end if

    ! real standard deviatino of the multiplication factor
    write(*,11), '   =========================================='
    write(*,*), "   Real standard deviation of the multiplication factor"
    if ( .not. fmfdon ) then
    write(*,*), "   MC"
    do ii = 1, n_batch
    do jj = 1, n_act
        k_avg(ii,jj) = AVG(k_eff(ii,n_inact+1:n_inact+jj))
    end do
    end do
    do ii = 1, n_act
        write(*,10), ii, PCM(STD_S(k_avg(1:n_batch,ii)))
    end do
    write(*,*)
    else
    write(*,*), "   FMFD"
    do ii = 1, n_batch
    do jj = 1, n_act
        k_avg(ii,jj) = AVG(k_fmfd(ii,n_inact+1:n_inact+jj))
    end do
    end do
    do ii = 1, n_act
        write(*,10), ii, PCM(STD_S(k_avg(1:n_batch,ii)))
    end do
    write(*,*)
    end if

    ! apparent standard deviation of the pin-wise information
    write(*,11), '   =========================================='
    write(*,*), "   Apparent standard deviation of the pin-wise information"
    if ( .not. fmfdon ) then
    write(*,*), "   MC"
    do ii = 1, n_batch
    do jj = 1, n_act
        t_avg(ii,jj,1,1,1) = STD_P(MC_tally(ii,1:jj,1,1,:,:,:))
    end do
    end do
    do ii = 1, n_act
        write(*,12), ii, AVG(t_avg(1:n_batch,ii,1,1,1))
    end do
    write(*,*)
    else
    write(*,*), "   FMFD"
    do ii = 1, n_batch
    do jj = 1, n_act
        t_avg(ii,jj,1,1,1) = STD_P(p_fmfd(ii,1:jj,:,:,:))
    end do
    end do
    do ii = 1, n_act
        write(*,12), ii, AVG(t_avg(1:n_batch,ii,1,1,1))
    end do
    write(*,*)
    end if

    ! real standard deviation of the pin-wise information
    write(*,11), '   =========================================='
    write(*,*), "   Real standard deviation of the pin-wise information"
    if ( .not. fmfdon ) then
    write(*,*), "   MC"
    do ii = 1, n_batch
    do jj = 1, n_act
    do xx = 1, nfm(1)
    do yy = 1, nfm(2)
    do zz = 1, nfm(3)
        t_avg(ii,jj,xx,yy,zz) = AVG(MC_tally(ii,1:jj,1,1,xx,yy,zz))
    end do
    end do
    end do
    end do
    end do
    call NORM_DIST(t_avg(1:n_batch,1:n_act,:,:,:))
    do ii = 1, n_act
        write(*,12), ii, STD_PS(t_avg(1:n_batch,ii,:,:,:))
    end do
    write(*,*)
    else
    write(*,*), "   FMFD"
    do ii = 1, n_batch
    do jj = 1, n_act
    do xx = 1, nfm(1)
    do yy = 1, nfm(2)
    do zz = 1, nfm(3)
        t_avg(ii,jj,xx,yy,zz) = AVG(p_fmfd(ii,1:jj,xx,yy,zz))
    end do
    end do
    end do
    end do
    end do
    call NORM_DIST(t_avg(1:n_batch,1:n_act,:,:,:))
    do ii = 1, n_act
        write(*,12), ii, STD_PS(t_avg(1:n_batch,ii,:,:,:))
    end do
    write(*,*)
    end if

    do ii = 1, n_batch
    do jj = 1, n_act
    write(8,1), MC_tally(ii,jj,1,1,:,:,:)
    write(8,*)
    end do
    end do
    do ii = 1, n_batch
    do jj = 1, n_act
    write(8,1), p_fmfd(ii,jj,:,:,:)
    write(8,*)
    end do
    end do
    1 format(51es15.7)

    10 format(4X,I4,F10.2)
    12 format(4X,I4,ES15.7)
    11 format(A)
    15 format(4X,3ES15.7)
    16 format(<nfm(1)>ES15.7)

end subroutine

subroutine HY
    use TALLY, only: MC_tally, MC_stally, MC_scat, n_tgroup, n_type
    use FMFD_HEADER, only: nfm, dfm
    use INPUT_READER, only: directory, filename
    implicit none
    integer:: gg
    integer:: ii, jj
    real(8):: ptemp(nfm(1),nfm(2),nfm(3))

    if ( icore /= score ) return
    filename = trim(directory)//'group_constants.out'

    open(1,file=trim(filename))
    write(1,*), "keff : ", AVG(k_eff(1,n_inact+1:n_totcyc)), "+/-", &
        PCM(STD_M(k_eff(1,n_inact+1:n_totcyc)))

!    do ii = 1, nfm(1)
!    do jj = 1, nfm(2)
!    do kk = 1, nfm(3)
!        ptemp(ii,jj,kk) = AVG(MC_tally(1,:,1,1,ii,jj,kk))
!    end do
!    end do
!    end do
!    write(1,3), ptemp
    do jj = 1, nfm(2)
    do ii = 1, nfm(1)
    do gg = 1, n_tgroup
        write(1,1), ii, jj, dfm(1), dfm(2), &
                    AVG(MC_tally(1,:,1,gg,ii,jj,1)), &
                    AVG(MC_tally(1,:,2,gg,ii,jj,1)), &
                    AVG(MC_tally(1,:,4,gg,ii,jj,1)), mod(dble(gg),2D0), &
                    AVG(MC_tally(1,:,3,gg,ii,jj,1)), &
                    AVG(MC_tally(1,:,5,gg,ii,jj,1)), &
                    AVG(MC_scat(1,:,gg,1,ii,jj,1)), &
                    AVG(MC_scat(1,:,gg,2,ii,jj,1))
    end do
        write(1,2), AVG(MC_tally(1,:,n_type,gg,ii,jj,1))
    do gg = 1, n_tgroup
        write(1,2), AVG(MC_stally(1,:,1,gg,ii,jj,1,2)), &
                    AVG(MC_stally(1,:,1,gg,ii,jj,1,1)), &
                    AVG(MC_stally(1,:,1,gg,ii,jj,1,4)), &
                    AVG(MC_stally(1,:,1,gg,ii,jj,1,3))
        write(1,2), AVG(MC_stally(1,:,2,gg,ii,jj,1,2)), &
                    AVG(MC_stally(1,:,2,gg,ii,jj,1,1)), &
                    AVG(MC_stally(1,:,2,gg,ii,jj,1,4)), &
                    AVG(MC_stally(1,:,2,gg,ii,jj,1,3))
    end do
    end do
    end do
    1 format(2i4,2f7.3,100es15.7)
    2 format(100es15.7)
    3 format(<nfm(1)>ES15.7)
    close(1)

end subroutine

subroutine process_MSR_prec()
    integer :: i,j,k
    real(8), allocatable :: MSR_data(:,:,:,:)
    real(8), allocatable :: MSR_prec(:,:,:,:)

    if(icore /= score) return
    ! if(.not. do_fuel_mv) return

    allocate(MSR_data(8,n_core_axial,n_core_radial,n_act))
    allocate(MSR_prec(8,n_core_axial,n_core_radial,2))

    open(prt_fuel_mv, file=trim(title)//'_MSR_prec',action='read',status='replace')
    do i = 1,n_act
        do j = 1,8
            do k = 1,n_core_radial
            read(prt_fuel_mv,*) MSR_data(j,:,k,i)
            enddo
        enddo
    enddo
    close(prt_fuel_mv)

    open(prt_fuel_mv,file=trim(title)//'_MSR_prec', action='write',status='replace')
    do i = 1,8
        do j = 1,n_core_axial
            do k = 1,n_core_radial
                MSR_prec(i,j,k,1) = avg(MSR_data(i,j,k,:))
                MSR_prec(i,j,k,2) = std_m(MSR_data(i,j,k,:))
            enddo
        enddo
        !write (prt_fuel_mv,'(<N_CORE_AXIAL>e15.6)') MSR_prec(i,:,1)
        !write (prt_fuel_mv,'(<N_CORE_AXIAL>e15.6)') MSR_prec(i,:,2)
    enddo
    do i = 1,n_act
        !print *, 'cycle',i,'1stgroup', MSR_prec(1,1:N_CORE_AXIAL,1,1)
    enddo

    do i = 1,8
        do j = 1,n_core_radial
            write(prt_fuel_mv,'(<N_CORE_AXIAL>e15.6)') MSR_prec(i,1:N_CORE_AXIAL,j,1)
            write(prt_fuel_mv,'(<N_CORE_AXIAL>e15.6)') MSR_prec(i,1:N_CORE_AXIAL,j,2)
        enddo
    enddo
    close(prt_fuel_mv)
    deallocate(MSR_data, MSR_prec)
end subroutine
end program 
