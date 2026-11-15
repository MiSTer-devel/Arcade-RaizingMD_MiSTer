// SPDX-License-Identifier: GPL-3.0-or-later
// 68000 bus router and address maps, peripherals, score window and work-RAM owner.

// Endpoint, completion-kind and window types for the bus router.
`default_nettype none

package rzbus_pkg;

  // EP_UNMAPPED: fallback owner for unsupported accesses; EP_CPU_SPACE: FC=7 interrupt acknowledge.
  localparam int NEP  = 40;
  localparam int EPW  = 6;
  localparam int IDXW = 23;   // word index width (addr[23:1])

  typedef enum logic [EPW-1:0] {
    EP_UNMAPPED              = 6'd0,
    EP_CPU_SPACE             = 6'd1,
    EP_CPU_ROM               = 6'd2,
    EP_WORK_RAM              = 6'd3,
    EP_WORK_RAM_UPPER        = 6'd4,
    EP_SHARED_RAM            = 6'd5,
    EP_INPUT_P1              = 6'd6,
    EP_INPUT_P2              = 6'd7,
    EP_INPUT_SYSTEM          = 6'd8,
    EP_DIP_A                 = 6'd9,
    EP_DIP_B                 = 6'd10,
    EP_REGION_JUMPERS        = 6'd11,
    EP_INPUT_PLAYERS         = 6'd12,
    EP_INPUT_SYSTEM_DIP      = 6'd13,
    EP_DIP_REMAINING         = 6'd14,
    EP_GP_STATUS             = 6'd15,
    EP_GP_REGISTERS          = 6'd16,
    EP_PALETTE_RAM           = 6'd17,
    EP_UNUSED_PALETTE_RAM    = 6'd18,
    EP_TEXT_MAP              = 6'd19,
    EP_TEXT_SELECT           = 6'd20,
    EP_TEXT_SCROLL           = 6'd21,
    EP_TEXT_WORK_RAM         = 6'd22,
    EP_COIN_CONTROL          = 6'd23,
    EP_COIN_OKI_BANK_CONTROL = 6'd24,
    EP_SOUND_COMMAND         = 6'd25,
    EP_SOUND_ROM             = 6'd26,
    EP_SOUND_REPLY_0         = 6'd27,
    EP_SOUND_REPLY_1         = 6'd28,
    EP_SOUND_BUSACK          = 6'd29,
    EP_SOUND_COMMAND_0       = 6'd30,
    EP_SOUND_COMMAND_1       = 6'd31,
    EP_SOUND_UNKNOWN         = 6'd32,
    EP_SOUND_IRQ_ACK         = 6'd33,
    EP_SOUND_BUSREQ          = 6'd34,
    EP_DMA_TEXT_GFX          = 6'd35,
    EP_DMA_PALETTE_TEXT      = 6'd36,
    EP_OBJECT_BANK           = 6'd37,
    EP_EEPROM_BUSACK         = 6'd38,
    EP_EEPROM_CONTROL        = 6'd39
  } ep_e;

  // Completion kind returned with every response.
  typedef enum logic [1:0] {
    KIND_ENDPOINT  = 2'd0,   // a board window answered
    KIND_UNMAPPED  = 2'd1,   // the external fallback owner answered
    KIND_CPU_SPACE = 2'd2,   // the FC=7 service answered
    KIND_FAULT     = 2'd3    // protocol fault, completed without an endpoint command
  } kind_e;

  // Reason carried with an EP_UNMAPPED request (0 when the request is mapped).
  localparam logic [1:0] REASON_NO_WINDOW = 2'd0;
  localparam logic [1:0] REASON_DIRECTION = 2'd1;
  localparam logic [1:0] REASON_LANES     = 2'd2;
  localparam logic [1:0] REASON_PROFILE   = 2'd3;

  // Profile IDs (PROFILE string -> id).
  localparam int PID_NONE     = 0;
  localparam int PID_SORCER   = 1;
  localparam int PID_KINGDOM  = 2;
  localparam int PID_GAREGGA  = 3;
  localparam int PID_BATRIDER = 4;
  localparam int PID_BAKRAID  = 5;

  // Window lookup result for one word address.
  typedef struct packed {
    logic            hit;
    logic [1:0]      lanes;   // lanes physically connected: 2'b11 or 2'b01
    ep_e             rd_ep;   // EP_UNMAPPED when the window has no read path
    ep_e             wr_ep;   // EP_UNMAPPED when the window has no write path
    logic [IDXW-1:0] base;    // first word address of the window
    logic [IDXW-1:0] xr;      // index XOR applied after the base subtraction
  } win_t;

  // No hit; both endpoints decode as EP_UNMAPPED.
  localparam win_t WIN_NONE = '0;

endpackage

`default_nettype wire

// Per-profile address windows; comment bounds are inclusive byte addresses, aw = addr[23:1].
`default_nettype none

package rzbus_map_pkg;
  import rzbus_pkg::*;

  // ---- sorcer: 18 windows ----
  function automatic win_t win_sorcer(input logic [IDXW-1:0] aw);
    win_t w;
    w = WIN_NONE;
    // 000000..07ffff rd=cpu_rom wr=- lanes=3 xor=0
    if ((aw & 23'h7c0000) == 23'h000000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_CPU_ROM; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h000000; w.xr = 23'h000000;
    end
    // 100000..10ffff rd=work_ram wr=work_ram lanes=3 xor=0
    if ((aw & 23'h7f8000) == 23'h080000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_WORK_RAM; w.wr_ep = EP_WORK_RAM;
      w.base = 23'h080000; w.xr = 23'h000000;
    end
    // 218000..21bfff rd=shared_ram wr=shared_ram lanes=1 xor=0
    if ((aw & 23'h7fe000) == 23'h10c000) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_SHARED_RAM; w.wr_ep = EP_SHARED_RAM;
      w.base = 23'h10c000; w.xr = 23'h000000;
    end
    // 21c01d..21c01d rd=- wr=coin_control lanes=1 xor=0
    if ((aw & 23'h7fffff) == 23'h10e00e) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_COIN_CONTROL;
      w.base = 23'h10e00e; w.xr = 23'h000000;
    end
    // 21c020..21c021 rd=input_p1 wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e010) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_INPUT_P1; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e010; w.xr = 23'h000000;
    end
    // 21c024..21c025 rd=input_p2 wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e012) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_INPUT_P2; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e012; w.xr = 23'h000000;
    end
    // 21c028..21c029 rd=input_system wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e014) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_INPUT_SYSTEM; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e014; w.xr = 23'h000000;
    end
    // 21c02c..21c02d rd=dip_a wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e016) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_DIP_A; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e016; w.xr = 23'h000000;
    end
    // 21c030..21c031 rd=dip_b wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e018) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_DIP_B; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e018; w.xr = 23'h000000;
    end
    // 21c034..21c035 rd=region_jumpers wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e01a) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_REGION_JUMPERS; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e01a; w.xr = 23'h000000;
    end
    // 21c03c..21c03d rd=gp_status wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e01e) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_GP_STATUS; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e01e; w.xr = 23'h000000;
    end
    // 300000..30000d rd=gp_registers wr=gp_registers lanes=3 xor=0
    if ((aw >= 23'h180000) && (aw <= 23'h180006)) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_GP_REGISTERS; w.wr_ep = EP_GP_REGISTERS;
      w.base = 23'h180000; w.xr = 23'h000000;
    end
    // 400000..400fff rd=palette_ram wr=palette_ram lanes=3 xor=0
    if ((aw & 23'h7ff800) == 23'h200000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_PALETTE_RAM; w.wr_ep = EP_PALETTE_RAM;
      w.base = 23'h200000; w.xr = 23'h000000;
    end
    // 401000..4017ff rd=unused_palette_ram wr=unused_palette_ram lanes=3 xor=0
    if ((aw & 23'h7ffc00) == 23'h200800) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_UNUSED_PALETTE_RAM; w.wr_ep = EP_UNUSED_PALETTE_RAM;
      w.base = 23'h200800; w.xr = 23'h000000;
    end
    // 500000..501fff rd=text_map wr=text_map lanes=3 xor=0
    if ((aw & 23'h7ff000) == 23'h280000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_TEXT_MAP; w.wr_ep = EP_TEXT_MAP;
      w.base = 23'h280000; w.xr = 23'h000000;
    end
    // 502000..502fff rd=text_select wr=text_select lanes=3 xor=0
    if ((aw & 23'h7ff800) == 23'h281000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_TEXT_SELECT; w.wr_ep = EP_TEXT_SELECT;
      w.base = 23'h281000; w.xr = 23'h000000;
    end
    // 503000..5031ff rd=text_scroll wr=text_scroll lanes=3 xor=0
    if ((aw & 23'h7fff00) == 23'h281800) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_TEXT_SCROLL; w.wr_ep = EP_TEXT_SCROLL;
      w.base = 23'h281800; w.xr = 23'h000000;
    end
    // 503200..503fff rd=text_work_ram wr=text_work_ram lanes=3 xor=0
    if ((aw >= 23'h281900) && (aw <= 23'h281fff)) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_TEXT_WORK_RAM; w.wr_ep = EP_TEXT_WORK_RAM;
      w.base = 23'h281900; w.xr = 23'h000000;
    end
    return w;
  endfunction

  function automatic int nhit_sorcer(input logic [IDXW-1:0] aw);
    int n;
    n = 0;
    if ((aw & 23'h7c0000) == 23'h000000) n = n + 1;
    if ((aw & 23'h7f8000) == 23'h080000) n = n + 1;
    if ((aw & 23'h7fe000) == 23'h10c000) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e00e) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e010) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e012) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e014) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e016) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e018) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e01a) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e01e) n = n + 1;
    if ((aw >= 23'h180000) && (aw <= 23'h180006)) n = n + 1;
    if ((aw & 23'h7ff800) == 23'h200000) n = n + 1;
    if ((aw & 23'h7ffc00) == 23'h200800) n = n + 1;
    if ((aw & 23'h7ff000) == 23'h280000) n = n + 1;
    if ((aw & 23'h7ff800) == 23'h281000) n = n + 1;
    if ((aw & 23'h7fff00) == 23'h281800) n = n + 1;
    if ((aw >= 23'h281900) && (aw <= 23'h281fff)) n = n + 1;
    return n;
  endfunction

  // ---- kingdom: 18 windows ----
  function automatic win_t win_kingdom(input logic [IDXW-1:0] aw);
    win_t w;
    w = WIN_NONE;
    // 000000..0fffff rd=cpu_rom wr=- lanes=3 xor=0
    if ((aw & 23'h780000) == 23'h000000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_CPU_ROM; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h000000; w.xr = 23'h000000;
    end
    // 100000..10ffff rd=work_ram wr=work_ram lanes=3 xor=0
    if ((aw & 23'h7f8000) == 23'h080000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_WORK_RAM; w.wr_ep = EP_WORK_RAM;
      w.base = 23'h080000; w.xr = 23'h000000;
    end
    // 218000..21bfff rd=shared_ram wr=shared_ram lanes=1 xor=0
    if ((aw & 23'h7fe000) == 23'h10c000) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_SHARED_RAM; w.wr_ep = EP_SHARED_RAM;
      w.base = 23'h10c000; w.xr = 23'h000000;
    end
    // 21c01d..21c01d rd=- wr=coin_oki_bank_control lanes=1 xor=0
    if ((aw & 23'h7fffff) == 23'h10e00e) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_COIN_OKI_BANK_CONTROL;
      w.base = 23'h10e00e; w.xr = 23'h000000;
    end
    // 21c020..21c021 rd=input_p1 wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e010) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_INPUT_P1; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e010; w.xr = 23'h000000;
    end
    // 21c024..21c025 rd=input_p2 wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e012) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_INPUT_P2; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e012; w.xr = 23'h000000;
    end
    // 21c028..21c029 rd=input_system wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e014) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_INPUT_SYSTEM; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e014; w.xr = 23'h000000;
    end
    // 21c02c..21c02d rd=dip_a wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e016) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_DIP_A; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e016; w.xr = 23'h000000;
    end
    // 21c030..21c031 rd=dip_b wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e018) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_DIP_B; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e018; w.xr = 23'h000000;
    end
    // 21c034..21c035 rd=region_jumpers wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e01a) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_REGION_JUMPERS; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e01a; w.xr = 23'h000000;
    end
    // 21c03c..21c03d rd=gp_status wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e01e) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_GP_STATUS; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e01e; w.xr = 23'h000000;
    end
    // 300000..30000d rd=gp_registers wr=gp_registers lanes=3 xor=0
    if ((aw >= 23'h180000) && (aw <= 23'h180006)) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_GP_REGISTERS; w.wr_ep = EP_GP_REGISTERS;
      w.base = 23'h180000; w.xr = 23'h000000;
    end
    // 400000..400fff rd=palette_ram wr=palette_ram lanes=3 xor=0
    if ((aw & 23'h7ff800) == 23'h200000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_PALETTE_RAM; w.wr_ep = EP_PALETTE_RAM;
      w.base = 23'h200000; w.xr = 23'h000000;
    end
    // 401000..4017ff rd=unused_palette_ram wr=unused_palette_ram lanes=3 xor=0
    if ((aw & 23'h7ffc00) == 23'h200800) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_UNUSED_PALETTE_RAM; w.wr_ep = EP_UNUSED_PALETTE_RAM;
      w.base = 23'h200800; w.xr = 23'h000000;
    end
    // 500000..501fff rd=text_map wr=text_map lanes=3 xor=0
    if ((aw & 23'h7ff000) == 23'h280000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_TEXT_MAP; w.wr_ep = EP_TEXT_MAP;
      w.base = 23'h280000; w.xr = 23'h000000;
    end
    // 502000..502fff rd=text_select wr=text_select lanes=3 xor=0
    if ((aw & 23'h7ff800) == 23'h281000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_TEXT_SELECT; w.wr_ep = EP_TEXT_SELECT;
      w.base = 23'h281000; w.xr = 23'h000000;
    end
    // 503000..5031ff rd=text_scroll wr=text_scroll lanes=3 xor=0
    if ((aw & 23'h7fff00) == 23'h281800) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_TEXT_SCROLL; w.wr_ep = EP_TEXT_SCROLL;
      w.base = 23'h281800; w.xr = 23'h000000;
    end
    // 503200..503fff rd=text_work_ram wr=text_work_ram lanes=3 xor=0
    if ((aw >= 23'h281900) && (aw <= 23'h281fff)) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_TEXT_WORK_RAM; w.wr_ep = EP_TEXT_WORK_RAM;
      w.base = 23'h281900; w.xr = 23'h000000;
    end
    return w;
  endfunction

  function automatic int nhit_kingdom(input logic [IDXW-1:0] aw);
    int n;
    n = 0;
    if ((aw & 23'h780000) == 23'h000000) n = n + 1;
    if ((aw & 23'h7f8000) == 23'h080000) n = n + 1;
    if ((aw & 23'h7fe000) == 23'h10c000) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e00e) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e010) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e012) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e014) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e016) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e018) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e01a) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e01e) n = n + 1;
    if ((aw >= 23'h180000) && (aw <= 23'h180006)) n = n + 1;
    if ((aw & 23'h7ff800) == 23'h200000) n = n + 1;
    if ((aw & 23'h7ffc00) == 23'h200800) n = n + 1;
    if ((aw & 23'h7ff000) == 23'h280000) n = n + 1;
    if ((aw & 23'h7ff800) == 23'h281000) n = n + 1;
    if ((aw & 23'h7fff00) == 23'h281800) n = n + 1;
    if ((aw >= 23'h281900) && (aw <= 23'h281fff)) n = n + 1;
    return n;
  endfunction

  // ---- garegga: 18 windows ----
  function automatic win_t win_garegga(input logic [IDXW-1:0] aw);
    win_t w;
    w = WIN_NONE;
    // 000000..0fffff rd=cpu_rom wr=- lanes=3 xor=0
    if ((aw & 23'h780000) == 23'h000000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_CPU_ROM; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h000000; w.xr = 23'h000000;
    end
    // 100000..10ffff rd=work_ram wr=work_ram lanes=3 xor=0
    if ((aw & 23'h7f8000) == 23'h080000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_WORK_RAM; w.wr_ep = EP_WORK_RAM;
      w.base = 23'h080000; w.xr = 23'h000000;
    end
    // 218000..21bfff rd=shared_ram wr=shared_ram lanes=1 xor=0
    if ((aw & 23'h7fe000) == 23'h10c000) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_SHARED_RAM; w.wr_ep = EP_SHARED_RAM;
      w.base = 23'h10c000; w.xr = 23'h000000;
    end
    // 21c01d..21c01d rd=- wr=coin_control lanes=1 xor=0
    if ((aw & 23'h7fffff) == 23'h10e00e) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_COIN_CONTROL;
      w.base = 23'h10e00e; w.xr = 23'h000000;
    end
    // 21c020..21c021 rd=input_p1 wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e010) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_INPUT_P1; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e010; w.xr = 23'h000000;
    end
    // 21c024..21c025 rd=input_p2 wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e012) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_INPUT_P2; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e012; w.xr = 23'h000000;
    end
    // 21c028..21c029 rd=input_system wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e014) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_INPUT_SYSTEM; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e014; w.xr = 23'h000000;
    end
    // 21c02c..21c02d rd=dip_a wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e016) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_DIP_A; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e016; w.xr = 23'h000000;
    end
    // 21c030..21c031 rd=dip_b wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e018) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_DIP_B; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e018; w.xr = 23'h000000;
    end
    // 21c034..21c035 rd=region_jumpers wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e01a) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_REGION_JUMPERS; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e01a; w.xr = 23'h000000;
    end
    // 21c03c..21c03d rd=gp_status wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h10e01e) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_GP_STATUS; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h10e01e; w.xr = 23'h000000;
    end
    // 300000..30000d rd=gp_registers wr=gp_registers lanes=3 xor=0
    if ((aw >= 23'h180000) && (aw <= 23'h180006)) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_GP_REGISTERS; w.wr_ep = EP_GP_REGISTERS;
      w.base = 23'h180000; w.xr = 23'h000000;
    end
    // 400000..400fff rd=palette_ram wr=palette_ram lanes=3 xor=0
    if ((aw & 23'h7ff800) == 23'h200000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_PALETTE_RAM; w.wr_ep = EP_PALETTE_RAM;
      w.base = 23'h200000; w.xr = 23'h000000;
    end
    // 500000..501fff rd=text_map wr=text_map lanes=3 xor=0
    if ((aw & 23'h7ff000) == 23'h280000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_TEXT_MAP; w.wr_ep = EP_TEXT_MAP;
      w.base = 23'h280000; w.xr = 23'h000000;
    end
    // 502000..502fff rd=text_select wr=text_select lanes=3 xor=0
    if ((aw & 23'h7ff800) == 23'h281000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_TEXT_SELECT; w.wr_ep = EP_TEXT_SELECT;
      w.base = 23'h281000; w.xr = 23'h000000;
    end
    // 503000..5031ff rd=text_scroll wr=text_scroll lanes=3 xor=0
    if ((aw & 23'h7fff00) == 23'h281800) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_TEXT_SCROLL; w.wr_ep = EP_TEXT_SCROLL;
      w.base = 23'h281800; w.xr = 23'h000000;
    end
    // 503200..503fff rd=text_work_ram wr=text_work_ram lanes=3 xor=0
    if ((aw >= 23'h281900) && (aw <= 23'h281fff)) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_TEXT_WORK_RAM; w.wr_ep = EP_TEXT_WORK_RAM;
      w.base = 23'h281900; w.xr = 23'h000000;
    end
    // 600001..600001 rd=- wr=sound_command lanes=1 xor=0
    if ((aw & 23'h7fffff) == 23'h300000) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_SOUND_COMMAND;
      w.base = 23'h300000; w.xr = 23'h000000;
    end
    return w;
  endfunction

  function automatic int nhit_garegga(input logic [IDXW-1:0] aw);
    int n;
    n = 0;
    if ((aw & 23'h780000) == 23'h000000) n = n + 1;
    if ((aw & 23'h7f8000) == 23'h080000) n = n + 1;
    if ((aw & 23'h7fe000) == 23'h10c000) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e00e) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e010) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e012) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e014) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e016) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e018) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e01a) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h10e01e) n = n + 1;
    if ((aw >= 23'h180000) && (aw <= 23'h180006)) n = n + 1;
    if ((aw & 23'h7ff800) == 23'h200000) n = n + 1;
    if ((aw & 23'h7ff000) == 23'h280000) n = n + 1;
    if ((aw & 23'h7ff800) == 23'h281000) n = n + 1;
    if ((aw & 23'h7fff00) == 23'h281800) n = n + 1;
    if ((aw >= 23'h281900) && (aw <= 23'h281fff)) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h300000) n = n + 1;
    return n;
  endfunction

  // ---- batrider: 21 windows ----
  function automatic win_t win_batrider(input logic [IDXW-1:0] aw);
    win_t w;
    w = WIN_NONE;
    // 000000..1fffff rd=cpu_rom wr=- lanes=3 xor=0
    if ((aw & 23'h700000) == 23'h000000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_CPU_ROM; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h000000; w.xr = 23'h000000;
    end
    // 200000..207fff rd=work_ram wr=work_ram lanes=3 xor=0
    if ((aw & 23'h7fc000) == 23'h100000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_WORK_RAM; w.wr_ep = EP_WORK_RAM;
      w.base = 23'h100000; w.xr = 23'h000000;
    end
    // 208000..20ffff rd=work_ram_upper wr=work_ram_upper lanes=3 xor=0
    if ((aw & 23'h7fc000) == 23'h104000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_WORK_RAM_UPPER; w.wr_ep = EP_WORK_RAM_UPPER;
      w.base = 23'h104000; w.xr = 23'h000000;
    end
    // 300000..37ffff rd=sound_rom wr=- lanes=3 xor=0
    if ((aw & 23'h7c0000) == 23'h180000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_SOUND_ROM; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h180000; w.xr = 23'h000000;
    end
    // 400000..40000d rd=gp_registers wr=gp_registers lanes=3 xor=6
    if ((aw >= 23'h200000) && (aw <= 23'h200006)) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_GP_REGISTERS; w.wr_ep = EP_GP_REGISTERS;
      w.base = 23'h200000; w.xr = 23'h000006;
    end
    // 500000..500001 rd=input_players wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h280000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_INPUT_PLAYERS; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h280000; w.xr = 23'h000000;
    end
    // 500002..500003 rd=input_system_dip wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h280001) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_INPUT_SYSTEM_DIP; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h280001; w.xr = 23'h000000;
    end
    // 500004..500005 rd=dip_remaining wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h280002) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_DIP_REMAINING; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h280002; w.xr = 23'h000000;
    end
    // 500006..500007 rd=gp_status wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h280003) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_GP_STATUS; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h280003; w.xr = 23'h000000;
    end
    // 500009..500009 rd=sound_reply_0 wr=- lanes=1 xor=0
    if ((aw & 23'h7fffff) == 23'h280004) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_SOUND_REPLY_0; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h280004; w.xr = 23'h000000;
    end
    // 50000b..50000b rd=sound_reply_1 wr=- lanes=1 xor=0
    if ((aw & 23'h7fffff) == 23'h280005) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_SOUND_REPLY_1; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h280005; w.xr = 23'h000000;
    end
    // 50000c..50000d rd=sound_busack wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h280006) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_SOUND_BUSACK; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h280006; w.xr = 23'h000000;
    end
    // 500011..500011 rd=- wr=coin_control lanes=1 xor=0
    if ((aw & 23'h7fffff) == 23'h280008) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_COIN_CONTROL;
      w.base = 23'h280008; w.xr = 23'h000000;
    end
    // 500021..500021 rd=- wr=sound_command_0 lanes=1 xor=0
    if ((aw & 23'h7fffff) == 23'h280010) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_SOUND_COMMAND_0;
      w.base = 23'h280010; w.xr = 23'h000000;
    end
    // 500023..500023 rd=- wr=sound_command_1 lanes=1 xor=0
    if ((aw & 23'h7fffff) == 23'h280011) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_SOUND_COMMAND_1;
      w.base = 23'h280011; w.xr = 23'h000000;
    end
    // 500024..500025 rd=- wr=sound_unknown lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h280012) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_SOUND_UNKNOWN;
      w.base = 23'h280012; w.xr = 23'h000000;
    end
    // 500026..500027 rd=- wr=sound_irq_ack lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h280013) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_SOUND_IRQ_ACK;
      w.base = 23'h280013; w.xr = 23'h000000;
    end
    // 500061..500061 rd=- wr=sound_busreq lanes=1 xor=0
    if ((aw & 23'h7fffff) == 23'h280030) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_SOUND_BUSREQ;
      w.base = 23'h280030; w.xr = 23'h000000;
    end
    // 500080..500081 rd=- wr=dma_text_gfx lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h280040) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_DMA_TEXT_GFX;
      w.base = 23'h280040; w.xr = 23'h000000;
    end
    // 500082..500083 rd=- wr=dma_palette_text lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h280041) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_DMA_PALETTE_TEXT;
      w.base = 23'h280041; w.xr = 23'h000000;
    end
    // 5000c0..5000cf rd=- wr=object_bank lanes=1 xor=0
    if ((aw & 23'h7ffff8) == 23'h280060) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_OBJECT_BANK;
      w.base = 23'h280060; w.xr = 23'h000000;
    end
    return w;
  endfunction

  function automatic int nhit_batrider(input logic [IDXW-1:0] aw);
    int n;
    n = 0;
    if ((aw & 23'h700000) == 23'h000000) n = n + 1;
    if ((aw & 23'h7fc000) == 23'h100000) n = n + 1;
    if ((aw & 23'h7fc000) == 23'h104000) n = n + 1;
    if ((aw & 23'h7c0000) == 23'h180000) n = n + 1;
    if ((aw >= 23'h200000) && (aw <= 23'h200006)) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280000) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280001) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280002) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280003) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280004) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280005) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280006) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280008) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280010) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280011) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280012) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280013) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280030) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280040) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280041) n = n + 1;
    if ((aw & 23'h7ffff8) == 23'h280060) n = n + 1;
    return n;
  endfunction

  // ---- bakraid: 21 windows ----
  function automatic win_t win_bakraid(input logic [IDXW-1:0] aw);
    win_t w;
    w = WIN_NONE;
    // 000000..1fffff rd=cpu_rom wr=- lanes=3 xor=0
    if ((aw & 23'h700000) == 23'h000000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_CPU_ROM; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h000000; w.xr = 23'h000000;
    end
    // 200000..207fff rd=work_ram wr=work_ram lanes=3 xor=0
    if ((aw & 23'h7fc000) == 23'h100000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_WORK_RAM; w.wr_ep = EP_WORK_RAM;
      w.base = 23'h100000; w.xr = 23'h000000;
    end
    // 208000..20ffff rd=work_ram_upper wr=work_ram_upper lanes=3 xor=0
    if ((aw & 23'h7fc000) == 23'h104000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_WORK_RAM_UPPER; w.wr_ep = EP_WORK_RAM_UPPER;
      w.base = 23'h104000; w.xr = 23'h000000;
    end
    // 300000..33ffff rd=sound_rom wr=- lanes=3 xor=0
    if ((aw & 23'h7e0000) == 23'h180000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_SOUND_ROM; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h180000; w.xr = 23'h000000;
    end
    // 400000..40000d rd=gp_registers wr=gp_registers lanes=3 xor=6
    if ((aw >= 23'h200000) && (aw <= 23'h200006)) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_GP_REGISTERS; w.wr_ep = EP_GP_REGISTERS;
      w.base = 23'h200000; w.xr = 23'h000006;
    end
    // 500000..500001 rd=input_players wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h280000) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_INPUT_PLAYERS; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h280000; w.xr = 23'h000000;
    end
    // 500002..500003 rd=input_system_dip wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h280001) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_INPUT_SYSTEM_DIP; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h280001; w.xr = 23'h000000;
    end
    // 500004..500005 rd=dip_remaining wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h280002) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_DIP_REMAINING; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h280002; w.xr = 23'h000000;
    end
    // 500006..500007 rd=gp_status wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h280003) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_GP_STATUS; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h280003; w.xr = 23'h000000;
    end
    // 500009..500009 rd=- wr=coin_control lanes=1 xor=0
    if ((aw & 23'h7fffff) == 23'h280004) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_COIN_CONTROL;
      w.base = 23'h280004; w.xr = 23'h000000;
    end
    // 500011..500011 rd=sound_reply_0 wr=- lanes=1 xor=0
    if ((aw & 23'h7fffff) == 23'h280008) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_SOUND_REPLY_0; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h280008; w.xr = 23'h000000;
    end
    // 500013..500013 rd=sound_reply_1 wr=- lanes=1 xor=0
    if ((aw & 23'h7fffff) == 23'h280009) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_SOUND_REPLY_1; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h280009; w.xr = 23'h000000;
    end
    // 500015..500015 rd=- wr=sound_command_0 lanes=1 xor=0
    if ((aw & 23'h7fffff) == 23'h28000a) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_SOUND_COMMAND_0;
      w.base = 23'h28000a; w.xr = 23'h000000;
    end
    // 500017..500017 rd=- wr=sound_command_1 lanes=1 xor=0
    if ((aw & 23'h7fffff) == 23'h28000b) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_SOUND_COMMAND_1;
      w.base = 23'h28000b; w.xr = 23'h000000;
    end
    // 500018..500019 rd=eeprom_busack wr=- lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h28000c) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_EEPROM_BUSACK; w.wr_ep = EP_UNMAPPED;
      w.base = 23'h28000c; w.xr = 23'h000000;
    end
    // 50001a..50001b rd=- wr=sound_unknown lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h28000d) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_SOUND_UNKNOWN;
      w.base = 23'h28000d; w.xr = 23'h000000;
    end
    // 50001c..50001d rd=- wr=sound_irq_ack lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h28000e) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_SOUND_IRQ_ACK;
      w.base = 23'h28000e; w.xr = 23'h000000;
    end
    // 50001f..50001f rd=- wr=eeprom_control lanes=1 xor=0
    if ((aw & 23'h7fffff) == 23'h28000f) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_EEPROM_CONTROL;
      w.base = 23'h28000f; w.xr = 23'h000000;
    end
    // 500080..500081 rd=- wr=dma_text_gfx lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h280040) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_DMA_TEXT_GFX;
      w.base = 23'h280040; w.xr = 23'h000000;
    end
    // 500082..500083 rd=- wr=dma_palette_text lanes=3 xor=0
    if ((aw & 23'h7fffff) == 23'h280041) begin
      w.hit = 1'b1; w.lanes = 2'b11;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_DMA_PALETTE_TEXT;
      w.base = 23'h280041; w.xr = 23'h000000;
    end
    // 5000c0..5000cf rd=- wr=object_bank lanes=1 xor=0
    if ((aw & 23'h7ffff8) == 23'h280060) begin
      w.hit = 1'b1; w.lanes = 2'b01;
      w.rd_ep = EP_UNMAPPED; w.wr_ep = EP_OBJECT_BANK;
      w.base = 23'h280060; w.xr = 23'h000000;
    end
    return w;
  endfunction

  function automatic int nhit_bakraid(input logic [IDXW-1:0] aw);
    int n;
    n = 0;
    if ((aw & 23'h700000) == 23'h000000) n = n + 1;
    if ((aw & 23'h7fc000) == 23'h100000) n = n + 1;
    if ((aw & 23'h7fc000) == 23'h104000) n = n + 1;
    if ((aw & 23'h7e0000) == 23'h180000) n = n + 1;
    if ((aw >= 23'h200000) && (aw <= 23'h200006)) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280000) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280001) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280002) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280003) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280004) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280008) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280009) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h28000a) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h28000b) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h28000c) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h28000d) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h28000e) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h28000f) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280040) n = n + 1;
    if ((aw & 23'h7fffff) == 23'h280041) n = n + 1;
    if ((aw & 23'h7ffff8) == 23'h280060) n = n + 1;
    return n;
  endfunction

  // Window lookup for a static profile id; PID_NONE never hits.
  function automatic win_t win_lookup(input int pid, input logic [IDXW-1:0] aw);
    case (pid)
      1: return win_sorcer(aw);
      2: return win_kingdom(aw);
      3: return win_garegga(aw);
      4: return win_batrider(aw);
      5: return win_bakraid(aw);
      default: return WIN_NONE;
    endcase
  endfunction

  function automatic int nhit_lookup(input int pid, input logic [IDXW-1:0] aw);
    case (pid)
      1: return nhit_sorcer(aw);
      2: return nhit_kingdom(aw);
      3: return nhit_garegga(aw);
      4: return nhit_batrider(aw);
      5: return nhit_bakraid(aw);
      default: return 0;
    endcase
  endfunction

endpackage

`default_nettype wire

// Routes at most one accepted 68000 transaction to its board endpoint.
`default_nettype none

module rzbus_router
#(
  parameter        PROFILE = "none",
  parameter int    TAGW    = 4
) (
  input  wire                  alt_map,      // run-time alternate map (see rzbus_decode)
  input  wire                  clk,
  input  wire                  rst,          // synchronous, active high

  // ---- normalized upstream request (one accepted 68000 transaction) ----
  input  wire                  req_valid,
  output logic                 req_ready,
  input  wire [23:0]           req_addr,     // bit 0 must be 0
  input  wire                  req_write,
  input  wire [15:0]           req_wdata,
  input  wire [1:0]            req_be,       // [1] upper/even D15:8, [0] lower/odd D7:0
  input  wire [2:0]            req_fc,
  input  wire [TAGW-1:0]       req_tag,

  // ---- normalized upstream response ----
  output logic                 rsp_valid,
  input  wire                  rsp_ready,
  output logic [15:0]          rsp_data,
  output logic [1:0]           rsp_driven,   // lanes the owner actually drove
  output logic [TAGW-1:0]      rsp_tag,
  output rzbus_pkg::kind_e      rsp_kind,

  // ---- quiesce / status ----
  input  wire                  quiesce,      // stop NEW admissions only
  output logic                 idle,         // nothing accepted and unfinished
  output logic                 profile_ok,
  output logic                 fault_pulse,  // protocol fault accepted this cycle
  output logic                 fault_sticky, // cleared by rst
  output logic                 stray_sticky, // response from a non-selected endpoint, cleared by rst

  // ---- typed endpoint request (one-hot valid, shared payload) ----
  output logic [rzbus_pkg::NEP-1:0] ep_req_valid,
  input  wire [rzbus_pkg::NEP-1:0] ep_req_ready,
  output logic [rzbus_pkg::IDXW-1:0] ep_req_index,
  output logic                 ep_req_write,
  output logic [15:0]          ep_req_wdata,
  output logic [1:0]           ep_req_lanes,
  output logic [TAGW-1:0]      ep_req_tag,
  output logic [2:0]           ep_req_fc,
  output logic [1:0]           ep_req_reason,

  // ---- typed endpoint response (per endpoint) ----
  input  wire [rzbus_pkg::NEP-1:0] ep_rsp_valid,
  output logic [rzbus_pkg::NEP-1:0] ep_rsp_ready,
  input  wire [rzbus_pkg::NEP*16-1:0] ep_rsp_data,
  input  wire [rzbus_pkg::NEP*2-1:0] ep_rsp_driven
);
  import rzbus_pkg::*;

  typedef enum logic [1:0] {StIdle, StReq, StWait, StHold} state_e;

  // ---- decoder on the live request (registered on acceptance) ----
  logic [NEP-1:0]  dec_onehot;
  /* verilator lint_off UNUSEDSIGNAL */
  ep_e             dec_ep;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [IDXW-1:0] dec_index;
  logic [1:0]      dec_lanes;
  kind_e           dec_kind;
  logic [1:0]      dec_reason;
  logic            dec_fault;

  rzbus_decode #(.PROFILE(PROFILE)) u_dec (
    .alt_map(alt_map),
    .addr(req_addr), .write(req_write), .be(req_be), .fc(req_fc),
    .ep_onehot(dec_onehot), .ep_id(dec_ep), .index(dec_index), .lanes(dec_lanes),
    .kind(dec_kind), .reason(dec_reason), .fault(dec_fault), .profile_ok(profile_ok)
  );

  // ---- transaction registers ----
  state_e          state_q;
  logic [NEP-1:0]  sel_q;        // one-hot selected endpoint (zero for a fault)
  logic [IDXW-1:0] index_q;
  logic            write_q;
  logic [15:0]     wdata_q;
  logic [1:0]      lanes_q;
  logic [TAGW-1:0] tag_q;
  logic [2:0]      fc_q;
  logic [1:0]      reason_q;
  kind_e           kind_q;
  logic [15:0]     hold_data_q;
  logic [1:0]      hold_driven_q;

  logic accept;
  logic ep_accept;
  logic ep_rsp_now;      // selected endpoint response is taken this edge
  logic sel_rsp_valid;
  logic sel_req_ready;
  logic [15:0] sel_rsp_data;
  logic [1:0]  sel_rsp_driven;

  assign req_ready = (state_q == StIdle) && !quiesce;
  assign accept    = req_valid && req_ready;
  assign idle      = (state_q == StIdle);

  // selected endpoint's inputs (AND-OR over the one-hot select)
  always_comb begin
    sel_rsp_valid  = 1'b0;
    sel_req_ready  = 1'b0;
    sel_rsp_data   = '0;
    sel_rsp_driven = '0;
    for (int i = 0; i < NEP; i++) begin
      if (sel_q[i]) begin
        sel_rsp_valid  = sel_rsp_valid  | ep_rsp_valid[i];
        sel_req_ready  = sel_req_ready  | ep_req_ready[i];
        sel_rsp_data   = sel_rsp_data   | ep_rsp_data[i*16 +: 16];
        sel_rsp_driven = sel_rsp_driven | ep_rsp_driven[i*2 +: 2];
      end
    end
  end

  assign ep_accept  = (state_q == StReq) && sel_req_ready;
  // A response is taken in StWait, or in StReq in the same cycle the endpoint accepts.
  assign ep_rsp_now = sel_rsp_valid && ((state_q == StWait) || ep_accept);

  // ---- state machine (next-state block + register) ----
  state_e state_d;

  always_comb begin
    state_d = state_q;
    unique case (state_q)
      StIdle: begin
        if (accept) begin
          if (dec_fault) state_d = StHold;
          else           state_d = StReq;
        end
      end
      StReq: begin
        if (ep_rsp_now) begin
          if (rsp_ready) state_d = StIdle;
          else           state_d = StHold;
        end else if (ep_accept) begin
          state_d = StWait;
        end
      end
      StWait: begin
        if (ep_rsp_now) begin
          if (rsp_ready) state_d = StIdle;
          else           state_d = StHold;
        end
      end
      StHold: begin
        if (rsp_ready) state_d = StIdle;
      end
      default: state_d = StIdle;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) state_q <= StIdle;
    else     state_q <= state_d;
  end

  // ---- request capture: all fields frozen for the life of the transaction ----
  always_ff @(posedge clk) begin
    if (rst) begin
      sel_q    <= '0;
      kind_q   <= KIND_ENDPOINT;
      reason_q <= 2'd0;
    end else if (accept) begin
      sel_q    <= dec_onehot;
      kind_q   <= dec_kind;
      reason_q <= dec_reason;
    end
  end

  always_ff @(posedge clk) begin
    if (accept) begin
      index_q <= dec_index;
      write_q <= req_write;
      wdata_q <= req_wdata;
      lanes_q <= dec_lanes;
      tag_q   <= req_tag;
      fc_q    <= req_fc;
    end
  end

  // ---- response hold register (filled when upstream is not ready) ----
  always_ff @(posedge clk) begin
    if (accept && dec_fault) begin
      hold_data_q   <= 16'h0000;
      hold_driven_q <= 2'b00;
    end else if (ep_rsp_now && !rsp_ready) begin
      hold_data_q   <= sel_rsp_data;
      hold_driven_q <= sel_rsp_driven;
    end
  end

  // ---- endpoint request: one-hot valid only in StReq ----
  assign ep_req_valid  = (state_q == StReq) ? sel_q : '0;
  assign ep_req_index  = index_q;
  assign ep_req_write  = write_q;
  assign ep_req_wdata  = wdata_q;
  assign ep_req_lanes  = lanes_q;
  assign ep_req_tag    = tag_q;
  assign ep_req_fc     = fc_q;
  assign ep_req_reason = reason_q;

  // ---- endpoint response ready: selected endpoint only, from acceptance on ----
  assign ep_rsp_ready = ((state_q == StWait) || ep_accept) ? sel_q : '0;

  // ---- upstream response: pass-through when possible, else from hold ----
  always_comb begin
    if (state_q == StHold) begin
      rsp_valid  = 1'b1;
      rsp_data   = hold_data_q;
      rsp_driven = hold_driven_q;
    end else begin
      rsp_valid  = ep_rsp_now;
      rsp_data   = sel_rsp_data;
      rsp_driven = sel_rsp_driven;
    end
  end
  assign rsp_tag  = tag_q;
  assign rsp_kind = kind_q;

  // ---- diagnostics ----
  assign fault_pulse = accept && dec_fault;

  logic stray_now;
  assign stray_now = |(ep_rsp_valid & ~ep_rsp_ready);

  always_ff @(posedge clk) begin
    if (rst) begin
      fault_sticky <= 1'b0;
      stray_sticky <= 1'b0;
    end else begin
      if (fault_pulse) fault_sticky <= 1'b1;
      if (stray_now)   stray_sticky <= 1'b1;
    end
  end

endmodule

`default_nettype wire

// Decodes one 68000 word address and its byte lanes into an endpoint for the board profile.
`default_nettype none

module rzbus_decode
#(
  parameter PROFILE = "none"
) (
  input  wire            alt_map,        // Kingdom profile: Sorcer map; Batrider profile: Bakraid map
  input  wire [23:0]     addr,
  input  wire            write,
  input  wire [1:0]      be,        // be[1] = upper/even byte D15:8, be[0] = lower/odd byte D7:0
  input  wire [2:0]      fc,
  output logic [rzbus_pkg::NEP-1:0]  ep_onehot, // zero for a protocol fault
  output rzbus_pkg::ep_e             ep_id,
  output logic [rzbus_pkg::IDXW-1:0] index,
  output logic [1:0]      lanes,
  output rzbus_pkg::kind_e           kind,
  output logic [1:0]      reason,
  output logic            fault,
  output logic            profile_ok
);
  import rzbus_pkg::*;
  import rzbus_map_pkg::*;

  // PROFILE string -> profile ID.
  /* verilator lint_off WIDTHEXPAND */
  localparam int PID = (PROFILE == "sorcer")   ? PID_SORCER   :
                       (PROFILE == "kingdom")  ? PID_KINGDOM  :
                       (PROFILE == "garegga")  ? PID_GAREGGA  :
                       (PROFILE == "batrider") ? PID_BATRIDER :
                       (PROFILE == "bakraid")  ? PID_BAKRAID  : PID_NONE;
  /* verilator lint_on WIDTHEXPAND */

  logic [IDXW-1:0] aw;
  win_t            w;
  ep_e             win_ep;
  logic [1:0]      conn_lanes;

  assign aw         = addr[23:1];
  assign profile_ok = (PID != PID_NONE);
  assign fault      = addr[0] | (be == 2'b00);

  // alt_map selects the Sorcer table in the Kingdom profile and the Bakraid table in the Batrider profile.
  always_comb w = (PID == PID_KINGDOM && alt_map)  ? win_sorcer(aw)  :
                  (PID == PID_BATRIDER && alt_map) ? win_bakraid(aw) : win_lookup(PID, aw);

  always_comb begin
    if (write) win_ep = w.wr_ep; else win_ep = w.rd_ep;
    conn_lanes = be & w.lanes;
    kind       = KIND_UNMAPPED;
    ep_id      = EP_UNMAPPED;
    index      = aw;
    lanes      = be;
    reason     = REASON_NO_WINDOW;
    if (fault) begin
      kind = KIND_FAULT;
    end else if (PID == PID_NONE) begin
      reason = REASON_PROFILE;
    end else if (fc == 3'd7) begin
      kind  = KIND_CPU_SPACE;
      ep_id = EP_CPU_SPACE;
    end else if (!w.hit) begin
      reason = REASON_NO_WINDOW;
    end else if (win_ep == EP_UNMAPPED) begin
      reason = REASON_DIRECTION;
    end else if (conn_lanes == 2'b00) begin
      reason = REASON_LANES;
    end else begin
      kind  = KIND_ENDPOINT;
      ep_id = win_ep;
      index = (aw - w.base) ^ w.xr;
      lanes = conn_lanes;
    end
  end

  always_comb begin
    ep_onehot = '0;
    if (!fault) ep_onehot[ep_id] = 1'b1;
  end

endmodule

`default_nettype wire

// Admits FX68K bus cycles into the transaction router.
`default_nettype none
module rzbus_cpu_link #(
    parameter PROFILE = "none"
) (
    input wire alt_map,        // run-time alternate map (see rzbus_decode)
    input wire clk, reset,
    input wire [23:1] cpu_addr,
    input wire cpu_as_n, cpu_rw, cpu_uds_n, cpu_lds_n,
    input wire [2:0] cpu_fc,
    input wire [15:0] cpu_dout,
    input wire override_valid,
    output wire selected, busy, idle,
    output wire [rzbus_pkg::NEP-1:0] command,
    output wire [22:0] command_index,
    output wire [1:0] command_lanes,
    input wire owner_complete,
    input wire [15:0] owner_data
);
    import rzbus_pkg::*;
    wire active = !cpu_as_n && (!cpu_uds_n || !cpu_lds_n) && cpu_fc != 3'b111;
    reg admitted, finished;
    reg [NEP-1:0] owner;
    wire req_ready, response_valid, router_idle, profile_ok;
    wire fault_sticky, stray_sticky;
    wire [15:0] response_data;
    wire [1:0] response_driven;
    wire response_tag;
    kind_e response_kind;
    wire command_write;
    wire [15:0] command_data;
    wire command_tag;
    wire [2:0] command_fc;
    wire [1:0] command_reason;
    wire [NEP-1:0] response_ready;
    wire request = active && !admitted && !override_valid && !reset;
    assign selected = active;
    assign busy = active && !(finished || response_valid);
    assign idle = !admitted && router_idle && !(|owner);

    rzbus_router #(.PROFILE(PROFILE),.TAGW(1)) router(.alt_map(alt_map),
        .clk(clk),.rst(reset),.req_valid(request),.req_ready(req_ready),
        .req_addr({cpu_addr,1'b0}),.req_write(!cpu_rw),.req_wdata(cpu_dout),
        .req_be({!cpu_uds_n,!cpu_lds_n}),.req_fc(cpu_fc),.req_tag(1'b0),
        .rsp_valid(response_valid),.rsp_ready(1'b1),.rsp_data(response_data),
        .rsp_driven(response_driven),.rsp_tag(response_tag),.rsp_kind(response_kind),
        .quiesce(1'b0),.idle(router_idle),.profile_ok(profile_ok),.fault_pulse(),
        .fault_sticky(fault_sticky),.stray_sticky(stray_sticky),
        .ep_req_valid(command),.ep_req_ready({NEP{1'b1}}),
        .ep_req_index(command_index),.ep_req_write(command_write),
        .ep_req_wdata(command_data),.ep_req_lanes(command_lanes),
        .ep_req_tag(command_tag),.ep_req_fc(command_fc),.ep_req_reason(command_reason),
        .ep_rsp_valid(owner & {NEP{owner_complete}}),.ep_rsp_ready(response_ready),
        .ep_rsp_data({NEP{owner_data}}),.ep_rsp_driven({NEP{cpu_rw ? 2'b11 : 2'b00}}));

    always @(posedge clk) begin
        if (reset) begin
            admitted <= 0;
            finished <= 0;
            owner <= 0;
        end else begin
            if (!active) begin admitted <= 0; finished <= 0; end
            if (request && req_ready) admitted <= 1;
            // an overridden cycle stays admitted until its strobes end
            if (active && override_valid) admitted <= 1;
            if (response_valid) finished <= 1;
            if (|command) owner <= command;
            else if (owner_complete) owner <= 0;
        end
    end

`ifdef SIMULATION
    always @(posedge clk) if (!reset) begin
        if (!profile_ok || fault_sticky || stray_sticky)
            $fatal(1,"Raizing bus routing contract failed");
        if ((|owner) && !active && !owner_complete)
            $fatal(1,"CPU abandoned an accepted endpoint transaction");
        if ((|command) && (|owner))
            $fatal(1,"Two endpoint owners overlap");
        if ((|command) && (command_write != !cpu_rw || command_data != cpu_dout || command_fc != cpu_fc))
            $fatal(1,"FX68K payload changed before endpoint acceptance");
    end
`endif
endmodule
`default_nettype wire

// Encodes active-low board controls as active-high CPU input bytes.
`default_nettype none

module rzboard_inputs #(
    parameter int PROFILE = -1
) (
    // verilator lint_off UNUSEDSIGNAL
    input  wire logic [9:0] player1_n,   // orientation-adjusted: [0] right [1] left [2] down [3] up [6:4] buttons 3-1
    input  wire logic [9:0] player2_n,
    input  wire logic [1:0] start_n,
    input  wire logic [1:0] coin_n,
    input  wire logic       service_n,
    input  wire logic [7:0] dip_a,
    // verilator lint_on UNUSEDSIGNAL
    output logic      [7:0] player1,         // [0] up [1] down [2] left [3] right [6:4] buttons 3-1
    output logic      [7:0] player2,
    output logic      [7:0] system_inputs    // [0] service [2] test [4:3] coin 2-1 [6:5] start 2-1
);

    // Control bit indices within player*_n.
    localparam int NAT_RIGHT = 0;
    localparam int NAT_LEFT  = 1;
    localparam int NAT_DOWN  = 2;
    localparam int NAT_UP    = 3;
    localparam int NAT_B1    = 4;
    localparam int NAT_B2    = 5;
    localparam int NAT_B3    = 6;

    // Test bit source: Sorcer/Kingdom dip_a[2], Garegga dip_a[0], Batrider/Bakraid low.
    localparam int TEST_TIED_LOW = 0;
    localparam int TEST_DIP_A2   = 1;
    localparam int TEST_DIP_A0   = 2;

    localparam bit PROFILE_KNOWN = (PROFILE >= 0) && (PROFILE <= 4);
    localparam int TEST_SOURCE =
        (PROFILE == 0 || PROFILE == 1) ? TEST_DIP_A2 :
        (PROFILE == 2)                 ? TEST_DIP_A0 :
                                         TEST_TIED_LOW;

    function automatic logic [7:0] cpu_player_byte(input logic [9:0] ctl_n);
        logic [7:0] b;
        b    = 8'h00;
        b[0] = ~ctl_n[NAT_UP];
        b[1] = ~ctl_n[NAT_DOWN];
        b[2] = ~ctl_n[NAT_LEFT];
        b[3] = ~ctl_n[NAT_RIGHT];
        b[4] = ~ctl_n[NAT_B1];
        b[5] = ~ctl_n[NAT_B2];
        b[6] = ~ctl_n[NAT_B3];
        cpu_player_byte = b;
    endfunction

    generate
        if (PROFILE_KNOWN) begin : g_known
            logic test_signal;

            if (TEST_SOURCE == TEST_DIP_A2) begin : g_test_dip_a2
                assign test_signal = dip_a[2];
            end else if (TEST_SOURCE == TEST_DIP_A0) begin : g_test_dip_a0
                assign test_signal = dip_a[0];
            end else begin : g_test_tied_low
                assign test_signal = 1'b0;
            end

            assign player1 = cpu_player_byte(player1_n);
            assign player2 = cpu_player_byte(player2_n);
            assign system_inputs = {1'b0, ~start_n[1], ~start_n[0], ~coin_n[1], ~coin_n[0], test_signal, 1'b0, ~service_n};
        end else begin : g_inert
            assign player1       = 8'h00;
            assign player2       = 8'h00;
            assign system_inputs = 8'h00;
        end
    endgenerate

endmodule

`default_nettype wire

// Decodes a routed 68000 request into a GP9001 operation (combinational).
`default_nettype none

module rzperiph_gp_command #(
    parameter integer PROFILE = 0
) (
    input  wire [1:0]  endpoint,     // 0 unselected, 1 GP window, 2 object bank, 3 unsupported
    input  wire [2:0]  index,        // normalized word index, or object-bank slot
    input  wire        read_cycle,   // 1 read, 0 write
    input  wire [1:0]  lanes,        // admitted {UDS, LDS}
    input  wire        block_write,  // suppress side effects of this write
    input  wire [15:0] write_data,   // complete CPU data word
    output reg  [1:0]  kind,         // 0 no service, 1 direct status, 2 GP operation
    output reg  [2:0]  op,           // GP operation number
    output reg  [2:0]  bank,         // object-bank slot, zero otherwise
    output reg  [15:0] data,         // complete word on writes, zero on reads
    output reg  [1:0]  be            // effective byte lanes of the operation
);

    // Early window: Sorcer, Kingdom, Garegga (0-2); late window: Batrider, Bakraid (3-4).
    localparam [0:0] IS_EARLY = ((PROFILE >= 0) && (PROFILE <= 2)) ? 1'b1 : 1'b0;
    localparam [0:0] IS_LATE  = ((PROFILE == 3) || (PROFILE == 4)) ? 1'b1 : 1'b0;
    localparam [0:0] IS_KNOWN = IS_EARLY | IS_LATE;

    localparam [1:0] EP_GP_WINDOW = 2'd1;
    localparam [1:0] EP_OBJ_BANK  = 2'd2;

    localparam [1:0] KIND_NONE    = 2'd0;
    localparam [1:0] KIND_STATUS  = 2'd1;
    localparam [1:0] KIND_GP_OP   = 2'd2;

    localparam [2:0] OP_POINTER   = 3'd0;
    localparam [2:0] OP_VRAM_W    = 3'd1;
    localparam [2:0] OP_VRAM_HI_R = 3'd2;
    localparam [2:0] OP_VRAM_LO_R = 3'd3;
    localparam [2:0] OP_SELECTOR  = 3'd4;
    localparam [2:0] OP_SCROLL    = 3'd5;
    localparam [2:0] OP_OBJ_BANK  = 3'd6;

    wire [2:0] widx = index;

    wire any_lane   = (lanes != 2'b00);
    wire live_write = !read_cycle && !block_write;

    // Register window decode before lane and profile qualification; "open" = unmapped.
    reg       win_status;
    reg       win_op_valid;
    reg [2:0] win_op;

    always @* begin
        win_status   = 1'b0;
        win_op_valid = 1'b0;
        win_op       = OP_POINTER;
        if (read_cycle) begin
            case (widx)
                3'd2:    begin win_op_valid = 1'b1; win_op = OP_VRAM_HI_R; end
                3'd3:    begin win_op_valid = 1'b1; win_op = OP_VRAM_LO_R; end
                3'd6:    win_status = 1'b1;
                3'd7:    win_status = IS_LATE;                       // early 7: open
                default: ;                                           // 0, 1, 4, 5: open
            endcase
        end else begin
            case (widx)
                3'd0:    begin win_op_valid = 1'b1;     win_op = OP_POINTER;  end
                3'd1:    begin win_op_valid = IS_EARLY; win_op = OP_POINTER;  end // late 1: open
                3'd2,
                3'd3:    begin win_op_valid = 1'b1;     win_op = OP_VRAM_W;   end
                3'd4,
                3'd5:    begin win_op_valid = 1'b1;     win_op = OP_SELECTOR; end
                3'd6:    begin win_op_valid = 1'b1;     win_op = OP_SCROLL;   end
                default: begin win_op_valid = IS_LATE;  win_op = OP_SCROLL;   end // 7; early 7: open
            endcase
        end
    end

    // block_write suppresses writes only.
    wire win_hit  = IS_KNOWN && (endpoint == EP_GP_WINDOW) && any_lane
                    && (read_cycle || !block_write);

    // Only late profiles accept object-bank writes, low lane required.
    wire bank_hit = IS_LATE && (endpoint == EP_OBJ_BANK) && live_write && lanes[0];

    // GP operations carry the admitted lanes and the full write word unmerged.
    always @* begin
        kind = KIND_NONE;
        op   = 3'd0;
        bank = 3'd0;
        data = 16'h0000;
        be   = 2'b00;
        if (win_hit && win_op_valid) begin
            kind = KIND_GP_OP;
            op   = win_op;
            data = read_cycle ? 16'h0000 : write_data;
            be   = lanes;
        end else if (win_hit && win_status) begin
            kind = KIND_STATUS;
        end else if (bank_hit) begin
            kind = KIND_GP_OP;
            op   = OP_OBJ_BANK;
            bank = index;
            data = write_data;
            be   = 2'b01;
        end
    end

endmodule

`default_nettype wire

// Formats direct CPU read words (inputs, DIPs, sound replies, raster status) by local read ID.
`default_nettype none

module rzperiph_read_word #(
    parameter integer PROFILE = 0
) (
    input  wire [3:0]  read_id,        // local selector, not a router endpoint number
    input  wire [15:0] players,        // {P2, P1}
    input  wire [7:0]  system_inputs,  // board-normalized
    input  wire [7:0]  dip_a,
    input  wire [7:0]  dip_b,
    input  wire [7:0]  dip_c,
    input  wire [15:0] reply,          // {reply 1, reply 0}
    input  wire [15:0] bus_status,     // sound-bus or EEPROM/GPIO status word
    input  wire [8:0]  vpos,           // raster row, 0..262
    input  wire        hs_n,
    input  wire        vs_n,
    input  wire        blank_n,
    input  wire        bit13,          // status bit 13
    output wire [15:0] data
);

    // Packing: Sorcer/Kingdom byte-replicated, Garegga zero-extended, Batrider/Bakraid paired; unassigned IDs read 0.
    localparam [0:0] FAM_REPLICATE = ((PROFILE == 0) || (PROFILE == 1)) ? 1'b1 : 1'b0;
    localparam [0:0] FAM_ZEXT      =  (PROFILE == 2)                    ? 1'b1 : 1'b0;
    localparam [0:0] FAM_PAIRED    = ((PROFILE == 3) || (PROFILE == 4)) ? 1'b1 : 1'b0;

    // Read ID 7 uses the raw row in replicated packing, else the adjusted row; ID 11 always the adjusted row.
    localparam [0:0] COUNT_USES_RAW = FAM_REPLICATE;

    wire [7:0] p1      = players[7:0];
    wire [7:0] p2      = players[15:8];
    wire [7:0] reply_0 = reply[7:0];
    wire [7:0] reply_1 = reply[15:8];

    // Raster words; adjusted row = (vpos + 15) mod 262.
    wire [9:0] row_raw    = {1'b0, vpos};
    wire [9:0] row_plus   = row_raw + 10'd15;
    wire [9:0] row_adj    = (row_plus >= 10'd262) ? (row_plus - 10'd262) : row_plus;
    wire [9:0] count_row  = COUNT_USES_RAW ? row_raw : row_adj;
    wire [7:0] count_byte = (count_row > 10'd255) ? 8'hFF : count_row[7:0];

    // Read ID 7 high byte, bits 15..8.
    wire [7:0] video_byte = {hs_n, vs_n, bit13, 4'b1111, blank_n};

    wire        row_flag   = (row_adj >= 10'd245);
    wire [15:0] count_word = {video_byte, count_byte};
    wire [15:0] flag_word  = {15'd0, row_flag};

    reg [15:0] rep_word, zext_word, pair_word;

    always @* begin
        case (read_id)
            4'd1:    rep_word = {p1, p1};
            4'd2:    rep_word = {p2, p2};
            4'd3:    rep_word = {dip_c, system_inputs};
            4'd4:    rep_word = {dip_a, dip_a};
            4'd5:    rep_word = {dip_b, dip_b};
            4'd6:    rep_word = {dip_c, dip_c};
            4'd7:    rep_word = count_word;
            4'd11:   rep_word = flag_word;
            default: rep_word = 16'h0000;
        endcase
    end

    always @* begin
        case (read_id)
            4'd1:    zext_word = {8'h00, p1};
            4'd2:    zext_word = {8'h00, p2};
            4'd3:    zext_word = {8'h00, system_inputs};
            4'd4:    zext_word = {8'h00, dip_a};
            4'd5:    zext_word = {8'h00, dip_b};
            4'd6:    zext_word = {8'h00, dip_c};
            4'd7:    zext_word = count_word;
            4'd11:   zext_word = flag_word;
            default: zext_word = 16'h0000;
        endcase
    end

    always @* begin
        case (read_id)
            4'd1:    pair_word = {p2, p1};
            4'd3:    pair_word = {dip_c, system_inputs};
            4'd4:    pair_word = {dip_b, dip_a};
            4'd7:    pair_word = count_word;
            4'd8:    pair_word = {8'h00, reply_0};
            4'd9:    pair_word = {8'h00, reply_1};
            4'd10:   pair_word = bus_status;
            4'd11:   pair_word = flag_word;
            default: pair_word = 16'h0000;
        endcase
    end

    assign data = FAM_REPLICATE ? rep_word  :
                  FAM_ZEXT      ? zext_word :
                  FAM_PAIRED    ? pair_word :
                                  16'h0000;                  // unknown profile

endmodule

`default_nettype wire

// Maps CPU addresses in each profile's high-score table to packed NVRAM lanes and word offset.
module rzscore_window #(
    parameter integer PROFILE = -1
) (
    input  wire        alt_map,        // Kingdom profile: use the Sorcer table
    input  wire [23:1] word_addr,
    input  wire [15:0] score_base,
    output reg  [1:0]  payload_lanes,
    output wire [8:0]  packed_word,
    output reg         witness_window
);
    wire [23:0] addr = {word_addr, 1'b0};
    wire [23:0] gbase = {8'h10, score_base};
    reg [23:0] offset;
    assign packed_word = offset[9:1];

    always @* begin
        payload_lanes = 2'b00;
        witness_window = 1'b0;
        offset = 24'd0;
        case ((PROFILE == 1 && alt_map) ? 0 : PROFILE)
            0: if (addr >= 24'h10029a && addr < 24'h10033e) begin
                payload_lanes = 2'b11;
                witness_window = 1'b1;
                offset = addr - 24'h10029a;
            end
            1: if (addr >= 24'h1002d0 && addr < 24'h10036e) begin
                payload_lanes = 2'b11;
                witness_window = 1'b1;
                offset = addr - 24'h1002d0;
            end else if (addr >= 24'h1003c4 && addr <= 24'h100416) begin
                payload_lanes = addr == 24'h100416 ? 2'b10 : 2'b11;
                witness_window = 1'b1;
                offset = addr - 24'h1003c4 + 24'd158;
            end
            2: if (score_base == 16'hca4c || score_base == 16'hca4e) begin
                witness_window = addr >= gbase && addr < gbase + 24'd240;
                if (addr >= gbase && addr < gbase + 24'd236) begin
                    payload_lanes = 2'b11;
                    offset = addr - gbase;
                end
            end
            3: begin
                witness_window = addr >= 24'h20fa24 && addr < 24'h20fd34;
                if (addr >= 24'h20fa20 && addr < 24'h20fd30) begin
                    payload_lanes = 2'b11;
                    offset = addr - 24'h20fa20;
                end
            end
            default: begin end
        endcase
    end
endmodule

// Board RAM owner: port 0 serves the CPU, port 1 serves read views or state/persistence/DMA (in that priority).
module rzmem_owner #(
  parameter         PROFILE = "garegga",
  parameter integer TAGW    = 4
) (
  input  logic scratch_en,   // enable the unused-palette scratch window (Sorcer/Kingdom)
  input  logic late_en,      // early profile acting as a late board (work RAM only)
  input  logic              clk,
  input  logic              rst,
  // control
  input  logic              cpu_quiesce,
  input  logic              hold_cert,
  input  logic              dma_enable,
  input  logic              write_block,
  output logic              profile_ok,
  output logic              idle,
  // primary request / response
  input  logic              cpu_valid,
  output logic              cpu_ready,
  input  logic [5:0]        cpu_endpoint,
  input  logic [22:0]       cpu_index,
  input  logic              cpu_write,
  input  logic [1:0]        cpu_be,
  input  logic [15:0]       cpu_wdata,
  input  logic [TAGW-1:0]   cpu_tag,
  output logic              cpu_rsp_valid,    // one cycle after accept
  input  logic              cpu_rsp_ready,
  output logic [15:0]       cpu_rsp_data,
  output logic [1:0]        cpu_rsp_driven,
  output logic [TAGW-1:0]   cpu_rsp_tag,
  output logic              cpu_rsp_error,
  // View buses: eight region slots, least significant first; absent or read-only regions ignore writes.
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [8*15-1:0]   view_addr,
  input  logic [8*16-1:0]   view_wdata,
  input  logic [8*2-1:0]    view_we,
  /* verilator lint_on UNUSEDSIGNAL */
  output wire  [8*16-1:0]   view_data,
  output wire  [7:0]        view_valid,       // low after reset, an out-of-range address or a secondary access
  // secondary clients: 0 state, 1 persistence, 2 DMA (client c at c*W +: W)
  input  logic [2:0]        aux_valid,
  output logic [2:0]        aux_ready,
  input  logic [3*3-1:0]    aux_region,
  input  logic [3*15-1:0]   aux_addr,
  input  logic [3*16-1:0]   aux_wdata,
  input  logic [3*2-1:0]    aux_we,
  input  logic [3*TAGW-1:0] aux_tag,
  output logic [2:0]        aux_rsp_valid,    // one cycle after grant
  input  logic [2:0]        aux_rsp_ready,
  output logic [3*16-1:0]   aux_rsp_data,
  output logic [3*TAGW-1:0] aux_rsp_tag,
  output logic [2:0]        aux_rsp_error,
  // work-RAM CPU write observation
  output logic              wram_commit,
  output logic [14:0]       wram_word,
  output logic [15:0]       wram_data,
  output logic [1:0]        wram_be,
    output wire [29:0] palette_commit
);
  // ------------------------------------------------------------------ profile
  /* verilator lint_off WIDTHEXPAND */
  localparam integer PID     = (PROFILE == "garegga")  ? 3 :
                               (PROFILE == "sorcer")   ? 1 :
                               (PROFILE == "kingdom")  ? 2 :
                               (PROFILE == "batrider") ? 4 :
                               (PROFILE == "bakraid")  ? 5 : 0;
  /* verilator lint_on WIDTHEXPAND */
  localparam         EARLY   = (PID == 1) || (PID == 2) || (PID == 3);
  localparam         LATE    = (PID == 4) || (PID == 5);
  localparam         SCRATCH = (PID == 1) || (PID == 2);   // unused_palette_ram window (region 7)
  localparam integer NREG    = EARLY ? 8 : (LATE ? 1 : 0);

  assign profile_ok = (NREG != 0);
  // An early-profile build with late_en behaves as the late profile: region 0 only.
  wire late_now  = LATE || (EARLY && late_en);
  wire early_now = EARLY && !late_en;

  // RAM window sizes and bases (words), shared by the region table, cpu_bind and the range tests.
  localparam int unsigned W_WORK      = 32768;            // work RAM (late: two halves)
  localparam int unsigned W_SHARED    = 8192;             // shared Z80 RAM
  localparam int unsigned W_PALETTE   = 2048;
  localparam int unsigned W_TEXT_MAP  = 4096;
  localparam int unsigned W_TEXT_SEL  = 2048;
  localparam int unsigned W_TEXT_SCR  = 256;
  localparam int unsigned B_TEXT_WORK = 256;              // first physical word of the text work window
  localparam int unsigned W_TEXT_WORK = 1792;
  localparam int unsigned W_SCRATCH   = 1024;             // unused palette RAM window
  localparam int unsigned W_HALF      = W_WORK / 2;       // late work RAM half

  // Region sizes (words), address and data widths; early region 1 is 8 bits wide.
  function automatic integer region_words(input integer r);
    if (EARLY) case (r)
      0: region_words = W_WORK;     1: region_words = W_SHARED;   2: region_words = W_PALETTE;
      3: region_words = W_TEXT_MAP; 4: region_words = W_TEXT_SEL; 5: region_words = W_TEXT_SCR;
      6: region_words = B_TEXT_WORK + W_TEXT_WORK;              7: region_words = W_SCRATCH;
      default: region_words = 0;
    endcase
    else if (LATE) region_words = (r == 0) ? W_WORK : 0;
    else region_words = 0;
  endfunction

  function automatic integer region_aw(input integer r);
    region_aw = (region_words(r) > 1) ? $clog2(region_words(r)) : 15;
  endfunction

  function automatic integer region_dw(input integer r);
    region_dw = (EARLY && r == 1) ? 8 : 16;
  endfunction

  // CPU endpoint binding: {valid, region[2:0], base[14:0], words[15:0], lanes[1:0]}
  function automatic [36:0] cpu_bind(input [5:0] ep);
    cpu_bind = 37'd0;
    if (early_now) begin
      case (ep)
        6'd3:  cpu_bind = {1'b1, 3'd0, 15'd0,              16'(W_WORK),      2'b11};   // work_ram
        6'd5:  cpu_bind = {1'b1, 3'd1, 15'd0,              16'(W_SHARED),    2'b01};   // shared_ram (low lane only)
        6'd17: cpu_bind = {1'b1, 3'd2, 15'd0,              16'(W_PALETTE),   2'b11};   // palette_ram
        6'd19: cpu_bind = {1'b1, 3'd3, 15'd0,              16'(W_TEXT_MAP),  2'b11};   // text_map
        6'd20: cpu_bind = {1'b1, 3'd4, 15'd0,              16'(W_TEXT_SEL),  2'b11};   // text_select
        6'd21: cpu_bind = {1'b1, 3'd5, 15'd0,              16'(W_TEXT_SCR),  2'b11};   // text_scroll
        6'd22: cpu_bind = {1'b1, 3'd6, 15'(B_TEXT_WORK),   16'(W_TEXT_WORK), 2'b11};   // text_work_ram
        6'd18: if (SCRATCH && scratch_en) cpu_bind = {1'b1, 3'd7, 15'd0, 16'(W_SCRATCH), 2'b11};   // unused_palette_ram
        default: cpu_bind = 37'd0;
      endcase
    end else if (late_now) begin
      case (ep)
        6'd3:  cpu_bind = {1'b1, 3'd0, 15'd0,          16'(W_HALF), 2'b11};   // work_ram, lower half
        6'd4:  cpu_bind = {1'b1, 3'd0, 15'(W_HALF),    16'(W_HALF), 2'b11};   // work_ram_upper, upper half
        default: cpu_bind = 37'd0;
      endcase
    end
  endfunction

  // ------------------------------------------------------------------ primary decode
  // Per-endpoint range test and physical word address.
  function automatic logic cpu_in_range(input [5:0] ep, input [22:0] idx);
    cpu_in_range = 1'b0;
    if (idx[22:16] == 7'd0) begin
      if (early_now) begin
        case (ep)
          6'd3:  cpu_in_range = {1'b0, idx[15:0]} < 17'(W_WORK);
          6'd5:  cpu_in_range = {1'b0, idx[15:0]} < 17'(W_SHARED);
          6'd17: cpu_in_range = {1'b0, idx[15:0]} < 17'(W_PALETTE);
          6'd19: cpu_in_range = {1'b0, idx[15:0]} < 17'(W_TEXT_MAP);
          6'd20: cpu_in_range = {1'b0, idx[15:0]} < 17'(W_TEXT_SEL);
          6'd21: cpu_in_range = {1'b0, idx[15:0]} < 17'(W_TEXT_SCR);
          6'd22: cpu_in_range = {1'b0, idx[15:0]} < 17'(W_TEXT_WORK);
          6'd18: cpu_in_range = SCRATCH && scratch_en && ({1'b0, idx[15:0]} < 17'(W_SCRATCH));
          default: cpu_in_range = 1'b0;
        endcase
      end else if (late_now) begin
        if (ep == 6'd3 || ep == 6'd4) cpu_in_range = {1'b0, idx[15:0]} < 17'(W_HALF);
      end
    end
  endfunction
  function automatic logic [14:0] cpu_phys(input [5:0] ep, input [22:0] idx);
    if (early_now && ep == 6'd22) cpu_phys = idx[14:0] + 15'(B_TEXT_WORK);
    else if (late_now && ep == 6'd4) cpu_phys = idx[14:0] + 15'(W_HALF);
    else cpu_phys = idx[14:0];
  endfunction

  logic [36:0] bnd;
  logic        b_valid;
  logic [2:0]  b_region;
  logic [14:0] b_base;
  logic [15:0] b_words;
  logic [1:0]  b_lanes;
  logic        req_ok, req_in_range, req_lanes_ok;
  logic [14:0] phys;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [1:0]  cpu_we_lanes;
  /* verilator lint_on UNUSEDSIGNAL */
  logic        accept, do_write, do_read;

  assign bnd        = cpu_bind(cpu_endpoint);
  assign b_valid    = bnd[36];
  assign b_region   = bnd[35:33];
  assign b_base     = bnd[32:18];
  assign b_words    = bnd[17:2];
  assign b_lanes    = bnd[1:0];
  assign req_in_range = cpu_in_range(cpu_endpoint, cpu_index);
  assign req_lanes_ok = (cpu_be != 2'b00) && ((cpu_be & b_lanes) != 2'b00);
  assign req_ok       = b_valid && req_in_range && req_lanes_ok;
  assign phys         = cpu_phys(cpu_endpoint, cpu_index);
`ifdef SIMULATION
  always_ff @(posedge clk) begin
    if (!rst && req_in_range !== ((cpu_index[22:16] == 7'd0) && (cpu_index[15:0] < b_words)))
      $fatal(1, "MEMOWNER_RANGE_MISMATCH");
    if (!rst && phys !== 15'(b_base + cpu_index[14:0])) $fatal(1, "MEMOWNER_PHYS_MISMATCH");
  end
`endif
  assign cpu_we_lanes = cpu_be & b_lanes;

  logic            busy;
  logic [TAGW-1:0] rsp_tag_q;
  logic            rsp_err_q, rsp_read_q;
  logic [1:0]      rsp_driven_q;
  logic [2:0]      rsp_region_q;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [14:0]     addr0_q;
  /* verilator lint_on UNUSEDSIGNAL */
  logic            hold_valid;
  logic [15:0]     hold_data;
  logic [15:0]     q0_sel;
  logic            cpu_consume;

  assign cpu_ready   = !busy && !cpu_quiesce && !hold_cert && !rst;
  assign accept      = cpu_valid && cpu_ready;
  assign do_write    = accept && req_ok && cpu_write && !write_block;
  assign do_read     = accept && req_ok && !cpu_write;
  assign cpu_rsp_valid = busy && !rst;     // no response-valid at the active reset edge
  assign cpu_consume = cpu_rsp_valid && cpu_rsp_ready;
  assign cpu_rsp_tag    = rsp_tag_q;
  assign cpu_rsp_error  = rsp_err_q;
  assign cpu_rsp_driven = rsp_driven_q;
  assign cpu_rsp_data   = rsp_read_q ? (hold_valid ? hold_data : q0_sel) : 16'd0;

  always_ff @(posedge clk) begin
    if (rst) begin
      busy         <= 1'b0;
      hold_valid   <= 1'b0;
      rsp_tag_q    <= '0;
      rsp_err_q    <= 1'b0;
      rsp_read_q   <= 1'b0;
      rsp_driven_q <= 2'b00;
      rsp_region_q <= 3'd0;
      addr0_q      <= 15'd0;
      hold_data    <= 16'd0;
    end else begin
      if (accept) begin
        busy         <= 1'b1;
        hold_valid   <= 1'b0;
        rsp_tag_q    <= cpu_tag;
        rsp_err_q    <= !req_ok;
        rsp_read_q   <= do_read;
        rsp_driven_q <= do_read ? b_lanes : 2'b00;
        rsp_region_q <= b_region;
        addr0_q      <= phys;
      end else if (cpu_consume) begin
        busy       <= 1'b0;
        hold_valid <= 1'b0;
      end else if (busy && !hold_valid) begin
        // hold the read word until it is consumed
        hold_valid <= 1'b1;
        hold_data  <= q0_sel;
      end
    end
  end

  // wram_commit pulses one cycle after each committed CPU work-RAM write.
  logic commit_q;
  assign wram_commit = commit_q && !rst;
  always_ff @(posedge clk) begin
    if (rst) begin
      commit_q    <= 1'b0;
      wram_word   <= 15'd0;
      wram_data   <= 16'd0;
      wram_be     <= 2'b00;
    end else begin
      commit_q    <= do_write && (b_region == 3'd0) && (NREG != 0);
      wram_word   <= phys;
      wram_data   <= cpu_wdata;
      wram_be     <= cpu_be;
    end
  end

  // ------------------------------------------------------------------ secondary arbitration
  logic [2:0]      elig, req, grant;
  logic            aux_accept, aux_busy, aux_consume;
  logic [1:0]      sel_client, aux_client_q;
  logic [2:0]      sel_region, aux_region_q;
  logic [14:0]     sel_addr;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [15:0]     sel_wdata;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [1:0]      sel_we;
  logic [TAGW-1:0] sel_tag, aux_tag_q;
  logic            sel_ok, sel_region_ok, sel_addr_ok, sel_we_ok, sel_byte_region, sel_dma_ok;
  logic            aux_err_q, aux_read_q, aux_hold_valid;
  logic [15:0]     aux_hold_data, q1_sel;
  integer          sel_words;

  assign elig[0] = hold_cert;
  assign elig[1] = hold_cert;
  assign elig[2] = dma_enable && !hold_cert && late_now;
  assign req     = aux_valid & elig;
  assign grant[0] = !aux_busy && !rst && req[0];
  assign grant[1] = !aux_busy && !rst && req[1] && !req[0];
  assign grant[2] = !aux_busy && !rst && req[2] && !req[0] && !req[1];
  assign aux_ready  = grant;
  assign aux_accept = |grant;
  assign sel_client = grant[0] ? 2'd0 : (grant[1] ? 2'd1 : 2'd2);
  assign sel_region = aux_region[sel_client*3 +: 3];
  assign sel_addr   = aux_addr[sel_client*15 +: 15];
  assign sel_wdata  = aux_wdata[sel_client*16 +: 16];
  assign sel_we     = aux_we[sel_client*2 +: 2];
  assign sel_tag    = aux_tag[sel_client*TAGW +: TAGW];

  always_comb begin
    sel_words = region_words({29'd0, sel_region});
  end
  assign sel_region_ok   = (NREG != 0) && (late_now ? sel_region == 3'd0 : ({29'd0, sel_region} < NREG));
  assign sel_addr_ok     = sel_region_ok && ({17'd0, sel_addr} < sel_words);
  assign sel_byte_region = early_now && (sel_region == 3'd1);
  assign sel_we_ok       = !(sel_byte_region && (sel_we == 2'b10));   // upper-byte-only write of 8-bit storage
  assign sel_dma_ok      = (sel_client != 2'd2) || ((sel_region == 3'd0) && (sel_we == 2'b00));
  assign sel_ok          = sel_region_ok && sel_addr_ok && sel_we_ok && sel_dma_ok;

  // Per-client form of sel_ok: addr below the region's word count.
  function automatic logic aux_addr_fits(input [2:0] region, input [14:0] addr);
    aux_addr_fits = 1'b0;
    for (int r = 0; r < 8; r++)
      if (region == 3'(r)) aux_addr_fits = {17'd0, addr} < 32'(region_words(r));
  endfunction
  function automatic logic aux_client_ok(input [1:0] c, input [2:0] region, input [14:0] addr,
                                         input [1:0] we);
    logic region_ok;
    region_ok = (NREG != 0) && (late_now ? region == 3'd0 : ({29'd0, region} < NREG));
    aux_client_ok = region_ok && aux_addr_fits(region, addr) &&
                    !(early_now && region == 3'd1 && we == 2'b10) &&
                    ((c != 2'd2) || ((region == 3'd0) && (we == 2'b00)));
  endfunction
  logic [2:0] aux_ok;
  assign aux_ok[0] = aux_client_ok(2'd0, aux_region[0 +: 3], aux_addr[0 +: 15], aux_we[0 +: 2]);
  assign aux_ok[1] = aux_client_ok(2'd1, aux_region[3 +: 3], aux_addr[15 +: 15], aux_we[2 +: 2]);
  assign aux_ok[2] = aux_client_ok(2'd2, aux_region[6 +: 3], aux_addr[30 +: 15], aux_we[4 +: 2]);
`ifdef SIMULATION
  always_ff @(posedge clk)
    if (aux_accept && aux_ok[sel_client] !== sel_ok) $fatal(1, "MEMOWNER_AUX_OK_MISMATCH");
`endif

  always_ff @(posedge clk) begin
    if (rst) begin
      aux_busy       <= 1'b0;
      aux_hold_valid <= 1'b0;
      aux_client_q   <= 2'd0;
      aux_region_q   <= 3'd0;
      aux_tag_q      <= '0;
      aux_err_q      <= 1'b0;
      aux_read_q     <= 1'b0;
      aux_hold_data  <= 16'd0;
    end else begin
      if (aux_accept) begin
        aux_busy       <= 1'b1;
        aux_hold_valid <= 1'b0;
        aux_client_q   <= sel_client;
        aux_region_q   <= sel_region;
        aux_tag_q      <= sel_tag;
        aux_err_q      <= !sel_ok;
        aux_read_q     <= sel_ok && (sel_we == 2'b00);
      end else if (aux_consume) begin
        aux_busy       <= 1'b0;
        aux_hold_valid <= 1'b0;
      end else if (aux_busy && !aux_hold_valid) begin
        aux_hold_valid <= 1'b1;
        aux_hold_data  <= q1_sel;
      end
    end
  end

  logic [15:0] aux_data_now;
  assign aux_data_now = aux_read_q ? (aux_hold_valid ? aux_hold_data : q1_sel) : 16'd0;
  assign aux_consume  = aux_busy && aux_rsp_ready[aux_client_q];

  genvar c;
  generate
    for (c = 0; c < 3; c = c + 1) begin : g_aux_rsp
      assign aux_rsp_valid[c]              = aux_busy && !rst && (aux_client_q == c);
      assign aux_rsp_data[c*16 +: 16]      = (aux_busy && (aux_client_q == c)) ? aux_data_now : 16'd0;
      assign aux_rsp_tag[c*TAGW +: TAGW]   = (aux_busy && (aux_client_q == c)) ? aux_tag_q : '0;
      assign aux_rsp_error[c]              = aux_busy && (aux_client_q == c) && aux_err_q;
    end
  endgenerate

  assign idle = !busy && !aux_busy;
  wire palette_cpu = do_write && b_region == 3'd2;
  wire palette_aux = aux_accept && sel_ok && sel_region == 3'd2 && (|sel_we);
  assign palette_commit = palette_cpu ? {1'b1, phys[10:0], cpu_wdata, cpu_we_lanes} :
                          palette_aux ? {1'b0, sel_addr[10:0], sel_wdata, sel_we} : 30'd0;

  // ------------------------------------------------------------------ storage and ports
  logic [15:0] q0_r [0:7];
  logic [15:0] q1_r [0:7];

  genvar r;
  generate
    for (r = 0; r < 8; r = r + 1) begin : g_region
      if (r < NREG) begin : g_present
        localparam integer AW = region_aw(r);
        localparam integer DW = region_dw(r);
        localparam integer WORDS = region_words(r);
        logic [AW-1:0]   a0, a1;
        logic [DW-1:0]   d0, d1, q0, q1;
        logic [DW/8-1:0] w0, w1;
        logic            stolen, view_oob;
        logic [2:0]      take;   // take[c] == aux_accept && sel_ok && sel_region == r && sel_client == c

        // Port 0 holds the accepted CPU address until its response is consumed.
        assign a0 = accept ? phys[AW-1:0] : addr0_q[AW-1:0];
        assign d0 = cpu_wdata[DW-1:0];
        if (DW == 8) begin : g_w0b
          assign w0 = do_write && (b_region == r) ? cpu_we_lanes[0] : 1'b0;
        end else begin : g_w0w
          assign w0 = (do_write && (b_region == r)) ? cpu_we_lanes : 2'b00;
        end

        // Port 1 serves the view except on the edge a valid secondary access is granted.
        assign take[0]  = grant[0] && aux_ok[0] && (aux_region[0 +: 3] == r);
        assign take[1]  = grant[1] && aux_ok[1] && (aux_region[3 +: 3] == r);
        assign take[2]  = grant[2] && aux_ok[2] && (aux_region[6 +: 3] == r);
        assign stolen   = |take;
        assign view_oob = ({17'd0, view_addr[r*15 +: 15]} >= WORDS);
        assign a1 = take[0] ? aux_addr[0 +: AW] : take[1] ? aux_addr[15 +: AW] :
                    take[2] ? aux_addr[30 +: AW] : view_addr[r*15 +: AW];
        assign d1 = take[0] ? aux_wdata[0 +: DW] : take[1] ? aux_wdata[16 +: DW] :
                    take[2] ? aux_wdata[32 +: DW] : view_wdata[r*16 +: DW];
`ifdef SIMULATION
        always_ff @(posedge clk) begin
          if (stolen !== (aux_accept && sel_ok && (sel_region == r))) $fatal(1, "MEMOWNER_STOLEN_MISMATCH");
          if (stolen && (a1 !== sel_addr[AW-1:0] || d1 !== sel_wdata[DW-1:0] ||
                         w1 !== sel_we[DW/8-1:0])) $fatal(1, "MEMOWNER_PORT1_MISMATCH");
        end
`endif
        if (DW == 8) begin : g_w1b
          // Z80 shared-RAM writes (low byte) apply only when hold and reset are clear.
          logic z80_we;
          assign z80_we = !hold_cert && !rst && !view_oob && view_we[r*2];
          assign w1 = take[0] ? aux_we[0] : take[1] ? aux_we[2] : take[2] ? aux_we[4] : z80_we;
        end else begin : g_w1w
          assign w1 = take[0] ? aux_we[0 +: 2] : take[1] ? aux_we[2 +: 2] :
                      take[2] ? aux_we[4 +: 2] : 2'b00;
        end

        raizing_bram #(.DW(DW), .AW(AW)) u_ram (
          .clk0(clk), .addr0(a0), .data0(d0), .we0(w0), .q0(q0),
          .clk1(clk), .addr1(a1), .data1(d1), .we1(w1), .q1(q1)
        );

        if (DW == 8) begin : g_q8
          assign q0_r[r] = {8'd0, q0};
          assign q1_r[r] = {8'd0, q1};
        end else begin : g_q16
          assign q0_r[r] = q0;
          assign q1_r[r] = q1;
        end
        assign view_data[r*16 +: 16] = q1_r[r];

        logic vv;
        always_ff @(posedge clk) begin
          if (rst) vv <= 1'b0;
          else     vv <= !stolen && !view_oob;
        end
        assign view_valid[r] = vv && !rst;
      end else begin : g_absent
        assign q0_r[r] = 16'd0;
        assign q1_r[r] = 16'd0;
        assign view_data[r*16 +: 16] = 16'd0;
        assign view_valid[r] = 1'b0;
      end
    end
  endgenerate

  assign q0_sel = q0_r[rsp_region_q];
  assign q1_sel = q1_r[aux_region_q];
endmodule

// Save-state access to RAM owner regions by chunk select: size query or single-word read/write.
module rzmem_ss_regions (
    input logic clk, reset, access_enable,
    input logic [63:0] ss_data,
    input logic [31:0] ss_addr,
    input logic [7:0] ss_select,
    input logic ss_write, ss_read, ss_query,
    output logic [63:0] ss_data_out,
    output logic ss_ack, active,
    output logic req_valid,
    input logic req_ready,
    output logic [2:0] req_region,
    output logic [14:0] req_addr,
    output logic [15:0] req_data,
    output logic [1:0] req_we,
    input logic rsp_valid,
    output logic rsp_ready,
    input logic [15:0] rsp_data,
    input logic rsp_error
);
    typedef enum logic [1:0] {IDLE, OFFER, RESPONSE, RELEASE} phase_t;
    phase_t phase;
    logic [3:0] region;
    logic [31:0] count;

    // Chunk select -> RAM owner region and word count.
    always_comb begin
        case (ss_select)
            8'd2:  begin region = 0; count = 32768; end
            8'd16: begin region = 1; count = 8192; end
            8'd38: begin region = 2; count = 2048; end
            8'd39: begin region = 3; count = 4096; end
            8'd40: begin region = 4; count = 2048; end
            8'd41: begin region = 5; count = 256; end
            8'd42: begin region = 6; count = 2048; end
            8'd43: begin region = 7; count = 1024; end
            default: begin region = 8; count = 0; end
        endcase
    end

    assign req_valid = !reset && phase == OFFER;
    assign rsp_ready = !reset && phase == RESPONSE;

    always_ff @(posedge clk) begin
        if (reset) begin
            phase <= IDLE;
            ss_data_out <= 0;
            ss_ack <= 0;
            active <= 0;
            req_region <= 0;
            req_addr <= 0;
            req_data <= 0;
            req_we <= 0;
        end else case (phase)
            IDLE: if (!region[3]) begin
                if (ss_query) begin
                    ss_data_out <= {ss_select, 22'd0, 1'b0, region != 1, count};
                    ss_ack <= 1;
                    phase <= RELEASE;
                end else if (access_enable && (ss_read || ss_write)) begin
                    if (ss_addr >= count) begin
                        ss_data_out <= 0;
                        ss_ack <= 1;
                        phase <= RELEASE;
                    end else begin
                        req_region <= region[2:0];
                        req_addr <= ss_addr[14:0];
                        req_data <= ss_data[15:0];
                        req_we <= ss_write ? (region == 1 ? 2'b01 : 2'b11) : 2'b00;
                        active <= 1;
                        phase <= OFFER;
                    end
                end
            end
            OFFER: if (req_ready) phase <= RESPONSE;
            RESPONSE: if (rsp_valid) begin
                ss_data_out <= (rsp_error || |req_we) ? 64'd0 : {48'd0, rsp_data};
                ss_ack <= 1;
                phase <= RELEASE;
            end
            RELEASE: if (!(ss_query || ss_read || ss_write)) begin
                ss_ack <= 0;
                active <= 0;
                phase <= IDLE;
            end
        endcase
    end
endmodule

// Synchronous true-dual-port storage; no payload reset or extra output stage.
module raizing_bram #(
    parameter integer DW = 8,
    parameter integer AW = 10
) (
    input                   clk0,
    input       [AW-1:0]    addr0,
    input       [DW-1:0]    data0,
    input       [DW/8-1:0]  we0,
    output      [DW-1:0]    q0,
    input                   clk1,
    input       [AW-1:0]    addr1,
    input       [DW-1:0]    data1,
    input       [DW/8-1:0]  we1,
    output      [DW-1:0]    q1
);
    // Same-port writes read back new data; mixed-port read/write collisions are undefined.
    genvar lane;
    generate for (lane = 0; lane < DW/8; lane = lane + 1) begin : bytes
        raizing_bram_byte #(.AW(AW)) storage (
            .clk0(clk0),.addr0(addr0),.data0(data0[lane*8 +: 8]),
            .we0(we0[lane]),.q0(q0[lane*8 +: 8]),
            .clk1(clk1),.addr1(addr1),.data1(data1[lane*8 +: 8]),
            .we1(we1[lane]),.q1(q1[lane*8 +: 8])
        );
    end endgenerate
`ifdef SIMULATION
    initial begin
        if ((DW != 8 && DW != 16) || AW < 1 || AW > 15)
            $fatal(1, "Unsupported RAM dimensions");
    end
`endif
endmodule

// One byte lane of inferred true-dual-port RAM.
module raizing_bram_byte #(parameter integer AW = 10) (
    input clk0, clk1,
    input [AW-1:0] addr0, addr1,
    input [7:0] data0, data1,
    input we0, we1,
    output reg [7:0] q0, q1
);
    (* ramstyle = "no_rw_check" *) reg [7:0] mem [0:(1<<AW)-1];
    always @(posedge clk0) begin
        if (we0) begin
            mem[addr0] <= data0;
            q0 <= data0;
        end else q0 <= mem[addr0];
    end
    always @(posedge clk1) begin
        if (we1) begin
            mem[addr1] <= data1;
            q1 <= data1;
        end else q1 <= mem[addr1];
    end
`ifdef SIMULATION
    initial for (integer word_index = 0; word_index < (1<<AW); word_index = word_index + 1)
        mem[word_index] = '0;
`endif
endmodule
