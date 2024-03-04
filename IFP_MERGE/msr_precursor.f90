module msr_prec
use constants, only: pi
use bank_header
use randoms,   only: rang
use variables, only: flowtype

contains
subroutine msr_dnp_track(xyz, t_emit)
    implicit none
    real(8), intent(inout) :: xyz(3)   !> Position of prec. [cm]
    real(8), intent(in)    :: t_emit   !> Time to emit [sec]
    select case(flowtype)
    case(1)
        call prec_rz(xyz, t_emit)
    case default
    end select
end subroutine
subroutine prec_rz(xyz, t_emit)
    use variables, only : nr, nz, &
        axial_axis, &
        velocity_r, velocity_z, active_r, active_z, &
        riser_r, &
        t_recirc, &
        MSR_leak, &
        k_col
    implicit none
    real(8), intent(inout) :: xyz(3)   !> Position of prec. [cm]
    real(8), intent(in)    :: t_emit   !> Time to emit [sec]
    real(8) :: pos(3)                  !> Position wrt Axial_axis
    real(8) :: t_left                  !> Time left to emit [sec]
    real(8) :: r, z, cost, sint, theta !> R, Z, cos(t), sin(t) [cm]
    integer :: i, ii, j, jj            !> Random Indexes
    real(8) :: vz, vr                  !> v along radial and axial [cm/s]
    real(8) :: tr, tz                  !> Time to reach radial/axial bound [s]


    ! === OUTLINE ===
    ! 0. T_LEFT = t_emit
    t_left = t_emit

    ! 1. Convert xyz to rz + theta (+ END COND)
    pos = xyz ; pos(1:2) = pos(1:2) - axial_axis(1:2)
    r = sqrt(pos(1)**2+pos(2)**2)
    if ( r > active_r(nr+1) ) return

    z = pos(3)
    if ( z < active_z(1) .or. z > active_z(nz+1) ) return

    cost = pos(1) / r;  sint = pos(2) / r

    ! 2. (r,z) in [r(i-1),ri] and [z(j-1),zj]
    ! Find mesh
    do ii = 1, nr
        if( r < active_r(ii+1) ) then
            i = ii; exit
        endif
    enddo

    do jj = 1, nz
        if( z < active_z(jj+1) ) then
            j = jj; exit
        endif
    enddo

    ! DO while alive
    do
        if(t_emit> 5D2) print '(I,A7,5F10.3)', bank_idx, 'RZT', r, z, cost, sint, t_left

        ! 3. vr, vz = v(i,j)
        vr = velocity_r(i,j); vz = velocity_z(i,j)
        ! 3-1. IF r out of active core: vr = 0d0
        if( r == 0d0 .and. vr < 0d0 ) vr = 0d0
        if( r == active_r(nr+1) .and. vr > 0d0 ) vr = 0d0
        if( z == 0d0 .and. vz < 0d0 ) vz = 0d0
        if( z == active_z(nz+1) .and. vz > 0d0 ) vz = 0d0
    
        ! 3-2. IF vr = vz = 0, TERMINATE
        if ( vr == 0d0 .and. vz == 0d0 ) then
            xyz(1) = cost * r + axial_axis(1)
            xyz(2) = sint * r + axial_axis(2)
            xyz(3) = z
            if(t_emit > 5D2) print '(I,A7,5F10.3)', bank_idx, 'STUCK', r, z, cost, sint, t_left
            return
        endif
        
        ! 4-0. tr = tz = 0
        tr = 0d0; tz = 0d0
        ! 4-1. IF abs(vr) > 0
        ! 4-1-1.  tr = (ri-r)/vr
        if( vr > 0 ) then
            tr = (active_r(i+1) - r) / vr
        elseif ( vr < 0 ) then
            tr = (r - active_r(i)) / abs(vr)
        endif
    
        ! 4-2. IF abs(vz) > 0
        ! 4-2-1.  tz = (zi-z)/vz
        if( vz > 0 ) then
            tz = (active_z(j+1) - z) / vz
        elseif( vz < 0 ) then
            tz = (z - active_z(j)) / abs(vz)
        endif
    
        ! 4-3. Set zero time larger than other
        ! NOTE) tr = tz = 0 is impossible... in theory
        if( tr == 0d0 ) tr = tz + 1d0
        if( tz == 0d0 ) tz = tr + 1d0 
    
        ! 5. IF (tleft < tr and tz)
        if ( t_left < tr .and. t_left < tz ) then
            ! 5-1. rz = r+tleft*vr, z+tleft*vz
            r = r + t_left * vr
            z = z + t_left * vz
            ! 5-2. Convert rtz to xyz => DONE
            xyz(1) = cost * r + axial_axis(1)
            xyz(2) = sint * r + axial_axis(2)
            xyz(3) = z
            if(t_emit>5D2) print '(I,A7,5F10.3)', bank_idx, 'EMIT', r, z, cost, sint, t_left
            return
    
        ! 6. ELSE if (tr < tz)
        elseif ( tr < tz ) then
            ! 6-1. rz = r+tr*vr (=ri), z+tr*vz
            if( vr > 0d0 ) then
                r = active_r(i+1)
            elseif ( vr < 0d0 ) then
                r = active_r(i)
            endif
            z = z + tr * vz
            ! 6-2. t_left = t_left - tr
            t_left = t_left - tr
            ! 6-3. IF r <= 0 || r >= active_r(nr+1)
            ! 6-3-1.  r = 0 || r = active_r(nr+1)
            if ( r <= 0d0 ) then
                r = 0d0
            elseif ( r >= active_r(nr+1) ) then
                r = active_r(nr+1)
            ! 6-4. ELSE
            else
            ! 6-4-1.  i = i +- 1
                i = i + sign(1d0, vr)
                if(i==0) print *, 'WTF', r, z, i, j, vr, vz, tr, tz, t_left
            endif
    
        ! 7. ELSE (tz > tr)
        elseif ( tz < tr ) then
            ! 7-1. rz = r+tz*vr, z+tz*vz (=zi)
            r = r + tz * vr
            if( vz > 0d0 ) then
                z = active_z(j+1)
            elseif ( vz < 0d0 ) then
                z = active_z(j)
            endif
            ! 7-2. t_left = t_left - tz
            t_left = t_left - tz
            ! 7-3. IF z >= active_z(nz+1)
            if ( z >= active_z(nz+1) ) then
                ! 7-3-1.  IF r > riser_r !> Trapped
                if ( r > riser_r ) then
                    ! 7-3-1-1.   z = active_z(nz+1)
                    z = active_z(nz+1)
                endif
            ! 7-4. ELSEIF z <= active_z(1)
            elseif ( z <= active_z(1) ) then
                ! 7-4-1.  z = active_z(1)
                z = active_z(1)
            ! 7-5. ELSE
            else
                ! 7-5-1.  j = j +- 1
                j = j + sign(1d0, vz)
            endif
        endif

        ! 8. If Reaches TOP & Inside riser
        if ( r < riser_r .and. z >= active_z(nz+1) ) then
            if(t_emit>5D2) print '(I,A7,5F10.3)', bank_idx, 'TOP', r, z, cost, sint, t_left
            ! 8-1.   IF t_left < t_recirc
            if( t_left <= t_recirc ) then
                ! 8-1-1.    KILL and DONE
                bank_idx = bank_idx - 1
                MSR_leak = MSR_leak + 1
                if(t_emit>5D2) print '(I,A7,5F10.3)', bank_idx, 'LEAK', r, z, cost, sint, t_left
                return
            ! 8-2.   ELSE
            else
                ! 8-2-1.    t_left -= t_recirc
                t_left = t_left - t_recirc
                ! 8-2-2.    j = 1, z = 0
                j = 1; z = 0d0
                ! 8-2-3.    sample r and theta randomly
                r = active_r(nr+1) * sqrt(rang())
                do ii = 1, nr
                    if( r < active_r(ii+1) ) then
                        i = ii; exit
                    endif
                enddo
                theta = 2d0 * pi * rang()
                cost = cos(theta); sint = sin(theta);
                if(t_emit>5D2) print '(I,A7,5F10.3)', bank_idx, 'RECIRC', r, z, cost, sint, t_left
            endif
        endif
    enddo 
end subroutine prec_rz
end module
