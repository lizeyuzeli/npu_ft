# VME INT8 RTL 仿真

记录 2026-11-24 起的 VME INT8 仿真实测。

| 文档 | 内容 |
|---|---|
| [实验负载与实测结果](vme-measurements.md) | 自写 GEMM 的数据布局和指令顺序、官方 INT8 用例、周期数、MAC 间隔和 tile 写回统计 |
| [逐拍波形摘录](vme-waveforms-and-flow.md) | 首条 MAC 的 block 输入、C 读写、VME 完成时序和采样口径 |

## 实验版本与配置

- CoralNPU RTL 基线为 `f385a31b4af454be21063fca1d17351b35a3a99c`，向量长度 `VLEN=128` bit，仿真时钟周期 1.25 ns。官方 `vme_matmul_int8_test` 使用 `VmeCoreMiniAxi`，分别运行 Verilator 5.052 和 VCS W-2024.09-SP1 Full64。
- Gemma INT8 使用该基线加实验时的 VME kernel、runner 和 highmem 测试配置，通过 VCS W-2024.09-SP1 Full64 运行 `VmeCoreMiniHighmemAxi`。ITCM 和 DTCM 各 1 MiB。ELF 代码装在 `0x00000000`，数据段基址为 `0x00100000`。三个负载的 A、B、C 和 `PackA` 临时区在 DTCM 中。Gemma ELF 记录的编译器是 GCC 16.1.0，编译目标定义 `GEMMA_USE_VME` 并使用 `-fno-tree-vectorize`，内核通过显式内联汇编发出 RVV/VME 指令。
- 测试使用 Python 3.11.9、cocotb 2.0.0 和 CoralFlow。Verilator 运行采集 FST，Gemma 波形由 VCS 和 Verdi W-2024.09-SP1 采集 FSDB。满 tile 和窄 M 的写回端口数据来自额外启用 `+fsdb+mda` 的采样。
- 本仓库归档测试配置、汇总数字和波形摘录。原始二进制波形、完整日志和 Gemma 实验配置补丁未随此记录归档。官方基线提交能定位官方小用例，完整复跑 Gemma 实验还需要上述补丁。
