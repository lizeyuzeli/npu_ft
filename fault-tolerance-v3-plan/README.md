# fault-tolerance-v3 规划

基于 CoralNPU 的容错设计（硕士毕业课题）第三版。v3 分支从 main@`9d0a8dcf` 开出，
目标是在新的 main（新增 VME/Zvt、ROB 16 项、rob_tag、CoralFlow 等）上，
**批判性地继承** v2（`fault-tolerance-v2`，tip `631c3ae1`）的工作。

## 文档索引

| 文件 | 内容 | 状态 |
|---|---|---|
| [01-v2-review.md](01-v2-review.md) | v2 回顾与 main 变化汇总：v2 做了什么（技术分析）+ main 变了什么（与 FT 相关的部分）+ 迁移难度评估 | 完成（2026-11-21，整合原 01/02/03） |
| [02-direction-discussion.md](02-direction-discussion.md) | 第 1 步方向讨论。R1～R5 五轮讨论：低开销定位、replay_mem DC 实测、零开销插空模式、宏定义、上报路径、流控分析 | R5，待确认第 1 步收尾（2026-11-21） |
| [rebase-log.md](rebase-log.md) | 专门记录每次与官方 main 同步的 rebase 过程（冲突解决、验证结果），不参与整体开发流程序号 | 当前 base: f385a31b |
| [tools/](tools/) | 面积解析脚本（area.py / group.py）和 DC 面积探测（area_probe/：replay_mem 结构��比、比较器、按真实位宽综合） | — |
| [03-rvv-implementation.md](03-rvv-implementation.md) | RVV 容错的实现和功能验证记录 | 完成（2026-11-21）：FULL 模式，复制/比较/重放已验证；trap 最后一段推迟到 VME 阶段；OPPORTUNISTIC 不做 |
| [04-vme-ft-design.md](04-vme-ft-design.md) | VME 容错：联网调研 + 方案讨论（含 RVV/VME 共用的 trap 上报修复） | R1（2026-11-22），待确认 §6 的 Q1～Q10 |

## 一页结论（截至 R5）

**定位：NPU 低开销容错。** 基准论文（Barbirotta 2024）只是参考之一，指标只做粗估，最终以论证低开销为准。

**RVV 指令冗余方案定稿：**
- copy-2 和重放统一经 replay_mem 发射，只用 dispatch 当拍不用的 push 端口，不直接阻塞 dispatch。
- replay_mem 采用"3 写 4 读"，实测约 2.6% 芯片面积（按 12nm 真实位宽）。
- 默认用 FULL 模式；OPPORTUNISTIC（插空）作为实验对照，放弃窗口内未发 copy-2，不重放时零开销。
- 保留完整比较，trap 重试、小容量池、签名比较都不做。

**宏定义：** `RVV_FT_ON` / `RVV_FT_MODE` / `RVV_FT_WATERMARK` / `RVV_FT_RETRY_MAX` / `RVV_FT_INJECT_ON`（RTL 注错备用）。VME 的宏用 `VME_FT_` 前缀。

**上报路径：** 完全复用现有通路（ROB → RvvCore trap → 标量异常 mcause=2 → ebreak → io.fault），不改 Chisel。

**v2 最值得继承的是方法论，不是代码。** FI 框架的划分规则、下降沿注入、正反对照、审计工具、hang 归因，以及"每个检测器都配一个故意失败模式"的纪律，都可以原样保留。RTL 和 Chisel 代码因为 main 的变化，基本都要按新结构重写。

**main 带来的新机会：**
- 仓库里现成的 SECDED(39,32) 实现和金模型，可以用于 VRF / tile ECC。
- OpenROAD/ASAP7 开源物理流程，可以量化开销，也可以作为网表级 SET 注入的切入点。
- UVM 三方协同仿真加 ISG 随机指令流，可以证明 FT 在架构上不可见。
- 矩阵乘 PE 阵列适合做 ABFT，可能成为论文的创新点。

## 关键版本锚点

| 名称 | 提交 | 日期 |
|---|---|---|
| v1 `zeyu/fault-tolerance` | `af20a24f`（base `7d0ae209`） | 2026-06-07 |
| v2 分叉点（main） | `1126ed3f` | 2026-07-31 |
| v2 tip | `631c3ae1` | 2026-08-24 |
| v3 起点 = 当前 main | `9d0a8dcf` | 2026-11（最新提交日期 11-13） |

