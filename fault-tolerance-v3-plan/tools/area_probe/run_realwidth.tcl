set target_library "/home/tools/tech_lib/tsmc12/tmp/tcbn12ffcllbwp6t16p96cpdffgnp0p88v0c.db"
set link_library "* $target_library"
foreach top {p1 p2 p3 p4} {
  analyze -format sverilog rm2.sv
  elaborate $top
  current_design $top
  link
  create_clock -period 1.0 clk
  set_max_delay 1.0 -from [all_inputs] -to [all_outputs]
  compile
  redirect -file area_$top.rpt { report_area }
  remove_design -all
}
exit
