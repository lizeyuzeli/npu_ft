# CoralNPU 低开销容错研究

本仓库保存基于 CoralNPU 的 NPU 容错课题资料，包括设计取舍、RTL 实现与验证记录、综合探测工具和参考文献。当前的 v3 工作围绕 RVV 向量后端和 VME 矩阵引擎，研究如何以较低的硬件开销检测和处理计算错误。

## 文档与工具

- v2 回顾、v3 方案取舍和关键版本见 [v3 规划与文档索引](fault-tolerance-v3-plan/README.md)。
- 指令复制、结果比较、重放机制与注错实验见 [RVV 容错实现与验证](fault-tolerance-v3-plan/03-rvv-implementation.md)。
- Tile 存储保护、矩阵乘阵列校验与 RVV/VME 共用错误上报的候选方案见 [VME 容错设计](fault-tolerance-v3-plan/04-vme-ft-design.md)。
- VME 时间复制、按序重放和 RS 负载奇偶保护的 RTL 签收及原始日志索引见 [VME 容错实现与验证](fault-tolerance-v3-plan/05-vme-implementation.md)。
- 仿真实测结果和波形摘录见 [测试数据](test-data/README.md)。
- CoralNPU 分支的 rebase、冲突处理和验证结果见 [上游同步记录](fault-tolerance-v3-plan/rebase-log.md)。
- 面积分析脚本、综合探测用的 RTL 和 Tcl、面积与时序报告，以及 VCS 编译辅助脚本见 [工具与实验材料](fault-tolerance-v3-plan/tools/)。课题使用的论文存放在 [参考文献](reference/)。

## 获取对应的 CoralNPU 源码

`npu_ft` 保存研究文档和实验资料。容错 RTL、构建配置和仿真测试在独立的 `coralnpu` 仓库维护，v3 实现在 `fault-tolerance-v3` 分支。[CoralNPU 仓库](https://github.com/lizeyuzeli/coralnpu) · [v3 分支](https://github.com/lizeyuzeli/coralnpu/tree/fault-tolerance-v3)

克隆本仓库后，在根目录运行下面的命令，将源码放到工具和文档使用的 `coralnpu/` 路径。该目录由外层仓库的 `.gitignore` 忽略。

```bash
git clone --branch fault-tolerance-v3 git@github.com:lizeyuzeli/coralnpu.git coralnpu
```

要复现 RVV 容错实验，先用下面的命令切换到对应提交，再按「构建和复现」章节运行。[CoralNPU 提交 `29a4e55`](https://github.com/lizeyuzeli/coralnpu/commit/29a4e555e1bf450d12c5254bbfcc02dc735e49c6) · [RVV 容错实现与验证](fault-tolerance-v3-plan/03-rvv-implementation.md#4-构建和复现)

```bash
git -C coralnpu switch --detach 29a4e555e1bf450d12c5254bbfcc02dc735e49c6
```
