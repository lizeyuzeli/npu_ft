// Area probe: zvt_mt (TE=16, VLEN=128) with end-to-end parity.
// Same port/mux structure as hdl/verilog/rvv/design/Zvt/zvt_mt.sv + zvt_mt_reg.sv.
// G = bytes per parity group: 0 = no parity (baseline), 1 = per byte, 4 = per 32-bit word.
// Parity is generated at the write port (from writeData) and checked at the read port.
// Group enable = OR of the byte enables in the group (exact for G=1; for G=4 this assumes
// word-granular writes, partial-word update logic is NOT included).
module mt_parity_probe #(parameter int G = 0) (
  input  logic clk, rst_n,
  input  logic [3:0][3:0][3:0]     readMtIdx,
  input  logic [3:0][3:0][3:0]     readSubIdx,
  output logic [3:0][3:0][127:0]   readData,
  output logic                     parErr,
  input  logic [3:0][3:0][15:0]    writeEn,
  input  logic [3:0][3:0][3:0]     writeMtIdx,
  input  logic [3:0][3:0][3:0]     writeSubIdx,
  input  logic [3:0][3:0][127:0]   writeData
);
  localparam int NP = (G == 0) ? 1 : 16 / G;   // parity bits per subtile (1 dummy when G=0)
  localparam int W  = 128 + ((G == 0) ? 0 : NP);

  logic [15:0][15:0][W-1:0]  mt, wdata;
  logic [15:0][15:0][15:0]   wen;
  logic [3:0][3:0][W-1:0]    wfull, rfull;

  // parity generation at the write source
  always_comb begin
    for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) begin
      wfull[i][j][127:0] = writeData[i][j];
      if (G != 0) for (int p = 0; p < NP; p++)
        wfull[i][j][128 + p] = ^writeData[i][j][p*8*G +: 8*G];
    end
  end

  always_comb begin
    wen = '0; wdata = '0;
    for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) begin
      if (|writeEn[i][j]) begin
        wen  [writeMtIdx[i][j]][writeSubIdx[i][j]] = writeEn[i][j];
        wdata[writeMtIdx[i][j]][writeSubIdx[i][j]] = wfull[i][j];
      end
      rfull[i][j] = mt[readMtIdx[i][j]][readSubIdx[i][j]];
    end
  end

  // storage: byte-enabled data + group-enabled parity bits
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) mt <= '0;
    else for (int a = 0; a < 16; a++) for (int s = 0; s < 16; s++) begin
      for (int h = 0; h < 16; h++)
        if (wen[a][s][h]) mt[a][s][h*8 +: 8] <= wdata[a][s][h*8 +: 8];
      if (G != 0) for (int p = 0; p < NP; p++)
        if (|wen[a][s][p*G +: G]) mt[a][s][128 + p] <= wdata[a][s][128 + p];
    end
  end

  // parity check at the consumer
  always_comb begin
    parErr = 1'b0;
    for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) begin
      readData[i][j] = rfull[i][j][127:0];
      if (G != 0) for (int p = 0; p < NP; p++)
        parErr |= (^rfull[i][j][p*8*G +: 8*G]) ^ rfull[i][j][128 + p];
    end
  end
endmodule

module mt_p0 (input logic clk, rst_n, input logic [3:0][3:0][3:0] readMtIdx, readSubIdx,
  output logic [3:0][3:0][127:0] readData, output logic parErr,
  input logic [3:0][3:0][15:0] writeEn, input logic [3:0][3:0][3:0] writeMtIdx, writeSubIdx,
  input logic [3:0][3:0][127:0] writeData);
  mt_parity_probe #(.G(0)) u (.*);
endmodule
module mt_p1 (input logic clk, rst_n, input logic [3:0][3:0][3:0] readMtIdx, readSubIdx,
  output logic [3:0][3:0][127:0] readData, output logic parErr,
  input logic [3:0][3:0][15:0] writeEn, input logic [3:0][3:0][3:0] writeMtIdx, writeSubIdx,
  input logic [3:0][3:0][127:0] writeData);
  mt_parity_probe #(.G(1)) u (.*);
endmodule
module mt_p4 (input logic clk, rst_n, input logic [3:0][3:0][3:0] readMtIdx, readSubIdx,
  output logic [3:0][3:0][127:0] readData, output logic parErr,
  input logic [3:0][3:0][15:0] writeEn, input logic [3:0][3:0][3:0] writeMtIdx, writeSubIdx,
  input logic [3:0][3:0][127:0] writeData);
  mt_parity_probe #(.G(4)) u (.*);
endmodule
