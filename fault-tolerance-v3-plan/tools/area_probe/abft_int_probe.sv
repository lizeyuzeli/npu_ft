// Area probe: integer full-checksum ABFT checker for the VME PE array (TE=16, VLEN=128).
// Per matmul instruction: C(16x16, int32) += A(16 x k) * B(k x 16),
//   int8 : k = 4 lanes of 8 bit per 32-bit word, int16 : k = 2 lanes of 16 bit.
// predicted = sum_k (sum_i a_ik) * (sum_j b_kj)          (mod 2^32, exact)
// measured  = sum over written elements of (C_new - C_old) (mod 2^32)
// Inputs follow the real interfaces: A/B = vs2/vs1 data of the 4 uops at the PE array input;
// C_new / C_old = per-block 16 write words / 16 read words per cycle (4 blocks).
// Two instruction contexts in flight (ping-pong), selected by ctx bits.
module abft_int_probe (
  input  logic                        clk, rst_n,
  // instruction start (at zvt_pe_array input)
  input  logic                        start,
  input  logic                        startCtx,
  input  logic                        isInt16,
  input  logic                        isSigned,
  input  logic [15:0]                 rowMask,   // tm tail
  input  logic [15:0]                 colMask,   // tn tail
  input  logic [3:0][127:0]           vs2,       // A
  input  logic [3:0][127:0]           vs1,       // B
  // per-cycle PE write / read (4 blocks x 16 words)
  input  logic [3:0]                  blkVld,
  input  logic [3:0]                  blkCtx,
  input  logic [3:0][15:0]            elemVld,
  input  logic [3:0][15:0][31:0]      cNew,
  input  logic [3:0][15:0][31:0]      cOld,
  // instruction end
  input  logic                        done,
  input  logic                        doneCtx,
  output logic                        mismatch
);
  // ---- row/col sums of A and B (masked) ----
  function automatic logic [19:0] sext(input logic [15:0] v, input logic int16, input logic sgn);
    if (int16) sext = sgn ? {{4{v[15]}}, v} : {4'b0, v};
    else       sext = sgn ? {{12{v[7]}}, v[7:0]} : {12'b0, v[7:0]};
  endfunction

  logic [3:0][19:0] sA, sB;
  always_comb begin
    sA = '0; sB = '0;
    for (int r = 0; r < 16; r++) begin
      // element r of the 16-element column lives in word r of {vs2[3..0]} (SEW32 view)
      automatic logic [31:0] wa = vs2[r/4][(r%4)*32 +: 32];
      automatic logic [31:0] wb = vs1[r/4][(r%4)*32 +: 32];
      for (int k = 0; k < 4; k++) begin
        automatic logic [15:0] ea = isInt16 ? wa[(k%2)*16 +: 16] : {8'b0, wa[k*8 +: 8]};
        automatic logic [15:0] eb = isInt16 ? wb[(k%2)*16 +: 16] : {8'b0, wb[k*8 +: 8]};
        if (rowMask[r] && (!isInt16 || k < 2)) sA[k] += sext(ea, isInt16, isSigned);
        if (colMask[r] && (!isInt16 || k < 2)) sB[k] += sext(eb, isInt16, isSigned);
      end
    end
  end

  logic [3:0][19:0] sA_q, sB_q;
  logic             st_q, stCtx_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin sA_q <= '0; sB_q <= '0; st_q <= 1'b0; stCtx_q <= 1'b0; end
    else begin sA_q <= sA; sB_q <= sB; st_q <= start; stCtx_q <= startCtx; end

  logic [31:0] pred;
  always_comb begin
    pred = '0;
    for (int k = 0; k < 4; k++) pred += 32'(signed'(sA_q[k]) * signed'(sB_q[k]));
  end

  // ---- per-block measured partial sums, registered ----
  logic [3:0][31:0] blkSum, blkSum_q;
  logic [3:0]       blkVld_q, blkCtx_q;
  always_comb begin
    for (int b = 0; b < 4; b++) begin
      blkSum[b] = '0;
      for (int e = 0; e < 16; e++)
        if (elemVld[b][e]) blkSum[b] += cNew[b][e] - cOld[b][e];
    end
  end
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin blkSum_q <= '0; blkVld_q <= '0; blkCtx_q <= '0; end
    else begin blkSum_q <= blkSum; blkVld_q <= blkVld; blkCtx_q <= blkCtx; end

  // ---- two contexts: acc = measured - predicted, must be 0 at done ----
  logic [1:0][31:0] acc;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) acc <= '0;
    else for (int c = 0; c < 2; c++) begin
      automatic logic [31:0] a = acc[c];
      if (done && doneCtx == c[0]) a = '0;
      if (st_q && stCtx_q == c[0]) a = a - pred;
      for (int b = 0; b < 4; b++)
        if (blkVld_q[b] && blkCtx_q[b] == c[0]) a = a + blkSum_q[b];
      acc[c] <= a;
    end
  end
  assign mismatch = done && (acc[doneCtx] != '0);
endmodule
