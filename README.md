# 安装与使用

## 获取 CoralNPU 源码

外层仓库保存设计文档、工具和参考资料。克隆外层仓库后，在其根目录单独克隆 CoralNPU：

```bash
git clone --branch fault-tolerance-v3 git@github.com:lizeyuzeli/coralnpu.git coralnpu
```

需要恢复这批文档对应的 CoralNPU 版本时，从外层仓库根目录执行：

```bash
git -C coralnpu switch --detach 29a4e555e1bf450d12c5254bbfcc02dc735e49c6
```

## 一、环境准备

Linux环境

Bazel 7.4.1，请参考官方安装文档：[安装 Bazel](https://bazel.build/install)。

Python 3.9–3.12，请参考官方安装页面：[下载 Python](https://www.python.org/downloads/)。

SRecord，请参考官方网站：[安装 SRecord](https://srecord.sourceforge.net/)。

## 二、仿真测试

```bash
cd your_path/coralnpu
```

进入工程目录，以下命令均应在 `coralnpu` 根目录下执行。

运行 MobileNet V1 部分网络仿真测试：

```bash
bazel test //tests/cocotb/tutorial/tfmicro:cocotb_run_mobilenet_v1
```

运行 Depthwise Conv 算子仿真测试：

```bash
bazel test //tests/cocotb/tutorial/tfmicro:cocotb_depthwise_conv
```

运行 Conv2D 算子仿真测试：

```bash
bazel test //tests/cocotb/tutorial/tfmicro:cocotb_conv2d
```

运行 Pooling 算子仿真测试：

```bash
bazel test //tests/cocotb/tutorial/tfmicro:cocotb_pooling
```

运行 Fully Connected 算子仿真测试：

```bash
bazel test //tests/cocotb/tutorial/tfmicro:cocotb_fully_connected
```

运行 Logistic 算子仿真测试：

```bash
bazel test //tests/cocotb/tutorial/tfmicro:cocotb_logistic
```
