// State-only derivative of jotego/jt6295 7d76b0be8cd8f85f3ae741178c9830b20e2071a1.
// Save-state access at device indices auto_ss_base_device_idx+1..+10; INTERPOL=0 only.
/*  This file is part of JT6295.
    JT6295 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT6295 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT6295.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 6-1-2020 */

// Sample tick = cen/132 (ss=1) or cen/165 (ss=0); cen_48k = cen*6/125.

module ss_jt6295_timing(
    input       clk,
    input state_freeze,
    input       cen,
    input       ss,
    output reg  cen_sr,   // Sample rate
    output reg  cen_sr4,  // 4x sample rate
    output reg  cen_sr4b, // 4x sample rate, 180 shift
    output reg  cen_sr32,
    output reg  cen_48k, // cen*6/125
    input auto_ss_rd,
    input auto_ss_wr,
    input [31:0] auto_ss_data_in,
    input [7:0] auto_ss_device_idx,
    input [15:0] auto_ss_state_idx,
    input [7:0] auto_ss_base_device_idx,
    output wire [31:0] auto_ss_data_out,
    output wire auto_ss_ack
);
wire device_match = auto_ss_device_idx == auto_ss_base_device_idx;
wire state_write = auto_ss_wr && device_match;


localparam [7:0] N48=8'd6, D48=8'd125;

reg  [2:0] base=0;
reg  [5:0] cnt =6'd0;
wire [2:0] lim = ss ? 3'h3 : 3'h4;

reg  [7:0] cnt48=0;
wire       over48 = cnt48>=D48;

always @(posedge clk) begin
if (state_write) begin
case (auto_ss_state_idx)
    0: begin cnt48 <= auto_ss_data_in[7:0]; cen_48k <= auto_ss_data_in[17]; end
    default: ;
endcase
end else if (!state_freeze) begin

    if(cen) cnt48 <= over48 ? cnt48-(D48-N48) : cnt48+N48;
    cen_48k <= over48 && cen;

end
end

always @(posedge clk) begin
if (state_write) begin
case (auto_ss_state_idx)
    0: begin cnt <= auto_ss_data_in[13:8]; base <= auto_ss_data_in[16:14]; cen_sr <= auto_ss_data_in[18]; cen_sr32 <= auto_ss_data_in[19]; cen_sr4 <= auto_ss_data_in[20]; cen_sr4b <= auto_ss_data_in[21]; end
    default: ;
endcase
end else if (!state_freeze) begin

    cen_sr4 <= 1'd0;
    cen_sr4b<= 1'd0;
    cen_sr  <= 1'd0;
    cen_sr32<= 1'b0;
    if( cen ) begin
        base    <= (base==lim) ? 3'd0 : base+3'd1;
        if(base==3'd0) cnt <= (cnt==6'd32) ? 6'd0 : cnt+6'd1;

        cen_sr32<= !cnt[5] && base==3'd0;
        cen_sr4 <= !cnt[5] && cnt[2:0] == 3'b000 && base == 3'd0;
        cen_sr4b<= !cnt[5] && cnt[2:0] == 3'b100 && base == 3'd0;
        cen_sr  <= {cnt,base} == 9'd0;
    end

end
end

reg [31:0] local_state;
reg local_ack;
always @* begin
local_state = 0; local_ack = 0;
if (auto_ss_rd && device_match) begin
case (auto_ss_state_idx)
0: begin
local_ack = 1;
local_state[7:0] = cnt48;
local_state[13:8] = cnt;
local_state[16:14] = base;
local_state[17] = cen_48k;
local_state[18] = cen_sr;
local_state[19] = cen_sr32;
local_state[20] = cen_sr4;
local_state[21] = cen_sr4b;
end
default: ;
endcase
end
end
assign auto_ss_data_out = local_state;
assign auto_ss_ack = local_ack;
endmodule

/*  This file is part of JT6295.
    JT6295 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT6295 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT6295.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 6-1-2020 */

// Each channel slot: 2 ADPCM and 6 control ROM reads; only control reads set ctrl_ok.

module ss_jt6295_rom(
    input             rst,
    input             clk,
    input state_freeze,
    input             cen4,
    input             cen32,

    input      [17:0] adpcm_addr,
    input      [17:0] ctrl_addr,

    output reg [ 7:0] adpcm_dout,
    output reg [ 7:0] ctrl_dout,

    output reg        ctrl_ok,
    output reg [17:0] rom_addr,
    input      [ 7:0] rom_data,
    input             rom_ok,
    input auto_ss_rd,
    input auto_ss_wr,
    input [31:0] auto_ss_data_in,
    input [7:0] auto_ss_device_idx,
    input [15:0] auto_ss_state_idx,
    input [7:0] auto_ss_base_device_idx,
    output wire [31:0] auto_ss_data_out,
    output wire auto_ss_ack
);
wire device_match = auto_ss_device_idx == auto_ss_base_device_idx;
wire state_write = auto_ss_wr && device_match;


reg [7:0] st;
reg [1:0] wait2;

always @(posedge clk) begin
if (state_write) begin
case (auto_ss_state_idx)
    0: begin st <= auto_ss_data_in[25:18]; end
    default: ;
endcase
end else if (!state_freeze) begin

    if(cen4 ) st <= 8'h80;
    else if(cen32) st <= { st[6:0], st[7] };

end
end

wire new_addr = rom_addr != ctrl_addr;

always @(posedge clk) begin
if (state_write) begin
case (auto_ss_state_idx)
    0: begin rom_addr <= auto_ss_data_in[17:0]; end
    1: begin adpcm_dout <= auto_ss_data_in[7:0]; ctrl_dout <= auto_ss_data_in[15:8]; wait2 <= auto_ss_data_in[17:16]; ctrl_ok <= auto_ss_data_in[18]; end
    default: ;
endcase
end else if (!state_freeze) begin

    case(st)
        8'b1,8'b10: begin
            rom_addr   <= adpcm_addr;
            adpcm_dout <= rom_data;
            ctrl_ok    <= 1'b0;
            wait2      <= 2'b0;
        end
        default: begin
            rom_addr   <= ctrl_addr;
            // rom_ok still reflects the ADPCM read until wait2 fills
            if(wait2==2'b11 && !new_addr) begin
                ctrl_ok   <= rom_ok;
                ctrl_dout <= rom_data;
            end else ctrl_ok <= 1'b0;
            if( new_addr )
                wait2 <= 2'b0;
            else
                wait2 <= {wait2[0],1'b1};
        end
    endcase

end
end

reg [31:0] local_state;
reg local_ack;
always @* begin
local_state = 0; local_ack = 0;
if (auto_ss_rd && device_match) begin
case (auto_ss_state_idx)
0: begin
local_ack = 1;
local_state[17:0] = rom_addr;
local_state[25:18] = st;
end
1: begin
local_ack = 1;
local_state[7:0] = adpcm_dout;
local_state[15:8] = ctrl_dout;
local_state[17:16] = wait2;
local_state[18] = ctrl_ok;
end
default: ;
endcase
end
end
assign auto_ss_data_out = local_state;
assign auto_ss_ack = local_ack;
endmodule
/*  This file is part of JT6295.
    JT6295 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT6295 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT6295.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 6-1-2020 */

module ss_jt6295_ctrl(
    input                  rst,
    input                  clk,
    input state_freeze,
    input                  cen4,
    input                  cen1,
    input                  wrn,
    input      [ 7:0]      din,
    output reg [17:0]      start_addr,
    output reg [17:0]      stop_addr,
    output reg [ 3:0]      att,
    output     [ 9:0]      rom_addr,
    input      [ 7:0]      rom_data,
    input                  rom_ok,
    output reg [ 3:0]      start,
    output reg [ 3:0]      stop,
    input      [ 3:0]      busy,
    input      [ 3:0]      ack,
    input                  zero,
    input auto_ss_rd,
    input auto_ss_wr,
    input [31:0] auto_ss_data_in,
    input [7:0] auto_ss_device_idx,
    input [15:0] auto_ss_state_idx,
    input [7:0] auto_ss_base_device_idx,
    output wire [31:0] auto_ss_data_out,
    output wire auto_ss_ack
);
wire device_match = auto_ss_device_idx == auto_ss_base_device_idx;
wire state_write = auto_ss_wr && device_match;


reg  last_wrn;
wire negedge_wrn  = !wrn && last_wrn;

reg [6:0] phrase;
reg       push, pull;
reg [3:0] ch, new_att;
reg       cmd;

always @(posedge clk) begin
if (state_write) begin
case (auto_ss_state_idx)
    4: begin last_wrn <= auto_ss_data_in[3]; end
    default: ;
endcase
end else if (!state_freeze) begin

    last_wrn <= wrn;

end
end

reg stop_clr;




always @(posedge clk) begin
    if( rst ) begin
        cmd      <= 1'b0;
        stop     <= 4'd0;
        ch       <= 4'd0;
        pull     <= 1'b1;
        phrase   <= 7'd0;
        new_att  <= 0;
    end else if (state_write) begin
case (auto_ss_state_idx)
    3: begin phrase <= auto_ss_data_in[6:0]; ch <= auto_ss_data_in[10:7]; new_att <= auto_ss_data_in[14:11]; stop <= auto_ss_data_in[18:15]; end
    4: begin cmd <= auto_ss_data_in[4]; pull <= auto_ss_data_in[5]; end
    default: ;
endcase
end else if (!state_freeze) begin
 begin
        if( cen4 ) begin
            stop <= stop & busy;
        end
        if( push ) pull <= 1'b0;
        if( negedge_wrn  ) begin
            if( cmd ) begin // 2nd byte: channel mask, attenuation
                ch      <= din[7:4];
                new_att <= din[3:0];
                cmd     <= 1'b0;
                pull    <= 1'b1;
            end
            else if( din[7] ) begin // 1st byte: phrase number
                phrase <= din[6:0];
                cmd    <= 1'b1;
                stop   <= 4'd0;
            end else begin // stop channels in din[6:3]
                stop   <= din[6:3];
            end
        end
    end

end
end

reg [17:0] new_start;
reg [17:8] new_stop;
reg [ 2:0] st, addr_lsb;
reg        wrom;

assign rom_addr = { phrase, addr_lsb };

// Read phrase table entry at phrase*8: start and stop addresses, 3 bytes each.
always @(posedge clk) begin
    if( rst ) begin
        st         <= 7;
        att        <= 0;
        start_addr <= 0;
        stop_addr  <= 0;
        start      <= 0;
        push       <= 0;
        addr_lsb   <= 0;
    end else if (state_write) begin
case (auto_ss_state_idx)
    0: begin new_start <= auto_ss_data_in[17:0]; end
    1: begin start_addr <= auto_ss_data_in[17:0]; end
    2: begin stop_addr <= auto_ss_data_in[17:0]; new_stop <= auto_ss_data_in[27:18]; end
    3: begin att <= auto_ss_data_in[22:19]; start <= auto_ss_data_in[26:23]; addr_lsb <= auto_ss_data_in[29:27]; end
    4: begin st <= auto_ss_data_in[2:0]; push <= auto_ss_data_in[6]; wrom <= auto_ss_data_in[7]; end
    default: ;
endcase
end else if (!state_freeze) begin
 begin
        if( st!=7 ) begin
            wrom <= 0;
            if( !wrom && rom_ok ) begin
                st       <= st+3'd1;
                addr_lsb <= st;
                wrom     <= 1;
            end
        end
        case( st )
            7: begin
                start    <= start & ~ack;
                addr_lsb <= 0;
                if(pull) begin
                    st       <= 0;
                    wrom     <= 1;
                    push     <= 1;
                end
            end
            0:;
            1: new_start[17:16] <= rom_data[1:0];
            2: new_start[15: 8] <= rom_data;
            3: new_start[ 7: 0] <= rom_data;
            4: new_stop [17:16] <= rom_data[1:0];
            5: new_stop [15: 8] <= rom_data;
            6: begin
                start       <= ch;
                start_addr  <= new_start;
                stop_addr   <= {new_stop[17:8], rom_data} ;
                att         <= new_att;
                push        <= 0;
            end
        endcase
    end

end
end

reg [31:0] local_state;
reg local_ack;
always @* begin
local_state = 0; local_ack = 0;
if (auto_ss_rd && device_match) begin
case (auto_ss_state_idx)
0: begin
local_ack = 1;
local_state[17:0] = new_start;
end
1: begin
local_ack = 1;
local_state[17:0] = start_addr;
end
2: begin
local_ack = 1;
local_state[17:0] = stop_addr;
local_state[27:18] = new_stop;
end
3: begin
local_ack = 1;
local_state[6:0] = phrase;
local_state[10:7] = ch;
local_state[14:11] = new_att;
local_state[18:15] = stop;
local_state[22:19] = att;
local_state[26:23] = start;
local_state[29:27] = addr_lsb;
end
4: begin
local_ack = 1;
local_state[2:0] = st;
local_state[3] = last_wrn;
local_state[4] = cmd;
local_state[5] = pull;
local_state[6] = push;
local_state[7] = wrom;
end
default: ;
endcase
end
end
assign auto_ss_data_out = local_state;
assign auto_ss_ack = local_ack;
endmodule
/*  This file is part of JT6295.

    JT6295 is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT6295 is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT6295.  If not, see <http://www.gnu.org/licenses/>.

	Author: Jose Tejada Gomez. Twitter: @topapate
	Version: 1.0
	Date: 6-1-2020
	*/

// STAGES must be greater than 2
module ss_jt6295_sh_rst #(parameter WIDTH=5, STAGES=32, RSTVAL=1'b0 )
(
	input					rst,	
	input 					clk,
    input state_freeze,
	input					clk_en /* synthesis direct_enable */,
	input		[WIDTH-1:0]	din,
   	output		[WIDTH-1:0]	drop,
    input auto_ss_rd,
    input auto_ss_wr,
    input [31:0] auto_ss_data_in,
    input [7:0] auto_ss_device_idx,
    input [15:0] auto_ss_state_idx,
    input [7:0] auto_ss_base_device_idx,
    output wire [31:0] auto_ss_data_out,
    output wire auto_ss_ack
);
wire device_match = auto_ss_device_idx == auto_ss_base_device_idx;
wire state_write = auto_ss_wr && device_match;


reg [STAGES-1:0] bits[WIDTH-1:0];

genvar i;
integer k;
generate
initial
	for (k=0; k < WIDTH; k=k+1) begin
		bits[k] = { STAGES{RSTVAL}};
	end
endgenerate

generate
	for (i=0; i < WIDTH; i=i+1) begin: bit_shifter
		always @(posedge clk, posedge rst) 
			if( rst ) begin
				bits[i] <= {STAGES{RSTVAL}};
			end else if (state_write && auto_ss_state_idx == i) begin
                bits[i] <= auto_ss_data_in[STAGES-1:0];
            end else if(clk_en && !state_freeze) begin
				bits[i] <= {bits[i][STAGES-2:0], din[i]};
			end
		assign drop[i] = bits[i][STAGES-1];
	end
endgenerate

assign auto_ss_ack = auto_ss_rd && device_match && auto_ss_state_idx < WIDTH;
assign auto_ss_data_out = auto_ss_ack ? {{(32-STAGES){1'b0}}, bits[auto_ss_state_idx]} : 32'd0;
endmodule

/*  This file is part of JT6295.
    JT6295 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT6295 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT6295.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 6-1-2020 */

module ss_jt6295_serial(
    input               rst,
    input               clk,
    input state_freeze,
    input               cen,
    input               cen4,
    input      [17:0]   start_addr,
    input      [17:0]   stop_addr,
    input      [ 3:0]   att,
    input      [ 3:0]   start,
    input      [ 3:0]   stop,
    output reg [ 3:0]   busy,
    output reg [ 3:0]   ack,
    output              zero,
    output     [17:0]   rom_addr,
    input      [ 7:0]   rom_data,
    output reg          pipe_en,
    output reg [ 3:0]   pipe_att,
    output reg [ 3:0]   pipe_data,
    input auto_ss_rd,
    input auto_ss_wr,
    input [31:0] auto_ss_data_in,
    input [7:0] auto_ss_device_idx,
    input [15:0] auto_ss_state_idx,
    input [7:0] auto_ss_base_device_idx,
    output wire [31:0] auto_ss_data_out,
    output wire auto_ss_ack
);
wire device_match = auto_ss_device_idx == auto_ss_base_device_idx;
wire state_write = auto_ss_wr && device_match;
wire [31:0] state_cnt;
wire ack_cnt;


localparam CSRW = 18+19+4+1;

reg  [ 3:0] ch;
wire [ 3:0] att_in, att_out;
wire [18:0] cnt, cnt_next, cnt_in;
wire [17:0] ch_end, stop_in, stop_out;
wire        update;
wire        over, busy_in, busy_out, cont;
reg         up_start, up_stop;

always @(posedge clk, posedge rst) begin
    if(rst)
        ch <= 4'b1;
    else if (state_write) begin
case (auto_ss_state_idx)
    0: begin ch <= auto_ss_data_in[3:0]; end
    default: ;
endcase
end else if (!state_freeze) begin
 begin
        if(cen4) ch <= { ch[2:0], ch[3]  };
    end

end
end

always @(*) begin
    case( ch )
        4'b0001: { up_start, up_stop } = { start[0], stop[0] };
        4'b0010: { up_start, up_stop } = { start[1], stop[1] };
        4'b0100: { up_start, up_stop } = { start[2], stop[2] };
        4'b1000: { up_start, up_stop } = { start[3], stop[3] };
        default: { up_start, up_stop } = 2'b00;
    endcase
end

reg [17:0] cnt0, cnt1, cnt2, cnt3;

always @(posedge clk, posedge rst ) begin
    if( rst ) begin
        busy <= 4'd0;
    end else if (state_write) begin
case (auto_ss_state_idx)
    0: begin ack <= auto_ss_data_in[7:4]; busy <= auto_ss_data_in[11:8]; end
    default: ;
endcase
end else if (!state_freeze) begin
 begin
        case( ch )
            4'b0001: busy[0] <= busy_in;
            4'b0010: busy[1] <= busy_in;
            4'b0100: busy[2] <= busy_in;
            4'b1000: busy[3] <= busy_in;
            default: busy    <= 4'd0;
        endcase
        if( cen4 ) begin
            case( ch )
                4'b0001: ack <= up_start ? ch : 4'b0;
                4'b0010: ack <= up_start ? ch : 4'b0;
                4'b0100: ack <= up_start ? ch : 4'b0;
                4'b1000: ack <= up_start ? ch : 4'b0;
                default: ack <= 4'd0;
            endcase
        end
        
    end

end
end

assign zero     = ch[0];
assign update   = up_start | up_stop;
assign cont     = busy_out & ~over;
assign cnt_next = cont      ? cnt+19'd1 : cnt;
assign stop_in  = up_start  ? stop_addr : stop_out;
assign cnt_in   = up_start  ? {start_addr, 1'b0} : cnt_next;
assign att_in   = up_start  ? att : att_out;
assign busy_in  = update    ? (up_start & ~up_stop) : cont;

wire [CSRW-1:0] csr_in, csr_out;
assign csr_in = { stop_in, cnt_in, att_in, busy_in };
assign {stop_out, cnt, att_out, busy_out } = csr_out;
assign rom_addr = cnt[18:1];
assign over     = rom_addr >= stop_out;

ss_jt6295_sh_rst #(.WIDTH(CSRW), .STAGES(4) ) u_cnt(
    .rst    ( rst       ),
    .clk    ( clk       ),
    .clk_en ( cen4      ),
    .din    ( csr_in    ),
    .drop   ( csr_out   ),
    .state_freeze(state_freeze),
    .auto_ss_rd(auto_ss_rd), .auto_ss_wr(auto_ss_wr),
    .auto_ss_data_in(auto_ss_data_in),
    .auto_ss_device_idx(auto_ss_device_idx), .auto_ss_state_idx(auto_ss_state_idx),
    .auto_ss_base_device_idx(auto_ss_base_device_idx + 8'd1),
    .auto_ss_data_out(state_cnt), .auto_ss_ack(ack_cnt)
);

// Latch nibble (high first), attenuation and enable on cen4.

always @(posedge clk, posedge rst) begin
    if(rst) begin
        pipe_data<= 4'd0;
        pipe_en  <= 1'b0;
        pipe_att <= 4'd0;
    end else if (state_write) begin
case (auto_ss_state_idx)
    0: begin pipe_att <= auto_ss_data_in[15:12]; pipe_data <= auto_ss_data_in[19:16]; pipe_en <= auto_ss_data_in[20]; end
    default: ;
endcase
end else if (!state_freeze) begin
 if(cen4) begin
        pipe_data <= !cnt[0] ? rom_data[7:4] : rom_data[3:0];
        pipe_att  <= att_out;
        pipe_en   <= busy_out;
    end

end
end

reg [31:0] local_state;
reg local_ack;
always @* begin
local_state = 0; local_ack = 0;
if (auto_ss_rd && device_match) begin
case (auto_ss_state_idx)
0: begin
local_ack = 1;
local_state[3:0] = ch;
local_state[7:4] = ack;
local_state[11:8] = busy;
local_state[15:12] = pipe_att;
local_state[19:16] = pipe_data;
local_state[20] = pipe_en;
end
default: ;
endcase
end
end
assign auto_ss_data_out = local_state | state_cnt;
assign auto_ss_ack = local_ack | ack_cnt;
endmodule

/*  This file is part of JT6295.
    JT6295 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT6295 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT6295.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 6-1-2020 */

module ss_jt6295_adpcm(
    input                    rst,
    input                    clk,
    input state_freeze,
    input                    cen,
    input                    en,
    input             [ 3:0] att,
    input             [ 3:0] data,
    output reg signed [11:0] sound,
    input auto_ss_rd,
    input auto_ss_wr,
    input [31:0] auto_ss_data_in,
    input [7:0] auto_ss_device_idx,
    input [15:0] auto_ss_state_idx,
    input [7:0] auto_ss_base_device_idx,
    output wire [31:0] auto_ss_data_out,
    output wire auto_ss_ack
);
wire device_match = auto_ss_device_idx == auto_ss_base_device_idx;
wire state_write = auto_ss_wr && device_match;
wire [31:0] state_enable;
wire ack_enable;
wire [31:0] state_att;
wire ack_att;
wire [31:0] state_sound;
wire ack_sound;



reg [10:0] lut[0:48];

reg [ 5:0] idx_inc_II;
reg [ 5:0] delta_idx_I,delta_idx_II, delta_idx_III, delta_idx_IV;

reg [ 2:0] factor_II, factor_III;
reg        factor_IV;
reg        sign_II, sign_III, sign_IV, sign_V;
reg [11:0] dn_II, qn_II, dn_III, qn_III, dn_IV, qn_IV, qn_V;

always @(posedge clk, posedge rst ) begin
    if(rst) begin
        idx_inc_II    <= 6'd0;
        delta_idx_I   <= 6'd0;
        delta_idx_II  <= 6'd0;
        delta_idx_III <= 6'd0;
        delta_idx_IV  <= 6'd0;

        factor_II  <= 3'd0;
        factor_III <= 0;
        factor_IV  <= 1'd0;
        { sign_II, sign_III, sign_IV, sign_V } <=4'd0;
        dn_II   <= 12'd0;
        qn_II   <= 12'd0;
        dn_III  <= 12'd0;
        qn_III  <= 12'd0;
        dn_IV   <= 12'd0;
        qn_IV   <= 12'd0;
        qn_V    <= 12'd0;
    end else if (state_write) begin
case (auto_ss_state_idx)
    0: begin dn_II <= auto_ss_data_in[11:0]; dn_III <= auto_ss_data_in[23:12]; end
    1: begin dn_IV <= auto_ss_data_in[11:0]; qn_II <= auto_ss_data_in[23:12]; end
    2: begin qn_III <= auto_ss_data_in[11:0]; qn_IV <= auto_ss_data_in[23:12]; end
    3: begin qn_V <= auto_ss_data_in[11:0]; end
    4: begin delta_idx_I <= auto_ss_data_in[24:19]; delta_idx_II <= auto_ss_data_in[30:25]; end
    5: begin delta_idx_III <= auto_ss_data_in[5:0]; delta_idx_IV <= auto_ss_data_in[11:6]; idx_inc_II <= auto_ss_data_in[17:12]; factor_II <= auto_ss_data_in[20:18]; factor_III <= auto_ss_data_in[23:21]; factor_IV <= auto_ss_data_in[24]; sign_II <= auto_ss_data_in[25]; sign_III <= auto_ss_data_in[26]; sign_IV <= auto_ss_data_in[27]; sign_V <= auto_ss_data_in[28]; end
    default: ;
endcase
end else if (!state_freeze) begin
 if(cen) begin
        // I
        case( data[1:0] )
            2'd0: idx_inc_II <= 6'd2;
            2'd1: idx_inc_II <= 6'd4;
            2'd2: idx_inc_II <= 6'd6;
            2'd3: idx_inc_II <= 6'd8;
        endcase
        sign_II      <= data[3];
        delta_idx_II <= en ? delta_idx_I : 6'd0;
        factor_II    <= en ? data[2:0] : 3'd0;
        qn_II        <= { 1'd0, lut[delta_idx_I]>>3};   // magnitude starts at step/8
        dn_II        <= { 1'b0, lut[delta_idx_I] };     // step size
        // II
        sign_III      <= sign_II;
        delta_idx_III <= factor_II[2] ? (delta_idx_II+idx_inc_II) : (delta_idx_II-6'd1);
        qn_III        <= factor_II[2] ? qn_II + dn_II : qn_II;
        dn_III        <= dn_II>>1;
        factor_III    <= factor_II;
        // III
        sign_IV      <= sign_III;
        qn_IV        <= factor_III[1] ? qn_III + dn_III : qn_III;
        dn_IV        <= dn_III>>1;
        factor_IV    <= factor_III[0];
        delta_idx_IV <=  delta_idx_III>6'd48 ?
            (factor_III[2] ? 6'd48 : 6'd0) :
            delta_idx_III;
        // IV
        sign_V      <= sign_IV;
        qn_V        <= factor_IV ? qn_IV + dn_IV : qn_IV;
        delta_idx_I <= delta_idx_IV;
    end

end
end

wire en_V;

ss_jt6295_sh_rst #(.WIDTH(1), .STAGES(4) ) u_enable
(
    .rst    ( rst       ),
    .clk    ( clk       ),
    .clk_en ( cen       ),
    .din    ( en        ),
    .drop   ( en_V      ),
    .state_freeze(state_freeze),
    .auto_ss_rd(auto_ss_rd), .auto_ss_wr(auto_ss_wr),
    .auto_ss_data_in(auto_ss_data_in),
    .auto_ss_device_idx(auto_ss_device_idx), .auto_ss_state_idx(auto_ss_state_idx),
    .auto_ss_base_device_idx(auto_ss_base_device_idx + 8'd1),
    .auto_ss_data_out(state_enable), .auto_ss_ack(ack_enable)
);

wire [3:0] att_V;

ss_jt6295_sh_rst #(.WIDTH(4), .STAGES(4) ) u_att
(
    .rst    ( rst       ),
    .clk    ( clk       ),
    .clk_en ( cen       ),
    .din    ( att       ),
    .drop   ( att_V     ),
    .state_freeze(state_freeze),
    .auto_ss_rd(auto_ss_rd), .auto_ss_wr(auto_ss_wr),
    .auto_ss_data_in(auto_ss_data_in),
    .auto_ss_device_idx(auto_ss_device_idx), .auto_ss_state_idx(auto_ss_state_idx),
    .auto_ss_base_device_idx(auto_ss_base_device_idx + 8'd2),
    .auto_ss_data_out(state_att), .auto_ss_ack(ack_att)
);


wire signed [11:0] snd_out;
reg  signed [11:0] snd_V, snd_VI;
reg  signed [13:0] unlim_V;
reg  signed [ 6:0] gain_lut[0:15];
reg  signed [ 6:0] gain_VI;
reg                ov_V;
wire signed [16:0] mul_VI = snd_VI * gain_VI;

always @(*) begin
    unlim_V = sign_V ? { {2{snd_out[11]}}, snd_out } - { 2'd0, qn_V } :
                        { {2{snd_out[11]}}, snd_out } + { 2'd0, qn_V };
    ov_V  = |(unlim_V[13:12] ^ {2{unlim_V[11]}});
    snd_V = !en_V ? 12'd0 :
             ov_V ? {unlim_V[13],{11{~unlim_V[13]}}} : unlim_V[11:0]; // clamp
end

always @(posedge clk, posedge rst) begin
    if(rst) begin
        snd_VI  <= 12'd0;
        gain_VI <= 7'd0;
        sound   <= 12'd0;
    end else if (state_write) begin
case (auto_ss_state_idx)
    3: begin snd_VI <= auto_ss_data_in[23:12]; end
    4: begin sound <= auto_ss_data_in[11:0]; gain_VI <= auto_ss_data_in[18:12]; end
    default: ;
endcase
end else if (!state_freeze) begin
 if(cen) begin
        snd_VI  <= snd_V;
        gain_VI <= gain_lut[att_V];
        sound   <= mul_VI[16:5];
    end

end
end

ss_jt6295_sh_rst #(.WIDTH(12), .STAGES(4) ) u_sound(
    .rst    ( rst       ),
    .clk    ( clk       ),
    .clk_en ( cen       ),
    .din    ( snd_V     ),
    .drop   ( snd_out   ),
    .state_freeze(state_freeze),
    .auto_ss_rd(auto_ss_rd), .auto_ss_wr(auto_ss_wr),
    .auto_ss_data_in(auto_ss_data_in),
    .auto_ss_device_idx(auto_ss_device_idx), .auto_ss_state_idx(auto_ss_state_idx),
    .auto_ss_base_device_idx(auto_ss_base_device_idx + 8'd3),
    .auto_ss_data_out(state_sound), .auto_ss_ack(ack_sound)
);

initial begin
lut[ 0] = 11'd0016; lut[ 1] = 11'd0017; lut[ 2] = 11'd0019; lut[ 3] = 11'd0021; lut[ 4] = 11'd0023; lut[ 5] = 11'd0025; lut[ 6] = 11'd0028;
lut[ 7] = 11'd0031; lut[ 8] = 11'd0034; lut[ 9] = 11'd0037; lut[10] = 11'd0041; lut[11] = 11'd0045; lut[12] = 11'd0050; lut[13] = 11'd0055;
lut[14] = 11'd0060; lut[15] = 11'd0066; lut[16] = 11'd0073; lut[17] = 11'd0080; lut[18] = 11'd0088; lut[19] = 11'd0097; lut[20] = 11'd0107;
lut[21] = 11'd0118; lut[22] = 11'd0130; lut[23] = 11'd0143; lut[24] = 11'd0157; lut[25] = 11'd0173; lut[26] = 11'd0190; lut[27] = 11'd0209;
lut[28] = 11'd0230; lut[29] = 11'd0253; lut[30] = 11'd0279; lut[31] = 11'd0307; lut[32] = 11'd0337; lut[33] = 11'd0371; lut[34] = 11'd0408;
lut[35] = 11'd0449; lut[36] = 11'd0494; lut[37] = 11'd0544; lut[38] = 11'd0598; lut[39] = 11'd0658; lut[40] = 11'd0724; lut[41] = 11'd0796;
lut[42] = 11'd0876; lut[43] = 11'd0963; lut[44] = 11'd1060; lut[45] = 11'd1166; lut[46] = 11'd1282; lut[47] = 11'd1411; lut[48] = 11'd1552;
end

// Attenuation: about 3 dB per step; 9-15 mute.
initial begin
    gain_lut[0]  = 7'd32;
    gain_lut[1]  = 7'd22;
    gain_lut[2]  = 7'd16;
    gain_lut[3]  = 7'd11;
    gain_lut[4]  = 7'd8;
    gain_lut[5]  = 7'd6;
    gain_lut[6]  = 7'd4;
    gain_lut[7]  = 7'd3;
    gain_lut[8]  = 7'd2;
    gain_lut[9]  = 7'd0; gain_lut[10] = 7'd0; gain_lut[11] = 7'd0;
    gain_lut[12] = 7'd0; gain_lut[13] = 7'd0; gain_lut[14] = 7'd0;
    gain_lut[15] = 7'd0;
end



reg [31:0] local_state;
reg local_ack;
always @* begin
local_state = 0; local_ack = 0;
if (auto_ss_rd && device_match) begin
case (auto_ss_state_idx)
0: begin
local_ack = 1;
local_state[11:0] = dn_II;
local_state[23:12] = dn_III;
end
1: begin
local_ack = 1;
local_state[11:0] = dn_IV;
local_state[23:12] = qn_II;
end
2: begin
local_ack = 1;
local_state[11:0] = qn_III;
local_state[23:12] = qn_IV;
end
3: begin
local_ack = 1;
local_state[11:0] = qn_V;
local_state[23:12] = snd_VI;
end
4: begin
local_ack = 1;
local_state[11:0] = sound;
local_state[18:12] = gain_VI;
local_state[24:19] = delta_idx_I;
local_state[30:25] = delta_idx_II;
end
5: begin
local_ack = 1;
local_state[5:0] = delta_idx_III;
local_state[11:6] = delta_idx_IV;
local_state[17:12] = idx_inc_II;
local_state[20:18] = factor_II;
local_state[23:21] = factor_III;
local_state[24] = factor_IV;
local_state[25] = sign_II;
local_state[26] = sign_III;
local_state[27] = sign_IV;
local_state[28] = sign_V;
end
default: ;
endcase
end
end
assign auto_ss_data_out = local_state | state_enable | state_att | state_sound;
assign auto_ss_ack = local_ack | ack_enable | ack_att | ack_sound;
endmodule

/*  This file is part of JT6295.
    JT6295 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT6295 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT6295.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 6-1-2020 */



module ss_jt6295_acc(
    input                rst,
    input filter_rst,
    input                clk,
    input state_freeze,
    input                cen,
    input                cen4,
    input  signed [11:0] sound_in,
    output signed [13:0] sound_out,
    output               sample,
    input auto_ss_rd,
    input auto_ss_wr,
    input [31:0] auto_ss_data_in,
    input [7:0] auto_ss_device_idx,
    input [15:0] auto_ss_state_idx,
    input [7:0] auto_ss_base_device_idx,
    output wire [31:0] auto_ss_data_out,
    output wire auto_ss_ack
);
wire device_match = auto_ss_device_idx == auto_ss_base_device_idx;
wire state_write = auto_ss_wr && device_match;

/* verilator lint_off WIDTH */
parameter INTERPOL=0; // only 0 (no interpolator) is supported

reg signed [13:0] acc, sum;
reg signed [15:0] fir_din;
always @(posedge clk, posedge rst) begin
if (rst) fir_din <= 0;
else if (state_write) begin
case (auto_ss_state_idx)
    0: begin fir_din <= auto_ss_data_in[15:0]; end
    default: ;
endcase
end else if (!state_freeze) begin
 if (filter_rst) fir_din <= 0;

end
end

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        acc <= 14'd0;
    end else if (state_write) begin
case (auto_ss_state_idx)
    0: begin acc <= auto_ss_data_in[29:16]; end
    default: ;
endcase
end else if (!state_freeze) begin
 if(cen4) begin
        acc <= cen ? sound_in : acc + sound_in;
    end

end
end

always @(posedge clk, posedge rst) begin
    if( rst ) begin
        sum <= 14'd0;
    end else if (state_write) begin
case (auto_ss_state_idx)
    1: begin sum <= auto_ss_data_in[13:0]; end
    default: ;
endcase
end else if (!state_freeze) begin
 if(cen) begin
        sum <= acc;
    end

end
end

assign sound_out = sum;
assign sample = cen;

/* verilator lint_on WIDTH */
reg [31:0] local_state;
reg local_ack;
always @* begin
local_state = 0; local_ack = 0;
if (auto_ss_rd && device_match) begin
case (auto_ss_state_idx)
0: begin
local_ack = 1;
local_state[15:0] = fir_din;
local_state[29:16] = acc;
end
1: begin
local_ack = 1;
local_state[13:0] = sum;
end
default: ;
endcase
end
end
assign auto_ss_data_out = local_state;
assign auto_ss_ack = local_ack;
// synthesis translate_off
initial if (INTERPOL != 0) $fatal(1, "Only INTERPOL=0 is supported");
// synthesis translate_on
endmodule

/*  This file is part of JT6295.
    JT6295 program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    JT6295 program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with JT6295.  If not, see <http://www.gnu.org/licenses/>.

    Author: Jose Tejada Gomez. Twitter: @topapate
    Version: 1.0
    Date: 6-1-2020 */

module ss_jt6295(
    input rst,
    input filter_rst,
    input clk,
    input state_freeze,
    output state_frozen,
    output rom_request,
    output resume_busy,
    input cen,
    input ss,
    input wrn,
    input [7:0] din,
    output [7:0] dout,
    output [17:0] rom_addr,
    input [7:0] rom_data,
    input rom_ok,
    output signed [13:0] sound,
    output sample,
    input auto_ss_rd,
    input auto_ss_wr,
    input [31:0] auto_ss_data_in,
    input [7:0] auto_ss_device_idx,
    input [15:0] auto_ss_state_idx,
    input [7:0] auto_ss_base_device_idx,
    output wire [31:0] auto_ss_data_out,
    output wire auto_ss_ack
);
wire device_match = auto_ss_device_idx == auto_ss_base_device_idx;
wire state_write = auto_ss_wr && device_match;
wire [31:0] state_timing;
wire ack_timing;
wire [31:0] state_rom;
wire ack_rom;
wire [31:0] state_ctrl;
wire ack_ctrl;
wire [31:0] state_serial;
wire ack_serial;
wire [31:0] state_adpcm;
wire ack_adpcm;
wire [31:0] state_acc;
wire ack_acc;
reg freeze_seen, resume_pending;
wire normal_freeze;


parameter INTERPOL=0; // only 0 (no interpolator) is supported
parameter SAMPLE=0;   // sample pin: 0 = cen_48k, 1 = accumulator sample rate

wire        cen_sr;  // sample rate
wire        cen_sr4, cen_sr4b; // 4x sample rate
wire        cen_sr32, // 32x sample rate
            cen_48k,  // cen*6/125
            cen_eff;  // accumulator sample rate

wire [ 3:0] busy, ack, start, stop;
wire [17:0] start_addr, stop_addr ,
            ch_addr;
wire [ 9:0] ctrl_addr;
wire [ 7:0] ch_data, ctrl_data;
wire [ 3:0] data0, data1, data2, data3, pipe_data;
wire [ 3:0] att, pipe_att;
wire        ctrl_ok, ctrl_cs, zero;
wire        pipe_en;
wire signed [11:0] pipe_snd;

assign dout   = { 4'hf, busy | start };
assign sample = !normal_freeze && (SAMPLE==0 ? cen_48k : cen_eff);

ss_jt6295_timing u_timing(
    .clk        ( clk       ),
    .cen        ( cen       ),
    .ss         ( ss        ),
    .cen_sr     ( cen_sr    ),
    .cen_sr4    ( cen_sr4   ),
    .cen_sr4b   ( cen_sr4b  ),
    .cen_sr32   ( cen_sr32  ),
    .cen_48k    ( cen_48k   ),
    .state_freeze(normal_freeze),
    .auto_ss_rd(auto_ss_rd), .auto_ss_wr(auto_ss_wr),
    .auto_ss_data_in(auto_ss_data_in),
    .auto_ss_device_idx(auto_ss_device_idx), .auto_ss_state_idx(auto_ss_state_idx),
    .auto_ss_base_device_idx(auto_ss_base_device_idx + 8'd1),
    .auto_ss_data_out(state_timing), .auto_ss_ack(ack_timing)
);

ss_jt6295_rom u_rom(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .cen4       ( cen_sr4       ),
    .cen32      ( cen_sr32      ),
    .adpcm_addr ( ch_addr       ),
    .ctrl_addr  ( { 8'd0, ctrl_addr } ),
    .adpcm_dout ( ch_data       ),
    .ctrl_dout  ( ctrl_data     ),
    .ctrl_ok    ( ctrl_ok       ),
    .rom_addr   ( rom_addr      ),
    .rom_data   ( rom_data      ),
    .rom_ok     ( rom_ok        ),
    .state_freeze(normal_freeze),
    .auto_ss_rd(auto_ss_rd), .auto_ss_wr(auto_ss_wr),
    .auto_ss_data_in(auto_ss_data_in),
    .auto_ss_device_idx(auto_ss_device_idx), .auto_ss_state_idx(auto_ss_state_idx),
    .auto_ss_base_device_idx(auto_ss_base_device_idx + 8'd2),
    .auto_ss_data_out(state_rom), .auto_ss_ack(ack_rom)
);

ss_jt6295_ctrl u_ctrl(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .cen1       ( cen_sr        ),
    .cen4       ( cen_sr4       ),
    .wrn        ( wrn           ),
    .din        ( din           ),
    .start_addr ( start_addr    ),
    .stop_addr  ( stop_addr     ),
    .att        ( att           ),
    .rom_addr   ( ctrl_addr     ),
    .rom_data   ( ctrl_data     ),
    .rom_ok     ( ctrl_ok       ),

    .start      ( start         ),
    .stop       ( stop          ),
    .busy       ( busy          ),
    .ack        ( ack           ),
    .zero       ( zero          ),
    .state_freeze(normal_freeze),
    .auto_ss_rd(auto_ss_rd), .auto_ss_wr(auto_ss_wr),
    .auto_ss_data_in(auto_ss_data_in),
    .auto_ss_device_idx(auto_ss_device_idx), .auto_ss_state_idx(auto_ss_state_idx),
    .auto_ss_base_device_idx(auto_ss_base_device_idx + 8'd3),
    .auto_ss_data_out(state_ctrl), .auto_ss_ack(ack_ctrl)
);

ss_jt6295_serial u_serial(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .cen        ( cen_sr        ),
    .cen4       ( cen_sr4       ),
    .start_addr ( start_addr    ),
    .stop_addr  ( stop_addr     ),
    .att        ( att           ),
    .start      ( start         ),
    .stop       ( stop          ),
    .busy       ( busy          ),
    .ack        ( ack           ),
    .zero       ( zero          ),
    .rom_addr   ( ch_addr       ),
    .rom_data   ( ch_data       ),
    .pipe_en    ( pipe_en       ),
    .pipe_att   ( pipe_att      ),
    .pipe_data  ( pipe_data     ),
    .state_freeze(normal_freeze),
    .auto_ss_rd(auto_ss_rd), .auto_ss_wr(auto_ss_wr),
    .auto_ss_data_in(auto_ss_data_in),
    .auto_ss_device_idx(auto_ss_device_idx), .auto_ss_state_idx(auto_ss_state_idx),
    .auto_ss_base_device_idx(auto_ss_base_device_idx + 8'd4),
    .auto_ss_data_out(state_serial), .auto_ss_ack(ack_serial)
);

ss_jt6295_adpcm u_adpcm(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .cen        ( cen_sr4       ),
    .en         ( pipe_en       ),
    .att        ( pipe_att      ),
    .data       ( pipe_data     ),
    .sound      ( pipe_snd      ),
    .state_freeze(normal_freeze),
    .auto_ss_rd(auto_ss_rd), .auto_ss_wr(auto_ss_wr),
    .auto_ss_data_in(auto_ss_data_in),
    .auto_ss_device_idx(auto_ss_device_idx), .auto_ss_state_idx(auto_ss_state_idx),
    .auto_ss_base_device_idx(auto_ss_base_device_idx + 8'd6),
    .auto_ss_data_out(state_adpcm), .auto_ss_ack(ack_adpcm)
);

ss_jt6295_acc #(.INTERPOL(INTERPOL)) u_acc(
    .rst        ( rst           ),
    .clk        ( clk           ),
    .cen        ( cen_sr        ),
    .cen4       ( cen_sr4       ),
    .sound_in   ( pipe_snd      ),
    .sound_out  ( sound         ),
    .sample     ( cen_eff       ),
    .state_freeze(normal_freeze),
    .auto_ss_rd(auto_ss_rd), .auto_ss_wr(auto_ss_wr),
    .auto_ss_data_in(auto_ss_data_in),
    .auto_ss_device_idx(auto_ss_device_idx), .auto_ss_state_idx(auto_ss_state_idx),
    .auto_ss_base_device_idx(auto_ss_base_device_idx + 8'd10),
    .auto_ss_data_out(state_acc), .auto_ss_ack(ack_acc)
    , .filter_rst(filter_rst)
);


wire [31:0] local_state = 32'd0;
wire local_ack = 1'b0;
assign auto_ss_data_out = local_state | state_timing | state_rom | state_ctrl | state_serial | state_adpcm | state_acc;
assign auto_ss_ack = local_ack | ack_timing | ack_rom | ack_ctrl | ack_serial | ack_adpcm | ack_acc;
// After state_freeze drops, stay frozen until rom_ok.
assign normal_freeze = state_freeze || (resume_pending && !rom_ok);
assign state_frozen = state_freeze && freeze_seen;
assign rom_request = !rst && !state_freeze;
assign resume_busy = !state_freeze && resume_pending && !rom_ok;
always @(posedge clk) begin
    if (rst) begin freeze_seen <= 0; resume_pending <= 0; end
    else begin
        freeze_seen <= state_freeze;
        if (state_freeze) resume_pending <= 1;
        else if (rom_ok) resume_pending <= 0;
    end
end
// synthesis translate_off
initial if (INTERPOL != 0) $fatal(1, "Only INTERPOL=0 is supported");
// synthesis translate_on
endmodule
