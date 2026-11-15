// SPDX-License-Identifier: GPL-3.0-or-later
// Batrider/Bakraid board: bus binding, text DMA, work-RAM state, shared Z80 ROM owner and restore undo.

// Restores one undo pre-image to work RAM, then to glyph RAM for mirrored words.
`timescale 1ns/1ps
module rzctx_late_undo_apply (
    input clk, reset,
    input request, mirror,
    input [14:0] word_index,
    input [15:0] wram_before, glyph_before,
    output ready,
    input wram_held, glyph_held,
    output wram_write, glyph_write,
    output reg [14:0] write_index,
    output [15:0] write_data,
    input wram_ack, wram_error, glyph_ack, glyph_error,
    output response_valid,
    output reg response_error,
    input response_ready
);
    typedef enum logic [1:0] {IDLE, WRAM, GLYPH, RESPONSE} phase_t;
    phase_t phase;
    reg needs_glyph;
    reg [15:0] old_wram, old_glyph;
    wire broken_hold = !wram_held || (needs_glyph && !glyph_held);
    wire wram_failed = response_error || broken_hold || glyph_ack || wram_error;

    assign ready = !reset && phase==IDLE && wram_held &&
                   (!mirror || glyph_held) && !wram_ack && !glyph_ack;
    assign wram_write = !reset && phase==WRAM;
    assign glyph_write = !reset && phase==GLYPH;
    assign write_data = phase==GLYPH ? old_glyph : old_wram;
    assign response_valid = !reset && phase==RESPONSE;

    // A dropped hold flags an error; the phase still waits for its ack.
    always @(posedge clk) begin
        if(reset) begin
            phase <= IDLE;
            needs_glyph <= 0;
            write_index <= 0;
            old_wram <= 0;
            old_glyph <= 0;
            response_error <= 0;
        end else case(phase)
            IDLE: if(request && ready) begin
                write_index <= word_index;
                old_wram <= wram_before;
                old_glyph <= glyph_before;
                needs_glyph <= mirror;
                response_error <= mirror && word_index[14];
                phase <= mirror && word_index[14] ? RESPONSE : WRAM;
            end
            WRAM: begin
                if(broken_hold || glyph_ack) response_error <= 1;
                if(wram_ack) begin
                    response_error <= wram_failed;
                    phase <= needs_glyph && !wram_failed ? GLYPH : RESPONSE;
                end
            end
            GLYPH: begin
                if(broken_hold) response_error <= 1;
                if(glyph_ack) begin
                    response_error <= response_error || broken_hold || glyph_error;
                    phase <= RESPONSE;
                end
            end
            RESPONSE: if(response_ready) phase <= IDLE;
            default: begin phase <= RESPONSE; response_error <= 1; end
        endcase
    end
endmodule

// Save-state chunk 2: 32768 work-RAM words; acks after the RAM owner responds.
module rzmem_ss_workram (
    input clk,reset,
    input [63:0] ss_data,
    input [31:0] ss_addr,
    input [7:0] ss_select,
    input ss_write,ss_read,ss_query,
    output reg [63:0] ss_data_out,
    output reg ss_ack,
    output reg ram_active,
    output reg [14:0] ram_addr,
    output reg [15:0] ram_data,
    output reg ram_we,
    input [15:0] ram_q,
    input ram_ack
);
    localparam [1:0] IDLE=0, ACCESS=1, RELEASE=2;
    reg [1:0] state;

    always @(posedge clk) begin
        if(reset) begin
            state<=IDLE;
            ss_ack<=0;
            ss_data_out<=0;
            ram_active<=0;
            ram_addr<=0;
            ram_data<=0;
            ram_we<=0;
        end else case(state)
            IDLE: if(ss_select==8'd2) begin
                if(ss_query) begin
                    ss_data_out<={8'd2,22'd0,2'd1,32'd32768};
                    ss_ack<=1;
                    state<=RELEASE;
                end else if(ss_read || ss_write) begin
                    if(|ss_addr[31:15]) begin
                        ss_data_out<=0;
                        ss_ack<=1;
                        state<=RELEASE;
                    end else begin
                        ram_addr<=ss_addr[14:0];
                        ram_data<=ss_data[15:0];
                        ram_we<=ss_write;
                        ram_active<=1;
                        state<=ACCESS;
                    end
                end
            end
            ACCESS: if(ram_ack) begin
                ss_data_out<=ram_we ? 64'd0 : {48'd0,ram_q};
                ss_ack<=1;
                ram_we<=0;
                state<=RELEASE;
            end
            default: if(!(ss_read || ss_write || ss_query)) begin
                ss_ack<=0;
                ram_active<=0;
                state<=IDLE;
            end
        endcase
    end
endmodule

// Shared Z80 program-ROM slot: main CPU (low slice) and sound CPU (high slice) alternate; ok holds while the owner's request matches.
module rzlate_zrom_owner #(
  parameter int AW = 18
) (
  input  logic            clk,
  input  logic            reset,
  input  logic [1:0]      request,
  input  logic [2*AW-1:0] address,
  input  logic            park1,        // sound CPU parked by a save/pause hold
  output logic [1:0]      ok,
  output logic [7:0]      data,
  output logic            rom_request,
  output logic [AW-1:0]   rom_address,
  input  logic            rom_ok,
  input  logic [7:0]      rom_data,
  output logic            idle
);

  logic          pending;    // ROM request outstanding
  logic          complete;   // response held for the owner
  logic          owner;      // 0 = main CPU, 1 = sound CPU
  logic          prefer;     // client tried first when free
  logic [AW-1:0] addr_q;
  logic [7:0]    data_q;

  logic [AW-1:0] addr_c0, addr_c1, owner_addr, prefer_addr, other_addr;
  assign addr_c0     = address[AW-1:0];
  assign addr_c1     = address[2*AW-1:AW];
  assign owner_addr  = owner  ? addr_c1 : addr_c0;
  assign prefer_addr = prefer ? addr_c1 : addr_c0;
  assign other_addr  = prefer ? addr_c0 : addr_c1;

  logic owner_req, prefer_req, other_req;
  assign owner_req  = owner  ? request[1] : request[0];
  assign prefer_req = prefer ? request[1] : request[0];
  assign other_req  = prefer ? request[0] : request[1];

  // Owner still requests the captured address.
  logic owner_match;
  assign owner_match = owner_req && (owner_addr == addr_q);

  always_ff @(posedge clk) begin
    if (reset) begin
      pending  <= 1'b0;
      complete <= 1'b0;
      owner    <= 1'b0;
      prefer   <= 1'b0;
      addr_q   <= '0;
      data_q   <= '0;
    end else if (pending) begin
      if (rom_ok) begin
        pending  <= 1'b0;
        complete <= 1'b1;
        data_q   <= rom_data;
        prefer   <= ~owner;
      end
    end else if (complete) begin
      // A parked sound CPU gives up its finished read to a waiting main CPU and refetches on resume.
      if (!owner_match || (owner && park1 && request[0])) begin
        complete <= 1'b0;
      end
    end else if (prefer_req) begin
      pending <= 1'b1;
      owner   <= prefer;
      addr_q  <= prefer_addr;
    end else if (other_req) begin
      pending <= 1'b1;
      owner   <= ~prefer;
      addr_q  <= other_addr;
    end
  end

  assign ok[0]       = complete && (owner == 1'b0) && owner_match;
  assign ok[1]       = complete && (owner == 1'b1) && owner_match;
  assign data        = data_q;
  assign rom_request = pending;
  assign rom_address = addr_q;
  assign idle        = ~pending;

endmodule

// Text DMA engine: copies one work-RAM word per request, ack and destination commit; done pulses after the last word.
`timescale 1ns/1ps
module rztdma_engine (
  input  logic        clk,
  input  logic        reset,
  // commands: levels, acted on at rising edges
  input  logic        text_dma_start,     // glyph transfer
  input  logic        palette_dma_start,  // frame transfer
  input  logic        allow,              // no hold or state access
  output logic        start_ready,
  output logic        accept_glyph,       // pulse on glyph command accept
  output logic        busy,
  output logic        done,
  // WRAM read service
  output logic        wram_req,
  output logic [14:0] wram_addr,
  input  logic        wram_readack,
  input  logic [15:0] wram_data,
  // palette service
  output logic        palette_valid,
  output logic [10:0] palette_addr,
  output logic [15:0] palette_data,
  output logic [1:0]  palette_be,
  input  logic        palette_ready,
  // local RAM write, valid for the commit cycle
  output logic        lw_valid,
  output logic [1:0]  lw_dest,            // 0 glyph, 1 text map, 2 select, 3 scroll
  output logic [13:0] lw_addr,
  output logic [15:0] lw_data
);
  localparam logic [1:0] D_GLYPH  = 2'd0;
  localparam logic [1:0] D_TEXT   = 2'd1;
  localparam logic [1:0] D_SELECT = 2'd2;
  localparam logic [1:0] D_SCROLL = 2'd3;

  logic        text_q, pal_q;      // previous command levels (edge detection)
  logic        busy_q, frame_q;    // frame_q: 0 glyph transfer, 1 frame transfer
  logic [14:0] src_q;              // source word position
  logic        req_q;
  logic        pend_q;             // acknowledged word waiting for its destination
  logic [15:0] word_q;
  logic        done_q;

  wire text_rise = text_dma_start && !text_q;
  wire pal_rise  = palette_dma_start && !pal_q;
  assign start_ready = !reset && !busy_q && allow;
  wire acc_glyph = start_ready && text_rise;
  wire acc_frame = start_ready && pal_rise && !text_rise;   // glyph transfer has priority

  // destination of the current source position
  logic        to_palette;
  logic [1:0]  dest;
  logic [13:0] daddr;
  logic        last;
  always_comb begin
    to_palette = 1'b0;
    dest  = D_GLYPH;
    daddr = src_q[13:0];
    if (!frame_q) begin
      last = (src_q == 15'h3fff);
    end else begin
      last = (src_q == 15'h19ff);
      if (src_q < 15'h1000) begin
        dest = D_TEXT;   daddr = {2'b00, src_q[11:0]};
      end else if (src_q < 15'h1800) begin
        to_palette = 1'b1; daddr = {3'b000, src_q[10:0]};       // 1000..17ff -> 000..7ff
      end else if (src_q < 15'h1900) begin
        dest = D_SELECT; daddr = {6'd0, src_q[7:0]};            // 1800..18ff -> 00..ff
      end else begin
        dest = D_SCROLL; daddr = {6'd0, src_q[7:0]};            // 1900..19ff -> 00..ff
      end
    end
  end

  wire ack    = wram_readack && req_q;            // unrequested ACKs are ignored
  wire commit = pend_q && (!to_palette || palette_ready);

  always_ff @(posedge clk) begin
    text_q <= text_dma_start;                     // command levels are sampled in reset too
    pal_q  <= palette_dma_start;                   
    done_q <= 1'b0;
    if (reset) begin
      busy_q <= 1'b0;
      frame_q <= 1'b0;
      src_q  <= 15'd0;
      req_q  <= 1'b0;
      pend_q <= 1'b0;
      word_q <= 16'd0;
    end else begin
      if (acc_glyph || acc_frame) begin
        busy_q  <= 1'b1;
        frame_q <= acc_frame;
        src_q   <= 15'd0;
        req_q   <= 1'b1;
      end
      if (ack) begin
        req_q  <= 1'b0;
        word_q <= wram_data;
        pend_q <= 1'b1;
      end
      if (commit) begin
        pend_q <= 1'b0;
        if (last) begin
          busy_q <= 1'b0;
          done_q <= 1'b1;
        end else begin
          src_q <= src_q + 15'd1;
          req_q <= 1'b1;
        end
      end
    end
  end

  assign accept_glyph  = acc_glyph;
  assign busy          = busy_q;
  assign done          = done_q;
  assign wram_req      = !reset && req_q;
  assign wram_addr     = src_q;
  assign palette_valid = !reset && pend_q && to_palette;
  assign palette_addr  = daddr[10:0];
  assign palette_data  = word_q;
  assign palette_be    = palette_valid ? 2'b11 : 2'b00;
  assign lw_valid      = !reset && pend_q && !to_palette;
  assign lw_dest       = dest;
  assign lw_addr       = daddr;
  assign lw_data       = word_q;
endmodule

// Text DMA state port: queries ack at once; owned in-range reads/writes ack after a memory cycle; others never ack; ack holds until requests drop.
`timescale 1ns/1ps
module rztdma_state #(
  parameter int REGION_GLYPH    = 46,
  parameter int REGION_TEXT     = 47,
  parameter int REGION_SELECT   = 48,
  parameter int REGION_SCROLL   = 49,
  parameter int REGION_UNPACKED = 50
) (
  input  logic        clk,
  input  logic        reset,
  input  logic        owned,              // held && state_access_enable
  // payload uses bits 15:0
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [63:0] SS_DATA,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [63:0] SS_DATA_OUT,
  input  logic [31:0] SS_ADDR,
  input  logic [7:0]  SS_SELECT,
  input  logic        SS_WRITE,
  input  logic        SS_READ,
  input  logic        SS_QUERY,
  output logic        SS_ACK,
  // control-port request, valid in the P_MEM cycle
  output logic        st_mem,
  output logic [2:0]  st_region,          // 0 glyph, 1 text, 2 select, 3 scroll, 4 unpacked
  output logic [13:0] st_addr,
  output logic        st_we,
  output logic [15:0] st_wdata,
  input  logic [15:0] glyph_q,
  input  logic [15:0] text_q,
  input  logic [15:0] select_q,
  input  logic [15:0] scroll_q,
  input  logic        unpacked
);
  localparam logic [2:0] R_GLYPH = 3'd0, R_TEXT = 3'd1, R_SELECT = 3'd2, R_SCROLL = 3'd3, R_UNPACKED = 3'd4;
  localparam logic [1:0] P_IDLE = 2'd0, P_MEM = 2'd1, P_RESP = 2'd2, P_HOLD = 2'd3;

  // region decode
  logic        supported;
  logic [2:0]  code;
  logic [31:0] items;
  logic [1:0]  width_code;
  always_comb begin
    supported = 1'b1;
    code = R_GLYPH; items = 32'd16384; width_code = 2'd1;
    if (SS_SELECT == 8'(REGION_GLYPH))         begin code = R_GLYPH;    items = 32'd16384; end
    else if (SS_SELECT == 8'(REGION_TEXT))     begin code = R_TEXT;     items = 32'd4096;  end
    else if (SS_SELECT == 8'(REGION_SELECT))   begin code = R_SELECT;   items = 32'd256;   end
    else if (SS_SELECT == 8'(REGION_SCROLL))   begin code = R_SCROLL;   items = 32'd256;   end
    else if (SS_SELECT == 8'(REGION_UNPACKED)) begin code = R_UNPACKED; items = 32'd1; width_code = 2'd0; end
    else supported = 1'b0;
  end
  wire in_range = SS_ADDR < items;

  logic [1:0]  phase_q;
  logic        ack_q;
  logic [63:0] out_q;
  logic [2:0]  reg_q;
  logic [13:0] idx_q;
  logic [15:0] wd_q;
  logic        we_q;

  wire any_req = SS_READ || SS_WRITE || SS_QUERY;

  logic [15:0] rdata;
  always_comb begin
    case (reg_q)
      R_GLYPH:  rdata = glyph_q;
      R_TEXT:   rdata = text_q;
      R_SELECT: rdata = select_q;
      R_SCROLL: rdata = scroll_q;
      default:  rdata = {15'd0, unpacked};
    endcase
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      phase_q <= P_IDLE;
      ack_q   <= 1'b0;
      out_q   <= 64'd0;
      reg_q   <= R_GLYPH;
      idx_q   <= 14'd0;
      wd_q    <= 16'd0;
      we_q    <= 1'b0;
    end else begin
      case (phase_q)
        P_IDLE: begin
          if (SS_QUERY && supported) begin
            ack_q   <= 1'b1;
            out_q   <= {SS_SELECT, 22'd0, width_code, items};
            phase_q <= P_HOLD;
          end else if ((SS_READ || SS_WRITE) && owned && supported && in_range) begin
            reg_q   <= code;
            idx_q   <= SS_ADDR[13:0];
            wd_q    <= SS_DATA[15:0];
            we_q    <= SS_WRITE;
            phase_q <= P_MEM;
          end
        end
        P_MEM:  phase_q <= P_RESP;                 // memory access cycle
        P_RESP: begin
          ack_q   <= 1'b1;
          out_q   <= we_q ? 64'd0 : {48'd0, rdata};
          phase_q <= P_HOLD;
        end
        default: begin                             // P_HOLD: ACK until all requests drop
          if (!any_req) begin
            ack_q   <= 1'b0;
            phase_q <= P_IDLE;
          end
        end
      endcase
    end
  end

  assign SS_ACK      = ack_q;
  assign SS_DATA_OUT = out_q;
  assign st_mem      = !reset && (phase_q == P_MEM);
  assign st_region   = reg_q;
  assign st_addr     = idx_q;
  assign st_we       = st_mem && we_q;
  assign st_wdata    = wd_q;
endmodule

// Text DMA and its glyph/text/select/scroll RAMs: DMA, held state access and CPU glyph mirror share the control port; the renderer reads the other.
`timescale 1ns/1ps
module rztdma_top #(
  parameter int REGION_GLYPH    = 46,
  parameter int REGION_TEXT     = 47,
  parameter int REGION_SELECT   = 48,
  parameter int REGION_SCROLL   = 49,
  parameter int REGION_UNPACKED = 50
) (
  input  logic        clk,
  input  logic        reset,
  // commands
  input  logic        text_dma_start,
  input  logic        palette_dma_start,
  output logic        start_ready,
  output logic        busy,
  output logic        done,
  // WRAM read service
  output logic        wram_req,
  output logic [14:0] wram_addr,
  input  logic        wram_readack,
  input  logic [15:0] wram_data,
  // palette service
  output logic        palette_valid,
  output logic [10:0] palette_addr,
  output logic [15:0] palette_data,
  output logic [1:0]  palette_be,
  input  logic        palette_ready,
  // CPU glyph mirror writes (applied while not unpacked)
  input  logic        cpu_mirror_we,
  input  logic [13:0] cpu_mirror_address,
  input  logic [15:0] cpu_mirror_data,
  input  logic [1:0]  cpu_mirror_be,
  output logic        text_unpacked,
  output wire         ctx_mirror_commit, ctx_glyph_valid,
  output wire [15:0]  ctx_glyph_before,
  // renderer reads (one-cycle, unarbitrated)
  input  logic [13:0] glyph_raddr,
  output logic [15:0] glyph_rdata,
  input  logic [11:0] text_raddr,
  output logic [15:0] text_rdata,
  input  logic [7:0]  select_raddr,
  output logic [15:0] select_rdata,
  input  logic [7:0]  scroll_raddr,
  output logic [15:0] scroll_rdata,
  // hold and state aperture
  input  logic        hold_request,
  output logic        held,
  input  logic        state_access_enable,
  input  logic [63:0] SS_DATA,
  output logic [63:0] SS_DATA_OUT,
  input  logic [31:0] SS_ADDR,
  input  logic [7:0]  SS_SELECT,
  input  logic        SS_WRITE,
  input  logic        SS_READ,
  input  logic        SS_QUERY,
  output logic        SS_ACK
);
  logic held_q, unpacked_q;

  // ------------------------------------------------------------ engine
  logic       accept_glyph, lw_valid;
  logic [1:0] lw_dest;
  logic [13:0] lw_addr;
  logic [15:0] lw_data;
  // a metadata query alone does not block a trigger
  wire allow = !hold_request && !held_q && !state_access_enable && !SS_READ && !SS_WRITE;

  rztdma_engine u_engine (
    .clk(clk), .reset(reset),
    .text_dma_start(text_dma_start), .palette_dma_start(palette_dma_start),
    .allow(allow), .start_ready(start_ready), .accept_glyph(accept_glyph),
    .busy(busy), .done(done),
    .wram_req(wram_req), .wram_addr(wram_addr), .wram_readack(wram_readack), .wram_data(wram_data),
    .palette_valid(palette_valid), .palette_addr(palette_addr), .palette_data(palette_data),
    .palette_be(palette_be), .palette_ready(palette_ready),
    .lw_valid(lw_valid), .lw_dest(lw_dest), .lw_addr(lw_addr), .lw_data(lw_data)
  );

  // ------------------------------------------------------------ hold
  // held sets while requested and not busy; clears when the request drops
  always_ff @(posedge clk) begin
    if (reset)              held_q <= 1'b0;
    else if (!hold_request) held_q <= 1'b0;
    else if (!busy)         held_q <= 1'b1;
  end
  assign held = held_q;

  // ------------------------------------------------------------ state aperture
  logic        st_mem, st_we;
  logic [2:0]  st_region;
  logic [13:0] st_addr;
  logic [15:0] st_wdata;
  logic [15:0] glyph_b_q, text_b_q, select_b_q, scroll_b_q;

  rztdma_state #(
    .REGION_GLYPH(REGION_GLYPH), .REGION_TEXT(REGION_TEXT), .REGION_SELECT(REGION_SELECT),
    .REGION_SCROLL(REGION_SCROLL), .REGION_UNPACKED(REGION_UNPACKED)
  ) u_state (
    .clk(clk), .reset(reset), .owned(held_q && state_access_enable),
    .SS_DATA(SS_DATA), .SS_DATA_OUT(SS_DATA_OUT), .SS_ADDR(SS_ADDR), .SS_SELECT(SS_SELECT),
    .SS_WRITE(SS_WRITE), .SS_READ(SS_READ), .SS_QUERY(SS_QUERY), .SS_ACK(SS_ACK),
    .st_mem(st_mem), .st_region(st_region), .st_addr(st_addr), .st_we(st_we), .st_wdata(st_wdata),
    .glyph_q(glyph_b_q), .text_q(text_b_q), .select_q(select_b_q), .scroll_q(scroll_b_q),
    .unpacked(unpacked_q)
  );

  // ------------------------------------------------------------ unpacked flag
  always_ff @(posedge clk) begin
    if (reset)                                    unpacked_q <= 1'b0;
    else if (accept_glyph)                        unpacked_q <= 1'b1;
    else if (st_we && st_region == 3'd4)          unpacked_q <= st_wdata[0];
  end
  assign text_unpacked = unpacked_q;

  // ------------------------------------------------------------ control-port arbitration
  wire dma_glyph  = lw_valid && lw_dest == 2'd0;
  wire dma_text   = lw_valid && lw_dest == 2'd1;
  wire dma_select = lw_valid && lw_dest == 2'd2;
  wire dma_scroll = lw_valid && lw_dest == 2'd3;
  wire st_glyph   = st_mem && st_region == 3'd0;
  wire st_text    = st_mem && st_region == 3'd1;
  wire st_select  = st_mem && st_region == 3'd2;
  wire st_scroll  = st_mem && st_region == 3'd3;
  wire mirror     = cpu_mirror_we && !unpacked_q && !reset && !held_q;

  logic [13:0] g_addr;
  logic        g_we;
  logic [1:0]  g_be;
  logic [15:0] g_d;
  always_comb begin
    if (dma_glyph) begin
      g_addr = lw_addr;  g_we = 1'b1;  g_be = 2'b11;         g_d = lw_data;
    end else if (st_glyph) begin
      g_addr = st_addr;  g_we = st_we; g_be = 2'b11;         g_d = st_wdata;
    end else begin
      g_addr = cpu_mirror_address; g_we = mirror; g_be = cpu_mirror_be; g_d = cpu_mirror_data;
    end
  end

  logic        mirror_read_q;
  logic [13:0] mirror_index_q;
  wire mirror_port = !dma_glyph && !st_glyph;
  always_ff @(posedge clk) begin
    mirror_read_q <= !reset && mirror_port && !g_we;
    mirror_index_q <= cpu_mirror_address;
  end
  assign ctx_mirror_commit = mirror_port && mirror && (|cpu_mirror_be);
  assign ctx_glyph_valid = !reset && mirror_read_q && mirror_index_q==cpu_mirror_address;
  assign ctx_glyph_before = glyph_b_q;

  rztdma_ram #(.AW(14)) u_glyph (
    .clk(clk), .a_addr(glyph_raddr), .a_q(glyph_rdata),
    .b_addr(g_addr), .b_we(g_we), .b_be(g_be), .b_d(g_d), .b_q(glyph_b_q)
  );
  rztdma_ram #(.AW(12)) u_text (
    .clk(clk), .a_addr(text_raddr), .a_q(text_rdata),
    .b_addr(dma_text ? lw_addr[11:0] : st_addr[11:0]), .b_we(dma_text || (st_text && st_we)), .b_be(2'b11),
    .b_d(dma_text ? lw_data : st_wdata), .b_q(text_b_q)
  );
  rztdma_ram #(.AW(8)) u_select (
    .clk(clk), .a_addr(select_raddr), .a_q(select_rdata),
    .b_addr(dma_select ? lw_addr[7:0] : st_addr[7:0]), .b_we(dma_select || (st_select && st_we)), .b_be(2'b11),
    .b_d(dma_select ? lw_data : st_wdata), .b_q(select_b_q)
  );
  rztdma_ram #(.AW(8)) u_scroll (
    .clk(clk), .a_addr(scroll_raddr), .a_q(scroll_rdata),
    .b_addr(dma_scroll ? lw_addr[7:0] : st_addr[7:0]), .b_we(dma_scroll || (st_scroll && st_we)), .b_be(2'b11),
    .b_d(dma_scroll ? lw_data : st_wdata), .b_q(scroll_b_q)
  );
endmodule

`timescale 1ns/1ps
module rztdma_ram #(parameter int AW=8) (
    input clk,
    input [AW-1:0] a_addr,b_addr,
    output [15:0] a_q,b_q,
    input b_we,
    input [1:0] b_be,
    input [15:0] b_d
);
    // Primitive port A = control (b_*), port B = renderer (a_*).
    altsyncram #(
        .operation_mode("BIDIR_DUAL_PORT"),.intended_device_family("Cyclone V"),
        .ram_block_type("M10K"),.byte_size(8),
        .width_a(16),.widthad_a(AW),.numwords_a(1<<AW),.width_byteena_a(2),
        .width_b(16),.widthad_b(AW),.numwords_b(1<<AW),.width_byteena_b(1),
        .address_reg_b("CLOCK0"),.rdcontrol_reg_b("CLOCK0"),
        .indata_reg_b("CLOCK0"),.byteena_reg_b("CLOCK0"),.wrcontrol_wraddress_reg_b("CLOCK0"),
        .outdata_reg_a("UNREGISTERED"),.outdata_reg_b("UNREGISTERED"),
        .read_during_write_mode_mixed_ports("OLD_DATA"),.power_up_uninitialized("FALSE")
    ) ram (
        .clock0(clk),.clocken0(1'b1),
        .addressstall_a(1'b0),.addressstall_b(1'b0),
        .address_a(b_addr),.data_a(b_d),.byteena_a(b_be),
        .wren_a(b_we && |b_be),.rden_a(!b_we),.q_a(b_q),
        .address_b(a_addr),.data_b(16'd0),.byteena_b(1'b1),
        .wren_b(1'b0),.rden_b(1'b1),.q_b(a_q),.eccstatus()
    );
endmodule

// Late-board 68000 bus: decodes endpoints and routes each cycle to ROM, Z80 ROM, work RAM, GP9001, mailbox wait or local registers.
module rzlate_bus (
    input logic bak,   // 1 = Bakraid, 0 = Batrider (latched)
    output raizing_socket_pkg::mem_in_t sk_mem_i,
    input raizing_socket_pkg::mem_out_t sk_mem_o,

    input logic clk, reset,
    input logic [23:1] cpu_addr,
    input logic cpu_as_n, cpu_rw, cpu_uds_n, cpu_lds_n,
    input logic [2:0] cpu_fc,
    input logic [15:0] cpu_dout,
    input logic block_writes, override_valid,
    output logic [15:0] cpu_din,
    output wire selected, busy, idle,
    output logic rom_req,
    output logic [19:0] rom_addr,
    input logic rom_ok,
    input logic [15:0] rom_data,
    output logic zrom_req,
    output logic [17:0] zrom_addr,
    input logic zrom_ok,
    input logic [7:0] zrom_data,
    output logic gp_req, gp_start,
    output logic [2:0] gp_op, gp_bank_slot,
    output logic [1:0] gp_be,
    output logic [15:0] gp_din,
    input logic gp_ack,
    input logic [15:0] gp_dout,
    input logic [8:0] vpos,
    input logic status_hs_n, status_vs_n, status_blank_n,
    input logic [7:0] p1_inputs, p2_inputs, sys_inputs, dsw_a, dsw_b, dsw_c,
    output wire [2:0] mailbox_write,
    output wire [7:0] mailbox_data,
    output wire mailbox_restore, mailbox_wait_active,
    output wire [31:0] mailbox_restore_data,
    input logic [31:0] mailbox_capture,
    input logic mailbox_wait_grant,
    input logic [7:0] sound_latch3, sound_latch4,
    input logic sound_bus_ack, sound_command_write,
    output wire sound_bus_request, sound_command_commit, sound_irq_clear,
    input logic eeprom_do,
    output wire eeprom_cs, eeprom_di, eeprom_clk,
    output wire dma_text_trigger, dma_palette_trigger,
    output wire ctx_wram_commit, ctx_wram_valid,
    output wire [15:0] ctx_wram_before,
    output wire mirror_write,
    output wire [13:0] mirror_addr,
    output wire [15:0] mirror_data,
    output wire [1:0] mirror_we,
    input logic dma_req, dma_enable,
    input logic [14:0] dma_addr,
    output logic dma_ack,
    output logic [15:0] dma_data,
    input logic ram_enable, ram_req,
    input logic [14:0] ram_addr,
    input logic [15:0] ram_din,
    input logic [1:0] ram_we,
    output logic ram_ack,
    output logic [15:0] ram_dout,
    input logic state_enable, state_active,
    input logic [14:0] state_addr,
    input logic [15:0] state_din,
    input logic [1:0] state_we,
    output wire [15:0] state_q,
    output wire state_ack,
    input logic hs_ready,
    input logic [15:0] score_base, hs_dout,
    output wire hs_cs,
    output wire [8:0] hs_addr,
    output wire [15:0] hs_din,
    output wire [1:0] hs_we,
    output wire wram_write,
    output wire [15:0] wram_addr, wram_data,
    output wire [1:0] wram_we,
    input logic control_restore_we,
    input logic [31:0] control_restore,
    output wire [31:0] control_capture
);
    // Batrider profile; bak selects Bakraid's map (alt_map) and endpoints.
    localparam PROFILE = "batrider";
    localparam integer PERIPH_PROFILE = 3;
    // Late-board endpoint IDs.
localparam logic [5:0] EP_UNMAPPED = 6'd0;
localparam logic [5:0] EP_CPU_SPACE = 6'd1;
localparam logic [5:0] EP_CPU_ROM = 6'd2;
localparam logic [5:0] EP_WORK_RAM = 6'd3;
localparam logic [5:0] EP_WORK_RAM_UPPER = 6'd4;
localparam logic [5:0] EP_INPUT_PLAYERS = 6'd12;
localparam logic [5:0] EP_INPUT_SYSTEM_DIP = 6'd13;
localparam logic [5:0] EP_DIP_REMAINING = 6'd14;
localparam logic [5:0] EP_GP_STATUS = 6'd15;
localparam logic [5:0] EP_GP_REGISTERS = 6'd16;
localparam logic [5:0] EP_SOUND_ROM = 6'd26;
localparam logic [5:0] EP_SOUND_REPLY_0 = 6'd27;
localparam logic [5:0] EP_SOUND_REPLY_1 = 6'd28;
localparam logic [5:0] EP_SOUND_BUSACK = 6'd29;
localparam logic [5:0] EP_SOUND_COMMAND_0 = 6'd30;
localparam logic [5:0] EP_SOUND_COMMAND_1 = 6'd31;
localparam logic [5:0] EP_SOUND_UNKNOWN = 6'd32;
localparam logic [5:0] EP_SOUND_IRQ_ACK = 6'd33;
localparam logic [5:0] EP_SOUND_BUSREQ = 6'd34;
localparam logic [5:0] EP_DMA_TEXT_GFX = 6'd35;
localparam logic [5:0] EP_DMA_PALETTE_TEXT = 6'd36;
localparam logic [5:0] EP_OBJECT_BANK = 6'd37;
localparam logic [5:0] EP_EEPROM_BUSACK = 6'd38;
localparam logic [5:0] EP_EEPROM_CONTROL = 6'd39;

    typedef enum logic [2:0] {LOCAL, PROGRAM, SOUND_ROM, MEMORY, GP, WAIT_GRANT} owner_t;
    owner_t owner, next_owner;
    logic seen, done, captured_hit;
    logic [3:0] read_id, next_read_id;

    wire [39:0] command;
    wire [22:0] command_index;
    wire [1:0] command_lanes;
    wire active = !reset && !override_valid && !cpu_as_n &&
                  (!cpu_uds_n || !cpu_lds_n) && cpu_fc != 3'd7;
    wire start = active && !seen && (|command) && !command[EP_CPU_SPACE];
    wire normal_write = start && !cpu_rw && !block_writes;
    wire wram_route = command[EP_WORK_RAM] || command[EP_WORK_RAM_UPPER];
    wire gp_register = command[EP_GP_REGISTERS];
    wire object_bank = command[EP_OBJECT_BANK];
    wire [14:0] route_word = {command[EP_WORK_RAM_UPPER], command_index[13:0]};
    wire [14:0] view_word = cpu_addr[15:1];

    wire rom_reply = active && rom_req && rom_ok;
    wire zrom_reply = active && zrom_req && zrom_ok;
    wire gp_reply = active && gp_req && gp_ack;
    wire [15:0] zrom_word = {8'b0, zrom_data};
    wire link_complete = rom_reply || zrom_reply || gp_reply || (active && done);
    wire [15:0] link_data = rom_reply ? rom_data : zrom_reply ? zrom_word :
                            gp_reply ? gp_dout : cpu_din;
    rzbus_cpu_link #(.PROFILE(PROFILE)) cpu_link (
        .alt_map(bak),
        .clk(clk), .reset(reset), .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n),
        .cpu_rw(cpu_rw), .cpu_uds_n(cpu_uds_n), .cpu_lds_n(cpu_lds_n),
        .cpu_fc(cpu_fc), .cpu_dout(cpu_dout), .override_valid(override_valid),
        .selected(selected), .busy(busy), .idle(idle),
        .command(command), .command_index(command_index), .command_lanes(command_lanes),
        .owner_complete(link_complete), .owner_data(link_data)
    );

    wire [1:0] gp_kind, leaf_gp_be;
    wire [2:0] leaf_gp_op, leaf_gp_bank;
    wire [15:0] leaf_gp_data, local_data, bus_status;
    wire [1:0] gp_endpoint = gp_register ? 2'd1 : object_bank ? 2'd2 : 2'd0;
    rzperiph_gp_command #(.PROFILE(PERIPH_PROFILE)) gp_command (
        .endpoint(gp_endpoint), .index(command_index[2:0]), .read_cycle(cpu_rw),
        .lanes(command_lanes), .block_write(block_writes), .write_data(cpu_dout),
        .kind(gp_kind), .op(leaf_gp_op), .bank(leaf_gp_bank),
        .data(leaf_gp_data), .be(leaf_gp_be)
    );
    rzperiph_read_word #(.PROFILE(PERIPH_PROFILE)) read_word (
        .read_id(read_id), .players({p2_inputs,p1_inputs}), .system_inputs(sys_inputs),
        .dip_a(dsw_a), .dip_b(dsw_b), .dip_c(dsw_c),
        .reply({sound_latch4,sound_latch3}), .bus_status(bus_status), .vpos(vpos),
        .hs_n(status_hs_n), .vs_n(status_vs_n), .blank_n(status_blank_n),
        .bit13(1'b1), .data(local_data)
    );

    assign mailbox_data = cpu_dout[7:0];
    assign mailbox_write = {normal_write && !bak && command[EP_SOUND_BUSREQ],
                            normal_write && command[EP_SOUND_COMMAND_1],
                            normal_write && command[EP_SOUND_COMMAND_0]};
    assign mailbox_restore = control_restore_we;
    assign mailbox_restore_data = control_restore;
    assign sound_command_commit = bak && normal_write && command[EP_SOUND_UNKNOWN];
    wire wait_marker = bak ? sound_command_commit : sound_command_write;
    assign mailbox_wait_active = active && seen && !done && owner == WAIT_GRANT;
    assign sound_irq_clear = normal_write && command[EP_SOUND_IRQ_ACK];
    assign dma_text_trigger = normal_write && command[EP_DMA_TEXT_GFX];
    assign dma_palette_trigger = normal_write && command[EP_DMA_PALETTE_TEXT];

    wire [1:0] payload_lanes;
    wire payload_hit = |payload_lanes;
    // Bakraid GPIO (EEPROM pins, sound bus request) or Batrider score window, selected by bak.
    wire [3:0] gpio_capture;
    wire [15:0] gpio_status;
    wire gpio_cs, gpio_di, gpio_clk, gpio_bus_request;
    rzbak_gpio gpio (
        .clk(clk), .reset(reset), .write_commit(bak && normal_write && command[EP_EEPROM_CONTROL]),
        .write_lanes(command_lanes), .write_data(cpu_dout),
        .eeprom_do(eeprom_do), .sound_bus_ack(sound_bus_ack), .read_data(gpio_status),
        .eeprom_cs(gpio_cs), .eeprom_di(gpio_di), .eeprom_clk(gpio_clk),
        .sound_bus_request(gpio_bus_request), .restore_valid(bak && control_restore_we),
        .restore_pins(control_restore[19:16]), .capture_pins(gpio_capture)
    );
    wire [1:0] window_lanes;
    wire [8:0] window_word;
    rzscore_window #(.PROFILE(3)) score_window (
        .alt_map(1'b0),
        .word_addr(cpu_addr), .score_base(score_base),
        .payload_lanes(window_lanes), .packed_word(window_word), .witness_window()
    );
    assign bus_status = bak ? gpio_status : {15'b0, sound_bus_ack};
    assign control_capture = bak ? {12'b0, gpio_capture, mailbox_capture[15:0]} : mailbox_capture;
    assign payload_lanes = bak ? 2'b0 : window_lanes;
    assign hs_addr = bak ? 9'b0 : window_word;
    assign {eeprom_cs, eeprom_di, eeprom_clk, sound_bus_request} =
        bak ? {gpio_cs, gpio_di, gpio_clk, gpio_bus_request} : 4'b0;
    assign hs_cs = active && payload_hit;
    assign hs_din = cpu_dout;
    assign hs_we = hs_ready && wram_write ? command_lanes & payload_lanes : 2'b0;

    always_comb begin
        next_owner = LOCAL;
        next_read_id = 4'd0;
        if (command[EP_CPU_ROM] && cpu_rw) next_owner = PROGRAM;
        else if (command[EP_SOUND_ROM] && cpu_rw) next_owner = SOUND_ROM;
        else if (wram_route) next_owner = MEMORY;
        else if (gp_register || object_bank) begin
            if (gp_kind == 2'd2 && (cpu_rw || !block_writes)) next_owner = GP;
            else if (gp_register && (gp_kind == 2'd1 || (!cpu_rw && block_writes)))
                next_read_id = 4'd11;
        end else if (wait_marker) next_owner = WAIT_GRANT;
        else if (cpu_rw) begin
            if (command[EP_INPUT_PLAYERS]) next_read_id = 4'd1;
            else if (command[EP_INPUT_SYSTEM_DIP]) next_read_id = 4'd3;
            else if (command[EP_DIP_REMAINING]) next_read_id = 4'd4;
            else if (command[EP_GP_STATUS]) next_read_id = 4'd7;
            else if (command[EP_SOUND_REPLY_0]) next_read_id = 4'd8;
            else if (command[EP_SOUND_REPLY_1]) next_read_id = 4'd9;
            else if (bak ? command[EP_EEPROM_BUSACK] : command[EP_SOUND_BUSACK])
                next_read_id = 4'd10;
        end
    end

    wire primary_ready, primary_rsp, primary_error, memory_write;
    wire [15:0] primary_data;
    wire [127:0] views;
    wire [7:0] view_valid;
    wire primary_offer = start && wram_route;
    wire primary_write = normal_write && wram_route;
    logic [14:0] previous_word;
    logic previous_write, previous_sample;
    assign wram_write = primary_write && primary_ready;
    assign wram_addr = {cpu_addr[15:1], 1'b0};
    assign wram_data = cpu_dout;
    assign wram_we = wram_write ? command_lanes : 2'b0;
    assign mirror_write = wram_write && !cpu_addr[15];
    assign mirror_addr = cpu_addr[14:1];
    assign mirror_data = cpu_dout;
    assign mirror_we = mirror_write ? command_lanes : 2'b0;
    assign ctx_wram_commit = wram_write;
    assign ctx_wram_before = views[15:0];
    assign ctx_wram_valid = !reset && view_valid[0] && previous_sample &&
                            previous_word == route_word && !previous_write &&
                            !(hs_ready && payload_hit);

    logic [2:0] aux_seen;
    wire [2:0] aux_ready, aux_rsp, aux_error;
    wire [47:0] aux_data;
    wire state_owner = (bak ? state_enable : ram_enable) && state_active && !reset;
    wire optional_owner = !bak && ram_req && ram_enable && !state_active && !reset;
    wire hold_cert = state_owner || optional_owner;
    wire dma_owner = dma_req && dma_enable && !hold_cert && (bak || !reset);
    wire [2:0] aux_valid = {dma_owner, optional_owner, state_owner} & ~aux_seen;
    wire [2:0] raw_req = {dma_req, !bak && ram_req, state_active};
    assign state_ack = aux_rsp[0];
    assign state_q = aux_data[15:0];

    // Shared rzmem_owner, via socket sk_mem.
    assign sk_mem_i.scratch_en = 1'b0;
    assign sk_mem_i.late_en = 1'b1;
    assign sk_mem_i.clk = clk;
    assign sk_mem_i.rst = reset;
    assign sk_mem_i.cpu_quiesce = 1'b0;
    assign sk_mem_i.hold_cert = hold_cert;
    assign sk_mem_i.dma_enable = dma_enable;
    assign sk_mem_i.write_block = block_writes;
    assign sk_mem_i.cpu_valid = primary_offer;
    assign sk_mem_i.cpu_endpoint = command[EP_WORK_RAM_UPPER] ? EP_WORK_RAM_UPPER : EP_WORK_RAM;
    assign sk_mem_i.cpu_index = command_index;
    assign sk_mem_i.cpu_write = !cpu_rw;
    assign sk_mem_i.cpu_be = command_lanes;
    assign sk_mem_i.cpu_wdata = cpu_dout;
    assign sk_mem_i.cpu_tag = 1'b0;
    assign sk_mem_i.cpu_rsp_ready = 1'b1;
    assign sk_mem_i.view_addr = {105'b0, view_word};
    assign sk_mem_i.view_wdata = 128'b0;
    assign sk_mem_i.view_we = 16'b0;
    assign sk_mem_i.aux_valid = aux_valid;
    assign sk_mem_i.aux_region = 9'b0;
    assign sk_mem_i.aux_addr = {dma_addr, (bak ? 15'b0 : ram_addr), state_addr};
    assign sk_mem_i.aux_wdata = {16'b0, (bak ? 16'b0 : ram_din), state_din};
    assign sk_mem_i.aux_we = {2'b0, (bak ? 2'b0 : ram_we), state_we};
    assign sk_mem_i.aux_tag = 3'b0;
    assign sk_mem_i.aux_rsp_ready = bak ? 3'b101 : 3'b111;
    assign primary_ready = sk_mem_o.cpu_ready;
    assign primary_rsp = sk_mem_o.cpu_rsp_valid;
    assign primary_data = sk_mem_o.cpu_rsp_data;
    assign primary_error = sk_mem_o.cpu_rsp_error;
    assign views = sk_mem_o.view_data;
    assign view_valid = sk_mem_o.view_valid;
    assign aux_ready = sk_mem_o.aux_ready;
    assign aux_rsp = sk_mem_o.aux_rsp_valid;
    assign aux_data = sk_mem_o.aux_rsp_data;
    assign aux_error = sk_mem_o.aux_rsp_error;
    assign memory_write = sk_mem_o.wram_commit;

    always_ff @(posedge clk) begin
        if (reset) begin
            previous_word <= 15'b0;
            previous_write <= 1'b0;
            previous_sample <= 1'b0;
            aux_seen <= 3'b0;
            dma_ack <= 1'b0;
            dma_data <= 16'b0;
            ram_ack <= 1'b0;
            ram_dout <= 16'b0;
        end else begin
            previous_word <= view_word;
            previous_write <= memory_write || wram_write;
            previous_sample <= 1'b1;
            aux_seen <= (aux_seen & raw_req) | (aux_valid & aux_ready);
            dma_ack <= aux_rsp[2];
            ram_ack <= !bak && aux_rsp[1];
            if (aux_rsp[2]) dma_data <= aux_data[47:32];
            if (!bak && aux_rsp[1]) ram_dout <= aux_data[31:16];
        end
    end

    logic response;
    logic [15:0] response_data;
    always_comb begin
        response = 1'b0;
        response_data = 16'b0;
        case (owner)
            PROGRAM: begin response = rom_reply; response_data = rom_data; end
            SOUND_ROM: begin response = zrom_reply; response_data = zrom_word; end
            GP: begin response = gp_reply; response_data = gp_dout; end
            MEMORY: begin
                response = primary_rsp;
                if (!primary_error) response_data = captured_hit && hs_ready ? hs_dout : primary_data;
            end
            WAIT_GRANT: response = mailbox_wait_grant;
            LOCAL: begin
                response = 1'b1;
                if (read_id != 4'd0) response_data = local_data;
            end
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        gp_start <= 1'b0;
        if (reset) begin
            seen <= 1'b0;
            done <= 1'b0;
            owner <= LOCAL;
            read_id <= 4'b0;
            captured_hit <= 1'b0;
            cpu_din <= 16'b0;
            rom_req <= 1'b0;
            rom_addr <= 20'b0;
            zrom_req <= 1'b0;
            zrom_addr <= 18'b0;
            gp_req <= 1'b0;
            gp_op <= 3'b0;
            gp_bank_slot <= 3'b0;
            gp_be <= 2'b0;
            gp_din <= 16'b0;
        end else if (!active) begin
            seen <= 1'b0;
            done <= 1'b0;
            owner <= LOCAL;
            read_id <= 4'b0;
            captured_hit <= 1'b0;
            rom_req <= 1'b0;
            zrom_req <= 1'b0;
            gp_req <= 1'b0;
        end else if (start) begin
            seen <= 1'b1;
            done <= 1'b0;
            owner <= next_owner;
            read_id <= next_read_id;
            captured_hit <= payload_hit;
            gp_be <= command_lanes;
            case (next_owner)
                PROGRAM: begin rom_req <= 1'b1; rom_addr <= cpu_addr[20:1]; end
                SOUND_ROM: begin
                    zrom_req <= 1'b1;
                    zrom_addr <= bak ? {1'b0, cpu_addr[17:1]} : cpu_addr[18:1];
                end
                GP: begin
                    gp_req <= 1'b1;
                    gp_start <= 1'b1;
                    gp_op <= leaf_gp_op;
                    gp_be <= leaf_gp_be;
                    if (!cpu_rw) gp_din <= leaf_gp_data;
                    if (object_bank) gp_bank_slot <= leaf_gp_bank;
                end
                default: ;
            endcase
        end else if (seen && !done && response) begin
            cpu_din <= response_data;
            done <= 1'b1;
            rom_req <= 1'b0;
            zrom_req <= 1'b0;
            gp_req <= 1'b0;
        end
    end

`ifndef SYNTHESIS
    always @(posedge clk) if (!reset) begin
        if (primary_offer && !primary_ready) $fatal(1, "schedule: primary refusal");
        if (primary_rsp && primary_error) $warning("schedule: primary response error");
        if (|(aux_rsp & aux_error)) $fatal(1, "schedule: secondary response error");
        if (state_owner && (primary_write || aux_rsp[1] || aux_rsp[2]))
            $fatal(1, "schedule: state overlap");
        if (!bak && ((optional_owner || dma_owner) && primary_write ||
                     dma_owner && aux_rsp[1]))
            $fatal(1, "schedule: Batrider auxiliary overlap");
        if (bak && dma_req && dma_enable && primary_write)
            $fatal(1, "schedule: Bakraid DMA overlap");
        if (bak && control_restore_we && !cpu_as_n) $fatal(1, "schedule: GPIO restore overlap");
    end
`endif
endmodule

module rzlate_main_cpu #(
    parameter integer SCORE_BYTES = 1024
) (
    input wire bak,   // 1 = Bakraid, 0 = Batrider (latched)
    output raizing_socket_pkg::mem_in_t sk_mem_i,
    input raizing_socket_pkg::mem_out_t sk_mem_o,

    output raizing_socket_pkg::ctx_in_t sk_ctx_i,
    input raizing_socket_pkg::ctx_out_t sk_ctx_o,

    output raizing_socket_pkg::cpu_in_t sk_cpu_i,
    input raizing_socket_pkg::cpu_out_t sk_cpu_o,

    input wire clk, reset, pause, hold_req, ss_freeze,
    output wire quiesced,
    output wire rom_req,
    output wire [19:0] rom_addr,
    input wire rom_ok,
    input wire [15:0] rom_data,
    output wire zrom_req,
    output wire [17:0] zrom_addr,
    input wire zrom_ok,
    input wire [7:0] zrom_data,
    output wire gp_req, gp_start,
    output wire [2:0] gp_op, gp_bank_slot,
    output wire [1:0] gp_be,
    output wire [15:0] gp_din,
    input wire gp_ack,
    input wire [15:0] gp_dout,
    input wire vblank_n,
    input wire [8:0] vpos,
    input wire status_hs_n, status_vs_n, status_blank_n,
    input wire [7:0] p1_inputs, p2_inputs, sys_inputs, dsw_a, dsw_b, dsw_c,
    output wire [2:0] mailbox_write,
    output wire [7:0] mailbox_data,
    output wire mailbox_restore, mailbox_wait_active,
    output wire [31:0] mailbox_restore_data,
    input wire [31:0] mailbox_capture,
    input wire mailbox_wait_grant,
    input wire [7:0] sound_latch3, sound_latch4,
    input wire sound_bus_ack,
    input wire sound_command_write, sound_irq,
    output wire sound_bus_request, sound_command_commit,   // Bakraid
    input wire eeprom_do,                                  // Bakraid
    output wire eeprom_cs, eeprom_di, eeprom_clk,          // Bakraid
    output wire dma_text_trigger, dma_palette_trigger,
    output wire mirror_write,
    output wire [13:0] mirror_addr,
    output wire [15:0] mirror_data,
    output wire [1:0] mirror_we,
    input wire dma_req,
    input wire [14:0] dma_addr,
    output wire dma_ack,
    output wire [15:0] dma_data,
    input wire ram_req, ram_access_enable,
    input wire [14:0] ram_addr,
    input wire [15:0] ram_din,
    input wire [1:0] ram_we,
    output wire ram_ack,
    output wire [15:0] ram_dout,
    input wire hs_ready,
    input wire [15:0] score_base, hs_dout,
    output wire hs_cs,
    output wire [8:0] hs_addr,
    output wire [15:0] hs_din,
    output wire [1:0] hs_we,
    output wire wram_write,
    output wire [15:0] wram_addr, wram_data,
    output wire [1:0] wram_we,
    output wire m68k_reset_n,
    input rzctx_slot_pkg::request_t ctx_request,
    output rzctx_slot_pkg::response_t ctx_response,
    output wire ctx_fault,
    input wire ctx_dma_held, ctx_mirror_commit, ctx_glyph_valid,
    input wire [15:0] ctx_glyph_before,
    output wire ctx_glyph_write,
    output wire [13:0] ctx_glyph_word,
    output wire [15:0] ctx_glyph_data,
    input wire ctx_glyph_ack,
    input wire ss_save_begin, ss_save_resume, ss_restore_begin, ss_restore_window,
    output wire ss_save_ready, ss_save_done, ss_restore_done, ss_busy,
    input wire [63:0] ss_data,
    input wire [31:0] ss_addr,
    input wire [7:0] ss_select,
    input wire ss_write, ss_read, ss_query,
    output wire [63:0] ss_data_out,
    output wire ss_ack,
    output wire [23:1] cpu_addr,
    output wire cpu_as_n, cpu_rw, cpu_uds_n, cpu_lds_n,
    output wire [2:0] cpu_fc,
    output wire cpu_phase1, cpu_phase2
);
    wire bus_selected, bus_busy, bus_idle;
    wire [15:0] bus_read_data, cpu_write_data;
    wire normal_as_n, phase_run, phase_dtack_n, phase1_pending;
    wire cpu_halted_n;
    wire [2:0] irq_ipl_n;
    wire irq_cpu_space, irq_vpa_n, sound_clear, sound_pending;

    wire private_claim, private_dtack_n, private_vpa_n, private_irq7;
    wire private_reset, private_busy, private_parked, private_held;
    wire private_captured, private_admitted;
    wire [15:0] private_read_data;
    wire service_run;

    wire [15:0] cpu_read_data = private_claim ? private_read_data : bus_read_data;
    wire cpu_dtack_n = private_claim ? private_dtack_n : (irq_cpu_space | phase_dtack_n);
    wire cpu_vpa_n = private_claim ? private_vpa_n : irq_vpa_n;
    assign normal_as_n = cpu_as_n | private_claim;

    wire hold_requested = pause | hold_req | ss_freeze;
    wire phase_run_game = !ctx_fault &&
        (private_reset || (!private_parked && !private_held &&
        (service_run || !hold_requested || !cpu_as_n)));
    assign phase_run = reset || phase_run_game;
    // Bakraid context tick: a pending phase 1 that will run; Batrider uses phase 1.
    wire context_tick = phase1_pending && phase_run_game;

    // quiesced: hold requested and a quiet bus boundary sampled on the previous clock.
    logic hold_sampled;
    always_ff @(posedge clk) begin
        if (reset)
            hold_sampled <= 1'b0;
        else
            hold_sampled <= hold_requested && !service_run &&
                !cpu_phase1 && !cpu_phase2 &&
                ((cpu_as_n && bus_idle) || private_parked || private_held);
    end
    assign quiesced = hold_sampled && hold_requested && !service_run && !reset;

    logic previous_as_n, window_ack, last_private, first_level7;
    always_ff @(posedge clk) begin
        if (reset) begin
            previous_as_n <= 1'b1;
            window_ack <= 1'b0;
            last_private <= 1'b0;
            first_level7 <= 1'b0;
        end else begin
            previous_as_n <= cpu_as_n;
            if (cpu_as_n) begin
                window_ack <= 1'b0;
            end else begin
                window_ack <= window_ack || !cpu_dtack_n || !cpu_vpa_n;
                last_private <= private_claim;
                if (previous_as_n)
                    first_level7 <= (cpu_fc == 3'd7 && cpu_addr[3:1] == 3'd7);
            end
        end
    end
    wire cycle_done = !reset && cpu_as_n && !previous_as_n && window_ack;

    // Shared fx68k, via socket sk_cpu.
    assign sk_cpu_i.clk = clk;
    assign sk_cpu_i.HALTn = 1'b1;
    assign sk_cpu_i.extReset = reset | private_reset;
    assign sk_cpu_i.pwrUp = reset;
    assign sk_cpu_i.enPhi1 = cpu_phase1;
    assign sk_cpu_i.enPhi2 = cpu_phase2;
    assign sk_cpu_i.DTACKn = cpu_dtack_n;
    assign sk_cpu_i.VPAn = cpu_vpa_n;
    assign sk_cpu_i.BERRn = 1'b1;
    assign sk_cpu_i.BRn = 1'b1;
    assign sk_cpu_i.BGACKn = 1'b1;
    assign sk_cpu_i.IPL0n = irq_ipl_n[0];
    assign sk_cpu_i.IPL1n = irq_ipl_n[1];
    assign sk_cpu_i.IPL2n = irq_ipl_n[2];
    assign sk_cpu_i.iEdb = cpu_read_data;
    assign cpu_rw = sk_cpu_o.eRWn;
    assign cpu_as_n = sk_cpu_o.ASn;
    assign cpu_lds_n = sk_cpu_o.LDSn;
    assign cpu_uds_n = sk_cpu_o.UDSn;
    assign cpu_fc[0] = sk_cpu_o.FC0;
    assign cpu_fc[1] = sk_cpu_o.FC1;
    assign cpu_fc[2] = sk_cpu_o.FC2;
    assign m68k_reset_n = sk_cpu_o.oRESETn;
    assign cpu_halted_n = sk_cpu_o.oHALTEDn;
    assign cpu_write_data = sk_cpu_o.oEdb;
    assign cpu_addr = sk_cpu_o.eab;

    raizing_68k_bus phases (
        .clk(clk), .reset(reset), .run(phase_run), .address_n(normal_as_n),
        .strobe_n({cpu_uds_n, cpu_lds_n}), .selected(bus_selected), .busy(bus_busy),
        .phase1(cpu_phase1), .phase2(cpu_phase2), .phase1_pending(phase1_pending), .dtack_n(phase_dtack_n)
    );

    wire slot_cmd, slot_req, slot_we;
    wire [2:0] slot_op;
    wire [5:0] slot_idx;
    wire [15:0] slot_data;
    assign {slot_cmd, slot_op, slot_req, slot_we, slot_idx, slot_data} = ctx_request;

    wire service_cmd, service_req;
    wire [2:0] service_op;
    wire [5:0] service_idx;
    wire rsp_valid, rsp_ok, ctx_ack, ctx_nak, event_valid;
    wire [3:0] rsp_code, event_code;
    wire [15:0] ctx_rdata;
    wire slot_write = !service_req && slot_we;
    assign ctx_response = {rsp_valid, rsp_ok, rsp_code, ctx_ack, ctx_nak,
                           ctx_rdata, private_admitted, ss_save_ready};
    assign ss_busy = private_busy | service_run;

    // Shared rzctx_core, via socket sk_ctx.
    assign sk_ctx_i.clk = clk;
    assign sk_ctx_i.rst = reset;
    assign sk_ctx_i.cpu_tick = bak ? context_tick : cpu_phase1;
    assign sk_ctx_i.ram_lo = 23'h100000;
    assign sk_ctx_i.ram_hi = 23'h107fff;
    assign sk_ctx_i.cpu_as_n = cpu_as_n;
    assign sk_ctx_i.cpu_uds_n = cpu_uds_n;
    assign sk_ctx_i.cpu_lds_n = cpu_lds_n;
    assign sk_ctx_i.cpu_rw = cpu_rw;
    assign sk_ctx_i.cpu_fc = cpu_fc;
    assign sk_ctx_i.cpu_addr = cpu_addr;
    assign sk_ctx_i.cpu_dout = cpu_write_data;
    assign sk_ctx_i.cpu_halted_n = cpu_halted_n;
    assign sk_ctx_i.bus_done = cycle_done;
    assign sk_ctx_i.cmd_valid = service_cmd | slot_cmd;
    assign sk_ctx_i.cmd_op = service_cmd ? service_op : slot_op;
    assign sk_ctx_i.ctx_req = service_req | slot_req;
    assign sk_ctx_i.ctx_we = slot_write;
    assign sk_ctx_i.ctx_bank = slot_write;
    assign sk_ctx_i.ctx_idx = service_req ? service_idx : slot_idx;
    assign sk_ctx_i.ctx_wdata = slot_data;
    assign private_claim = sk_ctx_o.bus_claim;
    assign private_dtack_n = sk_ctx_o.cpu_dtack_n;
    assign private_vpa_n = sk_ctx_o.cpu_vpa_n;
    assign private_read_data = sk_ctx_o.cpu_din;
    assign private_irq7 = sk_ctx_o.ipl7_req;
    assign private_reset = sk_ctx_o.cpu_reset;
    assign rsp_valid = sk_ctx_o.rsp_valid;
    assign rsp_ok = sk_ctx_o.rsp_ok;
    assign rsp_code = sk_ctx_o.rsp_code;
    assign ctx_ack = sk_ctx_o.ctx_ack;
    assign ctx_nak = sk_ctx_o.ctx_nak;
    assign ctx_rdata = sk_ctx_o.ctx_rdata;
    assign private_busy = sk_ctx_o.st_busy;
    assign private_parked = sk_ctx_o.st_parked;
    assign private_held = sk_ctx_o.st_held;
    assign private_captured = sk_ctx_o.st_cap_valid;
    assign private_admitted = sk_ctx_o.st_admitted;
    assign event_valid = sk_ctx_o.evt_valid;
    assign event_code = sk_ctx_o.evt_code;

    wire journal_arm, journal_cancel, journal_confirm, journal_done, journal_fault;
    wire [14:0] frame_word;
    wire [15:0] frame_pc;
    rzctx_board_service service (
        .clk(clk), .reset(reset), .save_begin(ss_save_begin), .save_resume(ss_save_resume),
        .restore_begin(ss_restore_begin), .parked(private_parked),
        .captured(private_captured), .admitted(private_admitted),
        .event_valid(event_valid), .event_code(event_code),
        .cmd_valid(service_cmd), .cmd_op(service_op), .rsp_valid(rsp_valid), .rsp_ok(rsp_ok),
        .ctx_req(service_req), .ctx_idx(service_idx),
        .ctx_ack(ctx_ack), .ctx_nak(ctx_nak), .ctx_rdata(ctx_rdata),
        .journal_arm(journal_arm), .journal_cancel(journal_cancel), .journal_confirm(journal_confirm),
        .journal_word(frame_word), .journal_pc(frame_pc),
        .journal_done(journal_done), .journal_fault(journal_fault),
        .service_run(service_run), .save_ready(ss_save_ready), .save_done(ss_save_done),
        .restore_done(ss_restore_done), .fault(ctx_fault)
    );

    wire wram_commit, wram_before_valid;
    wire [15:0] wram_before;
    wire sample_commit = wram_commit && wram_before_valid &&
        cpu_fc == 3'd5 && !cpu_uds_n && !cpu_lds_n &&
        (!ctx_mirror_commit || ctx_glyph_valid);
    logic sample_valid;
    logic [14:0] sample_word;
    logic [15:0] sample_written;
    logic [32:0] sample_before;
    always_ff @(posedge clk) begin
        sample_valid <= !reset && sample_commit;
        if (!reset && sample_commit) begin
            sample_word <= cpu_addr[15:1];
            sample_written <= cpu_write_data;
            sample_before <= {ctx_mirror_commit, ctx_glyph_before, wram_before};
        end
    end

    wire journal_held = private_parked && bus_idle && !cpu_phase1 && !cpu_phase2 && ctx_dma_held;
    wire undo_request, undo_ready, undo_rsp_valid, undo_rsp_error, undo_rsp_ready;
    wire [14:0] undo_word;
    wire [32:0] undo_before;
    rzctx_stack_undo #(.PREIMAGE_W(33)) journal (
        .clk(clk), .reset(reset), .arm(journal_arm), .cancel(journal_cancel),
        .ordinary_done(cycle_done && !last_private),
        .private_iack_done(cycle_done && last_private && first_level7),
        .sample_valid(sample_valid), .sample_word(sample_word),
        .sample_before(sample_before), .sample_written(sample_written),
        .confirm(journal_confirm), .frame_word(frame_word), .frame_pc_low(frame_pc),
        .wram_held(journal_held), .undo_valid(undo_request), .undo_ready(undo_ready),
        .undo_word(undo_word), .undo_data(undo_before), .response_valid(undo_rsp_valid),
        .response_error(undo_rsp_error), .response_ready(undo_rsp_ready),
        .done(journal_done), .fault(journal_fault)
    );

    wire undo_wram_write;
    wire [14:0] apply_index;
    wire [15:0] apply_data;
    wire bus_state_ack;
    // Undo owns the state ack from its request until its response is taken.
    wire undo_owns_ack = undo_request || undo_rsp_ready;
    rzctx_late_undo_apply apply_undo (
        .clk(clk), .reset(reset), .request(undo_request), .mirror(undo_before[32]),
        .word_index(undo_word), .wram_before(undo_before[15:0]), .glyph_before(undo_before[31:16]),
        .ready(undo_ready), .wram_held(journal_held), .glyph_held(journal_held),
        .wram_write(undo_wram_write), .glyph_write(ctx_glyph_write),
        .write_index(apply_index), .write_data(apply_data),
        .wram_ack(undo_owns_ack && bus_state_ack), .wram_error(1'b0),
        .glyph_ack(ctx_glyph_ack), .glyph_error(1'b0),
        .response_valid(undo_rsp_valid), .response_error(undo_rsp_error), .response_ready(undo_rsp_ready)
    );
    assign ctx_glyph_word = apply_index[13:0];
    assign ctx_glyph_data = apply_data;

    // ram_access_enable implies hold_requested (asserted below).
    wire host_ram_allowed = hold_sampled && !service_run && !reset && ram_access_enable;
`ifdef SIMULATION
    always_ff @(posedge clk)
        if (!reset && ram_access_enable && !hold_requested) $fatal(1, "LATE_RAM_ACCESS_WITHOUT_HOLD");
`endif
    wire state_allowed = host_ram_allowed && ss_freeze;
    wire bus_ram_permission = (bak ? state_allowed : host_ram_allowed) || (undo_wram_write && journal_held);
    wire ram_active, adapter_ram_we, ram_ss_ack;
    wire [14:0] ram_word;
    wire [15:0] ram_data, bus_state_q;
    wire [63:0] ram_ss_data;
    wire ordinary_state_active = ram_active && !(bak && ram_ss_ack);
    rzmem_ss_workram wram_state (
        .clk(clk), .reset(reset), .ss_data(ss_data), .ss_addr(ss_addr), .ss_select(ss_select),
        .ss_write(ss_write && state_allowed), .ss_read(ss_read && state_allowed), .ss_query(ss_query),
        .ss_data_out(ram_ss_data), .ss_ack(ram_ss_ack), .ram_active(ram_active),
        .ram_addr(ram_word), .ram_data(ram_data), .ram_we(adapter_ram_we), .ram_q(bus_state_q),
        .ram_ack(!undo_owns_ack && bus_state_ack)
    );

    wire [31:0] control_capture;
    wire [32:0] control_restore;
    wire reg_restore_we, reg_ss_ack;
    wire [63:0] reg_ss_data;
    wire control_load = bak ? reg_restore_we && state_allowed : reg_restore_we && ss_freeze && quiesced;
    wire at_register = ss_addr == 32'd0;
    raizing_ss_register #(.WIDTH(33), .SS_INDEX(10)) control_state (
        .clk(clk), .reset(reset), .capture_data({sound_pending, control_capture}),
        .restore_data(control_restore), .restore_we(reg_restore_we),
        .ss_data(ss_data), .ss_select(ss_select), .ss_write(ss_write && at_register && state_allowed),
        .ss_read(ss_read && at_register), .ss_query(ss_query),
        .ss_data_out(reg_ss_data), .ss_ack(reg_ss_ack)
    );
    assign ss_ack = reg_ss_ack || ram_ss_ack;
    assign ss_data_out = (reg_ss_ack ? reg_ss_data : 64'b0) | (ram_ss_ack ? ram_ss_data : 64'b0);

    rzirq_owner #(.PROFILE(rzirq_pkg::RZIRQ_BATRIDER)) irq (
        .alt_levels(bak),
        .clk(clk), .board_reset(reset), .state_hold(ss_freeze), .state_load(control_load),
        .load_video_pending(1'b0), .load_previous_video_n(1'b1),
        .load_sound_pending(control_restore[32]), .gp_vint_n(vblank_n), .raw_lvbl_n(1'b1),
        .sound_irq(sound_irq), .sound_clear(sound_clear), .priv_l7(private_irq7),
        .cpu_as_n(normal_as_n), .cpu_fc(cpu_fc), .cpu_a(cpu_addr[3:1]),
        .ipl_n(irq_ipl_n), .vpa_n(irq_vpa_n), .cpu_space(irq_cpu_space),
        .sound_pending(sound_pending), .irq_level(), .video_pending(), .previous_video_n(),
        .owned_fields(), .unsupported()
    );

    rzlate_bus game_bus (
        .bak(bak), .state_enable(bus_ram_permission),
        .eeprom_do(eeprom_do), .eeprom_cs(eeprom_cs), .eeprom_di(eeprom_di), .eeprom_clk(eeprom_clk),
        .sound_bus_request(sound_bus_request), .sound_command_commit(sound_command_commit),
        .sk_mem_i(sk_mem_i), .sk_mem_o(sk_mem_o),
        .cpu_as_n(normal_as_n), .cpu_dout(cpu_write_data), .cpu_din(bus_read_data),
        .block_writes(1'b0), .override_valid(1'b0),
        .selected(bus_selected), .busy(bus_busy), .idle(bus_idle), .sound_irq_clear(sound_clear),
        .ctx_wram_commit(wram_commit), .ctx_wram_valid(wram_before_valid), .ctx_wram_before(wram_before),
        .dma_enable(quiesced), .ram_enable(bus_ram_permission),
        .state_active(ordinary_state_active || undo_wram_write),
        .state_addr(undo_wram_write ? apply_index : ram_word),
        .state_din(undo_wram_write ? apply_data : ram_data),
        .state_we(undo_wram_write ? 2'b11 : {2{adapter_ram_we}}),
        .state_q(bus_state_q), .state_ack(bus_state_ack),
        .control_capture(control_capture), .control_restore(control_restore[31:0]),
        .control_restore_we(control_load),
        .clk(clk),
        .reset(reset),
        .cpu_addr(cpu_addr),
        .cpu_rw(cpu_rw),
        .cpu_uds_n(cpu_uds_n),
        .cpu_lds_n(cpu_lds_n),
        .cpu_fc(cpu_fc),
        .rom_req(rom_req),
        .rom_addr(rom_addr),
        .rom_ok(rom_ok),
        .rom_data(rom_data),
        .zrom_req(zrom_req),
        .zrom_addr(zrom_addr),
        .zrom_ok(zrom_ok),
        .zrom_data(zrom_data),
        .gp_req(gp_req),
        .gp_start(gp_start),
        .gp_op(gp_op),
        .gp_bank_slot(gp_bank_slot),
        .gp_be(gp_be),
        .gp_din(gp_din),
        .gp_ack(gp_ack),
        .gp_dout(gp_dout),
        .vpos(vpos),
        .status_hs_n(status_hs_n),
        .status_vs_n(status_vs_n),
        .status_blank_n(status_blank_n),
        .p1_inputs(p1_inputs),
        .p2_inputs(p2_inputs),
        .sys_inputs(sys_inputs),
        .dsw_a(dsw_a),
        .dsw_b(dsw_b),
        .dsw_c(dsw_c),
        .mailbox_write(mailbox_write),
        .mailbox_data(mailbox_data),
        .mailbox_restore(mailbox_restore),
        .mailbox_wait_active(mailbox_wait_active),
        .mailbox_restore_data(mailbox_restore_data),
        .mailbox_capture(mailbox_capture),
        .mailbox_wait_grant(mailbox_wait_grant),
        .sound_latch3(sound_latch3),
        .sound_latch4(sound_latch4),
        .sound_bus_ack(sound_bus_ack),
        .sound_command_write(sound_command_write),
        .dma_text_trigger(dma_text_trigger),
        .dma_palette_trigger(dma_palette_trigger),
        .mirror_write(mirror_write),
        .mirror_addr(mirror_addr),
        .mirror_data(mirror_data),
        .mirror_we(mirror_we),
        .dma_req(dma_req),
        .dma_addr(dma_addr),
        .dma_ack(dma_ack),
        .dma_data(dma_data),
        .ram_req(ram_req),
        .ram_addr(ram_addr),
        .ram_din(ram_din),
        .ram_we(ram_we),
        .ram_ack(ram_ack),
        .ram_dout(ram_dout),
        .hs_ready(hs_ready),
        .score_base(score_base),
        .hs_dout(hs_dout),
        .hs_cs(hs_cs),
        .hs_addr(hs_addr),
        .hs_din(hs_din),
        .hs_we(hs_we),
        .wram_write(wram_write),
        .wram_addr(wram_addr),
        .wram_data(wram_data),
        .wram_we(wram_we)
    );

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!reset) begin
            assert (!(service_cmd && slot_cmd)) else $fatal(1, "OVERLAP_SERVICE_SLOT_COMMAND");
            assert (!(service_req && slot_req)) else $fatal(1, "OVERLAP_SERVICE_SLOT_WORD");
            assert (!(undo_owns_ack && ordinary_state_active)) else $fatal(1, "OVERLAP_UNDO_STATE");
        end
    end
`endif
endmodule

module rzlate_board #(parameter USE_SCORE_TOKEN = 1'b0) (
    input logic bak,   // 1 = Bakraid, 0 = Batrider (latched)
    output raizing_socket_pkg::opm_in_t sk_opm_i,
    input raizing_socket_pkg::opm_out_t sk_opm_o,
    output raizing_socket_pkg::oki_in_t sk_oki_i,
    input raizing_socket_pkg::oki_out_t sk_oki_o,

    output raizing_socket_pkg::dma_in_t sk_dma_i,
    input raizing_socket_pkg::dma_out_t sk_dma_o,

    output raizing_socket_pkg::mem_in_t sk_mem_i,
    input raizing_socket_pkg::mem_out_t sk_mem_o,

    output raizing_socket_pkg::ctx_in_t sk_ctx_i,
    input raizing_socket_pkg::ctx_out_t sk_ctx_o,

    output raizing_socket_pkg::z80_in_t sk_z80_i,
    input raizing_socket_pkg::z80_out_t sk_z80_o,

    output raizing_socket_pkg::cpu_in_t sk_cpu_i,
    input raizing_socket_pkg::cpu_out_t sk_cpu_o,

    output raizing_socket_pkg::video_in_t sk_video_i,
    input raizing_socket_pkg::video_out_t sk_video_o,

  input  logic        clk,
  input  logic        reset,
  input  logic        platform_reset,
  // Registered copies: reset | bak, reset | !bak, platform_reset | bak, platform_reset | !bak.
  input  logic        reset_bat,
  input  logic        reset_bak,
  input  logic        platform_reset_bat,
  input  logic        platform_reset_bak,
  input  logic        pixel_ce,
  input  logic        z80_ce,
  input  logic        ym_ce,
  input  logic        ym_phase1_ce,
  input  logic        oki_ce,
  input  logic        ymz_ce,
  input  logic        ymz_sample_ce,

  input  logic        user_pause,
  input  logic        cpu_hold,
  input  logic        sound_hold,
  input  logic        video_hold,
  input  logic        ram_access_enable,
  input  logic        ss_freeze,

  input  rzctx_slot_pkg::request_t  ctx_request,
  output rzctx_slot_pkg::response_t ctx_response,
  output logic        ctx_fault,

  input  logic        save_begin,
  input  logic        save_resume,
  input  logic        restore_begin,
  input  logic        restore_window,
  input  logic        audio_restore,
  output logic        cpu_quiesced,
  output logic        sound_held,
  output logic        video_held,
  output logic        save_ready,
  output logic        save_done,
  output logic        restore_done,
  output logic        handler_busy,

  input  logic [1:0][9:0] joy,
  input  logic [1:0]  start_button,
  input  logic [1:0]  coin,
  input  logic        service,
  input  logic [7:0]  dsw_a,
  input  logic [7:0]  dsw_b,
  input  logic [7:0]  dsw_c,

  input  logic [31:0] rom_crc,
  input  logic [31:0] rom_length,
  input  logic        rom_valid,
  input  logic [3:0]  score_profile,
  input  logic [1:0]  fx_level,
  input  logic        fm_enable,
  input  logic        pcm_enable,
  input  logic [7:0]  audio_gain,          // Bakraid audio controls
  input  logic [3:0]  audio_attenuation,
  input  logic        audio_enable,

  output logic [7:0]   rom_request,
  output logic [191:0] rom_address,
  input  logic [255:0] rom_data,
  input  logic [7:0]   rom_ok,

  output logic        object_req_valid,
  input  logic        object_req_ready,
  output logic [23:0] object_req_addr,
  input  logic        object_rsp_valid,
  output logic        object_rsp_ready,
  input  logic [31:0] object_rsp_data,
  input  logic        object_rsp_error,
  input  tri1         object_port_idle,
  output logic        object_error,        // Bakraid object fault outputs (zero for Batrider)
  output logic        object_deadline_miss,
  output logic        object_row_skipped,
  output logic        object_ownership_error,
  output logic        object_handoff_error,

  output logic [7:0]  red,
  output logic [7:0]  green,
  output logic [7:0]  blue,
  output logic        lhbl,
  output logic        lvbl,
  output logic [8:0]  hcount,
  output logic [8:0]  vcount,
  output logic signed [15:0] audio,

  input  logic        nv_download,
  input  logic        nv_upload,
  input  logic        nv_write,
  input  logic        nv_read,
  input  logic [26:0] nv_addr,
  input  logic [7:0]  nv_data,
  input  logic        ioctl_download,      // Bakraid EEPROM: raw host stream
  input  logic        ioctl_upload,
  input  logic        ioctl_wr,
  input  logic        ioctl_rd,
  input  logic [15:0] ioctl_index,
  input  logic [26:0] ioctl_addr,
  input  logic [7:0]  ioctl_dout,
  output logic [7:0]  nv_q,
  output logic        nv_wait,
  output logic        nv_request,
  output logic        highscore_busy,
  output logic        nv_block,
  output logic        nv_restart,
  output logic        nv_reset_window,
  input  logic        nv_manual,
  input  logic        nv_autosave,
  input  logic        osd_open,

  input  logic        state_pending,
  input  logic        state_active,
  input  logic [63:0] SS_DATA,
  input  logic [31:0] SS_ADDR,
  input  logic [7:0]  SS_SELECT,
  input  logic        SS_WRITE,
  input  logic        SS_READ,
  input  logic        SS_QUERY,
  output logic [63:0] SS_DATA_OUT,
  output logic        SS_ACK,

  output logic        video_error,
  output logic        sound_state_fault,
  output logic        eeprom_state_fault,  // Bakraid (zero for Batrider)
  output logic        audio_deadline_fault,
  output logic        restore_devices_ready,
  output logic        sound_clock_held,
  output logic        sound_restore_active
);
  localparam int         ZROM_AW     = 18;
  localparam logic [7:0] GLYPH_CHUNK = 8'd46;
  localparam logic [8:0] CPU_HS_START = 9'd325;
  localparam logic [8:0] CPU_HS_END   = 9'd380;
  localparam logic [8:0] CPU_VS_START = 9'd232;
  localparam logic [8:0] CPU_VS_END   = 9'd245;

  // Selected sound subsystem drives the Z80 socket.
  raizing_socket_pkg::z80_in_t b_sk_z80_i, k_sk_z80_i;
  assign sk_z80_i = bak ? k_sk_z80_i : b_sk_z80_i;
  // Z80 held rebuilt from each sound subsystem's own wait_n.
  raizing_socket_pkg::z80_out_t b_sk_z80_o, k_sk_z80_o;
  always_comb begin
    b_sk_z80_o = sk_z80_o;
    b_sk_z80_o.held = sk_z80_o.held_base || (b_sk_z80_i.wait_n && sk_z80_o.stop_ready);
    k_sk_z80_o = sk_z80_o;
    k_sk_z80_o.held = sk_z80_o.held_base || (k_sk_z80_i.wait_n && sk_z80_o.stop_ready);
  end
`ifdef SIMULATION
  always_ff @(posedge clk)
    if ((bak ? k_sk_z80_o.held : b_sk_z80_o.held) !==
        (sk_z80_o.held_base || (sk_z80_i.wait_n && sk_z80_o.stop_ready)))
      $fatal(1, "Z80_HELD_LATE_MISMATCH");
`endif

  // Nets between endpoints

  // cabinet decode
  logic [7:0]  dec_p1, dec_p2, dec_sys;

  // main CPU
  logic        cpu_boundary;
  logic        cpu_rom_req;
  logic [19:0] cpu_rom_addr;
  logic        cpu_zrom_req;
  logic [17:0] cpu_zrom_addr;
  logic        gp_req;
  logic [2:0]  gp_op, gp_bank_slot;
  logic [1:0]  gp_be;
  logic [15:0] gp_din;
  logic [2:0]  mb_write;
  logic [7:0]  mb_data;
  logic        mb_restore, mb_wait_active;
  logic [31:0] mb_restore_data;
  logic        cpu_text_trigger, cpu_palette_trigger;
  logic        cpu_mirror_write;
  logic [13:0] cpu_mirror_addr;
  logic [15:0] cpu_mirror_data;
  logic [1:0]  cpu_mirror_we;
  logic        cpu_dma_ack;
  logic [15:0] cpu_dma_data;
  logic [8:0]  cpu_hs_addr;
  logic [15:0] cpu_hs_din;
  logic [1:0]  cpu_hs_we;
  logic        cpu_wram_write;
  logic [15:0] cpu_wram_addr, cpu_wram_data;
  logic [1:0]  cpu_wram_we;
  logic        cpu_reset_n;
  logic        cpu_glyph_write;
  logic [13:0] cpu_glyph_word;
  logic [15:0] cpu_glyph_data;
  logic        cpu_glyph_ack;
  logic [63:0] cpu_ss_data;
  logic        cpu_ss_ack;

  // sound
  // b_: Batrider, k_: Bakraid, unprefixed: selected subsystem
  logic [31:0] snd_mb_capture, b_snd_mb_capture;
  logic        snd_mb_wait_grant, snd_mb_start_wait, snd_mb_bus_request, b_snd_mb_wait_grant;
  logic [7:0]  snd_latch3, snd_latch4, b_snd_latch3, b_snd_latch4;
  logic        snd_irq, snd_bus_ack, b_snd_irq, b_snd_bus_ack;
  logic        snd_held, snd_canon_ready, snd_canon_fault, b_snd_held, b_snd_canon_ready, b_snd_canon_fault;
  logic [17:0] snd_zrom_addr, b_snd_zrom_addr;
  logic        snd_zrom_req, b_snd_zrom_req;
  logic [15:0] k_snd_mb_capture;
  logic        k_snd_mb_wait_grant, k_snd_irq, k_snd_bus_ack;
  logic [7:0]  k_snd_latch3, k_snd_latch4;
  logic        k_snd_held, k_snd_canon_ready, k_snd_canon_fault, k_snd_restore_busy;
  logic [16:0] k_snd_zrom_addr;
  logic        k_snd_zrom_req;
  logic [23:0] k_snd_pcm_addr;
  logic        k_snd_pcm_req;
  logic signed [15:0] b_audio, k_audio;
  logic        k_audio_deadline_fault;
  logic        cpu_snd_bus_request, cpu_snd_command_commit;
  logic        cpu_ee_cs, cpu_ee_di, cpu_ee_clk;
  logic [12:0] snd_ram_addr;
  logic [7:0]  snd_ram_wdata, snd_ram_rdata;
  logic        snd_ram_write;
  logic [19:0] snd_pcm0_addr, snd_pcm1_addr;
  logic        snd_pcm0_req, snd_pcm1_req;
  logic [63:0] snd_ss_data, b_snd_ss_data, k_snd_ss_data;
  logic        snd_ss_ack, b_snd_ss_ack, k_snd_ss_ack;

  // video
  logic        vid_gp_ack;
  logic [15:0] vid_gp_dout;
  logic        vid_vint_n, vid_cpu_hs_n, vid_cpu_vs_n, vid_cpu_fblank;
  logic [8:0]  vid_vcount;
  logic [3:0]  vid_gfx_req;
  logic [95:0] vid_gfx_addr;
  logic        vid_object_error;
  logic [10:0] vid_pal_addr;
  logic [15:0] vid_pal_data, canonical_pal_data;
  logic [10:0] canonical_pal_addr;
  logic palette_hold, palette_blank;
  logic [13:0] vid_glyph_addr;
  logic [11:0] vid_text_addr;
  logic [7:0]  vid_select_addr, vid_scroll_addr;
  logic        vid_quiesced;
  logic [63:0] vid_ss_data;
  logic        vid_ss_ack, vid_ss_error;

  // text DMA
  logic        dma_busy, dma_held;
  logic        dma_wram_req;
  logic [14:0] dma_wram_addr;
  logic        dma_pal_valid, dma_pal_ready;
  logic [10:0] dma_pal_addr;
  logic [15:0] dma_pal_data;
  logic [1:0]  dma_pal_be;
  logic        dma_ctx_commit, dma_ctx_glyph_valid;
  logic [15:0] dma_ctx_glyph_before;
  logic [15:0] dma_glyph_rdata, dma_text_rdata, dma_select_rdata, dma_scroll_rdata;
  logic [63:0] dma_ss_data_out;
  logic        dma_ss_ack;

  // palette memory and its state adapter
  logic [10:0] pal_addr0;
  logic [15:0] pal_data0, pal_q0;
  logic [1:0]  pal_we0;
  logic        pst_active, pst_we;
  logic [10:0] pst_addr;
  logic [15:0] pst_data;
  logic [63:0] pst_ss_data;
  logic        pst_ss_ack;

  // sound RAM state adapter
  logic        sst_active, sst_we;
  logic [12:0] sst_addr;
  logic [7:0]  sst_data, sst_q;
  logic [63:0] sst_ss_data;
  logic        sst_ss_ack;

  // score binding
  logic [15:0] score_base, score_q;
  logic        score_ready, persist_hold, b_persist_hold;
  logic [63:0] score_ss_data;
  logic        score_ss_ack;
  logic [7:0]  b_nv_q, k_nv_q;
  logic        b_nv_wait, b_nv_request, b_highscore_busy, k_nv_wait, k_nv_request;

  // Bakraid EEPROM binding
  logic        ee_do, ee_restore_busy, ee_state_fault, k_persist_hold;
  logic        k_nv_block, k_nv_restart, k_nv_reset_window;
  logic [63:0] ee_ss_data;
  logic        ee_ss_ack;

  // shared Z80 program-ROM owner
  logic [1:0]  zrom_ok;
  logic [7:0]  zrom_data;
  logic        zrom_rom_request;
  logic [ZROM_AW-1:0] zrom_rom_address;
  logic        zrom_idle;

  // CPU / DMA hold contract

  logic explicit_hold, cpu_hold_req, dma_hold_req, cpu_ram_access;
  assign explicit_hold  = cpu_hold | persist_hold | user_pause | state_active;
  assign cpu_hold_req   = cpu_hold | persist_hold | dma_busy;
  assign dma_hold_req   = explicit_hold & cpu_boundary;
  assign cpu_quiesced   = cpu_boundary & ~dma_busy & (~explicit_hold | dma_held);
  assign cpu_ram_access = ram_access_enable & dma_held;

  // Text DMA state aperture and private glyph undo

  logic        host_strobe, glyph_undo, dma_state_enable, dma_host_ack;
  logic [7:0]  dma_ss_select;
  logic [31:0] dma_ss_addr;
  logic [63:0] dma_ss_data_in;
  logic        dma_ss_write, dma_ss_read, dma_ss_query;
  assign host_strobe      = SS_READ | SS_WRITE | SS_QUERY;
  assign glyph_undo       = cpu_glyph_write & cpu_boundary & dma_held;
  assign dma_state_enable = (ram_access_enable & vid_quiesced) | glyph_undo;
  assign dma_ss_select    = glyph_undo ? GLYPH_CHUNK : SS_SELECT;
  assign dma_ss_addr      = glyph_undo ? {18'd0, cpu_glyph_word} : SS_ADDR;
  assign dma_ss_data_in   = glyph_undo ? {48'd0, cpu_glyph_data} : SS_DATA;
  assign dma_ss_write     = glyph_undo | SS_WRITE;
  assign dma_ss_read      = ~glyph_undo & SS_READ;
  assign dma_ss_query     = ~glyph_undo & SS_QUERY;
  assign cpu_glyph_ack    = glyph_undo & dma_ss_ack;
  assign dma_host_ack     = ~glyph_undo & host_strobe & dma_ss_ack;

  // Palette RAM control-port ownership

  logic pal_gate, pal_own;
  assign pal_gate      = ram_access_enable & dma_held & vid_quiesced;
  assign pal_own       = pal_gate & pst_active;
  assign dma_pal_ready = ~reset & ~pal_own;
  assign pal_addr0     = pal_own ? pst_addr : dma_pal_addr;
  assign pal_data0     = pal_own ? pst_data : dma_pal_data;
  assign pal_we0       = pal_own ? {2{pst_we}}
                                 : (dma_pal_be & {2{dma_pal_valid & dma_pal_ready}});

  // Sound RAM state access (raw sound held, not canonical-ready)

  logic snd_gate, snd_own;
  assign snd_gate = ram_access_enable & snd_held & ~bak;
  assign snd_own  = snd_gate & sst_active;

  // Sound reset / mailbox bus request

  logic snd_cpu_reset, snd_bus_request;
  assign snd_cpu_reset   = ~cpu_reset_n & ~state_active;
  assign snd_bus_request = snd_mb_bus_request & ~state_active;

  // Selected sound subsystem and persistence owner.
  assign snd_mb_capture    = bak ? {16'd0, k_snd_mb_capture} : b_snd_mb_capture;
  assign snd_mb_wait_grant = bak ? k_snd_mb_wait_grant : b_snd_mb_wait_grant;
  assign snd_latch3        = bak ? k_snd_latch3 : b_snd_latch3;
  assign snd_latch4        = bak ? k_snd_latch4 : b_snd_latch4;
  assign snd_irq           = bak ? k_snd_irq : b_snd_irq;
  assign snd_bus_ack       = bak ? k_snd_bus_ack : b_snd_bus_ack;
  assign snd_held          = bak ? k_snd_held : b_snd_held;
  assign snd_canon_ready   = bak ? k_snd_canon_ready : b_snd_canon_ready;
  assign snd_canon_fault   = bak ? k_snd_canon_fault : b_snd_canon_fault;
  assign snd_zrom_addr     = bak ? {1'b0, k_snd_zrom_addr} : b_snd_zrom_addr;
  assign snd_zrom_req      = bak ? k_snd_zrom_req : b_snd_zrom_req;
  assign snd_ss_data       = bak ? k_snd_ss_data : b_snd_ss_data;
  assign snd_ss_ack        = bak ? k_snd_ss_ack : b_snd_ss_ack;
  assign audio             = bak ? k_audio : b_audio;
  assign persist_hold      = bak ? k_persist_hold : b_persist_hold;
  assign nv_q              = bak ? k_nv_q : b_nv_q;
  assign nv_wait           = bak ? k_nv_wait : b_nv_wait;
  assign nv_request        = bak ? k_nv_request : b_nv_request;
  assign highscore_busy    = !bak && b_highscore_busy;
  assign nv_block          = bak && k_nv_block;
  assign nv_restart        = bak && k_nv_restart;
  assign nv_reset_window   = bak && k_nv_reset_window;
  assign sound_clock_held      = bak && k_snd_held;
  assign sound_restore_active  = bak && k_snd_restore_busy;
  assign eeprom_state_fault    = bak && ee_state_fault;
  assign audio_deadline_fault  = bak && k_audio_deadline_fault;
  assign restore_devices_ready = bak && ~ee_restore_busy & ~k_snd_restore_busy
                               & ~ee_state_fault & ~k_snd_canon_fault;

  // GP state hold: set once video quiesces during state_active

  logic gp_state_hold;
  always_ff @(posedge clk) begin
    if (reset || !state_active) begin
      gp_state_hold <= 1'b0;
    end else if (vid_quiesced) begin
      gp_state_hold <= 1'b1;
    end
  end

  // ROM lanes (packed least to most significant)

  // Batrider: two OKI lanes; Bakraid: one YMZ lane (lane 3 idle).
  logic pcm0_req_m, pcm1_req_m, k_pcm_req_m;
  assign pcm0_req_m = snd_pcm0_req & ~reset;
  assign pcm1_req_m = snd_pcm1_req & ~reset;
  assign k_pcm_req_m = k_snd_pcm_req & ~reset;

  assign rom_request = {vid_gfx_req, !bak && pcm1_req_m, bak ? k_pcm_req_m : pcm0_req_m,
                        zrom_rom_request, cpu_rom_req};
  assign rom_address = {vid_gfx_addr,
                        bak ? 24'd0 : {4'd0, snd_pcm1_addr},
                        bak ? k_snd_pcm_addr : {4'd0, snd_pcm0_addr},
                        {(24-ZROM_AW){1'b0}}, zrom_rom_address,
                        3'd0, cpu_rom_addr, 1'b0};

  // Host-facing status

  assign sound_held        = state_active && snd_canon_ready;
  assign video_held        = vid_quiesced;
  assign video_error       = vid_ss_error | (!bak && vid_object_error);
  assign sound_state_fault = snd_canon_fault;
  assign vcount            = vid_vcount;

  // State response: OR of provider ACKs, union of acknowledged words

  // Score and sound RAM answer only for Batrider, EEPROM only for Bakraid.
  logic b_score_ack, b_sst_ack, k_ee_ack;
  assign b_score_ack = !bak && score_ss_ack;
  assign b_sst_ack   = !bak && sst_ss_ack;
  assign k_ee_ack    = bak && ee_ss_ack;
  assign SS_ACK = cpu_ss_ack | snd_ss_ack | vid_ss_ack | b_score_ack
                | dma_host_ack | pst_ss_ack | b_sst_ack | k_ee_ack;
  assign SS_DATA_OUT = ({64{cpu_ss_ack}}   & cpu_ss_data)
                     | ({64{snd_ss_ack}}   & snd_ss_data)
                     | ({64{vid_ss_ack}}   & vid_ss_data)
                     | ({64{b_score_ack}}  & score_ss_data)
                     | ({64{dma_host_ack}} & dma_ss_data_out)
                     | ({64{pst_ss_ack}}   & pst_ss_data)
                     | ({64{b_sst_ack}}    & sst_ss_data)
                     | ({64{k_ee_ack}}     & ee_ss_data);

  // Endpoints

  rzboard_inputs #(.PROFILE(3)) u_inputs (
    .player1_n     (joy[0]),
    .player2_n     (joy[1]),
    .start_n       (start_button),
    .coin_n        (coin),
    .service_n     (service),
    .dip_a         (dsw_a),
    .player1       (dec_p1),
    .player2       (dec_p2),
    .system_inputs (dec_sys)
  );

  rzlate_main_cpu #(.SCORE_BYTES(784)) u_cpu (
    .bak                  (bak),
    .sound_bus_request    (cpu_snd_bus_request),
    .sound_command_commit (cpu_snd_command_commit),
    .eeprom_do            (ee_do),
    .eeprom_cs            (cpu_ee_cs),
    .eeprom_di            (cpu_ee_di),
    .eeprom_clk           (cpu_ee_clk),
        .sk_mem_i(sk_mem_i), .sk_mem_o(sk_mem_o),
        .sk_ctx_i(sk_ctx_i), .sk_ctx_o(sk_ctx_o),
        .sk_cpu_i(sk_cpu_i), .sk_cpu_o(sk_cpu_o),
    .clk                  (clk),
    .reset                (reset),
    .pause                (user_pause),
    .hold_req             (cpu_hold_req),
    .ss_freeze            (ss_freeze),
    .quiesced             (cpu_boundary),
    .rom_req              (cpu_rom_req),
    .rom_addr             (cpu_rom_addr),
    .rom_ok               (rom_ok[0]),
    .rom_data             (rom_data[15:0]),
    .zrom_req             (cpu_zrom_req),
    .zrom_addr            (cpu_zrom_addr),
    .zrom_ok              (zrom_ok[0]),
    .zrom_data            (zrom_data),
    .gp_req               (gp_req),
    .gp_start             (),
    .gp_op                (gp_op),
    .gp_bank_slot         (gp_bank_slot),
    .gp_be                (gp_be),
    .gp_din               (gp_din),
    .gp_ack               (vid_gp_ack),
    .gp_dout              (vid_gp_dout),
    .vblank_n             (vid_vint_n),
    .vpos                 (vid_vcount),
    .status_hs_n          (vid_cpu_hs_n),
    .status_vs_n          (vid_cpu_vs_n),
    .status_blank_n       (vid_cpu_fblank),
    .p1_inputs            (dec_p1),
    .p2_inputs            (dec_p2),
    .sys_inputs           (dec_sys),
    .dsw_a                (dsw_a),
    .dsw_b                (dsw_b),
    .dsw_c                (dsw_c),
    .mailbox_write        (mb_write),
    .mailbox_data         (mb_data),
    .mailbox_restore      (mb_restore),
    .mailbox_wait_active  (mb_wait_active),
    .mailbox_restore_data (mb_restore_data),
    .mailbox_capture      (snd_mb_capture),
    .mailbox_wait_grant   (snd_mb_wait_grant),
    .sound_latch3         (snd_latch3),
    .sound_latch4         (snd_latch4),
    .sound_bus_ack        (snd_bus_ack),
    .sound_command_write  (snd_mb_start_wait),
    .sound_irq            (snd_irq),
    .dma_text_trigger     (cpu_text_trigger),
    .dma_palette_trigger  (cpu_palette_trigger),
    .mirror_write         (cpu_mirror_write),
    .mirror_addr          (cpu_mirror_addr),
    .mirror_data          (cpu_mirror_data),
    .mirror_we            (cpu_mirror_we),
    .dma_req              (dma_wram_req),
    .dma_addr             (dma_wram_addr),
    .dma_ack              (cpu_dma_ack),
    .dma_data             (cpu_dma_data),
    .ram_req              (1'b0),
    .ram_access_enable    (cpu_ram_access),
    .ram_addr             (15'd0),
    .ram_din              (16'd0),
    .ram_we               (2'd0),
    .ram_ack              (),
    .ram_dout             (),
    .hs_ready             (!bak && score_ready),
    .score_base           (bak ? 16'd0 : score_base),
    .hs_dout              (bak ? 16'd0 : score_q),
    .hs_cs                (),
    .hs_addr              (cpu_hs_addr),
    .hs_din               (cpu_hs_din),
    .hs_we                (cpu_hs_we),
    .wram_write           (cpu_wram_write),
    .wram_addr            (cpu_wram_addr),
    .wram_data            (cpu_wram_data),
    .wram_we              (cpu_wram_we),
    .m68k_reset_n         (cpu_reset_n),
    .ctx_request          (ctx_request),
    .ctx_response         (ctx_response),
    .ctx_fault            (ctx_fault),
    .ctx_dma_held         (dma_held),
    .ctx_mirror_commit    (dma_ctx_commit),
    .ctx_glyph_valid      (dma_ctx_glyph_valid),
    .ctx_glyph_before     (dma_ctx_glyph_before),
    .ctx_glyph_write      (cpu_glyph_write),
    .ctx_glyph_word       (cpu_glyph_word),
    .ctx_glyph_data       (cpu_glyph_data),
    .ctx_glyph_ack        (cpu_glyph_ack),
    .ss_save_begin        (save_begin),
    .ss_save_resume       (save_resume),
    .ss_restore_begin     (restore_begin),
    .ss_restore_window    (restore_window),
    .ss_save_ready        (save_ready),
    .ss_save_done         (save_done),
    .ss_restore_done      (restore_done),
    .ss_busy              (handler_busy),
    .ss_data              (SS_DATA),
    .ss_addr              (SS_ADDR),
    .ss_select            (SS_SELECT),
    .ss_write             (SS_WRITE),
    .ss_read              (SS_READ),
    .ss_query             (SS_QUERY),
    .ss_data_out          (cpu_ss_data),
    .ss_ack               (cpu_ss_ack),
    .cpu_addr             (),
    .cpu_as_n             (),
    .cpu_rw               (),
    .cpu_uds_n            (),
    .cpu_lds_n            (),
    .cpu_fc               (),
    .cpu_phase1           (),
    .cpu_phase2           ()
  );

  rzbatrider_sound sound (
        .sk_opm_i(sk_opm_i), .sk_opm_o(sk_opm_o),
        .sk_oki_i(sk_oki_i), .sk_oki_o(sk_oki_o),
        .sk_z80_i(b_sk_z80_i), .sk_z80_o(b_sk_z80_o),
    .clk                  (clk),
    .reset                (reset_bat),
    .cpu_reset            (snd_cpu_reset | bak),
    .z80_ce               (z80_ce),
    .ym_ce                (ym_ce),
    .ym_phase1_ce         (ym_phase1_ce),
    .oki_ce               (oki_ce),
    .mailbox_write        (mb_write),
    .mailbox_data         (mb_data),
    .mailbox_restore      (mb_restore),
    .mailbox_wait_active  (mb_wait_active),
    .mailbox_restore_data (mb_restore_data),
    .mailbox_capture      (b_snd_mb_capture),
    .mailbox_wait_grant   (b_snd_mb_wait_grant),
    .mailbox_start_wait   (snd_mb_start_wait),
    .mailbox_bus_request  (snd_mb_bus_request),
    .bus_request          (snd_bus_request),
    .sound_latch3         (b_snd_latch3),
    .sound_latch4         (b_snd_latch4),
    .sound_wait           (),
    .sound_irq            (b_snd_irq),
    .bus_ack              (b_snd_bus_ack),
    .hold_request         (sound_hold | user_pause),
    .canonical_hold       (state_active),
    .restore_commit       (audio_restore),
    .held                 (b_snd_held),
    .replay_busy          (),
    .restore_busy         (),
    .canonical_ready      (b_snd_canon_ready),
    .canonical_fault      (b_snd_canon_fault),
    .canonical_service    (),
    .rom_address          (b_snd_zrom_addr),
    .rom_request          (b_snd_zrom_req),
    .rom_data             (zrom_data),
    .rom_ok               (zrom_ok[1]),
    .shared_address       (snd_ram_addr),
    .shared_data_out      (snd_ram_wdata),
    .shared_write         (snd_ram_write),
    .shared_data_in       (snd_ram_rdata),
    .pcm_address          (snd_pcm0_addr),
    .pcm1_address         (snd_pcm1_addr),
    .pcm_request          (snd_pcm0_req),
    .pcm1_request         (snd_pcm1_req),
    .pcm_frozen           (),
    .pcm1_frozen          (),
    .pcm_resume_busy      (),
    .pcm1_resume_busy     (),
    .pcm_data             (rom_data[71:64]),
    .pcm1_data            (rom_data[103:96]),
    .pcm_ok               (rom_ok[2]),
    .pcm1_ok              (rom_ok[3]),
    .audio                (b_audio),
    .sample               (),
    .fx_level             (fx_level),
    .fm_enable            (fm_enable),
    .pcm_enable           (pcm_enable),
    .SS_DATA              (SS_DATA),
    .SS_ADDR              (SS_ADDR),
    .SS_SELECT            (SS_SELECT),
    .SS_WRITE             (SS_WRITE),
    .SS_READ              (SS_READ),
    .SS_QUERY             (SS_QUERY),
    .SS_DATA_OUT          (b_snd_ss_data),
    .SS_ACK               (b_snd_ss_ack)
  );

`ifdef SIMULATION
  // Registered per-board resets equal their OR expressions.
  always_ff @(posedge clk)
    if (reset_bat !== (reset | bak) || reset_bak !== (reset | !bak) ||
        platform_reset_bat !== (platform_reset | bak) || platform_reset_bak !== (platform_reset | !bak))
      $fatal(1, "LATE_RESET_COPY_MISMATCH");
`endif

  rzbakraid_sound u_sound (
        .sk_z80_i(k_sk_z80_i), .sk_z80_o(k_sk_z80_o),
    .clk                  (clk),
    .reset                (reset_bak),
    .cpu_reset            (snd_cpu_reset | !bak),
    .z80_ce               (z80_ce),
    .ymz_ce               (ymz_ce),
    .ymz_sample_ce        (ymz_sample_ce),
    .mailbox_write        (mb_write[1:0]),
    .mailbox_data         (mb_data),
    .mailbox_restore      (mb_restore),
    .mailbox_wait_active  (mb_wait_active),
    .mailbox_restore_data (mb_restore_data[15:0]),
    .mailbox_capture      (k_snd_mb_capture),
    .mailbox_wait_grant   (k_snd_mb_wait_grant),
    .command_commit       (cpu_snd_command_commit),
    .bus_request          (cpu_snd_bus_request),
    .sound_latch3         (k_snd_latch3),
    .sound_latch4         (k_snd_latch4),
    .sound_wait           (),
    .sound_irq            (k_snd_irq),
    .bus_ack              (k_snd_bus_ack),
    .hold_request         (sound_hold | user_pause),
    .canonical_hold       (state_active),
    .restore_commit       (audio_restore),
    .held                 (k_snd_held),
    .canonical_ready      (k_snd_canon_ready),
    .canonical_fault      (k_snd_canon_fault),
    .canonical_service    (),
    .restore_busy         (k_snd_restore_busy),
    .rom_address          (k_snd_zrom_addr),
    .rom_request          (k_snd_zrom_req),
    .rom_accept           (zrom_ok[1]),
    .rom_valid            (zrom_ok[1]),
    .rom_data             (zrom_data),
    .pcm_address          (k_snd_pcm_addr),
    .pcm_request          (k_snd_pcm_req),
    .pcm_accept           (rom_ok[2]),
    .pcm_valid            (rom_ok[2]),
    .pcm_data             (rom_data[71:64]),
    .gain                 (audio_gain),
    .attenuation          (audio_attenuation),
    .audio_enable         (audio_enable),
    .audio                (k_audio),
    .sample               (),
    .ymz_irq              (),
    .audio_deadline_fault (k_audio_deadline_fault),
    .SS_DATA              (SS_DATA),
    .SS_ADDR              (SS_ADDR),
    .SS_SELECT            (SS_SELECT),
    .SS_WRITE             (SS_WRITE),
    .SS_READ              (SS_READ),
    .SS_QUERY             (SS_QUERY),
    .SS_DATA_OUT          (k_snd_ss_data),
    .SS_ACK               (k_snd_ss_ack)
  );

  // Shared raizing_video, via socket sk_video.
    assign sk_video_i.clk = clk;
    assign sk_video_i.reset = reset;
    assign sk_video_i.pixel_ce = pixel_ce;
    assign sk_video_i.flip = 1'b0;
    assign sk_video_i.hs_start = CPU_HS_START;
    assign sk_video_i.hs_end = CPU_HS_END;
    assign sk_video_i.vs_start = CPU_VS_START;
    assign sk_video_i.vs_end = CPU_VS_END;
    assign sk_video_i.gp_cs = gp_req;
    assign sk_video_i.gp_select_reg = gp_op == 3'd4;
    assign sk_video_i.gp_write_reg = gp_op == 3'd5;
    assign sk_video_i.gp_write_ram = gp_op == 3'd1;
    assign sk_video_i.gp_read_ram_h = gp_op == 3'd2;
    assign sk_video_i.gp_read_ram_l = gp_op == 3'd3;
    assign sk_video_i.gp_set_ram_ptr = gp_op == 3'd0;
    assign sk_video_i.gp_din = gp_din;
    assign sk_video_i.gp_be = gp_be;
    assign sk_video_i.gfx_data = rom_data[255:128];
    assign sk_video_i.gfx_ok = rom_ok[7:4];
    assign sk_video_i.object_req_ready = object_req_ready;
    assign sk_video_i.object_rsp_valid = object_rsp_valid;
    assign sk_video_i.object_rsp_data = object_rsp_data;
    assign sk_video_i.object_rsp_error = object_rsp_error;
    assign sk_video_i.object_port_idle = bak ? object_port_idle : 1'b1;
    assign sk_video_i.gp_objectbank_wr = gp_op == 3'd6;
    assign sk_video_i.gp_objectbank_slot = gp_bank_slot;
    assign sk_video_i.PALRAM_DATA = vid_pal_data;
    assign sk_video_i.TEXTROM_DATA = dma_glyph_rdata;
    assign sk_video_i.TEXTVRAM_DATA = dma_text_rdata;
    assign sk_video_i.TEXTSELECT_DATA = dma_select_rdata;
    assign sk_video_i.TEXTSCROLL_DATA = dma_scroll_rdata;
    assign sk_video_i.SS_FREEZE = video_hold;
    assign sk_video_i.STATE_HOLD = gp_state_hold;
    assign sk_video_i.SS_DATA = SS_DATA;
    assign sk_video_i.SS_ADDR = SS_ADDR;
    assign sk_video_i.SS_SELECT = SS_SELECT;
    assign sk_video_i.SS_WRITE = SS_WRITE;
    assign sk_video_i.SS_READ = SS_READ;
    assign sk_video_i.SS_QUERY = SS_QUERY;
    assign vid_gp_ack = sk_video_o.gp_ack;
    assign vid_gp_dout = sk_video_o.gp_dout;
    assign vid_vint_n = sk_video_o.vint_n;
    assign vid_cpu_hs_n = sk_video_o.cpu_hsync_n;
    assign vid_cpu_vs_n = sk_video_o.cpu_vsync_n;
    assign vid_cpu_fblank = sk_video_o.cpu_fblank;
    assign hcount = sk_video_o.hcount;
    assign vid_vcount = sk_video_o.vcount;
    assign vid_gfx_req = sk_video_o.gfx_req;
    assign vid_gfx_addr = sk_video_o.gfx_addr;
    assign object_req_valid = sk_video_o.object_req_valid;
    assign object_req_addr = sk_video_o.object_req_addr;
    assign object_rsp_ready = sk_video_o.object_rsp_ready;
    assign vid_object_error = sk_video_o.object_error;
    assign object_deadline_miss = bak && sk_video_o.object_deadline_miss;
    assign object_row_skipped = bak && sk_video_o.object_row_skipped;
    assign object_ownership_error = bak && sk_video_o.object_ownership_error;
    assign object_error = bak && sk_video_o.object_error;
    assign object_handoff_error = bak && sk_video_o.object_deadline_miss;
    assign vid_pal_addr = sk_video_o.PALRAM_ADDR;
    assign vid_glyph_addr = sk_video_o.TEXTROM_ADDR;
    assign vid_text_addr = sk_video_o.TEXTVRAM_ADDR;
    assign vid_select_addr = sk_video_o.TEXTSELECT_ADDR;
    assign vid_scroll_addr = sk_video_o.TEXTSCROLL_ADDR;
    assign red = sk_video_o.red;
    assign green = sk_video_o.green;
    assign blue = sk_video_o.blue;
    assign lhbl = sk_video_o.lhbl_dly;
    assign lvbl = sk_video_o.lvbl_dly;
    assign vid_quiesced = sk_video_o.SS_QUIESCED;
    assign vid_ss_data = sk_video_o.SS_DATA_OUT;
    assign vid_ss_ack = sk_video_o.SS_ACK;
    assign vid_ss_error = sk_video_o.SS_ERROR;
    assign palette_hold = sk_video_o.palette_hold;
    assign palette_blank = sk_video_o.palette_blank;

  // Shared rztdma_top, via socket sk_dma.
    assign sk_dma_i.clk = clk;
    assign sk_dma_i.reset = reset;
    assign sk_dma_i.text_dma_start = cpu_text_trigger;
    assign sk_dma_i.palette_dma_start = cpu_palette_trigger;
    assign sk_dma_i.wram_readack = cpu_dma_ack;
    assign sk_dma_i.wram_data = cpu_dma_data;
    assign sk_dma_i.palette_ready = dma_pal_ready;
    assign sk_dma_i.cpu_mirror_we = cpu_mirror_write;
    assign sk_dma_i.cpu_mirror_address = cpu_mirror_addr;
    assign sk_dma_i.cpu_mirror_data = cpu_mirror_data;
    assign sk_dma_i.cpu_mirror_be = cpu_mirror_we;
    assign sk_dma_i.glyph_raddr = vid_glyph_addr;
    assign sk_dma_i.text_raddr = vid_text_addr;
    assign sk_dma_i.select_raddr = vid_select_addr;
    assign sk_dma_i.scroll_raddr = vid_scroll_addr;
    assign sk_dma_i.hold_request = dma_hold_req;
    assign sk_dma_i.state_access_enable = dma_state_enable;
    assign sk_dma_i.SS_DATA = dma_ss_data_in;
    assign sk_dma_i.SS_ADDR = dma_ss_addr;
    assign sk_dma_i.SS_SELECT = dma_ss_select;
    assign sk_dma_i.SS_WRITE = dma_ss_write;
    assign sk_dma_i.SS_READ = dma_ss_read;
    assign sk_dma_i.SS_QUERY = dma_ss_query;
    assign dma_busy = sk_dma_o.busy;
    assign dma_wram_req = sk_dma_o.wram_req;
    assign dma_wram_addr = sk_dma_o.wram_addr;
    assign dma_pal_valid = sk_dma_o.palette_valid;
    assign dma_pal_addr = sk_dma_o.palette_addr;
    assign dma_pal_data = sk_dma_o.palette_data;
    assign dma_pal_be = sk_dma_o.palette_be;
    assign dma_ctx_commit = sk_dma_o.ctx_mirror_commit;
    assign dma_ctx_glyph_valid = sk_dma_o.ctx_glyph_valid;
    assign dma_ctx_glyph_before = sk_dma_o.ctx_glyph_before;
    assign dma_glyph_rdata = sk_dma_o.glyph_rdata;
    assign dma_text_rdata = sk_dma_o.text_rdata;
    assign dma_select_rdata = sk_dma_o.select_rdata;
    assign dma_scroll_rdata = sk_dma_o.scroll_rdata;
    assign dma_held = sk_dma_o.held;
    assign dma_ss_data_out = sk_dma_o.SS_DATA_OUT;
    assign dma_ss_ack = sk_dma_o.SS_ACK;

  // 2048-word palette RAM: port 0 DMA or state access, port 1 video.

  raizing_bram #(.DW(16), .AW(11)) u_palram (
    .clk0  (clk),
    .addr0 (pal_addr0),
    .data0 (pal_data0),
    .we0   (pal_we0),
    .q0    (pal_q0),
    .clk1  (clk),
    .addr1 (canonical_pal_addr),
    .data1 (16'd0),
    .we1   (2'b00),
    .q1    (canonical_pal_data)
  );

  SorcerPaletteTail u_palette_tail (
    .clk(clk), .reset(reset), .tail_hold(bak ? vid_vcount >= 9'd230 && vid_vcount < 9'd240 : palette_hold),
    .in_blank(bak ? vid_vcount >= 9'd240 : palette_blank),
    .cpu_commit(!pal_own), .write_addr(pal_addr0), .write_data(pal_data0), .write_be(pal_we0),
    .display_addr(vid_pal_addr), .display_data(vid_pal_data), .canonical_addr(canonical_pal_addr),
    .canonical_data(canonical_pal_data), .canonical_valid(1'b1), .copy_busy(),
    .live_fallback(), .missed_deadline()
  );

  raizing_ss_ram_adapter #(.WIDTH(16), .ADDR_WIDTH(11), .SS_INDEX(38)) u_palstate (
    .clk         (clk),
    .reset       (reset),
    .ss_data     (SS_DATA),
    .ss_addr     (SS_ADDR),
    .ss_select   (SS_SELECT),
    .ss_write    (SS_WRITE & pal_gate),
    .ss_read     (SS_READ & pal_gate),
    .ss_query    (SS_QUERY),
    .ss_data_out (pst_ss_data),
    .ss_ack      (pst_ss_ack),
    .ram_active  (pst_active),
    .ram_addr    (pst_addr),
    .ram_data    (pst_data),
    .ram_we      (pst_we),
    .ram_q       (pal_q0)
  );

  // 8192-byte sound RAM: port 0 sound CPU, port 1 state access.

  raizing_bram #(.DW(8), .AW(13)) u_sndram (
    .clk0  (clk),
    .addr0 (snd_ram_addr),
    .data0 (snd_ram_wdata),
    .we0   (snd_ram_write & ~snd_own),
    .q0    (snd_ram_rdata),
    .clk1  (clk),
    .addr1 (sst_addr),
    .data1 (sst_data),
    .we1   (sst_we & snd_own),
    .q1    (sst_q)
  );

  raizing_ss_ram_adapter #(.WIDTH(8), .ADDR_WIDTH(13), .SS_INDEX(16)) u_sndstate (
    .clk         (clk),
    .reset       (reset),
    .ss_data     (SS_DATA),
    .ss_addr     (SS_ADDR),
    .ss_select   (SS_SELECT),
    .ss_write    (SS_WRITE & snd_gate),
    .ss_read     (SS_READ & snd_gate),
    .ss_query    (SS_QUERY),
    .ss_data_out (sst_ss_data),
    .ss_ack      (sst_ss_ack),
    .ram_active  (sst_active),
    .ram_addr    (sst_addr),
    .ram_data    (sst_data),
    .ram_we      (sst_we),
    .ram_q       (sst_q)
  );

  rzbatrider_score_binding #(.USE_SCORE_TOKEN(USE_SCORE_TOKEN)) u_score (
    .clk            (clk),
    .reset          (platform_reset_bat),
    .cpu_reset      (reset_bat),
    .rom_crc        (rom_crc),
    .rom_length     (rom_length),
    .rom_valid      (rom_valid),
    .score_profile  (score_profile),
    .score_base     (score_base),
    .nv_download    (nv_download),
    .nv_upload      (nv_upload),
    .nv_write       (nv_write),
    .nv_read        (nv_read),
    .nv_addr        (nv_addr),
    .nv_data        (nv_data),
    .nv_q           (b_nv_q),
    .nv_wait        (b_nv_wait),
    .manual_save    (nv_manual),
    .autosave       (nv_autosave),
    .osd_open       (osd_open),
    .upload_request (b_nv_request),
    .normal_write   (cpu_wram_write),
    .normal_addr    (cpu_wram_addr),
    .normal_data    (cpu_wram_data),
    .normal_we      (cpu_wram_we),
    .ready          (score_ready),
    .cpu_addr       (cpu_hs_addr),
    .cpu_data       (cpu_hs_din),
    .cpu_we         (cpu_hs_we),
    .cpu_q          (score_q),
    .state_active   (state_active),
    .hold_ack       (cpu_quiesced),
    .hold_request   (b_persist_hold),
    .active         (b_highscore_busy),
    .dirty          (),
    .SS_DATA        (SS_DATA),
    .SS_ADDR        (SS_ADDR),
    .SS_SELECT      (SS_SELECT),
    .SS_WRITE       (SS_WRITE),
    .SS_READ        (SS_READ),
    .SS_QUERY       (SS_QUERY),
    .SS_DATA_OUT    (score_ss_data),
    .SS_ACK         (score_ss_ack)
  );

  rzbakraid_eeprom u_eeprom (
    .clk                 (clk),
    .platform_reset      (platform_reset_bak),
    .cpu_reset           (reset_bak),
    .cpu_hold_ack        (cpu_quiesced),
    .serial_cs           (cpu_ee_cs),
    .serial_clk          (cpu_ee_clk),
    .serial_di           (cpu_ee_di),
    .serial_do           (ee_do),
    .state_pending       (state_pending),
    .state_active        (state_active),
    .state_access_enable (ram_access_enable),
    .state_restore_commit(audio_restore),
    .state_block         (k_nv_block),
    .restore_busy        (ee_restore_busy),
    .state_fault         (ee_state_fault),
    .cpu_hold_req        (k_persist_hold),
    .cpu_restart         (k_nv_restart),
    .restart_window      (k_nv_reset_window),
    .manual_save         (nv_manual),
    .autosave            (nv_autosave),
    .osd_open            (osd_open),
    .ioctl_download      (ioctl_download),
    .ioctl_upload        (ioctl_upload),
    .ioctl_index         (ioctl_index),
    .ioctl_addr          (ioctl_addr),
    .ioctl_wr            (ioctl_wr),
    .ioctl_rd            (ioctl_rd),
    .ioctl_dout          (ioctl_dout),
    .ioctl_wait          (k_nv_wait),
    .ioctl_din           (k_nv_q),
    .ioctl_upload_req    (k_nv_request),
    .ioctl_upload_index  (),
    .dirty               (),
    .transfer_error      (),
    .timeout_error       (),
    .SS_DATA             (SS_DATA),
    .SS_ADDR             (SS_ADDR),
    .SS_SELECT           (SS_SELECT),
    .SS_WRITE            (SS_WRITE),
    .SS_READ             (SS_READ),
    .SS_QUERY            (SS_QUERY),
    .SS_DATA_OUT         (ee_ss_data),
    .SS_ACK              (ee_ss_ack)
  );

  rzlate_zrom_owner #(.AW(ZROM_AW)) u_zrom (
    .clk         (clk),
    .reset       (reset),
    .request     ({snd_zrom_req, cpu_zrom_req}),
    .address     ({snd_zrom_addr, cpu_zrom_addr}),
    .park1       (sk_z80_o.held_base),
    .ok          (zrom_ok),
    .data        (zrom_data),
    .rom_request (zrom_rom_request),
    .rom_address (zrom_rom_address),
    .rom_ok      (rom_ok[1]),
    .rom_data    (rom_data[39:32]),
    .idle        (zrom_idle)
  );

  // Integration-violation checks (not synthesized)

`ifndef SYNTHESIS
  // synthesis translate_off
  int unsigned sim_viol_ram_busy;
  int unsigned sim_viol_chunk2;
  int unsigned sim_viol_undo_overlap;
  initial begin
    sim_viol_ram_busy     = 0;
    sim_viol_chunk2       = 0;
    sim_viol_undo_overlap = 0;
  end
  always @(posedge clk) begin
    if (!reset) begin
      if (ram_access_enable && dma_busy) begin
        sim_viol_ram_busy <= sim_viol_ram_busy + 1;
        $error("rzlate_board: host RAM access while text DMA is busy");
      end
      if ((SS_READ || SS_WRITE) && SS_SELECT == 8'd2 && cpu_ram_access && !zrom_idle) begin
        sim_viol_chunk2 <= sim_viol_chunk2 + 1;
        $error("rzlate_board: host chunk-2 Read/Write with RAM access granted before the Z80 ROM owner is idle");
      end
      if (glyph_undo && host_strobe) begin
        sim_viol_undo_overlap <= sim_viol_undo_overlap + 1;
        $error("rzlate_board: private glyph undo overlaps host Read/Write/Query");
      end
    end
  end
  // synthesis translate_on
`endif

endmodule
`default_nettype wire
