# rebase-log · 与官方仓库的同步记录

> 本文件专门记录 fault-tolerance-v3 分支与官方 main 的每一次 rebase 过程，包括冲突解决、验证结果和需要注意的变化。
> 不参与整体开发流程的序号，独立维护。

---

## 格式约定

每次 rebase 记录一个条目，包含：

- **日期和新 base**：何时做的 rebase，新的 base commit（main 的 SHA 和日期）。
- **变化规模**：自上次 rebase 以来 main 上新增的提交数、文件数、行数。
- **冲突文件清单**：哪些文件有冲突、大致原因、解决策略。
- **需要适配的 FT 代码**：哪些 FT 机制受到上游变化影响、需要重新测试或修改。
- **验证清单**：rebase 后跑了哪些测试、结果如何。
- **备注**：值得记录的细节（比如上游引入了新的基础设施、删除了某个模块等）。

---

## 当前状态

- **v3 分支当前 base**：main@f385a31b（2026-11-20），最新一次 rebase 于 2026-11-21
- **v3 分支创建时的 base**：main@9d0a8dcf（2026-11-13）
- **v2 分支的 base**：main@1126ed3f（2026-07-31）
- **v2 → v3 起点跨越的 main 提交数**：347 个提交，842 文件，+109,771 / −30,179 行
- **v3 起点 → 当前 base**：4 个提交，12 文件，+1,425 / −229 行

---

## Rebase 记录

### #1 · 2026-11-21：9d0a8dcf → f385a31b（第 03 阶段开始前）

**日期和新 base**：
- 日期：2026-11-21
- 旧 base：`9d0a8dcf`（2026-11-13）
- 新 base：`f385a31b`（2026-11-20）

**变化规模**：
- 新增提交：4 个
- 变更文件：12 个（+1425 / −229 行）
- 提交清单：
  1. `1f6e408a` [fpga] Add bitstream and checkpoint output groups
  2. `62ee992a` Adding JSON telemetry reporting support for Coralflow
  3. `4507b606` Fix vfredusum check and seed RVV arithmetic tests
  4. `f385a31b` [ci] Skip workspace_status_command on `bazel test`

**冲突文件清单**：
- 无冲突。rebase 过程完全干净，`git rebase main` 一次成功。

**变更内容分析**：
- **CI 基础设施**（f385a31b）：`.bazelrc` 在 `bazel test` 时跳过 `workspace_status_command`，避免不必要的构建依赖。
- **RVV 算术测试修复**（4507b606）：修复 `vfredusum.vs` 的浮点精度检查问题（灾难性抵消导致的 ULP 差异），并给所有 NumPy RNG 统一设种子。**只改测试代码，不触及 HDL**。
- **CoralFlow 遥测**（62ee992a）：新增 `telemetry.py` 模块，支持 JSON 格式的测试结果上报；重构 `runner.py` 的错误收集逻辑。
- **FPGA 输出组**（1f6e408a）：Vivado 脚本增强，支持输出 checkpoint 和 bitstream 作为 Bazel output groups。

**对 FT 代码的影响**：
- **零影响。** 4 个提交全部涉及测试基础设施、CI 和 FPGA 流程，没有任何一个文件触及 `hdl/rvv` 或 RVV 后端核心逻辑。
- FT 代码尚未开始编写，所以没有适配需求。

**验��清单**：
- ✅ `git status` 干净，无未提交文件
- ✅ `git log` 显示 HEAD 在 `f385a31b`
- ✅ 确认没有 RVV backend HDL 文件被修改（`git diff 9d0a8dcf..HEAD --name-only | grep rvv` 无输出）
- ⏸️ 编译和测试：待 FT 实现后统一验证

**备注**：
- rebase 时机：第 03 阶段（RVV 容错设计实现）开始之前，符合 02-direction-discussion.md R5 的约定。
- 后续开发：下一步是 RVV 容错实现（记录到 `03-rvv-implementation.md`），实现过程需要新增以下文件：
  - replay_mem 模块（3 写 4 读，16 项 × 565 bit 最大位宽）
  - FT 控制逻辑（copy-2 发射、比较、重放、trap 上报）
  - 宏定义文件或机制（RVV_FT_* 5 个宏）
- 侵入性原则：尽量不改上游文件，优先新增文件、在顶层用薄钩子集成。
