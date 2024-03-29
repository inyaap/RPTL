module input_reader
    use constants
    use geometry_header
    use surface_header
    use variables
    use XS_header
    use material_header
    use tally,    only: TallyCoord, TallyFlux, TallyPower, CoordStruct, tallyon, tally_buf, meshon_tet_vrc
    use ENTROPY,  only: mprupon, bprupon, rampup, crt1, crt2, crt1c, crt2c, &
                        crt3c, crt4c, elength, entrpon
    use FMFD,     only: n_skip, n_acc, fm0, fm1, fm2, nfm, dfm, fcr, fcz, &
                        fmfdon, cmfdon, pfmfdon, pcmfdon
    use FMFD_HEADER,  only: ncm
    use geometry, only: getXYZ, find_cell
    use read_functions
    use depletion_module
    use ace_header
    use ace_module
    use transient
    use tetrahedral,         only: read_msh, num_tet, num_node, tet, node, tet_bc, tet_xyz
    use strings,              only : parse, readline, removesp, uppercase, insertstr, value
    use rgbimage_m
    use VRC,         only : m_pseudo
    use PCQS
    use SIMULATION_HEADER, only: source_read, source_file
	
	use hex_variables, only: dduct, hc_zmin, hc_zmax ! LINKPOINT
    implicit none
    character(80) :: directory, filename
    integer :: curr_line = 0

    contains

! =============================================================================
! INIT_VAR
! =============================================================================
subroutine init_var
    allocate(universes(0:0))
    universes(0)%univ_type = 0
    universes(0)%univ_id   = 0
    universes(0)%xyz(:)    = 0
    universes(0)%ncell     = 0

    keff = 1D0
    avg_power = 0D0
    n_batch = 1
    if ( icore == score ) iscore = .true.

end subroutine

! =============================================================================
! READ_GEOM reads the input about the geometry
! =============================================================================
subroutine read_geom
    
    implicit none
    
    integer :: i, j, k, ix, iy,iz, idx, n, level
    integer :: i_cell, i_univ, i_lat, i_surf 
    integer :: ntemp, itemp, tmpidx
    integer :: ierr
    real(8) :: dtemp, xyz(3)
    character(200) :: line
    character(20) :: option, temp, mat_id, pnum 
    character(1)  :: opt
    character(20) :: title
    character(30) :: filename
    character(100) :: args(100)
    integer :: nargs
	
    logical :: found 

    character(20) :: dupname
    character(5) :: char1, char2
    
    !Read geom.inp
    open(rd_geom, file=trim(trim(directory)//"geom.inp"),action="read", status="old")

    ierr = 0; curr_line = 0 
    do while (ierr.eq.0)
		call readandparse(rd_geom, args, nargs, ierr, curr_line)
		
        if (ierr /= 0) exit
		option = args(1)
        !<================================================================>!
        select case (option)
        case ("title") 
            title = args(2)
            filename = trim(title)//'_keff.out'
            
            inquire(file=filename, exist=found)
            if (found) then
              if (icore == score) open(prt_keff, file=filename, status="old")
            else
              if (icore == score) open(prt_keff, file=filename, status="new")
            end if
            
            !if(do_ifp) then
            !    filename = trim(title)//'_adj.out'
            !    inquire(file=filename, exist=found)
            !    if (found) then
            !      if (icore == score) open(prt_adjoint, file=filename, status="old")
            !    else
            !      if (icore == score) open(prt_adjoint, file=filename, status="new")
            !    end if
            !    if(icore==score) write(prt_adjoint,*) 'BETA   GENTIME'
            !endif
		case ('gmsh')
			read (args(2), '(L)') do_gmsh
			if (do_gmsh) call read_msh()
			! TODO :: 경계조건 입력 필요 (현재는 vacuum)
			
			
        case ("surf")
            isize = 0
            if (allocated(surfaces)) isize = size(surfaces) 
            isize = isize+1
            allocate(surfaces_temp(1:isize))
            if ( isize > 1 ) surfaces_temp(1:isize-1) = surfaces(:) 
            call read_surf(surfaces_temp(isize), args, nargs)
			call EMSG_surf(surfaces_temp(isize)%surf_type, nargs, curr_line)
            if(allocated(surfaces)) deallocate(surfaces)
            call move_alloc(surfaces_temp, surfaces)
            
        case ("cell")
            isize = 0
            if (allocated(cells)) isize = size(cells) 
            isize = isize+1
            allocate(cells_temp(1:isize))
            if (isize > 1) cells_temp(1:isize-1) = cells(:) 
            call read_cell (cells_temp(isize), args, nargs) 
            if(allocated(cells)) deallocate(cells)
            call move_alloc(cells_temp, cells)            
                        
        case ("pin")
            isize = 0
            if (allocated(universes)) isize = size(universes)-1
            isize = isize+1
            allocate(universes_temp(0:isize))
            if (isize > 1) universes_temp(0:isize-1) = universes(:) 
            call read_pin (universes_temp(isize), args, nargs) 
            universes_temp(isize)%xyz(:) = 0
            
            univptr => universes_temp(isize)
            
            allocate(univptr%r(1:univptr%ncell-1))
            allocate(univptr%cell(1:univptr%ncell))
            if(allocated(universes)) deallocate(universes)
            call move_alloc(universes_temp, universes)

            !> generage cell from pin
            if (allocated(cells)) then 
                isize = size(cells) 
                isize = isize + univptr%ncell
                allocate(cells_temp(1:isize))
                if (isize > 1) cells_temp(1:isize-univptr%ncell) = cells(:) 
                deallocate(cells)
            else 
                isize = 0
                isize = isize + univptr%ncell
                allocate(cells_temp(1:isize))
            endif
            
            call move_alloc(cells_temp, cells)
            
            do i = 1, univptr%ncell-1
                j = size(cells)-univptr%ncell+i
                univptr%cell(i) = j
				call readandparse(rd_geom, args, nargs, ierr, curr_line)
				
                read(args(1),*) mat_id
                read(args(2),*) univptr%r(i)
                
                if (E_mode == 0) cells(j)%mat_idx = find_mat_idx(XS_MG,mat_id)
                if (E_mode == 1) cells(j)%mat_idx = find_CE_mat_idx (materials, mat_id)
                if(materials(cells(j)%mat_idx) % duplicable &
                    .and. materials(cells(j)%mat_idx) % depletable) then
                    !if(icore==score)print *, 'DUPL', materials(cells(j)%mat_idx) % geom_count, mat_id, univptr % univ_id
                    tmpidx = cells(j) % mat_idx
                    if(materials(cells(j)%mat_idx) % geom_count > 0) then
                        if(univptr%univ_id<10) then
                            write(char1, '(I1)') univptr%univ_id
                        elseif(univptr%univ_id<100) then
                            write(char1, '(I2)') univptr%univ_id
                        elseif(univptr%univ_id<1000) then
                            write(char1, '(I3)') univptr%univ_id
                        elseif(univptr%univ_id<10000) then
                            write(char1, '(I4)') univptr%univ_id
                        elseif(univptr%univ_id<100000) then
                            write(char1, '(I5)') univptr%univ_id
                        endif

                        if(i<10) then
                            write(char2, '(I1)') i
                        elseif(i<100) then
                            write(char2, '(I2)') i
                        endif
                        !if(icore==score) print *, 'CHCK', char1, char2
                        !write(dupname, '(A,A1,A,A1,A)') adjustl(trim(materials(cells(j)%mat_idx) % mat_name)), '_', adjustl(trim(char1)), '_', adjustl(trim(char2))
                        dupname = adjustl(trim(materials(cells(j)%mat_idx)%mat_name)) //'_' //adjustl(trim(char1)) // '_' // adjustl(trim(char2))
                        if(icore==score) print *, 'DUP ', dupname, materials(cells(j)%mat_idx) % geom_count
                        allocate(materials_temp(n_materials+1))
                        materials_temp(1:n_materials) = materials(:)
                        materials_temp(n_materials+1) = materials(cells(j)%mat_idx)
                        materials_temp(n_materials+1) % mat_name = dupname
                        if(allocated(materials)) deallocate(materials)
                        call move_alloc(materials_temp, materials)
                        n_materials = n_materials + 1
                        cells(j) % mat_idx = n_materials
                    endif
                    materials(tmpidx) % geom_count = &
                        materials(tmpidx) % geom_count + 1
                endif
            enddo
            j = size(cells)
            univptr%cell(i) = j
			call readandparse(rd_geom, args, nargs, ierr, curr_line)
            read(args(1),*) mat_id
            
            if (E_mode == 0) cells(j)%mat_idx = find_mat_idx(XS_MG,mat_id)
            if (E_mode == 1) cells(j)%mat_idx = find_CE_mat_idx (materials, mat_id)
            if(materials(cells(j)%mat_idx) % duplicable &
                .and. materials(cells(j)%mat_idx) % depletable) then
                if(materials(cells(j)%mat_idx) % geom_count > 0) then
                    allocate(materials_temp(n_materials+1))
                    materials_temp(1:n_materials) = materials(:)
                    materials_temp(n_materials+1) = materials(cells(j)%mat_idx)
                    if(allocated(materials)) deallocate(materials)
                    call move_alloc(materials_temp, materials)
                    n_materials = n_materials + 1
                    cells(j) % mat_idx = n_materials
                endif
                materials(cells(j)%mat_idx) % geom_count = &
                    materials(cells(j)%mat_idx) % geom_count + 1
                if(icore==score) print *, 'ADDED', n_materials, cells(j)%mat_idx
            endif
            call gen_cells_from_pin (univptr, cells(j-univptr%ncell+1:j)) 
            
            
            !> generate surface from pin
            if (univptr%ncell > 1) then 
                isize = 0
                if (allocated(surfaces)) isize = size(surfaces) 
                isize = isize + univptr%ncell -1
                allocate(surfaces_temp(1:isize))
                if (isize > 1 .and. allocated(surfaces)) surfaces_temp(1:isize-univptr%ncell+1) = surfaces(:) 
                if(allocated(surfaces)) deallocate(surfaces)
                call move_alloc(surfaces_temp, surfaces)
                j = size(surfaces)
                call gen_surfs_from_pin (univptr, surfaces(j-univptr%ncell+2:j)) 
            endif 
        
        case ("lat")
            isize = 0
            if (allocated(lattices)) isize = size(lattices) 
            isize = isize+1
            allocate(lattices_temp(1:isize))
            if (isize > 1) lattices_temp(1:isize-1) = lattices(:) 
            
            lat_ptr => lattices_temp(isize)
            call read_lat(lat_ptr, args, nargs) 
            allocate(lat_ptr%lat(1:lat_ptr%n_xyz(1),1:lat_ptr%n_xyz(2),1:lat_ptr%n_xyz(3))) 
            
			!do iz = 1, lat_ptr%n_xyz(3)
			!	do iy = 1, lat_ptr%n_xyz(2)
			!		call readandparse(rd_geom, args, nargs, ierr, curr_line)
			!		if (nargs /= lat_ptr%n_xyz(1)) then
			!			write (*,'(a,i3,a)') "geom.inp (Line ",curr_line ,") Wrong lattice element number"
			!			stop
			!		endif
			!		do ix = 1, lat_ptr%n_xyz(1)
			!			read (args(ix), *) lat_ptr%lat(ix,iy,iz)
			!		enddo 
			!	enddo 
			!enddo 
			
			do iy = 1, lat_ptr%n_xyz(2)
				call readandparse(rd_geom, args, nargs, ierr, curr_line)
				if (nargs /= lat_ptr%n_xyz(1)) then
					write (*,'(a,i3,a)') "geom.inp (Line ",curr_line ,") Wrong lattice element number"
					stop
				endif
				do ix = 1, lat_ptr%n_xyz(1)
				  do iz = 1, lat_ptr%n_xyz(3)
					read (args(ix), *) lat_ptr%lat(ix,iy,iz)
				  enddo 
				enddo 
			enddo 
			
			
            if(allocated(lattices)) deallocate(lattices)
            call move_alloc(lattices_temp, lattices)    
            
            
            
        case ('bc') 
            !if (do_gmsh) then 
			!	read (args(2), '(I)') tet_bc

			!else
				call read_bc (surfaces, args, nargs)
            !endif 
            
        case ('sgrid') 
            allocate(sgrid(1:6))
            call read_sgrid (args, nargs)
		
        case default 
            print *, 'NO SUCH OPTION ::', option 
            stop
        end select
        
    enddo
    
    
    ! ===================================================================================== !
    !> add pure universes from cells(:)
    do i = 1, size(cells)
        !> if univ_id = 0 then add to base universe / else add to the tail
        if (cells(i)%univ_id == 0 ) then 
            universes(0)%ncell = universes(0)%ncell+1
        else
            found = .false.
            do j = 1, size(universes(1:))
                if (universes(j)%univ_id == cells(i)%univ_id) then 
                    found = .true.
                    idx = j
                    exit 
                endif
            enddo 
            if ( .not. found ) then 
                isize = size(universes(1:))
                allocate(universes_temp(0:isize+1))
                do j = 1, isize 
                    universes_temp(j) = universes(j)
                enddo
                obj_univ%univ_type = 0
                obj_univ%univ_id   = cells(i)%univ_id
                obj_univ%xyz(:)    = 0 
                obj_univ%ncell     = 1
                universes_temp(isize+1) = obj_univ
                call move_alloc(universes_temp, universes)
            elseif (.not. allocated(universes(idx)%r)) then 
                universes(idx)%ncell = universes(idx)%ncell+1
            endif
        endif
    enddo         
    
    
    !> 3. Update surface info to subpin cells 
    do i = 1, size(cells)
        read(cells(i)%cell_id,*) temp
        if (temp(1:1) == 'p') then                  !> sub_pin cell 
            !read(temp(2:2),'(I)') itemp
            !read(temp(4:4),'(I)') j
			call OptionAndNumber(temp, 1, opt, itemp, pnum) 
			call OptionAndNumber(temp, 2, opt, j) 
			
            
            do i_univ = 0, size(universes) 
                if (itemp == universes(i_univ)%univ_id) exit
            enddo 
            
            !print *, i_univ, universes(i_univ)%univ_id , universes(1)%ncell
            if (universes(i_univ)%ncell > 1) then
              if (j == 1)then 
                  allocate(cells(i)%neg_surf_idx(1))
                  allocate(cells(i)%pos_surf_idx(0))
                  cells(i)%neg_surf_idx(1) = find_surf_idx(surfaces,trim(pnum)//'s1')
              elseif (j == universes(i_univ)%ncell) then
                  allocate(cells(i)%neg_surf_idx(0))
                  allocate(cells(i)%pos_surf_idx(1))
                  write(line,*) j-1
                  cells(i)%pos_surf_idx(1) = find_surf_idx(surfaces,trim(pnum)//'s'//adjustl(line))
              else 
                  allocate(cells(i)%pos_surf_idx(1))
                  write(line,*) j-1
                  !print *, 'check1'
                  cells(i)%pos_surf_idx(1) = find_surf_idx(surfaces,trim(pnum)//'s'//adjustl(line))
                  allocate(cells(i)%neg_surf_idx(1))
                  write(line,*) j
                  cells(i)%neg_surf_idx(1) = find_surf_idx(surfaces,trim(pnum)//'s'//adjustl(line))
                  !print *, 'check2'
              endif
            endif
            cells(i)%operand_flag = 1
            
        else                                         !> ordinary cell
            ix=0; iy=0;
            cells(i)%nsurf = size(cells(i)%list_of_surface_IDs)
            do j = 1, cells(i)%nsurf
				temp = cells(i)%list_of_surface_IDs(j)
                if (temp(1:1) == '-' ) then 
					ix = ix+1
                else 
					iy = iy+1
				endif
            enddo 
            allocate(cells(i)%neg_surf_idx(ix))
            allocate(cells(i)%pos_surf_idx(iy))
            ix=1; iy=1;
            do j = 1, cells(i)%nsurf
				temp = cells(i)%list_of_surface_IDs(j)
                if (temp(1:1) == '-' ) then 
					write(line, *) temp(2:)
                    cells(i)%neg_surf_idx(ix) = find_surf_idx(surfaces,adjustl(line))
                    ix = ix+1
                else 
					write(line, *) temp
                    cells(i)%pos_surf_idx(iy) = find_surf_idx(surfaces,adjustl(line))
                    iy = iy+1
				endif
                
            enddo 
            
            !> cell translation
            if (cells(i)%nsurf == 1) then 
				temp = cells(i)%list_of_surface_IDs(1)
                write(line,*) temp(scan(temp,'-')+1:)
                idx = find_surf_idx(surfaces,adjustl(line))
                !if (surfaces(idx)%surf_type == sqcx) 
                !if (surfaces(idx)%surf_type == sqcy)
                if (surfaces(idx)%surf_type == sqcz) then 
                    allocate(cells(i)%translation(3))
                    cells(i)%translation(1) = surfaces(idx)%parmtrs(1)
                    cells(i)%translation(2) = surfaces(idx)%parmtrs(2)
                    cells(i)%translation(3) = 0
                endif
                !if (surfaces(idx)%surf_type == cylx)
                !if (surfaces(idx)%surf_type == cyly)
                if (surfaces(idx)%surf_type == cylz) then 
                    allocate(cells(i)%translation(3))
                    cells(i)%translation(1) = surfaces(idx)%parmtrs(1)
                    cells(i)%translation(2) = surfaces(idx)%parmtrs(2)
                    cells(i)%translation(3) = 0
                endif
                if (surfaces(idx)%surf_type == sph) then 
                    allocate(cells(i)%translation(3))
                    cells(i)%translation(1) = surfaces(idx)%parmtrs(1)
                    cells(i)%translation(2) = surfaces(idx)%parmtrs(2)
                    cells(i)%translation(3) = surfaces(idx)%parmtrs(3)
                endif
                
            endif
        endif 
    enddo 
    
    !> 4. Add cells to pin universe
    !> Add the cells to the universe cell list   
    do i = 0, size(universes(1:))
        idx = 1
        if (.not.allocated(universes(i)%cell)) allocate(universes(i)%cell(universes(i)%ncell))
        do k = 1, size(cells)
            if (cells(k)%univ_id == universes(i)%univ_id) then 
                universes(i)%cell(idx) = k
                idx = idx+1
            endif 
        enddo 
    enddo
	
    !> 5. Change lattice universe name to universe index
    do i = 1, size(lattices) 
        do ix = 1, lattices(i)%n_xyz(1)
            do iy = 1, lattices(i)%n_xyz(2)
                do iz = 1, lattices(i)%n_xyz(3)
                    itemp = find_univ_idx(universes,lattices(i)%lat(ix,iy,iz) )
                    lattices(i)%lat(ix,iy,iz) = itemp 
                enddo 
            enddo 
        enddo 
    enddo 
    
    
    do i = 1, size(cells) 
        associate(this => cells(i))
            if (this%fill < 0) then 
                this%filltype = FILL_MATERIAL
            elseif (in_the_list_univ(universes, this%fill)) then 
                this%filltype = FILL_UNIVERSE
            elseif (in_the_list_lat(lattices, this%fill)) then
                this%filltype = FILL_LATTICE
            else 
                print *, 'ERROR : WRONG SHIT FILLING THIS CELL', cells(i)%cell_id
                stop
            endif
        end associate
    enddo 
    
	
	!> Set transient surface movement 
	if (geom_change) then 
		do i = 1, n_interval 
			purterb(i)%idx1 = find_surf_idx(surfaces, move_surf(i))
		enddo 
	endif 
	
    
    
    !> CHECK THE INPUT READ RESULT
    !call check_input_result(universes,lattices, cells,surfaces)
            
    !> READ DONE
    close(rd_geom)
    if(icore==score) print '(A25)', '    GEOM  READ COMPLETE...' 
    
end subroutine

! =============================================================================
! READ_PIN processes the input for the pin geometry
! =============================================================================
subroutine read_pin (Pinobj, args, nargs)
    type(universe) :: Pinobj
    character(*) :: args(:)
    integer :: nargs

    if (nargs < 3) then
        write (*,'(a,i7,a)') "geom.inp (Line ",curr_line ,") Wrong pin object parameter(s)"
        stop
    endif

    read(args(2), *) Pinobj%univ_id
    read(args(3), *) Pinobj%ncell


end subroutine

! =============================================================================
! READ_CELL processes the input for the cell geometry
! =============================================================================
subroutine read_cell (Cellobj, args, nargs)
    class(Cell) :: Cellobj
    character(*) :: args(:)
    integer :: nargs
    character(50):: temp, option, flag, mat_id
    integer :: i, nsurf, n



    read(args(2), *) Cellobj%cell_id
    read(args(3), *) Cellobj%univ_id
    if (trim(uppercase(args(4))) == 'FILL') then
        Cellobj%mat_idx = -1
        read(args(5), *) Cellobj%fill
        n = 6
    elseif (trim(uppercase(args(4))) == 'OUTSIDE') then
        Cellobj%mat_idx = 0
        Cellobj%fill = -1
        n = 5
    else
        read(args(4), *) mat_id
        if (E_mode == 0) Cellobj%mat_idx = find_mat_idx(XS_MG,mat_id)
        if (E_mode == 1) Cellobj%mat_idx = find_CE_mat_idx (materials, mat_id)
        Cellobj%fill = -1
        n = 5
    endif

    ! operand flag
    if (trim(args(n)) == '&' ) then
        Cellobj%operand_flag = 1
    elseif (trim(args(n)) == '|') then
        Cellobj%operand_flag = -1
    else ! default is '&' operator
        Cellobj%operand_flag = 1
        n = 4

        !write (*,'(a,i3,a)') "geom.inp (Line ",curr_line ,") Requires Operand for Cell-Surface Definition"
        !stop
    endif

    nsurf = nargs-n
    allocate(Cellobj%list_of_surface_IDs(nsurf))

    do i = 1, nsurf
        read(args(i+n),*) Cellobj%list_of_surface_IDs(i)
    enddo


end subroutine

! =============================================================================
! READ_SGRID
! =============================================================================
subroutine read_sgrid (args, nargs)
    character(*) :: args(:)
    integer :: nargs
    integer :: i

    if (nargs /= 7) then
        write (*,'(a,i7,a)') "geom.inp (Line ",curr_line ,") Wrong sgrid parameter(s)"
        stop
    endif
    do i = 1, 6
        read(args(i+1),*) sgrid(i)
    enddo
end subroutine


! =============================================================================
! READ_BC
! =============================================================================

subroutine read_bc (surflist, args, nargs)
    type(Surface) :: surflist(:)
    character(*) :: args(:)
    integer :: nargs
    character(30):: temp, option, surf_id
    integer :: i, j, k, idx

    if (nargs /= 3) then
        write (*,'(a,i7,a)') "geom.inp (Line ",curr_line ,") Wrong BC parameter(s)"
        stop
    endif
    read(args(2), *) surf_id
    idx = find_surf_idx(surflist, surf_id)
    read(args(3), *) surflist(idx)%bc


end subroutine

! =============================================================================
! READ_LAT
! =============================================================================
subroutine read_lat (Latobj, args, nargs)
    type(lattice) :: Latobj
    character(*) :: args(:)
    integer :: nargs
    integer :: i

    if (nargs /= 12) then
        write (*,'(a,i7,a)') "geom.inp (Line ",curr_line ,") Wrong lattice parameters"
        stop
    endif


    read(args( 2), *) Latobj%lat_id
    read(args( 3), *) Latobj%lat_type
    read(args( 4), *) Latobj%xyz(1)
    read(args( 5), *) Latobj%xyz(2)
    read(args( 6), *) Latobj%xyz(3)
    read(args( 7), *) Latobj%n_xyz(1)
    read(args( 8), *) Latobj%n_xyz(2)
    read(args( 9), *) Latobj%n_xyz(3)
    read(args(10), *) Latobj%pitch(1)
    read(args(11), *) Latobj%pitch(2)
    read(args(12), *) Latobj%pitch(3)

    ! starting coordinates
    do i = 1, 3
    if ( mod(Latobj%n_xyz(i),2) == 0 ) then
    Latobj%xyz0(i) = Latobj%xyz(i) - Latobj%pitch(i) * Latobj%n_xyz(i)/2
    else
    Latobj%xyz0(i) = Latobj%xyz(i) - Latobj%pitch(i) * (Latobj%n_xyz(i)/2+5D-1)
    end if
    end do

end subroutine

subroutine gen_cells_from_pin (Pinobj, cellobj)
    type(universe) :: Pinobj
    type(cell):: cellobj(:)
    integer :: i
    character(10) :: num, pin_id

    do i = 1, size(cellobj)
        write(num, '(I10)') i
        write(pin_id, '(I10)') pinobj%univ_id

        cellobj(i)%cell_id     = 'p'//trim(adjustl(pin_id))//'c'//trim(adjustl(num))
        cellobj(i)%idx         = 0
        cellobj(i)%univ_id     = pinobj%univ_id
        cellobj(i)%nsurf     = 2

        cellobj(i)%fill = -1
        !cellobj(i)%list_of_surface_indices(:) =             !> TO BE EDITED


    enddo

end subroutine

subroutine gen_surfs_from_pin(Pinobj, surfobj)
    type(universe) :: Pinobj
    type(surface):: surfobj(:)
    integer :: i
    character(10) :: num, pin_id


    do i = 1, size(surfobj)
        write(num, '(I10)') i
        write(pin_id, '(I10)') pinobj%univ_id

        surfobj(i)%surf_id         = 'p'//trim(adjustl(pin_id))//'s'//trim(adjustl(num))
        surfobj(i)%surf_type     = cylz
        surfobj(i)%bc             = 0
        surfobj(i)%parmtrs(1)     = 0
        surfobj(i)%parmtrs(2)     = 0
        surfobj(i)%parmtrs(3)     = pinobj%r(i)
    enddo
end subroutine

subroutine read_MG_XS
    implicit none
    integer :: i, j, i_mat, n_mat,i_group, j_group, ierr
    character(50) :: mat_id, line, option

    filename = trim(directory)//'MG_XS.inp'

    open(rd_xs, file=trim(filename),action="read", status="old")
    ierr = 0; n_mat = 0
    !allocate(XS_MG(1)); allocate(XS_MG_temp(1));
    do while (ierr.eq.0)
        read (rd_xs, FMT='(A)', iostat=ierr) line
        if ((len_trim(line)==0).or.(scan(line,"%"))/=0) cycle

        j = 0;
        do while (j.le.len(line))
            j = j+1
            if (line(j:j).eq.' ') exit
            option = line(1:j)
        enddo


        select case (option)
        case('group')
            read(line(j+1:),*) n_group

        case('mat')

            n_mat = n_mat+1
            read(line(j+1:),*) mat_id

            allocate(XS_MG_temp(n_mat))
            if (n_mat > 1) XS_MG_temp(1:n_mat-1) = XS_MG(:)


            XS_MG_ptr => XS_MG_temp(n_mat)
            allocate(XS_MG_ptr%sig_tr(n_group))
            allocate(XS_MG_ptr%sig_abs(n_group))
            allocate(XS_MG_ptr%sig_cap(n_group))
            allocate(XS_MG_ptr%sig_fis(n_group))
            allocate(XS_MG_ptr%nu(n_group))
            allocate(XS_MG_ptr%chi(n_group))
            allocate(XS_MG_ptr%sig_scat(n_group,n_group))

            XS_MG_temp(n_mat)%mat_id = mat_id

            read(rd_xs, *) (XS_MG_temp(n_mat)%sig_tr(i_group), i_group = 1, n_group)
            read(rd_xs, *) (XS_MG_temp(n_mat)%sig_abs(i_group), i_group = 1, n_group)
            read(rd_xs, *) (XS_MG_temp(n_mat)%sig_cap(i_group), i_group = 1, n_group)
            read(rd_xs, *) (XS_MG_temp(n_mat)%sig_fis(i_group), i_group = 1, n_group)
            read(rd_xs, *) (XS_MG_temp(n_mat)%nu(i_group), i_group = 1, n_group)
            read(rd_xs, *) (XS_MG_temp(n_mat)%chi(i_group), i_group = 1, n_group)
            do j_group = 1, n_group
                read(rd_xs, *) (XS_MG_temp(n_mat)%sig_scat(j_group,i_group), i_group = 1, n_group)
            enddo
            if(allocated(XS_MG)) deallocate(XS_MG)
            call move_alloc(XS_MG_temp, XS_MG)



            ! Adjust nu value to match steady state in MG mode
            XS_MG(n_mat)%nu (:) = XS_MG(n_mat)%nu(:) / k_steady


            ! read transient parameters
            if (npg>0) then
                allocate(MGD_temp(n_mat))
                if (n_mat > 1) MGD_temp(1:n_mat-1) = MGD(:)
                allocate(MGD_temp(n_mat)%beta(1:npg))
                allocate(MGD_temp(n_mat)%lambda(1:npg))
                allocate(MGD_temp(n_mat)%vel(1:n_group))
                allocate(MGD_temp(n_mat)%spectra(1:npg,1:n_group))

                MGD_temp(n_mat)%beta(:)     = 0
                MGD_temp(n_mat)%lambda(:)   = 0
                MGD_temp(n_mat)%vel(:)      = 0
                MGD_temp(n_mat)%spectra(:,:) = 0

                read(rd_xs, *) (MGD_temp(n_mat)%beta(i_group), i_group = 1, npg)
                read(rd_xs, *) (MGD_temp(n_mat)%lambda(i_group), i_group = 1, npg)
                do j_group = 1, n_group
                    read(rd_xs, *) (MGD_temp(n_mat)%spectra(i_group,j_group), i_group = 1, npg)
                enddo
                read(rd_xs, *) (MGD_temp(n_mat)%vel(i_group), i_group = 1, n_group)
                if(allocated(MGD)) deallocate(MGD)
                call move_alloc(MGD_temp, MGD)
            endif



        case default
            print *, 'WRONG OPTION :: MG_XS.inp'
            STOP

        end select

    enddo

    close(rd_xs)

    !> READ DONE
    if(icore==score) print '(A25)', '    XS    READ COMPLETE...'
end subroutine


! =============================================================================
! READ_CTRL reads the input for the calculation control
! =============================================================================
subroutine READ_CTRL
    implicit none
    logical :: file_exists
    integer :: Open_Error, File_Error
    character(4) :: Card
    character:: Card_Type
    integer:: no_of_arg

    no_of_arg = IARGC()
    if ( no_of_arg == 0 ) then
    directory = "./inputfile/"
    else
    call GETARG(1,directory)
    directory = "./inputfile/"//trim(directory)//'/'
    end if

    filename = trim(directory)//'ctrl.inp'

    file_exists = .false.
    inquire(file=trim(filename),exist=file_exists)
    if(file_exists==.false.) then
      print *, "FATAL ERROR :: NO CTRL.INP FILE "
      stop
    end if

    open(unit=rd_ctrl,file=trim(filename),action='read',iostat=Open_Error)
    Read_File : do
        read(rd_ctrl,*,iostat=File_Error) Card
        if (File_Error/=0) exit Read_File
        if (Card=="CARD" .or. Compare_String(Card,"card")) then
            backspace(rd_ctrl)
            read(rd_ctrl,*,iostat=File_Error) Card,Card_Type
            call Small_to_Capital(Card_Type)
            if (icore==score) print *, "ctrl.inp :: CARD ", Card_Type," is being read..."
            call Read_Card(rd_ctrl,Card_Type)
        end if
    end do Read_File
    close(rd_ctrl)


    if ( icore == score ) print '(A25)', '    CTRL  READ COMPLETE...'

end subroutine READ_CTRL

! =============================================================================
! Read_Card reads the type of input card
! =============================================================================
    subroutine Read_Card(File_Number,Card_Type)
        use ENTROPY, only: en0, en1, nen, shannon, shannon_
        use TH_HEADER, only: th_on, th0, th1, th2, nth, dth, rr0, rr1, p_th, mth
        use FMFD_HEADER
        use TALLY, only: n_type, ttally, meshon, tgroup, n_tgroup, tcycle, n_tcycle
        use PERTURBATION, only: perton
        implicit none
        integer :: i, j
        integer,intent(in)::File_Number
        character(*),intent(inout)::Card_Type
        integer::File_Error
        character(30):: Char_Temp
        character(80):: line, lib1,lib2
        character(1)::Equal
        integer :: nm0, nm1 ! number of materials
        logical :: switch
        character(4):: mtype
        integer, allocatable:: tally_temp(:)
        integer, allocatable:: zztemp(:)
        real(8), allocatable:: numden(:)
        real(8):: sum_den
        character(100):: args(100)
        integer:: nargs, n_univ, univid
        integer:: ierr, curr_line
        character(20):: surf_id
        ! sorting isotopes for predictor-corrector
        integer:: idx_temp, comp, mini
        real(8):: den_temp
        integer, allocatable:: mid(:)

        File_Error=0
        select case(Card_Type)
        case('A')
            Read_Card_A : do
                if(File_Error/=0) call Card_Error(Card_Type,Char_Temp)
                read(File_Number,*,iostat=File_Error) Char_Temp
                Call Small_to_Capital(Char_Temp)
                Card_A_Inp : select case(Char_Temp)
            case("ENERGY_MODE")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, E_mode
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
            case("NOMINAL_POWER")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, Nominal_Power
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
            case("NUGRID")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, nugrid
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
            case("HISTORY_PER_CYCLE")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, ngen
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
            case("NUMBER_INACTIVE")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, n_inact
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
            case("NUMBER_ACTIVE")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, n_act
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                n_totcyc = n_act + n_inact
                allocate(kprt(n_totcyc))
            case("BATCH")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, n_batch
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
            case("BATCH_INACTIVE")
                if ( n_batch == 1 ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, b_inact
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                t_inact  = n_inact
                t_totcyc = n_totcyc
                n_inact  = b_inact
                n_totcyc = n_inact

            case("FAKE_MC")
                backspace(File_Number)
                read(file_number,*,iostat=file_error) char_temp, equal, fake_mc
                if(equal/="=") call card_error(card_type,char_temp)
                fmfdon = .true.
                n_fake = n_inact
                if ( fake_mc .and. icore == score ) then
                    print*, "   no. of fake cycles     = ", n_fake
                    print*, "   no. of inactive cycles = ", n_inact
                end if
            case("FAKE_INACTIVE")
                if ( .not. fake_MC ) cycle
                backspace(File_Number)
                read(file_number,*,iostat=file_error) char_temp, equal, n_fake
                if(equal/="=") call card_error(card_type,char_temp)
                if ( fake_mc .and. icore == score ) &
                    print*, "   no. of new fake cycles = ", n_fake
            case("DBRC")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, switch
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
            case("DBRC_E_MIN")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, DBRC_E_MIN
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
            case("DBRC_E_MAX")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, DBRC_E_MAX
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
            case("N_ISO0K")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, n_iso0K
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                allocate(ace0K(n_iso0K))
            case("DBRC_LIB")
                backspace(File_Number)
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, ace0K(1)%library
                do i = 2, n_iso0K
                    read(File_Number,*,iostat=File_Error) ace0K(i)%library
                enddo

            case("ENTROPY")
                entrpon = .true.
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, en0, en1, nen
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
            case("PRUP")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, bprupon
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
                crt1c = 1
                crt2c = 1D0
                crt3c = 1D-1
                crt4c = 100
            case("IGEN")
                if ( .not. bprupon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, ngen
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
                if ( bprupon ) call PRUP_INITIAL
            case("DGEN")
                if ( .not. bprupon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, rampup
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
            case("CRT1")
                if ( .not. bprupon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, crt1c
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
            case("CRT2")
                if ( .not. bprupon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, crt2c
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
            case("CRT3")
                if ( .not. bprupon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, crt3c
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
            case("CRT4")
                if ( .not. bprupon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, crt4c
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
            case("EACC")
                if ( .not. bprupon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, elength
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
                deallocate(shannon)
                allocate(shannon(2*elength))

            case("FMFD")
                if ( fake_MC ) then
                fmfdon = .true.
                else
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, fmfdon
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
                end if
                if ( fmfdon ) call FMFD_INITIAL
            case("PFMFD")
                if ( .not. fmfdon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, pfmfdon
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
            case("FMFD_ACC")
                if ( .not. fmfdon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, n_acc
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)

                if ( iscore ) then
                    if ( n_acc < n_act ) &
                            print*, "WARNING: FMFD_ACC is not long enough"
                    if ( n_acc > n_totcyc ) n_acc = n_totcyc
                    if ( n_acc == 0 ) n_acc = n_totcyc
                end if
            case("FMFD_SKIP")
                if ( .not. fmfdon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, n_skip
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
            case("ACC_SKIP")
                if ( .not. fmfdon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, acc_skip
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
            case("ONE_CMFD")
                if ( .not. fmfdon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, fcr, fcz
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
                ncm(1:2) = nfm(1:2) / fcr
                ncm(3)   = nfm(3)   / fcz
                call FMFD_ERR1
                cmfdon = .true.
                fc1 = fcr*fcz
                fc2 = fcr*fcr
                n_lnodes = fc2*fcz
                dcm(1) = dfm(1)*fcr
                dcm(2) = dfm(2)*fcr
                dcm(3) = dfm(3)*fcz
            case("ONE_PCMFD")
                if ( .not. fmfdon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, fcr, fcz
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
                            ncm(1:2) = nfm(1:2) / fcr
                ncm(3)   = nfm(3)   / fcz
                call FMFD_ERR1
                cmfdon = .true.
                pcmfdon = .true.
                fc1 = fcr*fcz
                fc2 = fcr*fcr
                n_lnodes = fc2*fcz
                dcm(1) = dfm(1)*fcr
                dcm(2) = dfm(2)*fcr
                dcm(3) = dfm(3)*fcz
            case("ZIGZAG")
                if ( .not. fmfdon ) cycle
                zigzagon = .true.
                n_zz = 0
                do
                n_zz = n_zz + 1
                allocate(zztemp(n_zz))
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, zztemp(1:n_zz)
                deallocate(zztemp)
                if ( File_Error /= 0 ) then
                    n_zz = n_zz - 1
                    allocate(zztemp(n_zz))
                    rewind(File_Number)
                    do
                    read(File_Number,*,iostat=File_Error) Char_Temp
                    Call Small_to_Capital(Char_Temp)
                    if ( Char_Temp == 'ZIGZAG' ) exit
                    end do
                    backspace(File_Number)
                    read(File_Number,*,iostat=File_Error) Char_Temp, Equal, zztemp(1:n_zz)
                    if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                    exit
                end if
                end do
                call ZIGZAG_INDEX(zztemp)
				
			case("D_DUCT") ! LINKPOINT
			    if ( .not. fmfdon ) cycle
				backspace(File_Number)
				read(File_Number, *, iostat = File_Error) Char_Temp, Equal, dduct ! dduct being positive sets grid to hex, negative to square
				if ( Equal /= "=" ) call Card_Error (Card_Type, Char_Temp)
			case("HEX_DFM") ! LINKPOINT
			    if ( .not. fmfdon ) cycle
				backspace(File_Number)
				read(File_Number, *, iostat = File_Error) Char_Temp, Equal, dfm(:)
				if ( Equal /= "=" ) call Card_Error (Card_Type, Char_Temp)
			case("HEX_FMFD") ! LINKPOINT --> call this to do FMFD
                if ( .not. fmfdon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, fcr, fcz, ncm(:)
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
				n_lnodes = fcr * fcr * fcz
                dcm(1) = sqrt(3.0 / 4.0) * dfm(1) * fcr + 2.0 * dduct
                dcm(2) = sqrt(3.0 / 4.0) * dfm(2) * fcr + 2.0 * dduct
                dcm(3) = dfm(3)*fcz
			case("HEX_ZMIN") ! LINKPOINT
			    if (.not. fmfdon) cycle
				zigzagon = .true.
				allocate(hc_zmin(ncm(2)))
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, hc_zmin(:)
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
			case("HEX_ZMAX") ! LINKPOINT
			    if (.not. fmfdon) cycle
				allocate(hc_zmax(ncm(2)))
				backspace(File_Number)
				read(File_Number, *, iostat=File_Error) Char_Temp, Equal, hc_zmax(:)
				if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
			case("HEX_GRID") ! LINKPOINT
			    if (.not. fmfdon) cycle
				meshon = .true.
				backspace(File_Number)
				read(File_Number, *, iostat=File_Error) Char_Temp, Equal, fm0(:) ! take grid centre
				if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
				! calculate centre of (0,0) CM grid cell
				fm0(1) = fm0(1) - sqrt(3.0/4.0) * ((ncm(1) + 1) / 2) * dcm(1)
				fm0(2) = fm0(2) - (3.0/2.0) * ((ncm(2) + 1) / 2) * dcm(2)
				fm0(3) = fm0(3) - ((ncm(3) + 1) / 2) * dcm(3)
			case("HEX_PCMFD") ! LINKPOINT
                if ( .not. fmfdon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, pcmfdon
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
				inactive_cmfd = .true.
                cmfdon = .true.
            case("FMFD_TO_MC")
                if ( .not. fmfdon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, fmfd2mc
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
            case("DUAL_FMFD")
                if ( .not. fmfdon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, dual_fmfd
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)

                if ( mprupon ) then
                    allocate(shannon_(elength))
                    shannon_ = 0
                end if
            case("QUARTER_CORE")
                if ( .not. fmfdon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, quarter
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
            case("INACTIVE_CMFD")
                if ( .not. fmfdon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, inactive_cmfd
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
                ncm(1:2) = nfm(1:2) / fcr
                ncm(3)   = nfm(3)   / fcz
                call FMFD_ERR1
                inactive_cmfd = .true.
                cmfdon = .true.
                pcmfdon = .true.
                fc1 = fcr*fcz
                fc2 = fcr*fcr
                n_lnodes = fc2*fcz
                dcm(1) = dfm(1)*fcr
                dcm(2) = dfm(2)*fcr
                dcm(3) = dfm(3)*fcz
            case("K_PERTURB")
                if ( .not. fmfdon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, perton
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)

            case("TH")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, th_on
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
            case("TH_GRID")
                if ( .not. th_on ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, th0, th1, nth
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
                th2 = th1 - th0
                dth = th2 / dble(nth)
            case("TH_RAD")
                if ( .not. th_on ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, p_th, rr0, rr1
                if ( File_error /= 0 ) rr1 = rr0
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)

            case("NUMBER_CMFD_SKIP")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, n_skip
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
            case("NUMBER_CMFD_ACC")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, n_acc
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
            case("TALLY")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, tally_switch
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                if( tally_switch > 0 .and. icore == score ) then
                    open(prt_flux,file="flux.out",action="write",status="replace")
                    open(prt_powr,file="power.out",action="write",status="replace")
                end if
            case("TALLY2")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, tallyon
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                allocate(ttally(1),tgroup(1))
                ttally(1) = 4
                tgroup(1) = 3D+1
                n_tgroup  = 1
                n_type = 1
                n_tcycle = 0
            case("TALLY_TYPE")
                if ( .not. tallyon ) cycle
                n_type = 0
                deallocate(ttally)
                do
                n_type = n_type + 1
                allocate(ttally(n_type))
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, ttally(1:n_type)
                deallocate(ttally)
                if ( File_Error /= 0 ) then
                    n_type = n_type - 1
                    allocate(ttally(n_type))
                    rewind(File_Number)
                    do
                    read(File_Number,*,iostat=File_Error) Char_Temp
                    Call Small_to_Capital(Char_Temp)
                    if ( Char_Temp == 'TALLY_TYPE' ) exit
                    end do
                    backspace(File_Number)
                    read(File_Number,*,iostat=File_Error) Char_Temp, Equal, ttally(1:n_type)
                    ! for XS production
                    do i = 1, n_type
                    if ( ttally(i) > 10 ) then
                        allocate(tally_temp(n_type))
                        tally_temp(:) = ttally(:)
                        deallocate(ttally)
                        n_type = n_type + 1
                        allocate(ttally(n_type))
                        ttally(1:n_type-1) = tally_temp(1:n_type-1)
                        ttally(n_type) = 0
                        deallocate(tally_temp)
                        exit
                    end if
                    end do
                    if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                    exit
                end if
                end do
            case("TALLY_GROUP")
                if ( .not. tallyon ) cycle
                deallocate(tgroup)
                n_tgroup = 0
                do
                n_tgroup = n_tgroup + 1
                allocate(tgroup(n_tgroup))
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, tgroup(1:n_tgroup)
                deallocate(tgroup)
                if ( File_Error /= 0 ) then
                    n_tgroup = n_tgroup - 1
                    allocate(tgroup(n_tgroup))
                    rewind(File_Number)
                    do
                    read(File_Number,*,iostat=File_Error) Char_Temp
                    Call Small_to_Capital(Char_Temp)
                    if ( Char_Temp == 'TALLY_GROUP' ) exit
                    end do
                    backspace(File_Number)
                    read(File_Number,*,iostat=File_Error) Char_Temp, Equal, tgroup(1:n_tgroup)
                    if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                    exit
                end if
                end do
                n_tgroup = n_tgroup + 1
            case("TALLY_CYCLE")
                if ( .not. tallyon ) cycle
                n_tcycle = 0
                do
                n_tcycle = n_tcycle + 1
                allocate(tcycle(n_tcycle))
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, tcycle(1:n_tcycle)
                deallocate(tcycle)
                if ( File_Error /= 0 ) then
                    n_tcycle = n_tcycle - 1
                    allocate(tcycle(n_tcycle))
                    rewind(File_Number)
                    do
                    read(File_Number,*,iostat=File_Error) Char_Temp
                    Call Small_to_Capital(Char_Temp)
                    if ( Char_Temp == 'TALLY_CYCLE' ) exit
                    end do
                    backspace(File_Number)
                    read(File_Number,*,iostat=File_Error) Char_Temp, Equal, tcycle(1:n_tcycle)
                    if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                    exit
                end if
                end do
                if ( maxval(tcycle) > n_act .and. icore == score ) then
                    print*, " tally cycle > no. of active cycles"
                    stop
                end if
            case("MESH_GRID")
                meshon = .true.
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, fm0, fm1, nfm
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
                fm2 = fm1 - fm0
                dfm = fm2 / dble(nfm)
                ! area and volume of mesh cell
                a_fm(:) = dfm(1)*dfm(3)
                a_fm(5) = dfm(1)*dfm(2)
                a_fm(6) = a_fm(5)
                v_fm    = dfm(1)*dfm(2)*dfm(3)
                n_nodes = nfm(1)*nfm(2)*nfm(3)

            case("MESH_GRID_TET_VRC")
                do_gmsh_vrc = .true.
                meshon_tet_vrc = .true.
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, fm0, fm1, nfm
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
                fm2 = fm1 - fm0
                dfm = fm2 / dble(nfm)
                ! area and volume of mesh cell
                a_fm(:) = dfm(1)*dfm(3)
                a_fm(5) = dfm(1)*dfm(2)
                a_fm(6) = a_fm(5)
                v_fm    = dfm(1)*dfm(2)*dfm(3)

            case("INITIAL_SOURCE")
                source_read = .true.
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, source_file
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)

            case("ACTIVE_GRID")
                meshon = .true.
                wholecore = .true.
                if ( .not. ( tallyon .or. fmfdon ) ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, fm0, fm1, nfm
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
                fm2 = fm1 - fm0
                dfm = fm2 / dble(nfm)
                ! area and volume of mesh cell
                a_fm(:) = dfm(1)*dfm(3)
                a_fm(5) = dfm(1)*dfm(2)
                a_fm(6) = a_fm(5)
                v_fm    = dfm(1)*dfm(2)*dfm(3)

            case("BU_GROUP")
                if ( .not. fmfdon ) cycle
                BUGROUP = .true.
                allocate(butype(nfm(1),nfm(2),nfm(3)))
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
                do kk = nfm(3), 1, -1
                do jj = nfm(2), 1, -1
                read(File_Number,*,iostat=File_Error), (butype(ii,jj,kk), ii = 1, nfm(1))
                end do
                end do

            case("MC_BU")
                if ( .not. fmfdon ) cycle
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, MCBU
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)

            case("NUM_PSEUDO_RAY")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, m_pseudo
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)

            case("TRANSIENT")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, do_transient, npg, line
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                if (E_mode == 1) npg = 6

                if(trim(uppercase(line)) == "DMC")  then
                    do_DMC = .true.
                elseif(trim(uppercase(line)) == "PCQS") then
                    do_PCQS = .true.
                else
                    print *, "ERROR : Unidentified transient solution method -", trim(line)
                    stop
                endif


            case("N_PCQS_ACTIVE")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, N_PCQS_ACT
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)

            case("N_PCQS_INACTIVE")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, N_PCQS_INACT
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)

            case("TIME_LAG")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, time_lag
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)

            case("N_TIMESTEP")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, n_timestep
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)

            case("K_STEADY")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, k_steady
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)

            case("MAT_CHANGE")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, MAT_CHANGE
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)

            case("GEOM_CHANGE")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, GEOM_CHANGE
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)

            case("N_INTERVAL")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, n_interval
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)

                allocate(purterb(n_interval))
                allocate(move_surf(n_interval))

                ierr = 0 ; curr_line = 0
                do i = 1, n_interval
                    ! read parameters
                    call readandparse(File_Number, args, nargs, ierr, curr_line)

                    read(args(1), *) purterb(i)%start_time
                    read(args(2), *) purterb(i)%end_time

                    if (geom_change) then
                        read(args(3), *) move_surf(i)
                    elseif (mat_change) then
                        read(args(3), *) purterb(i)%idx1
                    endif
                    read(args(4), *) purterb(i)%idx2


                    ! read f(t)
                    call readandparse(File_Number, args, nargs, ierr, curr_line)
                    purterb(i)%fcn = ''
                    do j = 1, nargs
                        call insertstr(purterb(i)%fcn, trim(args(j)),index(purterb(i)%fcn,' '))
                    enddo

                enddo


            case("PLOT")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, plotgeom, n_plot
                if(Equal/="=") call Card_Error(Card_Type,Char_Temp)

                allocate(plotlist(n_plot))
                allocate(plottype(n_plot))

                allocate(plt_x0(n_plot))
                allocate(plt_y0, plt_z0, plt_x1, plt_y1, plt_z1, plt_dx, plt_dy, plt_dz, mold=plt_x0)
                allocate(plt_nx, plt_ny, plt_nz, mold=plottype)


                do i = 1, n_plot
                    do
                    call readandparse(File_Number, args, nargs, ierr, curr_line)
                    if (nargs > 0) exit
                    enddo
                    plotlist(i) = trim(args(1))
                    read(args(2), '(I)') plottype(i)

                    select case (plottype(i))
                    case (1)
                        do
                        call readandparse(File_Number, args, nargs, ierr, curr_line)
                        if (nargs > 0) exit
                        enddo
                        read(args(1:7), *) plt_x0(i), plt_x1(i), &
                                           plt_nx(i), plt_y0(i), &
                                           plt_y1(i), plt_ny(i), plt_z0(i)
                        plt_dx(i) = (plt_x1(i) - plt_x0(i)) / real(plt_nx(i),8)
                        plt_dy(i) = (plt_y1(i) - plt_y0(i)) / real(plt_ny(i),8)

                    case (2)
                        do
                        call readandparse(File_Number, args, nargs, ierr, curr_line)
                        if (nargs > 0) exit
                        enddo
                        read(args(1:7), *) plt_y0(i), plt_y1(i), &
                                           plt_ny(i), plt_z0(i), &
                                           plt_z1(i), plt_nz(i), plt_x0(i)
                        plt_dy(i) = (plt_y1(i) - plt_y0(i)) / real(plt_ny(i),8)
                        plt_dz(i) = (plt_z1(i) - plt_z0(i)) / real(plt_nz(i),8)

                    case (3)
                        do
                        call readandparse(File_Number, args, nargs, ierr, curr_line)
                        if (nargs > 0) exit
                        enddo
                        read(args(1:7), *) plt_z0(i), plt_z1(i), &
                                           plt_nz(i), plt_x0(i), &
                                           plt_x1(i), plt_nx(i), plt_y0(i)
                        plt_dz(i) = (plt_z1(i) - plt_z0(i)) / real(plt_nz(i),8)
                        plt_dx(i) = (plt_x1(i) - plt_x0(i)) / real(plt_nx(i),8)

                    end select

                enddo

            case("PREDICTOR_CORRECTOR")
                backspace(File_Number)
                read(File_Number,*,iostat=File_Error) Char_Temp, Equal, preco
                if ( Equal /= "=" ) call Card_Error (Card_Type,Char_Temp)
                porc = 1

            end select Card_A_Inp
            if (Char_Temp=="ENDA") Exit Read_Card_A
        end do Read_Card_A

        case('D')
            nm0 = 0
            nm1 = 10
            allocate(materials(nm1))
            Read_Card_D : do
                read(File_Number,*,iostat=File_Error) Char_Temp
                if (Char_Temp(1:3)=="MAT" .or. Compare_String(Char_Temp(1:3),"mat")) then
                    ! add a new material slot
                    nm0 = nm0+1
                    if ( nm0 > nm1 ) then
                        call move_alloc(materials,materials_temp)
                        allocate(materials(nm1*10))
                        materials(1:nm1) = materials_temp(1:nm1)
                        deallocate(materials_temp)
                        nm1 = nm1 * 10
                    end if
                    CE_mat_ptr => materials(nm0)

                    if(File_Error/=0) call Card_Error(Card_Type,Char_Temp)
                    Read_Mat : do
                        read(File_Number,*,iostat=File_Error) Char_Temp
                        Call Small_to_Capital(Char_Temp)
                        Card_D_Inp : select case(Char_Temp)
                        case("MAT_NAME")
                            backspace(File_Number)
                            read(File_Number,*,iostat=File_Error) Char_Temp, Equal, CE_mat_ptr%mat_name
                            if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                        case("DENSITY_GPCC")
                            backspace(File_Number)
                            read(File_Number,*,iostat=File_Error) Char_Temp, Equal, CE_mat_ptr%density_gpcc
                            if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                        case("VOL")
                            backspace(File_Number)
                            read(File_Number,*,iostat=File_Error) Char_Temp, Equal, CE_mat_ptr%vol
                            if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                        case("FISSIONABLE")
                            backspace(File_Number)
                            read(File_Number,*,iostat=File_Error) Char_Temp, Equal, CE_mat_ptr%fissionable
                            if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                        case("DEPLETABLE")
                            backspace(File_Number)
                            read(File_Number,*,iostat=File_Error) Char_Temp, Equal, CE_mat_ptr%depletable
                            if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
!                            if ( DTMCBU .and. CE_mat_ptr%depletable .and. &
!                                .not. allocated(CE_mat_ptr%n_dtmc) ) allocate(CE_mat_ptr%n_dtmc(4))
!                            if ( CE_mat_ptr%depletable .and. .not. allocated(CE_mat_ptr%n_dtmc) ) &
!                                allocate(CE_mat_ptr%n_dtmc(4))
!                        case("N_DTMC")
!                            if ( .not. allocated(CE_mat_ptr%n_dtmc) ) cycle
!                            backspace(File_Number)
!                            read(File_Number,*,iostat=File_Error) Char_Temp, Equal, CE_mat_ptr%n_dtmc(:)
!                            if(Equal/="=") call Card_Error(Card_Type,Char_Temp)

                        case("SAB")
                            backspace(File_Number)
                            read(File_Number,*,iostat=File_Error) Char_Temp, Equal, CE_mat_ptr%sab
                            if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                            if (CE_mat_ptr%sab) then
                                backspace(File_Number)
                                read(File_Number,*,iostat=File_Error) &
                                    Char_Temp, Equal, line, lib1,lib2
                                call READ_SAB_MAT(j,lib1,lib2)
                            endif

                        case("N_ISO")
                            backspace(File_Number)
                            read(File_Number,*,iostat=File_Error) Char_Temp, Equal, CE_mat_ptr%n_iso
                            if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                            allocate(CE_mat_ptr%ace_idx(1:CE_mat_ptr%n_iso))
                            allocate(CE_mat_ptr%numden(1:CE_mat_ptr%n_iso))
                            allocate(numden(1:CE_mat_ptr%n_iso))

                        case("ISOTOPES")
                            backspace(File_Number)
                            if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                            read(File_Number,*,iostat=File_Error) Char_Temp, Equal, line, CE_mat_ptr%numden(1)
                            CE_mat_ptr%ace_idx(1) = find_ACE_iso_idx (ace, line)
                            do i = 2, CE_mat_ptr%n_iso
                                read(File_Number,*,iostat=File_Error) line, CE_mat_ptr%numden(i)
                                CE_mat_ptr%ace_idx(i) = find_ACE_iso_idx (ace, line)
                            enddo

                            ! sort (ascending order) for predictor-corrector
                            do ii = 1, CE_mat_ptr%n_iso-1, 1
                                idx_temp = CE_mat_ptr%ace_idx(ii)
                                den_temp = CE_mat_ptr%numden(ii)
                                comp = idx_temp
                                mini = ii
                                do jj = ii+1, CE_mat_ptr%n_iso
                                if ( comp > CE_mat_ptr%ace_idx(jj) ) then
                                    comp = CE_mat_ptr%ace_idx(jj)
                                    mini = jj
                                end if
                                end do
                                CE_mat_ptr%ace_idx(ii) = CE_mat_ptr%ace_idx(mini)
                                CE_mat_ptr%numden(ii) = CE_mat_ptr%numden(mini)
                                CE_mat_ptr%ace_idx(mini) = idx_temp
                                CE_mat_ptr%numden(mini) = den_temp
                            end do

                            ! number density
                            if (CE_mat_ptr%density_gpcc < 0 .and. CE_mat_ptr%numden(1) < 0) then
                                numden(:) = CE_mat_ptr%numden(:)
                                sum_den = sum(numden(:))
                                do i = 1, CE_mat_ptr%n_iso
                                    CE_mat_ptr%numden(i) = - CE_mat_ptr%density_gpcc * (numden(i)/sum_den) &
                                                            *N_avogadro/(ace(CE_mat_ptr%ace_idx(i))%atn*m_n)
                                enddo
                            elseif (CE_mat_ptr%density_gpcc < 0 .and. CE_mat_ptr%numden(1) > 0) then
                                do i =1, CE_mat_ptr%n_iso
                                    numden(i) = ace(CE_mat_ptr%ace_idx(i))%atn*m_n*CE_mat_ptr%numden(i)
                                enddo
                                sum_den = sum(numden(:))
                                do i = 1, CE_mat_ptr%n_iso
                                    CE_mat_ptr%numden(i) = - CE_mat_ptr%density_gpcc &
                                                            * (numden(i) / sum_den) &
                                                            *N_avogadro/(ace(CE_mat_ptr%ace_idx(i))%atn*m_n)
                                enddo
                            elseif (CE_mat_ptr%density_gpcc > 0 .and. CE_mat_ptr%numden(1) < 0) then
                                do i =1, CE_mat_ptr%n_iso
                                    numden(i) = CE_mat_ptr%numden(i) / (ace(CE_mat_ptr%ace_idx(i))%atn*m_n)
                                enddo
                                sum_den = sum(numden(:))
                                do i = 1, CE_mat_ptr%n_iso
                                    CE_mat_ptr%numden(i) = CE_mat_ptr%density_gpcc &
                                                            * (numden(i) / sum_den)
                                enddo
                            elseif (CE_mat_ptr%density_gpcc > 0 .and. CE_mat_ptr%numden(1) > 0) then
                                numden = CE_mat_ptr%numden
                                sum_den = sum(numden(:))
                                do i = 1, CE_mat_ptr%n_iso
                                    CE_mat_ptr%numden(i) = CE_mat_ptr%density_gpcc * (numden(i)/sum_den)
                                enddo
                            endif

                            deallocate(numden)

!                            print*, CE_mat_ptr%mat_name
!                            print*, CE_mat_ptr%numden

                        case("DOPPLER")
                            backspace(File_Number)
                            read(File_Number,*,iostat=File_Error) Char_Temp, Equal, CE_mat_ptr%db
                            if(Equal/="=") call Card_Error(Card_Type,Char_Temp)

                        case("TEMPERATURE")
                            if ( .not. CE_mat_ptr%db ) then
                            call MSG1(CE_mat_ptr%ace_idx(1),trim(CE_mat_ptr%mat_name))
                            cycle
                            end if
                            backspace(File_Number)
                            read(File_Number,*,iostat=File_Error) Char_Temp, Equal, CE_mat_ptr%temp
                            CE_mat_ptr%temp = CE_mat_ptr%temp * K_B

                        case("MAT_TYPE")
                            backspace(File_Number)
                            read(File_Number,*,iostat=File_Error) Char_Temp, Equal, mtype
                            Call Small_to_Capital(mtype)
                            select case(mtype)
                            case("FUEL"); CE_mat_ptr%mat_type = 1
                            case("CLAD"); CE_mat_ptr%mat_type = 2
                            case("COOL"); CE_mat_ptr%mat_type = 3
                            end select
						case default
						    !print *, "ERROR, " Char_Temp
                        end select Card_D_Inp

                        if (Char_Temp(1:7)=="END_MAT") Exit Read_Mat

                    enddo Read_Mat

                end if

                if (Char_Temp=="ENDD") Exit Read_Card_D
            end do Read_Card_D

            call move_alloc(materials,materials_temp)
            allocate(materials(nm0))
            materials(1:nm0) = materials_temp(1:nm0)
            deallocate(materials_temp)
            n_materials = nm0

        case('E') ! Depletion input
            Read_Card_E : do
                if(File_Error/=0) call Card_Error(Card_Type,Char_Temp)
                read(File_Number,*,iostat=File_Error) Char_Temp
                Call Small_to_Capital(Char_Temp)
                Card_E_Inp : select case(Char_Temp)
                ! 01_01. DO_BURN Title
                case("DO_BURN")
                    backspace(File_Number)
                    read(File_Number,*,iostat=File_Error) Char_Temp, Equal, do_burn
                    if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                !case("REAL_POWER")
                !    backspace(File_Number)
                !    read(File_Number,*,iostat=File_Error) Char_Temp, Equal, RealPower
                !    if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                ! 01_02. Read Data Format
                case("MATRIX_EXPONENTIAL_SOLVER")
                    backspace(File_Number)
                    read(File_Number,*,iostat=File_Error) Char_Temp, Equal, Matrix_Exponential_Solver
                    if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                ! 01_03. Read Energy Group
                case("CRAM_ORDER")
                    backspace(File_Number)
                    read(File_Number,*,iostat=File_Error) Char_Temp, Equal, CRAM_ORDER
                    if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                case("NSTEP_BURNUP")
                    backspace(File_Number)
                    read(File_Number,*,iostat=File_Error) Char_Temp, Equal, NSTEP_BURNUP
                    if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                    allocate(burn_step(0:NSTEP_BURNUP))
                case("BURNUP_TIME")
                    backspace(File_Number)
                    read(File_Number,*,iostat=File_Error) Char_Temp, Equal, burn_step(1)
                    do i = 2, NSTEP_BURNUP
                        read(File_Number,*,iostat=File_Error) burn_step(i)
                    enddo
                    burn_step(0) = 0.0d0
                    burn_step = burn_step * 86400.d0 !Unit in [sec]
                    if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                case("LIBRARY_PATH")
                    backspace(File_Number)
                    read(File_Number,*,iostat=File_Error) Char_Temp, Equal
                    if(Equal/="=") call Card_Error(Card_Type,Char_Temp)
                    read(File_Number,'(A)',iostat=File_Error) dep_lib(:)
                    dep_lib = adjustl(dep_lib)
                case("DTMC_BU")
                    if ( .not. fmfdon ) cycle
                    if ( .not. do_burn ) cycle
                    DTMCBU = .true.
                    allocate(buuniv(nfm(1),nfm(2),nfm(3)))
                    allocate(buring(nfm(1),nfm(2),nfm(3)))
                    buring = 0
                    backspace(File_Number)
                    read(File_Number,*,iostat=File_Error)
                    do kk = nfm(3), 1, -1
                    do jj = nfm(2), 1, -1
                    read(File_Number,*,iostat=File_Error), &
                        (buuniv(ii,jj,kk), ii = 1, nfm(1))
                    end do
                    end do
    
                    ! cell index
                    n_univ = size(universes)-1
                    do ii = 1, nfm(1)
                    do jj = 1, nfm(2)
                    do kk = 1, nfm(3)
                        ! search universe ID
                        if ( buuniv(ii,jj,kk) == 0 ) cycle
                        do mm = 1, n_univ
                        if ( buuniv(ii,jj,kk) == universes(mm)%univ_id ) then
                            univid = mm
                            exit
                        end if
                        end do
                        ! iDTMC ID
                        nargs = universes(univid)%ncell
                        buring(ii,jj,kk) = nargs
                        do mm = 1, nargs
                        idx_temp = universes(univid)%cell(mm)
                        cells(idx_temp)%dtmc = mm
                        mini = cells(idx_temp)%mat_idx
                        if ( materials(mini)%depletable ) then
                        if ( .not. allocated(materials(mini)%dtmc) ) then
                            allocate(materials(mini)%dtmc(200))
                            materials(mini)%dtmc    = 0
                            materials(mini)%dtmc(1) = ii
                            materials(mini)%dtmc(2) = jj
                            materials(mini)%dtmc(3) = kk
                            materials(mini)%dtmc(4) = mm
                        else
                            ! non-zero elements 
                            comp = count(materials(mini)%dtmc/=0)
                            materials(mini)%dtmc(comp+1) = ii
                            materials(mini)%dtmc(comp+2) = jj
                            materials(mini)%dtmc(comp+3) = kk
                            materials(mini)%dtmc(comp+4) = mm
                        end if
                        end if
                        end do
                    end do
                    end do
                    end do
                    nrings = maxval(buring)
                    deallocate(buuniv)
    
                    allocate(mid(200))
                    do mm = 1, n_materials
                        if ( .not. allocated(materials(mm)%dtmc) ) cycle
                        comp = count(materials(mm)%dtmc/=0)
                        mid(1:comp) = materials(mm)%dtmc(1:comp)
                        deallocate(materials(mm)%dtmc)
                        allocate(materials(mm)%dtmc(comp))
                        materials(mm)%dtmc(1:comp) = mid(1:comp)
                    end do
                    deallocate(mid)

                end select Card_E_Inp
                if (Char_Temp=="ENDE") Exit Read_Card_E
            end do Read_Card_E

        case default
            if (icore==score) print *, 'No such card type defined ::', card_type
            stop
        end select

        RealPower = Nominal_Power

    end subroutine Read_Card

    subroutine ZIGZAG_INDEX(zztemp)
        use FMFD_HEADER, only: n_zz, zzf0, zzf1, zzf2, zz_div, &
                            zzc0, zzc1, zzc2, zza0, zza1, zza2, &
                            zzb0, zzb1, zzb2, quarter, wholecore
        implicit none
        integer:: zztemp(:)
        integer:: ii

        zz_div = 2*n_zz+1
        allocate(zzf0(zz_div+1))
        allocate(zzf1(zz_div))
        allocate(zzf2(zz_div))
        ! zzf0   : reference points
        zzf0(1) = 0
        zzf0(2:n_zz+1) = zztemp(1:n_zz)
        zzf0(n_zz+2:zz_div) = nfm(1) - zzf0(n_zz+1:2:-1)
        zzf0(zz_div+1) = nfm(1)

        ! zzf1   : lower points for zzf0
        zzf1(1:n_zz) = zztemp(n_zz:1:-1)
        zzf1(n_zz+1) = 0
        zzf1(n_zz+2:zz_div) = zztemp(1:n_zz)

        ! zzf2   : upper points for zzf0
        zzf2(:) = nfm(1) - zzf1(:)


        ! =====================================================================
        ! quarter core
        if ( quarter ) then
        zz_div = n_zz+1
        deallocate(zzf0,zzf1,zzf2)

        allocate(zzf0(zz_div+1))
        allocate(zzf1(zz_div))
        allocate(zzf2(zz_div))
        zzf0(1) = 0
        zzf0(2:zz_div) = nfm(1) - zztemp(n_zz:1:-1)
        zzf0(zz_div+1) = nfm(1)

        zzf1(:) = 0

        zzf2(1) = nfm(1)
        zzf2(2:) = nfm(1) - zztemp(1:n_zz)
        end if



        ! =====================================================================
        ! 1-node CMFD
        if ( cmfdon ) then
        allocate(zzc0(zz_div+1))
        allocate(zzc1(zz_div))
        allocate(zzc2(zz_div))
        zzc0 = zzf0 / fcr
        zzc1 = zzf1 / fcr
        zzc2 = zzf2 / fcr
        if ( maxval(mod(zzf0,fcr)) /= 0 .or. &
             maxval(mod(zzf1,fcr)) /= 0 .or. &
             maxval(mod(zzf2,fcr)) /= 0 ) then
            write(*,*), " * check zigzag index"
            stop
        end if
        end if



        ! only active core
        if ( wholecore ) then
        allocate(zza0(zz_div+1))
        allocate(zza1(zz_div))
        allocate(zza2(zz_div))
        allocate(zzb0(zz_div+1))
        allocate(zzb1(zz_div))
        allocate(zzb2(zz_div))
        zza0(1:zz_div/2+1) = zzc0(1:zz_div/2+1) + 1
        zza0(zz_div/2+2:)  = zzc0(zz_div/2+2:) - 1
        zza1 = zzc1 + 1
        zza2 = zzc2 - 1
        zzb0(1:zz_div/2+1) = zzf0(1:zz_div/2+1) + fcr
        zzb0(zz_div/2+2:)  = zzf0(zz_div/2+2:) - fcr
        zzb1 = zzf1 + fcr
        zzb2 = zzf2 - fcr
        end if

    end subroutine

    subroutine READ_DEPLETION

        logical :: file_exists
        integer :: Open_Error, File_Error
        character(4)::Card
        character::Card_Type

        filename = trim(directory)//'depletion.inp'

        file_exists = .false.
        inquire(file=trim(filename),exist=file_exists)
        if(file_exists==.false.) then
            do_burn = .false.
            return
        end if

        open(unit=rd_dep,file=trim(filename),status='old',action='read',iostat=Open_Error)
        Read_File : do
            read(rd_dep,*,iostat=File_Error) Card
            if (File_Error/=0) exit Read_File
            if (Card=="CARD" .or. Compare_String(Card,"card")) then
                backspace(rd_dep)
                read(rd_dep,*,iostat=File_Error) Card,Card_Type
                call Small_to_Capital(Card_Type)
                if (icore==score) print *, "depletion.inp :: CARD ", Card_Type," is being read..."
                call Read_Card(rd_dep,Card_Type)
            end if
        end do Read_File
        close(rd_dep)

    end subroutine READ_DEPLETION

    subroutine MSG1(idx,matname)
        integer, intent(in):: idx
        character(*), intent(in):: matname

        if ( icore /= score ) return

        write(*,2), "    OTF Doppler broadening option is not on"
        write(*,1), "    XS for T =", &
            ace(idx)%temp/K_B, " K will be used in the ", matname, " material"

        1 format(a,f7.2,3a)
        2 format(a)

    end subroutine

! =========================================================================
! FMFD_INITIAL
! =========================================================================
subroutine FMFD_INITIAL
    use FMFD,   only: fmfdon, n_acc, FMFD_type, acc_skip
    implicit none

    n_acc  = 2
    n_skip = 0
    acc_skip = 0
    FMFD_type = 1
	dduct = -1.0

end subroutine

! =============================================================================
!
! =============================================================================
subroutine FMFD_ERR1
    if ( mod(nfm(1),fcr) /= 0 .or. mod(nfm(3),fcz) /= 0 ) then
        print*, "CMFD mesh grid /= FMFD mesh grid"
        stop
    end if
end subroutine

! =========================================================================
! PRUP_INTIAL
! =========================================================================
subroutine PRUP_INITIAL
    use ENTROPY, only: rampup, ccrt, scrt, elength, mprupon, shannon, &
                       dshannon, entrp1, entrp2, genup
    implicit none
    genup    = .true.
    rampup   = ngen
    ccrt     = 1
    scrt     = 1
    elength  = 2
    if ( n_batch == 1 ) then
    t_inact  = n_inact
    t_totcyc = n_totcyc
    end if
    n_inact  = 1000
    n_totcyc = n_inact + n_act
    allocate(shannon(2*elength))
    shannon  = 0
    dshannon = 0
    entrp1   = 0
    entrp2   = 0

end subroutine

! =========================================================================
! SET_PRUP
! =========================================================================
subroutine SET_PRUP
    use ENTROPY, only: rampup, ccrt, scrt, crt1, crt2, crt3, elength, &
                       shannon
    implicit none

    ! convergence criterion
    if ( crt1c < 1 ) then
        crt1 = crt1c/sqrt(dble(ngen))
    else
        ccrt = 2
        crt1 = crt1c
    end if

    ! stopping criterion
    if ( crt2c < 1 ) then
        crt2 = crt2c/sqrt(dble(ngen))
    else
        scrt = 2
        crt2 = crt2c
    end if

    ! last criterion
    crt3 = crt3c/sqrt(dble(ngen))

end subroutine

! =========================================================================
! READ_DBRC
! =========================================================================
subroutine READ_DBRC(line)
    implicit none
    character(len=*):: line
    character(len=80):: left
    integer:: j, i

    ! iinimum E
    j = index(line(:),' ')
    read(line(1:j-1),*) DBRC_E_min

    ! maximum E
    line = adjustl(line(j+1:)); j = index(line(:),' ')
    read(line(1:j-1),*) DBRC_E_max

    ! first library
    line = adjustl(line(j+1:)); j = index(line(:),' ')
    left(:) = line(:)

    ! other libraries
    do
        line = adjustl(line(j+1:))
        if ( len_trim(line) == 0 ) then
            exit
        else
            j = index(line(:),' ')
            n_iso0K = n_iso0K + 1
        end if
    end do

    ! library reading
    allocate(ace0K(n_iso0K))
    read(left,*) (ace0K(i)%library, i = 1, n_iso0K)

end subroutine

subroutine read_CE_mat

    logical :: file_exists
    integer :: Open_Error, File_Error
    character(4)::Card
    character::Card_Type

    filename = trim(directory)//'CE_mat.inp'
    file_exists = .false.
    inquire(file=trim(filename),exist=file_exists)
    if(file_exists==.false.) then
        if (icore==score) print *, "INPUT ERROR :: NO CE_mat.inp file"
        stop
    end if
    open(unit=rd_mat,file=trim(filename),status='old', action='read',iostat=Open_Error)
    Read_File : do
        read(rd_mat,*,iostat=File_Error) Card
        if (File_Error/=0) exit Read_File
        if (Card=="CARD" .or. Compare_String(Card,"card")) then
            backspace(rd_mat)
            read(rd_mat,*,iostat=File_Error) Card,Card_Type
            call Small_to_Capital(Card_Type)
            if (icore==score) print *, "   CE_mat.inp :: CARD ", Card_Type," is being read..."
            call Read_Card(rd_mat,Card_Type)
        end if
    end do Read_File
    close(rd_mat)

    if ( icore == score ) print '(A27)', '    CE MAT READ COMPLETE...'

end subroutine

! =============================================================================
!
! =============================================================================
subroutine SOURCE_READING(bank_size)
    use TALLY, only: FM_ID
    implicit none
    integer, intent(in):: bank_size
    real(8), allocatable:: fsd_initial(:,:,:)
    integer:: ii, jj, kk
    real(8):: pxyz(1:3), id(1:3)

    allocate(fsd_initial(nfm(1),nfm(2),nfm(3)))

    ! source reading
    open(23,file=trim(source_file))
    do kk = nfm(3), 1, -1
    do jj = nfm(2), 1, -1
        read(23,*), (fsd_initial(ii,jj,kk), ii = 1, nfm(1))
    end do
    end do
    close(23)
    fsd_initial(:,:,:) = fsd_initial(:,:,:) / sum(fsd_initial(:,:,:)) &
                *count(fsd_initial(:,:,:)/=0)


    ! source intialization
    !$omp parallel do default(shared) private(ii,pxyz,id)
    do ii = 1, bank_size
    do
        pxyz(1) = rang()*fm2(1)+fm0(1)
        pxyz(2) = rang()*fm2(2)+fm0(2)
        pxyz(3) = rang()*fm2(3)+fm0(3)
        id = FM_ID(pxyz)
        if ( fsd_initial(id(1),id(2),id(3)) == 0 ) cycle

        source_bank(ii)%xyz = pxyz
        source_bank(ii)%wgt = fsd_initial(id(1),id(2),id(3))
        exit
    end do
    end do
    !$omp end parallel do

    deallocate(fsd_initial)

end subroutine


! =============================================================================
! READ_SAB_MAT reads which isotope is considered by thermal scattering; S(a,b)
! =============================================================================
subroutine READ_SAB_MAT(j,lib1,lib2)
    integer, intent(inout):: j
    !character(*), intent(inout):: line
    character(80):: lib1    ! which isotope
    character(80):: lib2    ! which library
    integer:: i, k
    logical :: found = .false. 

    ! find a isotope and connect to the corresponding library
    do i = 1, num_iso
        if ( trim(ace(i)%library) == trim(lib1) ) then
            do k = 1, sab_iso
                found = .true. 
                if ( trim(sab(k)%library) == trim(lib2) ) then
                    ace(i)%sab_iso = k
                end if
            end do
        end if
    end do
    
    if (.not. found) then 
        if (icore==score) print *, "NO Sab LIBRARY IN inventor.inp : ", lib2
        stop 
    endif 
    
    

end subroutine READ_SAB_MAT


    subroutine read_inventory
        implicit none
        integer :: i, j, iso, ierr
        character(50) :: mat_id, option

        ! ======================================== !
        !                 ACE read start
        ! ======================================== !
        filename = trim(directory)//'inventory.inp'
        open(rd_inven, file=trim(filename),action="read", status="old")
        read(rd_inven,'(A)') library_path(:)
        read(rd_inven,*) num_iso
        allocate(ace(1:num_iso))

        do iso =1, num_iso
            read(rd_inven,*) i, ace(iso)%library
        end do
        close(rd_inven)

        call SET_SAB
        call SET_DBRC
        call set_ace
        if(icore==score) print '(A29)', '    ACE Lib. READ COMPLETE...'


    end subroutine


! =============================================================================
! SET_SAB
! =============================================================================
subroutine SET_SAB
    integer:: iso
    integer:: dummy
    integer:: i

    sab_iso = 0
    do iso = 1, num_iso
    if ( IS_SAB(trim(ace(iso)%library)) ) sab_iso = sab_iso + 1
    end do

    if ( allocated(ace) ) deallocate(ace)

    filename = trim(directory)//'inventory.inp'

    open(rd_inven, file=trim(filename),action="read", status="old")
    read(rd_inven,'(A)') library_path(:)
    read(rd_inven,*) dummy
    num_iso = num_iso - sab_iso
    allocate(ace(1:num_iso))
    allocate(sab(1:sab_iso))

    do iso = 1, num_iso
        read(rd_inven,*) i, ace(iso)%library
    end do
    do iso = 1, sab_iso
        read(rd_inven,*), i, sab(iso)%library
    end do
    close(rd_inven)

end subroutine

! =============================================================================
! SET_DBRC
! =============================================================================
subroutine SET_DBRC
    integer:: ii, jj

    do ii = 1, n_iso0K
    do jj = 1, num_iso
        if ( trim(ace(jj)%library(1:5))  &
            == trim(ace0K(ii)%library(1:5)) ) then
            ace(jj)%resonant = ii
            exit
        end if
    end do
    end do

end subroutine



function IS_SAB(name_of_lib) result(lib_type)
    character(len=*), intent(in):: name_of_lib  ! name of library
    logical:: lib_type  ! type of library
    integer:: length    ! length of character

    length = len_trim(name_of_lib)
    lib_type = .false.
    if ( name_of_lib(length-5:length-5) == 't' ) lib_type = .true.

!    select case(name_of_lib(length-5:length-5))
!    case('c'); lib_type = 1 ! continuous energy
!    case('t'); lib_type = 4 ! thermal scattering; S(a,b)
!    end select

end function







    subroutine read_tally
        use TALLY, only: tally1, tally2

        integer :: i, j, k, idx, n, level, i_univ, i_lat, i_pin, n_pin
        integer :: a,b,c, i_xyz(3), i_save
        integer :: ierr
        character(100) :: line
        character(50)  :: option, temp, test
        type(particle) :: p_tmp
        logical :: found =.false.


        !Read tally.inp
        filename = trim(directory)//'tally.inp'
        open(rd_tally, file=trim(filename),action="read", status="old")

        ierr = 0;
        do while (ierr.eq.0)
            read (rd_tally, FMT='(A)', iostat=ierr) line
            if ((len_trim(line)==0).or.(scan(line,"%"))/=0) cycle
            !> option identifier
            j = index(adjustl(line),' ') -1
            option = line(1:j)

            if (trim(option) /= "tally") then
                print *, 'ERROR Tally Read :: tally.inp     ', option
                stop
            end if

            line = adjustl(line(j+1:))
            j = index(line,' ')-1
            option = trim(line(1:j))

            select case (option)
            case ("cell")
                read(line(j+1:), *) n
                allocate(TallyCoord(1:n))
                allocate(TallyFlux(1:n))
                allocate(TallyPower(1:n))
                allocate(tally1(1:n))
                allocate(tally2(1:n))
                tally1 = 0; tally2 = 0
                TallyFlux(:) =0; TallyPower(:)=0
                TallyCoord(:)%flag = 1
                do i = 1, n
10                    read (rd_tally, FMT='(A)', iostat=ierr) line
                    if ((len_trim(line)==0).or.(scan(line,"%"))/=0)  goto 10
                    level = 0; idx = index(line,'>')
                    do while (idx /= 0)
                        level = level + 1
                        j = index(line,' '); read(line(1:j),*) temp ; line = line(j:)
                        line = adjustl(line);j = index(line,' '); read(line(1:j),*) i_univ;  line = line(j:)
                        line = adjustl(line);j = index(line,' '); read(line(1:j),*) i_lat  ; line = line(j:)
                        line = adjustl(line);j = index(line,' '); read(line(1:j),*) TallyCoord(i)%coord(level)%lattice_x; line = line(j:)
                        line = adjustl(line);j = index(line,' '); read(line(1:j),*) TallyCoord(i)%coord(level)%lattice_y; line = line(j:)
                        line = adjustl(line);j = index(line,' '); read(line(1:j),*) TallyCoord(i)%coord(level)%lattice_z; line = line(j:)

                        TallyCoord(i)%coord(level)%cell     = find_cell_idx(cells, adjustl(temp))
                        if (i_univ == 0) then
                            TallyCoord(i)%coord(level)%universe = 0
                        else
                            TallyCoord(i)%coord(level)%universe = find_univ_idx(universes, i_univ)
                        endif

                        if (i_lat == 0) then
                            TallyCoord(i)%coord(level)%lattice = 0
                        else
                            TallyCoord(i)%coord(level)%lattice  =  find_lat_idx(lattices, i_lat)
                        endif

                        idx = index(line,'>')
                        line = line(idx+1:); line = adjustl(line)
                    enddo
                    idx = index(line, 'vol')
                    line = adjustl(line(4:)); read(line(1:),*) TallyCoord(i)%vol
                    TallyCoord(i)%n_coord = level
                enddo
                TallyFlux(:)  = 0
                TallyPower(:) = 0

            case("pin", "pin_tet")
                read(line(j+1:), *) n
                allocate(TallyCoord(1:n)); TallyCoord(n)%n_coord = 0
                allocate(TallyFlux(1:n))
                allocate(TallyPower(1:n))
                allocate(tally_buf(1:n))
                allocate(tally1(1:n))
                allocate(tally2(1:n))
                tally1 = 0; tally2 = 0
                TallyCoord(:)%flag = 0
                i = 1;
                do while ( i <= n)
                11  read (rd_tally, FMT='(A)', iostat=ierr) line
                    if ((len_trim(line)==0).or.(scan(line,"%"))/=0) goto 11

                    level = 0; idx = index(line,'>')
                    do while (idx /= 0)
                        level = level + 1
                        !if (icore==score)print *, 'level', level, line
                        j = index(line,' '); read(line(1:j),*) temp ; line = line(j:)
                        line = adjustl(line);j = index(line,' '); read(line(1:j),*) i_univ;  line = line(j:)
                        line = adjustl(line);j = index(line,' '); read(line(1:j),*) i_lat  ; line = line(j:)

                        if (i_lat /= 0) i_lat = find_lat_idx(lattices, i_lat)
                        line = adjustl(line);
                        if (line(1:3) == 'all') then
                            a = lattices(i_lat)%n_xyz(1)
                            b = lattices(i_lat)%n_xyz(2)
                            c = lattices(i_lat)%n_xyz(3)
                            n_pin = a*b*c
                            i_save = i
                            do i_pin = 1, n_pin
                                i_xyz = getXYZ(i_pin, a,b,c)

                                TallyCoord(i)%coord(1:level) = TallyCoord(i_save)%coord(1:level)

                                TallyCoord(i)%coord(level)%lattice_x = i_xyz(1)
                                TallyCoord(i)%coord(level)%lattice_y = i_xyz(2)
                                TallyCoord(i)%coord(level)%lattice_z = i_xyz(3)

                                if (i_lat == 0) then
                                    TallyCoord(i)%coord(level)%lattice = 0
                                else
                                    TallyCoord(i)%coord(level)%lattice  =  i_lat
                                endif
                                TallyCoord(i)%n_coord = level
                                !> Reset the cell & univ designation (for pin only)
                                TallyCoord(i)%coord(level)%cell = 0
                                TallyCoord(i)%coord(level)%universe = 0

                                i = i + 1

                            enddo
                            idx = 0
                        else
                            line = adjustl(line);j = index(line,' '); read(line(1:j),*) TallyCoord(i)%coord(level)%lattice_x; line = line(j:)
                            line = adjustl(line);j = index(line,' '); read(line(1:j),*) TallyCoord(i)%coord(level)%lattice_y; line = line(j:)
                            line = adjustl(line);j = index(line,' '); read(line(1:j),*) TallyCoord(i)%coord(level)%lattice_z; line = line(j:)

                            if (adjustl(temp) /= '0') &
                                TallyCoord(i)%coord(level)%cell = find_cell_idx(cells, adjustl(temp))

                            if (i_univ == 0) then
                                TallyCoord(i)%coord(level)%universe = 0
                            else
                                TallyCoord(i)%coord(level)%universe = find_univ_idx(universes, i_univ)
                            endif

                            if (i_lat == 0) then
                                TallyCoord(i)%coord(level)%lattice = 0
                            else
                                TallyCoord(i)%coord(level)%lattice  =  i_lat
                            endif

                            idx = index(line,'>')
                            line = line(idx+1:); line = adjustl(line)

                            if (idx == 0) then
                                TallyCoord(i)%n_coord = level
                                !> Reset the cell designation (for pin only)
                                TallyCoord(i)%coord(level)%cell = 0
                                i = i + 1
                            endif
                        endif
                    enddo
                    !> pin volume is not needed (all same)
                    TallyCoord(:)%vol = 1
                enddo
                TallyFlux(:)  = 0
                TallyPower(:) = 0

                if (option == "pin_tet") do_gmsh_VRC = .true.

            case ("tet")
                if (.not. do_gmsh) then
                    print *, "Tetrahedral tracking option is not activated in geom.inp"
                    stop
                endif

                read(line(j+1:), *) tet_xyz(1:3)


                allocate(TallyFlux(1:num_tet))
                allocate(TallyPower(1:num_tet))
                allocate(tally_buf(1:num_tet))
                TallyFlux(:)  = 0
                TallyPower(:) = 0
                allocate(tally1(1:num_tet))
                allocate(tally2(1:num_tet))
                tally1 = 0; tally2 = 0


                p_tmp%n_coord = 1
                p_tmp%coord(1)%xyz = tet_xyz
                !print *, p_tmp%coord(1)%xyz
                call find_cell(p_tmp, found)
                !do i = 1, p_tmp%n_coord
                !    print *, p_tmp%coord(i) % cell
                !    print *, p_tmp%coord(i) % universe
                !    print *, p_tmp%coord(i) % lattice
                !enddo


                ! fill tallycoord
                allocate(TallyCoord(1))
                TallyCoord(1)%n_coord = p_tmp%n_coord
                TallyCoord(:)%flag = 0
                do i = 1, p_tmp%n_coord-1
                    TallyCoord(1)%coord(i)%cell           = p_tmp%coord(i) % cell
                    TallyCoord(1)%coord(i)%universe  = p_tmp%coord(i) % universe
                    TallyCoord(1)%coord(i)%lattice   = p_tmp%coord(i) % lattice
                    TallyCoord(1)%coord(i)%lattice_x = p_tmp%coord(i) % lattice_x
                    TallyCoord(1)%coord(i)%lattice_y = p_tmp%coord(i) % lattice_y
                    TallyCoord(1)%coord(i)%lattice_z = p_tmp%coord(i) % lattice_z
                enddo
                    i = p_tmp%n_coord
                    TallyCoord(1)%coord(i)%cell           = 0
                    TallyCoord(1)%coord(i)%universe  = p_tmp%coord(i) % universe
                    TallyCoord(1)%coord(i)%lattice   = p_tmp%coord(i) % lattice
                    TallyCoord(1)%coord(i)%lattice_x = p_tmp%coord(i) % lattice_x
                    TallyCoord(1)%coord(i)%lattice_y = p_tmp%coord(i) % lattice_y
                    TallyCoord(1)%coord(i)%lattice_z = p_tmp%coord(i) % lattice_z

            end select
        enddo

        close(rd_tally)


        20 continue
        if(icore==score) print '(A25)', '    TALLY READ COMPLETE...'

    end subroutine



    ! =============================================================================
    ! READ_TH
    ! =============================================================================
    subroutine READ_TH
        use TH_HEADER, only: k_fuel, k_clad, k_cool, h_cool, u_cool, c_cool
        implicit none
        integer:: ii, np
        character(10):: card


        ! read 'mat_temp.inp'
        filename = trim(directory)//'mat_temp.inp'
        open(rd_temp, file=trim(filename),action="read", status="old")

        ! fuel conductivity
        read(rd_temp,*)
        read(rd_temp,*), card, np
        allocate(k_fuel(2,np))
        do ii = 1, np
        read(rd_temp,*), k_fuel(1,ii), k_fuel(2,ii)
        end do
        read(rd_temp,*)

        ! clad conductivity
        read(rd_temp,*)
        read(rd_temp,*), card, np
        allocate(k_clad(2,np))
        do ii = 1, np
        read(rd_temp,*), k_clad(1,ii), k_clad(2,ii)
        end do
        read(rd_temp,*)

        ! coolant conductivity
        read(rd_temp,*)
        read(rd_temp,*), card, np
        allocate(k_cool(2,np))
        do ii = 1, np
        read(rd_temp,*), k_cool(1,ii), k_cool(2,ii)
        end do
        read(rd_temp,*)

        ! coolant enthalpy
        read(rd_temp,*)
        read(rd_temp,*), card, np
        allocate(h_cool(2,np))
        do ii = 1, np
        read(rd_temp,*), h_cool(1,ii), h_cool(2,ii)
        end do
        read(rd_temp,*)

        ! coolant specific heat
        read(rd_temp,*)
        read(rd_temp,*), card, np
        allocate(c_cool(2,np))
        do ii = 1, np
        read(rd_temp,*), c_cool(1,ii), c_cool(2,ii)
        end do
        read(rd_temp,*)

        ! coolant viscosity
        read(rd_temp,*)
        read(rd_temp,*), card, np
        allocate(u_cool(2,np))
        do ii = 1, np
        read(rd_temp,*), u_cool(1,ii), u_cool(2,ii)
        end do

        close(rd_temp)

    end subroutine




    subroutine check_input_result(universes,lattices, cells,surfaces)
        type(surface) :: surfaces(:)
        type(lattice) :: lattices(:)
        type(universe):: universes(0:)
        type(cell)      :: cells(:)
        integer :: i, j, iy, iz

        print *, ' ========== SURFACE CHECK =========='
        print *, ' INDEX     ID      surf_type'
        do i = 1, size(surfaces)
            print '(I5, A10, I10)', i, trim(surfaces(i)%surf_id), surfaces(i)%surf_type
        enddo
        print *, ''
        print *, ''


        !print *, ' ========== CELL CHECK =========='
        !do i = 1, size(cells)
        !    print *, 'cell number :', i
        !    print *, 'cell id:', cells(i)%cell_id!, cells(i)%univ_id, cells(i)%mat_id
        !    print *, 'surf list: ', cells(i)%list_of_surface_IDs(:)
        !    print *, 'neg : ', surfaces(cells(i)%neg_surf_idx(:))%surf_id
        !    print *, 'pos : ', surfaces(cells(i)%pos_surf_idx(:))%surf_id
        !    print *, 'operand : ',cells(i)%operand_flag
        !    print *, 'fill type:', cells(i)%fill_type()
        !    print *, 'material idx', cells(i)%mat_idx
        !    print *, ''
        !    print *, ''
        !enddo


        print *, ' ========== UNIVERSE CHECK =========='
        do i = 0,size(universes(1:))
            print *, ''
            print *, 'univ_id = ', universes(i)%univ_id, '   # of cell', universes(i)%ncell
            do j = 1, universes(i)%ncell
                print '(a4,I2,2A7)', 'cell',j,'    ', cells(universes(i)%cell(j))%cell_id
            enddo
        enddo
        print *, ''
        print *, ''


        print *, ' ========== LATTICE CHECK =========='
        do i = 1, size(lattices)
            print *, ''
            print *, 'lattice id = ', lattices(i)%lat_id
            do iz = 1, lattices(i)%n_xyz(3)
                do iy = 1, lattices(i)%n_xyz(2)
                    print '(<lattices(i)%n_xyz(1)>I3)', (universes(lattices(i)%lat(j,iy,iz))%univ_id, j = 1, lattices(i)%n_xyz(1))
                enddo

                print *, ''
            enddo
        enddo




    end subroutine

    subroutine readandparse(rdf, args, nargs, ierr, curr_line)
        integer, intent(in) :: rdf
        character(len=*),dimension(:),intent(inout) :: args
        integer,intent(inout) :: nargs
        integer,intent(inout) :: ierr
        integer,intent(inout) :: curr_line
        character(len=500) :: str, line
        character(1) :: delims=' '
        integer :: idx, lenline

        str(:) = ''
        do
            idx = len_trim(str)
            call readline(rdf,line,ierr,curr_line)
            lenline=len_trim(line)
            if (lenline==0) exit
            str(idx+1:idx+lenline) = line(1:lenline)
            if (line(lenline:lenline) /= '\') exit
        enddo
        call parse(str,delims,args,nargs)

    end subroutine


    subroutine OptionAndNumber(str, idx, option, num, full)
        character(*), intent(in) :: str
        integer, intent(in) :: idx
        character(1) :: option
        character(*), optional :: full
        character(10) :: strtemp
        integer :: num
        integer :: i, j, strsize
        integer :: idx1, idx2, itemp

        strsize = len(str)
        itemp = 0
        do i = 1, strsize
            if (notanumber(str(i:i))) itemp = itemp + 1

            if (itemp == idx) then
                idx1 = i+1
                option = str(i:i)
                do j = i+1, strsize
                    if (notanumber(str(j:j))) then
                        idx2 = j-1
                        exit
                    end if
                enddo
                read(str(idx1:idx2), *) num
                exit
            endif

        enddo

        if (present(full))    full = str(idx1-1:idx2)


    end subroutine OptionAndNumber

    logical function notanumber(str)
        character(1), intent(in) :: str

        if (str(1:1) /= '0' .and. str(1:1) /= '1' .and. str(1:1) /= '2' .and. str(1:1) /= '3' .and. str(1:1) /= '4' .and. &
            str(1:1) /= '5' .and. str(1:1) /= '6' .and. str(1:1) /= '7' .and. str(1:1) /= '8' .and. str(1:1) /= '9' ) then
            notanumber = .true.
        else
            notanumber = .false.
        endif

    end function


end module
