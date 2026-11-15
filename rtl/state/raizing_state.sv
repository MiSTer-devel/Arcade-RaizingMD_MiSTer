// SPDX-License-Identifier: GPL-3.0-or-later
// Save states: DDR transport, state adapters, stream, identity and OSD slot UI.

// Adapted from MiSTer-devel/Arcade-TaitoF2_MiSTer.

interface raizing_ssbus_if();
    logic [63:0] data;
    logic [31:0] addr;
    logic [7:0] select;
    logic write;
    logic read;
    logic query;
    logic [63:0] data_out;
    logic ack;

    modport stream(output data,addr,select,write,read,query,input data_out,ack);

    function automatic logic access(input integer index);
        return select == index[7:0] && !query && (read || write);
    endfunction

    task automatic setup(
        input integer index,
        input [31:0] count,
        input integer width
    );
        ack <= 1'b0;
        if(select == index[7:0] && query) begin
            data_out <= {index[7:0], 22'd0, width[1:0], count};
            ack <= 1'b1;
        end
    endtask

    task automatic read_response(input integer index, input [63:0] value);
        if(select == index[7:0]) begin
            data_out <= value;
            ack <= 1'b1;
        end
    endtask

    task automatic write_ack(input integer index);
        if(select == index[7:0])
            ack <= 1'b1;
    endtask
endinterface

// Adapted from MiSTer-devel/Arcade-TaitoF2_MiSTer.

interface raizing_ddr_if();
    logic acquire;
    logic [31:0] addr;
    logic [63:0] wdata;
    logic [63:0] rdata;
    logic read;
    logic write;
    logic [7:0] burstcnt;
    logic [7:0] byteenable;
    logic busy;
    logic rdata_ready;
endinterface

module raizing_ddr_mux(
    input clk,
    input reset,
    raizing_ddr_if host,
    raizing_ddr_if high_priority,
    raizing_ddr_if low_priority
);

    reg owner_valid;
    reg owner_high;
    reg read_pending;
    wire selected_high = owner_valid ? owner_high : high_priority.acquire;
    wire selected_acquire = selected_high ? high_priority.acquire :
                                                low_priority.acquire;

    always @* begin
        high_priority.rdata = host.rdata;
        low_priority.rdata = host.rdata;
        high_priority.busy = 1'b1;
        low_priority.busy = 1'b1;
        high_priority.rdata_ready = 1'b0;
        low_priority.rdata_ready = 1'b0;

        host.acquire = high_priority.acquire | low_priority.acquire;
        host.addr = 32'd0;
        host.wdata = 64'd0;
        host.read = 1'b0;
        host.write = 1'b0;
        host.burstcnt = 8'd1;
        host.byteenable = 8'hff;

        if(owner_valid || high_priority.acquire || low_priority.acquire) begin
            if(selected_high) begin
                host.addr = high_priority.addr;
                host.wdata = high_priority.wdata;
                host.read = high_priority.read;
                host.write = high_priority.write;
                host.burstcnt = high_priority.burstcnt;
                host.byteenable = high_priority.byteenable;
                high_priority.busy = host.busy;
                high_priority.rdata_ready = host.rdata_ready;
            end else begin
                host.addr = low_priority.addr;
                host.wdata = low_priority.wdata;
                host.read = low_priority.read;
                host.write = low_priority.write;
                host.burstcnt = low_priority.burstcnt;
                host.byteenable = low_priority.byteenable;
                low_priority.busy = host.busy;
                low_priority.rdata_ready = host.rdata_ready;
            end
        end
    end

    always @(posedge clk) begin
        if(reset) begin
            owner_valid <= 1'b0;
            owner_high <= 1'b0;
            read_pending <= 1'b0;
        end else begin
            if(!owner_valid) begin
                if(high_priority.acquire) begin
                    owner_valid <= 1'b1;
                    owner_high <= 1'b1;
                end else if(low_priority.acquire) begin
                    owner_valid <= 1'b1;
                    owner_high <= 1'b0;
                end
            end

            if((owner_valid || high_priority.acquire || low_priority.acquire) &&
               host.read && !host.busy)
                read_pending <= 1'b1;

            if(host.rdata_ready)
                read_pending <= 1'b0;

            if(owner_valid && !selected_acquire && !read_pending &&
               !host.busy && !host.rdata_ready)
                owner_valid <= 1'b0;
        end
    end

endmodule

module raizing_ss_response_mux #(
    parameter COUNT = 2
)(
    input [COUNT-1:0] ack,
    input [COUNT*64-1:0] data,
    output ack_out,
    output reg [63:0] data_out
);

    integer i;
    assign ack_out = |ack;

    always @* begin
        data_out = 64'd0;
        for(i = 0; i < COUNT; i = i + 1)
            data_out = data_out | (data[i*64 +: 64] & {64{ack[i]}});
    end

endmodule

module raizing_ss_register #(
    parameter WIDTH = 32,
    parameter SS_INDEX = 0
)(
    input clk,
    input reset,
    input [WIDTH-1:0] capture_data,
    output reg [WIDTH-1:0] restore_data,
    output reg restore_we,
    input [63:0] ss_data,
    input [7:0] ss_select,
    input ss_write,
    input ss_read,
    input ss_query,
    output reg [63:0] ss_data_out,
    output reg ss_ack
);

    localparam WIDTH_CODE = WIDTH <= 8 ? 0 : WIDTH <= 16 ? 1 :
                            WIDTH <= 32 ? 2 : 3;

    always @(posedge clk) begin
        ss_ack <= 1'b0;
        restore_we <= 1'b0;
        ss_data_out <= 64'd0;

        if(reset) begin
            restore_data <= {WIDTH{1'b0}};
        end else if(ss_select == SS_INDEX[7:0]) begin
            if(ss_query) begin
                ss_data_out <= {SS_INDEX[7:0], 22'd0, WIDTH_CODE[1:0], 32'd1};
                ss_ack <= 1'b1;
            end else if(ss_read) begin
                ss_data_out[WIDTH-1:0] <= capture_data;
                ss_ack <= 1'b1;
            end else if(ss_write) begin
                restore_data <= ss_data[WIDTH-1:0];
                restore_we <= 1'b1;
                ss_ack <= 1'b1;
            end
        end
    end

endmodule

module raizing_ss_wide_register #(
    parameter WIDTH = 128,
    parameter SS_INDEX = 0
)(
    input clk,
    input reset,
    input [WIDTH-1:0] capture_data,
    output reg [WIDTH-1:0] restore_data,
    output reg restore_we,
    input [63:0] ss_data,
    input [31:0] ss_addr,
    input [7:0] ss_select,
    input ss_write,
    input ss_read,
    input ss_query,
    output reg [63:0] ss_data_out,
    output reg ss_ack
);

    localparam WORD_COUNT = (WIDTH + 63) / 64;
    localparam INDEX_WIDTH = WORD_COUNT > 1 ? $clog2(WORD_COUNT) : 1;
    reg [WORD_COUNT*64-1:0] padded_restore;
    wire [WORD_COUNT*64-1:0] padded_capture =
        {{(WORD_COUNT*64-WIDTH){1'b0}}, capture_data};

    always @* restore_data = padded_restore[WIDTH-1:0];

    reg pending;
    reg request_query, request_read, request_valid;
    reg [INDEX_WIDTH-1:0] request_index;
    reg [63:0] request_data;

    // registers the request tuple that pending consumes next edge
    always @(posedge clk) begin
        request_query <= reset ? 1'b0 : ss_query;
        request_read <= reset ? 1'b0 : ss_read;
        request_valid <= !reset && ss_addr < WORD_COUNT;
        request_index <= reset ? {INDEX_WIDTH{1'b0}} : ss_addr[INDEX_WIDTH-1:0];
        request_data <= reset ? 64'd0 : ss_data;
    end

    always @(posedge clk) begin
        restore_we <= 1'b0;

        if(reset) begin
            ss_ack <= 1'b0;
            ss_data_out <= 64'd0;
            padded_restore <= {WORD_COUNT*64{1'b0}};
            pending <= 1'b0;
        end else if(ss_ack) begin
            if(!ss_read && !ss_write && !ss_query) begin
                ss_ack <= 1'b0;
                ss_data_out <= 64'd0;
            end
        end else if(pending) begin
            pending <= 1'b0;
            ss_ack <= 1'b1;
            ss_data_out <= 64'd0;
            if(request_query) begin
                ss_data_out <= {SS_INDEX[7:0], 22'd0, 2'd3, 32'(WORD_COUNT)};
            end else if(request_valid && request_read) begin
                ss_data_out <= padded_capture[request_index*64 +: 64];
            end else if(request_valid) begin
                padded_restore[request_index*64 +: 64] <= request_data;
                if(request_index == WORD_COUNT - 1)
                    restore_we <= 1'b1;
            end
        end else if(ss_select == SS_INDEX[7:0] && (ss_query || ss_read || ss_write)) begin
            pending <= 1'b1;
        end
    end

endmodule

module raizing_ss_ram_adapter #(
    parameter WIDTH = 16,
    parameter ADDR_WIDTH = 10,
    parameter SS_INDEX = 0
)(
    input clk,
    input reset,
    input [63:0] ss_data,
    input [31:0] ss_addr,
    input [7:0] ss_select,
    input ss_write,
    input ss_read,
    input ss_query,
    output reg [63:0] ss_data_out,
    output reg ss_ack,
    output reg ram_active,
    output reg [ADDR_WIDTH-1:0] ram_addr,
    output reg [WIDTH-1:0] ram_data,
    output reg ram_we,
    input [WIDTH-1:0] ram_q
);

    localparam WIDTH_CODE = WIDTH <= 8 ? 0 : WIDTH <= 16 ? 1 :
                            WIDTH <= 32 ? 2 : 3;
    localparam ST_IDLE = 2'd0;
    localparam ST_READ_WAIT = 2'd1;
    localparam ST_RESPOND = 2'd2;
    localparam ST_RELEASE = 2'd3;
    reg [1:0] state;
    reg op_read;

    always @(posedge clk) begin
        ss_ack <= 1'b0;
        ram_we <= 1'b0;

        if(reset) begin
            state <= ST_IDLE;
            ss_data_out <= 64'd0;
            ram_active <= 1'b0;
            ram_addr <= {ADDR_WIDTH{1'b0}};
            ram_data <= {WIDTH{1'b0}};
            op_read <= 1'b0;
        end else begin
            case(state)
                ST_IDLE: begin
                    ram_active <= 1'b0;
                    ss_data_out <= 64'd0;
                    if(ss_select == SS_INDEX[7:0] && ss_query) begin
                        ss_data_out <= {
                            SS_INDEX[7:0], 22'd0, WIDTH_CODE[1:0],
                            32'(1 << ADDR_WIDTH)
                        };
                        ss_ack <= 1'b1;
                        state <= ST_RELEASE;
                    end else if(ss_select == SS_INDEX[7:0] &&
                                (ss_read || ss_write)) begin
                        if(ss_addr < (1 << ADDR_WIDTH)) begin
                            ram_active <= 1'b1;
                            ram_addr <= ss_addr[ADDR_WIDTH-1:0];
                            ram_data <= ss_data[WIDTH-1:0];
                            op_read <= ss_read;
                            if(ss_write) begin
                                ram_we <= 1'b1;
                                state <= ST_RESPOND;
                            end else begin
                                state <= ST_READ_WAIT;
                            end
                        end else begin
                            ss_ack <= 1'b1;
                            state <= ST_RELEASE;
                        end
                    end
                end

                ST_READ_WAIT: begin
                    state <= ST_RESPOND;
                end

                ST_RESPOND: begin
                    if(op_read)
                        ss_data_out[WIDTH-1:0] <= ram_q;
                    ss_ack <= 1'b1;
                    state <= ST_RELEASE;
                end

                default: begin
                    ss_ack <= 1'b1;
                    if(!(ss_read || ss_write || ss_query)) begin
                        ss_ack <= 1'b0;
                        ram_active <= 1'b0;
                        state <= ST_IDLE;
                    end
                end
            endcase
        end
    end

endmodule

module raizing_ss_auto32 #(
    parameter SS_INDEX = 0,
    parameter DEVICE_COUNT = 1,
    parameter STATE_STRIDE = 64
)(
    input clk,
    input reset,
    input [63:0] ss_data,
    input [31:0] ss_addr,
    input [7:0] ss_select,
    input ss_write,
    input ss_read,
    input ss_query,
    output reg [63:0] ss_data_out,
    output reg ss_ack,
    output auto_ss_rd,
    output auto_ss_wr,
    output [31:0] auto_ss_data_in,
    output [7:0] auto_ss_device_idx,
    output [15:0] auto_ss_state_idx,
    input [31:0] auto_ss_data_out,
    input auto_ss_ack
);

    localparam WORD_COUNT = DEVICE_COUNT * STATE_STRIDE;
    wire selected = ss_select == SS_INDEX[7:0];
    wire valid_addr = ss_addr < WORD_COUNT;
    reg pending;
    reg request_write;
    reg [31:0] request_data;
    reg [7:0] request_device;
    reg [15:0] request_index;

    assign auto_ss_rd = pending && !request_write;
    assign auto_ss_wr = pending && request_write;
    assign auto_ss_data_in = request_data;
    assign auto_ss_device_idx = request_device;
    assign auto_ss_state_idx = request_index;

    always @(posedge clk) begin
        if(reset) begin
            ss_ack <= 1'b0;
            ss_data_out <= 64'd0;
            pending <= 1'b0;
            request_write <= 1'b0;
            request_data <= 32'd0;
            request_device <= 8'd0;
            request_index <= 16'd0;
        end else if(ss_ack) begin
            if(!ss_read && !ss_write && !ss_query) begin
                ss_ack <= 1'b0;
                ss_data_out <= 64'd0;
            end
        end else if(pending) begin
            pending <= 1'b0;
            ss_ack <= 1'b1;
            ss_data_out <= !request_write && auto_ss_ack ? {32'd0, auto_ss_data_out} : 64'd0;
        end else if(selected) begin
            if(ss_query) begin
                ss_data_out <= {
                    SS_INDEX[7:0], 22'd0, 2'd2, 32'(WORD_COUNT)
                };
                ss_ack <= 1'b1;
            end else if(ss_read || ss_write) begin
                if(valid_addr) begin
                    request_device <= ss_addr / STATE_STRIDE;
                    request_index <= ss_addr % STATE_STRIDE;
                    request_data <= ss_data[31:0];
                    request_write <= ss_write && !ss_read;
                    pending <= 1'b1;
                end else begin
                    ss_data_out <= 64'd0;
                    ss_ack <= 1'b1;
                end
            end
        end
    end

endmodule

// Save/load sequencer wrapper with user-pause holds.
module raizing_state(
    input clk, reset, save_request, load_request, user_pause,
    input cpu_quiesced, sound_held, sound_fault, video_quiesced, memory_quiesced,
    input cpu_save_ready, cpu_save_done, cpu_restore_done,
    input stream_busy, stream_valid, stream_fault, load_write,
    input mem_invalidate_done, restore_devices_ready, rebuild_done, frame_boundary,
    output cpu_hold, sound_hold, video_hold, ss_freeze,
    output rom_quiesce, cache_invalidate, audio_restore_commit, rebuild_request, ram_access_enable,
    output cpu_save_begin, cpu_save_resume, cpu_restore_begin, cpu_restore_window,
    output stream_save_start, stream_load_start, busy, load_rejected, completed, error
);
    wire cpu_hold_req, sound_hold_req;
    assign cpu_hold = cpu_hold_req || user_pause;
    assign sound_hold = sound_hold_req || user_pause;
    assign audio_restore_commit = cpu_restore_begin;
    raizing_ss_controller sequencing(
        .clk(clk),.reset(reset),.save_request(save_request),.load_request(load_request),
        .cpu_quiesced(cpu_quiesced),.sound_quiesced(sound_held),.sound_fault(sound_fault),.video_quiesced(video_quiesced),
        .memory_quiesced(memory_quiesced),.game_save_ready(cpu_save_ready),
        .game_save_done(cpu_save_done),.game_restore_done(cpu_restore_done),
        .stream_busy(stream_busy),.state_compatible(stream_valid),.stream_fault(stream_fault),
        .load_write(load_write),.invalidate_done(mem_invalidate_done),
        .restore_devices_ready(restore_devices_ready),.rebuild_done(rebuild_done),
        .frame_boundary(frame_boundary),.cpu_hold_req(cpu_hold_req),.sound_hold_req(sound_hold_req),
        .video_hold_req(video_hold),.cpu_ss_freeze(ss_freeze),.memory_quiesce(rom_quiesce),
        .memory_invalidate(cache_invalidate),.rebuild_request(rebuild_request),
        .ram_access_enable(ram_access_enable),.game_save_begin(cpu_save_begin),
        .game_save_resume(cpu_save_resume),.game_restore_begin(cpu_restore_begin),
        .restore_window(cpu_restore_window),.stream_save_start(stream_save_start),
        .stream_load_start(stream_load_start),.busy(busy),.load_rejected(load_rejected),
        .completed(completed),.error(error));
endmodule

// Save/load sequencer: drain, CPU save/restore handler, memory stream, rebuild, release on a frame boundary.
module raizing_ss_controller(
    input clk, reset, save_request, load_request,
    input cpu_quiesced, sound_quiesced, sound_fault, video_quiesced, memory_quiesced,
    input game_save_ready, game_save_done, game_restore_done,
    input stream_busy, state_compatible, stream_fault, load_write,
    input invalidate_done, restore_devices_ready, rebuild_done, frame_boundary,
    output cpu_hold_req, sound_hold_req, video_hold_req, cpu_ss_freeze,
    output memory_quiesce, memory_invalidate, rebuild_request, ram_access_enable,
    output game_save_begin, game_save_resume, game_restore_begin, restore_window,
    output stream_save_start, stream_load_start, busy,
    output reg load_rejected, completed, error
);
    typedef enum logic [4:0] {
        IDLE, DRAIN_CPU, DRAIN_VIDEO, SAVE_BEGIN, SAVE_HANDLER, MEMORY_DRAIN,
        SAVE_START, SAVE_ACCEPT, SAVE_STREAM, SAVE_RESUME, SAVE_EXIT,
        LOAD_START, LOAD_ACCEPT, LOAD_STREAM, INVALIDATE, RESTORE_BEGIN,
        RESTORE_HANDLER, EXIT_CPU, FINAL_DRAIN, REBUILD, RELEASE_FRAME, FAULT_HOLD
    } state_t;
    state_t state;
    reg loading, rejected, previous_save, previous_load, load_mutated;
    wire peripheral_idle = sound_quiesced && video_quiesced;
    assign busy = state != IDLE;
    assign cpu_hold_req = busy;
    assign sound_hold_req = busy;
    assign video_hold_req = busy && state != DRAIN_CPU && state != SAVE_BEGIN &&
        state != SAVE_HANDLER && state != REBUILD && state != RELEASE_FRAME;
    assign cpu_ss_freeze = busy && state != DRAIN_CPU;
    assign memory_quiesce = state==MEMORY_DRAIN || state==SAVE_START || state==SAVE_ACCEPT ||
        state==SAVE_STREAM || state==LOAD_START || state==LOAD_ACCEPT || state==LOAD_STREAM ||
        state==INVALIDATE || state==FINAL_DRAIN || state==FAULT_HOLD;
    // RAM access opens one edge after all quiesce acknowledgements are seen
    reg quiesce_seen;
    always @(posedge clk) quiesce_seen <= !reset && memory_quiesced && cpu_quiesced && peripheral_idle;
    assign ram_access_enable = memory_quiesce && quiesce_seen && state!=FAULT_HOLD;
    assign game_save_begin = state==SAVE_BEGIN;
    assign game_save_resume = state==SAVE_RESUME;
    assign game_restore_begin = state==RESTORE_BEGIN;
    assign stream_save_start = state==SAVE_START;
    assign stream_load_start = state==LOAD_START;
    assign memory_invalidate = state==INVALIDATE;
    assign rebuild_request = state==REBUILD || state==RELEASE_FRAME;
    assign restore_window = loading && !rejected &&
        (state==MEMORY_DRAIN || state==LOAD_START || state==LOAD_ACCEPT || state==LOAD_STREAM ||
         state==INVALIDATE || state==RESTORE_BEGIN || state==RESTORE_HANDLER);
    always @(posedge clk) begin
        load_rejected <= 0;
        completed <= 0;
        previous_save <= save_request;
        previous_load <= load_request;
        if(reset) begin
            state <= IDLE; loading <= 0; rejected <= 0; load_mutated <= 0; error <= 0;
            previous_save <= 0; previous_load <= 0;
        end else if(sound_fault && state!=IDLE && state!=FAULT_HOLD) begin
            error <= 1;
            load_rejected <= loading;
            if(state==DRAIN_CPU) begin
                completed <= 1;
                state <= IDLE;
            end else state <= FAULT_HOLD;
        end else case(state)
            IDLE: begin
                rejected <= 0;
                load_mutated <= 0;
                if(save_request && !previous_save) begin loading <= 0; error <= 0; state <= DRAIN_CPU; end
                else if(load_request && !previous_load) begin loading <= 1; error <= 0; state <= DRAIN_CPU; end
            end
            DRAIN_CPU: if(cpu_quiesced && sound_quiesced) state <= loading ? DRAIN_VIDEO : SAVE_BEGIN;
            DRAIN_VIDEO: if(cpu_quiesced && peripheral_idle) state <= MEMORY_DRAIN;
            SAVE_BEGIN: state <= SAVE_HANDLER;
            SAVE_HANDLER: if(game_save_ready && cpu_quiesced) state <= DRAIN_VIDEO;
            MEMORY_DRAIN: if(cpu_quiesced && peripheral_idle && memory_quiesced && !stream_busy)
                state <= loading ? LOAD_START : SAVE_START;
            SAVE_START: state <= SAVE_ACCEPT;
            SAVE_ACCEPT: if(stream_busy) state <= SAVE_STREAM;
            SAVE_STREAM: if(!stream_busy) begin error <= stream_fault; state <= SAVE_RESUME; end
            SAVE_RESUME: state <= SAVE_EXIT;
            SAVE_EXIT: if(game_save_done) state <= EXIT_CPU;
            LOAD_START: state <= LOAD_ACCEPT;
            LOAD_ACCEPT: begin
                if(load_write) load_mutated <= 1;
                if(stream_busy) state <= LOAD_STREAM;
            end
            LOAD_STREAM: begin
                if(load_write) load_mutated <= 1;
                if(!stream_busy) begin
                    if(state_compatible && !stream_fault) state <= INVALIDATE;
                    else begin
                        rejected <= 1; load_rejected <= 1; error <= stream_fault;
                        state <= (load_mutated || load_write) ? FAULT_HOLD : EXIT_CPU;
                    end
                end
            end
            INVALIDATE: if(invalidate_done) state <= RESTORE_BEGIN;
            RESTORE_BEGIN: state <= RESTORE_HANDLER;
            RESTORE_HANDLER: if(game_restore_done) state <= EXIT_CPU;
            EXIT_CPU: if(cpu_quiesced && peripheral_idle &&
                (!loading || rejected || restore_devices_ready)) state <= FINAL_DRAIN;
            FINAL_DRAIN: if(cpu_quiesced && peripheral_idle && memory_quiesced) state <= REBUILD;
            REBUILD: if(rebuild_done && !video_quiesced) state <= RELEASE_FRAME;
            RELEASE_FRAME: if(frame_boundary && rebuild_done && !video_quiesced) begin
                completed <= 1; state <= IDLE;
            end
            FAULT_HOLD: ;
            default: state <= IDLE;
        endcase
    end
endmodule

// State identity: format, ROM CRC/length and board words; compatible only when all match.
module raizing_ss_identity (
    input clk,reset,
    input raizing_board_pkg::board_e board,
    input [31:0] rom_crc,rom_length,
    input rom_valid,
    input [63:0] ss_data,
    input [31:0] ss_addr,
    input [7:0] ss_select,
    input ss_write,ss_read,ss_query,
    output [63:0] ss_data_out,
    output ss_ack,
    output compatible, legacy_slot
);
    // per-board format and board words
    wire [63:0] FORMAT=raizing_board_pkg::ss_format(board);
    wire [63:0] BOARD_WORD=raizing_board_pkg::ss_board(board);
    wire [191:0] captured={BOARD_WORD,rom_length,rom_crc,FORMAT};
    wire [191:0] restored;
    wire restored_we;
    reg complete;
    raizing_ss_wide_register #(.WIDTH(192),.SS_INDEX(0)) provider (
        .clk(clk),.reset(reset),.capture_data(captured),.restore_data(restored),.restore_we(restored_we),
        .ss_data(ss_data),.ss_addr(ss_addr),.ss_select(ss_select),.ss_write(ss_write),
        .ss_read(ss_read),.ss_query(ss_query),.ss_data_out(ss_data_out),.ss_ack(ss_ack)
    );
    always @(posedge clk) begin
        if(reset || (ss_select==0 && ss_write && ss_addr==0)) complete<=0;
        else if(restored_we) complete<=1;
    end
    // only this core's format is accepted
    assign legacy_slot=1'b0;
    assign compatible=rom_valid && complete && restored[191:64]==captured[191:64] &&
        restored[63:0]==FORMAT;
endmodule


`timescale 1ns/1ps
// Save-state memory stream: chunk descriptors and data in DDR; a load checks each descriptor before writing RAM.
module raizing_ss_memory_stream #(
    parameter CHUNK_COUNT=46
) (
    input clk,reset,transport_reset,
    raizing_ddr_if ddr,
    output reg device_write,
    output reg [63:0] device_write_data,
    input device_ack,
    output reg device_read,
    input [63:0] device_read_data,
    input [31:0] start_addr,slot_length,
    input load_start,save_start,load_compatible,
    output reg query,
    output reg [31:0] chunk_addr,
    output reg [7:0] chunk_select,
    output busy,
    output reg load_valid,fault,
    output reg preflight_start,
    output reg [31:0] ssp_offset,wram_offset,wram_words,
    input preflight_done,preflight_ok,context_admitted,legacy_slot,
    input preflight_read,
    input [31:0] preflight_addr,
    output preflight_idle,preflight_rd_done,
    output [63:0] preflight_data
);
    typedef enum logic [5:0] {
        IDLE,SCAN_START,SCAN_WAIT,SCAN_NEXT,GAP,
        HEADER_READ,HEADER_WAIT,HEADER_INVALIDATE,HEADER_INVALIDATE_WAIT,
        SAVE_PICK,SAVE_DESC,SAVE_DESC_WAIT,SAVE_READ,SAVE_READ_WAIT,
        SAVE_DATA,SAVE_DATA_WAIT,SAVE_ADVANCE,SAVE_END,SAVE_END_WAIT,
        SAVE_COMMIT,SAVE_COMMIT_WAIT,
        LOAD_DESC,LOAD_DESC_WAIT,LOAD_DESC_CHECK,LOAD_DATA,LOAD_DATA_WAIT,
        LOAD_WRITE,LOAD_WRITE_WAIT,LOAD_ADVANCE,LOAD_METADATA,
        PREFLIGHT, FINISH,FAILED
    } state_t;
    state_t state,next_after_gap;
    reg [CHUNK_COUNT-1:0] present,seen;
    (* ramstyle = "M10K, no_rw_check" *) reg [31:0] counts[0:CHUNK_COUNT-1];
    reg [31:0] count0_q, count1_q;   // chunks 0 and 1 for the fixed count checks
    reg [7:0] scan_index,item_index,last_index;
    // scanned chunk counts, written one edge after the acknowledge
    reg counts_we;
    reg [7:0] counts_index;
    reg [31:0] counts_data;
    always @(posedge clk) begin
        counts_we<=state==SCAN_WAIT && device_ack && !reset &&
            device_read_data[31:0]!=0 && device_read_data[31:0]<=(32'h400000>>3);
        counts_index<=scan_index;
        counts_data<=device_read_data[31:0];
        if(counts_we) counts[counts_index]<=counts_data;
        if(counts_we && counts_index==0) count0_q<=counts_data;
        if(counts_we && counts_index==1) count1_q<=counts_data;
    end
    reg [31:0] base,limit,cursor,end_addr,remaining;
    reg [63:0] header,buffer;
    reg loading,applying,have_previous,metadata_ok;
    wire [31:0] slot_cpu_count = legacy_slot ? 32'd1 : 32'd10;
    reg [8:0] timeout_count;
    reg [3:0] validation_delay;
    reg word_request,word_writing;
    reg [31:0] word_address;
    reg [63:0] word_data;
    reg [7:0] word_mask;
    wire word_idle,word_done;
    wire [63:0] word_result;
    wire word_terminal,word_descriptor;
    wire [31:0] descriptor_count={12'd0,word_result[19:0]};
    reg [31:0] descriptor_space,descriptor_payload;
    assign busy=state!=IDLE;
    assign preflight_idle=state==PREFLIGHT && word_idle;
    assign preflight_rd_done=state==PREFLIGHT && word_done;
    assign preflight_data=word_result;
    raizing_ddr_word transport(
        .clk(clk),.reset(transport_reset),.abort(reset),
        .request(state==PREFLIGHT ? preflight_read : word_request),
        .writing(state!=PREFLIGHT && word_writing),
        .address(state==PREFLIGHT ? preflight_addr : word_address),.data(word_data),.mask(word_mask),
        .idle(word_idle),.done(word_done),.result(word_result),
        .result_terminal(word_terminal),.result_descriptor(word_descriptor),.ddr(ddr)
    );

    // table entries for the loaded descriptor, checked one edge later
    reg desc_cpu;
    reg [31:0] desc_cpu_count;
    // registered count read, addressed one edge ahead of SAVE_PICK and LOAD_DESC_CHECK
    localparam integer COUNT_AW = $clog2(CHUNK_COUNT);
    wire [7:0] count_index = state==SAVE_ADVANCE ? item_index+8'd1 :
                             state==LOAD_DESC_WAIT ? word_result[63:56] : item_index;
    reg [31:0] count_q;
    always @(posedge clk) count_q <= counts[count_index[COUNT_AW-1:0]];
    wire [31:0] desc_count = desc_cpu ? desc_cpu_count : count_q;
    reg desc_present,desc_seen;
    always @(posedge clk) begin
        word_request<=0;preflight_start<=0;
        if(counts_we) present[counts_index]<=1;
        if(reset) begin
            state<=IDLE;next_after_gap<=IDLE;present<=0;seen<=0;
            scan_index<=0;item_index<=0;last_index<=0;chunk_select<=0;chunk_addr<=0;
            ssp_offset<=0;wram_offset<=0;wram_words<=0;
            descriptor_space<=0;descriptor_payload<=0;
            base<=0;limit<=0;cursor<=0;end_addr<=0;remaining<=0;header<=0;buffer<=0;
            loading<=0;applying<=0;have_previous<=0;metadata_ok<=0;validation_delay<=0;
            timeout_count<=0;device_write<=0;device_read<=0;query<=0;device_write_data<=0;
            load_valid<=0;fault<=0;word_request<=0;word_writing<=0;
            word_address<=0;word_data<=0;word_mask<=8'hff;
        end else case(state)
            IDLE: if(load_start || save_start) begin
                base<=start_addr;limit<=start_addr+slot_length;
                cursor<=start_addr+8;loading<=load_start;applying<=0;
                load_valid<=0;fault<=0;present<=0;seen<=0;scan_index<=0;
                metadata_ok<=0;have_previous<=0;ssp_offset<=0;wram_offset<=0;wram_words<=0;
                if(start_addr[2:0]!=0 || slot_length[2:0]!=0 || slot_length<64 ||
                   start_addr+slot_length<start_addr) state<=FAILED;
                else state<=SCAN_START;
            end
            SCAN_START: begin
                chunk_select<=scan_index;chunk_addr<=0;query<=1;timeout_count<=0;
                state<=SCAN_WAIT;
            end
            SCAN_WAIT: begin
                if(device_ack) begin
                    query<=0;
                    if(device_read_data[31:0]==0 || device_read_data[31:0]>(32'h400000>>3))
                        state<=FAILED;
                    else begin
                        next_after_gap<=SCAN_NEXT;state<=GAP;
                    end
                end else if(timeout_count==31) begin
                    query<=0;next_after_gap<=SCAN_NEXT;state<=GAP;
                end else timeout_count<=timeout_count+9'd1;
            end
            SCAN_NEXT: begin
                if(scan_index==CHUNK_COUNT-1) begin
                    if(!present[0] || count0_q!=3) state<=FAILED;
                    else state<=HEADER_READ;
                end else begin scan_index<=scan_index+8'd1;state<=SCAN_START;end
            end
            GAP: if(!device_ack) state<=next_after_gap;
            HEADER_READ: if(word_idle) begin
                word_request<=1;word_writing<=0;word_address<=base;word_mask<=8'hff;
                state<=HEADER_WAIT;
            end
            HEADER_WAIT: if(word_done) begin
                header<=word_result;
                if(loading) begin
                    if(word_result[63:62]!=0 || word_result[32] ||
                       {word_result[61:32],2'b00}<8 ||
                       {word_result[61:32],2'b00}>limit-base-8) state<=FAILED;
                    else begin
                        end_addr<=base+8+{word_result[61:32],2'b00};state<=LOAD_DESC;
                    end
                end else begin item_index<=0;state<=HEADER_INVALIDATE;end
            end
            HEADER_INVALIDATE: if(word_idle) begin
                word_request<=1;word_writing<=1;word_address<=base;
                word_data<={32'd0,header[31:0]};word_mask<=8'hff;state<=HEADER_INVALIDATE_WAIT;
            end
            HEADER_INVALIDATE_WAIT: if(word_done) state<=SAVE_PICK;
            SAVE_PICK: begin
                if(present[item_index]) begin
                    chunk_select<=item_index;chunk_addr<=0;remaining<=count_q;state<=SAVE_DESC;
                end else state<=SAVE_ADVANCE;
            end
            SAVE_DESC: if(word_idle) begin
                if(cursor>limit-16) state<=FAILED;
                else begin
                    word_request<=1;word_writing<=1;word_address<=cursor;
                    word_data<={item_index,22'd0,2'd3,remaining};word_mask<=8'hff;state<=SAVE_DESC_WAIT;
                end
            end
            SAVE_DESC_WAIT: if(word_done) begin cursor<=cursor+8;state<=SAVE_READ;end
            SAVE_READ: begin device_read<=1;timeout_count<=0;state<=SAVE_READ_WAIT;end
            SAVE_READ_WAIT: begin
                if(device_ack) begin
                    device_read<=0;buffer<=device_read_data;next_after_gap<=SAVE_DATA;state<=GAP;
                end else if(&timeout_count) state<=FAILED;
                else timeout_count<=timeout_count+9'd1;
            end
            SAVE_DATA: if(word_idle) begin
                if(cursor>limit-16) state<=FAILED;
                else begin
                    word_request<=1;word_writing<=1;word_address<=cursor;
                    word_data<=buffer;word_mask<=8'hff;state<=SAVE_DATA_WAIT;
                end
            end
            SAVE_DATA_WAIT: if(word_done) begin
                cursor<=cursor+8;
                if(remaining==1) state<=SAVE_ADVANCE;
                else begin remaining<=remaining-1;chunk_addr<=chunk_addr+1;state<=SAVE_READ;end
            end
            SAVE_ADVANCE: begin
                if(item_index==CHUNK_COUNT-1) state<=SAVE_END;
                else begin item_index<=item_index+8'd1;state<=SAVE_PICK;end
            end
            SAVE_END: if(word_idle) begin
                if(cursor>limit-8) state<=FAILED;
                else begin
                    word_request<=1;word_writing<=1;word_address<=cursor;
                    word_data<=64'hffffffffffffffff;word_mask<=8'hff;state<=SAVE_END_WAIT;
                end
            end
            SAVE_END_WAIT: if(word_done) begin cursor<=cursor+8;state<=SAVE_COMMIT;end
            SAVE_COMMIT: if(word_idle) begin
                word_request<=1;word_writing<=1;word_address<=base;
                word_data<={2'b00,30'((cursor-base-8)>>2),32'(header[31:0]+32'd1)};
                word_mask<=8'hff;state<=SAVE_COMMIT_WAIT;
            end
            SAVE_COMMIT_WAIT: if(word_done) state<=FINISH;
            LOAD_DESC: if(word_idle) begin
                if(cursor>end_addr-8) state<=FAILED;
                else begin
                    descriptor_space<=(end_addr-cursor-16)>>3;
                    descriptor_payload<=cursor+8;
                    word_request<=1;word_writing<=0;word_address<=cursor;state<=LOAD_DESC_WAIT;
                end
            end
            // descriptor word checked next edge against the registered table entries
            LOAD_DESC_WAIT: if(word_done) begin
                desc_cpu<=word_result[63:56]==1;desc_cpu_count<=slot_cpu_count;
                desc_present<=present[word_result[63:56]];
                desc_seen<=seen[word_result[63:56]];
                state<=LOAD_DESC_CHECK;
            end
            LOAD_DESC_CHECK: begin
                cursor<=descriptor_payload;
                if(word_terminal) begin
                    if(seen!=present || !metadata_ok || descriptor_payload!=end_addr) state<=FAILED;
                    else if(applying) begin load_valid<=1;state<=FINISH;end
                    else begin
                        if(!seen[1] || count1_q!=10 || !seen[2] || wram_words!=32768)
                            state<=FAILED;
                        else begin preflight_start<=1;state<=PREFLIGHT;end
                    end
                end else if(word_result[63:56]>=CHUNK_COUNT || !word_descriptor) state<=FAILED;
                else if(!desc_present || desc_seen ||
                        cursor>end_addr-16 ||
                        (have_previous && word_result[63:56]<=last_index) ||
                        (!have_previous && word_result[63:56]!=0) ||
                        desc_count!=descriptor_count ||
                        descriptor_count>descriptor_space) state<=FAILED;
                else begin
                    seen[word_result[63:56]]<=1;last_index<=word_result[63:56];have_previous<=1;
                    item_index<=word_result[63:56];chunk_select<=word_result[63:56];chunk_addr<=0;
                    remaining<=descriptor_count;
                    if((!applying && word_result[63:56]!=0) || word_result[63:56]==1) begin
                        if(word_result[63:56]==1) ssp_offset<=descriptor_payload;
                        if(word_result[63:56]==2) begin
                            wram_offset<=descriptor_payload;wram_words<=descriptor_count;
                        end
                        cursor<=descriptor_payload+(descriptor_count<<3);state<=LOAD_DESC;
                    end else state<=LOAD_DATA;
                end
            end
            LOAD_DATA: if(word_idle) begin
                word_request<=1;word_writing<=0;word_address<=cursor;state<=LOAD_DATA_WAIT;
            end
            LOAD_DATA_WAIT: if(word_done) begin
                buffer<=word_result;cursor<=cursor+8;state<=LOAD_WRITE;
            end
            LOAD_WRITE: begin
                device_write_data<=buffer;device_write<=1;timeout_count<=0;state<=LOAD_WRITE_WAIT;
            end
            LOAD_WRITE_WAIT: begin
                if(device_ack) begin device_write<=0;next_after_gap<=LOAD_ADVANCE;state<=GAP;end
                else if(&timeout_count) state<=FAILED;
                else timeout_count<=timeout_count+9'd1;
            end
            LOAD_ADVANCE: begin
                if(remaining==1) begin
                    if(item_index==0) begin validation_delay<=0;state<=LOAD_METADATA;end
                    else state<=LOAD_DESC;
                end else begin remaining<=remaining-1;chunk_addr<=chunk_addr+1;state<=LOAD_DATA;end
            end
            LOAD_METADATA: begin
                if(validation_delay==7) begin
                    if(load_compatible) begin metadata_ok<=1;state<=LOAD_DESC;end
                    else state<=FAILED;
                end else validation_delay<=validation_delay+4'd1;
            end
            PREFLIGHT: if(preflight_done) begin
                if(preflight_ok && context_admitted) begin
                    applying<=1;cursor<=base+8;seen<=0;have_previous<=0;state<=LOAD_DESC;
                end else state<=FAILED;
            end
            FAILED: begin
                fault<=1;load_valid<=0;device_write<=0;device_read<=0;query<=0;state<=FINISH;
            end
            FINISH: begin device_write<=0;device_read<=0;query<=0;state<=IDLE;end
            default: state<=FAILED;
        endcase
    end
`ifdef SIMULATION
    // reference copy of the count table; every registered read must match it
    reg [31:0] counts_ref[0:CHUNK_COUNT-1];
    always @(posedge clk) begin
        if(counts_we) counts_ref[counts_index]<=counts_data;
        if(!reset) begin
            if(state==SCAN_NEXT && scan_index==CHUNK_COUNT-1 && present[0] && count0_q!==counts_ref[0])
                $fatal(1,"COUNT_RAM_MISMATCH chunk 0");
            if(state==SAVE_PICK && present[item_index] && count_q!==counts_ref[item_index])
                $fatal(1,"COUNT_RAM_MISMATCH save chunk %0d",item_index);
            if(state==LOAD_DESC_CHECK && !word_terminal && word_result[63:56]<CHUNK_COUNT &&
               desc_count!==(word_result[63:56]==1 ? desc_cpu_count : counts_ref[word_result[63:56]]))
                $fatal(1,"COUNT_RAM_MISMATCH load chunk %0d",word_result[63:56]);
            if(state==LOAD_DESC_CHECK && word_terminal && seen[1] && count1_q!==counts_ref[1])
                $fatal(1,"COUNT_RAM_MISMATCH chunk 1");
        end
    end
`endif
endmodule

module raizing_save_state_data #(
    parameter CHUNK_COUNT=46,
    parameter [31:0] DDR_BASE=32'h3e000000,SLOT_SIZE=32'h00400000
) (
    input clk,reset,transport_reset,
    raizing_ddr_if ddr,
    input save_start,load_start,load_compatible,legacy_slot,
    input [1:0] slot,
    output busy,load_valid,fault,
    raizing_ssbus_if.stream ssbus,
    output rzctx_slot_pkg::request_t ctx_request,
    input rzctx_slot_pkg::response_t ctx_response
);
    logic save_transaction;
    wire use_legacy = legacy_slot && !save_transaction;
    wire pre_start, pre_idle, pre_rd_done;
    wire [31:0] ssp_offset,wram_offset,wram_words;
    wire [63:0] pre_data,packed_data;
    wire packed_ack;
    wire old_read,old_done,old_ok,old_cmd,old_ctx;
    wire new_read,new_done,new_ok,new_cmd,new_ctx,new_we;
    wire [31:0] old_addr,new_addr;
    wire [2:0] old_op,new_op;
    wire [5:0] old_idx,new_idx;
    wire [15:0] old_data,new_data;
    always_ff @(posedge clk) begin
        if (reset) save_transaction <= 1'b0;
        else if (!busy && (save_start || load_start)) save_transaction <= save_start && !load_start;
    end
    assign ctx_request = use_legacy ?
        {old_cmd,old_op,old_ctx,1'b1,old_idx,old_data} :
        {new_cmd,new_op,new_ctx,new_we,new_idx,new_data};

    raizing_ss_memory_stream #(.CHUNK_COUNT(CHUNK_COUNT)) stream(
        .clk(clk),.reset(reset),.transport_reset(transport_reset),.ddr(ddr),
        .device_write(ssbus.write),.device_write_data(ssbus.data),.device_ack(ssbus.ack || packed_ack),
        .device_read(ssbus.read),.device_read_data(packed_ack ? packed_data : ssbus.data_out),
        .start_addr(DDR_BASE+({30'd0,slot}*SLOT_SIZE)),.slot_length(SLOT_SIZE),
        .load_start(load_start),.save_start(save_start),.load_compatible(load_compatible),
        .query(ssbus.query),.chunk_addr(ssbus.addr),.chunk_select(ssbus.select),
        .busy(busy),.load_valid(load_valid),.fault(fault),.legacy_slot(legacy_slot),
        .preflight_start(pre_start),.ssp_offset(ssp_offset),.wram_offset(wram_offset),.wram_words(wram_words),
        .preflight_done(use_legacy ? old_done : new_done),.preflight_ok(use_legacy ? old_ok : new_ok),
        .context_admitted(ctx_response.admitted),.preflight_read(use_legacy ? old_read : new_read),
        .preflight_addr(use_legacy ? old_addr : new_addr),.preflight_idle(pre_idle),
        .preflight_rd_done(pre_rd_done),.preflight_data(pre_data));
    rzctx_packed_chunk packed_cpu(
        .clk(clk),.reset(reset),.select(ssbus.select==8'd1),.query(ssbus.query),.read_item(ssbus.read),
        .item(ssbus.addr),.captured(ctx_response.captured),.ack(packed_ack),.item_data(packed_data),
        .load_start(pre_start && !use_legacy),.load_offset(ssp_offset),.load_done(new_done),.load_ok(new_ok),
        .rd_req(new_read),.rd_addr(new_addr),.rd_idle(pre_idle),.rd_done(pre_rd_done),.rd_data(pre_data),
        .cmd_valid(new_cmd),.cmd_op(new_op),.rsp_valid(ctx_response.rsp_valid),.rsp_ok(ctx_response.rsp_ok),
        .admitted(ctx_response.admitted),.ctx_req(new_ctx),.ctx_we(new_we),.ctx_idx(new_idx),.ctx_wdata(new_data),
        .ctx_ack(ctx_response.ctx_ack),.ctx_nak(ctx_response.ctx_nak),.ctx_rdata(ctx_response.ctx_data));
    rzctx_legacy_preflight old_cpu(
        .clk(clk),.reset(reset),.start(pre_start && use_legacy),.ssp_offset(ssp_offset),
        .wram_offset(wram_offset),.wram_words(wram_words),.busy(),.done(old_done),.ok(old_ok),
        .code(),.rd_req(old_read),.rd_addr(old_addr),.rd_idle(pre_idle),.rd_done(pre_rd_done),.rd_data(pre_data),
        .cmd_valid(old_cmd),.cmd_op(old_op),.rsp_valid(ctx_response.rsp_valid),.rsp_ok(ctx_response.rsp_ok),
        .rsp_code(ctx_response.rsp_code),.ctx_req(old_ctx),.ctx_idx(old_idx),.ctx_data(old_data),
        .ctx_ack(ctx_response.ctx_ack),.ctx_nak(ctx_response.ctx_nak),.admitted(ctx_response.admitted));
endmodule

// DDR word transport: one read or masked write per request; abort discards the pending result.
module raizing_ddr_word (
    input clk,reset,abort,request,writing,
    input [31:0] address,
    input [63:0] data,
    input [7:0] mask,
    output idle,
    output reg done,
    output reg [63:0] result,
    output reg result_terminal, result_descriptor,
    raizing_ddr_if ddr
);
    reg active,accepted,is_write,discard;
    assign idle=!active && !abort;
    always @(posedge clk) begin
        done<=0;
        if(reset) begin
            active<=0;accepted<=0;is_write<=0;discard<=0;result<=0;
            result_terminal<=0;result_descriptor<=0;
            ddr.acquire<=0;ddr.read<=0;ddr.write<=0;
            ddr.addr<=0;ddr.wdata<=0;ddr.byteenable<=8'hff;ddr.burstcnt<=1;
        end else begin
            if(abort && active) discard<=1;
            if(!active && request && !abort) begin
                active<=1;accepted<=0;is_write<=writing;discard<=0;
                ddr.acquire<=1;ddr.read<=!writing;ddr.write<=writing;
                ddr.addr<=address;ddr.wdata<=data;ddr.byteenable<=mask;
            end
            if(active && !accepted && !ddr.busy) begin
                accepted<=1;ddr.read<=0;ddr.write<=0;
                if(is_write) begin
                    active<=0;ddr.acquire<=0;done<=!discard && !abort;
                end
            end
            if(active && !is_write && (accepted || !ddr.busy) && ddr.rdata_ready) begin
                result<=ddr.rdata;active<=0;ddr.acquire<=0;done<=!discard && !abort;
                result_terminal<=&ddr.rdata;
                result_descriptor<=ddr.rdata[55:32]==24'd3 && ddr.rdata[31:20]==0;
            end
        end
    end
endmodule

// Holds save/load requests during a Bakraid EEPROM copy (nv_block); releases them when it ends.
module raizing_state_admit (
    input clk, reset,
    input save_request, load_request,   // save-state UI pulses
    input nv_block,                     // EEPROM copy owns the CPU
    output state_save, state_load,      // to the state controller
    output nv_state_pending             // to the EEPROM owner: delays its next copy
);
    reg save_held = 0, load_held = 0;
    assign state_save = (save_request || save_held) && !nv_block;
    assign state_load = (load_request || load_held) && !nv_block;
    assign nv_state_pending = save_request || load_request || save_held || load_held;
    always @(posedge clk)
        if(reset) begin save_held <= 0; load_held <= 0; end
        else begin
            save_held <= (save_request || save_held) && nv_block;
            load_held <= (load_request || load_held) && nv_block;
        end
endmodule

module raizing_ss_ui #(
    parameter INFO_TIMEOUT_BITS = 24
)(
    input clk,
    input reset,
    input [10:0] ps2_key,
    input allow_ss,
    input busy,
    input load_rejected,
    input joy_ss,
    input joy_right,
    input joy_left,
    input joy_down,
    input joy_up,
    input [1:0] status_slot,
    input autoinc_slot,
    input [1:0] osd_save_load,
    output reg save_request,
    output reg load_request,
    output reg info_request,
    output reg [7:0] info_index,
    output reg status_update,
    output reg [1:0] selected_slot,
    output reg [1:0] request_slot
);

    localparam [7:0] INFO_INCOMPATIBLE = 8'd14;

    reg [10:0] ps2_key_d;
    reg alt_pressed;
    reg joy_ss_d;
    reg joy_right_d;
    reg joy_left_d;
    reg joy_down_d;
    reg joy_up_d;
    reg [1:0] osd_save_load_d;
    reg [1:0] status_slot_d;
    reg [3:0] slot_key_held;

    wire key_event = ps2_key[10] != ps2_key_d[10];
    wire key_pressed = ps2_key[9];
    wire [1:0] next_slot_right = selected_slot + 2'd1;
    wire [1:0] next_slot_left = selected_slot - 2'd1;

    function automatic is_slot_key(input [7:0] code);
        begin
            is_slot_key = code == 8'h05 || code == 8'h06 ||
                          code == 8'h04 || code == 8'h0c;
        end
    endfunction

    function automatic [1:0] key_slot(input [7:0] code);
        begin
            case(code)
                8'h06: key_slot = 2'd1;
                8'h04: key_slot = 2'd2;
                8'h0c: key_slot = 2'd3;
                default: key_slot = 2'd0;
            endcase
        end
    endfunction

    wire [1:0] event_slot = key_slot(ps2_key[7:0]);

    always @(posedge clk) begin
        save_request <= 1'b0;
        load_request <= 1'b0;
        info_request <= 1'b0;
        status_update <= 1'b0;

        if(reset) begin
            ps2_key_d <= 11'd0;
            alt_pressed <= 1'b0;
            joy_ss_d <= 1'b0;
            joy_right_d <= 1'b0;
            joy_left_d <= 1'b0;
            joy_down_d <= 1'b0;
            joy_up_d <= 1'b0;
            osd_save_load_d <= 2'd0;
            status_slot_d <= 2'd0;
            slot_key_held <= 4'd0;
            selected_slot <= 2'd0;
            request_slot <= 2'd0;
            info_index <= 8'd0;
        end else begin
            ps2_key_d <= ps2_key;
            joy_ss_d <= joy_ss;
            joy_right_d <= joy_right;
            joy_left_d <= joy_left;
            joy_down_d <= joy_down;
            joy_up_d <= joy_up;
            osd_save_load_d <= osd_save_load;
            status_slot_d <= status_slot;

            if(status_slot != status_slot_d)
                selected_slot <= status_slot;

            if(key_event && ps2_key[7:0] == 8'h11)
                alt_pressed <= key_pressed;
            // slot key make/break tracked even while state requests are blocked
            if(key_event && is_slot_key(ps2_key[7:0]))
                slot_key_held[event_slot] <= key_pressed;

            if(allow_ss && !busy && key_event && key_pressed &&
               is_slot_key(ps2_key[7:0]) &&
               !slot_key_held[event_slot]) begin
                request_slot <= key_slot(ps2_key[7:0]);
                selected_slot <= key_slot(ps2_key[7:0]);
                status_update <= 1'b1;
                info_request <= 1'b1;
                info_index <= 8'd6 + {key_slot(ps2_key[7:0]),
                                      !alt_pressed};
                if(alt_pressed) begin
                    save_request <= 1'b1;
                    if(autoinc_slot)
                        selected_slot <= key_slot(ps2_key[7:0]) + 1'b1;
                end else begin
                    load_request <= 1'b1;
                end
            end else if(allow_ss && !busy &&
                        osd_save_load[0] && !osd_save_load_d[0]) begin
                request_slot <= selected_slot;
                save_request <= 1'b1;
                info_request <= 1'b1;
                info_index <= 8'd6 + {selected_slot, 1'b0};
                if(autoinc_slot) begin
                    selected_slot <= selected_slot + 1'b1;
                    status_update <= 1'b1;
                end
            end else if(allow_ss && !busy &&
                        osd_save_load[1] && !osd_save_load_d[1]) begin
                request_slot <= selected_slot;
                load_request <= 1'b1;
                info_request <= 1'b1;
                info_index <= 8'd6 + {selected_slot, 1'b1};
            end else if(joy_ss && !joy_right_d && joy_right) begin
                selected_slot <= next_slot_right;
                status_update <= 1'b1;
                info_request <= 1'b1;
                info_index <= 8'd2 + {6'd0,next_slot_right};
            end else if(joy_ss && !joy_left_d && joy_left) begin
                selected_slot <= next_slot_left;
                status_update <= 1'b1;
                info_request <= 1'b1;
                info_index <= 8'd2 + {6'd0,next_slot_left};
            end else if(allow_ss && !busy && joy_ss &&
                        !joy_down_d && joy_down) begin
                request_slot <= selected_slot;
                save_request <= 1'b1;
                info_request <= 1'b1;
                info_index <= 8'd6 + {selected_slot, 1'b0};
                if(autoinc_slot) begin
                    selected_slot <= selected_slot + 1'b1;
                    status_update <= 1'b1;
                end
            end else if(allow_ss && !busy && joy_ss &&
                        !joy_up_d && joy_up) begin
                request_slot <= selected_slot;
                load_request <= 1'b1;
                info_request <= 1'b1;
                info_index <= 8'd6 + {selected_slot, 1'b1};
            end

            if(load_rejected) begin
                info_request <= 1'b1;
                info_index <= INFO_INCOMPATIBLE;
            end
        end
    end

endmodule
