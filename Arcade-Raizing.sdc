# Derives the related PLL clocks and their uncertainty.
derive_pll_clocks
derive_clock_uncertainty

# Defines the inverted forwarded SDRAM clock and its I/O delays.
create_generated_clock -name SDRAM_CLK -divide_by 1 -invert \
    -source [get_pins {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    [get_ports SDRAM_CLK]
set_input_delay -clock SDRAM_CLK -max 8.0 [get_ports {SDRAM_DQ[*]}]
set_input_delay -clock SDRAM_CLK -min 2.5 [get_ports {SDRAM_DQ[*]}]
set_output_delay -clock SDRAM_CLK -max 2.5 \
    [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]
set_output_delay -clock SDRAM_CLK -min -1.8 \
    [get_ports {SDRAM_A[*] SDRAM_BA[*] SDRAM_DQ[*] SDRAM_DQML SDRAM_DQMH SDRAM_nCS SDRAM_nRAS SDRAM_nCAS SDRAM_nWE SDRAM_CKE}]

# Checks DQ setup at the second system edge.
# Leaves the DQ hold end edge unshifted.
set sorcer_dq [get_ports {SDRAM_DQ[*]}]
set sorcer_capture [get_registers {*|memory|backend|controller|rdata_reg[*]}]
if {[get_collection_size $sorcer_dq] != 16 || [get_collection_size $sorcer_capture] != 16} {
    error "Expected exactly sixteen native SDRAM DQ capture paths"
}
set_multicycle_path -setup -end 2 -from $sorcer_dq -to $sorcer_capture
set_multicycle_path -hold -end 0 -from $sorcer_dq -to $sorcer_capture
