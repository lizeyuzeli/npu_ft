set target_library "/home/tools/tech_lib/tsmc12/tmp/tcbn12ffcllbwp6t16p96cpdffgnp0p88v0c.db"
set link_library "* $target_library"
foreach top {mt_sh0 mt_sh1} {
  analyze -format sverilog /home/lizeyu/eng/npu_ft/fault-tolerance-v3-plan/tools/area_probe/mt_shadow_probe.sv
  elaborate $top
  current_design $top
  link
  create_clock -period 1.0 clk
  set_input_delay 0.2 -clock clk [remove_from_collection [all_inputs] [get_ports clk]]
  set_output_delay 0.2 -clock clk [all_outputs]
  compile
  redirect -file area_$top.rpt { report_area }
  redirect -file timing_$top.rpt { report_timing }
  remove_design -all
}
exit
