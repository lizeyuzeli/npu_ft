# fault-tolerance-v3-plan 总览

## 课题定位

在 CoralNPU（RISC-V 标量核 + RVV 1.0 向量扩展 + 自研 VME 矩阵扩展）上实现低开销容错，目标是把 SDC（Silent Data Corruption）变成 DUE（Detected Unrecoverable Error）或 CORRECTED，最终通过门级注错量化覆盖率和开销。

## v3 阶段划分

| 阶段 | 文档 | 职责 | 当前状态 |
|---|---|---|---|
| 回顾 | [01-v2-review.md](01-v2-review.md) | v2 的结论、遗留问题、为什么要推倒重来 | ✅ 完成（R1） |
| 方向 | [02-direction-discussion.md](02-direction-discussion.md) | v3 的机制选择、开销目标、验证策略 | ✅ 完成（R6） |
| RVV 实现 | [03-rvv-implementation.md](03-rvv-implementation.md) | RVV 冗余比较 + 重放纠错的功能级实现和 RTL 注错验证 | ✅ 完成（M1-M5） |
| VME 方案 | [04-vme-ft-design.md](04-vme-ft-design.md) | VME 容错的方案讨论、调研、决策记录、交给 05 的输入 | ✅ 完成（R2，2026-11-26） |
| VME 实现 | [05-vme-implementation.md](05-vme-implementation.md) | VME 容错的功能级实现和 RTL 注错验证，分两阶段 | 第一阶段已签收（2026-11-29，`57de0885`，原测试提交 `ed5cd672`），第二阶段待定 |
| 06 以后 | 待定 | 综合、功耗、性能、网表注错、存储层、LSU trap 修复 | 📋 候选 |

## 文档更新规则

- **轮次**：在文件内原地修订（R1、R2、M1、M5…），修订记录写在文件开头的表格里。
- **决策记录**：讨论结果、取舍理由、已知风险都写在对应文档里，作为后续的输入。
- **代码改动不在这里**：只跟踪方案和验证数据，代码提交走正常的 git 流程。

## 各文档职责

### 01-v2-review.md
- **跟踪**：v2 做了什么、遗留了什么问题、为什么推倒。
- **不跟踪**：v3 的具体方案（那是 02 以后的事）。

### 02-direction-discussion.md
- **跟踪**：RVV 和 VME 分别用什么机制、为什么这样选、开销目标、验证策略（RTL 注错 → 门级注错）。
- **不跟踪**：具体实现细节（那是 03/05 的事）。

### 03-rvv-implementation.md
- **跟踪**：RVV FT 的实现记录（M1-M5）、RTL 注错结果、已知问题。
- **不跟踪**：方向讨论（已在 02 定）、VME 的事（那是 04/05）。

### 04-vme-ft-design.md
- **跟踪**：VME 容错方案的讨论、决策记录、调研结论、R1 和 R2 的面积探测数据、交给 05 的输入（实现拆分、验证项）。
- **不跟踪**：具体实现过程（那是 05 的事）、综合/功耗/性能（那是 06 的事）。
- **R1 → R2 的变化**：主方案从"ABFT + tile 奇偶"改为"交错时间复制 + 部分提交 + RS 当 ROB"。

### [05-vme-implementation.md](05-vme-implementation.md)
- **跟踪**：VME FT 的实现记录、第一阶段（核心机制）和第二阶段（写入校验、RS 奇偶）各自的 RTL 注错结果。
- **不跟踪**：方案讨论（已在 04 定）、综合/网表注错（那是 06 的事）。

### rebase-log.md
跟踪 rebase 到上游 main 的记录：日期、commit、冲突文件、解决方式。

### tools/
- `tools/area_probe/`：DC 面积探测脚本（`abft_int_probe.sv`、`mt_shadow_probe.sv`）和报告。
- `tools/ft_compile`：FT 构建包装脚本（见 03 M1）。

### test-data/（仓库根目录）
- `test-data/rvv/`：03 的 RTL 注错结果（FI 覆盖率表、CSV）。
- `test-data/vme/`：已有的 VME GEMM 负载实测数据（kernel patch 还没归档）。

## 通用约定

1. **宏传递**：通过构建参数（`--define`）传入，不在上游 `.svh` 里加 `define`。
2. **面积口径**：按"占 VME / 占全芯片"两个口径报。全芯片按 618,024 µm²（VmeCoreMiniAxi DC 综合）算，VME 按 343,000 µm² 算。
3. **轮次标记**：R=revision（方案讨论），M=milestone（实现）。
4. **注错分类**：MASKED、CORRECTED、DETECTED、SDC，按 Leveugle 2009 的定义。

## 一页结论（截至 04 R2，2026-11-26）

### RVV（03 完成）
- **机制**：指令级冗余比较（EVEN/ODD）+ 重放纠错，replay_mem 2.4 Kbit。
- **开销**：约 2.6% 全芯片面积（replay_mem + 控制），性能开销 ≤2%（实测负载）。
- **覆盖率**：VEU 通路约 86%、VRF 约 5%，共约 20% 全芯片（按面积）。
- **验证**：Verilator 和 VCS 上通过 rvv_arithmetic（25 用例）和 tfmicro（6 模型）；RTL 注错 FI 覆盖率 97.9%（4000 次采样，e=1%）。

### VME（04 R2 方案确定）
- **机制**：按组交错的时间复制（g0p0 g0p1 g1p0 g1p1…）+ 按元素部分提交 + RS 当 ROB 回滚。
- **开销**（估算，06 实测）：
  - 第一阶段（核心）：约 1% 全芯片（dupBuf 2.4 Kbit + done 掩码 256 bit + RS 加深到 12 + 控制）；
  - 第二阶段（写入校验 + RS 奇偶）：约 0.9%；
  - 合计约 2% 全芯片。
- **覆盖率**：PE 阵列 161k、读网络 70k、写网络 70k（第二阶段）、发射/控制逻辑，按面积约 88% VME。
- **不覆盖**：MT 存储寄存器 34k、FT 自身、永久故障（延后到 06）。
- **性能**（估算）：LSU 受限负载约 0；PE 打满时 8 拍/条（原设计 4 拍）；每条退休约晚 7 拍；每次回滚约 30 拍。
- **验证**：05 做 RTL 注错（vme_test 20 用例 + 定向测试），trap 只在 L1 观测（LSU trap 修复延后到 06）。

### 延后到 06
- 存储层（MT 寄存器）：影子奇偶 / 阵列内奇偶 / 运行校验和三选一，R1 面积数据见 04 附录。
- LSU trap 卡死修复（改 Lsu.scala）。
- 综合、功耗、性能实测、网表注错。
