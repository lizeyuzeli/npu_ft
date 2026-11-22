# 04 · 方向讨论（第 1 步）：分析与结论

> 三步流程里的第 1 步（讨论 → 调研+方案 → 开发流程 / agent flow）。所有讨论轮次都在本文件内修订，不另开文件。
> 标 〔待核实〕 的文献结论来自已有知识，第 2 步联网逐条核对，核对前不进论文。
> 课题名：**NPU 低开销容错**。亮点是**低开销**（面积、性能），容错能力满足一定指标即可。
> 工程约束：**RVV 指令冗余要尽快完成，开发重点留给 VME 容错**；**不碰 Chisel 通路**；尽量少改上游文件。

## 修订记录

| 轮次 | 日期 | 主要变化 |
|---|---|---|
| R1 | 2026-11-19 | 针对 6 个问题的初步分析 |
| R2 | 2026-11-20 | 以"低开销"统领；撤回强制空间配对；VME 做专项；LSU、锁步不做；只用官方负载；门级统一抽样；改用 VCS |
| R3 | 2026-11-20 | DC 实测 replay 存储和比较器；trap 重试、小容量池不做；撤回签名比较；配置改用宏；只改 Verilog 的检错上报 |
| R4 | 2026-11-20 | ① 指标只做粗估，基准论文只是参考之一（1）。② **copy-2 发射方式改为"统一经 replay_mem、优先级低于 dispatch"**（沿用 v2 的思路），并用真实位宽重测面积；**重新定义插空模式：不重放时零性能开销**（2.2、2.3）。③ 宏精简为 4 个，统一加 `RVV_FT_` 前缀，注错自测改由测试平台完成（2.4）。④ 上报完全复用现有通路，**上位机通过 `io.fault` 感知**（2.5）。⑤ Z01X 的 license 暂时拿不到 |
| R5 | 2026-11-21 | ① Verilator/Yosys 在 Bazel 依赖里可自动安装，12nm nldm 库已提供；默认 MODE=FULL；部分复制改为"放弃窗口内未发 copy-2"（3.1）。② replay_mem 3 写 4 读不阻塞，每类单元 1 读口足够（3.2）。③ 宏定为 4 个 + `RVV_FT_INJECT_ON`（RTL 注错备用）（3.3）。④ 文档重组：01～03 合并为 `01-v2-review.md`，下一步 `03-rvv-implementation.md`；新增 `rebase-log.md` 专记 rebase（3.4）|

---

## 0. 事实依据

### 0.1 基准论文：Barbirotta et al., IEEE OJCS 2024（Vitruvius+ VPU）

〔R4〕**定位：参考文献之一，不是对标对象。** 它只覆盖 RVV 处理单元，而且是 VLEN=16384 的服务器级 VPU；我们是端侧 NPU，VLEN=128，还有 VME。
它的思路只借鉴到 RVV 执行单元那部分。

| 方面 | 论文做法 |
|---|---|
| 复制 | 前端把所有算术指令复制成 EVEN/ODD 两份，纯时间冗余；访存指令不复制 |
| 比较 | 比较 8 bit ECC 签名，因为 VLEN 太大 |
| 恢复 | 借助寄存器重命名做 kill-and-retry，源操作数还在物理寄存器里，重做不用另存 |
| 开销 | 面积 +7.5%（相对 VPU）；最坏执行时间 2× |
| 注错 | RTL，只注 lane 0、只注每个信号的第 0 位；ISA 级负载 |
| 结果 | 漏检错误 −75%；挂死比例不变 |

### 0.2 VmeCoreMiniAxi 综合面积（DC W-2024.09-SP1，TSMC 12nm，1 GHz，compile_ultra，ffgnp0p88v0c 快角）

总面积 618,024 µm²；组合逻辑 456,842，时序单元 113,275，宏单元 47,908。

| 功能域 | 占芯片面积 | 占组合逻辑面积 | 占时序单元面积 |
|---|---|---|---|
| **VME** | **55.5%** | 62.6% | 50.3% |
| 其中 tile 读写选择网络 | 23.0% | — | — |
| 其中 tile 存储触发器（32 Kbit） | 5.6% | — | 22.4% |
| **指令冗余可覆盖的执行单元**（alu / mulmac / div / falu） | **8.9%** | 9.1% | 11.8% |
| 上述单元的 RS | 3.4% | 2.4% | 8.7% |
| ROB | 2.1% | 2.1% | 3.1% |
| VRF | 1.5% | 1.4% | 2.8% |
| 前端队列 + decode | 1.6% | 1.4% | 2.9% |
| 标量核 SCore（其中 LsuV3 占 10.8%） | 14.6% | 16.8% | 11.8% |
| Banked DTCM（SRAM 宏） | 6.3% | — | — |

解析脚本在 `tools/area.py` 和 `tools/group.py`。

### 0.3 仓库与环境

- 执行单元：ALU 的 RS 每拍弹出最多 2 条，分别送到 unit0 和 unit1，cmp 类只能走 unit0；MUL/MAC、FALU 各 2 个实例；DIV、PMTRDT、VME 各 1 个。
- `sw/` 里没有任何 kernel 用到 VME。
- 本机有 VCS、DC（W-2024.09-SP1，各 99 份 license）和 PrimeTime 2024；没有 Verilator 和 Yosys。
- license 服务注意事项：如果 DC 或 VCS 报 "not enabled"，先检查 `/var/tmp/locksnpslmd` 是不是被别的用户的锁文件占着。

### 0.4 后续轮次补充的事实

| 项 | 事实 | 影响 |
|---|---|---|
| 〔R2〕Z01X 2018 | 安装包已下载，没有 license；〔R4〕**暂时拿不到** | 主线只用 VCS（6.2） |
| 〔R2〕SRAM 仿真模型 | DTCM 用的宏在 memory compiler 目录下已有 Verilog 模型 | 门级仿真不缺 SRAM 模型 |
| 〔R2〕官方 VME 测试 | `vme_matmul_{int8,int16,bf16,fp32}`、transpose、load_store 等，16×16 tile 规模 | VME 负载 |
| 〔R3〕RS 的实现 | 每个单元的 RS 就是一个 `multi_fifo`（`CHAOS_PUSH=1`），uop 一发射 payload 就丢了；ROB 只保存 `DP2ROB_t`，不保存操作数 | 重做一条 uop 只能靠 replay_mem |
| 〔R3〕现有 RVV→标量异常通路 | `RvvCore.sv` 的 `trap_valid_o / trap_data_o` → `SCore` 的 `fault_manager.rvv_fault`，标量侧按 rob_tag 匹配；mcause 写死为 2，mepc 取 `trap.bits.pc`，mtval 取还原出的指令编码；目前只有 `RvvFrontEnd` 在驱动 | 只改 Verilog 就能上报（2.5） |
| 〔R3〕标准单元模型 | `vlg` 里 1143 个单元、4 个 UDP、2160 个 specify 块 | 门级仿真用 VCS |
| 〔R4〕**dispatch 是严格按序的** | `rvv_backend_dispatch_ctrl.sv`：`rs_ready[i] = rs_ready[i-1] & rs_ready_xxx[i]`，任何一个槽位进不了 RS，它后面的槽位在这一拍全部停住；RS 的 `pushRdy[k]` 要求至少还有 k+1 个空位 | 决定了 copy-2 不能和 dispatch 抢端口（2.2） |
| 〔R4〕**v2 的 copy-2 重注方式** | `freeslot = rs_ready & ~rs_valid`：只用 dispatch 当拍**没占用**的 push 端口，优先级低于 dispatch | 你的理解是对的（2.2） |
| 〔R4〕**RS payload 的真实位宽**（main，用 VCS 的 `$bits` 算出，脚本 `tools/area_probe/rs_width_probe.sv`） | ALU 565、MUL 407、DIV 284、FALU 502 bit；所以 replay_mem 位宽是 565（R3 估的是 596） | 面积按真实位宽重测（2.2） |
| 〔R4〕**上位机感知错误的现成路径** | 官方 crt（`toolchain/crt/coralnpu_start.S`）把 mtvec 设成 `coralnpu_exception_handler`，它的默认实现只有一条 `ebreak`；`ebreak` 会拉高 Core 顶层的 `io.fault` 引脚；测试 fixture 就是靠 `io_fault` 判定失败的（`wait_for_fault`） | **上位机不需要任何额外软件就能感知到错误**（2.5） |

---

## 1. 课题定位：低开销统领一切取舍

**"低开销"的含义**：无故障路径（绝大多数时间）的开销尽量接近 0，出错路径可以慢。

| 维度 | 判据 |
|---|---|
| 面积 | 不复制执行单元；新增的存储和选择逻辑尽量少 |
| 性能 | 插空复制：copy-2 只占空闲资源；不需要重放时零开销 |
| 侵入性 | 只改 Verilog，不碰 Chisel；尽量用新增文件加薄钩子 |

**覆盖口径**：按功能域报告。指令冗余域（约 12.3%）加 VME 域（55.5%），约 68% 的芯片面积有对应机制；标量核和 DTCM 划为范围外，注错时照样统计。

**〔R4〕指标：只做量级粗估，不预设硬目标。** 第 2 步综合多篇文献再定比较口径，最终以"把低开销论证清楚"为准。

| 项 | 量级（粗估） | 依据 |
|---|---|---|
| RVV 指令冗余的面积 | 全芯片约 3% | replay_mem 实测约 2.6%（2.2），加上比较和控制逻辑 |
| VME 专项的面积 | 待第 2 步 | |
| 插空模式的性能开销 | 不需要重放时接近 0 | 2.3 的定义 |
| 容错能力 | 各保护域内 SDC 明显下降 | 具体数值由注错结果说话 |

---

## 2. RVV 指令冗余

### 2.1 空间配对与硬错误（R2 撤回，保持）

硬错误检出不是设计目标，不强制空间配对。

### 2.2 〔R4 重写〕copy-2 怎么发射，replay_mem 怎么做

**为什么需要 replay_mem（R3 结论保留）**：RS 只是做流控的 FIFO，uop 一发射 payload 就丢了，ROB 也不存操作数。CoralNPU 没有寄存器重命名，重做只能靠另存的 payload。trap 重试要改 3 个以上的 Chisel 文件，小容量池会丢覆盖率，这两种都不做。

**〔R4〕你说得对：R3 提的"copy-2 直接从 dispatch 推入"会阻塞。** 核对代码（0.4）后：
- dispatch 是**严格按序**的。如果 copy-2 要和 copy-1 在同一拍推入同一个 RS，这个 RS 就必须多出一个空位和一个空闲端口。拿不到的话，在 FULL 模式下这个槽位以及它后面的所有槽位这一拍都发不出去，**这就是阻塞**。
- 只有"拿不到就不复制"的插空模式不会阻塞，但这时 FULL 模式又必须另外准备一条延后发射的路径，而那条路径还是要读 replay_mem。

**〔R4〕结论：统一经 replay_mem 发射，沿用 v2 的思路。**
- 所有 FT uop 在 dispatch 时把 payload 写进 replay_mem。
- **copy-2 和重试都从 replay_mem 发出，而且只用 dispatch 当拍没占用的 push 端口**（`freeslot`），优先级始终低于 dispatch，**直接阻塞为零**。
- replay_mem 相当于一个"复制出来的 RS"，解开了 copy-2 和 dispatch 之间的依赖。

需要说清楚的是，**间接影响还在**：copy-2 进了 RS 会占用容量，后面的 dispatch 可能因此更早遇到 RS 满；ROB entry 要等 copy-2 回来才能退休，ROB 可能更早被填满。在 FULL 模式下，这是把单元工作量翻倍的固有代价，无法避免；插空模式就是为了消除它（2.3）。

**面积（〔R4〕按真实位宽重测，DC compile，TSMC12，1 GHz，16 项 × 565 bit，每个读口按目标单元的 payload 位宽截位，脚本 `tools/area_probe/rm_realwidth.sv`）**：

| 结构 | 写入源 | 读出口 | 面积（µm²） | 占全芯片 |
|---|---|---|---|---|
| v2 原结构 | 12（4 类单元 × 3 个 RS push 端口） | 12（4 类单元 × 3 个端口） | 40,993 | 6.6% |
| 改为从 dispatch 槽位写入 | 3 | 12 | 24,126 | 3.9% |
| **再改为每类单元 1 个读口（推荐）** | **3** | **4** | **15,914** | **2.6%** |
| 所有单元共用 1 个读口 | 3 | 1 | 13,125 | 2.1% |

**推荐"3 写 4 读"。** 相对 v2 原结构省掉 61% 的面积，改动都在 Verilog 侧：
- **写入**：dispatch 每个槽位这一拍最多推入一个单元，所以先在槽位内按单元类型选出 payload，再写进 replay_mem。表里的数字没有包括这个槽位内的选择逻辑，粗估再加约 0.1%。
- **读出**：每类单元每拍最多重注 1 条，这不会成为瓶颈。在 FULL 模式下，一个双实例单元每拍最多执行 2 条，每条 FT uop 需要执行 2 次，所以 FT uop 的吞吐本身就不超过每拍 1 条；DIV 只有 1 个实例，更不会超。
- **共用 1 个读口**只再省 0.5%，但 4 类单元要互相竞争重注机会，不划算。

**以后可选的优化（不在本轮做）**：用 2 端口寄存器堆宏替代触发器；操作数重读重放（只存控制字段，借助按序退休时源操作数可重读的性质）。

### 2.3 〔R4 重写〕插空复制：不需要重放时零性能开销

R3 把自适应理解成"决定要不要复制"，这不完整。插空本身就是自适应：**copy-2 什么时候发、发不发，取决于运行时有没有空闲资源。** 在统一 replay_mem 的结构下，两种模式的区别只在于 copy-2 等不到空位时怎么办：

| 模式 | copy-2 的发射条件 | 等不到空位时 | 性能 | 容错能力 |
|---|---|---|---|---|
| `FULL` | 有空闲 push 端口 | 一直等，ROB entry 跟着等 | 有间接开销（2.2） | 每条合格 uop 都被校验 |
| `OPPORTUNISTIC` | 有空闲 push 端口，**并且**目标 RS 占用 ≤ `RVV_FT_WATERMARK` | **当这条 entry 已经可以退休、而 copy-2 还没发出去时，放弃 copy-2**，这条 entry 按普通指令退休，计为"未校验" | **不需要重放时接近零开销** | 只校验能插空的那部分 |

**为什么 OPPORTUNISTIC 能做到"零开销"**：
- copy-2 不会挤占 dispatch：用的是 dispatch 不用的端口。
- copy-2 不会挤占单元：`WATERMARK` 保证只在单元有余量时才发。
- copy-2 不会拖慢退休："entry 可以退休时还没发出的 copy-2 一律放弃"保证退休不会因为一条**尚未发出**的副本而延迟。
- 剩下的唯一开销来自**已经发出**的 copy-2：它是在单元空闲时发出的，几拍就能回来。这条 entry 要等它回来，延迟有上限，而且很小。要做到绝对零延迟，就得允许"已经发出的副本被作废"，这会牵扯到 ROB entry 被重新分配后结果落错位置的问题，代价不值得。论文里把它表述为"接近零，有上界"即可。
- **一旦出现 mismatch，重放是必须的，不能放弃**：这就是"不需要重放时零开销"里那个前提。

**放弃条件的实现**（第 2 步细化）：可以用"这条 entry 位于退休窗口内、而且比它更老的 entry 都已经完成"作为判据，比"只看 ROB 队头"更宽松，避免一次退休多条时被队头卡住。

**`WATERMARK` 只是锦上添花的旋钮**：主结果是 OPPORTUNISTIC（默认 `WATERMARK`）和 FULL 这两个点；扫描 `WATERMARK` 作为实验章节的补充曲线。

### 2.4 〔R4 重写〕宏：精简为 4 个，统一前缀

| 宏 | 取值 | 含义 |
|---|---|---|
| `RVV_FT_ON` | 有 / 无 | 总开关。没定义时，FT 相关代码全部不存在，构建与上游一致（继承 v2 的 INV-1） |
| `RVV_FT_MODE` | `FULL` / `OPPORTUNISTIC` | 2.3。**默认值待你确认**（7.2） |
| `RVV_FT_WATERMARK` | 0 … RS 深度 | 只在 OPPORTUNISTIC 下有效 |
| `RVV_FT_RETRY_MAX` | 整数 | 重放上限，耗尽后上报（2.5） |

- 以后 VME 的宏统一用 `VME_FT_` 前缀，两边互不干扰。
- **R3 里的 `FT_UNIT_MASK`、`FT_REPLAY_OFF` 删除。** 在统一 replay_mem 的结构下，copy-2 本身就要读 replay_mem，"只检测、不带 replay_mem"这一档已经不存在了。
- **v2 的注错自测宏（`FT_INJECT_ON`、`FT_INJECT_PERSIST`、`FT_TAG_INJECT_ON`、`FT_TMR_INJECT_ON`）不再放进 RTL。** 改用 VCS 测试平台在仿真时 force 或 deposit 某个 PU 结果位（一次性注入，或每次都注入以模拟持续错误），效果相同，而 RTL 保持干净。v2 里"每个检测器都配一个故意失败模式"的原则保留，只是换个地方实现。
- 宏通过 VCS 的 `+define+` 从外部传入，不改上游的 svh 文件。

### 2.5 〔R4 修订〕检错上报：完全复用现有路径

你说得对，复用现有路径对以后跟上游同步最稳。整条链路如下，只有第一步是我们新加的 Verilog：

1. **硬件**：重放耗尽（`RVV_FT_RETRY_MAX`）时，ROB 给出事件和 rob_tag；在 `RvvCore.sv` 里把它合并到已有的 `trap_valid_o / trap_data_o`（后端事件更老，优先级高于 `RvvFrontEnd`）。`RvvCore.sv` 对外端口不变，所以 Chisel 侧的 BlackBox 不用改。
2. **标量核（现有逻辑）**：按 rob_tag 匹配，产生异常，mcause=2，mtval 是我们填的**哨兵编码**（一个不可能合法的指令编码）。
3. **软件（现有逻辑）**：默认异常处理程序执行 `ebreak`。
4. **上位机（现有逻辑）**：Core 的 `io.fault` 引脚拉高，上位机或测试 fixture 就感知到了；需要区分错误类型时，上位机可以通过 debug 模块读 mcause/mtval/mepc，看到哨兵编码就知道是硬件错误。

| 层 | 内容 | 用途 |
|---|---|---|
| L1 仿真观测 | 注错框架直接读 FT 事件信号和计数器 | 实验分类（CORRECTED / DETECTED），不依赖软件 |
| L2 现有通路 | 上面 1～4 | 上位机感知 |
| L3 专用 CSR | — | **不做** |

**局限**（论文里写明即可）：mcause 只能是 2；正式构建的后端不带 PC，所以 mepc 不准确，但重放耗尽本来就是不可恢复错误，上位机感知到之后做复位或重新执行就行，不需要从 mepc 恢复。
**风险**：后端产生的异常走这条通路时，时序语义（冲刷、不挂死）要在第 0 层用定向测试确认。

### 2.6 ECC 的位置（保持）

不用 ECC 或签名做 DMR 比较；VRF 的奇偶校验看注错数据再定；ECC 和奇偶校验主要用在 VME tile 上。

---

## 3. 各功能域的取舍（R2/R3 结论保持）

| 功能域 | 面积占比 | 结论 |
|---|---|---|
| RVV 执行单元 + RS | 12.3% | 指令冗余，**尽快完成** |
| **VME** | **55.5%** | **开发重点**，细节到第 2 步：tile 端到端奇偶校验（覆盖占芯片 23% 的选择网络），PE 阵列 ABFT |
| VRF | 1.5% | 奇偶校验，可选 |
| watchdog | — | 低成本可选项 |
| ROB TMR、前端 decode | — | 不做 |
| 标量核 LSU（10.8%） | — | 不做：store 不能执行两次，load 执行两次会让带宽翻倍；LsuV3 是上游最活跃的 Chisel 模块 |
| 标量核锁步（14.6%） | — | 不做：面积 +14.6%，只检不纠；可以作为高开销的对照基线 |
| DTCM（6.3%） | — | 范围外 |

---

## 4. 注错负载与评估维度（保持）

**负载**：只用官方测试，注错包装放在独立的新目录里，只新增文件、不修改官方文件。

| 类别 | 官方测试 |
|---|---|
| AI 算子 | `tutorial/tfmicro`：conv2d、depthwise、FC、pooling、logistic |
| 矩阵乘 / Transformer 算子 | `rvv/ml_ops`、`gemma_kernels` |
| **VME** | `vme_test`：`vme_matmul_{int8,int16,bf16,fp32}`、transpose、load_store |
| ISA 覆盖 | `rvv/arithmetics` |
| 端到端 | `cocotb_run_mobilenet_v1`（部分层） |

**评估维度**：
- 主结果 5 类：MASKED / CORRECTED / DETECTED / SDC / DUE-undetected。
- SDC 的 AI 属性：出错元素数、误差幅度、空间模式、是否可容忍；〔待核实〕参考 FIdelity 做跨层投射。
- 开销：面积（分模块、分机制）、性能（FULL 和 OPPORTUNISTIC，外加 `WATERMARK` 扫描）、实际复制率。

---

## 5. 注错方法（保持）

| 层 | 方法 | 用途 |
|---|---|---|
| 第 0 层：机制自测 | RTL 加 VCS 测试平台 force/deposit（〔R4〕不再用 RTL 宏） | 证明机制和上报路径能工作，不进统计 |
| **第 1 层：门级统计注错** | DC 网表（compile，保留层次）+ VCS，混合级仿真 | 唯一的可靠性统计来源 |

- 故障点是所有标准单元的输出，组合和时序单元统一放进一个池子，**按单元面积加权抽样**。时序单元注 SEU，组合单元注 SET（零延迟模型，结果偏保守）。
- 按功能域分层抽样、分别报告；〔待核实〕样本量参考 Leveugle DATE 2009。

---

## 6. 工具

### 6.1 VCS

门级仿真是决定性因素：单元模型里有 UDP 和大量 specify 块。VCS 有 99 份 license，注错统一用 VCS。

### 6.2 Z01X（〔R4〕暂时搁置）

license 暂时拿不到，主线只用 VCS 逐个注入。为了控制门级仿真的时间，主要靠三点：混合级仿真、算子级的短负载、〔待核实〕VCS 的检查点功能。以后如果拿到 license，再评估是否能用并发故障仿真来加速。

### 6.3 标准单元库

`vlg` 和 `doc` 已经下载；`nldm` 只有在要报 tt/ss 角的时序或功耗时才需要。

---

## 7. 汇总

### 7.1 截至 R4 的共识

1. 定位：**NPU 低开销容错**。基准论文只是参考之一；指标只做粗估，最终以论证低开销为准。
2. RVV 指令冗余：
   - **copy-2 和重放统一经 replay_mem 发射**，只用 dispatch 当拍不用的 push 端口，不直接阻塞 dispatch。
   - replay_mem 采用"3 写 4 读"，实测约 2.6%，比 v2 原结构省 61%。
   - 保留完整比较，trap 重试、小容量池、签名比较都不做。
3. **插空模式（OPPORTUNISTIC）**：只在有空闲端口、而且单元有余量时发 copy-2；entry 可以退休时还没发出的 copy-2 就放弃。**不需要重放时零开销**（只剩已发出副本的几拍等待）；一旦 mismatch，必须重放。
4. **宏只有 4 个**：`RVV_FT_ON`、`RVV_FT_MODE`、`RVV_FT_WATERMARK`、`RVV_FT_RETRY_MAX`；VME 的宏用 `VME_FT_` 前缀；注错自测放到测试平台里做。
5. **上报完全复用现有路径**：ROB → `RvvCore.sv` 的 trap 输出 → 标量异常（mcause=2 加哨兵 mtval）→ 默认处理程序 `ebreak` → `io.fault` → 上位机。不改 Chisel。
6. VME 是开发重点；不做：LSU、锁步、ROB TMR、decode；可选：watchdog、VRF 奇偶校验。
7. 负载只用官方测试；统计注错用门级、按面积加权、按功能域分层；工具只用 VCS。

### 7.2 R5 技术结论与定稿

〔R5，2026-11-21〕

**1. 工具链澄清**

- Verilator 和 Yosys 都在 Bazel 依赖链里，跑的时候会自动安装。不因为本机是否预装而改工具选择。
- 12nm 完整的 nldm 库（`logic_synth/tsmc12ffc/nldm_1p0v_0c.tar.gz` 等）已下载并解压好，可以直接用于 DC 综合和时序报告。

**2. 指令复制方案定稿**

- **默认用 FULL 模式。** 部分复制（OPPORTUNISTIC）保留为实验对照，但不作为论文的主结果。理由：按现在的 replay_mem 方案，复制就是插空（优先级低于 dispatch），等价于自适应；FULL 的额外阻塞来自 ROB 容量和工作量翻倍，是 DMR 的固有开销。
- **部分复制的实现**：不是"等几拍超时就取消"（那样要计数器、状态复杂、还要评估超时阈值）；而是**"entry 在退休窗口内、而且比它老的都已完成时，如果 copy-2 还没发出，就放弃"**。判据是 `rd_valid_rob2rt[program_age]`（ROB 已有的组合逻辑），简单且恰好是"可以退休"的信号。
- 流控核实：`multi_fifo` 的 `pushRdy[k]` 依赖上一拍的 `entry_count`（寄存器），所以 v2 的 `freeslot = rs_ready & ~rs_valid` 确实比当拍的 push 慢一拍，但这不影响正确性。如果当拍没有空位，reinject 就等下一拍。**不需要做组合逻辑复制**（那会绕过 RS 接口，在 dispatch 层重写流控逻辑，风险大、收益小）。

**3. replay_mem 结构定稿**

- **采用"3 写（对应 3 个 dispatch 槽位）、4 读（每类执行单元 1 个读口）"**，DC 实测约 2.6% 芯片面积，按真实位宽（ALU 565、MUL 407、DIV 284、FALU 502 bit）。
- 不会成为性能瓶颈：双实例单元（ALU/MUL/FALU）每拍最多执行 2 条，FULL 模式下每条 FT uop 要执行两次，所以 FT uop 吞吐本来就不超过每拍 1 条/单元类型，1 个读口足够。

**4. 宏定义定稿**

保留 5 个：
- `RVV_FT_ON`：总开关。
- `RVV_FT_MODE`：FULL（默认）或 OPPORTUNISTIC。
- `RVV_FT_WATERMARK`：插空模式下的 RS 占用阈值。
- `RVV_FT_RETRY_MAX`：重试次数上限。
- **`RVV_FT_INJECT_ON`**：RTL 注错自测，保留备用。理由是功能验证时 RTL 注错最方便，不需要每次都造 VCS 的 force 环境。功能验证阶段用它，统计注错用门级 + VCS。

VME 的宏统一用 `VME_FT_` 前缀。

**5. 文档重组**

现在的四个文件（01/02/03/04）改为：
- **`01-v2-review.md`**：合并原来的 01/02/03，只保留事实（v2 做了什么、main 变了什么、技术分析），去掉初步决策建议（那些已经在 04 里被修订过了）。
- **`02-direction-discussion.md`**（原 04 改名）：就是当前这份讨论定稿，截至 R5。
- **`03-rvv-implementation.md`**（下一步）：RVV 容错的实现和功能验证记录。
- **`rebase-log.md`**（新增）：专门记录每次与官方仓库同步的 rebase 过程，不参与整体开发流程序号。

README 和记忆也同步更新。每推进一个文档换一个对话框，过去的有效信息通过 md 同步。

**6. 第 1 步讨论收尾**

〔待你确认〕：R5 之后，第 1 步讨论结束，进入第 2 步（联网调研 + 完整方案设计）？

### 7.3 第 2 步联网调研清单

- 自适应 / 机会式冗余：Warped-DMR（MICRO 2012）、Opportunistic Transient-Fault Detection（ISCA 2005）、SITR（SBAC-PAD 2007）；**重点是"利用空闲发射槽"和"放弃未发出副本"有没有先例**。
- 无重命名、按序退休处理器上的指令重放，以及重放缓冲的面积优化。
- 向量处理器、NPU、DNN 加速器的容错（Barbirotta 2024 只是其中之一）；systolic array 和矩阵引擎上的 ABFT（含浮点容差）；奇偶校验覆盖选择网络。
- 注错方法学：门级 SET 建模、按面积加权抽样、触发器与组合逻辑 SER 的比例、Leveugle DATE 2009、VCS 的检查点功能。
- AI 可靠性评估：Li SC 2017、FIdelity MICRO 2020。
- 低开销的论证方式：其他工作如何报告面积和性能开销，口径是全芯片还是只算加速器。
