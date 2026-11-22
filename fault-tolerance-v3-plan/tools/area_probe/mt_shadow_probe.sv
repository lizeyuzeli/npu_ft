// Area probe: shadow per-byte parity array next to zvt_mt (TE=16, VLEN=128).
// Taps only the zvt_mt port signals (no change to zvt_mt.sv); decodes addresses
// independently, so a main-array address/decode fault shows up as a parity mismatch.
// Parity is generated at the write ports (16 ports x 16 bytes) and checked at the
// read ports.
//   FOLD=0 : read network carries 16 parity bits per port, checked per byte.
//   FOLD=1 : the 16 stored byte-parity bits of each subtile are XOR-folded locally;
//            the read network carries 1 bit per port, checked against the XOR of
//            all 128 read data bits (misses an even number of flips in one subtile).
// rdVld gates the check (only ports whose data is actually consumed).
module mt_shadow_probe #(parameter bit FOLD = 0) (
  input  logic clk, rst_n,
  input  logic [3:0][3:0][3:0]     readMtIdx,
  input  logic [3:0][3:0][3:0]     readSubIdx,
  input  logic [3:0][3:0][127:0]   readData,
  input  logic [3:0][3:0]          rdVld,
  input  logic [3:0][3:0][15:0]    writeEn,
  input  logic [3:0][3:0][3:0]     writeMtIdx,
  input  logic [3:0][3:0][3:0]     writeSubIdx,
  input  logic [3:0][3:0][127:0]   writeData,
  output logic                     parErr
);
  logic [15:0][15:0][15:0] par, pwd;     // [mt][sub][byte]
  logic [15:0][15:0][15:0] pwen;
  logic [3:0][3:0][15:0]   wpar;

  always_comb
    for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++)
      for (int h = 0; h < 16; h++) wpar[i][j][h] = ^writeData[i][j][h*8 +: 8];

  always_comb begin
    pwen = '0; pwd = '0;
    for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++)
      if (|writeEn[i][j]) begin
        pwen[writeMtIdx[i][j]][writeSubIdx[i][j]] = writeEn[i][j];
        pwd [writeMtIdx[i][j]][writeSubIdx[i][j]] = wpar[i][j];
      end
  end

  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) par <= '0;
    else for (int a = 0; a < 16; a++) for (int s = 0; s < 16; s++)
      for (int h = 0; h < 16; h++) if (pwen[a][s][h]) par[a][s][h] <= pwd[a][s][h];

  logic [15:0][15:0] fold;
  always_comb for (int a = 0; a < 16; a++) for (int s = 0; s < 16; s++) fold[a][s] = ^par[a][s];

  always_comb begin
    parErr = 1'b0;
    for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) begin
      if (FOLD) begin
        parErr |= rdVld[i][j] & ((^readData[i][j]) ^ fold[readMtIdx[i][j]][readSubIdx[i][j]]);
      end else begin
        for (int h = 0; h < 16; h++)
          parErr |= rdVld[i][j] & ((^readData[i][j][h*8 +: 8]) ^ par[readMtIdx[i][j]][readSubIdx[i][j]][h]);
      end
    end
  end
endmodule

module mt_sh0 (input logic clk, rst_n, input logic [3:0][3:0][3:0] readMtIdx, readSubIdx,
  input logic [3:0][3:0][127:0] readData, input logic [3:0][3:0] rdVld,
  input logic [3:0][3:0][15:0] writeEn, input logic [3:0][3:0][3:0] writeMtIdx, writeSubIdx,
  input logic [3:0][3:0][127:0] writeData, output logic parErr);
  mt_shadow_probe #(.FOLD(0)) u (.*);
endmodule
module mt_sh1 (input logic clk, rst_n, input logic [3:0][3:0][3:0] readMtIdx, readSubIdx,
  input logic [3:0][3:0][127:0] readData, input logic [3:0][3:0] rdVld,
  input logic [3:0][3:0][15:0] writeEn, input logic [3:0][3:0][3:0] writeMtIdx, writeSubIdx,
  input logic [3:0][3:0][127:0] writeData, output logic parErr);
  mt_shadow_probe #(.FOLD(1)) u (.*);
endmodule
