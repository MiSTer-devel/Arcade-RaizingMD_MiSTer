// SPDX-License-Identifier: GPL-3.0-or-later
// YM2151 (IKAOPM) state owner and the Z80 wrapper.

// OPM state adapter constants and saved-bit masks.
`timescale 1ns/1ps
/* verilator lint_off UNUSEDPARAM */
package rzopm_pkg;

  localparam logic [15:0] SCHEMA_ID    = 16'h5A31;
  localparam int unsigned IMAGE_WORDS  = 31;
  localparam int unsigned REPLAY_STEPS = 243;   // 0..242, step 242 = selector

  // transport operations
  localparam logic [3:0] OP_STATUS        = 4'd0;
  localparam logic [3:0] OP_SAVE_BEGIN    = 4'd1;
  localparam logic [3:0] OP_READ          = 4'd2;
  localparam logic [3:0] OP_END           = 4'd3;
  localparam logic [3:0] OP_RESTORE_BEGIN = 4'd4;
  localparam logic [3:0] OP_WRITE         = 4'd5;
  localparam logic [3:0] OP_COMMIT        = 4'd6;
  localparam logic [3:0] OP_ABORT         = 4'd7;
  localparam logic [3:0] OP_RECOVER       = 4'd8;

  // response / latched error codes
  localparam logic [3:0] ST_OK             = 4'd0;
  localparam logic [3:0] ST_ERR_OP         = 4'd1;
  localparam logic [3:0] ST_ERR_PHASE      = 4'd2;
  localparam logic [3:0] ST_ERR_HOLD       = 4'd3;
  localparam logic [3:0] ST_ERR_INDEX      = 4'd4;
  localparam logic [3:0] ST_ERR_SCHEMA     = 4'd5;
  localparam logic [3:0] ST_ERR_INCOMPLETE = 4'd6;
  localparam logic [3:0] ST_ERR_PADDING    = 4'd7;
  localparam logic [3:0] ST_ERR_CHECKSUM   = 4'd8;
  localparam logic [3:0] ST_ERR_CONFLICT   = 4'd9;
  localparam logic [3:0] ST_ERR_RESET      = 4'd10;
  localparam logic [3:0] ST_ERR_NO_ENABLE  = 4'd11;
  localparam logic [3:0] ST_ERR_STUCK      = 4'd12;
  localparam logic [3:0] ST_ERR_ABORTED    = 4'd13;

  // phases
  localparam logic [2:0] PH_NORMAL     = 3'd0;
  localparam logic [2:0] PH_SAVE_DRAIN = 3'd1;
  localparam logic [2:0] PH_SAVE_READY = 3'd2;
  localparam logic [2:0] PH_STAGE      = 3'd3;
  localparam logic [2:0] PH_COMMIT     = 3'd4;
  localparam logic [2:0] PH_ERROR      = 3'd5;

  // last asynchronous result
  localparam logic [3:0] RES_NONE     = 4'd0;
  localparam logic [3:0] RES_SEALED   = 4'd1;
  localparam logic [3:0] RES_RESTORED = 4'd2;
  localparam logic [3:0] RES_FAILED   = 4'd3;

  // sticky diagnostic bits
  localparam int DG_OVERLAP     = 0;
  localparam int DG_DROPPED     = 1;
  localparam int DG_REACCEPT    = 2;
  localparam int DG_CONFLICT    = 3;
  localparam int DG_CPU_READ    = 4;
  localparam int DG_SHORT_RESET = 5;
  localparam int DG_ENABLE_GAP  = 6;

  // Address bits 7:3 select the mask for each high-register byte.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [7:0] hi_mask(input logic [7:0] a);
  /* verilator lint_on UNUSEDSIGNAL */
    case (a[7:5])
      3'b001: begin
        case (a[4:3])
          2'b00:   hi_mask = 8'hFF;   // 0x20-0x27 RL FL CONNECT
          2'b01:   hi_mask = 8'h7F;   // 0x28-0x2F KC
          2'b10:   hi_mask = 8'hFC;   // 0x30-0x37 KF
          default: hi_mask = 8'h73;   // 0x38-0x3F PMS AMS
        endcase
      end
      3'b010, 3'b011: hi_mask = 8'h7F; // 0x40-0x5F DT1 MUL, 0x60-0x7F TL
      3'b100, 3'b110: hi_mask = 8'hDF; // 0x80-0x9F KS AR, 0xC0-0xDF DT2 D2R
      3'b101:         hi_mask = 8'h9F; // 0xA0-0xBF AMS-EN D1R
      3'b111:         hi_mask = 8'hFF; // 0xE0-0xFF D1L RR
      default:        hi_mask = 8'h00; // not a high register
    endcase
  endfunction

  // Selects the saved low-register mask for each byte of word 29.
  function automatic logic [7:0] lo_a_mask(input logic [2:0] lane);
    case (lane)
      3'd0: lo_a_mask = 8'hFF;  // TEST
      3'd1: lo_a_mask = 8'h9F;  // 0x0F NE NFRQ
      3'd2: lo_a_mask = 8'hFF;  // CLKA1
      3'd3: lo_a_mask = 8'h03;  // CLKA2
      3'd4: lo_a_mask = 8'hFF;  // CLKB
      3'd5: lo_a_mask = 8'h8F;  // 0x14 persistent bits
      3'd6: lo_a_mask = 8'hFF;  // LFRQ
      default: lo_a_mask = 8'hC3; // 0x1B CT2 CT1 W
    endcase
  endfunction

  // word 30 lane masks
  function automatic logic [7:0] lo_b_mask(input logic [2:0] lane);
    case (lane)
      3'd0: lo_b_mask = 8'h7F;  // AMD
      3'd1: lo_b_mask = 8'h7F;  // PMD
      3'd2: lo_b_mask = 8'hFF;  // selector
      3'd3: lo_b_mask = 8'h00;  // reserved
      default: lo_b_mask = 8'hFF; // key nibbles
    endcase
  endfunction

  // register address carried by word w (1..28) lane l
  function automatic logic [7:0] hi_addr(input logic [4:0] word, input logic [2:0] lane);
    hi_addr = {word + 5'd3, lane};
  endfunction

  // mask of any payload lane (words 1..30); 0 outside
  function automatic logic [7:0] image_mask(input logic [4:0] word, input logic [2:0] lane);
    if (word == 5'd0)       image_mask = 8'h00;
    else if (word <= 5'd28) image_mask = hi_mask(hi_addr(word, lane));
    else if (word == 5'd29) image_mask = lo_a_mask(lane);
    else if (word == 5'd30) image_mask = lo_b_mask(lane);
    else                    image_mask = 8'h00;
  endfunction

endpackage
/* verilator lint_on UNUSEDPARAM */

// OPM register shadow (live image) and restore staging image; high registers in byte RAM with valid bits.

`timescale 1ns/1ps
module rzopm_image
  import rzopm_pkg::*;
(
  input  logic       clk,
  input  logic       mrst_n,            // mirrored chip master reset
  input  logic       ncen,              // mirrored phi1 N enable
  input  logic [4:0] slot,              // mirrored register slot counter
  // captured writes from the bus mirror
  input  logic       accept,
  input  logic       accept_is_data,
  input  logic [7:0] accept_byte,
  output logic       pending,           // a captured byte is still waiting for its slot
  // rd_byte is valid one cycle after the read address.
  input  logic       rd_stage,          // 0 = live image, 1 = staging area
  input  logic [4:0] rd_word,
  input  logic [2:0] rd_lane,
  output logic [7:0] rd_byte,
  // staging write port
  input  logic       stg_we,
  input  logic [4:0] stg_word,
  input  logic [2:0] stg_lane,
  input  logic [7:0] stg_byte,
  output logic       stg_lost,          // staging write dropped: the shadow wrote this edge
  output logic [7:0] selector
);
  // ---------------------------------------------------------------- low registers
  // cleared by chip master reset (low at power-up)
  logic [7:0] test_q;
  logic       ne_q;
  logic [4:0] nfrq_q;
  logic [7:0] clka1_q;
  logic [1:0] clka2_q;
  logic [7:0] clkb_q;
  logic       run_a_q, run_b_q, irq_a_q, irq_b_q, csm_q;
  logic [7:0] lfrq_q;
  logic [6:0] amd_q;
  logic [6:0] pmd_q;
  logic [1:0] w_q;
  logic [1:0] ct_q;
  logic [31:0] kon_q;                   // nibble c = channel c keys {C2,M2,C1,M1}, as committed
  logic [6:0]  kon_temp_q;              // last 0x08 byte: {key bits, channel}
  logic        kon_pend_q;              // a 0x08 byte not yet applied to its channel
  logic [223:0] valid_q;                // high-register byte written since reset
  // pending high-register byte, its address and valid flag
  logic        pend_v_q;
  logic [7:0]  pend_addr_q, pend_byte_q;
  // Master reset keeps dvalid_q and a low selector; a high selector becomes 0xFF.
  /* verilator lint_off PROCASSINIT */
  logic [7:0] sel_q    = 8'h00;
  logic       dvalid_q = 1'b0;
  /* verilator lint_on PROCASSINIT */

  wire sel_is_hi = (sel_q[7:5] != 3'b000);
  // slot match: 8-slot groups 0x20-0x3F compare three bits, 32-slot groups five
  wire pend_match = (pend_addr_q[7:5] == 3'b001) ? (slot[2:0] == pend_addr_q[2:0]) : (slot == pend_addr_q[4:0]);
  wire kon_match  = (slot == {2'b00, kon_temp_q[2:0]});
  wire hi_write   = ncen & mrst_n & pend_v_q & pend_match;
  wire [7:0] hi_index = pend_addr_q - 8'h20;

  always_ff @(posedge clk) begin
    if (!mrst_n) begin
      // Clear low registers; a held dvalid_q queues byte 0xFF at register 0xFF.
      test_q <= 8'h00; ne_q <= 1'b0; nfrq_q <= 5'h00;
      clka1_q <= 8'h00; clka2_q <= 2'b00; clkb_q <= 8'h00;
      run_a_q <= 1'b0; run_b_q <= 1'b0; irq_a_q <= 1'b0; irq_b_q <= 1'b0; csm_q <= 1'b0;
      lfrq_q <= 8'h00; amd_q <= 7'h00; pmd_q <= 7'h00; w_q <= 2'b00; ct_q <= 2'b00;
      kon_q <= 32'h0; kon_temp_q <= 7'h00; kon_pend_q <= 1'b0;
      valid_q <= '0;
      if (sel_is_hi) sel_q <= 8'hFF;
      pend_v_q    <= dvalid_q;
      pend_addr_q <= 8'hFF;
      pend_byte_q <= 8'hFF;
    end else begin
      if (accept & ~accept_is_data) begin
        sel_q    <= accept_byte;
        dvalid_q <= 1'b0;
        pend_v_q <= 1'b0;
      end
      // Low registers update at capture; high-register bytes wait for their slot.
      if (accept & accept_is_data) begin
        if (sel_is_hi) begin
          dvalid_q    <= 1'b1;
          pend_v_q    <= 1'b1;
          pend_addr_q <= sel_q;
          pend_byte_q <= accept_byte & hi_mask(sel_q);
        end else begin
          case (sel_q)
            8'h01: test_q <= accept_byte;
            8'h08: begin kon_temp_q <= accept_byte[6:0]; kon_pend_q <= 1'b1; end
            8'h0F: begin ne_q <= accept_byte[7]; nfrq_q <= accept_byte[4:0]; end
            8'h10: clka1_q <= accept_byte;
            8'h11: clka2_q <= accept_byte[1:0];
            8'h12: clkb_q  <= accept_byte;
            8'h14: begin
              run_a_q <= accept_byte[0]; run_b_q <= accept_byte[1];
              irq_a_q <= accept_byte[2]; irq_b_q <= accept_byte[3];
              csm_q   <= accept_byte[7];
            end
            8'h18: lfrq_q <= accept_byte;
            8'h19: begin
              if (accept_byte[7]) pmd_q <= accept_byte[6:0];
              else                amd_q <= accept_byte[6:0];
            end
            8'h1B: begin w_q <= accept_byte[1:0]; ct_q <= accept_byte[7:6]; end
            default: ;                                                     // no decoder: discarded
          endcase
        end
      end
      // High-register and key bytes commit on their matching slot.
      if (hi_write) begin
        valid_q[hi_index] <= 1'b1;
        if (~(accept & accept_is_data & sel_is_hi)) pend_v_q <= 1'b0;      // keep pending if another high-register write arrives this edge
      end
      if (ncen & kon_match) begin
        kon_q[4*kon_temp_q[2:0] +: 4] <= kon_temp_q[6:3];
        if (~(accept & accept_is_data & (sel_q == 8'h08))) kon_pend_q <= 1'b0;
      end
    end
  end

  assign pending = pend_v_q | kon_pend_q;

  // ---------------------------------------------------------------- RAM
  logic [8:0] ram_waddr, ram_raddr;
  logic [7:0] ram_wdata, ram_q;
  logic       ram_we;

  assign ram_we    = hi_write | stg_we;
  assign ram_waddr = hi_write ? {1'b0, pend_addr_q} : {1'b1, stg_word, stg_lane};
  assign ram_wdata = hi_write ? pend_byte_q : stg_byte;
  assign stg_lost  = hi_write & stg_we;
  assign ram_raddr = rd_stage ? {1'b1, rd_word, rd_lane} : {1'b0, rd_word + 5'd3, rd_lane};

  rzopm_ram512x8 u_ram (
    .clk(clk), .we(ram_we), .waddr(ram_waddr), .wdata(ram_wdata),
    .raddr(ram_raddr), .q(ram_q)
  );

  // ---------------------------------------------------------------- read mux
  logic [1:0] src_q;            // 0 live RAM, 1 low-register lane, 2 staging RAM
  logic       valid_r;
  logic [7:0] lo_r;
  logic [7:0] lo_byte;
  wire  [7:0] rd_index = {rd_word - 5'd1, rd_lane};

  always_comb begin
    lo_byte = 8'h00;
    if (rd_word == 5'd29) begin
      case (rd_lane)
        3'd0: lo_byte = test_q;
        3'd1: lo_byte = {ne_q, 2'b00, nfrq_q};
        3'd2: lo_byte = clka1_q;
        3'd3: lo_byte = {6'b0, clka2_q};
        3'd4: lo_byte = clkb_q;
        3'd5: lo_byte = {csm_q, 3'b000, irq_b_q, irq_a_q, run_b_q, run_a_q};
        3'd6: lo_byte = lfrq_q;
        default: lo_byte = {ct_q, 4'b0000, w_q};
      endcase
    end else begin
      case (rd_lane)
        3'd0: lo_byte = {1'b0, amd_q};
        3'd1: lo_byte = {1'b0, pmd_q};
        3'd2: lo_byte = sel_q;
        3'd3: lo_byte = 8'h00;
        3'd4: lo_byte = kon_q[7:0];
        3'd5: lo_byte = kon_q[15:8];
        3'd6: lo_byte = kon_q[23:16];
        default: lo_byte = kon_q[31:24];
      endcase
    end
  end

  always_ff @(posedge clk) begin
    src_q   <= rd_stage ? 2'd2 : ((rd_word >= 5'd29) ? 2'd1 : 2'd0);
    valid_r <= valid_q[rd_index];
    lo_r    <= lo_byte;
  end

  always_comb begin
    case (src_q)
      2'd1:    rd_byte = lo_r;
      2'd2:    rd_byte = ram_q;
      default: rd_byte = ram_q & {8{valid_r}};
    endcase
  end

  assign selector = sel_q;
endmodule

// 512x8 image RAM: 0x000-0x0FF live high registers, 0x100-0x1FF staging; read-during-write returns old data.

`timescale 1ns/1ps
module rzopm_ram512x8 (
  input  logic       clk,
  input  logic       we,
  input  logic [8:0] waddr,
  input  logic [7:0] wdata,
  input  logic [8:0] raddr,
  output logic [7:0] q
);
  logic [7:0] mem [0:511];

  always_ff @(posedge clk) begin
    if (we) mem[waddr] <= wdata;
    q <= mem[raddr];
  end
endmodule

// Mirrors IKAOPM_timinggen (fully synchronous, fast reset): phi1 enables, master reset, slot counter.

`timescale 1ns/1ps
module rzopm_cen_mirror (
  input  logic clk,
  input  logic chip_cen_n,   // i_phiM_PCEN_n as the chip sees it
  input  logic chip_ic_n,    // i_IC_n as the chip sees it
  input  logic chip_phi1,    // o_phi1
  output logic cen,          // phiM enable, active high
  output logic pcen,         // phi1 positive-edge enable, active high
  output logic ncen,         // phi1 negative-edge enable, active high
  output logic mrst_n,       // chip internal master reset, active low
  output logic [4:0] slot    // register slot counter
);
  // Power-up initial values only; no adapter reset.

  /* verilator lint_off PROCASSINIT */
  logic [3:0] ic_int        = 4'b0000;
  logic       ic_negedge    = 1'b1;
  logic       synced_mrst_n = 1'b0;
  logic       phi1n         = 1'b1;
  logic [4:0] tg_cntr       = 5'h00;     // master cycle counter
  /* verilator lint_on PROCASSINIT */
  logic       cycle31_q;                 // CYCLE_31
  logic [4:0] slot_q;

  wire phi1_init = ic_negedge | ~chip_ic_n;

  assign cen    = ~chip_cen_n;
  assign mrst_n = synced_mrst_n & chip_ic_n;
  assign pcen   = ~((chip_phi1 | chip_cen_n) & chip_ic_n);
  assign ncen   = ~((phi1n     | chip_cen_n) & chip_ic_n);

  always_ff @(posedge clk) begin
    if (cen) begin
      ic_int     <= {ic_int[2:0], chip_ic_n};
      ic_negedge <= ~ic_int[2] & ic_int[3];
    end
    if (ncen) synced_mrst_n <= ic_int[2];
    if (cen | ~chip_ic_n) begin
      if (phi1_init) phi1n <= 1'b1;
      else           phi1n <= chip_phi1;
    end
    // master cycle counter and CYCLE_31
    if (ncen) begin
      if (!mrst_n) tg_cntr <= 5'h00;
      else         tg_cntr <= (tg_cntr == 5'h1F) ? 5'h00 : tg_cntr + 5'h01;
      cycle31_q <= (tg_cntr == 5'd30);
    end
    // register slot counter: counts on every P edge, reset by CYCLE_31 or master reset
    if (pcen) begin
      if (cycle31_q | ~mrst_n) slot_q <= 5'h00;
      else                     slot_q <= slot_q + 5'h01;
    end
  end
  assign slot = slot_q;
endmodule

// Mirrors the IKAOPM write front end from the chip pins and phi1 enables, without driving the chip.
`timescale 1ns/1ps
module rzopm_bus_mirror (
  input  logic       clk,
  input  logic       pcen,            // phi1 positive-edge enable
  input  logic       ncen,            // phi1 negative-edge enable
  input  logic       mrst_n,          // chip master reset (mirrored)
  input  logic       chip_cs_n,
  input  logic       chip_wr_n,
  input  logic       chip_a0,
  input  logic [7:0] chip_din,
  // one pulse per logical write captured by the chip (synced2 rising, N1)
  output logic       accept,
  output logic       accept_is_data,
  output logic [7:0] accept_byte,
  // mirrored front-end state for the replay sequencer
  output logic       lat_a,
  output logic       lat_d,
  output logic       s1_a,
  output logic       s1_d,
  output logic       in_flight,       // a write is between latch set and N1
  output logic       strobe,          // synchronized write strobe active
  output logic       idle,            // nothing in flight and no strobe
  // diagnostic pulses (made sticky in rzopm_ctl)
  output logic       dg_overlap,      // byte in flight changed before capture
  output logic       dg_dropped,      // strobe ended inside the blocked window
  output logic       dg_reaccept      // held strobe accepted again
);
  // input synchronizers have no reset
  logic [1:0] cs_sc;
  logic [1:0] wr_sc;
  logic [1:0] a0_sc;
  logic [7:0] din_sc0;
  logic [7:0] din_sc1;
  wire        cs_n = cs_sc[1];
  wire        wr_n = wr_sc[1];
  wire        a0   = a0_sc[1];
  wire  [7:0] din  = din_sc1;

  wire temp_en = ~(cs_n | wr_n);

  logic [7:0] temp;                            // write data latch
  logic       lat_a_q;                         // address request latch
  logic       lat_d_q;                         // data request latch
  logic       s0_a_q, s1_a_q, s2_a_q;          // request synchronizer stages
  logic       s0_d_q, s1_d_q, s2_d_q;
  logic [7:0] inlatch;                         // captured byte

  wire set_d = ~(cs_n | wr_n | ~a0 | ~mrst_n | s1_d_q);
  wire rst_d = s1_d_q | ~mrst_n;
  wire set_a = ~(cs_n | wr_n |  a0 | ~mrst_n | s1_a_q);
  wire rst_a = s1_a_q | ~mrst_n;

  // diagnostics bookkeeping
  logic temp_en_q;
  logic held_a_q, held_d_q;                  // strobe continuously low since the last set
  logic blk_a_q, blk_d_q;                    // strobe started inside the blocked window
  logic acc_a_q, acc_d_q;
  logic ov_q, drop_q, re_q;

  wire set_a_eff = set_a & ~rst_a;             // set with reset clears
  wire set_d_eff = set_d & ~rst_d;
  wire strobe_new = temp_en & ~temp_en_q;
  wire infl_a = lat_a_q | s0_a_q | (s1_a_q & ~s2_a_q);
  wire infl_d = lat_d_q | s0_d_q | (s1_d_q & ~s2_d_q);

  always_ff @(posedge clk) begin
    cs_sc   <= {cs_sc[0], chip_cs_n};
    wr_sc   <= {wr_sc[0], chip_wr_n};
    a0_sc   <= {a0_sc[0], chip_a0};
    din_sc0 <= chip_din;
    din_sc1 <= din_sc0;

    // temporary data latch
    if (!mrst_n)      temp <= 8'h00;
    else if (temp_en) temp <= din;

    // request latches (reset wins over set)
    if (!mrst_n)    lat_d_q <= 1'b0;
    else if (rst_d) lat_d_q <= 1'b0;
    else if (set_d) lat_d_q <= 1'b1;
    if (!mrst_n)    lat_a_q <= 1'b0;
    else if (rst_a) lat_a_q <= 1'b0;
    else if (set_a) lat_a_q <= 1'b1;

    // synchronizer stages
    if (ncen) begin
      if (!mrst_n) begin
        s0_d_q <= 1'b0; s2_d_q <= 1'b0;
        s0_a_q <= 1'b0; s2_a_q <= 1'b0;
      end else begin
        s0_d_q <= lat_d_q; s2_d_q <= s1_d_q;
        s0_a_q <= lat_a_q; s2_a_q <= s1_a_q;
      end
    end
    if (pcen) begin
      if (!mrst_n) begin
        s1_d_q <= 1'b0; s1_a_q <= 1'b0;
      end else begin
        s1_d_q <= s0_d_q; s1_a_q <= s0_a_q;
      end
    end

    // captured byte
    if (ncen) begin
      if (!mrst_n)                 inlatch <= 8'h00;
      else if (s1_a_q | s1_d_q)    inlatch <= temp;
    end

    // acceptance pulses: synced2 rising at N1
    acc_d_q <= ncen & mrst_n & s1_d_q;
    acc_a_q <= ncen & mrst_n & s1_a_q;

    // diagnostics; reaccept flags a new latch assertion, not a held set input
    temp_en_q <= temp_en;
    held_a_q  <= (set_a_eff & ~lat_a_q) ? 1'b1 : (held_a_q & temp_en);
    held_d_q  <= (set_d_eff & ~lat_d_q) ? 1'b1 : (held_d_q & temp_en);
    re_q      <= (set_a_eff & ~lat_a_q & held_a_q) | (set_d_eff & ~lat_d_q & held_d_q);

    if (!mrst_n)                                   blk_a_q <= 1'b0;
    else if (strobe_new & ~a0 & s1_a_q & ~lat_a_q) blk_a_q <= 1'b1;
    else if (set_a_eff | ~temp_en)                 blk_a_q <= 1'b0;
    if (!mrst_n)                                   blk_d_q <= 1'b0;
    else if (strobe_new &  a0 & s1_d_q & ~lat_d_q) blk_d_q <= 1'b1;
    else if (set_d_eff | ~temp_en)                 blk_d_q <= 1'b0;
    drop_q <= ((blk_a_q & ~set_a_eff) | (blk_d_q & ~set_d_eff)) & ~temp_en & mrst_n;

    ov_q <= temp_en & (din != temp) & (infl_a | infl_d) & mrst_n;
  end

  assign accept         = acc_a_q | acc_d_q;
  assign accept_is_data = acc_d_q;
  assign accept_byte    = inlatch;
  assign lat_a          = lat_a_q;
  assign lat_d          = lat_d_q;
  assign s1_a           = s1_a_q;
  assign s1_d           = s1_d_q;
  assign in_flight      = infl_a | infl_d;
  assign strobe         = temp_en;
  assign idle           = ~(infl_a | infl_d | temp_en);
  assign dg_overlap     = ov_q;
  assign dg_dropped     = drop_q;
  assign dg_reaccept    = re_q;
endmodule

// Resets the chip, replays the saved register image, then waits for drain and timer lead.

`timescale 1ns/1ps
module rzopm_replay #(
  parameter int RESET_HOST_EDGES = 256,
  parameter int RESET_CEN_EDGES  = 8,
  parameter int DRAIN_PHI1       = 36,
  parameter int STROBE_EDGES     = 4,
  parameter int WRITE_WAIT_PHI1  = 8,
  parameter int COMMIT_WAIT_PHI1 = 40,
  parameter int STEP_CEN_MAX     = 512,   // parent enables per step before ERR_STUCK, independent of the chip's phi1
  parameter int TIMER_LEAD_CEN   = 22716  // parent enables from the 0x14 capture to done when a timer runs (0 = none)
)(
  input  logic       clk,
  input  logic       rst,
  input  logic       start,          // pulse: begin replay of a validated image
  input  logic       kill,           // pulse: stop immediately
  // chip cadence / mirror
  input  logic       cen,
  input  logic       ncen,
  input  logic       mrst_n,
  input  logic       lat_a,
  input  logic       lat_d,
  input  logic       s1_a,
  input  logic       s1_d,
  input  logic       acc_a,
  input  logic       acc_d,
  input  logic       img_pending,    // the captured byte has not reached its register slot yet
  // staging read port (one-cycle latency)
  output logic [4:0] rd_word,
  output logic [2:0] rd_lane,
  input  logic [7:0] rd_byte,
  // chip pins while the adapter owns them
  output logic       ic_n,
  output logic       cs_n,
  output logic       wr_n,
  output logic       a0,
  output logic [7:0] din,
  // status
  output logic       busy,
  output logic       done,           // pulse: every write and the selector drained
  output logic       stuck,          // pulse: a bounded wait expired
  output logic [7:0] progress        // steps completed
);
  localparam logic [3:0] R_IDLE    = 4'd0;
  localparam logic [3:0] R_RESET   = 4'd1;
  localparam logic [3:0] R_RELEASE = 4'd2;
  localparam logic [3:0] R_FETCH   = 4'd3;
  localparam logic [3:0] R_FETCH2  = 4'd4;
  localparam logic [3:0] R_APRE    = 4'd5;
  localparam logic [3:0] R_ASTROBE = 4'd6;
  localparam logic [3:0] R_AWAIT   = 4'd7;
  localparam logic [3:0] R_DPRE    = 4'd8;
  localparam logic [3:0] R_DSTROBE = 4'd9;
  localparam logic [3:0] R_DWAIT   = 4'd10;
  localparam logic [3:0] R_DRAIN   = 4'd11;
  localparam logic [3:0] R_COMMIT  = 4'd12;
  localparam logic [3:0] R_LEAD    = 4'd13;
  localparam int LEAD_W = $clog2(TIMER_LEAD_CEN + 2);

  logic [3:0]  st_q;
  logic [7:0]  step_q;
  logic [15:0] host_cnt_q;
  logic [7:0]  cen_cnt_q;
  logic [7:0]  ncen_cnt_q;
  logic [7:0]  addr_q, data_q;
  logic        is_sel_q;
  logic        mrst_seen_q;
  logic        done_q, stuck_q;
  // per-step watchdog in parent enables
  logic [9:0]  step_cen_q;
  logic [3:0]  st_prev_q;
  // timer lead counter: starts at the 0x14 capture, saturates at TIMER_LEAD_CEN
  logic              lead_on_q;
  logic [LEAD_W-1:0] lead_q;
  localparam logic [LEAD_W-1:0] LEAD_TARGET = TIMER_LEAD_CEN[LEAD_W-1:0];
  wire               lead_met = (lead_q >= LEAD_TARGET);

  // ------------------------------------------------------------ step table
  // The replay table puts timer registers before operator and key registers.
  logic [7:0] t_addr;
  logic [4:0] t_word;
  logic [2:0] t_lane;
  logic       t_is_sel, t_or80, t_is_kon, t_is_tmr;
  logic [2:0] t_kon_ch;

  always_comb begin
    t_addr = 8'h00; t_word = 5'd29; t_lane = 3'd0;
    t_is_sel = 1'b0; t_or80 = 1'b0; t_is_kon = 1'b0; t_is_tmr = 1'b0; t_kon_ch = 3'd0;
    if (step_q == 8'd0) begin
      t_addr = 8'h01; t_word = 5'd29; t_lane = 3'd0;
    end else if (step_q <= 8'd4) begin
      case (step_q)
        8'd1:    begin t_addr = 8'h10; t_word = 5'd29; t_lane = 3'd2; end
        8'd2:    begin t_addr = 8'h11; t_word = 5'd29; t_lane = 3'd3; end
        8'd3:    begin t_addr = 8'h12; t_word = 5'd29; t_lane = 3'd4; end
        default: begin t_addr = 8'h14; t_word = 5'd29; t_lane = 3'd5; t_is_tmr = 1'b1; end  // 4: starts the lead
      endcase
    end else if (step_q <= 8'd228) begin
      t_addr = step_q + 8'h1B;                       // 0x20 .. 0xFF
      // word = ((step-5) >> 3) + 1, lane = (step-5) & 7
      t_word = 5'((step_q - 8'd5) >> 3) + 5'd1;
      t_lane = 3'((step_q - 8'd5) & 8'd7);
    end else begin
      case (step_q)
        8'd229: begin t_addr = 8'h0F; t_word = 5'd29; t_lane = 3'd1; end
        8'd230: begin t_addr = 8'h18; t_word = 5'd29; t_lane = 3'd6; end
        8'd231: begin t_addr = 8'h19; t_word = 5'd30; t_lane = 3'd0; end                 // AMD
        8'd232: begin t_addr = 8'h19; t_word = 5'd30; t_lane = 3'd1; t_or80 = 1'b1; end  // PMD
        8'd233: begin t_addr = 8'h1B; t_word = 5'd29; t_lane = 3'd7; end
        8'd234, 8'd235, 8'd236, 8'd237, 8'd238, 8'd239, 8'd240, 8'd241: begin
          t_addr = 8'h08; t_word = 5'd30; t_is_kon = 1'b1;
          t_kon_ch = 3'(step_q - 8'd234);
          t_lane = {1'b1, t_kon_ch[2:1]};               // lanes 4..7 hold channel pairs
        end
        default: begin t_addr = 8'h00; t_word = 5'd30; t_lane = 3'd2; t_is_sel = 1'b1; end // 242 selector
      endcase
    end
  end

  logic [7:0] fetched;
  always_comb begin
    if (t_is_kon)
      fetched = {1'b0, (t_kon_ch[0] ? rd_byte[7:4] : rd_byte[3:0]), t_kon_ch};
    else if (t_or80)
      fetched = rd_byte | 8'h80;
    else
      fetched = rd_byte;
  end

  // ------------------------------------------------------------ sequencer
  wire reset_elapsed = (host_cnt_q >= 16'(RESET_HOST_EDGES)) & (cen_cnt_q >= 8'(RESET_CEN_EDGES));
  wire wait_expired  = (ncen_cnt_q >= 8'(WRITE_WAIT_PHI1));
  wire release_expired = (ncen_cnt_q >= 8'(2 * WRITE_WAIT_PHI1));
  wire commit_expired  = (ncen_cnt_q >= 8'(COMMIT_WAIT_PHI1));

  wire step_expired = (step_cen_q >= 10'(STEP_CEN_MAX));

  always_ff @(posedge clk) begin
    done_q  <= 1'b0;
    stuck_q <= 1'b0;
    st_prev_q <= st_q;
    if ((st_q == R_IDLE) | (st_q == R_FETCH) | (st_q == R_LEAD) |
        (st_q != st_prev_q & st_q == R_RELEASE) | (st_q != st_prev_q & st_q == R_DRAIN))
      step_cen_q <= 10'd0;
    else if (cen & ~step_expired)
      step_cen_q <= step_cen_q + 10'd1;
    if (rst | kill | ((st_q == R_IDLE) & start)) begin
      lead_on_q <= 1'b0; lead_q <= '0;
    end else if (lead_on_q & cen & ~lead_met)
      lead_q <= lead_q + 1'b1;
    if (rst | kill) begin
      st_q <= R_IDLE;
      step_q <= 8'd0;
      host_cnt_q <= 16'd0; cen_cnt_q <= 8'd0; ncen_cnt_q <= 8'd0;
    end else if ((st_q != R_IDLE) & (st_q != R_RESET) & step_expired) begin
      st_q <= R_IDLE;
      stuck_q <= 1'b1;
    end else begin
      case (st_q)
        R_IDLE: begin
          if (start) begin
            st_q <= R_RESET;
            step_q <= 8'd0;
            host_cnt_q <= 16'd0; cen_cnt_q <= 8'd0; ncen_cnt_q <= 8'd0;
          end
        end

        R_RESET: begin
          if (host_cnt_q != 16'hFFFF) host_cnt_q <= host_cnt_q + 16'd1;
          if (cen & (cen_cnt_q != 8'hFF)) cen_cnt_q <= cen_cnt_q + 8'd1;
          if (reset_elapsed) begin
            st_q <= R_RELEASE;
            ncen_cnt_q <= 8'd0;
            host_cnt_q <= 16'd0;
            mrst_seen_q <= 1'b0;
          end
        end

        R_RELEASE: begin
          // wait for the mirrored master reset to rise, then two more N edges
          if (ncen) ncen_cnt_q <= ncen_cnt_q + 8'd1;
          if (~mrst_seen_q) begin
            if (mrst_n) begin mrst_seen_q <= 1'b1; ncen_cnt_q <= 8'd0; end
            else if (release_expired) begin st_q <= R_IDLE; stuck_q <= 1'b1; end
          end else if (ncen_cnt_q >= 8'd2) begin
            st_q <= R_FETCH;
          end
        end

        R_FETCH:  st_q <= R_FETCH2;          // rd_word/rd_lane presented this cycle

        R_FETCH2: begin                       // rd_byte valid now
          addr_q   <= t_is_sel ? fetched : t_addr;   // the selector step strobes the saved address itself
          data_q   <= fetched;
          is_sel_q <= t_is_sel;
          ncen_cnt_q <= 8'd0;
          st_q <= R_APRE;
        end

        R_APRE: begin                         // wait until the address latch is free
          if (ncen) ncen_cnt_q <= ncen_cnt_q + 8'd1;
          if (mrst_n & ~lat_a & ~s1_a) begin st_q <= R_ASTROBE; host_cnt_q <= 16'd0; end
          else if (wait_expired) begin st_q <= R_IDLE; stuck_q <= 1'b1; end
        end

        R_ASTROBE: begin
          host_cnt_q <= host_cnt_q + 16'd1;
          if (host_cnt_q == 16'(STROBE_EDGES - 1)) begin st_q <= R_AWAIT; ncen_cnt_q <= 8'd0; end
        end

        R_AWAIT: begin                        // wait for capture (N1)
          if (ncen) ncen_cnt_q <= ncen_cnt_q + 8'd1;
          if (acc_a) begin
            ncen_cnt_q <= 8'd0;
            st_q <= is_sel_q ? R_DRAIN : R_DPRE;
          end else if (wait_expired) begin st_q <= R_IDLE; stuck_q <= 1'b1; end
        end

        R_DPRE: begin
          if (ncen) ncen_cnt_q <= ncen_cnt_q + 8'd1;
          if (mrst_n & ~lat_d & ~s1_d) begin st_q <= R_DSTROBE; host_cnt_q <= 16'd0; end
          else if (wait_expired) begin st_q <= R_IDLE; stuck_q <= 1'b1; end
        end

        R_DSTROBE: begin
          host_cnt_q <= host_cnt_q + 16'd1;
          if (host_cnt_q == 16'(STROBE_EDGES - 1)) begin st_q <= R_DWAIT; ncen_cnt_q <= 8'd0; end
        end

        R_DWAIT: begin
          if (ncen) ncen_cnt_q <= ncen_cnt_q + 8'd1;
          if (acc_d) begin
            ncen_cnt_q <= 8'd0;
            st_q <= R_COMMIT;
            // the captured 0x14 byte: a set run bit arms the lead from this edge
            if (t_is_tmr) begin lead_on_q <= |data_q[1:0]; lead_q <= '0; end
          end else if (wait_expired) begin st_q <= R_IDLE; stuck_q <= 1'b1; end
        end

        R_COMMIT: begin                       // wait until the byte reached its register slot
          if (ncen) ncen_cnt_q <= ncen_cnt_q + 8'd1;
          if (~img_pending) begin
            step_q <= step_q + 8'd1;
            st_q <= R_FETCH;
          end else if (commit_expired) begin st_q <= R_IDLE; stuck_q <= 1'b1; end
        end

        R_DRAIN: begin                        // DRAIN_PHI1 N edges after the selector capture
          if (ncen) ncen_cnt_q <= ncen_cnt_q + 8'd1;
          if (ncen_cnt_q >= 8'(DRAIN_PHI1)) begin
            step_q <= step_q + 8'd1;
            if (lead_on_q & ~lead_met) st_q <= R_LEAD;
            else begin st_q <= R_IDLE; done_q <= 1'b1; end
          end
        end

        R_LEAD: begin                         // pins idle, chip running on parent enables
          if (lead_met) begin st_q <= R_IDLE; done_q <= 1'b1; end
        end

        default: st_q <= R_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------ outputs
  assign rd_word = t_word;
  assign rd_lane = t_lane;
  assign ic_n    = (st_q != R_RESET);
  assign cs_n    = ~((st_q == R_ASTROBE) | (st_q == R_DSTROBE));
  assign wr_n    = cs_n;
  assign a0      = (st_q == R_DSTROBE);
  assign din     = (st_q == R_DSTROBE) ? data_q : addr_q;
  assign busy    = (st_q != R_IDLE);
  assign done    = done_q;
  assign stuck   = stuck_q;
  assign progress = step_q;
endmodule

// OPM state controller: one bounded response per request; seals images, validates restores, starts replay.
`timescale 1ns/1ps
module rzopm_ctl
  import rzopm_pkg::*;
#(
  parameter int CEN_SERVICE_MAX = 64,
  parameter int DRAIN_PHI1      = 36,
  parameter int STUCK_PHI1      = 96
)(
  input  logic        clk,
  input  logic        rst,
  // parent inputs
  input  logic        hold_cert,
  input  logic        parent_ic_n,
  input  logic        cpu_cs_n,
  input  logic        cpu_rd_n,
  input  logic        cpu_wr_n,
  // transport
  input  logic        sx_req_valid,
  output logic        sx_req_ready,
  input  logic [3:0]  sx_req_op,
  input  logic [5:0]  sx_req_index,
  input  logic [63:0] sx_req_data,
  output logic        sx_rsp_valid,
  input  logic        sx_rsp_ready,
  output logic [3:0]  sx_rsp_status,
  output logic [63:0] sx_rsp_data,
  // mirror
  input  logic        cen,
  input  logic        ncen,
  input  logic        mrst_n,
  input  logic        mir_idle,
  input  logic        img_pending,
  input  logic        dg_overlap,
  input  logic        dg_dropped,
  input  logic        dg_reaccept,
  // image read port and staging port
  output logic        img_rd_stage,
  output logic [4:0]  img_rd_word,
  output logic [2:0]  img_rd_lane,
  input  logic [7:0]  img_rd_byte,
  output logic        stg_we,
  output logic [4:0]  stg_word,
  output logic [2:0]  stg_lane,
  output logic [7:0]  stg_byte,
  // replay
  output logic        rp_start,
  output logic        rp_kill,
  input  logic        rp_done,
  input  logic        rp_stuck,
  input  logic [7:0]  rp_progress,
  // status
  output logic [2:0]  sx_phase,
  output logic        sx_owned,
  output logic        sx_muted,
  output logic [3:0]  sx_error,
  output logic [7:0]  sx_diag
);
  // ------------------------------------------------------------ state
  logic [2:0]  phase_q;
  logic        own_q, mute_q, done_q;
  logic [3:0]  err_q, res_q;
  logic [7:0]  diag_q;

  logic        rdy_q, rsp_v_q, rsp_is_read_q;
  logic [3:0]  rsp_st_q;
  logic [63:0] rsp_d_q;
  logic [4:0]  idx_q;
  logic [63:0] data_q;

  localparam logic [1:0] X_IDLE  = 2'd0;
  localparam logic [1:0] X_WRITE = 2'd1;
  localparam logic [1:0] X_SWEEP = 2'd2;    // READ or VALID sweep on behalf of a request
  logic [1:0]  xs_q;
  logic [2:0]  wlane_q;

  // sweep engine
  localparam logic [1:0] SW_READ  = 2'd0;
  localparam logic [1:0] SW_VALID = 2'd1;
  localparam logic [1:0] SW_SEAL  = 2'd2;
  logic        sw_active_q, sw_stage_q;
  logic [1:0]  sw_mode_q;
  logic [4:0]  sw_word_q, sw_last_q;
  logic [2:0]  sw_lane_q;
  logic        p1_v_q;
  logic [4:0]  p1_word_q;
  logic [2:0]  p1_lane_q;
  logic        fin_q;
  logic [63:0] acc_q;
  logic [15:0] vchk_q, hchk_q, chk_q;
  logic        vfail_q;
  logic [3:0]  vcode_q;
  logic        seal_started_q;

  logic [30:0] pres_q;

  logic [7:0]  drain_q, gap_q, mrst_low_q;
  logic [8:0]  stuck_q;          // parent enables spent in SAVE_DRAIN
  logic        cpu_wr_prev_q, mrst_prev_q;

  // ------------------------------------------------------------ helpers
  wire accept    = sx_req_valid & rdy_q;
  wire in_hold   = (phase_q == PH_SAVE_DRAIN) | (phase_q == PH_SAVE_READY) |
                   (phase_q == PH_STAGE) | (phase_q == PH_COMMIT);
  wire cpu_wr    = ~cpu_cs_n & ~cpu_wr_n;
  wire cpu_wr_new = cpu_wr & ~cpu_wr_prev_q;
  wire gap_err   = ~cen & (gap_q == 8'(CEN_SERVICE_MAX - 1));
  wire drained   = (phase_q == PH_SAVE_DRAIN) & mir_idle & ~img_pending & (drain_q >= 8'(DRAIN_PHI1)) & ~seal_started_q;

  // Encodes hold-time faults in priority order.
  wire ev_reset    = in_hold & ~parent_ic_n;
  wire ev_hold     = in_hold & ~hold_cert;
  wire ev_conflict = in_hold & (cpu_wr_new | ((phase_q != PH_COMMIT) & dg_reaccept));
  wire ev_gap      = ((phase_q == PH_SAVE_DRAIN) | (phase_q == PH_COMMIT)) & gap_err;
  wire ev_stuck    = ((phase_q == PH_SAVE_DRAIN) & (stuck_q >= 9'(2 * STUCK_PHI1))) |
                     ((phase_q == PH_COMMIT) & rp_stuck);
  wire ev_any      = ev_reset | ev_hold | ev_conflict | ev_gap | ev_stuck;
  logic [3:0] ev_code;
  always_comb begin
    if (ev_reset)         ev_code = ST_ERR_RESET;
    else if (ev_hold)     ev_code = ST_ERR_HOLD;
    else if (ev_conflict) ev_code = ST_ERR_CONFLICT;
    else if (ev_gap)      ev_code = ST_ERR_NO_ENABLE;
    else                  ev_code = ST_ERR_STUCK;
  end

  wire [63:0] status_word = {8'h00, SCHEMA_ID, 8'(IMAGE_WORDS), rp_progress, diag_q, res_q, err_q,
                             done_q, (phase_q == PH_SAVE_READY), hold_cert, mute_q, own_q, phase_q};

  // Validates the restore header lanes.
  logic hdr_bad;
  always_comb begin
    case (p1_lane_q)
      3'd0: hdr_bad = (img_rd_byte != SCHEMA_ID[7:0]);
      3'd1: hdr_bad = (img_rd_byte != SCHEMA_ID[15:8]);
      3'd2: hdr_bad = (img_rd_byte != 8'(IMAGE_WORDS));
      3'd4, 3'd5: hdr_bad = 1'b0;
      default: hdr_bad = (img_rd_byte != 8'h00);
    endcase
  end
  wire pad_bad = ((img_rd_byte & ~image_mask(p1_word_q, p1_lane_q)) != 8'h00);
  wire [15:0] lane_add = p1_lane_q[0] ? {img_rd_byte, 8'h00} : {8'h00, img_rd_byte};

  // ------------------------------------------------------------ main
  always_ff @(posedge clk) begin
    rp_start <= 1'b0;
    rp_kill  <= 1'b0;
    stg_we   <= 1'b0;
    fin_q    <= 1'b0;

    // sweep presentation pipeline (always running)
    p1_v_q    <= sw_active_q;
    p1_word_q <= sw_word_q;
    p1_lane_q <= sw_lane_q;

    cpu_wr_prev_q <= cpu_wr;
    mrst_prev_q   <= mrst_n;
    if (!mrst_n) begin
      if (mrst_low_q != 8'hFF) mrst_low_q <= mrst_low_q + 8'd1;
    end else mrst_low_q <= 8'd0;

    if (rst) begin
      phase_q <= PH_NORMAL; own_q <= 1'b0; mute_q <= 1'b0; done_q <= 1'b0;
      err_q <= ST_OK; res_q <= RES_NONE; diag_q <= 8'h00;
      rdy_q <= 1'b0; rsp_v_q <= 1'b0; rsp_is_read_q <= 1'b0; rsp_st_q <= ST_OK; rsp_d_q <= 64'h0;
      idx_q <= 5'd0; data_q <= 64'h0;
      xs_q <= X_IDLE; wlane_q <= 3'd0;
      sw_active_q <= 1'b0; sw_stage_q <= 1'b0; sw_mode_q <= SW_READ;
      sw_word_q <= 5'd0; sw_last_q <= 5'd0; sw_lane_q <= 3'd0;
      acc_q <= 64'h0; vchk_q <= 16'h0; hchk_q <= 16'h0; chk_q <= 16'h0;
      vfail_q <= 1'b0; vcode_q <= ST_OK; seal_started_q <= 1'b0;
      pres_q <= 31'h0;
      drain_q <= 8'd0; stuck_q <= 9'd0; gap_q <= 8'd0;
    end else begin
      // -------------------------------------------------- sticky diagnostics
      if (dg_overlap)  diag_q[DG_OVERLAP]  <= 1'b1;
      if (dg_dropped)  diag_q[DG_DROPPED]  <= 1'b1;
      if (dg_reaccept) diag_q[DG_REACCEPT] <= 1'b1;
      if (ev_conflict) diag_q[DG_CONFLICT] <= 1'b1;
      if (own_q & ~cpu_cs_n & ~cpu_rd_n) diag_q[DG_CPU_READ] <= 1'b1;
      if (mrst_n & ~mrst_prev_q & (mrst_low_q < 8'd64)) diag_q[DG_SHORT_RESET] <= 1'b1;
      if (ev_gap) diag_q[DG_ENABLE_GAP] <= 1'b1;

      // -------------------------------------------------- counters
      gap_q <= cen ? 8'd0 : ((gap_q == 8'(CEN_SERVICE_MAX - 1)) ? gap_q : gap_q + 8'd1);
      if (phase_q == PH_SAVE_DRAIN) begin
        if (~mir_idle) drain_q <= 8'd0;
        else if (ncen & (drain_q != 8'hFF)) drain_q <= drain_q + 8'd1;
        if (cen & (stuck_q != 9'h1FF)) stuck_q <= stuck_q + 9'd1;
      end else begin
        drain_q <= 8'd0; stuck_q <= 9'd0;
      end

      // -------------------------------------------------- sweep engine
      if (sw_active_q) begin
        if (sw_lane_q == 3'd7) begin
          sw_lane_q <= 3'd0;
          if (sw_word_q == sw_last_q) sw_active_q <= 1'b0;
          else sw_word_q <= sw_word_q + 5'd1;
        end else sw_lane_q <= sw_lane_q + 3'd1;
      end
      if (p1_v_q & ~vfail_q) begin
        case (sw_mode_q)
          SW_READ: acc_q[8*p1_lane_q +: 8] <= img_rd_byte;
          SW_SEAL: vchk_q <= vchk_q + lane_add;
          default: begin                                   // SW_VALID
            if (p1_word_q == 5'd0) begin
              if (p1_lane_q == 3'd4) hchk_q[7:0]  <= img_rd_byte;
              if (p1_lane_q == 3'd5) hchk_q[15:8] <= img_rd_byte;
              if (hdr_bad) begin vfail_q <= 1'b1; vcode_q <= ST_ERR_SCHEMA; sw_active_q <= 1'b0; end
            end else begin
              if (pad_bad) begin vfail_q <= 1'b1; vcode_q <= ST_ERR_PADDING; sw_active_q <= 1'b0; end
              vchk_q <= vchk_q + lane_add;
            end
          end
        endcase
      end
      if (p1_v_q & ~sw_active_q) fin_q <= 1'b1;            // last capture happened this edge

      // -------------------------------------------------- sweep completion
      if (fin_q) begin
        case (sw_mode_q)
          SW_READ: begin
            xs_q <= X_IDLE;
            rsp_v_q <= 1'b1; rsp_is_read_q <= 1'b1; rsp_d_q <= acc_q;
            rsp_st_q <= (phase_q == PH_SAVE_READY) ? ST_OK : ST_ERR_PHASE;
          end
          SW_SEAL: begin
            if (phase_q == PH_SAVE_DRAIN) begin
              chk_q <= vchk_q; phase_q <= PH_SAVE_READY; res_q <= RES_SEALED;
            end
          end
          default: begin                                   // SW_VALID
            xs_q <= X_IDLE;
            rsp_v_q <= 1'b1; rsp_is_read_q <= 1'b0;
            if (vfail_q)                      rsp_st_q <= vcode_q;
            else if (vchk_q != hchk_q)        rsp_st_q <= ST_ERR_CHECKSUM;
            else if (phase_q != PH_STAGE)     rsp_st_q <= ST_ERR_PHASE;
            else begin
              rsp_st_q <= ST_OK;
              phase_q <= PH_COMMIT; own_q <= 1'b1; mute_q <= 1'b1;
              rp_start <= 1'b1; gap_q <= 8'd0;
            end
          end
        endcase
      end

      // -------------------------------------------------- staging writes
      if (xs_q == X_WRITE) begin
        stg_we <= 1'b1;
        if (wlane_q == 3'd7) begin
          xs_q <= X_IDLE;
          if (phase_q == PH_STAGE) pres_q[idx_q] <= 1'b1;
          rsp_v_q <= 1'b1; rsp_is_read_q <= 1'b0;
          rsp_st_q <= (phase_q == PH_STAGE) ? ST_OK : ST_ERR_PHASE;
        end
        wlane_q <= wlane_q + 3'd1;
      end

      // -------------------------------------------------- seal start
      if (drained) begin
        seal_started_q <= 1'b1;
        sw_active_q <= 1'b1; sw_stage_q <= 1'b0; sw_mode_q <= SW_SEAL;
        sw_word_q <= 5'd1; sw_last_q <= 5'd30; sw_lane_q <= 3'd0;
        vchk_q <= 16'h0; vfail_q <= 1'b0;
      end

      // -------------------------------------------------- asynchronous events
      if (rp_done & (phase_q == PH_COMMIT)) begin
        phase_q <= PH_NORMAL; own_q <= 1'b0; mute_q <= 1'b0;
        done_q <= 1'b1; res_q <= RES_RESTORED;
      end
      if (ev_any) begin
        phase_q <= PH_ERROR; err_q <= ev_code; res_q <= RES_FAILED;
        if (phase_q == PH_COMMIT) rp_kill <= 1'b1;
      end

      // -------------------------------------------------- response handshake
      if (rsp_v_q & sx_rsp_ready) begin
        rsp_v_q <= 1'b0; rdy_q <= 1'b1;
      end
      if (~rdy_q & ~rsp_v_q & (xs_q == X_IDLE) & ~accept & ~fin_q) rdy_q <= 1'b1;

      // -------------------------------------------------- request acceptance
      if (accept) begin
        rdy_q <= 1'b0;
        idx_q <= sx_req_index[4:0];
        data_q <= sx_req_data;
        rsp_is_read_q <= 1'b0;
        case (sx_req_op)
          OP_STATUS: begin rsp_v_q <= 1'b1; rsp_st_q <= ST_OK; end

          OP_SAVE_BEGIN: begin
            rsp_v_q <= 1'b1;
            if (phase_q != PH_NORMAL)  rsp_st_q <= ST_ERR_PHASE;
            else if (~hold_cert)       rsp_st_q <= ST_ERR_HOLD;
            else begin
              rsp_st_q <= ST_OK;
              phase_q <= PH_SAVE_DRAIN; seal_started_q <= 1'b0;
              done_q <= 1'b0; res_q <= RES_NONE; gap_q <= 8'd0;
            end
          end

          OP_READ: begin
            if (phase_q != PH_SAVE_READY) begin rsp_v_q <= 1'b1; rsp_st_q <= ST_ERR_PHASE; end
            else if (sx_req_index >= 6'(IMAGE_WORDS)) begin rsp_v_q <= 1'b1; rsp_st_q <= ST_ERR_INDEX; end
            else if (sx_req_index == 6'd0) begin
              rsp_v_q <= 1'b1; rsp_is_read_q <= 1'b1; rsp_st_q <= ST_OK;
              rsp_d_q <= {16'h0000, chk_q, 8'h00, 8'(IMAGE_WORDS), SCHEMA_ID};
            end else begin
              xs_q <= X_SWEEP;
              sw_active_q <= 1'b1; sw_stage_q <= 1'b0; sw_mode_q <= SW_READ;
              sw_word_q <= sx_req_index[4:0]; sw_last_q <= sx_req_index[4:0]; sw_lane_q <= 3'd0;
              acc_q <= 64'h0; vfail_q <= 1'b0;
            end
          end

          OP_END: begin
            rsp_v_q <= 1'b1;
            if ((phase_q == PH_SAVE_DRAIN) | (phase_q == PH_SAVE_READY)) begin
              rsp_st_q <= ST_OK; phase_q <= PH_NORMAL;
            end else rsp_st_q <= ST_ERR_PHASE;
          end

          OP_RESTORE_BEGIN: begin
            rsp_v_q <= 1'b1;
            if (phase_q != PH_NORMAL)  rsp_st_q <= ST_ERR_PHASE;
            else if (~hold_cert)       rsp_st_q <= ST_ERR_HOLD;
            else begin
              rsp_st_q <= ST_OK;
              phase_q <= PH_STAGE; pres_q <= 31'h0;
              done_q <= 1'b0; res_q <= RES_NONE;
            end
          end

          OP_WRITE: begin
            if (phase_q != PH_STAGE) begin rsp_v_q <= 1'b1; rsp_st_q <= ST_ERR_PHASE; end
            else if (sx_req_index >= 6'(IMAGE_WORDS)) begin rsp_v_q <= 1'b1; rsp_st_q <= ST_ERR_INDEX; end
            else begin xs_q <= X_WRITE; wlane_q <= 3'd0; end
          end

          OP_COMMIT: begin
            if (phase_q != PH_STAGE) begin rsp_v_q <= 1'b1; rsp_st_q <= ST_ERR_PHASE; end
            else if (pres_q != {31{1'b1}}) begin rsp_v_q <= 1'b1; rsp_st_q <= ST_ERR_INCOMPLETE; end
            else begin
              xs_q <= X_SWEEP;
              sw_active_q <= 1'b1; sw_stage_q <= 1'b1; sw_mode_q <= SW_VALID;
              sw_word_q <= 5'd0; sw_last_q <= 5'd30; sw_lane_q <= 3'd0;
              vchk_q <= 16'h0; hchk_q <= 16'h0; vfail_q <= 1'b0; vcode_q <= ST_OK;
            end
          end

          OP_ABORT: begin
            rsp_v_q <= 1'b1;
            if ((phase_q == PH_STAGE) | (phase_q == PH_SAVE_DRAIN) | (phase_q == PH_SAVE_READY)) begin
              rsp_st_q <= ST_OK; phase_q <= PH_NORMAL;
            end else if (phase_q == PH_COMMIT) begin
              rsp_st_q <= ST_OK; phase_q <= PH_ERROR; err_q <= ST_ERR_ABORTED; res_q <= RES_FAILED;
              rp_kill <= 1'b1;
            end else rsp_st_q <= ST_ERR_PHASE;
          end

          OP_RECOVER: begin
            rsp_v_q <= 1'b1;
            if (phase_q == PH_ERROR) begin
              rsp_st_q <= ST_OK; phase_q <= PH_NORMAL;
              own_q <= 1'b0; mute_q <= 1'b0; err_q <= ST_OK; diag_q <= 8'h00;
            end else rsp_st_q <= ST_ERR_PHASE;
          end

          default: begin rsp_v_q <= 1'b1; rsp_st_q <= ST_ERR_OP; end
        endcase
      end
    end
  end

  // ------------------------------------------------------------ outputs
  assign sx_req_ready  = rdy_q;
  assign sx_rsp_valid  = rsp_v_q;
  assign sx_rsp_status = rsp_st_q;
  assign sx_rsp_data   = rsp_is_read_q ? rsp_d_q : status_word;
  assign img_rd_stage  = sw_stage_q;
  assign img_rd_word   = sw_word_q;
  assign img_rd_lane   = sw_lane_q;
  assign stg_word      = idx_q;
  assign stg_lane      = wlane_q;
  assign stg_byte      = data_q[8*wlane_q +: 8];
  assign sx_phase      = phase_q;
  assign sx_owned      = own_q;
  assign sx_muted      = mute_q;
  assign sx_error      = err_q;
  assign sx_diag       = diag_q;
endmodule

// IKAOPM with register-image save/restore; restore owns the chip pins and mutes output until done.

`timescale 1ns/1ps
module rzopm_top
  import rzopm_pkg::*;
#(
  parameter int CEN_SERVICE_MAX  = 64,
  parameter int RESET_HOST_EDGES = 256,
  parameter int RESET_CEN_EDGES  = 8,
  parameter int DRAIN_PHI1       = 36,
  parameter int STROBE_EDGES     = 4,
  parameter int WRITE_WAIT_PHI1  = 8,
  parameter int COMMIT_WAIT_PHI1 = 40,
  parameter int STEP_CEN_MAX     = 512,
  parameter int STUCK_PHI1       = 96,
  parameter int TIMER_LEAD_CEN   = 22716   // parent enables after timer start (0 = no lead)
)(
  input  logic        clk,
  input  logic        rst,
  // parent chip pins (chip polarity)
  input  logic        chip_cen_n,
  input  logic        chip_ic_n,
  input  logic        cpu_cs_n,
  input  logic        cpu_rd_n,
  input  logic        cpu_wr_n,
  input  logic        cpu_a0,
  input  logic [7:0]  cpu_din,
  output logic [7:0]  cpu_dout,
  output logic        cpu_dout_oe,
  output logic        chip_phi1,
  output logic        chip_ct1,
  output logic        chip_ct2,
  output logic        chip_irq_n,
  output logic        chip_sh1,
  output logic        chip_sh2,
  output logic        chip_so,
  output logic        snd_r_strobe,
  output logic        snd_l_strobe,
  output logic signed [15:0] snd_r,
  output logic signed [15:0] snd_l,
  output logic signed [15:0] snd_r_ex,
  output logic signed [15:0] snd_l_ex,
  // monitor observation
  output logic        mon_accept,
  output logic        mon_is_data,
  output logic [7:0]  mon_byte,
  output logic        mon_idle,
  // state transport
  input  logic        hold_cert,
  input  logic        sx_req_valid,
  output logic        sx_req_ready,
  input  logic [3:0]  sx_req_op,
  input  logic [5:0]  sx_req_index,
  input  logic [63:0] sx_req_data,
  output logic        sx_rsp_valid,
  input  logic        sx_rsp_ready,
  output logic [3:0]  sx_rsp_status,
  output logic [63:0] sx_rsp_data,
  output logic [2:0]  sx_phase,
  output logic        sx_owned,
  output logic        sx_muted,
  output logic [3:0]  sx_error,
  output logic [7:0]  sx_diag
);
  // ------------------------------------------------------------ pin ownership
  logic       own, mute;
  logic       rp_ic_n, rp_cs_n, rp_wr_n, rp_a0;
  logic [7:0] rp_din;

  wire        chip_cs_n_i = own ? rp_cs_n : cpu_cs_n;
  wire        chip_rd_n_i = own ? 1'b1    : cpu_rd_n;
  wire        chip_wr_n_i = own ? rp_wr_n : cpu_wr_n;
  wire        chip_a0_i   = own ? rp_a0   : cpu_a0;
  wire  [7:0] chip_din_i  = own ? rp_din  : cpu_din;
  wire        chip_ic_n_i = chip_ic_n & (own ? rp_ic_n : 1'b1);

  // ------------------------------------------------------------ OPM chip
  logic signed [15:0] c_r, c_l, c_r_ex, c_l_ex;

  IKAOPM #(
    .FULLY_SYNCHRONOUS (1),
    .FAST_RESET        (1),
    .USE_BRAM          (1)
  ) u_chip (
    .i_EMUCLK      (clk),
    .i_phiM_PCEN_n (chip_cen_n),
    .i_IC_n        (chip_ic_n_i),
    .o_phi1        (chip_phi1),
    .i_CS_n        (chip_cs_n_i),
    .i_RD_n        (chip_rd_n_i),
    .i_WR_n        (chip_wr_n_i),
    .i_A0          (chip_a0_i),
    .i_D           (chip_din_i),
    .o_D           (cpu_dout),
    .o_D_OE        (cpu_dout_oe),
    .o_CT2         (chip_ct2),
    .o_CT1         (chip_ct1),
    .o_IRQ_n       (chip_irq_n),
    .o_SH1         (chip_sh1),
    .o_SH2         (chip_sh2),
    .o_SO          (chip_so),
    .o_EMU_R_SAMPLE(snd_r_strobe),
    .o_EMU_R_EX    (c_r_ex),
    .o_EMU_R       (c_r),
    .o_EMU_L_SAMPLE(snd_l_strobe),
    .o_EMU_L_EX    (c_l_ex),
    .o_EMU_L       (c_l)
  );

  assign snd_r    = mute ? 16'sd0 : c_r;
  assign snd_l    = mute ? 16'sd0 : c_l;
  assign snd_r_ex = mute ? 16'sd0 : c_r_ex;
  assign snd_l_ex = mute ? 16'sd0 : c_l_ex;

  // ------------------------------------------------------------ mirrors
  logic cen, pcen, ncen, mrst_n;
  logic [4:0] slot;
  rzopm_cen_mirror u_cen (
    .clk(clk), .chip_cen_n(chip_cen_n), .chip_ic_n(chip_ic_n_i), .chip_phi1(chip_phi1),
    .cen(cen), .pcen(pcen), .ncen(ncen), .mrst_n(mrst_n), .slot(slot)
  );

  logic       accept, accept_is_data;
  logic [7:0] accept_byte;
  logic       lat_a, lat_d, s1_a, s1_d, in_flight, strobe, idle;
  logic       dg_overlap, dg_dropped, dg_reaccept;
  rzopm_bus_mirror u_bus (
    .clk(clk), .pcen(pcen), .ncen(ncen), .mrst_n(mrst_n),
    .chip_cs_n(chip_cs_n_i), .chip_wr_n(chip_wr_n_i), .chip_a0(chip_a0_i), .chip_din(chip_din_i),
    .accept(accept), .accept_is_data(accept_is_data), .accept_byte(accept_byte),
    .lat_a(lat_a), .lat_d(lat_d), .s1_a(s1_a), .s1_d(s1_d),
    .in_flight(in_flight), .strobe(strobe), .idle(idle),
    .dg_overlap(dg_overlap), .dg_dropped(dg_dropped), .dg_reaccept(dg_reaccept)
  );

  assign mon_accept  = accept;
  assign mon_is_data = accept_is_data;
  assign mon_byte    = accept_byte;
  assign mon_idle    = idle;

  // ------------------------------------------------------------ image store
  logic       ctl_rd_stage, stg_we, stg_lost, img_pending;
  logic [4:0] ctl_rd_word, rp_rd_word, stg_word;
  logic [2:0] ctl_rd_lane, rp_rd_lane, stg_lane;
  logic [7:0] rd_byte, stg_byte, selector;

  rzopm_image u_img (
    .clk(clk), .mrst_n(mrst_n), .ncen(ncen), .slot(slot),
    .accept(accept), .accept_is_data(accept_is_data), .accept_byte(accept_byte),
    .pending(img_pending),
    .rd_stage(own ? 1'b1 : ctl_rd_stage),
    .rd_word (own ? rp_rd_word : ctl_rd_word),
    .rd_lane (own ? rp_rd_lane : ctl_rd_lane),
    .rd_byte(rd_byte),
    .stg_we(stg_we), .stg_word(stg_word), .stg_lane(stg_lane), .stg_byte(stg_byte),
    .stg_lost(stg_lost), .selector(selector)
  );

  // ------------------------------------------------------------ replay
  logic rp_start, rp_kill, rp_busy, rp_done, rp_stuck;
  logic [7:0] rp_progress;
  rzopm_replay #(
    .RESET_HOST_EDGES(RESET_HOST_EDGES), .RESET_CEN_EDGES(RESET_CEN_EDGES),
    .DRAIN_PHI1(DRAIN_PHI1), .STROBE_EDGES(STROBE_EDGES), .WRITE_WAIT_PHI1(WRITE_WAIT_PHI1),
    .COMMIT_WAIT_PHI1(COMMIT_WAIT_PHI1), .STEP_CEN_MAX(STEP_CEN_MAX), .TIMER_LEAD_CEN(TIMER_LEAD_CEN)
  ) u_rp (
    .clk(clk), .rst(rst), .start(rp_start), .kill(rp_kill),
    .cen(cen), .ncen(ncen), .mrst_n(mrst_n),
    .lat_a(lat_a), .lat_d(lat_d), .s1_a(s1_a), .s1_d(s1_d),
    .acc_a(accept & ~accept_is_data), .acc_d(accept & accept_is_data),
    .img_pending(img_pending),
    .rd_word(rp_rd_word), .rd_lane(rp_rd_lane), .rd_byte(rd_byte),
    .ic_n(rp_ic_n), .cs_n(rp_cs_n), .wr_n(rp_wr_n), .a0(rp_a0), .din(rp_din),
    .busy(rp_busy), .done(rp_done), .stuck(rp_stuck), .progress(rp_progress)
  );

  // ------------------------------------------------------------ controller
  rzopm_ctl #(
    .CEN_SERVICE_MAX(CEN_SERVICE_MAX), .DRAIN_PHI1(DRAIN_PHI1), .STUCK_PHI1(STUCK_PHI1)
  ) u_ctl (
    .clk(clk), .rst(rst),
    .hold_cert(hold_cert), .parent_ic_n(chip_ic_n),
    .cpu_cs_n(cpu_cs_n), .cpu_rd_n(cpu_rd_n), .cpu_wr_n(cpu_wr_n),
    .sx_req_valid(sx_req_valid), .sx_req_ready(sx_req_ready), .sx_req_op(sx_req_op),
    .sx_req_index(sx_req_index), .sx_req_data(sx_req_data),
    .sx_rsp_valid(sx_rsp_valid), .sx_rsp_ready(sx_rsp_ready),
    .sx_rsp_status(sx_rsp_status), .sx_rsp_data(sx_rsp_data),
    .cen(cen), .ncen(ncen), .mrst_n(mrst_n), .mir_idle(idle), .img_pending(img_pending),
    .dg_overlap(dg_overlap), .dg_dropped(dg_dropped), .dg_reaccept(dg_reaccept),
    .img_rd_stage(ctl_rd_stage), .img_rd_word(ctl_rd_word), .img_rd_lane(ctl_rd_lane), .img_rd_byte(rd_byte),
    .stg_we(stg_we), .stg_word(stg_word), .stg_lane(stg_lane), .stg_byte(stg_byte),
    .rp_start(rp_start), .rp_kill(rp_kill), .rp_done(rp_done), .rp_stuck(rp_stuck), .rp_progress(rp_progress),
    .sx_phase(sx_phase), .sx_owned(own), .sx_muted(mute), .sx_error(sx_error), .sx_diag(sx_diag)
  );

  assign sx_owned = own;
  assign sx_muted = mute;

  /* verilator lint_off UNUSEDSIGNAL */
  wire unused_ok = &{1'b0, in_flight, strobe, stg_lost, selector, rp_busy};
  /* verilator lint_on UNUSEDSIGNAL */
endmodule

// OPM save-state owner: chunk SS_INDEX of 267 one-byte items, packed into the 31-word 0x5A31 image.
module rzopm_state_owner #(
    parameter [7:0] SS_INDEX = 8'd20,
    parameter integer TIMER_LEAD_CEN = 22716,
    parameter integer RESPONSE_TIMEOUT = 1024,      // request/response wait, SYS edges
    parameter integer DRAIN_TIMEOUT = 65536,        // save drain, SYS edges
    parameter integer REPLAY_TIMEOUT = 1048576,     // replay, SYS edges
    parameter integer RECOVER_IC_EDGES = 2048,      // >= 64 service CEs
    parameter integer RECOVER_SETTLE_EDGES = 1024
)(
    output raizing_socket_pkg::opm_in_t sk_opm_i,
    input raizing_socket_pkg::opm_out_t sk_opm_o,

    input clk,reset,
    input ym_ce,cpu_held,pcm_refill,
    input canonical_hold,cpu_canonical_ready,restore_commit,
    input cs_n,wr_n,a0,
    input [7:0] din,
    output [7:0] dout,
    output irq_n,sample,
    output signed [15:0] xleft,xright,
    output busy,fault,
    input [63:0] ss_data,
    input [31:0] ss_addr,
    input [7:0] ss_select,
    input ss_write,ss_read,ss_query,
    output reg [63:0] ss_data_out,
    output reg ss_ack
);
    import rzopm_pkg::*;
    localparam integer OPW=$clog2(REPLAY_TIMEOUT+DRAIN_TIMEOUT+2);
    localparam integer RCW=$clog2(RECOVER_IC_EDGES+RECOVER_SETTLE_EDGES+2);
    localparam integer RTW=$clog2(RESPONSE_TIMEOUT+2);
    /* verilator lint_off WIDTHTRUNC */
    localparam [RTW-1:0] RSP_LIMIT=RESPONSE_TIMEOUT;
    localparam [OPW-1:0] DRAIN_LIMIT=DRAIN_TIMEOUT,REPLAY_LIMIT=REPLAY_TIMEOUT;
    localparam [RCW-1:0] REC_IC_END=RECOVER_IC_EDGES,REC_END=RECOVER_IC_EDGES+RECOVER_SETTLE_EDGES,
        REC_RST_ON=8,REC_RST_OFF=24;
    /* verilator lint_on WIDTHTRUNC */

    // ---------------------------------------------------------- chip reset (stretched 256 edges) and CE
    reg stretch_q;
    reg [7:0] stretch_cnt;
    always_ff @(posedge clk) begin
        if(reset) begin stretch_q<=1'b1; stretch_cnt<=8'd0; end
        else if(stretch_q) begin
            stretch_cnt<=stretch_cnt+8'd1;
            if(&stretch_cnt) stretch_q<=1'b0;
        end
    end
    wire base_chip_reset=reset || stretch_q;
    reg svc_q,rec_ic_q,rec_rst_q;
    wire cen_d=ym_ce && (svc_q || (!cpu_held && !pcm_refill));   // svc_q clocks the chip during save drain, replay and recovery
    /* verilator lint_off PROCASSINIT */
    (* preserve *) reg cen_q=1'b0;   // inactive at power-up
    /* verilator lint_on PROCASSINIT */
    always_ff @(posedge clk) begin
        if(base_chip_reset) cen_q<=1'b0;
        else cen_q<=cen_d;
    end
    reg hold_q;
    always_ff @(posedge clk) hold_q<=cpu_held && cs_n && wr_n;

    // ---------------------------------------------------------- wrapper
    reg req_valid_q;
    reg [3:0] req_op_q;
    reg [5:0] req_idx_q;
    reg [63:0] req_data_q;
    wire req_ready,rsp_valid;
    wire [3:0] rsp_status;
    wire [63:0] rsp_data;
    wire [2:0] rsp_phase=rsp_data[2:0];
    // The shared rzopm_top instance connects through socket sk_opm.
    assign sk_opm_i.clk = clk;
    assign sk_opm_i.rst = reset || rec_rst_q;
    assign sk_opm_i.chip_cen_n = !cen_q;
    assign sk_opm_i.chip_ic_n = !(base_chip_reset || rec_ic_q);
    assign sk_opm_i.cpu_cs_n = cs_n;
    assign sk_opm_i.cpu_rd_n = cs_n | ~wr_n;
    assign sk_opm_i.cpu_wr_n = wr_n;
    assign sk_opm_i.cpu_a0 = a0;
    assign sk_opm_i.cpu_din = din;
    assign sk_opm_i.hold_cert = hold_q;
    assign sk_opm_i.sx_req_valid = req_valid_q;
    assign sk_opm_i.sx_req_op = req_op_q;
    assign sk_opm_i.sx_req_index = req_idx_q;
    assign sk_opm_i.sx_req_data = req_data_q;
    assign sk_opm_i.sx_rsp_ready = 1'b1;
    assign dout = sk_opm_o.cpu_dout;
    assign irq_n = sk_opm_o.chip_irq_n;
    assign sample = sk_opm_o.snd_l_strobe;
    assign xright = sk_opm_o.snd_r;
    assign xleft = sk_opm_o.snd_l;
    assign req_ready = sk_opm_o.sx_req_ready;
    assign rsp_valid = sk_opm_o.sx_rsp_valid;
    assign rsp_status = sk_opm_o.sx_rsp_status;
    assign rsp_data = sk_opm_o.sx_rsp_data;

    // ---------------------------------------------------------- item conversion
    // Words 1-28: high registers; word 29: eight low registers; word 30: selector, AMD, PMD, key nibbles (items 256-266).
    function automatic [8:0] item_of(input [4:0] w,input [3:0] j);
        if(w==5'd30) item_of=9'd256+{5'd0,j};
        else if(w==5'd29) begin
            case(j[2:0])
                3'd0: item_of=9'h001; 3'd1: item_of=9'h00f; 3'd2: item_of=9'h010; 3'd3: item_of=9'h011;
                3'd4: item_of=9'h012; 3'd5: item_of=9'h014; 3'd6: item_of=9'h018; default: item_of=9'h01b;
            endcase
        end else item_of={1'b0,w+5'd3,j[2:0]};
    endfunction
    // Selects the bits IKAOPM stores for each state item.
    function automatic [7:0] mask_of(input [8:0] item);
        if(item[8]) mask_of=item[3:0]==4'd0 ? 8'hff : item[3:0]<=4'd2 ? 8'h7f : 8'h0f;
        else if(item[7:5]==3'b001) begin
            case(item[4:3]) 2'd0: mask_of=8'hff; 2'd1: mask_of=8'h7f; 2'd2: mask_of=8'hfc; default: mask_of=8'h73; endcase
        end else if(item[7:5]==3'b010 || item[7:5]==3'b011) mask_of=8'h7f;
        else if(item[7:5]==3'b100 || item[7:5]==3'b110) mask_of=8'hdf;
        else if(item[7:5]==3'b101) mask_of=8'h9f;
        else if(item[7:5]==3'b111) mask_of=8'hff;
        else begin
            case(item[4:0])
                5'h01,5'h10,5'h12,5'h18: mask_of=8'hff;
                5'h0f: mask_of=8'h9f; 5'h11: mask_of=8'h03; 5'h14: mask_of=8'h8f; 5'h1b: mask_of=8'hc3;
                default: mask_of=8'h00;
            endcase
        end
    endfunction
    function automatic [7:0] byte_of(input [4:0] w,input [3:0] j,input [63:0] v);
        byte_of=v[8*j[2:0]+:8];
        if(w==5'd30) begin
            case(j)
                4'd0: byte_of=v[23:16]; 4'd1: byte_of=v[7:0]; 4'd2: byte_of=v[15:8];
                4'd3: byte_of={4'd0,v[35:32]}; 4'd4: byte_of={4'd0,v[39:36]}; 4'd5: byte_of={4'd0,v[43:40]};
                4'd6: byte_of={4'd0,v[47:44]}; 4'd7: byte_of={4'd0,v[51:48]}; 4'd8: byte_of={4'd0,v[55:52]};
                4'd9: byte_of={4'd0,v[59:56]}; 4'd10: byte_of={4'd0,v[63:60]}; default: byte_of=8'd0;
            endcase
        end
    endfunction
    function automatic [63:0] put(input [4:0] w,input [3:0] j,input [63:0] v,input [7:0] b);
        put=v;
        if(w==5'd30) begin
            case(j)
                4'd0: put[23:16]=b; 4'd1: put[7:0]=b; 4'd2: put[15:8]=b;
                4'd3: put[35:32]=b[3:0]; 4'd4: put[39:36]=b[3:0]; 4'd5: put[43:40]=b[3:0];
                4'd6: put[47:44]=b[3:0]; 4'd7: put[51:48]=b[3:0]; 4'd8: put[55:52]=b[3:0];
                4'd9: put[59:56]=b[3:0]; 4'd10: put[63:60]=b[3:0]; default: begin end
            endcase
        end else put[8*j[2:0]+:8]=b;
    endfunction
    function automatic [15:0] halves(input [15:0] s,input [63:0] v);
        halves=s+v[15:0]+v[31:16]+v[47:32]+v[63:48];
    endfunction

    // ---------------------------------------------------------- sequencer
    typedef enum logic [2:0] {Q_CLEAR,Q_IDLE,Q_REQ,Q_RSP,Q_SV_LOW,Q_SV_UNPACK,Q_RS_FETCH,Q_REC} q_t;
    typedef enum logic [3:0] {S_SAVE_BEGIN,S_SAVE_POLL,S_SAVE_READ,S_SAVE_END,S_RS_BEGIN,S_RS_WRITE,
        S_RS_COMMIT,S_RS_POLL,S_SOFT_STATUS,S_SOFT_FIX} s_t;
    q_t q;
    s_t step;
    reg [4:0] word;
    reg [3:0] item_j;
    reg [63:0] wbuf,hdr_q;
    reg [15:0] sum;
    reg [8:0] clr;
    reg [OPW-1:0] op_timer;
    reg [RTW-1:0] rsp_timer;
    reg [RCW-1:0] rec_cnt;
    reg [2:0] tries;
    reg captured_q,fault_q,pend_restore_q,pad_err_q;
    reg [7:0] fail_code_q;              // {step,status} of the first failure, debug only
    wire [3:0] n_items=word==5'd30 ? 4'd11 : 4'd8;
    wire [7:0] code_now={step,rsp_status},code_to={4'hf,step},code_phase={step,4'hd},code_step={step,4'hc};
    wire [5:0] cur_idx={1'b0,word},next_idx={1'b0,word+5'd1};
    wire [63:0] hdr_word={16'h0000,sum,8'h00,8'd31,16'h5a31};
    wire capture_due=canonical_hold && cpu_canonical_ready && !captured_q && !fault_q;
    // A fault keeps the sound CPU held and the output muted; a restore fault also resets the chip.
    assign busy=(q!=Q_IDLE && q!=Q_CLEAR) || fault_q || capture_due || pend_restore_q;
    assign fault=fault_q;

    // A state-bus item access waits for the sequencer to release the single-port RAM.
    (* ramstyle = "M10K" *) reg [7:0] items[0:511];
    reg [7:0] item_q;
    wire seq_ram=q==Q_CLEAR || q==Q_SV_LOW || q==Q_SV_UNPACK || q==Q_RS_FETCH;
    wire selected=ss_select==SS_INDEX;
    wire [8:0] ss_item=ss_addr>32'd266 ? 9'd266 : ss_addr[8:0];
    wire [7:0] ss_byte=ss_addr<32'd257 ? ss_data[7:0] : ss_addr<32'd259 ? {1'b0,ss_data[6:0]} : {4'd0,ss_data[3:0]};
    wire ss_store=selected && !ss_query && ss_write && ss_addr<=32'd266 && !seq_ram;
    wire [8:0] fetch_item=item_of(word,item_j);
    wire [8:0] last_item=item_of(word,item_j-4'd1);
    wire [63:0] packed_word=put(word,item_j-4'd1,wbuf,item_q & mask_of(last_item));
    wire [7:0] unpack_byte=byte_of(word,item_j,wbuf);
    reg [8:0] ram_addr;
    reg [7:0] ram_wdata;
    reg ram_we;
    always_comb begin
        ram_addr=ss_item; ram_wdata=ss_byte; ram_we=ss_store;
        case(q)
            Q_CLEAR: begin ram_addr=clr; ram_wdata=8'd0; ram_we=1'b1; end
            Q_SV_LOW: begin ram_addr={4'd0,clr[4:0]}; ram_wdata=8'd0; ram_we=1'b1; end
            Q_SV_UNPACK: begin ram_addr=fetch_item; ram_wdata=unpack_byte; ram_we=1'b1; end
            Q_RS_FETCH: begin ram_addr=fetch_item; ram_wdata=8'd0; ram_we=1'b0; end
            default: begin end
        endcase
    end
    always_ff @(posedge clk) begin
        if(ram_we) items[ram_addr]<=ram_wdata;
        item_q<=items[ram_addr];
    end

    reg rd_pending;
    always_ff @(posedge clk) begin
        ss_ack<=1'b0;
        if(reset) begin ss_data_out<=64'd0; rd_pending<=1'b0; end
        else begin
            if(!(selected && ss_read)) rd_pending<=1'b0;
            if(selected && ss_query) begin
                ss_data_out<={SS_INDEX,22'd0,2'd0,32'd267}; ss_ack<=1'b1;
            end else if(selected && ss_write) begin
                if(!seq_ram) ss_ack<=1'b1;
            end else if(selected && ss_read) begin
                if(rd_pending) begin ss_data_out<={56'd0,item_q}; ss_ack<=1'b1; end
                else if(!seq_ram) rd_pending<=1'b1;
            end
        end
    end

    // Request macros: ISSUE sends a request, HARD faults and resets the chip, SOFT recovers via status and retries.
    `define OWN_ISSUE(S,OP,IDX,DATA) begin step<=S; req_op_q<=OP; req_idx_q<=IDX; req_data_q<=DATA;         req_valid_q<=1'b1; rsp_timer<='0; q<=Q_REQ; end
    `define OWN_HARD(CODE) begin if(!fault_q) fail_code_q<=CODE; fault_q<=1'b1; captured_q<=1'b0;         req_valid_q<=1'b0; svc_q<=1'b1; rec_ic_q<=1'b1; rec_cnt<='0; q<=Q_REC; end
    `define OWN_SOFT(CODE) begin if(!fault_q) fail_code_q<=CODE; svc_q<=1'b0; tries<=tries+3'd1;         if(tries==3'd4) `OWN_HARD(CODE) else `OWN_ISSUE(S_SOFT_STATUS,OP_STATUS,6'd0,64'd0) end

    always_ff @(posedge clk) begin
        if(reset) begin
            q<=Q_CLEAR; step<=S_SAVE_BEGIN; clr<=9'd0; word<=5'd0; item_j<=4'd0;
            wbuf<=64'd0; hdr_q<=64'd0; sum<=16'd0; op_timer<='0; rsp_timer<='0; rec_cnt<='0; tries<=3'd0;
            captured_q<=1'b0; fault_q<=1'b0; pend_restore_q<=1'b0; pad_err_q<=1'b0; fail_code_q<=8'd0;
            req_valid_q<=1'b0; req_op_q<=OP_STATUS; req_idx_q<=6'd0; req_data_q<=64'd0;
            svc_q<=1'b0; rec_ic_q<=1'b0; rec_rst_q<=1'b0;
        end else begin
            if(!canonical_hold) captured_q<=1'b0;
            if(restore_commit && q!=Q_IDLE) pend_restore_q<=1'b1;
            if(op_timer!={OPW{1'b1}}) op_timer<=op_timer+1'b1;
            case(q)
                Q_CLEAR: begin
                    clr<=clr+9'd1;
                    if(&clr) q<=Q_IDLE;
                end
                Q_IDLE: begin
                    if(fault_q && !canonical_hold && !restore_commit && !pend_restore_q) fault_q<=1'b0;
                    if(restore_commit || pend_restore_q) begin
                        // A restore always starts from a chip reset inside the replay.
                        pend_restore_q<=1'b0; captured_q<=1'b0; fault_q<=1'b0; tries<=3'd0; sum<=16'd0;
                        `OWN_ISSUE(S_RS_BEGIN,OP_RESTORE_BEGIN,6'd0,64'd0)
                    end else if(capture_due && hold_q) begin
                        svc_q<=1'b1; op_timer<='0; tries<=3'd0; sum<=16'd0; pad_err_q<=1'b0;
                        `OWN_ISSUE(S_SAVE_BEGIN,OP_SAVE_BEGIN,6'd0,64'd0)
                    end
                end
                Q_REQ: begin
                    rsp_timer<=rsp_timer+1'b1;
                    if(req_ready) begin req_valid_q<=1'b0; rsp_timer<='0; q<=Q_RSP; end
                    else if(rsp_timer==RSP_LIMIT) `OWN_HARD(code_to)
                end
                Q_RSP: begin
                    rsp_timer<=rsp_timer+1'b1;
                    if(rsp_valid) begin
                        case(step)
                            S_SAVE_BEGIN:
                                if(rsp_status==ST_OK) `OWN_ISSUE(S_SAVE_POLL,OP_STATUS,6'd0,64'd0)
                                else `OWN_SOFT(code_now)
                            S_SAVE_POLL:
                                if(rsp_status==ST_OK && rsp_phase==PH_SAVE_READY) begin
                                    svc_q<=1'b0; clr<=9'd0; q<=Q_SV_LOW;
                                end else if(rsp_status==ST_OK && rsp_phase==PH_SAVE_DRAIN &&
                                    op_timer<DRAIN_LIMIT) `OWN_ISSUE(S_SAVE_POLL,OP_STATUS,6'd0,64'd0)
                                else `OWN_SOFT(code_now)
                            S_SAVE_READ:
                                if(rsp_status!=ST_OK) `OWN_SOFT(code_now)
                                else if(word==5'd0) begin
                                    hdr_q<=rsp_data; word<=5'd1; `OWN_ISSUE(S_SAVE_READ,OP_READ,6'd1,64'd0)
                                end else begin
                                    wbuf<=rsp_data; sum<=halves(sum,rsp_data); item_j<=4'd0;
                                    if(word==5'd30 && rsp_data[31:24]!=8'd0) pad_err_q<=1'b1;
                                    q<=Q_SV_UNPACK;
                                end
                            S_SAVE_END:
                                if(rsp_status!=ST_OK) `OWN_SOFT(code_now)
                                else begin
                                    if(hdr_q=={16'h0000,sum,8'h00,8'd31,16'h5a31} && !pad_err_q) captured_q<=1'b1;
                                    else begin fault_q<=1'b1; fail_code_q<={step,4'he}; end
                                    q<=Q_IDLE;
                                end
                            S_RS_BEGIN:
                                if(rsp_status==ST_OK) begin word<=5'd1; item_j<=4'd0; wbuf<=64'd0; q<=Q_RS_FETCH; end
                                else `OWN_HARD(code_now)
                            S_RS_WRITE:
                                if(rsp_status!=ST_OK) `OWN_HARD(code_now)
                                else if(word==5'd0) begin
                                    svc_q<=1'b1; op_timer<='0; `OWN_ISSUE(S_RS_COMMIT,OP_COMMIT,6'd0,64'd0)
                                end else if(word==5'd30) begin
                                    word<=5'd0; `OWN_ISSUE(S_RS_WRITE,OP_WRITE,6'd0,hdr_word)
                                end else begin
                                    word<=word+5'd1; item_j<=4'd0; wbuf<=64'd0; q<=Q_RS_FETCH;
                                end
                            S_RS_COMMIT:
                                if(rsp_status==ST_OK) `OWN_ISSUE(S_RS_POLL,OP_STATUS,6'd0,64'd0)
                                else `OWN_HARD(code_now)
                            S_RS_POLL:
                                if(rsp_status==ST_OK && rsp_phase==PH_NORMAL && rsp_data[7]) begin
                                    svc_q<=1'b0; q<=Q_IDLE;
                                end else if(rsp_status==ST_OK && rsp_phase==PH_COMMIT &&
                                    op_timer<REPLAY_LIMIT) `OWN_ISSUE(S_RS_POLL,OP_STATUS,6'd0,64'd0)
                                else `OWN_HARD(code_now)
                            S_SOFT_STATUS:
                                if(rsp_status!=ST_OK) `OWN_HARD(code_now)
                                else if(rsp_phase==PH_NORMAL) begin fault_q<=1'b1; q<=Q_IDLE; end
                                else if(rsp_phase==PH_ERROR) `OWN_ISSUE(S_SOFT_FIX,OP_RECOVER,6'd0,64'd0)
                                else if(rsp_phase==PH_SAVE_DRAIN || rsp_phase==PH_SAVE_READY || rsp_phase==PH_STAGE)
                                    `OWN_ISSUE(S_SOFT_FIX,OP_ABORT,6'd0,64'd0)
                                else `OWN_HARD(code_phase)
                            S_SOFT_FIX: `OWN_SOFT(fail_code_q)
                            default: `OWN_HARD(code_step)
                        endcase
                    end else if(rsp_timer==RSP_LIMIT) `OWN_HARD(code_to)
                end
                Q_SV_LOW: begin
                    clr<=clr+9'd1;
                    if(clr[4:0]==5'd31) begin word<=5'd0; `OWN_ISSUE(S_SAVE_READ,OP_READ,6'd0,64'd0) end
                end
                Q_SV_UNPACK: begin
                    if((unpack_byte & ~mask_of(fetch_item))!=8'd0) pad_err_q<=1'b1;
                    item_j<=item_j+4'd1;
                    if(item_j==n_items-4'd1) begin
                        if(word==5'd30) `OWN_ISSUE(S_SAVE_END,OP_END,6'd0,64'd0)
                        else begin word<=word+5'd1; `OWN_ISSUE(S_SAVE_READ,OP_READ,next_idx,64'd0) end
                    end
                end
                Q_RS_FETCH: begin
                    // item_j addresses item j; item_q returns item j-1 one edge later
                    item_j<=item_j+4'd1;
                    if(item_j!=4'd0) wbuf<=packed_word;
                    if(item_j==n_items) begin
                        sum<=halves(sum,packed_word);
                        `OWN_ISSUE(S_RS_WRITE,OP_WRITE,cur_idx,packed_word)
                    end
                end
                Q_REC: begin
                    rec_cnt<=rec_cnt+1'b1;
                    rec_rst_q<=rec_cnt>=REC_RST_ON && rec_cnt<REC_RST_OFF;
                    if(rec_cnt==REC_IC_END) rec_ic_q<=1'b0;
                    if(rec_cnt==REC_END) begin svc_q<=1'b0; q<=Q_IDLE; end
                end
                default: q<=Q_IDLE;
            endcase
        end
    end
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused_ok=&{1'b0,ss_data[63:8]};
    /* verilator lint_on UNUSEDSIGNAL */
    `undef OWN_ISSUE
    `undef OWN_HARD
    `undef OWN_SOFT
endmodule

// The raizing_z80 module below is distributed under BSD-3-Clause.
// T80 wrapper: T80s-style bus strobes, canonical-boundary hold, register-image restore via REG/DIR.
module raizing_z80 #(
    parameter integer CANONICAL_TIMEOUT_CYCLES=8100000,
    parameter integer RESTORE_TIMEOUT_CYCLES=16384
) (
    input clk,reset,cen,wait_n,int_n,hold_request,
    input tri1 nmi_n,busrq_n,
    output busak_n,
    input canonical_hold,
    output held,held_base,stop_ready,canonical_ready,canonical_service,restore_busy,
    output reg canonical_fault,
    input restore,
    input [255:0] restore_state,
    output [255:0] capture_state,
    output reg restore_done,
    output [15:0] address,
    input [7:0] data_in,
    output [7:0] data_out,
    output reg rd_n,wr_n,mreq_n,iorq_n,
    output m1_n,halt_n
);
    localparam [2:0] RUN=0, RESET_CORE=1, PRIME_REGISTERS=2, INJECT_JP=3,
        FINAL_REGISTERS=4, RESTORE_FINISH=5, RESTORE_FAILED=6;
    localparam integer CW=$clog2(CANONICAL_TIMEOUT_CYCLES+1);
    localparam integer RW=$clog2(RESTORE_TIMEOUT_CYCLES+1);
    wire [211:0] registers;
    wire [2:0] mc,ts;
    wire no_read,write_cycle,io_cycle,int_cycle_n;
    wire [15:0] core_address;
    wire [7:0] core_data_out;
    wire core_m1_n,core_halt_n,core_busak_n;
    reg [1:0] nmi_rearmed;
    reg [7:0] read_data;
    reg hold_latched,canonical_latched,reset_nmi_rearm;
    reg [1:0] prefix;
    reg jp_pending;
    reg [1:0] jp_operands;
    reg [15:0] jp_target;
    reg jr_pending,jr_unconditional,jr_operand,jr_stop_eligible;
    reg [15:0] jr_sequential,jr_target;
    reg [2:0] restore_phase;
    reg [255:0] restore_image;
    reg [1:0] private_progress;
    reg [CW-1:0] canonical_timer;
    reg [RW-1:0] restore_timer;
    reg pending_ei;
    wire private_bus=restore_phase!=RUN;
    assign restore_busy=private_bus;
    wire core_reset=reset || restore_phase==RESET_CORE;
    wire register_restore=restore_phase==PRIME_REGISTERS || restore_phase==FINAL_REGISTERS;
    wire boundary_pre=mc==1 && ts==2 && int_cycle_n && (prefix==0 || prefix==3);
    wire boundary=boundary_pre && wait_n;
    wire absolute_complete=jp_pending && jp_operands==2 && core_address==jp_target && registers[79:64]==jp_target;
    // Operand capture qualifies the JR; the PC match confirms the branch was taken.
    wire relative_complete=jr_pending && jr_stop_eligible &&
        core_address==jr_target && registers[79:64]==jr_target;
    wire canonical_terms=core_halt_n && nmi_n && nmi_rearmed==3 &&
        busrq_n && core_busak_n && (absolute_complete || relative_complete);
    wire canonical_boundary=boundary && canonical_terms;
    wire acquire=canonical_hold && !canonical_latched && !canonical_fault && restore_phase==RUN;
    wire ordinary_stop=hold_request && !acquire;
    wire stop_now=(ordinary_stop && boundary) || (acquire && canonical_boundary);
    wire private_complete=restore_phase==INJECT_JP && private_progress==3 &&
        mc==1 && ts==2 && int_cycle_n && core_address==restore_image[79:64];
    wire cpu_cen=cen && ((restore_phase==RUN && !(hold_latched && !acquire) && !stop_now) ||
        (restore_phase==INJECT_JP && !private_complete));
    wire [7:0] private_data=core_address==16'd1 ? restore_image[71:64] :
        core_address==16'd2 ? restore_image[79:72] : 8'hc3;
    wire [7:0] bus_data=private_bus ? private_data : data_in;
    wire [211:0] architectural_state=
        {registers[211:210] | {2{pending_ei && boundary}},registers[209:0]};
    wire valid_image=restore_state[255:214]==0 && restore_state[213] && !restore_state[212];
    reg [211:0] register_image;
    always @* begin
        register_image=restore_image[211:0];
        if(restore_phase==PRIME_REGISTERS) register_image[79:64]=0;
    end
    assign canonical_ready=canonical_hold && canonical_latched && hold_latched &&
        restore_phase==RUN && !canonical_fault;
    assign canonical_service=acquire && restore_phase==RUN;
    assign held=(hold_latched && !acquire) || (stop_now && restore_phase==RUN);
    // held split around wait_n; boards rebuild held from their own wait_n.
    assign held_base=hold_latched && !acquire;
    assign stop_ready=restore_phase==RUN && boundary_pre && (ordinary_stop || (acquire && canonical_terms));
`ifdef SIMULATION
    always @(posedge clk)
        if(held !== (held_base || (wait_n && stop_ready))) $fatal(1, "Z80_HELD_SPLIT_MISMATCH");
`endif
    // Bit 213 is a required canonical-image marker; bit 212 remains HALT status.
    assign capture_state={42'd0,canonical_ready,!core_halt_n,architectural_state};
    assign address=private_bus ? restore_image[79:64] : core_address;
    assign data_out=private_bus ? 8'd0 : core_data_out;
    assign m1_n=private_bus ? 1'b1 : core_m1_n;
    assign halt_n=private_bus ? 1'b1 : core_halt_n;
    assign busak_n=private_bus ? 1'b1 : core_busak_n;

    T80 #(.Mode(0),.IOWait(1)) chip (
        .RESET_n(!core_reset),.CLK_n(clk),.CEN(cpu_cen),.WAIT_n(private_bus ? 1'b1 : wait_n),
        .INT_n(private_bus ? 1'b1 : int_n),.NMI_n(private_bus || reset_nmi_rearm ? 1'b1 : nmi_n),
        .BUSRQ_n(private_bus ? 1'b1 : busrq_n),.M1_n(core_m1_n),
        .IORQ(io_cycle),.NoRead(no_read),.Write(write_cycle),.RFSH_n(),.HALT_n(core_halt_n),
        .BUSAK_n(core_busak_n),.A(core_address),.DInst(private_bus ? 8'hc3 : data_in),.DI(read_data),
        .DO(core_data_out),.MC(mc),.TS(ts),.IntCycle_n(int_cycle_n),.IntE(),.Stop(),
        .R800_mode(1'b0),.out0(1'b0),.REG(registers),.DIRSet(register_restore),.DIR(register_image)
    );

    always @(posedge clk) begin
        if(core_reset || !nmi_n) nmi_rearmed<=0;
        else if(cen && nmi_rearmed!=3) nmi_rearmed<=nmi_rearmed+1'b1;
    end
    always @(posedge clk) begin
        restore_done<=0;
        // T80 keeps NMI edge history across reset; hold NMI high one edge after reset.
        reset_nmi_rearm<=reset;
        if(reset) begin
            restore_phase<=RUN; hold_latched<=0; canonical_latched<=0;
            canonical_fault<=0; canonical_timer<=0; restore_timer<=0;
            prefix<=0; pending_ei<=0; jp_pending<=0; jp_operands<=0; jp_target<=0;
            jr_pending<=0; jr_unconditional<=0; jr_operand<=0; jr_stop_eligible<=0; jr_sequential<=0; jr_target<=0;
            restore_image<=0; private_progress<=0;
        end else begin
            if(!canonical_hold && restore_phase==RUN) begin
                canonical_latched<=0; canonical_timer<=0; canonical_fault<=0;
            end
            if(restore && restore_phase==RUN) begin
                if(canonical_ready && valid_image) begin
                    restore_image<=restore_state; restore_phase<=RESET_CORE;
                    hold_latched<=1; canonical_latched<=0; restore_timer<=0;
                    prefix<=0; pending_ei<=0; jp_pending<=0; jp_operands<=0; private_progress<=0;
                    jr_pending<=0; jr_operand<=0; jr_stop_eligible<=0;
                end else canonical_fault<=1;
            end else if(restore_phase!=RUN) begin
                if(restore_phase!=RESTORE_FAILED && restore_timer>=RESTORE_TIMEOUT_CYCLES-1) begin
                    canonical_fault<=1; restore_phase<=RESTORE_FAILED;
                end else begin
                    restore_timer<=restore_timer+1'b1;
                    case(restore_phase)
                        RESET_CORE: restore_phase<=PRIME_REGISTERS;
                        PRIME_REGISTERS: restore_phase<=INJECT_JP;
                        INJECT_JP: begin
                            if(private_complete) restore_phase<=FINAL_REGISTERS;
                            else if(cpu_cen && ts==2) begin
                                if(mc==1 && private_progress==0) private_progress<=1;
                                if(mc==2 && private_progress==1) private_progress<=2;
                                if(mc==3 && private_progress==2) private_progress<=3;
                            end
                        end
                        FINAL_REGISTERS: restore_phase<=RESTORE_FINISH;
                        RESTORE_FINISH: begin
                            restore_phase<=RUN; restore_done<=1; canonical_latched<=1;
                            jp_pending<=1; jp_operands<=2; jp_target<=restore_image[79:64];
                        end
                        default: begin end
                    endcase
                end
            end else begin
                if(acquire) begin
                    if(canonical_boundary) begin hold_latched<=1; canonical_latched<=1; end
                    else begin
                        hold_latched<=0;
                        if(canonical_timer>=CANONICAL_TIMEOUT_CYCLES-1) canonical_fault<=1;
                        else canonical_timer<=canonical_timer+1'b1;
                    end
                end else if(!hold_request && !canonical_latched) hold_latched<=0;
                else if(boundary) hold_latched<=1;
                if(cpu_cen) begin
                    // Any interrupt acknowledgement invalidates the preceding JP.
                    if(!int_cycle_n) begin jp_pending<=0; jp_operands<=0; jr_pending<=0; jr_operand<=0; jr_stop_eligible<=0; end
                    if(mc==1 && ts==2 && wait_n && int_cycle_n) begin
                        pending_ei<=core_halt_n && prefix!=2 && data_in==8'hfb;
                        jp_pending<=core_halt_n && prefix!=2 && data_in==8'hc3;
                        jp_operands<=0;
                        jr_pending<=core_halt_n && prefix!=2 &&
                            (data_in==8'h18 || data_in==8'h20 || data_in==8'h28 || data_in==8'h30 || data_in==8'h38);
                        jr_unconditional<=data_in==8'h18;
                        jr_operand<=0; jr_stop_eligible<=0; jr_sequential<=core_address+16'd2;
                        if(prefix==2) prefix<=0;
                        else if(data_in==8'hdd || data_in==8'hfd) prefix<=1;
                        else if(data_in==8'hed) prefix<=2;
                        else if(data_in==8'hcb) prefix<=prefix==1 ? 2'd3 : 2'd2;
                        else prefix<=0;
                    end else if(jp_pending && ts==2 && wait_n) begin
                        if(mc==2 && jp_operands==0) begin jp_target[7:0]<=data_in; jp_operands<=1; end
                        if(mc==3 && jp_operands==1) begin jp_target[15:8]<=data_in; jp_operands<=2; end
                    end else if(jr_pending && mc==2 && ts==2 && wait_n && !jr_operand) begin
                        jr_target<=jr_sequential+{{8{data_in[7]}},data_in}; jr_operand<=1; jr_stop_eligible<=jr_unconditional || (|data_in);
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if(!reset && restore_phase==RESTORE_FINISH) begin
            // Re-present the saved-PC fetch as private service ends; WAIT owns its completion.
            rd_n<=0; wr_n<=1; mreq_n<=0; iorq_n<=1;
        end else if(core_reset || private_bus || !core_busak_n || (restore && canonical_ready && valid_image)) begin
            rd_n<=1; wr_n<=1; mreq_n<=1; iorq_n<=1;
            if(core_reset) read_data<=0;
            else if(cpu_cen && ts==2) read_data<=bus_data;
        end else if(cpu_cen) begin
            rd_n<=1; wr_n<=1; mreq_n<=1; iorq_n<=1;
            if(mc==1) begin
                if(ts==1 || (ts==2 && !wait_n)) begin
                    rd_n<=!int_cycle_n; mreq_n<=!int_cycle_n; iorq_n<=int_cycle_n;
                end
                if(ts==3) mreq_n<=0;
            end else if(ts==1 || (ts==2 && !wait_n)) begin
                if(!no_read && !write_cycle) rd_n<=0;
                if(write_cycle) wr_n<=0;
                if((!no_read && !write_cycle) || write_cycle) begin
                    iorq_n<=!io_cycle; mreq_n<=io_cycle;
                end
            end
            if(ts==2 && wait_n) read_data<=data_in;
        end
    end
endmodule
