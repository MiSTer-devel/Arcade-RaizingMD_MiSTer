// SPDX-License-Identifier: GPL-3.0-or-later
// MiSTer top: selects the board from the MRA descriptor at load (RAIZING_BOARD_<NAME> fixes one board).
module emu (
    `include "sys/emu_ports.vh"
);
    assign ADC_BUS='z;
    assign USER_OUT='1;
    assign {UART_RTS,UART_TXD,UART_DTR}=0;
    assign {SD_SCK,SD_MOSI,SD_CS}='z;
    assign VGA_F1=0;
    assign VGA_SCALER=0;
    assign VGA_DISABLE=0;
    assign HDMI_BLACKOUT=0;
    assign HDMI_BOB_DEINT=0;
    assign HDMI_FREEZE=state_busy;
    assign AUDIO_S=1;
    assign AUDIO_MIX=0;
    assign LED_POWER=0;
    assign LED_DISK=0;
    assign BUTTONS=0;
    assign FB_FORCE_BLANK=0;
    `ifdef MISTER_DUAL_SDRAM
    assign {SDRAM2_CLK,SDRAM2_A,SDRAM2_BA,SDRAM2_DQ,SDRAM2_nCS,SDRAM2_nCAS,SDRAM2_nRAS,SDRAM2_nWE}='z;
    `endif

    `include "build_id.v"
    // Fixed-board builds (RAIZING_BOARD_<NAME>); none selects the board at runtime.
`ifdef RAIZING_BOARD_GAREGGA
    `define RAIZING_FIXED_BOARD 3
`elsif RAIZING_BOARD_KINGDOM
    `define RAIZING_FIXED_BOARD 2
`elsif RAIZING_BOARD_SORCER
    `define RAIZING_FIXED_BOARD 1
`endif
    localparam integer DL_AW = raizing_board_pkg::DL_ADDRESS_BITS;
    localparam CONF_STR={
        "RaizingMD;SS3E000000:400000;",
        "P1,Video Settings;",
        "P1O[17:16],Aspect Ratio,Original,Full Screen,[ARC1],[ARC2];",
        "P1O[40:39],Rotate Screen,Yes,No (Original),No (Flip);",
        "P1O[3],Scandoubler,Off,On;",
        "P1O[5:4],CRT Scanlines,None,25%,50%,75%;",
        "P1-;",
        "P1O[48],CRT H-Scale,Off,On;",
        "P1O[76:72],CRT Width,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "P1O[81:77],CRT H Offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "P1O[86:82],CRT V Offset,0,+1,+2,+3,+4,+5,+6,+7,+8,+9,+10,+11,+12,+13,+14,-14,-13,-12,-11,-10,-9,-8,-7,-6,-5,-4,-3,-2,-1;",
        "P2,Audio Settings;",
        // Audio lines: OPM/OKI boards (menumask bit 0 clear) or Bakraid's YMZ280B mix (set).
        "H0P2O[7:6],FX Volume,High,Very High,Very Low,Low;",
        "H0P2O[8],FX,On,Off;",
        "H0P2O[9],FM,On,Off;",
        "h0P2O[7:6],Volume,Normal,200%,50%,75%;",
        "h0P2O[8],Audio,On,Off;",
        "-;",
        "DIP;",
        "-;",
        "O[65:64],Savestate Slot,1,2,3,4;",
        "O[66],Autoincrement Slot,Off,On;",
        "R[67],Save State;",
        "R[68],Restore State;",
        "-;",
        "O[69],Autosave NVRAM,Off,On;",
        "T[70],Save NVRAM;",
        "-;",
        "R[0],Reset;",
        "I,Load=Up|Save=Down|Slot=Left+Right,",
        "Active Slot 1,Active Slot 2,Active Slot 3,Active Slot 4,",
        "Save State 1,Restore State 1,Save State 2,Restore State 2,",
        "Save State 3,Restore State 3,Save State 4,Restore State 4,Incompatible State;",
        "v,1;V,v",`BUILD_DATE
    };
    wire clk_sys,clk_sdram,pll_locked;
    pll pll(.refclk(CLK_50M),.rst(1'b0),.locked(pll_locked),.outclk_0(clk_sys),.outclk_1(clk_sdram));
    reg [2:0] reset_pipe=3'b111;
    always @(posedge clk_sys or posedge RESET or negedge pll_locked)
        if(RESET || !pll_locked) reset_pipe<=3'b111;
        else reset_pipe<={reset_pipe[1:0],1'b0};
    wire platform_reset=reset_pipe[2];
    altddio_out #(.width(1),.intended_device_family("Cyclone V"),.power_up_high("OFF")) sdram_clock (
        .outclock(clk_sdram),.datain_h(1'b0),.datain_l(1'b1),.dataout(SDRAM_CLK),
        .aclr(1'b0),.aset(1'b0),.oe(1'b1),.outclocken(1'b1),.sclr(1'b0),.sset(1'b0)
    );
    wire [127:0] status;
    wire menu_bakraid;   // OSD menumask bit 0: Bakraid's audio labels
    wire [1:0] buttons;
    wire [31:0] joystick_0,joystick_1;
    wire [15:0] analog_0,analog_1;
    wire [10:0] ps2_key;
    wire forced_scandoubler,direct_video,video_rotated;
    wire [21:0] gamma_bus;
    wire ioctl_download,ioctl_upload,ioctl_wr,ioctl_rd,ioctl_wait;
    wire [15:0] ioctl_index;
    wire [26:0] ioctl_addr;
    wire [7:0] ioctl_dout,nv_q;
    wire nv_request,nv_wait,hs_busy;
    wire status_update,info_request;
    wire [7:0] info_index;
    wire [1:0] selected_slot,request_slot;
    wire [127:0] status_in={status[127:66],selected_slot,status[63:0]};
    hps_io #(.CONF_STR(CONF_STR),.WIDE(0)) hps_io (
        .clk_sys(clk_sys),.HPS_BUS(HPS_BUS),.EXT_BUS(),.gamma_bus(gamma_bus),
        .forced_scandoubler(forced_scandoubler),.direct_video(direct_video),.video_rotated(video_rotated),
        .buttons(buttons),.status(status),.status_in(status_in),.status_set(status_update),.status_menumask({15'd0,menu_bakraid}),
        .ps2_key(ps2_key),.joystick_0(joystick_0),.joystick_1(joystick_1),
        .joystick_l_analog_0(analog_0),.joystick_l_analog_1(analog_1),
        .ioctl_download(ioctl_download),.ioctl_upload(ioctl_upload),.ioctl_wr(ioctl_wr),.ioctl_rd(ioctl_rd),
        .ioctl_index(ioctl_index),.ioctl_addr(ioctl_addr),.ioctl_dout(ioctl_dout),
        .ioctl_din(ioctl_index==2 ? nv_q : 8'hff),.ioctl_wait(ioctl_wait),
        .ioctl_upload_req(nv_request),.ioctl_upload_index(8'd2),.info_req(info_request),.info(info_index)
    );
    // Power-up DIPs; each MRA sends three switch bytes before the game starts.
    reg [7:0] dsw_a=0,dsw_b=0,dsw_c=8'hf2;
    always @(posedge clk_sys) if(ioctl_download && ioctl_wr && ioctl_index==254) begin
        case(ioctl_addr)
            0:dsw_a<=ioctl_dout;
            1:dsw_b<=ioctl_dout;
            2:dsw_c<=ioctl_dout;
            default:;
        endcase
    end
    // The HPS sets the file index before each download.
    (* preserve *) logic rom_index_q = 1'b0;
    always_ff @(posedge clk_sys)
        rom_index_q <= ioctl_index == 16'd0;
    wire rom_downloading=ioctl_download && rom_index_q;
    wire load_active,load_wait,rom_valid,load_error;
    wire load_stream_active,load_source_busy,load_source_error,load_host_wait;
    wire rom_stream_download,rom_stream_write;
    wire [26:0] rom_stream_address;
    wire [7:0] rom_stream_data;
    raizing_ddr_if rom_ddr(),shared_ddr();
    // MRA <rom index="1"> board descriptor; the ROM length must match that board.
    raizing_board_pkg::board_e loaded_board,selected_board;
    wire descriptor_ok,descriptor_error,selected_ok;
`ifdef RAIZING_FIXED_BOARD
    localparam logic [7:0] IMAGE_BOARDS = 8'd1 << `RAIZING_FIXED_BOARD;
`else
    localparam logic [7:0] IMAGE_BOARDS = raizing_board_pkg::RUNTIME_BOARDS;
`endif
    raizing_board_select #(.SUPPORTED(IMAGE_BOARDS)) board_select (
        .clk(clk_sys),.reset(platform_reset),.ioctl_download(ioctl_download),.ioctl_wr(ioctl_wr),
        .ioctl_index(ioctl_index),.ioctl_dout(ioctl_dout),.rom_download(rom_downloading),
        .board(loaded_board),.board_ok(descriptor_ok),.descriptor_error(descriptor_error),
        .active_board(selected_board),.active_ok(selected_ok)
    );
`ifdef RAIZING_FIXED_BOARD
    // Fixed-board builds also require the descriptor to name this board.
    localparam raizing_board_pkg::board_e active_board = raizing_board_pkg::board_e'(3'd`RAIZING_FIXED_BOARD);
    wire board_ok=descriptor_ok && loaded_board==active_board;
`else
    // Runtime build: board latched under reset from the descriptor, then its ROM loads.
    raizing_board_pkg::board_e active_board;
    assign active_board=selected_board;
    wire board_ok=selected_ok;
`endif
    wire [26:0] expected_rom_bytes=raizing_board_pkg::rom_bytes(loaded_board);
    wire pixel_ce,half_ce,sample_ce,ym_ce,ym_phase1_ce,z80_ce,oki_ce,ymz_ce,ymz_sample_ce;
    wire garegga_cadence=active_board==raizing_board_pkg::RZB_GAREGGA;
    wire batrider_cadence=active_board==raizing_board_pkg::RZB_BATRIDER;
    wire bakraid_cadence=active_board==raizing_board_pkg::RZB_BAKRAID;
    assign menu_bakraid=bakraid_cadence;
    wire late_board=batrider_cadence || bakraid_cadence;
    // Bakraid audio-phase state (rzbakraid_audio_state below).
    wire audio_clock_hold,audio_phase_load,clock_state_error;
    wire [31:0] audio_phase_restore,audio_phase_capture;
    raizing_rom_source rom_source (
        .clk(clk_sys),.reset(platform_reset),.rom_bytes(expected_rom_bytes),.host_download(rom_downloading),
        .host_write(ioctl_wr && ioctl_index==0),.host_address(ioctl_addr),.host_data(ioctl_dout),
        .abort(ioctl_download && ioctl_index==16'd1),
        .host_wait(load_host_wait),.busy(load_source_busy),.error(load_source_error),
        .stream_download(rom_stream_download),.stream_write(rom_stream_write),
        .stream_address(rom_stream_address),.stream_data(rom_stream_data),.stream_wait(load_wait),.ddr(rom_ddr)
    );
    assign load_active=load_source_busy || load_stream_active;
    // The ROM transport uses raw load_active and owns the SDRAM drain.
    logic game_load_active;
    always_ff @(posedge clk_sys)
        if (platform_reset) game_load_active <= 1'b1;
        else game_load_active <= load_active;
    wire [31:0] rom_crc,rom_length;
    wire dl_valid,dl_ready,dl_busy,dl_error;
    wire [DL_AW-1:0] dl_addr;
    wire [7:0] dl_data;
    raizing_download download (
        .clk(clk_sys),.reset(platform_reset),.rom_bytes(expected_rom_bytes),.downloading(rom_stream_download),
        .write(rom_stream_write),.address(rom_stream_address),.data(rom_stream_data),
        .wait_request(load_wait),.active(load_stream_active),.valid(rom_valid),.error(load_error),
        .crc(rom_crc),.length(rom_length),.dl_valid(dl_valid),.dl_address(dl_addr),.dl_data(dl_data),
        .dl_ready(dl_ready),.dl_busy(dl_busy),.dl_error(dl_error)
    );
    // Bakraid's EEPROM owner decodes the raw ioctl stream itself.
    assign ioctl_wait=(ioctl_index==0 && load_host_wait) ||
        (bakraid_cadence ? nv_wait : (ioctl_upload && ioctl_index==2 && nv_wait));
    wire memory_ready,memory_quiesced,invalidate_done;
    wire memory_quiesce,cache_invalidate;
    wire [7:0] req_valid,req_ready,rsp_valid,rsp_ready,rsp_error,port_idle,port_error;
    localparam integer ROM_AW=raizing_board_pkg::ROM_ADDR_BITS;
    // ROM lanes: program, sound, PCM, second PCM, four graphics (object channel on lane 4).
    wire [7:0] board_rom_request,board_rom_ok,rom_line_valid;
    wire [8*ROM_AW-1:0] rom_line_addr;
    wire [8*ROM_AW-1:0] board_rom_address,req_address;
    wire [255:0] board_rom_data,rsp_data;
    wire object_req_valid,object_req_ready,object_rsp_valid,object_rsp_ready,object_rsp_error;
    wire [ROM_AW-1:0] object_req_addr;
    // Batrider score layout and Bakraid supported-image check from the validated image.
    wire [3:0] score_profile_next;
    logic [3:0] score_profile;
    rzbatrider_highscore_profile score_identity (
        .rom_crc(rom_crc),.rom_length(rom_length),.progress(40'd0),.supported(),.profile(score_profile_next),
        .score_base(),.expected_addr(),.expected_data(),.expected_we()
    );
    // Score owners see the score profile and rom_valid on the same edge.
    logic score_rom_valid;
    always_ff @(posedge clk_sys) begin
        score_profile <= rom_valid ? score_profile_next : 4'd0;
        score_rom_valid <= rom_valid;
    end
    wire rom_supported;
    rzbakraid_rom_profile rom_profile (
        .image_valid(rom_valid),.image_length(rom_length),.image_crc(rom_crc),.supported(rom_supported),.profile()
    );
    wire object_error,object_deadline_miss,object_row_skipped,object_ownership_error,object_handoff_error;
    wire nv_block,nv_reset_window,eeprom_state_fault,audio_deadline_fault,board_restore_ready;
    wire sound_clock_held,sound_restore_active;
    wire [31:0] object_rsp_data;
    wire [13:0] text_rom_addr;
    wire [15:0] text_rom_data;
    // Game reset: held during load, on any download or SDRAM error, and by the OSD reset.
    logic game_reset=1'b1;
    wire game_reset_next=platform_reset || status[0] || buttons[1] || !board_ok || !rom_valid || game_load_active ||
            !memory_ready || load_error || load_source_error || dl_error ||
            (bakraid_cadence && (!rom_supported || nv_reset_window));
    // Per-board resets (bit 0 early, 1 Garegga, 2 late, 3 Batrider, 4 Bakraid), set while that board is not selected.
    wire early_cadence=active_board==raizing_board_pkg::RZB_SORCER || active_board==raizing_board_pkg::RZB_KINGDOM;
    wire [4:0] board_off=~{bakraid_cadence,batrider_cadence,late_board,garegga_cadence,early_cadence};
    logic [4:0] board_reset=5'b11111;
    reg [4:0] board_platform_reset=5'b11111;
    always_ff @(posedge clk_sys) begin
        game_reset <= game_reset_next;
        board_reset <= {5{game_reset_next}} | board_off;
    end
    always @(posedge clk_sys or posedge RESET or negedge pll_locked)
        if(RESET || !pll_locked) board_platform_reset<=5'b11111;
        else board_platform_reset<={5{reset_pipe[1]}} | board_off;
    genvar client;
    raizing_clocken clock_enables(
        .clk(clk_sys),.reset(platform_reset),.garegga(garegga_cadence),.batrider(batrider_cadence),.bakraid(bakraid_cadence),
        .audio_hold(audio_clock_hold),.state_load(audio_phase_load),.clear_state_error(game_reset),
        .state_in(audio_phase_restore),.state_out(audio_phase_capture),.state_error(clock_state_error),
        .pixel_ce(pixel_ce),.half_ce(half_ce),.sample_ce(sample_ce),
        .ym_ce(ym_ce),.ym_phase1_ce(ym_phase1_ce),.z80_ce(z80_ce),.oki_ce(oki_ce),
        .ymz_ce(ymz_ce),.ymz_sample_ce(ymz_sample_ce),.pixel_phase()
    );
    generate for(client=0;client<8;client=client+1) begin: rom_ports
        if(client==4)begin: native_object
            assign board_rom_ok[client]=0;
            assign rom_line_valid[client]=0;
            assign rom_line_addr[client*ROM_AW+:ROM_AW]=0;
            assign board_rom_data[client*32+:32]=0;
            raizing_native_rom_port port (
                .clk(clk_sys),.reset(platform_reset),.cancel(cache_invalidate || game_reset),
                .source_req_valid(object_req_valid),.source_req_ready(object_req_ready),.source_req_addr(object_req_addr),
                .source_rsp_valid(object_rsp_valid),.source_rsp_ready(object_rsp_ready),
                .source_rsp_data(object_rsp_data),.source_rsp_error(object_rsp_error),
                .req_valid(req_valid[client]),.req_ready(req_ready[client]),.req_addr(req_address[client*ROM_AW+:ROM_AW]),
                .rsp_valid(rsp_valid[client]),.rsp_ready(rsp_ready[client]),.rsp_data(rsp_data[client*32+:32]),
                .rsp_error(rsp_error[client]),.idle(port_idle[client]),.error(port_error[client])
            );
        end else begin: level_port
        raizing_rom_port port(
            .clk(clk_sys),.reset(platform_reset),.invalidate(cache_invalidate || game_reset),
            .request(!game_reset && board_rom_request[client]),.address(board_rom_address[client*ROM_AW+:ROM_AW]),
            .ok(board_rom_ok[client]),.data(board_rom_data[client*32+:32]),
            .req_valid(req_valid[client]),.req_ready(req_ready[client]),.req_addr(req_address[client*ROM_AW+:ROM_AW]),
            .rsp_valid(rsp_valid[client]),.rsp_ready(rsp_ready[client]),.rsp_data(rsp_data[client*32+:32]),
            .rsp_error(rsp_error[client]),.idle(port_idle[client]),.error(port_error[client]),
            .line_valid(rom_line_valid[client]),.line_addr(rom_line_addr[client*ROM_AW+:ROM_AW])
        );
        end
    end
    endgenerate
    raizing_memory memory (
        .board(active_board),
        .clk(clk_sys),.reset(platform_reset),.init_done(memory_ready),
        .quiesce(memory_quiesce),.invalidate(cache_invalidate),.quiesced(memory_quiesced),.invalidate_done(invalidate_done),
        .rom_req_valid(req_valid),.rom_req_ready(req_ready),.rom_req_addr(req_address),
        .rom_rsp_valid(rsp_valid),.rom_rsp_ready(rsp_ready),.rom_rsp_data(rsp_data),.rom_rsp_error(rsp_error),
        .text_addr(text_rom_addr),.text_data(text_rom_data),
        .download(load_active),.dl_valid(dl_valid),.dl_ready(dl_ready),.dl_busy(dl_busy),.dl_addr(dl_addr),.dl_data(dl_data),.dl_error(dl_error),
        .sdram_dq(SDRAM_DQ),.sdram_a(SDRAM_A),.sdram_ba(SDRAM_BA),
        .sdram_ncs(SDRAM_nCS),.sdram_nras(SDRAM_nRAS),.sdram_ncas(SDRAM_nCAS),.sdram_nwe(SDRAM_nWE),
        .sdram_dqml(SDRAM_DQML),.sdram_dqmh(SDRAM_DQMH),.sdram_cke(SDRAM_CKE)
    );
    // Board flip DIP: early boards DSW A bit 1, Garegga DSW B bit 2, late boards DSW C bit 0.
    wire board_garegga=active_board==raizing_board_pkg::RZB_GAREGGA;
    wire board_flip=late_board ? dsw_c[0] : board_garegga ? dsw_b[2] : dsw_a[1];
    wire [1:0][9:0] game_joy;
    wire [1:0] game_start,game_coin;
    wire game_service,game_pause,game_run;
    wire no_rotate,rotate_ccw,framebuffer_flip,width_enable;
    wire [4:0] width_step,h_adjust,v_adjust;
    wire [2:0] video_fx;
    wire signed [15:0] audio;
    wire [7:0] red,green,blue;
    wire lhbl,lvbl;
    wire [8:0] hcount,vcount;
    raizing_controls controls (
        .clk(clk_sys),.reset(game_reset),.status(status),.ps2_key(ps2_key),
        .joystick({joystick_1[15:0],joystick_0[15:0]}),.analog({analog_1,analog_0}),
        .active_v(lvbl),.state_busy(state_busy),
        .rotate_controls(1'b0),.board_flip(board_flip),.audio_left_in(audio),.audio_right_in(audio),
        .game_joy(game_joy),.game_start(game_start),.game_coin(game_coin),.game_service(game_service),.game_tilt(),.game_test(),
        .game_pause(game_pause),.game_run(game_run),.step_pulse(),
        .audio_left_out(AUDIO_L),.audio_right_out(AUDIO_R),.no_rotate(no_rotate),.rotate_ccw(rotate_ccw),.framebuffer_flip(framebuffer_flip),
        .aspect_x(VIDEO_ARX),.aspect_y(VIDEO_ARY),.video_fx(video_fx),
        .width_enable(width_enable),.width_step(width_step),.h_adjust(h_adjust),.v_adjust(v_adjust)
    );
    wire save_request,load_request,state_busy,load_rejected;
    raizing_ss_ui state_ui (
        .clk(clk_sys),.reset(game_reset),.ps2_key(ps2_key),.allow_ss(rom_valid && !load_active && !hs_busy && !nv_block),
        .busy(state_busy),.load_rejected(load_rejected),.joy_ss(joystick_0[13] || joystick_1[13]),
        .joy_right(joystick_0[0] || joystick_1[0]),.joy_left(joystick_0[1] || joystick_1[1]),
        .joy_down(joystick_0[2] || joystick_1[2]),.joy_up(joystick_0[3] || joystick_1[3]),
        .status_slot(status[65:64]),.autoinc_slot(status[66]),.osd_save_load({status[68],status[67]}),
        .save_request(save_request),.load_request(load_request),.info_request(info_request),.info_index(info_index),
        .status_update(status_update),.selected_slot(selected_slot),.request_slot(request_slot)
    );
    raizing_ddr_if state_ddr();
    raizing_ddr_mux rom_state_mux (
        .clk(clk_sys),.reset(platform_reset),.host(shared_ddr),
        .high_priority(rom_ddr),.low_priority(state_ddr)
    );
    raizing_ssbus_if state_bus();
    rzctx_slot_pkg::request_t ctx_request;
    rzctx_slot_pkg::response_t ctx_response;
    wire ctx_fault,legacy_slot;
    wire stream_save_start,stream_load_start,stream_busy,stream_valid,stream_fault,state_compatible;
    raizing_save_state_data #(.CHUNK_COUNT(51)) state_data (
        .clk(clk_sys),.reset(game_reset),.transport_reset(platform_reset),.ddr(state_ddr),.save_start(stream_save_start),.load_start(stream_load_start),
        .load_compatible(state_compatible),.legacy_slot(legacy_slot),.slot(request_slot),.busy(stream_busy),.load_valid(stream_valid),.fault(stream_fault),.ssbus(state_bus),
        .ctx_request(ctx_request),.ctx_response(ctx_response)
    );
    wire [63:0] identity_data,board_state_data,audio_phase_data;
    wire identity_ack,board_state_ack,audio_phase_ack;
    wire audio_devices_ready,audio_phase_fault;
    always_comb begin
        state_bus.ack=identity_ack || board_state_ack || audio_phase_ack;
        state_bus.data_out=(identity_data & {64{identity_ack}}) | (board_state_data & {64{board_state_ack}}) |
            (audio_phase_data & {64{audio_phase_ack}});
    end
    raizing_ss_identity identity (
        .board(active_board),
        .clk(clk_sys),.reset(game_reset),.rom_crc(rom_crc),.rom_length(rom_length),.rom_valid(rom_valid),
        .ss_data(state_bus.data),.ss_addr(state_bus.addr),.ss_select(state_bus.select),
        .ss_write(state_bus.write),.ss_read(state_bus.read),.ss_query(state_bus.query),
        .ss_data_out(identity_data),.ss_ack(identity_ack),.compatible(state_compatible),.legacy_slot(legacy_slot)
    );
    // Garegga registers the state-memory drain before the controller sees it.
    reg state_memory_drained;
    always @(posedge clk_sys)
        if (game_reset || !memory_quiesce) state_memory_drained <= 1'b0;
        else state_memory_drained <= memory_quiesced && (&port_idle);
    wire state_memory_ready = board_garegga ? state_memory_drained && memory_quiesce && !game_reset :
                                              memory_quiesced && (&port_idle);
    // Bakraid: the YMZ/Z80 clock phase is part of the saved state (held in reset otherwise).
    wire bakraid_state_reset=game_reset || !bakraid_cadence;
    wire [7:0] bakraid_state_select=bakraid_cadence ? state_bus.select : 8'hff;
    rzbakraid_audio_state audio_phases (
        .clk(clk_sys),.reset(bakraid_state_reset),.state_active(state_busy),.held(sound_clock_held),
        .restore_busy(sound_restore_active),.canonical_fault(sound_state_fault),.restore_commit(audio_restore),
        .phase_capture(audio_phase_capture),.phase_restore(audio_phase_restore),
        .clock_hold(audio_clock_hold),.phase_load(audio_phase_load),.devices_ready(audio_devices_ready),.fault(audio_phase_fault),
        .SS_DATA(state_bus.data),.SS_ADDR(state_bus.addr),.SS_SELECT(bakraid_state_select),
        .SS_WRITE(state_bus.write),.SS_READ(state_bus.read),.SS_QUERY(state_bus.query),
        .SS_DATA_OUT(audio_phase_data),.SS_ACK(audio_phase_ack)
    );
    wire cpu_hold,sound_hold,video_hold,ss_freeze,ram_access_enable;
    reg previous_manual;
    always @(posedge clk_sys) begin
        if(platform_reset) previous_manual<=0;
        else previous_manual<=status[70];
    end
    wire manual_save=status[70] && !previous_manual && !state_busy && !hs_busy && !nv_block && rom_valid && !load_active;
    wire cpu_quiesced,sound_held,video_held,save_ready,save_done,restore_done,handler_busy;
    wire save_begin,save_resume,restore_begin,restore_window,audio_restore,rebuild_request,state_error,video_error,sound_state_fault;
    wire frame_boundary=pixel_ce && hcount==0 && vcount==250;
    reg refill_frame;
    always @(posedge clk_sys) begin
        if(game_reset || !rebuild_request) refill_frame<=0;
        else if(frame_boundary && !video_held) refill_frame<=1;
    end
    wire state_save,state_load,nv_state_pending;
    raizing_state_admit state_admit (
        .clk(clk_sys),.reset(game_reset),.save_request(save_request),.load_request(load_request),
        .nv_block(nv_block),.state_save(state_save),.state_load(state_load),.nv_state_pending(nv_state_pending)
    );
    raizing_state state_control (
        .clk(clk_sys),.reset(game_reset),.save_request(state_save),.load_request(state_load),.user_pause(!game_run && !state_busy),
        .cpu_quiesced(cpu_quiesced),.sound_held(sound_held),.sound_fault(sound_state_fault || ctx_fault || eeprom_state_fault || audio_phase_fault || clock_state_error),.video_quiesced(video_held),
        .memory_quiesced(state_memory_ready),.cpu_save_ready(save_ready),.cpu_save_done(save_done),.cpu_restore_done(restore_done),
        .stream_busy(stream_busy),.stream_valid(stream_valid),.stream_fault(stream_fault),.load_write(state_bus.write && state_bus.select!=0),
        .mem_invalidate_done(invalidate_done),.restore_devices_ready(bakraid_cadence ? board_restore_ready && audio_devices_ready : sound_held),.rebuild_done(refill_frame),.frame_boundary(frame_boundary),
        .cpu_hold(cpu_hold),.sound_hold(sound_hold),.video_hold(video_hold),.ss_freeze(ss_freeze),
        .rom_quiesce(memory_quiesce),.cache_invalidate(cache_invalidate),.audio_restore_commit(audio_restore),
        .rebuild_request(rebuild_request),.ram_access_enable(ram_access_enable),
        .cpu_save_begin(save_begin),.cpu_save_resume(save_resume),.cpu_restore_begin(restore_begin),.cpu_restore_window(restore_window),
        .stream_save_start(stream_save_start),.stream_load_start(stream_load_start),.busy(state_busy),.load_rejected(load_rejected),.completed(),.error(state_error)
    );
    raizing_board board (
        .board(active_board),
        .score_profile(score_profile),.ymz_ce(ymz_ce),.ymz_sample_ce(ymz_sample_ce),
        .audio_gain(status[7:6]==0 ? 8'h10 : status[7:6]==1 ? 8'h20 : status[7:6]==2 ? 8'h08 : 8'h0c),
        .audio_attenuation(4'd0),.audio_enable(!status[8]),
        .object_error(object_error),.object_deadline_miss(object_deadline_miss),.object_row_skipped(object_row_skipped),
        .object_ownership_error(object_ownership_error),.object_handoff_error(object_handoff_error),
        .ioctl_download(ioctl_download),.ioctl_upload(ioctl_upload),.ioctl_index(ioctl_index),
        .ioctl_wr(ioctl_wr),.ioctl_rd(ioctl_rd),.ioctl_addr(ioctl_addr),.ioctl_dout(ioctl_dout),
        .nv_block(nv_block),.nv_restart(),.nv_reset_window(nv_reset_window),
        .state_pending(nv_state_pending),
        .eeprom_state_fault(eeprom_state_fault),.audio_deadline_fault(audio_deadline_fault),
        .restore_devices_ready(board_restore_ready),.sound_clock_held(sound_clock_held),
        .sound_restore_active(sound_restore_active),
        .clk(clk_sys),.board_reset(board_reset),.board_platform_reset(board_platform_reset),
        .pixel_ce(pixel_ce),.z80_ce(z80_ce),.ym_ce(ym_ce),.ym_phase1_ce(ym_phase1_ce),.oki_ce(oki_ce),
        .user_pause(!game_run && !state_busy),.cpu_hold(cpu_hold),.sound_hold(sound_hold),.video_hold(video_hold),
        .ram_access_enable(ram_access_enable),.ss_freeze(ss_freeze),
        .ctx_request(ctx_request),.ctx_response(ctx_response),.ctx_fault(ctx_fault),
        .save_begin(save_begin),.save_resume(save_resume),.restore_begin(restore_begin),.restore_window(restore_window),.audio_restore(audio_restore),
        .cpu_quiesced(cpu_quiesced),.sound_held(sound_held),.video_held(video_held),
        .save_ready(save_ready),.save_done(save_done),.restore_done(restore_done),.handler_busy(handler_busy),
        .joy(game_joy),.start_button(game_start),.coin(game_coin),.service(game_service),.dsw_a(dsw_a),.dsw_b(dsw_b),.dsw_c(dsw_c),
        .rom_crc(rom_crc),.rom_length(rom_length),.rom_valid(score_rom_valid),
        .fx_level(status[7:6]^2'b10),.fm_enable(!status[9]),.pcm_enable(!status[8]),
        .rom_request(board_rom_request),.rom_address(board_rom_address),.rom_data(board_rom_data),.rom_line_valid(rom_line_valid),.rom_line_addr(rom_line_addr),
        .object_req_valid(object_req_valid),.object_req_ready(object_req_ready),.object_req_addr(object_req_addr),
        .object_rsp_valid(object_rsp_valid),.object_rsp_ready(object_rsp_ready),
        .object_rsp_data(object_rsp_data),.object_rsp_error(object_rsp_error),.object_port_idle(port_idle[4]),
        .text_rom_addr(text_rom_addr),.text_rom_data(text_rom_data),.red(red),.green(green),.blue(blue),.lhbl(lhbl),.lvbl(lvbl),.hcount(hcount),.vcount(vcount),.audio(audio),
        .nv_download(ioctl_download && ioctl_index==2),.nv_upload(ioctl_upload && ioctl_index==2),
        .nv_write(ioctl_wr && ioctl_index==2),.nv_read(ioctl_rd && ioctl_index==2),.nv_addr(ioctl_addr),.nv_data(ioctl_dout),.nv_q(nv_q),
        .nv_wait(nv_wait),.nv_request(nv_request),.highscore_busy(hs_busy),.nv_manual(manual_save),.nv_autosave(status[69]),.osd_open(OSD_STATUS),
        .state_active(state_busy),.SS_DATA(state_bus.data),.SS_ADDR(state_bus.addr),.SS_SELECT(state_bus.select),
        .SS_WRITE(state_bus.write),.SS_READ(state_bus.read),.SS_QUERY(state_bus.query),.SS_DATA_OUT(board_state_data),.SS_ACK(board_state_ack),
        .video_error(video_error),.sound_state_fault(sound_state_fault)
    );
    wire [23:0] crt_rgb;
    wire crt_hs,crt_vs,crt_hb,crt_vb,crt_active;
    raizing_crt crt (
        .clk(clk_sys),.sample_ce(sample_ce),.half_ce(half_ce),.pixel_ce(pixel_ce),
        .width_enable(width_enable),.width_step(width_step),.h_adjust(h_adjust),.v_adjust(v_adjust),.border(2'd0),
        .rgb_in({red,green,blue}),.hb_in(!lhbl),.vb_in(!lvbl),.rgb_out(crt_rgb),
        .hs_out(crt_hs),.vs_out(crt_vs),.hb_out(crt_hb),.vb_out(crt_vb),.active_out(crt_active),
        .raster_hpos(),.raster_vpos(),.raster_hblank(),.raster_vblank(),.frame_start()
    );
    arcade_video #(.WIDTH(320),.DW(24)) video_output (
        .clk_video(clk_sys),.ce_pix(pixel_ce),.RGB_in(crt_rgb),.HBlank(!crt_active),.VBlank(crt_vb),.HSync(crt_hs),.VSync(crt_vs),
        .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),
        .VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.VGA_DE(VGA_DE),.VGA_SL(VGA_SL),
        .fx(video_fx),.forced_scandoubler(forced_scandoubler),.gamma_bus(gamma_bus)
    );
    wire rotation_write;
    wire [28:0] rotation_addr;
    wire [63:0] rotation_data;
    wire [7:0] rotation_mask;
    screen_rotate rotation (
        .CLK_VIDEO(CLK_VIDEO),.CE_PIXEL(CE_PIXEL),.VGA_R(VGA_R),.VGA_G(VGA_G),.VGA_B(VGA_B),
        .VGA_HS(VGA_HS),.VGA_VS(VGA_VS),.VGA_DE(VGA_DE),
        .rotate_ccw(rotate_ccw),.no_rotate(no_rotate || direct_video),.flip(framebuffer_flip && !direct_video),.video_rotated(video_rotated),
        .FB_EN(FB_EN),.FB_FORMAT(FB_FORMAT),.FB_WIDTH(FB_WIDTH),.FB_HEIGHT(FB_HEIGHT),.FB_BASE(FB_BASE),.FB_STRIDE(FB_STRIDE),.FB_VBL(FB_VBL),.FB_LL(FB_LL),
        .DDRAM_CLK(),.DDRAM_BUSY(DDRAM_BUSY),.DDRAM_BURSTCNT(),.DDRAM_ADDR(rotation_addr),.DDRAM_DIN(rotation_data),.DDRAM_BE(rotation_mask),.DDRAM_WE(rotation_write),.DDRAM_RD()
    );
    wire rotation_overflow,ddr_protocol_error;
    raizing_ddr ddr_router (
        .clk(clk_sys),.reset(platform_reset),.rotation_write(rotation_write),.rotation_word_addr(rotation_addr),
        .rotation_data(rotation_data),.rotation_byteenable(rotation_mask),.state(shared_ddr),
        .DDRAM_CLK(DDRAM_CLK),.DDRAM_BUSY(DDRAM_BUSY),.DDRAM_BURSTCNT(DDRAM_BURSTCNT),.DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT),.DDRAM_DOUT_READY(DDRAM_DOUT_READY),.DDRAM_RD(DDRAM_RD),.DDRAM_DIN(DDRAM_DIN),.DDRAM_BE(DDRAM_BE),.DDRAM_WE(DDRAM_WE),
        .rotation_level(),.rotation_high_water(),.rotation_full(),.rotation_overflow(rotation_overflow),.rotation_dropped(),.protocol_error(ddr_protocol_error),.read_pending(),.idle()
    );
    (* preserve *) logic led_user_q = 1'b0;
    always_ff @(posedge clk_sys)
        led_user_q <= load_active || state_busy || hs_busy || descriptor_error || load_error || load_source_error || state_error || video_error || rotation_overflow || ddr_protocol_error || (|port_error) || nv_block ||
            eeprom_state_fault || audio_deadline_fault || audio_phase_fault || clock_state_error || object_error;
    assign LED_USER = led_user_q;
endmodule
