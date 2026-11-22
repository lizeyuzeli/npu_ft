`ifdef RVV_FT_ON
  // RVV fault tolerance: DMR between dispatch/RS and arbiter/ROB
    logic         [`NUM_DP_UOP-1:0]       rs_valid_ft2alu;
    ALU_RS_t      [`NUM_DP_UOP-1:0]       rs_ft2alu;
    logic         [`NUM_DP_UOP-1:0]       rs_valid_ft2mul;
    MUL_RS_t      [`NUM_DP_UOP-1:0]       rs_ft2mul;
    logic         [`NUM_DP_UOP-1:0]       rs_valid_ft2div;
    DIV_RS_t      [`NUM_DP_UOP-1:0]       rs_ft2div;
  `ifdef ZVE32F_ON
    logic         [`NUM_DP_UOP-1:0]       rs_valid_ft2falu;
    FALU_RS_t     [`NUM_DP_UOP-1:0]       rs_ft2falu;
  `endif
    logic         [`NUM_SMPORT-1:0]       res_valid_ft2rob;
    PU2ROB_t      [`NUM_SMPORT-1:0]       res_ft2rob;

    rvv_backend_ft u_ft (
        .clk              (clk),
        .rst_n            (rst_n),
        .flush            (trap_flush_rvv),
        .rob_rptr         (rob_entry_rob2rt),
        .uop_valid_dp2rob (uop_valid_dp2rob),
        .uop_dp2rob       (uop_dp2rob),
        .rs_valid_dp2alu  (rs_valid_dp2alu),
        .rs_dp2alu        (rs_dp2alu),
        .rs_ready_alu2dp  (rs_ready_alu2dp),
        .rs_valid_dp2mul  (rs_valid_dp2mul),
        .rs_dp2mul        (rs_dp2mul),
        .rs_ready_mul2dp  (rs_ready_mul2dp),
        .rs_valid_dp2div  (rs_valid_dp2div),
        .rs_dp2div        (rs_dp2div),
        .rs_ready_div2dp  (rs_ready_div2dp),
      `ifdef ZVE32F_ON
        .rs_valid_dp2falu (rs_valid_dp2falu),
        .rs_dp2falu       (rs_dp2falu),
        .rs_ready_falu2dp (rs_ready_falu2dp),
        .rs_valid_ft2falu (rs_valid_ft2falu),
        .rs_ft2falu       (rs_ft2falu),
      `endif
        .rs_valid_ft2alu  (rs_valid_ft2alu),
        .rs_ft2alu        (rs_ft2alu),
        .rs_valid_ft2mul  (rs_valid_ft2mul),
        .rs_ft2mul        (rs_ft2mul),
        .rs_valid_ft2div  (rs_valid_ft2div),
        .rs_ft2div        (rs_ft2div),
        .res_valid_arb2ft (res_valid_arb2rob),
        .res_arb2ft       (res_arb2rob),
        .res_valid_ft2rob (res_valid_ft2rob),
        .res_ft2rob       (res_ft2rob),
        .trap_valid_o     (ft_trap_valid_o),
        .trap_data_o      (ft_trap_data_o)
    );
`endif
