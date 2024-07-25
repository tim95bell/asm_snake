
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
.equ clear_colour_offset, 0
.equ empty_cell_colour_offset, 8
.equ apple_colour_offset, 16
.equ snake_colour_offset, 24
.equ board_size_1d_offset, 32
.equ board_x_offset_offset, 36
.equ board_y_offset_offset, 40
.equ cell_size_offset, 44
.equ margin_size_offset, 48
.equ tail_offset, 52
.equ head_offset, 54
.equ previous_move_direction_offset, 56
.equ move_direction_offset, 57
.equ body_offset, 58
.equ UP_KEY_CODE, 265
.equ RIGHT_KEY_CODE, 262
.equ DOWN_KEY_CODE, 264
.equ LEFT_KEY_CODE, 263
.equ INITIAL_WINDOW_WIDTH, 640
.equ INITIAL_WINDOW_HEIGHT, 480
// D_REGISTER_BACKUP_SIZE = 0x50
// X_REGISTER_BACKUP_SIZE = 0x40
// FP_AND_LR_SIZE = 0x10
// GAME_STRUCT_SIZE = (8 + 8 + 8 + 8 + 4 + 4 + 4 + 4 + 4 + 2 + 2 + 1 + 1 + (((CELL_COUNT_1D * CELL_COUNT_1D) + 1) * 2)) = 0x83c
// STACK_FRAME_SIZE = 0x8dc (round up to multiple of 0x10) = 0x8e0
.equ STACK_FRAME_SIZE, 0x8e0

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
.extern _GetTime
.extern _SetTargetFPS
.extern _GetKeyPressed

.data
    window_name: .asciz "ASM Snake"
    // ABGR (because little endian)
    clear_colour: .4byte 0xFF224466
    empty_cell_colour: .4byte 0xFFDDBB99
    apple_colour: .4byte 0xFF5533BB
    snake_colour: .4byte 0xFFAA22CC

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
    // b` = b - a
    fsub \b, \b, \a
    // a = t * b` + a = t * (b - a) + a
    fmadd \a, \t, \b, \a
.endm

// update comparison flags for the direction moving. considering wrapping.
// lt => negative direction (left or down)
// eq => not moving in that dimension
// gt => positive direction (right or up)
// s_result: will contain result
// s_scratch_1, s_scratch_2: will be modified. can be equal to s_x and s_next_x, if they can be modified.
// s_scratch_3: will be modified.
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
    U64 clear_colour;
    U64 empty_cell_colour;
    U64 apple_colour;
    U64 snake_colour;
    F32 board_size_1d; // pixels
    F32 board_x_offset; // pixels
    F32 board_y_offset; // pixels
    F32 cell_size; // pixels
    F32 margin_size; // pixels
    // tail: index of head cell. multiply by 2 to get byte location
    U16 tail;
    // head: index of head cell. multiply by 2 to get byte location
    U16 head;
    U8 previous_move_direction;
    U8 move_direction;
    // pairs of U8 for x, y coordinates.
    // one for every cell, + 1 so we can remember where the tail end was last update
    U8 body[((cell_count_1d * cell_count_1d) + 1) * 2];
};
*/

.text
    // NOTE(TB): in the main function, after initialisation, the following registers will have these associated values.
    // tail, head, previous_move_direction, and move_direction are not ever read or written to memory (in the Game struct).
    // x19 => Game struct pointer
    // x20 => tail
    // x21 => head
    // x22 => previous_move_direction
    // x23 => move_direction
    // x24 => body
    _main:
        sub sp, sp, STACK_FRAME_SIZE
        stp fp, lr, [sp]
        stp d14, d15, [sp, #0x10]
        stp d12, d13, [sp, #0x20]
        stp d10, d11, [sp, #0x30]
        stp d8, d9, [sp, #0x40]
        stp x27, x28, [sp, #0x50]
        stp x25, x26, [sp, #0x60]
        stp x23, x24, [sp, #0x70]
        stp x21, x22, [sp, #0x80]
        stp x19, x20, [sp, #0x90]
        add x19, sp, #0xa0
        mov fp, sp

        // create window
        mov x0, INITIAL_WINDOW_WIDTH
        mov x1, INITIAL_WINDOW_HEIGHT
        adrp x2, window_name@PAGE
        add x2, x2, window_name@PAGEOFF
        bl _InitWindow
        bl _IsWindowReady
        cbz x0, done

        // init snake struct
        // body
        add x24, x19, body_offset
        // clear_colour and empty_cell_colour
        adrp x0, clear_colour@PAGE
        add x0, x0, clear_colour@PAGEOFF
        ldr x0, [x0]
        adrp x1, empty_cell_colour@PAGE
        add x1, x1, empty_cell_colour@PAGEOFF
        ldr x1, [x1]
        stp x0, x1, [x19, clear_colour_offset]
        // apple_colour and snake_colour
        adrp x0, apple_colour@PAGE
        add x0, x0, apple_colour@PAGEOFF
        ldr x0, [x0]
        adrp x1, snake_colour@PAGE
        add x1, x1, snake_colour@PAGEOFF
        ldr x1, [x1]
        stp x0, x1, [x19, apple_colour_offset]

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
        stp s10, s11, [x19, board_size_1d_offset]
        // board_y_offset, cell_size
        stp s12, s14, [x19, board_y_offset_offset]
        // margin_size
        str s15, [x19, margin_size_offset]
        // tail
        mov w20, #0
        /*
        // head
        mov w21, #1
        // previous move direction
        mov w22, RIGHT
        // move direction
        mov w23, w22
        mov w0, #16
        mov w1, #17
        // body[0].x
        mov x2, body_offset
        strb w0, [x19, x2]
        // body[0].y
        add x2, x2, #1
        strb w0, [x19, x2]
        // body[1].x
        add x2, x2, #1
        strb w1, [x19, x2]
        // body[1].y
        add x2, x2, #1
        strb w0, [x19, x2]
        */

        // TODO(TB): remove this
        // head
        mov w21, #4
        // previous move direction
        mov w22, RIGHT
        // move direction
        mov w23, w22
        mov w0, #16
        mov w1, #17
        // body[0].x
        mov x2, body_offset
        strb w0, [x19, x2]
        // body[0].y
        add x2, x2, #1
        strb w0, [x19, x2]
        // body[1].x
        add x2, x2, #1
        strb w1, [x19, x2]
        // body[1].y
        add x2, x2, #1
        strb w0, [x19, x2]
        add w1, w1, #1
        // body[2].x
        add x2, x2, #1
        strb w1, [x19, x2]
        // body[2].y
        add x2, x2, #1
        strb w0, [x19, x2]
        add w0, w0, #1
        // body[3].x
        add x2, x2, #1
        strb w1, [x19, x2]
        // body[3].y
        add x2, x2, #1
        strb w0, [x19, x2]
        add w0, w0, #1
        // body[4].x
        add x2, x2, #1
        strb w1, [x19, x2]
        // body[4].y
        add x2, x2, #1
        strb w0, [x19, x2]

        mov w0, #60
        bl _SetTargetFPS

        bl _GetTime
        fcvt s8, d0 // last update time
        fmov s9, wzr // frame dt

        b draw
    game_loop:
        // handle input
        mov w25, UP_KEY_CODE
        mov w26, RIGHT_KEY_CODE
        mov w27, DOWN_KEY_CODE
        mov w28, LEFT_KEY_CODE
        b input_loop_cond
        input_loop:
            cmp w0, w25
            b.eq 1f
            cmp w0, w26
            b.eq 2f
            cmp w0, w27
            b.eq 3f
            cmp w0, w28
            b.eq 4f
            b 5f
            1: // up
                cmp w22, DOWN
                b.eq 5f

                mov w23, UP
                b 5f
            2: // right
                cmp w22, LEFT
                b.eq 5f

                mov w23, RIGHT
                b 5f
            3: // down
                cmp w22, UP
                b.eq 5f

                mov w23, DOWN
                b 5f
            4: // left
                cmp w22, RIGHT
                b.eq 5f

                mov w23, LEFT
            5: // done

        input_loop_cond:
            bl _GetKeyPressed
            cbnz w0, input_loop

        // update
        bl _GetTime
        fcvt s0, d0
        // s9 = time delta
        fsub s9, s0, s8
        // s10 = time step s
        mov w0, TIME_STEP_S
        scvtf s10, w0

        fcmp s9, s10
        b.le after_update_loop
        // previous_move_direction = move_direction
        mov w22, w23
        // x4 = body
        add x4, x19, body_offset
        update_loop:
            // w1 = index
            mov w0, #2
            mul w1, w21, w0
            // w5 = x
            ldrb w5, [x4, x1]
            // w6 = y
            add w1, w1, #1
            ldrb w6, [x4, x1]

            mov w3, #4
            mul w3, w23, w3
            adrp x2, jt@PAGE
            add x2, x2, jt@PAGEOFF
            add x2, x2, x3
            // x0 = CELL_COUNT_1D
            mov x3, CELL_COUNT_1D
            br x2
            jt:
                b direction_up
                b direction_right
                b direction_down
                b direction_left
            direction_up:
                DEC_CLAMP_ZERO_TO_N w6, w3
                b direction_done
            direction_right:
                INC_CLAMP_ZERO_TO_N w5, w3
                b direction_done
            direction_down:
                INC_CLAMP_ZERO_TO_N w6, w3
                b direction_done
            direction_left:
                DEC_CLAMP_ZERO_TO_N w5, w3
            direction_done:

            // w1 = new head x index
            mov w2, BODY_CAPACITY
            mov w1, w21
            INC_CLAMP_ZERO_TO_N w1, w2
            mul w1, w1, w0

            // update new head x and y in body
            strb w5, [x4, x1]
            add w1, w1, #1
            strb w6, [x4, x1]

            // x0 = BODY_CAPACITY
            mov x0, BODY_CAPACITY

            // update head
            mov w1, w0
            INC_CLAMP_ZERO_TO_N w21, w1

            // TODO(TB): if NOT hit an apple
            // update tail
            INC_CLAMP_ZERO_TO_N w20, w0

            fadd s8, s8, s10
            fsub s9, s9, s10
        update_loop_condition:
            fcmp s9, s10
            b.gt update_loop
        after_update_loop:

        fdiv s9, s9, s10

    draw:
        stp s8, s9, [sp, #-0x10]!

        bl _BeginDrawing
        ldr x0, [x19, clear_colour_offset]
        bl _ClearBackground

        // cell colour
        ldr x28, [x19, empty_cell_colour_offset]

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
        ldp s10, s11, [x19, board_x_offset_offset]
        // cell_size, margin_size
        ldp s12, s13, [x19, cell_size_offset]
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
            mov x0, x28
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

    ldp s8, s9, [sp], #0x10

    stp s8, s9, [sp, #-0x10]!

    // w25 = index = tail
    mov w25, w20
    // s10 = cell_size
    ldp s10, s11, [x19, cell_size_offset]
    // s11 = cell_size_plus_margin_size
    fadd s11, s11, s10
    // s12 = board_x_offset
    // s13 = board_y_offset
    ldp s12, s13, [x19, board_x_offset_offset]
    // s14 = dt * cell_size
    fmul s14, s9, s10
    // s15 = (1 - dt) * cell_size
    fsub s15, s10, s14

    ldr x26, [x19, snake_colour_offset]

    // draw tail most cell
    mov w0, #2
    mul w1, w0, w25
    ldrb w2, [x24, x1]
    // x_index
    scvtf s0, w2
    add w1, w1, #1
    ldrb w2, [x24, x1]
    // y_index
    scvtf s1, w2
    // increment tail
    mov w1, BODY_CAPACITY
    INC_CLAMP_ZERO_TO_N w25, w1
    mul w1, w0, w25
    ldrb w2, [x24, x1]
    // next_x_index
    scvtf s2, w2
    add w1, w1, #1
    ldrb w2, [x24, x1]
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
    mov x0, x26
    // draw
    bl _DrawRectangleV

    // draw snake body (excluding head)
    b draw_body_loop_condition

    draw_body_loop:
        mov w0, #2
        mul w0, w0, w25
        ldrb w1, [x24, x0]
        // x_index
        scvtf s0, w1
        add w0, w0, #1
        ldrb w1, [x24, x0]
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
        mov x0, x26

        bl _DrawRectangleV

        mov w0, BODY_CAPACITY
        INC_CLAMP_ZERO_TO_N w25, w0
    draw_body_loop_condition:
        cmp w25, w21
        b.ne draw_body_loop

    // draw head
    mov w0, #2
    mul w1, w0, w25
    ldrb w2, [x24, x1]
    // x_index
    scvtf s0, w2
    add w1, w1, #1
    ldrb w2, [x24, x1]
    // y_index
    scvtf s1, w2
    mov w1, BODY_CAPACITY
    DEC_CLAMP_ZERO_TO_N w25, w1
    mul w1, w0, w25
    ldrb w2, [x24, x1]
    // prev_x_index
    scvtf s2, w2
    add w1, w1, #1
    ldrb w2, [x24, x1]
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
    mov x0, x26
    // draw
    bl _DrawRectangleV

    bl _EndDrawing
    ldp s8, s9, [sp], #0x10

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
        ldp x27, x28, [sp, #0x50]
        ldp x25, x26, [sp, #0x60]
        ldp x23, x24, [sp, #0x70]
        ldp x21, x22, [sp, #0x80]
        ldp x19, x20, [sp, #0x90]
        add sp, sp, STACK_FRAME_SIZE
        mov x0, xzr
        ret
