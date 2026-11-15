// SPDX-License-Identifier: GPL-3.0-or-later
// GP9001 sprite-row producer.

package rzspr_pkg;
  localparam int PROFILE_SORCER   = 0;
  localparam int PROFILE_KINGDOM  = 1;
  localparam int PROFILE_GAREGGA  = 2;
  localparam int PROFILE_BATRIDER = 3;
  localparam int PROFILE_BAKRAID  = 4;

  localparam int PIXELS_PER_LINE  = 320;   // accepted samples per job
  localparam int LINES_PER_FRAME  = 240;   // destination Y 0..239
  localparam int DESCRIPTORS      = 256;   // sprite descriptors per list

  typedef enum logic [1:0] {
    ST_COMPLETE  = 2'd0,
    ST_CANCELLED = 2'd1,
    ST_REJECTED  = 2'd2,
    ST_FAULTED   = 2'd3
  } status_e;

  // Code counter width per profile (half_bytes/16 elements); 0 = unsupported.
  function automatic int code_bits(input int profile);
    case (profile)
      PROFILE_SORCER:   return 16;   // 1 MiB halves
      PROFILE_KINGDOM:  return 17;   // 2 MiB halves
      PROFILE_GAREGGA:  return 18;   // 4 MiB halves
      PROFILE_BATRIDER: return 19;   // 8 MiB halves, banked
      PROFILE_BAKRAID:  return 19;   // 8 MiB halves, banked
      default:          return 0;
    endcase
  endfunction

  function automatic bit profile_banked(input int profile);
    return (profile == PROFILE_BATRIDER) || (profile == PROFILE_BAKRAID);
  endfunction

  function automatic bit profile_known(input int profile);
    return code_bits(profile) != 0;
  endfunction
endpackage

// Issues graphics-row reads tagged {seq, count} and queues responses in order; cancel retires without queuing.
module rzspr_gfxfetch #(
  parameter int CHECK_TAGS = 1,
  parameter int DEPTH_LOG2 = 2,
  parameter int SEQW       = 2,
  parameter int CNTW       = 6
) (
  input  logic                 clk,
  input  logic                 rst,
  input  logic                 start,
  input  logic                 cancel,
  input  logic [SEQW-1:0]      seq,
  // from the cell generator
  input  logic                 in_valid,
  output logic                 in_ready,
  input  logic [22:0]          in_addr,
  // memory service request
  output logic                 req_valid,
  input  logic                 req_ready,
  output logic [22:0]          req_addr,
  output logic [SEQW+CNTW-1:0] req_tag,
  // memory service response
  input  logic                 rsp_valid,
  output logic                 rsp_ready,
  input  logic [31:0]          rsp_data,
  input  logic [SEQW+CNTW-1:0] rsp_tag,
  // row data to the writer, in request order
  output logic                 d_valid,
  input  logic                 d_ready,
  output logic [31:0]          d_data,
  // status
  output logic                 outstanding_zero,
  output logic                 f_stray,
  output logic                 f_tag,
  output logic                 f_edge
);
  logic [CNTW-1:0]       issued, received;
  logic [DEPTH_LOG2:0]   outstanding;
  logic [DEPTH_LOG2:0]   fifo_count;
  logic                  req_fire, have_out, tag_ok, take, push;
  logic [SEQW+CNTW-1:0]  expect_tag;

  assign req_valid  = in_valid;
  assign in_ready   = req_ready;
  assign req_addr   = in_addr;
  assign req_tag    = {seq, issued};
  assign req_fire   = req_valid && req_ready;
  assign rsp_ready  = 1'b1;

  assign have_out   = (outstanding != '0);
  assign expect_tag = {seq, received};
  assign tag_ok     = (CHECK_TAGS == 0) || (rsp_tag == expect_tag);
  assign f_stray    = rsp_valid && !have_out && !req_fire;
  assign f_edge     = rsp_valid && !have_out &&  req_fire;
  assign f_tag      = rsp_valid &&  have_out && !tag_ok && !cancel;
  assign take       = rsp_valid && (have_out || req_fire);
  assign push       = rsp_valid && have_out && tag_ok && !cancel;
  assign outstanding_zero = !have_out;

  always_ff @(posedge clk) begin
    if (rst || start) begin
      issued      <= '0;
      received    <= '0;
      outstanding <= '0;
    end else begin
      if (req_fire) issued   <= issued + 1'b1;
      if (take)     received <= received + 1'b1;
      outstanding <= outstanding + {{DEPTH_LOG2{1'b0}}, req_fire} - {{DEPTH_LOG2{1'b0}}, take};
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic fifo_in_ready;   // A reserved FIFO slot guarantees ready on a push.
  logic [DEPTH_LOG2:0] fifo_count_unused;
  /* verilator lint_on UNUSEDSIGNAL */
  assign fifo_count_unused = fifo_count;

  rzspr_fifo #(.W(32), .DEPTH_LOG2(DEPTH_LOG2)) u_fifo (
    .clk(clk), .rst(rst), .clear(start || cancel),
    .in_valid(push), .in_ready(fifo_in_ready), .in_data(rsp_data),
    .out_valid(d_valid), .out_ready(d_ready), .out_data(d_data),
    .count(fifo_count)
  );
endmodule

// Decodes raw = {H1[a+1], H1[a], H0[a+1], H0[a]} into pens[4k +: 4]; pixel k takes bit 7-k of each byte.
module rzspr_rowdec (
  input  logic [31:0] raw,
  output logic [31:0] pens
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

// Valid/ready FIFO; REGISTER_HEAD serves the head from a register refilled on push/pop.
module rzspr_fifo #(
  parameter int W          = 8,
  parameter int DEPTH_LOG2 = 2,
  parameter bit REGISTER_HEAD = 1'b0
) (
  input  logic                  clk,
  input  logic                  rst,
  input  logic                  clear,  // Empties the FIFO on the next clock edge.
  input  logic                  in_valid,
  output logic                  in_ready,
  input  logic [W-1:0]          in_data,
  output logic                  out_valid,
  input  logic                  out_ready,
  output logic [W-1:0]          out_data,
  output logic [DEPTH_LOG2:0]   count
);
  localparam int DEPTH = 1 << DEPTH_LOG2;

  logic [W-1:0]          mem [0:DEPTH-1];
  logic [DEPTH_LOG2-1:0] rd_ptr, wr_ptr;
  logic                  in_fire, out_fire;

  assign in_ready  = !count[DEPTH_LOG2];   // count == DEPTH only when the MSB is set
  assign out_valid = (count != '0);
  generate
    if (REGISTER_HEAD) begin : g_registered_head
      (* preserve *) logic [W-1:0] head;
      wire [DEPTH_LOG2-1:0] next_rd = rd_ptr + 1'b1;
      assign out_data = head;
      always_ff @(posedge clk) begin
        if (!rst && !clear) begin
          // Refill directly if the new push is the next visible item.
          if (in_fire && (count == 0 || (count == 1 && out_fire)))
            head <= in_data;
          else if (out_fire && count > 1)
            head <= mem[next_rd];
        end
      end
    end else begin : g_async_head
      assign out_data = mem[rd_ptr];
    end
  endgenerate
  assign in_fire   = in_valid && in_ready;
  assign out_fire  = out_valid && out_ready;

  always_ff @(posedge clk) begin
    if (rst || clear) begin
      rd_ptr <= '0;
      wr_ptr <= '0;
      count  <= '0;
    end else begin
      if (in_fire)  wr_ptr <= wr_ptr + 1'b1;
      if (out_fire) rd_ptr <= rd_ptr + 1'b1;
      count <= count + {{DEPTH_LOG2{1'b0}}, in_fire} - {{DEPTH_LOG2{1'b0}}, out_fire};
    end
  end

  always_ff @(posedge clk) begin
    if (in_fire) mem[wr_ptr] <= in_data;
  end
endmodule

// Four-stage descriptor scan, stalled as a whole by w_ready, emitting work for sprites on line y.
module rzspr_scan
  import rzspr_pkg::*;
#(
  parameter int PROFILE = PROFILE_GAREGGA
) (
  input  logic [1:0] narrow,   // ROM geometry: 0 native, 1 Sorcer, 2 Kingdom, 3 Garegga
  input  logic         clk,
  input  logic         rst,
  input  logic         start,      // pulse: new job, clears rank histories
  input  logic         cancel,     // drop the pipeline contents
  input  logic [7:0]   y,
  input  logic [8:0]   scx,
  input  logic [8:0]   scy,
  input  logic         gflipx,
  input  logic         gflipy,
  input  logic [31:0]  banks,
  // descriptors in index order
  input  logic         d_valid,
  output logic         d_ready,
  input  logic [63:0]  d_data,
  // work items: {code_row[18:0], k[2:0], px[9:0], fx, wm1[3:0], rank[3:0], bank[5:0]}
  output logic         w_valid,
  input  logic         w_ready,
  output logic [46:0]  w_data,
  // status
  output logic [8:0]   consumed,   // descriptors taken from the stream (0..256)
  output logic         empty       // no descriptor inside the pipeline
);
  localparam int  CB     = code_bits(PROFILE);
  localparam bit  BANKED = profile_banked(PROFILE);
  localparam logic [18:0] CODE_MASK = (CB == 0) ? 19'd0 : ((19'd1 << CB) - 19'd1);
  localparam logic [18:0] CODE_MASK_SORCER = (19'd1 << code_bits(PROFILE_SORCER)) - 19'd1;
  localparam logic [18:0] CODE_MASK_KINGDOM = (19'd1 << code_bits(PROFILE_KINGDOM)) - 19'd1;
  localparam logic [18:0] CODE_MASK_GAREGGA = (19'd1 << code_bits(PROFILE_GAREGGA)) - 19'd1;
  wire [18:0] code_mask = narrow == 2'd1 ? (CODE_MASK_SORCER & CODE_MASK) :
                          narrow == 2'd2 ? (CODE_MASK_KINGDOM & CODE_MASK) :
                          narrow == 2'd3 ? (CODE_MASK_GAREGGA & CODE_MASK) : CODE_MASK;

  // ---------------------------------------------------------------- S0: position chain
  logic [15:0] head, codelow, xw, yw;
  logic        en0, rel0, lfy0, lfx0;
  logic [3:0]  rank0, wm1_0, hm1_0;
  logic [5:0]  bank0;
  logic [17:0] code0;
  logic [8:0]  xop, yop, hx, hy;
  logic [8:0]  hist_x [0:15];
  logic [8:0]  hist_y [0:15];
  /* verilator lint_off UNUSEDSIGNAL */
  logic [5:0]  attr_unmodeled;   // X and Y word bits 6:4 are unused.
  /* verilator lint_on UNUSEDSIGNAL */

  assign head    = d_data[15:0];
  assign codelow = d_data[31:16];
  assign xw      = d_data[47:32];
  assign yw      = d_data[63:48];
  assign en0     = head[15];
  assign rel0    = head[14];
  assign lfy0    = head[13];
  assign lfx0    = head[12];
  assign rank0   = head[11:8];
  assign bank0   = head[7:2];
  assign code0   = {head[1:0], codelow};
  assign xop     = xw[15:7];
  assign yop     = yw[15:7];
  assign wm1_0   = xw[3:0];
  assign hm1_0   = yw[3:0];
  assign attr_unmodeled = {xw[6:4], yw[6:4]};
  // Relative: add operands mod 512 to this raw rank's history; every descriptor updates it.
  assign hx = rel0 ? (hist_x[rank0] + xop) : xop;
  assign hy = rel0 ? (hist_y[rank0] + yop) : yop;

  logic stall, adv, fire;
  logic v1, v2, v3;
  assign stall   = v3 && !w_ready;
  assign adv     = !stall;
  assign d_ready = adv && !cancel;
  assign fire    = d_valid && d_ready;

  // ---------------------------------------------------------------- S1 regs
  logic [8:0]  hx1, hy1;
  logic        en1, lfx1, lfy1;
  logic [3:0]  rank1, wm1_1, hm1_1;
  logic [5:0]  bank1;
  logic [17:0] code1;

  // S1 combinational: subtract scroll, apply flip anchor (-7), wrap and global flip.
  logic [8:0]         px0, py0;
  /* verilator lint_off UNUSEDSIGNAL */
  logic signed [10:0] pxa, pya, pxw, pyw, pxg, pyg;   // bit 10 of pxg/pyg is a redundant sign copy
  /* verilator lint_on UNUSEDSIGNAL */
  assign px0 = hx1 - scx;
  assign py0 = hy1 - scy;
  assign pxa = lfx1 ? ($signed({2'b00, px0}) - 11'sd7) : $signed({2'b00, px0});
  assign pya = lfy1 ? ($signed({2'b00, py0}) - 11'sd7) : $signed({2'b00, py0});
  assign pxw = lfx1 ? ((pxa >= 11'sd448) ? (pxa - 11'sd512) : pxa)
                    : ((pxa >= 11'sd384) ? (pxa - 11'sd512) : pxa);
  assign pyw = lfy1 ? ((pya >= 11'sd448) ? (pya - 11'sd512) : pya)
                    : ((pya >= 11'sd384) ? (pya - 11'sd512) : pya);
  assign pxg = gflipx ? (11'sd320 - pxw) : pxw;
  assign pyg = gflipy ? (11'sd240 - pyw) : pyw;

  // ---------------------------------------------------------------- S2 regs
  logic signed [9:0] px2, py2;
  logic        en2, fx2, fy2;
  logic [3:0]  rank2, wm1_2, hm1_2;
  logic [5:0]  bank2;
  logic [17:0] code2;

  // S2 combinational: intersection with line y
  logic signed [10:0] dd, ee;
  logic        hit;
  assign dd  = $signed({3'b000, y}) - $signed({py2[9], py2});
  assign ee  = fy2 ? (11'sd7 - dd) : dd;
  // Hit: enabled, rank < 8, and 0 <= ee < 8*(hm1+1), i.e. ee[10:7] == 0 && ee[6:3] <= hm1.
  assign hit = en2 && !rank2[3] && (ee[10:7] == 4'b0000) && (ee[6:3] <= hm1_2);

  // ---------------------------------------------------------------- S3 regs
  logic signed [9:0] px3;
  logic        fx3;
  logic [3:0]  r3, rank3, wm1_3;
  logic [2:0]  k3;
  logic [5:0]  bank3;
  logic [17:0] code3;

  // S3 combinational: translate the base code once, then add r*w (row-major)
  logic [18:0] translated, code_row, code_sum;
  logic [3:0]  bank_sel;
  logic [8:0]  prod;
  assign bank_sel   = banks[4*code3[17:15] +: 4];
  assign translated = (BANKED && narrow == 2'd0) ? {bank_sel, code3[14:0]} : {1'b0, code3};
  assign prod       = ({4'b0000, r3} * {4'b0000, wm1_3}) + {5'b00000, r3};   // r*(w-1) + r = r*w
  assign code_sum   = translated + {10'b0, prod};
  assign code_row   = code_sum & code_mask;
  assign w_valid    = v3;
  assign w_data     = {code_row, k3, px3, fx3, wm1_3, rank3, bank3};
  assign empty      = !v1 && !v2 && !v3;

  integer i;
  always_ff @(posedge clk) begin
    if (rst || start || cancel) begin
      v1 <= 1'b0; v2 <= 1'b0; v3 <= 1'b0;
      consumed <= '0;
      if (rst || start) begin
        for (i = 0; i < 16; i++) begin
          hist_x[i] <= '0;
          hist_y[i] <= '0;
        end
      end
    end else if (adv) begin
      // S0 -> S1
      v1 <= fire;
      if (fire) begin
        hist_x[rank0] <= hx;
        hist_y[rank0] <= hy;
        consumed <= consumed + 1'b1;
      end
      hx1 <= hx; hy1 <= hy;
      en1 <= en0; lfx1 <= lfx0; lfy1 <= lfy0;
      rank1 <= rank0; wm1_1 <= wm1_0; hm1_1 <= hm1_0; bank1 <= bank0; code1 <= code0;
      // S1 -> S2
      v2 <= v1;
      px2 <= pxg[9:0]; py2 <= pyg[9:0];
      en2 <= en1; fx2 <= lfx1 ^ gflipx; fy2 <= lfy1 ^ gflipy;
      rank2 <= rank1; wm1_2 <= wm1_1; hm1_2 <= hm1_1; bank2 <= bank1; code2 <= code1;
      // S2 -> S3
      v3 <= v2 && hit;
      px3 <= px2; fx3 <= fx2;
      r3 <= ee[6:3]; k3 <= ee[2:0];
      rank3 <= rank2; wm1_3 <= wm1_2; bank3 <= bank2; code3 <= code2;
    end
  end
endmodule

// Streams the 256 descriptors in index order, tagged {seq, index}, with up to 2**DEPTH_LOG2 reads outstanding.
module rzspr_descfetch #(
  parameter int CHECK_TAGS = 1,
  parameter int DEPTH_LOG2 = 2,
  parameter int SEQW       = 2,
  parameter int GENW       = 16
) (
  input  logic                clk,
  input  logic                rst,
  input  logic                start,       // pulse: counters/FIFO cleared for a new job
  input  logic                run,         // may issue reads
  input  logic                cancel,      // drain: retire without forwarding
  input  logic [SEQW-1:0]     seq,
  input  logic [GENW-1:0]     gen,
  // request to the GP owner
  output logic                req_valid,
  input  logic                req_ready,
  output logic [7:0]          req_index,
  output logic [SEQW+7:0]     req_tag,
  output logic [GENW-1:0]     req_gen,
  // response from the GP owner
  input  logic                rsp_valid,
  output logic                rsp_ready,
  input  logic [63:0]         rsp_data,
  input  logic [SEQW+7:0]     rsp_tag,
  // descriptors to the scanner, in index order
  output logic                out_valid,
  input  logic                out_ready,
  output logic [63:0]         out_data,
  // status
  output logic                all_issued,
  output logic                idle,        // nothing outstanding, FIFO empty
  output logic                f_stray,
  output logic                f_tag,
  output logic                f_edge
);
  logic [8:0]            issued;      // 0..256
  logic [8:0]            received;    // 0..256
  logic [DEPTH_LOG2:0]   outstanding; // 0..DEPTH
  logic [DEPTH_LOG2:0]   fifo_count;
  logic [DEPTH_LOG2+1:0] slots;
  logic                  req_fire, have_out, tag_ok, take, push;
  logic [SEQW+7:0]       expect_tag;
  logic                  req_hold;    // an offered request is never retracted (cancel only stops new ones)

  assign slots      = {1'b0, outstanding} + {1'b0, fifo_count};
  assign req_valid  = req_hold || (run && !issued[8] && !slots[DEPTH_LOG2+1] && !slots[DEPTH_LOG2]);
  assign req_index  = issued[7:0];
  assign req_tag    = {seq, issued[7:0]};
  assign req_gen    = gen;
  assign req_fire   = req_valid && req_ready;
  assign rsp_ready  = 1'b1;   // every outstanding read has a reserved FIFO slot

  assign have_out   = (outstanding != '0);
  assign expect_tag = {seq, received[7:0]};
  assign tag_ok     = (CHECK_TAGS == 0) || (rsp_tag == expect_tag);
  assign f_stray    = rsp_valid && !have_out && !req_fire;
  assign f_edge     = rsp_valid && !have_out &&  req_fire;
  assign f_tag      = rsp_valid &&  have_out && !tag_ok && !cancel;
  assign take       = rsp_valid && (have_out || req_fire);
  assign push       = rsp_valid && have_out && tag_ok && !cancel;
  assign all_issued = issued[8];
  assign idle       = !have_out && (fifo_count == '0) && !req_hold;

  always_ff @(posedge clk) begin
    if (rst || start) begin
      issued      <= '0;
      received    <= '0;
      outstanding <= '0;
      req_hold    <= 1'b0;
    end else begin
      req_hold <= req_valid && !req_ready;
      if (req_fire) issued   <= issued + 1'b1;
      if (take)     received <= received + 1'b1;
      outstanding <= outstanding + {{DEPTH_LOG2{1'b0}}, req_fire} - {{DEPTH_LOG2{1'b0}}, take};
    end
  end

  /* verilator lint_off UNUSEDSIGNAL */
  logic fifo_in_ready;   // A reserved FIFO slot guarantees ready on a push.
  /* verilator lint_on UNUSEDSIGNAL */

  rzspr_fifo #(.W(64), .DEPTH_LOG2(DEPTH_LOG2)) u_fifo (
    .clk(clk), .rst(rst), .clear(start || cancel),
    .in_valid(push), .in_ready(fifo_in_ready), .in_data(rsp_data),
    .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data),
    .count(fifo_count)
  );
endmodule

// Expands a work item into 8-pixel cells; offscreen cells advance the code without a request.
module rzspr_cellgen
  import rzspr_pkg::*;
#(
  parameter int PROFILE    = PROFILE_GAREGGA,
  parameter int DEPTH_LOG2 = 2
) (
  input  logic [1:0] narrow,   // ROM geometry: 0 native, 1 Sorcer, 2 Kingdom, 3 Garegga
  input  logic                clk,
  input  logic                rst,
  input  logic                cancel,
  // work item from the scanner
  input  logic                w_valid,
  output logic                w_ready,
  input  logic [46:0]         w_data,
  // graphics row request (one outstanding slot per meta entry)
  output logic                g_valid,
  input  logic                g_ready,
  output logic [22:0]         g_addr,
  // placement of the requested cell: {sx[9:0], fx, rank[3:0], bank[5:0]}
  output logic                m_valid,
  output logic [20:0]         m_data,
  input  logic [DEPTH_LOG2:0] m_count,
  output logic                idle
);
  localparam int  CB = code_bits(PROFILE);
  localparam logic [18:0] CODE_MASK = (CB == 0) ? 19'd0 : ((19'd1 << CB) - 19'd1);
  localparam logic [18:0] CODE_MASK_SORCER = (19'd1 << code_bits(PROFILE_SORCER)) - 19'd1;
  localparam logic [18:0] CODE_MASK_KINGDOM = (19'd1 << code_bits(PROFILE_KINGDOM)) - 19'd1;
  localparam logic [18:0] CODE_MASK_GAREGGA = (19'd1 << code_bits(PROFILE_GAREGGA)) - 19'd1;
  wire [18:0] code_mask = narrow == 2'd1 ? (CODE_MASK_SORCER & CODE_MASK) :
                          narrow == 2'd2 ? (CODE_MASK_KINGDOM & CODE_MASK) :
                          narrow == 2'd3 ? (CODE_MASK_GAREGGA & CODE_MASK) : CODE_MASK;

  logic              busy;
  logic [3:0]        remaining;   // cells still to issue after the current one
  logic signed [9:0] sx_cur;
  logic [18:0]       code_cur;
  logic [2:0]        k_q;
  logic              fx_q;
  logic [3:0]        rank_q;
  logic [5:0]        bank_q;

  logic              visible, credit_ok, step, last, load;
  logic [18:0]       code_next;
  logic              hold_q;      // the request offered last cycle was not accepted yet

  assign visible   = (sx_cur >= -10'sd7) && (sx_cur <= 10'sd319);
  assign credit_ok = !m_count[DEPTH_LOG2];
  // under cancel only an already-offered request stays valid
  assign g_valid   = busy && visible && credit_ok && (!cancel || hold_q);
  assign g_addr    = {code_cur, k_q, 1'b0};        // half-byte address 16*code + 2*row
  assign m_valid   = g_valid && g_ready;
  assign m_data    = {sx_cur, fx_q, rank_q, bank_q};
  assign step      = busy && (!visible || (g_valid && g_ready));
  assign last      = step && (remaining == 4'd0);
  assign w_ready   = !busy || last;
  assign load      = w_valid && w_ready;
  assign idle      = !busy;
  assign code_next = (code_cur + 19'd1) & code_mask;

  always_ff @(posedge clk) begin
    if (rst) hold_q <= 1'b0;
    else     hold_q <= g_valid && !g_ready;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      busy <= 1'b0;
    end else if (cancel) begin
      // an offered request is never retracted: wait for its acceptance, then stop
      if (!g_valid || g_ready) busy <= 1'b0;
    end else begin
      if (load) begin
        busy      <= 1'b1;
        code_cur  <= w_data[46:28];
        k_q       <= w_data[27:25];
        sx_cur    <= w_data[24:15];
        fx_q      <= w_data[14];
        remaining <= w_data[13:10];
        rank_q    <= w_data[9:6];
        bank_q    <= w_data[5:0];
      end else if (step) begin
        if (last) busy <= 1'b0;
        remaining <= remaining - 1'b1;
        sx_cur    <= fx_q ? (sx_cur - 10'sd8) : (sx_cur + 10'sd8);
        code_cur  <= code_next;
      end
    end
  end
endmodule

// Double-buffered 320-pixel sprite line in eight lanes (lane = x mod 8); a cell merges in one cycle.
module rzspr_linebuf (
  input  logic              clk,
  input  logic              rst,
  // build side
  input  logic              build_buf,
  input  logic              clear_build,   // pulse: all occupancy bits of build_buf cleared
  input  logic              cell_valid,
  input  logic signed [9:0] cell_sx,       // screen x of the cell's leftmost pixel (-7..319)
  input  logic              cell_fx,       // effective horizontal flip
  input  logic [3:0]        cell_rank,
  input  logic [5:0]        cell_bank,
  input  logic [31:0]       cell_pens,     // pens[4*k +: 4] = source pixel k (left to right)
  // emit side: registered read of entry rd_entry (x[8:3]) of buffer emit_buf
  input  logic              emit_buf,
  input  logic [5:0]        rd_entry,
  output wire  [7:0]        q_valid,       // per lane, one cycle after rd_entry
  output wire  [7:0][13:0]  q_sample       // per lane {rank[3:0], bank[5:0], pen[3:0]}
);
  genvar b;
  generate
    for (b = 0; b < 8; b++) begin : g_lane
      logic [2:0]         j;        // which source pixel of the cell lands in this lane
      logic signed [10:0] x;        // its destination x
      logic               in_range;
      logic [5:0]         e;
      logic [2:0]         kk;       // source column after flip
      logic [3:0]         pen;
      logic               old_v, hit;
      logic [3:0]         old_rank;
      logic [39:0]        vld [0:1];
      logic [3:0]         rnk [0:39];
      logic [13:0]        mem [0:127];   // {buffer, entry}: entries 0..39 of each buffer are used
      logic [13:0]        q_s;
      logic               q_v;
      assign q_sample[b] = q_s;
      assign q_valid[b]  = q_v;

      assign j        = 3'(b) - cell_sx[2:0];
      assign x        = $signed({cell_sx[9], cell_sx}) + $signed({8'b0, j});
      assign in_range = (x >= 11'sd0) && (x <= 11'sd319);
      assign e        = x[8:3];
      assign kk       = cell_fx ? ~j : j;
      assign pen      = cell_pens[4*kk +: 4];
      assign old_v    = vld[build_buf][e];
      assign old_rank = rnk[e];
      // A nonzero pen replaces an empty slot or an occupant of equal or lower rank.
      assign hit     = cell_valid && in_range && (pen != 4'd0) && (!old_v || (cell_rank >= old_rank));

      always_ff @(posedge clk) begin
        if (rst) begin
          vld[0] <= '0;
          vld[1] <= '0;
        end else begin
          if (clear_build) vld[build_buf] <= '0;
          if (hit) begin
            vld[build_buf][e] <= 1'b1;
            rnk[e]            <= cell_rank;
          end
        end
      end

      // simple-dual-port payload RAM, registered read, old-data on collision
      always_ff @(posedge clk) begin
        if (hit) mem[{build_buf, e}] <= {cell_rank, cell_bank, pen};
        q_s <= mem[{emit_buf, rd_entry}];
        q_v <= vld[emit_buf][rd_entry];
      end
    end
  endgenerate
endmodule

// Produces one tagged 320-pixel sprite line: scan 256 descriptors, fetch visible rows, merge, emit.
module rzspr_producer
  import rzspr_pkg::*;
#(
  parameter int PROFILE         = PROFILE_GAREGGA,
  parameter int CHECK_TAGS      = 1,
  parameter int DESC_DEPTH_LOG2 = 2,   // up to 4 descriptor reads outstanding
  parameter int GFX_DEPTH_LOG2  = 3,   // up to 8 graphics reads outstanding
  parameter int TAGW            = 8,
  parameter int GENW            = 16
) (
  input  logic [1:0] narrow,   // ROM geometry: 0 native, 1 Sorcer, 2 Kingdom, 3 Garegga
  input  logic             clk,
  input  logic             rst,
  // line job (snapshot on acceptance)
  input  logic             job_valid,
  output logic             job_ready,
  input  logic [TAGW-1:0]  job_tag,
  input  logic [GENW-1:0]  job_gen,
  input  logic [7:0]       job_y,
  input  logic [8:0]       job_scx,
  input  logic [8:0]       job_scy,
  input  logic             job_gflipx,
  input  logic             job_gflipy,
  input  logic [31:0]      job_banks,
  // descriptor service (GP owner)
  output logic             desc_req_valid,
  input  logic             desc_req_ready,
  output logic [7:0]       desc_req_index,
  output logic [9:0]       desc_req_tag,
  output logic [GENW-1:0]  desc_req_gen,
  input  logic             desc_rsp_valid,
  output logic             desc_rsp_ready,
  input  logic [63:0]      desc_rsp_data,
  input  logic [9:0]       desc_rsp_tag,
  // graphics row service
  output logic             gfx_req_valid,
  input  logic             gfx_req_ready,
  output logic [22:0]      gfx_req_addr,
  output logic [7:0]       gfx_req_tag,
  input  logic             gfx_rsp_valid,
  output logic             gfx_rsp_ready,
  input  logic [31:0]      gfx_rsp_data,
  input  logic [7:0]       gfx_rsp_tag,
  // sprite line samples
  output logic             pix_valid,
  input  logic             pix_ready,
  output logic [TAGW-1:0]  pix_tag,
  output logic [8:0]       pix_x,
  output logic             pix_opaque,
  output logic [3:0]       pix_rank,
  output logic [9:0]       pix_index,
  // completion
  output logic             done_valid,
  input  logic             done_ready,
  output logic [TAGW-1:0]  done_tag,
  output logic [GENW-1:0]  done_gen,
  output logic [1:0]       done_status,
  output logic [8:0]       done_accepted,
  output logic             done_fault_seen,
  // control / observability
  input  logic             flush,
  input  logic             quiesce,
  output logic             idle,
  output logic             busy,
  output logic [6:0]       fault,
  input  logic             fault_ack,
  output logic [2:0]       dbg_state,
  output logic             dbg_scan_done
);
  localparam bit KNOWN = profile_known(PROFILE);
  localparam logic [2:0] S_IDLE = 3'd0, S_START = 3'd1, S_BUILD = 3'd2, S_EMIT = 3'd3,
                         S_CANCEL = 3'd4, S_DONE = 3'd5;

  // ------------------------------------------------------------ job snapshot
  logic [2:0]      state;
  logic [1:0]      seq;
  logic            buf_q;
  logic [TAGW-1:0] tag_q;
  logic [GENW-1:0] gen_q;
  logic [7:0]      y_q;
  logic [8:0]      scx_q, scy_q;
  logic            gfx_q, gfy_q;
  logic [31:0]     banks_q;
  status_e         status_q;
  logic [8:0]      accepted_q;
  logic            fault_seen_q;
  logic            job_fire, done_fire, start, run, cancel, reject;
  logic            flush_at_accept_q;   // a flush in the acceptance edge cancels that job

  assign job_ready = (state == S_IDLE) && !quiesce;
  assign job_fire  = job_valid && job_ready;
  assign done_fire = done_valid && done_ready;
  assign start     = (state == S_START);
  assign run       = (state == S_BUILD);
  assign cancel    = (state == S_CANCEL);
  assign reject    = !KNOWN || (y_q >= 8'(LINES_PER_FRAME));

  // ------------------------------------------------------------ descriptors
  logic        d_valid, d_ready;
  logic [63:0] d_data;
  logic        desc_all_issued, desc_idle, desc_f_stray, desc_f_tag, desc_f_edge;

  rzspr_descfetch #(.CHECK_TAGS(CHECK_TAGS), .DEPTH_LOG2(DESC_DEPTH_LOG2), .SEQW(2), .GENW(GENW)) u_desc (
    .clk(clk), .rst(rst), .start(start), .run(run), .cancel(cancel), .seq(seq), .gen(gen_q),
    .req_valid(desc_req_valid), .req_ready(desc_req_ready), .req_index(desc_req_index),
    .req_tag(desc_req_tag), .req_gen(desc_req_gen),
    .rsp_valid(desc_rsp_valid), .rsp_ready(desc_rsp_ready), .rsp_data(desc_rsp_data), .rsp_tag(desc_rsp_tag),
    .out_valid(d_valid), .out_ready(d_ready), .out_data(d_data),
    .all_issued(desc_all_issued), .idle(desc_idle),
    .f_stray(desc_f_stray), .f_tag(desc_f_tag), .f_edge(desc_f_edge)
  );

  // ------------------------------------------------------------ scanner
  logic        w_valid, w_ready;
  logic [46:0] w_data;
  logic [8:0]  scan_consumed;
  logic        scan_empty;

  rzspr_scan #(.PROFILE(PROFILE)) u_scan (
    .narrow(narrow),
    .clk(clk), .rst(rst), .start(start), .cancel(cancel),
    .y(y_q), .scx(scx_q), .scy(scy_q), .gflipx(gfx_q), .gflipy(gfy_q), .banks(banks_q),
    .d_valid(d_valid), .d_ready(d_ready), .d_data(d_data),
    .w_valid(w_valid), .w_ready(w_ready), .w_data(w_data),
    .consumed(scan_consumed), .empty(scan_empty)
  );

  logic        wf_valid, wf_ready;
  logic [46:0] wf_data;
  logic [1:0]  wf_count;

  rzspr_fifo #(.W(47), .DEPTH_LOG2(1)) u_work (
    .clk(clk), .rst(rst), .clear(start || cancel),
    .in_valid(w_valid), .in_ready(w_ready), .in_data(w_data),
    .out_valid(wf_valid), .out_ready(wf_ready), .out_data(wf_data), .count(wf_count)
  );

  // ------------------------------------------------------------ cells / rows
  logic                     g_valid, g_ready;
  logic [22:0]              g_addr;
  logic                     m_valid;
  logic [20:0]              m_data;
  logic [GFX_DEPTH_LOG2:0]  m_count;
  logic                     cg_idle;
  logic                     mf_valid, mf_ready;
  logic [20:0]              mf_data;
  logic                     gd_valid, gd_ready;
  logic [31:0]              gd_data;
  logic                     gfx_out_zero, gfx_f_stray, gfx_f_tag, gfx_f_edge;

  rzspr_cellgen #(.PROFILE(PROFILE), .DEPTH_LOG2(GFX_DEPTH_LOG2)) u_cell (
    .narrow(narrow),
    .clk(clk), .rst(rst), .cancel(cancel),
    .w_valid(wf_valid), .w_ready(wf_ready), .w_data(wf_data),
    .g_valid(g_valid), .g_ready(g_ready), .g_addr(g_addr),
    .m_valid(m_valid), .m_data(m_data), .m_count(m_count), .idle(cg_idle)
  );

  /* verilator lint_off UNUSEDSIGNAL */
  logic mf_in_ready;   // the cell generator only requests while m_count < depth
  /* verilator lint_on UNUSEDSIGNAL */

  rzspr_fifo #(.W(21), .DEPTH_LOG2(GFX_DEPTH_LOG2), .REGISTER_HEAD(1'b1)) u_meta (
    .clk(clk), .rst(rst), .clear(start || cancel),
    .in_valid(m_valid), .in_ready(mf_in_ready), .in_data(m_data),
    .out_valid(mf_valid), .out_ready(mf_ready), .out_data(mf_data), .count(m_count)
  );

  rzspr_gfxfetch #(.CHECK_TAGS(CHECK_TAGS), .DEPTH_LOG2(GFX_DEPTH_LOG2), .SEQW(2), .CNTW(6)) u_gfx (
    .clk(clk), .rst(rst), .start(start), .cancel(cancel), .seq(seq),
    .in_valid(g_valid), .in_ready(g_ready), .in_addr(g_addr),
    .req_valid(gfx_req_valid), .req_ready(gfx_req_ready), .req_addr(gfx_req_addr), .req_tag(gfx_req_tag),
    .rsp_valid(gfx_rsp_valid), .rsp_ready(gfx_rsp_ready), .rsp_data(gfx_rsp_data), .rsp_tag(gfx_rsp_tag),
    .d_valid(gd_valid), .d_ready(gd_ready), .d_data(gd_data),
    .outstanding_zero(gfx_out_zero), .f_stray(gfx_f_stray), .f_tag(gfx_f_tag), .f_edge(gfx_f_edge)
  );

  // ------------------------------------------------------------ writer
  logic [31:0] pens;
  logic        cell_valid;
  rzspr_rowdec u_dec (.raw(gd_data), .pens(pens));

  assign cell_valid = run && mf_valid && gd_valid;
  assign mf_ready   = cell_valid;
  assign gd_ready   = cell_valid;

  logic [7:0]       q_valid;
  logic [7:0][13:0] q_sample;
  logic [5:0]       rd_entry;

  rzspr_linebuf u_buf (
    .clk(clk), .rst(rst),
    .build_buf(buf_q), .clear_build(start),
    .cell_valid(cell_valid), .cell_sx(mf_data[20:11]), .cell_fx(mf_data[10]),
    .cell_rank(mf_data[9:6]), .cell_bank(mf_data[5:0]), .cell_pens(pens),
    .emit_buf(buf_q), .rd_entry(rd_entry), .q_valid(q_valid), .q_sample(q_sample)
  );

  logic build_done, abort_now;
  assign build_done = desc_all_issued && desc_idle && (scan_consumed == 9'(DESCRIPTORS)) && scan_empty
                      && (wf_count == 2'd0) && cg_idle && (m_count == '0) && gfx_out_zero;
  assign abort_now  = desc_f_tag || desc_f_edge || gfx_f_tag || gfx_f_edge;
  assign dbg_scan_done = (scan_consumed == 9'(DESCRIPTORS));

  // ------------------------------------------------------------ emitter
  logic [8:0]  x_rd, rd_x_q;
  logic        rd_pending;
  logic [2:0]  rd_lane_q;
  logic [2:0]  of_count;
  logic        of_room;
  logic        can_read, of_in_valid, of_out_valid, of_out_ready, pix_fire, last_accept;
  logic [23:0] of_in_data, of_out_data;
  logic [13:0] lane_sample;
  logic        lane_v;

  // the output FIFO has four entries; count the read in flight as an occupant
  assign of_room     = ({1'b0, of_count} + {3'b000, rd_pending}) < 4'd4;
  assign can_read    = (state == S_EMIT) && (x_rd != 9'(PIXELS_PER_LINE)) && of_room;
  assign rd_entry    = x_rd[8:3];
  assign lane_sample = q_sample[rd_lane_q];
  assign lane_v      = q_valid[rd_lane_q];
  assign of_in_valid = rd_pending;
  assign of_in_data  = {rd_x_q, lane_v, (lane_v ? lane_sample : 14'd0)};

  /* verilator lint_off UNUSEDSIGNAL */
  logic of_in_ready;   // The output slot count reserves space for this response.
  /* verilator lint_on UNUSEDSIGNAL */

  rzspr_fifo #(.W(24), .DEPTH_LOG2(2)) u_out (
    .clk(clk), .rst(rst), .clear(start || cancel),
    .in_valid(of_in_valid), .in_ready(of_in_ready), .in_data(of_in_data),
    .out_valid(of_out_valid), .out_ready(of_out_ready), .out_data(of_out_data), .count(of_count)
  );

  assign pix_valid    = of_out_valid && (state == S_EMIT);
  assign of_out_ready = pix_ready && (state == S_EMIT);
  assign pix_fire     = pix_valid && pix_ready;
  assign pix_tag      = tag_q;
  assign pix_x        = of_out_data[23:15];
  assign pix_opaque   = of_out_data[14];
  assign pix_rank     = of_out_data[13:10];
  assign pix_index    = of_out_data[9:0];
  assign last_accept  = pix_fire && (accepted_q == 9'(PIXELS_PER_LINE - 1));

  always_ff @(posedge clk) begin
    if (rst || start || cancel) begin
      x_rd       <= '0;
      rd_pending <= 1'b0;
      rd_lane_q  <= '0;
      rd_x_q     <= '0;
    end else if (can_read) begin
      rd_pending <= 1'b1;
      rd_lane_q  <= x_rd[2:0];
      rd_x_q     <= x_rd;
      x_rd       <= x_rd + 1'b1;
    end else begin
      rd_pending <= 1'b0;
    end
  end

  // ------------------------------------------------------------ completion
  assign done_valid      = (state == S_DONE);
  assign done_tag        = tag_q;
  assign done_gen        = gen_q;
  assign done_status     = status_q;
  assign done_accepted   = accepted_q;
  assign done_fault_seen = fault_seen_q;
  assign idle            = (state == S_IDLE) && desc_idle && gfx_out_zero;
  assign busy            = (state != S_IDLE);
  assign dbg_state       = state;

  // ------------------------------------------------------------ faults
  logic       pend_q, f_job_drop;
  logic [6:0] fault_pulse;
  assign f_job_drop  = pend_q && !job_valid;
  assign fault_pulse = {f_job_drop, gfx_f_edge, gfx_f_tag, gfx_f_stray, desc_f_edge, desc_f_tag, desc_f_stray};

  always_ff @(posedge clk) begin
    if (rst) begin
      fault  <= '0;
      pend_q <= 1'b0;
    end else begin
      fault  <= (fault_ack ? 7'd0 : fault) | fault_pulse;
      pend_q <= job_valid && !job_ready;
    end
  end

  // ------------------------------------------------------------ job FSM
  always_ff @(posedge clk) begin
    if (rst) begin
      state        <= S_IDLE;
      seq          <= '0;
      buf_q        <= 1'b0;
      status_q     <= ST_COMPLETE;
      accepted_q   <= '0;
      fault_seen_q <= 1'b0;
      tag_q        <= '0;
      gen_q        <= '0;
      y_q          <= '0;
      scx_q        <= '0;
      scy_q        <= '0;
      gfx_q        <= 1'b0;
      gfy_q        <= 1'b0;
      banks_q      <= '0;
      flush_at_accept_q <= 1'b0;
    end else begin
      if (pix_fire) accepted_q <= accepted_q + 1'b1;
      if ((|fault_pulse) && (state != S_IDLE)) fault_seen_q <= 1'b1;
      case (state)
        S_IDLE: begin
          if (job_fire) begin
            tag_q        <= job_tag;
            gen_q        <= job_gen;
            y_q          <= job_y;
            scx_q        <= job_scx;
            scy_q        <= job_scy;
            gfx_q        <= job_gflipx;
            gfy_q        <= job_gflipy;
            banks_q      <= job_banks;
            seq          <= seq + 1'b1;
            buf_q        <= ~buf_q;
            accepted_q   <= '0;
            fault_seen_q <= 1'b0;
            status_q     <= ST_COMPLETE;
            flush_at_accept_q <= flush;
            state        <= S_START;
          end
        end
        S_START: begin
          if (reject) begin
            status_q <= ST_REJECTED;
            state    <= S_DONE;
          end else if (flush || flush_at_accept_q) begin
            status_q <= ST_CANCELLED;
            state    <= S_DONE;
          end else begin
            state    <= S_BUILD;
          end
        end
        S_BUILD: begin
          if (abort_now) begin
            status_q <= ST_FAULTED;
            state    <= S_CANCEL;
          end else if (flush) begin
            status_q <= ST_CANCELLED;
            state    <= S_CANCEL;
          end else if (build_done) begin
            state    <= S_EMIT;
          end
        end
        S_EMIT: begin
          if (last_accept) begin
            state    <= S_DONE;
          end else if (flush) begin
            status_q <= ST_CANCELLED;
            state    <= S_CANCEL;
          end
        end
        S_CANCEL: begin
          // every offered request has been accepted and every reply retired
          if (desc_idle && gfx_out_zero && cg_idle) state <= S_DONE;
        end
        S_DONE: begin
          if (done_fire) state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end
endmodule

// Raster job ownership and complete-only publication for rzspr_producer.
module rzspr_scanline #(
    parameter integer PROFILE=2, MEM_AW=23,
    parameter logic [8:0] X_BIAS=9'h1cc, X_FLIP_BIAS=9'h17b,
    parameter logic [8:0] Y_BIAS=9'h1ef, Y_FLIP_BIAS=9'h108
) (
    input logic [1:0] narrow,   // ROM geometry: 0 native, 1 Sorcer, 2 Kingdom, 3 Garegga
    input logic early_bias,     // early boards' sprite Y origins (0x1ed / 0x10a)
    input logic clk,rst,pixel_ce,active,lhbl,lvbl,drain,
    input logic [8:0] h,render_y,
    input logic flip_x,flip_y,
    input logic [15:0] scroll_x,
    input logic [31:0] banks,
    output wire gp_acquire,gp_release,
    input logic gp_held,gp_job_valid,
    input logic [15:0] gp_job_seq,gp_job_y,
    input logic gp_job_y_valid,
    output wire gp_read,
    output wire [7:0] gp_index,
    input logic gp_read_valid,gp_read_gen_valid,
    input logic [15:0] gp_read_seq,
    input logic [63:0] gp_entry,
    output wire rom_req_valid,
    input logic rom_req_ready,
    output wire [MEM_AW-1:0] rom_req_addr,
    input logic rom_rsp_valid,
    output wire rom_rsp_ready,
    input logic [31:0] rom_rsp_data,
    input logic rom_rsp_error,
    output wire idle,
    output logic [14:0] pixel,
    output logic deadline_miss,row_skipped,
    output wire fault
);
    typedef enum logic [2:0] {WAIT_LINE,ACQUIRE,OFFER,RENDER,RELEASE_VIEW} phase_t;
    phase_t phase;
    logic was_active,expired,line_complete,display_valid,display_bank,local_fault;
    logic [7:0] line_tag,job_y;
    logic [8:0] job_scx,job_scy;
    logic [15:0] job_gen;
    logic job_flip_x,job_flip_y;
    logic [31:0] job_banks;
    wire start_edge=h==0 && lhbl && !was_active && (lvbl || render_y==0 || render_y==239) && render_y<240;
    wire publish=pixel_ce && h==431;
    wire job_ready,producer_idle;
    wire desc_valid,desc_ready,desc_reply,desc_take,desc_error,desc_idle,desc_fault;
    wire [7:0] desc_index;
    wire [9:0] desc_tag,desc_reply_tag;
    wire [15:0] desc_generation;
    wire [63:0] desc_data;
    wire [22:0] half_address;
    wire [31:0] row_word;
    wire [7:0] row_tag,pix_tag,done_tag;
    logic [7:0] row_reply_tag;
    wire sample_valid,sample_opaque,done_valid,done_fault;
    wire [8:0] sample_x,done_count;
    wire [3:0] sample_rank;
    wire [9:0] sample_index;
    wire [15:0] done_gen;
    wire [1:0] done_status;
    wire [6:0] producer_fault;
    wire good_done=done_valid && done_status==0 && done_count==320 &&
                   done_tag==line_tag && done_gen==job_gen && !done_fault && !expired;

    assign idle=phase==WAIT_LINE && !gp_held && producer_idle && desc_idle;
    assign gp_acquire=!rst && !drain && start_edge && idle;
    assign gp_release=!rst && phase==RELEASE_VIEW && gp_held;
    assign fault=local_fault || desc_fault || (|producer_fault);

    rzsprite_gp_read #(.TAG_W(10)) descriptors (
        .clk(clk),.rst(rst),.admit(gp_held && gp_job_valid),.generation(desc_generation),
        .req_valid(desc_valid),.req_ready(desc_ready),.req_index(desc_index),.req_tag(desc_tag),
        .rsp_valid(desc_reply),.rsp_ready(desc_take),.rsp_entry(desc_data),.rsp_tag(desc_reply_tag),.rsp_error(desc_error),
        .gp_en(gp_read),.gp_index(gp_index),.gp_valid(gp_read_valid),.gp_generation_valid(gp_read_gen_valid),
        .gp_generation(gp_read_seq),.gp_entry(gp_entry),.idle(desc_idle),.fault(desc_fault));
    rzsprite_rom_wires #(.MEM_AW(MEM_AW)) rom_wires (
        .half_address(half_address),.cache_address(rom_req_addr),.cache_word(rom_rsp_data),.row_word(row_word));
    // The ROM port has one outstanding request; its reply carries the last request tag.
    always @(posedge clk) begin
        if(rst)row_reply_tag<=0;
        else if(rom_req_valid && rom_req_ready)row_reply_tag<=row_tag;
    end
    rzspr_producer #(.PROFILE(PROFILE)) producer (
        .narrow(narrow),
        .clk(clk),.rst(rst),.job_valid(phase==OFFER),.job_ready(job_ready),.job_tag(line_tag),
        .job_gen(job_gen),.job_y(job_y),.job_scx(job_scx),.job_scy(job_scy),
        .job_gflipx(job_flip_x),.job_gflipy(job_flip_y),.job_banks(job_banks),
        .desc_req_valid(desc_valid),.desc_req_ready(desc_ready),.desc_req_index(desc_index),
        .desc_req_tag(desc_tag),.desc_req_gen(desc_generation),
        .desc_rsp_valid(desc_reply),.desc_rsp_ready(desc_take),.desc_rsp_data(desc_data),
        .desc_rsp_tag(desc_reply_tag ^ (desc_error ? 10'h200 : 10'd0)),
        .gfx_req_valid(rom_req_valid),.gfx_req_ready(rom_req_ready),.gfx_req_addr(half_address),.gfx_req_tag(row_tag),
        .gfx_rsp_valid(rom_rsp_valid),.gfx_rsp_ready(rom_rsp_ready),.gfx_rsp_data(row_word),
        .gfx_rsp_tag(row_reply_tag ^ (rom_rsp_error ? 8'h80 : 8'd0)),
        .pix_valid(sample_valid),.pix_ready(1'b1),.pix_tag(pix_tag),.pix_x(sample_x),
        .pix_opaque(sample_opaque),.pix_rank(sample_rank),.pix_index(sample_index),
        .done_valid(done_valid),.done_ready(1'b1),.done_tag(done_tag),.done_gen(done_gen),
        .done_status(done_status),.done_accepted(done_count),.done_fault_seen(done_fault),
        .flush(expired || publish),.quiesce(1'b0),.idle(producer_idle),.busy(),.fault(producer_fault),
        .fault_ack(1'b0),.dbg_state(),.dbg_scan_done());

    // Writes target only the unpublished line bank without clearing its data RAM.
    (* ramstyle="M10K, no_rw_check" *) logic [14:0] lines [0:1023];
    logic [14:0] scan_pixel;
    always @(posedge clk) begin
        scan_pixel<=lines[{display_bank,h}];
        if(!rst && phase==RENDER && !expired && !publish && sample_valid && pix_tag==line_tag)
            lines[{!display_bank,sample_x}]<=sample_opaque ? {sample_rank,1'b0,sample_index} : 15'd0;
        if(rst)pixel<=0;
        else if(pixel_ce && active)pixel<=display_valid ? scan_pixel : 15'd0;
    end

    always @(posedge clk) begin
        if(rst) begin
            phase<=WAIT_LINE;was_active<=0;expired<=0;line_complete<=0;display_valid<=0;display_bank<=0;
            local_fault<=0;deadline_miss<=0;row_skipped<=0;line_tag<=0;job_y<=0;job_gen<=0;
            job_scx<=0;job_scy<=0;job_flip_x<=0;job_flip_y<=0;job_banks<=0;
        end else begin
            was_active<=lhbl;
            if(start_edge && !drain && !idle)row_skipped<=1;
            case(phase)
                WAIT_LINE: if(gp_acquire)begin
                    phase<=ACQUIRE;expired<=0;line_tag<=line_tag+1'b1;
                    job_y<=render_y[7:0];job_flip_x<=flip_x;job_flip_y<=flip_y;job_banks<=banks;
                    job_scx<=scroll_x[8:0]-(flip_x ? X_FLIP_BIAS : X_BIAS);
                end
                ACQUIRE: begin
                    if(!gp_held)begin phase<=WAIT_LINE;local_fault<=1;end
                    else if(!gp_job_valid || publish || expired)phase<=RELEASE_VIEW;
                    else begin
                        phase<=OFFER;job_gen<=gp_job_seq;
                        job_scy<=(gp_job_y_valid ? gp_job_y[8:0] : 9'd0)-
                            (job_flip_y ? (early_bias ? 9'h10a : Y_FLIP_BIAS) : (early_bias ? 9'h1ed : Y_BIAS));
                    end
                end
                OFFER: if(job_ready)phase<=RENDER;
                RENDER: if(done_valid)begin
                    phase<=RELEASE_VIEW;
                    if(good_done)line_complete<=1;
                    else if(done_status!=1 || !expired)local_fault<=1;
                end
                RELEASE_VIEW: phase<=WAIT_LINE;
                default: phase<=WAIT_LINE;
            endcase
            if(sample_valid && pix_tag!=line_tag)local_fault<=1;
            if(publish)begin
                display_valid<=line_complete || good_done;
                if(line_complete || good_done)display_bank<=!display_bank;
                line_complete<=0;
                if((phase==ACQUIRE && gp_job_valid) || phase==OFFER || (phase==RENDER && !done_valid))begin
                    expired<=1;deadline_miss<=1;
                end
            end
        end
    end
endmodule

// GP descriptor read with a one-cycle response, held while rsp_ready is low.
module rzsprite_gp_read #(parameter integer TAG_W=8) (
    input logic clk,rst,admit,
    input logic [15:0] generation,
    input logic req_valid,
    output wire req_ready,
    input logic [7:0] req_index,
    input logic [TAG_W-1:0] req_tag,
    output wire rsp_valid,
    input logic rsp_ready,
    output wire [63:0] rsp_entry,
    output logic [TAG_W-1:0] rsp_tag,
    output wire rsp_error,
    output wire gp_en,
    output wire [7:0] gp_index,
    input logic gp_valid,gp_generation_valid,
    input logic [15:0] gp_generation,
    input logic [63:0] gp_entry,
    output wire idle,
    output logic fault
);
    logic pending,held_reply,saved_error;
    logic [15:0] expected_generation;
    logic [63:0] saved_entry;
    wire bad_reply=!gp_valid || !gp_generation_valid || gp_generation!=expected_generation;

    assign req_ready=!rst && admit && (!pending || rsp_ready);
    assign gp_en=req_valid && req_ready;
    assign gp_index=req_index;
    assign rsp_valid=!rst && pending;
    assign rsp_error=rsp_valid && (held_reply ? saved_error : bad_reply);
    assign rsp_entry=held_reply ? saved_entry : bad_reply ? 64'd0 : gp_entry;
    assign idle=!pending;

    always_ff @(posedge clk) begin
        if(rst)begin
            pending<=0;held_reply<=0;saved_error<=0;fault<=0;
            rsp_tag<=0;expected_generation<=0;saved_entry<=0;
        end else begin
            pending<=gp_en || (pending && !rsp_ready);
            held_reply<=pending && !rsp_ready;
            if(gp_en)begin
                rsp_tag<=req_tag;
                expected_generation<=generation;
            end
            if(pending && !held_reply)begin
                if(!rsp_ready)begin
                    saved_error<=bad_reply;
                    saved_entry<=bad_reply ? 64'd0 : gp_entry;
                end
                if(bad_reply)fault<=1;
            end
        end
    end
endmodule

// Producer rows use byte offsets in one ROM half; object caches use packed bytes.
module rzsprite_rom_wires #(parameter integer MEM_AW=24) (
    input wire [22:0] half_address,
    output wire [MEM_AW-1:0] cache_address,
    input wire [31:0] cache_word,
    output wire [31:0] row_word
);
    assign cache_address=MEM_AW'({half_address,1'b0});
    // Cache stream: H0[a], H1[a], H0[a+1], H1[a+1], most-significant byte per halfword first.
    assign row_word={cache_word[23:16],cache_word[7:0],cache_word[31:24],cache_word[15:8]};
endmodule
