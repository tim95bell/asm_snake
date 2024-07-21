
.global _main
.align 2

// CELL_COUNT_1D: amount of cells in a single dimension. The grid is a square, so this is both the rows and cols.
.equ CELL_COUNT_1D, 32
// MARGIN_DIVISOR: margin_size = cell_size / MARGIN_DIVISOR
.equ MARGIN_DIVISOR, 5
// TIME_STEP_S: the time in seconds, that everything updates in the game by (since it has discrete steps)
.equ TIME_STEP_S, 2

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
    float board_size_1d; // pixels
    float board_x_offset; // pixels
    float board_y_offset; // pixels
    float cell_size; // pixels
    float margin_size; // pixels
};
*/

.text
    _main:
        stp fp, lr, [sp, #-0x80]!
        stp d14, d15, [sp, #0x10]
        stp d12, d13, [sp, #0x20]
        stp d10, d11, [sp, #0x30]
        stp d8, d9, [sp, #0x40]
        stp x19, x20, [sp, #0x50]
        add x20, sp, #0x60
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

        stp s10, s11, [x20]
        stp s12, s14, [x20, #0x8]
        str s15, [x20, #0x10]

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

        bl _EndDrawing
        ldp d8, d9, [sp], #0x10

    game_loop_condition:
        bl _WindowShouldClose
        cbz x0, game_loop
    done:
        bl _CloseWindow
        ldp fp, lr, [sp], #0x10
        ldp d14, d15, [sp], #0x10
        ldp d12, d13, [sp], #0x10
        ldp d10, d11, [sp], #0x10
        ldp d8, d9, [sp], #0x10
        ldp x19, x20, [sp], #0x10
        add sp, sp, #0x20
        mov x0, xzr
        ret
