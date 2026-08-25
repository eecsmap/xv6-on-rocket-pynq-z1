set_property PACKAGE_PIN H16 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]
create_clock -name gclk_0 -period "8" -waveform {0.0 4.0} [get_ports clk]
