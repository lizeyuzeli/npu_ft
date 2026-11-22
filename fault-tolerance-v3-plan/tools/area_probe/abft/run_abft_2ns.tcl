set target_library "/home/tools/tech_lib/tsmc12/tmp/tcbn12ffcllbwp6t16p96cpdffgnp0p88v0c.db"
set link_library "* $target_library"
analyze -format sverilog ../../abft_int_probe.sv
elaborate abft_int_probe
current_design abft_int_probe
link
create_clock -period 2.0 clk
set_input_delay 0.2 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
set_output_delay 0.2 -clock clk [all_outputs]
compile
redirect -file area_abft_2ns.rpt { report_area }
redirect -file timing_abft_2ns.rpt { report_timing }
exit
