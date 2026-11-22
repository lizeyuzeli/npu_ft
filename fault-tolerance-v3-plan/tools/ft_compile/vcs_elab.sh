#!/bin/bash
# Quick VCS elaboration check of the Chisel-emitted VmeCoreMiniAxi.sv.
# Usage: vcs_elab.sh <top> <out_dir> [extra +define+... args]
# Rebuild first:  bazel build //hdl/chisel/src/coralnpu:VmeCoreMiniAxi.sv //hdl/chisel/src/coralnpu:${TOP}.zip
set -euo pipefail
REPO=/home/lizeyu/eng/npu_ft/coralnpu
TOP=$1; OUT=$2; shift 2
rm -rf "$OUT"; mkdir -p "$OUT/inc"
cd "$OUT"
unzip -q -o "$REPO/bazel-bin/hdl/chisel/src/coralnpu/${TOP}.zip" -d inc
cp "$REPO/bazel-bin/hdl/chisel/src/coralnpu/${TOP}.sv" top.sv
COMMON_INC="$(find -L "$REPO/bazel-coralnpu/external" -maxdepth 4 -type d -path '*common_cells*/include' 2>/dev/null | head -1)"
vcs -full64 -sverilog -lca -kdb=0 +lint=none -timescale=1ns/1ps \
  -assert disable_cover \
  +define+USE_GENERIC+TB_SUPPORT+VLEN_128+ZVE32F_ON \
  "$@" \
  +incdir+"$OUT/inc" ${COMMON_INC:++incdir+$COMMON_INC} \
  -top ${TOP} top.sv -o simv > vcs.log 2>&1 || true
grep -E "^Error|Error-\[" vcs.log | sort | uniq -c | head -40
grep -c "Error-\[" vcs.log || true
