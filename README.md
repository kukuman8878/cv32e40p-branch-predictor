# CV32E40P 动态分支预测优化

在 OpenHW Group **CV32E40P**（32 位、四级顺序流水线 RISC-V 核）上增加**可关闭的动态分支预测**
（2-bit 饱和计数器 BHT + 带 tag 的直接映射 BTB），完成正确性验证、可复现实验与面积评估。

- 基线：`openhwfoundation/cv32e40p` @ `b353438ff469c030c89f6804f3b24a2852880e8b`
- 实现方式：一个补丁 `branch-predictor.patch`（应用后得到全部预测器 RTL 改动）
- 开发流程：按阶段推进（架构分析 → 基线冻结 → 单测 → 集成 → 全回归 → 性能/PPA → 交付）

## 结果摘要

| 指标 | 数值 |
|---|---|
| 功能正确性 | `BR_PREDICT_EN=0` 与基线逐周期一致；`=1` 寄存器级签名与关闭版位精确一致 |
| 性能改善 | hello_world **+14.75%**、branch_heavy **+6.33%**、low_branch **+9.46%** |
| 性能退化（如实披露） | fib −1.65%、mixed −3.40%（数据依赖分支 + 密集 JAL/JALR 固有代价） |
| 面积 | 原始异步读 BTB +155.41%；改同步读 SRAM 后 **+25.2%**（generic cells，详见 `docs/05_area_decision.md`） |
| 未评估 | WNS/时序、功耗（无 PDK/时序库/功耗库） |

## 目录结构

```
cv32e40p-branch-predictor/
├── README.md                # 本文件
├── branch-predictor.patch   # RTL 改动（b353438 → 最终版，9 文件 +546/-19）
├── docs/                    # 设计报告与验证计划
│   ├── 00_scope.md
│   ├── 01_architecture_map.md   # 取指路径图、信号表（file:line）、风险清单
│   ├── 03_verification_plan.md  # 环境/工具链/编译选项/复现命令
│   ├── 04_results.md            # 最终设计报告与结果汇总
│   ├── 05_area_decision.md      # 面积口径说明
│   └── 06_related_work.md       # 开源借鉴（CVA6 前端等）
├── scripts/                 # 复现脚本
│   ├── run_all.sh           # 一键：基线 → EN0/EN1 回归 → 单测 → 综合
│   ├── reproduce.sh         # 编译 5 固件 + EN0 基线运行
│   ├── build_tb.sh          # Verilator tb 构建
│   ├── g3_verify.sh         # EN0/EN1 功能回归
│   ├── g4_full.sh           # 定向测试 + 一致性
│   ├── g5_full.sh           # 性能/CPI 汇总
│   ├── run_unit_tests.sh    # BHT/BTB 单测 + lint
│   └── synth_sram.sh        # 全核综合（sv2v + Yosys）
└── tests/                   # 基准 + 定向测试 + 单测源
```

## 复现步骤

### 1. 依赖工具

| 工具 | 版本 | 安装 |
|---|---|---|
| riscv32-unknown-elf-gcc | 13.2.0 | Ubuntu: `apt install gcc-riscv64-unknown-elf`（多库含 rv32imc），并把 `riscv64-unknown-elf-*` 符号链接成 `~/.riscv/bin/riscv32-unknown-elf-*` |
| picolibc | 1.8.6 | `apt install picolibc-riscv64-unknown-elf`，头文件/库链接到 `~/.riscv/riscv32-unknown-elf/{include,lib}` |
| Verilator | ≥5.0 | `apt install verilator` 或 conda |
| Yosys | 0.33 | `apt install yosys` |
| sv2v | 0.0.13 | 下载 prebuilt 到 `project/tools/sv2v`（仅综合需要） |

### 2. 获取基线并打补丁

```bash
git clone https://github.com/openhwfoundation/cv32e40p
cd cv32e40p
git checkout b353438ff469c030c89f6804f3b24a2852880e8b
git apply ../cv32e40p-branch-predictor/branch-predictor.patch
```

### 3. 目录布局

```
workdir/
├── cv32e40p/    # 上面打好补丁的仓库
└── project/     # 本包内容（scripts/、tests/、docs/）
```

> 脚本默认 `REPO_DIR = $project/../cv32e40p`，即两者为同级目录。

### 4. 一键复现

```bash
cd project
./scripts/run_all.sh
```

依次执行：`reproduce.sh`（编译 5 固件 + EN0 基线）→ `g3_verify.sh`（EN0/EN1 回归）→
`run_unit_tests.sh`（BHT/BTB 单测）→ `synth_full.sh`（全核综合）。退出码 0 即全部通过。

也可单独跑综合（sv2v + Yosys，输出面积 CSV）：

```bash
./scripts/synth_sram.sh
```

### 5. 关键结果文件

- `metrics/g3_cycle_comparison.csv` — EN0/EN1 周期对比
- `metrics/g5_cycle_cpi.csv` — CPI/准确率/速度提升
- `metrics/g5r2_synth_full_cells.csv` — 全核综合面积（BASE/EN0/EN1）

## 核心架构结论（实测验证）

CV32E40P 的条件分支在 **EX** 阶段决议、跳转（JAL/JALR）在 **ID** 阶段决议。因此：

- **条件分支预测有收益**（IF 预测省 EX→IF 重定向气泡）——即本项目的 BHT/BTB。
- **跳转/返回预测零收益**（ID 已决议，同拍等价）——本项目曾实现 JAL 预测与 RAS，
  实测确认零收益后已回退（详见 `docs/04_results.md`）。

面积从原始寄存器 BTB 的 +155.41% 优化到同步读 SRAM 的 +25.2%，根因是"异步组合读被
综合工具摊平为逐 bit 的 128:1 mux"，改为同步读即可让综合工具推断 block RAM。
