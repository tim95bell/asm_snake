
.global _main
.align 2

// CELL_COUNT_1D: amount of cells in a single dimension. The grid is a square, so this is both the rows and cols.
//      must be a power of 2 and <= 256
.equ CELL_COUNT_1D, 8
// MARGIN_DIVISOR: margin_size = cell_size / MARGIN_DIVISOR
.equ MARGIN_DIVISOR, 50
.equ MIN_WINDOW_SIZE_1D, 200
.equ INITIAL_WINDOW_WIDTH, 640
.equ INITIAL_WINDOW_HEIGHT, 480

.equ UP, 0
.equ RIGHT, 1
.equ DOWN, 2
.equ LEFT, 3
.equ BOARD_SIZE_1D_OFFSET, 0
.equ BOARD_X_POSITION_OFFSET, 4
.equ BOARD_Y_POSITION_OFFSET, 8
.equ CELL_SIZE_OFFSET, 12
.equ MARGIN_SIZE_OFFSET, 16
.equ LAST_UPDATE_TIME_OFFSET, 20
.equ MIN_TIME_STEP_S_OFFSET, 24
.equ MAX_TIME_STEP_S_OFFSET, 28
.equ TIME_STEP_S_OFFSET, 32
.equ TAIL_OFFSET, 36
.equ HEAD_OFFSET, 38
.equ APPLE_X_OFFSET, 40
.equ APPLE_Y_OFFSET, 42
.equ PREVIOUS_MOVE_DIRECTION_OFFSET, 44
.equ MOVE_DIRECTION_OFFSET, 45
.equ BODY_OFFSET, 46

.equ UP_KEY_CODE, 265
.equ RIGHT_KEY_CODE, 262
.equ DOWN_KEY_CODE, 264
.equ LEFT_KEY_CODE, 263
.equ SPACEBAR_KEY_CODE, 32
.equ ENTER_KEY_CODE, 257

// D_REGISTER_BACKUP_SIZE = 0x50
// X_REGISTER_BACKUP_SIZE = 0x40
// FP_AND_LR_SIZE = 0x10
// GAME_STRUCT_SIZE = (4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 2 + 2 + 2 + 2 + 1 + 1 + (((CELL_COUNT_1D * CELL_COUNT_1D) + 1) * 2)) = 0x830
// STACK_FRAME_SIZE = 0x8d0 (round up to multiple of 0x10) = 0x8d0
.equ STACK_FRAME_SIZE, 0x8d0

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
.extern _GetRandomValue

.data
    WINDOW_NAME: .asciz "ASM Snake"
    // MIN_TIME_STEP_S: the minimum time in seconds, that everything updates in the game by (since it has discrete steps)
    MIN_TIME_STEP_S: .float 0.05
    // MAX_TIME_STEP_S: the maximum time in seconds, that everything updates in the game by (since it has discrete steps)
    MAX_TIME_STEP_S: .float 0.15

.macro CREATE_COLOUR x_dest, ab, gr
    movk \x_dest, \ab, lsl #0x10
    movk \x_dest, \gr
.endm

.macro GET_CLEAR_COLOUR x_dest
    CREATE_COLOUR \x_dest, #0xFF22, #0x4466
.endm

.macro GET_EMPTY_CELL_COLOUR x_dest
    CREATE_COLOUR \x_dest, #0xFFDD, #0xBB99
.endm

.macro GET_APPLE_COLOUR x_dest
    CREATE_COLOUR \x_dest, #0xFF55, #0x33BB
.endm

.macro GET_SNAKE_COLOUR x_dest
    CREATE_COLOUR \x_dest, #0xFFAA, #0x22CC
.endm

// increment x, wrapping to keep in range [0, n)
// result in x
// n also modified
.macro INC_CLAMP_ZERO_TO_N x, n
    add \x, \x, #1
    subs \n, \x, \n
    csel \x, \x, \n, mi
.endm

// decrement x, wrapping to keep in range [0, n)
// result in x
// n also modified
.macro DEC_CLAMP_ZERO_TO_N x, n
    subs \x, \x, #1
    add \n, \n, \x
    csel \x, \n, \x, mi
.endm

// update comparison flags for the direction moving. considering wrapping.
// lt => negative direction (left or down)
// eq => not moving in that dimension
// gt => positive direction (right or up)
// s_result: will contain result
// s_scratch_1, s_scratch_2, scratch_3: will be modified. can be equal to s_x and s_next_x, if they can be modified.
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

// TODO(TB): change to use an index instead of byte index, it is confusing
// TODO(TB): make a simpler macro that just checks collision of a single index, instead of all indices in a range
// check for collions between the specified x and y indices, and the specified sections of the snake body.
// after calling, the result flags give the result:
//              eq => collision
//              ne => no collision
// i_x, i_y: x and y indices to check against collision with specified sections of snake body.
//              will NOT be modified.
// i_ti: starting byte index into snake body to check collisions against.
//              byte index not index.
//              will be modified.
// i_ti_end: ending byte index (inclusive) into snake body to check collisions against.
//              byte index not index.
//              will NOT be modified.
// i_tx, i_ty: to be used as test x and y indices.
//              will be modified.
// i_body: snake body pointer.
//              will NOT be modified.
// i_scratch_1: scratch buffer.
//              used to hold CELL_COUNT_2D_TIMES_2.
//              used to signal loop exit.
//              will be modified.
// i_scratch_2: scratch buffer.
//              used to hold CELL_COUNT_2D_TIMES_2.
//              will be modified.
.macro CHECK_COLLISION i_x, i_y, i_ti, i_ti_end, i_tx, i_ty, i_body, i_scratch_1, i_scratch_2
    GET_CELL_COUNT_2D w\i_scratch_2
    lsl w\i_scratch_2, w\i_scratch_2, #1
    b 2f
    1:
        ldrb w\i_tx, [x\i_body, x\i_ti]
        add w\i_ti, w\i_ti, #1
        ldrb w\i_ty, [x\i_body, x\i_ti]
        sub w\i_tx, w\i_x, w\i_tx
        sub w\i_ty, w\i_y, w\i_ty
        orr w\i_tx, w\i_tx, w\i_ty
        cmp w\i_tx, wzr
        // if collision, skip the rest of body loop, to the increment and re check_collision loop
        // else, increment and keep looping
        b.eq 3f

        // no collision

        cmp w\i_scratch_1, w\i_scratch_2
        b.ne 3f

        INC_CLAMP_ZERO_TO_N w\i_ti, w\i_scratch_1
    2:
        cmp w\i_ti, w\i_ti_end
        csel w\i_scratch_1, wzr, w\i_scratch_2, eq
        b 1b
    3:
.endm

// calculate snake length
// i_result: will contain the result. can be i_tail or i_head, if they can be modified.
//          will be modified.
// i_tail: tail index.
//          will NOT be modified.
// i_head: head_index.
//          will NOT be modified.
// i_scratch: scratch.
//          will be modified.
.macro SNAKE_LENGTH i_result, i_tail, i_head, i_scratch
    subs w\i_result, w\i_head, w\i_tail
    add w\i_result, w\i_result, #1
    GET_CELL_COUNT_2D w\i_scratch
    add w\i_scratch, w\i_result, w\i_scratch
    csel w\i_result, w\i_scratch, w\i_result, mi
.endm

// floating point lerp between `a` and `b` by `t`.
// result: will contain the result.
//      can be equal to `a` if it can be modified.
// scratch: will be modified.
//      can be equal to `b` if it can be modified.
.macro FLERP result, a, b, t, scratch
    // b = b - a
    fsub \scratch, \b, \a
    // a = t * b` + a = t * (b - a) + a
    fmadd \result, \t, \scratch, \a
.endm

.macro INIT_SNAKE game_ptr, tail_out, head_out, previous_move_direction_out, move_direction_out, scratch_1, scratch_2, scratch_3, scratch_4, f_scratch_1
        ldr s\f_scratch_1, [x\game_ptr, MAX_TIME_STEP_S_OFFSET]
        str s\f_scratch_1, [x\game_ptr, TIME_STEP_S_OFFSET]
        // tail
        mov w\tail_out, #0
        // head
        mov w\head_out, #2
        // previous move direction
        mov w\previous_move_direction_out, RIGHT
        // move direction
        mov w\move_direction_out, w\previous_move_direction_out
        add x\scratch_1, x\game_ptr, BODY_OFFSET
        mov w\scratch_2, CELL_COUNT_1D
        // CELL_COUNT_1D / 2
        mov w\scratch_3, #2
        // scratch_2 = y
        udiv w\scratch_2, w\scratch_2, w\scratch_3
        // scratch_3 = x
        sub w\scratch_3, w\scratch_2, 2

        // scratch_4 = index
        mov x\scratch_4, xzr

        // body[0].x
        strb w\scratch_3, [x\scratch_1, x\scratch_4]
        // body[0].y
        add x\scratch_4, x\scratch_4, #1
        strb w\scratch_2, [x\scratch_1, x\scratch_4]

        add w\scratch_3, w\scratch_3, #1
        // body[1].x
        add x\scratch_4, x\scratch_4, #1
        strb w\scratch_3, [x\scratch_1, x\scratch_4]
        // body[1].y
        add x\scratch_4, x\scratch_4, #1
        strb w\scratch_2, [x\scratch_1, x\scratch_4]

        add w\scratch_3, w\scratch_3, #1
        // body[2].x
        add x\scratch_4, x\scratch_4, #1
        strb w\scratch_3, [x\scratch_1, x\scratch_4]
        // body[2].y
        add x\scratch_4, x\scratch_4, #1
        strb w\scratch_2, [x\scratch_1, x\scratch_4]
.endm

.macro GET_CELL_COUNT_2D dest
    mov \dest, CELL_COUNT_1D
    mul \dest, \dest, \dest
.endm

/*
struct Game {
    F32 board_size_1d; // pixels
    F32 board_x_position; // pixels
    F32 board_y_position; // pixels
    F32 cell_size; // pixels
    F32 margin_size; // pixels
    F32 last_update_time; // seconds
    F32 min_time_step_s; // seconds
    F32 max_time_step_s; // seconds
    F32 time_step_s; // seconds
    // tail: index of head cell. multiply by 2 to get byte location
    U16 tail;
    // head: index of head cell. multiply by 2 to get byte location
    U16 head;
    U16 apple_x;
    U16 apple_y;
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
    // w24 => hit apple
    // s8 => frame dt
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
        adrp x2, WINDOW_NAME@PAGE
        add x2, x2, WINDOW_NAME@PAGEOFF
        bl _InitWindow
        bl _IsWindowReady
        cbz x0, done

        mov w0, 0x00000004 //FLAG_WINDOW_RESIZABLE
        bl _SetWindowState

        mov w0, MIN_WINDOW_SIZE_1D
        mov w1, MIN_WINDOW_SIZE_1D
        bl _SetWindowMinSize

        mov w0, #60
        bl _SetTargetFPS

        // init snake struct
        // min_time_step_s
        adrp x0, MIN_TIME_STEP_S@PAGE
        add x0, x0, MIN_TIME_STEP_S@PAGEOFF
        ldr s0, [x0]
        adrp x1, MAX_TIME_STEP_S@PAGE
        add x1, x1, MAX_TIME_STEP_S@PAGEOFF
        ldr s1, [x1]
        stp s0, s1, [x19, MIN_TIME_STEP_S_OFFSET]

        mov x0, x19
        bl init_based_on_window_size

        INIT_SNAKE 19, 20, 21, 22, 23, 0, 1, 2, 3, 0

        mov w0, w20
        mov w1, w21
        mov x2, x19
        bl place_apple

        bl _GetTime
        fcvt s0, d0 // last update time
        str s0, [x19, LAST_UPDATE_TIME_OFFSET]
        fmov s8, wzr // frame dt

        mov w24, 0

        b play_draw
    game_loop:

    play:
        bl _IsWindowResized
        cbz w0, 1f
            // window resized last frame
            mov x0, x19
            bl init_based_on_window_size
        1:
        // handle input
        mov w25, UP_KEY_CODE
        mov w26, RIGHT_KEY_CODE
        mov w27, DOWN_KEY_CODE
        mov w28, LEFT_KEY_CODE
        b play_input_loop_cond
        play_input_loop:
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

        play_input_loop_cond:
            bl _GetKeyPressed
            cbnz w0, play_input_loop

        ldr s9, [x19, LAST_UPDATE_TIME_OFFSET]
        // update
        bl _GetTime
        fcvt s0, d0
        // s8 = time delta
        fsub s8, s0, s9
        // s10 = time step s
        ldr s10, [x19, TIME_STEP_S_OFFSET]

        b play_update_loop_condition
        // NOTE(TB): assume update_loop will almost never run more than once, and far more often zero times
        play_update_loop:
            add x7, x19, BODY_OFFSET
            // previous_move_direction = move_direction
            mov w22, w23
            // w1 = index
            mov w0, #2
            mul w1, w21, w0
            // w5 = x
            ldrb w5, [x7, x1]
            // w6 = y
            add w1, w1, #1
            ldrb w6, [x7, x1]

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
            GET_CELL_COUNT_2D w2
            mov w3, w2
            mov w1, w21
            INC_CLAMP_ZERO_TO_N w1, w3
            mul w1, w1, w0

            // update new head x and y in body
            strb w5, [x7, x1]
            add w1, w1, #1
            strb w6, [x7, x1]

            // update head
            mov w1, w2
            // w21 = head
            INC_CLAMP_ZERO_TO_N w21, w1

            cbnz w24, hit_apple_last_update

            // check collision between new head and apple
            // w0 = apple x
            ldrh w0, [x19, APPLE_X_OFFSET]
            // w1 = apple y
            ldrh w1, [x19, APPLE_Y_OFFSET]
            // w2 = head byte index (start index)
            mov w3, #2
            mul w2, w21, w3
            // w3 = head byte index (end index)
            mov w3, w2
            CHECK_COLLISION 0, 1, 2, 3, 4, 5, 7, 6, 9
            mov w0, #1
            csel w24, w0, wzr, eq
            // update tail
            GET_CELL_COUNT_2D x0
            INC_CLAMP_ZERO_TO_N w20, w0

            b hit_apple_last_update_finish

            hit_apple_last_update:
                // reset hit apple flag
                mov w24, 0
                // place apple
                mov w0, w20
                mov w1, w21
                mov x2, x19
                bl place_apple
                ldp s0, s1, [x19, MIN_TIME_STEP_S_OFFSET]
                GET_CELL_COUNT_2D w2
                scvtf s2, w2
                SNAKE_LENGTH 3, 20, 21, 1
                scvtf s3, w3
                fdiv s3, s3, s2
                FLERP s10, s1, s0, s3, s0
                str s10, [x19, TIME_STEP_S_OFFSET]

            hit_apple_last_update_finish:

            // check collision against self
            SNAKE_LENGTH 0, 20, 21, 1
            cmp w0, #4
            b.le after_self_collision
            // TODO(TB): if collided with an apple, could not have collided with self
            mov w7, #2
            // x2 = ti
            mul x2, x20, x7
            // x3 = ti_end
            mov x3, x21
            // TODO(TB): make DEC_CLAMP_ZERO_TO_N take an argument of how much to decrement (must be in range [0, n))
            GET_CELL_COUNT_2D w5
            mov w4, w5
            DEC_CLAMP_ZERO_TO_N w3, w4
            mov w4, w5
            DEC_CLAMP_ZERO_TO_N w3, w4
            mov w4, w5
            DEC_CLAMP_ZERO_TO_N w3, w4
            mov w4, w5
            DEC_CLAMP_ZERO_TO_N w3, w4
            mul w3, w3, w7
            add x6, x19, BODY_OFFSET
            // w0 = head x
            mul w0, w21, w7
            // w1 = head y
            add w1, w0, #1
            ldrb w0, [x6, x0]
            ldrb w1, [x6, x1]
            CHECK_COLLISION 0, 1, 2, 3, 4, 5, 6, 7, 9

            b.eq game_over

            after_self_collision:

            fadd s9, s9, s10
            fsub s8, s8, s10
        play_update_loop_condition:
            fcmp s8, s10
            b.gt play_update_loop

        str s9, [x19, LAST_UPDATE_TIME_OFFSET]
        fdiv s8, s8, s10

    play_draw:
        bl _BeginDrawing
        bl draw_main_game
        bl _EndDrawing

    play_condition:
        bl _WindowShouldClose
        cbz x0, play
        b done

    game_over:
        bl _IsWindowResized
        cbz w0, 1f
            // window resized last frame
            mov x0, x19
            bl init_based_on_window_size
        1:
        // handle input
        b game_over_input_loop_cond
        game_over_input_loop:
            subs w1, w0, SPACEBAR_KEY_CODE
            sub w2, w0, ENTER_KEY_CODE
            csel w0, w1, w2, eq
            cbnz w0, game_over_input_loop_cond
            // space or enter
            INIT_SNAKE 19, 20, 21, 22, 23, 0, 1, 2, 3, 0
            fmov s8, #0.0
            bl _GetTime
            fcvt s0, d0
            str s0, [x19, LAST_UPDATE_TIME_OFFSET]

            mov w0, w20
            mov w1, w21
            mov x2, x19
            bl place_apple
            b play_draw

        game_over_input_loop_cond:
            bl _GetKeyPressed
            cbnz w0, game_over_input_loop

        bl _BeginDrawing
        bl draw_main_game
        bl _EndDrawing

    game_over_condition:
        bl _WindowShouldClose
        cbz x0, game_over

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

    draw_main_game:
        // TODO(TB): backup registers used
        stp fp, lr, [sp, #-0x10]!
        mov fp, sp
        GET_CLEAR_COLOUR x0
        bl _ClearBackground

        // cell colour
        GET_EMPTY_CELL_COLOUR x28

        // draw grid
        // s9 = x_coord
        // s10 = board_x_position
        // s11 = board_y_position
        // s12 = cell_size
        // s13 = cell_size + margin_size
        // s14 = x_index
        // s15 = y_index
        scvtf s0, wzr
        fmov s14, s0 // x_index
        // board_x_position, board_y_position
        ldp s10, s11, [x19, BOARD_X_POSITION_OFFSET]
        // cell_size, margin_size
        ldp s12, s13, [x19, CELL_SIZE_OFFSET]
        // cell_size + margin_size
        fadd s13, s13, s12
        b x_loop_cond

    x_loop:
        scvtf s0, wzr
        fmov s15, s0 // y_index
        // s9 = x_coord (pixels)
        fmadd s9, s14, s13, s10 // x_index * (cell_size + margin_size) + board_x_position
        b y_loop_cond
        y_loop:
            // x
            fmov s0, s9

            // y
            // s1 = y_coord (pixels)
            fmadd s1, s15, s13, s11 // y_index * (cell_size + margin_size) + board_y_position

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
            mov w0, CELL_COUNT_1D
            scvtf s0, w0
            fcmp s15, s0
            b.lt y_loop

        // inc x_index
        mov w0, #1
        scvtf s0, w0
        fadd s14, s14, s0
    x_loop_cond:
        mov w0, CELL_COUNT_1D
        scvtf s0, w0
        fcmp s14, s0
        b.lt x_loop

    // draw apple
    // x position
    ldrh w0, [x19, APPLE_X_OFFSET]
    scvtf s0, w0
    fmadd s0, s0, s13, s10
    // y position
    ldrh w1, [x19, APPLE_Y_OFFSET]
    scvtf s1, w1
    fmadd s1, s1, s13, s11
    // width
    fmov s2, s12
    // height
    fmov s3, s12
    // colour
    GET_APPLE_COLOUR x0
    // draw
    bl _DrawRectangleV

    // w25 = index = tail
    mov w25, w20
    // s10 = cell_size
    ldp s10, s11, [x19, CELL_SIZE_OFFSET]
    // s11 = cell_size_plus_margin_size
    fadd s11, s11, s10
    // s12 = board_x_position
    // s13 = board_y_position
    ldp s12, s13, [x19, BOARD_X_POSITION_OFFSET]
    // s14 = dt * cell_size
    fmul s14, s8, s10
    // s15 = (1 - dt) * cell_size
    fsub s15, s10, s14

    GET_SNAKE_COLOUR x26

    add x7, x19, BODY_OFFSET
    // skip drawing tail most cell as lerped if an apple was hit last update
    cbnz w24, after_draw_tail_most_cell

    // draw tail most cell
    mov w0, #2
    mul w1, w0, w25
    ldrb w2, [x7, x1]
    // x_index
    scvtf s0, w2
    add w1, w1, #1
    ldrb w2, [x7, x1]
    // y_index
    scvtf s1, w2
    // increment tail
    GET_CELL_COUNT_2D w1
    INC_CLAMP_ZERO_TO_N w25, w1
    mul w1, w0, w25
    ldrb w2, [x7, x1]
    // next_x_index
    scvtf s2, w2
    add w1, w1, #1
    ldrb w2, [x7, x1]
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

    after_draw_tail_most_cell:

    // draw snake body (excluding head)
    add x27, x19, BODY_OFFSET
    b draw_body_loop_condition

    draw_body_loop:
        mov w0, #2
        mul w0, w0, w25
        ldrb w1, [x27, x0]
        // x_index
        scvtf s0, w1
        add w0, w0, #1
        ldrb w1, [x27, x0]
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

        GET_CELL_COUNT_2D w0
        INC_CLAMP_ZERO_TO_N w25, w0
    draw_body_loop_condition:
        cmp w25, w21
        b.ne draw_body_loop

    // draw head
    mov w0, #2
    mul w1, w0, w25
    ldrb w2, [x27, x1]
    // x_index
    scvtf s0, w2
    add w1, w1, #1
    ldrb w2, [x27, x1]
    // y_index
    scvtf s1, w2
    GET_CELL_COUNT_2D w1
    DEC_CLAMP_ZERO_TO_N w25, w1
    mul w1, w0, w25
    ldrb w2, [x27, x1]
    // prev_x_index
    scvtf s2, w2
    add w1, w1, #1
    ldrb w2, [x27, x1]
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

    ldp fp, lr, [sp], #0x10
    ret

    // w0 => tail
    // w1 => head
    // x2 => Game struct pointer
    place_apple:
        stp fp, lr, [sp, #-0x30]!
        stp x21, x22, [sp, #0x10]
        stp x19, x20, [sp, #0x20]
        mov fp, sp
        mov w6, w0
        mov w7, w1
        // w3 = snake_length
        SNAKE_LENGTH 3, 0, 1, 4
        // w4 = cell_count_2d
        mov w5, CELL_COUNT_1D
        mul w4, w5, w5
        // w1 = cell_count_2d - snake_length
        sub w1, w4, w3
        // GetRandomValue is inclusive of both arguments
        sub w1, w1, #1
        mov w0, wzr
        bl _GetRandomValue
        // w1 = y = index / cell_count_1d
        udiv w1, w0, w5
        // w0 = x = index % cell_count_1d
        sub w5, w5, #1
        and w0, w0, w5

        // w0 = x_index
        // w1 = y_index
        // w2 = body byte index
        // w3 = body test x index
        // w4 = body test y index
        // w5 = CELL_COUNT_1D * 2
        // w6 = tail byte index (tail multipled by 2)
        // w7 = head byte index (head multipled by 2)
        // x19 = game struct pointer
        // x20 = body pointer
        mov x19, x2
        add x20, x19, BODY_OFFSET
        lsl w6, w6, #1
        lsl w7, w7, #1
        check_collision:
            mov w2, w6
            CHECK_COLLISION 0, 1, 2, 7, 3, 4, 20, 21, 9
            b.ne check_collision_done
        check_collision_increment:
            mov w3, CELL_COUNT_1D
            INC_CLAMP_ZERO_TO_N w0, w3
            // TODO(TB): make version of INC_CLAMP_ZERO_TO_N that sets condition flags?
            mov w3, CELL_COUNT_1D
            mov w4, w1
            INC_CLAMP_ZERO_TO_N w4, w3
            cmp w0, wzr
            csel w1, w4, w1, eq
            b check_collision

        check_collision_done:

        strh w0, [x19, APPLE_X_OFFSET]
        strh w1, [x19, APPLE_Y_OFFSET]

        ldp fp, lr, [sp], #0x10
        ldp x21, x22, [sp], #0x10
        ldp x19, x20, [sp], #0x10
        ret

    // x0 => Game struct pointer
    init_based_on_window_size:
        stp fp, lr, [sp, #-0x30]!
        stp x19, x20, [sp, #0x10]
        stp d8, d9, [sp, #0x20]
        mov fp, sp

        mov x19, x0

        bl _GetScreenWidth
        scvtf s8, x0 // screen width (pixels)

        bl _GetScreenHeight
        scvtf s9, x0 // screen height (pixels)

        fmin s0, s8, s9 // board size 1d (pixels)

        fsub s1, s8, s9
        mov x0, #2
        scvtf s2, x0
        fdiv s1, s1, s2
        scvtf s4, wzr
        fmax s1, s1, s4 // board x offset (pixels)

        fsub s3, s9, s8
        fdiv s3, s3, s2

        fmax s3, s3, s4 // board y offset (pixels)

        mov x0, CELL_COUNT_1D
        scvtf s4, x0 // board cell count 1d

        mov x0, MARGIN_DIVISOR
        scvtf s2, x0 // margin divisor

        // cell_size
        fmov s7, #1
        fmadd s5, s2, s4, s4
        fsub s5, s5, s6
        fdiv s5, s2, s5
        fmul s5, s5, s0

        fmsub s6, s4, s5, s0 // board_size_1d - (cell_count_1d * cell_size)
        fsub s2, s4, s7 // cell_count_1d - 1
        fdiv s6, s6, s2 // margin size

        // board_size_1d , board_x_position
        stp s0, s1, [x19, BOARD_SIZE_1D_OFFSET]
        // board_y_position, cell_size
        stp s3, s5, [x19, BOARD_Y_POSITION_OFFSET]
        // margin_size
        str s6, [x19, MARGIN_SIZE_OFFSET]

        ldp fp, lr, [sp], #0x10
        ldp x19, x20, [sp], #0x10
        ldp d8, d9, [sp], #0x10
        ret
