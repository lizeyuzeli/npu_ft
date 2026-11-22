#!/usr/bin/env python3
"""Insert the RVV_FT_ON hooks into rvv_backend.sv (idempotent check: aborts if already patched)."""
import re
import sys

path = sys.argv[1]
src = open(path).read()
assert "RVV_FT_ON" not in src, "already patched"


def sub1(pattern, repl, s):
    new, n = re.subn(pattern, repl, s, count=1, flags=re.M)
    assert n == 1, pattern
    return new


# 1. ports
src = sub1(r"^(    rd_rob2rt_o,\n)", r"\1`ifdef RVV_FT_ON\n    ft_trap_valid_o,\n    ft_trap_data_o,\n`endif\n", src)
src = sub1(r"^(// global signal\n)",
           "`ifdef RVV_FT_ON\n    output  logic                                 ft_trap_valid_o;\n"
           "    output  RVVInstruction                        ft_trap_data_o;\n`endif\n\\1", src)

# 2. RS push/datain
for u in ["alu", "mul", "div", "falu"]:
    pat = (r"^(\s*)\.push(\s*)\(rs_valid_dp2%s\),\n(\s*\.pushRdy\s*\(rs_ready_%s2dp\),\n)(\s*)\.datain(\s*)\(rs_dp2%s\),\n"
           % (u, u, u))
    repl = (r"`ifdef RVV_FT_ON\n\1.push\2(rs_valid_ft2%s),\n`else\n\1.push\2(rs_valid_dp2%s),\n`endif\n\3"
            r"`ifdef RVV_FT_ON\n\4.datain\5(rs_ft2%s),\n`else\n\4.datain\5(rs_dp2%s),\n`endif\n" % (u, u, u, u))
    src = sub1(pat, repl, src)

# 3. ROB result input
src = sub1(r"^(\s*)\.wr_valid_pu2rob(\s*)\(res_valid_arb2rob\),\n(\s*)\.wr_pu2rob(\s*)\(res_arb2rob\),\n",
           r"`ifdef RVV_FT_ON\n\1.wr_valid_pu2rob\2(res_valid_ft2rob),\n\3.wr_pu2rob\4(res_ft2rob),\n`else\n"
           r"\1.wr_valid_pu2rob\2(res_valid_arb2rob),\n\3.wr_pu2rob\4(res_arb2rob),\n`endif\n", src)

# 4. FT instance just before the ROB
inst = open(sys.argv[2]).read()
src = sub1(r"^(  // ROB, Re-Order Buffer\n)", inst + r"\n\1", src)

open(path, "w").write(src)
print("patched", path)
