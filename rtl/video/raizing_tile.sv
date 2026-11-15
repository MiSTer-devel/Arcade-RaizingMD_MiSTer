// SPDX-License-Identifier: GPL-3.0-or-later
// GP9001 tile-row producer.

package rztile_pkg;
  // Profile IDs and ROM half sizes; unsupported profiles reject every line.
  localparam int PROFILE_SORCER   = 0;   // half 0x100000
  localparam int PROFILE_KINGDOM  = 1;   // half 0x200000
  localparam int PROFILE_GAREGGA  = 2;   // half 0x400000
  localparam int PROFILE_BATRIDER = 3;   // half 0x800000, banked
  localparam int PROFILE_BAKRAID  = 4;   // half 0x800000, banked

  localparam int PIXELS_PER_PLANE = 320;

  typedef enum logic [1:0] {
    ST_COMPLETE  = 2'd0,  // all 960 samples accepted
    ST_CANCELLED = 2'd1,  // flushed; remaining samples suppressed
    ST_REJECTED  = 2'd2,  // unknown profile; no request, no sample
    ST_FAULTED   = 2'd3   // aborted on a same-edge or wrong-tag response
  } status_e;
endpackage

// Graphics row byte address in a ROM half: 16*group + 2*row, group = {code, qy, qx} wrapped to the half.
module rztile_gfxaddr #(
  parameter int PROFILE = 2
) (
  input  logic [1:0] narrow,   // ROM geometry: 0 native, 1 Sorcer, 2 Kingdom, 3 Garegga
  input  logic [15:0] code,
  input  logic        qx,
  input  logic        qy,
  input  logic [2:0]  row,
  input  logic [31:0] banks,   // entry i at [4i+3:4i]
  output logic [22:0] addr
);
  import rztile_pkg::*;
  localparam int HALF_BITS = (PROFILE == PROFILE_SORCER)   ? 20 :
                             (PROFILE == PROFILE_KINGDOM)  ? 21 :
                             (PROFILE == PROFILE_GAREGGA)  ? 22 :
                             (PROFILE == PROFILE_BATRIDER) ? 23 :
                             (PROFILE == PROFILE_BAKRAID)  ? 23 : 0;
  localparam bit BANKED     = (PROFILE == PROFILE_BATRIDER) || (PROFILE == PROFILE_BAKRAID);
  localparam int GROUP_BITS = (HALF_BITS > 4) ? (HALF_BITS - 4) : 0;
  localparam logic [18:0] WRAP_MASK = (GROUP_BITS >= 19) ? 19'h7ffff :
                                      ((19'd1 << GROUP_BITS) - 19'd1);

  logic [17:0] g18;
  logic [2:0]  bank_sel;
  logic [3:0]  bank;
  logic [18:0] g19, group;

  assign g18      = {code, qy, qx};
  assign bank_sel = g18[17:15];
  assign bank     = banks[4*bank_sel +: 4];
  // Batrider/Bakraid native geometry replaces group bits 18:15 with the selected bank.
  assign g19      = (BANKED && narrow == 2'd0) ? {bank, g18[14:0]} : {1'b0, g18};
  // Sorcer's 1 MiB halves keep 16 group bits, Kingdom's 2 MiB 17, Garegga's 4 MiB 18.
  wire [18:0] wrap_mask = narrow == 2'd1 ? (19'h0ffff & WRAP_MASK) :
                          narrow == 2'd2 ? (19'h1ffff & WRAP_MASK) :
                          narrow == 2'd3 ? (19'h3ffff & WRAP_MASK) : WRAP_MASK;
  assign group    = g19 & wrap_mask;
  assign addr     = {group, row, 1'b0};
endmodule

// Decodes raw = {H1[a+1], H1[a], H0[a+1], H0[a]} into eight pens; pixel k takes bit 7-k of each byte.
module rztile_rowdec (
  input  logic [31:0] raw,
  output logic [31:0] pens   // pens[4k+3:4k] = pen of pixel k
);
  genvar k;
  generate
    for (k = 0; k < 8; k++) begin : g_pix
      assign pens[4*k+3] = raw[31-k];
      assign pens[4*k+2] = raw[23-k];
      assign pens[4*k+1] = raw[15-k];
      assign pens[4*k+0] = raw[7-k];
    end
  endgenerate
endmodule

// Fetches and emits one tile plane's 320-pixel line, one graphics read per group of up to 8 pixels.
module rztile_plane #(
  parameter int PROFILE    = 2,
  parameter bit CHECK_TAGS = 1'b1
) (
  input  logic [1:0] narrow,   // ROM geometry: 0 native, 1 Sorcer, 2 Kingdom, 3 Garegga
  input  logic        clk,
  input  logic        rst,
  // job snapshot and control
  input  logic        clear,          // pulse: job accepted, clear counts
  input  logic        start,          // pulse: begin the line
  input  logic        cancel,         // level: suppress output, retire, go idle
  input  logic [8:0]  x0,
  input  logic [8:0]  y,
  input  logic        dir,            // 0: +1 per destination pixel, 1: -1
  input  logic [31:0] banks,
  // descriptor service (this plane's port, one outstanding)
  output logic        desc_req_valid,
  input  logic        desc_req_ready,
  output logic [9:0]  desc_req_index,
  output logic [3:0]  desc_req_tag,
  input  logic        desc_rsp_valid,
  output logic        desc_rsp_ready,
  input  logic [31:0] desc_rsp_pair,  // {code, attr}
  input  logic [3:0]  desc_rsp_tag,
  // graphics request through the parent's arbiter
  output logic        gfx_want,
  output logic [22:0] gfx_addr,
  input  logic        gfx_grant,      // this plane's request fired this cycle
  input  logic        gfx_rsp_fire,   // this plane's response is on gfx_rsp_data now
  input  logic [31:0] gfx_rsp_data,
  // pixel output channel
  output logic        pix_valid,
  input  logic        pix_ready,
  output logic [8:0]  pix_d,
  output logic        pix_opaque,
  output logic [3:0]  pix_rank,
  output logic [10:0] pix_index,
  // status
  output logic        fetch_idle,     // fetch FSM idle, no descriptor outstanding
  output logic [8:0]  accepted,
  output logic        line_done,      // accepted == 320
  output logic        f_desc_stray,   // fault pulses
  output logic        f_desc_tag,
  output logic        f_desc_edge,
  output logic        abort_req       // same-edge or wrong-tag response: parent faults the job
);
  import rztile_pkg::*;

  // ---------------------------------------------------------------- fetch
  typedef enum logic [2:0] {
    F_IDLE  = 3'd0,
    F_NEXT  = 3'd1,
    F_DESC  = 3'd2,
    F_DWAIT = 3'd3,
    F_GFX   = 3'd4,
    F_GWAIT = 3'd5,
    F_PUSH  = 3'd6
  } fstate_e;

  fstate_e     fstate;
  logic [8:0]  sx;          // source x of the current group's first pixel
  logic [8:0]  rem;         // destination pixels still to fetch (320..0)
  logic [8:0]  dst;         // destination position of the current group
  logic [9:0]  cur_cell;
  logic        have_desc;
  logic [6:0]  bank_q;      // attr[6:0]
  logic [3:0]  rank_q;      // attr[11:8]
  logic [15:0] code_q;      // pair[31:16]
  logic        desc_out;
  logic [3:0]  desc_out_tag, desc_seq;

  // per-group combinational values
  logic [9:0]  cell_idx;
  logic [2:0]  p0;
  logic [3:0]  span, count;
  logic [8:0]  sx_next;
  logic        need_desc;
  // Map cell index {row, column} wraps at 32x32 cells.
  assign cell_idx  = {y[8:4], sx[8:4]};
  assign p0        = sx[2:0];
  assign span      = dir ? ({1'b0, p0} + 4'd1) : (4'd8 - {1'b0, p0});
  assign count     = (rem < {5'd0, span}) ? rem[3:0] : span;
  assign sx_next   = dir ? (sx - {5'd0, count}) : (sx + {5'd0, count});
  assign need_desc = !have_desc || (cell_idx != cur_cell);

  rztile_gfxaddr #(.PROFILE(PROFILE)) u_addr (
      .narrow(narrow),
    .code  (code_q),
    .qx    (sx[3]),
    .qy    (y[3]),
    .row   (y[2:0]),
    .banks (banks),
    .addr  (gfx_addr)
  );
  assign gfx_want = (fstate == F_GFX) && !cancel;

  // descriptor port: request held until accepted; response always consumable
  logic desc_req_fire, dtag_match, drsp_take;
  assign desc_req_valid = (fstate == F_DESC);
  assign desc_req_index = cell_idx;
  assign desc_req_tag   = desc_seq;
  assign desc_rsp_ready = 1'b1;
  assign desc_req_fire  = desc_req_valid && desc_req_ready;
  assign dtag_match     = !CHECK_TAGS || (desc_rsp_tag == desc_out_tag);
  assign drsp_take      = desc_rsp_valid && desc_out && (dtag_match || cancel);
  assign f_desc_tag     = desc_rsp_valid && desc_out && !dtag_match;
  assign f_desc_stray   = desc_rsp_valid && !desc_out && !desc_req_fire;
  assign f_desc_edge    = desc_rsp_valid && !desc_out && desc_req_fire;
  assign abort_req      = f_desc_edge || (f_desc_tag && !cancel);
  assign fetch_idle     = (fstate == F_IDLE) && !desc_out;

  // Attribute bits 15:12 and 7 are unused.
  /* verilator lint_off UNUSEDSIGNAL */
  logic [4:0] attr_unmodeled;
  assign attr_unmodeled = {desc_rsp_pair[15:12], desc_rsp_pair[7]};
  /* verilator lint_on UNUSEDSIGNAL */

  // FIFO entry: {data[31:0], bank[6:0], rank[3:0], p0[2:0], count[3:0], dst[8:0]}
  localparam int EW = 32 + 7 + 4 + 3 + 4 + 9;
  logic          fin_valid, fin_ready, fout_valid, fout_ready;
  logic [EW-1:0] fin_data, fout_data, entry_now, entry_hold;

  assign entry_now = {gfx_rsp_data, bank_q, rank_q, p0, count, dst};
  assign fin_valid = !cancel && (((fstate == F_GWAIT) && gfx_rsp_fire) || (fstate == F_PUSH));
  assign fin_data  = (fstate == F_PUSH) ? entry_hold : entry_now;

  rztile_fifo2 #(.W(EW)) u_fifo (
    .clk       (clk),
    .rst       (rst),
    .clear     (cancel || clear),
    .in_valid  (fin_valid),
    .in_ready  (fin_ready),
    .in_data   (fin_data),
    .out_valid (fout_valid),
    .out_ready (fout_ready),
    .out_data  (fout_data)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      fstate       <= F_IDLE;
      desc_out     <= 1'b0;
      desc_out_tag <= 4'd0;
      desc_seq     <= 4'd0;
      have_desc    <= 1'b0;
      sx           <= 9'd0;
      rem          <= 9'd0;
      dst          <= 9'd0;
      cur_cell     <= 10'd0;
      bank_q       <= 7'd0;
      rank_q       <= 4'd0;
      code_q       <= 16'd0;
      entry_hold   <= '0;
    end else begin
      if (desc_req_fire) begin
        desc_seq <= desc_seq + 4'd1;
        if (!f_desc_edge) begin
          desc_out     <= 1'b1;
          desc_out_tag <= desc_seq;
        end
      end
      if (drsp_take || f_desc_tag) desc_out <= 1'b0;

      case (fstate)
        F_IDLE: begin
          if (start) begin
            sx        <= x0;
            rem       <= 9'(PIXELS_PER_PLANE);
            dst       <= 9'd0;
            have_desc <= 1'b0;
            fstate    <= F_NEXT;
          end
        end
        F_NEXT: begin
          if (cancel)           fstate <= F_IDLE;
          else if (rem == 9'd0) fstate <= F_IDLE;
          else if (need_desc)   fstate <= F_DESC;
          else                  fstate <= F_GFX;
        end
        F_DESC: begin
          // the request is never retracted, even under cancel
          if (desc_req_fire) begin
            if (f_desc_edge) fstate <= F_IDLE;
            else             fstate <= F_DWAIT;
          end
        end
        F_DWAIT: begin
          if (drsp_take) begin
            bank_q    <= desc_rsp_pair[6:0];
            rank_q    <= desc_rsp_pair[11:8];
            code_q    <= desc_rsp_pair[31:16];
            cur_cell  <= cell_idx;
            have_desc <= 1'b1;
            if (cancel) fstate <= F_IDLE;
            else        fstate <= F_GFX;
          end else if (f_desc_tag) begin
            fstate <= F_IDLE;             // retired by fault; parent aborts
          end
        end
        F_GFX: begin
          if (cancel)         fstate <= F_IDLE;
          else if (gfx_grant) fstate <= F_GWAIT;
        end
        F_GWAIT: begin
          if (cancel) fstate <= F_IDLE;      // the arbiter retires the response
          else if (gfx_rsp_fire) begin
            if (fin_ready) begin
              sx     <= sx_next;
              rem    <= rem - {5'd0, count};
              dst    <= dst + {5'd0, count};
              fstate <= F_NEXT;
            end else begin
              entry_hold <= entry_now;
              fstate     <= F_PUSH;
            end
          end
        end
        F_PUSH: begin
          if (cancel) fstate <= F_IDLE;
          else if (fin_ready) begin
            sx     <= sx_next;
            rem    <= rem - {5'd0, count};
            dst    <= dst + {5'd0, count};
            fstate <= F_NEXT;
          end
        end
        default: fstate <= F_IDLE;
      endcase
    end
  end

  // ----------------------------------------------------------------- emit
  logic [31:0] e_data, pens;
  logic [6:0]  e_bank;
  logic [3:0]  e_rank, e_count, pen;
  logic [2:0]  e_p0, i, k;
  logic [8:0]  e_dst, acc;
  logic        pix_fire, last;

  assign e_dst   = fout_data[8:0];
  assign e_count = fout_data[12:9];
  assign e_p0    = fout_data[15:13];
  assign e_rank  = fout_data[19:16];
  assign e_bank  = fout_data[26:20];
  assign e_data  = fout_data[58:27];

  rztile_rowdec u_dec (.raw(e_data), .pens(pens));

  assign k          = dir ? (e_p0 - i) : (e_p0 + i);
  assign pen        = pens[4*k +: 4];
  assign pix_valid  = fout_valid && !cancel;
  assign pix_d      = e_dst + {6'd0, i};
  assign pix_opaque = (pen != 4'd0);
  assign pix_rank   = e_rank;
  assign pix_index  = {e_bank, pen};
  assign pix_fire   = pix_valid && pix_ready;
  assign last       = ({1'b0, i} == (e_count - 4'd1));
  assign fout_ready = pix_fire && last;

  always_ff @(posedge clk) begin
    if (rst) begin
      i   <= 3'd0;
      acc <= 9'd0;
    end else if (clear) begin
      i   <= 3'd0;
      acc <= 9'd0;
    end else if (cancel) begin
      i   <= 3'd0;
    end else if (pix_fire) begin
      i   <= last ? 3'd0 : (i + 3'd1);
      acc <= acc + 9'd1;
    end
  end

  assign accepted  = acc;
  assign line_done = (acc == 9'(PIXELS_PER_PLANE));
endmodule

// Two-entry register FIFO with valid/ready on both ports; clear empties it.
module rztile_fifo2 #(
  parameter int W = 8
) (
  input  logic         clk,
  input  logic         rst,
  input  logic         clear,
  input  logic         in_valid,
  output logic         in_ready,
  input  logic [W-1:0] in_data,
  output logic         out_valid,
  input  logic         out_ready,
  output logic [W-1:0] out_data
);
  logic [W-1:0] d0, d1;
  logic         v0, v1;
  logic         push, pop;

  assign out_valid = v0;
  assign out_data  = d0;
  assign in_ready  = !v1;
  assign push      = in_valid && in_ready;
  assign pop       = out_valid && out_ready;

  always_ff @(posedge clk) begin
    if (rst || clear) begin
      v0 <= 1'b0;
      v1 <= 1'b0;
    end else begin
      if (push && pop) begin
        d0 <= in_data;            // v1 is 0 whenever push is possible
      end else if (push) begin
        if (!v0) begin d0 <= in_data; v0 <= 1'b1; end
        else     begin d1 <= in_data; v1 <= 1'b1; end
      end else if (pop) begin
        if (v1) begin d0 <= d1; v1 <= 1'b0; end
        else     v0 <= 1'b0;
      end
    end
  end
endmodule

// Produces three tile-plane pixel streams for one line job over a shared round-robin graphics port.
module rztile_producer #(
  parameter int PROFILE    = 2,     // 0 sorcer,1 kingdom,2 garegga,3 batrider,4 bakraid
  parameter int TAGW       = 8,     // caller-owned job tag width
  parameter bit CHECK_TAGS = 1'b1   // compare echoed response tags
) (
  input  logic [1:0] narrow,   // ROM geometry: 0 native, 1 Sorcer, 2 Kingdom, 3 Garegga
  input  logic              clk,
  input  logic              rst,       // synchronous, active high
  // job admission
  input  logic              job_valid,
  output logic              job_ready,
  input  logic [TAGW-1:0]   job_tag,
  input  logic [26:0]       job_x0,    // plane p at [9p+8:9p]
  input  logic [26:0]       job_y,
  input  logic [2:0]        job_dir,   // 1 = -1 per destination pixel
  input  logic [31:0]       job_banks, // eight 4-bit Batrider/Bakraid bank values
  // descriptor services (plane p at slice p)
  output logic [2:0]        desc_req_valid,
  input  logic [2:0]        desc_req_ready,
  output logic [29:0]       desc_req_index,
  output logic [11:0]       desc_req_tag,
  input  logic [2:0]        desc_rsp_valid,
  output logic [2:0]        desc_rsp_ready,
  input  logic [95:0]       desc_rsp_pair,
  input  logic [11:0]       desc_rsp_tag,
  // shared graphics service
  output logic              gfx_req_valid,
  input  logic              gfx_req_ready,
  output logic [22:0]       gfx_req_addr,
  output logic [7:0]        gfx_req_tag,
  output logic [1:0]        gfx_req_plane,  // plane that owns the request
  input  logic              gfx_rsp_valid,
  output logic              gfx_rsp_ready,
  input  logic [31:0]       gfx_rsp_data,
  input  logic [7:0]        gfx_rsp_tag,
  // pixel channels (plane p at slice p)
  output logic [2:0]        pix_valid,
  input  logic [2:0]        pix_ready,
  output logic [3*TAGW-1:0] pix_tag,
  output logic [5:0]        pix_plane,
  output logic [26:0]       pix_d,
  output logic [2:0]        pix_opaque,
  output logic [11:0]       pix_rank,
  output logic [32:0]       pix_index,
  // completion
  output logic              done_valid,
  input  logic              done_ready,
  output logic [TAGW-1:0]   done_tag,
  output logic [1:0]        done_status,
  output logic [26:0]       done_accepted,
  output logic              done_any_accepted,
  output logic              done_fault_seen,
  // control and status
  input  logic              flush,     // suppress output, drain, report CANCELLED
  input  logic              quiesce,   // block admission
  output logic              idle,
  output logic              busy,
  output logic [12:0]       fault,     // sticky protocol faults
  input  logic              fault_ack
);
  import rztile_pkg::*;

  localparam bit KNOWN = (PROFILE == PROFILE_SORCER)   || (PROFILE == PROFILE_KINGDOM) ||
                         (PROFILE == PROFILE_GAREGGA)  || (PROFILE == PROFILE_BATRIDER) ||
                         (PROFILE == PROFILE_BAKRAID);

  typedef enum logic [1:0] {S_IDLE = 2'd0, S_RUN = 2'd1, S_CANCEL = 2'd2, S_DONE = 2'd3} state_e;
  state_e state;

  // ------------------------------------------------------------ snapshot
  logic [8:0]      x0_q [3];
  logic [8:0]      y_q  [3];
  logic            dir_q[3];
  logic [31:0]     banks_q;
  logic [TAGW-1:0] tag_q;
  status_e         status_q;
  logic            start_q, accept_q, cancel_q, fault_seen_q;
  logic            job_fire, done_fire;
  logic [12:0]     fault_pulse;
  logic            jv_q, jr_q, f_job_drop;

  assign job_ready = (state == S_IDLE) && !quiesce;
  assign job_fire  = job_valid && job_ready;
  assign done_fire = done_valid && done_ready;

  // -------------------------------------------------------------- planes
  logic [2:0]  p_want, p_grant, p_rsp_fire, p_fetch_idle, p_line_done;
  logic [2:0]  p_f_stray, p_f_tag, p_f_edge, p_abort;
  logic [22:0] p_addr [3];
  logic [8:0]  p_acc  [3];

  genvar p;
  generate
    for (p = 0; p < 3; p++) begin : g_plane
      rztile_plane #(.PROFILE(PROFILE), .CHECK_TAGS(CHECK_TAGS)) u_plane (
          .narrow(narrow),
        .clk            (clk),
        .rst            (rst),
        .clear          (accept_q),
        .start          (start_q),
        .cancel         (cancel_q),
        .x0             (x0_q[p]),
        .y              (y_q[p]),
        .dir            (dir_q[p]),
        .banks          (banks_q),
        .desc_req_valid (desc_req_valid[p]),
        .desc_req_ready (desc_req_ready[p]),
        .desc_req_index (desc_req_index[10*p +: 10]),
        .desc_req_tag   (desc_req_tag[4*p +: 4]),
        .desc_rsp_valid (desc_rsp_valid[p]),
        .desc_rsp_ready (desc_rsp_ready[p]),
        .desc_rsp_pair  (desc_rsp_pair[32*p +: 32]),
        .desc_rsp_tag   (desc_rsp_tag[4*p +: 4]),
        .gfx_want       (p_want[p]),
        .gfx_addr       (p_addr[p]),
        .gfx_grant      (p_grant[p]),
        .gfx_rsp_fire   (p_rsp_fire[p]),
        .gfx_rsp_data   (gfx_rsp_data),
        .pix_valid      (pix_valid[p]),
        .pix_ready      (pix_ready[p]),
        .pix_d          (pix_d[9*p +: 9]),
        .pix_opaque     (pix_opaque[p]),
        .pix_rank       (pix_rank[4*p +: 4]),
        .pix_index      (pix_index[11*p +: 11]),
        .fetch_idle     (p_fetch_idle[p]),
        .accepted       (p_acc[p]),
        .line_done      (p_line_done[p]),
        .f_desc_stray   (p_f_stray[p]),
        .f_desc_tag     (p_f_tag[p]),
        .f_desc_edge    (p_f_edge[p]),
        .abort_req      (p_abort[p])
      );
      assign pix_tag[TAGW*p +: TAGW] = tag_q;
      assign pix_plane[2*p +: 2]     = 2'(p);
      assign done_accepted[9*p +: 9] = p_acc[p];
    end
  endgenerate

  // ---------------------------------------------------- graphics arbiter
  logic        req_hold, gfx_out, gfx_req_fire, pick_valid;
  logic [1:0]  rr, pick, owner, hold_owner, req_owner;
  logic [22:0] hold_addr;
  logic [7:0]  out_tag, gfx_seq;
  logic        gtag_match, grsp_take, f_gfx_tag, f_gfx_stray, f_gfx_edge;

  // rotating priority starting at rr
  assign pick = (rr == 2'd0) ? (p_want[0] ? 2'd0 : (p_want[1] ? 2'd1 : 2'd2)) :
                (rr == 2'd1) ? (p_want[1] ? 2'd1 : (p_want[2] ? 2'd2 : 2'd0)) :
                               (p_want[2] ? 2'd2 : (p_want[0] ? 2'd0 : 2'd1));
  assign pick_valid    = |p_want;
  assign req_owner     = req_hold ? hold_owner : pick;
  assign gfx_req_valid = req_hold || (pick_valid && !gfx_out);
  assign gfx_req_addr  = req_hold ? hold_addr : p_addr[pick];
  assign gfx_req_tag   = gfx_seq;
  assign gfx_req_plane = req_owner;
  assign gfx_req_fire  = gfx_req_valid && gfx_req_ready;
  assign gfx_rsp_ready = 1'b1;
  assign gtag_match    = !CHECK_TAGS || (gfx_rsp_tag == out_tag);
  assign grsp_take     = gfx_rsp_valid && gfx_out && (gtag_match || cancel_q);
  assign f_gfx_tag     = gfx_rsp_valid && gfx_out && !gtag_match;
  assign f_gfx_stray   = gfx_rsp_valid && !gfx_out && !gfx_req_fire;
  assign f_gfx_edge    = gfx_rsp_valid && !gfx_out && gfx_req_fire;

  generate
    for (p = 0; p < 3; p++) begin : g_route
      assign p_grant[p]    = gfx_req_fire && (req_owner == 2'(p));
      assign p_rsp_fire[p] = grsp_take && (owner == 2'(p));
    end
  endgenerate

  always_ff @(posedge clk) begin
    if (rst) begin
      req_hold   <= 1'b0;
      gfx_out    <= 1'b0;
      rr         <= 2'd0;
      owner      <= 2'd0;
      hold_owner <= 2'd0;
      hold_addr  <= 23'd0;
      out_tag    <= 8'd0;
      gfx_seq    <= 8'd0;
    end else begin
      if (gfx_req_fire) begin
        gfx_seq  <= gfx_seq + 8'd1;
        req_hold <= 1'b0;
        rr       <= (req_owner == 2'd2) ? 2'd0 : (req_owner + 2'd1);
        if (!f_gfx_edge) begin
          gfx_out <= 1'b1;
          owner   <= req_owner;
          out_tag <= gfx_seq;
        end
      end else if (gfx_req_valid && !req_hold) begin
        req_hold   <= 1'b1;      // never retract an offered request
        hold_addr  <= gfx_req_addr;
        hold_owner <= req_owner;
      end
      if (grsp_take || f_gfx_tag) gfx_out <= 1'b0;   // retired, or retired by fault
    end
  end

  // ------------------------------------------------------------ job FSM
  logic abort_any, all_done, all_fetch_idle, drained;
  // same-edge or wrong-tag response on an outstanding request: abort (FAULTED)
  assign abort_any      = (|p_abort) || f_gfx_edge || (f_gfx_tag && !cancel_q);
  assign all_fetch_idle = &p_fetch_idle;
  assign drained        = all_fetch_idle && !gfx_out && !req_hold;
  // Ignores stale line_done during the start pulse, before plane counts clear.
  assign all_done       = (&p_line_done) && drained && !start_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      state        <= S_IDLE;
      start_q      <= 1'b0;
      accept_q     <= 1'b0;
      cancel_q     <= 1'b0;
      status_q     <= ST_COMPLETE;
      fault_seen_q <= 1'b0;
      tag_q        <= '0;
      banks_q      <= 32'd0;
      for (int j = 0; j < 3; j++) begin
        x0_q[j]  <= 9'd0;
        y_q[j]   <= 9'd0;
        dir_q[j] <= 1'b0;
      end
    end else begin
      start_q  <= 1'b0;
      accept_q <= 1'b0;
      case (state)
        S_IDLE: begin
          if (job_fire) begin
            accept_q <= 1'b1;        // planes clear their counters next cycle
            tag_q   <= job_tag;
            banks_q <= job_banks;
            for (int j = 0; j < 3; j++) begin
              x0_q[j]  <= job_x0[9*j +: 9];
              y_q[j]   <= job_y[9*j +: 9];
              dir_q[j] <= job_dir[j];
            end
            fault_seen_q <= 1'b0;
            if (!KNOWN) begin
              // Unsupported profile: cancel, then report REJECTED.
              status_q <= ST_REJECTED;
              cancel_q <= 1'b1;
              state    <= S_CANCEL;
            end else if (flush) begin
              status_q <= ST_CANCELLED;
              cancel_q <= 1'b1;
              state    <= S_CANCEL;
            end else begin
              start_q <= 1'b1;
              state   <= S_RUN;
            end
          end
        end
        S_RUN: begin
          if (abort_any) begin
            status_q <= ST_FAULTED;
            cancel_q <= 1'b1;
            state    <= S_CANCEL;
          end else if (all_done) begin
            status_q <= ST_COMPLETE;
            state    <= S_DONE;
          end else if (flush) begin
            status_q <= ST_CANCELLED;
            cancel_q <= 1'b1;
            state    <= S_CANCEL;
          end
        end
        S_CANCEL: begin
          if (drained) begin
            cancel_q <= 1'b0;
            state    <= S_DONE;
          end
        end
        S_DONE: begin
          if (done_fire) state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
      if (fault_pulse != 13'd0) fault_seen_q <= 1'b1;
    end
  end

  assign done_valid        = (state == S_DONE);
  assign done_tag          = tag_q;
  assign done_status       = status_q;
  assign done_any_accepted = (p_acc[0] != 9'd0) || (p_acc[1] != 9'd0) || (p_acc[2] != 9'd0);
  assign done_fault_seen   = fault_seen_q;
  assign busy              = (state != S_IDLE);
  assign idle              = (state == S_IDLE) && drained;

  // ------------------------------------------------------------- faults
  always_ff @(posedge clk) begin
    if (rst) begin
      jv_q <= 1'b0;
      jr_q <= 1'b0;
    end else begin
      jv_q <= job_valid;
      jr_q <= job_ready;
    end
  end
  assign f_job_drop  = jv_q && !jr_q && !job_valid;
  assign fault_pulse = {f_job_drop, f_gfx_edge, f_gfx_tag, f_gfx_stray,
                        p_f_edge, p_f_tag, p_f_stray};

  always_ff @(posedge clk) begin
    if (rst) fault <= 13'd0;
    else     fault <= (fault_ack ? 13'd0 : fault) | fault_pulse;
  end
endmodule

// Combinational tile-plane map origins from scroll and reflection, addressing an unreflected 512x512 map.
`default_nettype none

module rztile_origin #(
    // 0 Sorcer, 1 Kingdom, 2 Garegga, 3 Batrider, 4 Bakraid; other values drive zero outputs.
    parameter integer PROFILE = -1
) (
  input  logic [1:0] narrow,   // ROM geometry: 0 native, 1 Sorcer, 2 Kingdom, 3 Garegga
    // Raw 16-bit scroll registers {P2Y, P2X, P1Y, P1X, P0Y, P0X}; only bits 8:0 are used.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [95:0] scroll,
    /* verilator lint_on UNUSEDSIGNAL */
    // Reflection flags in scroll register order.
    input  wire [5:0]  axis,
    // Output row of the job before any axis transform.
    input  wire [8:0]  render_y,
    // Per plane, 9 bits each, low plane first: {P2, P1, P0}.
    output wire [26:0] source_x,          // map column at physical column 0
    output wire [26:0] source_y,          // map row
    output wire [2:0]  source_descending, // X walks in decreasing map order
    output wire        profile_ok         // static valid-profile indication
);

    localparam PROFILE_VALID = (PROFILE >= 0) && (PROFILE <= 4);

    localparam SORCER_TRIM   = (PROFILE == 0);
    wire sorcer_trim = SORCER_TRIM || narrow == 2'd1;

    // Y biases, shared by all three planes.
    localparam [9:0] Y_NORMAL_BIAS  = 10'h1ef;
    localparam [9:0] Y_REFLECT_BIAS = 10'h210;

    // Last coordinate of the 512-entry map.
    localparam [9:0] MAP_LAST = 10'h1ff;

    assign profile_ok = PROFILE_VALID ? 1'b1 : 1'b0;

    genvar p;
    generate
        for (p = 0; p < 3; p = p + 1) begin : g_plane
            // Per-plane X biases.
            localparam [9:0] X_NORMAL_BIAS  = (p == 0) ? 10'h1d6 : (p == 1) ? 10'h1d8 : 10'h1da;
            localparam [9:0] X_REFLECT_BIAS = (p == 0) ? 10'h229 : (p == 1) ? 10'h227 : 10'h225;

            wire [8:0] raw_x  = scroll[32*p      +: 9];
            wire [8:0] raw_y  = scroll[32*p + 16 +: 9];
            wire       refl_x = axis[2*p];
            wire       refl_y = axis[2*p + 1];

            // Modulo 512: normal = s + raw - N, reflected = 511 - (s + F - raw); s = render_y for Y, 0 for X.
            /* verilator lint_off UNUSEDSIGNAL */
            wire [9:0] x_normal  = {1'b0, raw_x} - X_NORMAL_BIAS;
            wire [9:0] x_reflect = MAP_LAST - (X_REFLECT_BIAS - {1'b0, raw_x});
            wire [9:0] y_normal  = {1'b0, render_y} + {1'b0, raw_y} - Y_NORMAL_BIAS;
            wire [9:0] y_reflect = MAP_LAST - ({1'b0, render_y} + Y_REFLECT_BIAS - {1'b0, raw_y});
            /* verilator lint_on UNUSEDSIGNAL */

            wire [8:0] x_model = refl_x ? x_reflect[8:0] : x_normal[8:0];
            wire [8:0] y_model = refl_y ? y_reflect[8:0] : y_normal[8:0];

            // Sorcer: +1 to a normal X origin, -1 to a reflected one.
            wire [8:0] x_trim_step = refl_x ? 9'h1ff : 9'h001;
            wire [8:0] x_origin    = sorcer_trim ? (x_model + x_trim_step) : x_model;

            assign source_x[9*p +: 9]   = PROFILE_VALID ? x_origin : 9'd0;
            assign source_y[9*p +: 9]   = PROFILE_VALID ? y_model  : 9'd0;
            assign source_descending[p] = PROFILE_VALID ? refl_x   : 1'b0;
        end
    endgenerate

endmodule

`default_nettype wire

// Raster line jobs, graphics cache transport and double-buffered line store for rztile_producer.
module rztile_scanline #(
    parameter int PROFILE=2,
    parameter int MEM_AW=22
) (
  input  logic [1:0] narrow,   // ROM geometry: 0 native, 1 Sorcer, 2 Kingdom, 3 Garegga
    input logic clk,rst,pixel_ce,lhbl,drain,
    input logic [8:0] h,scan_y,render_y,
    input logic [26:0] source_x,source_y,
    input logic [2:0] source_dir,
    input logic [31:0] banks,
    output wire [2:0] desc_en,
    output wire [29:0] desc_index,
    input logic [2:0] desc_valid,
    input logic [95:0] desc_pair,
    output logic [2:0] mem_req,
    output logic [3*MEM_AW-1:0] mem_addr,
    input logic [2:0] mem_ok,
    input logic [95:0] mem_data,
    output logic [44:0] pixels,
    output wire idle,
    output wire [17:0] fault
);
    logic previous_active,offer,cancelled,complete,building;
    logic build_bank,read_bank,read_valid;
    logic [8:0] offered_row,published_row;
    logic [26:0] offered_x,offered_y;
    logic [2:0] offered_dir;
    logic [31:0] offered_banks;
    logic [4:0] parent_fault;
    wire start_line=lhbl && !previous_active;
    wire handoff=!lhbl && previous_active;
    wire producer_ready,producer_idle,producer_busy;
    wire [11:0] desc_tags;
    logic [11:0] response_tags;
    wire gfx_valid,gfx_ready,gfx_response,gfx_response_ready;
    wire [22:0] gfx_address;
    wire [7:0] gfx_tag;
    wire [1:0] gfx_plane;
    logic [31:0] response_data;
    logic [7:0] response_tag;
    wire [2:0] pix_valid,pix_opaque;
    wire [26:0] pix_tag,pix_position;
    wire [5:0] pix_plane;
    wire [11:0] pix_rank;
    wire [32:0] pix_index;
    wire done_valid,done_any,done_fault;
    wire [8:0] done_tag;
    wire [1:0] done_status;
    wire [26:0] done_counts;
    wire [12:0] producer_fault;
    wire valid_completion=done_valid && done_status==0 && !done_fault &&
        done_tag==offered_row && done_counts=={3{9'd320}} && !cancelled;

    // A level cache retires only after both request and acknowledgement fall.
    localparam M_IDLE=0,M_WAIT=1,M_REPLY=2,M_RETIRE=3;
    logic [1:0] memory_state,memory_plane;
    assign gfx_ready=memory_state==M_IDLE && mem_ok==0;
    assign gfx_response=memory_state==M_REPLY;
    assign idle=producer_idle && !offer && memory_state==M_IDLE;
    assign fault={producer_fault,parent_fault};
    always_ff @(posedge clk) begin
        if(rst) begin
            memory_state<=M_IDLE;memory_plane<=0;mem_req<=0;mem_addr<=0;
            response_data<=0;response_tag<=0;
        end else case(memory_state)
            M_IDLE: if(gfx_valid && gfx_ready) begin
                memory_plane<=gfx_plane;
                mem_req<=3'b001<<gfx_plane;
                // Early ports use words; late-board cache ports use bytes.
                mem_addr[gfx_plane*MEM_AW+:MEM_AW]<=(PROFILE>=3 && narrow==2'd0) ?
                    MEM_AW'({gfx_address,1'b0}) : MEM_AW'(gfx_address);
                response_tag<=gfx_tag;
                memory_state<=M_WAIT;
            end
            M_WAIT: if(mem_ok[memory_plane]) begin
                // Stream words: {H0[a+1],H1[a+1],H0[a],H1[a]}.
                response_data<={mem_data[memory_plane*32+16+:8],
                    mem_data[memory_plane*32+:8],
                    mem_data[memory_plane*32+24+:8],
                    mem_data[memory_plane*32+8+:8]};
                mem_req<=0;memory_state<=M_REPLY;
            end
            M_REPLY: if(gfx_response_ready) memory_state<=M_RETIRE;
            M_RETIRE: if(!mem_ok[memory_plane]) memory_state<=M_IDLE;
            default: begin mem_req<=0;memory_state<=M_IDLE;end
        endcase
    end

    // Descriptor RAMs have one registered, atomic pair read per plane.
    always_ff @(posedge clk) begin
        if(rst) response_tags<=0;
        else for(integer p=0;p<3;p=p+1)
            if(desc_en[p]) response_tags[p*4+:4]<=desc_tags[p*4+:4];
    end

    rztile_producer #(.PROFILE(PROFILE),.TAGW(9)) producer (
        .narrow(narrow),
        .clk(clk),.rst(rst),.job_valid(offer),.job_ready(producer_ready),
        .job_tag(offered_row),.job_x0(offered_x),.job_y(offered_y),
        .job_dir(offered_dir),.job_banks(offered_banks),
        .desc_req_valid(desc_en),.desc_req_ready(3'b111),.desc_req_index(desc_index),
        .desc_req_tag(desc_tags),.desc_rsp_valid(desc_valid),.desc_rsp_ready(),
        .desc_rsp_pair(desc_pair),.desc_rsp_tag(response_tags),
        .gfx_req_valid(gfx_valid),.gfx_req_ready(gfx_ready),.gfx_req_addr(gfx_address),
        .gfx_req_tag(gfx_tag),.gfx_req_plane(gfx_plane),.gfx_rsp_valid(gfx_response),
        .gfx_rsp_ready(gfx_response_ready),.gfx_rsp_data(response_data),.gfx_rsp_tag(response_tag),
        .pix_valid(pix_valid),.pix_ready(3'b111),.pix_tag(pix_tag),.pix_plane(pix_plane),
        .pix_d(pix_position),.pix_opaque(pix_opaque),.pix_rank(pix_rank),.pix_index(pix_index),
        .done_valid(done_valid),.done_ready(1'b1),.done_tag(done_tag),.done_status(done_status),
        .done_accepted(done_counts),.done_any_accepted(done_any),.done_fault_seen(done_fault),
        .flush(drain || cancelled || (handoff && building && !complete && !valid_completion)),
        .quiesce(drain && !offer),.idle(producer_idle),.busy(producer_busy),
        .fault(producer_fault),.fault_ack(1'b0)
    );

    always_ff @(posedge clk) begin
        if(rst) begin
            previous_active<=0;offer<=0;cancelled<=0;complete<=0;building<=0;
            build_bank<=0;read_bank<=1;read_valid<=0;offered_row<=0;published_row<=0;
            offered_x<=0;offered_y<=0;offered_dir<=0;offered_banks<=0;parent_fault<=0;
        end else begin
            previous_active<=lhbl;
            if(offer && producer_ready) offer<=0;
            if(producer_idle && !offer) cancelled<=0;
            if(drain && (offer || producer_busy)) cancelled<=1;
            if(done_valid) begin
                if(valid_completion && !drain) complete<=1;
                else if(done_status!=1) parent_fault[3]<=1;
            end
            if(start_line && !drain && render_y<240) begin
                if(idle && !building) begin
                    offer<=1;building<=1;complete<=0;offered_row<=render_y;
                    offered_x<=source_x;offered_y<=source_y;
                    offered_dir<=source_dir;offered_banks<=banks;
                end else parent_fault[1]<=1;
            end
            if(handoff) begin
                read_valid<=building && (complete || valid_completion) && !drain && !cancelled;
                if(building && (complete || valid_completion) && !drain && !cancelled) begin
                    read_bank<=build_bank;build_bank<=!build_bank;published_row<=offered_row;
                end else if(building && !drain) begin
                    parent_fault[0]<=1;cancelled<=1;
                end
                complete<=0;building<=0;
            end
            for(integer p=0;p<3;p=p+1) if(pix_valid[p] &&
                (pix_tag[p*9+:9]!=offered_row || pix_plane[p*2+:2]!=2'(p) ||
                 pix_position[p*9+:9]>=320 || !building)) parent_fault[2]<=1;
        end
    end

    genvar p;
    generate for(p=0;p<3;p=p+1) begin: line_store
        (* ramstyle="M10K" *) logic [14:0] data[0:1023];
        logic [14:0] read_q,sampled;
        logic read_good;
        logic [1:0] read_phase;
        always_ff @(posedge clk) begin
            if(pix_valid[p] && building && !cancelled && !drain &&
               pix_tag[p*9+:9]==offered_row && pix_position[p*9+:9]<320)
                data[{build_bank,pix_position[p*9+:9]}]<=pix_opaque[p] ?
                    {pix_rank[p*4+:4],pix_index[p*11+:11]} : 15'd0;
            read_q<=data[{read_bank,h}];
            read_good<=read_valid && published_row==scan_y && h<320;
            read_phase<={read_phase[0],pixel_ce};
            if(rst) begin
                read_phase<=0;sampled<=0;pixels[p*15+:15]<=0;
            end else begin
                if(read_phase[1]) sampled<=read_good ? read_q : 15'd0;
                if(pixel_ce) pixels[p*15+:15]<=sampled;
            end
        end
    end endgenerate
endmodule
