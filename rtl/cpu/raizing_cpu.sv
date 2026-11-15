// SPDX-License-Identifier: GPL-3.0-or-later
// 68000 CPU context engine, IRQ owner and bus-phase scheduler.

// Context-engine commands, responses, phases, events and saved 68000 word layout.
`timescale 1ns/1ps
package rzctx_pkg;
  // ---- commands (cmd_op) ----
  localparam logic [2:0] OP_CAPTURE = 3'd1;  // park the CPU at its next instruction boundary
  localparam logic [2:0] OP_RESUME  = 3'd2;  // return a parked CPU to the captured context
  localparam logic [2:0] OP_RESTORE = 3'd3;  // run the admitted restore context
  localparam logic [2:0] OP_CANCEL  = 3'd4;  // abandon the current operation (per-phase rule)
  localparam logic [2:0] OP_LOAD    = 3'd5;  // start a new restore context (clears its field map)
  localparam logic [2:0] OP_ADMIT   = 3'd6;  // validate the restore context
  localparam logic [2:0] OP_HOLD    = 3'd7;  // hold the CPU in private reset (before a RAM restore)

  // ---- command responses (rsp_code) ----
  localparam logic [3:0] R_OK           = 4'd0;
  localparam logic [3:0] R_BUSY         = 4'd1;   // not allowed in this phase
  localparam logic [3:0] R_CFG          = 4'd2;   // work-RAM bounds invalid
  localparam logic [3:0] R_HALTED       = 4'd3;   // CPU reports HALTED
  localparam logic [3:0] R_NOT_ADMITTED = 4'd4;
  localparam logic [3:0] R_INCOMPLETE   = 4'd5;   // a context word was never written
  localparam logic [3:0] R_FORMAT       = 4'd6;
  localparam logic [3:0] R_SR           = 4'd7;   // trace bit or reserved SR bit set
  localparam logic [3:0] R_PC           = 4'd8;   // odd PC or PC[31:24] != 0
  localparam logic [3:0] R_SSP_ODD      = 4'd9;
  localparam logic [3:0] R_SSP_RANGE    = 4'd10;  // frame SSP-6..SSP-1 (24-bit) not inside work RAM
  localparam logic [3:0] R_USP_ODD      = 4'd11;  // user-mode return with an odd USP
  localparam logic [3:0] R_BAD_OP       = 4'd12;

  // ---- events (evt_code) ----
  localparam logic [3:0] EV_PARKED       = 4'd1;   // capture ready: context stable, CPU parked
  localparam logic [3:0] EV_RESUMED      = 4'd2;   // save-resume retired in game code
  localparam logic [3:0] EV_RESTORED     = 4'd3;   // restore retired in game code
  localparam logic [3:0] EV_CANCELLED    = 4'd4;   // cancelled; CPU back in game code or untouched
  localparam logic [3:0] EV_HELD         = 4'd5;   // CPU held in private reset (hold, or cancelled restore)
  localparam logic [3:0] EV_RELEASED     = 4'd6;   // hold released: CPU does an ordinary reset
  localparam logic [3:0] EV_ABORTED      = 4'd7;   // stale level-7 IACK serviced by an immediate return
  localparam logic [3:0] EV_F_IACK_TO    = 4'd8;   // no level-7 IACK in time; request withdrawn
  localparam logic [3:0] EV_F_FRAME      = 4'd9;   // frame not as expected; returned without capture
  localparam logic [3:0] EV_F_RUN_TO     = 4'd10;  // private execution overran; CPU held
  localparam logic [3:0] EV_F_INCOMPLETE = 4'd11;  // context incomplete at park; CPU held
  localparam logic [3:0] EV_F_RET_TO     = 4'd12;  // no program fetch after the return
  localparam logic [3:0] EV_F_RETURN     = 4'd13;  // first program fetch had the wrong PC or FC
  localparam logic [3:0] EV_F_IDLE_TO    = 4'd14;  // restore found no idle bus; nothing done
  localparam logic [3:0] EV_F_STACK      = 4'd15;  // frame outside work RAM; returned without capture

  // ---- phases (st_phase) ----
  localparam logic [3:0] PH_IDLE  = 4'd0;
  localparam logic [3:0] PH_REQ   = 4'd1;   // level 7 requested; game cycles pass through
  localparam logic [3:0] PH_EXC   = 4'd2;   // level-7 IACK claimed: frame and vector
  localparam logic [3:0] PH_RUN   = 4'd3;   // private capture code
  localparam logic [3:0] PH_PARK  = 4'd4;   // CPU parked on a held private read; parent owns state
  localparam logic [3:0] PH_TAIL  = 4'd5;   // private return code (resume, restore, cancel, abort)
  localparam logic [3:0] PH_RET   = 4'd6;   // released; waiting for the first game fetch
  localparam logic [3:0] PH_RWAIT = 4'd7;   // restore: waiting for no open board transfer
  localparam logic [3:0] PH_RHOLD = 4'd8;   // restore: private reset asserted
  localparam logic [3:0] PH_RVEC  = 4'd9;   // restore: private reset vectors
  localparam logic [3:0] PH_HELD  = 4'd10;  // CPU held in private reset

  // ---- modes (st_mode) ----
  localparam logic [2:0] M_NONE    = 3'd0;
  localparam logic [2:0] M_CAPTURE = 3'd1;
  localparam logic [2:0] M_ABORT   = 3'd2;
  localparam logic [2:0] M_RESUME  = 3'd3;
  localparam logic [2:0] M_CANCEL  = 3'd4;
  localparam logic [2:0] M_RESTORE = 3'd5;
  localparam logic [2:0] M_HOLD    = 3'd6;

  // Saved context word layout (16-bit words).
  localparam logic [15:0] FORMAT_ID = 16'h6801;
  localparam int          CTX_WORDS = 38;
  localparam int          W_FMT = 0;    // format id
  localparam int          W_D0  = 1;    // D0..D7: words 1..16, high word first
  localparam int          W_A0  = 17;   // A0..A6: words 17..30
  localparam int          W_USP = 31;   // 31..32
  localparam int          W_SSP = 33;   // 33..34 architectural SSP
  localparam int          W_SR  = 35;
  localparam int          W_PC  = 36;   // 36..37
  // Restore rejects SR bits 15, 14, 12, 11, 7, 6 and 5 when set.
  localparam logic [15:0] SR_MUST_BE_ZERO = 16'hD8E0;
endpackage

`timescale 1ns/1ps
package rzctx_slot_pkg;
    typedef struct packed {
        logic cmd_valid;
        logic [2:0] cmd_op;
        logic ctx_req, ctx_we;
        logic [5:0] ctx_idx;
        logic [15:0] ctx_data;
    } request_t;

    typedef struct packed {
        logic rsp_valid, rsp_ok;
        logic [3:0] rsp_code;
        logic ctx_ack, ctx_nak;
        logic [15:0] ctx_data;
        logic admitted, captured;
    } response_t;
endpackage

// Context-engine firmware ROM (generated).
`timescale 1ns/1ps
package rzctx_fw_pkg;
  localparam logic [23:0] PRIV_BASE     = 24'h000100;
  localparam logic [23:0] PORT_BASE     = 24'h000180;
  localparam logic [23:0] PARK_ADDR     = 24'h0001FE;
  localparam logic [23:0] CAPTURE_ENTRY = 24'h000100;
  localparam logic [23:0] RESTORE_ENTRY = 24'h000120;
  localparam logic [23:0] ABORT_ENTRY   = 24'h00013A;
  localparam int          FW_WORDS      = 64;
  // word i of the code window PRIV_BASE + 2i; unused words read as NOP
  function automatic logic [15:0] fw_word(input logic [5:0] i);
    case (i)
      6'd0: fw_word = 16'h48F9;
      6'd1: fw_word = 16'h7FFF;
      6'd2: fw_word = 16'h0000;
      6'd3: fw_word = 16'h0182;
      6'd4: fw_word = 16'h4E68;
      6'd5: fw_word = 16'h23C8;
      6'd6: fw_word = 16'h0000;
      6'd7: fw_word = 16'h01BE;
      6'd8: fw_word = 16'h204F;
      6'd9: fw_word = 16'h5C88;
      6'd10: fw_word = 16'h23C8;
      6'd11: fw_word = 16'h0000;
      6'd12: fw_word = 16'h01C2;
      6'd13: fw_word = 16'h3039;
      6'd14: fw_word = 16'h0000;
      6'd15: fw_word = 16'h01FE;
      6'd16: fw_word = 16'h2079;
      6'd17: fw_word = 16'h0000;
      6'd18: fw_word = 16'h01BE;
      6'd19: fw_word = 16'h4E60;
      6'd20: fw_word = 16'h2E79;
      6'd21: fw_word = 16'h0000;
      6'd22: fw_word = 16'h01C2;
      6'd23: fw_word = 16'h5D8F;
      6'd24: fw_word = 16'h4CF9;
      6'd25: fw_word = 16'h7FFF;
      6'd26: fw_word = 16'h0000;
      6'd27: fw_word = 16'h0182;
      6'd28: fw_word = 16'h4E73;
      6'd29: fw_word = 16'h4E73;
      6'd30: fw_word = 16'h4E71;
      6'd31: fw_word = 16'h4E71;
      6'd32: fw_word = 16'h4E71;
      6'd33: fw_word = 16'h4E71;
      6'd34: fw_word = 16'h4E71;
      6'd35: fw_word = 16'h4E71;
      6'd36: fw_word = 16'h4E71;
      6'd37: fw_word = 16'h4E71;
      6'd38: fw_word = 16'h4E71;
      6'd39: fw_word = 16'h4E71;
      6'd40: fw_word = 16'h4E71;
      6'd41: fw_word = 16'h4E71;
      6'd42: fw_word = 16'h4E71;
      6'd43: fw_word = 16'h4E71;
      6'd44: fw_word = 16'h4E71;
      6'd45: fw_word = 16'h4E71;
      6'd46: fw_word = 16'h4E71;
      6'd47: fw_word = 16'h4E71;
      6'd48: fw_word = 16'h4E71;
      6'd49: fw_word = 16'h4E71;
      6'd50: fw_word = 16'h4E71;
      6'd51: fw_word = 16'h4E71;
      6'd52: fw_word = 16'h4E71;
      6'd53: fw_word = 16'h4E71;
      6'd54: fw_word = 16'h4E71;
      6'd55: fw_word = 16'h4E71;
      6'd56: fw_word = 16'h4E71;
      6'd57: fw_word = 16'h4E71;
      6'd58: fw_word = 16'h4E71;
      6'd59: fw_word = 16'h4E71;
      6'd60: fw_word = 16'h4E71;
      6'd61: fw_word = 16'h4E71;
      6'd62: fw_word = 16'h4E71;
      6'd63: fw_word = 16'h4E71;
      default: fw_word = 16'h4E71;
    endcase
  endfunction
endpackage

// Saves and restores 68000 context through a private level-7 exception running internal firmware.
`timescale 1ns/1ps
module rzctx_core #(
  parameter int unsigned WD_IACK   = 4096,  // CPU clocks from request to the level-7 IACK
  parameter int unsigned WD_RUN    = 8192,  // CPU clocks allowed for one private segment
  parameter int unsigned WD_RET    = 512,   // CPU clocks from release to the first game fetch
  parameter int unsigned WD_IDLE   = 4096,  // CPU clocks for a restore to see no open transfer
  parameter int unsigned RST_TICKS = 16     // CPU clocks the private reset is held (1..255)
)(
  input  logic        clk,
  input  logic        rst,           // board reset (also resets the CPU)
  input  logic        cpu_tick,      // one pulse per CPU clock (enPhi1)
  // static configuration: work RAM, inclusive word addresses
  input  logic [23:1] ram_lo,
  input  logic [23:1] ram_hi,
  // CPU outputs (observed)
  input  logic        cpu_as_n,
  input  logic        cpu_uds_n,
  input  logic        cpu_lds_n,
  input  logic        cpu_rw,
  input  logic [2:0]  cpu_fc,
  input  logic [23:1] cpu_addr,
  input  logic [15:0] cpu_dout,
  input  logic        cpu_halted_n,
  input  logic        bus_done,      // qualified transfer-completion pulse
  // CPU input overrides (parent muxes them while bus_claim is high)
  output logic        bus_claim,     // combinational: the open transfer is private
  output logic        active,        // the block is the private bus owner
  output logic        cpu_dtack_n,
  output logic        cpu_vpa_n,
  output logic [15:0] cpu_din,
  output logic        ipl7_req,      // parent presents IPL = 7 while high
  output logic        cpu_reset,     // private reset: FX68K extReset only (pwrUp low)
  // commands: one-clock request, response exactly one clock later
  input  logic        cmd_valid,
  input  logic [2:0]  cmd_op,
  output logic        rsp_valid,
  output logic        rsp_ok,
  output logic [3:0]  rsp_code,
  // context word port: one-clock request, ack or nak exactly one clock later
  input  logic        ctx_req,
  input  logic        ctx_we,        // writes go to the restore bank only
  input  logic        ctx_bank,      // read: 0 = captured bank, 1 = restore bank
  input  logic [5:0]  ctx_idx,       // context word 0..37
  input  logic [15:0] ctx_wdata,
  output logic        ctx_ack,
  output logic        ctx_nak,
  output logic [15:0] ctx_rdata,     // valid with ctx_ack of a read
  // status and events
  output logic [3:0]  st_phase,
  output logic [2:0]  st_mode,
  output logic        st_busy,
  output logic        st_parked,     // capture ready: the parent owns the state
  output logic        st_held,       // CPU held in private reset
  output logic        st_cap_valid,
  output logic        st_admitted,
  output logic        st_stale7,     // a withdrawn level-7 request may still be acknowledged
  output logic        st_err_unexp,  // sticky: an unexpected private transfer was absorbed
  output logic        evt_valid,
  output logic [3:0]  evt_code
);
  import rzctx_pkg::*;
  import rzctx_fw_pkg::*;

  // ---------------------------------------------------------------- checks
  initial begin
    if (RST_TICKS < 1 || RST_TICKS > 255) $error("rzctx_core: RST_TICKS must be 1..255");
    if (WD_IACK > 131000 || WD_RUN > 131000 || WD_RET > 131000 || WD_IDLE > 131000)
      $error("rzctx_core: watchdog limits must fit 17 bits");
    if (PRIV_BASE[6:0] != 7'd0 || PORT_BASE != PRIV_BASE + 24'h80 || PARK_ADDR != PORT_BASE + 24'h7E)
      $error("rzctx_core: firmware windows do not match the decoder");
  end

  // ---------------------------------------------------------------- private transfer kinds
  localparam logic [3:0] K_NONE  = 4'd0;  // unexpected: absorbed (reads return NOP)
  localparam logic [3:0] K_IACK  = 4'd1;  // level-7 IACK: VPA (autovector)
  localparam logic [3:0] K_FW    = 4'd2;  // private code fetch
  localparam logic [3:0] K_PORTR = 4'd3;  // context port read
  localparam logic [3:0] K_PORTW = 4'd4;  // context port write (capture only)
  localparam logic [3:0] K_FRMW  = 4'd5;  // exception frame write after IACK (overlay)
  localparam logic [3:0] K_VEC   = 4'd6;  // vector 31 read at $7C/$7E
  localparam logic [3:0] K_RVEC  = 4'd7;  // private reset vector read at 0..7
  localparam logic [3:0] K_FRMR  = 4'd8;  // RTE frame read (overlay)
  localparam logic [3:0] K_PARK  = 4'd9;  // held read

  // ---------------------------------------------------------------- state
  logic [3:0]  phase;
  logic [2:0]  mode;
  logic        ipl7_q, stale7_q, cancel_q, reset_q, park_rel_q, op_err_q, err_unexp_q;
  logic [16:0] wd_cnt;
  logic [3:0] wd_phase;
  // rst_cnt, rv_bits and fr_bits read as zero on the first edge of their phase.
  logic [7:0]  rst_cnt_stored;
  logic rst_cnt_prior_phase;
  wire [7:0] rst_cnt = phase == PH_RHOLD && !rst_cnt_prior_phase ? 8'd0 : rst_cnt_stored;
  logic [3:0]  ret_evt_q;
  // transfer tracker
  logic        as_q, taken_q, c_priv, c_rw;
  logic [2:0]  c_fc;
  logic [23:1] c_addr;
  logic [1:0]  c_strb;
  logic [15:0] c_wd;
  // private responder
  logic [3:0]  r_kind;
  logic [5:0]  r_idx;
  logic        r_bank, r_pend, r_rdy;
  logic [15:0] din_q;
  // live exception frame
  logic        rec_ok;      // last accepted unclaimed transfer was an S-data word write
  logic [23:1] rec_a;
  logic [15:0] rec_d;
  logic [1:0]  frm_n;
  logic        frm_adj;
  logic [23:1] frm_a;
  logic [23:0] frm_plus2, n_frm_plus2;
  logic [15:0] frm_sr, frm_pch;
  logic        vec_dec, vec_cap;
  logic [1:0]  vec_bits;
  logic [3:0]  rv_bits_stored;
  logic rv_bits_prior_phase;
  wire [3:0] rv_bits = phase == PH_RVEC && !rv_bits_prior_phase ? 4'b0000 : rv_bits_stored;
  logic [2:0]  fr_bits_stored;
  logic fr_bits_prior_phase;
  wire [2:0] fr_bits = phase == PH_TAIL && !fr_bits_prior_phase ? 3'b000 : fr_bits_stored;
  logic [23:1] exp_pc;
  logic        exp_s;
  // context banks: 0 = captured (CPU written), 1 = restore (parent written)
  logic [37:0] cap_bits, rst_bits;
  logic        cap_valid, admitted;
  logic [31:0] cap_ssp, cap_pc, rst_ssp, rst_pc;
  logic [15:0] cap_sr, rst_sr, rst_fmt;
  logic        rst_usp0;
  // registered outputs
  logic        rsp_valid_q, rsp_ok_q, evt_valid_q, ctx_ack_q, ctx_nak_q, p_ram_q;
  logic [3:0]  rsp_code_q, evt_code_q;
  logic [15:0] p_field_q;

  // ---------------------------------------------------------------- transfer tracking
  wire        open_now = ~cpu_as_n;
  wire        first    = open_now & ~as_q;
  wire [1:0]  strb_now = open_now ? {~cpu_uds_n, ~cpu_lds_n} : 2'b00;
  // One completion per transfer, accepted after its opening edge (including the closing edge).
  wire        done_acc = bus_done & ~taken_q & (open_now ? ~first : as_q);
  wire [1:0]  d_strb   = c_strb | strb_now;
  wire [15:0] d_wd     = (|strb_now) ? cpu_dout : c_wd;

  // ---------------------------------------------------------------- ownership
  wire is_iack7 = (cpu_fc == 3'b111) && (cpu_addr == 23'h7FFFFF);
  wire own_ph   = (phase == PH_EXC) || (phase == PH_RUN) || (phase == PH_PARK) || (phase == PH_TAIL) ||
                  (phase == PH_RHOLD) || (phase == PH_RVEC) || (phase == PH_HELD);
  wire iack_arm = (phase == PH_REQ) ||
                  (stale7_q && ((phase == PH_IDLE) || (phase == PH_RET) || (phase == PH_RWAIT)));
  wire claim_dec = own_ph | (is_iack7 & iack_arm);
  assign bus_claim = open_now & (first ? claim_dec : c_priv);
  assign active    = own_ph | bus_claim;

  // ---------------------------------------------------------------- return frame source
  logic [15:0] t_sr;
  logic [31:0] t_pc;
  logic [23:1] t_f;
  always_comb begin
    case (mode)
      M_ABORT:   begin t_sr = frm_sr; t_pc = {frm_pch, rec_d}; t_f = frm_a; end
      M_RESTORE: begin t_sr = rst_sr; t_pc = rst_pc; t_f = rst_ssp[23:1] - 23'd3; end
      default:   begin t_sr = cap_sr; t_pc = cap_pc; t_f = cap_ssp[23:1] - 23'd3; end
    endcase
  end

  // ---------------------------------------------------------------- private decode
  wire        in_code  = (cpu_addr[23:7] == PRIV_BASE[23:7]);
  wire        in_port  = (cpu_addr[23:7] == PORT_BASE[23:7]);
  wire [5:0]  widx     = cpu_addr[6:1];
  wire        fc_sp    = (cpu_fc == 3'b110);
  wire        fc_sd    = (cpu_fc == 3'b101);
  wire [22:0] fdiff    = cpu_addr - t_f;
  wire        is_vec   = fc_sd & cpu_rw & (cpu_addr[23:2] == 22'h00001F);
  wire        bank_now = (mode == M_RESTORE);
  logic [3:0] kind;
  logic [5:0] kidx;
  always_comb begin
    kind = K_NONE;
    kidx = widx;
    if (!own_ph) begin
      if (is_iack7) kind = K_IACK;
    end else begin
      case (phase)
        PH_EXC: begin
          if (fc_sd && !cpu_rw) kind = K_FRMW;
          else if (is_vec) begin kind = K_VEC; kidx = {5'd0, cpu_addr[1]}; end
          else if (fc_sp && cpu_rw && in_code) kind = K_FW;
        end
        PH_RUN: begin
          if (fc_sp && cpu_rw && in_code) kind = K_FW;
          else if (fc_sd && in_port && widx == 6'd63) kind = cpu_rw ? K_PARK : K_NONE;
          else if (fc_sd && in_port) kind = cpu_rw ? K_PORTR : K_PORTW;
        end
        PH_TAIL: begin
          if (fc_sp && cpu_rw && in_code) kind = K_FW;
          else if (fc_sd && cpu_rw && fdiff < 23'd3) begin kind = K_FRMR; kidx = {4'd0, fdiff[1:0]}; end
          else if (fc_sd && cpu_rw && in_port && widx != 6'd63) kind = K_PORTR;
        end
        PH_RVEC: begin
          if (fc_sp && cpu_rw && cpu_addr[23:3] == 21'd0) begin kind = K_RVEC; kidx = {4'd0, cpu_addr[2:1]}; end
          else if (fc_sp && cpu_rw && in_code) kind = K_FW;
        end
        default: kind = K_NONE;
      endcase
    end
  end

  // ---------------------------------------------------------------- context store
  function automatic logic [15:0] field_word(input logic [5:0] i, input logic [15:0] fmt,
      input logic [31:0] ssp, input logic [15:0] sr, input logic [31:0] pc);
    case (i)
      6'd0:    field_word = fmt;
      6'd33:   field_word = ssp[31:16];
      6'd34:   field_word = ssp[15:0];
      6'd35:   field_word = sr;
      6'd36:   field_word = pc[31:16];
      6'd37:   field_word = pc[15:0];
      default: field_word = 16'h4E71;
    endcase
  endfunction

  wire        cpu_rd_ram = first & claim_dec & (kind == K_PORTR) & (widx >= 6'd1) & (widx <= 6'd32);
  wire        cpu_wr_ram = done_acc & c_priv & (r_kind == K_PORTW) & (phase == PH_RUN) &
                           (r_idx >= 6'd1) & (r_idx <= 6'd32);
  wire        ctx_ph_ok  = (phase == PH_IDLE) || (phase == PH_REQ) || (phase == PH_PARK) ||
                           (phase == PH_HELD) || (phase == PH_RET);
  wire        ctx_go     = ctx_req & ctx_ph_ok & (ctx_idx < 6'd38) & (~ctx_we | ctx_bank) &
                           ~cpu_rd_ram & ~cpu_wr_ram;
  wire        ctx_wr_now = ctx_go & ctx_we;
  wire        p_is_ram   = (ctx_idx >= 6'd1) && (ctx_idx <= 6'd32);
  // word k (1..32) of a bank lives at RAM index {bank, k-1}; k = 32 wraps to 31
  wire [4:0]  widx_m1    = widx[4:0] - 5'd1;
  wire [4:0]  ridx_m1    = r_idx[4:0] - 5'd1;
  wire [4:0]  cidx_m1    = ctx_idx[4:0] - 5'd1;

  logic        ram_en;
  logic [1:0]  ram_we;
  logic [5:0]  ram_addr;
  logic [15:0] ram_wd, ram_rd;
  always_comb begin
    ram_en = 1'b0; ram_we = 2'b00; ram_addr = 6'd0; ram_wd = 16'h0000;
    if (cpu_rd_ram) begin
      ram_en = 1'b1; ram_addr = {bank_now, widx_m1};
    end else if (cpu_wr_ram) begin
      ram_en = 1'b1; ram_we = d_strb; ram_addr = {1'b0, ridx_m1}; ram_wd = d_wd;
    end else if (ctx_go && p_is_ram) begin
      ram_en = 1'b1; ram_we = ctx_we ? 2'b11 : 2'b00; ram_addr = {ctx_bank, cidx_m1}; ram_wd = ctx_wdata;
    end
  end
  rzctx_ram u_ram (.clk(clk), .en(ram_en), .we(ram_we), .addr(ram_addr), .wd(ram_wd), .rd(ram_rd));

  // ---------------------------------------------------------------- private read data
  wire [15:0] r_field  = r_bank ? field_word(r_idx, rst_fmt, rst_ssp, rst_sr, rst_pc)
                                : field_word(r_idx, FORMAT_ID, cap_ssp, cap_sr, cap_pc);
  wire        r_is_ram = (r_idx >= 6'd1) && (r_idx <= 6'd32);
  wire [23:0] vec_entry = vec_cap ? CAPTURE_ENTRY : ABORT_ENTRY;
  wire [31:0] rv_ssp    = rst_ssp - 32'd6;
  logic [15:0] r_data;
  always_comb begin
    case (r_kind)
      K_FW:    r_data = fw_word(r_idx);
      K_PORTR: r_data = r_is_ram ? ram_rd : r_field;
      K_VEC:   r_data = r_idx[0] ? vec_entry[15:0] : {8'h00, vec_entry[23:16]};
      K_RVEC: begin
        case (r_idx[1:0])
          2'd0:    r_data = rv_ssp[31:16];
          2'd1:    r_data = rv_ssp[15:0];
          2'd2:    r_data = {8'h00, RESTORE_ENTRY[23:16]};
          default: r_data = RESTORE_ENTRY[15:0];
        endcase
      end
      K_FRMR: begin
        case (r_idx[1:0])
          2'd0:    r_data = t_sr;
          2'd1:    r_data = t_pc[31:16];
          default: r_data = t_pc[15:0];
        endcase
      end
      K_NONE:  r_data = 16'h4E71;
      default: r_data = 16'h0000;
    endcase
  end

  // Private DTACK/VPA from the second clock of a claimed transfer; writes wait for a strobe, park for release.
  wire wr_ok   = c_rw | (|d_strb);
  wire ack_now = open_now & ~first & c_priv & r_rdy & wr_ok & ((r_kind != K_PARK) | park_rel_q);
  assign cpu_dtack_n = ~(ack_now & (r_kind != K_IACK));
  assign cpu_vpa_n   = ~(ack_now & (r_kind == K_IACK));
  assign cpu_din     = din_q;

  // ---------------------------------------------------------------- checks used by the sequencer
  wire        cfg_ok   = (ram_lo <= ram_hi) && (ram_lo >= 23'h000100);
  wire        frm_struct = rec_ok && (frm_n == 2'd2) && frm_adj && (rec_a == frm_plus2[22:0]);
  wire        frm_in_ram = (frm_a >= ram_lo) && (frm_plus2 <= {1'b0, ram_hi});
  wire        cap_go   = (mode == M_CAPTURE) && !cancel_q && frm_struct && frm_in_ram;
  wire [23:0] frm_ssp  = {frm_a, 1'b0} + 24'd6;
  wire        park_ok  = (&cap_bits[34:1]) && (cap_ssp[23:0] == frm_ssp) && !op_err_q;
  // restore frame base word address: ((SSP - 6) mod 2^24) / 2
  wire [23:1] rst_fw   = rst_ssp[23:1] - 23'd3;
  logic [3:0] v_code;
  always_comb begin
    if (!(&rst_bits))                                   v_code = R_INCOMPLETE;
    else if (rst_fmt != FORMAT_ID)                      v_code = R_FORMAT;
    else if ((rst_sr & SR_MUST_BE_ZERO) != 16'h0000)    v_code = R_SR;
    else if (rst_pc[0] || rst_pc[31:24] != 8'h00)       v_code = R_PC;
    else if (rst_ssp[0])                                v_code = R_SSP_ODD;
    else if (rst_fw < ram_lo || ({1'b0, rst_fw} + 24'd2) > {1'b0, ram_hi}) v_code = R_SSP_RANGE;
    else if (!rst_sr[13] && rst_usp0)                   v_code = R_USP_ODD;
    else if (!cfg_ok)                                   v_code = R_CFG;
    else                                                v_code = R_OK;
  end

  logic [16:0] wd_lim;
  always_comb begin
    case (phase)
      PH_REQ:   wd_lim = 17'(WD_IACK);
      PH_RET:   wd_lim = 17'(WD_RET);
      PH_RWAIT: wd_lim = 17'(WD_IDLE);
      default:  wd_lim = 17'(WD_RUN);
    endcase
  end
  wire wd_on  = (phase == PH_REQ) || (phase == PH_EXC) || (phase == PH_RUN) || (phase == PH_TAIL) ||
                (phase == PH_RET) || (phase == PH_RWAIT) || (phase == PH_RVEC);
  wire wd_match = wd_phase == phase;
  wire wd_tick = wd_on && cpu_tick;
  wire wd_exp = wd_on && ((wd_lim == 0) || (wd_match && wd_cnt >= wd_lim));

  // Watchdog count restarts from zero on each phase change.
  always_ff @(posedge clk) begin
    wd_phase <= rst ? PH_IDLE : phase;
    if (rst) wd_cnt <= 17'd0;
    else if (!wd_match) wd_cnt <= {16'd0, wd_tick};
    else if (wd_tick && wd_cnt != 17'h1FFFF) wd_cnt <= wd_cnt + 17'd1;
  end

  // ---------------------------------------------------------------- sequencer (next state)
  logic [3:0]  n_phase, n_ret_evt, n_rsp_code, n_evt_code;
  logic [2:0]  n_mode;
  logic        n_ipl7, n_stale7, n_cancel, n_reset, n_park_rel, n_op_err, n_err_unexp;
  logic [7:0]  n_rst_cnt;
  logic        n_rec_ok;
  logic [23:1] n_rec_a, n_frm_a, n_exp_pc;
  logic [15:0] n_rec_d, n_frm_sr, n_frm_pch, n_cap_sr, n_rst_sr, n_rst_fmt;
  logic [1:0]  n_frm_n, n_vec_bits;
  logic        n_frm_adj, n_vec_dec, n_vec_cap, n_exp_s, n_cap_valid, n_admitted, n_rst_usp0;
  logic [3:0]  n_rv_bits;
  logic [2:0]  n_fr_bits;
  logic [37:0] n_cap_bits, n_rst_bits;
  logic [31:0] n_cap_ssp, n_cap_pc, n_rst_ssp, n_rst_pc;
  logic        n_rsp_valid, n_rsp_ok, n_evt_valid, evt_busy;
  logic [1:0]  vb_new;
  logic [2:0]  fb_new;
  logic [3:0]  rb_new;

  always_comb begin
    n_phase = phase;         n_mode = mode;           n_ipl7 = ipl7_q;       n_stale7 = stale7_q;
    n_cancel = cancel_q;     n_reset = reset_q;       n_park_rel = park_rel_q;
    n_op_err = op_err_q;     n_err_unexp = err_unexp_q; n_rst_cnt = rst_cnt; n_ret_evt = ret_evt_q;
    n_rec_ok = rec_ok;       n_rec_a = rec_a;         n_rec_d = rec_d;
    n_frm_plus2 = frm_plus2;
    n_frm_n = frm_n;         n_frm_adj = frm_adj;     n_frm_a = frm_a;       n_frm_sr = frm_sr;
    n_frm_pch = frm_pch;     n_vec_dec = vec_dec;     n_vec_cap = vec_cap;   n_vec_bits = vec_bits;
    n_rv_bits = rv_bits;     n_fr_bits = fr_bits;     n_exp_pc = exp_pc;     n_exp_s = exp_s;
    n_cap_bits = cap_bits;   n_rst_bits = rst_bits;   n_cap_valid = cap_valid; n_admitted = admitted;
    n_cap_ssp = cap_ssp;     n_cap_pc = cap_pc;       n_cap_sr = cap_sr;
    n_rst_ssp = rst_ssp;     n_rst_pc = rst_pc;       n_rst_sr = rst_sr;     n_rst_fmt = rst_fmt;
    n_rst_usp0 = rst_usp0;
    n_rsp_valid = 1'b0;      n_rsp_ok = 1'b0;         n_rsp_code = R_OK;
    n_evt_valid = 1'b0;      n_evt_code = 4'd0;
    vb_new = vec_bits | (r_idx[0] ? 2'b10 : 2'b01);
    fb_new = fr_bits | (3'b001 << r_idx[1:0]);
    rb_new = rv_bits | (4'b0001 << r_idx[1:0]);
    if (first) n_park_rel = 1'b0;

    // ---- A. a private transfer opens
    if (first && claim_dec) begin
      if (kind == K_NONE) begin n_err_unexp = 1'b1; n_op_err = 1'b1; end
      if (kind == K_IACK) begin
        n_stale7 = 1'b0;
        n_frm_n = 2'd0; n_frm_adj = 1'b0; n_vec_dec = 1'b0; n_vec_cap = 1'b0; n_vec_bits = 2'b00;
        if (phase == PH_RWAIT) begin
          n_phase = PH_RHOLD; n_reset = 1'b1;            // stale IACK while restoring: bus is private
        end else begin
          n_phase = PH_EXC;
          if (phase != PH_REQ) begin n_mode = M_ABORT; n_ret_evt = EV_ABORTED; end
        end
      end
      if (kind == K_VEC && !vec_dec) begin
        n_vec_dec = 1'b1;
        n_vec_cap = cap_go;
        if (!cap_go) begin
          if (!frm_struct) begin                           // invalid return frame: hold
            n_reset = 1'b1; n_ipl7 = 1'b0; n_phase = PH_HELD;
            n_evt_valid = 1'b1; n_evt_code = EV_F_FRAME;
          end else if (mode == M_CAPTURE) begin
            n_ret_evt = cancel_q ? EV_CANCELLED : EV_F_STACK;
          end
          n_mode = M_ABORT;
        end
      end
      if (kind == K_PARK) begin
        if (park_ok) begin
          n_cap_valid = 1'b1; n_cap_sr = frm_sr; n_cap_pc = {frm_pch, rec_d};
          if (cancel_q) begin
            n_mode = M_CANCEL; n_park_rel = 1'b1; n_phase = PH_TAIL;
          end else begin
            n_phase = PH_PARK; n_evt_valid = 1'b1; n_evt_code = EV_PARKED;
          end
        end else begin
          n_cap_valid = 1'b0; n_reset = 1'b1; n_phase = PH_HELD;
          n_evt_valid = 1'b1; n_evt_code = EV_F_INCOMPLETE;
        end
      end
    end

    // ---- B. a transfer completes (parent's qualified event, counted once)
    if (done_acc) begin
      if (c_priv) begin
        case (r_kind)
          K_IACK: n_ipl7 = 1'b0;
          K_FRMW: begin
            if (d_strb != 2'b11 || frm_n == 2'd2) n_op_err = 1'b1;
            else if (frm_n == 2'd0) begin
              n_frm_a = c_addr; n_frm_sr = d_wd; n_frm_n = 2'd1;
              // 24-bit sum: carry kept for the RAM bound, low 23 bits for the bus compare
              n_frm_plus2 = {1'b0, c_addr} + 24'd2;
            end
            else begin n_frm_pch = d_wd; n_frm_adj = (c_addr == frm_a + 23'd1); n_frm_n = 2'd2; end
          end
          K_VEC: begin
            n_vec_bits = vb_new;
            if (vb_new == 2'b11 && phase == PH_EXC) n_phase = vec_cap ? PH_RUN : PH_TAIL;
          end
          K_PORTW: begin
            if (phase == PH_RUN && r_idx >= 6'd1 && r_idx <= 6'd34) begin
              if (d_strb == 2'b11) n_cap_bits[r_idx] = 1'b1;
              else n_op_err = 1'b1;
              if (r_idx == 6'd33) begin
                if (d_strb[1]) n_cap_ssp[31:24] = d_wd[15:8];
                if (d_strb[0]) n_cap_ssp[23:16] = d_wd[7:0];
              end
              if (r_idx == 6'd34) begin
                if (d_strb[1]) n_cap_ssp[15:8] = d_wd[15:8];
                if (d_strb[0]) n_cap_ssp[7:0]  = d_wd[7:0];
              end
            end else begin
              n_op_err = 1'b1; n_err_unexp = 1'b1;
            end
          end
          K_FRMR: begin
            n_fr_bits = fb_new;
            if (fb_new == 3'b111) begin n_phase = PH_RET; n_exp_pc = t_pc[23:1]; n_exp_s = t_sr[13]; end
          end
          K_RVEC: begin
            n_rv_bits = rb_new;
            if (rb_new == 4'b1111) n_phase = PH_TAIL;
          end
          default: ;
        endcase
      end else begin
        // Records the last unclaimed transfer (before IACK: the PC low word write to SSP-2).
        n_rec_ok = (c_fc == 3'b101) && !c_rw && (d_strb == 2'b11);
        n_rec_a  = c_addr;
        n_rec_d  = d_wd;
        if (phase == PH_RET && c_fc[1:0] == 2'b10) begin   // FC 010 or 110: program fetch
          n_phase = PH_IDLE; n_mode = M_NONE; n_evt_valid = 1'b1;
          if (c_addr == exp_pc && c_fc[2] == exp_s) begin
            case (mode)
              M_RESUME:  n_evt_code = EV_RESUMED;
              M_RESTORE: begin n_evt_code = EV_RESTORED; n_admitted = 1'b0; end
              M_CANCEL:  n_evt_code = EV_CANCELLED;
              default:   n_evt_code = ret_evt_q;
            endcase
          end else begin
            n_evt_code = EV_F_RETURN;
          end
        end
      end
    end

    // ---- C. restore start and private reset
    if (phase == PH_RWAIT && n_phase == PH_RWAIT && !open_now) begin
      n_phase = PH_RHOLD; n_reset = 1'b1;                  // no open board transfer
    end
    if (phase == PH_RHOLD && n_phase == PH_RHOLD && cpu_tick) begin
      if (32'(rst_cnt) + 32'd1 >= RST_TICKS) begin
        if (mode == M_RESTORE) begin n_reset = 1'b0; n_phase = PH_RVEC; end
        else begin n_phase = PH_HELD; n_evt_valid = 1'b1; n_evt_code = EV_HELD; end   // OP_HOLD
      end else begin
        n_rst_cnt = rst_cnt + 8'd1;
      end
    end

    // ---- D. watchdogs
    if (wd_exp && n_phase == phase) begin
      n_evt_valid = 1'b1;
      case (phase)
        PH_REQ:   begin n_phase = PH_IDLE; n_mode = M_NONE; n_ipl7 = 1'b0; n_stale7 = 1'b1;
                        n_evt_code = EV_F_IACK_TO; end
        PH_RET:   begin n_phase = PH_IDLE; n_mode = M_NONE; n_evt_code = EV_F_RET_TO; end
        PH_RWAIT: begin n_phase = PH_IDLE; n_mode = M_NONE; n_evt_code = EV_F_IDLE_TO; end
        default:  begin n_phase = PH_HELD; n_reset = 1'b1; n_ipl7 = 1'b0; n_evt_code = EV_F_RUN_TO; end
      endcase
    end
    evt_busy = n_evt_valid;

    // ---- E. commands, evaluated after this clock's bus events
    if (cmd_valid) begin
      n_rsp_valid = 1'b1;
      n_rsp_code  = R_BUSY;
      case (cmd_op)
        OP_CAPTURE: begin
          if (n_phase != PH_IDLE) n_rsp_code = R_BUSY;
          else if (!cfg_ok)       n_rsp_code = R_CFG;
          else if (!cpu_halted_n) n_rsp_code = R_HALTED;
          else begin
            n_phase = PH_REQ; n_mode = M_CAPTURE; n_ipl7 = 1'b1; n_cap_valid = 1'b0; n_cap_bits = '0;
            n_rec_ok = 1'b0; n_cancel = 1'b0; n_op_err = 1'b0; n_ret_evt = EV_ABORTED;
            n_rsp_ok = 1'b1; n_rsp_code = R_OK;
          end
        end
        OP_RESUME: begin
          if (n_phase == PH_PARK) begin
            n_mode = M_RESUME; n_park_rel = 1'b1; n_phase = PH_TAIL; n_rsp_ok = 1'b1; n_rsp_code = R_OK;
          end
        end
        OP_RESTORE: begin
          if (!admitted)        n_rsp_code = R_NOT_ADMITTED;
          else if (!cfg_ok)     n_rsp_code = R_CFG;
          else if (ctx_wr_now)  n_rsp_code = R_BUSY;
          else if (n_phase == PH_PARK) begin
            n_mode = M_RESTORE; n_park_rel = 1'b1; n_phase = PH_TAIL; n_rsp_ok = 1'b1; n_rsp_code = R_OK;
          end else if (n_phase == PH_IDLE) begin
            n_mode = M_RESTORE; n_phase = PH_RWAIT; n_rsp_ok = 1'b1; n_rsp_code = R_OK;
          end else if (n_phase == PH_HELD) begin
            n_mode = M_RESTORE; n_phase = PH_RHOLD; n_rsp_ok = 1'b1; n_rsp_code = R_OK;
          end
        end
        OP_CANCEL: begin
          n_rsp_ok = 1'b1; n_rsp_code = R_OK;
          case (n_phase)
            PH_REQ: begin
              if (evt_busy) begin n_rsp_ok = 1'b0; n_rsp_code = R_BUSY; end
              else begin
                n_phase = PH_IDLE; n_mode = M_NONE; n_ipl7 = 1'b0; n_stale7 = 1'b1;
                n_evt_valid = 1'b1; n_evt_code = EV_CANCELLED;
              end
            end
            PH_EXC, PH_RUN: if (n_mode == M_CAPTURE) n_cancel = 1'b1;
            PH_PARK: begin n_mode = M_CANCEL; n_park_rel = 1'b1; n_phase = PH_TAIL; end
            PH_TAIL: begin
              if (n_mode == M_RESTORE) begin
                if (evt_busy) begin n_rsp_ok = 1'b0; n_rsp_code = R_BUSY; end
                else begin n_reset = 1'b1; n_phase = PH_HELD; n_evt_valid = 1'b1; n_evt_code = EV_HELD; end
              end
            end
            PH_RWAIT: begin
              if (evt_busy) begin n_rsp_ok = 1'b0; n_rsp_code = R_BUSY; end
              else begin n_phase = PH_IDLE; n_mode = M_NONE; n_evt_valid = 1'b1; n_evt_code = EV_CANCELLED; end
            end
            PH_RHOLD, PH_RVEC: begin
              if (evt_busy) begin n_rsp_ok = 1'b0; n_rsp_code = R_BUSY; end
              else begin n_reset = 1'b1; n_phase = PH_HELD; n_evt_valid = 1'b1; n_evt_code = EV_HELD; end
            end
            PH_HELD: begin
              if (evt_busy) begin n_rsp_ok = 1'b0; n_rsp_code = R_BUSY; end
              else begin
                n_reset = 1'b0; n_phase = PH_IDLE; n_mode = M_NONE;
                n_evt_valid = 1'b1; n_evt_code = EV_RELEASED;
              end
            end
            default: ;   // IDLE, RET: nothing to cancel
          endcase
        end
        OP_HOLD: begin
          if (n_phase == PH_IDLE) begin
            n_mode = M_HOLD; n_phase = PH_RWAIT; n_rsp_ok = 1'b1; n_rsp_code = R_OK;
          end else if (n_phase == PH_PARK) begin
            if (!evt_busy) begin
              n_mode = M_HOLD; n_reset = 1'b1; n_phase = PH_HELD; n_rsp_ok = 1'b1; n_rsp_code = R_OK;
              n_evt_valid = 1'b1; n_evt_code = EV_HELD;
            end
          end else if (n_phase == PH_HELD) begin
            n_rsp_ok = 1'b1; n_rsp_code = R_OK;                // already held
          end
        end
        OP_LOAD: begin
          if (ctx_ph_ok) begin n_rst_bits = '0; n_admitted = 1'b0; n_rsp_ok = 1'b1; n_rsp_code = R_OK; end
        end
        OP_ADMIT: begin
          if (!ctx_ph_ok || ctx_wr_now) n_rsp_code = R_BUSY;
          else if (v_code != R_OK) begin n_admitted = 1'b0; n_rsp_code = v_code; end
          else begin n_admitted = 1'b1; n_rsp_ok = 1'b1; n_rsp_code = R_OK; end
        end
        default: n_rsp_code = R_BAD_OP;
      endcase
    end

    // ---- F. context port writes (restore bank)
    if (ctx_wr_now) begin
      n_rst_bits[ctx_idx] = 1'b1;
      n_admitted = 1'b0;
      case (ctx_idx)
        6'd0:  n_rst_fmt = ctx_wdata;
        6'd32: n_rst_usp0 = ctx_wdata[0];
        6'd33: n_rst_ssp[31:16] = ctx_wdata;
        6'd34: n_rst_ssp[15:0] = ctx_wdata;
        6'd35: n_rst_sr = ctx_wdata;
        6'd36: n_rst_pc[31:16] = ctx_wdata;
        6'd37: n_rst_pc[15:0] = ctx_wdata;
        default: ;
      endcase
    end
  end

  // ---------------------------------------------------------------- registers
  always_ff @(posedge clk) begin
    if (rst) begin
      phase <= PH_IDLE; mode <= M_NONE;
      ipl7_q <= 1'b0; stale7_q <= 1'b0; cancel_q <= 1'b0; reset_q <= 1'b0; park_rel_q <= 1'b0;
      op_err_q <= 1'b0; err_unexp_q <= 1'b0; rst_cnt_stored <= 8'd0; rst_cnt_prior_phase <= 1'b0; ret_evt_q <= EV_ABORTED;
      rec_ok <= 1'b0; rec_a <= '0; rec_d <= 16'h0000;
      frm_plus2 <= 24'd2;
      frm_n <= 2'd0; frm_adj <= 1'b0; frm_a <= '0; frm_sr <= 16'h0000; frm_pch <= 16'h0000;
      vec_dec <= 1'b0; vec_cap <= 1'b0; vec_bits <= 2'b00; rv_bits_stored <= 4'b0000; rv_bits_prior_phase <= 1'b0; fr_bits_stored <= 3'b000; fr_bits_prior_phase <= 1'b0;
      exp_pc <= '0; exp_s <= 1'b0;
      cap_bits <= '0; rst_bits <= '0; cap_valid <= 1'b0; admitted <= 1'b0;
      cap_ssp <= 32'h0; cap_pc <= 32'h0; cap_sr <= 16'h0;
      rst_ssp <= 32'h0; rst_pc <= 32'h0; rst_sr <= 16'h0; rst_fmt <= 16'h0; rst_usp0 <= 1'b0;
      rsp_valid_q <= 1'b0; rsp_ok_q <= 1'b0; rsp_code_q <= R_OK;
      evt_valid_q <= 1'b0; evt_code_q <= 4'd0;
      ctx_ack_q <= 1'b0; ctx_nak_q <= 1'b0; p_ram_q <= 1'b0; p_field_q <= 16'h0000;
      as_q <= 1'b0; taken_q <= 1'b0; c_priv <= 1'b0; c_rw <= 1'b1; c_fc <= 3'd0; c_addr <= '0;
      c_strb <= 2'b00; c_wd <= 16'h0000;
      r_kind <= K_NONE; r_idx <= 6'd0; r_bank <= 1'b0; r_pend <= 1'b0; r_rdy <= 1'b0; din_q <= 16'h0000;
    end else begin
      phase <= n_phase; mode <= n_mode;
      ipl7_q <= n_ipl7; stale7_q <= n_stale7; cancel_q <= n_cancel; reset_q <= n_reset;
      park_rel_q <= n_park_rel; op_err_q <= n_op_err; err_unexp_q <= n_err_unexp;
      rst_cnt_stored <= n_rst_cnt; rst_cnt_prior_phase <= phase == PH_RHOLD; ret_evt_q <= n_ret_evt;
      rec_ok <= n_rec_ok; rec_a <= n_rec_a; rec_d <= n_rec_d;
      frm_plus2 <= n_frm_plus2;
      frm_n <= n_frm_n; frm_adj <= n_frm_adj; frm_a <= n_frm_a; frm_sr <= n_frm_sr; frm_pch <= n_frm_pch;
      vec_dec <= n_vec_dec; vec_cap <= n_vec_cap; vec_bits <= n_vec_bits;
      rv_bits_stored <= n_rv_bits; rv_bits_prior_phase <= phase == PH_RVEC; fr_bits_stored <= n_fr_bits; fr_bits_prior_phase <= phase == PH_TAIL; exp_pc <= n_exp_pc; exp_s <= n_exp_s;
      cap_bits <= n_cap_bits; rst_bits <= n_rst_bits; cap_valid <= n_cap_valid; admitted <= n_admitted;
      cap_ssp <= n_cap_ssp; cap_pc <= n_cap_pc; cap_sr <= n_cap_sr;
      rst_ssp <= n_rst_ssp; rst_pc <= n_rst_pc; rst_sr <= n_rst_sr; rst_fmt <= n_rst_fmt;
      rst_usp0 <= n_rst_usp0;
      rsp_valid_q <= n_rsp_valid; rsp_ok_q <= n_rsp_ok; rsp_code_q <= n_rsp_code;
      evt_valid_q <= n_evt_valid; evt_code_q <= n_evt_code;
      // context port response (data from the RAM or a field register)
      ctx_ack_q <= ctx_go;
      ctx_nak_q <= ctx_req & ~ctx_go;
      p_ram_q   <= ctx_go & p_is_ram & ~ctx_we;
      p_field_q <= ctx_bank ? field_word(ctx_idx, rst_fmt, rst_ssp, rst_sr, rst_pc)
                            : field_word(ctx_idx, FORMAT_ID, cap_ssp, cap_sr, cap_pc);
      // transfer tracker and private responder
      as_q <= open_now;
      if (first) begin
        c_fc <= cpu_fc; c_rw <= cpu_rw; c_addr <= cpu_addr; c_priv <= claim_dec;
        c_strb <= strb_now;
        if (|strb_now) c_wd <= cpu_dout;
        r_kind <= claim_dec ? kind : K_NONE; r_idx <= kidx; r_bank <= bank_now;
        r_pend <= claim_dec; taken_q <= 1'b0;
      end else begin
        if (open_now) begin
          c_strb <= c_strb | strb_now;
          if (|strb_now) c_wd <= cpu_dout;
        end
        r_pend <= 1'b0;
        if (done_acc) taken_q <= 1'b1;
      end
      if (!open_now) r_rdy <= 1'b0;
      else if (r_pend) begin r_rdy <= 1'b1; din_q <= r_data; end
    end
  end

  // ---------------------------------------------------------------- outputs
  assign ipl7_req     = ipl7_q;
  assign cpu_reset    = reset_q | ((phase == PH_RWAIT) & ~open_now);
  assign rsp_valid    = rsp_valid_q;
  assign rsp_ok       = rsp_ok_q;
  assign rsp_code     = rsp_code_q;
  assign evt_valid    = evt_valid_q;
  assign evt_code     = evt_code_q;
  assign ctx_ack      = ctx_ack_q;
  assign ctx_nak      = ctx_nak_q;
  assign ctx_rdata    = p_ram_q ? ram_rd : p_field_q;
  assign st_phase     = phase;
  assign st_mode      = mode;
  assign st_busy      = (phase != PH_IDLE);
  assign st_parked    = (phase == PH_PARK);
  assign st_held      = (phase == PH_HELD);
  assign st_cap_valid = cap_valid;
  assign st_admitted  = admitted;
  assign st_stale7    = stale7_q;
  assign st_err_unexp = err_unexp_q;
endmodule

// 64-word single-port context RAM with byte enables and a registered read.
`timescale 1ns/1ps
module rzctx_ram (
  input  logic        clk,
  input  logic        en,
  input  logic [1:0]  we,      // [1] = bits 15:8 (UDS lane), [0] = bits 7:0 (LDS lane)
  input  logic [5:0]  addr,
  input  logic [15:0] wd,
  output logic [15:0] rd
);
  logic [7:0] mem_hi [0:63];
  logic [7:0] mem_lo [0:63];
  // power-up contents, not a reset
  initial begin
    for (int i = 0; i < 64; i++) begin
      mem_hi[i] = 8'h00;
      mem_lo[i] = 8'h00;
    end
  end
  always @(posedge clk) begin
    if (en) begin
      if (we[1]) mem_hi[addr] <= wd[15:8];
      if (we[0]) mem_lo[addr] <= wd[7:0];
      rd <= {mem_hi[addr], mem_lo[addr]};
    end
  end
endmodule

// Journals the last work-RAM write before the private IACK; restores its pre-image if it matches the frame.
module rzctx_stack_undo #(parameter integer PREIMAGE_W=16) (
    input clk, reset,
    input arm, cancel,
    input ordinary_done, private_iack_done,
    input sample_valid,
    input [14:0] sample_word,
    input [PREIMAGE_W-1:0] sample_before,
    input [15:0] sample_written,
    input confirm,
    input [14:0] frame_word,
    input [15:0] frame_pc_low,
    input wram_held,
    output undo_valid,
    input undo_ready,
    output [14:0] undo_word,
    output [PREIMAGE_W-1:0] undo_data,
    input response_valid, response_error,
    output response_ready,
    output reg done, fault
);
    typedef enum logic [2:0] {IDLE, OBSERVE, IACKED, REQUEST, RESPONSE} stage_t;
    stage_t stage;
    typedef struct packed {
        logic valid;
        logic [14:0] word;
        logic [PREIMAGE_W-1:0] before_word;
        logic [15:0] written;
    } observation_t;
    observation_t pending, last;
    wire good_sample = sample_valid && stage==OBSERVE;
    wire matches_frame = last.valid && last.word==frame_word && last.written==frame_pc_low;

    assign undo_valid = !reset && !cancel && wram_held && stage==REQUEST;
    assign undo_word = last.word;
    assign undo_data = last.before_word;
    assign response_ready = !reset && stage==RESPONSE;

    always @(posedge clk) begin
        done <= 0;
        if (reset) begin
            stage <= IDLE;
            pending <= '0;
            last <= '0;
            fault <= 0;
        end else case (stage)
            IDLE: if (arm) begin
                stage <= OBSERVE;
                pending.valid <= 0;
                last.valid <= 0;
                fault <= 0;
            end
            OBSERVE: if (cancel) stage <= IDLE;
            else if (private_iack_done) begin
                stage <= IACKED;
                if (ordinary_done || sample_valid || pending.valid) last.valid <= 0;
            end else begin
                if (ordinary_done) begin
                    last <= good_sample ? {1'b1,sample_word,sample_before,sample_written} : pending;
                    pending.valid <= 0;
                end else if (good_sample) begin
                    pending <= {1'b1,sample_word,sample_before,sample_written};
                end
            end
            IACKED: if (cancel) stage <= IDLE;
            else if (confirm) begin
                stage <= matches_frame ? REQUEST : IDLE;
                fault <= !matches_frame;
            end
            REQUEST: if (cancel) stage <= IDLE;
            else if (undo_valid && undo_ready) stage <= RESPONSE;
            RESPONSE: if (response_valid) begin
                stage <= IDLE;
                done <= !response_error;
                fault <= response_error;
            end
            default: stage <= IDLE;
        endcase
    end
endmodule

// Sequences save (capture, stack undo, resume) and restore commands for the context engine.
`timescale 1ns/1ps
`default_nettype none
module rzctx_board_service
    import rzctx_pkg::*;
(
    input logic clk, reset,
    input logic save_begin, save_resume, restore_begin,
    input logic parked, captured, admitted,
    input logic event_valid,
    input logic [3:0] event_code,
    output logic cmd_valid,
    output logic [2:0] cmd_op,
    input logic rsp_valid, rsp_ok,
    output logic ctx_req,
    output logic [5:0] ctx_idx,
    input logic ctx_ack, ctx_nak,
    input logic [15:0] ctx_rdata,
    output logic journal_arm, journal_cancel, journal_confirm,
    output logic [14:0] journal_word,
    output logic [15:0] journal_pc,
    input logic journal_done, journal_fault,
    output logic service_run, save_ready, save_done, restore_done, fault
);
    typedef enum logic [3:0] {
        IDLE, ISSUE, RESPONSE, EVENT, STACK_REQ, STACK_REPLY,
        PC_REQ, PC_REPLY, CONFIRM, UNDO, SAVED, FAILED
    } state_t;
    state_t state;
    logic [2:0] operation;
    logic [17:0] deadline;

    assign cmd_valid = state == ISSUE;
    assign cmd_op = operation;
    assign ctx_req = state == STACK_REQ || state == PC_REQ;
    assign ctx_idx = state == STACK_REQ ? 6'(W_SSP+1) : 6'(W_PC+1);
    assign journal_arm = cmd_valid && operation == OP_CAPTURE;
    assign journal_cancel = fault;
    assign journal_confirm = state == CONFIRM;
    assign service_run = (state == ISSUE || state == RESPONSE || state == EVENT) &&
        (operation != OP_CAPTURE || !parked);
    assign save_ready = state == SAVED && parked && captured;
    assign fault = state == FAILED;

    // Any state except IDLE/SAVED fails on deadline saturation; failure events (codes 8-15) fail too.
    always_ff @(posedge clk) begin
        save_done <= 1'b0;
        restore_done <= 1'b0;
        if (reset) begin
            state <= IDLE;
            operation <= 3'd0;
            deadline <= 18'd0;
            journal_word <= 15'd0;
            journal_pc <= 16'd0;
        end else begin
            if (state == IDLE || state == SAVED) deadline <= 18'd0;
            else if (!(&deadline)) deadline <= deadline + 18'd1;
            if ((&deadline && state != IDLE && state != SAVED) ||
                (event_valid && event_code[3])) state <= FAILED;
            else case (state)
                IDLE: if (save_resume || (save_begin && restore_begin)) state <= FAILED;
                else if (save_begin || restore_begin) begin
                    operation <= save_begin ? OP_CAPTURE : OP_RESTORE;
                    state <= (restore_begin && !admitted) ? FAILED : ISSUE;
                end
                ISSUE: state <= RESPONSE;
                RESPONSE: if (rsp_valid) state <= rsp_ok ? EVENT : FAILED;
                EVENT: if (event_valid) begin
                    if (operation == OP_CAPTURE && event_code == EV_PARKED && parked && captured)
                        state <= STACK_REQ;
                    else if (operation == OP_RESUME && event_code == EV_RESUMED) begin
                        save_done <= 1'b1;
                        state <= IDLE;
                    end else if (operation == OP_RESTORE && event_code == EV_RESTORED) begin
                        restore_done <= 1'b1;
                        state <= IDLE;
                    end else state <= FAILED;
                end
                STACK_REQ: state <= STACK_REPLY;
                STACK_REPLY: if (ctx_nak) state <= FAILED;
                else if (ctx_ack) begin
                    // journal word = (SSP - 2) word index, wrapping within the 64 KiB work RAM
                    journal_word <= ctx_rdata[15:1] - 15'd1;
                    state <= PC_REQ;
                end
                PC_REQ: state <= PC_REPLY;
                PC_REPLY: if (ctx_nak) state <= FAILED;
                else if (ctx_ack) begin journal_pc <= ctx_rdata; state <= CONFIRM; end
                CONFIRM: state <= UNDO;
                UNDO: if (journal_fault || !parked || !captured) state <= FAILED;
                else if (journal_done) state <= SAVED;
                SAVED: if (!parked || !captured || save_begin || restore_begin) state <= FAILED;
                else if (save_resume) begin operation <= OP_RESUME; state <= ISSUE; end
                FAILED: ;
                default: state <= FAILED;
            endcase
        end
    end
endmodule
`default_nettype wire

// Loads a stacked CPU frame (USP, D0-A6, SR, PC at SSP) from a work-RAM save image into the restore bank and admits it.
`timescale 1ns/1ps
`default_nettype none
module rzctx_legacy_preflight
    import rzctx_pkg::*;
(
    input logic clk, reset, start,
    input logic [31:0] ssp_offset, wram_offset,
    input logic [31:0] wram_words,
    output logic busy, done, ok,
    output logic [3:0] code,
    output logic rd_req,
    output logic [31:0] rd_addr,
    input logic rd_idle, rd_done,
    input logic [63:0] rd_data,
    output logic cmd_valid,
    output logic [2:0] cmd_op,
    input logic rsp_valid, rsp_ok,
    input logic [3:0] rsp_code,
    output logic ctx_req,
    output logic [5:0] ctx_idx,
    output logic [15:0] ctx_data,
    input logic ctx_ack, ctx_nak,
    input logic admitted
);
    typedef enum logic [3:0] {
        IDLE, BEGIN_BANK, WAIT_BANK, READ_SSP, WAIT_SSP,
        SEND_FIELD, WAIT_FIELD, READ_FRAME, WAIT_FRAME, ADMIT, WAIT_ADMIT
    } state_t;
    state_t state;
    localparam logic [23:0] WRAM_LO = 24'h100000;
    localparam logic [23:0] WRAM_LAST_FRAME = 24'h110000 - 24'd70;
    localparam logic [3:0] BAD_IMAGE = 4'd13;
    localparam logic [3:0] BAD_PORT = 4'd14;
    logic [31:0] ssp_addr, ram_addr, next_frame_addr, arch_ssp;
    logic [5:0] field_no;
    logic [15:0] frame_data;
    logic [3:0] waited;
    assign busy = state != IDLE;
    assign rd_req = rd_idle && (state == READ_SSP || state == READ_FRAME);
    assign rd_addr = state == READ_SSP ? ssp_addr : next_frame_addr;
    assign cmd_valid = state == BEGIN_BANK || state == ADMIT;
    assign cmd_op = state == BEGIN_BANK ? OP_LOAD : OP_ADMIT;
    assign ctx_req = state == SEND_FIELD;
    // Sends format and SSP words first, then the stacked frame words in file order.
    always_comb begin
        ctx_data = frame_data;
        if (field_no == 6'd0) begin ctx_idx = 6'd0; ctx_data = FORMAT_ID; end
        else if (field_no == 6'd1) begin ctx_idx = 6'd33; ctx_data = arch_ssp[31:16]; end
        else if (field_no == 6'd2) begin ctx_idx = 6'd34; ctx_data = arch_ssp[15:0]; end
        else if (field_no < 6'd5) ctx_idx = field_no + 6'd28;
        else if (field_no < 6'd35) ctx_idx = field_no - 6'd4;
        else ctx_idx = field_no;
    end

    always_ff @(posedge clk) begin
        done <= 1'b0;
        if (reset) begin
            state <= IDLE;
            ok <= 1'b0;
            code <= 4'd0;
            ssp_addr <= 32'd0;
            ram_addr <= 32'd0;
            next_frame_addr <= 32'd0;
            arch_ssp <= 32'd0;
            field_no <= 6'd0;
            frame_data <= 16'd0;
            waited <= 4'd0;
        end else case (state)
            IDLE: if (start) begin
                ok <= 1'b0;
                code <= 4'd0;
                ssp_addr <= ssp_offset;
                ram_addr <= wram_offset;
                field_no <= 6'd0;
                if (wram_words != 32'd32768 || ssp_offset[2:0] != 3'd0 ||
                    wram_offset[2:0] != 3'd0 || wram_offset > 32'hfffc0000) begin
                    done <= 1'b1;
                    code <= BAD_IMAGE;
                end else state <= BEGIN_BANK;
            end
            BEGIN_BANK, ADMIT: begin
                waited <= 4'd0;
                state <= state == BEGIN_BANK ? WAIT_BANK : WAIT_ADMIT;
            end
            WAIT_BANK, WAIT_ADMIT: begin
                if (rsp_valid) begin
                    if (!rsp_ok || (state == WAIT_ADMIT && !admitted)) begin
                        code <= rsp_ok ? BAD_PORT : rsp_code;
                        done <= 1'b1;
                        state <= IDLE;
                    end else if (state == WAIT_BANK) state <= READ_SSP;
                    else begin ok <= 1'b1; done <= 1'b1; state <= IDLE; end
                end else if (&waited) begin
                    code <= BAD_PORT; done <= 1'b1; state <= IDLE;
                end else waited <= waited + 4'd1;
            end
            READ_SSP: if (rd_idle) state <= WAIT_SSP;
            WAIT_SSP: if (rd_done) begin
                if (rd_data[63:32] != 32'd0 || rd_data[0] ||
                    rd_data[23:0] < WRAM_LO || rd_data[23:0] > WRAM_LAST_FRAME) begin
                    code <= BAD_IMAGE; done <= 1'b1; state <= IDLE;
                end else begin
                    arch_ssp <= rd_data[31:0] + 32'd70;
                    next_frame_addr <= ram_addr + {14'd0, rd_data[15:1], 3'b000};
                    state <= SEND_FIELD;
                end
            end
            READ_FRAME: if (rd_idle) state <= WAIT_FRAME;
            WAIT_FRAME: if (rd_done) begin
                if (rd_data[63:16] != 48'd0) begin
                    code <= BAD_IMAGE; done <= 1'b1; state <= IDLE;
                end else begin
                    frame_data <= rd_data[15:0];
                    next_frame_addr <= next_frame_addr + 32'd8;
                    state <= SEND_FIELD;
                end
            end
            SEND_FIELD: begin waited <= 4'd0; state <= WAIT_FIELD; end
            WAIT_FIELD: begin
                if (ctx_nak || (&waited && !ctx_ack)) begin
                    code <= BAD_PORT; done <= 1'b1; state <= IDLE;
                end else if (ctx_ack) begin
                    field_no <= field_no + 6'd1;
                    if (field_no == 6'd37) state <= ADMIT;
                    else if (field_no < 6'd2) state <= SEND_FIELD;
                    else state <= READ_FRAME;
                end else waited <= waited + 4'd1;
            end
            default: begin code <= BAD_PORT; done <= 1'b1; state <= IDLE; end
        endcase
    end
endmodule
`default_nettype wire

// Save-state chunk: 38 context words, four per 64-bit item; loads fill the restore bank and admit it.
`timescale 1ns/1ps
`default_nettype none
module rzctx_packed_chunk
    import rzctx_pkg::*;
(
    input logic clk, reset,
    input logic select, query, read_item,
    input logic [31:0] item,
    input logic captured,
    output logic ack,
    output logic [63:0] item_data,
    input logic load_start,
    input logic [31:0] load_offset,
    output logic load_done, load_ok,
    output logic rd_req,
    output logic [31:0] rd_addr,
    input logic rd_idle, rd_done,
    input logic [63:0] rd_data,
    output logic cmd_valid,
    output logic [2:0] cmd_op,
    input logic rsp_valid, rsp_ok, admitted,
    output logic ctx_req, ctx_we,
    output logic [5:0] ctx_idx,
    output logic [15:0] ctx_wdata,
    input logic ctx_ack, ctx_nak,
    input logic [15:0] ctx_rdata
);
    typedef enum logic [3:0] {
        IDLE, SAVE_SEND, SAVE_WAIT, SAVE_ACK, LOAD_BEGIN, LOAD_BANK,
        LOAD_READ, LOAD_DATA, LOAD_SEND, LOAD_WAIT, LOAD_ADMIT, LOAD_RESULT
    } state_t;
    state_t state;
    logic [5:0] word_idx;
    logic [63:0] lanes;
    logic [3:0] waited;

    assign cmd_valid = state == LOAD_BEGIN || state == LOAD_ADMIT;
    assign cmd_op = state == LOAD_BEGIN ? OP_LOAD : OP_ADMIT;
    assign ctx_req = state == SAVE_SEND || state == LOAD_SEND;
    assign ctx_we = state == LOAD_SEND;
    assign ctx_idx = word_idx;
    assign ctx_wdata = lanes[{word_idx[1:0],4'b0000}+:16];
    assign rd_req = state == LOAD_READ && rd_idle;

    always_ff @(posedge clk) begin
        load_done <= 1'b0;
        if (reset) begin
            state <= IDLE;
            ack <= 1'b0;
            item_data <= 64'd0;
            load_ok <= 1'b0;
            rd_addr <= 32'd0;
            word_idx <= 6'd0;
            waited <= 4'd0;
            lanes <= 64'd0;
        end else case (state)
            IDLE: if (load_start) begin
                load_ok <= 1'b0;
                word_idx <= 6'd0;
                rd_addr <= load_offset;
                if (load_offset[2:0] != 3'd0 || load_offset > 32'hffffffb0)
                    load_done <= 1'b1;
                else state <= LOAD_BEGIN;
            end else if (select && query) begin
                item_data <= {8'd1,22'd0,2'd3,32'd10};
                ack <= 1'b1;
                state <= SAVE_ACK;
            end else if (select && read_item && captured && item < 32'd10) begin
                word_idx <= {item[3:0],2'b00};
                lanes <= 64'd0;
                state <= SAVE_SEND;
            end
            SAVE_SEND, LOAD_SEND: begin
                waited <= 4'd0;
                state <= state == SAVE_SEND ? SAVE_WAIT : LOAD_WAIT;
            end
            SAVE_WAIT: if (!select || !read_item || !captured || ctx_nak || (&waited && !ctx_ack))
                state <= IDLE;
            else if (ctx_ack) begin
                lanes[{word_idx[1:0],4'b0000}+:16] <= ctx_rdata;
                if (word_idx[1:0] == 2'd3 || word_idx == 6'd37) begin
                    ack <= 1'b1;
                    item_data <= lanes | (64'(ctx_rdata) << {word_idx[1:0],4'b0000});
                    state <= SAVE_ACK;
                end else begin word_idx <= word_idx + 6'd1; state <= SAVE_SEND; end
            end else waited <= waited + 4'd1;
            SAVE_ACK: if (!select || !(read_item || query)) begin ack <= 1'b0; state <= IDLE; end
            LOAD_BEGIN, LOAD_ADMIT: begin
                waited <= 4'd0;
                state <= state == LOAD_BEGIN ? LOAD_BANK : LOAD_RESULT;
            end
            LOAD_BANK, LOAD_RESULT: if (rsp_valid) begin
                if (state == LOAD_BANK && rsp_ok) state <= LOAD_READ;
                else begin
                    load_ok <= state == LOAD_RESULT && rsp_ok && admitted;
                    load_done <= 1'b1;
                    state <= IDLE;
                end
            end else if (&waited) begin load_done <= 1'b1; state <= IDLE; end
            else waited <= waited + 4'd1;
            LOAD_READ: if (rd_idle) state <= LOAD_DATA;
            LOAD_DATA: if (rd_done) begin
                if (word_idx == 6'd36 && rd_data[63:32] != 32'd0) begin
                    load_done <= 1'b1;
                    state <= IDLE;
                end else begin lanes <= rd_data; rd_addr <= rd_addr + 32'd8; state <= LOAD_SEND; end
            end
            LOAD_WAIT: if (ctx_nak || (&waited && !ctx_ack)) begin
                load_done <= 1'b1;
                state <= IDLE;
            end else if (ctx_ack) begin
                word_idx <= word_idx + 6'd1;
                if (word_idx == 6'd37) state <= LOAD_ADMIT;
                else state <= word_idx[1:0] == 2'd3 ? LOAD_READ : LOAD_SEND;
            end else waited <= waited + 4'd1;
            default: state <= IDLE;
        endcase
    end
endmodule
`default_nettype wire

// Interrupt profile table for the main-CPU interrupt owner.
`timescale 1ns/1ps
package rzirq_pkg;
  // profile codes (PROFILE parameter); any other value is inert
  localparam int RZIRQ_GAREGGA  = 1;
  localparam int RZIRQ_SORCER   = 2;
  localparam int RZIRQ_KINGDOM  = 3;
  localparam int RZIRQ_BATRIDER = 4;
  localparam int RZIRQ_BAKRAID  = 5;

  // video modes
  localparam int VM_NONE    = 0;   // inert profile
  localparam int VM_SAMPLED = 1;   // pending follows the sampled video line (Garegga)
  localparam int VM_EDGE    = 2;   // pending set on the falling edge, cleared by IACK (Sorcer, Kingdom)
  localparam int VM_DIRECT  = 3;   // request is the live video line (Batrider, Bakraid)

  // owned logical state fields (bits of owned_fields)
  localparam int F_VIDEO_PENDING    = 0;
  localparam int F_PREVIOUS_VIDEO_N = 1;
  localparam int F_SOUND_PENDING    = 2;

  function automatic bit prof_supported(input int p);
    prof_supported = (p >= RZIRQ_GAREGGA) && (p <= RZIRQ_BAKRAID);
  endfunction

  function automatic int prof_video_mode(input int p);
    case (p)
      RZIRQ_GAREGGA:                 prof_video_mode = VM_SAMPLED;
      RZIRQ_SORCER, RZIRQ_KINGDOM:   prof_video_mode = VM_EDGE;
      RZIRQ_BATRIDER, RZIRQ_BAKRAID: prof_video_mode = VM_DIRECT;
      default:                       prof_video_mode = VM_NONE;
    endcase
  endfunction

  // 1 = raw_lvbl_n, 0 = gp_vint_n
  function automatic bit prof_video_raw(input int p);
    prof_video_raw = (p == RZIRQ_KINGDOM);
  endfunction

  function automatic logic [2:0] prof_video_level(input int p);
    case (p)
      RZIRQ_GAREGGA, RZIRQ_SORCER, RZIRQ_KINGDOM: prof_video_level = 3'd4;
      RZIRQ_BATRIDER:                             prof_video_level = 3'd2;
      RZIRQ_BAKRAID:                              prof_video_level = 3'd1;
      default:                                    prof_video_level = 3'd0;
    endcase
  endfunction

  // 0 = the profile has no sound interrupt
  function automatic logic [2:0] prof_sound_level(input int p);
    case (p)
      RZIRQ_BATRIDER: prof_sound_level = 3'd4;
      RZIRQ_BAKRAID:  prof_sound_level = 3'd2;
      default:        prof_sound_level = 3'd0;
    endcase
  endfunction

  function automatic logic [2:0] prof_fields(input int p);
    case (p)
      RZIRQ_GAREGGA:                 prof_fields = 3'b001;   // video_pending
      RZIRQ_SORCER, RZIRQ_KINGDOM:   prof_fields = 3'b011;   // video_pending, previous_video_n
      RZIRQ_BATRIDER, RZIRQ_BAKRAID: prof_fields = 3'b100;   // sound_pending
      default:                       prof_fields = 3'b000;
    endcase
  endfunction
endpackage

// Main-CPU interrupt owner: pending state, level encoding and autovector acknowledge per profile.
`timescale 1ns/1ps
module rzirq_owner
  import rzirq_pkg::*;
#(
  parameter int PROFILE = RZIRQ_GAREGGA
)(
  input  logic       clk,
  input  logic       board_reset,           // synchronous, active high
  input  logic       alt_levels,            // Batrider profile run as Bakraid: video level 1, sound 2
  input  logic       state_hold,            // architectural state hold: stored fields do not evolve
  input  logic       state_load,            // load saved fields; applied only during state_hold
  input  logic       load_video_pending,    // logical saved fields, used by state_load
  input  logic       load_previous_video_n,
  input  logic       load_sound_pending,
  input  logic       gp_vint_n,             // GP VINT, active low
  input  logic       raw_lvbl_n,            // raw vertical blank, active low
  input  logic       sound_irq,             // qualified SYS-domain sound IRQ event
  input  logic       sound_clear,           // qualified SYS-domain decoded sound clear
  input  logic       priv_l7,               // private level-7 request (state service)
  input  logic       cpu_as_n,
  input  logic [2:0] cpu_fc,
  input  logic [3:1] cpu_a,
  output logic [2:0] irq_level,             // encoded logical level, 0 = none
  output logic [2:0] ipl_n,                 // active-low IPL2:0, idle 111
  output logic       vpa_n,                 // active-low autovector qualifier: AS low and FC = 7
  output logic       cpu_space,             // the same qualifier, active high
  output logic       video_pending,         // logical fields (constant reset value when not owned)
  output logic       previous_video_n,
  output logic       sound_pending,
  output logic [2:0] owned_fields,          // [0] video_pending [1] previous_video_n [2] sound_pending
  output logic       unsupported            // PROFILE is not one of the five profiles: block inert
);
  localparam bit         SUP   = prof_supported(PROFILE);
  localparam int         VMODE = prof_video_mode(PROFILE);
  localparam bit         VRAW  = prof_video_raw(PROFILE);
  localparam logic [2:0] VLVL  = prof_video_level(PROFILE);
  localparam logic [2:0] SLVL  = prof_sound_level(PROFILE);
  localparam logic [2:0] OWN   = prof_fields(PROFILE);
  // alt_levels selects Bakraid's video and sound levels in the Batrider profile.
  wire alt = PROFILE == RZIRQ_BATRIDER && alt_levels;
  wire [2:0] vlvl = alt ? prof_video_level(RZIRQ_BAKRAID) : VLVL;
  wire [2:0] slvl = alt ? prof_sound_level(RZIRQ_BAKRAID) : SLVL;

  wire video_n = VRAW ? raw_lvbl_n : gp_vint_n;

  // CPU space: AS low with FC = 7 (no data strobe required).
  wire space      = SUP && !cpu_as_n && (cpu_fc == 3'b111);
  wire iack_video = space && (cpu_a == vlvl);

  logic vp_q, hist_q, sp_q;
  always_ff @(posedge clk) begin
    if (board_reset) begin
      vp_q   <= 1'b0;
      hist_q <= 1'b1;
      sp_q   <= 1'b0;
    end else if (state_hold) begin
      if (state_load) begin
        if (OWN[F_VIDEO_PENDING])    vp_q   <= load_video_pending;
        if (OWN[F_PREVIOUS_VIDEO_N]) hist_q <= load_previous_video_n;
        if (OWN[F_SOUND_PENDING])    sp_q   <= load_sound_pending;
      end
    end else begin
      if (VMODE == VM_SAMPLED) vp_q <= ~video_n;
      if (VMODE == VM_EDGE) begin
        if (iack_video)              vp_q <= 1'b0;   // a matching clear beats a new edge
        else if (hist_q && !video_n) vp_q <= 1'b1;
        hist_q <= video_n;                           // history advances either way
      end
      if (OWN[F_SOUND_PENDING]) begin
        if (sound_clear)    sp_q <= 1'b0;            // clear wins over a simultaneous event
        else if (sound_irq) sp_q <= 1'b1;
      end
    end
  end

  wire vreq = (VMODE == VM_DIRECT) ? !video_n : vp_q;
  wire sreq = OWN[F_SOUND_PENDING] && sp_q;
  logic [2:0] lvl;
  generate
    if (SUP) begin : g_encode
      // highest requested level wins; private level 7 is above everything
      always_comb begin
        lvl = 3'd0;
        if (vreq && vlvl > lvl) lvl = vlvl;
        if (sreq && slvl > lvl) lvl = slvl;
        if (priv_l7)            lvl = 3'd7;
      end
    end else begin : g_inert
      assign lvl = 3'd0;     // unknown profile: no request of any kind
    end
  endgenerate

  assign irq_level        = lvl;
  assign ipl_n            = ~lvl;
  assign cpu_space        = space;
  assign vpa_n            = ~space;
  assign video_pending    = vp_q;
  assign previous_video_n = hist_q;
  assign sound_pending    = sp_q;
  assign owned_fields     = OWN;
  assign unsupported      = !SUP;

  // Lint sink for inputs unused by some profiles.
  wire unused_inputs = &{1'b0, gp_vint_n, raw_lvbl_n, sound_irq, sound_clear, load_video_pending,
                         load_previous_video_n, load_sound_pending, priv_l7, vreq, sreq};
endmodule

// Schedules 68000 phase enables and asserts DTACK for ready transfers on the first eligible phase.
module raizing_68k_bus (
    input clk, reset, run,
    input address_n,
    input [1:0] strobe_n,
    input selected, busy,
    output phase1, phase2, phase1_pending,
    output reg dtack_n
);
    reg [7:0] residue = 0;
    reg last_phase = 1, raw_phase1 = 0, raw_phase2 = 0;
    reg [13:0] owed_phases = 0;
    wire consumed = phase1 || phase2;
    wire following_phase = consumed ? !phase1 : !last_phase;
    wire [8:0] sum = {1'b0, residue} + 9'd64;
    wire scheduled = run && sum > 9'd162;
    wire transfer = !address_n && !(&strobe_n);
    wire repay = run && owed_phases != 0 && !scheduled && (!transfer || !dtack_n);
    reg transfer_previous = 0, prepared = 0, sampled_dtack_n = 1;
    reg [2:0] transfer_phases = 0, wait_phase = 0;
    reg first_phase = 1;
    wire missed_sample = transfer && transfer_previous && phase1 && sampled_dtack_n &&
                         transfer_phases >= wait_phase;
    wire [14:0] debt_sum = {1'b0, owed_phases} + (missed_sample ? 15'd2 : 15'd0) -
                          (repay ? 15'd1 : 15'd0);
    assign phase1_pending = raw_phase1;
    assign phase1 = raw_phase1 && run;
    assign phase2 = raw_phase2 && run;

    always @(posedge clk) begin
        if (reset) residue <= 0;
        else if (run) residue <= 8'(scheduled ? sum - 9'd162 : sum);
        raw_phase1 <= 0;
        raw_phase2 <= 0;
        if (consumed) last_phase <= phase1;
        if (reset || scheduled || repay) begin
            raw_phase1 <= following_phase;
            raw_phase2 <= !following_phase;
        end
        if (reset) owed_phases <= 0;
        else owed_phases <= debt_sum[14] ? 14'h3fff : debt_sum[13:0];
        if (reset) begin
            transfer_previous <= 0;
            prepared <= 0;
            transfer_phases <= 0;
            wait_phase <= 0;
            sampled_dtack_n <= 1;
        end else if (run) begin
            if (phase2) sampled_dtack_n <= dtack_n;
            transfer_previous <= transfer;
            prepared <= !address_n && (&strobe_n);
            if (transfer) begin
                if (!transfer_previous) begin
                    wait_phase <= prepared ? 3'd1 : 3'd3;
                    transfer_phases <= {2'd0, consumed};
                end else if (consumed && transfer_phases != 3'd7)
                    transfer_phases <= transfer_phases + 3'd1;
            end
        end
        if (reset || address_n || (&strobe_n)) begin
            dtack_n <= 1;
            first_phase <= 1;
        end else if (run) begin
            if (phase1) first_phase <= 0;
            if ((!first_phase || phase1) && (!selected || !busy)) dtack_n <= 0;
        end
    end
endmodule
