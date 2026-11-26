# 04 · VME 容错：方案讨论与决策记录

> 第 04 阶段：VME 容错的方案讨论和决策记录，包括调研、取舍理由、设计细节、交给 05 实现的输入和延后项。
> 讨论轮次在本文件内原地修订（R1、R2…）。
> 分支：`fault-tolerance-v3`（base `main@f385a31b`，RVV FT 提交 `29a4e555`）。

## 修订记录

| 轮次 | 日期 | 主要变化 |
|---|---|---|
| R1 | 2026-11-22 | 确认 RVV FT 在 VmeCoreMiniAxi 上编译、通过；读 VME RTL；联网调研；VME 方案初稿（tile 影子奇偶校验 + 整数 ABFT）；trap 卡死的修复方向评估；DC 面积探测 |
| R2 | 2026-11-23 | **主方案从"ABFT + tile 奇偶"改为"交错时间复制 + 按元素部分提交 + RS 当 ROB 回滚"**。理由：(1) 时间复制同时覆盖整数和浮点，读网络也被覆盖，不需要按数据类型单独做预测逻辑；(2) 空间冗余约占 26% 芯片面积，没有空闲 PE；(3) 新方案第一阶段约 1% 芯片面积。补充项：写入校验（覆盖写分发）、RS 奇偶。存储层延后到 06 以后。LSU trap 卡死修复也延后 |

---

## 0. 本轮结论速览（R2）

1. **RVV FT 在 VmeCoreMiniAxi（ZVT_ON）下能编译并通过**：rvv_arithmetic 25/25，FT 计数与 RvvCoreMiniAxi 完全一致；官方 vme_test 20/20 也通过（§1）。
2. **VME 的结构决定了它只能"检测 → 上报"，不能像 RVV 那样重放**：matmul 在 tile 里原地累加（C ← C + A·B），旧的 C 被覆盖；A/B 来自 RS 的 payload，发射后就丢了（§2.4）。
3. **主方案（§4）：按组交错的时间复制 + 按元素部分提交 + RS 当 ROB 回滚**
   - 每组（cnt 的一个取值）发射两遍：g0p0 g0p1 g1p0 g1p1 …，配对永远相邻。
   - 两遍各自读 C_old，所以读网络也被覆盖；B 的 skew 寄存器改成每拍抓取，消除共模。
   - 比较点在 zvt_mt 写口前；一致的元素延迟一拍写入，用 done 掩码挡住重放时已提交的元素。
   - u_zvt_rs 当 ROB：发射用独立偏移，校验通过才释放；回滚就是偏移清零。
   - 按序提交：后一条在前面所有指令校验完之前不写 MT；时序上正好零停顿（前一条 T0+17 出结果，后一条 T0+17 第一次延迟写）。
   - 同一条连续失败 VME_FT_RETRY_MAX 次（默认 3）后报 trap。
   - **理由**：空间冗余约占 26%；时间冗余约 1%，同时覆盖整数和浮点，不需要按数据类型单独做预测。
4. **补充项（§4 第四部分，05 第二阶段，每项可单独叫停）**：
   - 提交写入校验（VME_FT_WCHK_ON）：覆盖 zvt_mt 内部的写分发，能重写；约 0.9%。
   - RS 负载奇偶（VME_FT_RSPAR_ON）：RS 当 ROB 后表项多待约 17 拍；约 0.3%。
5. **trap 卡死修复延后到 06**（原 §5.3 的方向 (a)）：它涉及 Chisel，上游以后也可能自己修好。05 里 trap 只在 L1 观测（trap_valid_o 和 rob_tag），出错指令之后不放 store 或仿真提前结束。
6. **调研结论（§3）和 R1 面积数据（§4 附录）保留作为对照**。存储层（MT 寄存器保护）延后到 06 以后。

---

## 1. 前置确认：RVV FT 在 VmeCoreMiniAxi 上

新增了 3 个测试目标，只在 BUILD 文件末尾追加，**尚未提交**：

| 目标 | 内容 |
|---|---|
| `//tests/cocotb:vme_core_mini_axi_ft_model` | 与 `vme_core_mini_axi_model` 相同的宏（`ZVT_ON`、`ZVTBF16FMM_ON`、`ZVTI16I32MM_ON`），另加 `RVV_FT_ON`、`RVV_FT_INJECT_ON` |
| `//tests/cocotb:vme_rvv_arithmetic_cocotb_test`（基线）/ `vme_rvv_arithmetic_ft_cocotb_test` | rvv_arithmetic 在 VmeCoreMiniAxi 上运行 |
| `//tests/cocotb/vme_test:vme_test_rvv_ft` | 官方 vme_test 在 FT 构建上运行 |

结果（Verilator，2026-11-22）：

| 测试 | 基线 | FT 开 | FT 计数（alloc / 比较 / 一致 / 不一致 / trap） | 仿真时间 |
|---|---|---|---|---|
| rvv_arithmetic | PASSED 25/25 | PASSED 25/25 | 9277 / 9277 / 9277 / 0 / 0 | 1,360,766 → 1,377,210 ns（+1.21%） |
| vme_test | PASSED 20/20 | PASSED 20/20 | 83 / 83 / 83 / 0 / 0 | 61,391 → 61,454 ns（+0.10%） |

- rvv_arithmetic 的计数和仿真时间与 03 §3.2（RvvCoreMiniAxi）完全一致。这个负载不用 VME，所以这是预期结果。
- 在 vme_test 里，VME 的结果（`vtmv.v.t` 写回 ROB）原样穿过 FT 模块，被保护的只有测试里夹带的 83 条 RVV 运算 uop。
- **没做的**：VmeCoreMiniAxi 上的 VCS 仿真、注错测试。

---

## 2. VME 的 RTL 结构（VLEN=128 → TE=16）

文件：`hdl/verilog/rvv/design/Zvt/`（21 个文件，5,312 行），在 `rvv_backend.sv` 里作为一个执行单元（`zvt vme`）例化。参数在 `inc/rvv_backend_define.svh`：`TE=16`、`NUM_MT=16`、`SUBTILE_SIZE=16`、`NUM_BLK=4`、`ZVT_LMUL=4`、`PROCESS_DELAY=4`、`NUM_BLKPORT=4`、`NUM_PE=64`。

### 2.1 模块与面积（DC，VmeCoreMiniAxi，全芯片 618,024 µm²）

| 模块 | 作用 | 面积（µm²） | 占全芯片 |
|---|---|---|---|
| `u_zvt_rs`（`rvv_backend.sv`） | VME 的 RS，深度 8 的 `multi_fifo`，payload 里带 vs1/vs2 数据 | 4,719 | 0.8% |
| `zvt_ctrl` | 译码，执行 move/load/store/zero，tile 读写端口在控制器和 PE 阵列之间切换 | 910 | 0.15% |
| `zvt_mt` | tile 存储加读写选择网络 | 176,482 | 28.6% |
| └ `zvt_mt_reg` | 16 个 tile × 16 个 subtile × 16 B = 4 KB（32 Kbit）触发器，按字节使能 | 34,365 | 5.6% |
| └ 选择网络（`zvt_mt` 自身的组合逻辑） | 16 个读口（4 block × 4 口，每口 128 bit，从 256 个 subtile 里选）加 16 个写口的译码 | 142,116 | 23.0% |
| `zvt_pe_array` | 4 个 `zvt_pe_block`，每个约 39.8k | 160,836 | 26.0% |
| └ 浮点乘法通路（`u_float_lane`，64 个） | bf16 两路点积 / fp32 乘 | ≈74,100 | ≈12.0% |
| └ 整数乘法通路（`u_int_lane`，64 个） | int8 四路 / int16 两路点积 | ≈40,800 | ≈6.6% |
| └ 加法器、流水寄存器、block 内部选择 | 层次报告没有再展开 | ≈46,000 | ≈7.4% |
| **VME 合计** | | **≈343,000** | **55.5%** |

浮点和整数乘法通路的面积是用 block 0 的子模块数乘以 4 得到的（`tools/area_probe` 解析 `area_hierarchy.rpt`）。

### 2.2 数据通路

```text
RVV dispatch ─► u_zvt_rs ─► zvt_ctrl ──┬─ matmul ─► zvt_pe_array（4 block）─┐
 (vs1/vs2 数据在 payload 里)          │                                  ▼ 写 C_new
                                      ├─ vtmv.t.v（vs2→tile）────────► zvt_mt（4 KB）
                                      ├─ tile load ◄─ lsu2vme ◄─ 标量 LSU    │ 读 C_old / 读出
                                      ├─ tile store ─► vme2lsu ─► 标量 LSU ◄─┤
                                      ├─ vtmv.v.t（tile→vector）─► res_vme2rvv ─► RVV ROB
                                      └─ vtzero
退休：rtCmd 队列 + 各 block 完成 ─► vmeRt（rob_tag）─► 标量 RetirementBuffer.writeDataTile
```

**matmul（`vtmmu/vtmms` int8、int16 变体、`vtfmm.alt` bf16、`vtfmm` fp32）**
- 一条指令有 4 个 uop，vs2 提供 A（16 行），vs1 提供 B（16 列）。
- 计算 C[16×16] += A[16×k]·B[k×16]，k 取 4（int8）、2（int16/bf16）或 1（fp32），C 是 int32 或 fp32。
- C 占 4 个连续的 MT（`dst_index[4:1]`）。
- 4 个 block 各算 C 的一个 8×8 象限，每拍 2 行 × 8 列，4 拍算完（`PROCESS_DELAY=4`）。
- 每个 block 的流水线：`mulbulk`（3 级，k 路乘积求和）→ 从 MT 读 C_old → `adder`（3 级）→ 把 C_new 写回 MT。
- 对同一个 tile 的相邻两条 matmul 有 RAW 检查（`hitRaw`），后一条要等前一条写回。
- bf16 的乘积和用 round-to-odd（ROD），之后的累加按 `rndMode` 舍入。

**其他操作**
- move、load、store 由 `zvt_ctrl` 经 block 0 的 4 个读写口完成，每个 uop 128 bit。
- 在 EEW8 和转置（`tss.pattern`）模式下按字节写，写同一个 subtile 时先读出旧值。
- 只有 `vtmv.v.t` 在 RVV ROB 里有 entry。其他 VME 指令不占 ROB（`pshrob_valid=0`），通过 `vmeRt` 直接在标量 retirement buffer 里退休。

**flush**
- `trap_flush_rvv` 清空 VME 内部的 FIFO 和 PE 流水线。
- tile 内容是架构状态，不会回滚。

### 2.3 与 RVV、标量 LSU 的接口

| 接口 | 方向 | 内容 |
|---|---|---|
| `uop_rs2zvt` | RVV → VME | ZVT_RS_t：rob_tag、rob_entry、vs1/vs2 数据、tm/vl/tk/sew 等 |
| `res_vme2rvv` | VME → RVV ROB | `vtmv.v.t` 的结果（PU2ROB_t）。开 RVV FT 时它在白名单之外，原样穿过 FT 模块 |
| `uop_vme2lsu` / `uop_lsu2vme` | VME ↔ 标量 LSU | tile store 的数据 / tile load 的数据，每拍 128 bit。走的是 **RVV 向量访存用的同一个 LsuSlot** |
| `vmeRt` | VME → 标量 RetirementBuffer | rob_tag、isStore、mtIdx。这是 VME 指令退休的唯一信号 |
| `vme_lsuflush_vld` | → RVV ROB | `RvvCore.sv` 里接的是常数 0，没有使用 |

### 2.4 对容错设计的约束

1. **不能重放**：matmul 原地累加，旧的 C 被覆盖；A/B 只存在 RS payload 和 PE 流水线里，发射后就丢了。要重放就得保存 C_old（每个累加器 8 Kbit）加 A/B（每条指令 1 Kbit），这和低开销的目标冲突。**所以 VME 的目标是把 SDC 变成 DETECTED，不追求 CORRECTED**。ABFT 的单错定位纠正可以作为以后的可选项（§4.3）。
2. **上报时机**：VME 指令一旦发出 `vmeRt` 就在标量侧退休了，之后 rob_tag 失效。所以检查必须在 `vmeRt` 之前完成，或者扣住 `vmeRt` 等检查完成。
3. **A/B 的入口在 RVV 一侧**：A/B 在 RS 里就出错时，ABFT 的预测值和实际值会一起错，检测不到。这部分（RS 占 0.8%）留给 §4 的"不覆盖"清单。

### 2.5 官方 VME 测试

`tests/cocotb/vme_test/BUILD` 里的 `vme_test` 有 18 个用例，加上 `vme_rvvi_retire_test` 的 2 个，共 20 个，覆盖 Verilator、VCS、UVM 三种目标：

- 计算类：`vme_matmul_{int8,int16,bf16,fp32}`、`vme_msettm_matmul`、`vme_mset_vtmmu_sequence`、`vme_altfmt`、`vme_mtwiden`。
- 数据搬运：`vme_load_store`、`vme_transpose`。
- 配置和状态：`mset_csr`、`msettk/msettm_clamp`、`decode`、`vset_mtype_reset`、`mset_retire`、`mstatus_ms`、`msettn_msettype`、`rvvi_*`。
- 另有 `vme_rvv_load_store_test`（RVV 的 load_store 在 VmeCoreMiniAxi 上跑）。

**问题**：全仓库只有这些单元测试用到 VME，`sw/` 和 tfmicro 里都没有。matmul 用例每个只做一次 16×16 的乘加（加上 vtzero 或预载入、读出），总共约 6 万 ns。05 用它们加自写的定向测试做功能验证；注错统计用什么负载留到 06 以后。

---

## 3. 联网调研结论

完整的报告（含原文出处）由调研子代理整理，PDF 和抽出的文本在 `/tmp/litdl/`（临时目录，进论文前要把需要的文件移进 `reference/`）。这里只列和方案有关的结论。**"自推导"表示我自己推导的，没有文献出处。**

### 3.1 矩阵引擎 / 脉动阵列 ABFT

| 结论 | 来源 | 对我们的意义 |
|---|---|---|
| 原始 ABFT：矩阵乘的行/列校验和可以检测并纠正单个错误 | Huang & Abraham, IEEE TC C-33(6):518–528, 1984, DOI 10.1109/TC.1984.1676475 | 基础引用 |
| FPGA 脉动阵列的低成本 MxM 检测：多数阵列尺寸下面积和能耗开销小于 1%，**相对的是阵列本身** | Libano, Rech, Brunhaver, IEEE TC 2023, DOI 10.1109/TC.2023.3248282（数字来自摘要） | 低开销 ABFT 的对标，口径是"相对阵列" |
| 卷积 ABFT 的多级 checksum，GPU 上运行时间开销 4–8% | Zhao 等 FT-CNN, IEEE TPDS 2021, arXiv 2003.12203 | 软件 ABFT 的口径 |
| 按算术强度在 global ABFT 和 thread-level ABFT 之间选择，执行时间开销比 global ABFT 低 1.09–5.3× | Kosaian & Rashmi, SC'21, DOI 10.1145/3458817.3476184 | "按负载选机制"的先例 |
| 16×16 阵列上做 tile 级 checksum；INT8 用 mod-239 消除两位翻转的结构性漏检 | Hua 等 TR-ABFT, Electronics 15(12):2715, 2026（MDPI） | 和我们的规模相同；mod-239 可以作为多位错误的补充 |
| **自推导**：在 Z/2^k 上，求和与乘法都是环同态，数据通路和校验和都按 mod 2^32 回绕时校验关系严格成立。结果的单比特错引入 ±2^j，mod 2^32 不为 0，所以一定能检出 | — | **整数 ABFT 不需要阈值** |
| 对单个 8×8 乘法器做残数检查，面积开销约 47% | Alzaher Noufal & Nicolaidis, DATE 1999 | 逐个 PE 做残数检查不划算，应在阵列级做 ABFT |

### 3.2 浮点 ABFT 的容差

| 结论 | 来源 |
|---|---|
| 用概率舍入误差模型在运行时算阈值（3σ），比 SEA 紧约两个数量级，检测率超过 90%；GPU 上开销约 13.8% | Braun, Halder, Wunderlich, A-ABFT, DSN 2014（已核实原文） |
| 经典 SEA 阈值 | Roy-Chowdhury & Banerjee, IEEE TC 1996, DOI 10.1109/12.485376（只核实了题目） |
| 混合精度时应该在 fp32 累加器里、量化之前比较，误差界约 1e-6；对低精度输出校验时约 1e-3 | V-ABFT, arXiv 2602.08043, 2026（**预印本**） |
| bf16、K 很大时低位尾数的翻转基本检测不到（0/600） | Khosla, arXiv 2610.02240, 2026（**单作者预印本**） |
| 只有高位（指数的高位）容易导致 SDC | Li 等, SC'17, DOI 10.1145/3126908.3126964（已核实） |

对我们的意义：
- 浮点 ABFT 只能抓住"大"错误。低位尾数的翻转本来对 DNN 影响也小，所以覆盖率应该按"有效错误"（SDC 改变了输出）来定义。
- 我们的 K 每条指令只有 1～4，累加跨多条指令发生，所以逐条指令做校验时 K 很短，阈值可以很紧。这个结论是自推导的。

### 3.3 tile 存储和选择网络的保护

| 结论 | 来源 |
|---|---|
| 码率：每字节 1 位奇偶 12.5%，每 32 位 1 位奇偶 3.1%，SECDED(39,32) 21.9% | 算术 |
| 所有寄存器存奇偶位，只对最脆弱的寄存器存 ECC。RF 的 AVF 降低 73%/85%，没有性能损失 | Montesinos 等, ParShield, DSN 2007 |
| 工业做法是检错加检查点重试 | IBM POWER6, IBM J. R&D 51(6), 2007 |
| **自推导**：选择器和 crossbar 只做选择、不改数据，奇偶位跟着数据走就能端到端覆盖，不需要预测逻辑 | — |
| 65 nm FF 的 MCU/SEU 比例最高 23–31%，随间距按指数下降；12/16 nm 的定量数据没有找到 | Furuta 等, IRPS 2013 |

### 3.4 DNN 加速器可靠性与开销口径

- **FIdelity**（He, Balaprakash, Li, MICRO 2020, DOI 10.1109/MICRO50266.2020.00033，已核实）：数据通路 FF 和软件变量一一对应，用 reuse factor 由 FF 推出软件故障模型，再按 FF 占比和逐层时间加权得到加速器 FIT。**只建模 FF，不注组合逻辑**。我们的门级注错（FF + 组合逻辑，按面积加权）更完整，可以把 FIdelity 作为方法对照。
- **开销口径**：多数工作只相对被保护的模块报面积（Libano 相对阵列，残数乘法器相对乘法器本身，Barbirotta 相对 VPU），几乎没有人相对整个 SoC 报。**建议同时报"相对 VME"和"相对全芯片"两个数**，性能报整个负载的周期数。

### 3.5 02 文档〔待核实〕条目的核对结果

| 条目 | 状态 | 说明 |
|---|---|---|
| Barbirotta：EVEN/ODD 指令复制 | 已核实 | 依据是同一组作者 RISC-V Summit Europe 2025 的摘要和海报，期刊 PDF 没有拿到 |
| Barbirotta：8 bit ECC 签名比较 | **修正** | 比较的是两份副本写进 ECC buffer 的 ECC 值，同一套 ECC 逻辑也保护 VRF；"8 bit"没有核实 |
| Barbirotta：借助重命名做 kill-and-retry | **修正** | 已核实的部分：不一致时不提交，kill 后回滚到这条指令之前的状态；是否借助重命名，原文没有说 |
| Barbirotta：面积 +7.5% | 已核实，附注 | 相对整个 VPU，等于寄存器文件 6.83% 加指令复制 0.67%。表里的数字（1.49→1.61）算出来是 +8.05%，结论里又写 7% |
| Barbirotta：最坏 2× 时间、未检出错误 −75%、只注 lane 0 的 bit 0 | 已核实 | 原文措辞是"non-silent undetected faults"减少 75% |
| FIdelity 跨层投射 | 已核实 | 见 3.4 |
| Leveugle DATE 2009 样本量 | 已核实（二手） | n = N·t²·p(1−p) / [e²(N−1) + t²·p(1−p)]；p=0.5、e=1%、99% 置信度时 n≈16.6k |
| VCS checkpoint | 部分核实 | `$save/$restart` 和 UCLI 的 `save/restore` 都有出处，本机版本要实测 |
| Warped-DMR、Gomaa ISCA 2005 | 已核实 | 后者：只在低 ILP 阶段插入冗余，平均性能损失约 2% |
| SITR（SBAC-PAD 2007） | **没找到** | 可能是 SRTR（ISCA 2002）或 Selective Replication 记错了。建议从 02 里删掉 |
| "放弃未发出的副本"的先例 | 没找到完全一致的 | OPPORTUNISTIC 已经不做，这一条不影响结论 |

## 4. VME 容错方案（R2）

**定位**：主线是"时间复制 + 回滚纠错"这一个机制，并在它上面尽量扩大保护域。重试耗尽几乎不会发生，trap 只是兜底。

**不做空间冗余的理由**：PE 阵列约占全芯片 26%，空间复制等于再加一个阵列。VME 没有 RVV 那样多条流水线可以复用，PE 阵列没有空闲。

### 4.1 核心机制（05 第一阶段）

#### 1) 按组交错的时间复制

**"组"**：原设计 cnt 的一个取值，也就是发射一拍的工作量。每个 block 算 2 行 × 8 列 = 16 个元素；一条 matmul 最多 4 组（`PROCESS_DELAY`）。

**发射顺序**：g0p0 g0p1 g1p0 g1p1 g2p0 g2p1 g3p0 g3p1，即每拍紧接着重复一次。**不用** 4+4（g0..g3 发完再发一遍）。

**理由**：
- 配对永远相邻，与组数无关。4+4 在组数 n<4 时变成 n+n；tm=9～14 时 block 0/1 做 4 组、block 2/3 只做 cntMax10+1 组，4+4 的配对距离还要按 block 变。
- 部分提交时 dupBuf 只需 1 级，4+4 需要 4 级。
- 第二遍输入和上一拍完全相同，数据通路几乎不翻转，动态功耗增量小（待功耗仿真量化）。
- 能查出电压跌落、老化这类时序错：第二遍没有跳变，不会重复同样的错。4+4 里 g1～g3 两遍的跳变完全相同，可能漏掉。

**覆盖范围**：
- 两遍各自经过读网络读 C_old，所以 zvt_mt 的**读网络**也被覆盖。
- PE 阵列的整数和浮点通路同时被覆盖，不需要按数据类型单独做预测逻辑。

**必须改的地方**（已对照 RTL 核实）：
- **cnt 两拍进一次，pass 每拍翻转**：
  ```systemverilog
  // zvt_pe_array.sv 原设计
  assign cntCr = cnt == cntMax00;
  assign cntEn = canStart && blkCmdRdy[0];
  
  // FT 下改为
  assign cntCr = (pass == 1) && (cnt == cntMax00);
  assign cntEn = canStart && blkCmdRdy[0];
  ```
- **B 的 skew 寄存器每拍抓取，消除共模**：
  ```systemverilog
  // zvt_pe_array.sv:322-324 原设计
  edff #(.T(PEVBINFO_t)) regLbData  (.e(pipeLbEn  && (cnt=='d0)), ...);
  edff #(.T(PEVBINFO_t)) regHb0Data (.e(pipeHb0En && (cnt=='d0)), ...);
  edff #(.T(PEVBINFO_t)) regHb1Data (.e(pipeHb1En && (cnt=='d1)), ...);
  
  // FT 下改为
  edff #(.T(PEVBINFO_t)) regLbData  (.e(pipeLbEn), ...);
  edff #(.T(PEVBINFO_t)) regHb0Data (.e(pipeHb0En), ...);
  edff #(.T(PEVBINFO_t)) regHb1Data (.e(pipeHb1En), ...);
  ```
  原设计只在 cnt==0/1 时抓取，交错后 block 3 的 g0p0 会用到上一条指令的 B，必须改成每拍抓取。这样也顺带消除了"两遍共用同一份 B"的共模。
- **A 的流水寄存器**（vaInfoLoD1 等）本来就是每拍抓取，不用改。

#### 2) 按元素部分提交 + 延迟写

**比较点**：zvt_mt 写口前（zvt_ctrl 写选择之后），16 口 × (128 bit 数据 + 16 bit 写使能 + 8 bit 地址) ≈ 2.4 Kbit。

**流程**：
1. p0 到达时，把端口级的数据、字节使能、写地址（writeMtIdx/writeSubIdx）存进 **dupBuf**，16 口 × 约 152 bit ≈ 2.4 Kbit。dupBuf 带有效位，p1 用完就清掉。
2. p1 到达时逐项比较，pass/组号/槽号和 fflags 旁路也一起比。槽号是在飞 PE 指令的序号，2 bit 就够。
3. 一致的元素打一拍后，从 dupBuf 写进 zvt_mt（**延迟写**）。

**done 掩码**：每个元素一个 done 位，4 block × 4 组 × 16 元素 = 256 bit。
- 提交条件 = 有效 ∧ 一致 ∧ ¬done。
- 重放时 done=1 的元素即使两遍一致也不写（它们读到的是已更新的 C，结果无意义）。
- 失败只看 有效 ∧ ¬done ∧ ¬一致。

**完整性**：按每个 block 的期望组数统计，每组每个有效元素都要么 done、要么本次一致。期望组数：
- block 0：cntMax00+1；
- block 1：只在 vbHiActive 时工作，为 cntMax00+1；
- block 2：只在 vaHiActive 时工作，为 cntMax10+1；
- block 3：两者都满足时才工作，为 cntMax10+1。

**不能用各 block 的 lastUopVld 判断完成**：tm=9～14 时 block 2/3 收不到 lastUopVld（已对照 RTL 核实：zvt_pe_array.sv:243-244 只有 block 0/1 的 lastUopVld 被赋值）。

**失配标志和完整性的累计按槽号分开**，至少两套。原因是后一条的第一次比较（T0+16）早于前一条出校验结果（T0+17）。

**不用原子提交**（全部比对通过后再一起写）：一条指令结果 8 Kbit，写口每拍 2 Kbit，至少要写 4 拍；背靠背时，同 tile 间隔会拉到约 14 拍。它的好处（不需要 done 掩码、trap 精确）在这里很小。

**fflags**：
- FT 下去掉加法器出口的浮点异常反压（`adderResRdy = !fpexpVld || fpexpRdy`），改为累计已提交元素的标志，校验通过时经 zvtFpexp 握手一次性上报。握手未就绪只推迟释放，不影响按序提交的判定。
- 原设计中，乘法级的 OF/NV 按 block 汇总进 tag，加法级逐 PE。累计规则：
  - 一组里只要有元素提交，就计入这组的乘法级标志。它只依赖 A、B，重放时不变。
  - 加法级标志按提交位逐 PE 计入。
- 这些标志随写口旁路带到提交单元，也参与两遍比较。
- 这样 FT 下 PE 流水没有任何停顿。原设计里 block 1～3 的 skew 寄存器没有反压、会丢组，这个问题也随之消失。

#### 3) RS 当 ROB：发射和释放解耦

**问题**：如果 RS 队头要等校验通过才释放，而 RS 又是只露出队头的 FIFO，背靠背就不可能（n=4 时 18 拍一条）。

**方案**：u_zvt_rs 本来就按 uop 存着全部操作数，让它同时充当 ROB 和 replay_mem。
- PE 指令的表项等校验通过才释放，一次弹出 4 项。
- misc 指令照旧发射即弹出，但只在偏移为 0 时（没有未校验的 PE 指令）才能发射。
- 发射用独立的偏移：发射视图是 `rptr + 偏移 + i` 处的 4 项，有效位 = `entry_count > 偏移 + i`。
- 回滚就是把偏移清零；trap_flush_rvv 时整体清空。

**为什么 rtCmdRs 不适合当重放源**：它每项只有 rob_tag、指令类型、mtIdx，没有操作数，补齐要约 11 Kbit，而且 misc 指令也占项。
- rtCmdRs 继续当按序退休队列。
- PE 指令改为校验通过时才 push，这样重放不会重复 push；misc 照旧。
- PE 发射不再受 rtCmdRdy 约束，改为在释放时检查。

**为什么 VME 能这样做而 RVV 不行**：RVV 的 RS 发射即释放，ROB 里也不存操作数；VME 的 RS 让表项多留一会儿就行。

**实现**：multi_fifo 只支持 2 的幂深度（指针宽 $clog2(DEPTH)，靠自然溢出回绕）。用它的 fifo_data 做偏移视图，深度 8 时要多约 1.4k µm² 选择器，深度 16 时多约 1 万 µm²。所以在 VME_FT_ON 下**新写一个专用 RS 模块**替换 u_zvt_rs，不改共用的 multi_fifo：
- 写入侧照搬 multi_fifo 的 3 路乱序 push 压缩（CHAOS_PUSH），almost_full 语义不变；
- 读出按偏移直接取 4 项；
- 指针按 DEPTH 取模；DEPTH 由 VME_FT_RS_DEPTH 决定，默认 12，可改成 8。

**深度取 12 的理由**：RS 要能放的指令数 = 每条指令占用 RS 的时间 ÷ 发射间隔。
- 原设计：约 6 拍 ÷ 4 拍 → 2 条。ZVT_RS_DEPTH = ZVT_LMUL×2 就是这么来的。
- FT 下 n=4：从开始发射到校验通过 17 拍，再加重新灌满约 3 拍（派发每拍最多 3 个 uop），约 20 拍 ÷ 8 拍 → 3 条 = 12 项。
- 深度 8 时，PE 打满约 10 拍一条，对目前 LSU 受限的实测负载（每条间隔 ≥20 拍）没有影响。

#### 4) 按序提交与回滚

**规则**：后一条指令在前面所有指令校验通过之前不能写 MT，不论是否同 tile。

**时序上正好零停顿**：
- 前一条最后一次比较（block 3 最后一组的 p1）在 T0+16，打一拍后 T0+17 出校验结果；
- 后一条从 T0+8 开始发射，它的第一次延迟写也在 T0+17。

**因此任何时刻只有最老那条可能部分提交**，done 掩码只要一套：最老那条校验通过（换头）时清零，同一拍属于新队头的提交直接写入新值。

**这是零余量时序**，要加断言。完整性要逐组累计，避免最后一拍汇总的组合路径过长。如果这条路径必须多加一拍，就在指令之间插 1 拍气泡（9 拍一条）。

**同 tile RAW**：提交比原设计晚 2 拍（p1 之后再延迟一拍），所以两条同 tile 指令 g0p0 的发射间隔要 ≥6 拍；开第二阶段的写入校验时要 ≥7 拍。这个间隔做成参数。
- 原设计是 ≥4 拍，靠 hitRaw 检查 block 0 的 mulbulk 三级里 readMtId==0 的组来保证（已对照 zvt_pe_array.sv:199 核实）。
- hitRaw 的检查窗口相应加长，例如记录上一条 g0p0 的 tile 和发射时刻。
- n≥3 时自然满足 6 拍，n≤2 要等。

**回滚流程**：
1. 只在最老那条的校验点触发，不在第一次失配时触发；
2. 停止发射；
3. 等 PE 流水排空，约 10 拍，期间所有比较和提交结果作废；
4. 偏移清零，从这条开始按序重发：它本身用 done 掩码挡住已提交的元素，后面的指令完整重做；
5. 同一条连续失败 VME_FT_RETRY_MAX 次（默认 3）后报 trap。

每次回滚大约多 30 拍。

**trap**：
- 带上该指令的 rob_tag，走 §5 的上报通路。
- 语义是不可恢复：tile 可能已被部分更新，由软件或主机整段重跑（正式构建里 mepc=0）。
- trap 能否端到端送到主机，取决于 LSU 的 trap 卡死修复（延后到 06，05 里只在 L1 观测）。

#### 5) 配套改动

**misc 指令**（vtle、vtse、vtzero、vtmv）要等到没有未校验的 PE 指令才执行，扩展原来的 peBusy 条件。

**zvt_ctrl 读写口归属**：按 uop[0] 译码来决定 MT 读写口归 PE 还是 misc（已对照 zvt.sv:130 核实：`peBusy || (|blkRtVld)`）。改成发射视图以后，要保证只要有未校验的 PE 指令，读写口就始终走 PE 通路。

**退休链**（peRtVld → blkRtVld → vmeRtCmdPop → vmeRt）改由校验/释放脉冲驱动，每条 PE 指令只驱动一次，vmeRt 比原来约晚 7 拍。已对照 zvt.sv:280-295 核实：
```systemverilog
// 原设计
vmeRtCmdPop = vmeRtCmd.isPe ? blkRtVld[3] : miscRtVldD1;
// FT 下改为
vmeRtCmdPop = vmeRtCmd.isPe ? checkpointPassVld : miscRtVldD1;
```

**RVVI 本轮不做**：
- 仿真构建都带 TB_SUPPORT，RVVI_ON 是开的；但 vme_test 用的 VmeCoreMiniAxi 不消费 RVVI 数据。
- 只要退休链对每条 PE 指令只驱动一次，mtInfo FIFO（不开 RVVI 也参与 vmeRtVld 握手）就保持一致。
- 同 tile 背靠背时 RVVI 会抓到后一条已写入的值，这个内容对齐问题只影响 VmeCoreMiniVerificationAxi 上的 cosim/UVM 比对，列为延后项。

**flush 清理**：原设计在 flush 时没有清零 pe_array 的 pipe*Vld、cnt 和 zvt_ctrl 的 vtzero 计数器，这里一并清零。

**参数化**：数字以 VLEN=128 为准（TE=16、4 组、4 uop、4 block），实现里不要写死这些数。

#### 6) 负载兼容性

| 场景 | 兼容性 |
|---|---|
| 组数 1～4，以及各 block 组数不同 | ✓ 完整性按各 block 期望组数统计 |
| tm≤8 或 tn≤8 时部分 block 不工作 | ✓ 校验完成点取最后一个工作的 block |
| 行列不满 | ✓ 逐 PE 有效位参与比较和提交 |
| int8/int16/bf16/fp32 及各种舍入模式 | ✓ 结果都是 32 bit，按位比较，fflags 一起比 |
| 同 tile 连发 | ✓ g0p0 发射间隔 ≥6 拍（开写入校验时 ≥7 拍）|
| 不同 tile 连发 | ✓ 吞吐由 RS 深度决定 |
| misc 指令穿插 | ✓ 等所有 PE 指令校验完 |
| 浮点异常 | ✓ 不再导致停顿 |
| LSU 受限负载 | ✓ 开销约为 0 |

#### 7) 代价（估算，06 以后综合和性能测试时实测）

**第一阶段面积**（按"占 VME / 占全芯片"两个口径报）：
- 提交单元约 3k µm²（dupBuf 约 2.4 Kbit、比较器、done 掩码、延迟写寄存器、控制）；
- RS 加深到 12 约 2k～2.4k µm²；
- 合计约 5.5k～6k µm²，约占 VME 1.7%、全芯片 1%；
- RS 保持 8 的话约 3.6k µm²（0.6%）。

**第二阶段面积**：
- 写入校验约 5k～6k µm²（约 0.9%）；
- RS 奇偶约 0.3k µm²。

**性能**：
- 实测的 LSU 受限负载（发射间隔 ≥20 拍）：约为 0。
- PE 打满、n=4：8 拍一条，这是时间冗余的下限；原设计是 4 拍。
- 吞吐表（拍/条，假设派发每拍 3 个 uop，没有其他瓶颈）：

| 场景 | 深度 8 | 深度 12 | 深度 16 | 原设计 |
|---|---|---|---|---|
| n=4 | 约 10 | 8 | 8 | 4 |
| n=2 不同 tile | 约 8 | 约 5.3 | 4 | 2 |
| n=1 不同 tile | 约 7 | 约 4.7 | 约 3.5 | 约 1.3 |
| 同 tile 的 n≤2 | 6（开写入校验时 7） | 6（7） | 6（7） | 2 |

- 每条 PE 指令的退休约晚 7 拍；每次回滚大约多 30 拍。

#### 8) 保护域（按面积估算）

**zvt_mt 的选择网络**约 142k µm²，读、写是对称的两套：16 个读口各从 256 个 subtile 里选 128 bit；256 个 subtile 各从 16 个写口里选数据和使能。按门数粗估各占一半，各约 7 万 µm²（06 用探测核实）。

**第一阶段覆盖**：PE 阵列约 161k µm²、zvt_mt 读分发约 7 万 µm²、发射逻辑、PE 写口打包、写地址计算、pe_array/zvt 布线、zvt_ctrl 写选择。

**第二阶段补上**：zvt_mt 写分发约 7 万 µm²（写入校验）、RS 负载（RS 奇偶）。

**仍未覆盖**：MT 存储寄存器 34k µm²、FT 自身逻辑（如 done 掩码）、永久故障。

**两个阶段都做完，按面积约 88% 的 VME 在保护域内**。

### 4.2 补充项（05 第二阶段）

每项用单独的宏、单独的测试，可以单独叫停：如果某一项需要改动第一阶段的控制流，或者开宏后第一阶段回归不过，就停下来挪到 06，不影响第一阶段和另一项。

#### 1) 提交写入校验（VME_FT_WCHK_ON）

**目的**：覆盖 zvt_mt 内部的写分发。第一阶段的比较点在 zvt_mt 入口，之后的分发出错没人知道。

**做法**：
- 在 zvt_mt 里，每个 subtile 根据实际写入的 wdata/wen 算 2 bit 签名：是否被写，以及数据加使能的奇偶。共 512 bit，从写入信号旁路取，不串在写路径上。
- 提交单元用另一套独立的译码，从 zvt_mt 的输入算出期望签名，同一拍逐个 subtile 比较。
- 只是目标 subtile 写坏了（数据错或漏写）：下一拍从 2.4 Kbit 的提交数据寄存器重写。交错模式下写口本来就隔拍空闲，用那个空拍。
- 重写再错，或者写到了不该写的 subtile（那里原来的数据已经丢了）：报 trap。
- misc 写入（vtle、vtzero、vtmv.t.v）也走这套分发，只检测、不重写，出错报 trap。

**能和第一阶段干净分开的关键**：打开时同 tile RAW 间隔从 6 改成 7。重写在提交后的下一拍完成，后一条同 tile 指令最早也要再晚一拍才读，读到的已是重写后的值，所以不用作废后面的指令，回滚和按序提交都不用动。代价是 n≤3 的同 tile 连发每条多等 1 拍。

**misc 的等待条件**加一条"没有待重写"。

**已核对**：同一拍里，PE 的 16 个写口不会写到同一个 subtile，期望签名可以按"一个口对一个 subtile"来算；misc 写入加一条断言兜底。

**改动量**：zvt_mt.sv 约 25 行（签名、端口、注错钩子），提交单元约 100～150 行，参数和连线约 15 行。

**FPGA 版的 zvt_mt**（FPGA_XILINX）不支持，两者同时定义时编译报错。

**测试**：
- 写分发里数据翻位：重写，结果正确；
- 漏写：重写；
- 写到不该写的 subtile：报 trap；
- 开这个宏时，第一阶段回归全过；
- 关掉它时，同样的注入应该漏检，作为对照。

#### 2) RS 负载奇偶（VME_FT_RSPAR_ON）

**做法**：在专用 RS 模块里实现。push 时每 32 bit 生成一位奇偶，每个 uop 约 10 bit；发射视图每次被读出（p0、p1、重放、misc）都检查，出错报 trap。约 40～60 行，约 0.3k µm²。

**必要性**：RS 当 ROB 以后，表项要多待约 17 拍；而且 RS 就是重放的数据源。表项如果在 p0 和 p1 之间被打翻，两遍对不上会触发重放，重放读到的是已经坏掉的表项，这回两遍一致，错值就被提交了。奇偶校验能把这种情况变成 trap。

**测试**：rs 注入点开、关奇偶各跑一遍做对照，其中包括"p0 和 p1 之间翻位"的场景。

#### 3) 第一阶段需要预留

- 写口选择做成多源结构，给"重写"留一个源；
- 同 tile RAW 间隔做成参数；
- 专用 RS 模块的表项宽度参数化，给奇偶位留位置。

### 4.3 宏和注错参数

**宏**：
1. `VME_FT_ON`（开关，默认关，第一阶段）：核心机制总开关，包括交错复制、写口前提交单元、RS 当 ROB、按序提交与回滚、fflags 累计上报、misc 等待、退休链改造、flush 清理、trap 合并。
2. `VME_FT_RETRY_MAX`（数值，默认 3，第一阶段）：同一条指令连续失败几次后报 trap。设成 0 就是只检测、不纠错，可以做对照实验。
3. `VME_FT_RS_DEPTH`（数值，默认 12，第一阶段）：专用 RS 的深度，必须是 ZVT_LMUL（4）的倍数且 ≥8。
4. `VME_FT_INJECT_ON`（开关，默认关，第一阶段，第二阶段补注入点）：仿真注错钩子、[VME_FT] 日志（mismatch、replay、rollback、squash、redo、trap）、仿真结束时的统计。风格和 RVV_FT_INJECT_ON 一致。
5. `VME_FT_WCHK_ON`（开关，默认关，第二阶段）：提交写入校验和重写；打开时同 tile 间隔 6 → 7。
6. `VME_FT_RSPAR_ON`（开关，默认关，第二阶段）：RS 负载奇偶校验，出错报 trap。

**规则**：
- INJECT、WCHK、RSPAR 三个开关必须和 VME_FT_ON 一起开，否则编译期报错；两个数值宏只在 VME_FT_ON 下生效；VME_FT_ON 依赖 ZVT_ON。
- 默认值和合法性检查写在新建的 VME FT 头文件里，用 ifndef 保护，不改上游 svh。
- VME_FT_ON 和 RVV_FT_ON 互相独立，任一打开时 trap 合并都生效。

**注错参数**用运行时 plusargs 选，不占宏：
- `+VME_FT_INJ_SITE=`：注入点。第一阶段有 p0、p1、dupbuf、bskew、done、rs，其中 done 和 rs 在第一阶段预期漏检，用作对照；第二阶段加 wsteer（写分发里翻位）、wstray（写到不该写的 subtile）。
- `+VME_FT_INJ_N=`：在第几次触发时注入；`+VME_FT_INJ_PERSIST=1`：之后每次都注，用来逼出重试耗尽。
- `+VME_FT_INJ_BIT=`、`+VME_FT_INJ_BLK=`：翻哪一位、哪个 block。

**要跑的编译组合**：
1. 不定义任何宏：行为必须和上游一致；
2. VME_FT_ON；
3. VME_FT_ON + VME_FT_INJECT_ON；
4. VME_FT_RS_DEPTH=8，跑一遍回归；
5. 第二阶段两个开关，各自单开一遍，再全开一遍；
6. 和 RVV_FT_ON 同时打开跑一遍，确认 trap 合并正常。

---

## 附录：R1 方案（ABFT + tile 奇偶）的面积数据

R1 推荐的是"整数 ABFT + tile 影子奇偶 / 阵列内奇偶"。R2 改为时间复制后，这些数据作为对照保留。

### A.1 整数 ABFT

探测脚本 `tools/area_probe/abft_int_probe.sv`，报告在 `abft/`。

**注意**：探测和 RTL 的差异：
- 缺 tk 掩码：RTL 里 tk<K 的 lane 不参与乘法，校验和也要跳过；
- 只有一个 isSigned：RTL 里 A、B 可以各自是有符号或无符号（INTMUL / UINTMUL / SINTMUL / USINTMUL）；
- 按行主序布局：探测里 vs2[i/4][(i%4)*32 +: 32] 是第 i 行，RTL 是列主序。

DC W-2024.09-SP1，TSMC12，IO 约束 0.2 ns：

| 条件 | 面积（µm²） | 占全芯片 | 占 VME | 时序 |
|---|---|---|---|---|
| 1 GHz | 9,632 | 1.56% | 2.8% | slack 0.00（刚好满足） |
| 2 ns（相当于多打一拍流水） | 7,574 | 1.23% | 2.2% | slack 0.70 |

### A.2 tile 奇偶校验

探测脚本 `tools/area_probe/mt_shadow_probe.sv`，报告在 `mt_sh/`。

| 机制 | 面积（µm²） | 占全芯片 | 占 VME | 来源 |
|---|---|---|---|---|
| 影子奇偶，每字节 1 位，不折叠 | 44,048 | 7.13% | 12.8% | DC 实测，slack 0.33 |
| 影子奇偶，每 subtile 折成 1 bit 再读 | 36,054 | 5.83% | 10.5% | DC 实测，slack 0.30 |
| 阵列内奇偶，每字节 1 位 | ≤ 约 26,000 | ≤ 约 4.2% | ≤ 约 7.6% | 估算（探测未收敛） |

**影子阵列为什么贵**：4 Kbit 奇偶 FF 只有 3,171 µm²（正好是主阵列 FF 的 1/8）。其余约 33～41k 是组合逻辑。大头是**独立的一套写使能译码**：256 个 subtile × 16 字节 = 4096 个使能，每个都要从 16 个写口里比较地址选出来。这套译码的规模和数据位宽无关，所以影子阵列虽然只有主阵列 1/8 宽，译码却是全量的。这正是"检测地址译码错误"的代价。
## 5. VME 错误上报（更新于 R2）

### 5.1 现状（和 R1 相同）

链路是 FT 事件 → `RvvCore.sv` 的 `trap_valid_o`（rob_tag + 哨兵 mtval）→ `FaultManager.rvv_fault` → RetirementBuffer 按 rob_tag 找到这条指令 → `trapRetired` → 跳到 mtvec → `ebreak` → `io.fault`。

### 5.2 事件源（R2 更新）

1. **复制回滚的重试耗尽**（第一阶段）：同一条指令连续失败 VME_FT_RETRY_MAX 次（默认 3）后，报 trap，rob_tag 为该指令。
2. **提交写入校验无法纠正**（第二阶段，VME_FT_WCHK_ON）：
   - 重写再错，报 trap；
   - 写到了不该写的 subtile（写坏了、或读分发译码错），报 trap。
3. **RS 负载奇偶错**（第二阶段，VME_FT_RSPAR_ON）：发射视图读出时检查奇偶，出错报 trap。

事件产生在 `zvt_ft.sv`（新建），附带出错指令的 rob_tag（从 `VME_RTCMD_t.rob_tag` 取，在 rtCmd 入队时就有）。

### 5.3 扣住 vmeRt

这条指令的检查没出结果之前不发 `vmeRt`。检查通过就放行；出错就不发 `vmeRt`，改发 trap。这样 rob_tag 对应的 RetirementBuffer entry 还没退休，可以被 trap 精确命中。

实现：退休链（§4.1 第 5 条）改由校验/释放脉冲驱动。

### 5.4 合并

在 `RvvCore.sv` 里和 RVV FT trap、前端 trap 一起合并到 `trap_valid_o`，每次 flush 只报一个。同一拍两个都有时，RVV FT 优先（因为另一个会被 flush 掉或者再次被检测到）。

### 5.5 mtval 哨兵

建议 VME 用一个和 RVV（`0xFFFF_FF87`）不同的保留编码，上位机就能区分错误来源。05 先按"分开"实现，以后定了再改。

### 5.6 flush

`trap_flush_rvv` 本来就会清空 VME 的 FIFO 和流水线。tile 内容不回滚，本来也是不可恢复错误。

### 5.7 LSU trap 卡死修复：延后到 06

**原 R1 的 §5.3 方向 (a)**（修 `Lsu.scala`，让 LsuSlot 在 flush 时放弃向量/tile 事务）**延后到 06 以后**。

理由：
- 它涉及 Chisel，上游以后也可能自己修好；
- 05 的目标是功能级 RTL 注错验证，trap 只在 L1 观测（trap_valid_o 和 rob_tag）；
- 出错指令之后不放 store，或者看到 trap 就结束仿真。

原 §5.2（VME 也有同样问题）和 §5.3（修复方向评估）的内容保留作为记录，标注"延后到 06"。

---

## 6. 交给 05 的输入

### 6.1 第一阶段实现拆分（按文件）

1. **新的专用 RS 模块**（VME_FT_ON 下替换 u_zvt_rs）：
   - 发射视图：按偏移取 4 项；
   - 释放：校验通过时一次弹出 4 项；
   - 回滚：偏移清零；
   - 参数：VME_FT_RS_DEPTH（默认 12）。
   - **rvv_backend.sv** 里的接线改动。

2. **zvt_pe_array.sv**：
   - 交错发射：cnt 两拍进一次，pass 每拍翻转；
   - B skew 寄存器每拍抓取（去掉 `cnt==0/1` 条件）；
   - hitRaw 窗口加长（参数化），记录上一条 g0p0 的 tile 和发射时刻；
   - 回滚状态机：停发射、等排空、偏移清零、按序重发；
   - 槽号（2 bit）随流水传递。

3. **zvt_pe_block.sv**：
   - FT 下去掉浮点异常反压（`adderResRdy = 1'b1`）；
   - pass/组号/槽号和 fflags 旁路随写口带出。

4. **zvt.sv**：
   - 写口前的提交单元（dupBuf、比较器、延迟写、done 掩码、按槽号的失配和完整性累计、按序校验、回滚触发、重试计数、trap 事件）；
   - 写口多源选择（为第二阶段的重写预留）；
   - 退休链改由校验脉冲驱动：PE 的 rtCmd 改在校验时 push；vmeRtCmdPop 改用 checkpointPassVld。

5. **zvt_ctrl.sv**：
   - misc 指令等待未校验的 PE 指令（扩展 peBusy）；
   - 有 PE 指令在飞时读写口保持 PE 通路；
   - flush 时清零 vtzero 计数器。

6. **RvvCore.sv**：
   - VME 的 FT trap 和 RVV FT trap、前端 trap 合并，一次 flush 只报一个，同拍都有时 RVV FT 优先。

7. **新建 VME FT 头文件**：
   - 宏的默认值和合法性检查（§4.3）。

### 6.2 第二阶段

见 §4.2。写入校验改 zvt_mt.sv（签名旁路和注错钩子）、扩展提交单元、调 RAW 参数；RS 奇偶只改专用 RS 模块。

### 6.3 第一阶段验证项

a) **不定义 VME_FT_ON 时，行为和上游一致**。

b) **FT 开、不注错**：
   - vme_test 全过（VmeCoreMiniAxi，20 个用例）；
   - 新增定向测试程序，覆盖同 tile 连发、不同 tile 连发、n=1～4、tm=9～14、tn≤8、行列不满、带浮点异常。

c) **FT 开、注错**：
   - p0 或 p1 结果翻位：能检测到、能回滚、最终结果正确；
   - 持续注错：重试耗尽后报 trap，rob_tag 正确；
   - 前一条出错时后一条已经在飞：后一条作废并按序重做，结果正确；
   - B skew 寄存器、dupBuf 翻位：能检测到；
   - 回滚中再次出错；回滚期间收到外部 flush；
   - **对照**：在 done 掩码和 RS 负载上翻位，预期漏检，用来标出保护域的边界。RS 负载里专门做一个"p0 和 p1 之间翻位"的场景，演示重放源被打坏时的 SDC。

d) **专用 RS 模块的单元测试**：带参考模型，随机做 push、发射、释放、回滚和 flush。

e) **trap 只在 L1 观测**（trap_valid_o 和 rob_tag）。LSU 的 trap 卡死修复不做，所以重试耗尽的用例里，出错指令之后不放 store，或者看到 trap 就结束仿真。

第二阶段的测试见 §4.2。

### 6.4 05 不做

综合（面积、时序）、功耗、性能统计、网表注错、存储层、misc 导出类读两遍、RVVI 内容对齐、LSU 的 trap 卡死修复、done 掩码保护、看门狗、永久故障检测。

### 6.5 已知风险

1. **写口前比较加上各 block 完整性汇总进校验寄存器，这条组合路径的时序**功能验证查不出来，留给 06 综合确认。时序不过就退回加法器出口比较，或者在指令之间插 1 拍气泡（9 拍一条）。
2. **zvt_mt 读、写分发各占一半**是按门数粗估的，影响保护域的说法，06 用探测核实。

---

## 7. 延后项和 06 以后的候选

1. **存储层**：MT 存储寄存器的保护，在影子奇偶、阵列内奇偶、运行校验和之间选（R1 的面积数据见附录）。
2. **LSU 的 trap 卡死修复**（原 R1 §5.3 方向 (a)，改 Lsu.scala），或者等上游修好。
3. **misc 导出类**（vtse、vtmv.v.t）读两遍比对，不一致就重读。
4. **done 掩码保护、看门狗**。
5. **永久故障**：第二遍交换乘法器的两个操作数（RESO 一类思路，代价是失去交错的低翻转优势），或者软件定期跑已知答案自检。
6. **RVVI 内容对齐**：只有在 VmeCoreMiniVerificationAxi 上做 cosim/UVM 比对时才需要。
7. **综合面积和时序**（两个口径），包括 zvt_mt 读、写分发面积拆分的探测；**功耗**（验证交错第二遍的低翻转）；PE 打满时的性能测试。
8. **网表注错**：未加固基线和加固后各做一遍。
9. **待核实**：普通中断或异常会不会冲刷正在 VME 里执行的 matmul。如果会，那是原设计本身的精确性问题，和 FT 无关，单独记录。
