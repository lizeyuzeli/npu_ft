# 05 · VME 容错实现与功能验证

> 第 05 阶段：按 04-vme-ft-design.md R2 的方案实现 VME 容错，并做 RTL 注错（Verilator）的功能验证。
> 第一阶段是核心机制（`VME_FT_ON`）；第二阶段是写入校验（`VME_FT_WCHK_ON`）和 RS 奇偶（`VME_FT_RSPAR_ON`），每项可单独叫停。
> 方案、宏定义、验证项、不做的事项以 04 为准（§4.1～4.3、§6）；本文件只记实现过程、测试结果和与 04 假设不符的地方。
> 分支：`fault-tolerance-v3`，起点 `29a4e555`（RVV FT）。
> 状态（2026-11-26）：M1 完成，等确认后进 M2。

## 里程碑

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M1 | VME FT 头文件 + 专用 RS 模块 + RS 单元测试 + 直通模式接入 `rvv_backend.sv` | 完成 |
| M2 | 交错发射（`zvt_pe_array.sv`、`zvt_pe_block.sv`）+ 写口前提交单元（只检测） | 完成 |
| M3 | 按序校验、RS 当 ROB（发射/释放解耦）、退休链、`zvt_ctrl.sv` 配套改动；FT 开不注错回归 | 完成 |
| M4 | 回滚、重试、trap 事件；单条 PE 在飞模式下注错测试通过 | **完成** |
| M5 | 恢复指令重叠、持续注错 trap 验证、第一阶段其余 §6.3 验收项 | 进行中 |
| M6 | 第二阶段：`VME_FT_WCHK_ON` | 待做 |
| M7 | 第二阶段：`VME_FT_RSPAR_ON` | 待做 |

M2～M7 的划分是暂定的，做到时按实际情况调整。每个里程碑完成后确认再进下一个。

---

## 0. 本轮目标

### 0.1 第一阶段

1. **不定义 `VME_FT_ON` 时，RTL 和上游一致**（04 §6.3 a）。
2. **FT 开、不注错**：官方 vme_test 20 个用例全过（VmeCoreMiniAxi，Verilator）；自写定向测试覆盖 04 §4.1 第 6 条的兼容性表（同 tile 连发、不同 tile 连发、组数 1～4、tm=9～14、tn≤8、行列不满、int8/int16/bf16/fp32、misc 指令穿插、浮点异常）。
3. **FT 开、注错**：能检测、能回滚、结果正确；持续注错时重试耗尽报 trap，rob_tag 正确（04 §6.3 c）。
4. **专用 RS 模块单元测试**：带参考模型，随机 push、发射、释放、回滚、flush（04 §6.3 d）。

### 0.2 第二阶段

每项独立：开宏后第一阶段回归全过，该项自己的注错测试通过（04 §4.2）。

### 0.3 范围约定

- 只做 RTL 注错（Verilator）。trap 只在 L1 观测：`trap_valid_o` 和 rob_tag。LSU 的 trap 卡死修复延后到 06（04 §5.7），所以重试耗尽的用例里，出错指令之后不放 store，或者看到 trap 就结束仿真。
- 不做：综合、功耗、性能统计、网表注错等（04 §6.4）。
- 实现中遇到和 04 方案对不上的 RTL 细节，记到 §「与 04 假设不符」，继续往下做，不回头改 04。第一阶段做完再决定是修正 04，还是只留在本文件的已知问题里。

### 0.4 测试负载现状

- **官方 vme_test**：20 个用例可用（04 §2.5），每个用例约 6 万 ns，只做一次 16×16 matmul，覆盖不到连发和各种 tm/tn 组合。
- **临时 VME 补充算子已丢失**：之前写的补充算子在 `git checkout` BUILD 时被撤销，找不回来。05 按需要重写定向测试，第一次需要是在 M3（FT 开不注错回归）。
- **04 §1 的 3 个测试目标也已丢失**：`vme_core_mini_axi_ft_model`、`vme_rvv_arithmetic_{,ft_}cocotb_test`、`vme_test:vme_test_rvv_ft` 当时没有提交，现在工作区干净（`git status` 为空），BUILD 里已经没有它们。05 需要的 VME FT 构建目标重新加。
- 参考数据：`test-data/vme/`（官方 INT8 用例和 Gemma INT8 的周期数、MAC 间隔、tile 写回统计、波形摘录）。

### 0.5 04 §6.1 文件拆分到里程碑的对应

| 04 §6.1 | 文件 | 里程碑 |
|---|---|---|
| 7 | 新建 VME FT 头文件（宏默认值、合法性检查） | M1 |
| 1 | 新建专用 RS 模块；`rvv_backend.sv` 接线 | M1（直通接法）、M3（发射/释放解耦） |
| 2 | `zvt_pe_array.sv`：交错发射、B skew 每拍抓取、hitRaw 窗口、回滚状态机、槽号 | M2（交错、skew、槽号）、M3（hitRaw）、M4（回滚） |
| 3 | `zvt_pe_block.sv`：去掉浮点异常反压，pass/组号/槽号/fflags 随写口带出 | M2 |
| 4 | `zvt.sv` 和新建 `zvt_ft.sv`：提交单元、写口多源选择、退休链 | M2（比较、延迟写、done 掩码）、M3（按序校验、退休链）、M4（回滚触发、重试、trap 事件） |
| 5 | `zvt_ctrl.sv`：misc 等待、读写口归属、flush 清 vtzero 计数 | M3 |
| 6 | `RvvCore.sv`：trap 合并 | M4 |

---

## 1. M1：头文件 + 专用 RS 模块

**为什么先做 RS**：它是独立的新模块，有明确的参考模型（FIFO + 发射偏移），能单独做单元测试；接进系统时可以先用"直通"接法（下面第 4 条），在 PE 阵列和 zvt 都不改的情况下用 vme_test 验证它能替换 `u_zvt_rs`。后面 M2～M4 出问题时，RS 这一层已经排除掉了。

### 1.1 要做的事

1. **VME FT 头文件**（新建，放 `hdl/verilog/rvv/inc/`，具体文件名和 include 方式按 BUILD 定）：
   - `VME_FT_RETRY_MAX`（默认 3）、`VME_FT_RS_DEPTH`（默认 12）的 `ifndef` 默认值；
   - 合法性检查：`VME_FT_RS_DEPTH` 是 `ZVT_LMUL` 的倍数且 ≥8；`VME_FT_INJECT_ON` / `WCHK_ON` / `RSPAR_ON` 必须和 `VME_FT_ON` 同开；`VME_FT_ON` 依赖 `ZVT_ON`；`WCHK_ON` 和 `FPGA_XILINX` 互斥。
   - 不改上游 svh。

2. **专用 RS 模块**（新建 `zvt_ft_rs.sv`，`VME_FT_ON` 下替换 `u_zvt_rs`）：
   - 写入侧照搬 `multi_fifo` 的 CHAOS_PUSH 压缩（M=`NUM_DP_UOP`=3 路），`pushRdy` / `almost_full` 语义不变，dispatch 侧的 `rs_ready_zvt2dp = ~almost_full` 不用改。
   - 指针按 DEPTH 取模（DEPTH 不要求是 2 的幂）。
   - 发射视图：`rptr + off + i` 处的 4 项（N=`ZVT_LMUL`），有效位 = `entry_count > off + i`。`off=0` 时和 `multi_fifo` 的 `dataout` / `~almost_empty` 完全等价。
   - 三种操作：
     - `issue`：PE 指令发射，`off += ZVT_LMUL`；
     - `release`：最老的 PE 指令校验通过，`rptr += ZVT_LMUL`，`off -= ZVT_LMUL`（同拍 issue + release 时 `off` 不变）；
     - `misc_pop`：misc 指令发射即弹出，`rptr += 1`；只允许在 `off == 0` 时发生（断言）。
   - `rollback`：`off` 清零；`clear`（`trap_flush_rvv`）：全部清空。
   - 表项宽度留一个 `EXTRA_W` 参数（默认 0），给第二阶段的奇偶位用（04 §4.2 第 3 条）。
   - 断言：`off` 不超过 `entry_count`；`release` 时 `off ≥ ZVT_LMUL`；`issue` 时 4 项都有效；不在满时 push。

3. **RS 单元测试**：cocotb + Python 参考模型，随机做 push、issue、release、misc_pop、rollback、clear，每拍比较发射视图、有效位、`almost_full`。DEPTH 跑 8 和 12 两种。写法跟仓库里现有的 RTL 单元测试走（开始时先找一个现成的例子）。

4. **直通接法接入 `rvv_backend.sv`**（`ifdef VME_FT_ON`）：zvt 还没改，`pop_zvt2rs` 照旧。把 4 位全 1 的 pop 映射成"同拍 issue + release"，`pop[0]` 单独为 1 映射成 `misc_pop`，`rollback` 接 0。这样 `off` 恒为 0，行为应和原 `u_zvt_rs` 一致。

5. **构建目标**（`tests/cocotb/BUILD` 末尾追加，和 03 一样）：
   - `vme_core_mini_axi_ft_model`：`vme_core_mini_axi_model` 的宏加 `VME_FT_ON`；
   - vme_test 跑在这个模型上；
   - 新文件登记：`hdl/verilog/rvv/design/BUILD` 文件列表，`RvvCore.scala` 的 `addResource`（03 §2.1 的先例，只登记资源，不改 Chisel 逻辑）。

### 1.2 M1 的验收

| 项 | 预期 |
|---|---|
| 不定义 `VME_FT_ON`，vme_test | 20/20，和上游一致 |
| RS 单元测试（DEPTH=8、12） | 和参考模型逐拍一致，断言不触发 |
| `VME_FT_ON`（直通接法），vme_test，DEPTH=12 | 20/20 |
| 同上，`VME_FT_RS_DEPTH=8` | 20/20 |
| 头文件的非法组合（如只开 `VME_FT_INJECT_ON`） | 编译期报错 |

### 1.3 实现记录

**文件改动**

| 文件 | 类型 | 改动 |
|---|---|---|
| `hdl/verilog/rvv/inc/rvv_backend_vme_ft.svh` | 新增 | 宏默认值和合法性检查 |
| `hdl/verilog/rvv/design/Zvt/zvt_ft_rs.sv` | 新增 | 专用 RS，整体在 `` `ifdef VME_FT_ON `` 里 |
| `hdl/verilog/rvv/design/Zvt/zvt_ft_rs_tb.sv` | 新增 | RS 单元测试（VCS testbench，不进构建） |
| `hdl/verilog/rvv/design/rvv_backend.sv` | 上游 | +30 行，全部在 `` `ifdef VME_FT_ON `` 里：include 头文件，`u_zvt_rs` 换成 `zvt_ft_rs` 的直通接法 |
| `hdl/chisel/src/coralnpu/rvv/RvvCore.scala` | 上游 | +2 行 `addResource`（头文件在 `rvv_backend.sv` 之前，RS 模块在 Zvt 文件块里） |
| `hdl/chisel/src/coralnpu/BUILD`、`hdl/verilog/rvv/design/BUILD`、`hdl/verilog/rvv/inc/BUILD` | 上游 | 各 +1 行文件列表 |
| `tests/cocotb/BUILD`、`tests/cocotb/vme_test/BUILD` | 上游 | 末尾追加 FT 模型（深度 12 和 8）和 `vme_test_ft`、`vme_test_ft_d8` |

不定义 `VME_FT_ON` 时，`rvv_backend.sv` 只多出一个不生效的 `` `ifdef `` 块，`zvt_ft_rs.sv` 预处理后为空。

**和计划的差别**

- 端口名不用 `release`：它是 Verilog 关键字，改成 `rel`，`issue` 改成 `iss`。
- 不设 `EXTRA_W` 参数。第二阶段的奇偶位直接加宽实例化时的 `T`，`zvt_ft_rs` 不看 `T` 的内容。
- 单元测试用 `logic [63:0]` 作载荷，不实例化 `ZVT_RS_t`。`ZVT_RS_t` 要带上 `fpnew_pkg` 和一串 svh，单元测试的价值是参考模型比对，载荷类型由 vme_test 覆盖。
- 单元测试是 VCS testbench，用脚本直接调 VCS，不走 Bazel。仓库的 `vcs_testbench_test` 规则不传 `+define+`，而 `zvt_ft_rs` 包在 `` `ifdef VME_FT_ON `` 里。
- 头文件的合法性检查用"非法组合留下一个未定义标识符"实现（如 `VME_FT_ON_requires_ZVT_ON`），编译报错里能看到这个名字。文件作用域不能放 `generate` 和 `$error`。`VME_FT_RS_DEPTH` 的倍数检查放在 `zvt_ft_rs` 里，用 elaboration 时的 `$error`。
- 两个数值宏的默认值只在 `VME_FT_ON` 下定义。否则不开 `VME_FT_ON` 的构建里也会出现 `VME_FT_RS_DEPTH` 这个宏名。

**头文件的 include 顺序（踩过的坑）**

生成的 Verilog 是把 `addResource` 的文件按登记顺序拼成一个大文件，`` `include "x.svh" `` 在 guard 已定义时被跳过。所以头文件必须用 `addResource` 登记在 `rvv_backend.sv` 之前，`rvv_backend.sv` 里的 include 再加一层 guard 判断。这和仓库里其他 svh 的做法一样。第一次没加 guard，Verilator 在拼接文件里按路径找 `rvv_backend_vme_ft.svh`，include 路径里没有 `hdl/verilog/rvv/inc/`，报 `VME_FT_RS_DEPTH` 未定义。

**验证（2026-11-26）**

| 项 | 结果 |
|---|---|
| RS 单元测试，DEPTH=12，seed 1～5，每个 20 万拍 | PASS。seed 1 的统计：push 187640、iss 47478、rel 40658、同拍 iss+rel 9337、misc 17556、rollback 4293、clear 1014、满 32673 拍、指针回绕 85999 拍、max_off=12 |
| 同上，DEPTH=8，seed 1～5 | PASS。满 51501 拍、回绕 75425 拍、max_off=8 |
| 变异：`rel` 不减 `off`；`pushRdy` 的 `<` 改成 `<=` | 都在前 25 拍报错，测试能抓到 |
| DEPTH=10（不是 4 的倍数） | elaboration 报错：`DEPTH (10) must be a multiple of N (4) and >= 8` |
| 头文件非法组合：只开 `VME_FT_ON`、只开 `INJECT_ON`、只开 `WCHK_ON`、只开 `RSPAR_ON`、`WCHK_ON` 加 `FPGA_XILINX` | 全部编译失败，报错含对应的标识符名；合法组合编译通过 |
| `vme_test_ft_verilator`（`VME_FT_ON`，深度 12） | PASSED，20 用例 PASS=20（4 个分片各跑 5 个） |
| `vme_test_verilator`（不定义 `VME_FT_ON`，同一工作区） | PASSED，20 用例 PASS=20，仿真时间与 FT 版逐分片相同 |
| `vme_test_ft_d8_verilator`（`VME_FT_RS_DEPTH=8`） | PASSED，20 用例 PASS=20，仿真时间与深度 12 逐分片相同 |

三个 vme_test 的仿真时间逐分片一致（13502.50 / 12896.25 / 12835.00 / 22157.50 ns），直通接法没有改变时序。

`vme_test_ft_d8` 和 `vme_core_mini_axi_ft_d8_model` 标了 `manual`：深度 8 是一个编译组合，不是每次回归都要跑的目标。

### 1.4 遗留

- 单元测试和头文件检查用脚本直接调 VCS，没有 Bazel 目标，复现命令没有写进仓库。需要的话再补。
- `vme_rvvi_retire_test` 的 2 个用例在 `vme_test` 的 data 里，所以 20 个用例都覆盖了；没有单独给它建 FT 目标。

---

## 2. M2：交错发射 + 写口前提交单元

### 2.1 实现

**交错发射**（`zvt_pe_array.sv`）

- pass 每拍翻转，`cnt` 只在第二份发射后前进，`cntCr` 在第二份且 `cnt == cntMax00` 时成立。
- B 的三个 skew 寄存器（`regLbData`、`regHb0Data`、`regHb1Data`）去掉 `cnt==0/1` 条件，每拍抓取。
- RAW 检查只对第一份做。第二份会命中自己的第一份还在 mulbulk 流水里，不做这个限制就会被自己挡住。
- 槽号计数器在 `cntCr` 时加一，随 `vaInfo` 带出。

**pass/组号/槽号随流水带出**（`zvt_pe_block.sv`）

- `PEVAINFO_t`、`MULBULKTAG_t`、`ADDERTAG_t` 加 `ftPass`、`ftSlot`，经乘法级和加法级流水带到写口。组号用已有的 `writeMtId`。
- FT 下 `fpexpVld = 0`、`adderResRdy = 1`，浮点异常不再反压加法器。

**提交单元**（新建 `Zvt/zvt_ft.sv`）

- 只看阵列自己的写口（`peWriteEn`），不看 `zvt_ctrl` 多路选择后的 `writeEn`。后者在杂项操作时是杂项写，会污染 dupBuf。
- p0 存进 dupBuf，p1 按块、端口、字节比较。比较项是组号、槽号、写地址、字节使能、数据和该 block 的 OF/NV。
- 一致且 done 位为 0 的字节晚一拍写入。
- 不一致时压住这条指令剩下的写，报 `ft_mismatch_o`。M2 没有重试和回滚，所以压住就是最终结果。
- `zvt.sv` 的写口分三种来源：比较后的写优先；阵列正在出原始写的那拍不写；阵列空闲时杂项写直接通过。

**fflags**

- 阵列导出每个 block 自己的 `fpexp`，不做跨 block 的 OR 规约。block 0 和 block 1 在同一拍写，规约后的值在两份之间不同。
- 比较通过的组的标志做 OR 合并，等 `fpexpRdy` 后送给退休单元。fcsr 里的标志是粘滞的，所以合并是安全的，PE 流水线也不因此停顿。

**注错**（`VME_FT_INJECT_ON`）

- 实现了 04 §4.3 里第一阶段的 p0 和 p1 两个注入点。p0 翻 dupBuf 里第一份的一位，p1 翻比较时第二份的一位。
- plusargs：`+VME_FT_INJ_SITE=`、`+VME_FT_INJ_N=`、`+VME_FT_INJ_PERSIST=`、`+VME_FT_INJ_BLK=`、`+VME_FT_INJ_BIT=`。只对选中的 block 和字节使能有效的写计数，所以每次注入都是可观测的。
- 仿真结束时打印 `[VME_FT] stats`：比较次数、失配次数、注入次数、提交字节数。
- dupbuf、bskew、done、rs 四个注入点留到对应逻辑写完再加。

### 2.2 验证（2026-11-26）

| 项 | 结果 |
|---|---|
| `vme_test_ft_verilator`（`VME_FT_ON`，深度 12） | PASSED，21 用例。分片 1 仿真时间 15297.50 ns |
| `vme_test_verilator`（不定义 `VME_FT_ON`） | PASSED，21 用例。分片 1 仿真时间 15262.50 ns |
| `vme_test_ft_d8_verilator`（深度 8） | PASSED，仿真时间与深度 12 逐分片相同 |
| `vme_rvvi_retire_test_verilator` | PASSED |
| `vme_fflags_test`（新增） | 溢出和无效操作两个用例，FT 开和 FT 关都通过 |
| `vme_test_ft_inject_verilator`（`VME_FT_INJECT_ON`，不注错） | PASSED，21 用例，仿真时间与 `vme_test_ft` 逐分片相同。分片 1 的统计：compares=16、mismatch=0、inject=0、commit_bytes=1024 |
| `vme_test_ft_inj_p0_verilator`（`+VME_FT_INJ_SITE=p0 +VME_FT_INJ_N=3`，manual） | 测试失败，符合预期。日志：`inject site=p0 blk=0 bit=0 grp=2 slot=0`，下一拍 `mismatch blk=0 -> squash`。统计：compares=16、mismatch=1、inject=1、commit_bytes=575。结果里没有出现翻位后的值，说明被翻的字节没有写入 |
| `vme_test_ft_inj_p1_verilator`（`+VME_FT_INJ_SITE=p1`，manual） | 同样失败，inject 和 mismatch 在同一拍 |

FT 版比基线慢 25～35 ns，是每组发射两次的开销。阵列的原始写在 FT 下被压住，PE 结果只能经过比较后的延迟写进入 tile，所以 matmul 结果正确说明这条路径在工作。

`vme_test_ft_inj_p0` 和 `vme_test_ft_inj_p1` 标了 `manual`：它们预期失败，用来看日志，不进常规回归。

### 2.3 遗留

- done 掩码的清零条件写得比较粗。阶段一一次只跑一条指令，所以能用。M3 改发射和释放时要重写。
- 失配只压住写，不回滚、不重试、不上报 trap。这是 M4 的事。
- 注错只覆盖 p0 和 p1。dupbuf、bskew、done、rs 留到对应逻辑稳定后补。

---

## 3. M3 诊断基线：单条 PE 在飞

**目标**：在 M1（RS 模块）和 M2（交错发射、提交单元）的基础上，实现退休链和按序校验，建立 FT 开启、无注错的通过基线。

**实施策略**：采用"单条 PE 在飞"的串行门控，简化调试。允许的指令重叠和精确的完成判定留到后续阶段。

### 3.1 实现

**退休链与命令保持**（`zvt.sv`）

- 退休命令队列（`rtCmd`）：PE 指令在最后一个 uop ready 时入队，misc 指令在 `last_uop_valid` 时入队
- 命令延迟寄存器（`vmeRtCmdVldD1`、`vmeRtCmdD1`）：
  - **M3 诊断版**：`vmeRtCmdVldD1` 持续有效直到握手完成（`vmeRtVld && vmeRtRdy`），解决命令脉冲先于信息到齐的问题
  - 原始版本：简单 1 拍延迟（`dff`），M3 前发现这会导致命令丢失
- mtInfo FIFO（4 个 block）：每个 block 的结果信息独立入队，退休握手时 pop
- 退休握手条件：`vmeRtVld = vmeRtCmdVldD1 && (&mtRtInfoVld)`（命令有效 且 4 个 FIFO 都有数据）

**按序校验与完成判定**（`zvt_ft.sv`）

- dupBuf 存储 p0，p1 到达时比较，匹配的字节标记 `done` 并延迟写入 MT
- 完成判定（简化版）：
  ```systemverilog
  assign inst_complete = !ft_squash && blk_complete_simple && (&(~db_vld)) && had_data;
  ```
  - `blk_complete_simple`：所有使能字节都已比较通过或标记 done
  - **M3 诊断修复**：添加 `if (|cap_p0) blk_complete_simple = 1'b0;` 防止 p0 到达时立即触发
  - `&(~db_vld)`：所有 dupBuf 都已清空
  - `had_data`：至少收到过一份数据（防止复位时误触发）
  - `!ft_squash`：失配时阻止成功退休

**单条 PE 在飞的串行门控**（诊断版本）

- `zvt.sv`：`assign ftInFlight = pe_inflight_cnt > 0;`
- `zvt_ctrl.sv`：
  ```systemverilog
  #ifdef VME_FT_ON
    peCmdVld = {(`ZVT_LMUL-1)'(0), isPe[0] && rtCmdRdy && !ftInFlight};
  #else
    peCmdVld = {(`ZVT_LMUL-1)'(0), isPe[0] && rtCmdRdy};
  #endif
  ```
- 效果：新的 PE 指令必须等待前一条完全完成（ftPass + ftRel）才能进入阵列

**退休边界检查**（`zvt.sv`，`!SYNTHESIS` 下生效）

```systemverilog
// 错误：新 pop 覆盖待退休的命令
if (vmeRtCmdVldD1 && !(vmeRtVld && vmeRtRdy) && vmeRtCmdPop) begin
  $error("[VME_RT_BOUNDARY_VIOLATION] ...");
end
// 合法：握手同拍接收下一条
if (vmeRtCmdVldD1 && vmeRtVld && vmeRtRdy && vmeRtCmdPop) begin
  $display("[VME_RT_BOUNDARY_OK] ...");
end
```

### 3.2 调试经过

从 M2 的 21/21 通过基线开始，启用 RS 发射/释放解耦（`zvt_rs_pe_pop & !zvt_ft_inflight`）后，测试降至 14/21 通过。经定向调试，定位并修复了三个关键问题：

#### 问题 1：p1 到达前提前释放 RS

**证据**：
- 时间 144220003：PC 0x188（slot=0, grp=1）的 p0 到达
- 同拍：`blk_complete_simple=1`，触发 `inst_complete` 和 `ftRel`，RS 释放（`off=4->0`）
- 时间 144221253：p1 才到达（晚了 1250ps）
- **根因**：p0 到达时 dupBuf 寄存器尚未更新，`blk_complete_simple` 看到的是上一拍的空 dupBuf，误判为完成

**修复**（`zvt_ft.sv:189`）：
```systemverilog
always_comb begin
  blk_complete_simple = 1'b1;
  // 防止 p0 到达当拍立即触发
  if (|cap_p0)
    blk_complete_simple = 1'b0;
  // 检查 dupBuf 中待比较的字节
  for (int b = 0; b < NB; b++)
    for (int p = 0; p < NP; p++)
      for (int k = 0; k < NBY; k++)
        if (db_vld[b] && db_wen[b][p][k] && !done[b][db_grp[b]][p][k] && !byte_ok[b][p][k])
          blk_complete_simple = 1'b0;
end
```

#### 问题 2：阵列与 RS 接受条件不一致造成重复执行

**证据**：
- slot=1（后续指令）在 slot=0 完成前就产生了 p0/p1
- slot=1 的两份数据内容不同（p0 读到 C=0，p1 读到 C=5），导致失配
- 间隔仅 1 拍（212500 释放 → 213750 下一条开始），违反同 tile 6 拍 RAW 约束
  - **注**：此处"间隔 1 拍"是修复前的异常情况。实测正常发射间隔见 §7.2（g0p0 间隔 12 拍，远大于 6 拍最小值）
- **根因**：`zvt_ctrl` 中 `peCmdVld` 的生成条件是 `isPe[0] && rtCmdRdy`，不检查 `ftInFlight`

**修复**（`zvt_ctrl.sv:143`）：
```systemverilog
#ifdef VME_FT_ON
  peCmdVld = {(`ZVT_LMUL-1)'(0), isPe[0] && rtCmdRdy && !ftInFlight};
#else
  peCmdVld = {(`ZVT_LMUL-1)'(0), isPe[0] && rtCmdRdy};
#endif
```

**验证**：修复后 slot=1 的失配消失，所有比较都是 `match=1`

#### 问题 3：退休命令的一拍脉冲早于四份 mtInfo 到齐

**证据**：
- 时间 212500：PC 0x188（tag=5）`vmeRtCmdPop=1`，blk=0 push mtInfo
- 时间 213750：`vmeRtCmdVldD1=1`，但 `mtVld=0001`（只有 blk=0），无法握手
- 时间 215000：blk=1,2 push，216250：blk=3 push，`mtVld=1111`
- 但此时 `vmeRtCmdVldD1` 已经在 215000 变回 0（原始逻辑只延迟 1 拍）
- **tag=5 的命令丢失**，永远不会握手
- 时间 228750：tag=8 握手时，消费的队头数据是 tag=5 的残留（blk=0 head_PC=0x188）

**修复**（`zvt.sv:347`）：
```systemverilog
#ifdef VME_FT_ON
  // 保持 vmeRtCmdVldD1 直到握手完成
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush)
      vmeRtCmdVldD1 <= 1'b0;
    else if (vmeRtCmdPop)
      vmeRtCmdVldD1 <= 1'b1;
    else if (vmeRtVld && vmeRtRdy)
      vmeRtCmdVldD1 <= 1'b0;
  end
  
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n || flush)
      vmeRtCmdD1 <= '0;
    else if (vmeRtCmdPop)
      vmeRtCmdD1 <= vmeRtCmd;
  end
#else
  // 原始行为
  dff regVmeRtCmdVldD1 (.q(vmeRtCmdVldD1), .d(vmeRtCmdPop), ...);
  edff regVmeRtCmdD1 (.q(vmeRtCmdD1), .d(vmeRtCmd), .e(vmeRtCmdPop), ...);
#endif
```

**验证**：
- 修复前：213750 只等待 1 拍，tag=5 丢失，tag=8 消费错误数据
- 修复后：213750→215000→216250 持续等待，216250 正确握手

### 3.3 验证（2026-12-04）

**测试环境**：
- 内层仓库：`/home/lizeyu/eng/npu_ft/coralnpu`
- 分支：`fault-tolerance-v3`
- 提交：`531c1667` ("VME FT: 单条 PE 在飞、FT 开启、无注错回归基线")
- 命令：
  ```bash
  # 单用例验证（4×4 matmul，数值读回）
  bazel test //tests/cocotb/vme_test:vme_test_ft_verilator \
    --test_filter=vme_mset_vtmmu_sequence_test \
    --test_sharding_strategy=disabled \
    --nocache_test_results
  
  # FT 开启全量回归
  bazel test //tests/cocotb/vme_test:vme_test_ft_verilator
  
  # FT 关闭回归（对照）
  bazel test //tests/cocotb/vme_test:vme_test_verilator
  ```

**4×4 定向用例（vme_mset_vtmmu_sequence_test）**：
| 验收项 | 结果 |
|--------|------|
| 两条 PE 指令按序退休 | ✅ rob_tag=15 (263750ns) → rob_tag=2 (278750ns) |
| 零失配 | ✅ 4 次 P1 比较全部 match=1（slot=0 grp=0,1; slot=1 grp=0,1） |
| 4×4 矩阵元素验证 | ✅ 16 个元素全部读回为 18 |
| 退休边界检查 | ✅ 3 次 vmeRtCmdPop 都在 vmeRtCmdVldD1=0 时发生，无覆盖违规 |

实测矩阵（result_matrix）：
```
Row 0: [18, 18, 18, 18]
Row 1: [18, 18, 18, 18]
Row 2: [18, 18, 18, 18]
Row 3: [18, 18, 18, 18]
```

**FT 开启全量回归（vme_test_ft_verilator）**：

21 个测试全部通过：

1. vme_mset_csr_test
2. vme_matmul_int8_test
3. vme_matmul_int16_test
4. vme_matmul_bf16_test
5. vme_matmul_fp32_test
6. vme_decode_test
7. vme_mtwiden_test
8. vme_load_store_test
9. vme_transpose_test
10. vme_moveto_test
11. vme_msettm_matmul_test
12. vme_altfmt_test
13. vme_vset_mtype_reset_test
14. vme_mset_retire_test
15. vme_mset_vtmmu_sequence_test（本轮新增数值验证）
16. vme_mstatus_ms_test
17. vme_msettn_msettype_test
18. vme_rvvi_mtype_retire_test
19. vme_rvvi_v0_writeback_test
20. vme_fflags_test
21. vme_unconfigured_trap_test

结果：**21/21 PASSED**

**FT 关闭回归（vme_test_verilator）**：

相同的 21 个测试全部通过。

结果：**21/21 PASSED**

**退休边界检查验证**：
- 检查代码编译生效：`!SYNTHESIS` 条件下每次 vmeRtCmdPop 都触发检查
- 检查条件：`vmeRtCmdVldD1 && !(vmeRtVld && vmeRtRdy) && vmeRtCmdPop`（完整握手）
- 实测结果：所有 3 次 pop 都在 vmeRtCmdVldD1=0 时发生，无违规
- 合法情况（握手同拍 pop）：未触发（表明命令都正常握手完成后才清零）

### 3.4 诊断基线的定位与后续

**本轮完成的工作**：
1. ✅ RS 发射/释放解耦（`zvt_rs_pe_pop & !zvt_ft_inflight`）
2. ✅ 退休命令保持到握手完成
3. ✅ 退休边界检查（防止命令覆盖）
4. ✅ 单条 PE 在飞的串行门控（诊断版本）
5. ✅ 完整性判定的基本逻辑（简化版）
6. ✅ 4×4 matmul 数值读回测试

**标注为诊断基线的原因**：
- **串行门控**：`!ftInFlight` 阻止指令重叠，简化了调试，但不是 04 §4.1 要求的最终状态
- **简化的完成判定**：基于 `blk_complete_simple` 和 dupBuf 清空，未按 slot 追踪预期组数和实际比较进度

**第一阶段后续工作**（按 04 §4.1）：
1. **精确完成判定**：按 slot 锁存预期组数（来自 `pe_exp_grp_i`），追踪每个 block 每个组的比较进度，只有当所有预期组都完成时才允许退休
2. **恢复规范允许的指令重叠**：去掉 `!ftInFlight` 门控，允许多条 PE 指令并发，依赖 RAW 检查和按序校验保证正确性
3. **注错重放与 trap**：
   - 失配时触发回滚（`rollback`），年轻指令作废
   - 重试计数器（`VME_FT_RETRY_MAX`，默认 3）
   - 重试耗尽时上报 trap 事件（`trap_valid_o`，`rob_tag`）
4. **mask 组处理**：明确全 mask 组（所有使能都是 0）如何计入完成
5. **与 M2 done 掩码的衔接**：当前 done 掩码的清零条件较粗，需要与 slot 管理对齐

**不在第一阶段做的**（留到第二阶段）：
- 写入校验与重写（`VME_FT_WCHK_ON`）
- RS 奇偶保护（`VME_FT_RSPAR_ON`）

---

## 与 04 假设不符

| # | 04 的假设 | 实际 | 处理 |
|---|---|---|---|
| 1 | PE 的 rtCmd 改到校验通过时 push | `mtInfoRs` 的注释明确每个 rtCmd push 必须与 mtInfo push 一一对应，否则 `vmeRt` 卡死 | M2 保持 rtCmd 原样，退休链改动留到 M3 |
| 2 | 命令行 `-D` 来不及影响结构体 typedef | 生成文件里宏定义在结构体之前，`-D` 是生效的 | 撤回把 `VME_FT_ON` 写进 `rvv_backend_config.svh` 的做法。那会让不开 FT 的模型也打开 FT |

## 已知问题

（第一阶段结束时整理）

---

## 4. M4：回滚、重试和 trap（单条 PE 在飞）

**目标**：实现 04 §4.1 ④ 的回滚和重试机制，在单条 PE 在飞模式下验证注错恢复。

**交接**：起点 531c1667 (M3 完成)，终点 d20943bd (M4 完成)。

### 4.1 实现

#### 核心机制

**zvt_ft.sv**：
- 重试计数器（`retry_cnt`，最大 `VME_FT_RETRY_MAX=3`）
- trap 输出（`ft_trap_o`, `ft_trap_tag_o`）
- **done 掩码按 int32 元素粒度**（4 字节）：
  - 提交时检查一个元素的所有 4 字节是否匹配
  - 只有全部匹配才提交整个元素
  - **rollback 时保留 done**（04 §4.1 ②），已提交元素不重写
  - ft_pass 时清空 done，为下一条指令准备

**zvt.sv**：
- 回滚状态机（FT_IDLE/DRAIN/ROLLBACK/TRAP）
  - 失配检测 → DRAIN（10 拍排空流水线）→ ROLLBACK 脉冲 → IDLE
  - rollback 脉冲：清零 RS offset、清零 pe_inflight_cnt
- **退休队列去重**（rtCmdVld_gated）：
  - 第一次发射时 push 到 rtCmd
  - 重试时不 push（检查队头是否已有 PE 指令）
  - 避免重复退休

**zvt_ft_rs.sv**：已有 rollback 支持（offset 清零）

**rvv_backend.sv**：添加 VME FT trap 输出端口

#### 设计取舍

**无故障路径优先**：
- PE 指令在发射时 push 到退休队列（保持正常发射间隔）
- 通过门控避免重试时重复 push，而不是延迟到 ft_pass 再 push
- 提交逻辑按元素粒度，但不引入额外的流水级

**回滚路径容错**：
- DRAIN 状态等待 10 拍排空流水线（保守估计）
- 回滚时保留 done 掩码（避免重复写入）
- 失败尝试的 mtInfo 暂未作废机制（依赖单条限制）

### 4.2 测试结果

#### 定向测试：vme_test_ft_inj_mset_seq

**配置**：
```python
testcases = ["vme_mset_vtmmu_sequence_test"]  # 4×4 矩阵，两条 vtmmu
test_args = ["+VME_FT_INJ_SITE=p1", "+VME_FT_INJ_N=1"]  # 第一次有效写入注错
```

**验收通过**（提交 d20943bd）：
- ✅ inject=1, mismatch=1（第一条指令 grp=0 失配）
- ✅ 失败尝试提交 7 元素（28 字节），失配元素未提交
- ✅ 回滚保留 done，重试只提交 9 元素（36 字节）
- ✅ 两条 PE 指令各退休一次（rob_tag=15, rob_tag=2）
- ✅ commit_bytes=128（28+36+64，精确）
- ✅ 程序正常 halt
- ✅ **数值验证通过**：16 个结果全为 18

**日志位置**：`/tmp/vme_ft_logs/mset_seq_pass.log`（24KB）

#### 回归测试：vme_test_ft_inj_p1

**配置**：
```python
testcases = ["vme_matmul_int8_test"]
test_args = ["+VME_FT_INJ_SITE=p1", "+VME_FT_INJ_N=3"]
```

**结果**：PASSED（2.3s，之前超时 10s+）

**日志位置**：`/tmp/vme_ft_logs/inj_p1_pass.log`（223KB）

### 4.3 已知限制

**当前实现**（单条 PE 在飞）：
- zvt_ctrl.sv: `peCmdVld` 门控 `!ftInFlight`
- 新 PE 指令必须等前一条释放才能发射
- 简化了 done 掩码管理（全局的，按指令清空）

**待解决**（M5）：
- 恢复指令重叠（同 tile RAW 间隔 ≥6 拍，不同 tile 并行）
- 持续注错的 trap 验证（rob_tag 上报到 L1）
- 失败尝试的 mtInfo 作废机制

### 4.4 可复现命令

```bash
# 定向测试（数值验证）
bazel test //tests/cocotb/vme_test:vme_test_ft_inj_mset_seq_verilator --nocache_test_results

# 回归测试
bazel test //tests/cocotb/vme_test:vme_test_ft_inj_p1_verilator --nocache_test_results

# 查看详细日志
cat bazel-testlogs/tests/cocotb/vme_test/vme_test_ft_inj_mset_seq_verilator/test.log | \
  grep -E "VME_FT_COMMIT|VME_FT_ROLLBACK|RETIRED|commit_bytes"
```


---

## 5. M4 补充：mtInfo 退休配对修复

**问题发现**（提交 d20943bd 后）：
从日志 `/tmp/vme_ft_logs/mset_seq_pass.log` 发现退休配对问题：
- **第 234 行**：rob_tag=2 (PC=0x198) 退休时，blk=0 队头仍是 PC=0x18c（旧数据）
- **根因**：失败尝试的 mtInfo 未作废，污染后续退休记录

**修复**（提交 7d9cc321）：
- 回滚时清空所有 mtInfo FIFO（`mtInfo_clear = flush || ft_rollback`）
- 确保只消费成功尝试的 4 份 mtInfo

**修复前后对比**：
```diff
修复前（mset_seq_pass.log 第 233-238 行）：
[VME_RT_STATE] 303750 vmeRtCmdVldD1=1 PC=0x198 tag=2 mtVld=1111
-[VME_RT_STATE]   blk=0 head_PC=0x18c  ← 错误！应该是 0x198
[VME_RT_HANDSHAKE] 303750 PC=0x198 rob_tag=2 RETIRED

修复后（mset_seq_mtinfo_fixed.log）：
[VME_RT_STATE] 306250 vmeRtCmdVldD1=1 PC=0x198 tag=2 mtVld=1111
+[VME_RT_STATE]   blk=0 head_PC=0x198  ← 正确！
[VME_RT_HANDSHAKE] 306250 PC=0x198 rob_tag=2 RETIRED
```

**验收结果**：
- ✅ 每次退休时，4 个 block 的 mtInfo 队头 PC 均与指令 PC 匹配
- ✅ 数值验证保持正确（16×18）
- ✅ 提交字节保持 128
- ✅ vme_test_ft_inj_p1 回归通过（2.3s）

**设计取舍**：
- 退休延后 2500 ps = 2.5 ns（整核时钟 2 拍，时钟周期 1.25 ns；注意模块 fixture 使用 10 ns 时钟），从 303750 到 306250，符合"回滚多花几拍"的设计目标
- 无故障路径未受影响

**日志位置**：
- 修复前：`/tmp/vme_ft_logs/mset_seq_pass.log`（问题对照）
- 修复后：`/tmp/vme_ft_logs/mset_seq_mtinfo_fixed.log`（配对正确）
- INT8 回归：`/tmp/vme_ft_logs/inj_p1_pass.log`（2.3s 通过）


---

## 6. M4 验收：老记录保护（双指令背压测试）

**验收范围**：验证第一条 PE 已校验成功、四份 mtInfo 正在等待退休时，第二条 PE 命中失配，第一条的记录能否完整保留并正确退休一次。

**代码提交**：`90753444e90b49546f1ea13182f7eee1ae4e3499` (fault-tolerance-v3)

### 6.1 测试设计

**Fixture**：模块级 Cocotb 测试 + Python 参考模型
- **Wrapper**：`zvt_retire_backpressure_wrapper.sv` - 采样 mtInfo push/pushRdy/pop/clear、ft_mismatch
- **Driver**：`zvt_uop_driver.sv` - 支持两条指令（tag 5/PC 0x100，tag 7/PC 0x200）
- **参考模型**：`zvt_dual_insn_refmodel_test.py` - 追踪每个 block 队列，严格验证握手和清除

**参考模型验证逻辑**：
1. **入队追踪**：按 `mtInfo[i].Vld && mtInfoRdy[i]` 记录成功入队，标记指令 tag 和失配状态
2. **握手验证**：
   - 检查所有 4 个 block 队头非空
   - 检查所有队头 tag 与 retire_tag 一致
   - 检查队头不是失配尝试
3. **清除验证**：
   - 禁止清除已接受、未退休、非失配的记录
   - 强制检查期望的 tag 和每个 block 的记录数量
4. **事件完整性**：前提、失配、握手、清除缺失均导致失败

**测试场景**：
- **N=3 正例**：第二条指令失配（跳过第一条的 2 次 p1 比较）
- **N=1 负例**：第一条指令失配，前提永远无法满足，第二条从未发送

### 6.2 测试结果

#### N=3 修复版（当前）

**目标**：`//tests/cocotb/vme_test:zvt_dual_insn_test_zvt_dual_insn_mismatch_test`

**退出码**：0 (PASSED)

**关键事件**（单位：ns，时钟周期 10ns）：
```
160    [RefModel] Instruction accepted: tag=5 PC=0x100
230    ftRel=1 (第一条校验完成)
235    Lowered vmeRtRdy_ctrl (开始阻塞)
270    Prerequisite met: tag=5 blocked at retire (mtRtInfoVld=1111, ready=0)
470    [RefModel] Instruction accepted: tag=7 PC=0x200
520    [VME_FT] inject site=p1 blk=0 grp=0 slot=1 (第二条第1次p1)
520    [VME_FT] mismatch blk=0 grp=0 slot=1 -> squash
520    [RefModel] Instruction mismatched: tag=7
200480 [VME_RT_HANDSHAKE] PC=0x100 rob_tag=5 RETIRED
200480 [RefModel] ✓ Handshake valid: tag=5 retired
200510 [CLEAR] mtInfo_clear asserted at handshakes=1
200510 Clear check: Block 0-3 each has [tag=7 PC=0x200 mismatched=True]
200510 [RefModel] ✓ CLEAR CHECK PASSED
```

**验收确认**：
- ✅ N=3 跳过第一条的 2 次 p1，命中第二条
- ✅ 前提满足：tag=5 到达退休接口被阻塞（mtRtInfoVld=1111）
- ✅ 失配检测：tag=7 在 520ns 失配
- ✅ 排空等待：释放背压前零次握手，清除前已有一次握手（tag=5 在 200.48us）
- ✅ 老指令退休：tag=5 在 200.48us 握手一次
- ✅ 清除验证：每个 block 恰有 1 份 tag=7 失配记录
- ✅ 总握手数：1

**test.log 路径**：
```
coralnpu/bazel-testlogs/tests/cocotb/vme_test/zvt_dual_insn_test_zvt_dual_insn_mismatch_test/test.log
```

#### N=3 旧版（7d9cc321）

**退出码**：3 (FAILED)

**失败时刻**：650ns（握手数=0）

**首条断言**：
```
650.00ns ERROR [RefModel] ✗ CLEAR CHECK FAILED: Clearing validation failed:
  - Block 0: tag=5 PC=0x100 (accepted, NOT retired, NOT mismatched)
  - Block 0: has 2 records, expected 1
  - Block 0: found tag=5, expected tag=7
  - Block 1: tag=5 PC=0x100 (accepted, NOT retired, NOT mismatched)
  - Block 1: has 2 records, expected 1
  - Block 1: found tag=5, expected tag=7
  - Block 2: tag=5 PC=0x100 (accepted, NOT retired, NOT mismatched)
  - Block 2: has 2 records, expected 1
  - Block 2: found tag=5, expected tag=7
  - Block 3: tag=5 PC=0x100 (accepted, NOT retired, NOT mismatched)
  - Block 3: has 2 records, expected 1
  - Block 3: found tag=5, expected tag=7
```

**RTL 日志验证**：
```
[VME_RT_STATE] 620-650ns: PC=0x100 tag=5 mtVld=1111 vmeRtVld=1 vmeRtRdy=0
[VME_FT_MTINFO_CLEAR] 650000 Clearing mtInfo FIFOs on rollback
```

**验收确认**：
- ✅ 旧版在排空完成后立即清除（650ns）
- ✅ 此时 tag=5 还在等待退休（握手数=0）
- ✅ 参考模型检测到将清除未退休的老记录
- ✅ 每个 block 有 2 条记录（tag=5, tag=7），期望只有 1 条（tag=7）

**test.log 路径**：
```
coralnpu-7d9cc321/bazel-testlogs/tests/cocotb/vme_test/zvt_dual_insn_test_zvt_dual_insn_mismatch_test/test.log
```

#### N=1 负例

**目标**：`//tests/cocotb/vme_test:zvt_dual_insn_test_negative_zvt_dual_insn_mismatch_test`

**退出码**：非 0 (FAILED)

**失败时刻**：340ns

**关键事件**：
```
210 [VME_FT] inject site=p1 blk=0 grp=0 slot=0 (第一条第1次p1)
210 [VME_FT] mismatch blk=0 grp=0 slot=0 -> squash (tag=5命中)
340 [CLEAR CHECK FAILED]:
    - Block 0-3: found tag=5, expected tag=7
```

**验收确认**：
- ✅ N=1 命中第一条指令（tag=5）
- ✅ 第一条失配，前提永远无法满足
- ✅ 第二条指令（tag=7）从未被发送
- ✅ 清除时只有 tag=5 记录，参考模型期望 tag=7 而失败

**test.log 路径**：
```
coralnpu/bazel-testlogs/tests/cocotb/vme_test/zvt_dual_insn_test_negative_zvt_dual_insn_mismatch_test/test.log
```

### 6.3 对比总结

| 测试 | 版本 | 退出码 | 关键时刻 | 握手数 | 结果 |
|------|------|--------|----------|--------|------|
| N=3 | 修复版 | 0 | 200.48us | 1 | ✅ tag=5 先退休，后清除 tag=7 |
| N=3 | 7d9cc321 | 3 | 650ns | 0 | ❌ tag=5 未退休被清除 |
| N=1 | 修复版 | 非 0 | 340ns | 0 | ✅ tag=5 命中，tag=7 未发送 |

**结论**：修复版（当前）正确保护老记录，旧版（7d9cc321）在排空后立即清除导致误删。

### 6.4 可复现命令

```bash
# N=3 正例（修复版）
cd coralnpu
bazel test //tests/cocotb/vme_test:zvt_dual_insn_test_zvt_dual_insn_mismatch_test

# N=3 对照（旧版）
cd coralnpu-7d9cc321
bazel test //tests/cocotb/vme_test:zvt_dual_insn_test_zvt_dual_insn_mismatch_test

# N=1 负例
cd coralnpu
bazel test //tests/cocotb/vme_test:zvt_dual_insn_test_negative_zvt_dual_insn_mismatch_test

# 查看参考模型日志
grep -E "RefModel|CLEAR.*CHECK|VME_RT_HANDSHAKE|VME_FT.*mismatch" test.log
```

---

## 7. 正常复制路径发射间隔测量（订正）

**测量目标**：建立无注错、无背压条件下的正常复制性能基线。

**代码提交**：4d825283（监控逻辑修正 + 整核测试）

### 7.1 上轮测量问题诊断

**问题1 - 激励端错误**：
- 模块级 fixture 等第一条退休后又等10拍才发第二条
- 测得"26拍"间隔 = ~14拍等退休 + 10拍脚本延迟 + 2拍发射
- 使用10 ns fixture时钟，不反映整核真实行为

**问题2 - 监控配置缺口**：
- 直接引用 `peCmd[0].uop_pc`，依赖 `TB_SUPPORT` 宏
- 未验证 FT 开且 `TB_SUPPORT` 未定义的生产配置

**问题3 - 数值验收缺失**：
- 模块级测试未运行原始的 16×18 读回断言
- 无法验证两条指令的数值正确性

### 7.2 整核程序测量（正确方法）

**测试配置**：
- **程序**：vme_mset_vtmmu_sequence_test.cc
- **指令序列**：
  1. mset 配置（msetmtype, msettn, msettm, msettk）
  2. vtzero mt0
  3. 第一条 vtmmu.tvv（v0=1, v8=2）
  4. 操作数更新（v0=2）
  5. 第二条 vtmmu.tvv（v0=2, v8=2）
  6. 结果读回验证
- **验证**：result_matrix 16个元素均为18
- **FT配置**：VME_FT_ON，无注错，无外加背压
- **目标**：`//tests/cocotb/vme_test:vme_test_ft_dispatch_interval_verilator`

**RTL监控修正（zvt_pe_array.sv:259-271）**：
```systemverilog
#ifdef TB_SUPPORT
  $display("[VME_FT_G0P0_DISPATCH] %0t PC=0x%0h tag=%0d cnt=%0d pass=%0d blk=0",
           $time, peCmd[0].uop_pc, peCmd[0].rob_tag, cnt, pass);
#else
  $display("[VME_FT_G0P0_DISPATCH] %0t tag=%0d cnt=%0d pass=%0d blk=0",
           $time, peCmd[0].rob_tag, cnt, pass);
#endif
```

### 7.3 两版本实测结果

**整核时钟**：1.25 ns/拍（从时间戳递增 1250 ps 推断）

#### 当前版本（4d825283）
```
[VME_FT_G0P0_DISPATCH] 246250 PC=0x18c tag=15 cnt=0 pass=0 blk=0
[VME_FT_G0P0_DISPATCH] 261250 PC=0x198 tag=2 cnt=0 pass=0 blk=0
[VME_RT_HANDSHAKE] 263750 PC=0x18c rob_tag=15 isStore=0 RETIRED
[VME_RT_HANDSHAKE] 278750 PC=0x198 rob_tag=2 isStore=0 RETIRED
✓ All 16 elements of 4×4 matrix verified = 18
```

- **第一条 g0p0**：246250 ps（PC=0x18c, tag=15）
- **第二条 g0p0**：261250 ps（PC=0x198, tag=2）
- **发射间隔**：15000 ps = 15 ns = **12 拍**
- **数值验证**：✅ 通过

#### 旧版本（7d9cc321）
```
[VME_FT_G0P0_DISPATCH] 246250 PC=0x18c tag=15 cnt=0 pass=0 blk=0
[VME_FT_G0P0_DISPATCH] 261250 PC=0x198 tag=2 cnt=0 pass=0 blk=0
[VME_RT_HANDSHAKE] 263750 PC=0x18c rob_tag=15 isStore=0 RETIRED
[VME_RT_HANDSHAKE] 278750 PC=0x198 rob_tag=2 isStore=0 RETIRED
✓ All 16 elements of 4×4 matrix verified = 18
```

- **第一条 g0p0**：246250 ps（PC=0x18c, tag=15）
- **第二条 g0p0**：261250 ps（PC=0x198, tag=2）
- **发射间隔**：15000 ps = 15 ns = **12 拍**
- **数值验证**：✅ 通过

#### 对比分析

| 版本 | 第一条g0p0 (ps) | 第二条g0p0 (ps) | 间隔 (拍) | 数值验证 |
|------|----------------|----------------|----------|---------|
| 7d9cc321（旧版，误删） | 246250 | 261250 | 12 | ✅ |
| 4d825283（当前，修复） | 246250 | 261250 | 12 | ✅ |
| **差异** | 0 | 0 | **0** | - |

### 7.4 结论

1. **性能保持一致**：修复版本在正常复制路径上发射间隔与旧版完全相同（12拍），12 拍间隔来自 FT 机制本身（单在飞门控），非修复引入的额外开销
2. **满足设计要求**：12拍 > 6拍（04 §4.1 同tile最小间隔要求）
3. **数值正确性**：两版本都通过16×18结果验证
4. **基线建立**：此数据可作为M5精确完成判定和指令重叠工作的性能基线

**上轮错误测量的适用范围**：
- 模块级fixture以10 ns时钟测得"26拍"
- 该值为特定送入时序（等退休+10拍脚本延迟）下的观测值
- 不反映整核真实指令流的发射间隔
- 已由本轮整核测量（12拍）替代

### 7.5 原始日志位置

**当前版本**：
```
bazel-testlogs/tests/cocotb/vme_test/vme_test_ft_dispatch_interval_verilator/test.log
/tmp/fullcore_dispatch_current.log
```

**旧版本（7d9cc321 worktree）**：
```
/home/lizeyu/eng/npu_ft/coralnpu-7d9cc321/bazel-testlogs/tests/cocotb/vme_test/vme_test_ft_dispatch_interval_verilator/test.log
/tmp/fullcore_dispatch_old.log
```

**详细对比报告**：
```
tests/cocotb/vme_test/FULLCORE_DISPATCH_COMPARISON.md
```

### 7.6 可复现命令

```bash
# 在当前版本运行
cd /home/lizeyu/eng/npu_ft/coralnpu
bazel test //tests/cocotb/vme_test:vme_test_ft_dispatch_interval_verilator --test_output=streamed

# 在旧版本运行
cd /home/lizeyu/eng/npu_ft/coralnpu-7d9cc321
bazel test //tests/cocotb/vme_test:vme_test_ft_dispatch_interval_verilator --test_output=streamed

# 提取关键信息
grep -E "VME_FT_G0P0_DISPATCH|All 16 elements" test.log
```

### 7.7 最小间隔测试：监控修复与等待原因分析

**代码提交**：
- d23693c8：修复监控遗漏，分离激励与监控
- ccff1391：补齐门控信号采样，完整等待原因分析

**问题背景**：
- 上轮模块级测试（§7.1）发现 Python 监控循环在第二条请求发出后才启动
- 漏捕第一条（tag=5）的 g0p0 发射事件（130ns）
- 只看到第二条（tag=7）发射（250ns），无法验证间隔

**核心修复（d23693c8）**：
1. **后台监控任务**：从复位释放后持续运行，使用统一周期计数
2. **分离激励与监控**：激励负责发送指令、等待握手；监控独立捕获所有发射和退休
3. **完整事件验证**：
   - 自动验证 g0p0 tag 序列 [5, 7]
   - 验证两条指令同 tile（tile=0）
   - 验证间隔 ≥6 拍（实测 12 拍）
   - 验证退休序列 [5, 7]

**等待原因补齐（ccff1391）**：
1. **门控信号采样**（wrapper 层次访问）：
   - `rtCmdRdy`：retire command ready（来自 zvt_inst.zvtCtrl.rtCmdRdy）
   - `peCmdVld[0]`：PE command valid（来自 zvt_inst.zvtCtrl.peCmdVld[0]）
   - `ftInFlight`：已采样（zvt_inst.ftInFlight）
   - `ftRel`：已采样（zvt_inst.ftRel）
   - `hitRaw`：same-tile RAW hazard（来自 zvt_inst.zvtPeArray.hitRaw）
   - `blkCmdRdy[0]`：block 0 ready（来自 zvt_inst.zvtPeArray.blkCmdRdy[0]）

2. **排空期持续监视**：
   - 收齐 2 次发射和 2 次退休后，继续采样 10 拍
   - 检测虚假发射或退休，立即失败
   - 增加超时断言（1000 拍），打印已收集事件

3. **完整等待分析表**：

```
tag=7 waiting analysis (cycle 11 to 19):
NOTE: Signals shown are sampled at cycle N (available for use at cycle N+1)
Cycle  ftInFlt  ftRel   rtRdy   peVld   hitRaw   blkRdy0  Blocking
11     1        0       1       0       1        1        ftInFlight, !peCmdVld
12     1        0       1       0       0        1        ftInFlight, !peCmdVld
13     1        0       1       0       0        1        ftInFlight, !peCmdVld
14     1        0       1       0       0        1        ftInFlight, !peCmdVld
15     1        0       1       0       0        1        ftInFlight, !peCmdVld
16     1        0       1       0       0        1        ftInFlight, !peCmdVld
17     1        1       1       0       0        1        ftInFlight, !peCmdVld
18     0        0       1       0       0        1        !peCmdVld
19     0        0       1       1       0        1        none

Release: ftRel sampled at cycle 17, used at cycle 18
Dispatch: tag=7 dispatched at cycle 19
```

**阻挡条件分析**：
- **周期 11-17**：`ftInFlight=1` 且 `!peCmdVld`
  - tag=5 仍在 FT 流水线中（从 170ns 到 230ns，对应周期 11-17）
  - `peCmdVld` 受 `rtCmdRdy && !ftInFlight` 门控（zvt_ctrl.sv:152）
- **周期 17**：`ftRel=1` 被采样（230ns 上升沿后 Cocotb 读到）
  - RTL 在 240ns 上升沿使用该信号
  - `ftInFlight` 在周期 18（240ns 上升沿后）降为 0
- **周期 18**：`ftInFlight=0`，但 wrapper 锁存的沿前 `peCmdVld` 仍为 0
- **周期 19**：wrapper 锁存的沾前 `peCmdVld=1`，tag=7 发射（250ns）

**采样口径说明**：
- `ftInFlight`、`ftRel`：Cocotb 在上升沿后 ReadOnly 阶段读到的当前值
- `peCmdVld`、`hitRaw`、`blkCmdRdy[0]`：wrapper 在上升沿锁存的沿前组合逻辑值
- 周期 N 的两类信号不代表同一时刻，不能直接推导门控延迟

**关键发现**：
1. **12 拍间隔由 ftInFlight 阻挡**：tag=7 必须等待 tag=5 的 FT 流水完成
2. **门控逻辑符合设计**：`peCmdVld = isPe[0] && rtCmdRdy && !ftInFlight`（zvt_ctrl.sv:152）
3. **hitRaw 未独立验证**：本测试两条指令用同一 tile，hitRaw 在周期 11 锁存为 1，但该值是沿前采样、tag=7 四路有效是沿后才呈现，无法据此判断 tag=7 独立受 RAW 阻挡
4. **rtCmdRdy 和 blkCmdRdy[0]**：在所列周期窗口始终为 1，非阻挡因素

**验收自动化**：
```bash
# 正例：间隔 ≥6 拍（实测 12 拍）
bazel test //tests/cocotb/vme_test:zvt_min_dispatch_test_zvt_min_dispatch_interval_test --test_output=errors
# Bazel 退出码：0

# 负例：临时设置间隔 ≥13 拍
# （修改 zvt_min_dispatch_test.py:line 193，assert interval >= 13）
bazel test //tests/cocotb/vme_test:zvt_min_dispatch_test_zvt_min_dispatch_interval_test --test_output=errors
# Bazel 退出码：3
# 失败消息："FAIL: Interval 12 < 13 cycles (measured 12, required 13)"
```

**原始日志**：
```
/tmp/test_full_signals.log          # 完整信号采样通过日志
/tmp/test_final_pass.log            # 正例（下限 6）
/tmp/test_final_fail.log            # 负例（下限 13）
bazel-testlogs/tests/cocotb/vme_test/zvt_min_dispatch_test_zvt_min_dispatch_interval_test/test.log
```

**待覆盖场景**：
- **同 tile RAW 独立阻挡**：本测试 hitRaw 与 ftInFlight 重叠，且采样口径不同，无法分离验证
- **不同 tile 并行发射**：需要额外测试验证不同 tile 间无间隔限制

**订正旧表述**：
1. ~~"26 拍间隔"~~（§3.2 line 311）→ **12 拍间隔**（整核测量 §7.2）
2. ~~"普遍无性能开销"~~（§7.4 line 887）→ **12 拍间隔来自 FT 机制本身（单在飞门控），非修复引入的额外开销**
3. ~~"清除前零次握手"~~（§6.2.2 line 690）→ **释放背压前零次握手，清除前已有一次握手**（该测试上下文）


## 8. 精确完成判定修复（M5）

**代码提交**：
- ccfcd1b8：实现精确完成判定，按槽跟踪期望组数（发现问题，已被后续提交修复）
- 42ba8d45：修复回滚清空 grp_seen 和发射时锁存期望组数

### 8.1 问题诊断

**问题1：回滚后提前完成**
- 失败尝试的 grp_seen 全1掩码被保留
- 重放立即满足完成条件，在 g0p0 发射当拍就 ftPass=1
- tag 15 在 531250ps 重发，同拍误报完成、弹退休命令、清 done
- 导致同一元素重复提交（首次 0x155e，重放 0x2abc = 2×原值）

**问题2：期望组数捕获时机错误**
- zvt_ft 在首次写回 p0 到达时捕获 pe_exp_grp_i
- 但 pe_exp_grp_i 是组合逻辑，反映 PE 阵列当前 peCmd 状态
- 发射到首次写回延迟 7 拍，此时可能已是下一条指令
- 5×7 形状（tm=5, tn=7）在 3430000ps 发射，期望 [3,0,0,0]
- 但 3438750ps 捕获时记录为 [4,4,4,4]（下一条指令的值）
- 导致等待 block 1/2/3 的不存在组，永不完成，测试超时

### 8.2 修复方案

**修复1：回滚时清空 grp_seen**
- 位置：zvt_ft.sv line 258 rollback_i 分支
- 改动：增加 `grp_seen <= '0;`
- 原因：重放必须独立建立本次验证资格
- done 掩码继续保留，保护已提交元素

**修复2：发射时锁存期望组数**
- 位置：zvt_pe_array.sv line 424-447
- 改动：
  - 新增 ftExpGrp_comb：组合逻辑计算期望组数
  - 新增 ftExpGrpReg：在 g0p0 发射时（cntEn && cnt==0 && pass==0）锁存
  - 修改 ftExpGrp 输出为 ftExpGrpReg（稳定值）
- 原因：发射时刻的值归属当前指令，后续可安全采样

### 8.3 验收结果

**测试1：vme_test_ft_inj_p0_verilator (INT8 p0注错)**

| 指标 | 结果 | 证据位置 |
|---|---|---|
| Bazel 退出码 | 0 (PASS) | - |
| 测试结果 | TESTS=21 PASS=1 FAIL=0 SKIP=20 | test.log 末尾 |
| tag 15 重发修复 | 531250ps ftPass=0（修复前为1） | line 243 |
| tag 15 完成 | 552500ps 完成，553750ps 唯一退休 | line 410, 420 |
| tag 15 元素 | 256 个元素，首次 572 字节、重放 452 字节 | 人工核对提交日志 |
| 跨尝试唯一性 | 各元素仅提交一次，无重复 | 人工核对地址 |
| 5×7 发射时期望组数 | 3430000ps [3,0,0,0] | line 2176 |
| 5×7 捕获时期望组数 | 3438750ps [3,0,0,0]（修复前为 [4,4,4,4]） | line 2177 |
| 5×7 元素 | 35 个元素，首次 136 字节、重放 4 字节 | 人工核对 |
| 5×7 完成 | 3478750ps 完成，3482500ps 退休 | line 2276, 2284 |

**测试2：vme_test_ft_inj_mset_seq_verilator (4×4 双乘加 p1注错)**

| 指标 | 结果 | 证据位置 |
|---|---|---|
| Bazel 退出码 | 0 (PASS) | - |
| 测试结果 | TESTS=21 PASS=1 FAIL=0 SKIP=20 | test.log 末尾 |
| p1 注错 | 256250ps inject site=p1 blk=0 grp=0 slot=0 | line 70 |
| 失配检测 | MISMATCH blk=0 port=0 byte=0 | line 71 |
| 失配详情 | db_data=0x05 vs pe_data=0x04 | line 71 |
| 回滚 | 271250ps ROLLBACK pulse | line 73 |
| done 保留 | rollback preserves done mask | line 76 |
| 实际重发 | 273750ps 同一 PC、tag 15 再次 g0p0 | line 106 |
| 提交统计 | 第一条 28+36 字节，第二条 64 字节，共 128 | line 279 |
| 内存验证 | All 16 elements of 4×4 matrix verified = 18 | line 222 |

### 8.4 已知限制

1. **状态非槽化**：ftExpGrpReg、exp_grp_saved、grp_seen 各只有一套，未按 slot 独立保存
   - 单在飞时正确：当前版本保持生产单在飞门控（zvt_ctrl.sv:152 `!ftInFlight`）
   - 重叠时风险：恢复指令重叠前需按槽独立保存完成状态
   
2. **元素唯一性检查**：跨尝试元素各提交一次已人工核实，尚未自动化

3. **定向测试缺失**："最后期望组延后、dupBuf 暂空"场景需独立测试
   - 建议形状：tm=11, tn=11 → 期望 [4,4,2,2]
   - 验证点：前面组完成、dupBuf 空、最后组未到时 ft_pass=0

### 8.5 下一步工作

1. 创建 tm=11 tn=11 定向测试，证明当前版等待最后组
2. 将元素唯一性纳入自动断言
3. 按 slot 独立保存 exp_grp、grp_seen、blk_all_grp_seen
4. 恢复指令重叠（移除 !ftInFlight 门控）

**原始日志**：
```
bazel-testlogs/tests/cocotb/vme_test/vme_test_ft_inj_p0_verilator/test.log
bazel-testlogs/tests/cocotb/vme_test/vme_test_ft_inj_mset_seq_verilator/test.log
```


### 8.6 tm=11 tn=11 对比测试

**测试用例**: 添加到 vme_matmul_int8_test
- tm=11, tn=11, tk=3
- 期望组数: [4,4,2,2] (block 0/1 各4组, block 2/3 各2组)
- 验证高半区启用且各 block 组数不同的场景

**ccff1391 版本**:
- Bazel 退出码: 0 (PASS)
- 测试结果: TESTS=21 PASS=1 FAIL=0
- 说明: 未锁存版本在正常顺序执行时也能通过

**42ba8d45 版本**:
- Bazel 退出码: 0 (PASS)
- 测试结果: TESTS=21 PASS=1 FAIL=0
- 关键日志:
  - 4406250ps 发射时: blk0=4 blk1=4 blk2=2 blk3=2 ✓
  - 4415000ps 捕获时: blk0=4 blk1=4 blk2=2 blk3=2 ✓
  - 4438750ps 重放时: blk0=4 blk1=4 blk2=2 blk3=2 ✓

**对比结论**:
1. tm=11 tn=11 在两版本都通过（顺序执行无串扰）
2. 5×7 案例已证明版本差异（ccff1391 超时，42ba8d45 通过）
3. 当前测试验证了发射时锁存机制的正确性

**未覆盖场景**:
- "前面组已处理、dupBuf 空、最后组延后"需要精确控制 p0/p1 时序
- 需创建专门的 zvt_ft 模块级测试（作为未来工作）

**代码提交**: 8572c25d (添加 tm=11 tn=11 测试用例)

