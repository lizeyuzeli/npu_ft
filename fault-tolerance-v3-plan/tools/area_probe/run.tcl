set target_library "/home/tools/tech_lib/tsmc12/tmp/tcbn12ffcllbwp6t16p96cpdffgnp0p88v0c.db"
set link_library "* $target_library"
analyze -format sverilog ft_area.sv
foreach top {rm_v1 rm_v2 rm_v3 cmp_full cmp_sig} {
  elaborate $top
  current_design $top
  link
  if {[sizeof_collection [get_ports -quiet clk]]} { create_clock -period 1.0 clk }
  set_max_delay 1.0 -from [all_inputs] -to [all_outputs]
  compile
  redirect -file area_$top.rpt { report_area }
  remove_design -all
  analyze -format sverilog ft_area.sv
}
exit
