# VME 逐拍波形摘录

下表摘自 Gemma INT8 单 tile 仿真的第一条 MAC。以 6875.00 ns 为第 0 拍，时钟周期为 1.25 ns。位图从左到右对应 block 3 到 block 0。C 写使能来自开启 `+fsdb+mda` 的同配置仿真，每个 block 有任一写端口有效就记为 1。

| 相对拍 | `blkCmdVld[3:0]` | C 写使能位图 | 同拍观察 |
|---:|---|---|---|
| 0 | `0001` | `0000` | `cnt=0`，`peCmdVld=1111`，block 0 收首拍 |
| 1 | `0111` | `0000` | `cnt=1`，block 1、2 开始收拍 |
| 2 | `1111` | `0000` | `cnt=2`，block 3 开始收拍 |
| 3 | `1111` | `0000` | `cnt=3`，`peCmdRdy=1111`，`rtCmdVld=1` |
| 4 | `1110` | `0000` | RS 中这条指令已出队，block 0 开始读 C |
| 5 | `1000` | `0000` | block 3 收最后一拍 |
| 6 | `0000` | `0000` | 四个 block 的输入 valid 均降为 0 |
| 7 | `0000` | `0001` | block 0 开始写 C |
| 8 | `0000` | `0111` | block 1、2 开始写 C |
| 9 | `0000` | `1111` | 四个 block 都在写 C |
| 10 | `0000` | `1111` | block 0 的最后一个有效写周期 |
| 11 | `0000` | `1110` | block 1、2 的最后一个有效写周期 |
| 12 | `0000` | `1000` | block 3 的最后一个有效写周期 |
| 13 | `0000` | `0000` | `vmeRtCmdPop=1` |
| 14 | `0000` | `0000` | `vmeRtVld=1` |

单 tile 这条 MAC 的 block 0 首个写端口在第 7 至第 10 拍的 `writeEn` 均为 `ffff`，而 `writeSubIdx` 依次为十六进制 `0、4、8、c`。因此按有效周期计得到 4 次写入。窄 M prefill 的首条 MAC 从 7418.75 ns 启动，第 7 至第 9 拍的写使能位图依次为 `0001 → 0011 → 0010`，对应 7427.50、7428.75、7430.00 ns。

## 信号及采样口径

Gemma 仿真波形中的 `backend` 对应 `VmeCoreMiniHighmemAxi.core.rvvCore.rvvCoreWrapper.core.backend`。

| 记录项 | 采样信号或判定条件 |
|---|---|
| 向量命令与 dispatch | `backend.insts_valid_rvs2cq`、`insts_ready_cq2rvs`、`uop_ready_rob2dp` |
| Zvt RS | `backend.rs_valid_dp2zvt`、`rs_ready_zvt2dp`、`u_zvt_rs.entry_count` |
| MAC 首拍 | `backend.vme.zvtPeArray` 中 `cnt=0 && blkCmdVld[0] && blkCmdRdy[0]` |
| 完整命令遭遇 RAW | `backend.vme.zvtPeArray` 中 `peCmdVld=1111 && hitRaw=1` |
| uop 出队与 RT 登记 | `backend.vme.peCmdRdy`、`uopRdy`、`rtCmdVld`、`rtCmdRdy` |
| block 0 读写 | `backend.vme.zvtPeArray.peBlkID[0].peBlock` 下的 `mulbulkCmdVld`、`mulbulkCmdRdy`、`readMtIdx`、`readSubIdx`、`writeEn[0..3]`、`writeMtIdx`、`writeSubIdx` |
| VME 完成 | `backend.vme.vmeRtCmdPop`、`mtRtInfoVld`、`vmeRtVld`。`vmeRtVld` 记录 VME 完成通知。标量退休时刻和标量退休缓冲 `nSpace` 不在本次采样内。 |

[实测结果](vme-measurements.md)汇总三个 Gemma 运行的周期数、MAC 启动间隔及输入槽位统计。
