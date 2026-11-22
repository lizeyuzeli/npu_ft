// replay_mem style storage: D entries x W bits, NW write sources, NR read ports
module rm #(parameter int W=596, D=16, NW=12, NR=12) (
  input  logic clk,
  input  logic [NW-1:0] wen,
  input  logic [NW-1:0][$clog2(D)-1:0] widx,
  input  logic [NW-1:0][W-1:0] wdata,
  input  logic [NR-1:0][$clog2(D)-1:0] ridx,
  output logic [NR-1:0][W-1:0] rdata);
  logic [D-1:0][W-1:0] mem;
  always_ff @(posedge clk)
    for (int i=0;i<NW;i++) if (wen[i]) mem[widx[i]] <= wdata[i];
  always_comb for (int r=0;r<NR;r++) rdata[r] = mem[ridx[r]];
endmodule
module rm_v1 (input logic clk, input logic [11:0] wen, input logic [11:0][3:0] widx, input logic [11:0][595:0] wdata,
              input logic [11:0][3:0] ridx, output logic [11:0][595:0] rdata);
  rm #(.NW(12),.NR(12)) u(.*);
endmodule
module rm_v2 (input logic clk, input logic [2:0] wen, input logic [2:0][3:0] widx, input logic [2:0][595:0] wdata,
              input logic [11:0][3:0] ridx, output logic [11:0][595:0] rdata);
  rm #(.NW(3),.NR(12)) u(.*);
endmodule
module rm_v3 (input logic clk, input logic [2:0] wen, input logic [2:0][3:0] widx, input logic [2:0][595:0] wdata,
              input logic [0:0][3:0] ridx, output logic [0:0][595:0] rdata);
  rm #(.NW(3),.NR(1)) u(.*);
endmodule
// full 128b compare of incoming copy-2 result against res_mem[entry] (res_mem itself is baseline -> input port)
module cmp_full (input logic [15:0][127:0] res_mem, input logic [3:0][127:0] d, input logic [3:0][3:0] idx,
                 output logic [3:0] mismatch);
  always_comb for (int p=0;p<4;p++) mismatch[p] = (d[p] != res_mem[idx[p]]);
endmodule
// 16b XOR-fold signature: stored at copy-1 write, compared at copy-2 write
module cmp_sig (input logic clk, input logic [3:0] first, input logic [3:0][127:0] d, input logic [3:0][3:0] idx,
                output logic [3:0] mismatch);
  logic [15:0][15:0] sig_mem; logic [3:0][15:0] s;
  always_comb for (int p=0;p<4;p++) begin s[p]='0; for (int k=0;k<8;k++) s[p]^=d[p][k*16+:16]; end
  always_ff @(posedge clk) for (int p=0;p<4;p++) if (first[p]) sig_mem[idx[p]] <= s[p];
  always_comb for (int p=0;p<4;p++) mismatch[p] = !first[p] && (s[p] != sig_mem[idx[p]]);
endmodule
