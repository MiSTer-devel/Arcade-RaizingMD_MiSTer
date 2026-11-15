// SPDX-License-Identifier: GPL-3.0-or-later
// Core PLL and per-board clock enables.
module pll (
    input refclk,rst,
    output locked,outclk_0,outclk_1
);
    // Keeps the pll|pll_inst|altera_pll_i hierarchy used by the SDC clock groups.
    raizing_clock81 pll_inst(.*);
endmodule

module raizing_clock81 (
    input refclk,rst,
    output locked,outclk_0,outclk_1
);
    altera_pll #(
        .fractional_vco_multiplier("false"),
        .reference_clock_frequency("50.0 MHz"),.operation_mode("direct"),
        .number_of_clocks(2),
        .output_clock_frequency0("81.000000 MHz"),.phase_shift0("0 ps"),.duty_cycle0(50),
        .output_clock_frequency1("81.000000 MHz"),.phase_shift1("2469 ps"),.duty_cycle1(50),
        .pll_type("General"),.pll_subtype("General")
    ) altera_pll_i (
        .refclk(refclk),.rst(rst),.locked(locked),.outclk({outclk_1,outclk_0}),
        .fbclk(1'b0),.fboutclk()
    );
endmodule

module raizing_clocken_early (
    input wire clk, reset,
    input wire garegga,   // reset-stable Garegga audio cadence select
    output wire pixel_ce, half_ce, sample_ce,
    output wire ym_ce, ym_phase1_ce, z80_ce, oki_ce,
    output wire [3:0] pixel_phase
);
    reg [3:0] pixel_count;
    reg [5:0] ym_count;
    reg [6:0] oki_count;
    reg [6:0] z80_residue;
    reg audio_half;   // Garegga: toggles per Z80 tick for the 2 MHz phase-1/OKI tick
    wire [7:0] z80_sum = {1'b0,z80_residue} + 8'd4;
    assign pixel_phase = pixel_count;
    assign pixel_ce = !reset && pixel_count == 4'd11;
    assign half_ce = !reset && (pixel_count == 4'd5 || pixel_count == 4'd11);
    assign sample_ce = !reset && pixel_count == 4'd5;
    assign z80_ce = !reset && z80_sum >= 8'd81;   // 4 MHz
    // Sorcer/Kingdom: YM 3.375, phase 1 1.6875, OKI 1 MHz; Garegga: YM 4, phase 1/OKI 2 MHz.
    wire early_ym = !reset && (ym_count == 6'd23 || ym_count == 6'd47);
    wire early_phase1 = !reset && ym_count == 6'd47;
    wire early_oki = !reset && oki_count == 7'd80;
    wire garegga_half = z80_ce && audio_half;
    assign ym_ce = garegga ? z80_ce : early_ym;
    assign ym_phase1_ce = garegga ? garegga_half : early_phase1;
    assign oki_ce = garegga ? garegga_half : early_oki;
    always @(posedge clk) begin
        if (reset) begin
            pixel_count <= 0;
            ym_count <= 0;
            oki_count <= 0;
            z80_residue <= 0;
            audio_half <= 0;
        end else begin
            pixel_count <= pixel_count == 4'd11 ? 4'd0 : pixel_count + 4'd1;
            ym_count <= ym_count == 6'd47 ? 6'd0 : ym_count + 6'd1;
            oki_count <= oki_count == 7'd80 ? 7'd0 : oki_count + 7'd1;
            z80_residue <= 7'(z80_ce ? z80_sum - 8'd81 : z80_sum);
            if (z80_ce) audio_half <= !audio_half;
        end
    end
endmodule

// Batrider cadence: Z80, YM and OKI enables from a fractional 16 MHz tick.
module raizing_clocken_batrider (
    input wire clk, reset,
    output wire pixel_ce, half_ce, sample_ce,
    output wire ym_ce, ym_phase1_ce, z80_ce, oki_ce,
    output wire [3:0] pixel_phase
);
    reg [3:0] pixel_count;
    reg audio_half;
    reg [6:0] master_residue;
    reg [1:0] z80_div, ym_div;
    reg [2:0] oki_div;
    wire [7:0] master_sum = {1'b0,master_residue} + 8'd16;
    wire master_ce = !reset && master_sum >= 8'd81;
    assign pixel_phase = pixel_count;
    assign pixel_ce = !reset && pixel_count == 4'd11;
    assign half_ce = !reset && (pixel_count == 4'd5 || pixel_count == 4'd11);
    assign sample_ce = !reset && pixel_count == 4'd5;
    // 16 MHz /3, /4, /5 (32 MHz /6, /8, /10): Z80, YM, OKI.
    assign z80_ce = master_ce && z80_div == 2'd2;
    assign ym_ce = master_ce && ym_div == 2'd3;
    assign ym_phase1_ce = ym_ce && audio_half;
    assign oki_ce = master_ce && oki_div == 3'd4;
    always @(posedge clk) begin
        if (reset) begin
            pixel_count <= 0;
            audio_half <= 0;
            master_residue <= 0;
            z80_div <= 0;
            ym_div <= 0;
            oki_div <= 0;
        end else begin
            pixel_count <= pixel_count == 4'd11 ? 4'd0 : pixel_count + 4'd1;
            if(ym_ce) audio_half <= !audio_half;
            master_residue <= 7'(master_ce ? master_sum - 8'd81 : master_sum);
            if(master_ce) begin
                z80_div <= z80_div == 2'd2 ? 2'd0 : z80_div + 2'd1;
                ym_div <= ym_div == 2'd3 ? 2'd0 : ym_div + 2'd1;
                oki_div <= oki_div == 3'd4 ? 3'd0 : oki_div + 3'd1;
            end
        end
    end
endmodule

// Bakraid cadence: Z80, YMZ280B clock and sample tick; phase held and reloaded for save states.
module raizing_clocken_bakraid (
    input wire clk, reset,
    input wire audio_hold,state_load,clear_state_error,
    input wire [31:0] state_in,
    output wire [31:0] state_out,
    output reg state_error,
    output wire pixel_ce, half_ce, video_sample_ce,
    output wire z80_ce, ymz_ce, ymz_sample_ce,
    output wire [3:0] pixel_phase
);
    reg [3:0] pixel_count;
    reg [6:0] board_residue;
    reg [1:0] z80_div;
    reg [12:0] ymz_residue;
    reg [7:0] ymz_sample_div;
    wire [7:0] board_sum = {1'b0,board_residue} + 8'd16;
    wire board_ce = !reset && !audio_hold && board_sum >= 8'd81;
    wire [13:0] ymz_sum = {1'b0,ymz_residue} + 14'd1176;

    assign pixel_phase = pixel_count;
    assign pixel_ce = !reset && pixel_count == 4'd11;
    assign half_ce = !reset && (pixel_count == 4'd5 || pixel_count == 4'd11);
    assign video_sample_ce = !reset && pixel_count == 4'd5;
    assign z80_ce = board_ce && z80_div == 2'd2;
    // 81 MHz * 1176/5625 = 16.9344 MHz; divide by 192 for 88.2 kHz.
    assign ymz_ce = !reset && !audio_hold && ymz_sum >= 14'd5625;
    assign ymz_sample_ce = ymz_ce && ymz_sample_div == 8'd191;
    assign state_out={2'd0,ymz_sample_div,ymz_residue,board_residue,z80_div};
    wire valid_state=state_in[31:30]==0 && state_in[1:0]<3 &&
        state_in[8:2]<81 && state_in[21:9]<5625 && state_in[29:22]<192;

    always @(posedge clk) begin
        if (reset) begin
            pixel_count <= 0;
            board_residue <= 0;
            z80_div <= 0;
            ymz_residue <= 0;
            ymz_sample_div <= 0;
            state_error <= 0;
        end else begin
            if(clear_state_error) state_error<=0;
            pixel_count <= pixel_count == 4'd11 ? 4'd0 : pixel_count + 4'd1;
            if(state_load) begin
                state_error<=!audio_hold || !valid_state;
                if(audio_hold && valid_state)
                    {ymz_sample_div,ymz_residue,board_residue,z80_div}<=state_in[29:0];
            end else if(!audio_hold) begin
                board_residue <= 7'(board_ce ? board_sum - 8'd81 : board_sum);
                if (board_ce) z80_div <= z80_div == 2'd2 ? 2'd0 : z80_div + 2'd1;
                ymz_residue <= 13'(ymz_ce ? ymz_sum - 14'd5625 : ymz_sum);
                if (ymz_ce) ymz_sample_div <= ymz_sample_div == 8'd191 ? 8'd0 : ymz_sample_div + 8'd1;
            end
        end
    end
endmodule

// Clock enables for the latched board: common pixel divider, per-board audio cadence.
module raizing_clocken (
    input wire clk, reset,
    input wire garegga, batrider, bakraid,   // reset-stable selects; none = Sorcer/Kingdom
    input wire audio_hold, state_load, clear_state_error,   // Bakraid audio-phase state
    input wire [31:0] state_in,
    output wire [31:0] state_out,
    output wire state_error,
    output wire pixel_ce, half_ce, sample_ce,
    output wire ym_ce, ym_phase1_ce, z80_ce, oki_ce, ymz_ce, ymz_sample_ce,
    output wire [3:0] pixel_phase
);
    wire e_ym, e_phase1, e_z80, e_oki, b_ym, b_phase1, b_z80, b_oki, k_z80, k_ymz, k_sample;
    raizing_clocken_early early (
        .clk(clk), .reset(reset), .garegga(garegga), .pixel_ce(pixel_ce), .half_ce(half_ce),
        .sample_ce(sample_ce), .ym_ce(e_ym), .ym_phase1_ce(e_phase1), .z80_ce(e_z80), .oki_ce(e_oki),
        .pixel_phase(pixel_phase));
    raizing_clocken_batrider batrider_cadence (
        .clk(clk), .reset(reset), .pixel_ce(), .half_ce(), .sample_ce(), .ym_ce(b_ym),
        .ym_phase1_ce(b_phase1), .z80_ce(b_z80), .oki_ce(b_oki), .pixel_phase());
    raizing_clocken_bakraid bakraid_cadence (
        .clk(clk), .reset(reset), .audio_hold(audio_hold), .state_load(state_load),
        .clear_state_error(clear_state_error), .state_in(state_in), .state_out(state_out),
        .state_error(state_error), .pixel_ce(), .half_ce(), .video_sample_ce(), .z80_ce(k_z80),
        .ymz_ce(k_ymz), .ymz_sample_ce(k_sample), .pixel_phase());
    assign z80_ce = bakraid ? k_z80 : batrider ? b_z80 : e_z80;
    assign ym_ce = batrider ? b_ym : e_ym;
    assign ym_phase1_ce = batrider ? b_phase1 : e_phase1;
    assign oki_ce = batrider ? b_oki : e_oki;
    assign ymz_ce = k_ymz;
    assign ymz_sample_ce = k_sample;
endmodule
