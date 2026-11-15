// SPDX-License-Identifier: GPL-3.0-or-later
// Early, Garegga and late boards sharing one instance of each socket chip, wired to the latched board; unselected boards are held in reset.
`default_nettype none

module raizing_board (
    input raizing_board_pkg::board_e board   // latched board; changes only under reset
    // Registered game/platform resets per board (0 early, 1 Garegga, 2 late, 3 Batrider, 4 Bakraid); held while that board is not latched.
    ,input wire [4:0] board_reset, board_platform_reset
    // Held line valid/address per 24-bit ROM lane (seven-lane boards skip lane 3; lane 4 is the object port, tied to zero).
    ,input wire [7:0] rom_line_valid
    ,input wire [191:0] rom_line_addr
    ,input logic clk
    ,input logic pixel_ce
    ,input logic z80_ce
    ,input logic ym_ce
    ,input logic ym_phase1_ce
    ,input logic oki_ce
    ,input logic ymz_ce
    ,input logic ymz_sample_ce
    ,input logic user_pause
    ,input logic cpu_hold
    ,input logic sound_hold
    ,input logic video_hold
    ,input logic ram_access_enable
    ,input logic ss_freeze
    ,input rzctx_slot_pkg::request_t ctx_request
    ,output rzctx_slot_pkg::response_t ctx_response
    ,output logic ctx_fault
    ,input logic save_begin
    ,input logic save_resume
    ,input logic restore_begin
    ,input logic restore_window
    ,input logic audio_restore
    ,output logic cpu_quiesced
    ,output logic sound_held
    ,output logic video_held
    ,output logic save_ready
    ,output logic save_done
    ,output logic restore_done
    ,output logic handler_busy
    ,input logic [1:0][9:0] joy
    ,input logic [1:0] start_button
    ,input logic [1:0] coin
    ,input logic service
    ,input logic [7:0] dsw_a
    ,input logic [7:0] dsw_b
    ,input logic [7:0] dsw_c
    ,input logic [31:0] rom_crc
    ,input logic [31:0] rom_length
    ,input logic rom_valid
    ,input logic [3:0] score_profile
    ,input logic [1:0] fx_level
    ,input logic fm_enable
    ,input logic pcm_enable
    ,input logic [7:0] audio_gain
    ,input logic [3:0] audio_attenuation
    ,input logic audio_enable
    ,output wire [7:0] rom_request
    ,output wire [191:0] rom_address
    ,input wire [255:0] rom_data
    ,output logic object_req_valid
    ,input logic object_req_ready
    ,output wire [23:0] object_req_addr
    ,input logic object_rsp_valid
    ,output logic object_rsp_ready
    ,input logic [31:0] object_rsp_data
    ,input logic object_rsp_error
    ,input tri1 object_port_idle
    ,output logic object_error
    ,output logic object_deadline_miss
    ,output logic object_row_skipped
    ,output logic object_ownership_error
    ,output logic object_handoff_error
    ,output logic [7:0] red
    ,output logic [7:0] green
    ,output logic [7:0] blue
    ,output logic lhbl
    ,output logic lvbl
    ,output logic [8:0] hcount
    ,output logic [8:0] vcount
    ,output logic signed [15:0] audio
    ,input logic nv_download
    ,input logic nv_upload
    ,input logic nv_write
    ,input logic nv_read
    ,input logic [26:0] nv_addr
    ,input logic [7:0] nv_data
    ,input logic ioctl_download
    ,input logic ioctl_upload
    ,input logic ioctl_wr
    ,input logic ioctl_rd
    ,input logic [15:0] ioctl_index
    ,input logic [26:0] ioctl_addr
    ,input logic [7:0] ioctl_dout
    ,output logic [7:0] nv_q
    ,output logic nv_wait
    ,output logic nv_request
    ,output logic highscore_busy
    ,output logic nv_block
    ,output logic nv_restart
    ,output logic nv_reset_window
    ,input logic nv_manual
    ,input logic nv_autosave
    ,input logic osd_open
    ,input logic state_pending
    ,input logic state_active
    ,input logic [63:0] SS_DATA
    ,input logic [31:0] SS_ADDR
    ,input logic [7:0] SS_SELECT
    ,input logic SS_WRITE
    ,input logic SS_READ
    ,input logic SS_QUERY
    ,output logic [63:0] SS_DATA_OUT
    ,output logic SS_ACK
    ,output logic video_error
    ,output logic sound_state_fault
    ,output logic eeprom_state_fault
    ,output logic audio_deadline_fault
    ,output logic restore_devices_ready
    ,output logic sound_clock_held
    ,output logic sound_restore_active
    ,output wire logic [13:0] text_rom_addr
    ,input wire logic [15:0] text_rom_data
);
    // Registered board code: 0 early or none, 1 Garegga, 2 late; late_bakraid selects Bakraid on the late board.
    logic [1:0] board_code = 2'd0;
    logic late_bakraid = 1'b0;
    always_ff @(posedge clk) begin
        board_code[0] <= board == raizing_board_pkg::RZB_GAREGGA;
        board_code[1] <= board == raizing_board_pkg::RZB_BATRIDER || board == raizing_board_pkg::RZB_BAKRAID;
        late_bakraid <= board == raizing_board_pkg::RZB_BAKRAID;
    end

    raizing_socket_pkg::cpu_in_t l_sk_cpu_i, g_sk_cpu_i, e_sk_cpu_i, sk_cpu_i;
    raizing_socket_pkg::cpu_out_t sk_cpu_o;
    assign sk_cpu_i = board_code[1] ? l_sk_cpu_i : (board_code[0] ? g_sk_cpu_i : e_sk_cpu_i);
    raizing_socket_pkg::ctx_in_t l_sk_ctx_i, g_sk_ctx_i, e_sk_ctx_i, sk_ctx_i;
    raizing_socket_pkg::ctx_out_t sk_ctx_o;
    assign sk_ctx_i = board_code[1] ? l_sk_ctx_i : (board_code[0] ? g_sk_ctx_i : e_sk_ctx_i);
    raizing_socket_pkg::mem_in_t l_sk_mem_i, g_sk_mem_i, e_sk_mem_i, sk_mem_i;
    raizing_socket_pkg::mem_out_t sk_mem_o;
    assign sk_mem_i = board_code[1] ? l_sk_mem_i : (board_code[0] ? g_sk_mem_i : e_sk_mem_i);
    raizing_socket_pkg::dma_in_t l_sk_dma_i, sk_dma_i;
    raizing_socket_pkg::dma_out_t sk_dma_o;
    assign sk_dma_i = l_sk_dma_i;
    raizing_socket_pkg::z80_in_t l_sk_z80_i, g_sk_z80_i, e_sk_z80_i, sk_z80_i;
    raizing_socket_pkg::z80_out_t sk_z80_o, g_sk_z80_o, e_sk_z80_o;
    assign sk_z80_i = board_code[1] ? l_sk_z80_i : (board_code[0] ? g_sk_z80_i : e_sk_z80_i);
    // Z80 held rebuilt from each board's own wait_n.
    always_comb begin
        g_sk_z80_o = sk_z80_o;
        g_sk_z80_o.held = sk_z80_o.held_base || (g_sk_z80_i.wait_n && sk_z80_o.stop_ready);
        e_sk_z80_o = sk_z80_o;
        e_sk_z80_o.held = sk_z80_o.held_base || (e_sk_z80_i.wait_n && sk_z80_o.stop_ready);
    end
`ifdef SIMULATION
    always_ff @(posedge clk)
        if (!board_code[1] && (board_code[0] ? g_sk_z80_o.held : e_sk_z80_o.held) !== sk_z80_o.held)
            $fatal(1, "Z80_HELD_BOARD_MISMATCH");
`endif
    raizing_socket_pkg::fm_in_t g_sk_fm_i, e_sk_fm_i, sk_fm_i;
    raizing_socket_pkg::fm_out_t sk_fm_o;
    assign sk_fm_i = (board_code[0] ? g_sk_fm_i : e_sk_fm_i);
    raizing_socket_pkg::opm_in_t l_sk_opm_i, f_sk_opm_i, sk_opm_i;
    raizing_socket_pkg::opm_out_t sk_opm_o;
    assign sk_opm_i = board_code[1] ? (board_code[0] ? f_sk_opm_i : l_sk_opm_i) : f_sk_opm_i;
    raizing_socket_pkg::oki_in_t l_sk_oki_i, g_sk_oki_i, e_sk_oki_i, sk_oki_i;
    raizing_socket_pkg::oki_out_t sk_oki_o;
    assign sk_oki_i = board_code[1] ? l_sk_oki_i : (board_code[0] ? g_sk_oki_i : e_sk_oki_i);
    raizing_socket_pkg::video_in_t l_sk_video_i, g_sk_video_i, e_sk_video_i, sk_video_i;
    raizing_socket_pkg::video_out_t sk_video_o;
    assign sk_video_i = board_code[1] ? l_sk_video_i : (board_code[0] ? g_sk_video_i : e_sk_video_i);

    rzctx_slot_pkg::response_t l_ctx_response;
    logic l_ctx_fault;
    logic l_cpu_quiesced;
    logic l_sound_held;
    logic l_video_held;
    logic l_save_ready;
    logic l_save_done;
    logic l_restore_done;
    logic l_handler_busy;
    logic [7:0] l_rom_request;
    logic [191:0] l_rom_address;
    logic l_object_req_valid;
    logic [23:0] l_object_req_addr;
    logic l_object_rsp_ready;
    logic l_object_error;
    logic l_object_deadline_miss;
    logic l_object_row_skipped;
    logic l_object_ownership_error;
    logic l_object_handoff_error;
    logic [7:0] l_red;
    logic [7:0] l_green;
    logic [7:0] l_blue;
    logic l_lhbl;
    logic l_lvbl;
    logic [8:0] l_hcount;
    logic [8:0] l_vcount;
    logic signed [15:0] l_audio;
    logic [7:0] l_nv_q;
    logic l_nv_wait;
    logic l_nv_request;
    logic l_highscore_busy;
    logic l_nv_block;
    logic l_nv_restart;
    logic l_nv_reset_window;
    logic [63:0] l_SS_DATA_OUT;
    logic l_SS_ACK;
    logic l_video_error;
    logic l_sound_state_fault;
    logic l_eeprom_state_fault;
    logic l_audio_deadline_fault;
    logic l_restore_devices_ready;
    logic l_sound_clock_held;
    logic l_sound_restore_active;
    wire [7:0] l_rom_ok;
    assign l_rom_ok[0] = !board_reset[2] && l_rom_request[0] && rom_line_valid[0] && rom_line_addr[0 +: 24] == 24'(l_rom_address[0 +: 24]);
    assign l_rom_ok[1] = !board_reset[2] && l_rom_request[1] && rom_line_valid[1] && rom_line_addr[24 +: 24] == 24'(l_rom_address[24 +: 24]);
    assign l_rom_ok[2] = !board_reset[2] && l_rom_request[2] && rom_line_valid[2] && rom_line_addr[48 +: 24] == 24'(l_rom_address[48 +: 24]);
    assign l_rom_ok[3] = !board_reset[2] && l_rom_request[3] && rom_line_valid[3] && rom_line_addr[72 +: 24] == 24'(l_rom_address[72 +: 24]);
    assign l_rom_ok[4] = !board_reset[2] && l_rom_request[4] && rom_line_valid[4] && rom_line_addr[96 +: 24] == 24'(l_rom_address[96 +: 24]);
    assign l_rom_ok[5] = !board_reset[2] && l_rom_request[5] && rom_line_valid[5] && rom_line_addr[120 +: 24] == 24'(l_rom_address[120 +: 24]);
    assign l_rom_ok[6] = !board_reset[2] && l_rom_request[6] && rom_line_valid[6] && rom_line_addr[144 +: 24] == 24'(l_rom_address[144 +: 24]);
    assign l_rom_ok[7] = !board_reset[2] && l_rom_request[7] && rom_line_valid[7] && rom_line_addr[168 +: 24] == 24'(l_rom_address[168 +: 24]);
    rzlate_board #(.USE_SCORE_TOKEN(1'b1)) late (
        .bak(late_bakraid),
        .clk(clk),
        .reset(board_reset[2]),
        .platform_reset(board_platform_reset[2]),
        .reset_bat(board_reset[3]),
        .reset_bak(board_reset[4]),
        .platform_reset_bat(board_platform_reset[3]),
        .platform_reset_bak(board_platform_reset[4]),
        .pixel_ce(pixel_ce),
        .z80_ce(z80_ce),
        .ym_ce(ym_ce),
        .ym_phase1_ce(ym_phase1_ce),
        .oki_ce(oki_ce),
        .ymz_ce(ymz_ce),
        .ymz_sample_ce(ymz_sample_ce),
        .user_pause(user_pause),
        .cpu_hold(cpu_hold),
        .sound_hold(sound_hold),
        .video_hold(video_hold),
        .ram_access_enable(ram_access_enable),
        .ss_freeze(ss_freeze),
        .ctx_request(ctx_request),
        .ctx_response(l_ctx_response),
        .ctx_fault(l_ctx_fault),
        .save_begin(save_begin),
        .save_resume(save_resume),
        .restore_begin(restore_begin),
        .restore_window(restore_window),
        .audio_restore(audio_restore),
        .cpu_quiesced(l_cpu_quiesced),
        .sound_held(l_sound_held),
        .video_held(l_video_held),
        .save_ready(l_save_ready),
        .save_done(l_save_done),
        .restore_done(l_restore_done),
        .handler_busy(l_handler_busy),
        .joy(joy),
        .start_button(start_button),
        .coin(coin),
        .service(service),
        .dsw_a(dsw_a),
        .dsw_b(dsw_b),
        .dsw_c(dsw_c),
        .rom_crc(rom_crc),
        .rom_length(rom_length),
        .rom_valid(rom_valid),
        .score_profile(score_profile),
        .fx_level(fx_level),
        .fm_enable(fm_enable),
        .pcm_enable(pcm_enable),
        .audio_gain(audio_gain),
        .audio_attenuation(audio_attenuation),
        .audio_enable(audio_enable),
        .rom_request(l_rom_request),
        .rom_address(l_rom_address),
        .rom_data(rom_data),
        .rom_ok(l_rom_ok),
        .object_req_valid(l_object_req_valid),
        .object_req_ready(object_req_ready),
        .object_req_addr(l_object_req_addr),
        .object_rsp_valid(object_rsp_valid),
        .object_rsp_ready(l_object_rsp_ready),
        .object_rsp_data(object_rsp_data),
        .object_rsp_error(object_rsp_error),
        .object_port_idle(object_port_idle),
        .object_error(l_object_error),
        .object_deadline_miss(l_object_deadline_miss),
        .object_row_skipped(l_object_row_skipped),
        .object_ownership_error(l_object_ownership_error),
        .object_handoff_error(l_object_handoff_error),
        .red(l_red),
        .green(l_green),
        .blue(l_blue),
        .lhbl(l_lhbl),
        .lvbl(l_lvbl),
        .hcount(l_hcount),
        .vcount(l_vcount),
        .audio(l_audio),
        .nv_download(nv_download),
        .nv_upload(nv_upload),
        .nv_write(nv_write),
        .nv_read(nv_read),
        .nv_addr(nv_addr),
        .nv_data(nv_data),
        .ioctl_download(ioctl_download),
        .ioctl_upload(ioctl_upload),
        .ioctl_wr(ioctl_wr),
        .ioctl_rd(ioctl_rd),
        .ioctl_index(ioctl_index),
        .ioctl_addr(ioctl_addr),
        .ioctl_dout(ioctl_dout),
        .nv_q(l_nv_q),
        .nv_wait(l_nv_wait),
        .nv_request(l_nv_request),
        .highscore_busy(l_highscore_busy),
        .nv_block(l_nv_block),
        .nv_restart(l_nv_restart),
        .nv_reset_window(l_nv_reset_window),
        .nv_manual(nv_manual),
        .nv_autosave(nv_autosave),
        .osd_open(osd_open),
        .state_pending(state_pending),
        .state_active(state_active),
        .SS_DATA(SS_DATA),
        .SS_ADDR(SS_ADDR),
        .SS_SELECT(SS_SELECT),
        .SS_WRITE(SS_WRITE),
        .SS_READ(SS_READ),
        .SS_QUERY(SS_QUERY),
        .SS_DATA_OUT(l_SS_DATA_OUT),
        .SS_ACK(l_SS_ACK),
        .video_error(l_video_error),
        .sound_state_fault(l_sound_state_fault),
        .eeprom_state_fault(l_eeprom_state_fault),
        .audio_deadline_fault(l_audio_deadline_fault),
        .restore_devices_ready(l_restore_devices_ready),
        .sound_clock_held(l_sound_clock_held),
        .sound_restore_active(l_sound_restore_active),
        .sk_cpu_i(l_sk_cpu_i), .sk_cpu_o(sk_cpu_o),
        .sk_ctx_i(l_sk_ctx_i), .sk_ctx_o(sk_ctx_o),
        .sk_mem_i(l_sk_mem_i), .sk_mem_o(sk_mem_o),
        .sk_dma_i(l_sk_dma_i), .sk_dma_o(sk_dma_o),
        .sk_z80_i(l_sk_z80_i), .sk_z80_o(sk_z80_o),
        .sk_opm_i(l_sk_opm_i), .sk_opm_o(sk_opm_o),
        .sk_oki_i(l_sk_oki_i), .sk_oki_o(sk_oki_o),
        .sk_video_i(l_sk_video_i), .sk_video_o(sk_video_o)
    );

    rzctx_slot_pkg::response_t g_ctx_response;
    wire logic g_ctx_fault;
    wire logic g_cpu_quiesced;
    wire logic g_sound_held;
    wire logic g_video_held;
    wire logic g_save_ready;
    wire logic g_save_done;
    wire logic g_restore_done;
    wire logic g_handler_busy;
    wire logic [6:0] g_rom_request;
    wire logic [160:0] g_rom_address;
    wire logic g_object_req_valid;
    wire logic [22:0] g_object_req_addr;
    wire logic g_object_rsp_ready;
    wire logic [13:0] g_text_rom_addr;
    wire logic [7:0] g_red;
    wire logic [7:0] g_green;
    wire logic [7:0] g_blue;
    wire logic g_lhbl;
    wire logic g_lvbl;
    wire logic [8:0] g_hcount;
    wire logic [8:0] g_vcount;
    wire logic signed [15:0] g_audio;
    wire logic [7:0] g_nv_q;
    wire logic g_nv_wait;
    wire logic g_nv_request;
    wire logic g_highscore_busy;
    wire logic [63:0] g_SS_DATA_OUT;
    wire logic g_SS_ACK;
    wire logic g_video_error;
    wire logic g_sound_state_fault;
    wire [6:0] g_rom_ok;
    assign g_rom_ok[0] = !board_reset[1] && g_rom_request[0] && rom_line_valid[0] && rom_line_addr[0 +: 24] == 24'(g_rom_address[0 +: 23]);
    assign g_rom_ok[1] = !board_reset[1] && g_rom_request[1] && rom_line_valid[1] && rom_line_addr[24 +: 24] == 24'(g_rom_address[23 +: 23]);
    assign g_rom_ok[2] = !board_reset[1] && g_rom_request[2] && rom_line_valid[2] && rom_line_addr[48 +: 24] == 24'(g_rom_address[46 +: 23]);
    assign g_rom_ok[3] = !board_reset[1] && g_rom_request[3] && rom_line_valid[4] && rom_line_addr[96 +: 24] == 24'(g_rom_address[69 +: 23]);
    assign g_rom_ok[4] = !board_reset[1] && g_rom_request[4] && rom_line_valid[5] && rom_line_addr[120 +: 24] == 24'(g_rom_address[92 +: 23]);
    assign g_rom_ok[5] = !board_reset[1] && g_rom_request[5] && rom_line_valid[6] && rom_line_addr[144 +: 24] == 24'(g_rom_address[115 +: 23]);
    assign g_rom_ok[6] = !board_reset[1] && g_rom_request[6] && rom_line_valid[7] && rom_line_addr[168 +: 24] == 24'(g_rom_address[138 +: 23]);
    rzgaregga_board garegga (
        .clk(clk),
        .reset(board_reset[1]),
        .platform_reset(board_platform_reset[1]),
        .pixel_ce(pixel_ce),
        .z80_ce(z80_ce),
        .ym_ce(ym_ce),
        .ym_phase1_ce(ym_phase1_ce),
        .oki_ce(oki_ce),
        .user_pause(user_pause),
        .cpu_hold(cpu_hold),
        .sound_hold(sound_hold),
        .video_hold(video_hold),
        .ram_access_enable(ram_access_enable),
        .ss_freeze(ss_freeze),
        .ctx_request(ctx_request),
        .ctx_response(g_ctx_response),
        .ctx_fault(g_ctx_fault),
        .save_begin(save_begin),
        .save_resume(save_resume),
        .restore_begin(restore_begin),
        .restore_window(restore_window),
        .audio_restore(audio_restore),
        .cpu_quiesced(g_cpu_quiesced),
        .sound_held(g_sound_held),
        .video_held(g_video_held),
        .save_ready(g_save_ready),
        .save_done(g_save_done),
        .restore_done(g_restore_done),
        .handler_busy(g_handler_busy),
        .joy(joy),
        .start_button(start_button),
        .coin(coin),
        .service(service),
        .dsw_a(dsw_a),
        .dsw_b(dsw_b),
        .dsw_c(dsw_c),
        .rom_crc(rom_crc),
        .rom_length(rom_length),
        .rom_valid(rom_valid),
        .fx_level(fx_level),
        .fm_enable(fm_enable),
        .pcm_enable(pcm_enable),
        .rom_request(g_rom_request),
        .rom_address(g_rom_address),
        .rom_data({rom_data[255:128], rom_data[95:0]}),
        .rom_ok(g_rom_ok),
        .object_req_valid(g_object_req_valid),
        .object_req_ready(object_req_ready),
        .object_req_addr(g_object_req_addr),
        .object_rsp_valid(object_rsp_valid),
        .object_rsp_ready(g_object_rsp_ready),
        .object_rsp_data(object_rsp_data),
        .object_rsp_error(object_rsp_error),
        .object_port_idle(object_port_idle),
        .text_rom_addr(g_text_rom_addr),
        .text_rom_data(text_rom_data),
        .red(g_red),
        .green(g_green),
        .blue(g_blue),
        .lhbl(g_lhbl),
        .lvbl(g_lvbl),
        .hcount(g_hcount),
        .vcount(g_vcount),
        .audio(g_audio),
        .nv_download(nv_download),
        .nv_upload(nv_upload),
        .nv_write(nv_write),
        .nv_read(nv_read),
        .nv_addr(nv_addr),
        .nv_data(nv_data),
        .nv_q(g_nv_q),
        .nv_wait(g_nv_wait),
        .nv_request(g_nv_request),
        .highscore_busy(g_highscore_busy),
        .nv_manual(nv_manual),
        .nv_autosave(nv_autosave),
        .osd_open(osd_open),
        .state_active(state_active),
        .SS_DATA(SS_DATA),
        .SS_ADDR(SS_ADDR),
        .SS_SELECT(SS_SELECT),
        .SS_WRITE(SS_WRITE),
        .SS_READ(SS_READ),
        .SS_QUERY(SS_QUERY),
        .SS_DATA_OUT(g_SS_DATA_OUT),
        .SS_ACK(g_SS_ACK),
        .video_error(g_video_error),
        .sound_state_fault(g_sound_state_fault),
        .sk_cpu_i(g_sk_cpu_i), .sk_cpu_o(sk_cpu_o),
        .sk_ctx_i(g_sk_ctx_i), .sk_ctx_o(sk_ctx_o),
        .sk_mem_i(g_sk_mem_i), .sk_mem_o(sk_mem_o),
        .sk_z80_i(g_sk_z80_i), .sk_z80_o(g_sk_z80_o),
        .sk_fm_i(g_sk_fm_i), .sk_fm_o(sk_fm_o),
        .sk_oki_i(g_sk_oki_i), .sk_oki_o(sk_oki_o),
        .sk_video_i(g_sk_video_i), .sk_video_o(sk_video_o)
    );

    rzctx_slot_pkg::response_t e_ctx_response;
    wire e_ctx_fault;
    wire e_cpu_quiesced;
    wire e_sound_held;
    wire e_video_held;
    wire e_save_ready;
    wire e_save_done;
    wire e_restore_done;
    wire e_handler_busy;
    wire [6:0] e_rom_request;
    wire [153:0] e_rom_address;
    wire e_object_req_valid;
    wire [21:0] e_object_req_addr;
    wire e_object_rsp_ready;
    wire [13:0] e_text_rom_addr;
    wire [7:0] e_red;
    wire [7:0] e_green;
    wire [7:0] e_blue;
    wire e_lhbl;
    wire e_lvbl;
    wire [8:0] e_hcount;
    wire [8:0] e_vcount;
    wire signed [15:0] e_audio;
    wire [7:0] e_nv_q;
    wire e_nv_wait;
    wire e_nv_request;
    wire e_highscore_busy;
    wire [63:0] e_SS_DATA_OUT;
    wire e_SS_ACK;
    wire e_video_error;
    wire e_sound_state_fault;
    wire [6:0] e_rom_ok;
    assign e_rom_ok[0] = !board_reset[0] && e_rom_request[0] && rom_line_valid[0] && rom_line_addr[0 +: 24] == 24'(e_rom_address[0 +: 22]);
    assign e_rom_ok[1] = !board_reset[0] && e_rom_request[1] && rom_line_valid[1] && rom_line_addr[24 +: 24] == 24'(e_rom_address[22 +: 22]);
    assign e_rom_ok[2] = !board_reset[0] && e_rom_request[2] && rom_line_valid[2] && rom_line_addr[48 +: 24] == 24'(e_rom_address[44 +: 22]);
    assign e_rom_ok[3] = !board_reset[0] && e_rom_request[3] && rom_line_valid[4] && rom_line_addr[96 +: 24] == 24'(e_rom_address[66 +: 22]);
    assign e_rom_ok[4] = !board_reset[0] && e_rom_request[4] && rom_line_valid[5] && rom_line_addr[120 +: 24] == 24'(e_rom_address[88 +: 22]);
    assign e_rom_ok[5] = !board_reset[0] && e_rom_request[5] && rom_line_valid[6] && rom_line_addr[144 +: 24] == 24'(e_rom_address[110 +: 22]);
    assign e_rom_ok[6] = !board_reset[0] && e_rom_request[6] && rom_line_valid[7] && rom_line_addr[168 +: 24] == 24'(e_rom_address[132 +: 22]);
    rzearly_board early (
        .board(board),
        .clk(clk),
        .reset(board_reset[0]),
        .platform_reset(board_platform_reset[0]),
        .pixel_ce(pixel_ce),
        .z80_ce(z80_ce),
        .ym_ce(ym_ce),
        .ym_phase1_ce(ym_phase1_ce),
        .oki_ce(oki_ce),
        .user_pause(user_pause),
        .cpu_hold(cpu_hold),
        .sound_hold(sound_hold),
        .video_hold(video_hold),
        .ram_access_enable(ram_access_enable),
        .ss_freeze(ss_freeze),
        .ctx_request(ctx_request),
        .ctx_response(e_ctx_response),
        .ctx_fault(e_ctx_fault),
        .save_begin(save_begin),
        .save_resume(save_resume),
        .restore_begin(restore_begin),
        .restore_window(restore_window),
        .audio_restore(audio_restore),
        .cpu_quiesced(e_cpu_quiesced),
        .sound_held(e_sound_held),
        .video_held(e_video_held),
        .save_ready(e_save_ready),
        .save_done(e_save_done),
        .restore_done(e_restore_done),
        .handler_busy(e_handler_busy),
        .joy(joy),
        .start_button(start_button),
        .coin(coin),
        .service(service),
        .dsw_a(dsw_a),
        .dsw_b(dsw_b),
        .dsw_c(dsw_c),
        .fx_level(fx_level),
        .fm_enable(fm_enable),
        .pcm_enable(pcm_enable),
        .rom_request(e_rom_request),
        .rom_address(e_rom_address),
        .rom_data({rom_data[255:128], rom_data[95:0]}),
        .rom_ok(e_rom_ok),
        .object_req_valid(e_object_req_valid),
        .object_req_ready(object_req_ready),
        .object_req_addr(e_object_req_addr),
        .object_rsp_valid(object_rsp_valid),
        .object_rsp_ready(e_object_rsp_ready),
        .object_rsp_data(object_rsp_data),
        .object_rsp_error(object_rsp_error),
        .text_rom_addr(e_text_rom_addr),
        .text_rom_data(text_rom_data),
        .red(e_red),
        .green(e_green),
        .blue(e_blue),
        .lhbl(e_lhbl),
        .lvbl(e_lvbl),
        .hcount(e_hcount),
        .vcount(e_vcount),
        .audio(e_audio),
        .nv_download(nv_download),
        .nv_upload(nv_upload),
        .nv_write(nv_write),
        .nv_read(nv_read),
        .nv_addr(nv_addr),
        .nv_data(nv_data),
        .nv_q(e_nv_q),
        .nv_wait(e_nv_wait),
        .nv_request(e_nv_request),
        .highscore_busy(e_highscore_busy),
        .nv_manual(nv_manual),
        .nv_autosave(nv_autosave),
        .osd_open(osd_open),
        .state_active(state_active),
        .SS_DATA(SS_DATA),
        .SS_ADDR(SS_ADDR),
        .SS_SELECT(SS_SELECT),
        .SS_WRITE(SS_WRITE),
        .SS_READ(SS_READ),
        .SS_QUERY(SS_QUERY),
        .SS_DATA_OUT(e_SS_DATA_OUT),
        .SS_ACK(e_SS_ACK),
        .video_error(e_video_error),
        .sound_state_fault(e_sound_state_fault),
        .sk_cpu_i(e_sk_cpu_i), .sk_cpu_o(sk_cpu_o),
        .sk_ctx_i(e_sk_ctx_i), .sk_ctx_o(sk_ctx_o),
        .sk_mem_i(e_sk_mem_i), .sk_mem_o(sk_mem_o),
        .sk_z80_i(e_sk_z80_i), .sk_z80_o(e_sk_z80_o),
        .sk_fm_i(e_sk_fm_i), .sk_fm_o(sk_fm_o),
        .sk_oki_i(e_sk_oki_i), .sk_oki_o(sk_oki_o),
        .sk_video_i(e_sk_video_i), .sk_video_o(sk_video_o)
    );

    // Selected board outputs.
    assign ctx_response = board_code[1] ? l_ctx_response : (board_code[0] ? g_ctx_response : e_ctx_response);
    assign ctx_fault = board_code[1] ? l_ctx_fault : (board_code[0] ? g_ctx_fault : e_ctx_fault);
    assign cpu_quiesced = board_code[1] ? l_cpu_quiesced : (board_code[0] ? g_cpu_quiesced : e_cpu_quiesced);
    assign sound_held = board_code[1] ? l_sound_held : (board_code[0] ? g_sound_held : e_sound_held);
    assign video_held = board_code[1] ? l_video_held : (board_code[0] ? g_video_held : e_video_held);
    assign save_ready = board_code[1] ? l_save_ready : (board_code[0] ? g_save_ready : e_save_ready);
    assign save_done = board_code[1] ? l_save_done : (board_code[0] ? g_save_done : e_save_done);
    assign restore_done = board_code[1] ? l_restore_done : (board_code[0] ? g_restore_done : e_restore_done);
    assign handler_busy = board_code[1] ? l_handler_busy : (board_code[0] ? g_handler_busy : e_handler_busy);
    assign rom_request = board_code[1] ? l_rom_request : (board_code[0] ? {g_rom_request[6:3], 1'b0, g_rom_request[2:0]} : {e_rom_request[6:3], 1'b0, e_rom_request[2:0]});
    assign rom_address[0 +: 24] = board_code[1] ? l_rom_address[0 +: 24] : (board_code[0] ? {1'd0, g_rom_address[0 +: 23]} : {2'd0, e_rom_address[0 +: 22]});
    assign rom_address[24 +: 24] = board_code[1] ? l_rom_address[24 +: 24] : (board_code[0] ? {1'd0, g_rom_address[23 +: 23]} : {2'd0, e_rom_address[22 +: 22]});
    assign rom_address[48 +: 24] = board_code[1] ? l_rom_address[48 +: 24] : (board_code[0] ? {1'd0, g_rom_address[46 +: 23]} : {2'd0, e_rom_address[44 +: 22]});
    assign rom_address[72 +: 24] = board_code[1] ? l_rom_address[72 +: 24] : 24'd0;
    assign rom_address[96 +: 24] = board_code[1] ? l_rom_address[96 +: 24] : (board_code[0] ? {1'd0, g_rom_address[69 +: 23]} : {2'd0, e_rom_address[66 +: 22]});
    assign rom_address[120 +: 24] = board_code[1] ? l_rom_address[120 +: 24] : (board_code[0] ? {1'd0, g_rom_address[92 +: 23]} : {2'd0, e_rom_address[88 +: 22]});
    assign rom_address[144 +: 24] = board_code[1] ? l_rom_address[144 +: 24] : (board_code[0] ? {1'd0, g_rom_address[115 +: 23]} : {2'd0, e_rom_address[110 +: 22]});
    assign rom_address[168 +: 24] = board_code[1] ? l_rom_address[168 +: 24] : (board_code[0] ? {1'd0, g_rom_address[138 +: 23]} : {2'd0, e_rom_address[132 +: 22]});
    assign object_req_valid = board_code[1] ? l_object_req_valid : (board_code[0] ? g_object_req_valid : e_object_req_valid);
    assign object_req_addr = board_code[1] ? l_object_req_addr : (board_code[0] ? {1'd0, g_object_req_addr} : {2'd0, e_object_req_addr});
    assign object_rsp_ready = board_code[1] ? l_object_rsp_ready : (board_code[0] ? g_object_rsp_ready : e_object_rsp_ready);
    assign object_error = board_code[1] ? (board_code[0] ? '0 : l_object_error) : '0;
    assign object_deadline_miss = board_code[1] ? (board_code[0] ? '0 : l_object_deadline_miss) : '0;
    assign object_row_skipped = board_code[1] ? (board_code[0] ? '0 : l_object_row_skipped) : '0;
    assign object_ownership_error = board_code[1] ? (board_code[0] ? '0 : l_object_ownership_error) : '0;
    assign object_handoff_error = board_code[1] ? (board_code[0] ? '0 : l_object_handoff_error) : '0;
    assign red = board_code[1] ? l_red : (board_code[0] ? g_red : e_red);
    assign green = board_code[1] ? l_green : (board_code[0] ? g_green : e_green);
    assign blue = board_code[1] ? l_blue : (board_code[0] ? g_blue : e_blue);
    assign lhbl = board_code[1] ? l_lhbl : (board_code[0] ? g_lhbl : e_lhbl);
    assign lvbl = board_code[1] ? l_lvbl : (board_code[0] ? g_lvbl : e_lvbl);
    assign hcount = board_code[1] ? l_hcount : (board_code[0] ? g_hcount : e_hcount);
    assign vcount = board_code[1] ? l_vcount : (board_code[0] ? g_vcount : e_vcount);
    assign audio = board_code[1] ? l_audio : (board_code[0] ? g_audio : e_audio);
    assign nv_q = board_code[1] ? l_nv_q : (board_code[0] ? g_nv_q : e_nv_q);
    assign nv_wait = board_code[1] ? l_nv_wait : (board_code[0] ? g_nv_wait : e_nv_wait);
    assign nv_request = board_code[1] ? l_nv_request : (board_code[0] ? g_nv_request : e_nv_request);
    assign highscore_busy = board_code[1] ? l_highscore_busy : (board_code[0] ? g_highscore_busy : e_highscore_busy);
    assign nv_block = board_code[1] ? (board_code[0] ? '0 : l_nv_block) : '0;
    assign nv_restart = board_code[1] ? (board_code[0] ? '0 : l_nv_restart) : '0;
    assign nv_reset_window = board_code[1] ? (board_code[0] ? '0 : l_nv_reset_window) : '0;
    assign SS_DATA_OUT = board_code[1] ? l_SS_DATA_OUT : (board_code[0] ? g_SS_DATA_OUT : e_SS_DATA_OUT);
    assign SS_ACK = board_code[1] ? l_SS_ACK : (board_code[0] ? g_SS_ACK : e_SS_ACK);
    assign video_error = board_code[1] ? l_video_error : (board_code[0] ? g_video_error : e_video_error);
    assign sound_state_fault = board_code[1] ? l_sound_state_fault : (board_code[0] ? g_sound_state_fault : e_sound_state_fault);
    assign eeprom_state_fault = board_code[1] ? (board_code[0] ? '0 : l_eeprom_state_fault) : '0;
    assign audio_deadline_fault = board_code[1] ? (board_code[0] ? '0 : l_audio_deadline_fault) : '0;
    assign restore_devices_ready = board_code[1] ? (board_code[0] ? '0 : l_restore_devices_ready) : '0;
    assign sound_clock_held = board_code[1] ? (board_code[0] ? '0 : l_sound_clock_held) : '0;
    assign sound_restore_active = board_code[1] ? (board_code[0] ? '0 : l_sound_restore_active) : '0;
    assign text_rom_addr = board_code[1] ? '0 : (board_code[0] ? g_text_rom_addr : e_text_rom_addr);

    // Shared chips.
    fx68k cpu (
        .clk(sk_cpu_i.clk), .HALTn(sk_cpu_i.HALTn), .extReset(sk_cpu_i.extReset), .pwrUp(sk_cpu_i.pwrUp),
        .enPhi1(sk_cpu_i.enPhi1), .enPhi2(sk_cpu_i.enPhi2), .eRWn(sk_cpu_o.eRWn), .ASn(sk_cpu_o.ASn),
        .LDSn(sk_cpu_o.LDSn), .UDSn(sk_cpu_o.UDSn), .E(sk_cpu_o.E), .VMAn(sk_cpu_o.VMAn), .FC0(sk_cpu_o.FC0),
        .FC1(sk_cpu_o.FC1), .FC2(sk_cpu_o.FC2), .BGn(sk_cpu_o.BGn), .oRESETn(sk_cpu_o.oRESETn),
        .oHALTEDn(sk_cpu_o.oHALTEDn), .DTACKn(sk_cpu_i.DTACKn), .VPAn(sk_cpu_i.VPAn), .BERRn(sk_cpu_i.BERRn),
        .BRn(sk_cpu_i.BRn), .BGACKn(sk_cpu_i.BGACKn), .IPL0n(sk_cpu_i.IPL0n), .IPL1n(sk_cpu_i.IPL1n),
        .IPL2n(sk_cpu_i.IPL2n), .iEdb(sk_cpu_i.iEdb), .oEdb(sk_cpu_o.oEdb), .eab(sk_cpu_o.eab)
    );
    rzctx_core context_core (
        .clk(sk_ctx_i.clk), .rst(sk_ctx_i.rst), .cpu_tick(sk_ctx_i.cpu_tick), .ram_lo(sk_ctx_i.ram_lo),
        .ram_hi(sk_ctx_i.ram_hi), .cpu_as_n(sk_ctx_i.cpu_as_n), .cpu_uds_n(sk_ctx_i.cpu_uds_n),
        .cpu_lds_n(sk_ctx_i.cpu_lds_n), .cpu_rw(sk_ctx_i.cpu_rw), .cpu_fc(sk_ctx_i.cpu_fc),
        .cpu_addr(sk_ctx_i.cpu_addr), .cpu_dout(sk_ctx_i.cpu_dout), .cpu_halted_n(sk_ctx_i.cpu_halted_n),
        .bus_done(sk_ctx_i.bus_done), .bus_claim(sk_ctx_o.bus_claim), .active(sk_ctx_o.active),
        .cpu_dtack_n(sk_ctx_o.cpu_dtack_n), .cpu_vpa_n(sk_ctx_o.cpu_vpa_n), .cpu_din(sk_ctx_o.cpu_din),
        .ipl7_req(sk_ctx_o.ipl7_req), .cpu_reset(sk_ctx_o.cpu_reset), .cmd_valid(sk_ctx_i.cmd_valid),
        .cmd_op(sk_ctx_i.cmd_op), .rsp_valid(sk_ctx_o.rsp_valid), .rsp_ok(sk_ctx_o.rsp_ok),
        .rsp_code(sk_ctx_o.rsp_code), .ctx_req(sk_ctx_i.ctx_req), .ctx_we(sk_ctx_i.ctx_we),
        .ctx_bank(sk_ctx_i.ctx_bank), .ctx_idx(sk_ctx_i.ctx_idx), .ctx_wdata(sk_ctx_i.ctx_wdata),
        .ctx_ack(sk_ctx_o.ctx_ack), .ctx_nak(sk_ctx_o.ctx_nak), .ctx_rdata(sk_ctx_o.ctx_rdata),
        .st_phase(sk_ctx_o.st_phase), .st_mode(sk_ctx_o.st_mode), .st_busy(sk_ctx_o.st_busy),
        .st_parked(sk_ctx_o.st_parked), .st_held(sk_ctx_o.st_held), .st_cap_valid(sk_ctx_o.st_cap_valid),
        .st_admitted(sk_ctx_o.st_admitted), .st_stale7(sk_ctx_o.st_stale7),
        .st_err_unexp(sk_ctx_o.st_err_unexp), .evt_valid(sk_ctx_o.evt_valid), .evt_code(sk_ctx_o.evt_code)
    );
    rzmem_owner #(.PROFILE("kingdom"), .TAGW(1)) bus_ram (
        .scratch_en(sk_mem_i.scratch_en), .late_en(sk_mem_i.late_en), .clk(sk_mem_i.clk), .rst(sk_mem_i.rst),
        .cpu_quiesce(sk_mem_i.cpu_quiesce), .hold_cert(sk_mem_i.hold_cert), .dma_enable(sk_mem_i.dma_enable),
        .write_block(sk_mem_i.write_block), .profile_ok(sk_mem_o.profile_ok), .idle(sk_mem_o.idle),
        .cpu_valid(sk_mem_i.cpu_valid), .cpu_ready(sk_mem_o.cpu_ready), .cpu_endpoint(sk_mem_i.cpu_endpoint),
        .cpu_index(sk_mem_i.cpu_index), .cpu_write(sk_mem_i.cpu_write), .cpu_be(sk_mem_i.cpu_be),
        .cpu_wdata(sk_mem_i.cpu_wdata), .cpu_tag(sk_mem_i.cpu_tag), .cpu_rsp_valid(sk_mem_o.cpu_rsp_valid),
        .cpu_rsp_ready(sk_mem_i.cpu_rsp_ready), .cpu_rsp_data(sk_mem_o.cpu_rsp_data),
        .cpu_rsp_driven(sk_mem_o.cpu_rsp_driven), .cpu_rsp_tag(sk_mem_o.cpu_rsp_tag),
        .cpu_rsp_error(sk_mem_o.cpu_rsp_error), .view_addr(sk_mem_i.view_addr),
        .view_wdata(sk_mem_i.view_wdata), .view_we(sk_mem_i.view_we), .view_data(sk_mem_o.view_data),
        .view_valid(sk_mem_o.view_valid), .aux_valid(sk_mem_i.aux_valid), .aux_ready(sk_mem_o.aux_ready),
        .aux_region(sk_mem_i.aux_region), .aux_addr(sk_mem_i.aux_addr), .aux_wdata(sk_mem_i.aux_wdata),
        .aux_we(sk_mem_i.aux_we), .aux_tag(sk_mem_i.aux_tag), .aux_rsp_valid(sk_mem_o.aux_rsp_valid),
        .aux_rsp_ready(sk_mem_i.aux_rsp_ready), .aux_rsp_data(sk_mem_o.aux_rsp_data),
        .aux_rsp_tag(sk_mem_o.aux_rsp_tag), .aux_rsp_error(sk_mem_o.aux_rsp_error),
        .wram_commit(sk_mem_o.wram_commit), .wram_word(sk_mem_o.wram_word), .wram_data(sk_mem_o.wram_data),
        .wram_be(sk_mem_o.wram_be), .palette_commit(sk_mem_o.palette_commit)
    );
    rztdma_top text_dma (
        .clk(sk_dma_i.clk), .reset(sk_dma_i.reset), .text_dma_start(sk_dma_i.text_dma_start),
        .palette_dma_start(sk_dma_i.palette_dma_start), .start_ready(sk_dma_o.start_ready),
        .busy(sk_dma_o.busy), .done(sk_dma_o.done), .wram_req(sk_dma_o.wram_req),
        .wram_addr(sk_dma_o.wram_addr), .wram_readack(sk_dma_i.wram_readack), .wram_data(sk_dma_i.wram_data),
        .palette_valid(sk_dma_o.palette_valid), .palette_addr(sk_dma_o.palette_addr),
        .palette_data(sk_dma_o.palette_data), .palette_be(sk_dma_o.palette_be),
        .palette_ready(sk_dma_i.palette_ready), .cpu_mirror_we(sk_dma_i.cpu_mirror_we),
        .cpu_mirror_address(sk_dma_i.cpu_mirror_address), .cpu_mirror_data(sk_dma_i.cpu_mirror_data),
        .cpu_mirror_be(sk_dma_i.cpu_mirror_be), .text_unpacked(sk_dma_o.text_unpacked),
        .ctx_mirror_commit(sk_dma_o.ctx_mirror_commit), .ctx_glyph_valid(sk_dma_o.ctx_glyph_valid),
        .ctx_glyph_before(sk_dma_o.ctx_glyph_before), .glyph_raddr(sk_dma_i.glyph_raddr),
        .glyph_rdata(sk_dma_o.glyph_rdata), .text_raddr(sk_dma_i.text_raddr),
        .text_rdata(sk_dma_o.text_rdata), .select_raddr(sk_dma_i.select_raddr),
        .select_rdata(sk_dma_o.select_rdata), .scroll_raddr(sk_dma_i.scroll_raddr),
        .scroll_rdata(sk_dma_o.scroll_rdata), .hold_request(sk_dma_i.hold_request), .held(sk_dma_o.held),
        .state_access_enable(sk_dma_i.state_access_enable), .SS_DATA(sk_dma_i.SS_DATA),
        .SS_DATA_OUT(sk_dma_o.SS_DATA_OUT), .SS_ADDR(sk_dma_i.SS_ADDR), .SS_SELECT(sk_dma_i.SS_SELECT),
        .SS_WRITE(sk_dma_i.SS_WRITE), .SS_READ(sk_dma_i.SS_READ), .SS_QUERY(sk_dma_i.SS_QUERY),
        .SS_ACK(sk_dma_o.SS_ACK)
    );
    raizing_z80 z80 (
        .clk(sk_z80_i.clk), .reset(sk_z80_i.reset), .cen(sk_z80_i.cen), .wait_n(sk_z80_i.wait_n),
        .int_n(sk_z80_i.int_n), .hold_request(sk_z80_i.hold_request), .nmi_n(sk_z80_i.nmi_n),
        .busrq_n(sk_z80_i.busrq_n), .busak_n(sk_z80_o.busak_n), .canonical_hold(sk_z80_i.canonical_hold),
        .held(sk_z80_o.held), .held_base(sk_z80_o.held_base), .stop_ready(sk_z80_o.stop_ready),
        .canonical_ready(sk_z80_o.canonical_ready),
        .canonical_service(sk_z80_o.canonical_service), .restore_busy(sk_z80_o.restore_busy),
        .canonical_fault(sk_z80_o.canonical_fault), .restore(sk_z80_i.restore),
        .restore_state(sk_z80_i.restore_state), .capture_state(sk_z80_o.capture_state),
        .restore_done(sk_z80_o.restore_done), .address(sk_z80_o.address), .data_in(sk_z80_i.data_in),
        .data_out(sk_z80_o.data_out), .rd_n(sk_z80_o.rd_n), .wr_n(sk_z80_o.wr_n), .mreq_n(sk_z80_o.mreq_n),
        .iorq_n(sk_z80_o.iorq_n), .m1_n(sk_z80_o.m1_n), .halt_n(sk_z80_o.halt_n)
    );
    rzopm_state_owner #(.SS_INDEX(20), .TIMER_LEAD_CEN(22716)) fm (
        .sk_opm_i(f_sk_opm_i), .sk_opm_o(sk_opm_o), .clk(sk_fm_i.clk), .reset(sk_fm_i.reset),
        .ym_ce(sk_fm_i.ym_ce), .cpu_held(sk_fm_i.cpu_held), .pcm_refill(sk_fm_i.pcm_refill),
        .canonical_hold(sk_fm_i.canonical_hold), .cpu_canonical_ready(sk_fm_i.cpu_canonical_ready),
        .restore_commit(sk_fm_i.restore_commit), .cs_n(sk_fm_i.cs_n), .wr_n(sk_fm_i.wr_n), .a0(sk_fm_i.a0),
        .din(sk_fm_i.din), .dout(sk_fm_o.dout), .irq_n(sk_fm_o.irq_n), .sample(sk_fm_o.sample),
        .xleft(sk_fm_o.xleft), .xright(sk_fm_o.xright), .busy(sk_fm_o.busy), .fault(sk_fm_o.fault),
        .ss_data(sk_fm_i.ss_data), .ss_addr(sk_fm_i.ss_addr), .ss_select(sk_fm_i.ss_select),
        .ss_write(sk_fm_i.ss_write), .ss_read(sk_fm_i.ss_read), .ss_query(sk_fm_i.ss_query),
        .ss_data_out(sk_fm_o.ss_data_out), .ss_ack(sk_fm_o.ss_ack)
    );
    rzopm_top opm (
        .clk(sk_opm_i.clk), .rst(sk_opm_i.rst), .chip_cen_n(sk_opm_i.chip_cen_n),
        .chip_ic_n(sk_opm_i.chip_ic_n), .cpu_cs_n(sk_opm_i.cpu_cs_n), .cpu_rd_n(sk_opm_i.cpu_rd_n),
        .cpu_wr_n(sk_opm_i.cpu_wr_n), .cpu_a0(sk_opm_i.cpu_a0), .cpu_din(sk_opm_i.cpu_din),
        .cpu_dout(sk_opm_o.cpu_dout), .cpu_dout_oe(sk_opm_o.cpu_dout_oe), .chip_phi1(sk_opm_o.chip_phi1),
        .chip_ct1(sk_opm_o.chip_ct1), .chip_ct2(sk_opm_o.chip_ct2), .chip_irq_n(sk_opm_o.chip_irq_n),
        .chip_sh1(sk_opm_o.chip_sh1), .chip_sh2(sk_opm_o.chip_sh2), .chip_so(sk_opm_o.chip_so),
        .snd_r_strobe(sk_opm_o.snd_r_strobe), .snd_l_strobe(sk_opm_o.snd_l_strobe), .snd_r(sk_opm_o.snd_r),
        .snd_l(sk_opm_o.snd_l), .snd_r_ex(sk_opm_o.snd_r_ex), .snd_l_ex(sk_opm_o.snd_l_ex),
        .mon_accept(sk_opm_o.mon_accept), .mon_is_data(sk_opm_o.mon_is_data), .mon_byte(sk_opm_o.mon_byte),
        .mon_idle(sk_opm_o.mon_idle), .hold_cert(sk_opm_i.hold_cert), .sx_req_valid(sk_opm_i.sx_req_valid),
        .sx_req_ready(sk_opm_o.sx_req_ready), .sx_req_op(sk_opm_i.sx_req_op),
        .sx_req_index(sk_opm_i.sx_req_index), .sx_req_data(sk_opm_i.sx_req_data),
        .sx_rsp_valid(sk_opm_o.sx_rsp_valid), .sx_rsp_ready(sk_opm_i.sx_rsp_ready),
        .sx_rsp_status(sk_opm_o.sx_rsp_status), .sx_rsp_data(sk_opm_o.sx_rsp_data),
        .sx_phase(sk_opm_o.sx_phase), .sx_owned(sk_opm_o.sx_owned), .sx_muted(sk_opm_o.sx_muted),
        .sx_error(sk_opm_o.sx_error), .sx_diag(sk_opm_o.sx_diag)
    );
    ss_jt6295 #(.INTERPOL(0), .SAMPLE(0)) oki (
        .rst(sk_oki_i.rst), .filter_rst(sk_oki_i.filter_rst), .clk(sk_oki_i.clk),
        .state_freeze(sk_oki_i.state_freeze), .state_frozen(sk_oki_o.state_frozen),
        .rom_request(sk_oki_o.rom_request), .resume_busy(sk_oki_o.resume_busy), .cen(sk_oki_i.cen),
        .ss(sk_oki_i.ss), .wrn(sk_oki_i.wrn), .din(sk_oki_i.din), .dout(sk_oki_o.dout),
        .rom_addr(sk_oki_o.rom_addr), .rom_data(sk_oki_i.rom_data), .rom_ok(sk_oki_i.rom_ok),
        .sound(sk_oki_o.sound), .sample(sk_oki_o.sample), .auto_ss_rd(sk_oki_i.auto_ss_rd),
        .auto_ss_wr(sk_oki_i.auto_ss_wr), .auto_ss_data_in(sk_oki_i.auto_ss_data_in),
        .auto_ss_device_idx(sk_oki_i.auto_ss_device_idx), .auto_ss_state_idx(sk_oki_i.auto_ss_state_idx),
        .auto_ss_base_device_idx(sk_oki_i.auto_ss_base_device_idx),
        .auto_ss_data_out(sk_oki_o.auto_ss_data_out), .auto_ss_ack(sk_oki_o.auto_ss_ack)
    );
    raizing_video video (
        .board(board), .clk(sk_video_i.clk), .reset(sk_video_i.reset), .pixel_ce(sk_video_i.pixel_ce),
        .flip(sk_video_i.flip), .hs_start(sk_video_i.hs_start), .hs_end(sk_video_i.hs_end),
        .vs_start(sk_video_i.vs_start), .vs_end(sk_video_i.vs_end), .gp_cs(sk_video_i.gp_cs),
        .gp_select_reg(sk_video_i.gp_select_reg), .gp_write_reg(sk_video_i.gp_write_reg),
        .gp_write_ram(sk_video_i.gp_write_ram), .gp_read_ram_h(sk_video_i.gp_read_ram_h),
        .gp_read_ram_l(sk_video_i.gp_read_ram_l), .gp_set_ram_ptr(sk_video_i.gp_set_ram_ptr),
        .gp_din(sk_video_i.gp_din), .gp_be(sk_video_i.gp_be), .gp_ack(sk_video_o.gp_ack),
        .gp_dout(sk_video_o.gp_dout), .vint_n(sk_video_o.vint_n), .cpu_hsync_n(sk_video_o.cpu_hsync_n),
        .cpu_vsync_n(sk_video_o.cpu_vsync_n), .cpu_fblank(sk_video_o.cpu_fblank), .hcount(sk_video_o.hcount),
        .vcount(sk_video_o.vcount), .gfx_req(sk_video_o.gfx_req), .gfx_addr(sk_video_o.gfx_addr),
        .gfx_data(sk_video_i.gfx_data), .gfx_ok(sk_video_i.gfx_ok),
        .object_req_valid(sk_video_o.object_req_valid), .object_req_ready(sk_video_i.object_req_ready),
        .object_req_addr(sk_video_o.object_req_addr), .object_rsp_valid(sk_video_i.object_rsp_valid),
        .object_rsp_ready(sk_video_o.object_rsp_ready), .object_rsp_data(sk_video_i.object_rsp_data),
        .object_rsp_error(sk_video_i.object_rsp_error), .object_port_idle(sk_video_i.object_port_idle),
        .gp_objectbank_wr(sk_video_i.gp_objectbank_wr), .gp_objectbank_slot(sk_video_i.gp_objectbank_slot),
        .object_deadline_miss(sk_video_o.object_deadline_miss),
        .object_row_skipped(sk_video_o.object_row_skipped),
        .object_ownership_error(sk_video_o.object_ownership_error), .object_error(sk_video_o.object_error),
        .PALRAM_ADDR(sk_video_o.PALRAM_ADDR), .PALRAM_DATA(sk_video_i.PALRAM_DATA),
        .TEXTROM_ADDR(sk_video_o.TEXTROM_ADDR), .TEXTROM_DATA(sk_video_i.TEXTROM_DATA),
        .TEXTVRAM_ADDR(sk_video_o.TEXTVRAM_ADDR), .TEXTVRAM_DATA(sk_video_i.TEXTVRAM_DATA),
        .TEXTSELECT_ADDR(sk_video_o.TEXTSELECT_ADDR), .TEXTSCROLL_ADDR(sk_video_o.TEXTSCROLL_ADDR),
        .TEXTSELECT_DATA(sk_video_i.TEXTSELECT_DATA), .TEXTSCROLL_DATA(sk_video_i.TEXTSCROLL_DATA),
        .red(sk_video_o.red), .green(sk_video_o.green), .blue(sk_video_o.blue), .hs(sk_video_o.hs),
        .vs(sk_video_o.vs), .lhbl(sk_video_o.lhbl), .lvbl(sk_video_o.lvbl), .lhbl_dly(sk_video_o.lhbl_dly),
        .lvbl_dly(sk_video_o.lvbl_dly), .SS_FREEZE(sk_video_i.SS_FREEZE), .STATE_HOLD(sk_video_i.STATE_HOLD),
        .SS_QUIESCED(sk_video_o.SS_QUIESCED), .SS_DATA(sk_video_i.SS_DATA), .SS_ADDR(sk_video_i.SS_ADDR),
        .SS_SELECT(sk_video_i.SS_SELECT), .SS_WRITE(sk_video_i.SS_WRITE), .SS_READ(sk_video_i.SS_READ),
        .SS_QUERY(sk_video_i.SS_QUERY), .SS_DATA_OUT(sk_video_o.SS_DATA_OUT), .SS_ACK(sk_video_o.SS_ACK),
        .SS_ERROR(sk_video_o.SS_ERROR), .palette_hold(sk_video_o.palette_hold),
        .palette_blank(sk_video_o.palette_blank)
    );
endmodule

`default_nettype wire
