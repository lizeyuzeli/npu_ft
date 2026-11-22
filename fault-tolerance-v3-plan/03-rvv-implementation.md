# 03 · RVV 容错实现与功能验证

> 第 03 阶段：按 02-direction-discussion.md R5 的方案实现 RVV 指令级 DMR，并做功能验证。
> 状态（2026-11-21，本阶段结束）：FULL 模式实现完成；指令复制、比较、重放在 4 个 RVV 套件（Verilator）和 rvv_arithmetic（VCS）上验证通过；trap 上报只通到 handler，最后一段推迟（§3.6）；OPPORTUNISTIC 不做（§5.2）。
> 分支：`fault-tolerance-v3`，base `main@f385a31b`，FT 提交 `29a4e555`（已 push 到 origin/fault-tolerance-v3）。

---

## 1. Rebase

`main@9d0a8dcf → f385a31b`：先同步 main 到 upstream，再把 v3 rebase 到 main。4 个提交（CI、rvv_arithmetic 测试修复、CoralFlow 遥测、FPGA），无冲突，没有改动 RVV HDL。详见 `rebase-log.md` #1。

---

## 2. 实现结果

### 2.1 文件改动

| 文件 | 类型 | 改动 |
|---|---|---|
| `hdl/verilog/rvv/design/rvv_backend_ft.sv` | 新增 | 全部 FT 逻辑（约 440 行），整体包在 `` `ifdef RVV_FT_ON `` 里 |
| `hdl/verilog/rvv/design/rvv_backend.sv` | 上游 | +101 行，全部在 `` `ifdef RVV_FT_ON `` 里：例化 FT 模块；4 个 RS 的 push/datain 和 ROB 的结果输入改接 FT 输出；新增 2 个 trap 输出端口 |
| `hdl/verilog/rvv/design/RvvCore.sv` | 上游 | +19 行，`` `ifdef `` 内：把 FT trap 和前端 trap 合并到已有的 `trap_valid_o / trap_data_o`，FT 优先 |
| `hdl/chisel/src/coralnpu/rvv/RvvCore.scala` | 上游 | +1 行 `addResource("…/rvv_backend_ft.sv")`，只把文件打包进生成的 Verilog，不改 Chisel 逻辑 |
| `hdl/chisel/src/coralnpu/BUILD`、`hdl/verilog/rvv/design/BUILD` | 上游 | 各 +1 行文件列表 |
| `tests/cocotb/BUILD` | 上游 | 末尾追加 FT 的 Verilator/VCS 模型和 7 个测试目标 |

`RVV_FT_ON` 未定义时，RTL 与上游一致：`RvvCore.sv` 和 `rvv_backend.sv` 里只多出不生效的 `` `ifdef `` 块，`rvv_backend_ft.sv` 预处理后为空。ROB、dispatch、RS 和各执行单元的源文件都没有改。

**与 R5「不改 Chisel」的出入**：`RvvCore.scala` 必须加 1 行 `addResource`，否则新文件进不了生成的 Verilog。这行只登记资源文件，不改变任何硬件逻辑。

### 2.2 结构

FT 模块插在两个位置：

```text
dispatch ──rs_dp2{alu,mul,div,falu}──► [rvv_backend_ft] ──► RS ──► 执行单元 ──► 结果仲裁 ──► [rvv_backend_ft] ──► ROB
                                          │  replay_mem                                          │  配对 / 比较
                                          └──── copy-2 / 重放 ◄──────────────────────────────────┘
```

| 部分 | 实现 |
|---|---|
| replay_mem | 16 项（= ROB_DEPTH），按 rob_entry 寻址；3 个写口对应 3 个 dispatch 槽位，每类单元 1 个读口；位宽取 4 种 RS payload 的 `$bits` 最大值，不再写死 565 |
| 白名单 | ALU（不含 `VEU_CMP`）、MUL/MAC、DIV/FDIV、FALU 中的 `VEU_FMA`；而且只保护占有 ROB entry 的 uop（`uop_valid_dp2rob`） |
| copy-2 发射 | 统一从 replay_mem 发出，只走最高的 dispatch 槽位（K = 2）。只有在该槽位这一拍没有被 dispatch 用来推入目标 RS、并且 `pushRdy[K]` 为 1 时才发射；每类单元从 ROB 读指针开始挑最老的待发 entry。dispatch 从不等待 FT |
| 比较 | 第一份结果存在 FT 模块里，ROB 这时看不到；两份结果一致后才把结果交给 ROB（`res_valid_ft2rob`）。比较字段为 `w_data`、`w_valid`、`vsaturate`、`fpexp` |
| 重放 | 不一致时两份都重新执行，`retry+1`；达到 `RVV_FT_RETRY_MAX`（默认 3）后上报 trap |
| 上报 | 一次 flush 只报一个 trap。`rob_tag` 取自该 entry；`mtval` 的哨兵编码为 `0xFFFF_FF87`（opcode=LOAD、高 25 位全 1，mew=1 在 RVV 1.0 中保留）；`mcause=2` 由标量核写死；`mepc` 只有在定义了 `TB_SUPPORT` 时才是真实 PC，正式构建为 0 |
| 注错 | `RVV_FT_INJECT_ON` 时可用 plusarg：`+RVV_FT_INJ_N=n` 翻转第 n 次比较的一个操作数的 bit 0；再加 `+RVV_FT_INJ_PERSIST=1` 则从第 n 次起每次都翻转 |
| 统计 | 仿真结束时打印 `[RVV_FT] stats` 和各单元 copy-2 数（`` `ifndef SYNTHESIS ``） |

### 2.3 宏

| 宏 | 状态 |
|---|---|
| `RVV_FT_ON` | 已实现，总开关 |
| `RVV_FT_RETRY_MAX` | 已实现，默认 3 |
| `RVV_FT_INJECT_ON` | 已实现，仅仿真 |
| `RVV_FT_MODE` / `RVV_FT_WATERMARK` | **不实现**（2026-11-21 决定），难点见 §5.2 |

宏通过构建参数传入（Verilator `-D`、VCS `+define+`），不改上游的 svh 文件。

### 2.4 设计上与 R5 的差别

| R5 描述 | 实际 | 原因 |
|---|---|---|
| 比较、重放放在 ROB 里 | 放在 ROB 前面的独立模块里 | 不改 ROB；ROB 只会收到已经确认一致的结果，退休逻辑不用动 |
| 白名单含 ALU 全部 | 去掉 `VEU_CMP` | 比较类指令在 ALU 里跨 uop 累积（`cmp_en`、只有 last uop 才写回），执行两次会破坏内部状态 |
| FALU 全部 | 只保护 `VEU_FMA` | FCMP/FNCMP 同样跨 uop 累积；FCVT/FTBL 暂不纳入，后面需要再评估 |
| copy-2 用 `freeslot = rs_ready & ~rs_valid` | 只用槽位 K | 单读口每拍最多发一条；最高槽位的 `pushRdy[K]` 已经扣除了 dispatch 在前面槽位的推入 |

---

## 3. 功能验证

平台：Verilator（Bazel `verilator_cocotb_model`），顶层 `RvvCoreMiniAxi`（DISPATCH3、ZVE32F、VLEN=128），负载 `rvv_arithmetic`（25 个子测试，8 个分片）。另用 VCS W-2024.09-SP1 对生成的 Verilog 做 elaboration 检查。

### 3.1 编译

| 配置 | Verilator | VCS elab |
|---|---|---|
| FT 关 | 通过 | 0 error |
| `RVV_FT_ON` | — | 0 error |
| `RVV_FT_ON` + `RVV_FT_INJECT_ON` | 通过 | 0 error |

VCS 脚本：`tools/ft_compile/vcs_elab.sh <top> <out> [+define+…]`。

### 3.2 架构不可见（FT 开、不注错）

| 目标 | 结果 |
|---|---|
| `//tests/cocotb:rvv_arithmetic_cocotb_test_verilator`（基线） | PASSED，25/25 |
| `//tests/cocotb:rvv_arithmetic_ft_cocotb_test_verilator` | PASSED，25/25 |

FT 计数（8 个分片合计）：alloc 9277、copy-2 9277、比较 9277、一致 9277、不一致 0、trap 0。每条被保护的 uop 都执行了两次并比较过，没有出现误报。

**性能（仿真时间，25 个子测试合计）**：基线 1,360,766 ns，FT 1,377,210 ns，**+1.21%**。单个子测试最高 +3.46%（`widen_math_ops_test_impl`），比较类和浮点比较类为 0%（不在白名单里）。这只是 rvv_arithmetic 这一个负载的数字；它的向量运算比较稀疏，ML 负载的开销还要另外测。

### 3.3 检测和重放（单次注错）

`//tests/cocotb:rvv_arithmetic_ft_inject_cocotb_test_verilator`，`+RVV_FT_INJ_N=5`（每个子测试的第 5 次比较注一次错）：

- PASSED，25/25，说明结果全部被纠正。
- 注错 484 次，检测到不一致 484 次，一次不漏。
- copy-2 共 10245 = 9277 + 2 × 484，每次不一致都重放了两份。
- 一致 9277，trap 0。
- ALU、MUL、DIV、FALU 四类单元都出现过注错并完成重放（例如 `rob_entry=4 unit=1` 为 MUL）。
- 仿真时间 +1.42%（基线 +1.21%，加上重放的额外开销）。

### 3.4 其他 RVV 负载（FT 开、不注错，Verilator）

| 套件 | 基线 | FT 开 | FT 计数（alloc / 比较 / 一致 / 不一致） |
|---|---|---|---|
| `rvv_load_store_test` | PASSED | PASSED，70/70 | 1581 / 1581 / 1581 / 0 |
| `rvv_assembly_cocotb_test` | PASSED | PASSED，43/43 | 1187 / 1186 / 1186 / 0 |
| `rvv_ml_ops_cocotb_test` | PASSED | PASSED，6/6 | 36702 / 36702 / 36702 / 0 |

`rvv_assembly` 里有 1 条 alloc 没有比较，是某个测试结束时被 trap flush 掉的 entry（这个套件里有 vill/vstart 的 trap 测试），不算错误。

### 3.5 VCS 仿真

| 目标 | 结果 |
|---|---|
| `rvv_arithmetic_cocotb_test_vcs`（基线） | PASSED，25/25 |
| `rvv_arithmetic_ft_vcs_cocotb_test_vcs`（FT + INJECT 构建，不注错） | PASSED，25/25；计数 9277 / 9277 / 9277 / 0，和 Verilator 一致 |

VCS 目标默认会被 `.bazelrc` 的 tag filter 过滤，要加 `--config=vcs`。

### 3.6 trap 通路（持续注错）：未通过

`//tests/cocotb:rvv_arithmetic_ft_trap_cocotb_test_verilator`（`manual`，只跑 `binary_op_vx`，`+RVV_FT_INJ_N=5 +RVV_FT_INJ_PERSIST=1`）：

已经确认能工作的部分：
1. 同一 entry 重放 3 次后发出 trap（`retry=3 -> TRAP`），一次 flush 只报一个 trap。
2. `trap_valid_o` 带着正确的 `rob_tag` 到达标量核，`FaultManager` 拉高，retirement buffer `trapRetired`，`rvvFlushReg` 打出 RVV flush，后端清空。
3. 标量核跳到 mtvec：PC 0x164，也就是默认 `coralnpu_exception_handler` 的 `ebreak`。

不工作的部分：`ebreak` 一直不能发射，`io_halted`/`io_fault` 始终不拉高，cocotb 超时。

根因（用临时探针 bind 到 `SCore` 和 `LsuV3` 上定位）：
1. 进入 handler 后，`lsu.io.active` 一直为 1，而 `ebreak` 属于 `isFency()`，在 `lsuActive` 时被 Decode 卡住（`Decode.scala:509`）。
2. `active` 的 5 项里，flush 之后 `isFlushing=1` 和 `_slot_io_active=1` 一直保持，`rs`、`flushCmd`、`isFaulted` 都为 0。`clearFaultState = slotsIdle && …`（`Lsu.scala` 约 2167 行）要等事务槽空闲，而槽一直不空闲，所以 LSU 一直不退出 flush 状态。
3. 被注错的指令是 `0x330 vadd.vx v8`，紧接着的 `0x338 vse8.v v8` 已经进了标量 LSU 的事务槽，正在等 RVV 后端送来 v8 的 store 数据（推断，没有抓波形）。FT 扣住了 vadd 的结果没交给 ROB，之后 RVV 被 flush，这份数据永远不会来，槽就一直等。

这和 `Decode.scala` 里 vill 串行化注释描述的是同一类问题（被冲掉的向量访存在 LSU 里挂住）。上游用"在 Decode 里提前拦截"的办法规避，而后端在执行中产生的异步 trap 没有对应的处理。

修复方向（都要改标量 LSU 或 RVV↔LSU 接口，不是只改 Verilog 就能解决）：
- (a) 让 LsuSlot 在 `pipelineFlush` 时放弃正在等 RVV 数据的向量事务（改 Chisel）；
- (b) 给 RVV→LSU 的 store 数据通路加一个"取消"握手，flush 时由 RVV 侧补发一个空事务（改 Verilog 加 Chisel）；
- (c) 走 ROB 已有的 LSU 精确 trap 通路（`trap_valid_rmp2rob`），让 trap 在 ROB 顺序退休时发生，但后面那条 store 还是会卡住，需要先确认这条通路在 store 等数据时能不能正常 flush。

结论：难度中等偏上，牵涉 Chisel，按 2026-11-21 的决定推迟到 VME 阶段，和 VME 的错误上报一起解决。

---

## 4. 构建和复现

```bash
cd /home/lizeyu/eng/npu_ft/coralnpu
# Verilator: FT 开 / FT 开 + 单次注错
bazel test //tests/cocotb:rvv_arithmetic_ft_cocotb_test_verilator \
           //tests/cocotb:rvv_arithmetic_ft_inject_cocotb_test_verilator \
           //tests/cocotb:rvv_load_store_ft_test_verilator \
           //tests/cocotb:rvv_assembly_ft_cocotb_test_verilator \
           //tests/cocotb:rvv_ml_ops_ft_cocotb_test_verilator
# VCS
bazel test --config=vcs //tests/cocotb:rvv_arithmetic_ft_vcs_cocotb_test_vcs
# trap 通路（manual，目前超时 FAIL，见 §3.6）
bazel test //tests/cocotb:rvv_arithmetic_ft_trap_cocotb_test_verilator
```

给 `coralflow_test` 传 plusarg（如 inject/trap 测试的 `+RVV_FT_INJ_N`）要用 `test_args`，不能用 `plus_args`：后者会生成 `--plus_args=`，`cocotb_wrapper.py` 不认识这个参数。

---

## 5. 未完成 / 已知问题

1. **trap 后挂死（§3.6）**：根因已定位（store 卡在 LSU 事务槽里，等一份已经被 flush 掉的 RVV 数据），修复需要改 LSU，推迟到 VME 阶段和 VME 上报一起解决。
2. **OPPORTUNISTIC 模式**：本阶段不做（2026-11-21 决定，它本来就是锦上添花）。下面记录在现有结构上实现它的难点，供以后参考：
   - **R5 的放弃判据用不了。** R5 打算用 `rd_valid_rob2rt[program_age]` 判断"可以退休"。但现在的结构下，FT entry 的结果要等两份一致后才交给 ROB，所以 ROB 里这条 entry 的 `uop_done` 永远不会先置位，`rd_valid_rob2rt` 也就永远不会因为它而变高，形成死循环。替代做法：FT 模块自己重建"比它老的 entry 都已完成"这个条件。这需要 ROB 每个 entry 的 valid/done，而 ROB 只通过 `uop_rob2dp` 对外给出 `valid` 和 `w_valid & uop_done`，后者对 `w_valid=0` 的 uop 不准确。要么从 ROB 再引出一组 done 位（要改上游 ROB 的端口），要么在 FT 模块里旁路跟踪所有 ROB entry 的完成情况。
   - **放弃时需要一个空闲的 ROB 写口。** 放弃 copy-2 就是把 FT 模块里暂存的 copy-1 结果直接交给 ROB。ROB 只有 `NUM_SMPORT=4` 个写口，在仲裁器把 4 个口都占满的那拍就放不出去，需要额外的端口仲裁（或者给 ROB 加一个写口，那就要改 ROB）。
   - **已经发出的 copy-2 迟到。** 如果 copy-2 已经进了 RS 或执行单元，entry 就不能再放弃，必须等它回来，否则它回来时 ROB entry 可能已经被重新分配，结果会配错对。要么规定"已发出就不放弃"（R4 原本就是这么说的），要么给 entry 加一个代际位（generation bit），把迟到的结果丢掉。
   - **WATERMARK 要用 RS 的占用数。** 4 个 RS 实例（`multi_fifo`）的 `entry_count` 在 `rvv_backend.sv` 里都没有接出来（`.entry_count ()`），需要在钩子里多接 4 根线。这一项改动很小。
   - 估计工作量：前三项加上验证，大约 1～2 天；真正的难点在第一项，也就是怎样在不改 ROB 的前提下得到一个可靠的"可退休"信号。
3. **白名单的覆盖面**：CMP、FCMP、FNCMP、FCVT、FTBL、PMT/RDT、LSU 都不保护。要按动态 uop 数统计覆盖率（这次 alloc 9277，但不受保护的 uop 还没统计）。
4. **UVM 三方协同**：没有跑（VCS cocotb 已跑，见 §3.5）。
5. **其他负载**：`tfmicro`、mobilenet 等端到端负载，以及开销测量，放到实验阶段。
6. **lint**：本机 `run_linters.sh` 里有 4 项跑不起来：没有 buildifier、没有 scalafmt、`MODULE.bazel.lock` 校验（提示过期）、测试分片校验（`bazel query` 拉 pybind11_bazel 超时）。这些失败来自环境，不是本次改动；`hdl/verilog/rvv/` 本身不在 verible 的检查范围内。push 前需要在能联网的环境里再跑一次。
7. **面积**：没有对实现做综合，2.6% 是 R4 的探测值。replay_mem 的实际位宽取 4 种 payload 的最大值，带 `TB_SUPPORT` 时会多出 uop_pc。

---

## 6. 里程碑

| 里程碑 | 状态 |
|---|---|
| M1 rebase | 完成 |
| M2 FT 模块 + 集成（FULL） | 完成 |
| M3 架构不可见（rvv_arithmetic） | 完成 |
| M4 检测 + 重放自测 | 完成 |
| M5 trap → io.fault 自测 | **推迟到 VME 阶段**（§3.6，根因已定位） |
| M6 更多负载（load_store、assembly、ml_ops）、VCS 仿真 | 完成（§3.4、§3.5）；tfmicro 等放到实验阶段 |
| M7 OPPORTUNISTIC | 不做，难点见 §5.2 |
