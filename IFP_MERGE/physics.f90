module physics
    use omp_lib
    use variables
    use constants
    use particle_header 
    use XS_header 
    use bank_header
    use randoms
	
    implicit none 
    
    contains
    
    subroutine collision_MG(p)
		implicit none 
        type(Particle), intent(inout) :: p
        real(8) :: sig_tot, rnum, wgt_s, uvw_temp(3)
        integer :: i, i_group, idx_group, n_group, n, bsize
		logical :: delayed
		integer :: pg, ng, nsplit
		real(8) :: temp, beta, lambda_b, speedn, fd
		real(8) :: rn, lambda_d, beta_d, val
		INTEGER :: iMT = 0
		
        p % n_collision = p % n_collision + 1
        p % n_coord = 1
        
		delayed = .false. 
        
        sig_tot = sum(XS_MG(p%material)%sig_scat(p%g,:)) + XS_MG(p%material)%sig_abs(p%g)
        
        !> Collision estimator 
        !$omp atomic
        k_col = k_col + p%wgt*(XS_MG(p%material)%nu(p%g)*XS_MG(p%material)%sig_fis(p%g)/sig_tot)
		
        !> NUMEBR OF BANKS TO BE STORED
        n = int(p%wgt*(XS_MG(p%material)%nu(p%g)*XS_MG(p%material)%sig_fis(p%g)/sig_tot)*(1/keff) + rang())
        
		!> FISSION BANK UPDATED
        if (n > 0) then
			!> DELAYED ?
			if (allocated(MGD)) then 
				if (rang() <= sum(MGD(p%material)%beta(:))) delayed = .true. 
			endif 
			
			!> INCREMENT IN BANK INDEX
			bank_idx                  = bank_idx + 1
			
			!> UPDATE BANK WEIGHT & POSITION 
			thread_bank(bank_idx)%wgt = p % wgt * sum(XS_MG(p%material)%sig_scat(p%g,:))/sig_tot ! THIS WAS MISSING IN THIS VERSION
			thread_bank(bank_idx)%xyz = p%coord(1)%xyz
			thread_bank(bank_idx)%uvw = rand_vec()
			
			! TSOH-IFP: MG CALCULATION ALSO SUPPORTS IFP CALCULATION
			thread_bank(bank_idx)%nlife    = p%trvltime
			thread_bank(bank_idx)%i_Parent = p%i_Parent
			
			if (delayed) then 
				ng = size(MGD(p%material)%beta)
				thread_bank(bank_idx)%delayed 		= .true.
				thread_bank(bank_idx)%time 			= p%time
				thread_bank(bank_idx)%G 			= fission_G(p%material,.true.,iMT);
				thread_bank(bank_idx)%G_delayed     = iMT
				thread_bank(bank_idx)%E 			= real(p%material,8)
				thread_bank(bank_idx)%beta(1:ng)	= MGD(p%material)%beta(:)
				thread_bank(bank_idx)%lambda(1:ng)	= MGD(p%material)%lambda(:)
				! TSOH-IFP
				thread_bank(bank_idx)%dIMT = iMT
				thread_bank(bank_idx)%dlam = MGD(p%material)%lambda(iMT)
			else 
				thread_bank(bank_idx)%G 		= fission_G(p%material,.false.)
				thread_bank(bank_idx)%delayed 	= .false.
				! TSOH-IFP
				thread_bank(bank_idx)%dIMT = 0
				thread_bank(bank_idx)%dlam = 0
			endif 
        endif
        
		! ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
		!> For Dynamic Neutron Source Initialization 
		! ++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
		if (do_DMC .and. allocated(MGD) .and. curr_cyc > n_inact) then 
			ng = size(MGD(p%material)%beta)
			beta = sum(MGD(p%material)%beta(:))
			temp = 0 
			do i = 1, ng 
				temp = temp + MGD(p%material)%beta(i) / MGD(p%material)%lambda(i)
			enddo 
			lambda_b = beta / temp
			!> Neutron Source Sample for Transient Calculation (not fission source) 
			init_idx = init_idx + 1
			thread_bank_init(init_idx)%wgt 			= p%wgt / (MGD(p%material)%vel(p%g)*sig_tot)
			thread_bank_init(init_idx)%xyz 			= p%coord(1)%xyz
			thread_bank_init(init_idx)%uvw 			= p%coord(1)%uvw
			thread_bank_init(init_idx)%delayed 		= .false.
			thread_bank_init(init_idx)%time 		= 0
			thread_bank_init(init_idx)%G 			= p%G
			
			!> Precursor bank add
			temp = p%wgt*(beta/lambda_b)*(XS_MG(p%material)%nu(p%g)*XS_MG(p%material)%sig_fis(p%g)/sig_tot)
			nsplit = int(temp/1.0) + 1 
			do i = 1, nsplit
				prec_idx = prec_idx + 1
				prec_thread(prec_idx)%wgt 			= temp/real(nsplit,8)
				prec_thread(prec_idx)%xyz 			= p%coord(1)%xyz
				prec_thread(prec_idx)%G 			= p%G
				prec_thread(prec_idx)%idx 			= p%material
				prec_thread(prec_idx)%time 			= 0
				prec_thread(prec_idx)%beta(1:ng)	= MGD(p%material)%beta(:)
				prec_thread(prec_idx)%lambda(1:ng)	= MGD(p%material)%lambda(:)
			enddo
		endif

		!> CHANGE IN THE GROUP AFTER COLLISION & PTC WEIGHT
        rnum = rang()
        do i_group = 1, size(XS_MG(p%material)%sig_scat(p%g,:))
            if (rnum < sum(XS_MG(p%material)%sig_scat(p%g,1:i_group))/sum(XS_MG(p%material)%sig_scat(p%g,:))) then 
                idx_group = i_group
                exit
            endif 
        enddo 
        
		!> UPDATE PTC INFO
        p % wgt = p % wgt * sum(XS_MG(p%material)%sig_scat(p%g,:))/sig_tot
        p % g   = idx_group
        p % last_uvw(:) = p % coord(1)% uvw(:)
        p % coord(1)% uvw(:) = rand_vec()
        if (p%wgt < wgt_min) THEN !call Russian_Roulette(p)
            wgt_s = 2*wgt_min
            if ((p%wgt/wgt_s).ge.rang()) then
                p%wgt = wgt_s
            else
                p%alive = .false.
            endif 
        endif 
    end subroutine collision_MG
    
    subroutine collision_MG_DT(p, macro_major)
        type(Particle), intent(inout) :: p
        real(8), intent(in) :: macro_major
        real(8) :: sig_tot, temp, rnum, wgt_s, uvw_temp(3)
        integer :: i, i_group, idx_group, n, bsize, i_source
        p % n_collision = p % n_collision + 1
        p % n_coord = 1
        
        sig_tot = sum(XS_MG(p%material)%sig_scat(p%g,:)) + XS_MG(p%material)%sig_abs(p%g)
        
        !> Collision estimator 
        !$omp atomic
        k_col = k_col + p%wgt*(XS_MG(p%material)%nu(p%g)*XS_MG(p%material)%sig_fis(p%g)/sig_tot)

        
        rnum = rang()
        if (rnum < (XS_MG(p%material)%sig_abs(p%g) - XS_MG(p%material)%sig_fis(p%g)) / sig_tot) then 
            p%wgt   = 0
            p%alive = .false.
            return
            
        elseif (rnum < (XS_MG(p%material)%sig_abs(p%g)) / sig_tot) then 
            !> Fission bank add
            !n = int(p%wgt*(XS_MG(p%material)%nu(p%g)*XS_MG(p%material)%sig_fis(p%g)/sig_tot)*(1/keff) + rang())
            n = int(p%wgt*XS_MG(p%material)%nu(p%g)*(1./keff) + rang())
            do i_source = 1, n
                bank_idx = bank_idx + 1
                thread_bank(bank_idx)%xyz = p%coord(1)%xyz
                thread_bank(bank_idx)%uvw = rand_vec()
                rnum = rang()
                do i_group = 1, size(XS_MG(p%material)%chi(:))
                    if (rnum < sum(XS_MG(p%material)%chi(1:i_group))/sum(XS_MG(p%material)%chi(:))) then 
                        thread_bank(bank_idx)%G = i_group
                        exit
                    endif 
                enddo
            enddo
            p%wgt   = 0
            p%alive = .false.
            return
             
        
        else
            rnum = rang()
            do i_group = 1, size(XS_MG(p%material)%sig_scat(p%g,:))
                if (rnum < sum(XS_MG(p%material)%sig_scat(p%g,1:i_group))/sum(XS_MG(p%material)%sig_scat(p%g,:))) then 
                    idx_group = i_group
                    exit
                endif 
            enddo 
            !p % wgt  = p % wgt * sum(XS_MG(p%material)%sig_scat(p%g,:))/sig_tot
            p % g    = idx_group
            p % coord(1) % uvw(:) = rand_vec()
        endif

    end subroutine

	
	
	

	
	
	
	
	
	function fission_G (i_mat, delayed, G_in) result(G)
		integer, intent(in) :: i_mat
		logical, intent(in) :: delayed
		integer, optional, intent(in) :: G_in
		integer :: G
		integer :: i_group, n, ng, G_prec, i
		real(8) :: rn, rnum, temp, beta
		real(8) :: val0, val1
		
		G = 1;
		rn = rang()
		n = n_group 
		G_prec = -1
		if (delayed) then 
			if (present(G_in)) then 
				G_prec = G_in
			else 
				! sample G_prec
				temp = 0
				beta = sum(MGD(i_mat)%beta(:))
				rnum = rang() 
				ng = size(MGD(i_mat)%beta)
				do i = 1, ng
					temp = temp + MGD(i_mat)%beta(i)
					if (rnum < temp/beta) then 
						G_prec = i
						exit 
					endif
				enddo 
			endif
			
			G = -1; val1 = 0
			val0 = sum(MGD(i_mat)%spectra(G_prec,:))
			do i_group = 1, n
				val1 = val1 + MGD(i_mat)%spectra(G_prec,i_group)
				if (rn < val1/val0) then 
					G = i_group
					exit
				endif 
			enddo
			
		else 
			val1 = 0
			val0 = sum(XS_MG(i_mat)%chi(:))
			do i_group = 1, n
				val1 = val1 + XS_MG(i_mat)%chi(i_group)
				if (rn < val1/val0) then 
					G = i_group
					exit
				endif 
			enddo
		endif 
		if (G < 0) then 
			print *, "fission_G :: group not selected", delayed
			stop
		endif 
		return 
	end function 
	
end module 
