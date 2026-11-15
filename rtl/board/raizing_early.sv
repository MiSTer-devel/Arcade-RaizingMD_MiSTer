// SPDX-License-Identifier: GPL-3.0-or-later
// Early boards (Sorcer Striker, Kingdom Grandprix): score, sound, bus, CPU and board tops.

module rzscore_early #(
    parameter integer PROFILE = 0
) (
    input wire early_sorcer,   // Kingdom-profile owner configured as Sorcer
    input wire clk, reset, cpu_reset, state_active, hold_ack,
    input wire nv_download, nv_upload, nv_write, nv_read,
    input wire manual_save, autosave, osd_open,
    input wire [26:0] nv_addr,
    input wire [7:0] nv_data,
    output wire [7:0] nv_q,
    output wire nv_wait, upload_request, hold_request, active, dirty, ready,
    input wire normal_write,
    input wire [15:0] normal_addr, normal_data,
    input wire [1:0] normal_we,
    input wire [6:0] cpu_addr,
    input wire [15:0] cpu_data,
    input wire [1:0] cpu_we,
    output wire [15:0] cpu_q,
    input wire state_word_own, state_word_write, state_flags_write,
    input wire [6:0] state_word_addr,
    input wire [15:0] state_word_data,
    input wire [4:0] state_flags_in,
    output wire [15:0] state_word_q,
    output wire [4:0] state_flags_out
);
    generate if (PROFILE == 0 || PROFILE == 1) begin : service
        wire KING = PROFILE == 1 && !early_sorcer;
        wire [26:0] FILE_BYTES = KING ? 27'd241 : 27'd164;
        wire [6:0] LAST_WORD = KING ? 7'd120 : 7'd81;
        wire [15:0] HEAD = KING ? 16'h02d0 : 16'h029a;
        wire [15:0] HEAD_END = KING ? 16'h036c : 16'h033c;
        localparam [1:0] IDLE = 2'd0, INSTALL = 2'd1, CAPTURE = 2'd2;

        reg live_bank, valid, first, tail, last, ready_r, ready_deferred, dirty_r;
        reg [1:0] copy_mode;
        reg [6:0] copy_word;
        reg primed, install_bank, cap_core, cap_host_seen;
        reg dl_seen, dl_bad, dl_bank, pending, pending_bank;
        reg [7:0] dl_count;
        reg pub_valid, pub_table, pub_bank, snapshot_stale, upload_pulse;
        reg up_seen, up_bad, up_discard;
        reg [7:0] up_count;
        reg save_queued, manual_prev, osd_prev;

        wire restore = state_active && state_flags_write;
        wire state_port = state_active && state_word_own;
        wire initialized = first && last && (!KING || tail);
        wire download_busy = nv_download || dl_seen;
        wire start_dl = nv_download && !dl_seen;
        wire cap_abort = copy_mode == CAPTURE &&
                         (nv_download || (!nv_upload && (!cap_core || cap_host_seen)));
        wire host_upload = nv_upload && !up_discard;

        wire in_head = normal_addr >= HEAD && normal_addr <= HEAD_END;
        wire in_tail = KING && normal_addr >= 16'h03c4 && normal_addr <= 16'h0416;
        wire [15:0] head_delta = normal_addr - HEAD;
        wire [15:0] tail_delta = normal_addr - 16'h03c4;
        wire [6:0] normal_index = in_head ? head_delta[7:1] : 7'd79 + tail_delta[7:1];
        wire normal_accept = normal_write && !normal_addr[0] &&
                             !state_active && !hold_ack && !cpu_reset && !ready_r;
        wire witness = normal_accept && (&normal_we);
        wire hit_first = witness && !first && normal_addr == HEAD &&
                         normal_data == (KING ? 16'h0010 : 16'h0065);
        wire hit_tail = witness && KING && first && !tail &&
                        normal_addr == 16'h0416 && normal_data == 16'h3900;
        wire hit_last = witness && first && !last && (!KING || tail) &&
                        normal_addr == (KING ? 16'h03da : 16'h033c) &&
                        normal_data == (KING ? 16'hffff : 16'h0020);

        wire cpu_accept = !reset && !cpu_reset && !state_active && !hold_ack && ready_r;
        wire cpu_hi = cpu_accept && cpu_addr <= LAST_WORD && cpu_we[1];
        wire cpu_lo = cpu_accept && cpu_addr <= LAST_WORD &&
                      !(KING && cpu_addr == LAST_WORD) && cpu_we[0];
        wire cpu_commit = cpu_hi || cpu_lo;
        wire save_edge = (manual_save && !manual_prev) ||
                         (autosave && osd_open && !osd_prev && (dirty_r || cpu_commit));
        wire queue_save = save_edge && ready_r && !cpu_reset && !pending &&
                          !download_busy && !nv_upload && !pub_valid && copy_mode == IDLE;
        wire copy_slot = copy_mode == IDLE && !download_busy && !pub_valid;
        wire want_install = copy_slot && pending && initialized && !cpu_reset && !nv_upload;
        wire want_capture = copy_slot && !pending &&
                            ((host_upload && valid && !cpu_reset) ||
                             (!nv_upload && !cpu_reset && save_queued));
        wire copy_grant = hold_request && hold_ack;
        wire install_run = copy_mode == INSTALL && copy_grant;
        wire capture_run = copy_mode == CAPTURE && copy_grant;
        wire install_word = install_run && primed;
        wire capture_word = capture_run && primed;
        wire copy_final = copy_word == LAST_WORD;
        wire [6:0] fetch_word = primed ? copy_word + 7'd1 : copy_word;

        // Download into the staging bank not held by an install or a pending-image upload.
        wire next_dl_bank = (copy_mode == INSTALL) ? !install_bank :
                            (pub_valid && !pub_table) ? !pub_bank : 1'b0;
        wire [7:0] expected_dl = start_dl ? 8'd0 : dl_count;
        wire dl_address_ok = nv_addr == {19'd0, expected_dl} && nv_addr < FILE_BYTES;
        wire dl_sample = nv_download && nv_write;
        wire dl_store = !reset && !restore && dl_sample && dl_address_ok && (start_dl || !dl_bad);
        wire [7:0] dl_location = {start_dl ? next_dl_bank : dl_bank, nv_addr[7:1]};
        reg [7:0] stage_hi [0:255];
        reg [7:0] stage_lo [0:255];
        reg [7:0] stage_hi_q, stage_lo_q;
        wire read_pending = pub_valid && !pub_table;
        wire read_payload = nv_addr < FILE_BYTES;
        wire [7:0] stage_rd = install_run ? {install_bank, fetch_word} : {pub_bank, nv_addr[7:1]};
        always @(posedge clk) begin
            if (dl_store && !nv_addr[0]) stage_hi[dl_location] <= nv_data;
            if (dl_store && nv_addr[0]) stage_lo[dl_location] <= nv_data;
            if ((install_run && !(primed && copy_final)) || (read_pending && read_payload)) begin
                stage_hi_q <= stage_hi[stage_rd];
                stage_lo_q <= stage_lo[stage_rd];
            end
        end

        // Words past LAST_WORD and Kingdom's last low byte stay in bank 0; payload follows live_bank.
        reg [7:0] table_hi [0:255];
        reg [7:0] table_lo [0:255];
        reg [7:0] table_hi_q, table_lo_q;
        wire [6:0] table_rd = state_port ? state_word_addr : capture_run ? fetch_word : cpu_addr;
        wire table_wr_state = state_port && state_word_write;
        wire state_payload_write = table_wr_state && state_word_addr <= LAST_WORD;
        wire table_wr_boot = normal_accept && !valid && (in_head || in_tail);
        wire [6:0] table_wr = table_wr_state ? state_word_addr : install_word ? copy_word :
                             table_wr_boot ? normal_index : cpu_addr;
        wire table_wr_bank = install_word ? !live_bank : live_bank;
        wire [15:0] table_d = table_wr_state ? state_word_data :
                              install_word ? {stage_hi_q, stage_lo_q} :
                              table_wr_boot ? normal_data : cpu_data;
        wire table_w_hi = table_wr_state || install_word || (table_wr_boot ? normal_we[1] : cpu_hi);
        wire table_w_lo = table_wr_state ||
                          (install_word ? !(KING && copy_final) :
                           table_wr_boot ? normal_we[0] && !(KING && normal_index == LAST_WORD) : cpu_lo);
        always @(posedge clk) begin
            table_hi_q <= table_hi[{live_bank && table_rd <= LAST_WORD, table_rd}];
            table_lo_q <= table_lo[{live_bank && table_rd <= LAST_WORD &&
                                   !(KING && table_rd == LAST_WORD), table_rd}];
            if (!reset && table_w_hi)
                table_hi[{table_wr_bank && table_wr <= LAST_WORD, table_wr}] <= table_d[15:8];
            if (!reset && table_w_lo)
                table_lo[{table_wr_bank && table_wr <= LAST_WORD &&
                          !(KING && table_wr == LAST_WORD), table_wr}] <= table_d[7:0];
        end

        reg [15:0] snapshot [0:127];
        reg [15:0] snapshot_q;
        reg output_live, output_table, output_low;
        always @(posedge clk) begin
            if (capture_word) snapshot[copy_word] <= {table_hi_q, table_lo_q};
            if (pub_valid && pub_table && read_payload) snapshot_q <= snapshot[nv_addr[7:1]];
            output_live <= !reset && !restore && pub_valid && read_payload;
            output_table <= pub_table;
            output_low <= nv_addr[0];
        end

        // hps_io may read byte 0 before the image is published.
        wire transfer_read = host_upload && nv_read;
        wire upload_address_ok = nv_addr == {19'd0, up_count} && nv_addr <= FILE_BYTES &&
                                 (pub_valid || nv_addr == 0);
        wire upload_complete = up_count == (FILE_BYTES[7:0] + 8'd1) && !up_bad;
        assign nv_q = !output_live ? 8'd0 :
                      output_table ? (output_low ? snapshot_q[7:0] : snapshot_q[15:8]) :
                      output_low ? stage_lo_q : stage_hi_q;
        assign nv_wait = nv_upload && (reset || restore || up_discard || !pub_valid);
        assign hold_request = !reset && !state_active &&
                              (want_install || want_capture || copy_mode == INSTALL ||
                               (copy_mode == CAPTURE && !cap_abort));
        assign active = !reset && (download_busy || nv_upload || pending || pub_valid ||
                                   save_queued || copy_mode != IDLE || want_capture);
        assign ready = ready_r;
        assign dirty = dirty_r;
        assign upload_request = upload_pulse;
        assign cpu_q = {table_hi_q, table_lo_q};
        assign state_word_q = {table_hi_q, table_lo_q};
        assign state_flags_out = KING ? {valid, last, tail, first, ready_r} :
                                        {1'b0, valid, last, first, ready_r};

        always @(posedge clk) begin
            upload_pulse <= 1'b0;
            osd_prev <= osd_open;
            manual_prev <= manual_save;
            if (reset || restore) begin
                if (reset) live_bank <= 1'b0;
                valid <= !reset && (KING ? state_flags_in[4] : state_flags_in[3]);
                last <= !reset && (KING ? state_flags_in[3] : state_flags_in[2]);
                tail <= !reset && KING && state_flags_in[2];
                first <= !reset && state_flags_in[1];
                ready_r <= !reset && state_flags_in[0];
                ready_deferred <= 1'b0;
                dirty_r <= 1'b0;
                copy_mode <= IDLE;
                copy_word <= 7'd0;
                primed <= 1'b0;
                install_bank <= 1'b0;
                cap_core <= 1'b0;
                cap_host_seen <= 1'b0;
                dl_seen <= nv_download;
                dl_bad <= nv_download;
                dl_count <= 8'd0;
                dl_bank <= 1'b0;
                pending <= 1'b0;
                pending_bank <= 1'b0;
                pub_valid <= 1'b0;
                pub_table <= 1'b0;
                pub_bank <= 1'b0;
                snapshot_stale <= 1'b0;
                up_seen <= nv_upload;
                // Restore: an upload that has only read byte 0 continues; any later upload is discarded.
                up_bad <= !reset && nv_upload &&
                          (up_bad || (nv_read && (up_count != 0 || nv_addr != 0)));
                up_discard <= nv_upload && (reset || up_discard || pub_valid || up_count > 1);
                up_count <= !reset && nv_upload && !up_discard && !pub_valid && !up_bad &&
                            (up_count == 1 || (up_count == 0 && nv_read && nv_addr == 0)) ?
                            8'd1 : 8'd0;
                save_queued <= 1'b0;
            end else begin
                dl_seen <= nv_download;
                if (start_dl) begin
                    pending <= 1'b0;
                    dl_bank <= next_dl_bank;
                    dl_count <= dl_store ? 8'd1 : 8'd0;
                    dl_bad <= dl_sample && !dl_address_ok;
                end else if (dl_sample) begin
                    if (!dl_address_ok) dl_bad <= 1'b1;
                    if (dl_store) dl_count <= dl_count + 8'd1;
                end else if (!nv_download && dl_seen) begin
                    pending <= !dl_bad && dl_count == FILE_BYTES[7:0];
                    pending_bank <= dl_bank;
                end

                if (hit_first) first <= 1'b1;
                if (hit_tail) tail <= 1'b1;
                if (hit_last) begin
                    last <= 1'b1;
                    valid <= 1'b1;
                    if (pending || download_busy || copy_mode == INSTALL) ready_deferred <= 1'b1;
                    else ready_r <= 1'b1;
                end
                if (ready_deferred && !state_active && !pending && !download_busy && copy_mode != INSTALL) begin
                    ready_r <= 1'b1;
                    ready_deferred <= 1'b0;
                end

                up_seen <= nv_upload;
                if (!nv_upload) begin
                    up_bad <= 1'b0;
                    up_count <= 8'd0;
                    up_discard <= 1'b0;
                    if (up_seen) begin
                        pub_valid <= 1'b0;
                        if (pub_valid && pub_table && upload_complete &&
                            !snapshot_stale && !cpu_commit && !state_payload_write) dirty_r <= 1'b0;
                    end
                end else if (transfer_read) begin
                    if (!upload_address_ok) up_bad <= 1'b1;
                    else up_count <= up_count + 8'd1;
                end
                if (cpu_commit) begin
                    dirty_r <= 1'b1;
                    if (pub_valid) snapshot_stale <= 1'b1;
                end
                if (pub_valid && state_payload_write)
                    snapshot_stale <= 1'b1;

                if (queue_save) save_queued <= 1'b1;
                if (nv_download || cpu_reset) save_queued <= 1'b0;
                if (copy_mode == IDLE) begin
                    primed <= 1'b0;
                    copy_word <= 7'd0;
                    if (copy_slot && host_upload && pending) begin
                        pub_valid <= 1'b1;
                        pub_table <= 1'b0;
                        pub_bank <= pending_bank;
                        save_queued <= 1'b0;
                    end else if (copy_grant && want_install) begin
                        copy_mode <= INSTALL;
                        install_bank <= pending_bank;
                        pending <= 1'b0;
                    end else if (copy_grant && want_capture) begin
                        copy_mode <= CAPTURE;
                        cap_core <= !nv_upload;
                        cap_host_seen <= nv_upload;
                        save_queued <= 1'b0;
                    end
                end else if (cap_abort) begin
                    copy_mode <= IDLE;
                    primed <= 1'b0;
                end else begin
                    if (copy_mode == CAPTURE && nv_upload) cap_host_seen <= 1'b1;
                    primed <= copy_grant;
                    // Restarts the score capture when a CPU or state write changes the live image.

                    if (copy_mode == CAPTURE && (cpu_commit || state_payload_write))
                        copy_word <= 7'd0;
                    if (install_word || capture_word) begin
                        if (!copy_final) copy_word <= copy_word + 7'd1;
                        else begin
                            copy_mode <= IDLE;
                            primed <= 1'b0;
                            if (install_word) begin
                                live_bank <= !live_bank;
                                valid <= 1'b1;
                                dirty_r <= 1'b0;
                                if (initialized && !pending && !download_busy) begin
                                    ready_r <= 1'b1;
                                    ready_deferred <= 1'b0;
                                end
                            end else begin
                                pub_valid <= 1'b1;
                                pub_table <= 1'b1;
                                snapshot_stale <= 1'b0;
                                upload_pulse <= cap_core && !nv_upload;
                            end
                        end
                    end
                end
                if (cpu_reset) begin
                    first <= 1'b0;
                    tail <= 1'b0;
                    last <= 1'b0;
                    ready_r <= 1'b0;
                    ready_deferred <= 1'b0;
                end
            end
        end
    end else begin : inert
        assign nv_q = 8'd0;
        assign nv_wait = 1'b0;
        assign upload_request = 1'b0;
        assign hold_request = 1'b0;
        assign active = 1'b0;
        assign dirty = 1'b0;
        assign ready = 1'b0;
        assign cpu_q = 16'd0;
        assign state_word_q = 16'd0;
        assign state_flags_out = 5'd0;
    end endgenerate
endmodule

module raizing_score_binding #(
    parameter integer FLAG_BITS = 5   // Kingdom's five flags; Sorcer leaves bit 4 clear
) (
    input raizing_board_pkg::board_e board,
    input clk,reset,cpu_reset,
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

    wire [7:0] state_select = state_active ? SS_SELECT : 8'hff;
    wire word_own, word_write, flags_write;
    wire [6:0] word_addr;
    wire [15:0] word_data, word_q;
    wire [4:0] flags_out, restore_flags;
    wire [FLAG_BITS-1:0] saved_flags;
    wire [1:0] state_ack;
    wire [127:0] state_response_data;
    assign restore_flags = 5'(saved_flags);

    raizing_ss_ram_adapter #(.WIDTH(16),.ADDR_WIDTH(7),.SS_INDEX(44)) state_table (
        .clk(clk),.reset(reset),.ss_data(SS_DATA),.ss_addr(SS_ADDR),.ss_select(state_select),
        .ss_write(SS_WRITE),.ss_read(SS_READ),.ss_query(SS_QUERY),
        .ss_data_out(state_response_data[0+:64]),.ss_ack(state_ack[0]),
        .ram_active(word_own),.ram_addr(word_addr),.ram_data(word_data),.ram_we(word_write),.ram_q(word_q)
    );
    raizing_ss_register #(.WIDTH(FLAG_BITS),.SS_INDEX(45)) state_flags (
        .clk(clk),.reset(reset),.capture_data(flags_out[FLAG_BITS-1:0]),
        .restore_data(saved_flags),.restore_we(flags_write),.ss_data(SS_DATA),.ss_select(state_select),
        .ss_write(SS_WRITE),.ss_read(SS_READ),.ss_query(SS_QUERY),
        .ss_data_out(state_response_data[64+:64]),.ss_ack(state_ack[1])
    );
    raizing_ss_response_mux #(.COUNT(2)) state_response (
        .ack(state_ack),.data(state_response_data),.ack_out(SS_ACK),.data_out(SS_DATA_OUT)
    );
    wire early_sorcer = board == raizing_board_pkg::RZB_SORCER;
    rzscore_early #(.PROFILE(1)) owner (
        .early_sorcer(early_sorcer),
        .clk(clk),.reset(reset),.cpu_reset(cpu_reset),.state_active(state_active),.hold_ack(hold_ack),
        .nv_download(nv_download),.nv_upload(nv_upload),.nv_write(nv_write),.nv_read(nv_read),
        .nv_addr(nv_addr),.nv_data(nv_data),.nv_q(nv_q),.nv_wait(nv_wait),
        .manual_save(manual_save),.autosave(autosave),.osd_open(osd_open),
        .upload_request(upload_request),.hold_request(hold_request),.active(active),.dirty(dirty),.ready(ready),
        .normal_write(normal_write),.normal_addr(normal_addr),.normal_data(normal_data),.normal_we(normal_we),
        .cpu_addr(cpu_addr),.cpu_data(cpu_data),.cpu_we(cpu_we),.cpu_q(cpu_q),
        .state_word_own(state_active && word_own),.state_word_write(state_active && word_write),
        .state_word_addr(word_addr),.state_word_data(word_data),.state_word_q(word_q),
        .state_flags_write(state_active && flags_write),.state_flags_in(restore_flags),.state_flags_out(flags_out)
    );
endmodule

module rzearly_sound #(
    parameter integer PCM_BITS = 19   // Kingdom's banked PCM; Sorcer's bank bit stays 0
) (
    output raizing_socket_pkg::fm_in_t sk_fm_i,
    input raizing_socket_pkg::fm_out_t sk_fm_o,
    output raizing_socket_pkg::oki_in_t sk_oki_i,
    input raizing_socket_pkg::oki_out_t sk_oki_o,

    output raizing_socket_pkg::z80_in_t sk_z80_i,
    input raizing_socket_pkg::z80_out_t sk_z80_o,

    input  wire clk, reset, main_reset_n, z80_ce, ym_ce, ym_phase1_ce, oki_ce,
    input  wire oki_bank,
    input  wire hold_request, canonical_hold, restore_commit,
    output wire held, replay_busy, restore_busy, canonical_ready, canonical_fault, canonical_service,
    output wire [15:0] rom_address,
    output wire rom_request,
    input  wire [7:0] rom_data,
    input  wire rom_ok,
    output wire [12:0] shared_address,
    output wire [7:0] shared_data_out,
    output wire shared_write,
    input  wire [7:0] shared_data_in,
    output wire [PCM_BITS-1:0] pcm_address,
    output wire pcm_request, pcm_frozen, pcm_resume_busy,
    input  wire [7:0] pcm_data,
    input  wire pcm_ok,
    output wire signed [15:0] audio,
    output wire sample,
    input  wire [1:0] fx_level,
    input  wire fm_enable, pcm_enable,
    input  wire [63:0] SS_DATA,
    input  wire [31:0] SS_ADDR,
    input  wire [7:0] SS_SELECT,
    input  wire SS_WRITE, SS_READ, SS_QUERY,
    output wire [63:0] SS_DATA_OUT,
    output wire SS_ACK
);
    // ym_phase1_ce is unused.
    wire [17:0] chip_pcm_address;
    generate if (PCM_BITS > 18) begin : g_banked_pcm
        assign pcm_address = {oki_bank, chip_pcm_address};
    end else begin : g_flat_pcm
        assign pcm_address = chip_pcm_address;
    end endgenerate
    wire cpu_reset, cpu_ce, cpu_hold_request, cpu_wait_n, cpu_irq_n;
    wire cpu_held, cpu_canonical_ready, cpu_fault;
    wire cpu_mreq_n, cpu_rd_n, cpu_wr_n;
    wire [7:0] cpu_data_in;
    wire [255:0] capture_state, restore_state;
    wire cpu_ss_ack, pcm_ss_ack;
    wire [63:0] cpu_ss_data, pcm_ss_data;
    wire auto_ss_rd, auto_ss_wr, auto_ss_ack;
    wire [31:0] auto_ss_data_in, auto_ss_data_out;
    wire [7:0] auto_ss_device_idx;
    wire [15:0] auto_ss_state_idx;

    assign shared_address = rom_address[12:0];

    // Socket sk_z80: pins of the shared raizing_z80 instance.
    assign sk_z80_i.nmi_n = 1'b1;     // no NMI or bus request on this board
    assign sk_z80_i.busrq_n = 1'b1;
    assign sk_z80_i.clk = clk;
    assign sk_z80_i.reset = cpu_reset;
    assign sk_z80_i.cen = cpu_ce;
    assign sk_z80_i.wait_n = cpu_wait_n;
    assign sk_z80_i.int_n = cpu_irq_n;
    assign sk_z80_i.hold_request = cpu_hold_request;
    assign sk_z80_i.canonical_hold = canonical_hold;
    assign sk_z80_i.restore = restore_commit;
    assign sk_z80_i.restore_state = restore_state;
    assign sk_z80_i.data_in = cpu_data_in;
    assign cpu_held = sk_z80_o.held;
    assign cpu_canonical_ready = sk_z80_o.canonical_ready;
    assign canonical_service = sk_z80_o.canonical_service;
    assign restore_busy = sk_z80_o.restore_busy;
    assign cpu_fault = sk_z80_o.canonical_fault;
    assign capture_state = sk_z80_o.capture_state;
    assign rom_address = sk_z80_o.address;
    assign shared_data_out = sk_z80_o.data_out;
    assign cpu_rd_n = sk_z80_o.rd_n;
    assign cpu_wr_n = sk_z80_o.wr_n;
    assign cpu_mreq_n = sk_z80_o.mreq_n;

    raizing_ss_wide_register #(.WIDTH(256), .SS_INDEX(15)) cpu_state (
        .clk(clk), .reset(reset), .capture_data(capture_state), .restore_data(restore_state),
        .restore_we(), .ss_data(SS_DATA), .ss_addr(SS_ADDR), .ss_select(SS_SELECT),
        .ss_write(SS_WRITE), .ss_read(SS_READ), .ss_query(SS_QUERY),
        .ss_data_out(cpu_ss_data), .ss_ack(cpu_ss_ack)
    );

    raizing_ss_auto32 #(.SS_INDEX(18), .DEVICE_COUNT(11), .STATE_STRIDE(64)) pcm_state (
        .clk(clk), .reset(reset), .ss_data(SS_DATA), .ss_addr(SS_ADDR), .ss_select(SS_SELECT),
        .ss_write(SS_WRITE), .ss_read(SS_READ), .ss_query(SS_QUERY),
        .ss_data_out(pcm_ss_data), .ss_ack(pcm_ss_ack),
        .auto_ss_rd(auto_ss_rd), .auto_ss_wr(auto_ss_wr), .auto_ss_data_in(auto_ss_data_in),
        .auto_ss_device_idx(auto_ss_device_idx), .auto_ss_state_idx(auto_ss_state_idx),
        .auto_ss_data_out(auto_ss_data_out), .auto_ss_ack(auto_ss_ack)
    );

    rzearly_sound_common board (
        .sk_fm_i(sk_fm_i), .sk_fm_o(sk_fm_o),
        .sk_oki_i(sk_oki_i), .sk_oki_o(sk_oki_o),
        .clk(clk), .reset(reset), .main_reset_n(main_reset_n),
        .z80_ce(z80_ce), .ym_ce(ym_ce), .oki_ce(oki_ce),
        .hold_request(hold_request), .canonical_hold(canonical_hold), .restore_commit(restore_commit),
        .held(held), .replay_busy(replay_busy), .canonical_ready(canonical_ready),
        .canonical_fault(canonical_fault), .rom_address(rom_address),
        .rom_request(rom_request), .rom_data(rom_data), .rom_ok(rom_ok),
        .shared_write(shared_write), .shared_data_in(shared_data_in),
        .pcm_address(chip_pcm_address), .pcm_request(pcm_request), .pcm_frozen(pcm_frozen),
        .pcm_resume_busy(pcm_resume_busy), .pcm_data(pcm_data), .pcm_ok(pcm_ok),
        .audio(audio), .sample(sample), .fx_level(fx_level),
        .fm_enable(fm_enable), .pcm_enable(pcm_enable),
        .cpu_reset(cpu_reset), .cpu_ce(cpu_ce), .cpu_hold_request(cpu_hold_request),
        .cpu_wait_n(cpu_wait_n), .cpu_irq_n(cpu_irq_n), .cpu_held(cpu_held),
        .cpu_restore_busy(restore_busy), .cpu_canonical_ready(cpu_canonical_ready),
        .cpu_fault(cpu_fault), .cpu_mreq_n(cpu_mreq_n), .cpu_rd_n(cpu_rd_n), .cpu_wr_n(cpu_wr_n),
        .cpu_data_out(shared_data_out), .cpu_data_in(cpu_data_in),
        .SS_DATA(SS_DATA), .SS_ADDR(SS_ADDR), .SS_SELECT(SS_SELECT),
        .SS_WRITE(SS_WRITE), .SS_READ(SS_READ), .SS_QUERY(SS_QUERY),
        .cpu_ss_ack(cpu_ss_ack), .pcm_ss_ack(pcm_ss_ack),
        .cpu_ss_data(cpu_ss_data), .pcm_ss_data(pcm_ss_data), .SS_DATA_OUT(SS_DATA_OUT), .SS_ACK(SS_ACK),
        .auto_ss_rd(auto_ss_rd), .auto_ss_wr(auto_ss_wr), .auto_ss_data_in(auto_ss_data_in),
        .auto_ss_device_idx(auto_ss_device_idx), .auto_ss_state_idx(auto_ss_state_idx),
        .auto_ss_data_out(auto_ss_data_out), .auto_ss_ack(auto_ss_ack)
    );
endmodule

module rzearly_sound_common (
    output raizing_socket_pkg::oki_in_t sk_oki_i,
    input raizing_socket_pkg::oki_out_t sk_oki_o,

    output raizing_socket_pkg::fm_in_t sk_fm_i,
    input raizing_socket_pkg::fm_out_t sk_fm_o,

    input  wire clk, reset, main_reset_n, z80_ce, ym_ce, oki_ce,
    input  wire hold_request, canonical_hold, restore_commit,
    output wire held, replay_busy, canonical_ready, canonical_fault,
    input  wire [15:0] rom_address,
    output wire rom_request,
    input  wire [7:0] rom_data,
    input  wire rom_ok,
    output wire shared_write,
    input  wire [7:0] shared_data_in,
    output wire [17:0] pcm_address,
    output wire pcm_request, pcm_frozen, pcm_resume_busy,
    input  wire [7:0] pcm_data,
    input  wire pcm_ok,
    output wire signed [15:0] audio,
    output wire sample,
    input  wire [1:0] fx_level,
    input  wire fm_enable, pcm_enable,

    output wire cpu_reset, cpu_ce, cpu_hold_request, cpu_wait_n, cpu_irq_n,
    input  wire cpu_held, cpu_restore_busy, cpu_canonical_ready, cpu_fault,
    input  wire cpu_mreq_n, cpu_rd_n, cpu_wr_n,
    input  wire [7:0] cpu_data_out,
    output logic [7:0] cpu_data_in,

    input  wire [63:0] SS_DATA,
    input  wire [31:0] SS_ADDR,
    input  wire [7:0] SS_SELECT,
    input  wire SS_WRITE, SS_READ, SS_QUERY,
    input  wire cpu_ss_ack, pcm_ss_ack,
    input  wire [63:0] cpu_ss_data, pcm_ss_data,
    output wire [63:0] SS_DATA_OUT,
    output wire SS_ACK,

    input  wire auto_ss_rd, auto_ss_wr,
    input  wire [31:0] auto_ss_data_in,
    input  wire [7:0] auto_ss_device_idx,
    input  wire [15:0] auto_ss_state_idx,
    output wire [31:0] auto_ss_data_out,
    output wire auto_ss_ack
);
    wire [7:0] fm_status, pcm_status;
    wire fm_fault, fm_ss_ack;
    wire [63:0] fm_ss_data;
    wire signed [15:0] fm_left, fm_right;
    wire signed [13:0] pcm_audio;

    wire in_rom = rom_address < 16'hc000;
    wire in_shared = rom_address[15:13] == 3'b110;
    wire at_fm = rom_address[15:1] == 15'h7000;
    wire at_pcm = rom_address == 16'he004;
    wire memory_read = !cpu_mreq_n && !cpu_rd_n;
    wire commit_write = !cpu_mreq_n && !cpu_wr_n && !cpu_held;
    wire fm_cs_n = !(at_fm && !cpu_mreq_n && !cpu_held);
    wire fm_wr_n = cpu_wr_n || cpu_held;
    wire pcm_wr_n = !(at_pcm && commit_write);

    assign rom_request = in_rom && memory_read;
    assign shared_write = in_shared && commit_write;
    always_comb begin
        if (in_shared)
            cpu_data_in = shared_data_in;
        else if (rom_address == 16'he001)
            cpu_data_in = fm_status;
        else if (at_pcm)
            cpu_data_in = pcm_status;
        else if (rom_request)
            cpu_data_in = rom_data;
        else
            cpu_data_in = 8'hff;
    end

    assign cpu_reset = reset || !main_reset_n;
    assign cpu_wait_n = !(rom_request && !rom_ok) && !fm_status[7];
    assign cpu_hold_request = hold_request || replay_busy;
    assign cpu_ce = z80_ce && (!pcm_resume_busy || cpu_restore_busy);
    wire both_settled = pcm_frozen && !replay_busy && !cpu_restore_busy;
    assign held = cpu_held && both_settled;
    assign canonical_ready = cpu_canonical_ready && both_settled;
    assign canonical_fault = cpu_fault || fm_fault;

    // Socket sk_fm: pins of the shared rzopm_state_owner instance.
    assign sk_fm_i.clk = clk;
    assign sk_fm_i.reset = reset;
    assign sk_fm_i.ym_ce = ym_ce;
    assign sk_fm_i.cpu_held = cpu_held;
    assign sk_fm_i.pcm_refill = pcm_resume_busy;
    assign sk_fm_i.canonical_hold = canonical_hold;
    assign sk_fm_i.cpu_canonical_ready = cpu_canonical_ready;
    assign sk_fm_i.restore_commit = restore_commit;
    assign sk_fm_i.cs_n = fm_cs_n;
    assign sk_fm_i.wr_n = fm_wr_n;
    assign sk_fm_i.a0 = rom_address[0];
    assign sk_fm_i.din = cpu_data_out;
    assign sk_fm_i.ss_data = SS_DATA;
    assign sk_fm_i.ss_addr = SS_ADDR;
    assign sk_fm_i.ss_select = SS_SELECT;
    assign sk_fm_i.ss_write = SS_WRITE;
    assign sk_fm_i.ss_read = SS_READ;
    assign sk_fm_i.ss_query = SS_QUERY;
    assign fm_status = sk_fm_o.dout;
    assign cpu_irq_n = sk_fm_o.irq_n;
    assign fm_left = sk_fm_o.xleft;
    assign fm_right = sk_fm_o.xright;
    assign replay_busy = sk_fm_o.busy;
    assign fm_fault = sk_fm_o.fault;
    assign fm_ss_data = sk_fm_o.ss_data_out;
    assign fm_ss_ack = sk_fm_o.ss_ack;

    // Socket sk_oki: pins of the shared ss_jt6295 instance.
    assign sk_oki_i.rst = reset;
    assign sk_oki_i.filter_rst = restore_commit;
    assign sk_oki_i.clk = clk;
    assign sk_oki_i.state_freeze = cpu_held;
    assign sk_oki_i.cen = oki_ce && !cpu_held;
    assign sk_oki_i.ss = 1'b1;
    assign sk_oki_i.wrn = pcm_wr_n;
    assign sk_oki_i.din = cpu_data_out;
    assign sk_oki_i.rom_data = pcm_data;
    assign sk_oki_i.rom_ok = pcm_ok;
    assign sk_oki_i.auto_ss_rd = auto_ss_rd;
    assign sk_oki_i.auto_ss_wr = auto_ss_wr;
    assign sk_oki_i.auto_ss_data_in = auto_ss_data_in;
    assign sk_oki_i.auto_ss_device_idx = auto_ss_device_idx;
    assign sk_oki_i.auto_ss_state_idx = auto_ss_state_idx;
    assign sk_oki_i.auto_ss_base_device_idx = 8'd0;
    assign pcm_frozen = sk_oki_o.state_frozen;
    assign pcm_request = sk_oki_o.rom_request;
    assign pcm_resume_busy = sk_oki_o.resume_busy;
    assign pcm_status = sk_oki_o.dout;
    assign pcm_address = sk_oki_o.rom_addr;
    assign pcm_audio = sk_oki_o.sound;
    assign sample = sk_oki_o.sample;
    assign auto_ss_data_out = sk_oki_o.auto_ss_data_out;
    assign auto_ss_ack = sk_oki_o.auto_ss_ack;

    assign SS_ACK = cpu_ss_ack || fm_ss_ack || pcm_ss_ack;
    assign SS_DATA_OUT = (cpu_ss_ack ? cpu_ss_data : 64'd0)
                       | (fm_ss_ack  ? fm_ss_data  : 64'd0)
                       | (pcm_ss_ack ? pcm_ss_data : 64'd0);

    logic signed [6:0] pcm_gain;
    always_comb begin
        case (fx_level)
            2'd0: pcm_gain = 7'sd11;
            2'd1: pcm_gain = 7'sd21;
            2'd2: pcm_gain = 7'sd32;
            default: pcm_gain = 7'sd43;
        endcase
    end

    // Mix: FM (L+R)/2 and PCM, scaled, floor-rounded and clamped to 16 bits.
    wire signed [16:0] fm_sum = {fm_left[15], fm_left} + {fm_right[15], fm_right};
    wire signed [16:0] fm_mean = fm_sum >>> 1;
    logic signed [21:0] fm_product, pcm_product;
    wire signed [22:0] product_sum = {fm_product[21], fm_product}
                                   + {pcm_product[21], pcm_product};
    wire signed [22:0] scaled = product_sum >>> 4;
    logic signed [15:0] mixed;

    always_ff @(posedge clk) begin
        if (reset) begin
            fm_product <= '0;
            pcm_product <= '0;
            mixed <= '0;
        end else begin
            fm_product <= fm_enable ? fm_mean * 22'sd12 : 22'sd0;
            pcm_product <= pcm_enable ? pcm_audio * pcm_gain * 22'sd4 : 22'sd0;
            if (scaled > 23'sd32767)
                mixed <= 16'sh7fff;
            else if (scaled < -23'sd32768)
                mixed <= 16'sh8000;
            else
                mixed <= scaled[15:0];
        end
    end

    assign audio = (hold_request || canonical_hold || replay_busy || pcm_resume_busy)
                 ? 16'sd0 : mixed;
endmodule

`timescale 1ns/1ps
module rzearly_bus_binding (
    output raizing_socket_pkg::mem_in_t sk_mem_i,
    input raizing_socket_pkg::mem_out_t sk_mem_o,

    input wire early_sorcer,   // Sorcer variant of the shared early bus
    input wire clk, reset,
    input wire [23:1] cpu_addr,
    input wire cpu_as_n, cpu_rw, cpu_uds_n, cpu_lds_n,
    input wire [2:0] cpu_fc,
    input wire [15:0] cpu_dout,
    input wire block_writes, override_valid,
    output logic [15:0] cpu_din,
    output wire selected, busy, idle,
    output logic rom_req,
    output logic [18:0] rom_addr,
    input wire rom_ok,
    input wire [15:0] rom_data,
    output logic gp_req, gp_start,
    output logic [2:0] gp_op,
    output logic [1:0] gp_be,
    output logic [15:0] gp_din,
    input wire gp_ack,
    input wire [15:0] gp_dout,
    input wire [8:0] vpos,
    input wire status_hs_n, status_vs_n, status_blank_n,
    input wire [7:0] p1_inputs, p2_inputs, sys_inputs, dsw_a, dsw_b, dsw_c,
    input wire [10:0] pal_addr,
    output wire [15:0] pal_data,
    input wire [11:0] text_addr,
    output wire [15:0] text_data,
    input wire [7:0] select_addr, scroll_addr,
    output wire [15:0] select_data, scroll_data,
    input wire [12:0] z80_addr,
    input wire [7:0] z80_din,
    input wire z80_we,
    output wire [7:0] z80_dout,
    input wire ram_enable, ram_req,
    input wire [2:0] ram_region,
    input wire [14:0] ram_addr,
    input wire [15:0] ram_din,
    input wire [1:0] ram_we,
    output logic ram_ack,
    output logic [15:0] ram_dout,
    input wire state_active, state_valid,
    output wire state_ready,
    input wire [2:0] state_region,
    input wire [14:0] state_addr,
    input wire [15:0] state_din,
    input wire [1:0] state_we,
    output wire state_rsp_valid,
    input wire state_rsp_ready,
    output wire [15:0] state_q,
    output wire state_error,
    input wire hs_ready,
    input wire [15:0] hs_dout,
    output wire hs_cs,
    output wire [6:0] hs_addr,
    output wire [15:0] hs_din,
    output wire [1:0] hs_we,
    output logic wram_write,
    output logic [15:0] wram_addr, wram_data,
    output logic [1:0] wram_we,
    output logic oki_bank_write,
    output logic ctx_sample_valid,
    output logic [14:0] ctx_sample_word,
    output logic [15:0] ctx_sample_before, ctx_sample_written
);

    localparam integer PROFILE_ID = 1;   // peripherals treat both early boards alike
    localparam [5:0] EP_OPEN = 0, EP_ROM = 2, EP_WRAM = 3, EP_SHARED = 5,
        EP_P1 = 6, EP_P2 = 7, EP_SYSTEM = 8, EP_DIP_A = 9, EP_DIP_B = 10,
        EP_JUMPERS = 11, EP_GP_STATUS = 15, EP_GP = 16, EP_PALETTE = 17,
        EP_SCRATCH = 18, EP_MAP = 19, EP_SELECT = 20, EP_SCROLL = 21,
        EP_TEXT_WORK = 22, EP_BANK = 24;

    typedef enum logic [2:0] {OPEN, LOCAL, RAM, ROM, GP} owner_t;
    owner_t next_owner, owner;
    logic [5:0] endpoint;
    logic [3:0] next_read_id, read_id;
    logic [1:0] payload_at_command;
    logic shared_at_command, wram_at_command, ram_accepted;
    logic seen, complete;

    wire [39:0] command;
    wire [22:0] command_index;
    wire [1:0] lanes;
    wire ordinary = !cpu_as_n && (!cpu_uds_n || !cpu_lds_n) &&
                    cpu_fc != 3'd7 && !override_valid;
    wire launch = !reset && ordinary && !seen && (|command);
    wire normal_write = !cpu_rw && !block_writes;

    wire [1:0] gp_kind, gp_lanes;
    wire [2:0] gp_leaf_op;
    wire [15:0] gp_leaf_data, local_data;
    wire [1:0] payload_lanes;
    wire [8:0] packed_word;
    wire witness_window;
    wire [14:0] view_word = cpu_addr[15:1];

    wire [15:0] ram_word;
    wire mem_ready, mem_rsp_valid;
    wire mem_offer = launch && next_owner == RAM;
    wire write_wram = mem_offer && mem_ready && normal_write && endpoint == EP_WRAM;

    wire [127:0] view_data;
    wire [7:0] view_valid;
    wire mem_wram_commit;
    wire [14:0] mem_wram_word;
    logic view_primed;
    logic [14:0] previous_view_word;

    wire [2:0] aux_ready, aux_rsp_valid, aux_rsp_error;
    wire [47:0] aux_rsp_data;
    logic aux_accepted;
    wire aux_offer = !reset && ram_req && !aux_accepted && !state_active;

    wire rom_bypass = rom_req && rom_ok;
    wire gp_bypass = gp_req && gp_ack;
    wire [15:0] bypass_data = rom_bypass ? rom_data : gp_dout;

    rzbus_cpu_link #(.PROFILE("kingdom")) link (.alt_map(early_sorcer),
        .clk(clk), .reset(reset), .cpu_addr(cpu_addr), .cpu_as_n(cpu_as_n),
        .cpu_rw(cpu_rw), .cpu_uds_n(cpu_uds_n), .cpu_lds_n(cpu_lds_n),
        .cpu_fc(cpu_fc), .cpu_dout(cpu_dout), .override_valid(override_valid),
        .selected(selected), .busy(busy), .idle(idle), .command(command),
        .command_index(command_index), .command_lanes(lanes),
        .owner_complete(rom_bypass || gp_bypass || complete),
        .owner_data((rom_bypass || gp_bypass) ? bypass_data : cpu_din)
    );

    // Decode the CPU address to an endpoint ID.
    always_comb begin
        endpoint = EP_OPEN;
        for (int i = 0; i < 40; i = i + 1)
            if (command[i]) endpoint = 6'(i);
    end

    rzperiph_gp_command #(.PROFILE(PROFILE_ID)) gp_command (
        .endpoint(command[EP_GP] ? 2'd1 : 2'd0), .index(command_index[2:0]),
        .read_cycle(cpu_rw), .lanes(lanes), .block_write(block_writes),
        .write_data(cpu_dout), .kind(gp_kind), .op(gp_leaf_op), .bank(),
        .data(gp_leaf_data), .be(gp_lanes)
    );

    always_comb begin
        next_owner = OPEN;
        next_read_id = 4'd0;
        case (endpoint)
            EP_ROM: next_owner = ROM;
            EP_WRAM, EP_SHARED, EP_PALETTE, EP_SCRATCH, EP_MAP,
            EP_SELECT, EP_SCROLL, EP_TEXT_WORK: next_owner = RAM;
            EP_GP: begin
                if ((!cpu_rw && block_writes) || gp_kind == 2'd1) begin
                    next_owner = LOCAL;
                    next_read_id = 4'd11;
                end else if (gp_kind == 2'd2) begin
                    next_owner = GP;
                end
            end
            EP_P1, EP_P2, EP_SYSTEM, EP_DIP_A, EP_DIP_B, EP_JUMPERS: begin
                next_owner = LOCAL;
                next_read_id = 4'(endpoint - EP_P1 + 6'd1);
            end
            EP_GP_STATUS: begin
                next_owner = LOCAL;
                next_read_id = 4'd7;
            end
            default: begin end
        endcase
    end

    rzperiph_read_word #(.PROFILE(PROFILE_ID)) read_word (
        .read_id(read_id), .players({p2_inputs, p1_inputs}), .system_inputs(sys_inputs),
        .dip_a(dsw_a), .dip_b(dsw_b), .dip_c(dsw_c), .reply(16'b0), .bus_status(16'b0),
        .vpos(vpos), .hs_n(status_hs_n), .vs_n(status_vs_n), .blank_n(status_blank_n),
        .bit13(1'b1), .data(local_data)
    );

    rzscore_window #(.PROFILE(PROFILE_ID)) score_window (.alt_map(early_sorcer),
        .word_addr(cpu_addr), .score_base(16'b0), .payload_lanes(payload_lanes),
        .packed_word(packed_word), .witness_window(witness_window)
    );

    assign hs_addr = packed_word[6:0];
    assign hs_din = cpu_dout;
    assign hs_cs = ordinary && (!early_sorcer ? |(payload_lanes & lanes) : |payload_lanes);
    assign hs_we = write_wram && hs_ready ? payload_lanes & lanes : 2'b0;

    wire [29:0] palette_commit;
    wire [10:0] palette_source_addr;

    // Socket sk_mem: pins of the shared rzmem_owner instance.
    assign sk_mem_i.scratch_en = 1'b1;
    assign sk_mem_i.late_en = 1'b0;
    assign sk_mem_i.clk = clk;
    assign sk_mem_i.rst = reset;
    assign sk_mem_i.cpu_quiesce = 1'b0;
    assign sk_mem_i.hold_cert = ram_enable;
    assign sk_mem_i.dma_enable = 1'b0;
    assign sk_mem_i.write_block = block_writes;
    assign sk_mem_i.cpu_valid = mem_offer;
    assign sk_mem_i.cpu_endpoint = endpoint;
    assign sk_mem_i.cpu_index = command_index;
    assign sk_mem_i.cpu_write = !cpu_rw;
    assign sk_mem_i.cpu_be = lanes;
    assign sk_mem_i.cpu_wdata = cpu_dout;
    assign sk_mem_i.cpu_tag = 1'b0;
    assign sk_mem_i.cpu_rsp_ready = 1'b1;
    assign sk_mem_i.view_addr = {30'b0, 7'b0, scroll_addr, 7'b0, select_addr, 3'b0, text_addr, 4'b0, palette_source_addr, 2'b0, z80_addr, view_word};
    assign sk_mem_i.view_wdata = {96'b0, 8'b0, z80_din, 16'b0};
    assign sk_mem_i.view_we = {12'b0, 1'b0, z80_we, 2'b0};
    assign sk_mem_i.aux_valid = {1'b0, aux_offer, state_valid};
    assign sk_mem_i.aux_region = {3'b0, ram_region, state_region};
    assign sk_mem_i.aux_addr = {15'b0, ram_addr, state_addr};
    assign sk_mem_i.aux_wdata = {16'b0, ram_din, state_din};
    assign sk_mem_i.aux_we = {2'b0, ram_we, state_we};
    assign sk_mem_i.aux_tag = 3'b0;
    assign sk_mem_i.aux_rsp_ready = {2'b11, state_rsp_ready};
    assign mem_ready = sk_mem_o.cpu_ready;
    assign mem_rsp_valid = sk_mem_o.cpu_rsp_valid;
    assign ram_word = sk_mem_o.cpu_rsp_data;
    assign view_data = sk_mem_o.view_data;
    assign view_valid = sk_mem_o.view_valid;
    assign aux_ready = sk_mem_o.aux_ready;
    assign aux_rsp_valid = sk_mem_o.aux_rsp_valid;
    assign aux_rsp_data = sk_mem_o.aux_rsp_data;
    assign aux_rsp_error = sk_mem_o.aux_rsp_error;
    assign mem_wram_commit = sk_mem_o.wram_commit;
    assign mem_wram_word = sk_mem_o.wram_word;
    assign palette_commit = sk_mem_o.palette_commit;

    assign z80_dout = view_data[16 +: 8];
    // Sorcer copies the palette for the visible tail; Kingdom reads it live.
    wire [15:0] tail_pal_data;
    wire [10:0] tail_source_addr;
    assign pal_data = early_sorcer ? tail_pal_data : view_data[32 +: 16];
    assign palette_source_addr = early_sorcer ? tail_source_addr : pal_addr;
    SorcerPaletteTail tail_palette (
        .clk(clk), .reset(reset), .tail_hold(vpos >= 9'd230), .in_blank(vpos >= 9'd240),
        .cpu_commit(palette_commit[29]), .write_addr(palette_commit[28:18]),
        .write_data(palette_commit[17:2]), .write_be(palette_commit[1:0]),
        .display_addr(pal_addr), .display_data(tail_pal_data), .canonical_addr(tail_source_addr),
        .canonical_data(view_data[32 +: 16]), .canonical_valid(view_valid[2]),
        .copy_busy(), .live_fallback(), .missed_deadline()
    );
    assign text_data = view_data[48 +: 16];
    assign select_data = view_data[64 +: 16];
    assign scroll_data = view_data[80 +: 16];
    assign state_ready = aux_ready[0];
    assign state_rsp_valid = aux_rsp_valid[0];
    assign state_q = aux_rsp_data[0 +: 16];
    assign state_error = aux_rsp_error[0];

    always_ff @(posedge clk) begin
        if (reset) begin
            owner <= OPEN;
            read_id <= '0;
            payload_at_command <= '0;
            shared_at_command <= 1'b0;
            wram_at_command <= 1'b0;
            ram_accepted <= 1'b0;
            seen <= 1'b0;
            complete <= 1'b0;
            cpu_din <= '0;
            rom_req <= 1'b0;
            rom_addr <= '0;
            gp_req <= 1'b0;
            gp_start <= 1'b0;
            gp_op <= '0;
            gp_be <= '0;
            gp_din <= '0;
            oki_bank_write <= 1'b0;
        end else begin
            gp_start <= 1'b0;
            oki_bank_write <= 1'b0;
            if (!ordinary) begin
                seen <= 1'b0;
                complete <= 1'b0;
                rom_req <= 1'b0;
                gp_req <= 1'b0;
            end else if (launch) begin
                seen <= 1'b1;
                complete <= 1'b0;
                owner <= next_owner;
                read_id <= next_read_id;
                ram_accepted <= mem_offer && mem_ready;
                shared_at_command <= endpoint == EP_SHARED;
                wram_at_command <= endpoint == EP_WRAM;
                payload_at_command <= payload_lanes;
                gp_be <= lanes;
                if (next_owner == ROM) begin
                    rom_req <= 1'b1;
                    rom_addr <= !early_sorcer ? cpu_addr[19:1] : {1'b0, cpu_addr[18:1]};
                end
                if (next_owner == GP) begin
                    gp_req <= 1'b1;
                    gp_start <= 1'b1;
                    gp_op <= gp_leaf_op;
                    gp_be <= gp_lanes;
                    gp_din <= cpu_rw ? cpu_dout : gp_leaf_data;
                end
                oki_bank_write <= !early_sorcer && endpoint == EP_BANK && normal_write;
            end else if (seen && !complete) begin
                if (rom_bypass || gp_bypass) begin
                    cpu_din <= bypass_data;
                    complete <= 1'b1;
                    rom_req <= 1'b0;
                    gp_req <= 1'b0;
                end else case (owner)
                    RAM: if (ram_accepted && mem_rsp_valid) begin
                        if (shared_at_command)
                            cpu_din <= {2{ram_word[7:0]}};
                        else if (wram_at_command && hs_ready)
                            cpu_din <= {payload_at_command[1] ? hs_dout[15:8] : ram_word[15:8],
                                        payload_at_command[0] ? hs_dout[7:0] : ram_word[7:0]};
                        else
                            cpu_din <= ram_word;
                        complete <= 1'b1;
                    end
                    LOCAL, OPEN: begin
                        cpu_din <= owner == LOCAL ? local_data : 16'b0;
                        complete <= 1'b1;
                    end
                    default: begin end
                endcase
            end
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            aux_accepted <= 1'b0;
            ram_ack <= 1'b0;
            ram_dout <= '0;
        end else begin
            if (!ram_req) aux_accepted <= 1'b0;
            else if (aux_offer && aux_ready[1]) aux_accepted <= 1'b1;
            ram_ack <= aux_rsp_valid[1];
            if (aux_rsp_valid[1]) ram_dout <= aux_rsp_data[16 +: 16];
        end
    end

    // The view is for last edge's address; drop it if that edge also wrote the word.
    always_ff @(posedge clk) begin
        if (reset) begin
            view_primed <= 1'b0;
            previous_view_word <= '0;
            wram_write <= 1'b0;
            wram_addr <= '0;
            wram_data <= '0;
            wram_we <= '0;
            ctx_sample_valid <= 1'b0;
            ctx_sample_word <= '0;
            ctx_sample_before <= '0;
            ctx_sample_written <= '0;
        end else begin
            view_primed <= 1'b1;
            previous_view_word <= view_word;
            wram_write <= write_wram;
            wram_we <= write_wram ? lanes : 2'b0;
            ctx_sample_valid <= 1'b0;
            if (write_wram) begin
                wram_addr <= {view_word, 1'b0};
                wram_data <= cpu_dout;
                if (lanes == 2'b11 && cpu_fc == 3'd5 && !witness_window &&
                    view_primed && view_valid[0] && previous_view_word == view_word &&
                    !(wram_write && wram_addr[15:1] == view_word) &&
                    !(mem_wram_commit && mem_wram_word == view_word)) begin
                    ctx_sample_valid <= 1'b1;
                    ctx_sample_word <= view_word;
                    ctx_sample_before <= view_data[15:0];
                    ctx_sample_written <= cpu_dout;
                end
            end
        end
    end

// synthesis translate_off
`ifndef SYNTHESIS
    always @(posedge clk)
        if (mem_offer && !mem_ready)
            $fatal(1, "PRIMARY_RAM_REFUSAL");
`endif
// synthesis translate_on
endmodule

module rzearly_bus (
    output raizing_socket_pkg::mem_in_t sk_mem_i,
    input raizing_socket_pkg::mem_out_t sk_mem_o,

    input raizing_board_pkg::board_e board,
    input wire clk, reset,
    input wire [23:1] cpu_addr,
    input wire cpu_as_n, cpu_rw, cpu_uds_n, cpu_lds_n,
    input wire [2:0] cpu_fc,
    input wire [15:0] cpu_dout,
    input wire block_writes, override_valid,
    output wire [15:0] cpu_din,
    output wire selected, busy, idle,
    output wire rom_req,
    output wire [18:0] rom_addr,
    input wire rom_ok,
    input wire [15:0] rom_data,
    output wire gp_req, gp_start,
    output wire [2:0] gp_op,
    output wire [1:0] gp_be,
    output wire [15:0] gp_din,
    input wire gp_ack,
    input wire [15:0] gp_dout,
    input wire [8:0] vpos,
    input wire status_hs_n, status_vs_n, status_blank_n,
    input wire [7:0] p1_inputs, p2_inputs, sys_inputs, dsw_a, dsw_b, dsw_c,
    input wire [10:0] pal_addr,
    output wire [15:0] pal_data,
    input wire [11:0] text_addr,
    output wire [15:0] text_data,
    input wire [7:0] select_addr, scroll_addr,
    output wire [15:0] select_data, scroll_data,
    input wire [12:0] z80_addr,
    input wire [7:0] z80_din,
    input wire z80_we,
    output wire [7:0] z80_dout,
    input wire ram_enable, ram_req,
    input wire [2:0] ram_region,
    input wire [14:0] ram_addr,
    input wire [15:0] ram_din,
    input wire [1:0] ram_we,
    output wire ram_ack,
    output wire [15:0] ram_dout,
    input wire state_active, state_valid,
    output wire state_ready,
    input wire [2:0] state_region,
    input wire [14:0] state_addr,
    input wire [15:0] state_din,
    input wire [1:0] state_we,
    output wire state_rsp_valid,
    input wire state_rsp_ready,
    output wire [15:0] state_q,
    output wire state_error,
    input wire hs_ready,
    input wire [15:0] hs_dout,
    output wire hs_cs,
    output wire [6:0] hs_addr,
    output wire [15:0] hs_din,
    output wire [1:0] hs_we,
    output wire wram_write,
    output wire [15:0] wram_addr, wram_data,
    output wire [1:0] wram_we,
    output wire oki_bank_write,
    output wire ctx_sample_valid,
    output wire [14:0] ctx_sample_word,
    output wire [15:0] ctx_sample_before, ctx_sample_written
);
    wire early_sorcer = board == raizing_board_pkg::RZB_SORCER;
    rzearly_bus_binding binding (
        .sk_mem_i(sk_mem_i), .sk_mem_o(sk_mem_o),
        .early_sorcer(early_sorcer),
        .clk(clk), .reset(reset), .cpu_addr(cpu_addr),
        .cpu_as_n(cpu_as_n), .cpu_rw(cpu_rw), .cpu_uds_n(cpu_uds_n),
        .cpu_lds_n(cpu_lds_n), .cpu_fc(cpu_fc), .cpu_dout(cpu_dout),
        .block_writes(block_writes), .override_valid(override_valid), .cpu_din(cpu_din),
        .selected(selected), .busy(busy), .idle(idle),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_ok(rom_ok),
        .rom_data(rom_data), .gp_req(gp_req), .gp_start(gp_start),
        .gp_op(gp_op), .gp_be(gp_be), .gp_din(gp_din),
        .gp_ack(gp_ack), .gp_dout(gp_dout), .vpos(vpos),
        .status_hs_n(status_hs_n), .status_vs_n(status_vs_n), .status_blank_n(status_blank_n),
        .p1_inputs(p1_inputs), .p2_inputs(p2_inputs), .sys_inputs(sys_inputs),
        .dsw_a(dsw_a), .dsw_b(dsw_b), .dsw_c(dsw_c),
        .pal_addr(pal_addr), .pal_data(pal_data), .text_addr(text_addr),
        .text_data(text_data), .select_addr(select_addr), .scroll_addr(scroll_addr),
        .select_data(select_data), .scroll_data(scroll_data), .z80_addr(z80_addr),
        .z80_din(z80_din), .z80_we(z80_we), .z80_dout(z80_dout),
        .ram_enable(ram_enable), .ram_req(ram_req), .ram_region(ram_region),
        .ram_addr(ram_addr), .ram_din(ram_din), .ram_we(ram_we),
        .ram_ack(ram_ack), .ram_dout(ram_dout), .state_active(state_active),
        .state_valid(state_valid), .state_ready(state_ready), .state_region(state_region),
        .state_addr(state_addr), .state_din(state_din), .state_we(state_we),
        .state_rsp_valid(state_rsp_valid), .state_rsp_ready(state_rsp_ready), .state_q(state_q),
        .state_error(state_error), .hs_ready(hs_ready), .hs_dout(hs_dout),
        .hs_cs(hs_cs), .hs_addr(hs_addr), .hs_din(hs_din),
        .hs_we(hs_we), .wram_write(wram_write), .wram_addr(wram_addr),
        .wram_data(wram_data), .wram_we(wram_we), .ctx_sample_valid(ctx_sample_valid),
        .ctx_sample_word(ctx_sample_word), .ctx_sample_before(ctx_sample_before), .ctx_sample_written(ctx_sample_written),
        .oki_bank_write(oki_bank_write)
    );
endmodule

module rzearly_main_cpu (
    output raizing_socket_pkg::ctx_in_t sk_ctx_i,
    input raizing_socket_pkg::ctx_out_t sk_ctx_o,

    output raizing_socket_pkg::mem_in_t sk_mem_i,
    input raizing_socket_pkg::mem_out_t sk_mem_o,

    output raizing_socket_pkg::cpu_in_t sk_cpu_i,
    input raizing_socket_pkg::cpu_out_t sk_cpu_o,

    input raizing_board_pkg::board_e board,
    input wire clk, reset, pause, hold_req, ss_freeze,
    output wire quiesced,
    output wire rom_req,
    output wire [18:0] rom_addr,
    input wire rom_ok,
    input wire [15:0] rom_data,
    output wire gp_req, gp_start,
    output wire [2:0] gp_op,
    output wire [1:0] gp_be,
    output wire [15:0] gp_din,
    input wire gp_ack,
    input wire [15:0] gp_dout,
    input wire vblank_n,
    input wire [8:0] vpos,
    input wire status_hs_n, status_vs_n, status_blank_n,
    input wire [7:0] p1_inputs, p2_inputs, sys_inputs, dsw_a, dsw_b, dsw_c,
    input wire [10:0] pal_addr,
    output wire [15:0] pal_data,
    input wire [11:0] text_addr,
    output wire [15:0] text_data,
    input wire [7:0] select_addr, scroll_addr,
    output wire [15:0] select_data, scroll_data,
    input wire [12:0] z80_addr,
    input wire [7:0] z80_din,
    input wire z80_we,
    output wire [7:0] z80_dout,
    input wire ram_req, ram_access_enable,
    input wire [2:0] ram_region,
    input wire [14:0] ram_addr,
    input wire [15:0] ram_din,
    input wire [1:0] ram_we,
    output wire ram_ack,
    output wire [15:0] ram_dout,
    input wire hs_ready,
    input wire [15:0] hs_dout,
    output wire hs_cs,
    output wire [6:0] hs_addr,
    output wire [15:0] hs_din,
    output wire [1:0] hs_we,
    output wire wram_write,
    output wire [15:0] wram_addr, wram_data,
    output wire [1:0] wram_we,
    output wire m68k_reset_n,
    output wire oki_bank,
    input rzctx_slot_pkg::request_t ctx_request,
    output rzctx_slot_pkg::response_t ctx_response,
    output wire ctx_fault,
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
    wire private_claim, private_reset, private_l7, cpu_halted_n;
    wire ctx_parked, ctx_held, ctx_captured, ctx_admitted, ctx_busy;
    wire service_run;
    wire bus_selected, bus_busy, bus_idle;
    wire [15:0] cpu_out, bus_in, private_in;
    wire private_dtack_n, private_vpa_n, bus_dtack_n, irq_vpa_n, cpu_space;
    wire [2:0] ipl_n;
    wire ordinary_as_n = cpu_as_n | private_claim;
    wire cpu_dtack_n = private_claim ? private_dtack_n : (cpu_space | bus_dtack_n);
    wire cpu_vpa_n = private_claim ? private_vpa_n : irq_vpa_n;
    wire host_hold = pause | hold_req | ss_freeze;
    wire run_cpu = reset | (!ctx_fault &&
        (private_reset || (!ctx_parked && !ctx_held &&
            (service_run || !host_hold || !cpu_as_n))));
    wire phases_low = !(cpu_phase1 | cpu_phase2);
    assign quiesced = host_hold && !service_run && phases_low &&
        ((cpu_as_n && bus_idle) || ctx_parked || ctx_held);
    // quiesced without host_hold, which ram_access_enable implies.
    wire normal_ram = !service_run && phases_low &&
        ((cpu_as_n && bus_idle) || ctx_parked || ctx_held) && ram_access_enable;
`ifdef SIMULATION
    always @(posedge clk)
        if (!reset && ram_access_enable && !host_hold) $fatal(1, "EARLY_RAM_ACCESS_WITHOUT_HOLD");
`endif
    // Journal hold: bus idle and low phases sampled once, then held while ctx_parked.
    logic journal_held_q;
    always_ff @(posedge clk) journal_held_q <= !reset && ctx_parked && bus_idle && phases_low;
    wire journal_held = journal_held_q && ctx_parked;

    // Latch ACK and claim while AS is low; bus_done is the first AS-high sample after an ACK.
    logic previous_as_n, saw_ack, last_claim, first_iack7;
    always_ff @(posedge clk) begin
        if (reset) begin
            previous_as_n <= 1'b1;
            saw_ack       <= 1'b0;
            last_claim    <= 1'b0;
            first_iack7   <= 1'b0;
        end else begin
            previous_as_n <= cpu_as_n;
            if (cpu_as_n) begin
                saw_ack <= 1'b0;
            end else begin
                saw_ack <= saw_ack || !cpu_dtack_n || !cpu_vpa_n;
                last_claim <= private_claim;
                if (previous_as_n)
                    first_iack7 <= (cpu_fc == 3'd7 && cpu_addr[3:1] == 3'd7);
            end
        end
    end
    wire bus_done = !reset && cpu_as_n && !previous_as_n && saw_ack;

    // Socket sk_cpu: pins of the shared fx68k instance.
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
    assign sk_cpu_i.IPL0n = ipl_n[0];
    assign sk_cpu_i.IPL1n = ipl_n[1];
    assign sk_cpu_i.IPL2n = ipl_n[2];
    assign sk_cpu_i.iEdb = private_claim ? private_in : bus_in;
    assign cpu_rw = sk_cpu_o.eRWn;
    assign cpu_as_n = sk_cpu_o.ASn;
    assign cpu_lds_n = sk_cpu_o.LDSn;
    assign cpu_uds_n = sk_cpu_o.UDSn;
    assign cpu_fc[0] = sk_cpu_o.FC0;
    assign cpu_fc[1] = sk_cpu_o.FC1;
    assign cpu_fc[2] = sk_cpu_o.FC2;
    assign m68k_reset_n = sk_cpu_o.oRESETn;
    assign cpu_halted_n = sk_cpu_o.oHALTEDn;
    assign cpu_out = sk_cpu_o.oEdb;
    assign cpu_addr = sk_cpu_o.eab;

    raizing_68k_bus phase_scheduler (
        .clk(clk), .reset(reset), .run(run_cpu), .address_n(ordinary_as_n),
        .strobe_n({cpu_uds_n, cpu_lds_n}), .selected(bus_selected), .busy(bus_busy),
        .phase1(cpu_phase1), .phase2(cpu_phase2), .dtack_n(bus_dtack_n)
    );

    wire slot_cmd, slot_word, slot_write;
    wire [2:0] slot_op;
    wire [5:0] slot_index;
    wire [15:0] slot_data;
    assign {slot_cmd, slot_op, slot_word, slot_write, slot_index, slot_data} = ctx_request;
    wire service_cmd, service_read;
    wire [2:0] service_op;
    wire [5:0] service_index;
    wire rsp_valid, rsp_ok, word_ack, word_nak, event_valid;
    wire [3:0] rsp_code, event_code;
    wire [15:0] word_data;
    assign ctx_response = {rsp_valid, rsp_ok, rsp_code, word_ack, word_nak,
                           word_data, ctx_admitted, ss_save_ready};
    assign ss_busy = ctx_busy | service_run;

    // Socket sk_ctx: pins of the shared rzctx_core instance.
    assign sk_ctx_i.clk = clk;
    assign sk_ctx_i.rst = reset;
    assign sk_ctx_i.cpu_tick = cpu_phase1;
    assign sk_ctx_i.ram_lo = 23'h080000;
    assign sk_ctx_i.ram_hi = 23'h087fff;
    assign sk_ctx_i.cpu_as_n = cpu_as_n;
    assign sk_ctx_i.cpu_uds_n = cpu_uds_n;
    assign sk_ctx_i.cpu_lds_n = cpu_lds_n;
    assign sk_ctx_i.cpu_rw = cpu_rw;
    assign sk_ctx_i.cpu_fc = cpu_fc;
    assign sk_ctx_i.cpu_addr = cpu_addr;
    assign sk_ctx_i.cpu_dout = cpu_out;
    assign sk_ctx_i.cpu_halted_n = cpu_halted_n;
    assign sk_ctx_i.bus_done = bus_done;
    assign sk_ctx_i.cmd_valid = service_cmd | slot_cmd;
    assign sk_ctx_i.cmd_op = service_cmd ? service_op : slot_op;
    assign sk_ctx_i.ctx_req = service_read | slot_word;
    assign sk_ctx_i.ctx_we = !service_read && slot_write;
    assign sk_ctx_i.ctx_bank = !service_read && slot_write;
    assign sk_ctx_i.ctx_idx = service_read ? service_index : slot_index;
    assign sk_ctx_i.ctx_wdata = slot_data;
    assign private_claim = sk_ctx_o.bus_claim;
    assign private_dtack_n = sk_ctx_o.cpu_dtack_n;
    assign private_vpa_n = sk_ctx_o.cpu_vpa_n;
    assign private_in = sk_ctx_o.cpu_din;
    assign private_l7 = sk_ctx_o.ipl7_req;
    assign private_reset = sk_ctx_o.cpu_reset;
    assign rsp_valid = sk_ctx_o.rsp_valid;
    assign rsp_ok = sk_ctx_o.rsp_ok;
    assign rsp_code = sk_ctx_o.rsp_code;
    assign word_ack = sk_ctx_o.ctx_ack;
    assign word_nak = sk_ctx_o.ctx_nak;
    assign word_data = sk_ctx_o.ctx_rdata;
    assign ctx_busy = sk_ctx_o.st_busy;
    assign ctx_parked = sk_ctx_o.st_parked;
    assign ctx_held = sk_ctx_o.st_held;
    assign ctx_captured = sk_ctx_o.st_cap_valid;
    assign ctx_admitted = sk_ctx_o.st_admitted;
    assign event_valid = sk_ctx_o.evt_valid;
    assign event_code = sk_ctx_o.evt_code;

    wire journal_arm, journal_cancel, journal_confirm, journal_done, journal_fault;
    wire [14:0] journal_word;
    wire [15:0] journal_pc;
    rzctx_board_service board_service (
        .clk(clk), .reset(reset),
        .save_begin(ss_save_begin), .save_resume(ss_save_resume),
        .restore_begin(ss_restore_begin), .parked(ctx_parked),
        .captured(ctx_captured), .admitted(ctx_admitted),
        .event_valid(event_valid), .event_code(event_code),
        .cmd_valid(service_cmd), .cmd_op(service_op), .rsp_valid(rsp_valid), .rsp_ok(rsp_ok),
        .ctx_req(service_read), .ctx_idx(service_index),
        .ctx_ack(word_ack), .ctx_nak(word_nak), .ctx_rdata(word_data),
        .journal_arm(journal_arm), .journal_cancel(journal_cancel),
        .journal_confirm(journal_confirm), .journal_word(journal_word), .journal_pc(journal_pc),
        .journal_done(journal_done), .journal_fault(journal_fault), .service_run(service_run),
        .save_ready(ss_save_ready), .save_done(ss_save_done),
        .restore_done(ss_restore_done), .fault(ctx_fault)
    );

    wire sample_valid;
    wire [14:0] sample_word, undo_word, region_addr;
    wire [15:0] sample_before, sample_written, undo_data, region_data, secondary_q;
    wire undo_valid, undo_reply_ready, region_active, region_valid, region_reply_ready;
    wire secondary_ready, secondary_reply_valid, secondary_error;
    wire [2:0] region_number;
    wire [1:0] region_we;
    wire bank_write, bank_restore;
    wire [7:0] bank_restore_data;
    // The reply phase retains ownership after request acceptance.
    wire undo_owns = undo_valid | undo_reply_ready;
    rzctx_stack_undo stack_undo (
        .clk(clk), .reset(reset), .arm(journal_arm), .cancel(journal_cancel),
        .ordinary_done(bus_done && !last_claim),
        .private_iack_done(bus_done && last_claim && first_iack7),
        .sample_valid(sample_valid), .sample_word(sample_word),
        .sample_before(sample_before), .sample_written(sample_written),
        .confirm(journal_confirm), .frame_word(journal_word), .frame_pc_low(journal_pc),
        .wram_held(journal_held), .undo_valid(undo_valid),
        .undo_ready(undo_owns && secondary_ready), .undo_word(undo_word), .undo_data(undo_data),
        .response_valid(undo_owns && secondary_reply_valid), .response_error(secondary_error),
        .response_ready(undo_reply_ready), .done(journal_done), .fault(journal_fault)
    );

    wire region_ack, irq_ack, bank_ack;
    wire [63:0] region_state_data, irq_state_data, bank_state_data;
    rzmem_ss_regions state_regions (
        .clk(clk), .reset(reset), .access_enable(normal_ram && ss_freeze),
        .ss_data(ss_data), .ss_addr(ss_addr), .ss_select(ss_select),
        .ss_write(ss_write), .ss_read(ss_read), .ss_query(ss_query),
        .ss_data_out(region_state_data), .ss_ack(region_ack), .active(region_active),
        .req_valid(region_valid), .req_ready(!undo_owns && secondary_ready),
        .req_region(region_number), .req_addr(region_addr), .req_data(region_data),
        .req_we(region_we), .rsp_valid(!undo_owns && secondary_reply_valid),
        .rsp_ready(region_reply_ready), .rsp_data(secondary_q), .rsp_error(secondary_error)
    );

    rzearly_bus game_bus (
        .sk_mem_i(sk_mem_i), .sk_mem_o(sk_mem_o),
        .board(board),
        .clk(clk), .reset(reset), .cpu_addr(cpu_addr), .cpu_as_n(ordinary_as_n),
        .cpu_rw(cpu_rw), .cpu_uds_n(cpu_uds_n), .cpu_lds_n(cpu_lds_n), .cpu_fc(cpu_fc),
        .cpu_dout(cpu_out), .block_writes(1'b0), .override_valid(1'b0), .cpu_din(bus_in),
        .selected(bus_selected), .busy(bus_busy), .idle(bus_idle),
        .rom_req(rom_req), .rom_addr(rom_addr), .rom_ok(rom_ok), .rom_data(rom_data),
        .gp_req(gp_req), .gp_start(gp_start), .gp_op(gp_op), .gp_be(gp_be),
        .gp_din(gp_din), .gp_ack(gp_ack), .gp_dout(gp_dout),
        .vpos(vpos), .status_hs_n(status_hs_n), .status_vs_n(status_vs_n),
        .status_blank_n(status_blank_n), .p1_inputs(p1_inputs), .p2_inputs(p2_inputs),
        .sys_inputs(sys_inputs), .dsw_a(dsw_a), .dsw_b(dsw_b), .dsw_c(dsw_c),
        .pal_addr(pal_addr), .pal_data(pal_data), .text_addr(text_addr), .text_data(text_data),
        .select_addr(select_addr), .select_data(select_data),
        .scroll_addr(scroll_addr), .scroll_data(scroll_data),
        .z80_addr(z80_addr), .z80_din(z80_din), .z80_we(z80_we), .z80_dout(z80_dout),
        .ram_enable(normal_ram | journal_held), .ram_req(ram_req), .ram_region(ram_region),
        .ram_addr(ram_addr), .ram_din(ram_din), .ram_we(ram_we),
        .ram_ack(ram_ack), .ram_dout(ram_dout),
        .state_active(region_active | undo_owns),
        .state_valid(undo_owns ? undo_valid : region_valid), .state_ready(secondary_ready),
        .state_region(undo_owns ? 3'd0 : region_number),
        .state_addr(undo_owns ? undo_word : region_addr),
        .state_din(undo_owns ? undo_data : region_data),
        .state_we(undo_owns ? 2'b11 : region_we),
        .state_rsp_valid(secondary_reply_valid),
        .state_rsp_ready(undo_owns ? undo_reply_ready : region_reply_ready),
        .state_q(secondary_q), .state_error(secondary_error),
        .hs_ready(hs_ready), .hs_dout(hs_dout), .hs_cs(hs_cs), .hs_addr(hs_addr),
        .hs_din(hs_din), .hs_we(hs_we), .wram_write(wram_write),
        .wram_addr(wram_addr), .wram_data(wram_data), .wram_we(wram_we),
        .oki_bank_write(bank_write),
        .ctx_sample_valid(sample_valid), .ctx_sample_word(sample_word),
        .ctx_sample_before(sample_before), .ctx_sample_written(sample_written)
    );

    wire irq_restore, previous_video_n, video_pending;
    wire [1:0] irq_restore_data;
    // Kingdom IRQ profile for both boards; vblank_n carries the per-board VINT/LVBL source.
    rzirq_owner #(.PROFILE(raizing_board_pkg::irq_profile(raizing_board_pkg::RZB_KINGDOM))) irq_owner (
        .alt_levels(1'b0),
        .clk(clk), .board_reset(reset), .state_hold(ss_freeze), .state_load(irq_restore),
        .load_video_pending(irq_restore_data[0]), .load_previous_video_n(irq_restore_data[1]),
        .load_sound_pending(1'b0),
        .gp_vint_n(1'b1), .raw_lvbl_n(vblank_n),
        .sound_irq(1'b0), .sound_clear(1'b0), .priv_l7(private_l7),
        .cpu_as_n(ordinary_as_n), .cpu_fc(cpu_fc), .cpu_a(cpu_addr[3:1]),
        .irq_level(), .ipl_n(ipl_n), .vpa_n(irq_vpa_n), .cpu_space(cpu_space),
        .video_pending(video_pending), .previous_video_n(previous_video_n),
        .sound_pending(), .owned_fields(), .unsupported()
    );

    raizing_ss_register #(.WIDTH(2), .SS_INDEX(10)) irq_state (
        .clk(clk), .reset(reset), .capture_data({previous_video_n, video_pending}),
        .restore_data(irq_restore_data), .restore_we(irq_restore),
        .ss_data(ss_data), .ss_select(ss_select), .ss_write(ss_write && ss_freeze),
        .ss_read(ss_read), .ss_query(ss_query), .ss_data_out(irq_state_data), .ss_ack(irq_ack)
    );

    // Sorcer's bank stays 0; the bus binding gates its bank writes.
    rzearly_oki_bank bank_owner (
        .clk(clk), .reset(reset), .freeze(ss_freeze), .write_valid(bank_write),
        .write_data(cpu_out[7:0]), .restore_valid(bank_restore),
        .restore_bank(bank_restore_data[0]), .bank(oki_bank)
    );
    raizing_ss_register #(.WIDTH(8), .SS_INDEX(17)) bank_state (
        .clk(clk), .reset(reset), .capture_data({7'b0, oki_bank}),
        .restore_data(bank_restore_data), .restore_we(bank_restore),
        .ss_data(ss_data), .ss_select(ss_select),
        .ss_write(ss_write && ss_freeze && (ss_addr == 32'd0)),
        .ss_read(ss_read && (ss_addr == 32'd0)), .ss_query(ss_query),
        .ss_data_out(bank_state_data), .ss_ack(bank_ack)
    );
    assign ss_ack = region_ack | irq_ack | bank_ack;
    assign ss_data_out = (region_ack ? region_state_data : 64'd0) |
                         (irq_ack ? irq_state_data : 64'd0) |
                         (bank_ack ? bank_state_data : 64'd0);

`ifndef SYNTHESIS
    always @(posedge clk) begin
        if (!reset) begin
            if (service_cmd && slot_cmd)
                $error("RZ_EARLY_SLOT_COMMAND_COLLISION");
            if (service_read && slot_word)
                $error("RZ_EARLY_SLOT_WORD_COLLISION");
            if (undo_owns && region_active)
                $error("RZ_EARLY_RAM_OWNER_COLLISION");
        end
    end
`endif
endmodule

// Kingdom's PCM bank: write bit 4 selects the upper 256 KiB OKI half.
module rzearly_oki_bank (
    input  logic       clk,
    input  logic       reset,
    input  logic       freeze,
    input  logic       write_valid,
    input  logic [7:0] write_data,
    input  logic       restore_valid,
    input  logic       restore_bank,
    output logic       bank
);
    always @(posedge clk) begin
        if (reset)
            bank <= 1'b0;
        else if (freeze) begin
            if (restore_valid)
                bank <= restore_bank;
        end else if (write_valid)
            bank <= write_data[4];
    end
endmodule

// Early-board top: CPU, GP/text video, sound and score owners for one BOARD.
module rzearly_board (
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

    input raizing_board_pkg::board_e board,   // latched board (constant in fixed builds)
    input  wire clk, reset, platform_reset,
    input  wire pixel_ce, z80_ce, ym_ce, ym_phase1_ce, oki_ce,
    input  wire user_pause, cpu_hold, sound_hold, video_hold, ram_access_enable, ss_freeze,
    input  rzctx_slot_pkg::request_t ctx_request,
    output rzctx_slot_pkg::response_t ctx_response,
    output wire ctx_fault,
    input  wire save_begin, save_resume, restore_begin, restore_window, audio_restore,
    output wire cpu_quiesced, sound_held, video_held,
    output wire save_ready, save_done, restore_done, handler_busy,
    input  wire [1:0][9:0] joy,
    input  wire [1:0] start_button, coin,
    input  wire service,
    input  wire [7:0] dsw_a, dsw_b, dsw_c,
    input  wire [1:0] fx_level,
    input  wire fm_enable, pcm_enable,
    output wire [6:0] rom_request,
    output wire [153:0] rom_address,
    // CPU and sound consume only the low bytes/word of their response lanes.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [223:0] rom_data,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire [6:0] rom_ok,
    output wire object_req_valid,
    input  wire object_req_ready,
    output wire [21:0] object_req_addr,
    input  wire object_rsp_valid,
    output wire object_rsp_ready,
    input  wire [31:0] object_rsp_data,
    input  wire object_rsp_error,
    output wire [13:0] text_rom_addr,
    input  wire [15:0] text_rom_data,
    output wire [7:0] red, green, blue,
    output wire lhbl, lvbl,
    output wire [8:0] hcount, vcount,
    output wire signed [15:0] audio,
    input  wire nv_download, nv_upload, nv_write, nv_read,
    input  wire [26:0] nv_addr,
    input  wire [7:0] nv_data,
    output wire [7:0] nv_q,
    output wire nv_wait, nv_request, highscore_busy,
    input  wire nv_manual, nv_autosave, osd_open,
    input  wire state_active,
    input  wire [63:0] SS_DATA,
    input  wire [31:0] SS_ADDR,
    input  wire [7:0] SS_SELECT,
    input  wire SS_WRITE, SS_READ, SS_QUERY,
    output wire [63:0] SS_DATA_OUT,
    output wire SS_ACK,
    output wire video_error, sound_state_fault
);
    localparam integer ADDR_BITS = 22;
    wire KINGDOM = board == raizing_board_pkg::RZB_KINGDOM;
    localparam integer INPUT_PROFILE = 1;   // inputs are identical on both early boards
    localparam integer GFX_BITS = 21, PCM_BITS = 19;   // Kingdom widths; Sorcer masked below
    wire oki_bank;
    wire video_vint_n, video_lvbl;

    wire [7:0] player1, player2, system_inputs;
    wire [18:0] cpu_rom_word;
    wire [15:0] sound_rom_byte;
    wire [PCM_BITS-1:0] pcm_rom_byte;
    wire pcm_request;
    // Each word field includes bits above the selected profile's address mask.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [87:0] gfx_rom_words;
    /* verilator lint_on UNUSEDSIGNAL */
    wire gp_request, gp_ack;
    wire [2:0] gp_op;
    wire [1:0] gp_be;
    wire [15:0] gp_din, gp_dout;
    wire cpu_irq_n, cpu_hsync_n, cpu_vsync_n, cpu_fblank;
    wire [10:0] pal_addr;
    wire [11:0] text_addr;
    wire [7:0] select_addr, scroll_addr;
    wire [15:0] pal_data, text_data, select_data, scroll_data;
    wire [12:0] shared_addr;
    wire [7:0] shared_write_data, shared_read_data;
    wire shared_write, main_reset_n;
    wire audio_held, audio_ready;
    wire score_hold, score_ready;
    // The score owner waits for the CPU quiesce acknowledgement.
    logic score_hold_q;
    always_ff @(posedge clk)
        if (platform_reset || reset) score_hold_q <= 1'b0;
        else score_hold_q <= score_hold;
    wire [6:0] score_addr;
    wire [15:0] score_write_data, score_read_data;
    wire [1:0] score_we;
    wire wram_write;
    wire [15:0] wram_addr, wram_data;
    wire [1:0] wram_we;
    wire video_state_error, video_object_error;
    wire cpu_state_ack, audio_state_ack, video_state_ack, score_state_ack;
    wire [63:0] cpu_state_word, audio_state_word, video_state_word, score_state_word;
    logic gp_state_hold;

    assign rom_address[0*ADDR_BITS +: ADDR_BITS] = {2'b00, cpu_rom_word, 1'b0};
    assign rom_address[1*ADDR_BITS +: ADDR_BITS] = {6'b0, sound_rom_byte};
    assign rom_address[2*ADDR_BITS +: ADDR_BITS] = {{(ADDR_BITS-PCM_BITS){1'b0}}, pcm_rom_byte};
    assign rom_request[2] = pcm_request & ~reset;
    genvar lane;
    generate
    for (lane = 0; lane < 4; lane = lane + 1) begin : g_gfx_byte_address
        assign rom_address[(lane+3)*ADDR_BITS +: ADDR_BITS] =
            {{(ADDR_BITS-GFX_BITS-1){1'b0}},
             gfx_rom_words[lane*ADDR_BITS +: GFX_BITS] & {KINGDOM, {(GFX_BITS-1){1'b1}}}, 1'b0};
    end
    endgenerate

    // sound_held is read only while state_active or one clock after.
    assign sound_held = state_active && audio_ready;
    assign video_error = video_state_error | video_object_error;
    assign SS_ACK = cpu_state_ack | audio_state_ack | video_state_ack | score_state_ack;
    assign SS_DATA_OUT = (cpu_state_ack   ? cpu_state_word   : 64'b0)
                       | (audio_state_ack ? audio_state_word : 64'b0)
                       | (video_state_ack ? video_state_word : 64'b0)
                       | (score_state_ack ? score_state_word : 64'b0);

    // Once sampled, quiescence grants the GP hold for the rest of this operation.
    always_ff @(posedge clk) begin
        if (reset || !state_active)
            gp_state_hold <= 1'b0;
        else if (video_held)
            gp_state_hold <= 1'b1;
    end

    rzboard_inputs #(.PROFILE(INPUT_PROFILE)) cabinet (
        .player1_n(joy[0]), .player2_n(joy[1]), .start_n(start_button), .coin_n(coin),
        .service_n(service), .dip_a(dsw_a),
        .player1(player1), .player2(player2), .system_inputs(system_inputs)
    );

    rzearly_main_cpu cpu (
        .sk_ctx_i(sk_ctx_i), .sk_ctx_o(sk_ctx_o),
        .sk_cpu_i(sk_cpu_i), .sk_cpu_o(sk_cpu_o),
        .sk_mem_i(sk_mem_i), .sk_mem_o(sk_mem_o),
        .board(board),
        .clk(clk), .reset(reset), .pause(user_pause),
        .hold_req(cpu_hold | score_hold_q), .ss_freeze(ss_freeze), .quiesced(cpu_quiesced),
        .rom_req(rom_request[0]), .rom_addr(cpu_rom_word), .rom_ok(rom_ok[0]),
        .rom_data(rom_data[0*32 +: 16]),
        .gp_req(gp_request), .gp_start(), .gp_op(gp_op), .gp_be(gp_be),
        .gp_din(gp_din), .gp_ack(gp_ack), .gp_dout(gp_dout),
        .vblank_n(cpu_irq_n), .vpos(vcount),
        .status_hs_n(cpu_hsync_n), .status_vs_n(cpu_vsync_n), .status_blank_n(cpu_fblank),
        .p1_inputs(player1), .p2_inputs(player2), .sys_inputs(system_inputs),
        .dsw_a(dsw_a), .dsw_b(dsw_b), .dsw_c(dsw_c),
        .pal_addr(pal_addr), .pal_data(pal_data), .text_addr(text_addr), .text_data(text_data),
        .select_addr(select_addr), .select_data(select_data),
        .scroll_addr(scroll_addr), .scroll_data(scroll_data),
        .z80_addr(shared_addr), .z80_din(shared_write_data),
        .z80_we(shared_write), .z80_dout(shared_read_data),
        .ram_req(1'b0), .ram_access_enable(ram_access_enable), .ram_region(3'b0),
        .ram_addr(15'b0), .ram_din(16'b0), .ram_we(2'b0), .ram_ack(), .ram_dout(),
        .hs_ready(score_ready), .hs_dout(score_read_data), .hs_cs(),
        .hs_addr(score_addr), .hs_din(score_write_data), .hs_we(score_we),
        .wram_write(wram_write), .wram_addr(wram_addr), .wram_data(wram_data), .wram_we(wram_we),
        .m68k_reset_n(main_reset_n),
        .oki_bank(oki_bank),
        .ctx_request(ctx_request), .ctx_response(ctx_response), .ctx_fault(ctx_fault),
        .ss_save_begin(save_begin), .ss_save_resume(save_resume),
        .ss_restore_begin(restore_begin), .ss_restore_window(restore_window),
        .ss_save_ready(save_ready), .ss_save_done(save_done),
        .ss_restore_done(restore_done), .ss_busy(handler_busy),
        .ss_data(SS_DATA), .ss_addr(SS_ADDR), .ss_select(SS_SELECT),
        .ss_write(SS_WRITE), .ss_read(SS_READ), .ss_query(SS_QUERY),
        .ss_data_out(cpu_state_word), .ss_ack(cpu_state_ack),
        .cpu_addr(), .cpu_as_n(), .cpu_rw(), .cpu_uds_n(), .cpu_lds_n(),
        .cpu_fc(), .cpu_phase1(), .cpu_phase2()
    );

    // Kingdom's CPU vertical interrupt is raw LVBL; Sorcer's is the GP VINT.
    assign cpu_irq_n = KINGDOM ? video_lvbl : video_vint_n;

    wire [22:0] video_object_addr;
    assign object_req_addr = video_object_addr[21:0];
    // Socket sk_video: pins of the shared raizing_video instance.
    assign sk_video_i.clk = clk;
    assign sk_video_i.reset = reset;
    assign sk_video_i.pixel_ce = pixel_ce;
    assign sk_video_i.flip = 1'b0;
    assign sk_video_i.hs_start = 9'd325;
    assign sk_video_i.hs_end = 9'd380;
    assign sk_video_i.vs_start = 9'd232;
    assign sk_video_i.vs_end = 9'd245;
    assign sk_video_i.gp_cs = gp_request;
    assign sk_video_i.gp_select_reg = gp_op == 3'd4;
    assign sk_video_i.gp_write_reg = gp_op == 3'd5;
    assign sk_video_i.gp_write_ram = gp_op == 3'd1;
    assign sk_video_i.gp_read_ram_h = gp_op == 3'd2;
    assign sk_video_i.gp_read_ram_l = gp_op == 3'd3;
    assign sk_video_i.gp_set_ram_ptr = gp_op == 3'd0;
    assign sk_video_i.gp_din = gp_din;
    assign sk_video_i.gp_be = gp_be;
    assign sk_video_i.gfx_data = rom_data[6*32+31:3*32];
    assign sk_video_i.gfx_ok = rom_ok[6:3];
    assign sk_video_i.object_req_ready = object_req_ready;
    assign sk_video_i.object_rsp_valid = object_rsp_valid;
    assign sk_video_i.object_rsp_data = object_rsp_data;
    assign sk_video_i.object_rsp_error = object_rsp_error;
    assign sk_video_i.object_port_idle = 1'b1;
    assign sk_video_i.gp_objectbank_wr = 1'b0;   // no object-bank register on this board
    assign sk_video_i.gp_objectbank_slot = 3'd0;
    assign sk_video_i.PALRAM_DATA = pal_data;
    assign sk_video_i.TEXTROM_DATA = text_rom_data;
    assign sk_video_i.TEXTVRAM_DATA = text_data;
    assign sk_video_i.TEXTSELECT_DATA = select_data;
    assign sk_video_i.TEXTSCROLL_DATA = scroll_data;
    assign sk_video_i.SS_FREEZE = video_hold;
    assign sk_video_i.STATE_HOLD = gp_state_hold;
    assign sk_video_i.SS_DATA = SS_DATA;
    assign sk_video_i.SS_ADDR = SS_ADDR;
    assign sk_video_i.SS_SELECT = SS_SELECT;
    assign sk_video_i.SS_WRITE = SS_WRITE;
    assign sk_video_i.SS_READ = SS_READ;
    assign sk_video_i.SS_QUERY = SS_QUERY;
    assign gp_ack = sk_video_o.gp_ack;
    assign gp_dout = sk_video_o.gp_dout;
    assign video_vint_n = sk_video_o.vint_n;
    assign cpu_hsync_n = sk_video_o.cpu_hsync_n;
    assign cpu_vsync_n = sk_video_o.cpu_vsync_n;
    assign cpu_fblank = sk_video_o.cpu_fblank;
    assign hcount = sk_video_o.hcount;
    assign vcount = sk_video_o.vcount;
    assign rom_request[6:3] = sk_video_o.gfx_req;
    // The shared video has 24-bit lanes; this board's graphics lanes are 22 bits.
    assign gfx_rom_words = {sk_video_o.gfx_addr[3*24 +: 22], sk_video_o.gfx_addr[2*24 +: 22], sk_video_o.gfx_addr[1*24 +: 22], sk_video_o.gfx_addr[0 +: 22]};
    assign object_req_valid = sk_video_o.object_req_valid;
    assign video_object_addr = sk_video_o.object_req_addr[22:0];
    assign object_rsp_ready = sk_video_o.object_rsp_ready;
    assign video_object_error = sk_video_o.object_error;
    assign pal_addr = sk_video_o.PALRAM_ADDR;
    assign text_rom_addr = sk_video_o.TEXTROM_ADDR;
    assign text_addr = sk_video_o.TEXTVRAM_ADDR;
    assign select_addr = sk_video_o.TEXTSELECT_ADDR;
    assign scroll_addr = sk_video_o.TEXTSCROLL_ADDR;
    assign red = sk_video_o.red;
    assign green = sk_video_o.green;
    assign blue = sk_video_o.blue;
    assign video_lvbl = sk_video_o.lvbl;
    assign lhbl = sk_video_o.lhbl_dly;
    assign lvbl = sk_video_o.lvbl_dly;
    assign video_held = sk_video_o.SS_QUIESCED;
    assign video_state_word = sk_video_o.SS_DATA_OUT;
    assign video_state_ack = sk_video_o.SS_ACK;
    assign video_state_error = sk_video_o.SS_ERROR;

    rzearly_sound sound (
        .sk_z80_i(sk_z80_i), .sk_z80_o(sk_z80_o),
        .sk_fm_i(sk_fm_i), .sk_fm_o(sk_fm_o),
        .sk_oki_i(sk_oki_i), .sk_oki_o(sk_oki_o),
        .clk(clk), .reset(reset), .main_reset_n(main_reset_n),
        .z80_ce(z80_ce), .ym_ce(ym_ce), .ym_phase1_ce(ym_phase1_ce), .oki_ce(oki_ce),
        .oki_bank(oki_bank),
        .hold_request(sound_hold | user_pause), .canonical_hold(state_active),
        .restore_commit(audio_restore), .held(audio_held), .canonical_ready(audio_ready),
        .canonical_fault(sound_state_fault), .replay_busy(), .restore_busy(), .canonical_service(),
        .rom_address(sound_rom_byte), .rom_request(rom_request[1]),
        .rom_data(rom_data[1*32 +: 8]), .rom_ok(rom_ok[1]),
        .shared_address(shared_addr), .shared_data_out(shared_write_data),
        .shared_write(shared_write), .shared_data_in(shared_read_data),
        .pcm_address(pcm_rom_byte), .pcm_request(pcm_request),
        .pcm_data(rom_data[2*32 +: 8]), .pcm_ok(rom_ok[2]),
        .pcm_frozen(), .pcm_resume_busy(), .audio(audio), .sample(),
        .fx_level(fx_level), .fm_enable(fm_enable), .pcm_enable(pcm_enable),
        .SS_DATA(SS_DATA), .SS_ADDR(SS_ADDR), .SS_SELECT(SS_SELECT),
        .SS_WRITE(SS_WRITE), .SS_READ(SS_READ), .SS_QUERY(SS_QUERY),
        .SS_DATA_OUT(audio_state_word), .SS_ACK(audio_state_ack)
    );

    raizing_score_binding score (
        .board(board),
        .clk(clk), .reset(platform_reset), .cpu_reset(reset),
        .nv_download(nv_download), .nv_upload(nv_upload), .nv_write(nv_write), .nv_read(nv_read),
        .nv_addr(nv_addr), .nv_data(nv_data), .nv_q(nv_q), .nv_wait(nv_wait),
        .manual_save(nv_manual), .autosave(nv_autosave), .osd_open(osd_open),
        .upload_request(nv_request), .active(highscore_busy), .dirty(),
        .normal_write(wram_write), .normal_addr(wram_addr), .normal_data(wram_data), .normal_we(wram_we),
        .ready(score_ready), .cpu_addr(score_addr), .cpu_data(score_write_data),
        .cpu_we(score_we), .cpu_q(score_read_data),
        .state_active(state_active), .hold_ack(cpu_quiesced), .hold_request(score_hold),
        .SS_DATA(SS_DATA), .SS_ADDR(SS_ADDR), .SS_SELECT(SS_SELECT),
        .SS_WRITE(SS_WRITE), .SS_READ(SS_READ), .SS_QUERY(SS_QUERY),
        .SS_DATA_OUT(score_state_word), .SS_ACK(score_state_ack)
    );
endmodule
