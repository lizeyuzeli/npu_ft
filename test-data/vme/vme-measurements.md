# VME INT8 实测结果

## 官方单指令回归

`vme_matmul_int8_test` 在 Verilator 和 VCS 上均通过，日志中的 `Core Cycles` 均为 **529**。测试用同一个 fixture 顺次执行五个独立子用例，每个子用例准备输入和 tile 初值、运行一条 MAC，再读回并检查整个 tile。行列维度上限为 16。

| 子用例 | 指令与目标 | `(tm, tn, tk)` | C 初值 |
|---|---|---|---|
| 1 | `vtmmu` → `mt0` | `(16, 16, 3)` | `vtzero` 清零 |
| 2 | `vtmmu` → `mt4` | `(16, 16, 2)` | 预载，覆盖 `vtmv.t.v` |
| 3 | `vtmms` → `mt0` | `(16, 16, 3)` | 预载，有符号 A |
| 4 | `vtmms` → `mt0` | `(5, 7, 3)` | 预载，检查 tile 尾部保留 |
| 5 | `vtmmu` → `mt0` | `(16, 16, 1)` | 预载，检查单个 K 分量 |

五次 MAC 的首拍分别在 **497.50、1446.25、2381.25、3316.25、4256.25 ns**。这些间隔跨子用例的设置、读回和仿真交互。

## Gemma INT8 实验负载

实验复用 Gemma INT8 测试接口，实际执行自写的 `vme_matmul_int8`。输入是行主序 `A[M,K]`、`B[K,N]`，元素为有符号 INT8。输出是行主序 `C[M,N]`，每个元素为 INT32 累加结果 `Σₖ A[m,k] × B[k,n]`。`prefill` 是窄 M 合成负载的测试名。三组测试都只运行这个 GEMM，使用随机矩阵输入，没有加载 Gemma 权重或运行模型推理。

### 算子结构

1. **打包 A。** M 每次取最多 16 行。原始 A 以 K 连续，`PackA` 用 `vle8.v` 和 `vsse8.v` 转置当前行块，写入 `packed_a[k*16 + m_in_tile]`，使用 `K×16` 字节临时区。每个 M 行块打包一次，后续各 N 列块共用。B 保持原始行主序，行步长为 `N` 字节。
2. **清零输出 tile。** 每块 C 最多 `16×16`。单 tile 模式每组覆盖 16 列，清 `mt0`。四 tile 模式每组覆盖 64 列，用 `vtzero` 清 `mt0/mt4/mt8/mt12`，N 不足 64 的尾部用单 tile 路径。
3. **按 K 累加。** 每步 K 处理最多 4 个分量。`msetmtype`、`msettn` 和尾步的 `msettk` 设置有效尺寸。四条 `vle8.v` 将这一 K 步的 A 装入 `v8/v10/v12/v14`。对每块 C，再用四条 `vle8.v` 将 B 装入 `v16/v18/v20/v22`，执行一条 `vtmms` 累加到目标 tile。A 的有符号模式由 MAC 编码选择，B 由 `altfmt=1` 选择。四 tile 同一个 K 步复用这组 A 寄存器，每块 C 分别加载自己的 B。
4. **写回 C。** K 循环结束后切回 INT32 配置，用 `vtse32` 逐行写入 `C`，每块只写有效行列，行步长为 `N` 个 INT32。

窄 M 或其他 `rows != cols` 的场景中，每个 K 步加载 A 前将 `tn` 设为 `rows`，装完 A 后恢复为 `cols` 再加载 B。在 `prefill` 的首段，20 拍是同一 K 步内不同 C tile 之间的间隔，58 拍跨 K 步，包含这组配置指令和 A 重装。

三组主测试按每个测试单独初始化 `np.random.default_rng(42)`，A、B 全范围采样 `[-128,127]`，两个矩阵的 `[0,0]` 均置为 `-128`。单 tile 与四 tile 的 `(64,128,64)` 用同一组输入，切换 runner 的 `interleave_tiles` 开关。fixture 预写 C 为 `0x1BADCAFE`，运行结束后读取整个有效输出与 NumPy INT32 结果逐元素比较。

### 算子周期与正确性

runner 在调用 `vme_matmul_int8` 前后读 `mcycle`。差值包括 `PackA`、配置指令、tile 清零、所有 K 步以及输出写回。宿主侧的 ELF 加载、输入准备和结果校验在计时区间外。表中的 CoralFlow `Core Cycles` 是仿真框架报告的核心周期数。后续波形表的 MAC 间隔是局部采样，按相邻两条 MAC 的首拍相减。

| 测试 | `(M,K,N)` | `mcycle` | CoralFlow `Core Cycles` | 首段 MAC 启动间隔 |
|---|---|---:|---:|---|
| `vme_gemma_int8_single_tile` | `(64,128,64)` | 42,591 | 42,778 | 54 拍 |
| `vme_gemma_int8_interleaved_tiles` | `(64,128,64)` | 29,243 | 29,430 | `22, 22, 22, 49` 拍 |
| `vme_gemma_int8_prefill` | `(4,64,1024)` | 33,126 | 33,313 | `20, 20, 20, 58` 拍 |

全表通过 NumPy INT32 逐元素校验。相同 `(64,128,64)` 下，四 tile 模式的 kernel 周期减少 **31.3%**，约 **1.46×** 加速。独立的 `vme_gemma_int8_correctness` 通过了 `(2,0,3)`、`(1,1,1)`、`(4,5,1)`、`(17,9,65)`、`(4,64,64)`、`(1,64,1024)`、`(1,1024,64)` 和 `(4,1024,64)` 八种形状。

### 首对 MAC 的时间线

时间戳为仿真绝对时间，周期为 1.25 ns。

| 事件 | 单 tile | 四 tile interleave |
|---|---:|---:|
| 首条 MAC 内部首拍 | 6875.00 ns | 6887.50 ns |
| 首条 `peCmdRdy=1111`、`rtCmdVld=1` | 6878.75 ns | 6891.25 ns |
| 首条 block 0 第一次读取 C | 6880.00 ns | 6892.50 ns |
| 首条 block 0 第一次拉高 C 写使能 | 6883.75 ns | — |
| 首条 `vmeRtVld=1` | 6892.50 ns | 6905.00 ns |
| 为下一条 MAC 发出的第一笔向量 load | 6903.75 ns | 6886.25 ns |
| 第二条 MAC 内部首拍 | 6942.50 ns | 6915.00 ns |
| block 0 输入空拍 | 50 | 18 |

表中的首次 C 写使能来自单 tile 的 `+fsdb+mda` 采样。

单 tile 顺序是 `C0(k0) → C0(k1)`，每条 MAC 前要走 K 循环并加载四个 A 向量和四个 B 向量。四 tile 顺序是 `C0(k0) → C1(k0) → C2(k0) → C3(k0) → C0(k1)`。同一个 `k` 的四条 MAC 共用 `v8/v10/v12/v14` 里的 A，各自加载四个 B，合计每四条 MAC 的向量 load 从 32 降到 20。下一 tile 的 B load 能早于当前 MAC 启动。组内 22 拍，跨 K 重装 A 和执行循环控制时回到 49 拍。

两个首对窗口内，向量 ROB `uop_ready_rob2dp=111`，RVV 命令入口 `insts_ready_cq2rvs=1111`，`rs_ready_zvt2dp=111`，`rtCmdRdy=1`。单 tile 从第一次 MAC 启动到下一轮第一笔 load dispatch 间隔 23 拍。四 tile 的对应 load 在当前 MAC 启动前一拍 dispatch，之后在 6890.00 ns 和 6893.75 ns 还观察到后续 load dispatch。标量退休缓冲 `nSpace` 未采样。

### 首组输出 tile 的 PE 输入统计

统计从首条 MAC 启动到该组最后一条 MAC 的 block 输入尾部，含组内空拍。每个 block 每拍单独计数。已用 block 拍按 `valid && ready` 计，ready 且空闲 block 拍按 `ready && !valid` 计。

| 测试 | 首次启动 / 下一输出组首启（ns） | 首组 MAC 数 | 窗口周期 | 已用 block 拍 | ready 且空闲 block 拍 | 完整命令被 `hitRaw` 阻挡的周期 |
|---|---:|---:|---:|---:|---:|---:|
| 单 tile | 6875.00 / 9212.50 | 32 | 1680 | 512 | 6208 | 0 |
| 四 tile interleave | 6887.50 / 15991.25 | 128 | 3637 | 2048 | 12500 | 0 |
| 窄 M prefill | 7418.75 / 9961.25 | 64 | 1833 | 256 | 7076 | 0 |

### Tile 写回实测

| 形状 | 参与写回的 block | 各 block `writeEn` 有效拍 | 整个阵列写回跨度 |
|---|---|---:|---:|
| `tm=16, tn=16` | block 0–3 | 各 4 拍 | 6 拍 |
| `tm=4, tn=16` | block 0、1 | 各 2 拍 | 3 拍 |

按每个时钟周期的有效位计算写回次数。`writeEn` 可以连续几拍保持相同掩码，同时 `writeSubIdx` 变化，所以只数 `writeEn` 上升沿会漏记。
