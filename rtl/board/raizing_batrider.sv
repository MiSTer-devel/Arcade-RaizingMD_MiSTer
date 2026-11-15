// SPDX-License-Identifier: GPL-3.0-or-later
// Batrider sound, audio filter and score modules.

// PCM low-pass at 192 kHz: two cascaded Sallen-Key biquads on one shared 32x16 multiplier.
`timescale 1ns/1ps
module rzbatrider_audio_filter (
  input  logic               clk,
  input  logic               reset,
  input  logic               hold,
  input  logic               sample,
  input  logic signed [15:0] din,
  output logic signed [15:0] dout
);
// Q30 coefficients from the RC values; denominator 1 + A1*z^-1 + A2*z^-2.
localparam logic signed [31:0] S1_B0 = 32'sd212531562;
localparam logic signed [31:0] S1_B1 = 32'sd425063124;
localparam logic signed [31:0] S1_B2 = 32'sd212531562;
localparam logic signed [31:0] S1_A1 = -32'sd967644436;
localparam logic signed [31:0] S1_A2 = 32'sd744028860;
localparam logic signed [31:0] S2_B0 = 32'sd26112195;
localparam logic signed [31:0] S2_B1 = 32'sd52224390;
localparam logic signed [31:0] S2_B2 = 32'sd26112195;
localparam logic signed [31:0] S2_A1 = -32'sd1641951548;
localparam logic signed [31:0] S2_A2 = 32'sd672658505;

  // Negated feedback coefficients.
  localparam logic signed [31:0] S1_NA1 = -S1_A1;
  localparam logic signed [31:0] S1_NA2 = -S1_A2;
  localparam logic signed [31:0] S2_NA1 = -S2_A1;
  localparam logic signed [31:0] S2_NA2 = -S2_A2;

  function automatic logic signed [15:0] sat16(input logic signed [55:0] a);
    logic signed [55:0] q;
    q = a >>> 30;                                    // floor(a / 2^30)
    if (q > 56'sd32767)       sat16 = 16'sh7FFF;
    else if (q < -56'sd32768) sat16 = 16'sh8000;
    else                      sat16 = q[15:0];
  endfunction

  logic               busy;
  logic [3:0]         step;
  logic signed [15:0] xin, u, w;
  logic signed [15:0] s1x1, s1x2, s1y1, s1y2, s2x1, s2x2, s2y1, s2y2;
  logic signed [47:0] prod;
  logic signed [55:0] acc;

  // multiplier operands for this step
  logic signed [31:0] mc;
  logic signed [15:0] md;
  always_comb begin
    case (step)
      4'd1:    begin mc = S1_B0;  md = xin;  end
      4'd2:    begin mc = S1_B1;  md = s1x1; end
      4'd3:    begin mc = S1_B2;  md = s1x2; end
      4'd4:    begin mc = S1_NA1; md = s1y1; end
      4'd5:    begin mc = S1_NA2; md = s1y2; end
      4'd8:    begin mc = S2_B0;  md = u;    end
      4'd9:    begin mc = S2_B1;  md = s2x1; end
      4'd10:   begin mc = S2_B2;  md = s2x2; end
      4'd11:   begin mc = S2_NA1; md = s2y1; end
      4'd12:   begin mc = S2_NA2; md = s2y2; end
      default: begin mc = 32'sd0; md = 16'sd0; end
    endcase
  end
  wire signed [15:0] y_now = sat16(acc);
  wire signed [55:0] prod56 = {{8{prod[47]}}, prod};

  always_ff @(posedge clk) begin
    if (reset) begin
      busy <= 1'b0; step <= 4'd0; dout <= 16'sd0; xin <= 16'sd0; u <= 16'sd0; w <= 16'sd0;
      s1x1 <= 16'sd0; s1x2 <= 16'sd0; s1y1 <= 16'sd0; s1y2 <= 16'sd0;
      s2x1 <= 16'sd0; s2x2 <= 16'sd0; s2y1 <= 16'sd0; s2y2 <= 16'sd0;
      prod <= 48'sd0; acc <= 56'sd0;
    end else if (!hold) begin
      if (!busy) begin
        if (sample) begin
          xin <= din; busy <= 1'b1; step <= 4'd1;    // acceptance edge 0
        end
      end else begin
        prod <= mc * md;
        case (step)
          4'd2, 4'd9:                acc <= prod56;
          4'd3, 4'd4, 4'd5, 4'd6,
          4'd10, 4'd11, 4'd12, 4'd13: acc <= acc + prod56;
          4'd7: begin
            u <= y_now;
            s1x2 <= s1x1; s1x1 <= xin; s1y2 <= s1y1; s1y1 <= y_now;
          end
          4'd14: begin
            w <= y_now;
            s2x2 <= s2x1; s2x1 <= u; s2y2 <= s2y1; s2y1 <= y_now;
          end
          4'd15: begin
            dout <= w; busy <= 1'b0;                 // published on the 15th non-held edge
          end
          default: ;
        endcase
        step <= (step == 4'd15) ? 4'd0 : step + 4'd1;
      end
    end
  end
endmodule

// YM2151 owner: IKAOPM chip CE/reset and save-state chunk 20 (267 byte items <-> 31-word 0x5A31 image).
module rzbatrider_opm_owner #(
    parameter [7:0] SS_INDEX = 8'd20,
    parameter integer RESPONSE_TIMEOUT = 1024,      // wrapper bound is 512
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

    // ---------------------------------------------------------- chip reset and CE
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
    wire cen_d=ym_ce && (svc_q || (!cpu_held && !pcm_refill));
    /* verilator lint_off PROCASSINIT */
    (* preserve *) reg cen_q=1'b0;
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
    // Socket sk_opm: pins of the shared rzopm_top instance.
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
    // Words 1-28: high-register items; word 29: eight low registers; word 30: selector/AMD/PMD/key nibbles (items 256-266).
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
    reg [7:0] fail_code_q;              // {step,status} of the first failure
    wire [3:0] n_items=word==5'd30 ? 4'd11 : 4'd8;
    wire [7:0] code_now={step,rsp_status},code_to={4'hf,step},code_phase={step,4'hd},code_step={step,4'hc};
    wire [5:0] cur_idx={1'b0,word},next_idx={1'b0,word+5'd1};
    wire [63:0] hdr_word={16'h0000,sum,8'h00,8'd31,16'h5a31};
    wire capture_due=canonical_hold && cpu_canonical_ready && !captured_q && !fault_q;
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

    // OWN_ISSUE sends a request; OWN_HARD faults and recovers the chip; OWN_SOFT retries via status, then OWN_HARD.
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

// OKI banking: eight 4-bit entries (0-3 chip 0, 4-7 chip 1); a write sets entries offset and offset+1.
`default_nettype none

module rzoki_batrider_bank (
    input  wire        clk,
    input  wire        reset,
    input  wire        hold,
    input  wire        restore,
    input  wire [31:0] restore_state,
    output wire [31:0] capture_state,
    input  wire        write,
    input  wire [7:0]  data,
    input  wire [2:0]  offset,
    input  wire [17:0] address,
    output wire [19:0] rom_address,
    input  wire [17:0] address1,
    output wire [19:0] rom1_address
);

    reg [31:0] bank_q;

    // Entry receiving the high nibble: the next index modulo eight.
    wire [2:0] high_index = offset + 3'd1;

    always @(posedge clk) begin
        if (reset) begin
            bank_q <= 32'h0000_0000;
        end else if (restore) begin
            bank_q <= restore_state;
        end else if (write && !hold) begin
            bank_q[{offset, 2'b00} +: 4]     <= data[3:0];
            bank_q[{high_index, 2'b00} +: 4] <= data[7:4];
        end
    end

    assign capture_state = bank_q;

    // Chip address 00000-003ff: entry a[9:8] (256-byte table pages); 00400-3ffff: entry a[17:16] (64 KiB windows).
    function [1:0] page_entry;
        input [17:0] a;
        begin
            if (a[17:10] == 8'h00)
                page_entry = a[9:8];
            else
                page_entry = a[17:16];
        end
    endfunction

    wire [15:0] chip0_table = bank_q[15:0];
    wire [15:0] chip1_table = bank_q[31:16];

    wire [1:0] entry0 = page_entry(address);
    wire [3:0] bank0  = chip0_table[{entry0, 2'b00} +: 4];
    assign rom_address = {bank0, address[15:0]};

    wire [1:0] entry1 = page_entry(address1);
    wire [3:0] bank1  = chip1_table[{entry1, 2'b00} +: 4];
    assign rom1_address = {bank1, address1[15:0]};

endmodule

`default_nettype wire

// Batrider sound: Z80, YM2151, two OKI M6295 with banking, mailbox, mixer and PCM filter.
module rzbatrider_sound (
    output raizing_socket_pkg::oki_in_t sk_oki_i,
    input raizing_socket_pkg::oki_out_t sk_oki_o,

    output raizing_socket_pkg::opm_in_t sk_opm_i,
    input raizing_socket_pkg::opm_out_t sk_opm_o,

    output raizing_socket_pkg::z80_in_t sk_z80_i,
    input raizing_socket_pkg::z80_out_t sk_z80_o,

    input wire clk, reset, cpu_reset, z80_ce, ym_ce, ym_phase1_ce, oki_ce,
    input wire [2:0] mailbox_write,
    input wire [7:0] mailbox_data,
    input wire mailbox_restore, mailbox_wait_active,
    input wire [31:0] mailbox_restore_data,
    output wire [31:0] mailbox_capture,
    output wire mailbox_wait_grant, mailbox_start_wait, mailbox_bus_request,
    input wire bus_request,
    output wire [7:0] sound_latch3, sound_latch4,
    output wire sound_wait,
    output logic sound_irq,
    output wire bus_ack,
    input wire hold_request, canonical_hold, restore_commit,
    output wire held, replay_busy, restore_busy, canonical_ready, canonical_fault, canonical_service,
    output wire [17:0] rom_address,
    output wire rom_request,
    input wire [7:0] rom_data,
    input wire rom_ok,
    output wire [12:0] shared_address,
    output wire [7:0] shared_data_out,
    output wire shared_write,
    input wire [7:0] shared_data_in,
    output wire [19:0] pcm_address, pcm1_address,
    output wire pcm_request, pcm1_request, pcm_frozen, pcm1_frozen, pcm_resume_busy, pcm1_resume_busy,
    input wire [7:0] pcm_data, pcm1_data,
    input wire pcm_ok, pcm1_ok,
    output wire signed [15:0] audio,
    output wire sample,
    input wire [1:0] fx_level,
    input wire fm_enable, pcm_enable,
    input wire [63:0] SS_DATA,
    input wire [31:0] SS_ADDR,
    input wire [7:0] SS_SELECT,
    input wire SS_WRITE, SS_READ, SS_QUERY,
    output wire [63:0] SS_DATA_OUT,
    output wire SS_ACK
);
    wire cpu_held, cpu_ready, cpu_fault, busak_n, rd_n, wr_n, mreq_n, iorq_n, m1_n;
    wire [15:0] address;
    wire [7:0] cpu_data, cpu_input;
    wire [7:0] port = address[7:0];
    wire live = !reset && !cpu_reset;
    wire mem_read = live && !mreq_n && !rd_n;
    wire shared_select = address[15:13] == 3'b110;
    wire io_select = live && !iorq_n && m1_n;
    wire io_read = io_select && !rd_n;
    wire io_write = io_select && !wr_n;
    logic io_history, cpu_ce_permitted;
    wire io_event = io_write && !io_history && !cpu_held;
    wire pcm_refill = pcm_resume_busy || pcm1_resume_busy;
    wire opm_select = io_select && port[7:1] == 7'h40;
    wire opm_int_n, opm_fault, opm_sample;
    wire [7:0] opm_data;
    wire signed [15:0] fm_left, fm_right;
    wire [7:0] oki_status [0:1];
    wire [17:0] oki_address [0:1];
    wire signed [13:0] oki_sound [0:1];
    wire mailbox_nmi, mailbox_irq, mailbox_hit, saved_nmi, saved_wait, saved_history;
    wire nmi_n = !mailbox_nmi;
    wire busrq_n = !bus_request;
    wire [7:0] mailbox_result, saved_reply0, saved_reply1;
    logic [7:0] mailbox_compat;
    wire [255:0] cpu_capture, cpu_staged;
    wire [63:0] control_staged;
    wire [3:0] bank_state;
    wire [31:0] sample_bank_state;
    wire [4:0] state_ack;
    wire [63:0] state_response [0:4];

    assign rom_request = mem_read && address < 16'hc000;
    assign shared_address = address[12:0];
    assign shared_data_out = cpu_data;
    assign shared_write = live && !mreq_n && !wr_n && shared_select && !cpu_held && busak_n;
    assign bus_ack = live && !busak_n;
    assign cpu_input = rom_request ? rom_data :
                       (mem_read && shared_select) ? shared_data_in :
                       mailbox_hit ? mailbox_result :
                       (io_read && opm_select) ? opm_data :
                       (io_read && port == 8'h82) ? oki_status[0] :
                       (io_read && port == 8'h84) ? oki_status[1] : 8'hff;

    wire devices_quiet = pcm_frozen && pcm1_frozen && !replay_busy && !restore_busy;
    assign held = cpu_held && devices_quiet;
    assign canonical_ready = cpu_ready && devices_quiet;
    assign canonical_fault = cpu_fault || opm_fault;
    assign mailbox_capture[31:24] = mailbox_compat;

    always_ff @(posedge clk) begin
        if (reset) begin
            io_history <= 1'b0;
            cpu_ce_permitted <= 1'b1;
            mailbox_compat <= 8'b0;
            sound_irq <= 1'b0;
        end else begin
            if (restore_commit) io_history <= control_staged[55];
            else if (!cpu_held) io_history <= io_write;

            if (cpu_held || restore_commit) cpu_ce_permitted <= 1'b0;
            else if (!pcm_refill) cpu_ce_permitted <= 1'b1;

            if (mailbox_restore) mailbox_compat <= mailbox_restore_data[31:24];
            else if (mailbox_write[2]) mailbox_compat <= 8'b0;
            sound_irq <= !restore_commit && mailbox_irq;
        end
    end

    // Socket sk_z80: pins of the shared raizing_z80 instance.
    assign sk_z80_i.clk = clk;
    assign sk_z80_i.reset = reset || cpu_reset;
    assign sk_z80_i.cen = z80_ce && (cpu_ce_permitted || restore_busy);
    assign sk_z80_i.wait_n = !rom_request || rom_ok;
    assign sk_z80_i.int_n = opm_int_n;
    assign sk_z80_i.hold_request = hold_request || replay_busy;
    assign sk_z80_i.nmi_n = nmi_n;
    assign sk_z80_i.busrq_n = busrq_n;
    assign sk_z80_i.canonical_hold = canonical_hold;
    assign sk_z80_i.restore = restore_commit;
    assign sk_z80_i.restore_state = cpu_staged;
    assign sk_z80_i.data_in = cpu_input;
    assign busak_n = sk_z80_o.busak_n;
    assign cpu_held = sk_z80_o.held;
    assign cpu_ready = sk_z80_o.canonical_ready;
    assign canonical_service = sk_z80_o.canonical_service;
    assign restore_busy = sk_z80_o.restore_busy;
    assign cpu_fault = sk_z80_o.canonical_fault;
    assign cpu_capture = sk_z80_o.capture_state;
    assign address = sk_z80_o.address;
    assign cpu_data = sk_z80_o.data_out;
    assign rd_n = sk_z80_o.rd_n;
    assign wr_n = sk_z80_o.wr_n;
    assign mreq_n = sk_z80_o.mreq_n;
    assign iorq_n = sk_z80_o.iorq_n;
    assign m1_n = sk_z80_o.m1_n;

    rzsnd_mailbox #(.PROFILE(4)) mb (
        .clk(clk), .board_reset(reset), .hold(1'b0),
        .m_cmd0_wr(mailbox_write[0]), .m_cmd1_wr(mailbox_write[1]), .m_commit(1'b0),
        .m_irq_clear(1'b0), .m_ctrl_wr(mailbox_write[2]), .m_wdata(mailbox_data), .m_as_idle(1'b0),
        .m_level_clear_ok(1'b0), .start_wait(mailbox_start_wait), .snd_cmd_line(), .main_irq_set(mailbox_irq),
        .main_irq_clear(), .busreq(mailbox_bus_request), .eep_clk(), .eep_di(), .eep_cs(),
        .wo_begin(mailbox_start_wait), .wo_abandon(!mailbox_wait_active),
        .wo_active(mailbox_wait_active), .wo_sample(1'b1), .wait_level(sound_wait),
        .wo_seen(), .wo_grant(mailbox_wait_grant), .snd_advance(!cpu_held),
        .z80_live(live), .z_wr(io_event), .z_rd(io_read), .z_io(1'b1), .z_iack(1'b0),
        .z_addr(address), .z_wdata(cpu_data), .snd_irq(mailbox_nmi), .z_rd_hit(mailbox_hit),
        .z_rdata(mailbox_result), .reply0(sound_latch3), .reply1(sound_latch4),
        .f_cmd0(mailbox_capture[7:0]), .f_cmd1(mailbox_capture[15:8]), .f_cmd_level(),
        .f_ctrl(mailbox_capture[23:16]), .f_irq(saved_nmi), .f_wait(saved_wait), .f_hist(saved_history),
        .f_reply0(saved_reply0), .f_reply1(saved_reply1), .r_main_load(mailbox_restore),
        .r_cmd0(mailbox_restore_data[7:0]), .r_cmd1(mailbox_restore_data[15:8]),
        .r_cmd_level(1'b0), .r_ctrl(mailbox_restore_data[23:16]), .r_snd_load(restore_commit),
        .r_irq(control_staged[53]), .r_wait(control_staged[54]), .r_hist(control_staged[52]),
        .r_reply0(control_staged[43:36]), .r_reply1(control_staged[51:44]),
        .own_main(), .own_snd(), .inert()
    );

    rzz80_rom_bank #(.PROFILE(3)) program_bank (
        .clk(clk), .reset(reset), .hold(cpu_held), .restore(restore_commit), .mem_write(1'b0),
        .io_write_event(io_event), .z80_address(address), .write_data(cpu_data),
        .restore_bank(control_staged[3:0]), .bank_state(bank_state), .rom_address(rom_address)
    );
    rzoki_batrider_bank sample_bank (
        .clk(clk), .reset(reset), .hold(cpu_held), .restore(restore_commit),
        .restore_state(control_staged[35:4]), .capture_state(sample_bank_state),
        .write(io_event && port >= 8'hc0 && port <= 8'hc6), .data(cpu_data), .offset(address[2:0]),
        .address(oki_address[0]), .rom_address(pcm_address),
        .address1(oki_address[1]), .rom1_address(pcm1_address)
    );

    rzbatrider_opm_owner #(.SS_INDEX(8'd20)) fm (
        .sk_opm_i(sk_opm_i), .sk_opm_o(sk_opm_o),
        .clk(clk), .reset(reset), .ym_ce(ym_ce), .cpu_held(cpu_held), .pcm_refill(pcm_refill),
        .canonical_hold(canonical_hold), .cpu_canonical_ready(cpu_ready), .restore_commit(restore_commit),
        .cs_n(!opm_select || cpu_held), .wr_n(wr_n || cpu_held), .a0(address[0]),
        .din(cpu_data), .dout(opm_data), .irq_n(opm_int_n), .sample(opm_sample),
        .xleft(fm_left), .xright(fm_right), .busy(replay_busy), .fault(opm_fault),
        .ss_data(SS_DATA), .ss_addr(SS_ADDR), .ss_select(SS_SELECT), .ss_write(SS_WRITE),
        .ss_read(SS_READ), .ss_query(SS_QUERY), .ss_data_out(state_response[4]), .ss_ack(state_ack[4])
    );

    wire [1:0] requests, frozen, refill_busy;
    wire [7:0] pcm_reply [0:1];
    wire [1:0] pcm_valid = {pcm1_ok, pcm_ok};
    assign pcm_reply[0] = pcm_data;
    assign pcm_reply[1] = pcm1_data;
    assign {pcm1_request, pcm_request} = requests;
    assign {pcm1_frozen, pcm_frozen} = frozen;
    assign {pcm1_resume_busy, pcm_resume_busy} = refill_busy;

    genvar lane;
    generate
    for (lane = 0; lane < 2; lane = lane + 1) begin : pcm_lane
        localparam integer LANE = lane;
        localparam logic [7:0] IO_PORT = LANE == 0 ? 8'h82 : 8'h84;
        wire state_rd, state_wr, device_ack;
        wire [31:0] device_in, device_out;
        wire [7:0] device_index;
        wire [15:0] state_index;
        if (LANE == 0) begin : shared
            // Lane 0 is the board's shared OKI (socket sk_oki); lane 1 keeps its own chip.
            assign sk_oki_i.rst = reset;
            assign sk_oki_i.filter_rst = restore_commit;
            assign sk_oki_i.clk = clk;
            assign sk_oki_i.state_freeze = cpu_held;
            assign sk_oki_i.cen = oki_ce && !cpu_held;
            assign sk_oki_i.ss = LANE == 0;
            assign sk_oki_i.wrn = !(io_write && port == IO_PORT && !cpu_held);
            assign sk_oki_i.din = cpu_data;
            assign sk_oki_i.rom_data = pcm_reply[LANE];
            assign sk_oki_i.rom_ok = pcm_valid[LANE];
            assign sk_oki_i.auto_ss_rd = state_rd;
            assign sk_oki_i.auto_ss_wr = state_wr;
            assign sk_oki_i.auto_ss_data_in = device_in;
            assign sk_oki_i.auto_ss_device_idx = device_index;
            assign sk_oki_i.auto_ss_state_idx = state_index;
            assign sk_oki_i.auto_ss_base_device_idx = 8'd0;
            assign frozen[LANE] = sk_oki_o.state_frozen;
            assign requests[LANE] = sk_oki_o.rom_request;
            assign refill_busy[LANE] = sk_oki_o.resume_busy;
            assign oki_status[LANE] = sk_oki_o.dout;
            assign oki_address[LANE] = sk_oki_o.rom_addr;
            assign oki_sound[LANE] = sk_oki_o.sound;
            assign device_out = sk_oki_o.auto_ss_data_out;
            assign device_ack = sk_oki_o.auto_ss_ack;
        end else begin : own
            ss_jt6295 #(.INTERPOL(0)) chip (
                .rst(reset), .filter_rst(restore_commit), .clk(clk), .state_freeze(cpu_held),
                .state_frozen(frozen[LANE]), .rom_request(requests[LANE]), .resume_busy(refill_busy[LANE]),
                .cen(oki_ce && !cpu_held), .ss(LANE == 0), .wrn(!(io_write && port == IO_PORT && !cpu_held)),
                .din(cpu_data), .dout(oki_status[LANE]), .rom_addr(oki_address[LANE]),
                .rom_data(pcm_reply[LANE]), .rom_ok(pcm_valid[LANE]), .sound(oki_sound[LANE]), .sample(),
                .auto_ss_rd(state_rd), .auto_ss_wr(state_wr), .auto_ss_data_in(device_in),
                .auto_ss_device_idx(device_index), .auto_ss_state_idx(state_index),
                .auto_ss_base_device_idx(8'd0), .auto_ss_data_out(device_out), .auto_ss_ack(device_ack)
            );
        end
        raizing_ss_auto32 #(.SS_INDEX(18 + LANE), .DEVICE_COUNT(11), .STATE_STRIDE(64)) state_port (
            .clk(clk), .reset(reset), .ss_data(SS_DATA), .ss_addr(SS_ADDR), .ss_select(SS_SELECT),
            .ss_write(SS_WRITE), .ss_read(SS_READ), .ss_query(SS_QUERY),
            .ss_data_out(state_response[2+LANE]), .ss_ack(state_ack[2+LANE]),
            .auto_ss_rd(state_rd), .auto_ss_wr(state_wr), .auto_ss_data_in(device_in),
            .auto_ss_device_idx(device_index), .auto_ss_state_idx(state_index),
            .auto_ss_data_out(device_out), .auto_ss_ack(device_ack)
        );
    end
    endgenerate

    wire [63:0] control_capture = {8'b0, io_history, saved_wait, saved_nmi, saved_history,
                                  saved_reply1, saved_reply0, sample_bank_state, bank_state};
    raizing_ss_wide_register #(.WIDTH(256), .SS_INDEX(15)) cpu_state (
        .clk(clk), .reset(reset), .capture_data(cpu_capture), .restore_data(cpu_staged), .restore_we(),
        .ss_data(SS_DATA), .ss_addr(SS_ADDR), .ss_select(SS_SELECT), .ss_write(SS_WRITE),
        .ss_read(SS_READ), .ss_query(SS_QUERY), .ss_data_out(state_response[0]), .ss_ack(state_ack[0])
    );
    raizing_ss_wide_register #(.WIDTH(64), .SS_INDEX(17)) control_state (
        .clk(clk), .reset(reset), .capture_data(control_capture), .restore_data(control_staged), .restore_we(),
        .ss_data(SS_DATA), .ss_addr(SS_ADDR), .ss_select(SS_SELECT), .ss_write(SS_WRITE),
        .ss_read(SS_READ), .ss_query(SS_QUERY), .ss_data_out(state_response[1]), .ss_ack(state_ack[1])
    );
    assign SS_ACK = |state_ack;
    assign SS_DATA_OUT = (state_ack[0] ? state_response[0] : 64'b0) |
                         (state_ack[1] ? state_response[1] : 64'b0) |
                         (state_ack[2] ? state_response[2] : 64'b0) |
                         (state_ack[3] ? state_response[3] : 64'b0) |
                         (state_ack[4] ? state_response[4] : 64'b0);

    function automatic signed [15:0] clip16(input logic signed [31:0] value);
        if (value > 32'sd32767) clip16 = 16'sh7fff;
        else if (value < -32'sd32768) clip16 = 16'sh8000;
        else clip16 = value[15:0];
    endfunction

    wire mixer_reset = reset || restore_commit;
    wire signed [31:0] pcm_gain = fx_level == 2'd0 ? 32'sd8 : fx_level == 2'd1 ? 32'sd12 :
                                  fx_level == 2'd2 ? 32'sd16 : 32'sd32;
    wire signed [31:0] pcm_sum = $signed(oki_sound[0]) + $signed(oki_sound[1]);
    wire signed [31:0] pcm_scaled = ((pcm_sum * 32'sd4) * pcm_gain) >>> 4;
    wire signed [16:0] fm_sum = $signed(fm_left) + $signed(fm_right);
    wire signed [15:0] fm_mono = fm_sum[16:1];
    logic signed [15:0] pcm_mono, mix;
    wire signed [15:0] filtered_pcm;
    // mix = (11*FM + 29*filtered PCM) >> 4, clipped.
    wire signed [19:0] fm_term = fm_enable ? fm_mono * 5'sd11 : 20'sd0;
    wire signed [20:0] pcm_term = pcm_enable ? filtered_pcm * 6'sd29 : 21'sd0;
    wire signed [21:0] scaled_mix = fm_term + pcm_term;
    logic [14:0] phase;
    wire [14:0] next_phase = phase + 15'd64;
    wire phase_wrap = next_phase >= 15'd27000;
    always_ff @(posedge clk) begin
        if (mixer_reset) begin
            pcm_mono <= '0;
            mix <= '0;
            phase <= '0;
        end else if (!cpu_held) begin
            pcm_mono <= clip16(pcm_scaled);
            phase <= phase_wrap ? next_phase - 15'd27000 : next_phase;
            mix <= clip16($signed(scaled_mix[21:4]));
        end
    end
    rzbatrider_audio_filter pcm_filter (
        .clk(clk), .reset(mixer_reset), .hold(cpu_held),
        .sample(phase_wrap && !cpu_held && !mixer_reset), .din(pcm_mono), .dout(filtered_pcm)
    );
    wire mute = hold_request || canonical_hold || replay_busy || pcm_refill;
    assign audio = mute ? 16'sd0 : mix;
    assign sample = opm_sample && !mute;
endmodule

// Score owner (PROFILE 2 or 3): NVRAM file staging, default-table witness, install and capture.
module rzscore_late_br #(
    parameter integer PROFILE = -1
) (
    input  wire clk, reset, cpu_reset, state_active, hold_ack,
    input  wire rom_valid, profile_supported,
    input  wire [31:0] rom_crc, rom_length,
    input  wire [3:0] profile_id,
    input  wire [15:0] score_base, restart_word,
    input  wire normal_write,
    input  wire [15:0] normal_addr, normal_data,
    input  wire [1:0] normal_we,
    output wire [39:0] init_cursor,
    input  wire [63:0] want_addr, want_data,
    input  wire [7:0] want_we,
    input  wire [8:0] cpu_addr,
    input  wire [15:0] cpu_data,
    input  wire [1:0] cpu_we,
    output wire [15:0] cpu_q,
    output wire ready,
    input  wire nv_download, nv_upload, nv_write, nv_read, manual_save, autosave, osd_open,
    input  wire [26:0] nv_addr,
    input  wire [7:0] nv_data,
    output wire [7:0] nv_q,
    output wire nv_wait, upload_request, hold_request, active, dirty,
    input  wire state_word_own, state_word_write, state_flags_write,
    input  wire [8:0] state_word_addr,
    input  wire [15:0] state_word_data,
    input  wire [63:0] state_flags_in,
    output wire [15:0] state_word_q,
    output wire [63:0] state_flags_out
);
    genvar tuple_index;
    generate if (PROFILE != 2 && PROFILE != 3) begin : inert
        assign {init_cursor, cpu_q, ready, nv_q, nv_wait, upload_request,
                hold_request, active, dirty, state_word_q, state_flags_out} = '0;
    end else begin : supported
        localparam G = PROFILE == 2;
        localparam integer AW = G ? 7 : 9;
        localparam integer DEPTH = 2 ** AW;
        localparam [9:0] WORDS = G ? 10'd118 : 10'd392;
        localparam [9:0] BYTES = WORDS << 1;
        localparam [1:0] IDLE = 0, INSTALL = 1, CAPTURE = 2;
        localparam [1:0] NO_SOURCE = 0, FILE_SOURCE = 1, TABLE_SOURCE = 2;

        reg seen_rom, known;
        reg [31:0] crc_q, length_q;
        wire usable = rom_valid && profile_supported;
        wire same = !reset && usable && known && crc_q == rom_crc && length_q == rom_length;
        wire retire_epoch = (known && !same) || (!seen_rom && rom_valid && !usable);
        wire cold = !seen_rom && !rom_valid && !reset;
        reg prev_cpu_reset, prev_dl, prev_ul, prev_osd, prev_manual;
        wire game_reset = cpu_reset && !prev_cpu_reset && !state_active;
        wire dl_start = nv_download && !prev_dl;
        wire ul_start = nv_upload && !prev_ul;
        wire restore = same && state_active && state_flags_write;

        reg [39:0] cursor;
        reg ready_q, valid_q, dirty_q, publish_due;
        reg live_bank;
        reg [39:0] next_cursor;
        wire [39:0] prior_cursor = same ? cursor : 40'd0;
        wire complete = G ? is_complete(prior_cursor) : (same && is_complete(cursor));

        function automatic is_complete(input [39:0] c);
            integer i;
            begin
                is_complete = G && c[7:0] == 8'd150;
                if (!G)
                    for (i = 0; i < 4; i = i + 1)
                        if (c[10*i +: 10] == {5'd28, 5'd0}) is_complete = 1;
            end
        endfunction

        function automatic valid_cursor(input [39:0] c);
            integer i;
            reg [4:0] row, step;
            begin
                valid_cursor = !G || c[7:0] <= 8'd150;
                if (!G)
                    for (i = 0; i < 4; i = i + 1) begin
                        row = c[10*i+5 +: 5];
                        step = c[10*i +: 5];
                        if (!(row < 5'd28 && {27'd0, step} < 22+i) &&
                            !(row == 5'd28 && step == 5'd0)) valid_cursor = 0;
                    end
            end
        endfunction

        wire [39:0] restore_cursor = G ? {32'd0, state_flags_in[7:0]} : state_flags_in[39:0];
        wire restore_ready = G ? state_flags_in[8] : state_flags_in[40];
        wire restore_valid = G ? state_flags_in[9] : state_flags_in[41];
        wire [3:0] restore_id = G ? state_flags_in[13:10] : state_flags_in[45:42];
        wire reserved_zero = G ? state_flags_in[15:14] == 0 : state_flags_in[63:46] == 0;
        wire restore_ok = reserved_zero && restore_id == profile_id && valid_cursor(restore_cursor)
                          && (!restore_ready || (restore_valid && is_complete(restore_cursor)));
        // Tuple 0 is the restart write.
        assign init_cursor = G ? prior_cursor : cursor;
        assign state_flags_out = !same ? 64'd0 :
            G ? {48'd0, 2'b00, profile_id, valid_q, ready_q, cursor[7:0]} :
                {18'd0, profile_id, valid_q, ready_q, cursor};
        assign ready = same && ready_q && !cpu_reset && !state_active;
        assign dirty = same && dirty_q;

        wire [1:0] normal_lanes;
        wire [8:0] normal_index;
        wire in_witness;
        wire [23:1] normal_word = {G ? 8'h10 : 8'h20, normal_addr[15:1]};
        rzscore_window #(.PROFILE(PROFILE)) witness_decode (
        .alt_map(1'b0),
            .word_addr(normal_word), .score_base(score_base), .payload_lanes(normal_lanes),
            .packed_word(normal_index), .witness_window(in_witness)
        );
        wire normal_event = !reset && usable && !cpu_reset && !state_active &&
                            !hold_ack && normal_write && !normal_addr[0] && !complete;
        wire witness_event = normal_event && in_witness;
        wire witness_done = witness_event && is_complete(next_cursor);
        wire restart = normal_we == 2'b11 && (G ?
            normal_addr == score_base && normal_data == restart_word &&
                (restart_word == 16'h000f || restart_word == 16'h0001) :
            normal_addr == 16'hfa24 && normal_data == 16'h0007);
        wire [3:0] match_tuple;
        for (tuple_index = 0; tuple_index < 4; tuple_index = tuple_index + 1) begin : tuple_match
            wire [1:0] lanes = want_we[2*tuple_index +: 2];
            wire [15:0] data_mask = {{8{lanes[1]}}, {8{lanes[0]}}};
            assign match_tuple[tuple_index] = normal_addr == want_addr[16*tuple_index +: 16] &&
                normal_we == lanes &&
                ((normal_data ^ want_data[16*tuple_index +: 16]) & data_mask) == 0;
        end

        integer i;
        always @* begin
            next_cursor = prior_cursor;
            if (witness_event) begin
                if (G) begin
                    next_cursor[7:0] = match_tuple[0] ? prior_cursor[7:0] + 8'd1 :
                                         restart ? 8'd1 : 8'd0;
                end else begin
                    for (i = 0; i < 4; i = i + 1) begin
                        if (!same || !match_tuple[i])
                            next_cursor[10*i +: 10] = restart ? 10'd1 : 10'd0;
                        else if ({27'd0, cursor[10*i +: 5]} == 21+i)
                            next_cursor[10*i +: 10] = {cursor[10*i+5 +: 5] + 5'd1, 5'd0};
                        else
                            next_cursor[10*i +: 5] = cursor[10*i +: 5] + 5'd1;
                    end
                end
            end
        end

        reg [1:0] op;
        reg hold_q, grant_q, primed, capture_host;
        reg [AW-1:0] copy_index;
        reg save_pending, notification;
        reg pending, pending_bank;
        reg rx_live, rx_ok, rx_bank;
        reg [9:0] rx_count;
        reg ul_live, ul_retired;
        reg [1:0] ul_src;
        reg ul_bank, reads_bad;
        reg [10:0] reads;
        reg snapshot, stale;

        // A pending-file upload pins its staging bank until HPS closes it.
        wire rx_begin = !reset && dl_start && (usable || cold) &&
                        (!same || op != INSTALL) && !restore;
        wire rx_current = rx_begin || (!dl_start && !retire_epoch && rx_live && rx_ok && !restore);
        wire rx_target = dl_start ? ((same && ul_live && ul_src == FILE_SOURCE) ?
                                    !ul_bank : !pending_bank) : rx_bank;
        wire [9:0] rx_index = dl_start ? 10'd0 : rx_count;
        wire rx_byte = !reset && nv_download && nv_write && rx_current &&
                       rx_index < BYTES && nv_addr == {17'd0, rx_index};
        wire ul_open = same && nv_upload && (ul_live || ul_start);
        wire ul_select = ul_open && ul_src == NO_SOURCE && !ul_retired && !restore;
        wire take_snapshot = ul_select && snapshot;
        wire take_file = ul_select && !snapshot && op != CAPTURE && pending && !dl_start;
        wire [1:0] source = !ul_open ? NO_SOURCE : ul_src != NO_SOURCE ? ul_src :
                             take_snapshot ? TABLE_SOURCE : take_file ? FILE_SOURCE : NO_SOURCE;
        wire file_readback = source == FILE_SOURCE;
        wire capture_abort = op == CAPTURE && capture_host && !nv_upload;
        wire port_granted = same && !cpu_reset && !state_active && hold_q && hold_ack &&
                            (G || grant_q);
        wire copy_install = port_granted && op == INSTALL && !file_readback;
        wire copy_capture = port_granted && op == CAPTURE && !capture_abort;
        wire install_done = copy_install && primed && {1'b0, copy_index} == WORDS-1'b1;
        wire capture_done = copy_capture && primed && {1'b0, copy_index} == WORDS-1'b1;

        assign hold_request = hold_q;
        assign nv_wait = ul_open && source == NO_SOURCE;
        assign active = (same || cold) && (rx_live || pending || op != IDLE ||
                        snapshot || ul_open || save_pending);
        assign upload_request = same && notification;

        wire cpu_port = ready && !hold_ack && {1'b0, cpu_addr} < WORDS;
        wire cpu_accept = cpu_port && cpu_we != 0;
        wire state_port = same && state_active && state_word_own &&
                          (!G || !state_word_addr[8:7]);
        wire init_store = normal_event && (!same || !valid_q) && (normal_lanes & normal_we) != 0;
        wire [AW:0] stage_write_addr = {rx_target, rx_index[AW:1]};
        wire nv_payload = source != NO_SOURCE && nv_addr < {17'd0, BYTES};

        reg [7:0] stage_hi [0:2*DEPTH-1], stage_lo [0:2*DEPTH-1];
        reg [7:0] image_hi [0:DEPTH-1], image_lo [0:DEPTH-1];
        reg [15:0] stage_q, image_q;
        reg [1:0] host_q_kind;
        reg host_q_low;
        wire host_stage_read = file_readback && nv_payload;
        wire [AW:0] stage_read_addr = host_stage_read ?
            {take_file ? pending_bank : ul_bank, nv_addr[AW:1]} : {pending_bank, copy_index};
        always @(posedge clk) begin
            if (rx_byte && !nv_addr[0]) stage_hi[stage_write_addr] <= nv_data;
            if (rx_byte &&  nv_addr[0]) stage_lo[stage_write_addr] <= nv_data;
            if (host_stage_read || (copy_install && !primed))
                stage_q <= {stage_hi[stage_read_addr], stage_lo[stage_read_addr]};
            if (source == TABLE_SOURCE && nv_payload)
                image_q <= {image_hi[nv_addr[AW:1]], image_lo[nv_addr[AW:1]]};
            host_q_kind <= nv_payload ? source : NO_SOURCE;
            host_q_low <= nv_addr[0];
        end
        wire [15:0] host_word = host_q_kind == FILE_SOURCE ? stage_q : image_q;
        assign nv_q = !ul_open || host_q_kind == NO_SOURCE ? 8'd0 :
                      host_q_low ? host_word[7:0] : host_word[15:8];

        // Install fills the inactive payload bank; words past WORDS stay in bank 0.
        reg [7:0] table_hi [0:2*DEPTH-1], table_lo [0:2*DEPTH-1];
        reg [AW:0] table_addr;
        reg [15:0] table_d, table_q;
        reg [1:0] table_we, table_owner, read_owner;
        localparam [1:0] CPU_PORT = 1, STATE_PORT = 2, COPY_PORT = 3;
        always @* begin
            table_addr = '0;
            table_d = '0;
            table_we = '0;
            table_owner = '0;
            if (state_port) begin
                table_addr = {({1'b0, state_word_addr} < WORDS) && live_bank, state_word_addr[AW-1:0]};
                table_d = state_word_data;
                table_we = {2{state_word_write}};
                table_owner = STATE_PORT;
            end else if (copy_install && primed) begin
                table_addr = {!live_bank, copy_index};
                table_d = stage_q;
                table_we = 2'b11;
            end else if (copy_capture && !primed) begin
                table_addr = {live_bank, copy_index};
                table_owner = COPY_PORT;
            end else if (cpu_port) begin
                table_addr = {live_bank, cpu_addr[AW-1:0]};
                table_d = cpu_data;
                table_we = cpu_we;
                table_owner = CPU_PORT;
            end else if (init_store) begin
                table_addr = {same && live_bank, normal_index[AW-1:0]};
                table_d = normal_data;
                table_we = normal_lanes & normal_we;
            end
        end
        always @(posedge clk) begin
            if (table_we[1]) table_hi[table_addr] <= table_d[15:8];
            if (table_we[0]) table_lo[table_addr] <= table_d[7:0];
            if (table_owner != 0) table_q <= {table_hi[table_addr], table_lo[table_addr]};
            read_owner <= table_owner;
            if (copy_capture && primed) begin
                image_hi[copy_index] <= table_q[15:8];
                image_lo[copy_index] <= table_q[7:0];
            end
        end
        assign cpu_q = same && read_owner == CPU_PORT ? table_q : 16'd0;
        assign state_word_q = same && read_owner == STATE_PORT ? table_q : 16'd0;

        always @(posedge clk) begin
            prev_dl <= nv_download;
            prev_ul <= nv_upload;
            prev_cpu_reset <= cpu_reset;
            prev_osd <= osd_open;
            prev_manual <= manual_save;
            notification <= 0;
            if (reset) begin
                known <= 0;
                seen_rom <= 0;
                crc_q <= 0;
                length_q <= 0;
                {cursor, ready_q, valid_q, dirty_q, live_bank, publish_due} <= '0;
                {rx_live, rx_ok, rx_bank, rx_count, pending, pending_bank} <= '0;
                {ul_live, ul_retired, ul_src, ul_bank, reads_bad, reads} <= '0;
                {op, hold_q, grant_q, primed, copy_index, capture_host,
                 snapshot, stale, save_pending} <= '0;
            end else begin
                known <= usable;
                if (rom_valid) seen_rom <= 1;
                if (usable) begin
                    crc_q <= rom_crc;
                    length_q <= rom_length;
                end
                if (!same) begin
                    cursor <= next_cursor;
                    {ready_q, valid_q, dirty_q, live_bank, publish_due} <= '0;
                    {ul_live, ul_retired, ul_src, ul_bank, reads_bad, reads} <= '0;
                    {op, hold_q, grant_q, primed, copy_index, capture_host,
                     snapshot, stale, save_pending} <= '0;
                end

                if (retire_epoch || restore) begin
                    pending <= 0;
                    rx_live <= 0;
                    rx_ok <= 0;
                end
                if (dl_start) begin
                    if (!same || op != INSTALL || restore) pending <= 0;
                    rx_live <= rx_begin;
                    rx_ok <= rx_begin && (!nv_write || rx_byte);
                    rx_bank <= rx_target;
                    rx_count <= rx_byte ? 10'd1 : 10'd0;
                end else if (!retire_epoch && !restore && rx_live) begin
                    if (!nv_download) begin
                        rx_live <= 0;
                        if (rx_ok && rx_count == BYTES) begin
                            pending <= 1;
                            pending_bank <= rx_bank;
                        end
                    end else if (nv_write) begin
                        if (rx_byte) rx_count <= rx_count + 10'd1;
                        else rx_ok <= 0;
                    end
                end

                if (same) begin
                    if (ul_start) begin
                        ul_live <= 1;
                        ul_retired <= 0;
                        reads <= 0;
                        reads_bad <= 0;
                    end
                    if (take_file || take_snapshot) begin
                        ul_src <= source;
                        ul_bank <= pending_bank;
                    end
                    if (ul_open && nv_read) begin
                        // hps_io may read address 0 before a source is bound.
                        if (reads <= {1'b0, BYTES} && nv_addr == {16'd0, reads} &&
                            (source != NO_SOURCE || reads == 0))
                            reads <= reads + 11'd1;
                        else reads_bad <= 1;
                    end
                    if (ul_live && !nv_upload) begin
                        ul_live <= 0;
                        ul_src <= NO_SOURCE;
                        reads <= 0;
                        reads_bad <= 0;
                        if (ul_src == TABLE_SOURCE) begin
                            snapshot <= 0;
                            if (reads == {1'b0, BYTES} + 11'd1 && !reads_bad &&
                                !stale && !cpu_accept) dirty_q <= 0;
                        end
                    end
                    if (cpu_accept) begin
                        dirty_q <= 1;
                        if (snapshot || ul_src == TABLE_SOURCE) stale <= 1;
                    end

                    cursor <= next_cursor;
                    if (witness_done) publish_due <= 1;
                    if (!ready_q && (publish_due || witness_done) && !cpu_reset && !state_active &&
                        !pending && !rx_live && !rx_begin) begin
                        ready_q <= 1;
                        valid_q <= 1;
                        publish_due <= 0;
                    end
                    if (ready && (manual_save && !prev_manual ||
                        autosave && osd_open && !prev_osd && dirty_q) &&
                        !snapshot && op != CAPTURE && ul_src == NO_SOURCE)
                        save_pending <= 1;

                    if (restore) begin
                        cursor <= restore_ok ? restore_cursor : 40'd0;
                        ready_q <= restore_ok && restore_ready;
                        valid_q <= restore_ok && restore_valid;
                        {op, hold_q, grant_q, primed, copy_index, capture_host,
                         snapshot, save_pending, dirty_q, publish_due} <= '0;
                        if (ul_open) ul_retired <= 1;
                    end else if (game_reset || capture_abort) begin
                        {op, hold_q, grant_q, primed, copy_index, capture_host, save_pending} <= '0;
                        if (game_reset) begin
                            cursor <= 0;
                            ready_q <= 0;
                            publish_due <= 0;
                        end
                    end else if (op == IDLE) begin
                        hold_q <= 0;
                        grant_q <= 0;
                        if (!state_active && !cpu_reset) begin
                            if (pending && complete && !rx_live && !ul_open && !dl_start &&
                                (!G || !snapshot)) begin
                                op <= INSTALL;
                                hold_q <= 1;
                            end else if (!snapshot && valid_q && !file_readback &&
                                ((ul_select && !take_snapshot && !take_file) ||
                                 (save_pending && !nv_upload))) begin
                                op <= CAPTURE;
                                hold_q <= 1;
                                capture_host <= ul_open;
                                save_pending <= 0;
                            end
                        end
                    end else begin
                        if (op == CAPTURE && ul_open) capture_host <= 1;
                        hold_q <= !state_active && !cpu_reset && !(op == INSTALL && file_readback);
                        grant_q <= hold_q && hold_ack && !state_active && !cpu_reset &&
                                   !(op == INSTALL && file_readback);
                        if (!(copy_install || copy_capture)) begin
                            primed <= 0;
                            copy_index <= 0;
                        end else if (install_done || capture_done) begin
                            {op, hold_q, grant_q, primed, copy_index, capture_host} <= '0;
                            if (install_done) begin
                                live_bank <= !live_bank;
                                pending <= 0;
                                ready_q <= 1;
                                valid_q <= 1;
                                dirty_q <= 0;
                                publish_due <= 0;
                                if (snapshot) stale <= 1;
                            end else begin
                                snapshot <= 1;
                                stale <= 0;
                                // An open upload reads the new snapshot; otherwise notify the host.
                                if (ul_open) ul_src <= TABLE_SOURCE;
                                notification <= !ul_open;
                            end
                        end else begin
                            primed <= !primed;
                            if (primed) copy_index <= copy_index + 1'b1;
                        end
                    end
                end
            end
        end
    end endgenerate
endmodule

// Batrider set ID by ROM CRC, and expected default score-table writes for four copy-length candidates.
module rzbatrider_highscore_profile (
    input [31:0] rom_crc,rom_length, input [39:0] progress,
    output reg supported, output reg [3:0] profile, output [15:0] score_base,
    output [63:0] expected_addr,expected_data, output [7:0] expected_we
);
    assign score_base=16'hfa20;
    always @* begin supported=0;profile=0;
        if(rom_length==32'h1440000) case(rom_crc)
            32'h376ceda9: begin supported=1;profile=4'd1;end // batrider
            32'h21a13c19: begin supported=1;profile=4'd2;end // batriderc
            32'hbb751b4d: begin supported=1;profile=4'd3;end // batriderhk
            32'h1fa7b384: begin supported=1;profile=4'd4;end // batriderj
            32'h5f030e13: begin supported=1;profile=4'd5;end // batriderja
            32'h020c8aec: begin supported=1;profile=4'd6;end // batriderk
            32'h6a636956: begin supported=1;profile=4'd7;end // batridert
            32'he67a9fb2: begin supported=1;profile=4'd8;end // batrideru
            32'h2f8d90a3: begin supported=1;profile=4'd9;end // batrideru-special
            default: begin end
        endcase
    end
    function automatic [33:0] expected(input [4:0] row,step,input integer chars);
        reg [31:0] score,ships; reg [23:0] name; reg [55:0] digits;
        reg [7:0] stage,value; reg [15:0] address,data; reg [1:0] lanes;
        integer offset,tail,index; begin
        score=0;ships=0;name=0;digits=0;stage=0;
        case(row)
            5'd0: begin score=32'd500000;ships=32'h9094989c;name=24'h2a2a2a;digits=56'h20353030303030;stage=8'h31;end
            5'd1: begin score=32'd400000;ships=32'h9ca0a4a8;name=24'h2a2a2a;digits=56'h20343030303030;stage=8'h31;end
            5'd2: begin score=32'd300000;ships=32'ha8acb0b4;name=24'h2a2a2a;digits=56'h20333030303030;stage=8'h31;end
            5'd3: begin score=32'd200000;ships=32'hb4b8bcc0;name=24'h2a2a2a;digits=56'h20323030303030;stage=8'h31;end
            5'd4: begin score=32'd100000;ships=32'hc0c4c8cc;name=24'h2a2a2a;digits=56'h20313030303030;stage=8'h31;end
            5'd5: begin score=32'd0;ships=32'h90909090;name=24'h202020;digits=56'h20202020202030;stage=8'h30;end
            5'd6: begin score=32'd0;ships=32'h90909090;name=24'h202020;digits=56'h20202020202030;stage=8'h30;end
            5'd7: begin score=32'd500000;ships=32'h9195999d;name=24'h2b2b2b;digits=56'h20353030303030;stage=8'h31;end
            5'd8: begin score=32'd400000;ships=32'h9da1a5a9;name=24'h2b2b2b;digits=56'h20343030303030;stage=8'h31;end
            5'd9: begin score=32'd300000;ships=32'ha9adb1b5;name=24'h2b2b2b;digits=56'h20333030303030;stage=8'h31;end
            5'd10: begin score=32'd200000;ships=32'hb5b9bdc1;name=24'h2b2b2b;digits=56'h20323030303030;stage=8'h31;end
            5'd11: begin score=32'd100000;ships=32'hc1c5c9cd;name=24'h2b2b2b;digits=56'h20313030303030;stage=8'h31;end
            5'd12: begin score=32'd0;ships=32'h90909090;name=24'h202020;digits=56'h20202020202030;stage=8'h30;end
            5'd13: begin score=32'd0;ships=32'h90909090;name=24'h202020;digits=56'h20202020202030;stage=8'h30;end
            5'd14: begin score=32'd500000;ships=32'h92969a9e;name=24'h232323;digits=56'h20353030303030;stage=8'h31;end
            5'd15: begin score=32'd400000;ships=32'h9ea2a6aa;name=24'h232323;digits=56'h20343030303030;stage=8'h31;end
            5'd16: begin score=32'd300000;ships=32'haaaeb2b6;name=24'h232323;digits=56'h20333030303030;stage=8'h31;end
            5'd17: begin score=32'd200000;ships=32'hb6babec2;name=24'h232323;digits=56'h20323030303030;stage=8'h31;end
            5'd18: begin score=32'd100000;ships=32'hc2c6cace;name=24'h232323;digits=56'h20313030303030;stage=8'h31;end
            5'd19: begin score=32'd0;ships=32'h90909090;name=24'h202020;digits=56'h20202020202030;stage=8'h30;end
            5'd20: begin score=32'd0;ships=32'h90909090;name=24'h202020;digits=56'h20202020202030;stage=8'h30;end
            5'd21: begin score=32'd500000;ships=32'h93979b9f;name=24'h3f3f3f;digits=56'h20353030303030;stage=8'h31;end
            5'd22: begin score=32'd400000;ships=32'h9fa3a7ab;name=24'h3f3f3f;digits=56'h20343030303030;stage=8'h31;end
            5'd23: begin score=32'd300000;ships=32'habafb3b7;name=24'h3f3f3f;digits=56'h20333030303030;stage=8'h31;end
            5'd24: begin score=32'd200000;ships=32'hb7bbbfc3;name=24'h3f3f3f;digits=56'h20323030303030;stage=8'h31;end
            5'd25: begin score=32'd100000;ships=32'hc3c7cbcf;name=24'h3f3f3f;digits=56'h20313030303030;stage=8'h31;end
            5'd26: begin score=32'd0;ships=32'h90909090;name=24'h202020;digits=56'h20202020202030;stage=8'h30;end
            5'd27: begin score=32'd0;ships=32'h90909090;name=24'h202020;digits=56'h20202020202030;stage=8'h30;end
            default: begin end
        endcase
        offset=0;data=0;lanes=0;value=0;tail=0;index=0;
        if(row<28) begin
            if(step<4) begin lanes=3; case(step)
                0: begin offset=0;data=score[31:16];end
                1: begin offset=2;data=score[15:0];end
                2: offset=18; 3: offset=16; default: begin end endcase end
            else begin
                if(step<4+chars) begin index=step-4;offset=16+index;value=8'(ships>>((3-index)*8));end
                else begin tail=step-4-chars; case(tail)
                    0,1,2: begin offset=12+tail;value=8'(name>>((2-tail)*8));end
                    3: offset=15; 4: begin offset=22;value=8'h20;end
                    5: begin offset=23;value=stage;end 6: offset=24;7: offset=25;
                    8,9,10,11,12,13,14: begin offset=4+tail-8;value=8'(digits>>((14-tail)*8));end
                    15: offset=11;16: begin offset=26;value=2;end
                    default: begin end endcase end
                lanes=offset[0] ? 1 : 2;data=offset[0] ? {8'd0,value} : {value,8'd0};
            end
        end
        address=16'hfa24+16'(row*28+offset);address[0]=1'b0;expected={address,data,lanes};
        end endfunction
    genvar candidate; generate for(candidate=0;candidate<4;candidate=candidate+1) begin: schedules
        assign {expected_addr[candidate*16+:16],expected_data[candidate*16+:16],expected_we[candidate*2+:2]}=
            expected(progress[candidate*10+5+:5],progress[candidate*10+:5],candidate+1);
    end endgenerate
endmodule

// Batrider score binding: set profile, score owner and save-state chunks 44/45.
module rzbatrider_score_binding #(parameter USE_SCORE_TOKEN = 1'b0) (
    input clk,reset,cpu_reset,
    input [31:0] rom_crc,rom_length,
    input rom_valid,
    input [3:0] score_profile,
    output [15:0] score_base,
    input nv_download,nv_upload,nv_write,nv_read,
    input [26:0] nv_addr,
    input [7:0] nv_data,
    output [7:0] nv_q,
    output nv_wait,
    input manual_save,autosave,osd_open,
    output upload_request,
    input normal_write,
    input [15:0] normal_addr,normal_data,
    input [1:0] normal_we,
    output ready,
    input [8:0] cpu_addr,
    input [15:0] cpu_data,
    input [1:0] cpu_we,
    output [15:0] cpu_q,
    input state_active,hold_ack,
    output hold_request,
    output active,
    output dirty,
    input [63:0] SS_DATA,
    input [31:0] SS_ADDR,
    input [7:0] SS_SELECT,
    input SS_WRITE,SS_READ,SS_QUERY,
    output [63:0] SS_DATA_OUT,
    output SS_ACK
);

    wire decoded_supported;
    wire [3:0] decoded_profile;
    wire supported = USE_SCORE_TOKEN ? score_profile != 4'd0 : decoded_supported;
    wire [3:0] profile = USE_SCORE_TOKEN ? score_profile : decoded_profile;
    // Owner identity: score token, or ROM CRC/length.
    wire [31:0] owner_id = USE_SCORE_TOKEN ? {28'd0, score_profile} : rom_crc;
    wire [31:0] owner_length = USE_SCORE_TOKEN ? 32'd0 : rom_length;
    wire [39:0] init_cursor;
    wire [15:0] restart_word;
    wire [63:0] want_addr, want_data;
    wire [7:0] want_we;
    reg previous_rom_valid;
    reg [3:0] previous_profile;
    always @(posedge clk) begin
        previous_rom_valid <= !reset && rom_valid;
        previous_profile <= reset || !supported ? 4'd0 : profile;
    end
    // State port is live for a valid, supported ROM whose profile ID has not changed.
    wire state_live = !reset && rom_valid && supported &&
                      (!previous_rom_valid || previous_profile == profile);
    wire [7:0] state_select = state_active && state_live ? SS_SELECT : 8'hff;

    assign restart_word = 16'h0007;
    rzbatrider_highscore_profile witness (
        .rom_crc(rom_crc),.rom_length(rom_length),.progress(init_cursor),
        .supported(decoded_supported),.profile(decoded_profile),.score_base(score_base),
        .expected_addr(want_addr),.expected_data(want_data),.expected_we(want_we)
    );

    wire word_own, word_write, flags_write;
    wire [8:0] word_addr;
    wire [15:0] word_data, word_q;
    wire [63:0] flags_out, restore_flags;
    wire [64-1:0] saved_flags;
    wire [1:0] state_ack;
    wire [127:0] state_response_data;
    assign restore_flags = 64'(saved_flags);

    raizing_ss_ram_adapter #(.WIDTH(16),.ADDR_WIDTH(9),.SS_INDEX(44)) state_table (
        .clk(clk),.reset(!state_live),.ss_data(SS_DATA),.ss_addr(SS_ADDR),.ss_select(state_select),
        .ss_write(SS_WRITE),.ss_read(SS_READ),.ss_query(SS_QUERY),
        .ss_data_out(state_response_data[0+:64]),.ss_ack(state_ack[0]),
        .ram_active(word_own),.ram_addr(word_addr),.ram_data(word_data),.ram_we(word_write),.ram_q(word_q)
    );
    raizing_ss_register #(.WIDTH(64),.SS_INDEX(45)) state_flags (
        .clk(clk),.reset(!state_live),.capture_data(flags_out[64-1:0]),
        .restore_data(saved_flags),.restore_we(flags_write),.ss_data(SS_DATA),.ss_select(state_select),
        .ss_write(SS_WRITE),.ss_read(SS_READ),.ss_query(SS_QUERY),
        .ss_data_out(state_response_data[64+:64]),.ss_ack(state_ack[1])
    );
    raizing_ss_response_mux #(.COUNT(2)) state_response (
        .ack(state_ack),.data(state_response_data),.ack_out(SS_ACK),.data_out(SS_DATA_OUT)
    );
    rzscore_late_br #(.PROFILE(3)) owner (
        .rom_valid(rom_valid),.profile_supported(supported),.rom_crc(owner_id),.rom_length(owner_length),
        .profile_id(profile),.score_base(score_base),.restart_word(restart_word),.init_cursor(init_cursor),
        .want_addr(want_addr),.want_data(want_data),.want_we(want_we),
        .clk(clk),.reset(reset),.cpu_reset(cpu_reset),.state_active(state_active),.hold_ack(hold_ack),
        .nv_download(nv_download),.nv_upload(nv_upload),.nv_write(nv_write),.nv_read(nv_read),
        .nv_addr(nv_addr),.nv_data(nv_data),.nv_q(nv_q),.nv_wait(nv_wait),
        .manual_save(manual_save),.autosave(autosave),.osd_open(osd_open),
        .upload_request(upload_request),.hold_request(hold_request),.active(active),.dirty(dirty),.ready(ready),
        .normal_write(normal_write),.normal_addr(normal_addr),.normal_data(normal_data),.normal_we(normal_we),
        .cpu_addr(9'(cpu_addr)),.cpu_data(cpu_data),.cpu_we(cpu_we),.cpu_q(cpu_q),
        .state_word_own(state_active && state_live && word_own),.state_word_write(state_active && state_live && word_write),
        .state_word_addr(9'(word_addr)),.state_word_data(word_data),.state_word_q(word_q),
        .state_flags_write(state_active && state_live && flags_write),.state_flags_in(restore_flags),.state_flags_out(flags_out)
    );
endmodule

`default_nettype none
`default_nettype wire

`default_nettype wire

`default_nettype wire
