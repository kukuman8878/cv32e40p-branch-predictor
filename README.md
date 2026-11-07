<div align="center">

# CV32E40P 动态分支预测优化

**在 OpenHW CV32E40P 上增加可关闭的动态分支预测，并完成正确性验证、可复现实验与面积评估**

[![License](https://img.shields.io/badge/license-Solderpad--0.51-blue.svg)](https://solderpad.org/licenses/SHL-0.51/)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com)
[![Verilator](https://img.shields.io/badge/仿真-Verilator-ff69b4.svg)](#)
[![Yosys](https://img.shields.io/badge/综合-Yosys-orange.svg)](#)

</div>

<div align="center">
  <h3>"分支预测的价值，取决于分支在哪里决议"</h3>
</div>

---

## 📌 项目介绍

- 本项目在 OpenHW Group 的 **CV32E40P**（32 位、四级顺序流水线 RISC-V 核）上，新增**可参数化关闭的动态分支预测**：2-bit 饱和计数器 **BHT**（方向预测）+ 带 tag 的直接映射 **BTB**（目标预测）。
- 全部工作在固定 commit 上进行（中途不更新上游），以**一个补丁** `branch-predictor.patch` 交付，应用后得到全部预测器 RTL 改动。
- 采用**双 Agent 机制**：Agent A 负责架构分析、RTL 实现与测试，Agent B 独立复核与审核，按 **G0–G6 七个 Gate** 推进，每 Gate 必须 B 判 `PASS` 且 P0/P1 清零才放行。
- 不止做"能跑通"，更强调**可复现、可追溯、不夸大**：每一项性能/面积数字都能回溯到日志，所有"未做/未评估"都显式标注，绝不伪造。

> 基线：`openhwfoundation/cv32e40p` @ `b353438ff469c030c89f6804f3b24a2852880e8b`

### 🎉 本项目包含以下内容

- 取指路径架构映射与信号表（精确到 `文件:行号`）——见 `docs/01_architecture_map.md`
- 独立 BHT/BTB 模块 + 单元测试 + lint（Verilator）
- 处理器集成：预测 PC 选择、预测元数据跨级传递、误预测 flush/恢复
- 5 个基准程序（分支密集/混合/低分支 + hello_world/fib）与定向测试、寄存器级一致性签名
- 全核综合脚本（sv2v + Yosys），BASE / EN0 / EN1 三套面积对照
- 一条命令复现：`./scripts/run_all.sh`

## 📌 结果摘要

| 维度 | 结果 |
|---|---|
| **功能正确性** | `BR_PREDICT_EN=0` 与基线逐周期一致；`=1` 与关闭版寄存器级签名位精确一致 |
| **性能改善** | hello_world **+14.75%**、branch_heavy **+6.33%**、low_branch **+9.46%** |
| **性能退化（如实披露）** | fib −1.65%、mixed −3.40%（数据依赖分支 + 密集 JAL/JALR 固有代价） |
| **面积** | 原始异步读 BTB **+155.41%** → 同步读 SRAM 化后 **+25.2%**（generic cells） |
| **未评估** | WNS/时序、功耗（无 PDK / 时序库 / 功耗库） |

## 📌 核心架构结论（实测验证，非猜测）

CV32E40P 的**条件分支在 EX 阶段决议**、**跳转（JAL/JALR）在 ID 阶段决议**。因此：

- ✅ **条件分支预测有收益**——IF 阶段预测可省去 EX→IF 的重定向气泡，即本项目的 BHT/BTB。
- ❌ **跳转/返回预测零收益**——JAL/JALR 在 ID 已决议，预测与之同拍等价。本项目曾实现 JAL 直接预测与 RAS 返回地址栈，实测确认零收益后已回退（见 `docs/04_results.md` §8）。

面积从 +155.41% 降到 +25.2% 的关键：**"异步组合读"被综合工具摊平为逐 bit 的 128:1 mux**，改为**同步读**后综合工具即可推断 block RAM。

---

## 📌 快速开始

<details>
<summary>💡 本人验证环境（供参考）</summary>

- OS：Ubuntu
- 工具：riscv32-unknown-elf-gcc 13.2.0 / Verilator 5.052 / Yosys 0.33 / sv2v 0.0.13 / picolibc 1.8.6

</details>

### 第 1 步：安装依赖

| 工具 | 版本 | 安装方式 |
|---|---|---|
| riscv32-unknown-elf-gcc | 13.2.0 | `apt install gcc-riscv64-unknown-elf`（多库含 rv32imc），并把 `riscv64-unknown-elf-*` 符号链接为 `~/.riscv/bin/riscv32-unknown-elf-*` |
| picolibc | 1.8.6 | `apt install picolibc-riscv64-unknown-elf`，头文件/库链接到 `~/.riscv/riscv32-unknown-elf/{include,lib}` |
| Verilator | ≥5.0 | `apt install verilator` 或 conda |
| Yosys | 0.33 | `apt install yosys`（仅综合需要） |
| sv2v | 0.0.13 | 下载官方 prebuilt（仅综合需要） |

### 第 2 步：获取基线并打补丁

```bash
git clone https://github.com/openhwfoundation/cv32e40p
cd cv32e40p
git checkout b353438ff469c030c89f6804f3b24a2852880e8b
git apply ../cv32e40p-branch-predictor/branch-predictor.patch
```

> 目录布局：`cv32e40p/`（打好补丁的仓库）与 `cv32e40p-branch-predictor/`（本仓库）同级，脚本默认 `REPO_DIR = $本仓库/../cv32e40p`。

### 第 3 步：一键复现

```bash
cd cv32e40p-branch-predictor
./scripts/run_all.sh        # 基线 → EN0/EN1 回归 → 单测 → 全核综合，退出码 0 即全通过
```

单独跑综合（sv2v + Yosys，输出面积 CSV）：

```bash
./scripts/synth_sram.sh
```

---

## 📌 目录结构

```text
cv32e40p-branch-predictor/
├── README.md                 # 本文件
├── branch-predictor.patch    # RTL 改动（b353438 → 最终版，9 文件 +546/-19）
├── docs/                     # 设计报告与验证计划
│   ├── 00_scope.md           # 项目范围与 Gate 状态
│   ├── 01_architecture_map.md# 取指路径图、信号表(file:line)、风险清单
│   ├── 03_verification_plan.md # 环境/工具链/编译选项/复现命令
│   ├── 04_results.md         # 最终设计报告与结果汇总
│   ├── 05_area_decision.md   # 面积口径裁决
│   └── 06_related_work.md    # 开源借鉴（CVA6 前端等）
├── scripts/                  # 复现/综合脚本
│   ├── run_all.sh            # 一键：基线 → EN0/EN1 回归 → 单测 → 综合
│   ├── reproduce.sh          # 编译 5 固件 + EN0 基线运行
│   ├── g3_verify.sh          # EN0/EN1 功能回归
│   ├── g4_full.sh            # 定向测试 + 一致性
│   ├── g5_full.sh            # 性能/CPI 汇总
│   ├── run_unit_tests.sh     # BHT/BTB 单测 + lint
│   ├── synth.sh / synth_full.sh / synth_sram.sh  # 综合
│   └── build_tb.sh           # Verilator tb 构建
├── tb/                       # Verilator 本地 testbench（打补丁后跑仿真用）
├── synth/                    # 全核综合辅助（sv2v shim 等）
└── tests/                    # 基准 + 定向测试 + 单测源
```

## 📌 结果与数据

- 完整结论、性能/面积数据、诚实披露清单，统一见 **`docs/04_results.md`**。
- 运行 `./scripts/run_all.sh` 会在本地 `metrics/` 下生成周期对比、CPI/准确率、综合面积等 CSV 与原始日志（未提交，可自行复现生成）。
- 双 Agent 的 A 提交单与 B 审核结论（PASS/REJECT 轨迹）见本地 `reviews/`（如需可另行补充上传）。

---

## 📌 诚实披露（未做 / 未评估）

- **WNS / 关键路径 / 时序**：未评估（无 OpenSTA / 时序库 / PDK）。
- **功耗**：未评估（无功耗库 + 活动数据），不把门数变化等同于功耗变化。
- **CoreMark**：未跑（需其自身 harness/计时接口）。
- **spike ISS 对拍**：未安装，以"内存 + 寄存器文件"双签名替代。
- **core-v-verif UVM**：未跑（需 Questa/VCS 商业仿真器，本机仅 Verilator）。
- **面积 ≤10% 挑战目标**：寄存器版超标（+155%→+25%），SRAM 宏等效面积需 memory compiler/PDK，未最终判定（见 `docs/05_area_decision.md`）。

## 📌 致谢与参考

- 基线核：[openhwfoundation/cv32e40p](https://github.com/openhwfoundation/cv32e40p)（Solderpad Hardware License v0.51）
- 分支预测参考：[openhwfoundation/cva6](https://github.com/openhwgroup/cva6) `core/frontend/{bht,btb,ras}.sv`（同步读 SRAM / valid 位 / flush_bp / debug_mode）
- 项目遵循的工程规程与双 Agent 审核方法，详见 `docs/00_scope.md`

## 📌 License

本补丁基于 CV32E40P（Solderpad Hardware License v0.51）衍生，预测器 RTL 与测试脚本沿用同一许可。详见基线仓库 LICENSE。
