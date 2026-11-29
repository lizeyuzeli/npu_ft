# 05 · VME 容错实现与功能验证

> 第 05 阶段：按 04-vme-ft-design.md R2 的方案实现 VME 容错，并做 RTL 注错（Verilator）的功能验证。
> 第一阶段是核心机制（`VME_FT_ON`）；第二阶段是写入校验（`VME_FT_WCHK_ON`）和 RS 奇偶（`VME_FT_RSPAR_ON`），每项可单独叫停。
> 方案、宏定义、验证项、不做的事项以 04 为准（§4.1～4.3、§6）；本文件只记实现过程、测试结果和与 04 假设不符的地方。
> 分支：`fault-tolerance-v3`，起点 `29a4e555`（RVV FT）。
> 状态（2026-11-29）：**第一阶段（M1～M5）完成**，签收提交 `ed5cd672`（RTL `70170f44`），验收见 §10（§10.8 为签收简表）。第二阶段 M6/M7 未开始。
> §3～§8 记录的单在飞门控、回滚清 mtInfo、`blk_complete_simple` 等过渡机制已被 §9 替换；§9 中重试上限（第 RETRY_MAX+1 次失败才 trap）、trap 合并、§9.8 简表和 `31f5f487` 日志目录已被 §10 订正，结论以 §10 为准。

## 里程碑

| 里程碑 | 内容 | 状态 |
|---|---|---|
| M1 | VME FT 头文件 + 专用 RS 模块 + RS 单元测试 + 直通模式接入 `rvv_backend.sv` | 完成 |
| M2 | 交错发射（`zvt_pe_array.sv`、`zvt_pe_block.sv`）+ 写口前提交单元（只检测） | 完成 |
| M3 | 按序校验、RS 当 ROB（发射/释放解耦）、退休链、`zvt_ctrl.sv` 配套改动；FT 开不注错回归 | 完成 |
| M4 | 回滚、重试、trap 事件；单条 PE 在飞模式下注错测试通过 | **完成** |
| M5 | 恢复指令重叠、持续注错 trap 验证、第一阶段其余 §6.3 验收项（§9；签收收尾 §10） | **完成**（`ed5cd672`） |
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
| 3 | PE 的 rtCmd 在校验通过时 push（§4.1 ③） | rtCmd 的 push 受 `rtCmdRdy` 约束，放到校验时要预留空位 | M5：rtCmd 仍在**首次**发射时 push（重发不再 push），mtInfo 改为校验通过时 push；失败尝试什么都不推，回滚不清 mtInfo（§9.1） |
| 4 | 换头当拍"零余量，要加断言"（§4.1 ④） | 后一条第一次比较与前一条最后一次比较同拍是常态（n=4 时每条都如此） | 实现为显式换头：同拍新队头的比较直接提交；不属于队头也不属于换头的比较按失配处理（回滚），不只报断言 |
| 5 | `VME_FT_RETRY_MAX` "连续失败几次后报 trap" | 字面与"设成 0 就是只检测"矛盾 | 按"允许的重试次数"实现：第 RETRY_MAX+1 次失败报 trap，0 即首次失配报 trap |
| 6 | 回滚排空"约 10 拍" | 排空条件取阵列空闲（含 skew 级）和提交级空，下限 4 拍 | 实测检测到回滚脉冲 10～11 拍，每次回滚使该指令通过推迟 20～27 拍 |
| 7 | 同 tile RAW 按 tile 号比较 | int32 累加器占 4 个 MT，`dst_index[4:1]` 不同的两个 tile 可能落在同一组 MT | 比较 `dst_index[4:3]`（累加器组），更严，对 4 对齐的 tile 无差别 |

## 已知问题

第一阶段的已知限制和遗留见 §9.6。

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

2. **元素唯一性检查**：已纳入自动退出条件，见 §8.7。
   跨尝试各元素只提交一次由检查器判定，不再只靠人工核对。

3. **定向测试缺失**：tm=11 tn=11 的顺序执行对比见 §8.6。
   "前面组已处理、dupBuf 空、最后组延后"的四 block 缺组场景已由
   模块级测试验证，见 §8.8。

### 8.5 下一步工作

1. 按 slot 独立保存 exp_grp、grp_seen、blk_all_grp_seen
2. 恢复指令重叠（移除 !ftInFlight 门控）

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

### 8.7 跨尝试元素提交唯一性（自动退出条件）

**检查单位**：同一条逻辑指令、同一个实际目的元素
`(blk, port, elem, mt, sub)`。同一条 PE 重放时 slot 可以变化，
已经提交的元素仍只能写一次；下一条合法乘加即使写同一地址，
也重新计数。

**检查器**：`tests/cocotb/vme_test/check_commit_uniqueness.py`，
退出条件是 Bazel 目标
`//tests/cocotb/vme_test:check_commit_uniqueness_test`。
发现重复、缺注错、缺重放或缺应提交元素时返回非零，并报告
逻辑指令、元素地址、首次与重复提交的行号、时间和 slot。
生产单在飞门控（`zvt_ctrl.sv:152` 的 `!ftInFlight`）保持不变。

**旧故障**：`/tmp/ft_precise_fix_test.log`。tag 15 的
`(blk=0, port=0, elem=0, mt=0, sub=0)` 在第 62 行 508750ps、
slot 0 提交 `0x0000155e`，又在第 287 行 541250ps、slot 1 提交
`0x00002abc`。检查器返回 1，报告 143 处重复；加 `--expect-fail`
后返回 0。

**合法回归**（现有定向日志，检查器返回 0）：

| 用例 | 结果 |
|---|---|
| 5×7 注错重放（`vme_test_ft_inj_p0`，tag 4，3430000ps） | 一次注错、一次重放，35 个不同元素、140 字节，无重复 |
| 4×4 双乘加（`vme_test_ft_inj_mset_seq`） | tag 15 与 tag 2 各提交 16 个元素一次，合计 128 字节；最终内存 16×18 |

**缺事件也失败**：定向夹具去掉 5×7 的注错、重放或任一应提交元素后，
同一 Bazel 目标返回非零。

### 8.8 四 block 缺组对照（已验证）

`c87fc237`（多块精确完成测试：同拍接收监视与独立期望组检查）的
`[4,4,2,2]` 模块级对照已验证，不再是待办。

- 目标：`//tests/cocotb/vme_test:zvt_precise_completion_test`，
  用例 `zvt_precise_completion_multiblock_4_4_2_2_test`。
- 期望组数 `[4,4,2,2]`，共 12 组；延后组是 `(block 3, group 1)`。
- 当前版：11 组到齐后空窗 30 拍（cycle 22 到 52），`ft_pass` 保持 0；
  `(block 3, group 1)` 的 p0/p1 都到齐后，cycle 59 完成一次。
  Bazel 退出码 0。
- 旧版 `ccff1391`：cycle 22 报 `premature ft_pass`，当时
  `(block 3, group 1)` 仍未到，测试失败。

证据在 `/tmp/ft_4block_logs/`。


---

## 9. M5：指令重叠、回滚、重试耗尽与第一阶段验收（2026-11-28）

> 本节记录 `31f5f487` 候选。其中重试上限、trap 合并、§9.8 和该提交的日志目录已被 §10 订正：重试 3 次后成功（§9.4）不符合 04，trap 改为第 3 次失败；`31f5f487` 目录里同 tile tm=2 切片和 fp 重放 `test.log` 来自负对照运行（§10.6）。

**代码提交**（内层仓库 `fault-tolerance-v3`）：

| 提交 | 内容 |
|---|---|
| `b08f95ec` | RTL：去掉单在飞门控，按槽校验、按序提交、回滚和 trap |
| `b8018b3d` | 测试：重叠/注错定向程序和 bench、按指令归属的检查器、真实 RS 的模块级夹具 |
| `31f5f487` | 测试：RVV FT + VME FT 同开的编译组合（候选提交，回归在此提交上跑） |

**原始日志**：`/home/lizeyu/eng/npu_ft/test-data/vme-ft-stage1-31f5f487/`（不入库，下文路径都相对此目录）。每个注错目标目录下有 `test.log`（整次仿真 stdout）和 `<case>.log`（该用例的 `[VME_FT_*]` 事件切片，即检查器的输入）。时间戳单位 ps，整核时钟 1250 ps/拍，`cyc=` 是 zvt_ft 内的拍号。

### 9.1 实现

**zvt_ft.sv（重写）**

- **按槽的指令记录**：g0p0 被 block 0 接受时（`ftIssG0`），按阵列给的 2 bit 槽号记下各 block 期望组数、rob_tag、pc、tile 和尝试号。槽号按 RS 顺序分配，回滚时阵列的槽计数重装为队头槽号，所以重发的指令槽号不变。
- **只有队头写 MT**：比较结果属于队头槽才提交（一致、有效、done=0 的元素，打一拍从 dupBuf 写入）。队头所有期望组都比较一致的那一拍 `ft_pass`。
- **换头当拍**：后一条第一次比较（block 0、g0）最早与队头最后一次比较同拍。这一拍若队头通过，后一条的比较按新队头提交，done 掩码清零后同拍装入新队头的位。若队头在这一拍失败，后一条的比较随之作废。其余既不属于队头也不属于换头的比较（按构造不会出现）按失配处理。
- **done 掩码**：4 block × 4 组 × 4 口 × 4 元素 = 256 bit，只属于队头，回滚保留，换头清零。失配判定只看 有效 ∧ ¬done ∧ ¬一致。
- **回滚/trap 状态机**（从 zvt.sv 移入）：队头失败即停发 → 排空（下限 4 拍，且阵列含 skew 级空闲、提交级空）→ 一拍 `rollback`：RS 偏移清零，阵列组计数、pass、槽计数回到队头。同一队头的重试计数达到 `VME_FT_RETRY_MAX` 后再失败：发一拍 trap（带队头 rob_tag），停发直到 flush。dupBuf 中只有 p0 没有 p1 的残留由 rollback 清掉。
- **fflags**：乘法级标志按组（该组有元素提交才计），加法级标志按元素（该元素提交才计），随队头累计，通过时交给退休侧。重放中 done 元素重新累加得到的标志不进入 fflags。

**zvt_pe_array.sv / zvt_pe_block.sv**

- 发射记录（槽、各 block 期望组数、tag、pc、tile）随 g0p0 交给 zvt_ft；`ftStop` 时不发射；`peCmdRdy`（RS 视图前移）只在 block 0 真正接受最后一个 p1 时有效。
- 同 tile RAW：记录最近 `VME_FT_RAW_GAP`-1 拍的 g0p0 累加器组（`dst_index[4:3]`），命中则 g0p0 不发。`VME_FT_RAW_GAP` 默认 6（WCHK_ON 时 7），新头文件宏。
- flush 清空 skew 级有效位、组计数、pass、槽计数。
- block 导出本组乘法级 OF/NV 和逐元素加法级 OF/NV（按写口排布）。

**zvt.sv / zvt_ctrl.sv（从上游重新应用）**

- 退休：PE 指令只在首次发射时进 rtCmd（`ftRtPushEn`：在飞数等于已入队未校验数时才是首次），只在校验通过时推 mtInfo（block 0/1/2/3 按原链的 0/1/1/2 拍延迟）。`vmeRt` 在 rtCmd 队头和四份 mtInfo 都在时握手，两者一起弹出；不再有一拍脉冲去对齐记录，退休背压只推迟。PE 指令的 `vmeRt` 在 `ft_pass` 后第 4 拍。
- misc 指令等 `ftBusy`（有未校验或未入队的 PE 指令、提交级非空、状态机非空闲）清零才执行；读写口随之归 PE。
- flush 时清 vtzero 计数器。

**rvv_backend.sv / RvvCore.sv**

- RS 接线：`iss` = PE 指令发射完成，`rel` = `ft_pass`，`rollback` 来自 zvt_ft。
- VME trap 合并进 `trap_valid_o`：RVV FT 同拍优先，每次 flush 只报一次。哨兵 opcode=STORE、bits 全 1（mtval=0xFFFFFFA7，RVV FT 是 0xFFFFFF87）。

**注错与观测**（`VME_FT_INJECT_ON` / `!SYNTHESIS`）

- 注入点：p0、p1、dupbuf（数据/字节使能/subtile/tile 地址位）、bskew（block 1～3 的 B skew 寄存器）、done（队头某元素的 done 位）、rs（RS 负载在发射前）、rs_mid（g0p0 之后改写 RS 表项，重放源被打坏）。
- 定向模式 `+VME_FT_INJ_INSN=<k> +VME_FT_INJ_GRP=<g> +VME_FT_INJ_ATT=<m>`：第 k 条 PE 指令前 m 次尝试各注一次。
- `+VME_FT_TRACE=<file>` 把 ISSUE/COMMIT/PASS/DRAIN/ROLLBACK/TRAP/FLUSH/RT_PUSH/RT_HANDSHAKE/L1_TRAP/inject 事件写入文件。COMMIT 行是**实际写入 zvt_mt 的那一拍**，带该元素所属指令的 tag 和尝试号。

### 9.2 检查器（`tests/cocotb/vme_test/check_commit_uniqueness.py`）

bench 在每次运行前写入每条 PE 指令的 `[VME_FT_SPEC] tile tm tn`。检查器按日志行自带的 tag/尝试号归属提交，不再归给"最近发射的指令"；每条指令应写的元素集合由 tile/tm/tn 按 tile 布局**独立算出**（不读 RTL 的地址逻辑）。判为违规：

- 提交不在本指令的元素集合内（错址、串到另一条指令）；
- 同一元素在本指令内提交两次（跨尝试也算）；
- 来自已作废尝试的提交；
- 更老的指令还没通过校验时写 MT；
- 通过校验但缺元素；
- 通过、退休不按序，或退休不止一次。

`check_commit_uniqueness_test` 用本轮真实日志做合法输入，并逐项做单点变异，10 个用例全部按预期判定（`check_commit_uniqueness_test/test.log`）。其中用户点名的两种：5×7 日志里把一个 `sub=0` 改成 `sub=12`、提交总数不变（70），报 "outside its footprint" 和 "never committed"；把 insn1 的一条提交改记到 insn0，报 "outside its footprint"。

### 9.3 无注错：正常重叠

**不同 tile 真重叠**（`vme_ft_overlap/overlap_diff_tile.log`，16×16，tk=4，n=4）

```text
[VME_FT_ISSUE] 1090000 cyc=408 tag=4 slot=0 att=0 pc=0x3e4 tile=0 exp=4,4,4,4   insn0 g0p0
[VME_FT_ISSUE] 1100000 cyc=416 tag=5 slot=1 att=0 pc=0x3e8 tile=4 exp=4,4,4,4   insn1 g0p0（阵列接受）
[VME_FT_PASS]  1110000 cyc=424 tag=4 slot=0 att=0 handover_blocks=0001         insn0 通过；同拍换头
                       cyc=425  insn1 第一次写 MT
[VME_RT_HANDSHAKE] 1115000 cyc=428 rob_tag=4 isPe=1 RETIRED
[VME_FT_PASS]  1120000 cyc=432 tag=5 slot=1 att=0
[VME_RT_HANDSHAKE] 1125000 cyc=436 rob_tag=5 isPe=1 RETIRED
```

- insn1 的 g0p0 比 insn0 的 `ft_pass` 早 8 拍；insn1 的第一个 tile 写在 insn0 通过之后一拍；检查器确认 insn1 的 256 次提交都在 insn0 通过之后。
- 两条各退休一次，按序；两块 tile 与 numpy 参考一致。
- 吞吐：n=4 时两条 g0p0 相隔 8 拍、两次通过相隔 8 拍，即时间冗余的下限（04 §4.1 ⑦）。三条在飞（`overlap_triple.log`）：g0p0 526/534/542，通过 542/550/558。

**同 tile RAW**（`vme_ft_overlap/overlap_same_tile_tm*.log`，tn=16）

| tm | 组数 n | insn0 g0p0 | insn1 g0p0 | 间隔 | insn0 通过 | insn1 首次写 MT |
|---|---|---|---|---|---|---|
| 2 | 1 | 301 | 307 | 6 | 310 | 316 |
| 4 | 2 | 301 | 307 | 6 | 312 | 316 |
| 6 | 3 | 301 | 307 | 6 | 314 | 316 |
| 16 | 4 | 301 | 309 | 8 | 317 | 318 |

间隔 = max(6, 2n)，n≤3 时由 RAW 检查扣到 6；数值都正确。

**官方程序对照**（`vme_test_ft_dispatch_interval/`，`vme_mset_vtmmu_sequence_test`，两条 vtmmu 写 mt0，tm=4）：

| 版本 | 第一条 g0p0 | 第二条 g0p0 | 间隔 | 读回 |
|---|---|---|---|---|
| `84028c04`（单在飞，`baseline_84028c04.test.log`） | 246250 | 261250 | 12 拍 | 16×18 |
| `31f5f487`（`test.log`） | 246250 | 253750 | 6 拍 | 16×18 |

**形状**（`vme_ft_overlap/shape_*.log`，不同 tile 和同 tile 各 17 种）：(tm,tn,tk) = (1,1,1) (2,16,4) (3,5,2) (4,8,3) (5,7,3) (6,16,1) (7,9,4) (8,8,2) (9,16,4) (10,3,2) (11,11,3) (12,10,4) (13,15,1) (14,8,4) (15,9,2) (16,16,4) (16,1,3)，覆盖组数 1～4、tm=9～14 各 block 组数不同、tm≤8 或 tn≤8 的空闲 block、行列不满。全部数值正确、无失配；不同 tile 时 insn1 的 g0p0 在 insn0 的 g0p0 后 2n 拍（无 RAW 等待），都早于 insn0 通过。

**浮点**（`vme_ft_overlap/overlap_fp_*.log`）：insn1 的一个元素上溢，fflags=0x4（OF）、无 NV；无异常的一对 fflags=0。

### 9.4 注错

**老错年轻在飞**（`vme_ft_inj_old_young/inj_old_young.log`；注在 insn0 最后一组 block 3 g3 的 p1）

```text
cyc=408 ISSUE tag=4 att=0            insn0
cyc=416 ISSUE tag=5 att=0            insn1 已发射
cyc=424 inject site=p1 blk=3 grp=3 tag=4 att=0
cyc=424 DRAIN head_tag=4 retry=0 cause=mismatch
cyc=434 ROLLBACK head_tag=4 retry=0 squashed_slots=0010     insn1（槽 1）作废
cyc=435 ISSUE tag=4 att=1            按序重发
cyc=443 ISSUE tag=5 att=1
cyc=451 PASS tag=4 att=1   cyc=455 RETIRED rob_tag=4
cyc=459 PASS tag=5 att=1   cyc=463 RETIRED rob_tag=5
```

insn0 尝试 0 提交 255 个元素、重发只补那 1 个（256 个各一次，无重复写）；insn1 的提交全部来自尝试 1；两块 tile 正确。

**换头当拍年轻出错**（`vme_ft_inj_young/inj_young.log`）：cyc=424 insn0 通过的同一拍 insn1 第一次比较被注错，insn1 成为失败的新队头；insn0 照常在 428 退休；insn1 在 434 回滚（无更年轻的可作废）、435 重发、451 通过、455 退休。

**允许范围内重试成功**（`vme_ft_inj_retry_ok/inj_retry_ok.log`；insn0 前 3 次尝试各注一次）：DRAIN/ROLLBACK 在 416/427、436/447、456/467，retry=0/1/2，每次 insn1 都随之作废重发；第 4 次尝试（att=3）在 484 通过、488 退休，insn1 在 492 通过、496 退休，数值正确，无 trap。

**重试耗尽 trap**（`vme_ft_inj_trap/inj_trap.log`；insn0 前 4 次尝试都注）

```text
cyc=416/436/456 DRAIN + 427/447/467 ROLLBACK retry=0/1/2
cyc=476 inject att=3 -> DRAIN head_tag=4 retry=3
[VME_FT_L1_TRAP] 1188750 trap_valid_o=1 rob_tag=4 opcode=1 bits=0x1ffffff source=vme_ft
[VME_FT_TRAP]    1188750 cyc=487 tag=4 retry=3
[VME_FT_FLUSH]   1191250 cyc=489 state=3 active_slots=0011   标量侧取 trap 后冲刷
```

L1 的 `trap_valid_o` 带出 insn0 的 rob_tag=4，哨兵 STORE/全 1；insn0、insn1 都未通过、未退休。RVV FT 同开的构建上同一用例结果相同（`vme_ft_inj_trap_rvvft/`）。

**其他注入点**

| 注入 | 目标 | 结果 |
|---|---|---|
| B skew（block 1，第 3 个命令） | `vme_ft_inj_bskew` | 检测（block 1 g1 失配）、回滚、结果正确 |
| dupBuf 数据位 | `vme_ft_inj_dupbuf` | 检测、回滚、结果正确 |
| dupBuf subtile 地址位 | `vme_ft_inj_dupbuf_addr` | 检测、回滚、结果正确 |
| fp：C 接近上限，重放中 done 元素再累加会上溢 | `vme_ft_inj_fp_replay` | 1 次回滚，结果 3.0e38，fflags=0（与无注错一致） |
| 对照：done 位提前置 1 | `vme_ft_inj_done` | 未检测；该元素未写、保留旧值（SDC），只有检查器报 "never committed" |
| 对照：RS 负载发射前翻位 | `vme_ft_inj_rs` | 未检测；tile 0 第 0 行错（SDC），tile 1 正确 |
| 对照：g0p0 后改写 RS 表项 | `vme_ft_inj_rs_mid` | 检测一次、回滚，重放读到坏表项，第 0 行错（SDC）——第二阶段 RS 奇偶要补的洞 |

**模块级**（真实 `zvt_ft_rs` + `zvt`）

- 排空中外部 flush（`zvt_ft_unit_flush/`）：A 最后一组失配、B 在飞，DRAIN 中 flush；之后状态机空闲，RS、rtCmd、mtInfo 全空，60 拍内无 tile 写、无退休；新指令 C 提交 256 个元素各一次、退休一次。
- 退休背压（`zvt_ft_unit_backpressure/`）：`vmeRtRdy` 一直为 0，A 通过、B 失配回滚后通过，rtCmd 和 mtInfo 各恰 2 项、0 次退休；释放后 A、B 依次各退休一次，B 是最后一条、后面没有指令也能独立退休。
- 四 block 缺组（`zvt_precise_completion_test/`）：[4,4,2,2] 11 组到齐后空窗 30 拍不完成，(3,1) 只有 p0 时不完成，p1 比较当拍完成一次；tm=11 tn=11 单块用例同样通过。

### 9.5 负对照与回归

**RTL 变异**（`neg/`，每项改一处、跑对应目标、恢复）：

| 变异 | 目标 | 结果 |
|---|---|---|
| 加法级标志不按提交过滤 | `vme_ft_inj_fp_replay` | 失败：spurious fflags 0x4 |
| `VME_FT_RAW_GAP` 6→4 | `vme_ft_overlap` | 失败：同 tile tm=2 有 32 个元素错 |
| 提交不看 done 掩码 | `vme_ft_inj_old_young` | 失败：检查器报 "committed twice" |

**RS 单元测试**（`rs_unit/`，VCS，带参考模型）：DEPTH=8/12/16 × seed 1～5 全部 PASS；DEPTH=12 seed 1 的统计与 M1 完全相同（push 187640、iss 47478、rel 40658、rollback 4293、clear 1014、max_off=12）。

**候选提交 `31f5f487` 回归**（`--nocache_test_results`，`final_regression_31f5f487.txt`）：24/24 通过。

| 编译组合（04 §4.3） | 目标 | 结果 |
|---|---|---|
| 1 不定义 VME_FT_ON | `vme_test_verilator`、`vme_rvvi_retire_test_verilator` | PASS（21 用例） |
| 2 VME_FT_ON | `vme_test_ft_verilator`、`vme_ft_overlap_verilator`、`vme_test_ft_dispatch_interval_verilator` | PASS |
| 3 + INJECT | `vme_test_ft_inject_verilator`（不注错）、11 个 `vme_ft_inj_*`、`zvt_ft_unit_*`、`zvt_precise_completion_test` | PASS |
| 4 RS_DEPTH=8 | `vme_test_ft_d8_verilator` | PASS |
| 6 + RVV_FT_ON | `vme_test_ft_rvvft_verilator`、`vme_ft_inj_trap_rvvft_verilator` | PASS |
| — | `check_commit_uniqueness_test` | PASS |

M2 时预期失败的 `vme_test_ft_inj_p0/p1`（manual）现在各检测 1 次、回滚 1 次后通过；`vme_test_ft_inj_mset_seq`：1 次回滚，commit_bytes=128，读回 16×18。

### 9.6 已知限制与遗留

1. **丢副本无看门狗**：若故障使某组的 p1 整个消失（写使能全 0），队头一直等，不会 trap。04 §6.4 已把看门狗列为 05 不做。
2. **orphan / protocol 两条兜底路径**按构造不可达，注错没有打到；它们只把异常转成回滚。
3. **`ft_pass` 是组合路径**：比较 → 完整性 → 换头/提交使能/RS 释放，时序留给 06（04 §6.5 风险 1）。
4. **RETRY_MAX=0、VCS 整核仿真没有单独跑**。
5. **RVVI**：PE 指令退休记录里的 `status` 在 VME_FT_ON 下为 0（fflags 走 fcsr 通路是对的），只影响 VmeCoreMiniVerificationAxi 上的 cosim，属 04 已延后的 RVVI 对齐。
6. **lint**：本机没有 yapf3/buildifier，`utils/run_linters.sh` 的 Python/BUILD 格式检查没跑；`hdl/verilog/rvv/` 不在 verible 范围内。
7. 内层工作区里 `tests/cocotb/coralnpu_dv/BUILD` 的改动和若干未跟踪文件是更早会话留下的，本轮没有动也没有提交。

### 9.7 复现

```bash
cd /home/lizeyu/eng/npu_ft/coralnpu   # 31f5f487
bazel test //tests/cocotb/vme_test:vme_ft_stage1          # 重叠 + 11 个注错目标
bazel test //tests/cocotb/vme_test:zvt_ft_unit_flush //tests/cocotb/vme_test:zvt_ft_unit_backpressure \
           //tests/cocotb/vme_test:zvt_precise_completion_test //tests/cocotb/vme_test:check_commit_uniqueness_test
bazel test //tests/cocotb/vme_test:vme_test_verilator //tests/cocotb/vme_test:vme_test_ft_verilator \
           //tests/cocotb/vme_test:vme_test_ft_d8_verilator //tests/cocotb/vme_test:vme_test_ft_inject_verilator \
           //tests/cocotb/vme_test:vme_test_ft_rvvft_verilator //tests/cocotb/vme_test:vme_ft_inj_trap_rvvft_verilator
# 单个用例的事件切片
ls bazel-testlogs/tests/cocotb/vme_test/vme_ft_inj_trap_verilator/test.outputs/
python3 tests/cocotb/vme_test/check_commit_uniqueness.py <slice.log> --require-retire
```

### 9.8 §6.3 验收简表

| §6.3 项 | 测试目标 | 退出 | 证明结论的原始日志 |
|---|---|---|---|
| a) 不定义 VME_FT_ON 与上游一致 | `vme_test_verilator`、`vme_rvvi_retire_test_verilator` | PASS | `vme_test/`、`vme_rvvi_retire_test/` |
| b) vme_test 全过（FT 开） | `vme_test_ft_verilator`、`vme_test_ft_d8_verilator`、`vme_test_ft_inject_verilator` | PASS | `vme_test_ft/`、`vme_test_ft_d8/`、`vme_test_ft_inject/` |
| b) 不同 tile 连发（真重叠） | `vme_ft_overlap_verilator` diff_tile、triple | PASS | `vme_ft_overlap/overlap_diff_tile.log`、`overlap_triple.log` |
| b) 同 tile 连发（RAW ≥6） | `vme_ft_overlap_verilator` same_tile；`vme_test_ft_dispatch_interval_verilator` | PASS | `vme_ft_overlap/overlap_same_tile_tm{2,4,6,16}.log`；`vme_test_ft_dispatch_interval/{test,baseline_84028c04.test}.log` |
| b) n=1～4、tm=9～14、tn≤8、行列不满 | `vme_ft_overlap_verilator` shapes（34 次运行） | PASS | `vme_ft_overlap/shape_*.log` |
| b) 带浮点异常 | `vme_ft_overlap_verilator` fp | PASS | `vme_ft_overlap/overlap_fp_of.log`、`overlap_fp_clean.log` |
| c) p0/p1 翻位：检测、回滚、结果正确 | `vme_ft_inj_old_young`、`vme_ft_inj_young`、`vme_test_ft_inj_p0/p1`、`vme_test_ft_inj_mset_seq` | PASS | `vme_ft_inj_old_young/inj_old_young.log` 等 |
| c) 前一条出错时后一条在飞 | `vme_ft_inj_old_young_verilator` | PASS | `vme_ft_inj_old_young/inj_old_young.log` |
| c) 回滚中再次出错（重试内成功） | `vme_ft_inj_retry_ok_verilator` | PASS | `vme_ft_inj_retry_ok/inj_retry_ok.log` |
| c) 持续注错：重试耗尽、trap、rob_tag | `vme_ft_inj_trap_verilator`、`vme_ft_inj_trap_rvvft_verilator` | PASS | `vme_ft_inj_trap/inj_trap.log`（L1_TRAP rob_tag=4） |
| c) 回滚期间外部 flush | `zvt_ft_unit_flush` | PASS | `zvt_ft_unit_flush/test.log`、`zvt_ft_unit_trace.log` |
| c) B skew、dupBuf 翻位：检测 | `vme_ft_inj_bskew`、`vme_ft_inj_dupbuf`、`vme_ft_inj_dupbuf_addr` | PASS | 对应目录 `inj_*.log` |
| c) 对照：done 掩码翻位预期漏检 | `vme_ft_inj_done_verilator` | PASS（判定 SDC） | `vme_ft_inj_done/inj_done.log` |
| c) 对照：RS 负载翻位、p0/p1 之间改 RS | `vme_ft_inj_rs`、`vme_ft_inj_rs_mid` | PASS（判定 SDC） | `vme_ft_inj_rs/inj_rs.log`、`vme_ft_inj_rs_mid/inj_rs_mid.log` |
| d) 专用 RS 单元测试（参考模型、随机） | `zvt_ft_rs_tb.sv`（VCS，DEPTH 8/12/16 × 5 seed） | PASS | `rs_unit/run_*.log` |
| e) trap 只在 L1 观测 | 同 c) 持续注错 | PASS | `vme_ft_inj_trap/inj_trap.log` |
| 补充：退休背压下保护老记录、最后一条独立退休 | `zvt_ft_unit_backpressure` | PASS | `zvt_ft_unit_backpressure/test.log` |
| 补充：四 block 缺组判定 | `zvt_precise_completion_test` | PASS | `zvt_precise_completion_test/test.log` |
| 补充：提交归属/错址/重复的检查器 | `check_commit_uniqueness_test` | PASS | `check_commit_uniqueness_test/test.log` |
| 补充：fp 重放不报 done 元素标志 | `vme_ft_inj_fp_replay_verilator` | PASS | `vme_ft_inj_fp_replay/inj_fp_replay.log` |
| 负对照：标志不过滤 / RAW=4 / 不看 done | 同上三个目标 | 均 FAIL（预期） | `neg/` |

## 10. 第一阶段签收收尾：L1 trap 次序、flush 后退休记录、重试边界、归档（2026-11-29）

**代码提交**（内层仓库 `fault-tolerance-v3`，在 `31f5f487` 之上）：

| 提交 | 内容 |
|---|---|
| `70170f44` | RTL：重试上限按 04、flush 后退休有效链清零、trap 合并抽成 `rvv_core_ft_trap_arb` |
| `ed5cd672` | 测试：重试边界与 `RETRY_MAX=0`、trap 先后次序、flush 扫描、trap 合并单元测试（**签收提交**） |

**原始日志**：`/home/lizeyu/eng/npu_ft/test-data/vme-ft-stage1-ed5cd672/`（不入库，下文路径相对此目录）。全部来自 `ed5cd672` 上同一次 `bazel test --nocache_test_results`（`run_head.txt`：HEAD 与运行时间；`final_regression_ed5cd672.txt`：bazel 汇总）。每个目标一个目录，分 shard 的目标保留 `shard_k_of_n/`；`test.log` 是整次仿真输出，`test.outputs/<case>.log` 是该用例的 `[VME_FT_*]` 事件切片。负对照单放 `neg/<变异名>/`（`mutation.diff` + 该次运行的日志），修复前的复现单放 `prefix_repro/`，沿用的 RS 随机验证放 `rs_unit_from_31f5f487/`。

### 10.1 L1 trap 次序（`RvvCore.sv`）

**问题**：原合并用一个 `ft_trap_sent`，任何源报过 trap 就屏蔽之后的 VME trap，直到 flush。前端 trap 只可能属于比 VME 里所有指令都年轻的指令，而 RetirementBuffer 按序取 trap：年轻 trap 要等老 VME 指令退休，老 VME 指令耗尽后不退休、只发一拍 trap，被屏蔽后双方都等 flush。

**生产整核可达**：`RvvFrontEnd.sv:1017-1030` 的动态合法性（寄存器对齐等）只在前端检查，标量 `Decode.scala:1108-1130` 只查 vstart、vill、mstatus.MS。`vme_ft_overlap_test.cc` 的 `ov_trap_fe`：`vtmmu mt0` 后接 `divu`，再接 `vwaddu.vx v3, v12, a1`（e8/m1 下宽化目的需偶数），`a1` 依赖除法结果，约 30 拍后到达前端，正好落在 vtmmu 的重试窗口里。

**修复前复现**（`prefix_repro/trap_fe_att4_old.test.log`，旧 RTL，注 4 次以便在旧上限下耗尽）：

```text
[VME_FT_DRAIN]   991250 cyc=329 head_tag=11 head_att=1 retry=1 cause=mismatch
[VME_FT_L1_TRAP] 998750 trap_valid_o=1 rob_tag=13 opcode=2 bits=0x1858bc3 source=frontend   年轻 vwaddu
[VME_FT_TRAP]   1051250 cyc=377 tag=11 retry=3                                              老 vtmmu 耗尽
（此后无 VME 的 L1_TRAP、无 VME_FT_FLUSH，仿真跑满 20000 拍超时）
```

**修复**：`rvv_core_ft_trap_arb`（`RvvCore.sv` 末尾）。VME 脉冲只被同拍的 RVV FT trap 推迟（挂起，下一拍没有 RVV FT trap 时发出，tag 锁存）；已发出的其他 trap 不再屏蔽它；VME trap 每次 flush 至多一次，flush 当拍的脉冲丢弃（属于被冲刷的工作）。同拍优先级 RVV FT > VME FT > 前端不变（04 §5.4）。仅 `RVV_FT_ON` 时 VME 输入恒 0，输出与原来 `ft | fe` 相同。

**修复后**（`vme_ft_inj_trap_fe/test.outputs/inj_trap_fe.log`；RVV FT 同开的 `vme_ft_inj_trap_fe_rvvft/` 逐行相同）：

```text
[VME_FT_ISSUE]    957500 cyc=302 tag=11 att=0
[VME_FT_DRAIN]    967500 cyc=310 head_tag=11 retry=0 cause=mismatch
[VME_FT_ROLLBACK] 980000 cyc=320 head_tag=11 retry=0
[VME_FT_DRAIN]    991250 cyc=329 head_tag=11 retry=1 cause=mismatch
[VME_FT_L1_TRAP]  998750 trap_valid_o=1 rob_tag=13 opcode=2 bits=0x1858bc3 source=frontend
[VME_FT_ROLLBACK] 1003750 cyc=339 head_tag=11 retry=1
[VME_FT_ISSUE]    1005000 cyc=340 tag=11 att=2
[VME_FT_DRAIN]    1015000 cyc=348 head_tag=11 retry=2 cause=mismatch
[VME_FT_L1_TRAP]  1027500 trap_valid_o=1 rob_tag=11 opcode=1 bits=0x1ffffff source=vme_ft
[VME_FT_TRAP]     1027500 cyc=358 tag=11 retry=2
[VME_FT_FLUSH]    1030000 cyc=360 state=3 active_slots=0001
```

年轻指令 rob_tag=13 的前端 trap 先到 L1，老指令 rob_tag=11 耗尽当拍以自己的 tag 报到 L1 一次，2 拍后 flush；L1 共 2 条 trap、无重复。

**单元测试**（`rvv_core_ft_trap_arb_test/test.log`）：逐拍检查与实现无关的三条性质（同拍优先级；未被 flush 的 VME 脉冲在首个无 RVV FT trap 的拍上以自己的 tag 和哨兵报出；两次 flush 间至多一次、flush 当拍不报）。定向 9 种次序（前端先 20 拍后 VME、RVV FT 与 VME 同拍、RVV FT 连续 3 拍压住 VME、VME 与前端同拍、VME 两次、flush 当拍脉冲、挂起中遇 flush 等）全过；随机 81813 拍、3181 个 VME 脉冲、6512 个 RVV FT、5740 个前端 trap，全过。

### 10.2 flush 后退休记录（`zvt.sv`、`zvt_ft.sv`）

**问题**：PE 的退休记录在 `ft_pass` 后经 `blkRtVld[0]`→`[1]/[2]`→`[3]` 分 3 拍推入四个 mtInfo FIFO。FIFO 只在 flush 当拍清，链上的有效位不清，所以 flush 打在 pass 后 0～2 拍时，残余记录在 flush 后入队，与下一条指令的 rtCmd 配对。

**修复**（只在 `VME_FT_ON` 下）：`blkRtVld`、`miscRtVldD1` 改为随 flush 清零的寄存器；`ft_pass_o` 在 flush 当拍屏蔽（不释放 RS、不启动记录）；flush 当拍不握手。非 FT 构建不变。

**测试**（`zvt_ft_unit_backpressure/`，真实 `zvt_ft_rs` + `zvt`）：`zvt_ft_unit_flush_retire_sweep_test` 中 A（tag 3）、B（tag 5）在飞，单拍 flush 打在 A 的 `pass_now` 同拍（k=0）和其后 k=1～4 拍（`vmeRtRdy=1`）、k=0～4、6 拍（`vmeRtRdy=0` 背压），共 11 个点。夹具每拍快照 `rtCmdRs` 和四个 `mtInfoRs` 的**真实 `entry_count`**、入队、`blkRtVld` 和退休握手。要求 flush 后到 C 入队前没有任何入队且全部占用为 0，A、B 都不退休；随后 C（tag 9）在自己的 `ft_pass` 前退休 0 次、之后恰好 1 次，256 个元素各提交一次。同一仿真先跑原有的 `zvt_ft_unit_backpressure_test`（A 过、B 失配内部回滚，`vmeRtRdy` 一直为 0），实测真实占用 `rtCmd=2 mtInfo[0..3]=[2,2,2,2]`，0 次退休，释放后 A、B 依次各退休一次：内部回滚仍保住老记录。

修复前（`prefix_repro/unit_sweep_old.test.log`，k=0）：

```text
cyc=25 blkRtVld=0001 mtInfo_push=0001 ...   flush 之后 A 的记录仍在入队
cyc=56 mtInfo_cnt=1,1,1,1 rtCmd_cnt=1 rt_hs=1 rt_tag=9   C 在自己 pass（cyc=64）之前退休
```

k=1、k=2 各残留 3 份、1 份记录（`mtInfo_cnt=0,1,1,1`、`0,0,0,1`），四个 FIFO 错位。

修复后（`zvt_ft_unit_backpressure/test.log`，k=1、背压）：

```text
cyc=24 flush=0 pass_now=1 ft_pass=1 blkRtVld=0000 mtInfo_cnt=0,0,0,0 rtCmd_cnt=2
cyc=25 flush=1 pass_now=0 ft_pass=0 blkRtVld=0001 mtInfo_push=0001 mtInfo_cnt=0,0,0,0 rtCmd_cnt=2
cyc=26 flush=0 blkRtVld=0000 mtInfo_push=0000 mtInfo_cnt=0,0,0,0 rtCmd_cnt=0 rt_hs=0
C: rtCmd push cyc=56 pass cyc=65 retire cyc=[69] tags=[9]
```

（cyc=25 的入队与 flush 同拍，被 FIFO 的 clear 吃掉。）11 个点全部 OK。负对照 `neg/retire_chain_no_flush_clear/` 只去掉链的清零：k=1、k=2 失败，k=0 仍过（由 `ft_pass` 屏蔽覆盖），两处改动各有用例能区分。

`zvt_ft_unit_flush/`（DRAIN 中 flush）在新夹具下改读真实占用，结论不变：cyc=29 flush，状态、RS、rtCmd、mtInfo 全空，C 提交 256 个元素、退休一次。

### 10.3 重试边界（`zvt_ft.sv`）

**问题**：04 §4.1 第 4 条、§5.2 要求同一条连续失败 `VME_FT_RETRY_MAX` 次（默认 3）后报 trap。`31f5f487` 在第 4 次失败才 trap，§9.4 的 retry_ok（3 次失败、第 4 次通过）和 trap（4 次失败）都按这个错的边界写成了通过条件。

**修复**：`retry_left = retry_cnt + 1 < RETRY_MAX`，第 RETRY_MAX 次失败报 trap，最多发射 RETRY_MAX 次；`RETRY_MAX=0` 与 1 相同，首次失败即 trap。`[VME_FT_CFG]` 行记下编译期的 RETRY_MAX，bench 从这里读，不再写死。注错改为 retry_ok `ATT=2`、trap `ATT=3`、max0 `ATT=1`。

**MAX=3，前两次失败、第三次成功**（`vme_ft_inj_retry_ok/test.outputs/inj_retry_ok.log`）：

```text
ISSUE cyc=408 tag=4 att=0 / cyc=416 tag=5 att=0
MISMATCH cyc=416 tag=4 att=0 blk=0 grp=0 ... db=0x6823afe7 pe=0x6823afe6
DRAIN cyc=416 head_tag=4 retry=0      ROLLBACK cyc=427 retry=0 squashed_slots=0010
ISSUE cyc=428 tag=4 att=1 / cyc=436 tag=5 att=1
MISMATCH cyc=436 tag=4 att=1          DRAIN cyc=436 retry=1    ROLLBACK cyc=447 retry=1
ISSUE cyc=448 tag=4 att=2 / cyc=456 tag=5 att=2
PASS cyc=464 tag=4 att=2   RT_HANDSHAKE cyc=468 rob_tag=4 RETIRED
PASS cyc=472 tag=5 att=2   RT_HANDSHAKE cyc=476 rob_tag=5 RETIRED
```

无 TRAP、无 L1_TRAP，两块 tile 与 numpy 参考一致。

**MAX=3，三次都失败**（`vme_ft_inj_trap/test.outputs/inj_trap.log`）：

```text
ISSUE att=0 (408/416)  MISMATCH+DRAIN cyc=416 retry=0  ROLLBACK cyc=427 retry=0
ISSUE att=1 (428/436)  MISMATCH+DRAIN cyc=436 retry=1  ROLLBACK cyc=447 retry=1
ISSUE att=2 (448/456)  MISMATCH+DRAIN cyc=456 retry=2
[VME_FT_L1_TRAP] 1163750 trap_valid_o=1 rob_tag=4 opcode=1 bits=0x1ffffff source=vme_ft
[VME_FT_TRAP]    1163750 cyc=467 tag=4 retry=2
[VME_FT_FLUSH]   1166250 cyc=469 state=3 active_slots=0011
```

发射记录只有 att 0、1、2，没有第 4 次尝试；3 次 DRAIN、2 次 ROLLBACK、1 次 L1 trap（rob_tag=4）。RVV FT 同开（`vme_ft_inj_trap_rvvft/`）逐行相同。

**MAX=0，单独编译**（`vme_core_mini_axi_ft_max0_model`，`vme_ft_inj_trap_max0/test.outputs/inj_trap.log`，`[VME_FT_CFG] 0 retry_max=0`）：

```text
ISSUE cyc=408 tag=4 att=0 / cyc=416 tag=5 att=0
MISMATCH+DRAIN cyc=416 head_tag=4 retry=0
[VME_FT_L1_TRAP] 1113750 trap_valid_o=1 rob_tag=4 opcode=1 bits=0x1ffffff source=vme_ft
[VME_FT_TRAP]    1113750 cyc=427 tag=4 retry=0
[VME_FT_FLUSH]   1116250 cyc=429 state=3 active_slots=0011
```

0 次 ROLLBACK、0 次重发。cyc=416 insn1 的 g0p0 与 insn0 失配同拍被接受（停发从下一拍起），测试判据是"最后一次发射不晚于最后一次 DRAIN"。

### 10.4 与 04 的差异：失配即开始恢复

04 §4.1 第 4 条写"只在最老那条的校验点触发，不在第一次失配时触发"。实现是**队头（或换头当拍的新队头）任一组比较失配即停发、进入排空**，不等它的最后一组。

- **对提交**：队头之外的指令不写 MT（只有队头提交，§9.1），所以提前恢复不会让年轻指令的结果落地；队头本次已一致的元素照常提交并置 done，失配之后的组不再比较，重发时补齐。
- **对恢复**：重发从队头开始，done 掩码挡住已提交的元素，年轻指令整体作废重做，和等到校验点再恢复的结果相同，只是少等几拍（失配在第 0 组时，按 n=4 的发射节奏估计每次约早 8 拍；未实测"等校验点"的版本）。
- **对 trap**：重试计数按"一次失败一次计数"，与触发时刻无关。
- **验证**：老错年轻在飞（失配在最后一组，等价于校验点）与失配在第 0 组（retry_ok、trap、max0）都覆盖；`vme_ft_inj_old_young` 中 insn0 两次尝试分别提交 255 个和 1 个元素、无重复，insn1 的 256 个全部来自尝试 1；负对照 `neg/no_done_mask/` 去掉 done 掩码后检查器报 "committed twice"。

采用实现的行为，04 原文不改，以本节为准。

### 10.5 其余 §6.3 项复核（同一提交、同一次运行）

| 事实 | 原始日志 | 实测 |
|---|---|---|
| 不同 tile 真重叠 | `vme_ft_overlap/shard_1_of_5/test.outputs/overlap_diff_tile.log` | insn0 g0p0 cyc=408，insn1 g0p0 cyc=416，insn0 PASS cyc=424，insn1 首次写 cyc=425、PASS cyc=432 |
| 同 tile RAW | `vme_ft_overlap/shard_2_of_5/test.outputs/overlap_same_tile_tm{2,4,6,16}.log` | g0p0 301→307 / 301→307 / 301→307 / 301→309，间隔 6/6/6/8 |
| 三条在飞 | `vme_ft_overlap/shard_3_of_5/test.outputs/overlap_triple.log` | PASS |
| 17 种形状 × 不同/同 tile | `vme_ft_overlap/shard_4_of_5/test.outputs/shape_*.log`（34 个） | 数值正确、无失配 |
| 浮点 fflags | `vme_ft_overlap/shard_5_of_5/test.log` | `overlap_fp_of` fflags=0x4，`overlap_fp_clean` fflags=0x0 |
| 浮点重放 | `vme_ft_inj_fp_replay/test.log` | 1 次回滚，值 3.0e38，fflags=0x0（判据已改为 `== 0`） |
| 老错年轻在飞 | `vme_ft_inj_old_young/test.log` | insn0 尝试 0/1 提交 255/1 个，insn1 全部来自尝试 1，最终两块 tile 正确，按序各退休一次 |

其余注错（young、bskew、dupbuf、dupbuf_addr、done/rs/rs_mid 对照）、`zvt_precise_completion_test`、`check_commit_uniqueness_test` 都在同一次运行里通过，结论同 §9.4、§9.5。

**沿用**：专用 RS 单元测试（04 §6.3 d）沿用 `31f5f487` 的 VCS 运行，日志复制在 `rs_unit_from_31f5f487/`（DEPTH 8/12/16 × seed 1～5，15 个 PASS）。`git diff 31f5f487 ed5cd672 -- hdl/verilog/rvv/design/Zvt/zvt_ft_rs.sv` 为空，`zvt_ft_rs_tb.sv` 也未动。

### 10.6 归档订正

`31f5f487` 目录里有两处混入了负对照（文件未删，以本节为准）：

- `vme_ft_overlap/overlap_same_tile_tm2.log` 的两条 ISSUE 是 cyc=301、305（间隔 4），来自 `VME_FT_RAW_GAP=4` 变异的运行；目录里也只有 tm2 的同 tile 切片。§9.3 表格里的 6 拍当时取自 bench 输出，切片被后来的负对照覆盖。
- `vme_ft_inj_fp_replay/test.log` 与 `neg/flags_unmasked.test.log` 逐字节相同（`cmp` 无差异），即正例目录放的是负对照日志。

原因是负对照跑完后再从 `bazel-testlogs` 收集正例。本轮改为：正例回归跑完立即用脚本按目标复制（含各 shard 的 `test.log` 和 `test.outputs/`），再跑负对照，每个负对照把自己的日志收进 `neg/<名>/`；上表各项都是从 `ed5cd672` 目录逐个打开核对的。

### 10.7 负对照（`neg/`，在 `ed5cd672` 上每项改一处 RTL、跑对应目标、`git checkout` 恢复）

| 变异 | 目标 | 结果 |
|---|---|---|
| `retry_bound_old`：恢复 `retry_cnt < RETRY_MAX` | `vme_ft_inj_trap` | 失败：第 4 次尝试通过、两条都退休，无 trap |
| `retire_chain_no_flush_clear`：退休有效链不随 flush 清 | `zvt_ft_unit_backpressure` | 失败：k=1、k=2 的 flush 后残留记录（两种 `vmeRtRdy`） |
| `trap_arb_any_trap_blocks`：任何 trap 都置 `vme_sent` | `vme_ft_inj_trap_fe`、`rvv_core_ft_trap_arb_test` | 失败：整核 "0 VME traps at L1 … flushes 0"；单元 "trap_valid wrong"（前端 trap 之后的 VME 脉冲没报） |
| `flags_unmasked`：加法级标志不按提交过滤 | `vme_ft_inj_fp_replay` | 失败：spurious fflags 0x4 |
| `raw_gap_4`：`VME_FT_RAW_GAP` 6→4 | `vme_ft_overlap` | 失败：同 tile tm=2 有 32 个元素错 |
| `no_done_mask`：提交不看 done 掩码 | `vme_ft_inj_old_young` | 失败：committed twice |

修复前在旧 RTL 上的复现单放在 `prefix_repro/`：`trap_att3_old.test.log`（注 3 次，旧上限下第 4 次通过）、`trap_fe_att4_old.test.log`（§10.1 卡死）、`unit_sweep_old.test.log`（§10.2）。

### 10.8 签收回归与 §6.3 简表

`ed5cd672` 上 33 个目标一次运行，33/33 通过（`final_regression_ed5cd672.txt`）。工作区另有早先会话留下的 `tests/cocotb/coralnpu_dv/BUILD` 改动，不在这些目标的依赖里。

| §6.3 项 | 测试目标 | 实际结果 | 原始日志 |
|---|---|---|---|
| a) 不定义 VME_FT_ON 与上游一致 | `vme_test_verilator`、`vme_rvvi_retire_test_verilator` | PASS | `vme_test/shard_*`、`vme_rvvi_retire_test/` |
| b) vme_test 全过（FT 开） | `vme_test_ft`、`vme_test_ft_d8`（RS=8）、`vme_test_ft_inject`、`vme_test_ft_rvvft` | PASS | 对应目录 `shard_*` |
| b) 不同 tile 连发、三条在飞 | `vme_ft_overlap` diff_tile、triple | PASS：408/416 发射，424 通过 | `vme_ft_overlap/shard_1_of_5/`、`shard_3_of_5/` |
| b) 同 tile 连发 | `vme_ft_overlap` same_tile；`vme_test_ft_dispatch_interval` | PASS：6/6/6/8 拍 | `vme_ft_overlap/shard_2_of_5/test.outputs/`、`vme_test_ft_dispatch_interval/` |
| b) n=1～4、tm=9～14、tn≤8、行列不满 | `vme_ft_overlap` shapes | PASS（34 次） | `vme_ft_overlap/shard_4_of_5/test.outputs/shape_*.log` |
| b) 浮点异常 | `vme_ft_overlap` fp | PASS：0x4 / 0x0 | `vme_ft_overlap/shard_5_of_5/` |
| c) p0/p1 翻位：检测、回滚、正确 | `vme_ft_inj_old_young`、`vme_ft_inj_young`、`vme_test_ft_inj_p0/p1`、`vme_test_ft_inj_mset_seq` | PASS | 对应目录 |
| c) 前一条错时后一条在飞 | `vme_ft_inj_old_young` | PASS：255+1 提交，insn1 全部重做 | `vme_ft_inj_old_young/` |
| c) 回滚中再次出错（重试内成功） | `vme_ft_inj_retry_ok` | PASS：2 次回滚，att 2 通过，按序退休 | `vme_ft_inj_retry_ok/test.outputs/inj_retry_ok.log` |
| c) 持续注错：重试耗尽、trap、rob_tag | `vme_ft_inj_trap`、`vme_ft_inj_trap_rvvft`、`vme_ft_inj_trap_max0` | PASS：第 3 次失败 trap、rob_tag=4、无第 4 次；MAX=0 首次即 trap | 对应目录 `test.outputs/inj_trap.log` |
| c) 回滚期间外部 flush | `zvt_ft_unit_flush` | PASS | `zvt_ft_unit_flush/` |
| c) 外部 flush 与退休记录（本轮） | `zvt_ft_unit_backpressure`（sweep + 内部回滚） | PASS：11 个点 | `zvt_ft_unit_backpressure/test.log` |
| c) B skew、dupBuf 翻位 | `vme_ft_inj_bskew`、`vme_ft_inj_dupbuf`、`vme_ft_inj_dupbuf_addr` | PASS | 对应目录 |
| c) 对照：done、RS 负载、p0/p1 间改 RS | `vme_ft_inj_done`、`vme_ft_inj_rs`、`vme_ft_inj_rs_mid` | PASS（判定 SDC） | 对应目录 |
| d) 专用 RS 单元测试 | `zvt_ft_rs_tb.sv`（VCS） | PASS（沿用，源码未变） | `rs_unit_from_31f5f487/` |
| e) trap 在 L1：trap_valid_o + rob_tag | 同 c) 持续注错；`vme_ft_inj_trap_fe`、`vme_ft_inj_trap_fe_rvvft` | PASS：年轻前端 trap 先到后，老指令仍报一次 | `vme_ft_inj_trap_fe/test.outputs/inj_trap_fe.log` |
| e) trap 合并（同拍优先级、每次 flush 一次） | `rvv_core_ft_trap_arb_test` | PASS：定向 9 种 + 随机 81813 拍 | `rvv_core_ft_trap_arb_test/test.log` |
| 补充：仅 RVV_FT_ON 构建（合并模块改动） | `rvv_arithmetic_ft_cocotb_test`、`rvv_arithmetic_ft_inject_cocotb_test` | PASS | `//tests/cocotb` 下同名目录 |
| 补充：精确完成、检查器、fp 重放 | `zvt_precise_completion_test`、`check_commit_uniqueness_test`、`vme_ft_inj_fp_replay` | PASS | 对应目录 |
| 负对照 | 见 §10.7 | 6 项均 FAIL（预期） | `neg/` |

### 10.9 遗留

1. §9.6 的 1～3、5 不变（无看门狗、orphan/protocol 路径未打到、`ft_pass` 组合路径时序留 06、RVVI `status`）。§9.6 第 4 条的 `RETRY_MAX=0` 已补；VCS 整核仿真仍没跑。
2. `RETRY_MAX=0` 下没有"重试窗口"，所以 `vme_ft_inj_trap_fe` 没有 max0 版本。
3. 非 FT 构建的退休有效链（`miscRtVldD1`、`blkRtVld`）flush 后也会残留一拍，属上游行为，本轮只在 `VME_FT_ON` 下改。
4. lint：本机没有 verible、clang-format-19、yapf3、buildifier、mdl、shellcheck，`utils/run_linters.sh` 没跑。
5. trap 后端到端（LSU 卡死修复）仍按 04 §5.7 延后到 06，第一阶段只在 L1 观测。
