`define DISPATCH3
`define ZVE32F_ON
`define ZVT_ON
`define ZVFBFWMA_ON
`define ARBITER_ON
`define VLEN_128
`include "rvv_backend.svh"
module top;
  initial begin
    $display("ALU_RS_t  %0d", $bits(ALU_RS_t));
    $display("MUL_RS_t  %0d", $bits(MUL_RS_t));
    $display("DIV_RS_t  %0d", $bits(DIV_RS_t));
    $display("FALU_RS_t %0d", $bits(FALU_RS_t));
    $display("PU2ROB_t  %0d", $bits(PU2ROB_t));
    $display("DP2ROB_t  %0d", $bits(DP2ROB_t));
    $display("RES_ROB_t %0d", $bits(RES_ROB_t));
    $finish;
  end
endmodule
