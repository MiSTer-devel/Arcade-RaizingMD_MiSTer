// SPDX-License-Identifier: GPL-3.0-or-later
// GP9001 CPU interface, VRAM, registers and frame epochs.

`timescale 1ns/1ps
/* verilator lint_off UNUSEDPARAM */
package rzgp_pkg;

  localparam int PROFILE_UNSUPPORTED = 0;
  localparam int PROFILE_GAREGGA     = 1;
  localparam int PROFILE_BATRIDER    = 2;
  localparam int PROFILE_BAKRAID     = 3;
  localparam int PROFILE_MAHOUDAI    = 4;  // Sorcer Striker
  localparam int PROFILE_KINGDMGP    = 5;  // Kingdom Grandprix

  function automatic bit profile_is_supported(input int id);
    return (id >= PROFILE_GAREGGA) && (id <= PROFILE_KINGDMGP);
  endfunction

  // All supported profiles use the same capture age constants.
  function automatic bit profile_is_measured(input int id);
    return (id == PROFILE_GAREGGA);
  endfunction

  // GP command offsets from word_offset[2:1]; bit 0 is an alias.
  localparam logic [1:0] OFF_POINTER = 2'd0;  // write: VRAM pointer; read: unhandled
  localparam logic [1:0] OFF_VRAM    = 2'd1;  // write/read: VRAM word, pointer +1
  localparam logic [1:0] OFF_SELECT  = 2'd2;  // write: register select; read: unhandled
  localparam logic [1:0] OFF_DATA    = 2'd3;  // write: register data; read: status

  localparam logic [15:0] UNHANDLED_READ_DATA = 16'hFFFF; // read of an unhandled offset
  localparam logic [15:0] FAULT_READ_DATA     = 16'hFFFF; // read data of a faulted request

  // The raw selector keeps bits 6:4 but the register decode ignores them.
  localparam int REG_TM0_X = 0;
  localparam int REG_TM0_Y = 1;
  localparam int REG_TM1_X = 2;
  localparam int REG_TM1_Y = 3;
  localparam int REG_TM2_X = 4;
  localparam int REG_TM2_Y = 5;
  localparam int REG_SP_X  = 6;
  localparam int REG_SP_Y  = 7;
  localparam int REG_CTRL_0E = 14; // video interrupt acknowledge, same as 0x0F
  localparam int REG_CTRL_0F = 15; // video interrupt acknowledge

  localparam int VRAM_WORDS_TOTAL   = 'h1C00;  // canonical words 0..0x1bff
  localparam int TILE_REGION_WORDS  = 'h0800;  // 1024 attribute/code pairs
  localparam int SPRITE_WORDS       = 'h0400;  // 256 entries x 4 words
  localparam int SPRITE_BASE_WORD   = 'h1800;
  localparam int SPRITE_MIRROR_WORD = 'h1C00;  // ..0x1fff mirrors 0x1800..0x1bff
  localparam int POINTER_DECODE_BITS = 13;       // pointer[12:0] addresses VRAM

  localparam int POLICY_DESCRIPTOR_AGE   = 2;  // sprite descriptor captures of delay
  localparam int POLICY_SPR_SCROLL_Y_AGE = 1;  // sprite Y-scroll captures of delay
  localparam int POLICY_SPR_SCROLL_X_AGE = 0;  // sprite X scroll is live
  localparam int GEN_SLOTS               = 3;  // 2 retained generations + 1 landing slot
  localparam int GEN_ENTRIES             = 256;
  localparam int GEN_SLOT_ADDR_BITS      = 10; // {slot[1:0], entry[7:0]}

  // State-access regions and region 0 register indices.
  localparam logic [3:0] ST_REGION_REGS = 4'd0;
  localparam logic [3:0] ST_REGION_VRAM = 4'd1;
  localparam logic [3:0] ST_REGION_GEN  = 4'd2;

  localparam int ST_REG_POINTER   = 0;
  localparam int ST_REG_SELECT    = 1;
  localparam int ST_REG_YVIEW     = 2;  // [15:0] value, [16] valid
  localparam int ST_REG_GENBOOK   = 3;  // [1:0] prev, [3:2] latest, [5:4] free, [21:6] capture_seq
  localparam int ST_REG_SLOT0     = 4;  // [15:0] seq, [16] valid, [17] collided
  localparam int ST_REG_SLOT1     = 5;
  localparam int ST_REG_SLOT2     = 6;
  localparam int ST_REG_COUNTERS  = 7;  // read-only diagnostics
  localparam int ST_REG_SCROLL0   = 16; // 16..31: [15:0] value, [16] flip, [17] written

  localparam logic [1:0] ST_ERR_NONE      = 2'd0;
  localparam logic [1:0] ST_ERR_OWNERSHIP = 2'd1; // owner not quiesced
  localparam logic [1:0] ST_ERR_RANGE     = 2'd2; // bad region/index or read-only

endpackage
/* verilator lint_on UNUSEDPARAM */

// RAM with registered read/write port A and read-only port B; old data on collision, zero at power-up only.
`timescale 1ns/1ps
module rzgp_tdp_ram #(
  parameter int AW = 10,
  parameter int DW = 16
) (
  input  logic          clk,
  // Port A: read/write, output register loads only when a_en is high
  input  logic          a_en,
  input  logic          a_we,
  input  logic [AW-1:0] a_addr,
  input  logic [DW-1:0] a_wdata,
  output logic [DW-1:0] a_q,
  // Port B: read-only, output register loads only when b_en is high
  input  logic          b_en,
  input  logic [AW-1:0] b_addr,
  output logic [DW-1:0] b_q
);

  logic [DW-1:0] mem [0:(1<<AW)-1];

  initial begin
    for (int i = 0; i < (1<<AW); i++) mem[i] = '0;
  end

  always @(posedge clk) begin
    if (a_we) mem[a_addr] <= a_wdata;
    if (a_en) a_q <= mem[a_addr];
  end

  always_ff @(posedge clk) begin
    if (b_en) b_q <= mem[b_addr];
  end

endmodule

// Simple dual-port RAM with registered read; old data on collision, zero at power-up.
`timescale 1ns/1ps
module rzgp_sdp_ram #(
  parameter int AW    = 10,
  parameter int DW    = 64,
  parameter int DEPTH = 768
) (
  input  logic          clk,
  input  logic          w_en,
  input  logic [AW-1:0] w_addr,
  input  logic [DW-1:0] w_data,
  input  logic          r_en,
  input  logic [AW-1:0] r_addr,
  output logic [DW-1:0] r_q
);

  logic [DW-1:0] mem [0:DEPTH-1];

  initial begin
    for (int i = 0; i < DEPTH; i++) mem[i] = '0;
  end

  always @(posedge clk) begin
    if (w_en) mem[w_addr] <= w_data;
  end

  always_ff @(posedge clk) begin
    if (r_en) r_q <= mem[r_addr];
  end

endmodule

// GP VRAM: three 0x800-word tile maps (attr even, code odd) and 256 four-word sprite entries at 0x1800.
`timescale 1ns/1ps
module rzgp_vram (
  input  logic        clk,
  input  logic        rst,             // resets valid flags only; RAM contents persist
  // Port A (CPU command owner, or state access while quiesced)
  input  logic        a_en,
  input  logic        a_we,
  input  logic [12:0] a_addr,
  input  logic [15:0] a_wdata,
  output logic [15:0] a_rdata,
  output logic        a_sprite_write,   // pulse: this cycle writes the sprite region
  // Renderer tile descriptor services, one per plane; pair = {attr, code}, valid the next cycle
  input  logic        t0_en,
  input  logic [9:0]  t0_idx,
  output logic [31:0] t0_pair,
  output logic        t0_valid,
  input  logic        t1_en,
  input  logic [9:0]  t1_idx,
  output logic [31:0] t1_pair,
  output logic        t1_valid,
  input  logic        t2_en,
  input  logic [9:0]  t2_idx,
  output logic [31:0] t2_pair,
  output logic        t2_valid,
  // Sprite entry read service for the capture copy engine; data = {w3, w2, w1, w0}
  input  logic        s_en,
  input  logic [7:0]  s_entry,
  output logic [63:0] s_data,
  output logic        s_valid
);

  // ----- port A decode -------------------------------------------------
  logic [1:0] a_region;      // 0..2 tile, 3 sprite
  logic       a_is_sprite;
  logic       a_tile_bank;   // 0 attr (even), 1 code (odd)
  logic [9:0] a_tile_idx;
  logic [7:0] a_spr_entry;
  logic [1:0] a_spr_word;

  always_comb begin
    a_region    = a_addr[12:11];
    a_is_sprite = (a_region == 2'd3);
    a_tile_bank = a_addr[0];
    a_tile_idx  = a_addr[10:1];
    a_spr_entry = a_addr[9:2];   // bit 10 ignored: 0x1c00..0x1fff mirror
    a_spr_word  = a_addr[1:0];
    a_sprite_write = a_we & a_is_sprite;
  end

  // ----- tile banks ----------------------------------------------------
  logic [15:0] tile_a_q [0:2][0:1];
  logic [15:0] tile_b_q [0:2][0:1];
  logic        tile_a_en [0:2][0:1];
  logic        tile_a_we [0:2][0:1];
  logic        tile_b_en [0:2];
  logic [9:0]  tile_b_idx [0:2];

  always_comb begin
    tile_b_en[0]  = t0_en;  tile_b_idx[0] = t0_idx;
    tile_b_en[1]  = t1_en;  tile_b_idx[1] = t1_idx;
    tile_b_en[2]  = t2_en;  tile_b_idx[2] = t2_idx;
    for (int r = 0; r < 3; r++) begin
      for (int b = 0; b < 2; b++) begin
        tile_a_en[r][b] = a_en & ~a_is_sprite & (a_region == 2'(r)) & (a_tile_bank == 1'(b));
        tile_a_we[r][b] = a_we & ~a_is_sprite & (a_region == 2'(r)) & (a_tile_bank == 1'(b));
      end
    end
  end

  genvar gr, gb;
  generate
    for (gr = 0; gr < 3; gr++) begin : g_region
      for (gb = 0; gb < 2; gb++) begin : g_bank
        rzgp_tdp_ram #(.AW(10), .DW(16)) u_tile (
          .clk     (clk),
          .a_en    (tile_a_en[gr][gb]),
          .a_we    (tile_a_we[gr][gb]),
          .a_addr  (a_tile_idx),
          .a_wdata (a_wdata),
          .a_q     (tile_a_q[gr][gb]),
          .b_en    (tile_b_en[gr]),
          .b_addr  (tile_b_idx[gr]),
          .b_q     (tile_b_q[gr][gb])
        );
      end
    end
  endgenerate

  // ----- sprite banks --------------------------------------------------
  logic [15:0] spr_a_q [0:3];
  logic [15:0] spr_b_q [0:3];
  logic        spr_a_en [0:3];
  logic        spr_a_we [0:3];

  always_comb begin
    for (int w = 0; w < 4; w++) begin
      spr_a_en[w] = a_en & a_is_sprite & (a_spr_word == 2'(w));
      spr_a_we[w] = a_we & a_is_sprite & (a_spr_word == 2'(w));
    end
  end

  genvar gw;
  generate
    for (gw = 0; gw < 4; gw++) begin : g_sprbank
      rzgp_tdp_ram #(.AW(8), .DW(16)) u_spr (
        .clk     (clk),
        .a_en    (spr_a_en[gw]),
        .a_we    (spr_a_we[gw]),
        .a_addr  (a_spr_entry),
        .a_wdata (a_wdata),
        .a_q     (spr_a_q[gw]),
        .b_en    (s_en),
        .b_addr  (s_entry),
        .b_q     (spr_b_q[gw])
      );
    end
  endgenerate

  // ----- port A read-data mux (select registered with the read) -------
  logic       rd_is_sprite_q;
  logic [1:0] rd_region_q;
  logic       rd_bank_q;
  logic [1:0] rd_word_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      rd_is_sprite_q <= 1'b0;
      rd_region_q    <= 2'd0;
      rd_bank_q      <= 1'b0;
      rd_word_q      <= 2'd0;
    end else if (a_en) begin
      rd_is_sprite_q <= a_is_sprite;
      rd_region_q    <= a_region;
      rd_bank_q      <= a_tile_bank;
      rd_word_q      <= a_spr_word;
    end
  end

  always_comb begin
    if (rd_is_sprite_q) a_rdata = spr_a_q[rd_word_q];
    else                a_rdata = tile_a_q[rd_region_q][rd_bank_q];
  end

  // ----- renderer outputs ----------------------------------------------
  always_comb begin
    t0_pair = {tile_b_q[0][0], tile_b_q[0][1]};
    t1_pair = {tile_b_q[1][0], tile_b_q[1][1]};
    t2_pair = {tile_b_q[2][0], tile_b_q[2][1]};
    s_data  = {spr_b_q[3], spr_b_q[2], spr_b_q[1], spr_b_q[0]};
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      t0_valid <= 1'b0;
      t1_valid <= 1'b0;
      t2_valid <= 1'b0;
      s_valid  <= 1'b0;
    end else begin
      t0_valid <= t0_en;
      t1_valid <= t1_en;
      t2_valid <= t2_en;
      s_valid  <= s_en;
    end
  end

endmodule

// GP command owner: one request at a time, response on the next edge, held until accepted.
`timescale 1ns/1ps
module rzgp_cmd
  import rzgp_pkg::*;
(
  input  logic        clk,
  input  logic        rst,
  input  logic        profile_ok,
  // ---- CPU request ----
  input  logic        req_valid,
  output logic        req_ready,
  input  logic        req_write,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [2:0]  req_offset,   // bit 0 is an address alias
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [15:0] req_data,     // the 16 data wires, not a merged value
  input  logic [1:0]  req_lanes,    // [1] = D15:8 (even/upper), [0] = D7:0 (odd/lower)
  input  logic [7:0]  req_tag,
  // ---- CPU response ----
  output logic        rsp_valid,
  input  logic        rsp_ready,
  output logic [15:0] rsp_data,
  output logic        rsp_fault,
  output logic [7:0]  rsp_tag,
  // ---- external status / interrupt ack ----
  input  logic [15:0] status_word,  // supplied by the status/IRQ timing owner
  output logic        irq_ack,      // one-cycle pulse per accepted ack write
  // ---- VRAM port A (muxed with the state port at the top) ----
  output logic        va_en,
  output logic        va_we,
  output logic [12:0] va_addr,
  output logic [15:0] va_wdata,
  input  logic [15:0] va_rdata,
  // ---- quiesce ----
  input  logic        quiesce_req,
  output logic        cmd_idle,     // no accepted command outstanding
  // ---- live register views ----
  output logic [15:0]  voffs,
  output logic [15:0]  sel_raw,
  output logic [255:0] reg_raw_flat, // [16*i +: 16] = raw register i
  output logic [15:0]  reg_flip,     // selector bit 7 at the last write to i
  output logic [15:0]  reg_written,  // register i written since reset
  // ---- state restore (driven only while quiesced) ----
  input  logic        st_reg_we,
  input  logic [4:0]  st_reg_idx,    // 0 pointer, 1 selector, 16..31 registers
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [31:0] st_reg_wdata   // [15:0] value, [16] flip, [17] written
  /* verilator lint_on UNUSEDSIGNAL */
);

  function automatic logic [15:0] merge_lanes(input logic [15:0] old_v,
                                              input logic [15:0] new_v,
                                              input logic [1:0]  lanes);
    merge_lanes = {lanes[1] ? new_v[15:8] : old_v[15:8],
                   lanes[0] ? new_v[7:0]  : old_v[7:0]};
  endfunction

  logic        req_ready_q;
  logic        busy_q;          // == response outstanding
  logic [15:0] voffs_q;
  logic [15:0] sel_raw_q;
  logic [15:0] reg_raw_q [0:15];
  logic [15:0] reg_flip_q;
  logic [15:0] reg_written_q;
  logic [15:0] rsp_data_q;
  logic        rsp_src_vram_q;
  logic        rsp_fault_q;
  logic [7:0]  rsp_tag_q;
  logic        irq_ack_q;

  // decode of the request presented this cycle

  logic        accept;
  logic        fault;
  logic [1:0]  op;
  logic        do_pointer_w, do_vram_w, do_vram_r, do_select_w, do_data_w, do_status_r, do_unhandled_r;
  logic [3:0]  sel_idx;
  logic        busy_d;

  always_comb begin
    accept  = req_valid & req_ready_q & ~rst;
    fault   = (req_lanes == 2'b00) | ~profile_ok;
    op      = req_offset[2:1];                 // bit 0 is an address alias
    sel_idx = sel_raw_q[3:0];                   // The selector decode ignores bits 6:4.
    do_pointer_w   = accept & ~fault &  req_write & (op == OFF_POINTER);
    do_vram_w      = accept & ~fault &  req_write & (op == OFF_VRAM);
    do_vram_r      = accept & ~fault & ~req_write & (op == OFF_VRAM);
    do_select_w    = accept & ~fault &  req_write & (op == OFF_SELECT);
    do_data_w      = accept & ~fault &  req_write & (op == OFF_DATA);
    do_status_r    = accept & ~fault & ~req_write & (op == OFF_DATA);
    do_unhandled_r = accept & ~fault & ~req_write & ((op == OFF_POINTER) | (op == OFF_SELECT));
    busy_d  = accept | (busy_q & ~rsp_ready);   // cleared by the response handshake
  end

  // A VRAM write stores the full data word when any byte lane is enabled.
  always_comb begin
    va_en    = do_vram_r;
    va_we    = do_vram_w;
    va_addr  = voffs_q[POINTER_DECODE_BITS-1:0];
    va_wdata = req_data;
  end

  // admission / response bookkeeping

  always_ff @(posedge clk) begin
    if (rst) begin
      busy_q      <= 1'b0;
      req_ready_q <= 1'b0;
    end else begin
      busy_q      <= busy_d;
      req_ready_q <= ~quiesce_req & ~busy_d;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      rsp_data_q     <= '0;
      rsp_src_vram_q <= 1'b0;
      rsp_fault_q    <= 1'b0;
      rsp_tag_q      <= '0;
    end else if (accept) begin
      rsp_tag_q      <= req_tag;
      rsp_fault_q    <= fault;
      rsp_src_vram_q <= do_vram_r;
      if (fault)             rsp_data_q <= FAULT_READ_DATA;
      else if (do_status_r)  rsp_data_q <= status_word;        // status sampled at accept
      else if (do_unhandled_r) rsp_data_q <= UNHANDLED_READ_DATA;
      else                   rsp_data_q <= 16'h0000;           // writes / vram (unused)
    end
  end

  always_comb begin
    req_ready = req_ready_q;
    rsp_valid = busy_q;
    rsp_fault = rsp_fault_q;
    rsp_tag   = rsp_tag_q;
    rsp_data  = rsp_src_vram_q ? va_rdata : rsp_data_q;
    cmd_idle  = ~busy_q;
    irq_ack   = irq_ack_q;
  end

  // The 16-bit pointer advances once per accepted VRAM read or write.
  always_ff @(posedge clk) begin
    if (rst)                                           voffs_q <= '0;
    else if (st_reg_we && st_reg_idx == 5'(ST_REG_POINTER)) voffs_q <= st_reg_wdata[15:0];
    else if (do_pointer_w)                             voffs_q <= merge_lanes(voffs_q, req_data, req_lanes);
    else if (do_vram_w | do_vram_r)                    voffs_q <= voffs_q + 16'd1;
  end

  // Merges enabled selector bytes without rewriting the stored scroll controls.
  always_ff @(posedge clk) begin
    if (rst)                                            sel_raw_q <= '0;
    else if (st_reg_we && st_reg_idx == 5'(ST_REG_SELECT)) sel_raw_q <= st_reg_wdata[15:0];
    else if (do_select_w)                               sel_raw_q <= merge_lanes(sel_raw_q, req_data, req_lanes);
  end

  // sixteen raw scroll/control words with per-register flip metadata
  genvar gi;
  generate
    for (gi = 0; gi < 16; gi++) begin : g_reg
      always_ff @(posedge clk) begin
        if (rst) begin
          reg_raw_q[gi]     <= '0;
          reg_flip_q[gi]    <= 1'b0;
          reg_written_q[gi] <= 1'b0;
        end else if (st_reg_we && st_reg_idx == 5'(ST_REG_SCROLL0 + gi)) begin
          reg_raw_q[gi]     <= st_reg_wdata[15:0];
          reg_flip_q[gi]    <= st_reg_wdata[16];
          reg_written_q[gi] <= st_reg_wdata[17];
        end else if (do_data_w && sel_idx == 4'(gi)) begin
          reg_raw_q[gi]     <= merge_lanes(reg_raw_q[gi], req_data, req_lanes);
          reg_flip_q[gi]    <= sel_raw_q[7];
          reg_written_q[gi] <= 1'b1;
        end
      end
      always_comb reg_raw_flat[16*gi +: 16] = reg_raw_q[gi];
    end
  endgenerate

  // A write with selector 0x0E or 0x0F pulses the video interrupt acknowledge.
  always_ff @(posedge clk) begin
    if (rst) irq_ack_q <= 1'b0;
    else     irq_ack_q <= do_data_w & ((sel_idx == 4'(REG_CTRL_0E)) | (sel_idx == 4'(REG_CTRL_0F)));
  end

  always_comb begin
    voffs       = voffs_q;
    sel_raw     = sel_raw_q;
    reg_flip    = reg_flip_q;
    reg_written = reg_written_q;
  end

endmodule

// Copies live sprite entries into rotating generation slots; jobs read the previous generation and latest Y view.
`timescale 1ns/1ps
module rzgp_epoch
  import rzgp_pkg::*;
(
  input  logic        clk,
  input  logic        rst,
  input  logic        capture_event,     // from the status/IRQ timing owner
  input  logic        quiesce_req,
  input  logic        st_mode,           // quiesced: state port owns the slot RAM
  // live sprite RAM read port (rzgp_vram port B of the sprite banks)
  output logic        sc_en,
  output logic [7:0]  sc_entry,
  input  logic [63:0] sc_data,
  input  logic        live_sprite_write, // pulse: a CPU/state write hit the sprite region
  input  logic [15:0] spr_scroll_y_live, // raw register 7
  // renderer job ownership
  input  logic        job_acquire,
  input  logic        job_release,
  output logic        job_held,
  output logic        job_gen_valid,
  output logic [15:0] job_gen_seq,
  output logic        job_gen_collided,
  output logic        job_acq_refused,
  output logic [15:0] job_spr_scroll_y,
  output logic        job_spr_scroll_y_valid,
  output logic [15:0] spr_scroll_y_view,
  output logic        spr_scroll_y_view_valid,
  // sprite descriptor read service (held generation)
  input  logic        spr_rd_en,
  input  logic [7:0]  spr_rd_index,
  output logic [63:0] spr_rd_entry,
  output logic        spr_rd_valid,
  output logic        spr_rd_gen_valid,
  output logic [15:0] spr_rd_gen_seq,
  // capture status
  output logic        capture_busy,
  output logic        capture_pending,
  output logic        capture_done,
  output logic [15:0] capture_seq,
  output logic [15:0] cnt_deferred,
  output logic [15:0] cnt_overrun,
  output logic [15:0] cnt_collision,
  output logic [15:0] cnt_ignored,
  output logic        epoch_idle,
  // state access (driven only while quiesced)
  input  logic        st_gen_we,
  input  logic        st_gen_rd_en,
  input  logic [9:0]  st_gen_addr,       // {slot[1:0], entry[7:0]}
  input  logic [63:0] st_gen_wdata,
  input  logic        bk_we,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [63:0] bk_wdata,      // [21:0] used; upper bits reserved
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [63:0] bk_rdata,
  input  logic        slot_we,
  input  logic [1:0]  slot_we_idx,
  input  logic [17:0] slot_wdata,
  output logic [17:0] slot_meta0,
  output logic [17:0] slot_meta1,
  output logic [17:0] slot_meta2,
  input  logic        yview_we,
  input  logic [16:0] yview_wdata
);

  // bookkeeping
  logic [1:0]  role_prev_q, role_latest_q, role_free_q;
  logic        slot_valid_q [0:2];
  logic [15:0] slot_seq_q   [0:2];
  logic        slot_coll_q  [0:2];
  logic [15:0] capture_seq_q;
  logic [15:0] y_view_q;
  logic        y_view_valid_q;
  logic [15:0] y_pending_q;

  // copy engine
  logic        copy_active_q;
  logic [8:0]  copy_idx_q;       // 0..256
  logic [1:0]  copy_slot_q;
  logic        copy_coll_q;
  logic        pending_q;        // deferred capture waiting for a free slot
  logic        done_q;

  // job
  logic        held_q;
  logic [1:0]  held_slot_q;
  logic        job_gen_valid_q, job_gen_coll_q;
  logic [15:0] job_gen_seq_q;
  logic [15:0] job_y_q;
  logic        job_y_valid_q;
  logic        refused_q;

  // counters
  logic [15:0] cnt_deferred_q, cnt_overrun_q, cnt_collision_q, cnt_ignored_q;

  // capture decision
  logic free_held, can_start, start_now, defer_now, overrun_now, ignored_now, pending_start, start, finish;

  always_comb begin
    free_held     = held_q & (held_slot_q == role_free_q);
    can_start     = ~copy_active_q & ~free_held;
    ignored_now   = capture_event & quiesce_req;
    overrun_now   = capture_event & ~quiesce_req & (copy_active_q | pending_q);
    start_now     = capture_event & ~quiesce_req & ~copy_active_q & ~pending_q & can_start;
    defer_now     = capture_event & ~quiesce_req & ~copy_active_q & ~pending_q & ~can_start;
    pending_start = pending_q & can_start;
    start         = start_now | pending_start;
    finish        = copy_active_q & (copy_idx_q == 9'd256);
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      pending_q <= 1'b0;
    end else if (defer_now) begin
      pending_q <= 1'b1;
    end else if (pending_start) begin
      pending_q <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      copy_active_q <= 1'b0;
      copy_idx_q    <= '0;
      copy_slot_q   <= 2'd0;
      copy_coll_q   <= 1'b0;
      y_pending_q   <= '0;
    end else if (start) begin
      copy_active_q <= 1'b1;
      copy_idx_q    <= '0;
      copy_slot_q   <= role_free_q;
      copy_coll_q   <= 1'b0;
      y_pending_q   <= spr_scroll_y_live;   // Y view sampled at capture start
    end else if (copy_active_q) begin
      if (finish) copy_active_q <= 1'b0;
      else        copy_idx_q    <= copy_idx_q + 9'd1;
      if (live_sprite_write) copy_coll_q <= 1'b1;
    end
  end

  // live sprite RAM read: entries 0..255 presented on consecutive cycles
  always_comb begin
    sc_en    = copy_active_q & (copy_idx_q != 9'd256);
    sc_entry = copy_idx_q[7:0];
  end

  // publication (rotation) at completion
  always_ff @(posedge clk) begin
    if (rst) begin
      role_prev_q   <= 2'd0;
      role_latest_q <= 2'd1;
      role_free_q   <= 2'd2;
      capture_seq_q <= '0;
      y_view_q      <= '0;
      y_view_valid_q<= 1'b0;
      done_q        <= 1'b0;
    end else begin
      done_q <= finish;
      if (bk_we) begin
        role_prev_q   <= bk_wdata[1:0];
        role_latest_q <= bk_wdata[3:2];
        role_free_q   <= bk_wdata[5:4];
        capture_seq_q <= bk_wdata[21:6];
      end else if (finish) begin
        role_latest_q <= copy_slot_q;
        role_prev_q   <= role_latest_q;
        role_free_q   <= role_prev_q;
        capture_seq_q <= capture_seq_q + 16'd1;
      end
      if (yview_we) begin
        y_view_q       <= yview_wdata[15:0];
        y_view_valid_q <= yview_wdata[16];
      end else if (finish) begin
        y_view_q       <= y_pending_q;
        y_view_valid_q <= 1'b1;
      end
    end
  end

  genvar gs;
  generate
    for (gs = 0; gs < 3; gs++) begin : g_slot
      always_ff @(posedge clk) begin
        if (rst) begin
          slot_valid_q[gs] <= 1'b0;
          slot_seq_q[gs]   <= '0;
          slot_coll_q[gs]  <= 1'b0;
        end else if (slot_we && slot_we_idx == 2'(gs)) begin
          slot_seq_q[gs]   <= slot_wdata[15:0];
          slot_valid_q[gs] <= slot_wdata[16];
          slot_coll_q[gs]  <= slot_wdata[17];
        end else if (start && role_free_q == 2'(gs)) begin
          slot_valid_q[gs] <= 1'b0;             // landing slot is not retained while filling
        end else if (finish && copy_slot_q == 2'(gs)) begin
          slot_valid_q[gs] <= 1'b1;
          slot_seq_q[gs]   <= capture_seq_q + 16'd1;
          slot_coll_q[gs]  <= copy_coll_q | live_sprite_write;
        end
      end
    end
  endgenerate

  // renderer job ownership
  logic grant;
  always_comb begin
    grant = job_acquire & ~quiesce_req & (~held_q | job_release);
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      held_q          <= 1'b0;
      held_slot_q     <= 2'd0;
      job_gen_valid_q <= 1'b0;
      job_gen_seq_q   <= '0;
      job_gen_coll_q  <= 1'b0;
      job_y_q         <= '0;
      job_y_valid_q   <= 1'b0;
      refused_q       <= 1'b0;
    end else begin
      refused_q <= job_acquire & ~grant;
      if (grant) begin
        held_q          <= 1'b1;
        held_slot_q     <= role_prev_q;
        job_gen_valid_q <= slot_valid_q[role_prev_q];
        job_gen_seq_q   <= slot_seq_q[role_prev_q];
        job_gen_coll_q  <= slot_coll_q[role_prev_q];
        job_y_q         <= y_view_q;
        job_y_valid_q   <= y_view_valid_q;
      end else if (job_release & held_q) begin
        held_q <= 1'b0;
      end
    end
  end

  // generation store: 3 slots x 256 entries x 64 bits
  logic        w_en;
  logic [9:0]  w_addr;
  logic [63:0] w_data;
  logic        r_en;
  logic [9:0]  r_addr;
  logic [1:0]  rd_slot;
  logic        copy_w_en;
  logic [7:0]  copy_w_entry;

  always_comb begin
    copy_w_en    = copy_active_q & (copy_idx_q != 9'd0);
    copy_w_entry = copy_idx_q[7:0] - 8'd1;
    rd_slot      = held_q ? held_slot_q : role_prev_q;
    if (st_mode) begin
      w_en   = st_gen_we;
      w_addr = st_gen_addr;
      w_data = st_gen_wdata;
      r_en   = st_gen_rd_en;
      r_addr = st_gen_addr;
    end else begin
      w_en   = copy_w_en;
      w_addr = {copy_slot_q, copy_w_entry};
      w_data = sc_data;
      r_en   = spr_rd_en;
      r_addr = {rd_slot, spr_rd_index};
    end
  end

  rzgp_sdp_ram #(.AW(10), .DW(64), .DEPTH(768)) u_gen (
    .clk    (clk),
    .w_en   (w_en),
    .w_addr (w_addr),
    .w_data (w_data),
    .r_en   (r_en),
    .r_addr (r_addr),
    .r_q    (spr_rd_entry)
  );

  logic spr_rd_valid_q, spr_rd_gen_valid_q;
  logic [15:0] spr_rd_gen_seq_q;
  always_ff @(posedge clk) begin
    if (rst) begin
      spr_rd_valid_q     <= 1'b0;
      spr_rd_gen_valid_q <= 1'b0;
      spr_rd_gen_seq_q   <= '0;
    end else begin
      spr_rd_valid_q     <= spr_rd_en & ~st_mode;
      spr_rd_gen_valid_q <= spr_rd_en & ~st_mode & held_q & job_gen_valid_q;
      spr_rd_gen_seq_q   <= job_gen_seq_q;
    end
  end

  // counters (saturating)
  function automatic logic [15:0] sat_inc(input logic [15:0] v, input logic inc);
    sat_inc = (inc && v != 16'hFFFF) ? v + 16'd1 : v;
  endfunction

  always_ff @(posedge clk) begin
    if (rst) begin
      cnt_deferred_q  <= '0;
      cnt_overrun_q   <= '0;
      cnt_collision_q <= '0;
      cnt_ignored_q   <= '0;
    end else begin
      cnt_deferred_q  <= sat_inc(cnt_deferred_q,  defer_now);
      cnt_overrun_q   <= sat_inc(cnt_overrun_q,   overrun_now);
      cnt_collision_q <= sat_inc(cnt_collision_q, copy_active_q & live_sprite_write);
      cnt_ignored_q   <= sat_inc(cnt_ignored_q,   ignored_now);
    end
  end

  always_comb begin
    job_held               = held_q;
    job_gen_valid          = job_gen_valid_q;
    job_gen_seq            = job_gen_seq_q;
    job_gen_collided       = job_gen_coll_q;
    job_acq_refused        = refused_q;
    job_spr_scroll_y       = job_y_q;
    job_spr_scroll_y_valid = job_y_valid_q;
    spr_scroll_y_view      = y_view_q;
    spr_scroll_y_view_valid= y_view_valid_q;
    spr_rd_valid           = spr_rd_valid_q;
    spr_rd_gen_valid       = spr_rd_gen_valid_q;
    spr_rd_gen_seq         = spr_rd_gen_seq_q;
    capture_busy           = copy_active_q;
    capture_pending        = pending_q;
    capture_done           = done_q;
    capture_seq            = capture_seq_q;
    cnt_deferred           = cnt_deferred_q;
    cnt_overrun            = cnt_overrun_q;
    cnt_collision          = cnt_collision_q;
    cnt_ignored            = cnt_ignored_q;
    epoch_idle             = ~copy_active_q & ~pending_q & ~held_q;
    bk_rdata               = {42'd0, capture_seq_q, role_free_q, role_latest_q, role_prev_q};
    slot_meta0             = {slot_coll_q[0], slot_valid_q[0], slot_seq_q[0]};
    slot_meta1             = {slot_coll_q[1], slot_valid_q[1], slot_seq_q[1]};
    slot_meta2             = {slot_coll_q[2], slot_valid_q[2], slot_seq_q[2]};
  end

endmodule

// GP state port: region 0 registers, 1 VRAM words, 2 generation slots; done pulses two cycles after accept.
`timescale 1ns/1ps
module rzgp_state
  import rzgp_pkg::*;
(
  input  logic        clk,
  input  logic        rst,
  input  logic        quiesced,
  // ---- state port ----
  input  logic        st_valid,
  output logic        st_ready,
  input  logic        st_write,
  input  logic [3:0]  st_region,
  input  logic [15:0] st_index,
  input  logic [63:0] st_wdata,
  output logic        st_done,
  output logic [63:0] st_rdata,
  output logic [1:0]  st_err,
  // ---- command owner registers ----
  input  logic [15:0]  voffs,
  input  logic [15:0]  sel_raw,
  input  logic [255:0] reg_raw_flat,
  input  logic [15:0]  reg_flip,
  input  logic [15:0]  reg_written,
  output logic        st_reg_we,
  output logic [4:0]  st_reg_idx,
  output logic [31:0] st_reg_wdata,
  // ---- VRAM port A ----
  output logic        st_va_en,
  output logic        st_va_we,
  output logic [12:0] st_va_addr,
  output logic [15:0] st_va_wdata,
  input  logic [15:0] va_rdata,
  // ---- epoch owner ----
  output logic        st_gen_we,
  output logic        st_gen_rd_en,
  output logic [9:0]  st_gen_addr,
  output logic [63:0] st_gen_wdata,
  input  logic [63:0] gen_rdata,
  output logic        bk_we,
  output logic [63:0] bk_wdata,
  input  logic [63:0] bk_rdata,
  output logic        slot_we,
  output logic [1:0]  slot_we_idx,
  output logic [17:0] slot_wdata,
  input  logic [17:0] slot_meta0,
  input  logic [17:0] slot_meta1,
  input  logic [17:0] slot_meta2,
  output logic        yview_we,
  output logic [16:0] yview_wdata,
  input  logic [16:0] yview_rdata,
  input  logic [63:0] counters_rdata
);

  typedef enum logic [1:0] { S_IDLE = 2'd0, S_WAIT = 2'd1, S_DONE = 2'd2 } st_e;
  st_e  fsm_q;

  logic        accept;
  logic [1:0]  err_d;
  logic        is_regs, is_vram, is_gen;
  logic        reg_is_cmd, reg_is_ro, reg_known;
  logic [63:0] reg_read_now;

  // registered copy of the accepted transaction
  logic        t_write_q;
  logic [3:0]  t_region_q;
  logic [15:0] t_index_q;
  logic [1:0]  t_err_q;
  logic [63:0] rdata_q;
  logic [1:0]  err_q;
  logic        done_q;

  always_comb begin
    accept     = st_valid & (fsm_q == S_IDLE) & ~rst;
    is_regs    = (st_region == ST_REGION_REGS);
    is_vram    = (st_region == ST_REGION_VRAM);
    is_gen     = (st_region == ST_REGION_GEN);
    reg_is_cmd = (st_index == 16'(ST_REG_POINTER)) | (st_index == 16'(ST_REG_SELECT)) |
                 ((st_index >= 16'(ST_REG_SCROLL0)) & (st_index < 16'(ST_REG_SCROLL0 + 16)));
    reg_is_ro  = (st_index == 16'(ST_REG_COUNTERS));
    reg_known  = reg_is_cmd | reg_is_ro |
                 (st_index == 16'(ST_REG_YVIEW)) | (st_index == 16'(ST_REG_GENBOOK)) |
                 (st_index == 16'(ST_REG_SLOT0)) | (st_index == 16'(ST_REG_SLOT1)) | (st_index == 16'(ST_REG_SLOT2));
    err_d = ST_ERR_NONE;
    if (!quiesced)                                   err_d = ST_ERR_OWNERSHIP;
    else if (is_regs && (!reg_known || (st_write && reg_is_ro))) err_d = ST_ERR_RANGE;
    else if (is_vram && st_index >= 16'(VRAM_WORDS_TOTAL)) err_d = ST_ERR_RANGE;
    else if (is_gen  && st_index >= 16'(GEN_SLOTS*GEN_ENTRIES)) err_d = ST_ERR_RANGE;
    else if (!is_regs && !is_vram && !is_gen)        err_d = ST_ERR_RANGE;
  end

  // ---- issue side effects in the accept cycle (writes) / read issue ----
  always_comb begin
    st_reg_we    = accept & (err_d == ST_ERR_NONE) & is_regs & st_write & reg_is_cmd;
    st_reg_idx   = st_index[4:0];
    st_reg_wdata = st_wdata[31:0];
    st_va_en     = accept & (err_d == ST_ERR_NONE) & is_vram & ~st_write;
    st_va_we     = accept & (err_d == ST_ERR_NONE) & is_vram &  st_write;
    st_va_addr   = st_index[12:0];
    st_va_wdata  = st_wdata[15:0];
    st_gen_we    = accept & (err_d == ST_ERR_NONE) & is_gen &  st_write;
    st_gen_rd_en = accept & (err_d == ST_ERR_NONE) & is_gen & ~st_write;
    st_gen_addr  = st_index[9:0];
    st_gen_wdata = st_wdata;
    bk_we        = accept & (err_d == ST_ERR_NONE) & is_regs & st_write & (st_index == 16'(ST_REG_GENBOOK));
    bk_wdata     = st_wdata;
    slot_we      = accept & (err_d == ST_ERR_NONE) & is_regs & st_write &
                   ((st_index == 16'(ST_REG_SLOT0)) | (st_index == 16'(ST_REG_SLOT1)) | (st_index == 16'(ST_REG_SLOT2)));
    slot_we_idx  = 2'(st_index - 16'(ST_REG_SLOT0));
    slot_wdata   = st_wdata[17:0];
    yview_we     = accept & (err_d == ST_ERR_NONE) & is_regs & st_write & (st_index == 16'(ST_REG_YVIEW));
    yview_wdata  = st_wdata[16:0];
  end

  // ---- read mux (evaluated in the WAIT cycle on the registered index) ----
  always_comb begin
    reg_read_now = '0;
    if (t_index_q == 16'(ST_REG_POINTER))        reg_read_now = {48'd0, voffs};
    else if (t_index_q == 16'(ST_REG_SELECT))    reg_read_now = {48'd0, sel_raw};
    else if (t_index_q == 16'(ST_REG_YVIEW))     reg_read_now = {47'd0, yview_rdata};
    else if (t_index_q == 16'(ST_REG_GENBOOK))   reg_read_now = bk_rdata;
    else if (t_index_q == 16'(ST_REG_SLOT0))     reg_read_now = {46'd0, slot_meta0};
    else if (t_index_q == 16'(ST_REG_SLOT1))     reg_read_now = {46'd0, slot_meta1};
    else if (t_index_q == 16'(ST_REG_SLOT2))     reg_read_now = {46'd0, slot_meta2};
    else if (t_index_q == 16'(ST_REG_COUNTERS))  reg_read_now = counters_rdata;
    else if (t_index_q >= 16'(ST_REG_SCROLL0) && t_index_q < 16'(ST_REG_SCROLL0 + 16))
      reg_read_now = {46'd0, reg_written[t_index_q[3:0]], reg_flip[t_index_q[3:0]],
                      reg_raw_flat[16*t_index_q[3:0] +: 16]};
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      fsm_q      <= S_IDLE;
      t_write_q  <= 1'b0;
      t_region_q <= '0;
      t_index_q  <= '0;
      t_err_q    <= ST_ERR_NONE;
      rdata_q    <= '0;
      err_q      <= ST_ERR_NONE;
      done_q     <= 1'b0;
    end else begin
      done_q <= 1'b0;
      case (fsm_q)
        S_IDLE: begin
          if (accept) begin
            t_write_q  <= st_write;
            t_region_q <= st_region;
            t_index_q  <= st_index;
            t_err_q    <= err_d;
            fsm_q      <= S_WAIT;
          end
        end
        S_WAIT: begin
          err_q <= t_err_q;
          if (t_err_q != ST_ERR_NONE)                    rdata_q <= '0;
          else if (t_write_q)                            rdata_q <= '0;
          else if (t_region_q == ST_REGION_VRAM)         rdata_q <= {48'd0, va_rdata};
          else if (t_region_q == ST_REGION_GEN)          rdata_q <= gen_rdata;
          else                                           rdata_q <= reg_read_now;
          done_q <= 1'b1;
          fsm_q  <= S_DONE;
        end
        S_DONE: begin
          fsm_q <= S_IDLE;
        end
        default: fsm_q <= S_IDLE;
      endcase
    end
  end

  always_comb begin
    st_ready = (fsm_q == S_IDLE) & ~rst;
    st_done  = done_q;
    st_rdata = rdata_q;
    st_err   = err_q;
  end

endmodule

// Connects the GP command, VRAM, sprite generation and state owners.
`timescale 1ns/1ps
module rzgp_top
  import rzgp_pkg::*;
#(
  // 1 Garegga, 2 Batrider, 3 Bakraid, 4 Sorcer, 5 Kingdom; other values admit no transactions.
  parameter int PROFILE_ID = 1
) (
  input  logic        clk,
  input  logic        rst,
  // ---- CPU command service ----
  input  logic        req_valid,
  output logic        req_ready,
  input  logic        req_write,
  input  logic [2:0]  req_offset,
  input  logic [15:0] req_data,
  input  logic [1:0]  req_lanes,
  input  logic [7:0]  req_tag,
  output logic        rsp_valid,
  input  logic        rsp_ready,
  output logic [15:0] rsp_data,
  output logic        rsp_fault,
  output logic [7:0]  rsp_tag,
  // ---- status / interrupt ----
  input  logic [15:0] status_word,
  output logic        irq_ack,
  // ---- capture event and status ----
  input  logic        capture_event,
  output logic        capture_busy,
  output logic        capture_pending,
  output logic        capture_done,
  output logic [15:0] capture_seq,
  output logic [15:0] cnt_capture_deferred,
  output logic [15:0] cnt_capture_overrun,
  output logic [15:0] cnt_capture_collision,
  output logic [15:0] cnt_capture_ignored,
  // ---- renderer: tile descriptor services ----
  input  logic        t0_rd_en,
  input  logic [9:0]  t0_rd_idx,
  output logic [31:0] t0_rd_pair,
  output logic        t0_rd_valid,
  input  logic        t1_rd_en,
  input  logic [9:0]  t1_rd_idx,
  output logic [31:0] t1_rd_pair,
  output logic        t1_rd_valid,
  input  logic        t2_rd_en,
  input  logic [9:0]  t2_rd_idx,
  output logic [31:0] t2_rd_pair,
  output logic        t2_rd_valid,
  // ---- renderer: sprite descriptor service + job ownership ----
  input  logic        spr_rd_en,
  input  logic [7:0]  spr_rd_index,
  output logic [63:0] spr_rd_entry,
  output logic        spr_rd_valid,
  output logic        spr_rd_gen_valid,
  output logic [15:0] spr_rd_gen_seq,
  input  logic        job_acquire,
  input  logic        job_release,
  output logic        job_held,
  output logic        job_gen_valid,
  output logic [15:0] job_gen_seq,
  output logic        job_gen_collided,
  output logic        job_acq_refused,
  output logic [15:0] job_spr_scroll_y,
  output logic        job_spr_scroll_y_valid,
  // ---- renderer: live scroll/control views ----
  output logic [15:0]  spr_scroll_x_live,     // raw register 6, undelayed
  output logic [15:0]  spr_scroll_y_view,     // raw register 7, retained at capture
  output logic         spr_scroll_y_view_valid,
  output logic [15:0]  sel_raw,               // full raw selector word
  output logic [255:0] reg_raw_flat,          // sixteen raw register words
  output logic [15:0]  reg_flip,
  output logic [15:0]  reg_written,
  output logic [15:0]  pointer,
  // ---- quiesce and state access ----
  input  logic        quiesce_req,
  output logic        quiesce_ack,
  input  logic        st_valid,
  output logic        st_ready,
  input  logic        st_write,
  input  logic [3:0]  st_region,
  input  logic [15:0] st_index,
  input  logic [63:0] st_wdata,
  output logic        st_done,
  output logic [63:0] st_rdata,
  output logic [1:0]  st_err,
  // ---- compile-time profile report ----
  output logic [2:0]  profile_id,
  output logic        profile_supported,
  output logic        profile_measured
);

  localparam bit PROFILE_OK = profile_is_supported(PROFILE_ID);
  localparam bit PROFILE_MEASURED = profile_is_measured(PROFILE_ID);

  assign profile_id        = PROFILE_OK ? 3'(PROFILE_ID) : 3'(PROFILE_UNSUPPORTED);
  assign profile_supported = PROFILE_OK;
  assign profile_measured  = PROFILE_MEASURED;

  // quiesce: ack only after a full cycle with no admissions possible
  logic quiesce_req_d, quiesce_ack_q;
  logic cmd_idle, epoch_idle;

  always_ff @(posedge clk) begin
    if (rst) begin
      quiesce_req_d <= 1'b0;
      quiesce_ack_q <= 1'b0;
    end else begin
      quiesce_req_d <= quiesce_req;
      quiesce_ack_q <= quiesce_req & quiesce_req_d & cmd_idle & epoch_idle;
    end
  end
  always_comb quiesce_ack = quiesce_ack_q;

  // command owner
  logic        c_va_en, c_va_we;
  logic [12:0] c_va_addr;
  logic [15:0] c_va_wdata;
  logic [15:0] va_rdata;
  logic [15:0] voffs_w, sel_raw_w;
  logic [255:0] reg_raw_flat_w;
  logic [15:0] reg_flip_w, reg_written_w;
  logic        st_reg_we;
  logic [4:0]  st_reg_idx;
  logic [31:0] st_reg_wdata;

  rzgp_cmd u_cmd (
    .clk (clk), .rst (rst), .profile_ok (PROFILE_OK),
    .req_valid (req_valid), .req_ready (req_ready), .req_write (req_write),
    .req_offset (req_offset), .req_data (req_data), .req_lanes (req_lanes), .req_tag (req_tag),
    .rsp_valid (rsp_valid), .rsp_ready (rsp_ready), .rsp_data (rsp_data),
    .rsp_fault (rsp_fault), .rsp_tag (rsp_tag),
    .status_word (status_word), .irq_ack (irq_ack),
    .va_en (c_va_en), .va_we (c_va_we), .va_addr (c_va_addr), .va_wdata (c_va_wdata), .va_rdata (va_rdata),
    .quiesce_req (quiesce_req), .cmd_idle (cmd_idle),
    .voffs (voffs_w), .sel_raw (sel_raw_w), .reg_raw_flat (reg_raw_flat_w),
    .reg_flip (reg_flip_w), .reg_written (reg_written_w),
    .st_reg_we (st_reg_we), .st_reg_idx (st_reg_idx), .st_reg_wdata (st_reg_wdata)
  );

  // VRAM with the port A mux (state port owns it only while quiesced)
  logic        s_va_en, s_va_we;
  logic [12:0] s_va_addr;
  logic [15:0] s_va_wdata;
  logic        va_en, va_we;
  logic [12:0] va_addr;
  logic [15:0] va_wdata;
  logic        va_sprite_write;
  logic        sc_en;
  logic [7:0]  sc_entry;
  logic [63:0] sc_data;
  /* verilator lint_off UNUSEDSIGNAL */
  logic        sc_valid;   // copy engine tracks its own read pipeline
  /* verilator lint_on UNUSEDSIGNAL */

  always_comb begin
    if (quiesce_ack_q) begin
      va_en = s_va_en; va_we = s_va_we; va_addr = s_va_addr; va_wdata = s_va_wdata;
    end else begin
      va_en = c_va_en; va_we = c_va_we; va_addr = c_va_addr; va_wdata = c_va_wdata;
    end
  end

  rzgp_vram u_vram (
    .clk (clk), .rst (rst),
    .a_en (va_en), .a_we (va_we), .a_addr (va_addr), .a_wdata (va_wdata), .a_rdata (va_rdata),
    .a_sprite_write (va_sprite_write),
    .t0_en (t0_rd_en), .t0_idx (t0_rd_idx), .t0_pair (t0_rd_pair), .t0_valid (t0_rd_valid),
    .t1_en (t1_rd_en), .t1_idx (t1_rd_idx), .t1_pair (t1_rd_pair), .t1_valid (t1_rd_valid),
    .t2_en (t2_rd_en), .t2_idx (t2_rd_idx), .t2_pair (t2_rd_pair), .t2_valid (t2_rd_valid),
    .s_en (sc_en), .s_entry (sc_entry), .s_data (sc_data), .s_valid (sc_valid)
  );

  // epoch / generation owner
  logic        st_gen_we, st_gen_rd_en;
  logic [9:0]  st_gen_addr;
  logic [63:0] st_gen_wdata;
  logic        bk_we;
  logic [63:0] bk_wdata, bk_rdata;
  logic        slot_we;
  logic [1:0]  slot_we_idx;
  logic [17:0] slot_wdata, slot_meta0, slot_meta1, slot_meta2;
  logic        yview_we;
  logic [16:0] yview_wdata;
  logic [15:0] cnt_def, cnt_ovr, cnt_col, cnt_ign;

  rzgp_epoch u_epoch (
    .clk (clk), .rst (rst),
    .capture_event (capture_event & PROFILE_OK), .quiesce_req (quiesce_req), .st_mode (quiesce_ack_q),
    .sc_en (sc_en), .sc_entry (sc_entry), .sc_data (sc_data),
    .live_sprite_write (va_sprite_write),
    .spr_scroll_y_live (reg_raw_flat_w[16*REG_SP_Y +: 16]),
    .job_acquire (job_acquire & PROFILE_OK), .job_release (job_release),
    .job_held (job_held), .job_gen_valid (job_gen_valid), .job_gen_seq (job_gen_seq),
    .job_gen_collided (job_gen_collided), .job_acq_refused (job_acq_refused),
    .job_spr_scroll_y (job_spr_scroll_y), .job_spr_scroll_y_valid (job_spr_scroll_y_valid),
    .spr_scroll_y_view (spr_scroll_y_view), .spr_scroll_y_view_valid (spr_scroll_y_view_valid),
    .spr_rd_en (spr_rd_en), .spr_rd_index (spr_rd_index), .spr_rd_entry (spr_rd_entry),
    .spr_rd_valid (spr_rd_valid), .spr_rd_gen_valid (spr_rd_gen_valid), .spr_rd_gen_seq (spr_rd_gen_seq),
    .capture_busy (capture_busy), .capture_pending (capture_pending), .capture_done (capture_done),
    .capture_seq (capture_seq),
    .cnt_deferred (cnt_def), .cnt_overrun (cnt_ovr), .cnt_collision (cnt_col), .cnt_ignored (cnt_ign),
    .epoch_idle (epoch_idle),
    .st_gen_we (st_gen_we), .st_gen_rd_en (st_gen_rd_en), .st_gen_addr (st_gen_addr), .st_gen_wdata (st_gen_wdata),
    .bk_we (bk_we), .bk_wdata (bk_wdata), .bk_rdata (bk_rdata),
    .slot_we (slot_we), .slot_we_idx (slot_we_idx), .slot_wdata (slot_wdata),
    .slot_meta0 (slot_meta0), .slot_meta1 (slot_meta1), .slot_meta2 (slot_meta2),
    .yview_we (yview_we), .yview_wdata (yview_wdata)
  );

  // state-access port
  rzgp_state u_state (
    .clk (clk), .rst (rst), .quiesced (quiesce_ack_q),
    .st_valid (st_valid), .st_ready (st_ready), .st_write (st_write), .st_region (st_region),
    .st_index (st_index), .st_wdata (st_wdata), .st_done (st_done), .st_rdata (st_rdata), .st_err (st_err),
    .voffs (voffs_w), .sel_raw (sel_raw_w), .reg_raw_flat (reg_raw_flat_w),
    .reg_flip (reg_flip_w), .reg_written (reg_written_w),
    .st_reg_we (st_reg_we), .st_reg_idx (st_reg_idx), .st_reg_wdata (st_reg_wdata),
    .st_va_en (s_va_en), .st_va_we (s_va_we), .st_va_addr (s_va_addr), .st_va_wdata (s_va_wdata), .va_rdata (va_rdata),
    .st_gen_we (st_gen_we), .st_gen_rd_en (st_gen_rd_en), .st_gen_addr (st_gen_addr), .st_gen_wdata (st_gen_wdata),
    .gen_rdata (spr_rd_entry),
    .bk_we (bk_we), .bk_wdata (bk_wdata), .bk_rdata (bk_rdata),
    .slot_we (slot_we), .slot_we_idx (slot_we_idx), .slot_wdata (slot_wdata),
    .slot_meta0 (slot_meta0), .slot_meta1 (slot_meta1), .slot_meta2 (slot_meta2),
    .yview_we (yview_we), .yview_wdata (yview_wdata),
    .yview_rdata ({spr_scroll_y_view_valid, spr_scroll_y_view}),
    .counters_rdata ({cnt_ign, cnt_col, cnt_ovr, cnt_def})
  );

  // live views
  always_comb begin
    spr_scroll_x_live     = reg_raw_flat_w[16*REG_SP_X +: 16];
    sel_raw               = sel_raw_w;
    reg_raw_flat          = reg_raw_flat_w;
    reg_flip              = reg_flip_w;
    reg_written           = reg_written_w;
    pointer               = voffs_w;
    cnt_capture_deferred  = cnt_def;
    cnt_capture_overrun   = cnt_ovr;
    cnt_capture_collision = cnt_col;
    cnt_capture_ignored   = cnt_ign;
  end

endmodule

// Board-bus GP owner: object-bank register, IRQ latch, compact save state and generation rebuild.
module rzgp_native_owner #(
    parameter integer PROFILE=1,VRAM_INDEX=25,REG_INDEX=27
) (
    input logic late_en,   // Batrider/Bakraid board active: enables the object-bank register
    input logic clk,rst,quiesce_req,control_hold,
    output wire quiesce_ack,
    input logic request,
    input logic [2:0] operation,bank_slot,
    input logic [15:0] data_in,
    input logic [1:0] byte_lanes,
    output wire acknowledge,
    output wire [15:0] data_out,
    output wire idle,copy_idle,
    input logic [15:0] status_word,
    input logic irq_event,capture_event,
    output wire vint_n,
    output wire [31:0] object_banks,
    output wire [255:0] raw_registers,
    output wire [15:0] raw_selector,axis_flags,register_written,
    output wire [15:0] sprite_x_live,sprite_y_view,
    output wire sprite_y_valid,
    input logic [2:0] tile_en,
    input logic [29:0] tile_index,
    output wire [2:0] tile_valid,
    output wire [95:0] tile_pairs,
    input logic job_acquire,job_release,
    output wire job_held,job_valid,
    output wire [15:0] job_sequence,job_y,
    output wire job_y_valid,
    input logic sprite_en,
    input logic [7:0] sprite_index,
    output wire sprite_valid,sprite_generation_valid,
    output wire [63:0] sprite_entry,
    output wire [15:0] sprite_sequence,
    output wire capture_busy,capture_pending,capture_done,
    output wire [15:0] capture_sequence,
    output wire [63:0] capture_counts,
    output wire rebuilding,
    output logic [7:0] fault,
    input logic [63:0] ss_data,
    input logic [31:0] ss_addr,
    input logic [7:0] ss_select,
    input logic ss_write,ss_read,ss_query,
    output wire [63:0] ss_data_out,
    output wire ss_ack,ss_error
);
    localparam bit SUPPORTED=PROFILE>=1 && PROFILE<=5;
    localparam bit LATE=PROFILE==2 || PROFILE==3;
    typedef enum logic [2:0] {IDLE,RELEASE,START,COPY_WAIT,REQUIESCE,RESPONSE} rebuild_t;
    rebuild_t rebuild_phase;
    wire rebuild_request;
    logic rebuild_done;
    wire warm_cycle=rebuild_phase==RELEASE || rebuild_phase==START || rebuild_phase==COPY_WAIT;
    wire late_now=LATE && late_en;
    wire bank_request=request && operation==6 && late_now;
    logic bank_seen,bank_ack,irq_pending;
    logic [31:0] bank_values;
    wire cpu_idle,cpu_drained,gp_quiesced,state_idle,irq_ack,job_refused;
    wire hold_active=quiesce_req || !state_idle || rebuild_phase!=IDLE;
    wire [2:0] cpu_fault;
    wire cpu_ack;
    wire [15:0] cpu_data,pointer;
    wire req_valid,req_ready,req_write,rsp_valid,rsp_ready,rsp_fault;
    wire [2:0] req_offset;
    wire [15:0] req_data,rsp_data;
    wire [1:0] req_lanes;
    wire [7:0] req_tag,rsp_tag;
    wire [95:0] raw_tile_pairs;
    wire [63:0] raw_sprite_entry;
    wire st_valid,st_ready,st_write,st_done;
    wire [3:0] st_region;
    wire [15:0] st_index;
    wire [63:0] st_wdata;
    wire [15:0] st_rdata;
    wire [47:0] unused_st_rdata_high;
    wire [1:0] st_err;
    wire auxiliary_write;
    wire [32:0] auxiliary_data;
    wire unused_job_collided,unused_profile_supported,unused_profile_measured;
    wire [2:0] unused_profile_id;
    wire [15:0] deferred_count,overrun_count,collision_count,ignored_count;

    assign idle=cpu_idle && !request && state_idle && rebuild_phase==IDLE;
    assign copy_idle=!capture_busy && !capture_pending && !job_held && rebuild_phase==IDLE;
    assign rebuilding=rebuild_phase!=IDLE;
    assign quiesce_ack=hold_active && cpu_drained && (!quiesce_req || !request) && (gp_quiesced || rebuilding);
    assign acknowledge=bank_request ? bank_ack:cpu_ack;
    assign data_out=bank_request ? 16'd0:cpu_data;
    assign vint_n=!irq_pending;
    assign object_banks=bank_values;
    assign sprite_entry=sprite_generation_valid ? raw_sprite_entry:64'd0;
    assign capture_counts={ignored_count,collision_count,overrun_count,deferred_count};
    genvar plane;
    generate for(plane=0;plane<3;plane=plane+1) begin: pair_order
        assign tile_pairs[plane*32+:32]={raw_tile_pairs[plane*32+:16],raw_tile_pairs[plane*32+16+:16]};
    end endgenerate

    rzgp_bus_link cpu_link (
        .clk(clk),.rst(rst),.hold_admission(hold_active || control_hold),
        .request(request && !bank_request),.operation(operation),.data_in(data_in),.lanes(byte_lanes),
        .acknowledge(cpu_ack),.data_out(cpu_data),.idle(cpu_idle),.transport_idle(cpu_drained),.fault(cpu_fault),
        .req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),.req_offset(req_offset),
        .req_data(req_data),.req_lanes(req_lanes),.req_tag(req_tag),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.rsp_fault(rsp_fault),.rsp_tag(rsp_tag)
    );
    rzgp_top #(.PROFILE_ID(PROFILE)) storage (
        .clk(clk),.rst(rst),.req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),
        .req_offset(req_offset),.req_data(req_data),.req_lanes(req_lanes),.req_tag(req_tag),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_data(rsp_data),.rsp_fault(rsp_fault),.rsp_tag(rsp_tag),
        .status_word(status_word),.irq_ack(irq_ack),
        .capture_event(rebuild_phase==START || (capture_event && rebuild_phase==IDLE && !control_hold)),
        .capture_busy(capture_busy),.capture_pending(capture_pending),.capture_done(capture_done),
        .capture_seq(capture_sequence),.cnt_capture_deferred(deferred_count),.cnt_capture_overrun(overrun_count),
        .cnt_capture_collision(collision_count),.cnt_capture_ignored(ignored_count),
        .t0_rd_en(tile_en[0]),.t0_rd_idx(tile_index[0+:10]),.t0_rd_pair(raw_tile_pairs[0+:32]),.t0_rd_valid(tile_valid[0]),
        .t1_rd_en(tile_en[1]),.t1_rd_idx(tile_index[10+:10]),.t1_rd_pair(raw_tile_pairs[32+:32]),.t1_rd_valid(tile_valid[1]),
        .t2_rd_en(tile_en[2]),.t2_rd_idx(tile_index[20+:10]),.t2_rd_pair(raw_tile_pairs[64+:32]),.t2_rd_valid(tile_valid[2]),
        .spr_rd_en(sprite_en),.spr_rd_index(sprite_index),.spr_rd_entry(raw_sprite_entry),
        .spr_rd_valid(sprite_valid),.spr_rd_gen_valid(sprite_generation_valid),.spr_rd_gen_seq(sprite_sequence),
        .job_acquire(job_acquire && !hold_active),.job_release(job_release),.job_held(job_held),.job_gen_valid(job_valid),
        .job_gen_seq(job_sequence),.job_gen_collided(unused_job_collided),.job_acq_refused(job_refused),
        .job_spr_scroll_y(job_y),.job_spr_scroll_y_valid(job_y_valid),
        .spr_scroll_x_live(sprite_x_live),.spr_scroll_y_view(sprite_y_view),.spr_scroll_y_view_valid(sprite_y_valid),
        .sel_raw(raw_selector),.reg_raw_flat(raw_registers),.reg_flip(axis_flags),.reg_written(register_written),.pointer(pointer),
        .quiesce_req(hold_active && cpu_drained && !warm_cycle),.quiesce_ack(gp_quiesced),
        .st_valid(st_valid),.st_ready(st_ready),.st_write(st_write),.st_region(st_region),.st_index(st_index),
        .st_wdata(st_wdata),.st_done(st_done),.st_rdata({unused_st_rdata_high,st_rdata}),.st_err(st_err),
        .profile_id(unused_profile_id),.profile_supported(unused_profile_supported),.profile_measured(unused_profile_measured)
    );
    rzgp_state_minimal #(.LATE(LATE),.VRAM_INDEX(VRAM_INDEX),.REG_INDEX(REG_INDEX)) state_pack (
        .late_en(late_en),
        .clk(clk),.rst(rst),.quiesced(gp_quiesced && hold_active && SUPPORTED),
        .ss_data(ss_data),.ss_addr(ss_addr),.ss_select(ss_select),.ss_write(ss_write),.ss_read(ss_read),.ss_query(ss_query),
        .ss_data_out(ss_data_out),.ss_ack(ss_ack),.ss_error(ss_error),.idle(state_idle),
        .pointer(pointer),.selector(raw_selector),.reg_flip(axis_flags[7:0]),.reg_values(raw_registers[127:0]),
        .auxiliary({irq_pending,bank_values}),.auxiliary_write(auxiliary_write),.auxiliary_data(auxiliary_data),
        .rebuild_request(rebuild_request),.rebuild_done(rebuild_done),
        .st_valid(st_valid),.st_ready(st_ready),.st_write(st_write),.st_region(st_region),.st_index(st_index),
        .st_wdata(st_wdata),.st_done(st_done),.st_rdata(st_rdata),.st_err(st_err)
    );
    always_ff @(posedge clk) begin
        rebuild_done<=0;
        if(rst)begin rebuild_phase<=IDLE;rebuild_done<=0;end
        else case(rebuild_phase)
            IDLE: if(rebuild_request)rebuild_phase<=RELEASE;
            RELEASE: if(!gp_quiesced)rebuild_phase<=START;
            START: rebuild_phase<=COPY_WAIT;
            COPY_WAIT: if(capture_done)rebuild_phase<=REQUIESCE;
            REQUIESCE: if(gp_quiesced)begin rebuild_done<=1;rebuild_phase<=RESPONSE;end
            RESPONSE: if(!rebuild_request)rebuild_phase<=IDLE;
            default:rebuild_phase<=IDLE;
        endcase
    end
    always_ff @(posedge clk) begin
        if(rst)begin bank_seen<=0;bank_ack<=0;bank_values<=0;irq_pending<=0;fault<=0;end
        else begin
            fault[2:0]<=fault[2:0] | cpu_fault;
            if(job_refused || (job_acquire && hold_active))fault[3]<=1;
            if(!bank_request)begin bank_seen<=0;bank_ack<=0;end
            else if(!bank_seen && !hold_active && !control_hold && SUPPORTED)begin
                bank_seen<=1;bank_ack<=1;
                if(byte_lanes[0])bank_values[bank_slot*4+:4]<=data_in[3:0];
                if(byte_lanes==0)fault[4]<=1;
            end
            if(irq_event && !hold_active && !control_hold && SUPPORTED)irq_pending<=1;
            if(irq_ack)irq_pending<=0;
            if(auxiliary_write)begin bank_values<=late_now ? auxiliary_data[31:0]:32'd0;irq_pending<=auxiliary_data[32];end
        end
    end
endmodule

// Forwards a held board request to the GP command port exactly once.
module rzgp_bus_link (
    input logic clk,rst,hold_admission,
    input logic request,
    input logic [2:0] operation,
    input logic [15:0] data_in,
    input logic [1:0] lanes,
    output logic acknowledge,
    output logic [15:0] data_out,
    output wire idle,
    output wire transport_idle,
    output logic [2:0] fault,
    output logic req_valid,
    input logic req_ready,
    output logic req_write,
    output logic [2:0] req_offset,
    output logic [15:0] req_data,
    output logic [1:0] req_lanes,
    output logic [7:0] req_tag,
    input logic rsp_valid,
    output wire rsp_ready,
    input logic [15:0] rsp_data,
    input logic rsp_fault,
    input logic [7:0] rsp_tag
);
    logic seen,outstanding,cancelled;
    logic [7:0] sequence_number;
    assign idle=!request && !req_valid && !outstanding;
    assign transport_idle=!req_valid && !outstanding;
    assign rsp_ready=outstanding;

    always_ff @(posedge clk) begin
        if(rst) begin
            seen<=0;outstanding<=0;cancelled<=0;sequence_number<=0;
            acknowledge<=0;data_out<=0;fault<=0;
            req_valid<=0;req_write<=0;req_offset<=0;req_data<=0;req_lanes<=0;req_tag<=0;
        end else begin
            if(!request) begin
                seen<=0;acknowledge<=0;
                if(req_valid || outstanding) cancelled<=1;
            end
            if(request && !seen && !req_valid && !outstanding && !hold_admission) begin
                seen<=1;cancelled<=0;acknowledge<=0;
                if(operation>5) begin
                    acknowledge<=1;data_out<=16'hffff;fault[0]<=1;
                end else begin
                    req_valid<=1;req_data<=data_in;req_lanes<=lanes;req_tag<=sequence_number;
                    req_write<=operation!=2 && operation!=3;
                    case(operation)
                        0:req_offset<=0;
                        1,2:req_offset<=2;
                        3:req_offset<=3;
                        4:req_offset<=4;
                        5:req_offset<=6;
                        default:req_offset<=0;
                    endcase
                end
            end
            if(req_valid && req_ready) begin
                req_valid<=0;outstanding<=1;sequence_number<=sequence_number+8'd1;
            end
            if(rsp_valid && rsp_ready) begin
                outstanding<=0;
                if(rsp_tag!=req_tag || rsp_fault) fault[2]<=1;
                if(request && !cancelled) begin
                    acknowledge<=1;
                    data_out<=rsp_tag==req_tag && !rsp_fault ? rsp_data:16'hffff;
                end
            end
            if(rsp_valid && !outstanding) fault[1]<=1;
        end
    end
endmodule

// Saves VRAM and GP controls; a restore rebuilds the sprite generations.
module rzgp_state_minimal #(
    parameter bit LATE=0,
    parameter integer VRAM_INDEX=25, REG_INDEX=27
) (
    input logic late_en,   // bank register is saved only for Batrider/Bakraid
    input logic clk,rst,quiesced,
    input logic [63:0] ss_data,
    input logic [31:0] ss_addr,
    input logic [7:0] ss_select,
    input logic ss_write,ss_read,ss_query,
    output logic [63:0] ss_data_out,
    output logic ss_ack,ss_error,
    output wire idle,
    input logic [15:0] pointer,selector,
    input logic [7:0] reg_flip,
    input logic [127:0] reg_values,
    input logic [32:0] auxiliary,
    output logic auxiliary_write,
    output logic [32:0] auxiliary_data,
    output wire rebuild_request,
    input logic rebuild_done,
    output wire st_valid,
    input logic st_ready,
    output logic st_write,
    output logic [3:0] st_region,
    output logic [15:0] st_index,
    output logic [63:0] st_wdata,
    input logic st_done,
    input logic [15:0] st_rdata,
    input logic [1:0] st_err
);
    localparam integer VRAM_COUNT=1792;
    wire [2:0] REG_COUNT=(LATE && late_en) ? 3'd4 : 3'd3;
    typedef enum logic [2:0] {IDLE,PLAN,ISSUE,WAIT_REPLY,WARM,WARM_GAP,FINISH} phase_t;
    phase_t phase;
    logic seen,cancelled,writing,abort_rebuild;
    logic [7:0] selection;
    logic [31:0] address;
    logic [63:0] payload,result;
    logic [3:0] step;
    logic [1:0] warm_remaining;
    wire [2:0] raw_index=3'((address-1)*4)+3'(step);
    wire activity=ss_write || ss_read || ss_query;
    wire selected=ss_select==8'(VRAM_INDEX) || ss_select==8'(REG_INDEX);
    wire abandoned=cancelled || !activity;
    wire terminal_write=selection==8'(VRAM_INDEX) ? address==1791:address==32'(REG_COUNT)-1;
    assign st_valid=phase==ISSUE;
    assign rebuild_request=phase==WARM;
    assign idle=phase==IDLE;

    always_ff @(posedge clk) begin
        auxiliary_write<=0;
        if(rst) begin
            phase<=IDLE;seen<=0;cancelled<=0;writing<=0;abort_rebuild<=0;
            selection<=0;address<=0;payload<=0;result<=0;step<=0;warm_remaining<=0;
            ss_ack<=0;ss_error<=0;ss_data_out<=0;auxiliary_write<=0;auxiliary_data<=0;
            st_write<=0;st_region<=0;st_index<=0;st_wdata<=0;
        end else begin
            if(!activity) begin
                seen<=0;ss_ack<=0;ss_error<=0;ss_data_out<=0;
                if(phase!=IDLE)cancelled<=1;
            end
            case(phase)
                IDLE: if(activity && selected && !seen) begin
                    seen<=1;cancelled<=0;abort_rebuild<=0;ss_ack<=0;ss_error<=0;ss_data_out<=0;
                    if(ss_query && !(ss_write || ss_read)) begin
                        ss_data_out<={ss_select,22'd0,2'd3,
                            ss_select==8'(VRAM_INDEX) ? 32'(VRAM_COUNT):32'(REG_COUNT)};
                        ss_ack<=1;
                    end else if(!quiesced || ss_query || ss_write==ss_read ||
                        (ss_select==8'(VRAM_INDEX) && ss_addr>=VRAM_COUNT) ||
                        (ss_select==8'(REG_INDEX) && ss_addr>=32'(REG_COUNT))) begin
                        ss_ack<=1;ss_error<=1;
                    end else begin
                        selection<=ss_select;address<=ss_addr;payload<=ss_data;writing<=ss_write;
                        step<=0;result<=0;phase<=PLAN;
                    end
                end
                PLAN: begin
                    st_write<=writing;st_region<=0;st_index<=0;st_wdata<=0;phase<=ISSUE;
                    if(selection==8'(VRAM_INDEX)) begin
                        st_region<=1;st_index<={3'd0,address[10:0],2'b00}+16'(step);
                        st_wdata<={48'd0,payload[step*16+:16]};
                    end else if(!writing) begin
                        case(address[1:0])
                            0:result<={23'd0,auxiliary[32],reg_flip,selector,pointer};
                            1:result<=reg_values[0+:64];
                            2:result<=reg_values[64+:64];
                            default:result<={32'd0,auxiliary[31:0]};
                        endcase
                        phase<=FINISH;
                    end else if(address==0) begin
                        if(step==0) begin
                            st_index<=0;st_wdata<={48'd0,payload[15:0]};
                            auxiliary_write<=1;auxiliary_data<={payload[40],auxiliary[31:0]};
                        end else if(step==1) begin st_index<=1;st_wdata<={48'd0,payload[31:16]};end
                        else begin
                            st_index<=16'd14+16'(step);
                            st_wdata<={46'd0,1'b1,payload[30+step],reg_values[(step-2)*16+:16]};
                        end
                    end else if(address<3) begin
                        st_index<=16'd16+16'(raw_index);
                        st_wdata<={46'd0,1'b1,reg_flip[raw_index],payload[step*16+:16]};
                    end else begin
                        auxiliary_write<=1;auxiliary_data<={auxiliary[32],payload[31:0]};phase<=FINISH;
                    end
                end
                ISSUE: if(st_ready)phase<=WAIT_REPLY;
                WAIT_REPLY: if(st_done) begin
                    if(st_err!=0 || !quiesced)begin ss_error<=1;phase<=FINISH;end
                    else if(selection==8'(VRAM_INDEX)) begin
                        if(!writing)result[step*16+:16]<=st_rdata;
                        if(step==3)phase<=FINISH;
                        else begin step<=step+4'd1;phase<=PLAN;end
                    end else if((address==0 && step==9) || (address!=0 && step==3))phase<=FINISH;
                    else begin step<=step+4'd1;phase<=PLAN;end
                end
                FINISH: begin
                    if(writing && !abort_rebuild && (terminal_write || abandoned))begin
                        warm_remaining<=abandoned ? 2:1;abort_rebuild<=abandoned;phase<=WARM;
                    end else begin
                        if(activity && !cancelled)begin ss_ack<=1;ss_data_out<=writing ? 64'd0:result;end
                        phase<=IDLE;
                    end
                end
                WARM: if(rebuild_done)begin
                    if(abandoned && !abort_rebuild)begin
                        abort_rebuild<=1;warm_remaining<=1;phase<=WARM_GAP;
                    end else if(warm_remaining>1)begin warm_remaining<=warm_remaining-2'd1;phase<=WARM_GAP;end
                    else begin abort_rebuild<=1;phase<=FINISH;end
                end
                WARM_GAP: if(!rebuild_done)phase<=WARM;
                default:phase<=IDLE;
            endcase
        end
    end
endmodule
