
.global _main
.align 2

// CELL_COUNT_1D: amount of cells in a single dimension. The grid is a square, so this is both the rows and cols.
.equ CELL_COUNT_1D, 32
// MARGIN_DIVISOR: margin_size = cell_size / MARGIN_DIVISOR
.equ MARGIN_DIVISOR, 5
// TIME_STEP_S: the time in seconds, that everything updates in the game by (since it has discrete steps)
.equ TIME_STEP_S, 2
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
.equ move_direction_offset, 24
.equ body_offset, 25

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

.data
    window_name: .asciz "ASM Snake"
    update_string: .asciz "update\n"
    draw_string: .asciz "draw with delta: %f\n"
    // ABGR (because little endian)
    clear_colour: .4byte 0xFF224466
    empty_cell_colour: .4byte 0xFFDDBB99
    apple_colour: .4byte 0xFF5533BB
    snake_body_colour: .4byte 0xFFAA22CC
    snake_head_colour: .4byte 0xFFAA22CC

.macro CALC_CELL_SIZE, result, scratch, cell_count_1d, board_size_1d, margin_divisor
    fmov \scratch, #1
    fmadd \result, \margin_divisor, \cell_count_1d, \cell_count_1d
    fsub \result, \result, \scratch
    fdiv \result, \margin_divisor, \result
    fmul \result, \result, \board_size_1d
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
    U8 body[((board_size_1d * board_size_1d) + 1) * 2];
};
*/

// D_REGISTER_BACKUP_SIZE = 0x40
// X_REGISTER_BACKUP_SIZE = 0x40
// FP_AND_LR_SIZE = 0x10
// GAME_STRUCT_SIZE = (4 + 4 + 4 + 4 + 4 + 2 + 2 + 1 + (((CELL_COUNT_1D * CELL_COUNT_1D) + 1) * 2)) = 0x81B
// STACK_FRAME_SIZE = 0x8aB (round up to multiple of 0x10) = 0x8b0

.text
    _main:
        sub sp, sp, #0x8b0
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

        mov x0, #640
        mov x1, #480
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
        stp s10, s11, [x20]
        // board_y_offset, cell_size
        stp s12, s14, [x20, #0x8]
        // margin_size
        str s15, [x20, #0x10]
        // tail
        mov w0, #0
        strh w0, [x20, #0x14]
        // head
        mov w0, #1
        strh w0, [x20, #0x16]
        // move direction
        mov w0, RIGHT
        strb w0, [x20, #0x18]
        mov w0, #16
        mov w1, #17
        // body[0].x
        strb w0, [x20, #0x19]
        // body[0].y
        strb w0, [x20, #0x1a]
        // body[1].x
        strb w1, [x20, #0x1b]
        // body[1].y
        strb w0, [x20, #0x1c]

        // TODO(TB): remove this
        add w1, w1, #1
        // body[2].x
        strb w1, [x20, #0x1d]
        // body[2].y
        strb w0, [x20, #0x1e]
        add w0, w0, #1
        // body[3].x
        strb w1, [x20, #0x1f]
        // body[3].y
        strb w0, [x20, #0x20]
        add w0, w0, #1
        // body[4].x
        strb w1, [x20, #0x21]
        // body[4].y
        strb w0, [x20, #0x22]
        // head
        mov w0, #4
        strh w0, [x20, #0x16]

        bl _GetTime
        fmov d8, d0 // last update time
        fmov d9, xzr

        mov w0, #4
        bl _SetTargetFPS

        b draw
    game_loop:
        // update
        bl _GetTime

        // d9 = time delta
        fsub d9, d0, d8
        // d10 = time step s
        mov x0, TIME_STEP_S
        scvtf d10, x0

        b update_loop_condition
        update_loop:
            adrp x0, update_string@PAGE
            add x0, x0, update_string@PAGEOFF
            bl _printf

            fadd d8, d8, d10
            fsub d9, d9, d10
        update_loop_condition:
            fcmp d9, d10
            b.gt update_loop

        fdiv d9, d9, d10

    draw:
        stp d8, d9, [sp, #-0x10]!

        str d9, [sp, #-0x10]!
        adrp x0, draw_string@PAGE
        add x0, x0, draw_string@PAGEOFF
        bl _printf
        add sp, sp, #0x10

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
        ldp s10, s11, [x20, #0x4]
        ldp s12, s13, [x20, #0xc]
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

    // TODO(TB): will this clear the other bits in the x register?
    // w21 = head
    ldrh w21, [x20, head_offset]
    // w22 = tail
    ldrh w22, [x20, tail_offset]
    // s10 = cell_size
    ldp s10, s11, [x20, cell_size_offset]
    // s11 = cell_size_plus_margin_size
    fadd s11, s11, s10
    // s2 = board_x_offset
    // s3 = board_y_offset
    ldp s12, s13, [x20, board_x_offset_offset]
    // body
    add x23, x20, body_offset

    // draw head
    // colour
    adrp x0, snake_head_colour@PAGE
    add x0, x0, snake_head_colour@PAGEOFF
    ldr x0, [x0]
    // body_ptr
    mov x1, x23
    // index
    mov x2, x21
    // cell_size
    fmov s0, s10
    // cell_size_plus_margin_size
    fmov s1, s11
    // board_x_offset
    fmov s2, s12
    // board_y_offset
    fmov s3, s13
    bl draw_snake_cell

    // draw snake body (excluding head)
    adrp x24, snake_body_colour@PAGE
    add x24, x24, snake_body_colour@PAGEOFF
    ldr x24, [x24]

    cmp x21, x22
    b.gt tail_before_head_body_loop_cond

    head_before_tail:
    // TODO(TB): implement drawing body when head is before tail

    b end_draw_snake

    tail_before_head_body_loop:
        // colour
        mov x0, x24
        // body_ptr
        mov x1, x23
        // index
        mov x2, x22
        // cell_size
        fmov s0, s10
        // cell_size_plus_margin_size
        fmov s1, s11
        // board_x_offset
        fmov s2, s12
        // board_y_offset
        fmov s3, s13
        bl draw_snake_cell

    tail_before_head_body_loop_cond:
        // tail += 1
        add x22, x22, #1
        cmp x21, x22
        b.gt tail_before_head_body_loop

    end_draw_snake:

    bl _EndDrawing

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
        add sp, sp, #0x8b0
        mov x0, xzr
        ret

    // x_colour, x_body_ptr, x_index
    // s_cell_size, s_cell_size_plus_margin_size, s_x_offset, s_y_offset
    draw_snake_cell:
        stp fp, lr, [sp, #-0x10]!
        mov fp, sp
        mov x5, #2
        mul x2, x2, x5
        fmov s5, s2
        fmov s6, s3
        // width = cell_size
        fmov s2, s0
        // height = cell_size
        fmov s3, s0
        // s_cell_size_plus_margin_size
        fmov s4, s1
        // x_index
        ldrb w3, [x1, x2]
        scvtf s0, w3
        add x2, x2, #1
        // y_index
        ldrb w4, [x1, x2]
        scvtf s1, w4
        // x_pos
        fmadd s0, s0, s4, s5
        // y_pos
        fmadd s1, s1, s4, s6
        // draw
        bl _DrawRectangleV
        ldp fp, lr, [sp], #0x10
        ret
