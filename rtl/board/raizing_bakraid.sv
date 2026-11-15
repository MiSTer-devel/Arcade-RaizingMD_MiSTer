// SPDX-License-Identifier: GPL-3.0-or-later
// Bakraid GPIO, 93C66 EEPROM/NVRAM, YMZ280B sound, ROM profile and audio state modules.

// GPIO: write bits 0/2/3/4 = EEPROM CS/DI/CLK and Z80 bus request; read bit 4 = EEPROM DO, bit 0 = bus ack.
`timescale 1ns/1ps
module rzbak_gpio (
  input  logic        clk,
  input  logic        reset,
  input  logic        write_commit,       // one pulse per admitted write
  input  logic [1:0]  write_lanes,        // [0] = odd/low byte, [1] = high byte
  input  logic [15:0] write_data,
  input  logic        eeprom_do,
  input  logic        sound_bus_ack,
  output logic [15:0] read_data,          // combinational status word
  output logic        eeprom_cs,
  output logic        eeprom_di,
  output logic        eeprom_clk,
  output logic        sound_bus_request,
  input  logic        restore_valid,
  input  logic [3:0]  restore_pins,       // {sound_bus_request, eeprom_clk, eeprom_di, eeprom_cs}
  output logic [3:0]  capture_pins        // the same order
);
  // {sound_bus_request, eeprom_clk, eeprom_di, eeprom_cs}
  logic [3:0] pins_q;

  always_ff @(posedge clk) begin
    if (reset)
      pins_q <= 4'b0000;
    else if (restore_valid)
      pins_q <= restore_pins;
    else if (write_commit && write_lanes[0])
      pins_q <= {write_data[4], write_data[3], write_data[2], write_data[0]};
  end

  assign eeprom_cs         = pins_q[0];
  assign eeprom_di         = pins_q[1];
  assign eeprom_clk        = pins_q[2];
  assign sound_bus_request = pins_q[3];
  assign capture_pins      = pins_q;

  assign read_data = {11'd0, eeprom_do, 3'd0, sound_bus_ack};

  // Ignored write bits: high byte and bits 1, 5-7.
  wire unused_ok = &{1'b0, write_lanes[1], write_data[15:5], write_data[1]};
endmodule

// 93C66 EEPROM: 512x8 Microwire serial model with state and host RAM ports.
module rzbakraid_93c66 #(
    parameter integer PROGRAM_CYCLES=162000,
    parameter integer ERASE_ALL_CYCLES=486000,
    parameter integer WRITE_ALL_CYCLES=1215000
) (
    input clk,reset,
    input serial_cs,serial_clk,serial_di,
    output serial_do,busy,
    output reg modified,
    input hold,
    input state_load,
    input [127:0] state_in,
    output [127:0] state_out,
    output reg restore_done,restore_error,
    input mem_access,mem_we,
    input [8:0] mem_addr,
    input [7:0] mem_data,
    output reg [7:0] mem_q
);
    localparam [2:0] IDLE=0,HEADER=1,READ_DATA=2,WRITE_DATA=3,PROGRAM=4,DONE=5;
    typedef struct packed {
        logic [2:0] phase;
        logic enabled,last_clk;
        logic [10:0] header;
        logic [3:0] remaining;
        logic [8:0] address;
        logic [7:0] read_shift,write_shift,program_data;
        logic [8:0] program_addr;
        logic bulk,pending;
        logic [20:0] timer;
        logic [1:0] prefetch;
        logic [2:0] read_bit;
        logic serial_out;
    } control_t;
    localparam integer CONTROL_BITS=$bits(control_t);
    control_t q;
    wire [10:0] header_next={q.header[9:0],serial_di};
    wire [7:0] data_next={q.write_shift[6:0],serial_di};
    wire rise=serial_clk && !q.last_clk;
    wire programming=q.phase==PROGRAM;
    wire serial_write=programming && q.pending && !hold && !reset;
    wire [8:0] serial_addr=serial_write ? q.program_addr : q.address;
    (* ramstyle = "no_rw_check" *) reg [7:0] memory[0:511];
    reg [7:0] serial_q;
    reg [1:0] restore_settle;
    control_t incoming;
    assign incoming=state_in[CONTROL_BITS-1:0];
    wire incoming_valid=state_in[127:CONTROL_BITS]==0 && incoming.phase<=DONE &&
        (incoming.phase!=HEADER || (incoming.remaining>=1 && incoming.remaining<=11)) &&
        (incoming.phase!=WRITE_DATA || (incoming.remaining>=1 && incoming.remaining<=8)) &&
        (!incoming.pending || incoming.phase==PROGRAM);
    assign state_out={{(128-CONTROL_BITS){1'b0}},q};
    assign busy=programming;
    assign serial_do=!serial_cs ? 1'b1 : programming ? 1'b0 : q.phase==READ_DATA ? q.serial_out : 1'b1;
    initial for(integer a=0;a<512;a=a+1) memory[a]=8'hff;
    always @(posedge clk) begin
        if(serial_write) begin
            memory[serial_addr]<=q.program_data;
            serial_q<=q.program_data;
        end else serial_q<=memory[serial_addr];
    end
    always @(posedge clk) begin
        if(hold && mem_access && mem_we && !reset) begin
            memory[mem_addr]<=mem_data;
            mem_q<=mem_data;
        end else mem_q<=memory[mem_addr];
    end
    always @(posedge clk) begin
        modified<=serial_write;
        restore_done<=0;
        if(reset) begin
            q<='0;restore_settle<=0;restore_error<=0;modified<=0;
        end else begin
            if(restore_settle!=0) begin
                restore_settle<=restore_settle-2'd1;
                if(restore_settle==1) restore_done<=1;
            end
            if(hold) begin
                if(state_load) begin
                    restore_error<=!incoming_valid;
                    if(incoming_valid) q<=incoming;
                    restore_settle<=2;
                end
            end else begin
                q.last_clk<=serial_clk;
                if(q.prefetch!=0) begin
                    q.prefetch<=q.prefetch-2'd1;
                    if(q.prefetch==1) q.read_shift<=serial_q;
                end
                if(programming) begin
                    if(q.pending) begin
                        if(q.bulk && q.program_addr!=9'd511) q.program_addr<=q.program_addr+9'd1;
                        else q.pending<=0;
                    end
                    if(q.timer!=0) q.timer<=q.timer-21'd1;
                    else if(!q.pending) q.phase<=serial_cs ? DONE : IDLE;
                end else if(!serial_cs) begin
                    q.phase<=IDLE;q.prefetch<=0;
                end else case(q.phase)
                    IDLE: if(rise && serial_di) begin
                        q.phase<=HEADER;q.remaining<=11;q.header<=0;
                    end
                    HEADER: if(rise) begin
                        q.header<=header_next;q.remaining<=q.remaining-4'd1;
                        if(q.remaining==1) begin
                            q.address<=header_next[8:0];q.bulk<=0;
                            case(header_next[10:9])
                                2'b10: begin
                                    q.phase<=READ_DATA;q.prefetch<=2;q.read_bit<=7;q.serial_out<=0;
                                end
                                2'b01: begin q.phase<=WRITE_DATA;q.remaining<=8;q.write_shift<=0;end
                                2'b11: begin
                                    q.phase<=DONE;
                                    if(q.enabled) begin
                                        q.phase<=PROGRAM;q.timer<=21'(PROGRAM_CYCLES-1);
                                        q.program_addr<=header_next[8:0];q.program_data<=8'hff;q.pending<=1;
                                    end
                                end
                                2'b00: begin
                                    q.phase<=DONE;
                                    case(header_next[8:7])
                                        2'b00: q.enabled<=0;
                                        2'b11: q.enabled<=1;
                                        2'b01: begin
                                            q.phase<=WRITE_DATA;q.remaining<=8;q.write_shift<=0;q.bulk<=1;
                                        end
                                        2'b10: if(q.enabled) begin
                                            q.phase<=PROGRAM;q.timer<=21'(ERASE_ALL_CYCLES-1);
                                            q.program_addr<=0;q.program_data<=8'hff;q.pending<=1;q.bulk<=1;
                                        end
                                    endcase
                                end
                            endcase
                        end
                    end
                    READ_DATA: if(rise && q.prefetch==0) begin
                        q.serial_out<=q.read_shift[7];q.read_shift<={q.read_shift[6:0],1'b0};
                        q.read_bit<=q.read_bit-3'd1;
                        if(q.read_bit==0) begin q.address<=q.address+9'd1;q.prefetch<=2;q.read_bit<=7;end
                    end
                    WRITE_DATA: if(rise) begin
                        q.write_shift<=data_next;q.remaining<=q.remaining-4'd1;
                        if(q.remaining==1) begin
                            q.phase<=DONE;
                            if(q.enabled) begin
                                q.phase<=PROGRAM;
                                q.timer<=21'((q.bulk ? WRITE_ALL_CYCLES : PROGRAM_CYCLES)-1);
                                q.program_addr<=q.bulk ? 9'd0 : q.address;
                                q.program_data<=data_next;q.pending<=1;
                            end
                        end
                    end
                    default: begin end
                endcase
            end
        end
    end
`ifdef SIMULATION
    initial begin
        if(CONTROL_BITS>128 || PROGRAM_CYCLES<2 || ERASE_ALL_CYCLES<513 || WRITE_ALL_CYCLES<513 ||
           PROGRAM_CYCLES>2097152 || ERASE_ALL_CYCLES>2097152 || WRITE_ALL_CYCLES>2097152)
            $fatal(1,"Invalid 93C66 model parameters");
    end
    always @(posedge clk) if(!reset && !hold && q.phase==READ_DATA && rise && q.prefetch!=0)
        $fatal(1,"93C66 serial clock exceeds synchronous prefetch contract");
`endif
endmodule

// Bakraid NVRAM: ioctl index 2 load/save of the 512-byte EEPROM image.
module rzbakraid_nvram #(
    parameter integer WAIT_CYCLES = 2097152
) (
    input clk, reset,
    input manual_save, autosave, osd_open,
    input ioctl_download, ioctl_upload,
    input [15:0] ioctl_index,
    input [26:0] ioctl_addr,
    input ioctl_wr, ioctl_rd,
    input [7:0] ioctl_dout,
    output ioctl_wait,
    output [7:0] ioctl_din,
    output ioctl_upload_req,
    output [7:0] ioctl_upload_index,
    input cpu_hold_ack, state_pending, state_active, state_restored,
    input ee_busy, ee_modified,
    input [7:0] ee_mem_q,
    output cpu_hold_req, ee_hold, state_block,
    output ee_mem_access, ee_mem_we,
    output [8:0] ee_mem_addr,
    output [7:0] ee_mem_data,
    output ee_protocol_reset, cpu_restart, restart_window,
    output reg dirty = 0,
    output reg snapshot_ready = 0,
    output reg load_done = 0, save_done = 0,
    output reg transfer_error = 0, timeout_error = 0
);
    localparam [3:0] IDLE=0, DRAIN=1, PROGRAM_WAIT=2, CAP_ISSUE=3,
        CAP_SETTLE=4, CAP_STORE=5, COMMIT=6, RESTART=7, PUBLISH=8,
        LOAD_ISSUE=9;
    reg [3:0] op = IDLE;
    reg loading = 0;
    reg [8:0] copy_addr = 0;
    reg [31:0] wait_count = 0;
    reg save_pending = 0, release_load = 0;
    reg manual_old = 0, osd_old = 0;
    reg download_old = 0, upload_old = 0;
    reg [63:0] generation = 0, snapshot_generation = 0;

    (* ramstyle = "no_rw_check" *) reg [7:0] load_buffer [0:511];
    (* ramstyle = "no_rw_check" *) reg [7:0] snapshot_buffer [0:511];
    reg [7:0] load_q;
    reg rx_active = 0, rx_bad = 0, rx_deferred = 0;
    reg [9:0] rx_count = 0;
    reg load_pending = 0;
    reg load_save_conflict = 0;
    reg tx_active = 0, tx_bad = 0, tx_capture = 0;
    reg [9:0] tx_count = 0;
    reg [7:0] snapshot_q;
    reg [8:0] snapshot_q_addr = 0;
    reg snapshot_q_valid = 0;

    wire index_ok = ioctl_index == 16'd2;
    wire state_wants = state_pending || state_active;
    wire modification = ee_modified || state_restored;
    wire critical = op==CAP_ISSUE || op==CAP_SETTLE || op==CAP_STORE ||
                    op==COMMIT || op==LOAD_ISSUE || op==RESTART;
    wire committing = op==LOAD_ISSUE || op==COMMIT || op==RESTART;
    wire download_start = ioctl_download && !download_old;
    wire upload_start = ioctl_upload && !upload_old;
    wire rx_end = rx_active && !ioctl_download;
    wire rx_valid_end = rx_end && !rx_bad && !rx_deferred &&
                        rx_count==10'd512 && index_ok && !reset;
    wire tx_end = tx_active && !ioctl_upload;
    wire tx_valid_end = tx_end && !tx_bad && snapshot_ready && tx_count==10'd512 &&
                        index_ok && !ioctl_download && !reset;
    wire [9:0] tx_next = tx_count + 10'd1;
    wire deferred_wait = ioctl_download && index_ok &&
        ((download_start && load_pending) || (rx_active && rx_deferred));
    wire host_capture_start = upload_start && index_ok && !snapshot_ready &&
        !ioctl_download;
    wire cancel_capture = tx_capture && !snapshot_ready &&
        (!ioctl_upload || !index_ok || ioctl_download);
    wire upload_wait = ioctl_upload && index_ok &&
        ((upload_start && !ioctl_download) ||
         (tx_active && tx_capture && !snapshot_ready && !ioctl_download) ||
         (tx_active && snapshot_ready &&
          (reset || !snapshot_q_valid || snapshot_q_addr!=tx_count[8:0])));
    wire save_edge = (manual_save && !manual_old) ||
                     (autosave && osd_open && !osd_old && dirty);

    assign ioctl_upload_index = 8'd2;
    assign ioctl_upload_req = snapshot_ready && !tx_active;
    assign ioctl_wait = deferred_wait || upload_wait;
    assign ioctl_din = snapshot_ready ? snapshot_q : 8'hff;
    assign cpu_hold_req = critical ||
        ((op==DRAIN || op==PROGRAM_WAIT) && !state_wants && !reset);
    assign ee_hold = critical;
    assign state_block = critical;
    assign ee_mem_access = !reset && (op==COMMIT || op==CAP_ISSUE ||
                                      op==CAP_SETTLE || op==CAP_STORE);
    assign ee_mem_we = !reset && op==COMMIT;
    assign ee_mem_addr = copy_addr;
    assign ee_mem_data = load_q;
    assign ee_protocol_reset = op==RESTART && !reset;
    assign cpu_restart = ee_protocol_reset;

    reg [7:0] restart_tail = 0;
    reg restart_window_q = 1'b0;
    assign restart_window = restart_window_q;
    wire restart_next = (op == COMMIT && !reset && copy_addr == 9'd511) ||
                        (op == RESTART && reset);
    always @(posedge clk) begin
        if (reset) restart_tail <= 0;
        else if (cpu_restart) restart_tail <= 8'hff;
        else if (restart_tail != 0) restart_tail <= restart_tail - 8'd1;
        // Window: commit end, reset held in RESTART, cpu_restart and its tail.
        restart_window_q <= restart_next || (!reset && (cpu_restart || restart_tail > 8'd1));
    end

    // Snapshot port reads byte tx_count; the first HPS read primes it without advancing the count.
    always @(posedge clk) begin
        load_q <= load_buffer[copy_addr];
        snapshot_q <= snapshot_buffer[tx_count[8:0]];
        snapshot_q_addr <= tx_count[8:0];
        snapshot_q_valid <= 1;
        if(op==CAP_STORE && !reset) snapshot_buffer[copy_addr] <= ee_mem_q;
    end

    always @(posedge clk) begin
        download_old <= ioctl_download;
        upload_old <= ioctl_upload;
        manual_old <= manual_save;
        osd_old <= osd_open;
        transfer_error <= 0;
        timeout_error <= 0;
        load_done <= 0;
        save_done <= 0;
        release_load <= 0;

        if(modification) begin
            generation <= generation + 64'd1;
            dirty <= 1;
        end

        // A transfer starts on the ioctl_download edge with index 2.
        if(download_start && index_ok) begin
            rx_active <= 1;
            rx_bad <= reset || ioctl_upload;
            rx_deferred <= load_pending;
            if(!load_pending) begin
                rx_count <= 0;
                if(ioctl_wr && !reset && !ioctl_upload) begin
                    if(ioctl_addr==0) begin
                        load_buffer[0] <= ioctl_dout;
                        rx_count <= 1;
                    end else rx_bad <= 1;
                end
            end
        end else if(rx_active && ioctl_download) begin
            if(!index_ok || ioctl_upload || reset) rx_bad <= 1;
            if(rx_deferred) begin
                // A deferred download waits until the prior load releases its image.

                if(!load_pending) begin
                    rx_deferred <= 0;
                    rx_count <= 0;
                end
            end else if(ioctl_wr && !rx_bad && index_ok && !reset) begin
                if(rx_count<512 && ioctl_addr=={17'd0,rx_count}) begin
                    load_buffer[rx_count[8:0]] <= ioctl_dout;
                    rx_count <= rx_count + 10'd1;
                end else rx_bad <= 1;
            end
        end
        if(rx_end) begin
            rx_active <= 0;
            rx_deferred <= 0;
            if(rx_valid_end) load_pending <= 1;
            else transfer_error <= 1;
        end
        if(release_load) load_pending <= 0;
        // Records an upload that replaces the host file while a new load is still pending.

        if(rx_valid_end) load_save_conflict <= tx_valid_end;
        else if(tx_valid_end && load_pending) load_save_conflict <= 1;

        if(upload_start) begin
            if(index_ok) begin
                tx_active <= 1;
                tx_bad <= ioctl_addr!=0 || ioctl_download || reset;
                tx_count <= 0;
                tx_capture <= host_capture_start;
                // A host-initiated index-2 upload adopts an active capture or queues one behind the load.

                if(host_capture_start && (op==IDLE || loading)) save_pending <= 1;
            end
        end else if(tx_active && ioctl_upload) begin
            if(!index_ok || ioctl_download || reset) tx_bad <= 1;
            // Well-formed read pulses can advance the reader even after the stream is marked invalid.

            if(ioctl_rd && index_ok && !reset) begin
                if(snapshot_ready && tx_count<512 && ioctl_addr=={17'd0,tx_next} &&
                   snapshot_q_valid && snapshot_q_addr==tx_count[8:0])
                    tx_count <= tx_count + 10'd1;
                else tx_bad <= 1;
            end
        end
        if(tx_end) begin
            tx_active <= 0;
            tx_capture <= 0;
            snapshot_ready <= 0;
            tx_count <= 0;
            if(tx_valid_end) begin
                save_done <= 1;
                dirty <= generation!=snapshot_generation || modification;
            end else transfer_error <= 1;
        end

        if(save_edge && !tx_active && !(upload_start && index_ok) &&
           !snapshot_ready && !save_pending &&
           !(op!=IDLE && !loading) && !reset) save_pending <= 1;

        // Requeues a live host capture when reset or cancellation has left no snapshot ready.

        if(tx_capture && tx_active && ioctl_upload && index_ok &&
           !ioctl_download && !snapshot_ready && op==IDLE && !reset)
            save_pending <= 1;
        if(cancel_capture) begin
            save_pending <= 0;
            tx_capture <= 0;
        end

        if(reset && !committing) begin
            op <= IDLE;
            save_pending <= 0;
            wait_count <= 0;
            if(load_pending) release_load <= 1;
            if(rx_active) rx_bad <= 1;
            if(tx_active) tx_bad <= 1;
        end else if(cancel_capture && !committing && (op==IDLE || !loading)) begin
            // Cancel an abandoned host capture.

            op <= IDLE;
            wait_count <= 0;
        end else case(op)
            IDLE: begin
                wait_count <= 0;
                if(load_pending && !release_load) begin
                    loading <= 1;
                    op <= DRAIN;
                end else if(save_pending && !snapshot_ready) begin
                    loading <= 0;
                    save_pending <= 0;
                    op <= DRAIN;
                end
            end
            DRAIN, PROGRAM_WAIT: begin
                if(wait_count>=WAIT_CYCLES-1) begin
                    op <= IDLE;
                    timeout_error <= 1;
                    if(loading) release_load <= 1;
                    // Timeout: release a pending load, or requeue a live host capture.

                    else if(tx_capture || host_capture_start) save_pending <= 1;
                end else begin
                    wait_count <= wait_count + 32'd1;
                    if(state_wants || !cpu_hold_ack) op <= DRAIN;
                    else if(ee_busy) op <= PROGRAM_WAIT;
                    else begin
                        copy_addr <= 0;
                        if(loading) op <= LOAD_ISSUE;
                        else begin
                            snapshot_generation <= generation + (modification ? 64'd1 : 64'd0);
                            op <= CAP_ISSUE;
                        end
                    end
                end
            end
            CAP_ISSUE: op <= CAP_SETTLE;
            CAP_SETTLE: op <= CAP_STORE;
            CAP_STORE: begin
                if(copy_addr==511) op <= PUBLISH;
                else begin
                    copy_addr <= copy_addr + 9'd1;
                    op <= CAP_ISSUE;
                end
            end
            LOAD_ISSUE: begin
                if(reset) copy_addr <= 0;
                else op <= COMMIT;
            end
            COMMIT: begin
                // Reset restarts an accepted EEPROM commit at byte zero without releasing ownership.

                if(reset) begin copy_addr <= 0;op <= LOAD_ISSUE;end
                else if(copy_addr==511) op <= RESTART;
                else begin copy_addr <= copy_addr + 9'd1;op <= LOAD_ISSUE;end
            end
            RESTART: if(!reset) begin
                load_done <= 1;
                generation <= generation + 64'd1;
                dirty <= modification || load_save_conflict || tx_valid_end;
                release_load <= 1;
                op <= IDLE;
            end
            PUBLISH: begin
                snapshot_ready <= 1;
                op <= IDLE;
            end
            default: op <= IDLE;
        endcase
    end
`ifdef SIMULATION
    initial if(WAIT_CYCLES<2) $fatal(1,"Invalid NVRAM wait bound");
    always @(posedge clk) begin
        if(ee_mem_we && (!ee_hold || reset || ee_protocol_reset))
            $fatal(1,"NVRAM RAM write without exclusive live ownership");
        if(critical && (state_active || !cpu_hold_ack))
            $fatal(1,"Parent violated NVRAM ownership grant");
    end
`endif
endmodule

// Bakraid EEPROM owner: serial 93C66, host NVRAM and save-state chunks 36/37.
module rzbakraid_eeprom (
    input clk,platform_reset,cpu_reset,cpu_hold_ack,
    input serial_cs,serial_clk,serial_di,
    output serial_do,
    input state_pending,state_active,state_access_enable,state_restore_commit,
    output state_block,restore_busy,state_fault,
    output cpu_hold_req,cpu_restart,restart_window,
    input manual_save,autosave,osd_open,
    input ioctl_download,ioctl_upload,
    input [15:0] ioctl_index,
    input [26:0] ioctl_addr,
    input ioctl_wr,ioctl_rd,
    input [7:0] ioctl_dout,
    output ioctl_wait,
    output [7:0] ioctl_din,
    output ioctl_upload_req,
    output [7:0] ioctl_upload_index,
    output dirty,transfer_error,timeout_error,
    input [63:0] SS_DATA,
    input [31:0] SS_ADDR,
    input [7:0] SS_SELECT,
    input SS_WRITE,SS_READ,SS_QUERY,
    output [63:0] SS_DATA_OUT,
    output SS_ACK
);
    reg previous_cpu_reset,state_owned,restore_pending,restore_fault,control_staged;
    wire ee_busy,ee_modified,nv_hold,nv_access,nv_we,nv_protocol_reset;
    wire [8:0] nv_addr;
    wire [7:0] nv_data,mem_q;
    wire [127:0] control_capture,control_restore;
    wire control_we,leaf_restore_done,leaf_restore_error;
    wire ram_active,ram_we;
    wire [8:0] ram_addr;
    wire [7:0] ram_data;
    wire [1:0] response_ack;
    wire [127:0] response_data;
    wire grant=state_owned && state_active && state_access_enable && !nv_hold;
    wire protocol_reset=platform_reset || nv_protocol_reset ||
        (cpu_reset && !previous_cpu_reset && !nv_hold && !state_active);
    wire apply_control=state_restore_commit && state_owned && state_active && !nv_hold && control_staged;
    assign restore_busy=restore_pending;
    assign state_fault=restore_fault;

    always @(posedge clk) begin
        previous_cpu_reset<=cpu_reset;
        if(platform_reset) begin
            previous_cpu_reset<=cpu_reset;state_owned<=0;restore_pending<=0;
            restore_fault<=0;control_staged<=0;
        end else begin
            if(!state_active) begin state_owned<=0;control_staged<=0;end
            else if(cpu_hold_ack && !state_block) state_owned<=1;
            if(control_we && grant) control_staged<=1;
            if(state_restore_commit) begin
                if(apply_control) begin restore_pending<=1;restore_fault<=0;end
                else restore_fault<=1;
            end
            if(leaf_restore_done && restore_pending) begin
                restore_pending<=0;restore_fault<=leaf_restore_error;
            end
        end
    end
    rzbakraid_93c66 leaf(
        .clk(clk),.reset(protocol_reset),.serial_cs(serial_cs),.serial_clk(serial_clk),.serial_di(serial_di),
        .serial_do(serial_do),.busy(ee_busy),.modified(ee_modified),.hold(nv_hold || state_owned),
        .state_load(apply_control),.state_in(control_restore),.state_out(control_capture),
        .restore_done(leaf_restore_done),.restore_error(leaf_restore_error),
        .mem_access(nv_hold ? nv_access : grant && ram_active),
        .mem_we(nv_hold ? nv_we : grant && ram_active && ram_we),
        .mem_addr(nv_hold ? nv_addr : ram_addr),.mem_data(nv_hold ? nv_data : ram_data),.mem_q(mem_q));
    rzbakraid_nvram nvram(
        .clk(clk),.reset(platform_reset),.manual_save(manual_save),.autosave(autosave),.osd_open(osd_open),
        .ioctl_download(ioctl_download),.ioctl_upload(ioctl_upload),.ioctl_index(ioctl_index),
        .ioctl_addr(ioctl_addr),.ioctl_wr(ioctl_wr),.ioctl_rd(ioctl_rd),.ioctl_dout(ioctl_dout),
        .ioctl_wait(ioctl_wait),.ioctl_din(ioctl_din),.ioctl_upload_req(ioctl_upload_req),
        .ioctl_upload_index(ioctl_upload_index),.cpu_hold_ack(cpu_hold_ack || cpu_reset),
        .state_pending(state_pending),.state_active(state_active),
        .state_restored(leaf_restore_done && restore_pending && !leaf_restore_error),
        .ee_busy(ee_busy),.ee_modified(ee_modified),.ee_mem_q(mem_q),.cpu_hold_req(cpu_hold_req),
        .ee_hold(nv_hold),.state_block(state_block),.ee_mem_access(nv_access),.ee_mem_we(nv_we),
        .ee_mem_addr(nv_addr),.ee_mem_data(nv_data),.ee_protocol_reset(nv_protocol_reset),
        .cpu_restart(cpu_restart),.restart_window(restart_window),.dirty(dirty),.snapshot_ready(),.load_done(),.save_done(),
        .transfer_error(transfer_error),.timeout_error(timeout_error));
    raizing_ss_wide_register #(.WIDTH(128),.SS_INDEX(36)) control_state(
        .clk(clk),.reset(platform_reset),.capture_data(control_capture),.restore_data(control_restore),
        .restore_we(control_we),.ss_data(SS_DATA),.ss_addr(SS_ADDR),.ss_select(SS_SELECT),
        .ss_write(SS_WRITE && grant),.ss_read(SS_READ && grant),.ss_query(SS_QUERY),
        .ss_data_out(response_data[0+:64]),.ss_ack(response_ack[0]));
    raizing_ss_ram_adapter #(.WIDTH(8),.ADDR_WIDTH(9),.SS_INDEX(37)) memory_state(
        .clk(clk),.reset(platform_reset),.ss_data(SS_DATA),.ss_addr(SS_ADDR),.ss_select(SS_SELECT),
        .ss_write(SS_WRITE && grant),.ss_read(SS_READ && grant),.ss_query(SS_QUERY),
        .ss_data_out(response_data[64+:64]),.ss_ack(response_ack[1]),
        .ram_active(ram_active),.ram_addr(ram_addr),.ram_data(ram_data),.ram_we(ram_we),.ram_q(mem_q));
    raizing_ss_response_mux #(.COUNT(2)) response(
        .ack(response_ack),.data(response_data),.ack_out(SS_ACK),.data_out(SS_DATA_OUT));
`ifdef SIMULATION
    always @(posedge clk) if(!platform_reset) begin
        if(state_owned && nv_hold) $fatal(1,"EEPROM state and NVRAM owners overlap");
        if(grant && !cpu_hold_ack && !cpu_reset) $fatal(1,"EEPROM state owner lost CPU hold");
        if(nv_access && state_active) $fatal(1,"EEPROM NVRAM access during state");
    end
`endif
endmodule

// Holds one ROM request through its response; a cancel discards the result.
module rzbakraid_sound_rom_port #(parameter AW=24)(
    input clk,reset,start,cancel,
    input [AW-1:0] address,
    output reg busy,done,
    output reg [7:0] data,
    output request,
    output reg [AW-1:0] request_address,
    input accept,valid,
    input [7:0] response_data
);
    reg accepted,discard;
    assign request=busy;
    always @(posedge clk) begin
        done<=0;
        if(reset) begin
            busy<=0; accepted<=0; discard<=0; data<=0; request_address<=0;
        end else if(busy) begin
            if(cancel) discard<=1;
            if(accept) accepted<=1;
            if(valid && (accepted || accept)) begin
                busy<=0; accepted<=0;
                if(!discard && !cancel) begin data<=response_data; done<=1; end
            end
        end else if(start && !cancel) begin
            busy<=1; accepted<=0; discard<=0; request_address<=address;
        end
    end
endmodule

// YMZ280B: eight ADPCM voices, CPU port, PCM ROM fetch and save-state words.
module rzbakraid_ymz (
    input  logic clk, reset, ymz_ce, sample_ce, hold_request,
    output logic held, idle,
    input  logic cpu_valid, cpu_write, cpu_a0,
    input  logic [7:0] cpu_data,
    output logic cpu_ready, cpu_done,
    output logic [7:0] cpu_dout,
    output logic irq,
    output logic pcm_request,
    output logic [23:0] pcm_address,
    input  logic pcm_accept, pcm_valid,
    input  logic [7:0] pcm_data,
    output logic signed [15:0] left, right,
    output logic sample, deadline_fault,
    input  logic [5:0] state_address,
    input  logic [63:0] state_data,
    input  logic state_write,
    output logic [63:0] state_q
);
    typedef struct packed {
        logic checkpoint, playing;
        logic [9:0] phase;
        logic signed [15:0] cur, prev;
        logic [15:0] loop_step;
        logic signed [15:0] loop_predictor;
        logic [15:0] step;
        logic signed [15:0] predictor;
        logic [24:0] pos;
    } voice_t;
    localparam voice_t QUIET = {2'b00, 10'd512, 32'b0, 16'd127,
                                16'b0, 16'd127, 16'b0, 25'b0};

    // State words: 0-31 registers, 32-55 voices (3 words each), 56-58 port and output latches.
    logic [63:0] regs [0:31];
    logic [132:0] voices [0:7];
    logic [7:0] selector, status, read_latch;
    logic [23:0] read_ptr;
    logic signed [15:0] pending_l, pending_r;

    typedef enum logic [3:0] {IDLE, LOAD, STEP, BYTE_LO, BYTE_HI, DECODE,
                              INTERP, MIX, FINISH, CPU_PREFETCH, CPU_REFILL} stage_t;
    stage_t stage;
    logic [2:0] channel;
    voice_t work, decoded, keyed_voice;
    logic [1:0] mode;
    logic looping;
    logic [9:0] phase_inc;
    logic [24:0] loop_start, loop_end, stop_at;
    logic [7:0] gain_l, gain_r, lo_byte, hi_byte, old_latch;
    logic [23:0] byte_addr;
    logic accepted, wait_byte, byte_done;
    logic [7:0] byte_value;
    logic signed [17:0] sum_l, sum_r;
    logic signed [15:0] interpolated;

    logic [7:0] load_ctrl, load_pitch, load_level;
    logic [3:0] load_pan;
    logic [7:0] next_ctrl;
    logic [2:0] ctrl_voice, state_voice;
    logic [1:0] state_part;
    logic [4:0] state_offset;
    logic [24:0] key_start, key_loop_start;
    logic [23:0] new_ptr;

    function automatic logic [7:0] reg_byte(input logic [7:0] index);
        return regs[index[7:3]][{index[2:0], 3'b000} +: 8];
    endfunction

    function automatic logic [24:0] voice_addr(input logic [2:0] v, input logic [1:0] k);
        return {reg_byte({3'b001,v,k}), reg_byte({3'b010,v,k}),
                reg_byte({3'b011,v,k}), 1'b0};
    endfunction

    function automatic logic signed [15:0] clip16(input logic signed [17:0] x);
        if (x > 18'sd32767) return 16'sh7fff;
        if (x < -18'sd32768) return 16'sh8000;
        return x[15:0];
    endfunction

    function automatic logic [7:0] reduced_gain(input logic [7:0] level,
                                                input logic [2:0] factor);
        logic [10:0] product;
        logic [21:0] scaled;
        // floor(level * factor / 7) as (product * 2341) >> 14, exact for 0..1785.
        product = level * factor;
        scaled = product * 22'd2341;
        return scaled[21:14];
    endfunction

    function automatic logic signed [15:0] decay(input logic signed [15:0] x);
        logic signed [19:0] product;
        product = x * 20'sd15;
        if (product < 0) product = product + 20'sd15;
        return 16'(product >>> 4);
    endfunction

    function automatic logic signed [15:0] lerp(input logic signed [15:0] cur, prev_sample, input logic [9:0] phase);
        logic signed [16:0] span;
        logic signed [25:0] product;
        span = $signed({cur[15],cur}) - $signed({prev_sample[15],prev_sample});
        product = span * $signed({1'b0,phase[8:0]});
        return prev_sample + 16'(product >>> 9);
    endfunction

    function automatic logic signed [17:0] weighted(input logic signed [15:0] x,
                                                     input logic [7:0] gain);
        logic signed [23:0] product;
        product = x * $signed({1'b0,gain});
        return 18'(product >>> 9);
    endfunction

    always_comb begin : decode_sample
        logic [3:0] n;
        logic signed [4:0] odd;
        logic [9:0] scale;
        logic signed [19:0] difference;
        logic signed [17:0] amplitude;
        logic [25:0] scaled_step;
        logic [17:0] step_next;
        decoded = work;
        n = work.pos[0] ? lo_byte[3:0] : lo_byte[7:4];
        odd = $signed({1'b0,n[2:0],1'b1});
        if (n[3]) odd = -odd;
        case (n[2:0])
            3'd4: scale = 10'd307;
            3'd5: scale = 10'd409;
            3'd6: scale = 10'd512;
            3'd7: scale = 10'd614;
            default: scale = 10'd230;
        endcase
        difference = odd * $signed({1'b0,work.step});
        amplitude = 18'(work.predictor) + 18'(difference >>> 3);
        scaled_step = work.step * scale;
        step_next = scaled_step[25:8];
        case (mode)
            2'd1: begin
                decoded.cur = clip16(amplitude);
                if (step_next < 18'd127) decoded.step = 16'd127;
                else if (step_next > 18'd24576) decoded.step = 16'd24576;
                else decoded.step = step_next[15:0];
                decoded.pos = work.pos + 25'd1;
            end
            2'd2: begin
                decoded.cur = {lo_byte,8'b0};
                decoded.pos = work.pos + 25'd2;
            end
            default: begin
                decoded.cur = {hi_byte,lo_byte};
                decoded.pos = work.pos + 25'd4;
            end
        endcase
        decoded.predictor = decoded.cur;
        if (looping) begin
            if (mode == 2'd1 && !work.checkpoint && decoded.pos == loop_start) begin
                decoded.checkpoint = 1'b1;
                decoded.loop_predictor = decoded.predictor;
                decoded.loop_step = decoded.step;
            end
            if (decoded.pos >= loop_end) begin
                decoded.pos = loop_start;
                decoded.checkpoint = 1'b1;
                if (mode == 2'd1) begin
                    decoded.predictor = decoded.loop_predictor;
                    decoded.step = decoded.loop_step;
                end
            end
        end
        decoded.playing = decoded.pos < stop_at;
    end

    always_comb begin
        {load_pitch, load_ctrl, load_level, load_pan} =
            {reg_byte({3'b000,channel,2'd0}), reg_byte({3'b000,channel,2'd1}),
             reg_byte({3'b000,channel,2'd2}), 4'(reg_byte({3'b000,channel,2'd3}))};
        ctrl_voice = selector[4:2];
        next_ctrl = cpu_data;
        if (cpu_data[6:5] == 2'b00) begin
            next_ctrl[7] = 1'b0;
            next_ctrl[6:5] = regs[selector[7:3]][{selector[2:0],3'b000}+5 +: 2];
        end
        key_start = voice_addr(ctrl_voice, 2'd0);
        key_loop_start = voice_addr(ctrl_voice, 2'd1);
        keyed_voice = QUIET;
        keyed_voice.pos = key_start;
        keyed_voice.playing = 1'b1;
        keyed_voice.checkpoint = next_ctrl[6:5] == 2'd1 && next_ctrl[4] &&
                                 key_start == key_loop_start;
    end

    assign new_ptr = {regs[16][39:32],regs[16][47:40],cpu_data};
    assign held = !reset && hold_request && stage == IDLE;
    assign idle = !reset && stage == IDLE;
    // No hold term: CPU accesses occur only in Z80 I/O cycles, never while held.
    assign cpu_ready = !reset && stage == IDLE && ymz_ce && !sample_ce;
    assign irq = regs[31][60] && |(regs[31][55:48] & status);
    assign wait_byte = stage == BYTE_LO || stage == BYTE_HI ||
                       stage == CPU_PREFETCH || stage == CPU_REFILL;
    assign pcm_address = byte_addr;
    assign pcm_request = !reset && wait_byte && byte_addr < 24'hc00000;
    assign byte_done = wait_byte && (!pcm_request || (pcm_valid && (accepted || pcm_accept)));
    assign byte_value = pcm_request ? pcm_data : 8'b0;

    assign state_offset = state_address[4:0];
    assign state_voice = 3'(state_offset / 5'd3);
    assign state_part = 2'(state_offset % 5'd3);
    always_comb begin
        state_q = 64'b0;
        if (state_address < 6'd32) state_q = regs[state_address[4:0]];
        else if (state_address < 6'd56) begin
            case (state_part)
                2'd0: state_q = voices[state_voice][63:0];
                2'd1: state_q = voices[state_voice][127:64];
                default: state_q = {59'b0, voices[state_voice][132:128]};
            endcase
        end else case (state_address)
            6'd56: state_q = {16'b0, read_ptr, read_latch, status, selector};
            6'd57: state_q = {23'b0, deadline_fault, cpu_dout, left, right};
            6'd58: state_q = {32'b0, pending_l, pending_r};
            default: ;
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            for (int i = 0; i < 32; i++) regs[i] <= 0;
            for (int i = 0; i < 8; i++) voices[i] <= QUIET;
            stage <= IDLE;
            accepted <= 0;
            selector <= 0;
            status <= 0;
            read_latch <= 0;
            read_ptr <= 0;
            cpu_done <= 0;
            cpu_dout <= 0;
            left <= 0;
            right <= 0;
            pending_l <= 0;
            pending_r <= 0;
            sample <= 0;
            deadline_fault <= 0;
        end else begin
            cpu_done <= 0;
            sample <= 0;

            if (sample_ce && !hold_request) begin
                if (!ymz_ce || stage != IDLE) deadline_fault <= 1'b1;
                if (ymz_ce) begin
                    left <= pending_l;
                    right <= pending_r;
                    sample <= 1'b1;
                end
            end

            if (pcm_request && pcm_accept) accepted <= 1'b1;
            if (byte_done) accepted <= 1'b0;

            case (stage)
                IDLE: begin
                    // state_write occurs only while the Z80 is held.
                    if (state_write) begin
                        if (state_address < 6'd32) regs[state_address[4:0]] <= state_data;
                        else if (state_address < 6'd56) begin
                            case (state_part)
                                2'd0: voices[state_voice][63:0] <= state_data;
                                2'd1: voices[state_voice][127:64] <= state_data;
                                default: voices[state_voice][132:128] <= state_data[4:0];
                            endcase
                        end else case (state_address)
                            6'd56: {read_ptr, read_latch, status, selector} <= state_data[47:0];
                            6'd57: {deadline_fault, cpu_dout, left, right} <= state_data[40:0];
                            6'd58: {pending_l, pending_r} <= state_data[31:0];
                            default: ;
                        endcase
                    end else if (cpu_ready && cpu_valid) begin
                        // Exclusive with sample output: cpu_ready requires !sample_ce.
                        cpu_done <= 1'b1;
                        if (!cpu_write) begin
                            if (cpu_a0) begin
                                cpu_dout <= status;
                                status <= 0;
                            end else if (!regs[31][62]) cpu_dout <= 8'hff;
                            else begin
                                old_latch <= read_latch;
                                read_ptr <= read_ptr + 24'd1;
                                byte_addr <= read_ptr + 24'd1;
                                stage <= CPU_REFILL;
                                cpu_done <= 1'b0;
                            end
                        end else if (!cpu_a0) selector <= cpu_data;
                        else if (selector < 8'h20 && selector[1:0] == 2'd1) begin
                            regs[selector[7:3]][{selector[2:0],3'b000} +: 8] <= next_ctrl;
                            if (!next_ctrl[7]) voices[ctrl_voice][131] <= 1'b0;
                            else if (!regs[selector[7:3]][{selector[2:0],3'b000}+7] &&
                                     regs[31][63]) voices[ctrl_voice] <= keyed_voice;
                        end else begin
                            regs[selector[7:3]][{selector[2:0],3'b000} +: 8] <= cpu_data;
                            if (selector == 8'hff) begin
                                for (int v = 0; v < 8; v++) begin
                                    if (!cpu_data[7]) voices[v][131] <= 1'b0;
                                    else if (!regs[31][63] &&
                                             regs[v/2][32*(v%2)+15] && regs[v/2][32*(v%2)+12])
                                        voices[v][131] <= 1'b1;
                                end
                            end else if (selector == 8'h86) begin
                                read_ptr <= new_ptr;
                                if (regs[31][62]) begin
                                    byte_addr <= new_ptr;
                                    stage <= CPU_PREFETCH;
                                    cpu_done <= 1'b0;
                                end
                            end
                        end
                    end else if (!hold_request && sample_ce && ymz_ce) begin
                        channel <= 0;
                        sum_l <= 0;
                        sum_r <= 0;
                        stage <= LOAD;
                    end
                end
                CPU_PREFETCH, CPU_REFILL: if (byte_done) begin
                    read_latch <= byte_value;
                    if (stage == CPU_REFILL) cpu_dout <= old_latch;
                    cpu_done <= 1'b1;
                    stage <= IDLE;
                end
                LOAD: begin
                    work <= voices[channel];
                    mode <= load_ctrl[6:5];
                    looping <= load_ctrl[7] && load_ctrl[4];
                    phase_inc <= {1'b0,load_ctrl[0] && load_ctrl[6],load_pitch} + 10'd1;
                    loop_start <= voice_addr(channel, 2'd1);
                    loop_end <= voice_addr(channel, 2'd2);
                    stop_at <= voice_addr(channel, 2'd3);
                    gain_l <= load_pan <= 4'd8 ? load_level : reduced_gain(load_level, 3'd7-load_pan[2:0]);
                    gain_r <= load_pan >= 4'd8 ? load_level :
                              load_pan <= 4'd1 ? 8'd0 : reduced_gain(load_level, load_pan[2:0]-3'd1);
                    stage <= STEP;
                end
                STEP: begin
                    stage <= INTERP;
                    if (work.phase[9]) begin
                        work.phase[9] <= 1'b0;
                        work.prev <= work.cur;
                        if (work.playing) begin
                            byte_addr <= work.pos[24:1];
                            stage <= BYTE_LO;
                        end else work.cur <= decay(work.cur);
                    end
                end
                BYTE_LO: if (byte_done) begin
                    lo_byte <= byte_value;
                    if (mode == 2'd3) begin
                        byte_addr <= byte_addr + 24'd1;
                        stage <= BYTE_HI;
                    end else stage <= DECODE;
                end
                BYTE_HI: if (byte_done) begin
                    hi_byte <= byte_value;
                    stage <= DECODE;
                end
                DECODE: begin
                    work <= decoded;
                    if (!decoded.playing) status[channel] <= 1'b1;
                    stage <= INTERP;
                end
                INTERP: begin
                    interpolated <= lerp(work.cur, work.prev, work.phase);
                    work.phase <= work.phase + phase_inc;
                    stage <= MIX;
                end
                MIX: begin
                    voices[channel] <= work;
                    sum_l <= sum_l + weighted(interpolated, gain_l);
                    sum_r <= sum_r + weighted(interpolated, gain_r);
                    channel <= channel + 3'd1;
                    stage <= channel == 3'd7 ? FINISH : LOAD;
                end
                FINISH: begin
                    pending_l <= clip16(sum_l);
                    pending_r <= clip16(sum_r);
                    stage <= IDLE;
                end
                default: stage <= IDLE;
            endcase
        end
    end
endmodule

// Bakraid sound: Z80, YMZ280B, mailbox, sound ROM/RAM and save-state chunks 15-18.
module rzbakraid_sound (
    output raizing_socket_pkg::z80_in_t sk_z80_i,
    input raizing_socket_pkg::z80_out_t sk_z80_o,

    input wire clk, reset, cpu_reset, z80_ce, ymz_ce, ymz_sample_ce,
    input wire [1:0] mailbox_write,
    input wire [7:0] mailbox_data,
    input wire mailbox_restore, mailbox_wait_active,
    input wire [15:0] mailbox_restore_data,
    output wire [15:0] mailbox_capture,
    output wire mailbox_wait_grant,
    input wire command_commit, bus_request,
    output wire [7:0] sound_latch3, sound_latch4,
    output wire sound_wait,
    output logic sound_irq,
    output wire bus_ack,
    input wire hold_request, canonical_hold, restore_commit,
    output wire held, canonical_ready, canonical_fault, canonical_service, restore_busy,
    output wire [16:0] rom_address,
    output wire rom_request,
    input wire rom_accept, rom_valid,
    input wire [7:0] rom_data,
    output wire [23:0] pcm_address,
    output wire pcm_request,
    input wire pcm_accept, pcm_valid,
    input wire [7:0] pcm_data,
    input wire [7:0] gain,
    input wire [3:0] attenuation,
    input wire audio_enable,
    output wire signed [15:0] audio,
    output wire sample, ymz_irq, audio_deadline_fault,
    input wire [63:0] SS_DATA,
    input wire [31:0] SS_ADDR,
    input wire [7:0] SS_SELECT,
    input wire SS_WRITE, SS_READ, SS_QUERY,
    output logic [63:0] SS_DATA_OUT,
    output logic SS_ACK
);
    wire cpu_held, cpu_ready, cpu_fault, busak_n, rd_n, wr_n, mreq_n, iorq_n, m1_n;
    wire [15:0] address;
    wire [7:0] cpu_data, cpu_input;
    wire live = !reset && !cpu_reset && !restore_busy;
    wire mem_read = live && !mreq_n && !rd_n;
    wire ram_range = address >= 16'hc000;
    wire rom_read = mem_read && !ram_range;
    wire ram_write = live && !mreq_n && !wr_n && ram_range;
    wire io_window = live && !iorq_n && m1_n && (!rd_n || !wr_n);
    wire ymz_port = io_window && address[7:1] == 7'h40;
    wire iack = live && !iorq_n && !m1_n;
    wire rom_busy, rom_done, ymz_held, ymz_idle, ymz_ready, ymz_done;
    wire [7:0] rom_result, ymz_result, ram_result, state_ram_result;
    wire mailbox_nmi, mailbox_irq, mailbox_hit, saved_nmi, saved_wait, saved_history;
    wire nmi_n = !mailbox_nmi;
    wire busrq_n = !bus_request;
    wire [7:0] mailbox_result, saved_reply0, saved_reply1;
    logic rom_seen, rom_ready, io_seen, io_complete, ram_seen, int_n;
    logic [7:0] rom_byte;
    logic [13:0] irq_count;
    logic bus_fault;
    wire [255:0] cpu_capture;
    logic [255:0] staged_cpu;
    logic [127:0] staged_control;
    wire image_valid = staged_cpu[255:214] == 42'b0 && staged_cpu[213] &&
                       !staged_cpu[212] && staged_control[127:48] == 80'b0 &&
                       staged_control[45:32] < 14'd12000;
    wire apply_restore = !reset && restore_commit && canonical_ready && image_valid;
    wire rom_start = rom_read && !rom_seen && !rom_busy && !cpu_held;
    // io_window and cpu_held never overlap (the Z80 is held only at M1).
    wire io_event = io_window && !io_seen && (!ymz_port || ymz_ready);
    wire wait_n = (!rom_read || rom_ready) && (!ymz_port || io_complete);

    assign held = cpu_held && ymz_held && !rom_busy && !restore_busy;
    // cpu_ready implies the Z80 is held; ymz_idle stands for ymz_held.
    assign canonical_ready = cpu_ready && ymz_idle && !rom_busy && !restore_busy && !bus_fault;
    assign canonical_fault = cpu_fault || bus_fault;
    assign bus_ack = live && !busak_n;
    assign cpu_input = rom_read ? rom_byte :
                       (mem_read && ram_range) ? ram_result :
                       mailbox_hit ? mailbox_result :
                       (ymz_port && !rd_n) ? ymz_result : 8'hff;

    // Socket sk_z80: pins of the shared raizing_z80 instance.
    assign sk_z80_i.clk = clk;
    assign sk_z80_i.reset = reset || cpu_reset;
    assign sk_z80_i.cen = z80_ce;
    assign sk_z80_i.wait_n = wait_n;
    assign sk_z80_i.int_n = int_n;
    assign sk_z80_i.hold_request = hold_request;
    assign sk_z80_i.nmi_n = nmi_n;
    assign sk_z80_i.busrq_n = busrq_n;
    assign sk_z80_i.canonical_hold = canonical_hold;
    assign sk_z80_i.restore = apply_restore;
    assign sk_z80_i.restore_state = staged_cpu;
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

    rzsnd_mailbox #(.PROFILE(5)) mb (
        .clk(clk), .board_reset(reset), .hold(1'b0),
        .m_cmd0_wr(mailbox_write[0]), .m_cmd1_wr(mailbox_write[1]), .m_commit(command_commit),
        .m_irq_clear(1'b0), .m_ctrl_wr(1'b0), .m_wdata(mailbox_data), .m_as_idle(1'b0),
        .m_level_clear_ok(1'b0), .start_wait(), .snd_cmd_line(), .main_irq_set(mailbox_irq),
        .main_irq_clear(), .busreq(), .eep_clk(), .eep_di(), .eep_cs(),
        .wo_begin(command_commit), .wo_abandon(!mailbox_wait_active),
        .wo_active(mailbox_wait_active), .wo_sample(1'b1), .wait_level(sound_wait),
        .wo_seen(), .wo_grant(mailbox_wait_grant), .snd_advance(!cpu_held && !restore_busy),
        .z80_live(live), .z_wr(io_event && !wr_n), .z_rd(io_window && !rd_n),
        .z_io(1'b1), .z_iack(1'b0), .z_addr(address), .z_wdata(cpu_data),
        .snd_irq(mailbox_nmi), .z_rd_hit(mailbox_hit), .z_rdata(mailbox_result),
        .reply0(sound_latch3), .reply1(sound_latch4), .f_cmd0(mailbox_capture[7:0]),
        .f_cmd1(mailbox_capture[15:8]), .f_cmd_level(), .f_ctrl(), .f_irq(saved_nmi),
        .f_wait(saved_wait), .f_hist(saved_history), .f_reply0(saved_reply0), .f_reply1(saved_reply1),
        .r_main_load(mailbox_restore), .r_cmd0(mailbox_restore_data[7:0]),
        .r_cmd1(mailbox_restore_data[15:8]), .r_cmd_level(1'b0), .r_ctrl(8'b0),
        .r_snd_load(apply_restore), .r_irq(staged_control[17]), .r_wait(staged_control[16]),
        .r_hist(staged_control[18]), .r_reply0(staged_control[7:0]), .r_reply1(staged_control[15:8]),
        .own_main(), .own_snd(), .inert()
    );

    rzbakraid_sound_rom_port #(.AW(17)) program_rom (
        .clk(clk), .reset(reset), .start(rom_start), .cancel(cpu_reset),
        .address({1'b0, address}), .busy(rom_busy), .done(rom_done), .data(rom_result),
        .request(rom_request), .request_address(rom_address), .accept(rom_accept),
        .valid(rom_valid), .response_data(rom_data)
    );

    wire signed [15:0] left, right;
    wire ymz_sample;
    wire [63:0] ymz_state;
    wire host_ram_write, host_ymz_write;
    rzbakraid_ymz chip (
        .clk(clk), .reset(reset), .ymz_ce(ymz_ce), .sample_ce(ymz_sample_ce),
        .hold_request(cpu_held), .held(ymz_held), .idle(ymz_idle), .cpu_valid(io_event && ymz_port),
        .cpu_write(!wr_n), .cpu_a0(address[0]), .cpu_data(cpu_data), .cpu_ready(ymz_ready),
        .cpu_done(ymz_done), .cpu_dout(ymz_result), .irq(ymz_irq), .pcm_address(pcm_address),
        .pcm_request(pcm_request), .pcm_accept(pcm_accept), .pcm_valid(pcm_valid),
        .pcm_data(pcm_data), .left(left), .right(right), .sample(ymz_sample),
        .deadline_fault(audio_deadline_fault), .state_address(SS_ADDR[5:0]),
        .state_data(SS_DATA), .state_write(host_ymz_write), .state_q(ymz_state)
    );

    raizing_bram #(.DW(8), .AW(14)) ram (
        .clk0(clk), .addr0(address[13:0]), .data0(cpu_data),
        .we0(ram_write && !ram_seen && !cpu_held && busak_n && !host_ram_write), .q0(ram_result),
        .clk1(clk), .addr1(SS_ADDR[13:0]), .data1(SS_DATA[7:0]),
        .we1(host_ram_write), .q1(state_ram_result)
    );

    always_ff @(posedge clk) begin
        if (reset) begin
            {rom_seen, rom_ready, io_seen, io_complete, ram_seen, rom_byte} <= '0;
            irq_count <= '0;
            int_n <= 1'b1;
            sound_irq <= 1'b0;
        end else if (apply_restore) begin
            {sound_irq, ram_seen, irq_count, int_n, rom_byte, rom_ready, rom_seen,
             io_complete, io_seen} <= staged_control[47:19];
        end else begin
            sound_irq <= mailbox_irq;
            if (z80_ce && !cpu_held && !restore_busy) begin
                if (irq_count == 14'd11999) begin
                    irq_count <= '0;
                    int_n <= 1'b0;
                end else irq_count <= irq_count + 14'd1;
            end
            if (iack) int_n <= 1'b1;

            if (cpu_reset) begin
                {rom_seen, rom_ready, io_seen, io_complete, ram_seen} <= '0;
            end else begin
                if (!rom_read) {rom_seen, rom_ready} <= '0;
                else if (rom_start) {rom_seen, rom_ready} <= 2'b10;
                if (rom_done) begin
                    rom_ready <= 1'b1;
                    rom_byte <= rom_result;
                end
                if (!io_window) {io_seen, io_complete} <= '0;
                else if (io_event) io_seen <= 1'b1;
                if (ymz_done) io_complete <= 1'b1;
                if (live && !cpu_held) ram_seen <= ram_write;
            end
        end
    end

    wire [63:0] control_capture = {16'b0, sound_irq, ram_seen, irq_count, int_n, rom_byte,
                                  rom_ready, rom_seen, io_complete, io_seen, saved_history,
                                  saved_nmi, saved_wait, saved_reply1, saved_reply0};
    logic request_seen, ram_read_pending;
    wire request_group = SS_READ || SS_WRITE || SS_QUERY;
    logic [31:0] word_count;
    always_comb begin
        case (SS_SELECT)
            8'd15: word_count = 32'd4;
            8'd16: word_count = 32'd16384;
            8'd17: word_count = 32'd2;
            8'd18: word_count = 32'd59;
            default: word_count = 32'd0;
        endcase
    end
    wire admit = !reset && request_group && !request_seen && word_count != 0;
    // State writes need canonical_ready (implies held); reads need held.
    wire legal_data = (SS_WRITE ? canonical_ready : held) && SS_ADDR < word_count &&
                      !(SS_READ && SS_WRITE);
`ifdef SIMULATION
    always_ff @(posedge clk)
        if (!reset && canonical_ready && !held) $fatal(1, "BAKRAID_CANONICAL_NOT_HELD");
`endif
`ifdef SIMULATION
    // Invariants for the YMZ write enables.
    always_ff @(posedge clk) begin
        if (!reset && io_window && cpu_held) $fatal(1, "BAKRAID_IO_WHILE_HELD");
        if (!reset && host_ymz_write && !cpu_held) $fatal(1, "BAKRAID_STATE_WRITE_NOT_HELD");
    end
`endif
    // Admitted legal write: legal_data with SS_WRITE set.
    wire state_write = admit && !SS_QUERY && SS_WRITE && canonical_ready && SS_ADDR < word_count &&
                       !SS_READ;
    assign host_ram_write = state_write && SS_SELECT == 8'd16;
    assign host_ymz_write = state_write && SS_SELECT == 8'd18;

    always_ff @(posedge clk) begin
        SS_ACK <= 1'b0;
        SS_DATA_OUT <= '0;
        ram_read_pending <= 1'b0;
        if (reset) begin
            request_seen <= 1'b0;
            bus_fault <= 1'b0;
            staged_cpu <= '0;
            staged_control <= '0;
        end else begin
            if (!request_group) request_seen <= 1'b0;
            else if (admit) request_seen <= 1'b1;
            if (restore_commit && !apply_restore) bus_fault <= 1'b1;
            // The BRAM captures the host address at admission; its output is valid here.
            if (ram_read_pending) begin
                SS_ACK <= 1'b1;
                SS_DATA_OUT <= {56'b0, state_ram_result};
            end
            if (admit) begin
                if (SS_QUERY) begin
                    SS_ACK <= 1'b1;
                    SS_DATA_OUT <= {SS_SELECT, 22'b0, (SS_SELECT == 8'd16 ? 2'd0 : 2'd3), word_count};
                end else if (!legal_data) bus_fault <= 1'b1;
                else if (SS_WRITE) begin
                    SS_ACK <= 1'b1;
                    if (SS_SELECT == 8'd15) staged_cpu[64*SS_ADDR[1:0] +: 64] <= SS_DATA;
                    if (SS_SELECT == 8'd17) staged_control[64*SS_ADDR[0] +: 64] <= SS_DATA;
                end else if (SS_SELECT == 8'd16) ram_read_pending <= 1'b1;
                else begin
                    SS_ACK <= 1'b1;
                    case (SS_SELECT)
                        8'd15: SS_DATA_OUT <= cpu_capture[64*SS_ADDR[1:0] +: 64];
                        8'd17: SS_DATA_OUT <= SS_ADDR[0] ? 64'b0 : control_capture;
                        8'd18: SS_DATA_OUT <= ymz_state;
                        default: SS_DATA_OUT <= '0;
                    endcase
                end
            end
        end
    end

    wire signed [31:0] channel_sum = $signed(left) + $signed(right);
    // (channel_sum * gain) >>> 4 as shifts for the OSD gains 0x08, 0x0c, 0x10, 0x20.
    wire signed [31:0] gained = gain == 8'h20 ? channel_sum <<< 1 :
                                gain == 8'h08 ? channel_sum >>> 1 :
                                gain == 8'h0c ? (channel_sum + (channel_sum <<< 1)) >>> 2 : channel_sum;
    wire signed [31:0] scaled = gained >>> attenuation;
`ifndef SYNTHESIS
    always @(posedge clk) if (!reset && gain != 8'h08 && gain != 8'h0c && gain != 8'h10 && gain != 8'h20)
        $fatal(1, "rzbakraid_sound: gain %h is not one of the OSD values", gain);
`endif
    wire signed [15:0] clipped = scaled > 32'sd32767 ? 16'sh7fff :
                                 scaled < -32'sd32768 ? 16'sh8000 : scaled[15:0];
    assign audio = (!audio_enable || held || restore_busy) ? 16'sd0 : clipped;
    assign sample = ymz_sample && !held && !restore_busy;
endmodule

`default_nettype none
`default_nettype wire

`default_nettype wire

// Bakraid set profile by ROM CRC and length.
module rzbakraid_rom_profile (
    input wire image_valid,
    input wire [31:0] image_length, image_crc,
    output reg supported,
    output reg [2:0] profile
);
    always @* begin
        supported = 0;
        profile = 0;
        if(image_valid && image_length == 32'h01E20000) begin
            case(image_crc)
                32'hD368268B: begin supported=1;profile=3'd0;end // Unlimited USA
                32'h7945BFA7: begin supported=1;profile=3'd1;end // Special USA
                32'h46E4F0EF: begin supported=1;profile=3'd2;end // Unlimited China
                32'h5FCA496C: begin supported=1;profile=3'd3;end // Unlimited Japan
                32'h48830439: begin supported=1;profile=3'd4;end // Japan April
                default: begin end
            endcase
        end
    end
endmodule

// Bakraid audio clock-phase state (chunk 39) and its restore sequencing.
module rzbakraid_audio_state (
    input clk,reset,state_active,held,restore_busy,canonical_fault,restore_commit,
    input [31:0] phase_capture,
    output [31:0] phase_restore,
    output clock_hold,phase_load,devices_ready,
    output reg fault,
    input [63:0] SS_DATA,
    input [31:0] SS_ADDR,
    input [7:0] SS_SELECT,
    input SS_WRITE,SS_READ,SS_QUERY,
    output [63:0] SS_DATA_OUT,
    output SS_ACK
);
    reg pending,priming_seen,staged;
    wire restore_we;
    assign clock_hold=held && !restore_busy;
    assign phase_load=pending && priming_seen && held && !restore_busy && !canonical_fault && !fault;
    assign devices_ready=!pending && !fault;
    always @(posedge clk) begin
        if(reset) begin pending<=0;priming_seen<=0;staged<=0;fault<=0;end
        else begin
            if(!state_active) staged<=0;
            if(restore_we && state_active && held) staged<=1;
            if(restore_commit) begin
                if(state_active && held && staged && !canonical_fault) begin
                    pending<=1;priming_seen<=0;
                end else fault<=1;
            end
            if(pending && restore_busy) priming_seen<=1;
            if(phase_load) pending<=0;
        end
    end
    raizing_ss_register #(.WIDTH(32),.SS_INDEX(39)) phases(
        .clk(clk),.reset(reset),.capture_data(phase_capture),.restore_data(phase_restore),.restore_we(restore_we),
        .ss_data(SS_DATA),.ss_select(SS_SELECT),.ss_write(SS_WRITE && state_active && held && SS_ADDR==0),
        .ss_read(SS_READ && state_active && held && SS_ADDR==0),.ss_query(SS_QUERY),
        .ss_data_out(SS_DATA_OUT),.ss_ack(SS_ACK));
endmodule

`default_nettype wire
