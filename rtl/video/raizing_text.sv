// SPDX-License-Identifier: GPL-3.0-or-later
// External text row engine, scanout and board text ports.

// Renders one 320-pixel text row from the select/scroll tables at line_y, then pulses line_done.

`default_nettype none

module txrow_engine #(
  parameter logic       POSE0_SCROLL_ADD = 1'b1     // 1: reverse-pose X = pose0_xoff + scroll, 0: pose0_xoff - scroll
) (
  input  logic [8:0] pose1_xoff,   // forward-pose X origin (added to scroll)
  input  logic [8:0] pose0_xoff,   // reverse-pose X origin
  input  logic        clk,
  input  logic        rst,

  // control / status
  input  logic        drain,
  input  logic        flush,
  output logic        idle,
  output logic        busy,
  output logic        proto_err,       // sticky: a response arrived with nothing outstanding

  // line job
  input  logic        line_valid,
  output logic        line_ready,
  input  logic [8:0]  line_y,
  input  logic [15:0] line_job,

  // select table port: data[15] = pose (1 forward, 0 reverse), data[8:0] = source Y
  output logic        sel_req_valid,
  input  logic        sel_req_ready,
  output logic [8:0]  sel_req_addr,
  input  logic        sel_rsp_valid,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [15:0] sel_rsp_data,
  /* verilator lint_on UNUSEDSIGNAL */

  // scroll table port: data[8:0] = X scroll (mod 512)
  output logic        scr_req_valid,
  input  logic        scr_req_ready,
  output logic [8:0]  scr_req_addr,
  input  logic        scr_rsp_valid,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [15:0] scr_rsp_data,
  /* verilator lint_on UNUSEDSIGNAL */

  // text-word port: word index = {src_y[8:3], src_x[8:3]}
  output logic        txt_req_valid,
  input  logic        txt_req_ready,
  output logic [11:0] txt_req_addr,
  input  logic        txt_rsp_valid,
  input  logic [15:0] txt_rsp_data,

  // glyph-row port: row = src_y[2:0], pen = src_x[2:0]
  output logic        gly_req_valid,
  input  logic        gly_req_ready,
  output logic [9:0]  gly_req_code,
  output logic [2:0]  gly_req_row,
  input  logic        gly_rsp_valid,
  input  logic [31:0] gly_rsp_data,

  // pixel stream
  output logic        pix_valid,
  output logic [15:0] pix_job,
  output logic [8:0]  pix_x,
  output logic [10:0] pix_pal,
  output logic        pix_opaque,
  output logic        line_done
);

  typedef enum logic [1:0] { StIdle, StCtx, StRun, StFlush } state_e;
  state_e state_q, state_d;

  // job capture
  logic [8:0]  y_q;
  logic [15:0] job_q;
  logic        accept;

  assign line_ready = (state_q == StIdle) && !drain && !flush;
  assign accept     = line_valid && line_ready;

  always_ff @(posedge clk) begin
    if (rst) begin
      y_q   <= 9'd0;
      job_q <= 16'd0;
    end else if (accept) begin
      y_q   <= line_y;
      job_q <= line_job;
    end
  end


  // row-context fetch: one select and one scroll request per job
  logic sel_pend_q, scr_pend_q, sel_sent_q, scr_sent_q, sel_got_q, scr_got_q;
  logic        pose_q;
  logic [8:0]  srcy_q;
  logic [8:0]  scr9_q;
  logic sel_fire, scr_fire, sel_take, scr_take, ctx_clear;

  assign ctx_clear     = (state_q == StFlush) || (state_q == StIdle);
  assign sel_req_valid = (state_q == StCtx) && !sel_sent_q;
  assign scr_req_valid = (state_q == StCtx) && !scr_sent_q;
  assign sel_req_addr  = y_q;
  assign scr_req_addr  = y_q;
  assign sel_fire      = sel_req_valid && sel_req_ready;
  assign scr_fire      = scr_req_valid && scr_req_ready;
  assign sel_take      = sel_rsp_valid && sel_pend_q && (state_q == StCtx);
  assign scr_take      = scr_rsp_valid && scr_pend_q && (state_q == StCtx);

  always_ff @(posedge clk) begin
    if (rst) begin
      sel_pend_q <= 1'b0; scr_pend_q <= 1'b0;
    end else begin
      if (sel_fire) sel_pend_q <= 1'b1; else if (sel_rsp_valid) sel_pend_q <= 1'b0;
      if (scr_fire) scr_pend_q <= 1'b1; else if (scr_rsp_valid) scr_pend_q <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (rst || ctx_clear) begin
      sel_sent_q <= 1'b0; scr_sent_q <= 1'b0; sel_got_q <= 1'b0; scr_got_q <= 1'b0;
    end else begin
      if (sel_fire) sel_sent_q <= 1'b1;
      if (scr_fire) scr_sent_q <= 1'b1;
      if (sel_take) sel_got_q  <= 1'b1;
      if (scr_take) scr_got_q  <= 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (sel_take) begin
      pose_q <= sel_rsp_data[15];
      srcy_q <= sel_rsp_data[8:0];
    end
    if (scr_take) scr9_q <= scr_rsp_data[8:0];
  end


  // row geometry
  logic [8:0]  x0, pose0_base;
  logic [2:0]  sub0, o0;
  logic [5:0]  cell0, ncell;

  assign pose0_base = POSE0_SCROLL_ADD ? (pose0_xoff + scr9_q) : (pose0_xoff - scr9_q);
  assign x0         = pose_q ? (scr9_q + pose1_xoff) : pose0_base;  // source X at output x = 0
  assign cell0      = x0[8:3];
  assign sub0       = x0[2:0];
  assign o0         = pose_q ? sub0 : ~sub0;                       // pixels skipped in the first cell
  assign ncell      = (o0 == 3'd0) ? 6'd40 : 6'd41;                // ceil((o0 + 320) / 8)


  // sequencing
  logic ctx_ready, start, emit_done;
  logic txt_pend, gly_pend, fetch_err;
  logic any_pend;

  assign ctx_ready = sel_got_q && scr_got_q;
  assign any_pend  = sel_pend_q || scr_pend_q || txt_pend || gly_pend;
  assign start     = (state_q == StCtx) && ctx_ready && !flush;

  always_comb begin
    state_d = state_q;
    unique case (state_q)
      StIdle:  if (flush) state_d = StFlush; else if (accept) state_d = StCtx;
      StCtx:   if (flush) state_d = StFlush; else if (ctx_ready) state_d = StRun;
      StRun:   if (flush) state_d = StFlush; else if (emit_done) state_d = StIdle;
      StFlush: if (!flush && !any_pend) state_d = StIdle;
      default: state_d = StIdle;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) state_q <= StIdle;
    else     state_q <= state_d;
  end

  logic clear;
  assign clear = (state_q == StFlush) || flush;

  logic        cell_valid, cell_pop;
  logic [31:0] cell_pens;
  logic [5:0]  cell_bank;

  txrow_fetch u_fetch (
    .clk, .rst, .clear,
    .start,
    .start_srcy   (srcy_q),
    .start_cell0  (cell0),
    .start_inc    (pose_q),
    .start_ncell  (ncell),
    .txt_req_valid, .txt_req_ready, .txt_req_addr, .txt_rsp_valid, .txt_rsp_data,
    .gly_req_valid, .gly_req_ready, .gly_req_code, .gly_req_row, .gly_rsp_valid, .gly_rsp_data,
    .cell_valid (cell_valid),
    .cell_pens  (cell_pens),
    .cell_bank  (cell_bank),
    .cell_pop   (cell_pop),
    .txt_pend, .gly_pend,
    .proto_err  (fetch_err)
  );

  txrow_emit u_emit (
    .clk, .rst, .clear,
    .start,
    .start_sub0 (sub0),
    .start_inc  (pose_q),
    .start_job  (job_q),
    .cell_valid, .cell_pens, .cell_bank, .cell_pop,
    .pix_valid, .pix_job, .pix_x, .pix_pal, .pix_opaque,
    .done       (emit_done)
  );

  assign line_done = emit_done && (state_q == StRun);


  // status
  logic ctx_err_q;
  always_ff @(posedge clk) begin
    if (rst) ctx_err_q <= 1'b0;
    else if ((sel_rsp_valid && !sel_pend_q) || (scr_rsp_valid && !scr_pend_q)) ctx_err_q <= 1'b1;
  end

  assign idle      = (state_q == StIdle);
  assign busy      = !idle;
  assign proto_err = ctx_err_q || fetch_err;

endmodule

`default_nettype wire

// Fetches one text word and one glyph row per cell; a two-entry FIFO passes {bank, pens} to the emitter.
`default_nettype none

module txrow_fetch (
  input  logic        clk,
  input  logic        rst,            // synchronous, active high
  input  logic        clear,          // level: flush in progress; outstanding responses are dropped

  // job start (one-cycle pulse, only when nothing is in flight)
  input  logic        start,
  input  logic [8:0]  start_srcy,     // 9-bit source Y of this line
  input  logic [5:0]  start_cell0,    // first source cell column
  input  logic        start_inc,      // 1: columns increase (pose 1), 0: decrease (pose 0)
  input  logic [5:0]  start_ncell,    // cells to fetch (40 or 41)

  // text-word port (word index = {srcY[8:3], col[5:0]})
  output logic        txt_req_valid,
  input  logic        txt_req_ready,
  output logic [11:0] txt_req_addr,
  input  logic        txt_rsp_valid,
  input  logic [15:0] txt_rsp_data,   // {bank[5:0], code[9:0]}

  // glyph-row port (code[9:0], row[2:0]) -> 8 ordered pens, pen 0 in [31:28]
  output logic        gly_req_valid,
  input  logic        gly_req_ready,
  output logic [9:0]  gly_req_code,
  output logic [2:0]  gly_req_row,
  input  logic        gly_rsp_valid,
  input  logic [31:0] gly_rsp_data,

  // cell stream to the emitter
  output logic        cell_valid,
  output logic [31:0] cell_pens,
  output logic [5:0]  cell_bank,
  input  logic        cell_pop,

  // status
  output logic        txt_pend,       // a text request is outstanding
  output logic        gly_pend,       // a glyph request is outstanding
  output logic        proto_err       // sticky: response seen with nothing outstanding
);


  // cell address generator
  logic [5:0] gen_rem_q;      // cells still to request
  logic [5:0] gen_col_q;      // next column to request
  logic       gen_inc_q;
  logic [8:0] srcy_q;

  logic txt_fire, gly_fire, txt_take, gly_take;

  always_ff @(posedge clk) begin
    if (rst || clear) begin
      gen_rem_q <= 6'd0;
      gen_col_q <= 6'd0;
      gen_inc_q <= 1'b1;
      srcy_q    <= 9'd0;
    end else if (start) begin
      gen_rem_q <= start_ncell;
      gen_col_q <= start_cell0;
      gen_inc_q <= start_inc;
      srcy_q    <= start_srcy;
    end else if (txt_fire) begin
      gen_rem_q <= gen_rem_q - 6'd1;
      gen_col_q <= gen_inc_q ? (gen_col_q + 6'd1) : (gen_col_q - 6'd1);
    end
  end


  // text port: one outstanding, one-entry holding register for the response
  logic        tbuf_valid_q;
  logic [5:0]  tbuf_bank_q;
  logic [9:0]  tbuf_code_q;
  logic        txt_pend_q;

  assign txt_req_valid = (gen_rem_q != 6'd0) && !txt_pend_q && !tbuf_valid_q && !clear;
  assign txt_req_addr  = {srcy_q[8:3], gen_col_q};
  assign txt_fire      = txt_req_valid && txt_req_ready;
  assign txt_take      = txt_rsp_valid && txt_pend_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      txt_pend_q <= 1'b0;
    end else if (txt_fire) begin
      txt_pend_q <= 1'b1;
    end else if (txt_rsp_valid) begin
      txt_pend_q <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (rst || clear) begin
      tbuf_valid_q <= 1'b0;
    end else if (txt_take) begin
      tbuf_valid_q <= 1'b1;
    end else if (gly_fire) begin
      tbuf_valid_q <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (txt_take) begin
      tbuf_bank_q <= txt_rsp_data[15:10];
      tbuf_code_q <= txt_rsp_data[9:0];
    end
  end


  // glyph port: one outstanding request, issued only when a FIFO slot is free
  logic        gly_pend_q;
  logic [5:0]  gly_bank_q;      // bank travelling with the in-flight glyph request
  logic [1:0]  fifo_count_q;

  assign gly_req_valid = tbuf_valid_q && !gly_pend_q && (fifo_count_q != 2'd2) && !clear;
  assign gly_req_code  = tbuf_code_q;
  assign gly_req_row   = srcy_q[2:0];
  assign gly_fire      = gly_req_valid && gly_req_ready;
  assign gly_take      = gly_rsp_valid && gly_pend_q && !clear;

  always_ff @(posedge clk) begin
    if (rst) begin
      gly_pend_q <= 1'b0;
    end else if (gly_fire) begin
      gly_pend_q <= 1'b1;
    end else if (gly_rsp_valid) begin
      gly_pend_q <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (gly_fire) gly_bank_q <= tbuf_bank_q;
  end


  // two-entry cell FIFO of {bank, pens}
  logic [37:0] slot0_q, slot1_q;
  logic        fifo_wr_q, fifo_rd_q;
  logic        pop_fire;

  assign pop_fire   = cell_pop && cell_valid;
  assign cell_valid = (fifo_count_q != 2'd0) && !clear;
  assign cell_pens  = fifo_rd_q ? slot1_q[31:0]  : slot0_q[31:0];
  assign cell_bank  = fifo_rd_q ? slot1_q[37:32] : slot0_q[37:32];

  always_ff @(posedge clk) begin
    if (rst || clear) begin
      fifo_count_q <= 2'd0;
      fifo_wr_q    <= 1'b0;
      fifo_rd_q    <= 1'b0;
    end else begin
      if (gly_take) fifo_wr_q <= ~fifo_wr_q;
      if (pop_fire) fifo_rd_q <= ~fifo_rd_q;
      unique case ({gly_take, pop_fire})
        2'b10:   fifo_count_q <= fifo_count_q + 2'd1;
        2'b01:   fifo_count_q <= fifo_count_q - 2'd1;
        default: fifo_count_q <= fifo_count_q;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (gly_take && !fifo_wr_q) slot0_q <= {gly_bank_q, gly_rsp_data};
    if (gly_take &&  fifo_wr_q) slot1_q <= {gly_bank_q, gly_rsp_data};
  end


  // status
  logic proto_err_q;
  always_ff @(posedge clk) begin
    if (rst) proto_err_q <= 1'b0;
    else if ((txt_rsp_valid && !txt_pend_q) || (gly_rsp_valid && !gly_pend_q)) proto_err_q <= 1'b1;
  end

  assign txt_pend  = txt_pend_q;
  assign gly_pend  = gly_pend_q;
  assign proto_err = proto_err_q;

endmodule

`default_nettype wire

// Emits 320 pixels from the cell stream; source X steps up (pose 1) or down (pose 0) and its low bits pick the pen.
`default_nettype none

module txrow_emit (
  input  logic        clk,
  input  logic        rst,
  input  logic        clear,

  input  logic        start,          // one-cycle pulse
  input  logic [2:0]  start_sub0,     // source X low bits at x = 0
  input  logic        start_inc,      // 1: source X increases with x
  input  logic [15:0] start_job,

  input  logic        cell_valid,
  input  logic [31:0] cell_pens,
  input  logic [5:0]  cell_bank,
  output logic        cell_pop,

  output logic        pix_valid,
  output logic [15:0] pix_job,
  output logic [8:0]  pix_x,
  output logic [10:0] pix_pal,        // 0x400 + bank*16 + pen
  output logic        pix_opaque,
  output logic        done            // one-cycle pulse after x = 319 was emitted
);

  logic        active_q;
  logic [8:0]  x_q;
  logic [2:0]  sub_q;
  logic        inc_q;
  logic [15:0] job_q;
  logic        done_q;

  logic [3:0]  pen;
  logic        last_in_cell, last_px, emit;

  always_comb begin
    unique case (sub_q)
      3'd0:    pen = cell_pens[31:28];
      3'd1:    pen = cell_pens[27:24];
      3'd2:    pen = cell_pens[23:20];
      3'd3:    pen = cell_pens[19:16];
      3'd4:    pen = cell_pens[15:12];
      3'd5:    pen = cell_pens[11:8];
      3'd6:    pen = cell_pens[7:4];
      default: pen = cell_pens[3:0];
    endcase
  end

  assign emit         = active_q && cell_valid && !clear;
  assign last_in_cell = inc_q ? (sub_q == 3'd7) : (sub_q == 3'd0);
  assign last_px      = (x_q == 9'd319);
  assign cell_pop     = emit && (last_in_cell || last_px);

  always_ff @(posedge clk) begin
    if (rst || clear) begin
      active_q <= 1'b0;
      x_q      <= 9'd0;
      sub_q    <= 3'd0;
      inc_q    <= 1'b1;
    end else if (start) begin
      active_q <= 1'b1;
      x_q      <= 9'd0;
      sub_q    <= start_sub0;
      inc_q    <= start_inc;
    end else if (emit) begin
      x_q   <= x_q + 9'd1;
      sub_q <= inc_q ? (sub_q + 3'd1) : (sub_q - 3'd1);
      if (last_px) active_q <= 1'b0;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) job_q <= 16'd0;
    else if (start) job_q <= start_job;
  end

  always_ff @(posedge clk) begin
    if (rst || clear) done_q <= 1'b0;
    else             done_q <= emit && last_px;
  end

  assign pix_valid  = emit;
  assign pix_job    = job_q;
  assign pix_x      = x_q;
  assign pix_pal    = {1'b1, cell_bank, pen};
  assign pix_opaque = (pen != 4'd0);
  assign done       = done_q;

endmodule

`default_nettype wire

// Double-buffered row store: the producer fills one 320-pixel bank, publish swaps it to scanout.
module rztext_scanout (
  input  logic        clk,
  input  logic        reset,
  input  logic        drain,
  // reservation
  input  logic        row_valid,
  input  logic [15:0] row_tag,
  input  logic [8:0]  row_y,
  output logic        row_ready,
  // producer stream (no backpressure)
  input  logic        pix_valid,
  input  logic [15:0] pix_tag,
  input  logic [8:0]  pix_x,
  input  logic [10:0] pix_pal,
  input  logic        pix_opaque,
  input  logic        line_done,
  input  logic        producer_fault,
  // publication
  input  logic        publish,
  input  logic [8:0]  publish_y,
  // display
  input  logic [8:0]  scan_y,
  input  logic [8:0]  scan_x,
  input  logic        active,
  input  logic        pixel_ce,
  output logic [10:0] text_pixel,
  // status
  output logic        idle,
  output logic        fault
);
  localparam logic [8:0] LAST_X = 9'd319;
  localparam logic [8:0] WIDTH  = 9'd320;

  // write-side state
  logic        busy;        // reservation outstanding (until line_done or reset)
  logic        bad;         // the current job is malformed; its row is discarded
  logic        need_done;   // the sample with x=319 was accepted at the previous edge
  logic [8:0]  exp_x;       // next expected column
  logic [15:0] tag_q;
  logic [8:0]  y_q;
  logic        pending;     // a complete good row waits for publication

  // read-side state
  logic        rd_bank;     // bank being displayed
  logic        rd_valid;    // the displayed bank holds the published row rd_y
  logic [8:0]  rd_y;

  // per-edge producer checks
  logic accept, pix_good, done_good, malformed, stray, discard_pending, complete_now;
  logic publish_hit, publish_wrong_row, deadline_miss;

  assign row_ready = !reset && !busy && !pending && !drain && !publish;
  assign accept    = row_valid && row_ready;

  // sample continues the current job in order
  assign pix_good  = pix_valid && busy && !bad && !need_done && !line_done
                     && (pix_tag == tag_q) && (pix_x == exp_x) && (exp_x != WIDTH);
  // completion on the edge after x=319 with no sample
  assign done_good = line_done && busy && !bad && need_done && !pix_valid;
  // other producer activity during a good job
  assign malformed = busy && !bad && ((pix_valid && !pix_good)          // wrong tag, x, extra sample
                                      || (need_done && !line_done)      // late or missing completion
                                      || (line_done && !done_good)      // early completion
                                      || producer_fault);
  // producer activity with no reservation; discards an unpublished row
  assign stray           = !busy && (pix_valid || line_done || producer_fault);
  assign discard_pending = pending && stray;

  assign complete_now      = (pending && !discard_pending) || done_good;
  assign publish_hit       = publish && complete_now && (y_q == publish_y);
  assign publish_wrong_row = publish && complete_now && (y_q != publish_y);
  // a reservation that has not completed by its publication edge misses its deadline
  assign deadline_miss     = publish && busy && !done_good;

  always_ff @(posedge clk) begin
    if (reset) begin
      busy      <= 1'b0;
      bad       <= 1'b0;
      need_done <= 1'b0;
      exp_x     <= 9'd0;
      tag_q     <= 16'd0;
      y_q       <= 9'd0;
      pending   <= 1'b0;
      rd_bank   <= 1'b0;
      rd_valid  <= 1'b0;
      rd_y      <= 9'd0;
      fault     <= 1'b0;
    end else begin
      // reservation (only when nothing is reserved or pending)
      if (accept) begin
        busy      <= 1'b1;
        bad       <= 1'b0;
        need_done <= 1'b0;
        exp_x     <= 9'd0;
        tag_q     <= row_tag;
        y_q       <= row_y;
      end
      // job progress
      if (busy) begin
        if (pix_good) exp_x <= exp_x + 9'd1;
        need_done <= pix_good && (exp_x == LAST_X);
        if (malformed || deadline_miss) bad <= 1'b1;
        if (line_done) begin
          busy <= 1'b0;                       // the reservation retires at line_done, good or bad
          if (done_good && !publish) pending <= 1'b1;
        end
      end
      if (discard_pending) pending <= 1'b0;
      // publication
      if (publish) begin
        pending  <= 1'b0;
        rd_valid <= publish_hit;              // stays invalid unless the published row matched
        if (publish_hit) begin
          rd_bank <= ~rd_bank;
          rd_y    <= y_q;
        end
      end
      if (malformed || stray || deadline_miss || publish_wrong_row) fault <= 1'b1;
    end
  end

  assign idle = !busy && !pending;

  // row storage (simple dual port, bank = MSB)
  logic        we;
  logic [9:0]  wa, ra;
  logic [10:0] wd, q;
  logic        v_q;

  assign we = pix_good && !reset;
  assign wa = {~rd_bank, pix_x};
  assign wd = pix_opaque ? pix_pal : 11'd0;   // transparency writes zero
  assign ra = {rd_bank, scan_x};

  (* ramstyle = "M10K" *) logic [10:0] mem [0:1023];

  always_ff @(posedge clk) begin
    if (we) mem[wa] <= wd;
    q <= mem[ra];
  end

  // row-valid flag aligned with the RAM read
  always_ff @(posedge clk) begin
    if (reset) v_q <= 1'b0;
    else       v_q <= rd_valid && (rd_y == scan_y) && (scan_x < WIDTH);
  end

  // output register, updated on pixel_ce
  always_ff @(posedge clk) begin
    if (reset)                    text_pixel <= 11'd0;
    else if (pixel_ce && active)  text_pixel <= v_q ? q : 11'd0;
  end
endmodule

// Text layer: rising LHBL queues a job for the next row, falling LHBL publishes it (row 262 wraps to 0).
`default_nettype none
module raizing_text_layer (
    input raizing_board_pkg::board_e board,
    input wire clk, reset, pixel_ce,
    input wire [8:0] render_y, h, v,
    input wire active, lhbl, lvbl, drain,
    output wire idle,
    output wire [10:0] text_pixel,
    output wire [13:0] font_addr,
    input wire [15:0] font_data,
    output wire [11:0] text_addr,
    input wire [15:0] text_data,
    output wire [7:0] select_addr, scroll_addr,
    input wire [15:0] select_data, scroll_data
);
    reg previous_lhbl;
    reg pending;
    reg [8:0] job_y;        // producer render Y (select/scroll table row)
    reg [8:0] row_y;        // physical display row reserved for that job
    wire engine_idle, line_ready, ports_idle, row_ready, scanout_idle;
    wire [8:0] next_row = v==9'd262 ? 9'd0 : v+9'd1;
    wire launch = lhbl && !previous_lhbl && (lvbl || render_y==0 || render_y==239);
    wire offer = launch && !drain && engine_idle && !pending;
    // One edge accepts both the producer job and the publisher reservation.
    wire job_accept = pending && line_ready && row_ready;
    always @(posedge clk) begin
        if (reset) begin
            previous_lhbl <= lhbl;
            pending <= 1'b0;
        end else begin
            previous_lhbl <= lhbl;
            if (job_accept) pending <= 1'b0;
            if (offer) pending <= 1'b1;
        end
        if (offer) begin
            job_y <= render_y;
            row_y <= next_row;
        end
    end
    wire publish = previous_lhbl && !lhbl;     // falling LHBL publishes next_row
    // a job queued before drain still completes
    wire job_drain = drain && !pending;

    wire sel_req_valid, sel_req_ready, sel_rsp_valid;
    wire scr_req_valid, scr_req_ready, scr_rsp_valid;
    wire txt_req_valid, txt_req_ready, txt_rsp_valid;
    wire gly_req_valid, gly_req_ready, gly_rsp_valid;
    wire [8:0] sel_req_addr, scr_req_addr;
    wire [11:0] txt_req_addr;
    wire [9:0] gly_req_code;
    wire [2:0] gly_req_row;
    wire [15:0] sel_rsp_data, scr_rsp_data, txt_rsp_data;
    wire [31:0] gly_rsp_data;
    wire pix_valid, pix_opaque, proto_err, line_done;
    wire [15:0] pix_job;
    wire [8:0] pix_x;
    wire [10:0] pix_pal;
    wire kingdom_text = board == raizing_board_pkg::RZB_KINGDOM;
    txrow_engine engine (
        .pose1_xoff(kingdom_text ? 9'd44 : 9'd40),.pose0_xoff(kingdom_text ? 9'd468 : 9'd472),
        .clk(clk),.rst(reset),
        .drain(job_drain),.flush(1'b0),.idle(engine_idle),.busy(),.proto_err(proto_err),
        .line_valid(pending && row_ready),.line_ready(line_ready),.line_y(job_y),.line_job({7'd0,job_y}),
        .sel_req_valid(sel_req_valid),.sel_req_ready(sel_req_ready),.sel_req_addr(sel_req_addr),
        .sel_rsp_valid(sel_rsp_valid),.sel_rsp_data(sel_rsp_data),
        .scr_req_valid(scr_req_valid),.scr_req_ready(scr_req_ready),.scr_req_addr(scr_req_addr),
        .scr_rsp_valid(scr_rsp_valid),.scr_rsp_data(scr_rsp_data),
        .txt_req_valid(txt_req_valid),.txt_req_ready(txt_req_ready),.txt_req_addr(txt_req_addr),
        .txt_rsp_valid(txt_rsp_valid),.txt_rsp_data(txt_rsp_data),
        .gly_req_valid(gly_req_valid),.gly_req_ready(gly_req_ready),.gly_req_code(gly_req_code),
        .gly_req_row(gly_req_row),.gly_rsp_valid(gly_rsp_valid),.gly_rsp_data(gly_rsp_data),
        .pix_valid(pix_valid),.pix_job(pix_job),.pix_x(pix_x),.pix_pal(pix_pal),
        .pix_opaque(pix_opaque),.line_done(line_done)
    );
    wire late_text = board == raizing_board_pkg::RZB_BATRIDER || board == raizing_board_pkg::RZB_BAKRAID;
    raizing_text_ports ports (
        .glyph_swap(late_text),
        .clk(clk),.reset(reset),
        .sel_req_valid(sel_req_valid),.sel_req_ready(sel_req_ready),.sel_req_addr(sel_req_addr[7:0]),
        .sel_rsp_valid(sel_rsp_valid),.sel_rsp_data(sel_rsp_data),
        .scr_req_valid(scr_req_valid),.scr_req_ready(scr_req_ready),.scr_req_addr(scr_req_addr[7:0]),
        .scr_rsp_valid(scr_rsp_valid),.scr_rsp_data(scr_rsp_data),
        .txt_req_valid(txt_req_valid),.txt_req_ready(txt_req_ready),.txt_req_addr(txt_req_addr),
        .txt_rsp_valid(txt_rsp_valid),.txt_rsp_data(txt_rsp_data),
        .gly_req_valid(gly_req_valid),.gly_req_ready(gly_req_ready),.gly_req_code(gly_req_code),
        .gly_req_row(gly_req_row),.gly_rsp_valid(gly_rsp_valid),.gly_rsp_data(gly_rsp_data),
        .select_addr(select_addr),.scroll_addr(scroll_addr),.text_addr(text_addr),.font_addr(font_addr),
        .select_data(select_data),.scroll_data(scroll_data),.text_data(text_data),.font_data(font_data),.idle(ports_idle)
    );

    // A wrong-row, late, malformed, or stray job shows a transparent row and sets a sticky fault.
    wire fault;
    rztext_scanout scanout (
        .clk(clk),.reset(reset),.drain(job_drain),
        .row_valid(pending && line_ready),.row_tag({7'd0,job_y}),.row_y(row_y),.row_ready(row_ready),
        .pix_valid(pix_valid),.pix_tag(pix_job),.pix_x(pix_x),.pix_pal(pix_pal),.pix_opaque(pix_opaque),
        .line_done(line_done),.producer_fault(proto_err),
        .publish(publish),.publish_y(next_row),
        .scan_y(v),.scan_x(h),.active(active),.pixel_ce(pixel_ce),
        .text_pixel(text_pixel),.idle(scanout_idle),.fault(fault)
    );
    assign idle = engine_idle && ports_idle && !pending && scanout_idle;

`ifdef SIMULATION
    always @(posedge clk) if (!reset) begin
        if (sel_req_valid && sel_req_addr[8]) $fatal(1,"TEXT_ROW_TABLE_RANGE");
        if (scr_req_valid && scr_req_addr[8]) $fatal(1,"TEXT_ROW_TABLE_RANGE");
        if (proto_err) $fatal(1,"TEXT_ROW_PROTOCOL_ERROR");
    end
`endif
endmodule
`default_nettype wire

// Maps txrow_engine requests onto the text RAM ports; a glyph row is two font words.
`default_nettype none
module raizing_text_ports (
    input wire glyph_swap,   // Batrider/Bakraid: byte-swap glyph words
    input wire clk, reset,
    input wire sel_req_valid,
    input wire [7:0] sel_req_addr,
    output wire sel_req_ready,
    output reg sel_rsp_valid,
    output wire [15:0] sel_rsp_data,
    input wire scr_req_valid,
    input wire [7:0] scr_req_addr,
    output wire scr_req_ready,
    output reg scr_rsp_valid,
    output wire [15:0] scr_rsp_data,
    input wire txt_req_valid,
    input wire [11:0] txt_req_addr,
    output wire txt_req_ready,
    output reg txt_rsp_valid,
    output wire [15:0] txt_rsp_data,
    input wire gly_req_valid,
    input wire [9:0] gly_req_code,
    input wire [2:0] gly_req_row,
    output wire gly_req_ready,
    output wire gly_rsp_valid,
    output wire [31:0] gly_rsp_data,
    output wire [7:0] select_addr, scroll_addr,
    input wire [15:0] select_data, scroll_data,
    output wire [11:0] text_addr,
    input wire [15:0] text_data,
    output wire [13:0] font_addr,
    input wire [15:0] font_data,
    output wire idle
);
    assign select_addr = sel_req_addr;
    assign scroll_addr = scr_req_addr;
    assign text_addr = txt_req_addr;
    assign sel_req_ready = !reset;
    assign scr_req_ready = !reset;
    assign txt_req_ready = !reset;
    assign sel_rsp_data = select_data;
    assign scr_rsp_data = scroll_data;
    assign txt_rsp_data = text_data;

    always @(posedge clk) begin
        if (reset) begin
            sel_rsp_valid <= 1'b0;
            scr_rsp_valid <= 1'b0;
            txt_rsp_valid <= 1'b0;
        end else begin
            sel_rsp_valid <= sel_req_valid && sel_req_ready;
            scr_rsp_valid <= scr_req_valid && scr_req_ready;
            txt_rsp_valid <= txt_req_valid && txt_req_ready;
        end
    end

    localparam [1:0] FONT_IDLE=0, FONT_FIRST=1, FONT_SECOND=2;
    reg [1:0] font_state;
    reg [12:0] font_row;
    reg [15:0] first_half;
    assign gly_req_ready = font_state==FONT_IDLE && !reset;
    assign font_addr = font_state==FONT_IDLE ? {gly_req_code,gly_req_row,1'b0} : {font_row,1'b1};
    assign gly_rsp_valid = font_state==FONT_SECOND && !reset;
    assign gly_rsp_data = glyph_swap ? {first_half[7:0],first_half[15:8],font_data[7:0],font_data[15:8]} :
                                       {first_half,font_data};

    always @(posedge clk) begin
        if (reset) font_state <= FONT_IDLE;
        else case (font_state)
            FONT_IDLE: if (gly_req_valid && gly_req_ready) font_state <= FONT_FIRST;
            FONT_FIRST: font_state <= FONT_SECOND;
            FONT_SECOND: font_state <= FONT_IDLE;
            default: font_state <= FONT_IDLE;
        endcase
    end
    always @(posedge clk) begin
        if (gly_req_valid && gly_req_ready) font_row <= {gly_req_code,gly_req_row};
        if (font_state==FONT_FIRST) first_half <= font_data;
    end
    assign idle = font_state==FONT_IDLE && !(sel_rsp_valid || scr_rsp_valid || txt_rsp_valid);
endmodule
`default_nettype wire
