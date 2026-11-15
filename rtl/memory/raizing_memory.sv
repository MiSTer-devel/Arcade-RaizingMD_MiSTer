// SPDX-License-Identifier: GPL-3.0-or-later
// ROM staging and validation, SDRAM ROM caches and the IKA controller wrapper.

// Board descriptor download (index 1, bytes 52 5A <version> <board>); active_board latches when the ROM download starts.
module raizing_board_select #(
    parameter logic [7:0] VERSION = 8'h01,
    // Board IDs this image contains (raizing_board_pkg::board_bit); others are rejected.
    parameter logic [7:0] SUPPORTED = raizing_board_pkg::RUNTIME_BOARDS
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        ioctl_download,
    input  logic        ioctl_wr,
    input  logic [15:0] ioctl_index,
    input  logic [7:0]  ioctl_dout,
    input  logic        rom_download,       // index-0 ROM download level
    output raizing_board_pkg::board_e board,
    output logic        board_ok,
    output logic        descriptor_error,
    output raizing_board_pkg::board_e active_board,
    output logic        active_ok
);
    logic        active_q;                  // descriptor download in progress
    logic [2:0]  count_q;                   // bytes received, saturating at 5
    logic [31:0] bytes_q;                   // first four bytes, byte 0 in [31:24]
    wire descriptor = ioctl_download && ioctl_index == 16'd1;
    wire start = descriptor && !active_q;
    wire finish = active_q && !descriptor;
    wire [2:0] id = bytes_q[2:0];
    wire well_formed = count_q == 3'd4 && bytes_q[31:16] == 16'h525A && bytes_q[15:8] == VERSION &&
                       bytes_q[7:3] == 5'd0;
    wire accept = well_formed && SUPPORTED[id];

    always_ff @(posedge clk) begin
        if (reset) active_q <= 1'b0;
        else active_q <= descriptor;
    end

    always_ff @(posedge clk) begin
        if (reset || start) begin
            count_q <= 3'd0;
            bytes_q <= 32'd0;
        end else if (descriptor && ioctl_wr) begin
            if (count_q != 3'd5) count_q <= count_q + 3'd1;
            if (count_q < 3'd4) bytes_q <= {bytes_q[23:0], ioctl_dout};
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            board <= raizing_board_pkg::RZB_NONE;
            board_ok <= 1'b0;
            descriptor_error <= 1'b0;
        end else if (start) begin
            board_ok <= 1'b0;
        end else if (finish) begin
            board <= accept ? raizing_board_pkg::board_e'(id) : raizing_board_pkg::RZB_NONE;
            board_ok <= accept;
            descriptor_error <= !accept;
        end
    end

    // game profile: cleared by a descriptor, set when the ROM download starts
    always_ff @(posedge clk) begin
        if (reset || descriptor) active_board <= raizing_board_pkg::RZB_NONE;
        else if (rom_download) active_board <= board_ok ? board : raizing_board_pkg::RZB_NONE;
    end
    assign active_ok = board_ok && active_board == board;
endmodule


// ROM source: direct HPS byte stream, or a DDR-staged image (start address = length) replayed as bytes.
module raizing_rom_source #(
    parameter [26:0] MAX_ROM_BYTES=27'h1e20000,
    parameter [31:0] DDR_BASE=32'h30000000,
    parameter integer TIMEOUT_CYCLES=81000000
) (
    input clk,reset,
    // Expected staged length for the selected board; 0 rejects every image.
    input [26:0] rom_bytes,
    input host_download,host_write,
    input [26:0] host_address,
    input [7:0] host_data,
    // descriptor download started: aborts a replay in progress with error
    input abort,
    output host_wait,busy,
    output reg error,
    output stream_download,stream_write,
    output [26:0] stream_address,
    output [7:0] stream_data,
    input stream_wait,
    raizing_ddr_if ddr
);
    localparam [3:0] IDLE=0,DIRECT=1,STAGED=2,START=3,ISSUE=4,
                     WAIT_WORD=5,OUTPUT_BYTES=6,FINISH=7,DRAIN=8;
    localparam integer TIMER_W=$clog2(TIMEOUT_CYCLES+1);
    reg [3:0] phase;
    reg previous;
    reg [26:0] declared_length,offset;
    reg [63:0] buffer;
    reg [TIMER_W-1:0] timer;
    reg word_request;
    wire word_idle,word_done;
    wire [63:0] word_result;
    wire starting=host_download && !previous;
    wire direct_start=phase==IDLE && starting && host_address==0;
    wire direct=(phase==DIRECT || direct_start) && host_download;
    wire replay=phase>=START && phase<=OUTPUT_BYTES;
    wire send_byte=phase==OUTPUT_BYTES && !stream_wait && !error && !reset;
    wire watchdog=phase>=ISSUE && phase<=OUTPUT_BYTES;
    wire aborted=phase==DRAIN;

    assign stream_download=!reset && (direct || (replay && !error));
    assign stream_write=!reset && ((direct && host_write) || send_byte);
    assign stream_address=direct ? host_address : offset;
    assign stream_data=direct ? host_data : buffer[offset[2:0]*8+:8];
    assign host_wait=(phase==DIRECT || direct_start) ? stream_wait : phase!=IDLE && phase!=STAGED;
    assign busy=host_download || phase!=IDLE || !word_idle;

    raizing_ddr_word fetch(
        .clk(clk),.reset(reset),.abort(aborted),.request(word_request),.writing(1'b0),
        .address(DDR_BASE+{5'd0,offset[26:3],3'b000}),.data(64'd0),.mask(8'hff),
        .idle(word_idle),.done(word_done),.result(word_result),.ddr(ddr));

    always @(posedge clk) begin
        previous<=host_download;
        word_request<=0;
        if(reset) begin
            phase<=IDLE;previous<=0;error<=0;declared_length<=0;offset<=0;
            buffer<=0;timer<=0;word_request<=0;
        end else if(starting && phase!=IDLE) begin
            error<=1;phase<=DRAIN;
        end else if(abort && phase!=IDLE && phase!=DRAIN) begin
            error<=1;phase<=DRAIN;
        end else if(watchdog && timer==TIMER_W'(TIMEOUT_CYCLES-1)) begin
            error<=1;phase<=DRAIN;
        end else begin
            if(watchdog && !send_byte && !word_done) timer<=timer+1'b1;
            else timer<=0;
            case(phase)
                IDLE: if(starting) begin
                    error<=host_address!=0 && host_write;
                    offset<=0;declared_length<=host_address;
                    phase<=host_address==0 ? DIRECT : STAGED;
                end
                DIRECT: if(!host_download) phase<=IDLE;
                STAGED: begin
                    if(host_write) error<=1;
                    if(!host_download) begin
                        // length is the address given at download start
                        if(error || rom_bytes==0 || declared_length!=rom_bytes) begin error<=1;phase<=IDLE;end
                        else phase<=START;
                    end
                end
                START: phase<=ISSUE;
                ISSUE: if(word_idle) begin word_request<=1;phase<=WAIT_WORD;end
                WAIT_WORD: if(word_done) begin buffer<=word_result;phase<=OUTPUT_BYTES;end
                OUTPUT_BYTES: if(send_byte) begin
                    offset<=offset+27'd1;
                    // ends at the length declared at start
                    if(offset==declared_length-27'd1) phase<=FINISH;
                    else if(offset[2:0]==7) phase<=ISSUE;
                end
                FINISH: phase<=IDLE;
                DRAIN: if(!ddr.acquire && !word_request) phase<=IDLE;
                default: begin error<=1;phase<=DRAIN;end
            endcase
        end
    end
`ifdef SIMULATION
    initial begin
        if(MAX_ROM_BYTES==0 || MAX_ROM_BYTES>27'h2000000 || DDR_BASE[2:0]!=0 ||
           DDR_BASE+MAX_ROM_BYTES<DDR_BASE || TIMEOUT_CYCLES<4)
            $fatal(1,"Invalid DDR ROM staging parameters");
    end
`endif
endmodule

// Download checker: one buffered HPS byte, CRC-32 and length; done after the last SDRAM write.
module raizing_download #(
    parameter integer DL_AW=raizing_board_pkg::DL_ADDRESS_BITS
) (
    input clk,reset,
    // Expected image length for the selected board; 0 rejects every image.
    input [26:0] rom_bytes,
    input downloading,write,
    input [26:0] address,
    input [7:0] data,
    output wait_request,active,
    output reg valid,error,
    output reg [31:0] crc,length,
    output dl_valid,
    output reg [DL_AW-1:0] dl_address,
    output reg [7:0] dl_data,
    input dl_ready,dl_busy,dl_error
);
    reg pending,previous,finishing;
    reg [31:0] running_crc,count;
    wire accepted=pending && dl_ready;
    assign dl_valid=pending;
    assign active=downloading || pending || dl_busy || finishing;
    assign wait_request=pending || dl_busy || (downloading && !dl_ready);
    function automatic [31:0] crc_byte(input [31:0] c,input [7:0] d);
        reg [31:0] x;
        begin
            x=c^{24'd0,d};
            for(integer i=0;i<8;i=i+1) x=x[0] ? (x>>1)^32'hedb88320 : x>>1;
            crc_byte=x;
        end
    endfunction
    always @(posedge clk) begin
        previous<=downloading;
        if(reset) begin
            pending<=0;previous<=0;finishing<=0;valid<=0;error<=0;
            crc<=0;length<=0;running_crc<=32'hffffffff;count<=0;dl_address<=0;dl_data<=0;
        end else begin
            if(downloading && !previous) begin
                valid<=0;error<=0;running_crc<=32'hffffffff;count<=0;finishing<=1;
            end
            if(write && downloading) begin
                if((pending && !accepted) || address>=rom_bytes) begin error<=1;valid<=0;end
                else begin pending<=1;dl_address<=address[DL_AW-1:0];dl_data<=data;end
            end else if(accepted) pending<=0;
            if(accepted) begin
                running_crc<=crc_byte(running_crc,dl_data);count<=count+32'd1;
                if(32'(dl_address)!=count) begin error<=1;valid<=0;end
            end
            if(finishing && !downloading && !pending && !dl_busy) begin
                finishing<=0;crc<=~running_crc;length<=count;
                valid<=!error && !dl_error && rom_bytes!=0 && count==32'(rom_bytes);
            end
            // a later SDRAM write error invalidates the image
            if(dl_error && !downloading) begin error<=1;valid<=0;end
        end
    end
endmodule

// ROM memory: staged image to SDRAM mapping per board family, eight client caches and early text ROM BRAM.
module raizing_memory #(
    parameter integer DL_AW = raizing_board_pkg::DL_ADDRESS_BITS,
    parameter integer INIT_PAUSE = 20000
) (
    input clk, reset,
    input raizing_board_pkg::board_e board,   // selects the staged ROM layout
    output init_done,
    input quiesce, invalidate,
    output quiesced,
    output reg invalidate_done,
    input [7:0] rom_req_valid,
    output [7:0] rom_req_ready,
    input [8*raizing_board_pkg::ROM_ADDR_BITS-1:0] rom_req_addr,
    output [7:0] rom_rsp_valid,
    input [7:0] rom_rsp_ready,
    output [255:0] rom_rsp_data,
    output [7:0] rom_rsp_error,
    input [13:0] text_addr,
    output reg [15:0] text_data,
    input download, dl_valid,
    output dl_ready, dl_busy,
    input [DL_AW-1:0] dl_addr,
    input [7:0] dl_data,
    output reg dl_error,
    inout [15:0] sdram_dq,
    output [12:0] sdram_a,
    output [1:0] sdram_ba,
    output sdram_ncs, sdram_nras, sdram_ncas, sdram_nwe,
    output sdram_dqml, sdram_dqmh, sdram_cke
);
    localparam integer AW = raizing_board_pkg::ROM_ADDR_BITS;   // client byte address (24)
    // staged byte offsets: program, sound, graphics, text, PCM, second PCM
    wire [24:0] PROG = 25'(raizing_board_pkg::prog_bytes(board));
    wire [24:0] PCM = 25'(raizing_board_pkg::pcm_bytes(board));
    wire [24:0] PCM2 = 25'(raizing_board_pkg::pcm2_bytes(board));
    wire [24:0] GFX = 25'(raizing_board_pkg::gfx_bytes(board));
    wire [24:0] GFX_OFF = PROG + 25'(raizing_board_pkg::sound_bytes(board));
    wire [24:0] TEXT_OFF = GFX_OFF + GFX;
    wire [24:0] PCM_OFF = TEXT_OFF + 25'(raizing_board_pkg::text_bytes(board));
    wire [24:0] ROM_END = PCM_OFF + PCM + PCM2;
    // Bakraid bytes: non-graphics packed from 0 in staged order; graphics from 16 MiB
    // graphics: horizontal 32-byte cells paired within each 64-byte tile pair
    function automatic [AW-1:0] gfx_layout(input [AW-1:0] address);
        gfx_layout={address[AW-1:6],address[2],address[4:3],address[5],address[1:0]};
    endfunction
    wire [24:0] gfx_offset = dl_addr - GFX_OFF;
    wire [24:0] text_offset = dl_addr - TEXT_OFF;
    wire in_text = dl_addr >= TEXT_OFF && dl_addr < PCM_OFF;
    wire map_valid = dl_addr < ROM_END;
    wire [24:0] map_address = dl_addr < GFX_OFF ? dl_addr :
                              dl_addr < TEXT_OFF ? 25'h1000000 + {1'b0,gfx_layout(gfx_offset[AW-1:0])} :
                              dl_addr - (PCM_OFF - GFX_OFF);
    // family: 0 early (Sorcer, Kingdom, Garegga), 1 Batrider, 2 Bakraid
    wire [1:0] family = board==raizing_board_pkg::RZB_BATRIDER ? 2'd1 :
                        board==raizing_board_pkg::RZB_BAKRAID ? 2'd2 : 2'd0;
    wire family_bytes = family!=2'd2;
    // early/Batrider byte writes: word address per family (early: within a bank pair; Batrider: 23-bit)
    wire [24:0] SOUND_END = GFX_OFF;
    wire [24:0] PCM_END = PCM_OFF + PCM;
    wire [24:0] e_gfx_offset = dl_addr - GFX_OFF;
    wire [23:0] e_gfx_word = 24'(gfx_layout(e_gfx_offset[AW-1:0]) >> 1);
    wire [23:0] byte_word = dl_addr < PROG ? 24'(dl_addr >> 1) :
                            dl_addr < SOUND_END ? (family==2'd1 ? 24'h100000 : 24'h080000) + 24'((dl_addr - PROG) >> 1) :
                            dl_addr < TEXT_OFF ? e_gfx_word :
                            dl_addr < PCM_END ? (family==2'd1 ? 24'h120000 : 24'h090000) + 24'((dl_addr - PCM_OFF) >> 1) :
                            24'h1a0000 + 24'((dl_addr - PCM_END) >> 1);
    wire byte_gfx = dl_addr >= SOUND_END && dl_addr < TEXT_OFF;
    localparam [1:0] DL_IDLE=0, DL_ISSUE=1, DL_WAIT=2;
    reg [1:0] dl_state;
    reg last_download, half_valid;
    reg [24:0] half_addr;
    reg [7:0] half_data;
    reg [23:0] prog_addr;
    reg [15:0] prog_data;
    reg [1:0] prog_be;
    reg prog_flag;
    wire prog_valid = dl_state == DL_ISSUE;
    wire prog_ready, prog_done, backend_idle;
    wire [7:0] line_valid, line_ready, line_done, cache_idle;
    wire [8*AW-1:0] line_addr;
    wire [63:0] line_data;
    wire all_idle = &cache_idle && backend_idle;
    wire invalidate_accept = invalidate && quiesced;
    wire block_requests = !init_done || download || dl_busy || half_valid || dl_error || quiesce || invalidate;
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] text_high [0:16383];
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] text_low [0:16383];
    wire dl_accept = dl_valid && dl_ready && !reset;
    // early text ROM is written to BRAM; late boards have no text region
    wire text_write = dl_accept && in_text;

    assign dl_busy = dl_state != DL_IDLE;
    assign dl_ready = download && init_done && all_idle && !dl_busy;
    assign quiesced = quiesce && all_idle && !dl_busy && !download && !half_valid;

    always @(posedge clk) begin
        text_data <= {text_high[text_addr],text_low[text_addr]};
        if (text_write && !dl_addr[0]) text_high[text_offset[14:1]] <= dl_data;
        if (text_write && dl_addr[0]) text_low[text_offset[14:1]] <= dl_data;
    end

    // download writer; Bakraid pairs an even byte with the next odd byte into one word write
    always @(posedge clk) begin
        if (reset) begin
            dl_state <= DL_IDLE; dl_error <= 0; last_download <= 0; half_valid <= 0;
            half_addr <= 0; half_data <= 0; prog_addr <= 0; prog_data <= 0; invalidate_done <= 0;
            prog_be <= 2'b11; prog_flag <= 0;
        end else begin
            last_download <= download;
            invalidate_done <= invalidate_accept;
            if (download && !last_download) begin
                dl_error <= dl_busy; half_valid <= 0;
            end
            if (!download && last_download && half_valid) begin dl_error <= 1; half_valid <= 0; end
            case (dl_state)
                DL_IDLE: if (dl_accept && !in_text && family_bytes) begin
                    // early/Batrider: one byte per write
                    prog_data <= {2{dl_data}};
                    prog_be <= dl_addr[0] ? 2'b01 : 2'b10;
                    prog_flag <= byte_gfx;
                    prog_addr <= byte_word;
                    if (!map_valid) dl_error <= 1;
                    else dl_state <= DL_ISSUE;
                end else if (dl_accept && !in_text) begin
                    prog_be <= 2'b11; prog_flag <= 0;
                    if (dl_error && !(download && !last_download)) half_valid <= 0;
                    else if (!map_valid || (!half_valid && dl_addr[0]) ||
                             (half_valid && dl_addr != half_addr + 25'd1)) begin
                        dl_error <= 1; half_valid <= 0;
                    end else if (!half_valid) begin
                        half_valid <= 1; half_addr <= dl_addr; half_data <= dl_data;
                    end else begin
                        prog_addr <= map_address[24:1]; prog_data <= {half_data,dl_data};
                        half_valid <= 0; dl_state <= DL_ISSUE;
                    end
                end
                DL_ISSUE: if (prog_ready) dl_state <= DL_WAIT;
                DL_WAIT: if (prog_done) dl_state <= DL_IDLE;
                default: dl_state <= DL_IDLE;
            endcase
        end
    end

    // clients: 0 program (16-bit), 1 sound, 2 PCM/YMZ, 3 second PCM (8-bit), 4-7 graphics (32-bit)
    genvar c;
    generate for (c=0; c<8; c=c+1) begin : clients
        localparam integer DW = c == 0 ? 16 : c < 4 ? 8 : 32;
        wire [24:0] size = c == 0 ? PROG : c == 1 ? GFX_OFF - PROG : c == 2 ? PCM : c == 3 ? PCM2 : GFX;
        wire [24:0] base = c == 0 ? 25'd0 : c == 1 ? PROG : c == 2 ? GFX_OFF : c == 3 ? GFX_OFF + PCM : 25'h1000000;
        // word bases: early Z80 0x80000, PCM 0x90000; Batrider Z80 0x100000, PCM 0x120000, PCM2 0x1a0000
        wire [23:0] word_base = family == 2'd2 ? base[24:1] :
            c == 1 ? (family == 2'd1 ? 24'h100000 : 24'h080000) :
            c == 2 ? (family == 2'd1 ? 24'h120000 : 24'h090000) :
            c == 3 ? 24'h1a0000 : 24'd0;
        raizing_rom_cache #(.DATA_BITS(DW)) cache (
            .clk(clk),.region_bytes(size),.word_base(word_base),.reset(reset),.block_requests(block_requests),
            .invalidate(download || invalidate_accept),
            .req_valid(rom_req_valid[c]),.req_ready(rom_req_ready[c]),
            .req_addr(c>=4 ? gfx_layout(rom_req_addr[c*AW +: AW]) : rom_req_addr[c*AW +: AW]),
            .rsp_valid(rom_rsp_valid[c]),.rsp_ready(rom_rsp_ready[c]),
            .rsp_data(rom_rsp_data[c*32 +: 32]),.rsp_error(rom_rsp_error[c]),
            .idle(cache_idle[c]),.line_valid(line_valid[c]),.line_ready(line_ready[c]),
            .line_addr(line_addr[c*AW +: AW]),.line_done(line_done[c]),
            .line_data(line_data)
        );
    end endgenerate
    raizing_ika_sdram #(.INIT_PAUSE(INIT_PAUSE)) backend (
        .layout(family),.prog_flag(prog_flag),
        .clk(clk),.reset(reset),.init_done(init_done),.idle(backend_idle),
        .line_valid(line_valid),.line_ready(line_ready),.line_addr(line_addr),
        .line_done(line_done),.line_data(line_data),
        .prog_valid(prog_valid),.prog_ready(prog_ready),.prog_addr(prog_addr),
        .prog_data(prog_data),.prog_be(prog_be),.prog_done(prog_done),
        .sdram_dq(sdram_dq),.sdram_a(sdram_a),.sdram_ba(sdram_ba),
        .sdram_ncs(sdram_ncs),.sdram_nras(sdram_nras),.sdram_ncas(sdram_ncas),
        .sdram_nwe(sdram_nwe),.sdram_dqml(sdram_dqml),.sdram_dqmh(sdram_dqmh),
        .sdram_cke(sdram_cke)
    );
endmodule

// ROM client cache: two 64-bit lines, filled from SDRAM on a miss.
module raizing_rom_cache #(
    parameter integer DATA_BITS = 16,
    parameter integer AW = raizing_board_pkg::ROM_ADDR_BITS   // request byte address
) (
    input [AW:0] region_bytes,   // this client's region size for the selected board (0 = none)
    input [AW-1:0] word_base,    // physical word address of the region
    input clk, reset, block_requests, invalidate,
    input req_valid,
    output req_ready,
    input [AW-1:0] req_addr,
    output rsp_valid,
    input rsp_ready,
    output reg [31:0] rsp_data,
    output reg rsp_error,
    output idle,
    output line_valid,
    input line_ready,
    output [AW-1:0] line_addr,
    input line_done,
    input [63:0] line_data
);
    localparam [2:0] IDLE=0, LOOKUP=1, MISS=2, FILL=3, RESPONSE=4;
    reg [2:0] state;
    reg [AW-1:0] address;
    reg [AW-4:0] recent_tag, previous_tag;
    reg [63:0] recent_data, previous_data;
    reg [1:0] valid;
    wire hit_recent = valid[0] && recent_tag == address[AW-1:3];
    wire hit_previous = valid[1] && previous_tag == address[AW-1:3];
    wire [63:0] hit_data = hit_recent ? recent_data : previous_data;
    wire address_error = {1'b0,req_addr} >= region_bytes ||
        (DATA_BITS == 16 && req_addr[0]) ||
        (DATA_BITS == 32 && |req_addr[1:0]);

    function automatic [31:0] select_data(input [63:0] data, input [2:0] offset);
        reg [15:0] word_data;
        begin
            word_data = data[offset[2:1]*16 +: 16];
            if (DATA_BITS == 8)
                select_data = {24'd0, offset[0] ? word_data[7:0] : word_data[15:8]};
            else if (DATA_BITS == 16) select_data = {16'd0,word_data};
            else select_data = data[offset[2]*32 +: 32];
        end
    endfunction

    assign req_ready = state == IDLE && !block_requests;
    assign rsp_valid = state == RESPONSE;
    assign idle = state == IDLE;
    assign line_valid = state == MISS;
    assign line_addr = word_base + {1'b0,address[AW-1:3],2'b00};

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            address <= 0;
            valid <= 0;
            rsp_data <= 0;
            rsp_error <= 0;
        end else begin
            case (state)
                IDLE: if (req_valid && req_ready) begin
                    address <= req_addr;
                    rsp_error <= address_error;
                    if (address_error) begin
                        rsp_data <= 32'hffffffff;
                        state <= RESPONSE;
                    end else state <= LOOKUP;
                end
                LOOKUP: if (hit_recent || hit_previous) begin
                    rsp_data <= select_data(hit_data,address[2:0]);
                    state <= RESPONSE;
                end else state <= MISS;
                MISS: if (line_ready) state <= FILL;
                FILL: if (line_done) begin
                    previous_tag <= recent_tag;
                    previous_data <= recent_data;
                    recent_tag <= address[AW-1:3];
                    recent_data <= line_data;
                    valid <= {valid[0],1'b1};
                    rsp_data <= select_data(line_data,address[2:0]);
                    state <= RESPONSE;
                end
                RESPONSE: if (rsp_ready) state <= IDLE;
                default: state <= IDLE;
            endcase
            if (invalidate) valid <= 0;
        end
    end
`ifdef SIMULATION
    initial if (DATA_BITS != 8 && DATA_BITS != 16 && DATA_BITS != 32)
        $fatal(1,"Unsupported ROM width");
    always @(posedge clk) if (!reset && line_done && state != FILL)
        $fatal(1,"Unowned ROM fill");
`endif
endmodule

// Level-sensitive ROM read port: one request in flight; ok while the address matches the returned word.
module raizing_rom_port #(
    parameter integer AW = raizing_board_pkg::ROM_ADDR_BITS
) (
    input clk,reset,invalidate,
    input request,
    input [AW-1:0] address,
    output ok,
    output reg [31:0] data,
    output req_valid,
    input req_ready,
    output [AW-1:0] req_addr,
    input rsp_valid,
    output rsp_ready,
    input [31:0] rsp_data,
    input rsp_error,
    output idle,
    output reg error,
    // held word address/valid: ok = request && line_valid && address == line_addr
    output line_valid,
    output [AW-1:0] line_addr
);
    reg pending,valid;
    reg [AW-1:0] accepted_address;
    assign req_valid=request && !pending && !valid && !invalidate;
    assign req_addr=address;
    assign rsp_ready=pending;
    assign ok=request && valid && address==accepted_address;
    assign line_valid=valid;
    assign line_addr=accepted_address;
    assign idle=!pending;
    always @(posedge clk) begin
        if(reset) begin pending<=0; valid<=0; data<=0; accepted_address<=0; error<=0; end
        else begin
            if(invalidate || !request || address!=accepted_address) valid<=0;
            if(req_valid && req_ready) begin pending<=1; accepted_address<=address; end
            if(rsp_valid && rsp_ready) begin
                pending<=0;
                data<=rsp_data;
                valid<=request && address==accepted_address && !invalidate;
                error<=error || rsp_error;
            end
        end
    end
endmodule

// Request/response ROM port: cancel discards an outstanding reply while it still drains.
module raizing_native_rom_port #(
    parameter integer AW = raizing_board_pkg::ROM_ADDR_BITS
) (
    input clk,reset,cancel,
    input source_req_valid,
    output source_req_ready,
    input [AW-1:0] source_req_addr,
    output source_rsp_valid,
    input source_rsp_ready,
    output [31:0] source_rsp_data,
    output source_rsp_error,
    output req_valid,
    input req_ready,
    output [AW-1:0] req_addr,
    input rsp_valid,
    output rsp_ready,
    input [31:0] rsp_data,
    input rsp_error,
    output idle,
    output reg error=0
);
    reg pending=0,discard=0;
    assign req_valid=source_req_valid && !pending && !cancel && !reset;
    assign source_req_ready=req_ready && !pending && !cancel && !reset;
    assign req_addr=source_req_addr;
    assign source_rsp_valid=rsp_valid && pending && !discard && !cancel && !reset;
    assign source_rsp_data=rsp_data;
    assign source_rsp_error=rsp_error;
    assign rsp_ready=pending && (discard || cancel || source_rsp_ready) && !reset;
    assign idle=!pending;
    always @(posedge clk)begin
        if(reset)begin pending<=0;discard<=0;error<=0;end
        else begin
            if(pending && cancel)discard<=1;
            if(req_valid && req_ready)begin pending<=1;discard<=0;end
            if(rsp_valid && rsp_ready)begin
                pending<=0;discard<=0;error<=error || rsp_error;
            end
        end
    end
`ifdef SIMULATION
    always @(posedge clk)if(!reset && rsp_valid && !pending)
        $fatal(1,"Unowned native object ROM response");
`endif
endmodule

// SDRAM wrapper: one IKA controller with per-family layouts (0 early, 1 Batrider, 2 Bakraid) and front ends.
module raizing_ika_sdram #(
    parameter integer INIT_PAUSE=20000
) (
    input clk,reset,
    input [1:0] layout,              // family of the latched board
    output init_done,idle,
    input [7:0] line_valid,
    output [7:0] line_ready,
    input [191:0] line_addr,         // eight 24-bit word addresses (lane 3 unused by early)
    output [7:0] line_done,
    output [63:0] line_data,
    input prog_valid,
    output prog_ready,
    input [23:0] prog_addr,          // early: 22-bit word in a pair; Batrider: 23-bit; Bakraid: 24-bit
    input prog_flag,                 // early: graphics pair 2/3; Batrider: graphics banks
    input [15:0] prog_data,
    input [1:0] prog_be,
    output prog_done,
    inout [15:0] sdram_dq,
    output [12:0] sdram_a,
    output [1:0] sdram_ba,
    output sdram_ncs,sdram_nras,sdram_ncas,sdram_nwe,
    output sdram_dqml,sdram_dqmh,sdram_cke
);
    localparam integer REFRESH_CYCLES=576;   // 7.111 us at 81 MHz
    reg [9:0] refresh_count;
    reg refresh;
    always @(posedge clk) begin
        if(reset || !init_done) begin refresh_count<=0;refresh<=0;end
        else begin
            refresh<=0;
            if(refresh_count==REFRESH_CYCLES-1) begin refresh_count<=0;refresh<=1;end
            else refresh_count<=refresh_count+1'b1;
        end
    end
    // layout follows the board only while the active front end is idle; inactive front ends stay in reset
    reg [1:0] layout_q=2'd0;
    wire active_idle;
    always @(posedge clk)
        if(reset || active_idle) layout_q<=layout;
    wire use_e=layout_q==2'd0, use_b=layout_q==2'd1, use_k=layout_q==2'd2;

    // Controller slots used: 0, 1, 2 (ROM mirror pairs) and 8-11 (private banks).
    wire [15:0] slot_data,preload_result;
    wire preload_busy;
    wire [11:0] c_busy,c_first,c_done;
    wire [11:0] c_rd;
    wire [22:0] c_addr [0:11];

    // ---- early front end: slots 0, 1, 2
    wire [6:0] e_line_valid={line_valid[7:4],line_valid[2:0]};
    wire [153:0] e_line_addr;
    genvar ln;
    generate for(ln=0;ln<7;ln=ln+1) begin : early_lines
        localparam integer LANE=ln<3 ? ln : ln+1;
        assign e_line_addr[ln*22 +: 22]=line_addr[LANE*24 +: 22];
    end endgenerate
    wire [6:0] e_line_ready,e_line_done;
    wire [63:0] e_line_data;
    wire e_read_idle,e_idle,e_prog_ready,e_prog_done,e_preload_en,e_preload_wr,e_preload_rd;
    wire [68:0] e_slot_addr;
    wire [2:0] e_slot_rd;
    wire [25:0] e_preload_addr;
    wire [15:0] e_preload_data;
    raizing_ika_frontend_early frontend_early(
        .clk(clk),.reset(reset || !use_e),.init_done(init_done),
        .line_valid(use_e ? e_line_valid : 7'd0),.line_ready(e_line_ready),.line_addr(e_line_addr),
        .line_done(e_line_done),.line_data(e_line_data),.read_idle(e_read_idle),.idle(e_idle),
        .slot_addr(e_slot_addr),.slot_rd(e_slot_rd),
        .slot_busy({c_busy[2],c_busy[1],c_busy[0]}),.slot_first({c_first[2],c_first[1],c_first[0]}),
        .slot_done({c_done[2],c_done[1],c_done[0]}),.slot_data(slot_data),
        .prog_valid(use_e && prog_valid),.prog_ready(e_prog_ready),.prog_addr(prog_addr[21:0]),
        .prog_pair(prog_flag),.prog_data(prog_data),.prog_be(prog_be),.prog_done(e_prog_done),
        .preload_en(e_preload_en),.preload_addr(e_preload_addr),.preload_data(e_preload_data),
        .preload_wr(e_preload_wr),.preload_rd(e_preload_rd),.preload_busy(preload_busy),
        .preload_result(preload_result)
    );

    // ---- Batrider front end: slots 0, 1, 8, 9
    wire [183:0] b_line_addr;
    generate for(ln=0;ln<8;ln=ln+1) begin : batrider_lines
        assign b_line_addr[ln*23 +: 23]=line_addr[ln*24 +: 23];
    end endgenerate
    wire [7:0] b_line_ready,b_line_done;
    wire [63:0] b_line_data;
    wire b_read_idle,b_idle,b_prog_ready,b_prog_done,b_preload_en,b_preload_wr,b_preload_rd;
    wire [91:0] b_slot_addr;
    wire [3:0] b_slot_rd;
    wire [25:0] b_preload_addr;
    wire [15:0] b_preload_data;
    raizing_ika_frontend_batrider frontend_batrider(
        .clk(clk),.reset(reset || !use_b),.init_done(init_done),
        .line_valid(use_b ? line_valid : 8'd0),.line_ready(b_line_ready),.line_addr(b_line_addr),
        .line_done(b_line_done),.line_data(b_line_data),.read_idle(b_read_idle),.idle(b_idle),
        .slot_addr(b_slot_addr),.slot_rd(b_slot_rd),
        .slot_busy({c_busy[9],c_busy[8],c_busy[1],c_busy[0]}),
        .slot_first({c_first[9],c_first[8],c_first[1],c_first[0]}),
        .slot_done({c_done[9],c_done[8],c_done[1],c_done[0]}),.slot_data(slot_data),
        .prog_valid(use_b && prog_valid),.prog_ready(b_prog_ready),.prog_addr(prog_addr[22:0]),
        .prog_gfx(prog_flag),.prog_data(prog_data),.prog_be(prog_be),.prog_done(b_prog_done),
        .preload_en(b_preload_en),.preload_addr(b_preload_addr),.preload_data(b_preload_data),
        .preload_wr(b_preload_wr),.preload_rd(b_preload_rd),.preload_busy(preload_busy),
        .preload_result(preload_result)
    );

    // ---- Bakraid front end: slots 8-11
    wire [7:0] k_line_ready,k_line_done;
    wire [63:0] k_line_data;
    wire k_read_idle,k_idle,k_prog_ready,k_prog_done,k_preload_en,k_preload_wr,k_preload_rd;
    wire [91:0] k_slot_addr;
    wire [3:0] k_slot_rd;
    wire [25:0] k_preload_addr;
    wire [15:0] k_preload_data;
    raizing_ika_frontend frontend(
        .clk(clk),.reset(reset || !use_k),.init_done(init_done),
        .line_valid(use_k ? line_valid : 8'd0),.line_ready(k_line_ready),.line_addr(line_addr),
        .line_done(k_line_done),.line_data(k_line_data),.read_idle(k_read_idle),.idle(k_idle),
        .slot_addr(k_slot_addr),.slot_rd(k_slot_rd),
        .slot_busy(c_busy[11:8]),.slot_first(c_first[11:8]),.slot_done(c_done[11:8]),.slot_data(slot_data),
        .prog_valid(use_k && prog_valid),.prog_ready(k_prog_ready),.prog_addr(prog_addr),
        .prog_data(prog_data),.prog_be(prog_be),.prog_done(k_prog_done),
        .preload_en(k_preload_en),.preload_addr(k_preload_addr),.preload_data(k_preload_data),
        .preload_wr(k_preload_wr),.preload_rd(k_preload_rd),.preload_busy(preload_busy),
        .preload_result(preload_result)
    );

    // ---- selected front end
    assign line_ready=use_e ? {e_line_ready[6:3],1'b0,e_line_ready[2:0]} : use_b ? b_line_ready : k_line_ready;
    assign line_done=use_e ? {e_line_done[6:3],1'b0,e_line_done[2:0]} : use_b ? b_line_done : k_line_done;
    assign line_data=use_e ? e_line_data : use_b ? b_line_data : k_line_data;
    assign prog_ready=use_e ? e_prog_ready : use_b ? b_prog_ready : k_prog_ready;
    assign prog_done=use_e ? e_prog_done : use_b ? b_prog_done : k_prog_done;
    // idle only once the layout matches the board
    assign active_idle=use_e ? e_idle : use_b ? b_idle : k_idle;
    assign idle=active_idle && layout_q==layout;
    wire preload_en=use_e ? e_preload_en : use_b ? b_preload_en : k_preload_en;
    wire preload_wr=use_e ? e_preload_wr : use_b ? b_preload_wr : k_preload_wr;
    wire preload_rd=use_e ? e_preload_rd : use_b ? b_preload_rd : k_preload_rd;
    wire [25:0] preload_addr=use_e ? e_preload_addr : use_b ? b_preload_addr : k_preload_addr;
    wire [15:0] preload_data=use_e ? e_preload_data : use_b ? b_preload_data : k_preload_data;
    assign c_rd[0]=use_e ? e_slot_rd[0] : use_b && b_slot_rd[0];
    assign c_rd[1]=use_e ? e_slot_rd[1] : use_b && b_slot_rd[1];
    assign c_rd[2]=use_e && e_slot_rd[2];
    assign c_rd[7:3]=5'd0;
    assign c_rd[8]=use_b ? b_slot_rd[2] : use_k && k_slot_rd[0];
    assign c_rd[9]=use_b ? b_slot_rd[3] : use_k && k_slot_rd[1];
    assign c_rd[10]=use_k && k_slot_rd[2];
    assign c_rd[11]=use_k && k_slot_rd[3];
    assign c_addr[0]=use_e ? e_slot_addr[0+:23] : b_slot_addr[0+:23];
    assign c_addr[1]=use_e ? e_slot_addr[23+:23] : b_slot_addr[23+:23];
    assign c_addr[2]=e_slot_addr[46+:23];
    assign c_addr[8]=use_b ? b_slot_addr[46+:23] : k_slot_addr[0+:23];
    assign c_addr[9]=use_b ? b_slot_addr[69+:23] : k_slot_addr[23+:23];
    assign c_addr[10]=k_slot_addr[46+:23];
    assign c_addr[11]=k_slot_addr[69+:23];
    generate for(ln=3;ln<8;ln=ln+1) begin : unused_slots
        assign c_addr[ln]=23'd0;
    end endgenerate

    ikautil_sdram_rz #(
        .FREQ(95),.BL0(4),.BL1(4),.CAP_DELAY(1),.RFSHCNT(1),
        .INIT_PAUSE(INIT_PAUSE),.DQM_SHARED(1),
        .SLOT0_EN(1),.SLOT1_EN(1),.SLOT2_EN(1),.SLOT3_EN(0),
        .SLOT4_EN(0),.SLOT5_EN(0),.SLOT6_EN(0),.SLOT7_EN(0),
        .SLOT8_EN(1),.SLOT9_EN(1),.SLOT10_EN(1),.SLOT11_EN(1),
        .SLOT0_DW(64),.SLOT1_DW(64),.SLOT2_DW(64),
        .SLOT8_DW(64),.SLOT9_DW(64),.SLOT10_DW(64),.SLOT11_DW(64),
        .SLOT0_SA(23'd0),.SLOT1_SA(23'd0),.SLOT2_SA(23'd0),
        .SLOT8_SA(23'd0),.SLOT9_SA(23'd0),.SLOT10_SA(23'd0),.SLOT11_SA(23'd0),
        // layout 0 (early): slot 0 pair 0/1, slot 1 pair 2/3, slot 2 pair 0/1
        .SLOT0_BANK(3'd0),.SLOT1_BANK(3'd2),.SLOT2_BANK(3'd0),
        .SLOT8_BANK(3'd0),.SLOT9_BANK(3'd1),.SLOT10_BANK(3'd2),.SLOT11_BANK(3'd3),
        .LAYOUTS(3),
        .L0_EN(12'h007),
        // layout 1 (Batrider): slots 0, 1 pair 0/1; slot 8 bank 2; slot 9 bank 3
        .L1_BANKS({3'd0,3'd0,3'd3,3'd2,3'd0,3'd0,3'd0,3'd0,3'd0,3'd0,3'd0,3'd0}),.L1_EN(12'h303),
        // layout 2 (Bakraid): slots 8-11 banks 0-3
        .L2_BANKS({3'd3,3'd2,3'd1,3'd0,3'd0,3'd0,3'd0,3'd0,3'd0,3'd0,3'd0,3'd0}),.L2_EN(12'hF00)
    ) controller (
        .i_LAYOUT(layout_q),
        .i_CLK(clk),.i_RST_n(!reset),.i_RFSH(refresh),.o_INIT_DONE(init_done),
        .i_PRELOAD(preload_en),.i_PRELOAD_A(preload_addr),.i_PRELOAD_DI(preload_data),
        .i_PRELOAD_WR(preload_wr),.i_PRELOAD_RD(preload_rd),
        .o_PRELOAD_BUSY(preload_busy),.o_PRELOAD_DO(preload_result),.o_RDATA(slot_data),
        .io_SDRAM_DQ(sdram_dq),.o_SDRAM_A(sdram_a),.o_SDRAM_BA(sdram_ba),
        .o_SDRAM_nCS(sdram_ncs),.o_SDRAM_nRAS(sdram_nras),.o_SDRAM_nCAS(sdram_ncas),.o_SDRAM_nWE(sdram_nwe),
        .o_SDRAM_DQML(sdram_dqml),.o_SDRAM_DQMH(sdram_dqmh),.o_SDRAM_CKE(sdram_cke),
        .i_SLOT0_RD(c_rd[0]),.i_SLOT1_RD(c_rd[1]),.i_SLOT2_RD(c_rd[2]),.i_SLOT3_RD(1'b0),
        .i_SLOT4_RD(1'b0),.i_SLOT5_RD(1'b0),.i_SLOT6_RD(1'b0),.i_SLOT7_RD(1'b0),
        .i_SLOT0_A(c_addr[0]),.i_SLOT1_A(c_addr[1]),.i_SLOT2_A(c_addr[2]),.i_SLOT3_A(23'd0),
        .i_SLOT4_A(23'd0),.i_SLOT5_A(23'd0),.i_SLOT6_A(23'd0),.i_SLOT7_A(23'd0),
        .o_SLOT0_BUSY(c_busy[0]),.o_SLOT1_BUSY(c_busy[1]),.o_SLOT2_BUSY(c_busy[2]),.o_SLOT3_BUSY(c_busy[3]),
        .o_SLOT4_BUSY(c_busy[4]),.o_SLOT5_BUSY(c_busy[5]),.o_SLOT6_BUSY(c_busy[6]),.o_SLOT7_BUSY(c_busy[7]),
        .o_SLOT0_RDY(c_done[0]),.o_SLOT1_RDY(c_done[1]),.o_SLOT2_RDY(c_done[2]),.o_SLOT3_RDY(c_done[3]),
        .o_SLOT4_RDY(c_done[4]),.o_SLOT5_RDY(c_done[5]),.o_SLOT6_RDY(c_done[6]),.o_SLOT7_RDY(c_done[7]),
        .o_SLOT0_DST(c_first[0]),.o_SLOT1_DST(c_first[1]),.o_SLOT2_DST(c_first[2]),.o_SLOT3_DST(c_first[3]),
        .o_SLOT4_DST(c_first[4]),.o_SLOT5_DST(c_first[5]),.o_SLOT6_DST(c_first[6]),.o_SLOT7_DST(c_first[7]),
        .o_SLOT0_DO(),.o_SLOT1_DO(),.o_SLOT2_DO(),.o_SLOT3_DO(),
        .o_SLOT4_DO(),.o_SLOT5_DO(),.o_SLOT6_DO(),.o_SLOT7_DO(),
        .i_SLOT8_RD(c_rd[8]),.i_SLOT9_RD(c_rd[9]),.i_SLOT10_RD(c_rd[10]),.i_SLOT11_RD(c_rd[11]),
        .i_SLOT8_WR(1'b0),.i_SLOT9_WR(1'b0),.i_SLOT10_WR(1'b0),.i_SLOT11_WR(1'b0),
        .i_SLOT8_A(c_addr[8]),.i_SLOT9_A(c_addr[9]),.i_SLOT10_A(c_addr[10]),.i_SLOT11_A(c_addr[11]),
        .i_SLOT8_DI(64'd0),.i_SLOT9_DI(64'd0),.i_SLOT10_DI(64'd0),.i_SLOT11_DI(64'd0),
        .o_SLOT8_BUSY(c_busy[8]),.o_SLOT9_BUSY(c_busy[9]),.o_SLOT10_BUSY(c_busy[10]),.o_SLOT11_BUSY(c_busy[11]),
        .o_SLOT8_RDY(c_done[8]),.o_SLOT9_RDY(c_done[9]),.o_SLOT10_RDY(c_done[10]),.o_SLOT11_RDY(c_done[11]),
        .o_SLOT8_DST(c_first[8]),.o_SLOT9_DST(c_first[9]),.o_SLOT10_DST(c_first[10]),.o_SLOT11_DST(c_first[11]),
        .o_SLOT8_DO(),.o_SLOT9_DO(),.o_SLOT10_DO(),.o_SLOT11_DO()
    );
endmodule

// Bakraid SDRAM front end: one read slot per bank (slots 8-11); download writes through preload.
module raizing_ika_frontend (
    input clk,reset,init_done,
    input [7:0] line_valid,
    output [7:0] line_ready,
    input [191:0] line_addr,
    output reg [7:0] line_done,
    output reg [63:0] line_data,
    output read_idle,idle,
    output reg [91:0] slot_addr,
    output reg [3:0] slot_rd,
    input [3:0] slot_busy,slot_first,slot_done,
    input [15:0] slot_data,
    input prog_valid,
    output prog_ready,
    input [23:0] prog_addr,
    input [15:0] prog_data,
    input [1:0] prog_be,
    output reg prog_done,
    output preload_en,
    output reg [25:0] preload_addr,
    output reg [15:0] preload_data,
    output reg preload_wr,preload_rd,
    input preload_busy,
    input [15:0] preload_result
);
    localparam [3:0] P_IDLE=0,P_READ=1,P_READ_ACCEPT=2,P_READ_WAIT=3,
        P_WRITE=4,P_WRITE_ACCEPT=5,P_WRITE_WAIT=6,P_FINISH=7;
    reg [3:0] prog_state;
    reg [3:0] active,physical_done,data_done;
    reg [2:0] owner[0:3],tail[0:3];
    reg [1:0] beat[0:3],turn[0:3];
    reg [63:0] assembled[0:3];
    wire [3:0] eligible[0:3];
    wire [5:0] pick[0:3];
    wire [2:0] grant_owner[0:3];
    wire [3:0] lane_grant;
    wire [7:0] grant;
    reg [15:0] write_data;
    reg [1:0] write_be;
    wire [3:0] stream_valid=slot_first|{(|tail[3]),(|tail[2]),(|tail[1]),(|tail[0])};
    assign read_idle=!(|active || |slot_rd || |slot_busy || |stream_valid);
    assign idle=read_idle && prog_state==P_IDLE && !preload_busy;
    wire launch=init_done && read_idle && prog_state==P_IDLE && !prog_valid;
    assign line_ready=launch ? grant : 8'd0;
    assign prog_ready=init_done && idle;
    assign preload_en=init_done && read_idle && (prog_valid || prog_state!=P_IDLE);

    function automatic [22:0] physical_addr(input [21:0] logical_addr);
        physical_addr={logical_addr[21:9],1'b0,logical_addr[8:0]};
    endfunction
    function automatic [5:0] rotate_pick(input [3:0] valid,input [1:0] start);
        begin
            rotate_pick=0;
            case(start)
                0: if(valid[0]) rotate_pick=6'b00_0001;
                   else if(valid[1]) rotate_pick=6'b01_0010;
                   else if(valid[2]) rotate_pick=6'b10_0100;
                   else if(valid[3]) rotate_pick=6'b11_1000;
                1: if(valid[1]) rotate_pick=6'b01_0010;
                   else if(valid[2]) rotate_pick=6'b10_0100;
                   else if(valid[3]) rotate_pick=6'b11_1000;
                   else if(valid[0]) rotate_pick=6'b00_0001;
                2: if(valid[2]) rotate_pick=6'b10_0100;
                   else if(valid[3]) rotate_pick=6'b11_1000;
                   else if(valid[0]) rotate_pick=6'b00_0001;
                   else if(valid[1]) rotate_pick=6'b01_0010;
                3: if(valid[3]) rotate_pick=6'b11_1000;
                   else if(valid[0]) rotate_pick=6'b00_0001;
                   else if(valid[1]) rotate_pick=6'b01_0010;
                   else if(valid[2]) rotate_pick=6'b10_0100;
            endcase
        end
    endfunction
    function automatic [21:0] select_addr(input [191:0] addresses,input [2:0] id);
        case(id)
            0: select_addr=addresses[0+:22];
            1: select_addr=addresses[24+:22];
            2: select_addr=addresses[48+:22];
            3: select_addr=addresses[72+:22];
            4: select_addr=addresses[96+:22];
            5: select_addr=addresses[120+:22];
            6: select_addr=addresses[144+:22];
            7: select_addr=addresses[168+:22];
        endcase
    endfunction
    genvar b,c;
    generate for(b=0;b<4;b=b+1) begin: banks
        for(c=0;c<4;c=c+1) begin: clients
            localparam integer ID=b<2 ? c : c+4;
            assign eligible[b][c]=line_valid[ID] && line_addr[ID*24+22+:2]==2'(b);
        end
        assign pick[b]=rotate_pick(eligible[b],turn[b]);
        assign lane_grant[b]=|eligible[b];
        assign grant_owner[b]={b>=2,pick[b][5:4]};
    end endgenerate
    assign grant={pick[2][3:0]|pick[3][3:0],pick[0][3:0]|pick[1][3:0]};

    always @(posedge clk) begin
        if(reset) begin
            active<=0;physical_done<=0;data_done<=0;line_done<=0;line_data<=0;
            slot_addr<=0;slot_rd<=0;
            for(integer s=0;s<4;s=s+1) begin owner[s]<=0;tail[s]<=0;beat[s]<=0;turn[s]<=0;end
        end else begin
            slot_rd<=0;line_done<=0;
            for(integer s=0;s<4;s=s+1) begin
                tail[s]<={tail[s][1:0],slot_first[s]};
                if(slot_done[s]) physical_done[s]<=1;
                if(slot_first[s]) begin assembled[s][15:0]<=slot_data;beat[s]<=1;end
                else if(|tail[s]) begin
                    assembled[s][beat[s]*16+:16]<=slot_data;beat[s]<=beat[s]+1'b1;
                    if(tail[s][2]) begin
                        line_data<={slot_data,assembled[s][47:0]};
                        line_done[owner[s]]<=1;data_done[s]<=1;
                    end
                end
                if(active[s] && (physical_done[s] || slot_done[s]) && (data_done[s] || tail[s][2]))
                    active[s]<=0;
                if(launch && lane_grant[s]) begin
                    slot_addr[s*23+:23]<=physical_addr(select_addr(line_addr,grant_owner[s]));
                    slot_rd[s]<=1;owner[s]<=grant_owner[s];active[s]<=1;
                    physical_done[s]<=0;data_done[s]<=0;turn[s]<=pick[s][5:4]+2'd1;
                end
            end
        end
    end

    always @(posedge clk) begin
        if(reset) begin
            prog_state<=P_IDLE;preload_addr<=0;preload_data<=0;
            preload_wr<=0;preload_rd<=0;prog_done<=0;write_data<=0;write_be<=0;
        end else begin
            preload_wr<=0;preload_rd<=0;prog_done<=0;
            case(prog_state)
                P_IDLE: if(prog_valid && prog_ready) begin
                    preload_addr<={1'b0,prog_addr[23:22],physical_addr(prog_addr[21:0])};
                    write_data<=prog_data;write_be<=prog_be;preload_data<=prog_data;
                    prog_state<=prog_be==0 ? P_FINISH : prog_be==3 ? P_WRITE : P_READ;
                end
                P_READ: if(!preload_busy) begin preload_rd<=1;prog_state<=P_READ_ACCEPT;end
                P_READ_ACCEPT: if(preload_busy) prog_state<=P_READ_WAIT;
                P_READ_WAIT: if(!preload_busy) begin
                    preload_data<={write_be[1] ? write_data[15:8] : preload_result[15:8],
                                   write_be[0] ? write_data[7:0] : preload_result[7:0]};
                    prog_state<=P_WRITE;
                end
                P_WRITE: if(!preload_busy) begin preload_wr<=1;prog_state<=P_WRITE_ACCEPT;end
                P_WRITE_ACCEPT: if(preload_busy) prog_state<=P_WRITE_WAIT;
                P_WRITE_WAIT: if(!preload_busy) prog_state<=P_FINISH;
                P_FINISH: begin prog_done<=1;prog_state<=P_IDLE;end
                default: prog_state<=P_IDLE;
            endcase
        end
    end
`ifdef SIMULATION
    always @(posedge clk) if(!reset) begin
        if((preload_rd || preload_wr) && (!preload_en || preload_busy)) $fatal(1,"Preload ownership");
        if(|(stream_valid & (stream_valid-1'b1))) $fatal(1,"Overlapping IKA data lanes");
        for(integer s=0;s<4;s=s+1) begin
            if(slot_rd[s] && slot_busy[s]) $fatal(1,"Busy private slot reused");
            if(slot_first[s] && (!active[s] || |tail[s])) $fatal(1,"Unowned IKA stream");
            if(slot_done[s] && !active[s]) $fatal(1,"Unowned IKA retirement");
        end
    end
`endif
endmodule

// Early-board SDRAM front end (Sorcer, Kingdom, Garegga): slots 0-2 over mirrored bank pairs.
module raizing_ika_frontend_early (
    input clk, reset, init_done,
    input [6:0] line_valid,
    output [6:0] line_ready,
    input [153:0] line_addr,
    output reg [6:0] line_done,
    output reg [63:0] line_data,
    output read_idle,
    output idle,
    output reg [68:0] slot_addr,
    output reg [2:0] slot_rd,
    input [2:0] slot_busy, slot_first, slot_done,
    input [15:0] slot_data,
    input prog_valid,
    output prog_ready,
    input [21:0] prog_addr,
    input prog_pair,
    input [15:0] prog_data,
    input [1:0] prog_be,
    output reg prog_done,
    output preload_en,
    output reg [25:0] preload_addr,
    output reg [15:0] preload_data,
    output reg preload_wr, preload_rd,
    input preload_busy,
    input [15:0] preload_result
);
    localparam [3:0] P_IDLE=0, P_READ=1, P_READ_ACCEPT=2, P_READ_WAIT=3,
        P_WRITE=4, P_WRITE_ACCEPT=5, P_WRITE_WAIT=6, P_FINISH=7;
    reg [3:0] prog_state;
    reg [2:0] active, physical_done, data_done;
    reg [2:0] owner [0:2];
    reg [2:0] tail [0:2];
    reg [1:0] beat [0:2];
    reg [63:0] assembled [0:2];
    reg cpu_turn;
    reg [1:0] gfx_turn;
    reg [6:0] grant;
    reg [2:0] grant_owner [0:2];
    reg [15:0] write_data;
    reg [1:0] write_be;
    reg mirror;
    wire [2:0] stream_valid = slot_first | {(|tail[2]),(|tail[1]),(|tail[0])};
    wire streams_active = |stream_valid;
    assign read_idle = !(|active || |slot_rd || |slot_busy || streams_active);
    assign idle = read_idle && prog_state == P_IDLE && !preload_busy;
    wire launch = init_done && read_idle && prog_state == P_IDLE && !prog_valid;
    assign line_ready = launch ? grant : 7'd0;
    assign prog_ready = init_done && idle;
    assign preload_en = init_done && read_idle &&
                        (prog_valid || prog_state != P_IDLE);

    function automatic [22:0] physical_addr(input [21:0] logical_addr);
        physical_addr = {logical_addr[21:9],1'b0,logical_addr[8:0]};
    endfunction

    // round-robin grants: lanes 0/1 alternate, graphics lanes 3-6 rotate
    always @* begin
        grant = 0;
        grant_owner[0] = 0;
        grant_owner[1] = 3;
        grant_owner[2] = 2;
        if (line_valid[cpu_turn]) begin
            grant[cpu_turn] = 1'b1;
            grant_owner[0] = {2'd0,cpu_turn};
        end else if (line_valid[!cpu_turn]) begin
            grant[!cpu_turn] = 1'b1;
            grant_owner[0] = {2'd0,!cpu_turn};
        end
        for (integer n=3; n>=0; n=n-1) begin
            if (line_valid[3+((gfx_turn+n)&3)]) begin
                grant[6:3] = 0;
                grant[3+((gfx_turn+n)&3)] = 1'b1;
                grant_owner[1] = 3'(3+((gfx_turn+n)&3));
            end
        end
        grant[2] = line_valid[2];
    end

    always @(posedge clk) begin
        if (reset) begin
            active <= 0;
            physical_done <= 0;
            data_done <= 0;
            line_done <= 0;
            slot_addr <= 0;
            slot_rd <= 0;
            cpu_turn <= 0;
            gfx_turn <= 0;
            for (integer s=0; s<3; s=s+1) begin
                owner[s] <= 0;
                tail[s] <= 0;
                beat[s] <= 0;
            end
        end else begin
            slot_rd <= 0;
            line_done <= 0;
            for (integer s=0; s<3; s=s+1) begin
                tail[s] <= {tail[s][1:0],slot_first[s]};
                if (slot_done[s]) physical_done[s] <= 1'b1;
                if (slot_first[s]) begin
                    assembled[s][15:0] <= slot_data;
                    beat[s] <= 1;
                end else if (|tail[s]) begin
                    assembled[s][beat[s]*16 +: 16] <= slot_data;
                    beat[s] <= beat[s] + 1'b1;
                    if (tail[s][2]) begin
                        line_data <= {slot_data,assembled[s][47:0]};
                        line_done[owner[s]] <= 1'b1;
                        data_done[s] <= 1'b1;
                    end
                end
                if (active[s] && (physical_done[s] || slot_done[s]) &&
                    (data_done[s] || tail[s][2])) active[s] <= 1'b0;
            end
            if (launch) begin
                for (integer s=0; s<3; s=s+1) begin
                    if (grant[grant_owner[s]]) begin
                        slot_addr[s*23 +: 23] <=
                            physical_addr(line_addr[grant_owner[s]*22 +: 22]);
                        slot_rd[s] <= 1'b1;
                        owner[s] <= grant_owner[s];
                        active[s] <= 1'b1;
                        physical_done[s] <= 1'b0;
                        data_done[s] <= 1'b0;
                        if (s == 0) cpu_turn <= !grant_owner[s][0];
                        if (s == 1) gfx_turn <= 2'(grant_owner[s]-2);
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            prog_state <= P_IDLE;
            preload_addr <= 0;
            preload_data <= 0;
            preload_wr <= 0;
            preload_rd <= 0;
            prog_done <= 0;
            write_data <= 0;
            write_be <= 0;
            mirror <= 0;
        end else begin
            preload_wr <= 0;
            preload_rd <= 0;
            prog_done <= 0;
            case (prog_state)
                P_IDLE: if (prog_valid && prog_ready) begin
                    preload_addr <= {prog_pair ? 3'd2 : 3'd0,physical_addr(prog_addr)};
                    write_data <= prog_data;
                    write_be <= prog_be;
                    preload_data <= prog_data;
                    mirror <= 0;
                    prog_state <= prog_be == 0 ? P_FINISH :
                                  prog_be == 2'b11 ? P_WRITE : P_READ;
                end
                P_READ: if (!preload_busy) begin
                    preload_rd <= 1;
                    prog_state <= P_READ_ACCEPT;
                end
                P_READ_ACCEPT: if (preload_busy) prog_state <= P_READ_WAIT;
                P_READ_WAIT: if (!preload_busy) begin
                    preload_data <= {
                        write_be[1] ? write_data[15:8] : preload_result[15:8],
                        write_be[0] ? write_data[7:0] : preload_result[7:0]};
                    prog_state <= P_WRITE;
                end
                P_WRITE: if (!preload_busy) begin
                    preload_wr <= 1;
                    prog_state <= P_WRITE_ACCEPT;
                end
                P_WRITE_ACCEPT: if (preload_busy) prog_state <= P_WRITE_WAIT;
                P_WRITE_WAIT: if (!preload_busy) begin
                    if (!mirror) begin
                        preload_addr[23] <= ~preload_addr[23];
                        mirror <= 1;
                        prog_state <= P_WRITE;
                    end else prog_state <= P_FINISH;
                end
                P_FINISH: begin
                    prog_done <= 1;
                    prog_state <= P_IDLE;
                end
                default: prog_state <= P_IDLE;
            endcase
        end
    end
`ifdef SIMULATION
    always @(posedge clk) if (!reset) begin
        if ((preload_rd || preload_wr) && (!preload_en || preload_busy))
            $fatal(1,"Preload launched without ownership");
        if (|(stream_valid & (stream_valid-1'b1)))
            $fatal(1,"Overlapping IKA data lanes");
        for (integer s=0; s<3; s=s+1) begin
            if (slot_rd[s] && slot_busy[s]) $fatal(1,"Busy IKA slot reused");
            if (slot_first[s] && (!active[s] || |tail[s]))
                $fatal(1,"Unowned or overlapping IKA stream");
            if (slot_done[s] && !active[s]) $fatal(1,"Unowned IKA retirement");
        end
    end
`endif
endmodule

// Batrider SDRAM front end: slots 0/1 over mirrored bank pairs, slots 8/9 on graphics banks.
module raizing_ika_frontend_batrider (
    input clk, reset, init_done,
    input [7:0] line_valid,
    output [7:0] line_ready,
    input [183:0] line_addr,
    output reg [7:0] line_done,
    output reg [63:0] line_data,
    output read_idle,
    output idle,
    output reg [91:0] slot_addr,
    output reg [3:0] slot_rd,
    input [3:0] slot_busy, slot_first, slot_done,
    input [15:0] slot_data,
    input prog_valid,
    output prog_ready,
    input [22:0] prog_addr,
    input prog_gfx,
    input [15:0] prog_data,
    input [1:0] prog_be,
    output reg prog_done,
    output preload_en,
    output reg [25:0] preload_addr,
    output reg [15:0] preload_data,
    output reg preload_wr, preload_rd,
    input preload_busy,
    input [15:0] preload_result
);
    localparam [3:0] P_IDLE=0, P_READ=1, P_READ_ACCEPT=2, P_READ_WAIT=3,
        P_WRITE=4, P_WRITE_ACCEPT=5, P_WRITE_WAIT=6, P_FINISH=7;
    reg [3:0] prog_state;
    reg [3:0] active, physical_done, data_done;
    reg [2:0] owner [0:3];
    reg [2:0] tail [0:3];
    reg [1:0] beat [0:3];
    reg [63:0] assembled [0:3];
    reg cpu_turn, pcm_turn;
    reg [1:0] gfx_turn [0:1];
    wire [7:0] grant;
    wire [2:0] grant_owner [0:3];
    wire [21:0] grant_addr [0:3];
    reg [15:0] write_data;
    reg [1:0] write_be;
    reg mirror, mirror_enable;
    wire [3:0] stream_valid = slot_first | {(|tail[3]),(|tail[2]),(|tail[1]),(|tail[0])};
    wire streams_active = |stream_valid;
    assign read_idle = !(|active || |slot_rd || |slot_busy || streams_active);
    assign idle = read_idle && prog_state == P_IDLE && !preload_busy;
    wire launch = init_done && read_idle && prog_state == P_IDLE && !prog_valid;
    assign line_ready = launch ? grant : 8'd0;
    assign prog_ready = init_done && idle;
    assign preload_en = init_done && read_idle &&
                        (prog_valid || prog_state != P_IDLE);

    function automatic [22:0] physical_addr(input [21:0] logical_addr);
        physical_addr = {logical_addr[21:9],1'b0,logical_addr[8:0]};
    endfunction

    // returns {owner[1:0], one-hot grant[3:0]} for the first eligible lane from turn
    function automatic [5:0] rotate_pick(input [3:0] eligible, input [1:0] turn);
        begin
            rotate_pick = 6'b00_0000;
            case (turn)
                2'd0: if (eligible[0]) rotate_pick = 6'b00_0001;
                      else if (eligible[1]) rotate_pick = 6'b01_0010;
                      else if (eligible[2]) rotate_pick = 6'b10_0100;
                      else if (eligible[3]) rotate_pick = 6'b11_1000;
                2'd1: if (eligible[1]) rotate_pick = 6'b01_0010;
                      else if (eligible[2]) rotate_pick = 6'b10_0100;
                      else if (eligible[3]) rotate_pick = 6'b11_1000;
                      else if (eligible[0]) rotate_pick = 6'b00_0001;
                2'd2: if (eligible[2]) rotate_pick = 6'b10_0100;
                      else if (eligible[3]) rotate_pick = 6'b11_1000;
                      else if (eligible[0]) rotate_pick = 6'b00_0001;
                      else if (eligible[1]) rotate_pick = 6'b01_0010;
                2'd3: if (eligible[3]) rotate_pick = 6'b11_1000;
                      else if (eligible[0]) rotate_pick = 6'b00_0001;
                      else if (eligible[1]) rotate_pick = 6'b01_0010;
                      else if (eligible[2]) rotate_pick = 6'b10_0100;
            endcase
        end
    endfunction

    function automatic [21:0] select_addr(input [183:0] addresses, input [2:0] client_id);
        case (client_id)
            3'd0: select_addr = addresses[21:0];
            3'd1: select_addr = addresses[44:23];
            3'd2: select_addr = addresses[67:46];
            3'd3: select_addr = addresses[90:69];
            3'd4: select_addr = addresses[113:92];
            3'd5: select_addr = addresses[136:115];
            3'd6: select_addr = addresses[159:138];
            3'd7: select_addr = addresses[182:161];
            default: select_addr = 22'd0;
        endcase
    endfunction

    wire [3:0] gfx_banks = {line_addr[183],line_addr[160],line_addr[137],line_addr[114]};
    wire [3:0] gfx_eligible0 = line_valid[7:4] & ~gfx_banks;
    wire [3:0] gfx_eligible1 = line_valid[7:4] & gfx_banks;
    wire [5:0] gfx_pick0 = rotate_pick(gfx_eligible0,gfx_turn[0]);
    wire [5:0] gfx_pick1 = rotate_pick(gfx_eligible1,gfx_turn[1]);
    wire [1:0] cpu_grant = {line_valid[1] && (cpu_turn || !line_valid[0]),
                            line_valid[0] && (!cpu_turn || !line_valid[1])};
    wire [1:0] pcm_grant = {line_valid[3] && (pcm_turn || !line_valid[2]),
                            line_valid[2] && (!pcm_turn || !line_valid[3])};
    wire [3:0] lane_grant = {|gfx_eligible1,|gfx_eligible0,|pcm_grant,|cpu_grant};
    assign grant = {gfx_pick0[3:0] | gfx_pick1[3:0],pcm_grant,cpu_grant};
    assign grant_owner[0] = {2'b00,cpu_grant[1]};
    assign grant_owner[1] = {2'b01,pcm_grant[1]};
    assign grant_owner[2] = {1'b1,gfx_pick0[5:4]};
    assign grant_owner[3] = {1'b1,gfx_pick1[5:4]};
    genvar lane;
    generate for (lane=0; lane<4; lane=lane+1) begin : address_mux
        assign grant_addr[lane] = select_addr(line_addr,grant_owner[lane]);
    end endgenerate

    always @(posedge clk) begin
        if (reset) begin
            active <= 0;
            physical_done <= 0;
            data_done <= 0;
            line_done <= 0;
            slot_addr <= 0;
            slot_rd <= 0;
            cpu_turn <= 0;
            pcm_turn <= 0;
            gfx_turn[0] <= 0;
            gfx_turn[1] <= 0;
            for (integer s=0; s<4; s=s+1) begin
                owner[s] <= 0;
                tail[s] <= 0;
                beat[s] <= 0;
            end
        end else begin
            slot_rd <= 0;
            line_done <= 0;
            for (integer s=0; s<4; s=s+1) begin
                tail[s] <= {tail[s][1:0],slot_first[s]};
                if (slot_done[s]) physical_done[s] <= 1'b1;
                if (slot_first[s]) begin
                    assembled[s][15:0] <= slot_data;
                    beat[s] <= 1;
                end else if (|tail[s]) begin
                    assembled[s][beat[s]*16 +: 16] <= slot_data;
                    beat[s] <= beat[s] + 1'b1;
                    if (tail[s][2]) begin
                        line_data <= {slot_data,assembled[s][47:0]};
                        line_done[owner[s]] <= 1'b1;
                        data_done[s] <= 1'b1;
                    end
                end
                if (active[s] && (physical_done[s] || slot_done[s]) &&
                    (data_done[s] || tail[s][2])) active[s] <= 1'b0;
            end
            if (launch) begin
                for (integer s=0; s<4; s=s+1) begin
                    if (lane_grant[s]) begin
                        slot_addr[s*23 +: 23] <=
                            physical_addr(grant_addr[s]);
                        slot_rd[s] <= 1'b1;
                        owner[s] <= grant_owner[s];
                        active[s] <= 1'b1;
                        physical_done[s] <= 1'b0;
                        data_done[s] <= 1'b0;
                        if (s == 0) cpu_turn <= !grant_owner[s][0];
                        if (s == 1) pcm_turn <= !grant_owner[s][0];
                        if (s >= 2) gfx_turn[s-2] <= grant_owner[s][1:0] + 2'd1;
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            prog_state <= P_IDLE;
            preload_addr <= 0;
            preload_data <= 0;
            preload_wr <= 0;
            preload_rd <= 0;
            prog_done <= 0;
            write_data <= 0;
            write_be <= 0;
            mirror <= 0;
            mirror_enable <= 0;
        end else begin
            preload_wr <= 0;
            preload_rd <= 0;
            prog_done <= 0;
            case (prog_state)
                P_IDLE: if (prog_valid && prog_ready) begin
                    preload_addr <= {prog_gfx ? {2'b01,prog_addr[22]} : 3'd0,
                                     physical_addr(prog_addr[21:0])};
                    write_data <= prog_data;
                    write_be <= prog_be;
                    preload_data <= prog_data;
                    mirror <= 0;
                    mirror_enable <= !prog_gfx;
                    prog_state <= prog_be == 0 ? P_FINISH :
                                  prog_be == 2'b11 ? P_WRITE : P_READ;
                end
                P_READ: if (!preload_busy) begin
                    preload_rd <= 1;
                    prog_state <= P_READ_ACCEPT;
                end
                P_READ_ACCEPT: if (preload_busy) prog_state <= P_READ_WAIT;
                P_READ_WAIT: if (!preload_busy) begin
                    preload_data <= {
                        write_be[1] ? write_data[15:8] : preload_result[15:8],
                        write_be[0] ? write_data[7:0] : preload_result[7:0]};
                    prog_state <= P_WRITE;
                end
                P_WRITE: if (!preload_busy) begin
                    preload_wr <= 1;
                    prog_state <= P_WRITE_ACCEPT;
                end
                P_WRITE_ACCEPT: if (preload_busy) prog_state <= P_WRITE_WAIT;
                P_WRITE_WAIT: if (!preload_busy) begin
                    if (mirror_enable && !mirror) begin
                        preload_addr[23] <= ~preload_addr[23];
                        mirror <= 1;
                        prog_state <= P_WRITE;
                    end else prog_state <= P_FINISH;
                end
                P_FINISH: begin
                    prog_done <= 1;
                    prog_state <= P_IDLE;
                end
                default: prog_state <= P_IDLE;
            endcase
        end
    end
`ifdef SIMULATION
    always @(posedge clk) if (!reset) begin
        if ((preload_rd || preload_wr) && (!preload_en || preload_busy))
            $fatal(1,"Preload launched without ownership");
        if (|(stream_valid & (stream_valid-1'b1)))
            $fatal(1,"Overlapping IKA data lanes");
        if (prog_valid && !prog_gfx && prog_addr[22])
            $fatal(1,"CPU/audio preload exceeds mirrored bank capacity");
        for (integer s=0; s<4; s=s+1) begin
            if (slot_rd[s] && slot_busy[s]) $fatal(1,"Busy IKA slot reused");
            if (slot_first[s] && (!active[s] || |tail[s]))
                $fatal(1,"Unowned or overlapping IKA stream");
            if (slot_done[s] && !active[s]) $fatal(1,"Unowned IKA retirement");
        end
    end
`endif
endmodule
