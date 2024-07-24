
.global _main
.align 2

// CELL_COUNT_1D: amount of cells in a single dimension. The grid is a square, so this is both the rows and cols.
.equ CELL_COUNT_1D, 32
// BODY_CAPACITY: ((CELL_COUNT_1D * CELL_COUNT_1D) + 1)
.equ BODY_CAPACITY, 1025
// MARGIN_DIVISOR: margin_size = cell_size / MARGIN_DIVISOR
.equ MARGIN_DIVISOR, 5
// TIME_STEP_S: the time in seconds, that everything updates in the game by (since it has discrete steps)
.equ TIME_STEP_S, 1
.equ UP, 0
.equ RIGHT, 1
.equ DOWN, 2
.equ LEFT, 3
.equ board_size_1d_offset, 0
.equ board_x_offset_offset, 4
.equ board_y_offset_offset, 8
.equ cell_size_offset, 12
.equ margin_size_offset, 16
.equ tail_offset, 20
.equ head_offset, 22
.equ previous_move_direction_offset, 24
.equ move_direction_offset, 25
.equ body_offset, 26
.equ UP_KEY_CODE, 265
.equ RIGHT_KEY_CODE, 262
.equ DOWN_KEY_CODE, 264
.equ LEFT_KEY_CODE, 263
.equ INITIAL_WINDOW_WIDTH, 640
.equ INITIAL_WINDOW_HEIGHT, 480
// D_REGISTER_BACKUP_SIZE = 0x40
// X_REGISTER_BACKUP_SIZE = 0x40
// FP_AND_LR_SIZE = 0x10
// GAME_STRUCT_SIZE = (4 + 4 + 4 + 4 + 4 + 2 + 2 + 1 + 1 + (((CELL_COUNT_1D * CELL_COUNT_1D) + 1) * 2)) = 0x81c
// STACK_FRAME_SIZE = 0x8ac (round up to multiple of 0x10) = 0x8b0
.equ STACK_FRAME_SIZE, 0x8b0

.extern _InitWindow
.extern _WindowShouldClose
.extern _BeginDrawing
.extern _ClearBackground
.extern _EndDrawing
.extern _CloseWindow
.extern _GetScreenWidth
.extern _GetScreenHeight
.extern _IsWindowReady
.extern _DrawRectangleV
.extern _printf
.extern _GetTime
.extern _SetTargetFPS
.extern _GetKeyPressed

.data
    window_name: .asciz "ASM Snake"
    update_string: .asciz "update\n"
    draw_string: .asciz "draw with delta: %f\n"
    // ABGR (because little endian)
    clear_colour: .4byte 0xFF224466
    empty_cell_colour: .4byte 0xFFDDBB99
    apple_colour: .4byte 0xFF5533BB
    snake_body_colour: .4byte 0xFFAA22CC

.macro CALC_CELL_SIZE, result, scratch, cell_count_1d, board_size_1d, margin_divisor
    fmov \scratch, #1
    fmadd \result, \margin_divisor, \cell_count_1d, \cell_count_1d
    fsub \result, \result, \scratch
    fdiv \result, \margin_divisor, \result
    fmul \result, \result, \board_size_1d
.endm

// increment x, wrapping to keep in range [0, n)
// result in x
// n also modified
.macro INC_CLAMP_ZERO_TO_N, x, n
    add \x, \x, #1
    subs \n, \x, \n
    csel \x, \x, \n, mi
.endm

// decrement x, wrapping to keep in range [0, n)
// result in x
// n also modified
.macro DEC_CLAMP_ZERO_TO_N, x, n
    subs \x, \x, #1
    add \n, \n, \x
    csel \x, \n, \x, mi
.endm

.macro FLERP a, b, t
    // b = b - a
    fsub \b, \b, \a
    // a = t * b' + a = t * (b - a) + a
    fmadd \a, \t, \b, \a
.endm

// update comparison flags for the direction moving. considering wrapping.
// lt => negative direction (left or down)
// eq => not moving in that dimension
// gt => positive direction (right or up)
// s_result: will contain result
// s_scratch_1, s_scratch_2, and s_scratch_3: will be modified. can be equal to s_x and s_next_x, if they can be modified.
// s_x and s_next_x: will not be modified, unless also passed as scratch. the value of the cell and the adjacent cell.
.macro DIRECTION s_x, s_next_x, s_scratch_1, s_scratch_2, s_scratch_3
    fsub \s_scratch_3, \s_x, \s_next_x
    fabs \s_scratch_1, \s_scratch_3
    fmov \s_scratch_2, #1
    fcmp \s_scratch_1, \s_scratch_2
    // if eq, flip sign
    fneg \s_scratch_1, \s_scratch_3
    fcsel \s_scratch_3, \s_scratch_1, \s_scratch_3, eq
    fcmp \s_scratch_3, #0.0
.endm

/*
struct Game {
    F32 board_size_1d; // pixels
    F32 board_x_offset; // pixels
    F32 board_y_offset; // pixels
    F32 cell_size; // pixels
    F32 margin_size; // pixels
    // tail: index of head cell. multiply by 2 to get byte location
    U16 tail;
    // head: index of head cell. multiply by 2 to get byte location
    U16 head;
    U8 move_direction;
    // pairs of U8 for x, y coordinates.
    // one for every cell, + 1 so we can remember where the tail end was last update
    U8 body[((cell_count_1d * cell_count_1d) + 1) * 2];
};
*/

.text
    _main:
        sub sp, sp, STACK_FRAME_SIZE
        stp fp, lr, [sp]
        stp d14, d15, [sp, #0x10]
        stp d12, d13, [sp, #0x20]
        stp d10, d11, [sp, #0x30]
        stp d8, d9, [sp, #0x40]
        stp x25, x26, [sp, #0x50]
        stp x23, x24, [sp, #0x60]
        stp x21, x22, [sp, #0x70]
        stp x19, x20, [sp, #0x80]
        add x20, sp, #0x90
        mov fp, sp

        mov x0, INITIAL_WINDOW_WIDTH
        mov x1, INITIAL_WINDOW_HEIGHT
        adrp x2, window_name@PAGE
        add x2, x2, window_name@PAGEOFF
        bl _InitWindow
        bl _IsWindowReady
        cbz x0, done

        bl _GetScreenWidth
        scvtf s8, x0 // screen width (pixels)

        bl _GetScreenHeight
        scvtf s9, x0 // screen height (pixels)

        fmin s10, s8, s9 // board size 1d (pixels)

        fsub s11, s8, s9
        mov x0, #2
        scvtf s0, x0
        fdiv s11, s11, s0
        scvtf s0, wzr
        fmax s11, s11, s0 // board x offset (pixels)

        fsub s12, s9, s8
        fdiv s12, s12, s0

        fmax s12, s12, s0 // board y offset (pixels)

        mov x0, CELL_COUNT_1D
        scvtf s13, x0 // board cell count 1d

        mov x0, MARGIN_DIVISOR
        scvtf s0, x0 // margin divisor

        CALC_CELL_SIZE s14, s1, s13, s10, s0 // cell size (pixels)

        // margin_size = (board_size_1d - (cell_count_1d * cell_size)) / (cell_count_1d - 1)
        fmsub s15, s13, s14, s10 // board_size_1d - (cell_count_1d * cell_size)
        fmov s1, #1
        fsub s0, s13, s1 // cell_count_1d - 1
        fdiv s15, s15, s0 // margin size

        // board_size_1d , board_x_offset
        stp s10, s11, [x20, board_size_1d_offset]
        // board_y_offset, cell_size
        stp s12, s14, [x20, board_y_offset_offset]
        // margin_size
        str s15, [x20, margin_size_offset]
        // tail
        mov w0, #0
        strh w0, [x20, tail_offset]
        /*
        // head
        mov w0, #1
        strh w0, [x20, head_offset]
        // move direction
        mov w0, RIGHT
        strb w0, [x20, previous_move_direction_offset]
        strb w0, [x20, move_direction_offset]
        mov w0, #16
        mov w1, #17
        // body[0].x
        mov x2, body_offset
        strb w0, [x20, x2]
        // body[0].y
        add x2, x2, #1
        strb w0, [x20, x2]
        // body[1].x
        add x2, x2, #1
        strb w1, [x20, x2]
        // body[1].y
        add x2, x2, #1
        strb w0, [x20, x2]
        */

        // TODO(TB): remove this
        // head
        mov w0, #4
        strh w0, [x20, head_offset]
        // move direction
        mov w0, RIGHT
        strb w0, [x20, previous_move_direction_offset]
        strb w0, [x20, move_direction_offset]
        mov w0, #16
        mov w1, #17
        // body[0].x
        mov x2, body_offset
        strb w0, [x20, x2]
        // body[0].y
        add x2, x2, #1
        strb w0, [x20, x2]
        // body[1].x
        add x2, x2, #1
        strb w1, [x20, x2]
        // body[1].y
        add x2, x2, #1
        strb w0, [x20, x2]
        add w1, w1, #1
        // body[2].x
        add x2, x2, #1
        strb w1, [x20, x2]
        // body[2].y
        add x2, x2, #1
        strb w0, [x20, x2]
        add w0, w0, #1
        // body[3].x
        add x2, x2, #1
        strb w1, [x20, x2]
        // body[3].y
        add x2, x2, #1
        strb w0, [x20, x2]
        add w0, w0, #1
        // body[4].x
        add x2, x2, #1
        strb w1, [x20, x2]
        // body[4].y
        add x2, x2, #1
        strb w0, [x20, x2]

        bl _GetTime
        fmov d8, d0 // last update time
        fmov d9, xzr

        mov w0, #60
        bl _SetTargetFPS

        b draw
    game_loop:
        // handle input
        mov w21, UP_KEY_CODE
        mov w22, RIGHT_KEY_CODE
        mov w23, DOWN_KEY_CODE
        mov w24, LEFT_KEY_CODE
        ldrb w25, [x20, previous_move_direction_offset]
        b input_loop_cond
        input_loop:
            cmp w0, w21
            b.eq 1f
            cmp w0, w22
            b.eq 2f
            cmp w0, w23
            b.eq 3f
            cmp w0, w24
            b.eq 4f
            b 5f
            1: // up
                cmp w25, DOWN
                b.eq 5f

                mov w0, UP
                strb w0, [x20, move_direction_offset]
                b 5f
            2: // right
                cmp w25, LEFT
                b.eq 5f

                mov w0, RIGHT
                strb w0, [x20, move_direction_offset]
                b 5f
            3: // down
                cmp w25, UP
                b.eq 5f

                mov w0, DOWN
                strb w0, [x20, move_direction_offset]
                b 5f
            4: // left
                cmp w25, RIGHT
                b.eq 5f

                mov w0, LEFT
                strb w0, [x20, move_direction_offset]
            5: // done

        input_loop_cond:
            bl _GetKeyPressed
            cbnz w0, input_loop

        // update
        bl _GetTime

        // d9 = time delta
        fsub d9, d0, d8
        // d10 = time step s
        mov x0, TIME_STEP_S
        scvtf d10, x0

        b update_loop_condition
        update_loop:
            ldrb w0, [x20, move_direction_offset]
            strb w0, [x20, previous_move_direction_offset]
            //adrp x0, update_string@PAGE
            //add x0, x0, update_string@PAGEOFF
            //bl _printf

            // x21 = body
            add x21, x20, body_offset
            // w22 = head
            ldrh w22, [x20, head_offset]
            // w23 = move_direction
            ldrb w23, [x20, move_direction_offset]
            // w24 = index
            mov w0, #2
            mul w24, w22, w0
            // w25 = x
            ldrb w25, [x21, x24]
            // w26 = y
            add w24, w24, #1
            ldrb w26, [x21, x24]

            // w24 = new head x index
            mov w1, BODY_CAPACITY
            mov w24, w22
            INC_CLAMP_ZERO_TO_N w24, w1
            mul w24, w24, w0

            mov w0, #4
            mul w23, w23, w0
            adrp x1, jt@PAGE
            add x1, x1, jt@PAGEOFF
            add x1, x1, x23
            // x0 = CELL_COUNT_1D
            mov x0, CELL_COUNT_1D
            br x1
            jt:
                b direction_up
                b direction_right
                b direction_down
                b direction_left
            direction_up:
                mov w1, w0
                DEC_CLAMP_ZERO_TO_N w26, w1
                b direction_done
            direction_right:
                mov w1, w0
                INC_CLAMP_ZERO_TO_N w25, w1
                b direction_done
            direction_down:
                mov w1, w0
                INC_CLAMP_ZERO_TO_N w26, w1
                b direction_done
            direction_left:
                mov w1, w0
                DEC_CLAMP_ZERO_TO_N w25, w1
            direction_done:

            // update new head x and y in body
            strb w25, [x21, x24]
            add w24, w24, #1
            strb w26, [x21, x24]

            // x0 = BODY_CAPACITY
            mov x0, BODY_CAPACITY

            // update head
            mov w1, w0
            INC_CLAMP_ZERO_TO_N w22, w1
            strh w22, [x20, head_offset]

            // TODO(TB): if NOT hit an apple
            // update tail
            // w22 = tail
            ldrh w22, [x20, tail_offset]
            INC_CLAMP_ZERO_TO_N w22, w0
            strh w22, [x20, tail_offset]

            fadd d8, d8, d10
            fsub d9, d9, d10
        update_loop_condition:
            fcmp d9, d10
            b.gt update_loop

        fdiv d9, d9, d10

    draw:
        stp d8, d9, [sp, #-0x10]!

        //str d9, [sp, #-0x10]!
        //adrp x0, draw_string@PAGE
        //add x0, x0, draw_string@PAGEOFF
        //bl _printf
        //add sp, sp, #0x10

        bl _BeginDrawing
        adrp x0, clear_colour@PAGE
        add x0, x0, clear_colour@PAGEOFF
        ldr x0, [x0]
        bl _ClearBackground

        // cell colour
        adrp x19, empty_cell_colour@PAGE
        add x19, x19, empty_cell_colour@PAGEOFF
        ldr x19, [x19]

        // draw grid
        // s8 = board_cell_count_1d
        // s9 = x_coord
        // s10 = board_x_offset
        // s11 = board_y_offset
        // s12 = cell_size
        // s13 = cell_size + margin_size
        // s14 = x_index
        // s15 = y_index
        scvtf s0, wzr
        fmov s14, s0 // x_index
        // board_x_offset, board_y_offset
        ldp s10, s11, [x20, board_x_offset_offset]
        // cell_size, margin_size
        ldp s12, s13, [x20, cell_size_offset]
        // cell_size + margin_size
        fadd s13, s13, s12
        mov w0, CELL_COUNT_1D
        scvtf s8, w0 // board cell count 1d
        b x_loop_cond

    x_loop:
        scvtf s0, wzr
        fmov s15, s0 // y_index
        // s9 = x_coord (pixels)
        fmadd s9, s14, s13, s10 // x_index * (cell_size + margin_size) + board_x_offset
        b y_loop_cond
        y_loop:
            // x
            fmov s0, s9

            // y
            // s1 = y_coord (pixels)
            fmadd s1, s15, s13, s11 // y_index * (cell_size + margin_size) + board_y_offset

            // width
            fmov s2, s12
            // height
            fmov s3, s12
            // colour
            mov x0, x19
            // draw
            bl _DrawRectangleV

            // inc y_index
            mov w0, #1
            scvtf s0, w0
            fadd s15, s15, s0
        y_loop_cond:
            fcmp s15, s8
            b.lt y_loop

        // inc x_index
        mov w0, #1
        scvtf s0, w0
        fadd s14, s14, s0
    x_loop_cond:
        fcmp s14, s8
        b.lt x_loop

    ldp d8, d9, [sp], #0x10

    stp d8, d9, [sp, #-0x10]!

    // TODO(TB): will this clear the other bits in the x register?
    // w21 = head
    ldrh w21, [x20, head_offset]
    // w22 = tail
    ldrh w22, [x20, tail_offset]
    // s10 = cell_size
    ldp s10, s11, [x20, cell_size_offset]
    // s11 = cell_size_plus_margin_size
    fadd s11, s11, s10
    // s12 = board_x_offset
    // s13 = board_y_offset
    ldp s12, s13, [x20, board_x_offset_offset]
    // s14 = dt * cell_size
    fcvt s9, d9
    fmul s14, s9, s10
    // s15 = (1 - dt) * cell_size
    fsub s15, s10, s14
    // body
    add x23, x20, body_offset

    // draw snake body (excluding head)
    adrp x24, snake_body_colour@PAGE
    add x24, x24, snake_body_colour@PAGEOFF
    ldr x24, [x24]


    // draw tail most cell
    mov w0, #2
    mul w1, w0, w22
    ldrb w2, [x23, x1]
    // x_index
    scvtf s0, w2
    add w1, w1, #1
    ldrb w2, [x23, x1]
    // y_index
    scvtf s1, w2
    // increment tail
    mov w1, BODY_CAPACITY
    INC_CLAMP_ZERO_TO_N w22, w1
    mul w1, w0, w22
    ldrb w2, [x23, x1]
    // next_x_index
    scvtf s2, w2
    add w1, w1, #1
    ldrb w2, [x23, x1]
    // next_y_index
    scvtf s3, w2

    DIRECTION s0, s2, s2, s5, s6
    // s4 = x_offset
    fmov s7, wzr
    fcsel s4, s14, s7, gt
    // s2 = width_offset
    fcsel s2, s14, s7, ne

    DIRECTION s1, s3, s3, s5, s6
    // s5 = y_offset
    fcsel s5, s14, s7, gt
    // s3 = height_offset
    fcsel s3, s14, s7, ne

    // x
    fmadd s0, s0, s11, s12
    fadd s0, s0, s4
    // y
    fmadd s1, s1, s11, s13
    fadd s1, s1, s5
    // width
    fsub s2, s10, s2
    // height
    fsub s3, s10, s3
    // colour
    mov x0, x24
    // draw
    bl _DrawRectangleV

    b draw_body_loop_condition

    draw_body_loop:
        mov w0, #2
        mul w0, w0, w22
        ldrb w1, [x23, x0]
        // x_index
        scvtf s0, w1
        add w0, w0, #1
        ldrb w1, [x23, x0]
        // y_index
        scvtf s1, w1
        // x
        fmadd s0, s0, s11, s12
        // y
        fmadd s1, s1, s11, s13
        // width
        fmov s2, s10
        // height
        fmov s3, s10
        // colour
        mov x0, x24

        bl _DrawRectangleV

        mov w0, BODY_CAPACITY
        INC_CLAMP_ZERO_TO_N w22, w0
    draw_body_loop_condition:
        cmp w22, w21
        b.ne draw_body_loop

    // draw head
    mov w0, #2
    mul w1, w0, w22
    ldrb w2, [x23, x1]
    // x_index
    scvtf s0, w2
    add w1, w1, #1
    ldrb w2, [x23, x1]
    // y_index
    scvtf s1, w2
    mov w1, BODY_CAPACITY
    DEC_CLAMP_ZERO_TO_N w22, w1
    mul w1, w0, w22
    ldrb w2, [x23, x1]
    // prev_x_index
    scvtf s2, w2
    add w1, w1, #1
    ldrb w2, [x23, x1]
    // prev_y_index
    scvtf s3, w2

    DIRECTION s2, s0, s2, s4, s5
    fmov s7, wzr
    // x_offset
    fcsel s2, s15, s7, lt
    // width_offset
    fcsel s4, s15, s7, ne

    DIRECTION s3, s1, s3, s5, s6
    // y_offset
    fcsel s3, s15, s7, lt
    // height_offset
    fcsel s5, s15, s7, ne

    // x
    fmadd s0, s0, s11, s12
    fadd s0, s0, s2
    // y
    fmadd s1, s1, s11, s13
    fadd s1, s1, s3
    // width
    fsub s2, s10, s4
    // height
    fsub s3, s10, s5
    // colour
    mov x0, x24
    // draw
    bl _DrawRectangleV

    bl _EndDrawing
    ldp d8, d9, [sp], #0x10

    game_loop_condition:
        bl _WindowShouldClose
        cbz x0, game_loop
    done:
        bl _CloseWindow
        ldp fp, lr, [sp]
        ldp d14, d15, [sp, #0x10]
        ldp d12, d13, [sp, #0x20]
        ldp d10, d11, [sp, #0x30]
        ldp d8, d9, [sp, #0x40]
        ldp x25, x26, [sp, #0x50]
        ldp x23, x24, [sp, #0x60]
        ldp x21, x22, [sp, #0x70]
        ldp x19, x20, [sp, #0x80]
        add sp, sp, STACK_FRAME_SIZE
        mov x0, xzr
        ret
