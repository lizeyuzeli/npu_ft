# 04 · VME 容错：联网调研与方案讨论

> 第 04 阶段：VME 容错的联网调研和方案讨论，加上 RVV/VME 共用的错误上报（含 03 §3.6 的 trap 卡死修复）。
> 讨论轮次在本文件内原地修订（R1、R2…）。需要你拍板的问题集中在 §6。
> 分支：`fault-tolerance-v3`（base `main@f385a31b`，RVV FT 提交 `29a4e555`）。

## 修订记录

| 轮次 | 日期 | 主要变化 |
|---|---|---|
| R1 | 2026-11-22 | 确认 RVV FT 在 VmeCoreMiniAxi 上编译、通过；读 VME RTL；联网调研；VME 方案初稿（tile 影子奇偶校验 + 整数 ABFT）；trap 卡死的修复方向评估；DC 面积探测 |

---

## 0. 本轮结论速览

1. **RVV FT 在 VmeCoreMiniAxi（ZVT_ON）下能编译并通过**：rvv_arithmetic 25/25，FT 计数与 RvvCoreMiniAxi 完全一致；官方 vme_test 20/20 也通过（§1）。
2. **VME 的结构决定了它只能"检测 → 上报"，不能像 RVV 那样重放**：matmul 在 tile 里原地累加（C ← C + A·B），旧的 C 被覆盖；A/B 来自 RS 的 payload，发射后就丢了（§2.4）。
3. **推荐组合（待你确认，§4.6）**：
   - PE 阵列的整数通路：**整数全校验和 ABFT**，按 mod 2^32 精确比较，不需要阈值。DC 实测检查器 7,574～9,632 µm²，占全芯片 1.2～1.6%。这是低开销的主要亮点。
   - tile 存储和选择网络（28.6%）：**奇偶校验**。不改上游的影子阵列 DC 实测要 5.8～7.1%；改上游的阵列内方案估计 ≤ 4.2%。**这是整个方案里最贵的一项，选哪种需要你拍板（Q1、Q2）**。
   - 浮点通路：硬件 ABFT 估计要 4～6%，**建议先不做**，用注错数据决定（§4.4）。
4. **trap 卡死是 RVV 和 VME 的共同问题**：VME 的 tile load/store 也走标量 LSU 的同一个事务槽。推荐修 `Lsu.scala`（flush 时放弃正在等协处理器数据的向量/tile 事务）。这必须改 Chisel，理由见 §5.3。
5. **VME 能复用 RVV 的上报通路**：按 VME 指令的 rob_tag 走 `trap_valid_o`，前提是先扣住该指令的 `vmeRt`，等检查完成再放行（§5.4）。

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

**问题**：全仓库只有这些单元测试用到 VME，`sw/` 和 tfmicro 里都没有。matmul 用例每个只做一次 16×16 的乘加（加上 vtzero 或预载入、读出），总共约 6 万 ns。用它们做注错负载代表性不足，见 §6 的 Q5。

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

## 4. VME 容错方案

### 4.1 按功能域列候选机制

| 功能域 | 面积占比 | 候选机制 | 结论 |
|---|---|---|---|
| D1 tile 存储 FF | 5.6% | 阵列内奇偶校验 / **影子奇偶校验** / SECDED | 影子奇偶校验（4.2） |
| D2 tile 读写选择网络 | 23.0% | 同 D1（奇偶位跟着数据走） | 同上 |
| D3 PE 整数乘法通路 | 6.6% | **整数 ABFT** / 逐 PE 残数检查 / 空间 DMR | 整数 ABFT（4.3） |
| D4 PE 浮点乘法通路 | 12.0% | 浮点 ABFT（带阈值）/ 降精度 ABFT / 不保护 | **待定**（4.4，Q3） |
| D5 加法器、流水寄存器 | 7.4% | 被 D3、D4 的 ABFT 顺带覆盖（只覆盖校验和所用的那部分） | 随 D3/D4 |
| D6 控制器、RS、各 FIFO | ≈1% | watchdog | 不做，watchdog 可选 |

不做的机制及理由：
- **SECDED**：
  - tile 有按字节的写（EEW8 的 move/load、转置），按 32 位字编码就要读改写。
  - 码位占 21.9%，读网络也要同比变宽。读网络本身是 23%，光这一项就约 +5%。
  - 能纠错的只是存储这一段，而 matmul 的累加错误还是只能检测，纠错能力用不上。
- **逐 PE 残数检查**：每个乘法器约 +47%（DATE'99）。只算整数通路就要 +3%，而且不覆盖加法器。
- **空间 DMR / 锁存比较**：+26%，只作为高开销的对照。
- **重放**：matmul 原地累加，不能重放（2.4）。

### 4.2 tile 存储 + 选择网络：影子奇偶校验

**结构**：新文件 `zvt_ft.sv` 里放一份独立的奇偶位阵列，16 tile × 16 subtile × 16 bit，共 4 Kbit。
- 写入：在 `zvt_mt` 的写口（writeEn/MtIdx/SubIdx/Data）上，每个字节算 1 位奇偶，按同样的地址和字节使能独立写进影子阵列。
- 读出：在读口按同样的 readMtIdx/SubIdx 读出影子奇偶位，和 readData 现算的奇偶比较。
- 校验只在读出的数据真正被使用的那拍做（PE 的 C_old 读、`vtmv.v.t`、tile store），避免对不会再用的 tile 报错。

**覆盖什么**：
- 存储 FF 的单比特翻转。
- 写网络、读网络里数据通路的错误：从写口到 FF，再从 FF 到读口，任何改变数据的单比特错误。
- **主阵列的地址译码错误**：写到了错的 subtile，或从错的 subtile 读出。影子阵列独立译码，所以读出时奇偶对不上。这一点比"把奇偶位塞进主阵列"更强：阵列内的奇偶位和数据走同一套译码，地址错了也检测不到，除非把地址也折进奇偶位。

**不覆盖什么**：
- 写口之前产生的错误：PE 算错了交给 ABFT；move/load 的源数据错在 RVV RS 或 LSU 里。
- 读口之后 `zvt_ctrl` 里的重排逻辑。
- 两边共用的地址信号本身出错，比如 PE 算出了错的 readMtIdx。
- 同一个字节里偶数个比特翻转。

**和"阵列内奇偶校验"的比较**：

| | 阵列内（改 `zvt_mt.sv`、`zvt_mt_reg.sv`） | 影子阵列（新文件） |
|---|---|---|
| 改上游 | 存储加宽，奇偶位要穿过所有端口类型，会牵连 `zvt_ctrl` 和 `zvt_pe_block` 的位宽 | `zvt_mt` 不改；`zvt.sv` 里加一处例化 |
| 地址错误 | 检测不到（不折地址时） | 能检测 |
| 面积 | ≤ 约 4.2% 全芯片（估算，4.5） | 5.8～7.1% 全芯片（DC 实测，4.5） |

**变体：在影子阵列内部折叠**。每个 subtile 的 16 个奇偶位先在本地异或，读网络只传 1 bit 或少数几 bit。这样读网络能缩小到 1/16，代价是检测粒度变粗：同一个 subtile 里偶数个比特翻转就漏掉了，相邻 MBU 正好是这种情况。折成 4 bit 并按位交织（bit i 进第 i mod 4 组）是一种折中。面积见 4.5。

### 4.3 PE 阵列整数通路：全校验和 ABFT

**原理**：每条整数 matmul 指令（int8 时 k=4，int16 时 k=2）满足

```text
预测值  S_pred = Σ_k (Σ_i a_ik)·(Σ_j b_kj)                 （只计 tm/tn 尾部掩码内的行和列）
实测值  S_meas = Σ_{i,j 被写} (C_new_ij − C_old_ij)
检查    S_meas − S_pred ≡ 0  (mod 2^32)
```

- PE 的整数累加本身按 32 位回绕，所以校验关系严格成立，**不需要阈值，没有误报**。
- C 里任何一个元素的单比特错都会引入 ±2^j（j<32），mod 2^32 不为 0，一定能检出。这是自推导的结论（3.1）。

**取值点**：
- A、B 在 `zvt_pe_array` 入口取（4 个 uop 的 vs2/vs1），这样后面的脉动流水寄存器（vaInfoLoD1 等）也在覆盖范围内。
- C_old 和 C_new 在每个 block 的加法器入口和出口取，带上元素的有效位。实测值按"写入 − 读出"分别累加，两者不需要在同一拍对齐。

**为什么要在 `zvt_pe_block` 里加钩子**：
- 只在 `zvt.sv` 那一层取 readData/peWriteData 的话，读是按 subtile 读出 4 个字，写是按字带掩码写，尾部元素读了但没写，无法从端口信号判断哪些读出的字会被写。
- 所以 `zvt_pe_block` 要在 `` `ifdef VME_FT_ON `` 里把加法器的输入/输出和有效位引出来，经 `zvt_pe_array`、`zvt.sv` 送到 `zvt_ft.sv`。

**并发**：
- 同时在流水线里的 matmul 最多 3 条左右：发射间隔 4 拍，流水约 11 拍。
- 校验和累加器按累加器组（`dst_index[4:3]`，4 组）分开。同一组的相邻 matmul 有 `hitRaw` 互锁，所以每组同时只有一条。这一点实现时要用断言确认。

**检查时机**：
- 指令的最后一次写回（`blkRtVld[3]`）之后 1～2 拍出结果。
- 在此之前扣住这条指令的 `vmeRt`（5.4）。只增加退休延迟，不降低 PE 吞吐。rtCmd 队列和 mtInfo 队列深度都是 8，可以吸收这点延迟。

**面积（DC 实测，TSMC12，探测脚本 `tools/area_probe/abft_int_probe.sv`）**：

| 条件 | 面积（µm²） | 占全芯片 | 占 VME | 时序 |
|---|---|---|---|---|
| 1 GHz | 9,632 | 1.56% | 2.8% | slack 0.00（刚好满足） |
| 2 ns（相当于多打一拍流水） | 7,574 | 1.23% | 2.2% | slack 0.70 |

- 探测模块包含：A/B 的列和行和（4 路 × 16 元素，带尾部掩码和符号扩展）、4 个 20×20 位乘法、4 个 block 每拍 16 个元素的 (C_new − C_old) 求和、2 个上下文的累加器。
- 不包含：钩子的连线，按累加器组分开的 4 个上下文（探测里只有 2 个），`vmeRt` 扣留逻辑。估计再加 10～20%。
- 实际实现可以多打一拍，面积接近 2 ns 那一行。

**覆盖什么**：整数乘法通路、加法器的整数部分、PE 的流水寄存器、block 内部的读数据重排（`operands`），以及 A/B 在阵列内的传递。

**不覆盖什么**：
- A/B 在进阵列之前就错了（RS、VRF）。
- 预测和实测同时被同一个错误影响（概率很小）。
- 多个错误恰好抵消（概率很小）。
- 控制错误：比如少写了一个元素，这时实测值少一项，会被检出；但写到了错的 tile 地址，这要靠影子奇偶校验。

**可选的纠错扩展（不建议本轮做）**：加上行、列两组校验和（16+16 个）可以定位并纠正单个元素的错误。代价是预测端约 32×k 个小乘法器，外加 32 个实测累加器，还要能写回 MT。估计面积是全校验和的 4～8 倍。

### 4.4 PE 阵列浮点通路：代价高，建议先测再定

浮点的问题在于校验和本身要用浮点加法：
- 实测端：每拍 64 个元素的差要求和，需要一棵 64 输入的 fp32 加法树（63 个 fp32 加法器）。
- 预测端：约 32 个 16 输入的和加上 k 个乘法。
- 此外还要做阈值比较。

按 12 nm 下 fp32 加法器约 400～600 µm² 粗估（**未综合，待测**），完整的 fp32 ABFT 约 4～6% 芯片面积，相当于浮点乘法通路本身面积的一半，和"低开销"的定位冲突。

| 方案 | 面积（粗估） | 能检测的错误 | 备注 |
|---|---|---|---|
| F0 不保护 | 0 | 无（tile 存储和选择网络仍有奇偶校验） | 论文里写成局限，用注错数据说明浮点通路的 SDC 占比 |
| F1 降精度校验和（尾数约 8 bit，阈值宽） | 约 1.5～2.5% | 指数位、尾数高位的错误 | 依据 Li SC'17"只有高位导致 SDC"。阈值按每条指令 K≤2 推导，可以很紧 |
| F2 完整 fp32 校验和 + 阈值 | 约 4～6% | 除低位尾数以外的大多数错误 | 参考 A-ABFT 的阈值 |

**建议**：本轮先做 F0。整数 ABFT 和影子奇偶校验做完后，用门级注错测出浮点通路的 SDC 占比，再决定要不要做 F1。理由是端侧 NPU 的主要推理路径是 int8。浮点通路只在浮点 matmul 时工作，做整数 matmul 时浮点通路里的错误大多被屏蔽。这个判断需要你确认（Q3）。

### 4.5 面积汇总

DC W-2024.09-SP1，TSMC12 ffgnp0p88v0c，`compile`（没有用 compile_ultra），IO 约束 0.2 ns。探测脚本和报告在 `tools/area_probe/`（`mt_shadow_probe.sv`、`abft_int_probe.sv`，结果在 `mt_sh/`、`abft/`）。全芯片按 618,024 µm² 算，VME 按 343,000 µm² 算。

| 机制 | 面积（µm²） | 占全芯片 | 占 VME | 来源 |
|---|---|---|---|---|
| 影子奇偶校验，每字节 1 位，不折叠（`mt_sh0`） | 44,048 | 7.13% | 12.8% | DC 实测，slack 0.33 |
| 影子奇偶校验，每 subtile 折成 1 bit 再读（`mt_sh1`） | 36,054 | 5.83% | 10.5% | DC 实测，slack 0.30 |
| 阵列内奇偶校验，每字节 1 位 | ≤ 约 26,000 | ≤ 约 4.2% | ≤ 约 7.6% | **估算**（见下） |
| 整数 ABFT（多打一拍） | 7,574 | 1.23% | 2.2% | DC 实测（2 ns） |
| 整数 ABFT（1 GHz 单拍） | 9,632 | 1.56% | 2.8% | DC 实测 |
| 浮点 ABFT F1 / F2 | 约 1.5～2.5% / 约 4～6% | | | 粗估，未综合 |

**影子阵列为什么贵**：
- 4 Kbit 奇偶 FF 只有 3,171 µm²（正好是主阵列 FF 的 1/8）。其余约 33～41k 是组合逻辑。
- 大头是**独立的一套写使能译码**：256 个 subtile × 16 字节 = 4096 个使能，每个都要从 16 个写口里比较地址选出来。这套译码的规模和数据位宽无关，所以影子阵列虽然只有主阵列 1/8 宽，译码却是全量的。
- 折叠只能省掉读网络（约 8k），省不掉写译码。
- 这正是"检测地址译码错误"的代价：要独立译码，就得付一整套译码的面积。

**阵列内奇偶校验的估算（上界）**：
- `mt_par` 探测在 1 GHz 下跑了 55 分钟没有收敛，已经停掉（`mt_par/NOTE.txt`），所以这一行是按比例估的。
- 读写数据网络加宽 1/8：主阵列网络的 142k 里包括使能译码，不随位宽变，所以按 1/8 算是上界，≤ 17.8k。
- 加上 FF 3.2k、`zvt_mt_reg` 里的使能选择约 1.1k、奇偶生成和检查的异或树约 4k（参考 `mt_sh0` 和 `mt_sh1` 的差）。
- 合计 ≤ 约 26k。

**为什么不考虑"每 32 位 1 位"**：
- tile 有两种按字节的部分写：EEW8 非转置写一个字里的 4 个字节，EEW8 转置写 4 个字里各 1 个字节。
- 不论怎样分组，总有一种模式只写到组里的部分字节。这时新的奇偶位要依赖没写的旧字节，必须读改写。
- 每字节 1 位是唯一不需要读改写的粒度。

**VME 合计（按推荐的组合）**：

| 组合 | 占全芯片 | 占 VME | 改上游 |
|---|---|---|---|
| 影子奇偶（折叠）+ 整数 ABFT | 约 7.1% | 约 12.7% | 少（新文件 + 薄钩子） |
| 阵列内奇偶（每字节）+ 整数 ABFT | ≤ 约 5.4% | ≤ 约 9.8% | 多（`zvt_mt.sv`、`zvt_mt_reg.sv` 和所有读写端口的位宽） |
| 只做整数 ABFT | 约 1.2% | 约 2.2% | 少 |

再加上 RVV 指令冗余约 3%，全芯片的总开销在 8～10% 左右。**和"低开销"的定位比，tile 奇偶校验是最贵的一项**，需要你权衡（Q1、Q2）。

**还没试过的降本办法**（下一轮可以探测）：
- 影子阵列复用主阵列的写使能译码：需要给 `zvt_mt` 加一个输出端口，算小改上游。这样就失去了写地址译码错误的检测，但可能省下一半以上的面积。
- 只保护累加器 tile（`dst_index` 对应的 4 组），不保护只做搬运用的 tile。是否可行取决于负载怎样使用 tile。官方测试太少，判断不了。

### 4.6 推荐组合与侵入性

**推荐**：整数 ABFT（4.3）+ tile 奇偶校验（4.2，影子阵列还是阵列内由 Q1 决定）+ 浮点 F0（4.4）。VME 的错误一律报为 DETECTED，经 5.4 的通路上报。

下表按影子阵列方案列出。如果选阵列内方案，还要加上 `zvt_mt.sv`、`zvt_mt_reg.sv`，以及 `zvt_ctrl.sv`、`zvt_pe_block.sv` 里读写端口的位宽改动。

| 文件 | 类型 | 改动 |
|---|---|---|
| `hdl/verilog/rvv/design/Zvt/zvt_ft.sv` | 新增 | 影子奇偶阵列、ABFT、`vmeRt` 扣留、错误事件和计数器、RTL 注错（`VME_FT_INJECT_ON`） |
| `zvt.sv` | 上游 | `` `ifdef VME_FT_ON ``：例化 `zvt_ft`；`vmeRtVld` 经扣留逻辑输出；新增错误输出端口 |
| `zvt_pe_block.sv`、`zvt_pe_array.sv` | 上游 | `` `ifdef `` 内引出加法器的输入/输出和有效位，每个文件约 10 行 |
| `rvv_backend.sv`、`RvvCore.sv` | 上游（已有 RVV FT 钩子） | 把 VME 错误合并进 trap |
| `RvvCore.scala`、两个 BUILD | 上游 | 各 +1 行文件列表（和 RVV FT 相同） |

**宏（建议，待确认 Q6）**：`VME_FT_ON`（总开关）、`VME_FT_PARITY`、`VME_FT_ABFT`（两种机制可以单独开，方便做消融实验）、`VME_FT_INJECT_ON`。和 `RVV_FT_*` 完全独立。

## 5. RVV/VME 共用的错误上报

### 5.1 现状

链路是 FT 事件 → `RvvCore.sv` 的 `trap_valid_o`（rob_tag + 哨兵 mtval）→ `FaultManager.rvv_fault` → RetirementBuffer 按 rob_tag 找到这条指令 → `trapRetired` → 跳到 mtvec → `ebreak` → `io.fault`。

03 §3.6 停在最后一步：`ebreak` 是 `isFency()`，`lsuActive` 时 Decode 不让它发射（`Decode.scala:509`）。而 LSU 一直 active：
- `Lsu.scala:2168`：`clearFaultState = slotsIdle && (isFlushing || pipelineFlush)`，要等事务槽空闲。
- `Lsu.scala:2028`：`slot.io.active` 只有在所有 cell 都是 `DONE` 时才为 0。
- 那条更年轻的 `vse8.v` 的 cell 停在 `W_DATA`，等 RVV 送数据，而 RVV 已经被 flush，数据永远不会来。

### 5.2 VME 也有同样的问题

读代码确认（`Lsu.scala:2040-2047`、`SCore.scala:271-272`）：
- tile store 的数据（`vme2lsu`）和 RVV store 的数据（`rvv2lsu`）进的是**同一个 LsuSlot**，都是 `W_DATA` 状态等数据。区别只在 ready 取决于 `isVme`。
- 所以 RVV 或 VME 任何一方发出异步 trap 时，只要标量 LSU 里有一条更年轻的向量或 tile store 在等数据，就会卡死。
- **load 方向还有一个隐患**（推断，没有用仿真确认）：被 flush 的向量/tile load 如果在 flush 之后才把数据写回（`lsu2rvv` / `lsu2vme`），这份数据会留在 RVV/VME 侧已经清空的 FIFO 里，后面的 load 会配错对。`Decode.scala:684-688` 关于 vill 串行化的注释描述的就是 RVV 这一侧的这种现象。

上游目前不会碰到这个问题，因为它的异步 trap 只来自 `RvvFrontEnd`（vill 等），而 Decode 已经用串行化提前把这种情况拦住了。**FT 是第一个在执行中途从后端产生异步 trap 的来源**。

### 5.3 修复方向评估

| 方向 | 改动 | 能否解决 | 评价 |
|---|---|---|---|
| **(a) LsuSlot 在 flush 时放弃向量/tile 事务** | 只改 `Lsu.scala`（Chisel） | store 和 load、RVV 和 VME 都能解决 | **推荐** |
| (b) RVV→LSU 加"取消"握手 | `RvvInterface.scala`、`RvvCore.scala`、`Lsu.scala`、`RvvCore.sv` | 能解决 | LSU 同样要改，改动面比 (a) 大，没有额外收益 |
| (b′) 只改 Verilog："假数据排空" | `RvvCore.sv`：trap 后在 `rvv2lsu` 上送全掩码的数据（mask 全 0，cell 走 `doInvalidate`，不写内存），直到 ready 变低 | 只能解决 RVV 的 unit-stride store | VME store 没有 mask（`isVmeInst` 时 mask 恒为真），会把垃圾写进内存；indexed store 要 idx；解决不了 load 的残留数据。这是在滥用接口语义，不推荐 |
| (c) 走 ROB 的精确 trap（`trap_flag`） | — | 不能 | 更年轻的 store 照样卡在 LSU 里；而且标量侧根本不读 `Rob2Rt.trap_flag`（只在 `RvvInterface.scala` 里声明了），trap 到不了标量核 |
| (d) 推迟 trap，直到没有更年轻的访存在途 | Verilog | 不能 | 标量 LSU 可能比 RVV 后端更早收到这条向量 store（前端队列），Verilog 一侧看不到 LSU 里有什么 |
| (e) 像 vill 那样在 Decode 里串行化 | `Decode.scala` | 能解决 | 所有向量访存都要等 RVV 排空，性能代价大 |

**为什么必须改 Chisel**：卡住的是 LsuSlot 的状态机，只有 Chisel 能改它。RVV/VME 一侧没有任何合法的办法让 LSU 放弃一个已经接收的事务（接口里没有取消），也无法从 Verilog 侧可靠地避开这个竞争（(c)、(d) 不成立）。只改 Verilog 的 (b′) 只能修好一部分，还会引入内存写垃圾的问题。

**(a) 的做法（初稿，实现时细化）**：
1. `pipelineFlush` 或 `isFlushing` 时，槽里处于 `W_DATA` 的 cell 直接转 `DONE`，不发总线事务。已经发出去的（`W_RESP`）照常收完响应，txid 分配器不受影响。
2. flush 之后不再发出 `vectorWriteback` / `vmeWriteback`，直接丢弃。
3. 这样 `slot.io.active` 会降下来，`clearFaultState` 成立，`isFlushing` 清掉，`ebreak` 就能发射。

改动估计在 `LsuSlot` 里 20～40 行，只在一个文件里。

**要说清楚的语义问题**：
- 本核的 store 在退休之前就写内存（RetirementBuffer 要等 `storeComplete` 才让 store 退休）。所以被 flush 的年轻 store 如果是多拍的（LMUL>1），可能已经写了一部分内存。
- 对 FT trap 来说这是可以接受的：重放耗尽或 VME 检测到错误都是不可恢复的，上位机看到 `io.fault` 后整段重跑。论文里要写明"FT trap 之后内存状态不精确"。
- (a) 不改变 LSU 自身访存出错（`isFaulted`）的已有处理。

**风险**：
- `Lsu.scala`（LsuV3）是上游最活跃的 Chisel 文件，以后 rebase 时容易冲突，但冲突只局限在这一处。
- 这个修复本身和 FT 无关，是"标量 LSU 不能在协处理器事务进行中被冲刷"的健壮性问题，**可以考虑单独给上游提 PR**（Q4）。

**验证计划**：
1. `rvv_arithmetic_ft_trap` 通过，`io.fault` 拉高，mcause=2，mtval 为哨兵值。
2. VME 的对应测试：注错让 ABFT 报错，并且后面紧跟一条 tile store。
3. 官方回归：`rvv_load_store`（含 fault 用例）、`vme_test`、`lsu_fault_cases`、`core_mini_axi` 的 LSU 相关测试，FT 关时结果必须与上游一致。

### 5.4 VME 复用这条上报通路

1. **事件源**：`zvt_ft.sv` 在 ABFT 不一致或奇偶校验错误时产生事件，附带出错指令的 rob_tag（`VME_RTCMD_t.rob_tag`，在 rtCmd 入队时就有）。
2. **扣住 `vmeRt`**：这条指令的检查没出结果之前不发 `vmeRt`。检查通过就放行；出错就不发 `vmeRt`，改发 trap。这样 rob_tag 对应的 RetirementBuffer entry 还没退休，可以被 trap 精确命中。
   - 奇偶校验错误：C_old 读出错时，归到正在读它的那条 matmul；store 或 `vtmv.v.t` 读出错时，归到这条 move/store 自己。
3. **合并**：在 `RvvCore.sv` 里和 RVV FT trap、前端 trap 一起合并到 `trap_valid_o`，每次 flush 只报一个。同一拍两个都有时谁优先，实现时定（倾向于 RVV FT 优先，因为另一个会被 flush 掉或者再次被检测到）。
4. **mtval 哨兵**：建议 VME 用一个和 RVV（`0xFFFF_FF87`）不同的保留编码，上位机就能区分错误来源（Q8）。
5. **flush**：`trap_flush_rvv` 本来就会清空 VME 的 FIFO 和流水线。tile 内容不回滚，本来也是不可恢复错误。
6. **前提**：5.3 的 (a) 先修好，否则 trap 之后的 tile store 一样会卡住。

**L1 仿真观测**（不依赖软件）：
- `zvt_ft.sv` 在 `` `ifndef SYNTHESIS `` 下打印统计：检查次数、ABFT 不一致次数、奇偶校验错误次数、trap 次数。
- 注错框架直接读这些事件，用于 DETECTED 的分类。

## 6. 需要你拍板的问题

| # | 问题 | 选项 | 我的倾向 |
|---|---|---|---|
| Q1 | tile 奇偶校验用哪种实现 | A. 影子阵列，独立译码：不改 `zvt_mt`，5.8～7.1%，能检测地址译码错误<br>B. 阵列内每字节奇偶：≤ 约 4.2%，要改 `zvt_mt`、`zvt_mt_reg` 和端口位宽<br>C. 影子阵列复用主阵列的写使能：`zvt_mt` 加一个输出口，面积待测，不能检测写地址错误<br>D. 不做 tile 奇偶校验，只做 ABFT | 先探测 C 的面积再定。如果 C 在 3% 以下就选 C，否则在 A 和 B 之间按"少改上游"还是"低开销"哪个优先来定 |
| Q2 | 全芯片总开销（RVV 约 3% + VME 约 5～7%）在 8～10%，"低开销"能不能这样表述 | 接受，按"相对 VME / 相对全芯片"两个口径报；或者压低 tile 保护的范围（只保护累加器 tile 等） | 两个口径都报。ABFT 那 1.2% 是亮点，tile 保护作为覆盖率和面积的权衡单独讨论 |
| Q3 | 浮点通路本轮先不保护（F0），等注错数据再定 | F0 / F1 / F2 | F0 |
| Q4 | 修 trap 卡死要改 `Lsu.scala`（方向 a），可以吗？要不要另外给上游提 PR？ | 改 / 不改（那样 FT trap 就停在 handler 里，只能用 L1 观测） | 改；PR 等你决定 |
| Q5 | VME 的负载：官方只有 `vme_test` 里的单元测试，每个用例只做一次 16×16 乘加 | A. 只用 `vme_test`（覆盖率统计的代表性弱）<br>B. 放宽"只用官方测试"，写一个基于 VME 的 GEMM/conv 负载<br>C. 等上游出 VME kernel | 主结果先用 A，B 由你决定 |
| Q6 | 宏 | `VME_FT_ON`、`VME_FT_PARITY`、`VME_FT_ABFT`、`VME_FT_INJECT_ON` | 如表 |
| Q7 | FT trap 之后内存状态不精确（被 flush 的多拍 store 可能已经写了一部分）。论文里按"不可恢复错误，上位机整段重跑"处理 | 接受 / 要求精确 | 接受 |
| Q8 | VME 用一个和 RVV（`0xFFFF_FF87`）不同的 mtval 哨兵值 | 分开 / 共用 | 分开 |
| Q9 | §1 新加的 3 个测试目标还没提交。要不要现在单独提交一个"VmeCoreMiniAxi 上的 RVV FT 回归"提交，还是等 VME FT 一起提交 | 现在 / 一起 | 一起，按你"只保留有意义的提交"的习惯 |
| Q10 | 02 文档里的 Barbirotta 条目和 SITR 条目，按 §3.5 原地修正吗 | 修正 / 不动 | 修正，删掉 SITR |

---

## 7. 下一步（等 Q1～Q5 确定后）

1. 方向 (a)：修 `Lsu.scala`，让 `rvv_arithmetic_ft_trap` 通过（M5 收尾）。
2. `zvt_ft.sv`：先做整数 ABFT 和 `vmeRt` 扣留，用 RTL 注错跑 `vme_matmul_int8/int16`，验证检测和上报。
3. tile 奇偶校验（按 Q1 的结果）。
4. 对实现做综合，按两个口径填面积表；用 vme_test 测性能开销。
5. 进入门级注错（第 1 层）。
