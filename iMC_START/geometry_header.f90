module geometry_header
    use constants 
    use surface_header
    use omp_lib
    
    implicit none
    
    integer :: n_universe
    integer :: n_cell
    integer :: n_surface
    integer :: base_univ = 0
    
    integer :: isize
    
    
    
!    Type :: surf_block
!        logical :: positive                            !> positive direction  
!        integer :: operand_flag                        !> and / or
!        logical :: inside
!        integer, allocatable :: neg_surf_idx(:), pos_surf_idx(:)
!    end Type
    
    ! ======================== CELL DATA SECTION ======================== !
    !> GENERAL CELL TYPE =============
    Type :: Cell
        character(20)  :: cell_id     !> unique cell index (from input)
        integer        :: idx         !> cell index in the cells(:) array
        integer        :: univ_id
        !character(20) :: mat_id      !> material ID filling this cell
                                      !> if imat = 0, information of fill must be provided.
        integer        :: mat_idx
        integer        :: fill        !> fill = universe / lattice index filling this cell
        !class(Universe), pointer :: univ_in_cell
        
        integer         :: nsurf      !> number of surfaces of this cell
        integer         :: filltype
        integer         :: dtmc = 0
        character(20), allocatable :: list_of_surface_IDs(:)
        integer, allocatable :: neg_surf_idx(:), pos_surf_idx(:)
        
        real(8), allocatable :: translation(:)
        !type(NeighboringCellStruct), allocatable(:) :: NeighboringCells
        
        
        integer :: operand_flag       !> and -> 1 / or -> -1 / default = 0 
!        type(surf_block), allocatable :: surf_blk(:)
    contains 
        procedure :: fill_type => cell_fill
    End Type
    type(Cell), allocatable, target :: cells(:), cells_temp(:)
    type(Cell) :: obj_cell
    
    ! ======================== UNIVERSE DATA SECTION ======================== !
    !> GENERAL UNIVERSE TYPE =============
    
    Type :: Universe
        integer :: univ_type          !> 0 : pure universe  
                                      !> 1 : pin universe
        integer :: univ_id            !> Unique ID
        real(8) :: xyz(3)             !> Universe translation 
        integer :: ncell
        real(8), allocatable :: r(:)
        integer, allocatable :: cell(:)
    contains
        procedure :: initialize
    End Type
    
    type(Universe), allocatable, target :: universes(:), universes_temp(:)
    type(Universe) :: obj_univ
    type(Universe), pointer :: univptr
    
    
    type :: Lattice
        integer :: lat_id
        integer :: lat_type                !> 1 :: rectlinear lattice
                                           !> 2 :: vertical hexgon lattice
                                           !> 3 :: horizontal hexgon lattice
        real(8) :: xyz(3)                  !> Universe translation 
        real(8) :: xyz0(3)                 !> starting coordinates
        integer :: n_xyz(3)                !> no of repetitions in x y direction
        integer, allocatable :: lat(:,:,:) !> index in the universes array
        real(8) :: pitch(3)
        
    endtype
    type(lattice), allocatable, target :: lattices(:), lattices_temp(:)
    type(lattice)  :: obj_lat
    type(lattice), pointer :: lat_ptr
    
    real(8),allocatable :: sgrid(:)
    
    contains 
    !=============================================================================
    ! Define miscel. geometry subroutines here 

    
    function find_univ_idx(this, univ_id) result (idx)
        type(universe) :: this(0:)
        integer :: univ_id , i ,idx
        !print *, 'WTF', size(this), univ_id
        do i = 1, size(this)-1
            if (this(i)%univ_id == univ_id) then 
                idx = i
                goto 1
            endif
        enddo 
        print *, "no such universe id : ", univ_id 
        stop 
1        continue
    end function 
    
    
    function find_cell_idx(this, cell_id) result (idx)
        type(cell) :: this(:)
        integer :: i, idx, n 
        character(*) :: cell_id
        
        n = size(this)
        do i = 1, n
            if (this(i)%cell_id == cell_id) then 
                idx = i 
                goto 2
            endif
        enddo 
        print *, "no such cell id : ", cell_id 
        stop 
2        continue
    end function 
    
    function find_lat_idx(this, lat_id) result (idx)
        type(lattice) :: this(:)
        integer :: i, idx, n 
        integer :: lat_id
        
        n = size(this)
        do i = 1, n
            if (this(i)%lat_id == lat_id) then 
                idx = i 
                goto 3
            endif
        enddo 
        print *, "no such lattice id : ", lat_id 
        stop 
3        continue
    end function 
    !===============================================================================
    ! LATTICE_COORD determins the xyz position of the repeted universe in the given 
    ! lattice geometry 
    !===============================================================================
    function lattice_coord (this, xyz0) result(coord_lat)
        !use variables, only: latidx
        implicit none
        type(Lattice) :: this                !> targetted lattice object
        real(8), dimension(3) :: xyz0         !> xyz position of particle in the universe
        real(8), dimension(3) :: xyz_tr        !> 
        integer, dimension(3) :: coord_lat    !> position among the repeted univs
        integer :: i, j, idx, n

        ! previous
!        xyz_tr(:) = xyz0(:) - this%xyz(:)
!        
!        do i = 1, 3
!            if (mod(this%n_xyz(i),2)==0) then  !> both even 
!                coord_lat(i) = floor(xyz_tr(i)/this%pitch(i)) + (real(this%n_xyz(i),8)/2) + 1
!            else
!                coord_lat(i) = floor((xyz_tr(i)/this%pitch(i))+0.5) + ceiling(real(this%n_xyz(i),8)/2)
!            endif
!        enddo 
!
!        do i = 1, 3
!            if (coord_lat(i).le.0) coord_lat(i) = 1
!            if (coord_lat(i).gt.this%n_xyz(i)) coord_lat(i) = this%n_xyz(i)
!        enddo 

        ! new
        coord_lat(:) = floor((xyz0(:)-this%xyz0(:))/this%pitch(:))+1

        do i = 1, 3
            if (coord_lat(i).le.0) coord_lat(i) = 1
            if (coord_lat(i).gt.this%n_xyz(i)) coord_lat(i) = this%n_xyz(i)
        enddo 

        !latidx = coord_lat
        !if ( curr_cyc > 5 ) print'(i3,a,3i6)', omp_get_thread_num(), "lat", latidx
        
    end function 
    
        
    subroutine initialize(this)
    
        class(Universe) :: this
        
        this%univ_type   = 0
        this%univ_id     = -1                           
        this%xyz(:)      = 0                 
        this%ncell       = 0 
        deallocate(this%r)
        
    end subroutine initialize
    
    function cell_fill(this) result(fill_type)
        class(cell) :: this
        integer :: i, idx, fill_type
        
        if (this%fill < 0) then 
            fill_type = FILL_MATERIAL
        elseif (in_the_list_univ(universes, this%fill)) then 
            fill_type = FILL_UNIVERSE
        elseif (in_the_list_lat(lattices, this%fill)) then
            fill_type = FILL_LATTICE
        else 
            print *, 'ERROR : WRONG SHIT FILLING THIS CELL'
            stop
        endif
        
    end function
    
    
    function in_the_list_univ (this, name) result(in_the_list)
        class(universe) :: this(:)
        integer :: name
        integer :: i, n
        logical :: in_the_list
        
        in_the_list = .false.
        
        n = size(this) 
        do i = 1, n
            if (this(i)%univ_id == name) then 
                in_the_list = .true.
                exit
            endif 
        enddo 
    end function    
    
    function in_the_list_lat (this, name) result(in_the_list)
        class(lattice) :: this(:)
        integer :: name
        integer :: i, n
        logical :: in_the_list
        
        in_the_list = .false.
        
        n = size(this) 
        do i = 1, n
            if (this(i)%lat_id == name) then 
                in_the_list = .true.
                exit
            endif 
        enddo 
        
    end function
    
    
    function get_local_xyz(this, upper_xyz, i_xyz) result(local_xyz)
        type(lattice) :: this 
        real(8) :: upper_xyz(3), local_xyz(3), d_xyz(3), d_xy(2)
        real(8) :: val
        integer :: i, i_xyz(3)
        
        if (this%lat_type == 1) then 
            do i = 1, 3
                if (mod(this%n_xyz(i),2)==0) then 
                    d_xyz(i) = (i_xyz(i)-(real(this%n_xyz(i),8)/2) - 0.5)*this%pitch(i)
                else 
                    d_xyz(i) = (i_xyz(i)-ceiling((real(this%n_xyz(i),8)/2)))*this%pitch(i)
                endif
            enddo 
            
        elseif (this%lat_type == 2) then ! vertical hex 
            
            val = sqrt(3.0)*0.5
            d_xy(1) = (i_xyz(1)-ceiling((real(this%n_xyz(1),8)/2)))*this%pitch(1)
            d_xy(2) = (i_xyz(2)-ceiling((real(this%n_xyz(2),8)/2)))*this%pitch(2)*val
            
            d_xyz(1) =  d_xy(1)*val + d_xy(2)*0.5
            d_xyz(2) = -d_xy(1)*0.5 + d_xy(2)*val
            if (mod(this%n_xyz(3),2)==0) then 
                d_xyz(3) = (i_xyz(3)-(real(this%n_xyz(3),8)/2) - 0.5)*this%pitch(3)
            else 
                d_xyz(3) = (i_xyz(3)-ceiling((real(this%n_xyz(3),8)/2)))*this%pitch(3)
            endif
            
        elseif (this%lat_type == 3) then ! horizontal hex 
            val = sqrt(3.0)*0.5
            d_xyz(1) = (i_xyz(1)-ceiling((real(this%n_xyz(1),8)/2)))*this%pitch(1)
            d_xyz(2) = (i_xyz(2)-ceiling((real(this%n_xyz(2),8)/2)))*this%pitch(2)*val
            if (mod(this%n_xyz(3),2)==0) then 
                d_xyz(3) = (i_xyz(3)-(real(this%n_xyz(3),8)/2) - 0.5)*this%pitch(3)
            else 
                d_xyz(3) = (i_xyz(3)-ceiling((real(this%n_xyz(3),8)/2)))*this%pitch(3)
            endif
        endif 
        
        do i = 1, 3
            local_xyz(i) = upper_xyz(i)-d_xyz(i)
        enddo 
        
    end function

    subroutine cell_distance (this,xyz, uvw, surflist, d_surf, idx_surf)
        implicit none
        type(cell) :: this
        type(surface) :: surflist(:)
        real(8) :: xyz(3), uvw(3) 
        real(8) :: d_surf, d_temp 
        integer :: i, n, idx_surf
        
        d_surf = INFINITY; idx_surf = 0 
        
        n = size(this%pos_surf_idx)
        do i = 1, n
            call surf_select(surflist(this%pos_surf_idx(i)),xyz, uvw, d_temp) 
            
            if (d_temp < d_surf) then 
                d_surf = d_temp 
                idx_surf = this%pos_surf_idx(i)
            endif
        enddo 
        n = size(this%neg_surf_idx) 
        do i = 1, n
            call surf_select(surflist(this%neg_surf_idx(i)),xyz, uvw, d_temp) 
            if (d_temp < d_surf) then 
                d_surf = d_temp 
                idx_surf = this%neg_surf_idx(i)
            endif
        enddo 
    end subroutine 
    
    
    subroutine lat_distance (this,surflist, xyz, uvw,i_xyz, d_surf, idx_surf)
        type(lattice), intent(in) :: this
        type(surface), intent(in) :: surflist(:)
        integer, intent(in) :: i_xyz(3)
        !integer, intent(inout) :: i_xyz_out(3)
        real(8), intent(in) :: xyz(3), uvw(3)
        real(8) :: xyz_(3)
        real(8) :: d_surf, d_temp
        integer :: i,j, ix, iy, iz, dxyz(3), nxyz(3)
        integer :: idx_temp, idx_surf
		real(8) :: dist(2)
        integer :: idx(2)

        
        
        d_surf = INFINITY
        
        ! ================== 수 정 사 항 ==================
        ! 1. 자기 (ix,iy,iz)에서 d_surf 찾기 
        ! if (d_surf < toolong) then 
        !     2. uvw 방향의 pin 탐색 
        !    if (allocated(univ(j)%r)) then !> pin univ 
        !        3.1 제일 바깥 cell에서만 찾기 
        !    else 
        !        3.2 밑에서 하는 대로 
        !    endif 
        ! endif  
        
        ix = i_xyz(1); iy = i_xyz(2); iz = i_xyz(3); 
        j = this%lat(ix,iy,iz)
        do i = 1, universes(j)%ncell
            associate(c => cells(universes(j)%cell(i)))
                if(cell_contains_xyz(c, xyz)) then 
                    call cell_distance(c,xyz, uvw, surflist, d_temp, idx_temp)
                    if (d_surf > d_temp) then 
                        d_surf = d_temp
                        idx_surf = idx_temp
                    endif 
                endif
            end associate
        enddo 

!        xyz_(:) = xyz(:) + d_surf*uvw(:) 
!        do i = 1, 3 
!            if (abs(xyz_(i)) > this%pitch(i)/2.0) d_surf = INFINITY
!        enddo 
        if (d_surf < TOOLONG) return
        
        if (this%lat_type == 1) then ! rectilinear 
            do i = 1, 3 
                dxyz(i) = int(sign(1.0d0, uvw(i)))
                if (dxyz(i) > 0) then 
                    nxyz(i) = this%n_xyz(i)
                else 
                    nxyz(i) = 1
                endif 
            enddo 
        elseif (this%lat_type == 2) then 
            ! TODO
        
        elseif (this%lat_type == 3) then 
            ! TODO
        
        
        endif
        
        do iz = i_xyz(3), nxyz(3), dxyz(3)
            do iy = i_xyz(2), nxyz(2), dxyz(2)
                do ix = i_xyz(1), nxyz(1), dxyz(1)
                    xyz_(1) = xyz(1) + this%pitch(1)*(i_xyz(1)-ix)
                    xyz_(2) = xyz(2) + this%pitch(2)*(i_xyz(2)-iy)
                    xyz_(3) = xyz(3) + this%pitch(3)*(i_xyz(3)-iz)
                    j = this%lat(ix,iy,iz)
                    
                    if (allocated(universes(j)%r)) then 
                        associate(c => cells(universes(j)%cell(universes(j)%ncell)))
                            if(cell_contains_xyz(c, xyz_)) then 
                                call cell_distance(c,xyz_, uvw, surflist, d_temp, idx_temp)
                                if (d_surf > d_temp) then 
                                    d_surf = d_temp
                                    idx_surf = idx_temp
                                endif 
                            endif
                        end associate
                    else 
                        do i = 1, universes(j)%ncell
                            associate(c => cells(universes(j)%cell(i)))
                                if(cell_contains_xyz(c, xyz_)) then 
                                    call cell_distance(c,xyz_, uvw, surflist, d_temp, idx_temp)
                                    if (d_surf > d_temp) then 
                                        d_surf = d_temp
                                        idx_surf = idx_temp
                                    endif 
                                endif
                            end associate
                        enddo 
                    endif
                enddo 
            enddo 
        enddo 
        
    end subroutine
    
    
    
    
    function cell_contains_xyz(c, xyz) result(in_cell)
        type(Cell), intent(in) :: c
        real(8),    intent(in) :: xyz(3)
        logical :: in_cell
        integer :: i,j,n
        
        if (c%operand_flag >= 0) then   !> and 
            in_cell = .true.
            n =size(c%neg_surf_idx)
            do i = 1, n
                if (surf_neg_or_pos(surfaces(c%neg_surf_idx(i)),xyz) == .false.) in_cell = .false.
            enddo
            n = size(c%pos_surf_idx)
            do i = 1, n
                if (surf_neg_or_pos(surfaces(c%pos_surf_idx(i)), xyz) == .true.) in_cell = .false.
            enddo
        else !> or
            in_cell = .false.
            n = size(c%neg_surf_idx)
            do i = 1, n
                if (surf_neg_or_pos(surfaces(c%neg_surf_idx(i)),xyz) == .true.) in_cell = .true.
            enddo
            n = size(c%pos_surf_idx)
            do i = 1, n
                if (surf_neg_or_pos(surfaces(c%pos_surf_idx(i)), xyz) == .false.) in_cell = .true.
            enddo
        endif
        
    end function     !=============================================================================
    
end module
