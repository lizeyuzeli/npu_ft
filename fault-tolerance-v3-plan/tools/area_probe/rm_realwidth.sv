// replay_mem probes with real main widths: W=565 (=ALU_RS_t), unit read widths ALU565 MUL407 DIV284 FALU502, D=16
module rmx #(parameter int NW=3, parameter int NRU=3) (   // NRU = read ports per unit (0 => single shared port)
  input  logic clk,
  input  logic [NW-1:0] wen, input logic [NW-1:0][3:0] widx, input logic [NW-1:0][564:0] wdata,
  input  logic [3:0][2:0][3:0] ridx,
  output logic [2:0][564:0] r_alu, output logic [2:0][406:0] r_mul,
  output logic [2:0][283:0] r_div, output logic [2:0][501:0] r_falu,
  input  logic [3:0] sidx, output logic [564:0] r_shared);
  logic [15:0][564:0] mem;
  always_ff @(posedge clk) for (int i=0;i<NW;i++) if (wen[i]) mem[widx[i]] <= wdata[i];
  always_comb begin
    r_alu='0; r_mul='0; r_div='0; r_falu='0; r_shared='0;
    if (NRU==0) r_shared = mem[sidx];
    else for (int p=0;p<NRU;p++) begin
      r_alu[p]  = mem[ridx[0][p]][564:0];
      r_mul[p]  = mem[ridx[1][p]][406:0];
      r_div[p]  = mem[ridx[2][p]][283:0];
      r_falu[p] = mem[ridx[3][p]][501:0];
    end
  end
endmodule
module p1 (input logic clk, input logic [11:0] wen, input logic [11:0][3:0] widx, input logic [11:0][564:0] wdata,
  input logic [3:0][2:0][3:0] ridx, output logic [2:0][564:0] r_alu, output logic [2:0][406:0] r_mul,
  output logic [2:0][283:0] r_div, output logic [2:0][501:0] r_falu, input logic [3:0] sidx, output logic [564:0] r_shared);
  rmx #(.NW(12),.NRU(3)) u(.*); endmodule
module p2 (input logic clk, input logic [2:0] wen, input logic [2:0][3:0] widx, input logic [2:0][564:0] wdata,
  input logic [3:0][2:0][3:0] ridx, output logic [2:0][564:0] r_alu, output logic [2:0][406:0] r_mul,
  output logic [2:0][283:0] r_div, output logic [2:0][501:0] r_falu, input logic [3:0] sidx, output logic [564:0] r_shared);
  rmx #(.NW(3),.NRU(3)) u(.*); endmodule
module p3 (input logic clk, input logic [2:0] wen, input logic [2:0][3:0] widx, input logic [2:0][564:0] wdata,
  input logic [3:0][2:0][3:0] ridx, output logic [2:0][564:0] r_alu, output logic [2:0][406:0] r_mul,
  output logic [2:0][283:0] r_div, output logic [2:0][501:0] r_falu, input logic [3:0] sidx, output logic [564:0] r_shared);
  rmx #(.NW(3),.NRU(1)) u(.*); endmodule
module p4 (input logic clk, input logic [2:0] wen, input logic [2:0][3:0] widx, input logic [2:0][564:0] wdata,
  input logic [3:0][2:0][3:0] ridx, output logic [2:0][564:0] r_alu, output logic [2:0][406:0] r_mul,
  output logic [2:0][283:0] r_div, output logic [2:0][501:0] r_falu, input logic [3:0] sidx, output logic [564:0] r_shared);
  rmx #(.NW(3),.NRU(0)) u(.*); endmodule
