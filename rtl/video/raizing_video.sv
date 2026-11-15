// SPDX-License-Identifier: GPL-3.0-or-later
// Pixel composition, palette output, raster timing and the board video wrapper.

package rzvideo_pkg;

  typedef enum logic [2:0] {
    WIN_BACKDROP = 3'd0,
    WIN_TILE_A   = 3'd1,
    WIN_TILE_B   = 3'd2,
    WIN_TILE_C   = 3'd3,
    WIN_SPRITE   = 3'd4,
    WIN_TEXT     = 3'd5
  } winner_e;

endpackage
// Picks the visible palette index: text first, then the highest-ranked sprite or tile.
module rzvideo_select (
  input  logic [2:0]  tile_opaque,
  input  logic [11:0] tile_rank,
  input  logic [32:0] tile_index,
  input  logic        sprite_opaque,
  input  logic [3:0]  sprite_rank,
  input  logic [10:0] sprite_index,
  input  logic        text_opaque,
  input  logic [10:0] text_index,
  output logic [10:0] palette_index,
  output logic [2:0]  winner
);
  import rzvideo_pkg::*;
  // tile rank bit 0 is ignored; ties favor sprite, then tile C, B, A
  localparam logic [3:0] TILE_RANK_MASK = 4'he;

  logic        part_a, part_b, part_c, part_s, part_t;
  logic [3:0]  eff_a, eff_b, eff_c;
  logic [10:0] idx_a, idx_b, idx_c;

  assign part_a = tile_opaque[0];
  assign part_b = tile_opaque[1];
  assign part_c = tile_opaque[2];
  assign part_s = sprite_opaque;
  assign part_t = text_opaque;

  assign eff_a = tile_rank[3:0]  & TILE_RANK_MASK;
  assign eff_b = tile_rank[7:4]  & TILE_RANK_MASK;
  assign eff_c = tile_rank[11:8] & TILE_RANK_MASK;
  assign idx_a = tile_index[10:0];
  assign idx_b = tile_index[21:11];
  assign idx_c = tile_index[32:22];

  logic        cb_part, cb_is_c;
  logic [3:0]  cb_rank;
  logic [10:0] cb_idx;

  assign cb_is_c = part_c && (!part_b || (eff_c >= eff_b));
  assign cb_part = part_c || part_b;
  assign cb_rank = cb_is_c ? eff_c : eff_b;
  assign cb_idx  = cb_is_c ? idx_c : idx_b;

  logic        tile_part, tile_is_cb;
  logic [3:0]  tile_rank_win;
  logic [10:0] tile_idx;
  logic [2:0]  tile_win;

  assign tile_is_cb    = cb_part && (!part_a || (cb_rank >= eff_a));
  assign tile_part     = cb_part || part_a;
  assign tile_rank_win = tile_is_cb ? cb_rank : eff_a;
  assign tile_idx      = tile_is_cb ? cb_idx : idx_a;

  always_comb begin
    if (!tile_is_cb)  tile_win = WIN_TILE_A;
    else if (cb_is_c) tile_win = WIN_TILE_C;
    else              tile_win = WIN_TILE_B;
  end

  logic sprite_wins;

  assign sprite_wins = part_s && (!tile_part || (sprite_rank >= tile_rank_win));

  always_comb begin
    palette_index = 11'd0;
    winner        = WIN_BACKDROP;
    if (part_t) begin
      palette_index = text_index;
      winner        = WIN_TEXT;
    end else if (sprite_wins) begin
      palette_index = sprite_index;
      winner        = WIN_SPRITE;
    end else if (tile_part) begin
      palette_index = tile_idx;
      winner        = tile_win;
    end
  end

endmodule

// Palette stage: registers the index, expands the palette word to RGB888 and delays blanking three pixel enables.
`timescale 1ns/1ps
module rzpalette_output (
  input  logic        clk,
  input  logic        pixel_ce,
  input  logic        reset,
  input  logic        lhbl,
  input  logic        lvbl,
  input  logic [10:0] selected_index,
  output logic [10:0] palette_addr,
  input  logic [15:0] palette_word,
  output logic [7:0]  red,
  output logic [7:0]  green,
  output logic [7:0]  blue,
  output logic        lhbl_dly,
  output logic        lvbl_dly
);
  // 5-bit channel to 8 bits: 8*v + floor(v/4)
  function automatic logic [7:0] expand5(input logic [4:0] v);
    expand5 = {v, v[4:2]};
  endfunction

  // reset mutes RGB only; the address and blanking history keep running

  /* verilator lint_off PROCASSINIT */
  logic [10:0] addr_q  = 11'd0;   // selected_index[n]
  logic [14:0] word_q  = 15'd0;   // palette_word[n-1] at edge n; bit 15 is never stored
  logic [3:0]  hhist_q = 4'd0;    // before edge n: [0] = lhbl[n-1] ... [3] = lhbl[n-4]
  logic [3:0]  vhist_q = 4'd0;    // the same for lvbl
  logic [23:0] rgb_q   = 24'd0;   // {red, green, blue}
  /* verilator lint_on PROCASSINIT */

  // the active flags published after edge n are lhbl[n-3] and lvbl[n-3]
  wire active_n3 = hhist_q[2] & vhist_q[2];

  always_ff @(posedge clk) begin
    if (pixel_ce) begin
      addr_q  <= selected_index;
      word_q  <= palette_word[14:0];
      hhist_q <= {hhist_q[2:0], lhbl};
      vhist_q <= {vhist_q[2:0], lvbl};
      if (reset || !active_n3) rgb_q <= 24'd0;
      else                     rgb_q <= {expand5(word_q[4:0]), expand5(word_q[9:5]), expand5(word_q[14:10])};
    end
  end

  assign palette_addr = addr_q;
  assign lhbl_dly     = hhist_q[3];
  assign lvbl_dly     = vhist_q[3];
  assign red          = rgb_q[23:16];
  assign green        = rgb_q[15:8];
  assign blue         = rgb_q[7:0];

  wire unused_bit15 = palette_word[15];
endmodule

// Raster counters: H 0..431 per pixel enable, V 0..262 advancing at H361; 320x240 visible.
`timescale 1ns/1ps
module rzraster_timing (
  input  logic       clk,
  input  logic       pixel_ce,
  input  logic       flip,          // 1: render_y = 239 - next row
  output logic [8:0] hcount,
  output logic [8:0] vcount,
  output logic [8:0] render_y,
  output logic       hs,
  output logic       vs,
  output logic       lhbl,
  output logic       lvbl,
  output logic       active,
  output logic       boundary
);
  // power-up values; the counters have no reset
  /* verilator lint_off PROCASSINIT */
  logic [8:0] h_q = 9'd0;
  logic [8:0] v_q = 9'd0;
  /* verilator lint_on PROCASSINIT */

  always_ff @(posedge clk) begin
    if (pixel_ce) begin
      h_q <= (h_q == 9'd431) ? 9'd0 : h_q + 9'd1;
      if (h_q == 9'd360) v_q <= (v_q == 9'd262) ? 9'd0 : v_q + 9'd1;   // transition to H361
    end
  end

  wire h_sync_band = (h_q >= 9'd361) && (h_q < 9'd380);      // H361..379
  wire h_tail      = (h_q >= 9'd320) && (h_q <= 9'd360);     // H320..360: end of a raster line

  // render row: the following vertical row, wrapping 262 to 0; flip reflects it around 239
  wire [8:0] next_row = (v_q == 9'd262) ? 9'd0 : v_q + 9'd1;

  assign hcount   = h_q;
  assign vcount   = v_q;
  assign render_y = flip ? (9'd239 - next_row) : next_row;
  assign hs       = h_sync_band;
  // H380/V244 up to, not including, H380/V249
  assign vs       = ((v_q == 9'd244) && !h_sync_band) || ((v_q >= 9'd245) && (v_q <= 9'd248)) ||
                    ((v_q == 9'd249) && h_sync_band);
  assign lhbl     = (h_q < 9'd320);
  // low from H320/V239 up to, not including, H320/V262
  assign lvbl     = !(((v_q == 9'd239) && h_tail) || ((v_q >= 9'd240) && (v_q <= 9'd261)) ||
                      ((v_q == 9'd262) && !h_tail));
  assign active   = lhbl && lvbl;                             // the 320 x 240 visible rectangle
  assign boundary = pixel_ce && (h_q == 9'd0) && (v_q == 9'd250);
endmodule

// CPU raster status, vblank IRQ, frame capture and save-state quiescence.
`timescale 1ns/1ps
module rzraster_control (
  input  logic       clk,
  input  logic       reset,
  input  logic       pixel_ce,
  input  logic [8:0] hcount,
  input  logic [8:0] vcount,
  input  logic       lvbl,
  input  logic       boundary,
  input  logic [8:0] hs_start,       // CPU HSYNC/VSYNC status window bounds
  input  logic [8:0] hs_end,
  input  logic [8:0] vs_start,
  input  logic [8:0] vs_end,
  input  logic       freeze,
  input  logic       state_hold,
  input  logic       state_access,   // any read, write or query asserted
  input  logic       gp_quiesce_ack,
  input  logic       gp_idle,
  input  logic       copy_idle,
  input  logic       sprite_idle,
  input  logic       tile_idle,
  input  logic       text_idle,
  input  logic       memory_idle,    // remaining memory services idle
  output logic       cpu_hsync_n,
  output logic       cpu_vsync_n,
  output logic       cpu_fblank,
  output logic       irq_event,
  output logic       capture_event,
  output logic       quiesced,
  output logic       drain,
  output logic       rebuild
);
  assign cpu_hsync_n = !((hcount > hs_start) && (hcount < hs_end));     // low strictly inside
  assign cpu_vsync_n = !((vcount >= vs_start) && (vcount <= vs_end));   // low including both ends
  assign cpu_fblank  = cpu_hsync_n && cpu_vsync_n;                      // low if either is low

  // vblank IRQ at H0/V230
  assign irq_event = pixel_ce && (hcount == 9'd0) && (vcount == 9'd230);

  // one capture per falling LVBL unless held or quiesced
  /* verilator lint_off PROCASSINIT */
  logic lvbl_hist = 1'b1;            // power-up nonblank; not saved
  logic quiesced_q = 1'b0;
  /* verilator lint_on PROCASSINIT */
  always_ff @(posedge clk) lvbl_hist <= lvbl;
  assign capture_event = lvbl_hist && !lvbl && !(reset || freeze || state_hold || quiesced_q);

  // quiescence enters and leaves only at the raster boundary (H0/V250)
  wire services_idle = gp_idle && copy_idle && sprite_idle && tile_idle && text_idle && memory_idle;
  wire may_enter     = freeze && gp_quiesce_ack && services_idle;
  wire may_leave     = !freeze && gp_idle && copy_idle && !state_access;
  always_ff @(posedge clk) begin
    if (reset)
      quiesced_q <= 1'b0;
    else if (boundary) begin
      if (!quiesced_q && may_enter) quiesced_q <= 1'b1;
      else if (quiesced_q && may_leave) quiesced_q <= 1'b0;
    end
  end

  assign quiesced = quiesced_q;
  assign drain    = reset || freeze || quiesced_q;
  assign rebuild  = reset || quiesced_q;
endmodule

`default_nettype none

module rz_video_binding #(
    parameter integer GP_PROFILE = 1,
    parameter integer RENDER_PROFILE = 2,
    parameter integer TILE_AW = 22,
    parameter integer SPRITE_AW = 23,
    parameter integer VRAM_INDEX = 25,
    parameter integer REG_INDEX = 27
) (
    input wire [1:0] narrow,   // profile narrowing: 0 none, 1 Sorcer, 2 Kingdom, 3 Garegga
    input wire tile_tail_en,   // use IRQ-time tile scroll/axis for the rest of the visible frame
    input  wire clk, reset, pixel_ce,
    input  wire [8:0] hs_start, hs_end, vs_start, vs_end,
    input  wire gp_cs, gp_select_reg, gp_write_reg, gp_write_ram,
    input  wire gp_read_ram_h, gp_read_ram_l, gp_set_ram_ptr,
    input  wire gp_objectbank_wr,
    input  wire [2:0] gp_objectbank_slot,
    input  wire [15:0] gp_din,
    input  wire [1:0] gp_be,
    output wire gp_ack,
    output wire [15:0] gp_dout,
    output wire vint_n, cpu_hsync_n, cpu_vsync_n, cpu_fblank,
    output wire [8:0] hcount, vcount,
    output wire [3:0] gfx_req,
    output wire [4*TILE_AW-1:0] gfx_addr,
    input  wire [127:0] gfx_data,
    input  wire [3:0] gfx_ok,
    output wire object_req_valid,
    input  wire object_req_ready,
    output wire [SPRITE_AW-1:0] object_req_addr,
    input  wire object_rsp_valid,
    output wire object_rsp_ready,
    input  wire [31:0] object_rsp_data,
    input  wire object_rsp_error, object_port_idle,
    output wire object_error, object_deadline_miss, object_row_skipped,
    output wire object_ownership_error,
    output wire hs, vs, lhbl, lvbl,
    input  wire SS_FREEZE, STATE_HOLD,
    output wire SS_QUIESCED,
    input  wire [63:0] SS_DATA,
    input  wire [31:0] SS_ADDR,
    input  wire [7:0] SS_SELECT,
    input  wire SS_WRITE, SS_READ, SS_QUERY,
    output wire [63:0] SS_DATA_OUT,
    output wire SS_ACK, SS_ERROR,
    output wire [8:0] render_y,
    output wire active, drain, rebuild, palette_reset,
    input  wire text_idle,
    output wire [44:0] tile_pixels,
    output wire [14:0] object_pixel,
    // palette tail hold window and vblank flag for the palette mirror
    output wire palette_hold,
    output wire palette_blank
);
    localparam EARLY = RENDER_PROFILE < 2;
    localparam LATE = RENDER_PROFILE >= 3;

    wire boundary, irq_event, capture_event;
    wire gp_quiesce_ack, gp_idle, copy_idle, sprite_idle, tile_idle;
    wire memory_idle = sprite_idle & object_port_idle;

    rzraster_timing u_timing (
        .clk(clk), .pixel_ce(pixel_ce), .flip(1'b0),
        .hcount(hcount), .vcount(vcount), .render_y(render_y),
        .hs(hs), .vs(vs), .lhbl(lhbl), .lvbl(lvbl),
        .active(active), .boundary(boundary)
    );

    rzraster_control u_control (
        .clk(clk), .reset(reset), .pixel_ce(pixel_ce),
        .hcount(hcount), .vcount(vcount), .lvbl(lvbl), .boundary(boundary),
        .hs_start(hs_start), .hs_end(hs_end), .vs_start(vs_start), .vs_end(vs_end),
        .freeze(SS_FREEZE), .state_hold(STATE_HOLD),
        .state_access(SS_WRITE | SS_READ | SS_QUERY),
        .gp_quiesce_ack(gp_quiesce_ack), .gp_idle(gp_idle), .copy_idle(copy_idle),
        .sprite_idle(sprite_idle), .tile_idle(tile_idle), .text_idle(text_idle),
        .memory_idle(memory_idle),
        .cpu_hsync_n(cpu_hsync_n), .cpu_vsync_n(cpu_vsync_n), .cpu_fblank(cpu_fblank),
        .irq_event(irq_event), .capture_event(capture_event),
        .quiesced(SS_QUIESCED), .drain(drain), .rebuild(rebuild)
    );

    wire gp_request = gp_cs & (gp_select_reg | gp_write_reg | gp_objectbank_wr |
                      gp_set_ram_ptr | gp_write_ram | gp_read_ram_h | gp_read_ram_l);
    wire [2:0] gp_operation = gp_select_reg     ? 3'd4 :
                              gp_write_reg      ? 3'd5 :
                              gp_objectbank_wr  ? 3'd6 :
                              gp_set_ram_ptr    ? 3'd0 :
                              gp_write_ram      ? 3'd1 :
                              gp_read_ram_h     ? 3'd2 : 3'd3;

    wire [31:0] object_banks;
    wire late_now = LATE && narrow == 2'd0;
    wire [31:0] render_banks = late_now ? object_banks : 32'b0;
    wire [255:0] raw_registers;
    wire [15:0] axis_flags;
    wire [7:0] gp_fault;

    wire [2:0] tile_en, tile_valid;
    wire [29:0] tile_index;
    wire [95:0] tile_pairs;
    wire job_acquire, job_release, job_held, job_valid, job_y_valid;
    wire [15:0] job_sequence, job_y;
    wire sprite_en, sprite_valid, sprite_generation_valid;
    wire [7:0] sprite_index;
    wire [63:0] sprite_entry;
    wire [15:0] sprite_sequence;

    rzgp_native_owner #(
        .PROFILE(GP_PROFILE), .VRAM_INDEX(VRAM_INDEX), .REG_INDEX(REG_INDEX)
    ) u_gp (
        .late_en(late_now),
        .clk(clk), .rst(reset), .quiesce_req(SS_FREEZE | SS_QUIESCED),
        .control_hold(STATE_HOLD), .quiesce_ack(gp_quiesce_ack),
        .request(gp_request), .operation(gp_operation), .bank_slot(gp_objectbank_slot),
        .data_in(gp_din), .byte_lanes(gp_be), .acknowledge(gp_ack), .data_out(gp_dout),
        .idle(gp_idle), .copy_idle(copy_idle), .status_word(16'hffff),
        .irq_event(irq_event), .capture_event(capture_event), .vint_n(vint_n),
        .object_banks(object_banks), .raw_registers(raw_registers),
        .raw_selector(), .axis_flags(axis_flags), .register_written(),
        .sprite_x_live(), .sprite_y_view(), .sprite_y_valid(),
        .tile_en(tile_en), .tile_index(tile_index), .tile_valid(tile_valid),
        .tile_pairs(tile_pairs),
        .job_acquire(job_acquire), .job_release(job_release), .job_held(job_held),
        .job_valid(job_valid), .job_sequence(job_sequence), .job_y(job_y),
        .job_y_valid(job_y_valid), .sprite_en(sprite_en), .sprite_index(sprite_index),
        .sprite_valid(sprite_valid), .sprite_generation_valid(sprite_generation_valid),
        .sprite_entry(sprite_entry), .sprite_sequence(sprite_sequence),
        .capture_busy(), .capture_pending(), .capture_done(), .capture_sequence(),
        .capture_counts(), .rebuilding(), .fault(gp_fault),
        .ss_data(SS_DATA), .ss_addr(SS_ADDR), .ss_select(SS_SELECT),
        .ss_write(SS_WRITE), .ss_read(SS_READ), .ss_query(SS_QUERY),
        .ss_data_out(SS_DATA_OUT), .ss_ack(SS_ACK), .ss_error(SS_ERROR)
    );

    wire [26:0] source_x, source_y;
    wire [2:0] source_dir;

    // latch tile scroll/axis at the IRQ and use them until vblank
    logic tile_tail_held;
    logic [95:0] tile_tail_scroll;
    logic [5:0] tile_tail_axis;
    wire tile_tail_visible = tile_tail_en && !reset && lvbl && tile_tail_held;
    // palette hold spans the retained-scroll window; blank covers vblank from V240
    assign palette_blank = !lvbl && vcount >= 9'd240;
    assign palette_hold = !reset && !palette_blank && (tile_tail_held || irq_event);
    always_ff @(posedge clk) begin
        if (reset || (!lvbl && vcount >= 9'd240))
            tile_tail_held <= 1'b0;
        else if (irq_event && lvbl && !tile_tail_held) begin
            tile_tail_held <= 1'b1;
            tile_tail_scroll <= raw_registers[95:0];
            tile_tail_axis <= axis_flags[5:0];
        end
    end

    rztile_origin #(.PROFILE(RENDER_PROFILE)) u_origin (
        .narrow(narrow),
        .scroll(tile_tail_visible ? tile_tail_scroll : raw_registers[95:0]),
        .axis(tile_tail_visible ? tile_tail_axis : axis_flags[5:0]), .render_y(render_y),
        .source_x(source_x), .source_y(source_y), .source_descending(source_dir),
        .profile_ok()
    );

    wire [17:0] tile_fault;
    assign gfx_req[0] = 1'b0;
    assign gfx_addr[TILE_AW-1:0] = {TILE_AW{1'b0}};

    rztile_scanline #(.PROFILE(RENDER_PROFILE), .MEM_AW(TILE_AW)) u_tile (
        .narrow(narrow),
        .clk(clk), .rst(rebuild), .pixel_ce(pixel_ce), .lhbl(lhbl), .drain(drain),
        .h(hcount), .scan_y(vcount), .render_y(render_y),
        .source_x(source_x), .source_y(source_y), .source_dir(source_dir),
        .banks(render_banks),
        .desc_en(tile_en), .desc_index(tile_index), .desc_valid(tile_valid),
        .desc_pair(tile_pairs), .mem_req(gfx_req[3:1]),
        .mem_addr(gfx_addr[4*TILE_AW-1:TILE_AW]),
        .mem_ok(gfx_ok[3:1]), .mem_data(gfx_data[127:32]),
        .pixels(tile_pixels), .idle(tile_idle), .fault(tile_fault)
    );

    wire [SPRITE_AW-1:0] sprite_byte_addr;
    wire [14:0] sprite_pixel;
    // early sprite bias and priority: early profiles, or narrowed to Sorcer or Kingdom
    wire early_now = EARLY || narrow == 2'd1 || narrow == 2'd2;

    // shared sprite port list; the early instance overrides the Y biases
`define RZ_VIDEO_SPRITE_PORTS \
        .clk(clk), .rst(rebuild), .pixel_ce(pixel_ce), .active(active), .narrow(narrow),         .early_bias(early_now), \
        .lhbl(lhbl), .lvbl(lvbl), .drain(drain), .h(hcount), .render_y(render_y), \
        .flip_x(axis_flags[6]), .flip_y(axis_flags[7]), \
        .scroll_x(raw_registers[111:96]), .banks(render_banks), \
        .gp_acquire(job_acquire), .gp_release(job_release), .gp_held(job_held), \
        .gp_job_valid(job_valid), .gp_job_seq(job_sequence), .gp_job_y(job_y), \
        .gp_job_y_valid(job_y_valid), .gp_read(sprite_en), .gp_index(sprite_index), \
        .gp_read_valid(sprite_valid), .gp_read_gen_valid(sprite_generation_valid), \
        .gp_read_seq(sprite_sequence), .gp_entry(sprite_entry), \
        .rom_req_valid(object_req_valid), .rom_req_ready(object_req_ready), \
        .rom_req_addr(sprite_byte_addr), .rom_rsp_valid(object_rsp_valid), \
        .rom_rsp_ready(object_rsp_ready), .rom_rsp_data(object_rsp_data), \
        .rom_rsp_error(object_rsp_error), .idle(sprite_idle), .pixel(sprite_pixel), \
        .deadline_miss(object_deadline_miss), .row_skipped(object_row_skipped), \
        .fault(object_ownership_error)

    generate
    if (EARLY) begin : g_early
        rzspr_scanline #(
            .PROFILE(RENDER_PROFILE), .MEM_AW(SPRITE_AW),
            .Y_BIAS(9'h1ed), .Y_FLIP_BIAS(9'h10a)
        ) u_sprite (`RZ_VIDEO_SPRITE_PORTS);
    end else begin : g_other
        rzspr_scanline #(.PROFILE(RENDER_PROFILE), .MEM_AW(SPRITE_AW))
            u_sprite (`RZ_VIDEO_SPRITE_PORTS);
    end
    endgenerate
`undef RZ_VIDEO_SPRITE_PORTS

    assign object_req_addr = sprite_byte_addr;

    wire [3:0] raised_priority = sprite_pixel[14:11] + 4'd1;
    assign object_pixel = !early_now ? sprite_pixel :
                          sprite_pixel[3:0] == 4'd0 ? 15'b0 :
                          {raised_priority, sprite_pixel[10:0]};
    assign palette_reset = reset | SS_QUIESCED;
    assign object_error = (|gp_fault) | (|tile_fault) | object_ownership_error |
                          object_deadline_miss | object_row_skipped;
endmodule

`default_nettype wire

`default_nettype none
// Connects the GP9001 and text renderers to the palette output.

module raizing_video #(
    parameter integer VRAM_INDEX = 25,
    parameter integer REG_INDEX = 27,
    // build profile; a late profile narrows to Sorcer, Kingdom or Garegga from board
    parameter raizing_board_pkg::board_e PROFILE_BOARD = raizing_board_pkg::RZB_BATRIDER,
    parameter integer OBJECT_AW = 24, TILE_AW = 24
) (
    input raizing_board_pkg::board_e board,   // latched board (constant in fixed builds)
    input wire clk, reset, pixel_ce, flip,
    input wire [8:0] hs_start, hs_end, vs_start, vs_end,
    input wire gp_cs, gp_select_reg, gp_write_reg, gp_write_ram,
    input wire gp_read_ram_h, gp_read_ram_l, gp_set_ram_ptr,
    input wire [15:0] gp_din,
    input wire [1:0] gp_be,
    output wire gp_ack,
    output wire [15:0] gp_dout,
    output wire vint_n, cpu_hsync_n, cpu_vsync_n, cpu_fblank,
    output wire [8:0] hcount, vcount,
    output wire [3:0] gfx_req,
    output wire [4*TILE_AW-1:0] gfx_addr,   // four lanes, TILE_AW bits each
    input wire [127:0] gfx_data,
    input wire [3:0] gfx_ok,
    output wire object_req_valid,
    input wire object_req_ready,
    output wire [OBJECT_AW-1:0] object_req_addr,
    input wire object_rsp_valid,
    output wire object_rsp_ready,
    input wire [31:0] object_rsp_data,
    input wire object_rsp_error,
    input wire object_port_idle,   // object port idle (tie 1 when absent)
    input wire gp_objectbank_wr,   // Batrider/Bakraid object-bank register write
    input wire [2:0] gp_objectbank_slot,
    output wire object_deadline_miss, object_row_skipped, object_ownership_error,
    output wire object_error,
    output wire [10:0] PALRAM_ADDR,
    input wire [15:0] PALRAM_DATA,
    output wire [13:0] TEXTROM_ADDR,
    input wire [15:0] TEXTROM_DATA,
    output wire [11:0] TEXTVRAM_ADDR,
    input wire [15:0] TEXTVRAM_DATA,
    output wire [7:0] TEXTSELECT_ADDR, TEXTSCROLL_ADDR,
    input wire [15:0] TEXTSELECT_DATA, TEXTSCROLL_DATA,
    output wire [7:0] red, green, blue,
    output wire hs, vs, lhbl, lvbl, lhbl_dly, lvbl_dly,
    input wire SS_FREEZE, STATE_HOLD,
    output wire SS_QUIESCED,
    input wire [63:0] SS_DATA,
    input wire [31:0] SS_ADDR,
    input wire [7:0] SS_SELECT,
    input wire SS_WRITE, SS_READ, SS_QUERY,
    output wire [63:0] SS_DATA_OUT,
    output wire SS_ACK, SS_ERROR,
    output wire palette_hold, palette_blank
);
    wire [8:0] render_y;
    wire active, drain, rebuild, palette_reset, text_idle;
    wire [10:0] text_pixel;
    wire [44:0] tile_pixels;
    wire [14:0] object_pixel;

    wire [1:0] narrow = board == raizing_board_pkg::RZB_SORCER ? 2'd1 :
                        board == raizing_board_pkg::RZB_KINGDOM ? 2'd2 :
                        board == raizing_board_pkg::RZB_GAREGGA ? 2'd3 : 2'd0;
    wire tile_tail_en = board == raizing_board_pkg::RZB_SORCER || board == raizing_board_pkg::RZB_GAREGGA ||
                        board == raizing_board_pkg::RZB_BATRIDER;
    rz_video_binding #(
        .GP_PROFILE(raizing_board_pkg::gp_profile(PROFILE_BOARD)),
        .RENDER_PROFILE(raizing_board_pkg::render_profile(PROFILE_BOARD)),
        .TILE_AW(TILE_AW), .SPRITE_AW(OBJECT_AW),
        .VRAM_INDEX(VRAM_INDEX), .REG_INDEX(REG_INDEX)
    ) u_binding (
        .narrow(narrow),
        .tile_tail_en(tile_tail_en),
        .clk(clk),
        .reset(reset),
        .pixel_ce(pixel_ce),
        .hs_start(hs_start),
        .hs_end(hs_end),
        .vs_start(vs_start),
        .vs_end(vs_end),
        .gp_cs(gp_cs),
        .gp_select_reg(gp_select_reg),
        .gp_write_reg(gp_write_reg),
        .gp_write_ram(gp_write_ram),
        .gp_read_ram_h(gp_read_ram_h),
        .gp_read_ram_l(gp_read_ram_l),
        .gp_set_ram_ptr(gp_set_ram_ptr),
        .gp_din(gp_din),
        .gp_be(gp_be),
        .gp_ack(gp_ack),
        .gp_dout(gp_dout),
        .vint_n(vint_n),
        .cpu_hsync_n(cpu_hsync_n),
        .cpu_vsync_n(cpu_vsync_n),
        .cpu_fblank(cpu_fblank),
        .hcount(hcount),
        .vcount(vcount),
        .gfx_req(gfx_req),
        .gfx_addr(gfx_addr),
        .gfx_data(gfx_data),
        .gfx_ok(gfx_ok),
        .object_req_valid(object_req_valid),
        .object_req_ready(object_req_ready),
        .object_req_addr(object_req_addr),
        .object_rsp_valid(object_rsp_valid),
        .object_rsp_ready(object_rsp_ready),
        .object_rsp_data(object_rsp_data),
        .object_rsp_error(object_rsp_error),
        .object_error(object_error),
        .hs(hs),
        .vs(vs),
        .lhbl(lhbl),
        .lvbl(lvbl),
        .SS_FREEZE(SS_FREEZE),
        .STATE_HOLD(STATE_HOLD),
        .SS_QUIESCED(SS_QUIESCED),
        .SS_DATA(SS_DATA),
        .SS_ADDR(SS_ADDR),
        .SS_SELECT(SS_SELECT),
        .SS_WRITE(SS_WRITE),
        .SS_READ(SS_READ),
        .SS_QUERY(SS_QUERY),
        .SS_DATA_OUT(SS_DATA_OUT),
        .SS_ACK(SS_ACK),
        .SS_ERROR(SS_ERROR),
        .render_y(render_y),
        .active(active),
        .drain(drain),
        .rebuild(rebuild),
        .palette_reset(palette_reset),
        .text_idle(text_idle),
        .tile_pixels(tile_pixels),
        .object_pixel(object_pixel),
        .gp_objectbank_wr(gp_objectbank_wr),
        .gp_objectbank_slot(gp_objectbank_slot),
        .object_port_idle(object_port_idle),
        .object_deadline_miss(object_deadline_miss),
        .object_row_skipped(object_row_skipped),
        .object_ownership_error(object_ownership_error),
        .palette_hold(palette_hold),
        .palette_blank(palette_blank)
    );

    raizing_text_layer u_text (
        .board(board),
        .clk(clk),
        .reset(rebuild),
        .pixel_ce(pixel_ce),
        .render_y(render_y),
        .h(hcount),
        .v(vcount),
        .active(active),
        .lhbl(lhbl),
        .lvbl(lvbl),
        .drain(drain),
        .idle(text_idle),
        .text_pixel(text_pixel),
        .font_addr(TEXTROM_ADDR),
        .font_data(TEXTROM_DATA),
        .text_addr(TEXTVRAM_ADDR),
        .text_data(TEXTVRAM_DATA),
        .select_addr(TEXTSELECT_ADDR),
        .select_data(TEXTSELECT_DATA),
        .scroll_addr(TEXTSCROLL_ADDR),
        .scroll_data(TEXTSCROLL_DATA)
    );

    raizing_palette u_palette (
        .clk(clk),
        .reset(palette_reset),
        .pixel_ce(pixel_ce),
        .lhbl(lhbl),
        .lvbl(lvbl),
        .text_pixel(text_pixel),
        .obj_pixel(object_pixel),
        .scr0_pixel(tile_pixels[14:0]),
        .scr1_pixel(tile_pixels[29:15]),
        .scr2_pixel(tile_pixels[44:30]),
        .PALRAM_ADDR(PALRAM_ADDR),
        .PALRAM_DATA(PALRAM_DATA),
        .red(red),
        .green(green),
        .blue(blue),
        .lhbl_dly(lhbl_dly),
        .lvbl_dly(lvbl_dly)
    );
endmodule

`default_nettype wire

// Priority select followed by the palette output stage.
module raizing_palette (
    input clk,reset,pixel_ce,lhbl,lvbl,
    input [10:0] text_pixel,
    input [14:0] obj_pixel,scr0_pixel,scr1_pixel,scr2_pixel,
    output [10:0] PALRAM_ADDR,
    input [15:0] PALRAM_DATA,
    output [7:0] red,green,blue,
    output lhbl_dly,lvbl_dly
);
    wire [10:0] selected_index;
    rzvideo_select select_pixel (
        .tile_opaque({|scr2_pixel[10:0],|scr1_pixel[10:0],|scr0_pixel[10:0]}),
        .tile_rank({scr2_pixel[14:11],scr1_pixel[14:11],scr0_pixel[14:11]}),
        .tile_index({scr2_pixel[10:0],scr1_pixel[10:0],scr0_pixel[10:0]}),
        .sprite_opaque(|obj_pixel[10:0]),.sprite_rank(obj_pixel[14:11]),
        .sprite_index(obj_pixel[10:0]),.text_opaque(|text_pixel),.text_index(text_pixel),
        .palette_index(selected_index),.winner()
    );
    rzpalette_output output_stage (
        .clk(clk),.pixel_ce(pixel_ce),.reset(reset),.lhbl(lhbl),.lvbl(lvbl),
        .selected_index(selected_index),.palette_addr(PALRAM_ADDR),.palette_word(PALRAM_DATA),
        .red(red),.green(green),.blue(blue),.lhbl_dly(lhbl_dly),.lvbl_dly(lvbl_dly)
    );
endmodule
// Display palette mirror: writes during the tail hold are deferred and the full palette is recopied in vblank.
module SorcerPaletteTail (
    input  logic        clk, reset,
    input  logic        tail_hold, in_blank,
    input  logic        cpu_commit,
    input  logic [10:0] write_addr,
    input  logic [15:0] write_data,
    input  logic [1:0]  write_be,
    input  logic [10:0] display_addr,
    output wire  [15:0] display_data,
    output wire  [10:0] canonical_addr,
    input  logic [15:0] canonical_data,
    input  logic        canonical_valid,
    output logic        copy_busy,
    output wire         live_fallback,
    output logic        missed_deadline
);
    logic pending, mirror_ready, read_phase;
    logic [10:0] copy_index;
    wire [15:0] mirror_data;

    wire committed = !reset && (|write_be);
    wire deferred = committed && cpu_commit && tail_hold && !in_blank;
    wire forward_write = committed && !deferred;
    wire copy_write = !reset && copy_busy && in_blank && read_phase &&
                      canonical_valid && !forward_write;
    wire [1:0] mirror_we = forward_write ? write_be : {2{copy_write}};
    assign canonical_addr = copy_busy && in_blank ? copy_index : display_addr;
    assign live_fallback = !mirror_ready;
    assign display_data = live_fallback ? canonical_data : mirror_data;

    raizing_bram #(.DW(16),.AW(11)) mirror (
        .clk0(clk),.addr0(forward_write ? write_addr : copy_index),
        .data0(forward_write ? write_data : canonical_data),.we0(mirror_we),.q0(),
        .clk1(clk),.addr1(display_addr),.data1(16'd0),.we1(2'b00),.q1(mirror_data)
    );

    always_ff @(posedge clk) begin
        if (reset) begin
            copy_busy <= 1'b0;
            missed_deadline <= 1'b0;
            pending <= 1'b1;
            mirror_ready <= 1'b0;
            read_phase <= 1'b0;
            copy_index <= 11'd0;
        end else begin
            if (deferred) pending <= 1'b1;
            if (!in_blank) begin
                if (copy_busy) begin
                    copy_busy <= 1'b0;
                    mirror_ready <= 1'b0;
                    missed_deadline <= 1'b1;
                end
            end else if (!copy_busy) begin
                if (pending) begin
                    copy_busy <= 1'b1;
                    copy_index <= 11'd0;
                    read_phase <= 1'b0;
                end
            end else if (forward_write) begin
                read_phase <= 1'b0;
            end else if (copy_write) begin
                read_phase <= 1'b0;
                if (&copy_index) begin
                    copy_busy <= 1'b0;
                    pending <= 1'b0;
                    mirror_ready <= 1'b1;
                end else copy_index <= copy_index+11'd1;
            end else read_phase <= 1'b1;
        end
    end
endmodule
