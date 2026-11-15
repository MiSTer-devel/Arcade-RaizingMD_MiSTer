// SPDX-License-Identifier: GPL-3.0-or-later
// Shared-chip sockets: a board drives each chip's *_in_t and reads its *_out_t; raizing_board wires the selected board to the chip.
package raizing_socket_pkg;

  // fx68k
  typedef struct packed {
    logic clk;
    logic HALTn;
    logic extReset;
    logic pwrUp;
    logic enPhi1;
    logic enPhi2;
    logic DTACKn;
    logic VPAn;
    logic BERRn;
    logic BRn;
    logic BGACKn;
    logic IPL0n;
    logic IPL1n;
    logic IPL2n;
    logic [15:0] iEdb;
  } cpu_in_t;

  typedef struct packed {
    logic eRWn;
    logic ASn;
    logic LDSn;
    logic UDSn;
    logic E;
    logic VMAn;
    logic FC0;
    logic FC1;
    logic FC2;
    logic BGn;
    logic oRESETn;
    logic oHALTEDn;
    logic [15:0] oEdb;
    logic [22:0] eab;
  } cpu_out_t;

  // rzctx_core
  typedef struct packed {
    logic clk;
    logic rst;
    logic cpu_tick;
    logic [22:0] ram_lo;
    logic [22:0] ram_hi;
    logic cpu_as_n;
    logic cpu_uds_n;
    logic cpu_lds_n;
    logic cpu_rw;
    logic [2:0] cpu_fc;
    logic [22:0] cpu_addr;
    logic [15:0] cpu_dout;
    logic cpu_halted_n;
    logic bus_done;
    logic cmd_valid;
    logic [2:0] cmd_op;
    logic ctx_req;
    logic ctx_we;
    logic ctx_bank;
    logic [5:0] ctx_idx;
    logic [15:0] ctx_wdata;
  } ctx_in_t;

  typedef struct packed {
    logic bus_claim;
    logic active;
    logic cpu_dtack_n;
    logic cpu_vpa_n;
    logic [15:0] cpu_din;
    logic ipl7_req;
    logic cpu_reset;
    logic rsp_valid;
    logic rsp_ok;
    logic [3:0] rsp_code;
    logic ctx_ack;
    logic ctx_nak;
    logic [15:0] ctx_rdata;
    logic [3:0] st_phase;
    logic [2:0] st_mode;
    logic st_busy;
    logic st_parked;
    logic st_held;
    logic st_cap_valid;
    logic st_admitted;
    logic st_stale7;
    logic st_err_unexp;
    logic evt_valid;
    logic [3:0] evt_code;
  } ctx_out_t;

  // rzmem_owner
  typedef struct packed {
    logic scratch_en;
    logic late_en;
    logic clk;
    logic rst;
    logic cpu_quiesce;
    logic hold_cert;
    logic dma_enable;
    logic write_block;
    logic cpu_valid;
    logic [5:0] cpu_endpoint;
    logic [22:0] cpu_index;
    logic cpu_write;
    logic [1:0] cpu_be;
    logic [15:0] cpu_wdata;
    logic cpu_tag;
    logic cpu_rsp_ready;
    logic [119:0] view_addr;
    logic [127:0] view_wdata;
    logic [15:0] view_we;
    logic [2:0] aux_valid;
    logic [8:0] aux_region;
    logic [44:0] aux_addr;
    logic [47:0] aux_wdata;
    logic [5:0] aux_we;
    logic [2:0] aux_tag;
    logic [2:0] aux_rsp_ready;
  } mem_in_t;

  typedef struct packed {
    logic profile_ok;
    logic idle;
    logic cpu_ready;
    logic cpu_rsp_valid;
    logic [15:0] cpu_rsp_data;
    logic [1:0] cpu_rsp_driven;
    logic cpu_rsp_tag;
    logic cpu_rsp_error;
    logic [127:0] view_data;
    logic [7:0] view_valid;
    logic [2:0] aux_ready;
    logic [2:0] aux_rsp_valid;
    logic [47:0] aux_rsp_data;
    logic [2:0] aux_rsp_tag;
    logic [2:0] aux_rsp_error;
    logic wram_commit;
    logic [14:0] wram_word;
    logic [15:0] wram_data;
    logic [1:0] wram_be;
    logic [29:0] palette_commit;
  } mem_out_t;

  // rztdma_top
  typedef struct packed {
    logic clk;
    logic reset;
    logic text_dma_start;
    logic palette_dma_start;
    logic wram_readack;
    logic [15:0] wram_data;
    logic palette_ready;
    logic cpu_mirror_we;
    logic [13:0] cpu_mirror_address;
    logic [15:0] cpu_mirror_data;
    logic [1:0] cpu_mirror_be;
    logic [13:0] glyph_raddr;
    logic [11:0] text_raddr;
    logic [7:0] select_raddr;
    logic [7:0] scroll_raddr;
    logic hold_request;
    logic state_access_enable;
    logic [63:0] SS_DATA;
    logic [31:0] SS_ADDR;
    logic [7:0] SS_SELECT;
    logic SS_WRITE;
    logic SS_READ;
    logic SS_QUERY;
  } dma_in_t;

  typedef struct packed {
    logic start_ready;
    logic busy;
    logic done;
    logic wram_req;
    logic [14:0] wram_addr;
    logic palette_valid;
    logic [10:0] palette_addr;
    logic [15:0] palette_data;
    logic [1:0] palette_be;
    logic text_unpacked;
    logic ctx_mirror_commit;
    logic ctx_glyph_valid;
    logic [15:0] ctx_glyph_before;
    logic [15:0] glyph_rdata;
    logic [15:0] text_rdata;
    logic [15:0] select_rdata;
    logic [15:0] scroll_rdata;
    logic held;
    logic [63:0] SS_DATA_OUT;
    logic SS_ACK;
  } dma_out_t;

  // raizing_z80
  typedef struct packed {
    logic clk;
    logic reset;
    logic cen;
    logic wait_n;
    logic int_n;
    logic hold_request;
    logic nmi_n;
    logic busrq_n;
    logic canonical_hold;
    logic restore;
    logic [255:0] restore_state;
    logic [7:0] data_in;
  } z80_in_t;

  typedef struct packed {
    logic busak_n;
    logic held;
    logic held_base;          // held == held_base || (wait_n && stop_ready)
    logic stop_ready;
    logic canonical_ready;
    logic canonical_service;
    logic restore_busy;
    logic canonical_fault;
    logic [255:0] capture_state;
    logic restore_done;
    logic [15:0] address;
    logic [7:0] data_out;
    logic rd_n;
    logic wr_n;
    logic mreq_n;
    logic iorq_n;
    logic m1_n;
    logic halt_n;
  } z80_out_t;

  // rzopm_state_owner
  typedef struct packed {
    logic clk;
    logic reset;
    logic ym_ce;
    logic cpu_held;
    logic pcm_refill;
    logic canonical_hold;
    logic cpu_canonical_ready;
    logic restore_commit;
    logic cs_n;
    logic wr_n;
    logic a0;
    logic [7:0] din;
    logic [63:0] ss_data;
    logic [31:0] ss_addr;
    logic [7:0] ss_select;
    logic ss_write;
    logic ss_read;
    logic ss_query;
  } fm_in_t;

  typedef struct packed {
    logic [7:0] dout;
    logic irq_n;
    logic sample;
    logic [15:0] xleft;
    logic [15:0] xright;
    logic busy;
    logic fault;
    logic [63:0] ss_data_out;
    logic ss_ack;
  } fm_out_t;

  // rzopm_top
  typedef struct packed {
    logic clk;
    logic rst;
    logic chip_cen_n;
    logic chip_ic_n;
    logic cpu_cs_n;
    logic cpu_rd_n;
    logic cpu_wr_n;
    logic cpu_a0;
    logic [7:0] cpu_din;
    logic hold_cert;
    logic sx_req_valid;
    logic [3:0] sx_req_op;
    logic [5:0] sx_req_index;
    logic [63:0] sx_req_data;
    logic sx_rsp_ready;
  } opm_in_t;

  typedef struct packed {
    logic [7:0] cpu_dout;
    logic cpu_dout_oe;
    logic chip_phi1;
    logic chip_ct1;
    logic chip_ct2;
    logic chip_irq_n;
    logic chip_sh1;
    logic chip_sh2;
    logic chip_so;
    logic snd_r_strobe;
    logic snd_l_strobe;
    logic [15:0] snd_r;
    logic [15:0] snd_l;
    logic [15:0] snd_r_ex;
    logic [15:0] snd_l_ex;
    logic mon_accept;
    logic mon_is_data;
    logic [7:0] mon_byte;
    logic mon_idle;
    logic sx_req_ready;
    logic sx_rsp_valid;
    logic [3:0] sx_rsp_status;
    logic [63:0] sx_rsp_data;
    logic [2:0] sx_phase;
    logic sx_owned;
    logic sx_muted;
    logic [3:0] sx_error;
    logic [7:0] sx_diag;
  } opm_out_t;

  // ss_jt6295
  typedef struct packed {
    logic rst;
    logic filter_rst;
    logic clk;
    logic state_freeze;
    logic cen;
    logic ss;
    logic wrn;
    logic [7:0] din;
    logic [7:0] rom_data;
    logic rom_ok;
    logic auto_ss_rd;
    logic auto_ss_wr;
    logic [31:0] auto_ss_data_in;
    logic [7:0] auto_ss_device_idx;
    logic [15:0] auto_ss_state_idx;
    logic [7:0] auto_ss_base_device_idx;
  } oki_in_t;

  typedef struct packed {
    logic state_frozen;
    logic rom_request;
    logic resume_busy;
    logic [7:0] dout;
    logic [17:0] rom_addr;
    logic [13:0] sound;
    logic sample;
    logic [31:0] auto_ss_data_out;
    logic auto_ss_ack;
  } oki_out_t;

  // raizing_video
  typedef struct packed {
    logic clk;
    logic reset;
    logic pixel_ce;
    logic flip;
    logic [8:0] hs_start;
    logic [8:0] hs_end;
    logic [8:0] vs_start;
    logic [8:0] vs_end;
    logic gp_cs;
    logic gp_select_reg;
    logic gp_write_reg;
    logic gp_write_ram;
    logic gp_read_ram_h;
    logic gp_read_ram_l;
    logic gp_set_ram_ptr;
    logic [15:0] gp_din;
    logic [1:0] gp_be;
    logic [127:0] gfx_data;
    logic [3:0] gfx_ok;
    logic object_req_ready;
    logic object_rsp_valid;
    logic [31:0] object_rsp_data;
    logic object_rsp_error;
    logic object_port_idle;
    logic gp_objectbank_wr;
    logic [2:0] gp_objectbank_slot;
    logic [15:0] PALRAM_DATA;
    logic [15:0] TEXTROM_DATA;
    logic [15:0] TEXTVRAM_DATA;
    logic [15:0] TEXTSELECT_DATA;
    logic [15:0] TEXTSCROLL_DATA;
    logic SS_FREEZE;
    logic STATE_HOLD;
    logic [63:0] SS_DATA;
    logic [31:0] SS_ADDR;
    logic [7:0] SS_SELECT;
    logic SS_WRITE;
    logic SS_READ;
    logic SS_QUERY;
  } video_in_t;

  typedef struct packed {
    logic gp_ack;
    logic [15:0] gp_dout;
    logic vint_n;
    logic cpu_hsync_n;
    logic cpu_vsync_n;
    logic cpu_fblank;
    logic [8:0] hcount;
    logic [8:0] vcount;
    logic [3:0] gfx_req;
    logic [95:0] gfx_addr;
    logic object_req_valid;
    logic [23:0] object_req_addr;
    logic object_rsp_ready;
    logic object_deadline_miss;
    logic object_row_skipped;
    logic object_ownership_error;
    logic object_error;
    logic [10:0] PALRAM_ADDR;
    logic [13:0] TEXTROM_ADDR;
    logic [11:0] TEXTVRAM_ADDR;
    logic [7:0] TEXTSELECT_ADDR;
    logic [7:0] TEXTSCROLL_ADDR;
    logic [7:0] red;
    logic [7:0] green;
    logic [7:0] blue;
    logic hs;
    logic vs;
    logic lhbl;
    logic lvbl;
    logic lhbl_dly;
    logic lvbl_dly;
    logic SS_QUIESCED;
    logic [63:0] SS_DATA_OUT;
    logic SS_ACK;
    logic SS_ERROR;
    logic palette_hold;
    logic palette_blank;
  } video_out_t;

endpackage
