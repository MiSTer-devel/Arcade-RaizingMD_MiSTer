// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer controls, CRT adjustments and DDR router.

// Two-player input mapping, pause/step and video settings.
module raizing_controls #(
    parameter ROTATE_CCW = 1'b1
) (
    input clk, reset,
    input [127:0] status,
    input [10:0] ps2_key,
    input [1:0][15:0] joystick, analog,
    input active_v, state_busy,
    input rotate_controls, board_flip,
    input signed [15:0] audio_left_in, audio_right_in,
    output reg [1:0][9:0] game_joy = '1,
    output reg [1:0] game_start = '1, game_coin = '1,
    output reg game_service = 1, game_tilt = 1,
    output game_test,
    output reg game_pause = 0,
    output game_run,
    output reg step_pulse = 0,
    output reg signed [15:0] audio_left_out = 0, audio_right_out = 0,
    output reg no_rotate = 0, rotate_ccw = ROTATE_CCW, framebuffer_flip = 0,
    output reg [12:0] aspect_x = 3, aspect_y = 4,
    output reg [2:0] video_fx = 0,
    output reg width_enable = 0,
    output reg [4:0] width_step = 0, h_adjust = 0, v_adjust = 0
);
    wire [1:0][9:0] key_joy;
    wire [1:0] key_start, key_coin;
    wire key_pause, key_service, key_tilt;
    raizing_keyboard u_keyboard (
        .clk(clk), .reset(reset), .ps2_key(ps2_key),
        .joystick(key_joy), .start(key_start), .coin(key_coin),
        .pause(key_pause), .service(key_service), .tilt(key_tilt)
    );
    wire [1:0][15:0] stick_joy;
    raizing_analog u_analog (
        .clk(clk), .reset(reset), .active_v(active_v),
        .sticks(analog), .digital(joystick), .joystick(stick_joy)
    );
    reg [1:0][9:0] filtered_keys = 0, merged_joy = '1, rotated_joy = '1;
    function automatic [9:0] rotate_joy(input [9:0] value);
        begin
            rotate_joy = value;
            if (rotate_controls)
                rotate_joy[3:0] = rotate_ccw ?
                    {value[0],value[1],value[3],value[2]} :
                    {value[1],value[0],value[2],value[3]};
        end
    endfunction
    always @(posedge clk) begin
        for (integer p = 0; p < 2; p = p + 1) begin
            if (reset) begin
                filtered_keys[p] <= 0;
                merged_joy[p] <= '1;
                rotated_joy[p] <= '1;
                game_joy[p] <= '1;
                game_start[p] <= 1;
                game_coin[p] <= 1;
            end else begin
                filtered_keys[p] <= key_joy[p];
                if (&key_joy[p][1:0]) filtered_keys[p][1:0] <= 0;
                if (&key_joy[p][3:2]) filtered_keys[p][3:2] <= 0;
                merged_joy[p] <= ~(stick_joy[p][9:0] | filtered_keys[p]);
                rotated_joy[p] <= rotate_joy(merged_joy[p]);
                game_joy[p] <= rotated_joy[p];
                game_start[p] <= ~(joystick[p][7] | key_start[p]);
                game_coin[p] <= ~(joystick[p][8] | key_coin[p]);
            end
        end
        game_service <= reset ? 1'b1 : ~key_service;
        game_tilt <= reset ? 1'b1 : ~key_tilt;
    end
    assign game_test = 1'b1;

    wire pause_level = key_pause | joystick[0][9] | joystick[1][9];
    reg last_pause = 0, last_service = 0, last_active_v = 0;
    reg step_pending = 0, stepping = 0;
    wire forced_hold = reset | state_busy;
    assign game_run = !forced_hold && (!game_pause || stepping);
    always @(posedge clk) begin
        last_pause <= pause_level;
        last_service <= key_service;
        last_active_v <= active_v;
        step_pulse <= 0;
        if (reset) begin
            game_pause <= 0;
            step_pending <= 0;
            stepping <= 0;
            last_pause <= 0;
            last_service <= 0;
        end else begin
            if (pause_level && !last_pause) begin
                game_pause <= ~game_pause;
                step_pending <= 0;
                stepping <= 0;
            end else if (!game_pause) begin
                step_pending <= 0;
                stepping <= 0;
            end else if (forced_hold) begin
                step_pending <= 0;
                stepping <= 0;
            end else begin
                if (key_service && !last_service) step_pending <= 1;
                if (!active_v && last_active_v) begin
                    stepping <= step_pending;
                    step_pulse <= step_pending;
                    step_pending <= 0;
                end
            end
        end
        audio_left_out <= game_run ? audio_left_in : 16'sd0;
        audio_right_out <= game_run ? audio_right_in : 16'sd0;
    end

    function automatic [4:0] crt_adjust(input [4:0] raw);
        crt_adjust = raw <= 14 ? raw : raw <= 28 ? raw - 5'd29 : 5'd0;
    endfunction
    wire rotated = status[40:39] == 0;
    always @(posedge clk) begin
        no_rotate <= !rotated;
        rotate_ccw <= board_flip ^ ROTATE_CCW;
        framebuffer_flip <= status[40:39] == 2;
        aspect_x <= status[17:16] == 0 ? (rotated ? 13'd3 : 13'd4) :
                    {11'd0,status[17:16] - 2'd1};
        aspect_y <= status[17:16] == 0 ? (rotated ? 13'd4 : 13'd3) : 13'd0;
        video_fx <= status[3] ? 3'd1 : status[5:4] == 0 ? 3'd0 :
                    {1'b0,status[5:4]} + 3'd1;
        width_enable <= status[48];
        width_step <= crt_adjust(status[76:72]);
        h_adjust <= crt_adjust(status[81:77]);
        v_adjust <= crt_adjust(status[86:82]);
    end
endmodule

// Signed analog stick values are decoded into digital directions.
module raizing_analog (
    input clk, reset, active_v,
    input [1:0][15:0] sticks, digital,
    output [1:0][15:0] joystick
);
    reg last_active_v = 0;
    reg [1:0] frame_phase = 0;
    always @(posedge clk) begin
        last_active_v <= active_v;
        if (reset) frame_phase <= 0;
        else if (active_v && !last_active_v) frame_phase <= frame_phase + 2'd1;
    end
    function automatic [1:0] axis_request(
        input [7:0] sample, input [1:0] buttons, phase
    );
        reg [7:0] magnitude;
        reg pulse;
        begin
            magnitude = sample[7] ? ~sample : sample;
            case (magnitude[6:4])
                3'd0: pulse = 0;
                3'd1: pulse = phase == 0;
                3'd2: pulse = phase[0];
                3'd3: pulse = phase != 0;
                default: pulse = 1;
            endcase
            axis_request = buttons;
            if (magnitude[6:4] != 0) axis_request[sample[7]] = pulse;
        end
    endfunction
    genvar player, axis;
    generate for (player = 0; player < 2; player = player + 1) begin : stick
        assign joystick[player][15:4] = digital[player][15:4];
        for (axis = 0; axis < 2; axis = axis + 1) begin : direction
            reg [1:0] sampled = 0, resolved = 0;
            always @(posedge clk) begin
                if (reset) begin
                    sampled <= 0;
                    resolved <= 0;
                end else begin
                    sampled <= axis_request(sticks[player][axis*8 +: 8],
                        digital[player][axis*2 +: 2], frame_phase);
                    resolved <= (&sampled) ? 2'b00 : sampled;
                end
            end
            assign joystick[player][axis*2 +: 2] = resolved;
        end
    end endgenerate
endmodule

// Maps keyboard scan codes to game inputs.
module raizing_keyboard (
    input clk, reset,
    input [10:0] ps2_key,
    output reg [1:0][9:0] joystick = '0,
    output reg [1:0] start = '0, coin = '0,
    output reg pause = 0, service = 0, tilt = 0
);
    reg last_event = 0;
    wire pressed = ps2_key[9];
    always @(posedge clk) begin
        last_event <= ps2_key[10];
        if (reset) begin
            joystick <= '0;
            start <= '0;
            coin <= '0;
            pause <= 0;
            service <= 0;
            tilt <= 0;
        end else if (last_event != ps2_key[10]) begin
            case (ps2_key[8:0])
                9'h022: joystick[0][9] <= pressed;
                9'h01a: joystick[0][8] <= pressed;
                9'h012: joystick[0][7] <= pressed;
                9'h029: joystick[0][6] <= pressed;
                9'h011: joystick[0][5] <= pressed;
                9'h014: joystick[0][4] <= pressed;
                9'h175: joystick[0][3] <= pressed;
                9'h172: joystick[0][2] <= pressed;
                9'h16b: joystick[0][1] <= pressed;
                9'h174: joystick[0][0] <= pressed;
                9'h024: joystick[1][8] <= pressed;
                9'h01d: joystick[1][7] <= pressed;
                9'h015: joystick[1][6] <= pressed;
                9'h01b: joystick[1][5] <= pressed;
                9'h01c: joystick[1][4] <= pressed;
                9'h02d: joystick[1][3] <= pressed;
                9'h02b: joystick[1][2] <= pressed;
                9'h023: joystick[1][1] <= pressed;
                9'h034: joystick[1][0] <= pressed;
                9'h042: joystick[1][9] <= pressed;
                9'h016: start[0] <= pressed;
                9'h01e: start[1] <= pressed;
                9'h02e: coin[0] <= pressed;
                9'h036: coin[1] <= pressed;
                9'h04d: pause <= pressed;
                9'h046: service <= pressed;
                9'h02c: tilt <= pressed;
                default:;
            endcase
        end
    end
endmodule

// CRT presentation: adjustable sync position and horizontal width.
module raizing_crt #(
    parameter integer H_TOTAL = 432, V_TOTAL = 263,
    parameter integer H_ACTIVE = 320, V_ACTIVE = 240,
    parameter integer SYNC_PHASE = 5 // sync lag behind the raster, in samples
) (
    input clk, sample_ce, half_ce, pixel_ce,
    input width_enable,
    input [4:0] width_step, h_adjust, v_adjust,
    input [1:0] border,
    input [23:0] rgb_in,
    input hb_in, vb_in,
    output [23:0] rgb_out,
    output hs_out, vs_out, hb_out, vb_out, active_out,
    output [8:0] raster_hpos, raster_vpos,
    output raster_hblank, raster_vblank, frame_start
);
    wire hs_raw, vs_raw;
    raizing_crt_sync #(
        .H_TOTAL(H_TOTAL), .V_TOTAL(V_TOTAL),
        .H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE), .SYNC_PHASE(SYNC_PHASE)
    ) u_sync (
        .clk(clk), .sample_ce(sample_ce), .h_adjust(h_adjust), .v_adjust(v_adjust),
        .hs_out(hs_raw), .vs_out(vs_raw),
        .hpos(raster_hpos), .vpos(raster_vpos),
        .hblank(raster_hblank), .vblank(raster_vblank), .frame_start(frame_start)
    );
    raizing_crt_video u_video (
        .clk(clk), .sample_ce(sample_ce), .half_ce(half_ce), .output_ce(pixel_ce),
        .width_enable(width_enable), .width_step(width_step), .border(border),
        .rgb_in(rgb_in), .hs_in(hs_raw), .vs_in(vs_raw), .hb_in(hb_in), .vb_in(vb_in),
        .rgb_out(rgb_out), .hs_out(hs_out), .vs_out(vs_out),
        .hb_out(hb_out), .vb_out(vb_out), .active_out(active_out)
    );
endmodule

// Generates adjustable sync pulses from a free-running raster.
module raizing_crt_sync #(
    parameter integer H_TOTAL = 432, V_TOTAL = 263,
    parameter integer H_ACTIVE = 320, V_ACTIVE = 240,
    parameter integer SYNC_PHASE = 0
) (
    input clk, sample_ce,
    input [4:0] h_adjust, v_adjust,
    output reg hs_out = 1, vs_out = 1,
    output [8:0] hpos, vpos,
    output hblank, vblank, frame_start
);
    reg [8:0] column = 0, row = 0;
    reg [5:0] h_remaining = 0;
    reg [1:0] v_remaining = 0;
    wire [8:0] h_start = 9'd331 + {{4{h_adjust[4]}},h_adjust};
    // vsync start: raster position offset by the adjusts; a wrapped column carries into the row
    wire [8:0] v_column_unwrapped = 9'd423 + {{4{h_adjust[4]}},h_adjust};
    wire v_column_carry = v_column_unwrapped >= H_TOTAL;
    wire [8:0] v_column = v_column_carry ? v_column_unwrapped - 9'(H_TOTAL) : v_column_unwrapped;
    wire [8:0] v_row_unwrapped = 9'd243 + {{4{v_adjust[4]}},v_adjust} + {8'd0,v_column_carry};
    wire [8:0] v_row = v_row_unwrapped >= V_TOTAL ? v_row_unwrapped - 9'(V_TOTAL) : v_row_unwrapped;
    wire [8:0] sync_column, sync_row;
    generate if (SYNC_PHASE == 0) begin : raw_phase
        assign sync_column = column;
        assign sync_row = row;
    end else begin : published_phase
        localparam [8:0] INITIAL_COLUMN = 9'(H_TOTAL-SYNC_PHASE);
        reg [8:0] phase_column = INITIAL_COLUMN, phase_row = 0;
        always @(posedge clk) if (sample_ce) begin
            if (phase_column == H_TOTAL-1) begin
                phase_column <= 0;
                phase_row <= phase_row == V_TOTAL-1 ? 9'd0 : phase_row+9'd1;
            end else phase_column <= phase_column+9'd1;
        end
        assign sync_column = phase_column;
        assign sync_row = phase_row;
    end endgenerate
    assign hpos = column;
    assign vpos = row;
    assign hblank = column >= H_ACTIVE;
    assign vblank = row >= V_ACTIVE;
    assign frame_start = sample_ce && column == 0 && row == 0;
    // free-running; not paused or restored with the game
    always @(posedge clk) if (sample_ce) begin
        if (column == H_TOTAL-1) begin
            column <= 0;
            row <= row == V_TOTAL-1 ? 9'd0 : row + 9'd1;
        end else column <= column + 9'd1;
        if (sync_column == h_start) begin
            hs_out <= 0;
            h_remaining <= 35;
        end else begin
            hs_out <= h_remaining == 0;
            if (h_remaining != 0) h_remaining <= h_remaining - 6'd1;
        end
        if (sync_column == v_column) begin
            if (sync_row == v_row) begin
                vs_out <= 0;
                v_remaining <= 3;
            end else begin
                vs_out <= v_remaining == 0;
                if (v_remaining != 0) v_remaining <= v_remaining - 2'd1;
            end
        end
    end
endmodule

// Adjusts horizontal scale without changing raster timing.
module raizing_crt_video (
    input clk, sample_ce, half_ce, output_ce,
    input width_enable,
    input [4:0] width_step,
    input [1:0] border,
    input [23:0] rgb_in,
    input hs_in, vs_in, hb_in, vb_in,
    output reg [23:0] rgb_out=0,
    output reg hs_out=0, vs_out=0, hb_out=0, vb_out=0,
    output active_out
);
    reg [8:0] write_column=0, line_length=0, first_column=0, last_column=0;
    reg [16:0] line_span=0;
    reg [9:0] previous_span=0;
    reg [8:0] next_origin=0;
    reg [15:0] read_phase=0;
    reg sampled_hs=0, active_d1=0, active_d2=0;
    reg previous_vs=0, previous_vb=0, retrace_seen=0, read_inside=0;
    reg bank=0, raw_hs=1;
    reg [23:0] line_rgb;
    wire [15:0] stride=16'd64+{{11{width_step[4]}},width_step};
    wire [9:0] centering_delta={1'b0,line_length}-previous_span;

    (* ramstyle="M10K, no_rw_check" *) reg [23:0] lines[0:1023];
    always @(posedge clk) begin
        if (sample_ce) lines[{bank,write_column}] <= rgb_in;
        line_rgb <= lines[{!bank,read_phase[15:7]}];
        raw_hs <= hs_in;
        if (hs_in && !raw_hs) bank <= !bank;
    end
    always @(posedge clk) begin
        if (half_ce) begin
            line_span <= line_span+{1'b0,stride};
            read_inside <= read_phase[15:7]>=first_column && read_phase[15:7]<=last_column;
            if (!hs_in && sampled_hs) retrace_seen <= 1;
            if (hs_in && !sampled_hs && retrace_seen) begin
                line_span <= 0;
                previous_span <= line_span[16:7];
                next_origin <= centering_delta[9:1];
                read_phase <= {next_origin,7'd0};
                retrace_seen <= 0;
            end else read_phase <= read_phase+stride;
        end
        if (sample_ce) begin
            sampled_hs <= hs_in;
            active_d1 <= !hb_in;
            active_d2 <= active_d1;
            hs_out <= hs_in;
            hb_out <= hb_in;
            vb_out <= vb_in;
            if (!hb_in && !active_d1) begin
                vb_out <= previous_vb;
                previous_vb <= vb_in;
            end
            if (hs_in && !sampled_hs) begin
                line_length <= write_column;
                write_column <= 0;
                previous_vs <= vs_in;
                vs_out <= previous_vs;
            end else write_column <= write_column+9'd1;
            if (!width_enable) begin
                vb_out <= vb_in;
                vs_out <= vs_in;
            end
            if (active_d1 && !active_d2) first_column <= write_column;
            if (hb_in && active_d1) last_column <= write_column;
            rgb_out <= !width_enable ? rgb_in : !hb_out && read_inside ? line_rgb : 24'd0;
        end
    end
    reg [8:0] border_position=0;
    reg was_active=0, border_active=0;
    always @(posedge clk) if (output_ce) begin
        was_active <= !hb_out;
        border_position <= !hb_out && !was_active ? 9'd1 : border_position+9'd1;
        if (border_position==(border[1] ? 9'd15 : 9'd7) && !hb_out) border_active <= 1;
        if (border_position==(border[1] ? 9'd303 : 9'd311)) border_active <= 0;
    end
    assign active_out=border[0] ? border_active : !hb_out;
endmodule

// Arbitrates DDR requests from the rotation FIFO and state transfer.
module raizing_ddr #(
    parameter integer ROTATION_FIFO_DEPTH = 512
) (
    input clk, reset,
    input rotation_write,
    input [28:0] rotation_word_addr,
    input [63:0] rotation_data,
    input [7:0] rotation_byteenable,
    raizing_ddr_if state,
    output DDRAM_CLK,
    input DDRAM_BUSY,
    output [7:0] DDRAM_BURSTCNT,
    output [28:0] DDRAM_ADDR,
    input [63:0] DDRAM_DOUT,
    input DDRAM_DOUT_READY,
    output DDRAM_RD,
    output [63:0] DDRAM_DIN,
    output [7:0] DDRAM_BE,
    output DDRAM_WE,
    output [ $clog2(ROTATION_FIFO_DEPTH):0] rotation_level,
    output reg [$clog2(ROTATION_FIFO_DEPTH):0] rotation_high_water = 0,
    output rotation_full,
    output reg rotation_overflow = 0,
    output reg [31:0] rotation_dropped = 0,
    output reg protocol_error = 0,
    output read_pending, idle
);
    localparam integer PTR_W = $clog2(ROTATION_FIFO_DEPTH);
    localparam [2:0] IDLE = 0, FETCH_ROTATION = 1, COMMAND = 2, WRITE_WAIT = 3;
    reg [2:0] phase = IDLE;
    reg [PTR_W-1:0] write_pointer = 0, read_pointer = 0;
    reg [PTR_W:0] used = 0;
    (* ramstyle = "M10K, no_rw_check" *) reg [100:0] rotation_fifo [0:ROTATION_FIFO_DEPTH-1];
    reg [100:0] fifo_q;
    reg command_state = 0, command_read = 0, prefer_state = 0;
    reg [28:0] command_addr = 0;
    reg [63:0] command_data = 0;
    reg [7:0] command_mask = 0, command_burst = 1;
    reg [7:0] write_remaining = 0, read_remaining = 0;

    wire accepted = phase == COMMAND && !reset && !DDRAM_BUSY;
    wire pop_rotation = accepted && !command_state;
    wire push_rotation = rotation_write && !reset && (!rotation_full || pop_rotation);
    wire accept_read = accepted && command_state && command_read;
    wire return_owned = read_remaining != 0 || accept_read;
    wire state_valid = state.acquire && (state.read || state.write);
    wire bad_state = state_valid &&
        ((state.read && state.write) || state.burstcnt == 0 || state.addr[2:0] != 0);
    wire state_request = state_valid && !bad_state && read_remaining == 0;
    wire bad_write_beat = phase == WRITE_WAIT && state.read;

    assign DDRAM_CLK = clk;
    assign DDRAM_ADDR = command_addr;
    assign DDRAM_DIN = command_data;
    assign DDRAM_BE = command_mask;
    assign DDRAM_BURSTCNT = command_burst;
    assign DDRAM_RD = !reset && phase == COMMAND && command_read;
    assign DDRAM_WE = !reset && phase == COMMAND && !command_read;
    assign rotation_level = used;
    assign rotation_full = used == ROTATION_FIFO_DEPTH;
    assign read_pending = read_remaining != 0;
    assign idle = !reset && phase == IDLE && used == 0 &&
                  read_remaining == 0 && !state_valid && !rotation_write;

    // Availability without a command is advisory; only valid && !busy accepts.
    always @* begin
        state.busy = 1;
        if (!reset) begin
            if (phase == COMMAND && command_state) state.busy = DDRAM_BUSY;
            else if (!state.read && !state.write) state.busy = 0;
        end
        state.rdata = return_owned ? DDRAM_DOUT : 64'd0;
        state.rdata_ready = !reset && DDRAM_DOUT_READY && return_owned;
    end

    // The synchronous head read is consumed one full FETCH cycle later.
    always @(posedge clk) begin
        fifo_q <= rotation_fifo[read_pointer];
        if (push_rotation)
            rotation_fifo[write_pointer] <= {rotation_word_addr,rotation_data,rotation_byteenable};
        if (reset) begin
            write_pointer <= 0;
            read_pointer <= 0;
            used <= 0;
            rotation_high_water <= 0;
            rotation_overflow <= 0;
            rotation_dropped <= 0;
        end else begin
            if (push_rotation) write_pointer <= write_pointer + 1'b1;
            if (pop_rotation) read_pointer <= read_pointer + 1'b1;
            case ({push_rotation,pop_rotation})
                2'b10: used <= used + 1'b1;
                2'b01: used <= used - 1'b1;
                default:;
            endcase
            if (push_rotation && !pop_rotation && used >= rotation_high_water)
                rotation_high_water <= used + 1'b1;
            if (rotation_write && !push_rotation) begin
                rotation_overflow <= 1;
                if (!(&rotation_dropped)) rotation_dropped <= rotation_dropped + 32'd1;
            end
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            phase <= IDLE;
            prefer_state <= 0;
            command_state <= 0;
            command_read <= 0;
            command_addr <= 0;
            command_data <= 0;
            command_mask <= 0;
            command_burst <= 1;
            write_remaining <= 0;
            read_remaining <= 0;
            protocol_error <= 0;
        end else begin
            if (bad_state || bad_write_beat || (DDRAM_DOUT_READY && !return_owned))
                protocol_error <= 1;
            if (accept_read)
                read_remaining <= command_burst - (DDRAM_DOUT_READY ? 8'd1 : 8'd0);
            else if (DDRAM_DOUT_READY && read_remaining != 0)
                read_remaining <= read_remaining - 8'd1;

            case (phase)
                IDLE: begin
                    if (state_request && (prefer_state || used == 0)) begin
                        command_state <= 1;
                        command_read <= state.read;
                        command_addr <= state.addr[31:3];
                        command_data <= state.wdata;
                        command_mask <= state.byteenable;
                        command_burst <= state.burstcnt;
                        write_remaining <= state.write ? state.burstcnt : 8'd0;
                        phase <= COMMAND;
                    end else if (used != 0) phase <= FETCH_ROTATION;
                end
                FETCH_ROTATION: begin
                    {command_addr,command_data,command_mask} <= fifo_q;
                    command_burst <= 1;
                    command_state <= 0;
                    command_read <= 0;
                    phase <= COMMAND;
                end
                COMMAND: if (accepted) begin
                    if (!command_state) begin
                        prefer_state <= 1;
                        phase <= IDLE;
                    end else if (command_read) begin
                        prefer_state <= 0;
                        phase <= IDLE;
                    end else if (write_remaining > 1) begin
                        write_remaining <= write_remaining - 8'd1;
                        phase <= WRITE_WAIT;
                    end else begin
                        write_remaining <= 0;
                        prefer_state <= 0;
                        phase <= IDLE;
                    end
                end
                WRITE_WAIT: if (state.write && !state.read) begin
                    command_data <= state.wdata;
                    command_mask <= state.byteenable;
                    phase <= COMMAND;
                end
                default: phase <= IDLE;
            endcase
        end
    end

    initial begin
        if (ROTATION_FIFO_DEPTH < 2 || (ROTATION_FIFO_DEPTH & (ROTATION_FIFO_DEPTH-1)) != 0)
            $fatal(1,"ROTATION_FIFO_DEPTH must be a power of two >= 2");
    end
endmodule
