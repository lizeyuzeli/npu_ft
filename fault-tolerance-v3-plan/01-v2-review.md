# 01 · fault-tolerance-v2 回顾与 main 变化汇总

> 依据：`git log 1126ed3f..fault-tolerance-v2`（16 个提交，2026-08-05 ~ 08-24）+ `git log 1126ed3f..main`（347 个提交，2026-07-31 → 2026-11-13）。
> 本文件是事实与技术分析，**不包含 v3 的设计决策**（那些在 02-direction-discussion.md）。

---

## 0. 谱系

```text
zeyu/fault-tolerance (v1, base 7d0ae209, 2026-06)  ──┐ 5 个提交：FI harness + 模型套件 + DMR Stage1+2
        │（中间还有一个旧 FT 分支 d94a1ae1，v2 提交里多次引用）
        ▼
fault-tolerance-v2 (base 1126ed3f = main@2026-07-31, tip 631c3ae1, 2026-08-24)
        │  16 个提交，27 个非模型文件 +6308/-37 行，另有 tflite 模型套件 ~10k 行
        ▼
fault-tolerance-v3 (当前 = main@9d0a8dcf，与 v2 分叉后 main 已前进 347 个提交，842 文件、+110k/-30k 行)
```

v2 本身已经是"一次移植"：把 v1 的 DMR + FI 框架搬到 1126ed3f 上。所以 v3 是第二次移植，但这次 main 的变化量（347 个提交）远大于上一次。

---

## 1. v2 的总体架构

| 子模块（FI 划分） | 内容 | v2 方案 | 实现状态 |
|---|---|---|---|
| `compute_ctrl` | ROB 控制位 `uop_done/trap_flag/entry_valid/trap_ready` | 寄存器级 TMR + scrub | ✅ 已实现并有 FI 对比数据 |
| `execute` | ALU/MUL/MAC/DIV/FALU 流水 + RS + 结果 fifo | 指令级 DMR（时间冗余）+ 比较 + 回滚重试 | ✅ 已实现，**但没有 FI 层面的 FT_ON 对比数据** |
| `storage` | VRF（32×VLEN） | ECC（计划中） | ❌ 未实现 |
| `decode_path` | 前端 cmd/uop 队列 | "TMR?"（未定） | ❌ 未实现 |
| （诊断）`rob_data` / `fifo_ptr` / `lsu` | ROB 数据面 / fifo 指针 / LSU 接口缓冲 | 不保护 | — |

软件可见面：`ftstatus`(0x7c8)、`ftcecnt`(0x7c9)、`ftdmrcnt`(0x7ca)、`ftctl`(0x7cb) 四个 CSR，以及新异常 `mcause=19`（hardware error）。

全部 RTL 改动都放在 `` `ifdef FAULT_TOLERANT_ON `` 里，FT 关闭时预处理后的 token 流与基线逐字节一致（v2 称为 **INV-1**）。

---

## 2. v2 逐项技术分析

### 2.1 DMR 指令复制（c7614634，核心）

**做了什么**

- dispatch 处给白名单 uop 打 `is_ft`：ALU/MUL/MAC/DIV，开 ZVE32F 时再加 FMA(FALU addmul)/FDIV。FCMP/FNCMP/FCVT/FTBL、PMTRDT、LSU、VME 都不在白名单里。
- 两份副本**共用一个 ROB entry**；ROB 写回时比较结果，不一致就回滚重发，重试 `FT_RETRY_MAX=3` 次后走 `trap_flag → trap_flush_rvv` 全局 trap。
- "ROB 是大脑，顶层是手"：顶层的 `replay_mem` 保存 copy-1 的 RS payload，再通过每个端口一个 2:1 MUX，利用 normal dispatch 没占用的 RS push 端口重注入，不改 RS 实例。
- 自测开关：`FT_INJECT_ON`（一次性注错）、`FT_INJECT_PERSIST`（持续注错，必然 trap）。

**证据**：rvv_arithmetic 24 个子测试在 OFF / ON / ON+INJECT 三种构建下都通过；仿真时间 +1.1%（复制开销）和 +3.6%（含一次回滚）。DC 综合时发现并修复了一个异步复位推断的 bug。

**技术观察**

1. **没有空间分集。** 代码和提交说明都没提到"两份副本必须走不同的物理单元"。`NUM_DIV=1`，DIV/FDIV 的两份副本必然在同一个单元上执行；ALU/MUL 虽然各有 2 个实例，但也没有强制分开。这意味着对 `stuck`（永久故障）和共模故障，DMR 基本没有检测能力，**只对瞬态故障有效**。
2. **共模点没有覆盖。** `replay_mem` 保存的是 copy-1 的 payload，两份副本的操作数来自同一次 VRF 读和同一次 forwarding。操作数在进 RS 之前出错，两份副本会一致地错。v2 自己也把 `replay_mem` 称为 "DMR common-mode point"。要堵住这个缺口，需要 VRF ECC 加上 payload/replay_mem 的保护。
3. **面积代价大、而且没有量化过。** `replay_mem` 在 FT_ON 时多出 4768 bit（当时 ROB_DEPTH=8），是 FT 引入的最大单项。main 把 ROB_DEPTH 改成 16 后，它会再翻倍（约 9.5 kbit）。v2 **从没给出综合后的面积、时序或功耗开销**。
4. **性能开销只在 rvv_arithmetic 上测过**（+1.1%）。没有在真实模型上测过 IPC 或周期数开销，而 DMR 占用的是"空闲 RS 端口"，负载越密集，开销应该越大。
5. **侵入性太强。** `rvv_backend_rob.sv` 从 318 行涨到 1410 行（main 现在是 362 行）；ROB 同时承担比较、回滚、重注调度、TMR、计数器和 tag 检查。而 RVV 后端在 main 上是由外部团队以 "Sync backend updates" 的方式成批同步的，每次同步都会和这 1000 多行冲突。
6. **复制粒度是 uop，不是指令。** 对于跨 uop 有状态的单元（reduction、FCMP 等）只能排除。这个排除是对的，但覆盖率因此打了折扣，而且 v2 没有统计"FT 覆盖的动态 uop 比例"。


### 2.2 ROB 控制位 TMR（91de4423）

**做了什么**

- 对 ROB 的 8 个 entry 的控制位（`uop_done`、`trap_flag`、`trap_ready.q`、`entry_valid`、`w_valid`、`last_uop_valid`）做寄存器级 TMR：每个位存 3 份，写时复制 3 份、读时投票，scrub 在检测到单 bit 翻转时写回多数值。
- `entry_valid` 特殊：整个 fifo 例化 3 份（共 3 个 `multi_fifo` 实例），每个实例管自己的 rptr/wptr，valid 信号投票。
- 自测开关：`TMR_INJECT_ON`、`TMR_INJECT_PERSIST`。

**证据**：投票和scrub 逻辑手工实现（没有用参数化原语）；合成后 TMR 区域约 49 个触发器 × 8 个 entry = 392 个触发器（v2 估计）。

**技术观察**

- **目标选择的理由清楚**：控制位出错会导致退休错误或挂死，数据位错误顶多是结果错（会被 DMR 检测）。
- **面积合理**：几百个触发器对整个芯片来说是小头。
- **但 main 的变化让实现过时**：`trap_ready.q` 被改成了 `dff regTrapFlush(is_trapping)`，而 `dff` 不在 v2 的 vlt 暴露规则里；ROB_DEPTH 从 8 涨到 16，位数翻倍。

### 2.3 Tag 合理性检查（631c3ae1）

**做了什么**

- 检查反压向量和 tag 的一致性：如果某个单元不能接受新指令（反压为 1），那么 dispatch 重试的 uop 的 tag 应该与上一次相同。
- 动机：v2 声称"arbiter 的 priority_reg 如果出错会导致 tag 分配不一致，进而静默错"；加一层运行时检查。

**技术观察**

- 代价极小，收益明确（排除一类静默错）。
- main 的 arbiter 已经重写（5652f096），改成两个 N-to-2 round-robin slice，v3 需要按新结构重新分析动机是否仍然成立。

### 2.4 CSR 与 trap 上报链（Chisel，b12e1b87 / ee41e19d / 9eb3649d / fd139cdd）

**做了什么**

- 在 `Decode.scala` 增加 4 个只读 CSR（0x7c8～0x7cb）；`Csr.scala` 和 `RvvCore.scala` 转发 FT 状态和计数器。
- 在 `SCore.scala` 增加 `mcause=19`（hardware error）分支，优先级高于前端非法指令。
- 整个链路：RVV backend 检测到不可恢复错误（重放耗尽 / tag 不一致）→ 拉高 `trapFlag_trap` / `tagFail_trap` → `RvvCore.sv` 按 PC 匹配向量 trap → 标量侧 `ft_trap`，mepc 指向出错指令（or nearby）。

**技术观察**

- **main 的变化让这条路大部分失效**（302a42d3、5e7e7413 等）：
  - trap 匹配改为按 `rob_tag`，不再按 PC。v2 用 mepc 匹配来上报 FT trap 的做法过时了。
  - 写只读 CSR 触发非法指令异常（8c726f4f）。v2 把计数器放在 0x7c9/0x7ca（可读写区间），不符合规范。应该挪到 0xFxx 自定义只读区间。
  - retirement buffer 重构（C3）；`Decode/Csr/SCore/RvvCore` 四个 Chisel 文件共约 +1000/-500 行。
- v3 如果要复用这条链，**必须在 Chisel 侧全部重写**，这违背了"不碰 Chisel"的约束。

### 2.5 注错框架（Python，42281a91 / 07fcfaaa / d4a86c50 / 29d6cb78）

**做了什么**

- 把故障空间按 FI 注册表（fi_hier_tb.json）分组：`compute_ctrl`（ROB 控制位）、`execute`（执行单元流水）、`rob_data`（ROB 数据）、`fifo_ptr`、`lsu`。每组用正则匹配 vlt 暴露的信号，在仿真的固定时刻（下降沿）翻转单 bit。
- 对照组：OFF（无保护）/ ON（有保护）/ ON-TAMPER（保护开、但自测宏拉高，必然触发 trap）。
- 三类结果：MASKED（正确）、DETECTED（trap 或 fault）、SDC（静默错）。
- 工具：`fi_utils.py`（注入、运行、解析）、`fi_campaign.py`（批量）、`fi_audit.py`（对比 OFF/ON）、`fi_seq_audit.py`（审计序列）、`hang_triaging.sh`（hang 归因）。

**证据**：compute_ctrl 子集的 25 个随机样本，OFF 下 9 MASKED / 9 DETECTED / 7 SDC，ON 下 23 MASKED / 2 DETECTED / 0 SDC；execute 没有 FI 对比数据。

**技术观察**

- **v2 最有价值的资产**：方法论清晰（划分、三类对照、审计、hang 归因、条件 AVF），代码可复用。
- main 的变化影响：
  - ROB_DEPTH 翻倍，注册表里写死的位置偏移（25/75 等）全部失效。
  - `dff` 原语和 VME 模块要加进 vlt 暴露规则。
  - 测试构建改用 `coralflow_test`（cocotb_test_suite 已移除），但底层仍然是 `verilator_cocotb_test`，所以 VPI 访问 dut 的方式不变。

### 2.6 负载与软件（c9320b8a / 36281e80 / f65a8d38）

**做了什么**

- 在 `sw/opt/litert-micro/conv.cc`、`fully_connected.*` 加了 FT 自测的条件编译分支（读 ftctl、拉高 inject、读计数器、trap 处理）。
- 迁移了 13 个 tflite 模型（`sine_model` / `person_detect` / `keyword_spotting` 等），每个模型一个独立 BUILD。
- README 里记录了每个模型在 v2 base 上的周期数。

**技术观察**

- main 的 `conv.cc` 和 `fully_connected.*` **在分叉点之后没有被改过**，v2 的 c9320b8a 可以直接 cherry-pick。
- 模型套件的 BUILD 要按 CoralFlow 重写（E2）；base 变了，周期数要重测。

---

## 3. main 在分叉点之后的变化（与容错相关的部分）

> 范围：`git log 1126ed3f..main`，共 347 个提交（2026-07-31 → 2026-11-13）。
> 规模：842 个文件，+109,771 / −30,179 行。
> 只列出**会影响 v3 容错设计、移植或验证**的变化。

### 3.1 RVV 后端：ROB / dispatch / 退休 / trap

| 关键变化 | 提交 | 对 FT 的影响 |
|---|---|---|
| **ROB_DEPTH 从 8 改为 16** | 406ff183 | TMR 位数翻倍；`replay_mem` 翻倍（约 9.5 kbit）；FI 注册表里的常量全部失效 |
| **ROB 加了 `rob_tag`**，retirement buffer 改为按 tag 匹配 | 302a42d3、5e7e7413 | v2 用 mepc 匹配的上报链过时了，**必须改成 `rob_tag`** |
| **RVV flush 来源改变**：`trap_valid_rvs2rvv = flush`（标量侧 flush），ROB 的 `trap_in` 直接 OR 上它 | 302a42d3、7d2f8129 | `trap_flush_rvv` 现在会被**每一次标量侧的 trap/flush** 触发。DMR 在途状态的清理逻辑必须重新验证 |
| `trap_ready` 的 `edff` 换成 **`dff regTrapFlush`（is_trapping）** | 0e7ea4ef、302a42d3 | v2 的 TMR 目标 `trap_ready.q` 不存在了；`dff` 不在 vlt 暴露规则里 |
| **`multi_fifo` 接口变化**：新增 `pushRdy` | 302a42d3、575921c6 | v2 "把 valid fifo 例化 3 份"的写法要按新接口改 |
| **退休接口改为 6 lane**（Rob2Rt bundle） | 7a0305d5、bdbc6780 | FT 上报接口要对齐 |
| **Arbiter 重写**：改成两个 N-to-2 round-robin slice | 5652f096 | v2 的 tag 检查动机要重新分析 |
| dispatch / decode 大改：合法性检查、vl=0 no-op、vill 串行化、fault-only-first 修复 | 60586562、4d82d870、5c599a88、e8641152、2e8d8d71 | `is_ft` 白名单插入位置要重新找；新增 no-op uop 是否需要复制要评估 |
| 执行单元重构：ALU 拆出 addsub/shift datapath，MUL/MAC 有 eew32 datapath，PMTRDT reduction 大改；FALU 默认 4 级流水 | 7032b0b7、afbd7091、a253c4d5 等 | execute 故障空间变了，FI 注册表要重新生成；DMR 延迟和开销要重测 |

**一个结构性观察**：RVV 后端在这期间被 10 位作者修改了约 70 次，其中好几次是外部团队的 **"Sync backend updates" 整体同步**。也就是说，**ROB、dispatch 这些文件会周期性地被整体覆盖**。v2 那种往 ROB 里加 1000 多行的做法，每次同步都会带来大量冲突。

### 3.2 VME / Zvt 矩阵扩展（新的保护对象）

| 关键变化 | 提交 | 对 FT 的影响 |
|---|---|---|
| Zvt 升级到 **v0.4 规范**；`msettm/msettk/msetmtype` 等配置指令 | e43ace04、27d00090、e2e1d8ab | VME 现在是一个完整的、架构可见的执行单元，需要有自己的 FT 方案 |
| **部分 VME uop 现在会进 ROB**：`vtmv.v.t` 占用 ROB entry；`vtzero`、`vtmv.t.v` 只写 tile、不进 ROB | 22731c68、89a0bcbb | v2 说"VME uop 不进 ROB，所以不能做 DMR"，这个前提**部分失效** |
| **矩阵 tile 存储**：`NUM_MT=16`，每个 MT 占 TE×TE 字节（TE=VLEN/8）。VLEN=128 时约 **4 KiB = 32 Kbit**，是 VRF（4 Kbit）的 **8 倍**。FPGA 上映射到 UltraRAM | c8d95975 等 | **整个 NPU 里最大的架构状态**，v2 完全没覆盖。天然适合 ECC |
| PE 阵列：`zvt_pe_array / pe_block / pe_mulbulk / pe_adder`，支持 INT8、INT16→INT32、BF16 | a503b406、5177dbd2、4168a645 | 矩阵乘的 PE 阵列天然适合**基于校验和的 ABFT**（行/列校验和），代价远低于复制 |
| VME 有关的 flush / trap：`vme_lsuflush_vld` 接入 ROB 的 `trap_in` | 79820a84 | FT 的 trap 上报要和 VME 的 flush 共存 |

### 3.3 标量核 / CSR / 退休缓冲

| 关键变化 | 提交 | 对 FT 的影响 |
|---|---|---|
| **写只读 CSR（csr[11:10]==11）触发非法指令异常** | 8c726f4f | v2 把只读计数器放在 0x7c9/0x7ca，不符合规范。应该挪到 0xFxx 自定义只读区间 |
| Retirement buffer：深度改为 16；decode fault 与控制流 trap 解耦；满时不入队非法指令 | e9791623、7de11594、14d37df7、d52d09e0 | v2 在 SCore 里插入 FT trap 上报的那段逻辑要按新结构重写 |
| `Decode.scala` 约 +600/-270 行，`Csr.scala` 约 +250/-90 行，`SCore.scala` 约 +110/-75 行，`RvvCore.scala` 约 +480/-160 行 | 多个 | v2 在这几个文件里的改动（共约 200 行）基本都要手工重新落地 |

### 3.4 存储系统 / 总线

| 关键变化 | 提交 | 说明 |
|---|---|---|
| LsuV2 退役，**LsuV3** 成为唯一实现；LSU 通过 **TileLink-UL 访问 banked TCM** | d57a9342、1fbd7be6、628892e6 | 不在 v2 范围内；如果 v3 要覆盖 TCM 或 LSU，基础完全变了 |
| `TlulIntegrity.scala` 和 `secded_golden.py`（prim_secded_inv_39_32） | 分叉点之前就有 | **仓库里已经有 OpenTitan 风格的 SECDED(39,32) 编解码实现和 Python 金模型**，VRF / tile 的 ECC 可以直接复用 |

### 3.5 构建 / 测试基础设施

| 关键变化 | 提交 | 对 FT 的影响 |
|---|---|---|
| **Bazel 9.1.0 + Bzlmod**，删除 WORKSPACE；`MODULE.bazel.lock` 由 lint 检查 | 8e4df09b、2c5b8b80 | v2 的 BUILD 文件要在新工具链下重新验证 |
| **CoralFlow**：统一的多后端测试宏 `coralflow_test`，**`cocotb_test_suite` 已移除**；fixture 重构 | 99ec0d01、ec0c463e、5eff3822 | v2 的 FI BUILD 和 13 个模型 BUILD **全部要重写**；FI 需要 VPI 访问 dut，只能用 Verilator 后端 |
| `rules/default.vlt.tpl` **在 main 上没有被改过** | — | v2 的 vlt 暴露规则可以直接合入，再补上 `dff` 和 VME 原语 |
| Verilator 构建优化（类输出分组、-O0/-O2 分离、OPT_FAST=-O3） | 70b54232、eb40a16a | FI 活动的仿真速度可能有提升 |
| **UVM DV 测试平台 + Spike/MPACT 三方协同仿真**（默认在 presubmit 中启用） | 9d0a8dcf、728dc9ae、f692ed59 | **FT_ON 必须在架构上不可见**，可以用三方协同仿真把 FT_ON 构建和 ISS 逐条对比 |
| **ISG 指令流生成器**（随机指令流、hazard shaping、架构 trap、覆盖率收敛） | b50b85a9、f9f96044、5b56f7d4 | 可以用来做随机压力测试，覆盖 DMR 回滚和 flush 的各种交叉情况 |
| **OpenROAD + ASAP7 物理流程**（RvvCoreMini），以及 vcs_netlist 测试 | 74af63a4、a253c4d5 | **可以用开源流程量化 FT 的面积和时序开销**（v2 完全缺这部分）；网表仿真也为门级 SET 注入提供了切入点 |
| `utils/fst_query` 波形查询工具；`AGENTS.md` 规定提交前必须跑 `utils/run_linters.sh` | 08eadd1c、9adffe93 | **v3 的提交必须通过 lint**（verible / scalafmt / yapf / buildifier / shellcheck / mdl） |

### 3.6 软件 / 负载

| 关键变化 | 提交 | 说明 |
|---|---|---|
| `sw/opt/litert-micro/conv.cc`、`fully_connected.*` **在 main 上没有被改过** | — | v2 的 c9320b8a 可以直接 cherry-pick |
| 新增 BF16 Gemma kernel、int8→int32 gemv/matmul、bf16 sigmoid/softmax | 8cfb5c62、4b239bfe、77563d17 | 可以作为 FI 的新负载，尤其是走 VME 的 matmul |
| `tests/cocotb/rvv/ml_ops`、`vme_test` 等新的测试集 | 多个 | VME 的 FI 负载候选 |

---

## 4. v2 各部分的迁移难度汇总

| v2 组成部分 | 受影响的 main 变化 | 迁移难度 |
|---|---|---|
| DMR（rob / backend / dispatch / define） | 3.1 的 9 项 + 3.2 的部分 VME uop | **高**，实际上要按新 ROB 重写 |
| ROB TMR | 3.1 ROB_DEPTH 翻倍 + trap_ready 换成 dff + flush 来源变化 | **高**，按新 ROB 重写 |
| Tag 合理性检查 | 3.1 rob_tag 引入 + arbiter 重写 | 中 |
| CSR 与 trap 上报链（Chisel） | 3.1 rob_tag + 3.3 的 4 项 | **高**，Chisel 端几乎全部重写 |
| FI 框架（Python） | 3.1 ROB_DEPTH + dff + 执行单元重构 + 3.2 VME + 3.5 CoralFlow | 中：核心逻辑可复用，注册表和 BUILD 重写 |
| vlt 暴露规则 | 3.5（未变）+ 3.1 dff | **低** |
| litert-micro 算子 | 3.6（未变） | **低**，直接 cherry-pick |
| tflite 模型套件 | 3.5 Bazel + CoralFlow | 中，BUILD 全部重写，可以按需迁移 |

