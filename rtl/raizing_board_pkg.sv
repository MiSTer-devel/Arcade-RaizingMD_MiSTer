// SPDX-License-Identifier: GPL-3.0-or-later
// Board IDs (MRA <rom index="1"> board byte), their per-module profile numbers, ROM region sizes and save-state words.
package raizing_board_pkg;

  typedef enum logic [2:0] {
    RZB_NONE     = 3'd0,
    RZB_SORCER   = 3'd1,
    RZB_KINGDOM  = 3'd2,
    RZB_GAREGGA  = 3'd3,
    RZB_BATRIDER = 3'd4,
    RZB_BAKRAID  = 3'd5
  } board_e;

  // One-hot mask bit of a board ID.
  function automatic logic [7:0] board_bit(input board_e b);
    return 8'd1 << b;
  endfunction
  // Boards this image accepts.
  localparam logic [7:0] RUNTIME_BOARDS = (8'd1 << RZB_SORCER) | (8'd1 << RZB_KINGDOM) |
                                          (8'd1 << RZB_GAREGGA) | (8'd1 << RZB_BATRIDER) |
                                          (8'd1 << RZB_BAKRAID);

  // rzbus_router / rzmem_owner / rzearly_bus_binding PROFILE string (zero-padded packed literal).
  function automatic logic [63:0] bus_name(input board_e b);
    case (b)
      RZB_SORCER:   return "sorcer";
      RZB_KINGDOM:  return "kingdom";
      RZB_GAREGGA:  return "garegga";
      RZB_BATRIDER: return "batrider";
      RZB_BAKRAID:  return "bakraid";
      default:      return "none";
    endcase
  endfunction

  // rzgp_native_owner PROFILE (rz_video_binding GP_PROFILE).
  function automatic int gp_profile(input board_e b);
    case (b)
      RZB_GAREGGA:  return 1;
      RZB_BATRIDER: return 2;
      RZB_BAKRAID:  return 3;
      RZB_SORCER:   return 4;
      RZB_KINGDOM:  return 5;
      default:      return 0;
    endcase
  endfunction

  // Tile/sprite producer PROFILE (rz_video_binding RENDER_PROFILE).
  function automatic int render_profile(input board_e b);
    case (b)
      RZB_SORCER:   return 0;
      RZB_KINGDOM:  return 1;
      RZB_GAREGGA:  return 2;
      RZB_BATRIDER: return 3;
      RZB_BAKRAID:  return 4;
      default:      return -1;
    endcase
  endfunction

  // rzirq_pkg profile (RZIRQ_GAREGGA = 1 ... RZIRQ_BAKRAID = 5).
  function automatic int irq_profile(input board_e b);
    case (b)
      RZB_GAREGGA:  return 1;
      RZB_SORCER:   return 2;
      RZB_KINGDOM:  return 3;
      RZB_BATRIDER: return 4;
      RZB_BAKRAID:  return 5;
      default:      return 0;
    endcase
  endfunction

  // rzboard_inputs / rzscore_early PROFILE: Sorcer 0, Kingdom 1.
  function automatic int early_profile(input board_e b);
    return b == RZB_KINGDOM ? 1 : 0;
  endfunction

  // Staged ROM image size in bytes (MRA <rom index="0"> length).
  function automatic logic [26:0] rom_bytes(input board_e b);
    case (b)
      RZB_SORCER:  return 27'h02d8000;
      RZB_KINGDOM: return 27'h0598000;
      RZB_GAREGGA: return 27'h0a28000;
      RZB_BATRIDER: return 27'h1440000;
      RZB_BAKRAID: return 27'h1e20000;
      default:     return 27'h0;
    endcase
  endfunction

  // ROM region sizes in staged order: program, sound, graphics, text, PCM (Bakraid: YMZ280B), second OKI PCM (Batrider).
  function automatic logic [26:0] prog_bytes(input board_e b);
    case (b)
      RZB_SORCER:   return 27'h0080000;
      RZB_BATRIDER, RZB_BAKRAID: return 27'h0200000;
      default:      return 27'h0100000;
    endcase
  endfunction
  function automatic logic [26:0] sound_bytes(input board_e b);
    case (b)
      RZB_GAREGGA, RZB_BAKRAID: return 27'h0020000;
      RZB_BATRIDER: return 27'h0040000;
      default:      return 27'h0010000;
    endcase
  endfunction
  function automatic logic [26:0] gfx_bytes(input board_e b);
    case (b)
      RZB_KINGDOM: return 27'h0400000;
      RZB_GAREGGA: return 27'h0800000;
      RZB_BATRIDER, RZB_BAKRAID: return 27'h1000000;
      default:     return 27'h0200000;
    endcase
  endfunction
  function automatic logic [26:0] text_bytes(input board_e b);
    return (b == RZB_BATRIDER || b == RZB_BAKRAID) ? 27'h0 : 27'h0008000;   // late boards load text by DMA
  endfunction
  function automatic logic [26:0] pcm_bytes(input board_e b);
    case (b)
      RZB_KINGDOM: return 27'h0080000;
      RZB_GAREGGA, RZB_BATRIDER: return 27'h0100000;
      RZB_BAKRAID: return 27'h0c00000;
      default:     return 27'h0040000;
    endcase
  endfunction
  function automatic logic [26:0] pcm2_bytes(input board_e b);
    return b == RZB_BATRIDER ? 27'h0100000 : 27'h0;
  endfunction

  // Download byte-address width (largest image: Bakraid 0x1e20000).
  localparam int DL_ADDRESS_BITS = 25;
  // ROM client byte-address width (16 MiB late-board graphics).
  localparam int ROM_ADDR_BITS = 24;

  // Save-state format word: "RAIZ", version 1, board ID.
  function automatic logic [63:0] ss_format(input board_e b);
    return {32'h5241495A, 8'h01, 16'h0000, 5'd0, b};
  endfunction

  // Foreign save-state format words (not accepted).
  function automatic logic [63:0] native_ss_format(input board_e b);
    case (b)
      RZB_SORCER:  return 64'h534f524301000004;
      RZB_KINGDOM: return 64'h4b47525001000003;
      RZB_GAREGGA: return 64'h4741524501000003;
      default:     return 64'h0;
    endcase
  endfunction

  function automatic logic [63:0] native_ss_legacy(input board_e b);
    case (b)
      RZB_SORCER:  return 64'h534f524301000003;
      RZB_KINGDOM: return 64'h4b47525001000002;
      RZB_GAREGGA: return 64'h4741524501000002;
      default:     return 64'h0;
    endcase
  endfunction

  function automatic logic [63:0] ss_board(input board_e b);
    case (b)
      RZB_SORCER:  return 64'h0000000000001993;
      RZB_KINGDOM: return 64'h0000000000001994;
      RZB_GAREGGA: return 64'h0000000000001996;
      RZB_BATRIDER: return 64'h0000000000009704;
      RZB_BAKRAID: return 64'h455436382d563939;
      default:     return 64'h0;
    endcase
  endfunction

endpackage
