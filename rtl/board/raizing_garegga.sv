// SPDX-License-Identifier: GPL-3.0-or-later
// Battle Garegga board: sound mailbox, Z80 ROM and OKI banks, score owner, game bus, main CPU and board top.

// Sound mailbox board profile codes.
`timescale 1ns/1ps
package rzsnd_pkg;
  localparam int RZSND_GAREGGA  = 1;
  localparam int RZSND_SORCER   = 2;   // shared RAM board: mailbox inert
  localparam int RZSND_KINGDOM  = 3;   // shared RAM board: mailbox inert
  localparam int RZSND_BATRIDER = 4;
  localparam int RZSND_BAKRAID  = 5;
  function automatic bit prof_gar(input int p);  prof_gar  = (p == RZSND_GAREGGA);  endfunction
  function automatic bit prof_bat(input int p);  prof_bat  = (p == RZSND_BATRIDER); endfunction
  function automatic bit prof_bak(input int p);  prof_bak  = (p == RZSND_BAKRAID);  endfunction
endpackage

package rzgaregga_mbox_pkg;
    typedef struct packed {
        logic command_write;
        logic [7:0] command_data;
        logic as_idle, clear_ok, restore;
        logic [8:0] state_in;
        logic wait_begin, wait_abandon, wait_active;
    } request_t;
    typedef struct packed {
        logic [8:0] state;
        logic wait_level, wait_grant;
    } response_t;
endpackage

// Sound mailbox: command/reply latches, sound IRQ/NMI, WAIT observer and late-board control bits.

`timescale 1ns/1ps

module rzsnd_mailbox
  import rzsnd_pkg::*;
#(
  parameter int PROFILE = RZSND_GAREGGA
)(
  input  logic        clk,
  input  logic        board_reset,       // whole-board reset: clears every latch (wins over restore)
  input  logic        hold,              // state freeze: no updates, no events
  // ---- main CPU: one event per accepted write
  input  logic        m_cmd0_wr,         // command byte 0 (Garegga 600001, Batrider 500021, Bakraid 500015)
  input  logic        m_cmd1_wr,         // command byte 1 (Batrider 500023, Bakraid 500017)
  input  logic        m_commit,          // Bakraid 50001a..1b commit
  input  logic        m_irq_clear,       // Batrider 500026..27, Bakraid 50001c..1d
  input  logic        m_ctrl_wr,         // Batrider BUSREQ 500061, Bakraid GPIO 50001f
  input  logic [7:0]  m_wdata,           // low byte of the accepted write
  input  logic        m_as_idle,         // Garegga: main AS idle
  input  logic        m_level_clear_ok,  // Garegga: parent permits clearing the command level
  output logic        start_wait,        // comb: this edge accepted a blocking command
  output logic        snd_cmd_line,      // what the sound side samples: Garegga level, late-board strobe
  output logic        main_irq_set,      // comb one-tick event: Z80 I/O write 44 (late boards)
  output logic        main_irq_clear,    // comb one-tick event: main IRQ clear write (late boards)
  output logic        busreq,            // Batrider control bit 0, Bakraid GPIO bit 4
  output logic        eep_clk,           // Bakraid GPIO bit 3
  output logic        eep_di,            // Bakraid GPIO bit 2
  output logic        eep_cs,            // Bakraid GPIO bit 0
  // ---- main CPU: WAIT observer for the parent's blocking cycle
  input  logic        wo_begin,          // a new blocking cycle starts: clear observation history
  input  logic        wo_abandon,        // the cycle was abandoned: clear observation history
  input  logic        wo_active,         // a blocking cycle is in progress
  input  logic        wo_sample,         // an eligible host sampling edge for completion
  output logic        wait_level,        // the mailbox WAIT state seen by the main side
  output logic        wo_seen,           // WAIT has been observed high in this cycle
  output logic        wo_grant,          // comb: completion grant after WAIT seen high then low
  // ---- sound CPU: advance gates and qualified Z80 transactions
  input  logic        snd_advance,       // the sound control state may advance on this edge
  input  logic        z80_live,          // the Z80 may supply a live bus event on this edge
  input  logic        z_wr,              // one event per accepted write
  input  logic        z_rd,              // a read in progress (for the read data only)
  input  logic        z_io,              // 1 = I/O space, 0 = memory
  input  logic        z_iack,            // one event per interrupt acknowledge
  input  logic [15:0] z_addr,
  input  logic [7:0]  z_wdata,
  output logic        snd_irq,           // Garegga sound IRQ pending, late-board NMI pending
  output logic        z_rd_hit,          // comb: the Z80 read address is a mailbox port
  output logic [7:0]  z_rdata,           // comb: command byte for that read
  output logic [7:0]  reply0,            // late boards: reply bytes for the main read ports
  output logic [7:0]  reply1,
  // ---- typed state fields (capture) and staged restore
  output logic [7:0]  f_cmd0,
  output logic [7:0]  f_cmd1,
  output logic        f_cmd_level,
  output logic [7:0]  f_ctrl,            // Batrider full byte; Bakraid bits 4,3,2,0 only
  output logic        f_irq,
  output logic        f_wait,
  output logic        f_hist,            // sound-side command history (sampled command line)
  output logic [7:0]  f_reply0,
  output logic [7:0]  f_reply1,
  input  logic        r_main_load,       // staged restore of the main fields
  input  logic [7:0]  r_cmd0,
  input  logic [7:0]  r_cmd1,
  input  logic        r_cmd_level,
  input  logic [7:0]  r_ctrl,
  input  logic        r_snd_load,        // staged restore of the sound fields
  input  logic        r_irq,
  input  logic        r_wait,
  input  logic        r_hist,
  input  logic [7:0]  r_reply0,
  input  logic [7:0]  r_reply1,
  output logic [3:0]  own_main,          // owned main fields: [0] cmd0 [1] cmd1 [2] cmd_level [3] ctrl
  output logic [4:0]  own_snd,           // owned sound fields: [0] irq [1] wait [2] hist [3] reply0 [4] reply1
  output logic        inert              // Sorcer, Kingdom or unknown profile: no side effects
);
  localparam bit GAR  = prof_gar(PROFILE);
  localparam bit BAT  = prof_bat(PROFILE);
  localparam bit BAK  = prof_bak(PROFILE);
  localparam bit LATE = BAT || BAK;
  localparam bit ACT  = GAR || LATE;
  localparam logic [7:0] CTRL_MASK = BAT ? 8'hFF : BAK ? 8'h1D : 8'h00;   // Bakraid keeps bits 4,3,2,0

  // ---------------------------------------------------------------- state
  logic [7:0] cmd0_q, cmd1_q, ctrl_q, rep0_q, rep1_q;
  logic       lvl_q, irq_q, wait_q, hist_q, seen_q;

  // ---------------------------------------------------------------- main side
  wire m_ok     = ACT && !board_reset && !hold;
  wire blocking = GAR ? m_cmd0_wr :
                  BAT ? ((m_cmd0_wr && m_wdata == 8'h55) || m_cmd1_wr) :
                  BAK ? m_commit : 1'b0;
  assign start_wait   = m_ok && blocking;
  assign snd_cmd_line = GAR ? lvl_q : (LATE && start_wait);    // late boards: strobe on the same edge

  // ---------------------------------------------------------------- sound side
  wire s_ok  = ACT && !board_reset && !hold && snd_advance;
  wire z_ok  = s_ok && z80_live;
  wire io_w  = z_ok && z_wr && z_io;
  wire w40   = io_w && (z_addr[7:0] == 8'h40);
  wire w42   = io_w && (z_addr[7:0] == 8'h42);
  wire w44   = io_w && (z_addr[7:0] == 8'h44);
  wire w46   = io_w && (z_addr[7:0] == 8'h46);
  wire wE00C = z_ok && z_wr && !z_io && (z_addr == 16'hE00C);
  wire ack   = z_ok && z_iack;

  wire new_cmd = snd_cmd_line && !hist_q;                       // rising edge of the sampled command line
  wire clr_irq  = GAR ? ack : BAT ? w46 : BAK ? w46 : 1'b0;
  wire clr_wait = GAR ? wE00C : BAT ? w46 : BAK ? (w40 || w42) : 1'b0;

  always_ff @(posedge clk) begin
    if (board_reset) begin
      cmd0_q <= 8'h00; cmd1_q <= 8'h00; ctrl_q <= 8'h00; lvl_q <= 1'b0;
      irq_q <= 1'b0; wait_q <= 1'b0; hist_q <= 1'b0; rep0_q <= 8'h00; rep1_q <= 8'h00;
      seen_q <= 1'b0;
    end else begin
      // main fields: staged restore has priority over live updates
      if (r_main_load && ACT) begin
        cmd0_q <= r_cmd0;
        if (LATE) cmd1_q <= r_cmd1;
        if (GAR)  lvl_q  <= r_cmd_level;
        ctrl_q <= r_ctrl & CTRL_MASK;
      end else if (m_ok) begin
        if (m_cmd0_wr) cmd0_q <= m_wdata;
        if (m_cmd1_wr && LATE) cmd1_q <= m_wdata;
        if (GAR) begin
          if (m_cmd0_wr) lvl_q <= 1'b1;
          else if (m_as_idle && m_level_clear_ok) lvl_q <= 1'b0;
        end
        if (m_ctrl_wr && LATE) ctrl_q <= m_wdata & CTRL_MASK;
      end
      // sound fields: staged restore has priority over live updates
      if (r_snd_load && ACT) begin
        irq_q <= r_irq; wait_q <= r_wait; hist_q <= r_hist;
        if (LATE) begin rep0_q <= r_reply0; rep1_q <= r_reply1; end
      end else if (s_ok) begin
        irq_q  <= new_cmd || (irq_q && !clr_irq);               // new command has priority over clear
        wait_q <= new_cmd || (wait_q && !clr_wait);
        hist_q <= snd_cmd_line;
        if (LATE && w40) rep0_q <= z_wdata;
        if (LATE && w42) rep1_q <= z_wdata;
      end
      // WAIT observer (in flight, never saved)
      if (wo_begin || wo_abandon) seen_q <= 1'b0;
      else if (ACT && !hold && wo_active && wait_q) seen_q <= 1'b1;
    end
  end

  // ---------------------------------------------------------------- outputs
  assign main_irq_set   = LATE && w44;
  assign main_irq_clear = LATE && m_ok && m_irq_clear;
  assign busreq   = BAT ? ctrl_q[0] : BAK ? ctrl_q[4] : 1'b0;
  assign eep_clk  = BAK && ctrl_q[3];
  assign eep_di   = BAK && ctrl_q[2];
  assign eep_cs   = BAK && ctrl_q[0];

  assign wait_level = wait_q;
  assign wo_seen    = seen_q;
  assign wo_grant   = ACT && !board_reset && !hold && wo_active && wo_sample && seen_q && !wait_q;

  assign snd_irq = irq_q;
  assign z_rd_hit = ACT && z_rd && (GAR ? (!z_io && z_addr == 16'hE01C)
                                        : (z_io && (z_addr[7:0] == 8'h48 || z_addr[7:0] == 8'h4A)));
  assign z_rdata  = !z_rd_hit ? 8'h00 : (GAR || z_addr[7:0] == 8'h48) ? cmd0_q : cmd1_q;
  assign reply0   = rep0_q;
  assign reply1   = rep1_q;

  assign f_cmd0      = cmd0_q;
  assign f_cmd1      = cmd1_q;
  assign f_cmd_level = lvl_q;
  assign f_ctrl      = ctrl_q;
  assign f_irq       = irq_q;
  assign f_wait      = wait_q;
  assign f_hist      = hist_q;
  assign f_reply0    = rep0_q;
  assign f_reply1    = rep1_q;
  assign own_main = {LATE, GAR, LATE, ACT};
  assign own_snd  = {LATE, LATE, ACT, ACT, ACT};
  assign inert    = !ACT;

  wire unused_ok = &{1'b0, z_addr[15:8], m_irq_clear, m_commit, r_cmd1, r_cmd_level, r_reply0, r_reply1,
                     r_ctrl, z_wdata};
endmodule

// Garegga binding of rzsnd_mailbox to packed event and state ports.
`timescale 1ns/1ps
module rzgaregga_mailbox_bridge (
    input clk,reset,
    input m_write,m_as_idle,m_clear_ok,
    input [7:0] m_data,
    input m_restore,
    input [8:0] m_state_in,
    output [8:0] m_state_out,
    input wait_begin,wait_abandon,wait_active,
    output wait_level,wait_seen,wait_grant,start_wait,
    input snd_held,z_write,z_read,z_iack,
    input [15:0] z_address,
    input snd_restore,
    input [3:0] snd_state_in,
    output [3:0] snd_state_out,
    output irq_pending,z_read_hit,
    output [7:0] z_read_data
);
    wire ack_write=z_write && z_address==16'he00c;
    wire wait_capture,history;
    reg ack_seen;
    // One history bit edge-qualifies both the E00C write and the interrupt acknowledge.
    always @(posedge clk) begin
        if(reset) ack_seen<=0;
        else if(snd_restore) ack_seen<=snd_state_in[3];
        else if(!snd_held) ack_seen<=ack_write || z_iack;
    end
    assign snd_state_out={ack_seen,wait_capture,irq_pending,history};

    rzsnd_mailbox #(.PROFILE(rzsnd_pkg::RZSND_GAREGGA)) mailbox (
        .clk(clk),.board_reset(reset),.hold(1'b0),
        .m_cmd0_wr(m_write),.m_cmd1_wr(1'b0),.m_commit(1'b0),.m_irq_clear(1'b0),.m_ctrl_wr(1'b0),
        .m_wdata(m_data),.m_as_idle(m_as_idle),.m_level_clear_ok(m_clear_ok),
        .start_wait(start_wait),.snd_cmd_line(m_state_out[8]),.main_irq_set(),.main_irq_clear(),
        .busreq(),.eep_clk(),.eep_di(),.eep_cs(),
        .wo_begin(wait_begin),.wo_abandon(wait_abandon),.wo_active(wait_active),.wo_sample(1'b1),
        .wait_level(wait_level),.wo_seen(wait_seen),.wo_grant(wait_grant),
        .snd_advance(!snd_held),.z80_live(1'b1),.z_wr(ack_write && !ack_seen),.z_rd(z_read),
        .z_io(1'b0),.z_iack(z_iack && !ack_seen),.z_addr(z_address),.z_wdata(8'd0),
        .snd_irq(irq_pending),.z_rd_hit(z_read_hit),.z_rdata(z_read_data),.reply0(),.reply1(),
        .f_cmd0(m_state_out[7:0]),.f_cmd1(),.f_cmd_level(),.f_ctrl(),.f_irq(),
        .f_wait(wait_capture),.f_hist(history),.f_reply0(),.f_reply1(),
        .r_main_load(m_restore),.r_cmd0(m_state_in[7:0]),.r_cmd1(8'd0),.r_cmd_level(m_state_in[8]),.r_ctrl(8'd0),
        .r_snd_load(snd_restore),.r_irq(snd_state_in[1]),.r_wait(snd_state_in[2]),.r_hist(snd_state_in[0]),
        .r_reply0(8'd0),.r_reply1(8'd0),.own_main(),.own_snd(),.inert());
endmodule

// Z80 ROM bank: 8000-BFFF maps through the bank register (profile 2: E00A write, profile 3: I/O 88).
module rzz80_rom_bank #(
    parameter integer PROFILE = 0
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        hold,
    input  wire        restore,
    input  wire        mem_write,
    input  wire        io_write_event,
    input  wire [15:0] z80_address,
    input  wire [7:0]  write_data,
    input  wire [3:0]  restore_bank,
    output wire [3:0]  bank_state,
    output logic [17:0] rom_address
);
    generate
        if (PROFILE == 2 || PROFILE == 3) begin : active_profile
            localparam integer BANK_BITS = (PROFILE == 2) ? 3 : 4;
            logic [BANK_BITS-1:0] bank;
            wire bank_write = (PROFILE == 2)
                ? mem_write && (z80_address == 16'he00a)
                : io_write_event && (z80_address[7:0] == 8'h88);

            always_ff @(posedge clk) begin
                if (reset)
                    bank <= BANK_BITS'(2);
                else if (restore)
                    bank <= restore_bank[BANK_BITS-1:0];
                else if (!hold && bank_write)
                    bank <= write_data[BANK_BITS-1:0];
            end

            assign bank_state = {{(4-BANK_BITS){1'b0}}, bank};
            always @* begin
                rom_address = (z80_address[15:14] == 2'b10)
                    ? {bank_state, z80_address[13:0]}
                    : {2'b00, z80_address};
            end
        end else begin : inactive_profile
            assign bank_state = 4'b0;
            assign rom_address = 18'b0;
        end
    endgenerate
endmodule

// Garegga OKI banking: four 4-bit entries map the 18-bit chip address to a 20-bit sample ROM address.

`default_nettype none

module rzoki_garegga_bank (
    input  wire        clk,
    input  wire        reset,
    input  wire        hold,
    input  wire        restore,
    input  wire [15:0] restore_state,
    output wire [15:0] capture_state,   // entries 0..3, low to high nibble
    input  wire        write,
    input  wire [7:0]  data,
    input  wire        pair,            // 0: E006 sets entries 0,1; 1: E008 sets entries 2,3
    input  wire [17:0] address,
    output wire [19:0] rom_address
);

    reg [15:0] bank_q;

    always @(posedge clk) begin
        if (reset) begin
            bank_q <= 16'h0000;
        end else if (restore) begin
            bank_q <= restore_state;
        end else if (write && !hold) begin
            if (pair) begin
                bank_q[11:8]  <= data[3:0];
                bank_q[15:12] <= data[7:4];
            end else begin
                bank_q[3:0]   <= data[3:0];
                bank_q[7:4]   <= data[7:4];
            end
        end
    end

    assign capture_state = bank_q;

    // 00000-003ff  table area, four 256-byte subpages     -> entry a[9:8]
    // 00400-3ffff  four 64 KiB sample windows             -> entry a[17:16]

    function [1:0] page_entry;
        input [17:0] a;
        begin
            if (a[17:10] == 8'h00)
                page_entry = a[9:8];
            else
                page_entry = a[17:16];
        end
    endfunction

    wire [1:0] entry = page_entry(address);
    wire [3:0] bank  = bank_q[{entry, 2'b00} +: 4];

    assign rom_address = {bank, address[15:0]};

endmodule

`default_nettype wire

// Garegga sound: Z80, YM2151, OKI M6295, mailbox, ROM banks and mixer.
module rzgaregga_sound (
    output raizing_socket_pkg::oki_in_t sk_oki_i,
    input raizing_socket_pkg::oki_out_t sk_oki_o,

    output raizing_socket_pkg::fm_in_t sk_fm_i,
    input raizing_socket_pkg::fm_out_t sk_fm_o,

    output raizing_socket_pkg::z80_in_t sk_z80_i,
    input raizing_socket_pkg::z80_out_t sk_z80_o,

    input logic clk, reset, z80_ce, ym_ce, ym_phase1_ce, oki_ce,
    input rzgaregga_mbox_pkg::request_t mailbox_request,
    output rzgaregga_mbox_pkg::response_t mailbox_reply,
    output logic sound_wait,
    input logic hold_request, canonical_hold, restore_commit,
    output logic held, replay_busy, restore_busy, canonical_ready,
    output logic canonical_fault, canonical_service,
    output logic [16:0] rom_address,
    output logic rom_request,
    input logic [7:0] rom_data,
    input logic rom_ok,
    output logic [12:0] shared_address,
    output logic [7:0] shared_data_out,
    output logic shared_write,
    input logic [7:0] shared_data_in,
    output logic [19:0] pcm_address,
    output logic pcm_request, pcm_frozen, pcm_resume_busy,
    input logic [7:0] pcm_data,
    input logic pcm_ok,
    output logic signed [15:0] audio,
    output logic sample,
    input logic [1:0] fx_level,
    input logic fm_enable, pcm_enable,
    input logic [63:0] SS_DATA,
    input logic [31:0] SS_ADDR,
    input logic [7:0] SS_SELECT,
    input logic SS_WRITE, SS_READ, SS_QUERY,
    output logic [63:0] SS_DATA_OUT,
    output logic SS_ACK
);
    logic [15:0] z_address;
    logic [7:0] z_din, z_dout, fm_status, oki_status, mbox_data;
    logic rd_n, wr_n, mreq_n, iorq_n, m1_n;
    logic mem_read, mem_write, iack, shared_region, fm_select, oki_select;
    logic cpu_held, cpu_ready, cpu_fault, fm_fault, mbox_irq, mbox_hit;
    logic [17:0] program_address, sample_address;
    logic [3:0] program_bank, mbox_state;
    logic [15:0] sample_banks;
    logic [255:0] cpu_capture, cpu_restore;
    logic [63:0] control_capture, control_restore;
    logic cpu_ack, fm_ack, oki_ack, control_ack;
    logic [63:0] cpu_word, fm_word, oki_word, control_word;
    logic auto_rd, auto_wr, auto_ack;
    logic [31:0] auto_din, auto_dout;
    logic [7:0] auto_device;
    logic [15:0] auto_index;
    logic signed [15:0] fm_left, fm_right;
    logic signed [13:0] pcm_sound;

    assign mem_read = !mreq_n && !rd_n;
    assign mem_write = !mreq_n && !wr_n;
    assign iack = !iorq_n && !m1_n;
    assign shared_region = z_address[15:13] == 3'b110;
    assign fm_select = z_address[15:1] == 15'h7000;
    assign oki_select = z_address == 16'he004;

    assign rom_request = mem_read && z_address < 16'hc000;
    assign rom_address = program_address[16:0];
    assign shared_address = z_address[12:0];
    assign shared_data_out = z_dout;
    assign shared_write = mem_write && shared_region && !cpu_held;

    always_comb begin
        z_din = 8'hff;
        if (rom_request) z_din = rom_data;
        else if (mem_read) begin
            if (shared_region) z_din = shared_data_in;
            else if (z_address == 16'he001) z_din = fm_status;
            else if (oki_select) z_din = oki_status;
            else if (mbox_hit) z_din = mbox_data;
            else if (z_address == 16'he01d) z_din = 8'h00;
        end
    end

    assign held = cpu_held && pcm_frozen && !replay_busy && !restore_busy;

    logic pcm_freeze_seen;
    always_ff @(posedge clk) begin
        if (reset) pcm_freeze_seen <= 1'b0;
        else pcm_freeze_seen <= cpu_held;
    end
    assign canonical_ready = cpu_ready && pcm_freeze_seen && !replay_busy && !restore_busy;
    assign canonical_fault = cpu_fault || fm_fault;
    assign sound_wait = mailbox_reply.wait_level;

    // raizing_z80 pins via socket sk_z80.
    assign sk_z80_i.nmi_n = 1'b1;     // no NMI or bus request on this board
    assign sk_z80_i.busrq_n = 1'b1;
    assign sk_z80_i.clk = clk;
    assign sk_z80_i.reset = reset;
    assign sk_z80_i.cen = z80_ce && (!pcm_resume_busy || restore_busy);
    assign sk_z80_i.wait_n = !rom_request || rom_ok;
    assign sk_z80_i.int_n = !mbox_irq;
    assign sk_z80_i.hold_request = hold_request || replay_busy;
    assign sk_z80_i.canonical_hold = canonical_hold;
    assign sk_z80_i.restore = restore_commit;
    assign sk_z80_i.restore_state = cpu_restore;
    assign sk_z80_i.data_in = z_din;
    assign cpu_held = sk_z80_o.held;
    assign cpu_ready = sk_z80_o.canonical_ready;
    assign canonical_service = sk_z80_o.canonical_service;
    assign restore_busy = sk_z80_o.restore_busy;
    assign cpu_fault = sk_z80_o.canonical_fault;
    assign cpu_capture = sk_z80_o.capture_state;
    assign z_address = sk_z80_o.address;
    assign z_dout = sk_z80_o.data_out;
    assign rd_n = sk_z80_o.rd_n;
    assign wr_n = sk_z80_o.wr_n;
    assign mreq_n = sk_z80_o.mreq_n;
    assign iorq_n = sk_z80_o.iorq_n;
    assign m1_n = sk_z80_o.m1_n;

    rzz80_rom_bank #(.PROFILE(2)) program_banks (
        .clk(clk), .reset(reset), .hold(cpu_held), .restore(restore_commit),
        .mem_write(mem_write), .io_write_event(1'b0), .z80_address(z_address),
        .write_data(z_dout), .restore_bank({1'b0, control_restore[2:0]}),
        .bank_state(program_bank), .rom_address(program_address)
    );

    rzgaregga_mailbox_bridge mbox (
        .clk(clk), .reset(reset), .m_write(mailbox_request.command_write),
        .m_as_idle(mailbox_request.as_idle), .m_clear_ok(mailbox_request.clear_ok),
        .m_data(mailbox_request.command_data), .m_restore(mailbox_request.restore),
        .m_state_in(mailbox_request.state_in), .m_state_out(mailbox_reply.state),
        .wait_begin(mailbox_request.wait_begin), .wait_abandon(mailbox_request.wait_abandon),
        .wait_active(mailbox_request.wait_active), .wait_level(mailbox_reply.wait_level),
        .wait_seen(), .wait_grant(mailbox_reply.wait_grant), .start_wait(),
        .snd_held(cpu_held), .z_write(mem_write), .z_read(mem_read), .z_iack(iack),
        .z_address(z_address), .snd_restore(restore_commit),
        .snd_state_in(control_restore[22:19]), .snd_state_out(mbox_state),
        .irq_pending(mbox_irq), .z_read_hit(mbox_hit), .z_read_data(mbox_data)
    );

    // rzopm_state_owner (YM2151) pins via socket sk_fm.
    assign sk_fm_i.clk = clk;
    assign sk_fm_i.reset = reset;
    assign sk_fm_i.ym_ce = ym_ce;
    assign sk_fm_i.cpu_held = cpu_held;
    assign sk_fm_i.pcm_refill = pcm_resume_busy;
    assign sk_fm_i.canonical_hold = canonical_hold;
    assign sk_fm_i.cpu_canonical_ready = cpu_ready;
    assign sk_fm_i.restore_commit = restore_commit;
    assign sk_fm_i.cs_n = !(fm_select && !mreq_n && !cpu_held);
    assign sk_fm_i.wr_n = wr_n || cpu_held;
    assign sk_fm_i.a0 = z_address[0];
    assign sk_fm_i.din = z_dout;
    assign sk_fm_i.ss_data = SS_DATA;
    assign sk_fm_i.ss_addr = SS_ADDR;
    assign sk_fm_i.ss_select = SS_SELECT;
    assign sk_fm_i.ss_write = SS_WRITE;
    assign sk_fm_i.ss_read = SS_READ;
    assign sk_fm_i.ss_query = SS_QUERY;
    assign fm_status = sk_fm_o.dout;
    assign fm_left = sk_fm_o.xleft;
    assign fm_right = sk_fm_o.xright;
    assign replay_busy = sk_fm_o.busy;
    assign fm_fault = sk_fm_o.fault;
    assign fm_word = sk_fm_o.ss_data_out;
    assign fm_ack = sk_fm_o.ss_ack;

    // ss_jt6295 (OKI M6295) pins via socket sk_oki.
    assign sk_oki_i.rst = reset;
    assign sk_oki_i.filter_rst = restore_commit;
    assign sk_oki_i.clk = clk;
    assign sk_oki_i.state_freeze = cpu_held;
    assign sk_oki_i.cen = oki_ce && !cpu_held;
    assign sk_oki_i.ss = 1'b1;
    assign sk_oki_i.wrn = !(mem_write && oki_select && !cpu_held);
    assign sk_oki_i.din = z_dout;
    assign sk_oki_i.rom_data = pcm_data;
    assign sk_oki_i.rom_ok = pcm_ok;
    assign sk_oki_i.auto_ss_rd = auto_rd;
    assign sk_oki_i.auto_ss_wr = auto_wr;
    assign sk_oki_i.auto_ss_data_in = auto_din;
    assign sk_oki_i.auto_ss_device_idx = auto_device;
    assign sk_oki_i.auto_ss_state_idx = auto_index;
    assign sk_oki_i.auto_ss_base_device_idx = 8'd0;
    assign pcm_frozen = sk_oki_o.state_frozen;
    assign pcm_request = sk_oki_o.rom_request;
    assign pcm_resume_busy = sk_oki_o.resume_busy;
    assign oki_status = sk_oki_o.dout;
    assign sample_address = sk_oki_o.rom_addr;
    assign pcm_sound = sk_oki_o.sound;
    assign sample = sk_oki_o.sample;
    assign auto_dout = sk_oki_o.auto_ss_data_out;
    assign auto_ack = sk_oki_o.auto_ss_ack;

    rzoki_garegga_bank sample_banks_owner (
        .clk(clk), .reset(reset), .hold(cpu_held), .restore(restore_commit),
        .restore_state(control_restore[18:3]), .capture_state(sample_banks),
        .write(mem_write && (z_address == 16'he006 || z_address == 16'he008)),
        .data(z_dout), .pair(z_address[3]), .address(sample_address), .rom_address(pcm_address)
    );

    raizing_ss_wide_register #(.WIDTH(256), .SS_INDEX(15)) cpu_context (
        .clk(clk), .reset(reset), .capture_data(cpu_capture), .restore_data(cpu_restore), .restore_we(),
        .ss_data(SS_DATA), .ss_addr(SS_ADDR), .ss_select(SS_SELECT),
        .ss_write(SS_WRITE), .ss_read(SS_READ), .ss_query(SS_QUERY),
        .ss_data_out(cpu_word), .ss_ack(cpu_ack)
    );

    assign control_capture = {41'b0, mbox_state, sample_banks, program_bank[2:0]};
    raizing_ss_wide_register #(.WIDTH(64), .SS_INDEX(17)) control_context (
        .clk(clk), .reset(reset), .capture_data(control_capture), .restore_data(control_restore), .restore_we(),
        .ss_data(SS_DATA), .ss_addr(SS_ADDR), .ss_select(SS_SELECT),
        .ss_write(SS_WRITE), .ss_read(SS_READ), .ss_query(SS_QUERY),
        .ss_data_out(control_word), .ss_ack(control_ack)
    );

    raizing_ss_auto32 #(.SS_INDEX(18), .DEVICE_COUNT(11), .STATE_STRIDE(64)) oki_context (
        .clk(clk), .reset(reset), .ss_data(SS_DATA), .ss_addr(SS_ADDR), .ss_select(SS_SELECT),
        .ss_write(SS_WRITE), .ss_read(SS_READ), .ss_query(SS_QUERY),
        .ss_data_out(oki_word), .ss_ack(oki_ack),
        .auto_ss_rd(auto_rd), .auto_ss_wr(auto_wr), .auto_ss_data_in(auto_din),
        .auto_ss_device_idx(auto_device), .auto_ss_state_idx(auto_index),
        .auto_ss_data_out(auto_dout), .auto_ss_ack(auto_ack)
    );

    assign SS_ACK = cpu_ack || control_ack || oki_ack || fm_ack;
    assign SS_DATA_OUT = (cpu_ack ? cpu_word : 64'b0) |
                         (control_ack ? control_word : 64'b0) |
                         (oki_ack ? oki_word : 64'b0) |
                         (fm_ack ? fm_word : 64'b0);

    logic signed [16:0] fm_sum;
    logic signed [7:0] pcm_gain;
    logic signed [19:0] fm_product;
    logic signed [22:0] pcm_product;
    logic signed [23:0] mixed_sum, scaled;
    logic signed [15:0] mixed_audio;

    always_comb begin
        case (fx_level)
            2'd0: pcm_gain = 8'sd20;
            2'd1: pcm_gain = 8'sd29;
            2'd2: pcm_gain = 8'sd40;
            default: pcm_gain = 8'sd78;
        endcase
    end

    // Arithmetic shifts floor negative odd values.
    assign fm_sum = $signed({fm_left[15], fm_left}) + $signed({fm_right[15], fm_right});
    assign mixed_sum = $signed({{4{fm_product[19]}}, fm_product}) +
                       $signed({pcm_product[22], pcm_product});
    assign scaled = mixed_sum >>> 4;

    always_ff @(posedge clk) begin
        if (reset) begin
            fm_product <= '0;
            pcm_product <= '0;
            mixed_audio <= '0;
        end else begin
            fm_product <= fm_enable ? (fm_sum >>> 1) * 20'sd10 : 20'sd0;
            pcm_product <= pcm_enable ? (pcm_sound * pcm_gain) <<< 2 : 23'sd0;
            if (scaled > 24'sd32767) mixed_audio <= 16'sh7fff;
            else if (scaled < -24'sd32768) mixed_audio <= 16'sh8000;
            else mixed_audio <= scaled[15:0];
        end
    end

    assign audio = (hold_request || canonical_hold || replay_busy || pcm_resume_busy) ? 16'sd0 : mixed_audio;
endmodule

// High-score owner: ROM identity epoch, score witness, NV file staging, table install and capture.
module rzscore_late #(
    parameter integer PROFILE = -1,
    parameter bit STABLE_ROM_EPOCH = 0
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
        wire cold = (G || !seen_rom) && !rom_valid && !reset;
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
        wire complete = is_complete(prior_cursor);

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
        assign init_cursor = prior_cursor;
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
                        if (!match_tuple[i])
                            next_cursor[10*i +: 10] = restart ? 10'd1 : 10'd0;
                        else if ({27'd0, prior_cursor[10*i +: 5]} == 21+i)
                            next_cursor[10*i +: 10] = {prior_cursor[10*i+5 +: 5] + 5'd1, 5'd0};
                        else
                            next_cursor[10*i +: 5] = prior_cursor[10*i +: 5] + 5'd1;
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
        reg ul_table, ul_file;
        reg ul_bank, reads_bad;
        reg [10:0] reads;
        reg snapshot, stale;

        // A pending-file upload pins its staging bank until HPS closes it.
        wire rx_begin = !reset && dl_start && (usable || cold) &&
                        (!same || op != INSTALL) && !restore;
        wire rx_current = rx_begin || (!dl_start && !retire_epoch && rx_live && rx_ok && !restore);
        wire rx_target = dl_start ? ((same && ul_live && ul_file) ?
                                    !ul_bank : !pending_bank) : rx_bank;
        wire [9:0] rx_index = dl_start ? 10'd0 : rx_count;
        wire rx_byte = !reset && nv_download && nv_write && rx_current &&
                       rx_index < BYTES && nv_addr == {17'd0, rx_index};
        wire ul_open = same && nv_upload && (ul_live || ul_start);
        wire ul_select = ul_open && !ul_table && !ul_file && !ul_retired && !restore;
        wire take_snapshot = ul_select && snapshot;
        // The pending file is readable while CPU reset keeps the live table not ready.

        wire take_file = ul_select && !snapshot && op != CAPTURE && pending && !dl_start &&
                         (!G || !valid_q || (cpu_reset && !ready_q));
        wire table_readback = ul_open && (ul_table || take_snapshot);
        wire file_readback = ul_open && (ul_file || take_file);
        wire have_readback = table_readback || file_readback;
        wire [1:0] ul_src = {ul_table, ul_file};
        wire [1:0] source = {table_readback, file_readback};
        wire capture_abort = op == CAPTURE && capture_host && !nv_upload;
        wire port_granted = same && !cpu_reset && !state_active && hold_q && hold_ack &&
                            (G || grant_q);
        wire copy_install = port_granted && op == INSTALL && !file_readback;
        wire copy_capture = port_granted && op == CAPTURE && !capture_abort;
        wire install_done = copy_install && primed && {1'b0, copy_index} == WORDS-1'b1;
        wire capture_word_ready;
        wire capture_commit = copy_capture && primed && capture_word_ready;
        wire capture_retry = copy_capture && primed && !capture_word_ready;
        wire capture_done = capture_commit && {1'b0, copy_index} == WORDS-1'b1;

        // Garegga: STABLE_ROM_EPOCH holds on rom_valid instead of the ROM identity match.
        assign hold_request = hold_q && (!G || (STABLE_ROM_EPOCH ? rom_valid && !reset : same));
        assign nv_wait = ul_open && (!have_readback || (G && nv_payload && !host_data_valid));
        assign active = same && (rx_live || pending || op != IDLE ||
                        snapshot || ul_open || save_pending);
        assign upload_request = same && notification;

        wire cpu_port = ready && !hold_ack && {1'b0, cpu_addr} < WORDS;
        wire cpu_accept = cpu_port && cpu_we != 0;
        wire state_port = same && state_active && state_word_own &&
                          (!G || !state_word_addr[8:7]);
        wire init_store = normal_event && (!same || !valid_q) && (normal_lanes & normal_we) != 0;
        wire [AW:0] stage_write_addr = {rx_target, rx_index[AW:1]};
        wire nv_in_range = nv_addr < {17'd0, BYTES};
        wire nv_payload = have_readback && nv_in_range;

        // Each byte lane has one write port and one synchronous read port.
        reg [7:0] stage_hi [0:2*DEPTH-1], stage_lo [0:2*DEPTH-1];
        reg [15:0] stage_q;
        wire [15:0] image_q;
        reg host_q_table, host_q_file;
        reg host_q_low;
        reg [AW:0] host_q_addr;
        wire host_data_valid = ((host_q_table && table_readback) || (host_q_file && file_readback)) &&
                               host_q_addr == nv_addr[AW:0];
        wire host_stage_read = file_readback && nv_in_range;
        wire [AW:0] stage_read_addr = host_stage_read ?
            {take_file ? pending_bank : ul_bank, nv_addr[AW:1]} : {pending_bank, copy_index};
        always @(posedge clk) begin
            if (rx_byte && !nv_addr[0]) stage_hi[stage_write_addr] <= nv_data;
            if (rx_byte &&  nv_addr[0]) stage_lo[stage_write_addr] <= nv_data;
            if (host_stage_read || (copy_install && !primed))
                stage_q <= {stage_hi[stage_read_addr], stage_lo[stage_read_addr]};
            host_q_addr <= nv_addr[AW:0];
            host_q_table <= table_readback && nv_in_range;
            host_q_file <= host_stage_read;
            host_q_low <= nv_addr[0];
        end
        wire [15:0] host_word = host_q_file ? stage_q : image_q;
        assign nv_q = !ul_open || !(host_q_table || host_q_file) || (G && (!nv_payload || !host_data_valid)) ? 8'd0 :
                      host_q_low ? host_word[7:0] : host_word[15:8];

        // Two table banks: install fills the inactive bank; state words at or above WORDS use bank 0.
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
        wire [15:0] capture_word = table_q;
        if (G) begin : checked_image
            reg [AW:0] capture_address;
            reg [15:0] words [0:DEPTH-1];
            reg [15:0] host_data;
            always @(posedge clk) begin
                if (table_owner == COPY_PORT) capture_address <= table_addr;
                if (capture_commit) words[copy_index] <= capture_word;
                host_data <= words[nv_addr[AW:1]];
            end
            assign image_q = host_data;
            // Only a copy-port read of the current address commits to the host image.
            assign capture_word_ready = read_owner == COPY_PORT &&
                                        capture_address == {live_bank, copy_index};
        end else begin : late_image
            reg [7:0] image_hi [0:DEPTH-1], image_lo [0:DEPTH-1];
            reg [15:0] host_data;
            always @(posedge clk) begin
                if (capture_commit) begin
                    image_hi[copy_index] <= capture_word[15:8];
                    image_lo[copy_index] <= capture_word[7:0];
                end
                if (table_readback && nv_in_range)
                    host_data <= {image_hi[nv_addr[AW:1]], image_lo[nv_addr[AW:1]]};
            end
            assign image_q = host_data;
            assign capture_word_ready = 1'b1;
        end
        always @(posedge clk) begin
            if (table_we[1]) table_hi[table_addr] <= table_d[15:8];
            if (table_we[0]) table_lo[table_addr] <= table_d[7:0];
            if (table_owner != 0)
                table_q <= {table_hi[table_addr], table_lo[table_addr]};
            read_owner <= table_owner;
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
                {ul_live, ul_retired, ul_table, ul_file, ul_bank, reads_bad, reads} <= '0;
                {op, hold_q, grant_q, primed, copy_index, capture_host,
                 snapshot, stale, save_pending} <= '0;
            end else begin
                known <= usable;
                // Garegga: seen_rom follows rom_valid, accepting a cold file each ROM load.
                if (G) seen_rom <= rom_valid;
                else if (rom_valid) seen_rom <= 1;
                if (usable) begin
                    crc_q <= rom_crc;
                    length_q <= rom_length;
                end
                if (!same) begin
                    cursor <= next_cursor;
                    {ready_q, valid_q, dirty_q, live_bank, publish_due} <= '0;
                    {ul_live, ul_retired, ul_table, ul_file, ul_bank, reads_bad, reads} <= '0;
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
                        ul_table <= take_snapshot;
                        ul_file <= take_file;
                        ul_bank <= pending_bank;
                    end
                    if (ul_open && nv_read) begin
                        // Address 0 may be read before readback is ready (hps_io prefetch).
                        if (reads <= {1'b0, BYTES} && nv_addr == {16'd0, reads} &&
                            (have_readback || reads == 0))
                            reads <= reads + 11'd1;
                        else reads_bad <= 1;
                    end
                    if (ul_live && !nv_upload) begin
                        ul_live <= 0;
                        ul_table <= 0;
                        ul_file <= 0;
                        reads <= 0;
                        reads_bad <= 0;
                        if (ul_table) begin
                            snapshot <= 0;
                            if (reads == {1'b0, BYTES} + 11'd1 && !reads_bad &&
                                !stale && !cpu_accept) dirty_q <= 0;
                        end
                    end
                    if (cpu_accept) begin
                        dirty_q <= 1;
                        if (snapshot || ul_table) stale <= 1;
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
                        !snapshot && op != CAPTURE && !ul_table && !ul_file)
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
                        if (!(copy_install || copy_capture) || capture_retry) begin
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
                                // An open upload binds to the published table.
                                if (ul_open) begin
                                    ul_table <= 1;
                                    ul_file <= 0;
                                end
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

// Garegga high-score profiles by program ROM CRC, with two base-relative 150-write init schedules.
module rzgaregga_highscore_profile (
    input [31:0] rom_crc,rom_length,
    input [7:0] progress,
    output reg supported,location,
    output reg [3:0] profile,
    output reg [15:0] score_base,expected_addr,expected_data,
    output reg [1:0] expected_we
);
    reg [7:0] offset;
    always @* begin
        supported=0;location=0;profile=0;score_base=16'hca4c;
        if(rom_length==32'ha28000) case(rom_crc)
            32'hc31f6b26: begin supported=1;profile=4'd1;score_base=16'hca4c;location=1'b0;end // bgaregga
            32'hd7164121: begin supported=1;profile=4'd2;score_base=16'hca4c;location=1'b0;end // bgareggahk
            32'he2f509a3: begin supported=1;profile=4'd3;score_base=16'hca4c;location=1'b0;end // bgareggatw
            32'h8eb5138d: begin supported=1;profile=4'd4;score_base=16'hca4c;location=1'b0;end // bgareggz
            32'h4e72849c: begin supported=1;profile=4'd5;score_base=16'hca4c;location=1'b1;end // bgareggat
            32'hbc7c9b7c: begin supported=1;profile=4'd6;score_base=16'hca4e;location=1'b0;end // bgareggak
            32'hd45dac59: begin supported=1;profile=4'd7;score_base=16'hca4e;location=1'b0;end // bgaregganv
            32'h764fea7a: begin supported=1;profile=4'd8;score_base=16'hca4e;location=1'b0;end // bgareggat2
            32'h72982e40: begin supported=1;profile=4'd9;score_base=16'hca4e;location=1'b0;end // bgareggacn
            default: begin end
        endcase
        offset=0;expected_data=0;expected_we=0;
        case(progress)
            8'd0: begin offset=8'd0;expected_data=location ? 16'h0001 : 16'h000f;expected_we=2'd3;end
            8'd1: begin offset=8'd2;expected_data=location ? 16'h86a0 : 16'h4240;expected_we=2'd3;end
            8'd2: begin offset=8'd18;expected_data=16'h2a00;expected_we=2'd3;end
            8'd3: begin offset=8'd12;expected_data=16'h2a2a;expected_we=2'd3;end
            8'd4: begin offset=8'd14;expected_data=16'h2a00;expected_we=2'd3;end
            8'd5: begin offset=8'd4;expected_data=location ? 16'h2000 : 16'h3100;expected_we=2'd2;end
            8'd6: begin offset=8'd4;expected_data=location ? 16'h0031 : 16'h0030;expected_we=2'd1;end
            8'd7: begin offset=8'd6;expected_data=16'h3000;expected_we=2'd2;end
            8'd8: begin offset=8'd6;expected_data=16'h0030;expected_we=2'd1;end
            8'd9: begin offset=8'd8;expected_data=16'h3000;expected_we=2'd2;end
            8'd10: begin offset=8'd8;expected_data=16'h0030;expected_we=2'd1;end
            8'd11: begin offset=8'd10;expected_data=16'h3000;expected_we=2'd2;end
            8'd12: begin offset=8'd10;expected_data=16'h0000;expected_we=2'd1;end
            8'd13: begin offset=8'd20;expected_data=16'h0000;expected_we=2'd1;end
            8'd14: begin offset=8'd22;expected_data=16'h0002;expected_we=2'd1;end
            8'd15: begin offset=8'd24;expected_data=location ? 16'h0001 : 16'h000d;expected_we=2'd3;end
            8'd16: begin offset=8'd26;expected_data=location ? 16'h5f90 : 16'hbba0;expected_we=2'd3;end
            8'd17: begin offset=8'd42;expected_data=16'h2a00;expected_we=2'd3;end
            8'd18: begin offset=8'd36;expected_data=16'h2a2a;expected_we=2'd3;end
            8'd19: begin offset=8'd38;expected_data=16'h2a00;expected_we=2'd3;end
            8'd20: begin offset=8'd28;expected_data=16'h2000;expected_we=2'd2;end
            8'd21: begin offset=8'd28;expected_data=location ? 16'h0020 : 16'h0039;expected_we=2'd1;end
            8'd22: begin offset=8'd30;expected_data=location ? 16'h3900 : 16'h3000;expected_we=2'd2;end
            8'd23: begin offset=8'd30;expected_data=16'h0030;expected_we=2'd1;end
            8'd24: begin offset=8'd32;expected_data=16'h3000;expected_we=2'd2;end
            8'd25: begin offset=8'd32;expected_data=16'h0030;expected_we=2'd1;end
            8'd26: begin offset=8'd34;expected_data=16'h3000;expected_we=2'd2;end
            8'd27: begin offset=8'd34;expected_data=16'h0000;expected_we=2'd1;end
            8'd28: begin offset=8'd44;expected_data=16'h0000;expected_we=2'd1;end
            8'd29: begin offset=8'd46;expected_data=16'h0002;expected_we=2'd1;end
            8'd30: begin offset=8'd48;expected_data=location ? 16'h0001 : 16'h000c;expected_we=2'd3;end
            8'd31: begin offset=8'd50;expected_data=location ? 16'h3880 : 16'h3500;expected_we=2'd3;end
            8'd32: begin offset=8'd66;expected_data=16'h2a00;expected_we=2'd3;end
            8'd33: begin offset=8'd60;expected_data=16'h2a2a;expected_we=2'd3;end
            8'd34: begin offset=8'd62;expected_data=16'h2a00;expected_we=2'd3;end
            8'd35: begin offset=8'd52;expected_data=16'h2000;expected_we=2'd2;end
            8'd36: begin offset=8'd52;expected_data=location ? 16'h0020 : 16'h0038;expected_we=2'd1;end
            8'd37: begin offset=8'd54;expected_data=location ? 16'h3800 : 16'h3000;expected_we=2'd2;end
            8'd38: begin offset=8'd54;expected_data=16'h0030;expected_we=2'd1;end
            8'd39: begin offset=8'd56;expected_data=16'h3000;expected_we=2'd2;end
            8'd40: begin offset=8'd56;expected_data=16'h0030;expected_we=2'd1;end
            8'd41: begin offset=8'd58;expected_data=16'h3000;expected_we=2'd2;end
            8'd42: begin offset=8'd58;expected_data=16'h0000;expected_we=2'd1;end
            8'd43: begin offset=8'd68;expected_data=16'h0000;expected_we=2'd1;end
            8'd44: begin offset=8'd70;expected_data=16'h0002;expected_we=2'd1;end
            8'd45: begin offset=8'd72;expected_data=location ? 16'h0001 : 16'h000a;expected_we=2'd3;end
            8'd46: begin offset=8'd74;expected_data=location ? 16'h1170 : 16'hae60;expected_we=2'd3;end
            8'd47: begin offset=8'd90;expected_data=16'h2a00;expected_we=2'd3;end
            8'd48: begin offset=8'd84;expected_data=16'h2a2a;expected_we=2'd3;end
            8'd49: begin offset=8'd86;expected_data=16'h2a00;expected_we=2'd3;end
            8'd50: begin offset=8'd76;expected_data=16'h2000;expected_we=2'd2;end
            8'd51: begin offset=8'd76;expected_data=location ? 16'h0020 : 16'h0037;expected_we=2'd1;end
            8'd52: begin offset=8'd78;expected_data=location ? 16'h3700 : 16'h3000;expected_we=2'd2;end
            8'd53: begin offset=8'd78;expected_data=16'h0030;expected_we=2'd1;end
            8'd54: begin offset=8'd80;expected_data=16'h3000;expected_we=2'd2;end
            8'd55: begin offset=8'd80;expected_data=16'h0030;expected_we=2'd1;end
            8'd56: begin offset=8'd82;expected_data=16'h3000;expected_we=2'd2;end
            8'd57: begin offset=8'd82;expected_data=16'h0000;expected_we=2'd1;end
            8'd58: begin offset=8'd92;expected_data=16'h0000;expected_we=2'd1;end
            8'd59: begin offset=8'd94;expected_data=16'h0002;expected_we=2'd1;end
            8'd60: begin offset=8'd96;expected_data=location ? 16'h0000 : 16'h0009;expected_we=2'd3;end
            8'd61: begin offset=8'd98;expected_data=location ? 16'hea60 : 16'h27c0;expected_we=2'd3;end
            8'd62: begin offset=8'd114;expected_data=16'h2a00;expected_we=2'd3;end
            8'd63: begin offset=8'd108;expected_data=16'h2a2a;expected_we=2'd3;end
            8'd64: begin offset=8'd110;expected_data=16'h2a00;expected_we=2'd3;end
            8'd65: begin offset=8'd100;expected_data=16'h2000;expected_we=2'd2;end
            8'd66: begin offset=8'd100;expected_data=location ? 16'h0020 : 16'h0036;expected_we=2'd1;end
            8'd67: begin offset=8'd102;expected_data=location ? 16'h3600 : 16'h3000;expected_we=2'd2;end
            8'd68: begin offset=8'd102;expected_data=16'h0030;expected_we=2'd1;end
            8'd69: begin offset=8'd104;expected_data=16'h3000;expected_we=2'd2;end
            8'd70: begin offset=8'd104;expected_data=16'h0030;expected_we=2'd1;end
            8'd71: begin offset=8'd106;expected_data=16'h3000;expected_we=2'd2;end
            8'd72: begin offset=8'd106;expected_data=16'h0000;expected_we=2'd1;end
            8'd73: begin offset=8'd116;expected_data=16'h0000;expected_we=2'd1;end
            8'd74: begin offset=8'd118;expected_data=16'h0002;expected_we=2'd1;end
            8'd75: begin offset=8'd120;expected_data=location ? 16'h0000 : 16'h0007;expected_we=2'd3;end
            8'd76: begin offset=8'd122;expected_data=location ? 16'hc350 : 16'ha120;expected_we=2'd3;end
            8'd77: begin offset=8'd138;expected_data=16'h2a00;expected_we=2'd3;end
            8'd78: begin offset=8'd132;expected_data=16'h2a2a;expected_we=2'd3;end
            8'd79: begin offset=8'd134;expected_data=16'h2a00;expected_we=2'd3;end
            8'd80: begin offset=8'd124;expected_data=16'h2000;expected_we=2'd2;end
            8'd81: begin offset=8'd124;expected_data=location ? 16'h0020 : 16'h0035;expected_we=2'd1;end
            8'd82: begin offset=8'd126;expected_data=location ? 16'h3500 : 16'h3000;expected_we=2'd2;end
            8'd83: begin offset=8'd126;expected_data=16'h0030;expected_we=2'd1;end
            8'd84: begin offset=8'd128;expected_data=16'h3000;expected_we=2'd2;end
            8'd85: begin offset=8'd128;expected_data=16'h0030;expected_we=2'd1;end
            8'd86: begin offset=8'd130;expected_data=16'h3000;expected_we=2'd2;end
            8'd87: begin offset=8'd130;expected_data=16'h0000;expected_we=2'd1;end
            8'd88: begin offset=8'd140;expected_data=16'h0000;expected_we=2'd1;end
            8'd89: begin offset=8'd142;expected_data=16'h0002;expected_we=2'd1;end
            8'd90: begin offset=8'd144;expected_data=location ? 16'h0000 : 16'h0006;expected_we=2'd3;end
            8'd91: begin offset=8'd146;expected_data=location ? 16'h9c40 : 16'h1a80;expected_we=2'd3;end
            8'd92: begin offset=8'd162;expected_data=16'h2a00;expected_we=2'd3;end
            8'd93: begin offset=8'd156;expected_data=16'h2a2a;expected_we=2'd3;end
            8'd94: begin offset=8'd158;expected_data=16'h2a00;expected_we=2'd3;end
            8'd95: begin offset=8'd148;expected_data=16'h2000;expected_we=2'd2;end
            8'd96: begin offset=8'd148;expected_data=location ? 16'h0020 : 16'h0034;expected_we=2'd1;end
            8'd97: begin offset=8'd150;expected_data=location ? 16'h3400 : 16'h3000;expected_we=2'd2;end
            8'd98: begin offset=8'd150;expected_data=16'h0030;expected_we=2'd1;end
            8'd99: begin offset=8'd152;expected_data=16'h3000;expected_we=2'd2;end
            8'd100: begin offset=8'd152;expected_data=16'h0030;expected_we=2'd1;end
            8'd101: begin offset=8'd154;expected_data=16'h3000;expected_we=2'd2;end
            8'd102: begin offset=8'd154;expected_data=16'h0000;expected_we=2'd1;end
            8'd103: begin offset=8'd164;expected_data=16'h0000;expected_we=2'd1;end
            8'd104: begin offset=8'd166;expected_data=16'h0002;expected_we=2'd1;end
            8'd105: begin offset=8'd168;expected_data=location ? 16'h0000 : 16'h0004;expected_we=2'd3;end
            8'd106: begin offset=8'd170;expected_data=location ? 16'h7530 : 16'h93e0;expected_we=2'd3;end
            8'd107: begin offset=8'd186;expected_data=16'h2a00;expected_we=2'd3;end
            8'd108: begin offset=8'd180;expected_data=16'h2a2a;expected_we=2'd3;end
            8'd109: begin offset=8'd182;expected_data=16'h2a00;expected_we=2'd3;end
            8'd110: begin offset=8'd172;expected_data=16'h2000;expected_we=2'd2;end
            8'd111: begin offset=8'd172;expected_data=location ? 16'h0020 : 16'h0033;expected_we=2'd1;end
            8'd112: begin offset=8'd174;expected_data=location ? 16'h3300 : 16'h3000;expected_we=2'd2;end
            8'd113: begin offset=8'd174;expected_data=16'h0030;expected_we=2'd1;end
            8'd114: begin offset=8'd176;expected_data=16'h3000;expected_we=2'd2;end
            8'd115: begin offset=8'd176;expected_data=16'h0030;expected_we=2'd1;end
            8'd116: begin offset=8'd178;expected_data=16'h3000;expected_we=2'd2;end
            8'd117: begin offset=8'd178;expected_data=16'h0000;expected_we=2'd1;end
            8'd118: begin offset=8'd188;expected_data=16'h0000;expected_we=2'd1;end
            8'd119: begin offset=8'd190;expected_data=16'h0002;expected_we=2'd1;end
            8'd120: begin offset=8'd192;expected_data=location ? 16'h0000 : 16'h0003;expected_we=2'd3;end
            8'd121: begin offset=8'd194;expected_data=location ? 16'h4e20 : 16'h0d40;expected_we=2'd3;end
            8'd122: begin offset=8'd210;expected_data=16'h2a00;expected_we=2'd3;end
            8'd123: begin offset=8'd204;expected_data=16'h2a2a;expected_we=2'd3;end
            8'd124: begin offset=8'd206;expected_data=16'h2a00;expected_we=2'd3;end
            8'd125: begin offset=8'd196;expected_data=16'h2000;expected_we=2'd2;end
            8'd126: begin offset=8'd196;expected_data=location ? 16'h0020 : 16'h0032;expected_we=2'd1;end
            8'd127: begin offset=8'd198;expected_data=location ? 16'h3200 : 16'h3000;expected_we=2'd2;end
            8'd128: begin offset=8'd198;expected_data=16'h0030;expected_we=2'd1;end
            8'd129: begin offset=8'd200;expected_data=16'h3000;expected_we=2'd2;end
            8'd130: begin offset=8'd200;expected_data=16'h0030;expected_we=2'd1;end
            8'd131: begin offset=8'd202;expected_data=16'h3000;expected_we=2'd2;end
            8'd132: begin offset=8'd202;expected_data=16'h0000;expected_we=2'd1;end
            8'd133: begin offset=8'd212;expected_data=16'h0000;expected_we=2'd1;end
            8'd134: begin offset=8'd214;expected_data=16'h0002;expected_we=2'd1;end
            8'd135: begin offset=8'd216;expected_data=location ? 16'h0000 : 16'h0001;expected_we=2'd3;end
            8'd136: begin offset=8'd218;expected_data=location ? 16'h2710 : 16'h86a0;expected_we=2'd3;end
            8'd137: begin offset=8'd234;expected_data=16'h2a00;expected_we=2'd3;end
            8'd138: begin offset=8'd228;expected_data=16'h2a2a;expected_we=2'd3;end
            8'd139: begin offset=8'd230;expected_data=16'h2a00;expected_we=2'd3;end
            8'd140: begin offset=8'd220;expected_data=16'h2000;expected_we=2'd2;end
            8'd141: begin offset=8'd220;expected_data=location ? 16'h0020 : 16'h0031;expected_we=2'd1;end
            8'd142: begin offset=8'd222;expected_data=location ? 16'h3100 : 16'h3000;expected_we=2'd2;end
            8'd143: begin offset=8'd222;expected_data=16'h0030;expected_we=2'd1;end
            8'd144: begin offset=8'd224;expected_data=16'h3000;expected_we=2'd2;end
            8'd145: begin offset=8'd224;expected_data=16'h0030;expected_we=2'd1;end
            8'd146: begin offset=8'd226;expected_data=16'h3000;expected_we=2'd2;end
            8'd147: begin offset=8'd226;expected_data=16'h0000;expected_we=2'd1;end
            8'd148: begin offset=8'd236;expected_data=16'h0000;expected_we=2'd1;end
            8'd149: begin offset=8'd238;expected_data=16'h0002;expected_we=2'd1;end
            default: begin end
        endcase
        expected_addr=score_base+{8'd0,offset};
    end
endmodule

// Garegga high-score binding: profile lookup, score owner and save-state table.
module rzgaregga_score_binding #(parameter bit STABLE_ROM_EPOCH = 0) (
    input clk,reset,cpu_reset,
    input [31:0] rom_crc,rom_length,
    input rom_valid,
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
    input [6:0] cpu_addr,
    input [15:0] cpu_data,
    input [1:0] cpu_we,
    output [15:0] cpu_q,
    input state_active,hold_ack,
    output hold_request,active,
    output dirty,
    input [63:0] SS_DATA,
    input [31:0] SS_ADDR,
    input [7:0] SS_SELECT,
    input SS_WRITE,SS_READ,SS_QUERY,
    output [63:0] SS_DATA_OUT,
    output SS_ACK
);

    wire supported;
    wire [3:0] profile;
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
    // Each supported CRC/length has a unique nonzero profile ID.
    wire state_live = !reset && rom_valid && supported &&
                      (!previous_rom_valid || previous_profile == profile);
    wire [7:0] state_select = state_active && state_live ? SS_SELECT : 8'hff;

    wire location;
    assign restart_word = location ? 16'h0001 : 16'h000f;
    assign want_addr[63:16]=0;
    assign want_data[63:16]=0;
    assign want_we[7:2]=0;
    rzgaregga_highscore_profile witness (
        .rom_crc(rom_crc),.rom_length(rom_length),.progress(init_cursor[7:0]),
        .supported(supported),.location(location),.profile(profile),.score_base(score_base),
        .expected_addr(want_addr[15:0]),.expected_data(want_data[15:0]),.expected_we(want_we[1:0])
    );

    wire word_own, word_write, flags_write;
    wire [6:0] word_addr;
    wire [15:0] word_data, word_q;
    wire [63:0] flags_out, restore_flags;
    wire [16-1:0] saved_flags;
    wire [1:0] state_ack;
    wire [127:0] state_response_data;
    assign restore_flags = 64'(saved_flags);

    raizing_ss_ram_adapter #(.WIDTH(16),.ADDR_WIDTH(7),.SS_INDEX(44)) state_table (
        .clk(clk),.reset(!state_live),.ss_data(SS_DATA),.ss_addr(SS_ADDR),.ss_select(state_select),
        .ss_write(SS_WRITE),.ss_read(SS_READ),.ss_query(SS_QUERY),
        .ss_data_out(state_response_data[0+:64]),.ss_ack(state_ack[0]),
        .ram_active(word_own),.ram_addr(word_addr),.ram_data(word_data),.ram_we(word_write),.ram_q(word_q)
    );
    raizing_ss_register #(.WIDTH(16),.SS_INDEX(45)) state_flags (
        .clk(clk),.reset(!state_live),.capture_data(flags_out[16-1:0]),
        .restore_data(saved_flags),.restore_we(flags_write),.ss_data(SS_DATA),.ss_select(state_select),
        .ss_write(SS_WRITE),.ss_read(SS_READ),.ss_query(SS_QUERY),
        .ss_data_out(state_response_data[64+:64]),.ss_ack(state_ack[1])
    );
    raizing_ss_response_mux #(.COUNT(2)) state_response (
        .ack(state_ack),.data(state_response_data),.ack_out(SS_ACK),.data_out(SS_DATA_OUT)
    );
    rzscore_late #(.PROFILE(2), .STABLE_ROM_EPOCH(STABLE_ROM_EPOCH)) owner (
        .rom_valid(rom_valid),.profile_supported(supported),.rom_crc(rom_crc),.rom_length(rom_length),
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

// Garegga CPU bus router: ROM and GP replies complete combinationally, other completions are registered.

`default_nettype none

module rzgaregga_bus (
    output raizing_socket_pkg::mem_in_t sk_mem_i,
    input raizing_socket_pkg::mem_out_t sk_mem_o,

  input  wire        clk,
  input  wire        reset,
  input  wire [23:1] cpu_addr,
  input  wire        cpu_as_n,
  input  wire        cpu_rw,
  input  wire        cpu_uds_n,
  input  wire        cpu_lds_n,
  input  wire [2:0]  cpu_fc,
  input  wire [15:0] cpu_dout,
  input  wire        block_writes,
  input  wire        override_valid,
  output wire [15:0] cpu_din,
  output wire        selected,
  output wire        busy,
  output wire        idle,
  output wire        rom_req,
  output wire [18:0] rom_addr,
  input  wire        rom_ok,
  input  wire [15:0] rom_data,
  output wire        gp_req,
  output wire        gp_start,
  output wire [2:0]  gp_op,
  output wire [1:0]  gp_be,
  output wire [15:0] gp_din,
  input  wire        gp_ack,
  input  wire [15:0] gp_dout,
  input  wire [8:0]  vpos,
  input  wire        status_hs_n,
  input  wire        status_vs_n,
  input  wire        status_blank_n,
  input  wire [7:0]  p1_inputs,
  input  wire [7:0]  p2_inputs,
  input  wire [7:0]  sys_inputs,
  input  wire [7:0]  dsw_a,
  input  wire [7:0]  dsw_b,
  input  wire [7:0]  dsw_c,
  input  wire palette_hold, palette_blank,
  input  wire [10:0] pal_addr,
  output wire [15:0] pal_data,
  input  wire [11:0] text_addr,
  output wire [15:0] text_data,
  input  wire [7:0]  select_addr,
  input  wire [7:0]  scroll_addr,
  output wire [15:0] select_data,
  output wire [15:0] scroll_data,
  input  wire [12:0] z80_addr,
  input  wire [7:0]  z80_din,
  input  wire        z80_we,
  output wire [7:0]  z80_dout,
  input  wire        ram_enable,
  input  wire        ram_req,
  input  wire [2:0]  ram_region,
  input  wire [14:0] ram_addr,
  input  wire [15:0] ram_din,
  input  wire [1:0]  ram_we,
  output wire        ram_ack,
  output wire [15:0] ram_dout,
  input  wire        state_active,
  input  wire        state_valid,
  output wire        state_ready,
  input  wire [2:0]  state_region,
  input  wire [14:0] state_addr,
  input  wire [15:0] state_din,
  input  wire [1:0]  state_we,
  output wire        state_rsp_valid,
  input  wire        state_rsp_ready,
  output wire [15:0] state_q,
  output wire        state_error,
  input  wire        hs_ready,
  input  wire [15:0] score_base,
  input  wire [15:0] hs_dout,
  output wire        hs_cs,
  output wire [6:0]  hs_addr,
  output wire [15:0] hs_din,
  output wire [1:0]  hs_we,
  output wire        wram_write,
  output wire [15:0] wram_addr,
  output wire [15:0] wram_data,
  output wire [1:0]  wram_we,
  input  wire        sound_wait_grant,
  output wire        sound_wait_begin,
  output wire        sound_wait_abandon,
  output wire        sound_wait_active,
  output wire        sound_command_write,
  output wire        ctx_sample_valid,
  output wire [14:0] ctx_sample_word,
  output wire [15:0] ctx_sample_before,
  output wire [15:0] ctx_sample_written
);

  // Endpoint IDs select bits in the link's one-hot route vector.

  localparam logic [5:0] EP_CPU_ROM        = 6'd2;
  localparam logic [5:0] EP_WORK_RAM       = 6'd3;
  localparam logic [5:0] EP_SHARED_RAM     = 6'd5;
  localparam logic [5:0] EP_INPUT_P1       = 6'd6;
  localparam logic [5:0] EP_INPUT_P2       = 6'd7;
  localparam logic [5:0] EP_INPUT_SYSTEM   = 6'd8;
  localparam logic [5:0] EP_DIP_A          = 6'd9;
  localparam logic [5:0] EP_DIP_B          = 6'd10;
  localparam logic [5:0] EP_REGION_JUMPERS = 6'd11;
  localparam logic [5:0] EP_GP_STATUS      = 6'd15;
  localparam logic [5:0] EP_GP_REGISTERS   = 6'd16;
  localparam logic [5:0] EP_PALETTE_RAM    = 6'd17;
  localparam logic [5:0] EP_TEXT_MAP       = 6'd19;
  localparam logic [5:0] EP_TEXT_SELECT    = 6'd20;
  localparam logic [5:0] EP_TEXT_SCROLL    = 6'd21;
  localparam logic [5:0] EP_TEXT_WORK_RAM  = 6'd22;
  localparam logic [5:0] EP_SOUND_COMMAND  = 6'd25;

  // Tracked transaction owner
  localparam logic [2:0] OWN_OPEN  = 3'd0;  // open / unserviced: zero data
  localparam logic [2:0] OWN_ROM   = 3'd1;  // program ROM level request
  localparam logic [2:0] OWN_RAM   = 3'd2;  // RAM owner primary request
  localparam logic [2:0] OWN_GP    = 3'd3;  // GP level request
  localparam logic [2:0] OWN_LOCAL = 3'd4;  // local read word (direct read ID)
  localparam logic [2:0] OWN_SOUND = 3'd5;  // sound command waiting for grant

  // Endpoint-facing nets

  wire [39:0]  lk_cmd;
  wire [22:0]  lk_index;
  wire [1:0]   lk_lanes;
  wire         lk_complete;
  wire [15:0]  lk_data;

  wire         mo_cpu_ready;
  wire         mo_rsp_valid;
  wire [15:0]  mo_rsp_data;
  wire [119:0] mo_view_addr;
  wire [127:0] mo_view_wdata;
  wire [15:0]  mo_view_we;
  wire [127:0] mo_view_data;
  wire [7:0]   mo_view_valid;
  wire [2:0]   mo_aux_valid;
  wire [2:0]   mo_aux_ready;
  wire [8:0]   mo_aux_region;
  wire [44:0]  mo_aux_addr;
  wire [47:0]  mo_aux_wdata;
  wire [5:0]   mo_aux_we;
  wire [2:0]   mo_aux_rsp_valid;
  wire [2:0]   mo_aux_rsp_ready;
  wire [47:0]  mo_aux_rsp_data;
  wire [2:0]   mo_aux_rsp_error;

  wire [1:0]   gpc_kind;
  wire [2:0]   gpc_op;
  wire [15:0]  gpc_data;
  wire [1:0]   gpc_be;
  wire [15:0]  rw_data;
  wire [1:0]   sw_lanes;
  wire [8:0]   sw_word;
  wire         sw_witness;

  // Unused endpoint outputs.
  wire         unused_profile_ok, unused_mo_idle, unused_rsp_tag, unused_rsp_error;
  wire [1:0]   unused_rsp_driven;
  wire [2:0]   unused_aux_rsp_tag, unused_gpc_bank;
  wire         unused_wram_commit;
  wire [14:0]  unused_wram_word;
  wire [15:0]  unused_wram_data;
  wire [1:0]   unused_wram_be;

  // Ordinary active window and command acceptance

  // AS low, a data strobe low, and not CPU space (FC=7).
  wire win_act   = ~cpu_as_n & (~cpu_uds_n | ~cpu_lds_n) & (cpu_fc != 3'b111);
  wire cpu_write = ~cpu_rw;
  wire normal_wr = cpu_write & ~block_writes;

  logic seen_q;   // a command was taken in the current active window
  logic done_q;   // the current transaction has already finished

  // A nonzero one-hot command starts a single transaction per active window.
  wire cmd_fire = ~reset & win_act & ~seen_q & (|lk_cmd);

  // Route classes of the one-hot command
  wire r_rom   = lk_cmd[EP_CPU_ROM];
  wire r_wram  = lk_cmd[EP_WORK_RAM];
  wire r_ram   = lk_cmd[EP_WORK_RAM]    | lk_cmd[EP_SHARED_RAM]   |
                 lk_cmd[EP_PALETTE_RAM] | lk_cmd[EP_TEXT_MAP]     |
                 lk_cmd[EP_TEXT_SELECT] | lk_cmd[EP_TEXT_SCROLL]  |
                 lk_cmd[EP_TEXT_WORK_RAM];
  wire r_gp    = lk_cmd[EP_GP_REGISTERS];
  wire r_sound = lk_cmd[EP_SOUND_COMMAND];

  // RAM route endpoint number for the memory owner (one-hot to binary)
  wire [5:0] ram_ep = ({6{lk_cmd[EP_WORK_RAM]}}      & EP_WORK_RAM)      |
                      ({6{lk_cmd[EP_SHARED_RAM]}}    & EP_SHARED_RAM)    |
                      ({6{lk_cmd[EP_PALETTE_RAM]}}   & EP_PALETTE_RAM)   |
                      ({6{lk_cmd[EP_TEXT_MAP]}}      & EP_TEXT_MAP)      |
                      ({6{lk_cmd[EP_TEXT_SELECT]}}   & EP_TEXT_SELECT)   |
                      ({6{lk_cmd[EP_TEXT_SCROLL]}}   & EP_TEXT_SCROLL)   |
                      ({6{lk_cmd[EP_TEXT_WORK_RAM]}} & EP_TEXT_WORK_RAM);

  // Local read IDs of the direct-read routes
  wire [3:0] dir_id = ({4{lk_cmd[EP_INPUT_P1]}}       & 4'd1) |
                      ({4{lk_cmd[EP_INPUT_P2]}}       & 4'd2) |
                      ({4{lk_cmd[EP_INPUT_SYSTEM]}}   & 4'd3) |
                      ({4{lk_cmd[EP_DIP_A]}}          & 4'd4) |
                      ({4{lk_cmd[EP_DIP_B]}}          & 4'd5) |
                      ({4{lk_cmd[EP_REGION_JUMPERS]}} & 4'd6) |
                      ({4{lk_cmd[EP_GP_STATUS]}}      & 4'd7);
  wire r_direct = |dir_id;

  // GP register command classes from rzperiph_gp_command
  wire gp_blocked = cpu_write & block_writes;
  wire gp_launch  = r_gp & (gpc_kind == 2'd2) & ~gp_blocked;
  wire gp_local   = r_gp & ((gpc_kind == 2'd1) | gp_blocked);
  wire snd_wait   = r_sound & normal_wr;

  logic [2:0] own_next;
  always_comb begin
    own_next = OWN_OPEN;
    if (r_rom)                     own_next = OWN_ROM;
    else if (r_ram)                own_next = OWN_RAM;
    else if (gp_launch)            own_next = OWN_GP;
    else if (gp_local | r_direct)  own_next = OWN_LOCAL;
    else if (snd_wait)             own_next = OWN_SOUND;
  end
  wire [3:0] rid_next = gp_local ? 4'd11 : dir_id;

  // Score window hit from rzscore_window

  wire score_hit = |sw_lanes;

  // RAM owner primary request: exactly one offer, in the command cycle

  wire ram_valid = cmd_fire & r_ram;
  wire ram_admit = ram_valid & mo_cpu_ready;
  wire wram_wr   = ram_admit & r_wram & normal_wr;   // normal admitted WRAM write

  // Transaction state

  logic [2:0]  own_q;     // tracked owner
  logic [3:0]  rid_q;     // captured local read ID
  logic        adm_q;     // normal memory request admitted at command
  logic        hit_q;     // current score word in the payload at command
  logic        wram_q;    // command was a WRAM route
  logic        cmpl_q;    // registered completion to the link
  logic [15:0] data_q;    // registered response word (cpu_din)

  logic        rom_req_q;
  logic [18:0] rom_addr_q;
  logic        gp_req_q;
  logic        gp_start_q;
  logic [2:0]  gp_op_q;
  logic [1:0]  gp_be_q;
  logic [15:0] gp_din_q;

  // Active, seen and unfinished transaction
  wire live      = win_act & seen_q & ~done_q;
  wire fin_open  = live & (own_q == OWN_OPEN);
  wire fin_local = live & (own_q == OWN_LOCAL);
  wire fin_ram   = live & (own_q == OWN_RAM) & adm_q & mo_rsp_valid;
  wire fin_sound = live & (own_q == OWN_SOUND) & sound_wait_grant;
  wire fin_reg   = fin_open | fin_local | fin_ram | fin_sound;

  // Score word overlays a WRAM read that hit the score window while the score owner is ready.
  wire        overlay  = wram_q & hit_q & hs_ready;
  wire [15:0] ram_word = overlay ? hs_dout : mo_rsp_data;
  wire [15:0] fin_word = fin_local ? rw_data : (fin_ram ? ram_word : 16'h0000);

  // ROM OK / GP ACK complete to the link combinationally
  wire rom_hit = rom_req_q & rom_ok;
  wire gp_hit  = gp_req_q & gp_ack;
  assign lk_complete = rom_hit | gp_hit | cmpl_q;
  assign lk_data     = rom_hit ? rom_data : (gp_hit ? gp_dout : data_q);

  always_ff @(posedge clk) begin
    if (reset) begin
      seen_q     <= 1'b0;
      done_q     <= 1'b0;
      own_q      <= OWN_OPEN;
      rid_q      <= 4'd0;
      adm_q      <= 1'b0;
      hit_q      <= 1'b0;
      wram_q     <= 1'b0;
      cmpl_q     <= 1'b0;
      data_q     <= 16'h0000;
      rom_req_q  <= 1'b0;
      rom_addr_q <= 19'd0;
      gp_req_q   <= 1'b0;
      gp_start_q <= 1'b0;
      gp_op_q    <= 3'd0;
      gp_be_q    <= 2'b00;
      gp_din_q   <= 16'h0000;
    end else begin
      cmpl_q     <= fin_reg;
      gp_start_q <= 1'b0;

      if (fin_reg) begin
        data_q <= fin_word;
        done_q <= 1'b1;
      end
      if (rom_hit) begin
        rom_req_q <= 1'b0;
        data_q    <= rom_data;
        done_q    <= 1'b1;
      end else if (gp_hit) begin
        gp_req_q <= 1'b0;
        data_q   <= gp_dout;
        done_q   <= 1'b1;
      end

      if (cmd_fire) begin
        seen_q <= 1'b1;
        done_q <= 1'b0;
        own_q  <= own_next;
        rid_q  <= rid_next;
        adm_q  <= ram_admit;
        hit_q  <= score_hit;
        wram_q <= r_wram;
        if (r_rom) begin
          rom_req_q  <= 1'b1;
          rom_addr_q <= cpu_addr[19:1];
        end
        if (gp_launch) begin
          gp_req_q   <= 1'b1;
          gp_start_q <= 1'b1;
          gp_op_q    <= gpc_op;
          gp_be_q    <= gpc_be;
          gp_din_q   <= cpu_rw ? cpu_dout : gpc_data;
        end else begin
          gp_be_q    <= lk_lanes;
        end
      end

      // Leaving the active window drops seen/completed and live requests.
      if (~win_act) begin
        seen_q    <= 1'b0;
        done_q    <= 1'b0;
        rom_req_q <= 1'b0;
        gp_req_q  <= 1'b0;
      end
    end
  end

  // Auxiliary client 1: ordinary auxiliary RAM request

  logic        ram_acc_q;   // the held ram_req level has been accepted
  logic        ram_ack_q;
  logic [15:0] ram_dout_q;
  wire aux1_valid = ram_req & ~ram_acc_q & ~state_active;

  always_ff @(posedge clk) begin
    if (reset) begin
      ram_acc_q  <= 1'b0;
      ram_ack_q  <= 1'b0;
      ram_dout_q <= 16'h0000;
    end else begin
      ram_ack_q <= mo_aux_rsp_valid[1];
      if (mo_aux_rsp_valid[1]) ram_dout_q <= mo_aux_rsp_data[31:16];
      if (~ram_req)                            ram_acc_q <= 1'b0;
      else if (aux1_valid & mo_aux_ready[1])   ram_acc_q <= 1'b1;
    end
  end

  // Stack journal: samples full-word FC=5 WRAM writes outside the score witness with a clean prior read.

  wire [14:0]  wr_word = cpu_addr[15:1];
  logic [14:0] jv_word_q;                  // view-0 word sampled at the preceding edge
  logic        jw_cpu_q,  jw_st_q,  jw_ax_q;
  logic [14:0] jw_cpu_word_q, jw_st_word_q, jw_ax_word_q;
  logic        cs_valid_q;
  logic [14:0] cs_word_q;
  logic [15:0] cs_before_q, cs_after_q;

  wire prior_hazard = (jw_cpu_q & (jw_cpu_word_q == wr_word)) |
                      (jw_st_q  & (jw_st_word_q  == wr_word)) |
                      (jw_ax_q  & (jw_ax_word_q  == wr_word));
  wire prior_ok  = mo_view_valid[0] & (jv_word_q == wr_word) & ~prior_hazard;
  wire sample_ok = wram_wr & (lk_lanes == 2'b11) & (cpu_fc == 3'b101) &
                   ~sw_witness & prior_ok;

  always_ff @(posedge clk) begin
    jv_word_q     <= wr_word;
    jw_cpu_q      <= wram_wr;
    jw_cpu_word_q <= wr_word;
    jw_st_q       <= state_valid & mo_aux_ready[0] & (state_region == 3'd0) & (|state_we);
    jw_st_word_q  <= state_addr;
    jw_ax_q       <= aux1_valid & mo_aux_ready[1] & (ram_region == 3'd0) & (|ram_we);
    jw_ax_word_q  <= ram_addr;
    if (wram_wr) begin
      cs_word_q   <= wr_word;
      cs_before_q <= mo_view_data[15:0];
      cs_after_q  <= cpu_dout;
    end
    cs_valid_q    <= sample_ok;
  end

  // Endpoint instances

  rzbus_cpu_link #(.PROFILE("garegga")) u_link (
    .alt_map(1'b0),
    .clk            (clk),
    .reset          (reset),
    .cpu_addr       (cpu_addr),
    .cpu_as_n       (cpu_as_n),
    .cpu_rw         (cpu_rw),
    .cpu_uds_n      (cpu_uds_n),
    .cpu_lds_n      (cpu_lds_n),
    .cpu_fc         (cpu_fc),
    .cpu_dout       (cpu_dout),
    .override_valid (override_valid),
    .selected       (selected),
    .busy           (busy),
    .idle           (idle),
    .command        (lk_cmd),
    .command_index  (lk_index),
    .command_lanes  (lk_lanes),
    .owner_complete (lk_complete),
    .owner_data     (lk_data)
  );

  wire [29:0] palette_commit;
  wire [10:0] palette_source_addr;

  // Views pack by ascending region from the least-significant bits.
  assign mo_view_addr = {15'd0,                  // region 7
                         15'd0,                  // region 6
                         {7'd0, scroll_addr},    // region 5 line scroll
                         {7'd0, select_addr},    // region 4 line select
                         {3'd0, text_addr},      // region 3 text map
                         {4'd0, palette_source_addr},       // region 2 palette
                         {2'd0, z80_addr},       // region 1 Z80 shared byte
                         cpu_addr[15:1]};        // region 0 journal (CPU offset)
  assign mo_view_wdata = {96'd0, {8'd0, z80_din}, 16'd0};
  assign mo_view_we    = {12'd0, {1'b0, z80_we}, 2'b00};

  // Auxiliary clients pack from low to high: 0 = state, 1 = RAM, 2 = off.
  assign mo_aux_valid     = {1'b0, aux1_valid, state_valid};
  assign mo_aux_region    = {3'd0, ram_region, state_region};
  assign mo_aux_addr      = {15'd0, ram_addr, state_addr};
  assign mo_aux_wdata     = {16'd0, ram_din, state_din};
  assign mo_aux_we        = {2'b00, ram_we, state_we};
  assign mo_aux_rsp_ready = {1'b1, 1'b1, state_rsp_ready};

  // rzmem_owner pins via socket sk_mem.
    assign sk_mem_i.scratch_en = 1'b0;
    assign sk_mem_i.late_en = 1'b0;
    assign sk_mem_i.clk = clk;
    assign sk_mem_i.rst = reset;
    assign sk_mem_i.cpu_quiesce = 1'b0;
    assign sk_mem_i.hold_cert = ram_enable;
    assign sk_mem_i.dma_enable = 1'b0;
    assign sk_mem_i.write_block = block_writes;
    assign sk_mem_i.cpu_valid = ram_valid;
    assign sk_mem_i.cpu_endpoint = ram_ep;
    assign sk_mem_i.cpu_index = lk_index;
    assign sk_mem_i.cpu_write = cpu_write;
    assign sk_mem_i.cpu_be = lk_lanes;
    assign sk_mem_i.cpu_wdata = cpu_dout;
    assign sk_mem_i.cpu_tag = 1'b0;
    assign sk_mem_i.cpu_rsp_ready = 1'b1;
    assign sk_mem_i.view_addr = mo_view_addr;
    assign sk_mem_i.view_wdata = mo_view_wdata;
    assign sk_mem_i.view_we = mo_view_we;
    assign sk_mem_i.aux_valid = mo_aux_valid;
    assign sk_mem_i.aux_region = mo_aux_region;
    assign sk_mem_i.aux_addr = mo_aux_addr;
    assign sk_mem_i.aux_wdata = mo_aux_wdata;
    assign sk_mem_i.aux_we = mo_aux_we;
    assign sk_mem_i.aux_tag = 3'b000;
    assign sk_mem_i.aux_rsp_ready = mo_aux_rsp_ready;
    assign unused_profile_ok = sk_mem_o.profile_ok;
    assign unused_mo_idle = sk_mem_o.idle;
    assign mo_cpu_ready = sk_mem_o.cpu_ready;
    assign mo_rsp_valid = sk_mem_o.cpu_rsp_valid;
    assign mo_rsp_data = sk_mem_o.cpu_rsp_data;
    assign unused_rsp_driven = sk_mem_o.cpu_rsp_driven;
    assign unused_rsp_tag = sk_mem_o.cpu_rsp_tag;
    assign unused_rsp_error = sk_mem_o.cpu_rsp_error;
    assign mo_view_data = sk_mem_o.view_data;
    assign mo_view_valid = sk_mem_o.view_valid;
    assign mo_aux_ready = sk_mem_o.aux_ready;
    assign mo_aux_rsp_valid = sk_mem_o.aux_rsp_valid;
    assign mo_aux_rsp_data = sk_mem_o.aux_rsp_data;
    assign unused_aux_rsp_tag = sk_mem_o.aux_rsp_tag;
    assign mo_aux_rsp_error = sk_mem_o.aux_rsp_error;
    assign unused_wram_commit = sk_mem_o.wram_commit;
    assign unused_wram_word = sk_mem_o.wram_word;
    assign unused_wram_data = sk_mem_o.wram_data;
    assign unused_wram_be = sk_mem_o.wram_be;
    assign palette_commit = sk_mem_o.palette_commit;

  rzperiph_gp_command #(.PROFILE(2)) u_gpcmd (
    .endpoint    ({1'b0, r_gp}),
    .index       (lk_index[2:0]),
    .read_cycle  (cpu_rw),
    .lanes       (lk_lanes),
    .block_write (block_writes),
    .write_data  (cpu_dout),
    .kind        (gpc_kind),
    .op          (gpc_op),
    .bank        (unused_gpc_bank),
    .data        (gpc_data),
    .be          (gpc_be)
  );
  // Input and DIP reads return zero in the upper byte.
  rzperiph_read_word #(.PROFILE(2)) u_rdw (
    .read_id       (rid_q),
    .players       ({p2_inputs, p1_inputs}),
    .system_inputs (sys_inputs),
    .dip_a         (dsw_a),
    .dip_b         (dsw_b),
    .dip_c         (dsw_c),
    .reply         (16'h0000),
    .bus_status    (16'h0000),
    .vpos          (vpos),
    .hs_n          (status_hs_n),
    .vs_n          (status_vs_n),
    .blank_n       (status_blank_n),
    .bit13         (1'b1),
    .data          (rw_data)
  );

  rzscore_window #(.PROFILE(2)) u_score (
    .alt_map(1'b0),
    .word_addr      (cpu_addr),
    .score_base     (score_base),
    .payload_lanes  (sw_lanes),
    .packed_word    (sw_word),
    .witness_window (sw_witness)
  );

  // Public outputs

  assign cpu_din   = data_q;
  assign rom_req   = rom_req_q;
  assign rom_addr  = rom_addr_q;
  assign gp_req    = gp_req_q;
  assign gp_start  = gp_start_q;
  assign gp_op     = gp_op_q;
  assign gp_be     = gp_be_q;
  assign gp_din    = gp_din_q;

  assign z80_dout    = mo_view_data[23:16];
  SorcerPaletteTail tail_palette (
    .clk(clk), .reset(reset), .tail_hold(palette_hold), .in_blank(palette_blank),
    .cpu_commit(palette_commit[29]), .write_addr(palette_commit[28:18]),
    .write_data(palette_commit[17:2]), .write_be(palette_commit[1:0]),
    .display_addr(pal_addr), .display_data(pal_data), .canonical_addr(palette_source_addr),
    .canonical_data(mo_view_data[47:32]), .canonical_valid(mo_view_valid[2]),
    .copy_busy(), .live_fallback(), .missed_deadline()
  );
  assign text_data   = mo_view_data[63:48];
  assign select_data = mo_view_data[79:64];
  assign scroll_data = mo_view_data[95:80];

  assign ram_ack  = ram_ack_q;
  assign ram_dout = ram_dout_q;

  assign state_ready     = mo_aux_ready[0];
  assign state_rsp_valid = mo_aux_rsp_valid[0];
  assign state_q         = mo_aux_rsp_data[15:0];
  assign state_error     = mo_aux_rsp_error[0];

  assign hs_cs   = win_act & score_hit & ~reset & ~override_valid;
  assign hs_addr = sw_word[6:0];
  assign hs_din  = cpu_dout;
  assign hs_we   = (hs_cs & wram_wr & hs_ready) ? (lk_lanes & sw_lanes) : 2'b00;

  assign wram_write = wram_wr;
  assign wram_addr  = {cpu_addr[15:1], 1'b0};
  assign wram_data  = cpu_dout;
  assign wram_we    = wram_wr ? lk_lanes : 2'b00;

  assign sound_wait_begin    = cmd_fire;
  assign sound_wait_abandon  = ~win_act;
  assign sound_wait_active   = ~reset & live & (own_q == OWN_SOUND);
  assign sound_command_write = cmd_fire & r_sound & normal_wr;

  // Unused endpoint output bits
  wire unused_endpoint_bits = &{1'b0, mo_view_data[127:96], mo_view_data[31:24], mo_view_valid[7:1],
                                mo_aux_ready[2], mo_aux_rsp_valid[2], mo_aux_rsp_data[47:32],
                                mo_aux_rsp_error[2:1], sw_word[8:7]};

  assign ctx_sample_valid   = cs_valid_q;
  assign ctx_sample_word    = cs_word_q;
  assign ctx_sample_before  = cs_before_q;
  assign ctx_sample_written = cs_after_q;

  // Simulation-only contract checks.

`ifndef SYNTHESIS
  // synthesis translate_off
  integer sim_ram_refusals;    // refused normal RAM admissions
  integer sim_contract_flags;  // other out-of-contract observations
  initial begin
    sim_ram_refusals   = 0;
    sim_contract_flags = 0;
  end
  always @(posedge clk) begin
    if (!reset) begin
      if (ram_valid && !mo_cpu_ready) begin
        sim_ram_refusals <= sim_ram_refusals + 1;
        $display("rzgaregga_bus SIM-FLAG: normal RAM command refused (outside the qualified contract; no cycle added, no write fabricated)");
      end
      if ((lk_cmd & (lk_cmd - 40'd1)) != 40'd0) begin
        sim_contract_flags <= sim_contract_flags + 1;
        $display("rzgaregga_bus SIM-FLAG: link command is not one-hot (%h)", lk_cmd);
      end
      if ((|lk_cmd) && win_act && seen_q) begin
        sim_contract_flags <= sim_contract_flags + 1;
        $display("rzgaregga_bus SIM-FLAG: second link command in one active window ignored");
      end
      if (cmd_fire && r_gp && (gpc_kind == 2'd3)) begin
        sim_contract_flags <= sim_contract_flags + 1;
        $display("rzgaregga_bus SIM-FLAG: GP command leaf returned kind 3 (treated as open)");
      end
      if (mo_rsp_valid && !(live && (own_q == OWN_RAM) && adm_q)) begin
        sim_contract_flags <= sim_contract_flags + 1;
        $display("rzgaregga_bus SIM-FLAG: RAM owner reply with no admitted live RAM transaction");
      end
    end
  end
  // synthesis translate_on
`endif

endmodule

`default_nettype wire

// Garegga main CPU: FX68K with phase scheduler, game bus, IRQ owner, context owner and state adapters.

module rzgaregga_main_cpu (
    output raizing_socket_pkg::ctx_in_t sk_ctx_i,
    input raizing_socket_pkg::ctx_out_t sk_ctx_o,

    output raizing_socket_pkg::mem_in_t sk_mem_i,
    input raizing_socket_pkg::mem_out_t sk_mem_o,

    output raizing_socket_pkg::cpu_in_t sk_cpu_i,
    input raizing_socket_pkg::cpu_out_t sk_cpu_o,

    // ---- clock, board reset, host hold controls ---------------------------
    input  logic        clk,
    input  logic        reset,
    input  logic        pause,
    input  logic        hold_req,
    input  logic        ss_freeze,
    output logic        quiesced,
    // ---- program ROM (direct game bus pins) -------------------------------
    output logic        rom_req,
    output logic [18:0] rom_addr,
    input  logic        rom_ok,
    input  logic [15:0] rom_data,
    // ---- GP9001 host port (direct game bus pins) --------------------------
    output logic        gp_req,
    output logic        gp_start,
    output logic [2:0]  gp_op,
    output logic [1:0]  gp_be,
    output logic [15:0] gp_din,
    input  logic        gp_ack,
    input  logic [15:0] gp_dout,
    // ---- video timing ------------------------------------------------------
    input  logic        vblank_n,          // IRQ owner GP VINT input only
    input  logic [8:0]  vpos,
    input  logic        status_hs_n,
    input  logic        status_vs_n,
    input  logic        status_blank_n,
    // ---- inputs and DIP switches (direct game bus pins) -------------------
    input  logic [7:0]  p1_inputs,
    input  logic [7:0]  p2_inputs,
    input  logic [7:0]  sys_inputs,
    input  logic [7:0]  dsw_a,
    input  logic [7:0]  dsw_b,
    input  logic [7:0]  dsw_c,
    // ---- palette and external text map / select / scroll ------------------
    input  logic palette_hold, palette_blank,
    input  logic [10:0] pal_addr,
    output logic [15:0] pal_data,
    input  logic [11:0] text_addr,
    output logic [15:0] text_data,
    input  logic [7:0]  select_addr,
    input  logic [7:0]  scroll_addr,
    output logic [15:0] select_data,
    output logic [15:0] scroll_data,
    // ---- Z80 shared memory -------------------------------------------------
    input  logic [12:0] z80_addr,
    input  logic [7:0]  z80_din,
    input  logic        z80_we,
    output logic [7:0]  z80_dout,
    // ---- ordinary external RAM request (permission applied here) ----------
    input  logic        ram_req,
    input  logic        ram_access_enable,
    input  logic [2:0]  ram_region,
    input  logic [14:0] ram_addr,
    input  logic [15:0] ram_din,
    input  logic [1:0]  ram_we,
    output logic        ram_ack,
    output logic [15:0] ram_dout,
    // ---- high score --------------------------------------------------------
    input  logic        hs_ready,
    input  logic [15:0] score_base,
    input  logic [15:0] hs_dout,
    output logic        hs_cs,
    output logic [6:0]  hs_addr,
    output logic [15:0] hs_din,
    output logic [1:0]  hs_we,
    // ---- committed WRAM observation ---------------------------------------
    output logic        wram_write,
    output logic [15:0] wram_addr,
    output logic [15:0] wram_data,
    output logic [1:0]  wram_we,
    // ---- FX68K oRESETn ----------------------------------------------------
    output logic        m68k_reset_n,
    // ---- sound mailbox -----------------------------------------------------
    output logic [7:0]  sound_latch,
    output logic        sound_irq,
    output rzgaregga_mbox_pkg::request_t  mailbox_request,
    input  rzgaregga_mbox_pkg::response_t mailbox_reply,
    // ---- context slot and save/restore service ----------------------------
    input  rzctx_slot_pkg::request_t    ctx_request,
    output rzctx_slot_pkg::response_t   ctx_response,
    output logic        ctx_fault,
    input  logic        ss_save_begin,
    input  logic        ss_save_resume,
    input  logic        ss_restore_begin,
    input  logic        ss_restore_window, // unused
    output logic        ss_save_ready,
    output logic        ss_save_done,
    output logic        ss_restore_done,
    output logic        ss_busy,
    // ---- outer state transfer ---------------------------------------------
    input  logic [63:0] ss_data,
    input  logic [31:0] ss_addr,
    input  logic [7:0]  ss_select,
    input  logic        ss_write,
    input  logic        ss_read,
    input  logic        ss_query,
    output logic [63:0] ss_data_out,
    output logic        ss_ack,
    // ---- CPU bus monitor --------------------------------------------------
    output logic [23:1] cpu_addr,
    output logic        cpu_as_n,
    output logic        cpu_rw,
    output logic        cpu_uds_n,
    output logic        cpu_lds_n,
    output logic [2:0]  cpu_fc,
    output logic        cpu_phase1,
    output logic        cpu_phase2
);

    // Constants

    // Context RAM window, inclusive 68000 word addresses (A23:1 values).
    localparam logic [23:1] CTX_RAM_LO_WORD = 23'h08_0000;
    localparam logic [23:1] CTX_RAM_HI_WORD = 23'h08_7FFF;
    // Slot writes target the restore bank and all reads target the captured bank.

    localparam logic        CTX_BANK_CAPTURED = 1'b0;
    // Undo always writes region 0 with both byte lanes.
    localparam logic [2:0]  UNDO_REGION = 3'd0;
    localparam logic [1:0]  UNDO_LANES  = 2'b11;

    // Nets

    // FX68K pins
    logic        cpu_as_n_s, cpu_rw_s, cpu_uds_n_s, cpu_lds_n_s;
    logic        cpu_fc0_s, cpu_fc1_s, cpu_fc2_s;
    logic [2:0]  cpu_fc_s;
    logic [23:1] cpu_addr_s;
    logic [15:0] cpu_dout_s;
    logic        cpu_halted_n_s, cpu_oreset_n_s;
    // Values supplied to FX68K by the ownership table
    logic [15:0] sel_din;
    logic        sel_dtack_n, sel_vpa_n;
    // AS presented to normal endpoints (game bus, phase scheduler, IRQ owner)
    logic        normal_as_n;

    // Phase scheduler
    logic        phase1, phase2, base_dtack_n, sched_run;

    // Game bus
    logic [15:0] bus_cpu_din;
    logic        bus_selected, bus_busy, bus_idle;
    logic        bus_ram_enable;
    logic        bus_state_active, bus_state_valid, bus_state_ready;
    logic [2:0]  bus_state_region;
    logic [14:0] bus_state_addr;
    logic [15:0] bus_state_din;
    logic [1:0]  bus_state_we;
    logic        bus_state_rsp_valid, bus_state_rsp_ready;
    logic [15:0] bus_state_q;
    logic        bus_state_error;
    logic        bus_snd_wait_begin, bus_snd_wait_abandon, bus_snd_wait_active;
    logic        bus_snd_command_write;
    logic        bus_sample_valid;
    logic [14:0] bus_sample_word;
    logic [15:0] bus_sample_before, bus_sample_written;

    // Context owner
    logic        ctx_bus_claim, ctx_cpu_dtack_n, ctx_cpu_vpa_n;
    logic [15:0] ctx_cpu_din;
    logic        ctx_ipl7_req, ctx_cpu_reset;
    logic        ctx_cmd_valid;
    logic [2:0]  ctx_cmd_op;
    logic        ctx_rsp_valid, ctx_rsp_ok;
    logic [3:0]  ctx_rsp_code;
    logic        ctx_word_req, ctx_word_we, ctx_word_bank;
    logic [5:0]  ctx_word_idx;
    logic [15:0] ctx_word_wdata;
    logic        ctx_word_ack, ctx_word_nak;
    logic [15:0] ctx_word_rdata;
    logic        ctx_st_busy, ctx_st_parked, ctx_st_held;
    logic        ctx_st_cap_valid, ctx_st_admitted;
    logic        ctx_evt_valid;
    logic [3:0]  ctx_evt_code;

    // Board service
    logic        svc_cmd_valid;
    logic [2:0]  svc_cmd_op;
    logic        svc_ctx_req;
    logic [5:0]  svc_ctx_idx;
    logic        svc_journal_arm, svc_journal_cancel, svc_journal_confirm;
    logic [14:0] svc_journal_word;
    logic [15:0] svc_journal_pc;
    logic        svc_run, svc_save_ready, svc_save_done, svc_restore_done, svc_fault;

    // Stack undo
    logic        undo_valid, undo_response_ready, undo_done, undo_fault;
    logic [14:0] undo_word;
    logic [15:0] undo_data;
    logic        undo_owns;

    // IRQ owner
    logic [2:0]  irq_ipl_n;
    logic        irq_vpa_n, irq_cpu_space, irq_video_pending;

    // State register
    logic [9:0]  ssreg_restore_data;
    logic        ssreg_restore_we;
    logic [63:0] ssreg_data_out;
    logic        ssreg_ack;

    // Save-memory region adapter
    logic [63:0] ssmem_data_out;
    logic        ssmem_ack, ssmem_active;
    logic        ssmem_req_valid, ssmem_rsp_ready;
    logic [2:0]  ssmem_req_region;
    logic [14:0] ssmem_req_addr;
    logic [15:0] ssmem_req_data;
    logic [1:0]  ssmem_req_we;

    // Unpacked slot request fields
    logic        slot_cmd_valid;
    logic [2:0]  slot_cmd_op;
    logic        slot_ctx_req, slot_ctx_we;
    logic [5:0]  slot_ctx_idx;
    logic [15:0] slot_ctx_data;

    // Mailbox reply fields
    logic [8:0]  mbox_state;
    logic        mbox_wait_grant;

    // Hold / permission terms
    logic        hold_request;
    logic        ordinary_ram_ok, ss_mem_admit, journal_held;
    logic        ss_addr_zero;
    logic        irq_state_load, mbox_restore, mbox_clear_ok;

    // Completion tracker
    logic        trk_prev_as_n, trk_ack, trk_claim, trk_iack7;
    logic        sel_ack_now;
    logic        bus_done, undo_ordinary_done, undo_private_iack_done;

    // Packed bundle unpacking

    assign slot_cmd_valid  = ctx_request.cmd_valid;
    assign slot_cmd_op     = ctx_request.cmd_op;
    assign slot_ctx_req    = ctx_request.ctx_req;
    assign slot_ctx_we     = ctx_request.ctx_we;
    assign slot_ctx_idx    = ctx_request.ctx_idx;
    assign slot_ctx_data   = ctx_request.ctx_data;

    assign mbox_state      = mailbox_reply.state;      // {pending IRQ, latch[7:0]}
    assign mbox_wait_grant = mailbox_reply.wait_grant;

    // CPU data/DTACK/VPA: context claim (normal AS held high), else CPU space (no DTACK, IRQ VPA), else game bus.
    assign normal_as_n = ctx_bus_claim | cpu_as_n_s;

    always_comb begin
        if (ctx_bus_claim) begin
            sel_din     = ctx_cpu_din;
            sel_dtack_n = ctx_cpu_dtack_n;
            sel_vpa_n   = ctx_cpu_vpa_n;
        end else begin
            sel_din     = bus_cpu_din;
            sel_dtack_n = irq_cpu_space ? 1'b1 : base_dtack_n;
            sel_vpa_n   = irq_vpa_n;
        end
    end

    assign cpu_fc_s = {cpu_fc2_s, cpu_fc1_s, cpu_fc0_s};

    // Pause / save boundary

    assign hold_request = pause | hold_req | ss_freeze;

    // Scheduler runs in reset; otherwise gated by service fault, context park/hold and hold request.

    assign sched_run = reset
                     | (~svc_fault
                        & (ctx_cpu_reset
                           | (~ctx_st_parked & ~ctx_st_held
                              & (svc_run | ~hold_request | ~cpu_as_n_s))));

    // Combinational: hold, phases idle, service idle, and bus idle or context parked/held.
    assign quiesced = hold_request & ~phase1 & ~phase2 & ~svc_run
                    & ((cpu_as_n_s & bus_idle) | ctx_st_parked | ctx_st_held);

    // quiesced terms without hold_request; ram_access_enable implies hold_request (asserted below).
    assign ordinary_ram_ok = ~phase1 & ~phase2 & ~svc_run
                           & ((cpu_as_n_s & bus_idle) | ctx_st_parked | ctx_st_held) & ram_access_enable;
`ifdef SIMULATION
    always @(posedge clk)
        if (!reset && ram_access_enable && !hold_request) $fatal(1, "GAREGGA_RAM_ACCESS_WITHOUT_HOLD");
`endif
    assign ss_mem_admit    = ordinary_ram_ok & ss_freeze;
    assign journal_held    = ctx_st_parked & bus_idle & ~phase1 & ~phase2;
    assign bus_ram_enable  = journal_held | ordinary_ram_ok;

    // Transfer-completion tracker (AS, selected DTACK / VPA)

    assign sel_ack_now = ~sel_dtack_n | ~sel_vpa_n;

    always_ff @(posedge clk) begin
        if (reset) begin
            trk_prev_as_n <= 1'b1;
            trk_ack       <= 1'b0;
            trk_claim     <= 1'b0;
            trk_iack7     <= 1'b0;
        end else begin
            trk_prev_as_n <= cpu_as_n_s;
            if (cpu_as_n_s) begin
                trk_ack <= 1'b0;                       // AS high clears
            end else begin
                if (sel_ack_now)
                    trk_ack <= 1'b1;                   // sticky within window
                trk_claim <= ctx_bus_claim;            // every AS-low sample
                if (trk_prev_as_n)                     // first AS-low sample only
                    trk_iack7 <= (cpu_fc_s == 3'b111) && (cpu_addr_s[3:1] == 3'b111);
            end
        end
    end

    // A remembered acknowledgement produces one completion in the first high-AS cycle.

    assign bus_done               = cpu_as_n_s & ~trk_prev_as_n & trk_ack;
    assign undo_ordinary_done     = bus_done & ~trk_claim;
    assign undo_private_iack_done = bus_done &  trk_claim & trk_iack7;

    // Context owner command / word multiplexing

    assign ctx_cmd_valid  = svc_cmd_valid | slot_cmd_valid;
    assign ctx_cmd_op     = svc_cmd_valid ? svc_cmd_op : slot_cmd_op;
    assign ctx_word_req   = svc_ctx_req | slot_ctx_req;
    assign ctx_word_idx   = svc_ctx_req ? svc_ctx_idx       : slot_ctx_idx;
    assign ctx_word_we    = svc_ctx_req ? 1'b0              : slot_ctx_we;
    assign ctx_word_bank  = svc_ctx_req ? CTX_BANK_CAPTURED : slot_ctx_we;
    assign ctx_word_wdata = slot_ctx_data;

    always_comb begin
        ctx_response           = '0;
        ctx_response.rsp_valid = ctx_rsp_valid;
        ctx_response.rsp_ok    = ctx_rsp_ok;
        ctx_response.rsp_code  = ctx_rsp_code;
        ctx_response.ctx_ack   = ctx_word_ack;
        ctx_response.ctx_nak   = ctx_word_nak;
        ctx_response.ctx_data  = ctx_word_rdata;
        ctx_response.admitted  = ctx_st_admitted;
        ctx_response.captured  = svc_save_ready;   // not the raw bank flag
    end

    assign ctx_fault       = svc_fault;
    assign ss_save_ready   = svc_save_ready;
    assign ss_save_done    = svc_save_done;
    assign ss_restore_done = svc_restore_done;
    assign ss_busy         = ctx_st_busy | svc_run;

    // State RAM port ownership: stack undo vs. normal region adapter

    assign undo_owns           = undo_valid | undo_response_ready;

    assign bus_state_active    = undo_owns | ssmem_active;
    assign bus_state_valid     = undo_owns ? undo_valid  : ssmem_req_valid;
    assign bus_state_region    = undo_owns ? UNDO_REGION : ssmem_req_region;
    assign bus_state_addr      = undo_owns ? undo_word   : ssmem_req_addr;
    assign bus_state_din       = undo_owns ? undo_data   : ssmem_req_data;
    assign bus_state_we        = undo_owns ? UNDO_LANES  : ssmem_req_we;
    assign bus_state_rsp_ready = undo_owns ? undo_response_ready : ssmem_rsp_ready;

    // Mailbox request / reply

    assign ss_addr_zero   = (ss_addr == 32'd0);
    assign irq_state_load = ssreg_restore_we & quiesced;
    assign mbox_restore   = ssreg_restore_we & quiesced & ss_freeze;
    assign mbox_clear_ok  = ~(ss_freeze & quiesced & ~svc_run);

    always_comb begin
        mailbox_request               = '0;
        mailbox_request.command_write = bus_snd_command_write;
        mailbox_request.command_data  = cpu_dout_s[7:0];
        mailbox_request.as_idle       = cpu_as_n_s;
        mailbox_request.clear_ok      = mbox_clear_ok;
        mailbox_request.restore       = mbox_restore;
        mailbox_request.state_in      = ssreg_restore_data[9:1];
        mailbox_request.wait_begin    = bus_snd_wait_begin;
        mailbox_request.wait_abandon  = bus_snd_wait_abandon;
        mailbox_request.wait_active   = bus_snd_wait_active;
    end

    assign sound_irq   = mbox_state[8];
    assign sound_latch = mbox_state[7:0];

    // Outer state response: OR of acknowledged words only

    assign ss_ack      = ssreg_ack | ssmem_ack;
    assign ss_data_out = ({64{ssreg_ack}} & ssreg_data_out)
                       | ({64{ssmem_ack}} & ssmem_data_out);

    // CPU monitor pins

    assign cpu_addr     = cpu_addr_s;
    assign cpu_as_n     = cpu_as_n_s;
    assign cpu_rw       = cpu_rw_s;
    assign cpu_uds_n    = cpu_uds_n_s;
    assign cpu_lds_n    = cpu_lds_n_s;
    assign cpu_fc       = cpu_fc_s;
    assign cpu_phase1   = phase1;
    assign cpu_phase2   = phase2;
    assign m68k_reset_n = cpu_oreset_n_s;

    // Instances

    /* verilator lint_off PINCONNECTEMPTY */
    // fx68k pins via socket sk_cpu.
    assign sk_cpu_i.clk = clk;
    assign sk_cpu_i.HALTn = 1'b1;
    assign sk_cpu_i.extReset = reset | ctx_cpu_reset;
    assign sk_cpu_i.pwrUp = reset;
    assign sk_cpu_i.enPhi1 = phase1;
    assign sk_cpu_i.enPhi2 = phase2;
    assign sk_cpu_i.DTACKn = sel_dtack_n;
    assign sk_cpu_i.VPAn = sel_vpa_n;
    assign sk_cpu_i.BERRn = 1'b1;
    assign sk_cpu_i.BRn = 1'b1;
    assign sk_cpu_i.BGACKn = 1'b1;
    assign sk_cpu_i.IPL0n = irq_ipl_n[0];
    assign sk_cpu_i.IPL1n = irq_ipl_n[1];
    assign sk_cpu_i.IPL2n = irq_ipl_n[2];
    assign sk_cpu_i.iEdb = sel_din;
    assign cpu_rw_s = sk_cpu_o.eRWn;
    assign cpu_as_n_s = sk_cpu_o.ASn;
    assign cpu_lds_n_s = sk_cpu_o.LDSn;
    assign cpu_uds_n_s = sk_cpu_o.UDSn;
    assign cpu_fc0_s = sk_cpu_o.FC0;
    assign cpu_fc1_s = sk_cpu_o.FC1;
    assign cpu_fc2_s = sk_cpu_o.FC2;
    assign cpu_oreset_n_s = sk_cpu_o.oRESETn;
    assign cpu_halted_n_s = sk_cpu_o.oHALTEDn;
    assign cpu_dout_s = sk_cpu_o.oEdb;
    assign cpu_addr_s = sk_cpu_o.eab;

    raizing_68k_bus u_phase (
        .clk       (clk),
        .reset     (reset),
        .run       (sched_run),
        .address_n (normal_as_n),
        .strobe_n  ({cpu_uds_n_s, cpu_lds_n_s}),
        .selected  (bus_selected),
        .busy      (bus_busy),
        .phase1    (phase1),
        .phase2    (phase2),
        .dtack_n   (base_dtack_n)
    );

    rzgaregga_bus u_bus (
        .sk_mem_i(sk_mem_i), .sk_mem_o(sk_mem_o),
        .clk                 (clk),
        .reset               (reset),
        .cpu_addr            (cpu_addr_s),
        .cpu_as_n            (normal_as_n),
        .cpu_rw              (cpu_rw_s),
        .cpu_uds_n           (cpu_uds_n_s),
        .cpu_lds_n           (cpu_lds_n_s),
        .cpu_fc              (cpu_fc_s),
        .cpu_dout            (cpu_dout_s),
        .block_writes        (1'b0),
        .override_valid      (1'b0),
        .cpu_din             (bus_cpu_din),
        .selected            (bus_selected),
        .busy                (bus_busy),
        .idle                (bus_idle),
        .rom_req             (rom_req),
        .rom_addr            (rom_addr),
        .rom_ok              (rom_ok),
        .rom_data            (rom_data),
        .gp_req              (gp_req),
        .gp_start            (gp_start),
        .gp_op               (gp_op),
        .gp_be               (gp_be),
        .gp_din              (gp_din),
        .gp_ack              (gp_ack),
        .gp_dout             (gp_dout),
        .vpos                (vpos),
        .status_hs_n         (status_hs_n),
        .status_vs_n         (status_vs_n),
        .status_blank_n      (status_blank_n),
        .p1_inputs           (p1_inputs),
        .p2_inputs           (p2_inputs),
        .sys_inputs          (sys_inputs),
        .dsw_a               (dsw_a),
        .dsw_b               (dsw_b),
        .dsw_c               (dsw_c),
        .pal_addr            (pal_addr),
        .pal_data            (pal_data),
        .palette_hold(palette_hold), .palette_blank(palette_blank),
        .text_addr           (text_addr),
        .text_data           (text_data),
        .select_addr         (select_addr),
        .scroll_addr         (scroll_addr),
        .select_data         (select_data),
        .scroll_data         (scroll_data),
        .z80_addr            (z80_addr),
        .z80_din             (z80_din),
        .z80_we              (z80_we),
        .z80_dout            (z80_dout),
        .ram_enable          (bus_ram_enable),
        .ram_req             (ram_req),
        .ram_region          (ram_region),
        .ram_addr            (ram_addr),
        .ram_din             (ram_din),
        .ram_we              (ram_we),
        .ram_ack             (ram_ack),
        .ram_dout            (ram_dout),
        .state_active        (bus_state_active),
        .state_valid         (bus_state_valid),
        .state_ready         (bus_state_ready),
        .state_region        (bus_state_region),
        .state_addr          (bus_state_addr),
        .state_din           (bus_state_din),
        .state_we            (bus_state_we),
        .state_rsp_valid     (bus_state_rsp_valid),
        .state_rsp_ready     (bus_state_rsp_ready),
        .state_q             (bus_state_q),
        .state_error         (bus_state_error),
        .hs_ready            (hs_ready),
        .score_base          (score_base),
        .hs_dout             (hs_dout),
        .hs_cs               (hs_cs),
        .hs_addr             (hs_addr),
        .hs_din              (hs_din),
        .hs_we               (hs_we),
        .wram_write          (wram_write),
        .wram_addr           (wram_addr),
        .wram_data           (wram_data),
        .wram_we             (wram_we),
        .sound_wait_grant    (mbox_wait_grant),
        .sound_wait_begin    (bus_snd_wait_begin),
        .sound_wait_abandon  (bus_snd_wait_abandon),
        .sound_wait_active   (bus_snd_wait_active),
        .sound_command_write (bus_snd_command_write),
        .ctx_sample_valid    (bus_sample_valid),
        .ctx_sample_word     (bus_sample_word),
        .ctx_sample_before   (bus_sample_before),
        .ctx_sample_written  (bus_sample_written)
    );

    // rzctx_core pins via socket sk_ctx.
    assign sk_ctx_i.clk = clk;
    assign sk_ctx_i.rst = reset;
    assign sk_ctx_i.cpu_tick = phase1;
    assign sk_ctx_i.ram_lo = CTX_RAM_LO_WORD;
    assign sk_ctx_i.ram_hi = CTX_RAM_HI_WORD;
    assign sk_ctx_i.cpu_as_n = cpu_as_n_s;
    assign sk_ctx_i.cpu_uds_n = cpu_uds_n_s;
    assign sk_ctx_i.cpu_lds_n = cpu_lds_n_s;
    assign sk_ctx_i.cpu_rw = cpu_rw_s;
    assign sk_ctx_i.cpu_fc = cpu_fc_s;
    assign sk_ctx_i.cpu_addr = cpu_addr_s;
    assign sk_ctx_i.cpu_dout = cpu_dout_s;
    assign sk_ctx_i.cpu_halted_n = cpu_halted_n_s;
    assign sk_ctx_i.bus_done = bus_done;
    assign sk_ctx_i.cmd_valid = ctx_cmd_valid;
    assign sk_ctx_i.cmd_op = ctx_cmd_op;
    assign sk_ctx_i.ctx_req = ctx_word_req;
    assign sk_ctx_i.ctx_we = ctx_word_we;
    assign sk_ctx_i.ctx_bank = ctx_word_bank;
    assign sk_ctx_i.ctx_idx = ctx_word_idx;
    assign sk_ctx_i.ctx_wdata = ctx_word_wdata;
    assign ctx_bus_claim = sk_ctx_o.bus_claim;
    assign ctx_cpu_dtack_n = sk_ctx_o.cpu_dtack_n;
    assign ctx_cpu_vpa_n = sk_ctx_o.cpu_vpa_n;
    assign ctx_cpu_din = sk_ctx_o.cpu_din;
    assign ctx_ipl7_req = sk_ctx_o.ipl7_req;
    assign ctx_cpu_reset = sk_ctx_o.cpu_reset;
    assign ctx_rsp_valid = sk_ctx_o.rsp_valid;
    assign ctx_rsp_ok = sk_ctx_o.rsp_ok;
    assign ctx_rsp_code = sk_ctx_o.rsp_code;
    assign ctx_word_ack = sk_ctx_o.ctx_ack;
    assign ctx_word_nak = sk_ctx_o.ctx_nak;
    assign ctx_word_rdata = sk_ctx_o.ctx_rdata;
    assign ctx_st_busy = sk_ctx_o.st_busy;
    assign ctx_st_parked = sk_ctx_o.st_parked;
    assign ctx_st_held = sk_ctx_o.st_held;
    assign ctx_st_cap_valid = sk_ctx_o.st_cap_valid;
    assign ctx_st_admitted = sk_ctx_o.st_admitted;
    assign ctx_evt_valid = sk_ctx_o.evt_valid;
    assign ctx_evt_code = sk_ctx_o.evt_code;

    rzctx_board_service u_svc (
        .clk             (clk),
        .reset           (reset),
        .save_begin      (ss_save_begin),
        .save_resume     (ss_save_resume),
        .restore_begin   (ss_restore_begin),
        .parked          (ctx_st_parked),
        .captured        (ctx_st_cap_valid),
        .admitted        (ctx_st_admitted),
        .event_valid     (ctx_evt_valid),
        .event_code      (ctx_evt_code),
        .cmd_valid       (svc_cmd_valid),
        .cmd_op          (svc_cmd_op),
        .rsp_valid       (ctx_rsp_valid),
        .rsp_ok          (ctx_rsp_ok),
        .ctx_req         (svc_ctx_req),
        .ctx_idx         (svc_ctx_idx),
        .ctx_ack         (ctx_word_ack),
        .ctx_nak         (ctx_word_nak),
        .ctx_rdata       (ctx_word_rdata),
        .journal_arm     (svc_journal_arm),
        .journal_cancel  (svc_journal_cancel),
        .journal_confirm (svc_journal_confirm),
        .journal_word    (svc_journal_word),
        .journal_pc      (svc_journal_pc),
        .journal_done    (undo_done),
        .journal_fault   (undo_fault),
        .service_run     (svc_run),
        .save_ready      (svc_save_ready),
        .save_done       (svc_save_done),
        .restore_done    (svc_restore_done),
        .fault           (svc_fault)
    );

    rzctx_stack_undo u_undo (
        .clk               (clk),
        .reset             (reset),
        .arm               (svc_journal_arm),
        .cancel            (svc_journal_cancel),
        .ordinary_done     (undo_ordinary_done),
        .private_iack_done (undo_private_iack_done),
        .sample_valid      (bus_sample_valid),
        .sample_word       (bus_sample_word),
        .sample_before     (bus_sample_before),
        .sample_written    (bus_sample_written),
        .confirm           (svc_journal_confirm),
        .frame_word        (svc_journal_word),
        .frame_pc_low      (svc_journal_pc),
        .wram_held         (journal_held),
        .undo_valid        (undo_valid),
        .undo_ready        (undo_owns & bus_state_ready),
        .undo_word         (undo_word),
        .undo_data         (undo_data),
        .response_valid    (undo_owns & bus_state_rsp_valid),
        .response_error    (bus_state_error),
        .response_ready    (undo_response_ready),
        .done              (undo_done),
        .fault             (undo_fault)
    );

    rzirq_owner #(
        .PROFILE (rzirq_pkg::RZIRQ_GAREGGA)
    ) u_irq (
        .alt_levels(1'b0),
        .clk                   (clk),
        .board_reset           (reset),
        .state_hold            (ss_freeze),
        .state_load            (irq_state_load),
        .load_video_pending    (ssreg_restore_data[0]),
        .load_previous_video_n (1'b1),
        .load_sound_pending    (1'b0),
        .gp_vint_n             (vblank_n),
        .raw_lvbl_n            (1'b1),
        .sound_irq             (1'b0),
        .sound_clear           (1'b0),
        .priv_l7               (ctx_ipl7_req),
        .cpu_as_n              (normal_as_n),
        .cpu_fc                (cpu_fc_s),
        .cpu_a                 (cpu_addr_s[3:1]),
        .irq_level             (),
        .ipl_n                 (irq_ipl_n),
        .vpa_n                 (irq_vpa_n),
        .cpu_space             (irq_cpu_space),
        .video_pending         (irq_video_pending),
        .previous_video_n      (),
        .sound_pending         (),
        .owned_fields          (),
        .unsupported           ()
    );

    raizing_ss_register #(
        .WIDTH    (10),
        .SS_INDEX (10)
    ) u_ss_reg (
        .clk          (clk),
        .reset        (reset),
        .capture_data ({mbox_state, irq_video_pending}),
        .restore_data (ssreg_restore_data),
        .restore_we   (ssreg_restore_we),
        .ss_data      (ss_data),
        .ss_select    (ss_select),
        .ss_write     (ss_write & ss_addr_zero & ss_freeze & quiesced),
        .ss_read      (ss_read & ss_addr_zero),
        .ss_query     (ss_query),
        .ss_data_out  (ssreg_data_out),
        .ss_ack       (ssreg_ack)
    );

    rzmem_ss_regions u_ss_mem (
        .clk           (clk),
        .reset         (reset),
        .access_enable (ss_mem_admit),
        .ss_data       (ss_data),
        .ss_addr       (ss_addr),
        .ss_select     (ss_select),
        .ss_write      (ss_write),
        .ss_read       (ss_read),
        .ss_query      (ss_query),
        .ss_data_out   (ssmem_data_out),
        .ss_ack        (ssmem_ack),
        .active        (ssmem_active),
        .req_valid     (ssmem_req_valid),
        .req_ready     (~undo_owns & bus_state_ready),
        .req_region    (ssmem_req_region),
        .req_addr      (ssmem_req_addr),
        .req_data      (ssmem_req_data),
        .req_we        (ssmem_req_we),
        .rsp_valid     (~undo_owns & bus_state_rsp_valid),
        .rsp_ready     (ssmem_rsp_ready),
        .rsp_data      (bus_state_q),
        .rsp_error     (bus_state_error)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // ss_restore_window and mailbox_reply.wait_level are unused.

    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_inputs;
    assign unused_inputs = ss_restore_window ^ mailbox_reply.wait_level;
    /* verilator lint_on UNUSEDSIGNAL */

    // Simulation-only owner collision checks.

`ifndef SYNTHESIS
    // synthesis translate_off
    int unsigned sim_cmd_collisions;   // service + slot command, same cycle
    int unsigned sim_word_collisions;  // service read + slot word request
    int unsigned sim_owner_overlaps;   // undo ownership + normal state-active

    initial begin
        sim_cmd_collisions  = 0;
        sim_word_collisions = 0;
        sim_owner_overlaps  = 0;
    end

    always @(posedge clk) begin
        if (svc_cmd_valid === 1'b1 && slot_cmd_valid === 1'b1) begin
            sim_cmd_collisions <= sim_cmd_collisions + 1;
            $error("rzgaregga_main_cpu: invalid parent behaviour at %0t: service and slot context commands collide (service op %0d is used)",
                   $time, svc_cmd_op);
        end
        if (svc_ctx_req === 1'b1 && slot_ctx_req === 1'b1) begin
            sim_word_collisions <= sim_word_collisions + 1;
            $error("rzgaregga_main_cpu: invalid parent behaviour at %0t: service read and slot word request collide (service index %0d is used)",
                   $time, svc_ctx_idx);
        end
        if (undo_owns === 1'b1 && ssmem_active === 1'b1) begin
            sim_owner_overlaps <= sim_owner_overlaps + 1;
            $error("rzgaregga_main_cpu: invalid parent behaviour at %0t: stack undo owns the state RAM port while the region adapter is active",
                   $time);
        end
    end
    // synthesis translate_on
`endif

endmodule

// Garegga board top: CPU, sound, video, score and input endpoints; only the GP state hold is registered.

`default_nettype none

module rzgaregga_board (
    output raizing_socket_pkg::ctx_in_t sk_ctx_i,
    input raizing_socket_pkg::ctx_out_t sk_ctx_o,

    output raizing_socket_pkg::z80_in_t sk_z80_i,
    input raizing_socket_pkg::z80_out_t sk_z80_o,
    output raizing_socket_pkg::fm_in_t sk_fm_i,
    input raizing_socket_pkg::fm_out_t sk_fm_o,
    output raizing_socket_pkg::oki_in_t sk_oki_i,
    input raizing_socket_pkg::oki_out_t sk_oki_o,

    output raizing_socket_pkg::cpu_in_t sk_cpu_i,
    input raizing_socket_pkg::cpu_out_t sk_cpu_o,
    output raizing_socket_pkg::mem_in_t sk_mem_i,
    input raizing_socket_pkg::mem_out_t sk_mem_o,

    output raizing_socket_pkg::video_in_t sk_video_i,
    input raizing_socket_pkg::video_out_t sk_video_o,

  // --- clock, resets, clock enables (single 81 MHz SYS clock) ---------------
  input  wire logic                      clk,
  input  wire logic                      reset,           // game reset
  input  wire logic                      platform_reset,  // lifetime reset (score)
  input  wire logic                      pixel_ce,
  input  wire logic                      z80_ce,
  input  wire logic                      ym_ce,
  input  wire logic                      ym_phase1_ce,
  input  wire logic                      oki_ce,
  // --- pause / hold / freeze -------------------------------------------------
  input  wire logic                      user_pause,
  input  wire logic                      cpu_hold,
  input  wire logic                      sound_hold,
  input  wire logic                      video_hold,
  input  wire logic                      ram_access_enable,
  input  wire logic                      ss_freeze,
  // --- CPU context transport (opaque) ---------------------------------------
  input  rzctx_slot_pkg::request_t       ctx_request,
  output rzctx_slot_pkg::response_t      ctx_response,
  output wire logic                      ctx_fault,
  // --- save/restore handler controls and status -----------------------------
  input  wire logic                      save_begin,
  input  wire logic                      save_resume,
  input  wire logic                      restore_begin,
  input  wire logic                      restore_window,
  input  wire logic                      audio_restore,
  output wire logic                      cpu_quiesced,
  output wire logic                      sound_held,
  output wire logic                      video_held,
  output wire logic                      save_ready,
  output wire logic                      save_done,
  output wire logic                      restore_done,
  output wire logic                      handler_busy,
  // --- cabinet (active-low bundle, forwarded to rzboard_inputs) -------------
  input  wire logic [1:0][9:0]           joy,             // joy[0]=P1, joy[1]=P2
  input  wire logic [1:0]                start_button,
  input  wire logic [1:0]                coin,
  input  wire logic                      service,
  input  wire logic [7:0]                dsw_a,
  input  wire logic [7:0]                dsw_b,
  input  wire logic [7:0]                dsw_c,
  // --- ROM identity (score binding) ------------------------------------------
  input  wire logic [31:0]               rom_crc,
  input  wire logic [31:0]               rom_length,
  input  wire logic                      rom_valid,
  // --- audio configuration ---------------------------------------------------
  input  wire logic [1:0]                fx_level,
  input  wire logic                      fm_enable,
  input  wire logic                      pcm_enable,
  // --- level ROM transport: 7 lanes, 23-bit byte address, 32-bit data --------
  output wire logic [6:0]                rom_request,
  output wire logic [160:0]              rom_address,
  input  wire logic [223:0]              rom_data,
  input  wire logic [6:0]                rom_ok,
  // --- object channel (memory port 3, ready/valid) ---------------------------
  output wire logic                      object_req_valid,
  input  wire logic                      object_req_ready,
  output wire logic [22:0]               object_req_addr,
  input  wire logic                      object_rsp_valid,
  output wire logic                      object_rsp_ready,
  input  wire logic [31:0]               object_rsp_data,
  input  wire logic                      object_rsp_error,
  input  tri1                            object_port_idle,  // pullup
  // --- text/font ROM ---------------------------------------------------------
  output wire logic [13:0]               text_rom_addr,
  input  wire logic [15:0]               text_rom_data,
  // --- video / audio out -----------------------------------------------------
  output wire logic [7:0]                red,
  output wire logic [7:0]                green,
  output wire logic [7:0]                blue,
  output wire logic                      lhbl,
  output wire logic                      lvbl,
  output wire logic [8:0]                hcount,
  output wire logic [8:0]                vcount,
  output wire logic signed [15:0]        audio,
  // --- NV / high-score file --------------------------------------------------
  input  wire logic                      nv_download,
  input  wire logic                      nv_upload,
  input  wire logic                      nv_write,
  input  wire logic                      nv_read,
  input  wire logic [26:0]               nv_addr,
  input  wire logic [7:0]                nv_data,
  output wire logic [7:0]                nv_q,
  output wire logic                      nv_wait,
  output wire logic                      nv_request,
  output wire logic                      highscore_busy,
  input  wire logic                      nv_manual,
  input  wire logic                      nv_autosave,
  input  wire logic                      osd_open,
  // --- save-state transaction and bus ---------------------------------------
  input  wire logic                      state_active,
  input  wire logic [63:0]               SS_DATA,
  input  wire logic [31:0]               SS_ADDR,
  input  wire logic [7:0]                SS_SELECT,
  input  wire logic                      SS_WRITE,
  input  wire logic                      SS_READ,
  input  wire logic                      SS_QUERY,
  output wire logic [63:0]               SS_DATA_OUT,
  output wire logic                      SS_ACK,
  // --- faults -----------------------------------------------------------------
  output wire logic                      video_error,
  output wire logic                      sound_state_fault
);
  localparam raizing_board_pkg::board_e VIDEO_BOARD = raizing_board_pkg::RZB_GAREGGA;

  // ROM lanes: seven 23-bit byte addresses and seven 32-bit data words, lane 0 in the LSBs.
  localparam int LANE_AW   = 23;
  localparam int LANE_DW   = 32;
  localparam int LANE_CPU  = 0;   // CPU program  : 19-bit word address (x2), low 16 bits
  localparam int LANE_Z80  = 1;   // Z80 program  : 17-bit byte address,      low 8 bits
  localparam int LANE_PCM  = 2;   // sound PCM    : 20-bit byte address,      low 8 bits
  localparam int LANE_GFX0 = 3;   // video gfx    : local lanes 0..3 -> host lanes 3..6
  localparam int GFX_LANES = 4;
  localparam int GFX_AW    = 22;  //                22-bit word address (x2), all 32 bits

  // CPU status sync windows (H and V counts).
  localparam logic [8:0] CPU_STATUS_H_START = 9'd325;
  localparam logic [8:0] CPU_STATUS_H_END   = 9'd380;
  localparam logic [8:0] CPU_STATUS_V_START = 9'd232;
  localparam logic [8:0] CPU_STATUS_V_END   = 9'd245;

  // GP operation codes on the CPU endpoint's gp_op. 3'd6 and 3'd7 select none.
  localparam logic [2:0] GP_OP_SET_PTR    = 3'd0;  // select pointer
  localparam logic [2:0] GP_OP_WRITE_RAM  = 3'd1;  // VRAM write
  localparam logic [2:0] GP_OP_READ_HIGH  = 3'd2;  // high-port read
  localparam logic [2:0] GP_OP_READ_LOW   = 3'd3;  // low-port read
  localparam logic [2:0] GP_OP_SELECT_REG = 3'd4;  // register select
  localparam logic [2:0] GP_OP_WRITE_REG  = 3'd5;  // register write

  // rzboard_inputs profile used by Garegga.
  localparam int INPUT_PROFILE = 2;

  // Endpoint interconnect

  // --- CPU endpoint outputs ----------------------------------------------------
  wire logic        cpu_rom_req;
  wire logic [18:0] cpu_rom_addr;
  wire logic        cpu_gp_req;
  wire logic [2:0]  cpu_gp_op;
  wire logic [1:0]  cpu_gp_be;
  wire logic [15:0] cpu_gp_din;
  wire logic [15:0] cpu_pal_data;
  wire logic palette_hold, palette_blank;
  wire logic [15:0] cpu_text_data;
  wire logic [15:0] cpu_select_data;
  wire logic [15:0] cpu_scroll_data;
  wire logic [7:0]  cpu_z80_dout;
  wire logic [6:0]  cpu_hs_addr;
  wire logic [15:0] cpu_hs_din;
  wire logic [1:0]  cpu_hs_we;
  wire logic        cpu_wram_write;
  wire logic [15:0] cpu_wram_addr;
  wire logic [15:0] cpu_wram_data;
  wire logic [1:0]  cpu_wram_we;
  wire logic [63:0] cpu_ss_data_out;
  wire logic        cpu_ss_ack;
  rzgaregga_mbox_pkg::request_t  mbox_request;   // CPU -> sound (opaque)

  // --- sound endpoint outputs --------------------------------------------------
  rzgaregga_mbox_pkg::response_t mbox_reply;     // sound -> CPU (opaque)
  wire logic        snd_canonical_ready;
  wire logic [16:0] snd_rom_address;
  wire logic        snd_rom_request;
  wire logic [12:0] snd_shared_address;
  wire logic [7:0]  snd_shared_data_out;
  wire logic        snd_shared_write;
  wire logic [19:0] snd_pcm_address;
  wire logic        snd_pcm_request;
  wire logic [63:0] snd_ss_data_out;
  wire logic        snd_ss_ack;

  // --- video endpoint outputs --------------------------------------------------
  wire logic        vid_gp_ack;
  wire logic [15:0] vid_gp_dout;
  wire logic        vid_vint_n;
  wire logic        vid_cpu_hsync_n;
  wire logic        vid_cpu_vsync_n;
  wire logic        vid_cpu_fblank;
  wire logic [8:0]  vid_vcount;
  wire logic [3:0]  vid_gfx_req;
  wire logic [87:0] vid_gfx_addr;
  wire logic        vid_object_error;
  wire logic [10:0] vid_palram_addr;
  wire logic [11:0] vid_textvram_addr;
  wire logic [7:0]  vid_textselect_addr;
  wire logic [7:0]  vid_textscroll_addr;
  wire logic        vid_ss_quiesced;
  wire logic [63:0] vid_ss_data_out;
  wire logic        vid_ss_ack;
  wire logic        vid_ss_error;

  // --- score binding outputs ---------------------------------------------------
  wire logic [15:0] hs_score_base;
  wire logic        hs_ready;
  wire logic [15:0] hs_cpu_q;
  wire logic        hs_hold_request;
  wire logic [63:0] hs_ss_data_out;
  wire logic        hs_ss_ack;

  // --- input decoder outputs ---------------------------------------------------
  wire logic [7:0]  inp_player1;
  wire logic [7:0]  inp_player2;
  wire logic [7:0]  inp_system;

  // Hold / readiness

  // user_pause reaches the CPU on its pause input.
  wire logic cpu_hold_request = cpu_hold | hs_hold_request;

  wire logic snd_hold_request = sound_hold | user_pause;

  assign sound_held = state_active && snd_canonical_ready;

  assign video_held = vid_ss_quiesced;

  assign video_error = vid_ss_error | vid_object_error;

  // GP state hold: set on video quiescence during a state transaction, cleared on reset or transaction end.
  logic gp_state_hold = 1'b0;

  always_ff @(posedge clk) begin
    if (reset || !state_active)
      gp_state_hold <= 1'b0;
    else if (vid_ss_quiesced)
      gp_state_hold <= 1'b1;
  end

  // Level ROM transport

  // Word addresses become zero-extended byte addresses.
  wire logic [LANE_AW-1:0] lane_addr_cpu  = {3'b000, cpu_rom_addr, 1'b0};     // word -> byte
  wire logic [LANE_AW-1:0] lane_addr_z80  = {6'b00_0000, snd_rom_address};    // byte
  wire logic [LANE_AW-1:0] lane_addr_pcm  = {3'b000, snd_pcm_address};        // byte
  wire logic [LANE_AW-1:0] lane_addr_gfx0 = {vid_gfx_addr[0*GFX_AW +: GFX_AW], 1'b0};
  wire logic [LANE_AW-1:0] lane_addr_gfx1 = {vid_gfx_addr[1*GFX_AW +: GFX_AW], 1'b0};
  wire logic [LANE_AW-1:0] lane_addr_gfx2 = {vid_gfx_addr[2*GFX_AW +: GFX_AW], 1'b0};
  wire logic [LANE_AW-1:0] lane_addr_gfx3 = {vid_gfx_addr[3*GFX_AW +: GFX_AW], 1'b0};

  assign rom_address = {lane_addr_gfx3, lane_addr_gfx2, lane_addr_gfx1, lane_addr_gfx0,
                        lane_addr_pcm, lane_addr_z80, lane_addr_cpu};

  // PCM request is gated during game reset.
  wire logic lane_req_pcm = snd_pcm_request & ~reset;

  assign rom_request = {vid_gfx_req, lane_req_pcm, snd_rom_request, cpu_rom_req};

  // GP operation decode (CS is cpu_gp_req)

  wire logic gp_set_ram_ptr = (cpu_gp_op == GP_OP_SET_PTR);
  wire logic gp_write_ram   = (cpu_gp_op == GP_OP_WRITE_RAM);
  wire logic gp_read_ram_h  = (cpu_gp_op == GP_OP_READ_HIGH);
  wire logic gp_read_ram_l  = (cpu_gp_op == GP_OP_READ_LOW);
  wire logic gp_select_reg  = (cpu_gp_op == GP_OP_SELECT_REG);
  wire logic gp_write_reg   = (cpu_gp_op == GP_OP_WRITE_REG);

  // Save-state response: OR of acknowledged providers.
  assign SS_ACK      = cpu_ss_ack | snd_ss_ack | vid_ss_ack | hs_ss_ack;
  assign SS_DATA_OUT = ({64{cpu_ss_ack}} & cpu_ss_data_out)
                     | ({64{snd_ss_ack}} & snd_ss_data_out)
                     | ({64{vid_ss_ack}} & vid_ss_data_out)
                     | ({64{hs_ss_ack}}  & hs_ss_data_out);

  // Main CPU

  rzgaregga_main_cpu u_cpu (
        .sk_ctx_i(sk_ctx_i), .sk_ctx_o(sk_ctx_o),
        .sk_cpu_i(sk_cpu_i), .sk_cpu_o(sk_cpu_o),
        .sk_mem_i(sk_mem_i), .sk_mem_o(sk_mem_o),
    .clk               (clk),
    .reset             (reset),
    .pause             (user_pause),
    .hold_req          (cpu_hold_request),
    .ss_freeze         (ss_freeze),
    .quiesced          (cpu_quiesced),
    // program ROM, host lane 0
    .rom_req           (cpu_rom_req),
    .rom_addr          (cpu_rom_addr),
    .rom_ok            (rom_ok[LANE_CPU]),
    .rom_data          (rom_data[LANE_CPU*LANE_DW +: 16]),
    // GP (video) port
    .gp_req            (cpu_gp_req),
    .gp_start          (),                    // unused
    .gp_op             (cpu_gp_op),
    .gp_be             (cpu_gp_be),
    .gp_din            (cpu_gp_din),
    .gp_ack            (vid_gp_ack),
    .gp_dout           (vid_gp_dout),
    // video timing / CPU-facing status
    .vblank_n          (vid_vint_n),
    .vpos              (vid_vcount),
    .status_hs_n       (vid_cpu_hsync_n),
    .status_vs_n       (vid_cpu_vsync_n),
    .status_blank_n    (vid_cpu_fblank),
    // decoded cabinet bytes and raw DIP bytes
    .p1_inputs         (inp_player1),
    .p2_inputs         (inp_player2),
    .sys_inputs        (inp_system),
    .dsw_a             (dsw_a),
    .dsw_b             (dsw_b),
    .dsw_c             (dsw_c),
    // memory views: video addresses, CPU data
    .pal_addr          (vid_palram_addr),
    .pal_data          (cpu_pal_data),
    .palette_hold(palette_hold), .palette_blank(palette_blank),
    .text_addr         (vid_textvram_addr),
    .text_data         (cpu_text_data),
    .select_addr       (vid_textselect_addr),
    .scroll_addr       (vid_textscroll_addr),
    .select_data       (cpu_select_data),
    .scroll_data       (cpu_scroll_data),
    // Z80 shared memory (sound is the requester)
    .z80_addr          (snd_shared_address),
    .z80_din           (snd_shared_data_out),
    .z80_we            (snd_shared_write),
    .z80_dout          (cpu_z80_dout),
    // external RAM command port: unused
    .ram_req           (1'b0),
    .ram_access_enable (ram_access_enable),
    .ram_region        (3'b000),
    .ram_addr          (15'h0000),
    .ram_din           (16'h0000),
    .ram_we            (2'b00),
    .ram_ack           (),
    .ram_dout          (),
    // score overlay and committed WRAM writes
    .hs_ready          (hs_ready),
    .score_base        (hs_score_base),
    .hs_dout           (hs_cpu_q),
    .hs_cs             (),                    // binding has no CS input
    .hs_addr           (cpu_hs_addr),
    .hs_din            (cpu_hs_din),
    .hs_we             (cpu_hs_we),
    .wram_write        (cpu_wram_write),
    .wram_addr         (cpu_wram_addr),
    .wram_data         (cpu_wram_data),
    .wram_we           (cpu_wram_we),
    // unused reset / latch / IRQ outputs
    .m68k_reset_n      (),
    .sound_latch       (),
    .sound_irq         (),
    // mailbox (opaque)
    .mailbox_request   (mbox_request),
    .mailbox_reply     (mbox_reply),
    // CPU context transport (opaque) and handler controls/status
    .ctx_request       (ctx_request),
    .ctx_response      (ctx_response),
    .ctx_fault         (ctx_fault),
    .ss_save_begin     (save_begin),
    .ss_save_resume    (save_resume),
    .ss_restore_begin  (restore_begin),
    .ss_restore_window (restore_window),
    .ss_save_ready     (save_ready),
    .ss_save_done      (save_done),
    .ss_restore_done   (restore_done),
    .ss_busy           (handler_busy),
    // save-state bus (broadcast)
    .ss_data           (SS_DATA),
    .ss_addr           (SS_ADDR),
    .ss_select         (SS_SELECT),
    .ss_write          (SS_WRITE),
    .ss_read           (SS_READ),
    .ss_query          (SS_QUERY),
    .ss_data_out       (cpu_ss_data_out),
    .ss_ack            (cpu_ss_ack),
    // unused bus monitor
    .cpu_addr          (),
    .cpu_as_n          (),
    .cpu_rw            (),
    .cpu_uds_n         (),
    .cpu_lds_n         (),
    .cpu_fc            (),
    .cpu_phase1        (),
    .cpu_phase2        ()
  );

  // Sound

  rzgaregga_sound u_sound (
        .sk_z80_i(sk_z80_i), .sk_z80_o(sk_z80_o),
        .sk_fm_i(sk_fm_i), .sk_fm_o(sk_fm_o),
        .sk_oki_i(sk_oki_i), .sk_oki_o(sk_oki_o),
    .clk               (clk),
    .reset             (reset),
    .z80_ce            (z80_ce),
    .ym_ce             (ym_ce),
    .ym_phase1_ce      (ym_phase1_ce),
    .oki_ce            (oki_ce),
    // mailbox (opaque)
    .mailbox_request   (mbox_request),
    .mailbox_reply     (mbox_reply),
    .sound_wait        (),                    // monitor
    // hold / canonical state
    .hold_request      (snd_hold_request),
    .canonical_hold    (state_active),
    .restore_commit    (audio_restore),
    .held              (),
    .replay_busy       (),                    // monitor
    .restore_busy      (),                    // monitor
    .canonical_ready   (snd_canonical_ready),
    .canonical_fault   (sound_state_fault),
    .canonical_service (),                    // monitor
    // Z80 program ROM, host lane 1
    .rom_address       (snd_rom_address),
    .rom_request       (snd_rom_request),
    .rom_data          (rom_data[LANE_Z80*LANE_DW +: 8]),
    .rom_ok            (rom_ok[LANE_Z80]),
    // Z80 shared memory into CPU memory
    .shared_address    (snd_shared_address),
    .shared_data_out   (snd_shared_data_out),
    .shared_write      (snd_shared_write),
    .shared_data_in    (cpu_z80_dout),
    // PCM ROM, host lane 2
    .pcm_address       (snd_pcm_address),
    .pcm_request       (snd_pcm_request),
    .pcm_frozen        (),                    // monitor
    .pcm_resume_busy   (),                    // monitor
    .pcm_data          (rom_data[LANE_PCM*LANE_DW +: 8]),
    .pcm_ok            (rom_ok[LANE_PCM]),
    // audio out / configuration
    .audio             (audio),
    .sample            (),                    // monitor strobe
    .fx_level          (fx_level),
    .fm_enable         (fm_enable),
    .pcm_enable        (pcm_enable),
    // save-state bus (broadcast)
    .SS_DATA           (SS_DATA),
    .SS_ADDR           (SS_ADDR),
    .SS_SELECT         (SS_SELECT),
    .SS_WRITE          (SS_WRITE),
    .SS_READ           (SS_READ),
    .SS_QUERY          (SS_QUERY),
    .SS_DATA_OUT       (snd_ss_data_out),
    .SS_ACK            (snd_ss_ack)
  );

  // raizing_video pins via socket sk_video.
    assign sk_video_i.clk = clk;
    assign sk_video_i.reset = reset;
    assign sk_video_i.pixel_ce = pixel_ce;
    assign sk_video_i.flip = 1'b0;
    assign sk_video_i.hs_start = CPU_STATUS_H_START;
    assign sk_video_i.hs_end = CPU_STATUS_H_END;
    assign sk_video_i.vs_start = CPU_STATUS_V_START;
    assign sk_video_i.vs_end = CPU_STATUS_V_END;
    assign sk_video_i.gp_cs = cpu_gp_req;
    assign sk_video_i.gp_select_reg = gp_select_reg;
    assign sk_video_i.gp_write_reg = gp_write_reg;
    assign sk_video_i.gp_write_ram = gp_write_ram;
    assign sk_video_i.gp_read_ram_h = gp_read_ram_h;
    assign sk_video_i.gp_read_ram_l = gp_read_ram_l;
    assign sk_video_i.gp_set_ram_ptr = gp_set_ram_ptr;
    assign sk_video_i.gp_din = cpu_gp_din;
    assign sk_video_i.gp_be = cpu_gp_be;
    assign sk_video_i.gfx_data = rom_data[LANE_GFX0*LANE_DW +: GFX_LANES*LANE_DW];
    assign sk_video_i.gfx_ok = rom_ok[LANE_GFX0 +: GFX_LANES];
    assign sk_video_i.object_req_ready = object_req_ready;
    assign sk_video_i.object_rsp_valid = object_rsp_valid;
    assign sk_video_i.object_rsp_data = object_rsp_data;
    assign sk_video_i.object_rsp_error = object_rsp_error;
    assign sk_video_i.object_port_idle = object_port_idle;
    assign sk_video_i.gp_objectbank_wr = 1'b0;   // no object-bank register on this board
    assign sk_video_i.gp_objectbank_slot = 3'd0;
    assign sk_video_i.PALRAM_DATA = cpu_pal_data;
    assign sk_video_i.TEXTROM_DATA = text_rom_data;
    assign sk_video_i.TEXTVRAM_DATA = cpu_text_data;
    assign sk_video_i.TEXTSELECT_DATA = cpu_select_data;
    assign sk_video_i.TEXTSCROLL_DATA = cpu_scroll_data;
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
    assign vid_cpu_hsync_n = sk_video_o.cpu_hsync_n;
    assign vid_cpu_vsync_n = sk_video_o.cpu_vsync_n;
    assign vid_cpu_fblank = sk_video_o.cpu_fblank;
    assign hcount = sk_video_o.hcount;
    assign vid_vcount = sk_video_o.vcount;
    assign vid_gfx_req = sk_video_o.gfx_req;
    // Video gfx address lanes are 24 bits; Garegga uses the low 22.
    assign vid_gfx_addr = {sk_video_o.gfx_addr[3*24 +: 22], sk_video_o.gfx_addr[2*24 +: 22], sk_video_o.gfx_addr[1*24 +: 22], sk_video_o.gfx_addr[0 +: 22]};
    assign object_req_valid = sk_video_o.object_req_valid;
    assign object_req_addr = sk_video_o.object_req_addr[22:0];
    assign object_rsp_ready = sk_video_o.object_rsp_ready;
    assign vid_object_error = sk_video_o.object_error;
    assign vid_palram_addr = sk_video_o.PALRAM_ADDR;
    assign text_rom_addr = sk_video_o.TEXTROM_ADDR;
    assign vid_textvram_addr = sk_video_o.TEXTVRAM_ADDR;
    assign vid_textselect_addr = sk_video_o.TEXTSELECT_ADDR;
    assign vid_textscroll_addr = sk_video_o.TEXTSCROLL_ADDR;
    assign red = sk_video_o.red;
    assign green = sk_video_o.green;
    assign blue = sk_video_o.blue;
    assign lhbl = sk_video_o.lhbl_dly;
    assign lvbl = sk_video_o.lvbl_dly;
    assign vid_ss_quiesced = sk_video_o.SS_QUIESCED;
    assign vid_ss_data_out = sk_video_o.SS_DATA_OUT;
    assign vid_ss_ack = sk_video_o.SS_ACK;
    assign vid_ss_error = sk_video_o.SS_ERROR;
    assign palette_hold = sk_video_o.palette_hold;
    assign palette_blank = sk_video_o.palette_blank;

  assign vcount = vid_vcount;

  // Score binding

  rzgaregga_score_binding #(.STABLE_ROM_EPOCH(1'b1)) u_score (
    .clk               (clk),
    .reset             (platform_reset),      // lifetime state
    .cpu_reset         (reset),               // game reset
    .rom_crc           (rom_crc),
    .rom_length        (rom_length),
    .rom_valid         (rom_valid),
    .score_base        (hs_score_base),
    .nv_download       (nv_download),
    .nv_upload         (nv_upload),
    .nv_write          (nv_write),
    .nv_read           (nv_read),
    .nv_addr           (nv_addr),
    .nv_data           (nv_data),
    .nv_q              (nv_q),
    .nv_wait           (nv_wait),
    .manual_save       (nv_manual),
    .autosave          (nv_autosave),
    .osd_open          (osd_open),
    .upload_request    (nv_request),
    .normal_write      (cpu_wram_write),
    .normal_addr       (cpu_wram_addr),
    .normal_data       (cpu_wram_data),
    .normal_we         (cpu_wram_we),
    .ready             (hs_ready),
    .cpu_addr          (cpu_hs_addr),
    .cpu_data          (cpu_hs_din),
    .cpu_we            (cpu_hs_we),
    .cpu_q             (hs_cpu_q),
    .state_active      (state_active),
    .hold_ack          (cpu_quiesced),
    .hold_request      (hs_hold_request),
    .active            (highscore_busy),
    .dirty             (),                    // unused
    .SS_DATA           (SS_DATA),
    .SS_ADDR           (SS_ADDR),
    .SS_SELECT         (SS_SELECT),
    .SS_WRITE          (SS_WRITE),
    .SS_READ           (SS_READ),
    .SS_QUERY          (SS_QUERY),
    .SS_DATA_OUT       (hs_ss_data_out),
    .SS_ACK            (hs_ss_ack)
  );

  // Cabinet input decoder

  rzboard_inputs #(
    .PROFILE           (INPUT_PROFILE)
  ) u_inputs (
    .player1_n         (joy[0]),
    .player2_n         (joy[1]),
    .start_n           (start_button),
    .coin_n            (coin),
    .service_n         (service),
    .dip_a             (dsw_a),
    .player1           (inp_player1),
    .player2           (inp_player2),
    .system_inputs     (inp_system)
  );

endmodule

`default_nettype wire

`default_nettype wire
