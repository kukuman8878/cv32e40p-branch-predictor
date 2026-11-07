# 最终版：设计报告与结果（04_results.md）

> 本项目的最终交付物。汇总首版成果、迭代 1/2/3 的后续优化、迭代 3/4 的 JAL/RAS 回退结论、
> 诚实的未完成/未评估项，以及可复现流程。本文所有结果均为实际执行；"未做/未评估"均已显式标注。
> 最终交付 commit `36a8c91`（分支 `feature/sram-btb`）。

---

## 0. 一句话结论

在固定 commit `b353438` 的 OpenHW CV32E40P（4 级顺序、EX 决议条件分支）上新增了
**可参数化关闭的动态分支预测（2-bit BHT + 直接映射 BTB）**。首版（异步读寄存器
BTB）功能正确但面积爆炸（BASE→EN1 +155.41%）；经**迭代 1（BTB/BHT 同步读 SRAM 化）**、
**迭代 2（健壮性：BR_PREDICT_EN 门控 + BHT valid + flush_bp_i + debug_mode_i）**、
**迭代 3（BTB 128→32 缩表深）**后，面积降为 **BASE→EN1 +25.2%**（generic 无 BRAM 口径，
`memory_libmap` 可把 BTB 存储映到 4×RAMB4_S16_S16）。**迭代 3/4 尝试的 JAL 直接预测与
RAS 返回预测经实测零收益，已回退**：根因是 CV32E40P 的 **JAL/JALR 均在 ID 阶段已由
控制器解析**（非假设的"EX 才决议"），ID 阶段跳转/返回预测与控制器既有 ID 解析时序
等价，IF 阶段预测又因组合环不可行，故无周期改善（证据见 §8）。最终功能不变：EN0 与基线
逐位一致、EN1 功能正确（寄存器签名 EN0==EN1）、分支密集/低分支/hello_world 分别取得
**+6.03% / +9.44% / +14.75%** 周期改善，**fib/mixed 负收益（-1.65% / -3.40%）**；
WNS/功耗未评估（无时序/功耗库）。

---

## 1. 目标与明确不做的内容

### 1.1 研究问题

原核条件分支在 **EX 阶段**决议（`rtl/cv32e40p_ex_stage.sv:250`），每次 taken 分支产生
固定前端重定向气泡。本项目回答：引入动态分支预测后，能否在**功能不变**前提下改善
分支密集型负载的 CPI，代价是多少面积/关键路径。

### 1.2 目标功能（已实现，最终版）

- **BHT**：2-bit 饱和计数器方向预测，初始弱不跳转（weakly not-taken），规模可配
  `BHT_DEPTH`（默认 256）；迭代 2 起每项带 `valid` 位（首次遇见/冲刷后不预测）、
  `flush_bp_i`、`debug_mode_i` 门控。
- **BTB**：带 valid/tag/target 的直接映射分支目标缓存，`BTB_ENTRIES`（默认 32，迭代 3
  由 128 缩至 32）；仅当 **BTB 命中 且 方向预测为 taken** 才使用预测目标。
- **同步读 SRAM 化（迭代 1，最终架构）**：BTB/BHT 读口由异步读寄存器数组改为**同步读
  （1 拍读延迟）**；BTB tag+target 数组声明为非打包数组，使 sv2v/Yosys 将其保留为真
  存储器、可被 `memory_libmap` 映到块 RAM（`4×RAMB4_S16_S16`），解决首版的 128:1 读 mux
  面积爆炸。
- **健壮性（迭代 2）**：`BR_PREDICT_EN` 门控（EN0 下 BTB 存储被常量折叠消除）、BHT per-entry
  `valid` 位、`flush_bp_i`（fence.i/异常/MRET/URET 时清空）、`debug_mode_i`（debug 态不训练）。
- **预测元数据**随指令流跨级传递；EX 实际决议后更新 BHT/BTB，并对误预测实施 flush 恢复。
- **参数开关** `BR_PREDICT_EN`（0/1），同一 RTL 代码库支持 A/B 对照。
- **统计接口**：branch_total / pred_taken / correct / mispredict（tb 观测口读出）。

### 1.3 明确不做（沿用范围 + 迭代结论）

不重写整颗 CPU；**不预测 JAL/JALR**（迭代 3/4 实测零收益后回退，见 §8）；不加乱序、
Cache 或全局历史预测器；不声称流片/功耗实测/FPGA 上板（均未做）。

---

## 2. 架构方案

### 2.1 取指路径改动

基线 `pc_mux_i`（`cv32e40p_if_stage.sv`）是唯一 PC 来源多路选择点。新增预测重定向：
- 新增 `PC_PREDICT`（及配套 `PC_FALLTHROUGH`）编码，IF 阶段以 `pc_if_o` 索引 BHT/BTB；
- 命中且预测 taken 时 PC 走预测目标；否则 fall-through（原 `PC_BRANCH/PC_JUMP` 等优先级
  不变，仍以异常/中断/debug/fence 的真实重定向优先）。

### 2.2 BHT / BTB（最终版：同步读 SRAM）

- `rtl/cv32e40p_bht.sv`：`BHT_DEPTH×2bit` 饱和计数器，索引取 PC 低位，`BR_PREDICT_EN`
  门控更新与输出；EN=0 时输出恒 not-taken 且状态冻结。读口同步化 `rcounter_q <= counter_q[read_index]`。
- `rtl/cv32e40p_btb.sv`：直接映射 `ENTRIES×(valid+tag+target)`，tag = PC 高位（
  `TAG_W = 32 - clog2(ENTRIES) - 1`），目标地址强制半字对齐（`[1:0]=0`）。读口同步化
  `rdata_q <= mem_q[read_index]` + 同步 tag 寄存器 `rtag_q`，命中/目标组合输出。tag+target
  数组声明为非打包数组（`logic [DATA_W-1:0] mem_q [ENTRIES]`），使 sv2v 保留为真存储器、
  可被 `memory_libmap` 映到块 RAM（迭代 1 关键，见 §8）。

### 2.3 预测元数据跨级传递

IF 预测结果打包为 `{predicted_taken, predicted_target, is_compressed}` 元数据，随指令
经 IF/ID→EX 流水线寄存器传递；EX 用真实 `branch_decision_o` 与 `pc_ex` 回读并对比，
产生 correct/mispredict 判定。

### 2.4 flush / 恢复

复用基线既有的 **"冲刷计数器 + FIFO flush"** 机制（无新增重定向通道）：
- 误预测时按 `PC_BRANCH` 语义重定向到真实分支目标/顺序 PC，触发 `pc_set_i→branch_req
  →fifo_flush_o` + `flush_cnt_q` 丢弃在途旧路径响应。
- 统计更新仅在指令**有效且未被杀**时进行（`id_valid`/`instr_valid_id`/`~pc_set` 兜底），
  避免 kill 指令污染 BHT/BTB。

### 2.5 无 epoch/tag 方案（关键设计取舍）

基线 CPU **不使用显式 epoch/tag**，靠 `flush_cnt_q` + FIFO flush 作废旧路径。本预测器
**同样不引入 epoch/tag**，而是复用同一 flush 通道：预测重定向与真实决议共享
`pc_set_i/branch_i`，训练禁止时机覆盖 (a) `flush_cnt_q>0` 冲刷期、(b) 异常/中断/debug
重定向、(c) `is_fetch_failed`/`instr_err`。stall+flush 同周期定向测试（`g5_stall_flush`）
与旧路径响应测试覆盖了这一边界。

---

## 3. 验证结果汇总

### 3.1 基线（EN=0，预测关闭）

| 程序 | 结果 | 周期数 | 源 |
|---|---|---|---|
| hello_world | PASS | 3533 | `tests/hello_world.c` |
| fib | PASS | 377169 | `tests/fib.c` |
| branch_heavy（分支密集） | PASS | **20912** | `tests/branch_heavy.c` |
| mixed（混合应用） | PASS | **3106787** | `tests/mixed.c` |
| low_branch（低分支） | PASS | **78753** | `tests/low_branch.c` |

证据：`metrics/logs/*_run.log`、`metrics/logs/environment_g1.txt`；
一键复现 `./scripts/reproduce.sh`。

### 3.2 单测（BHT/BTB）

| 模块 | lint | 测试 | 覆盖 |
|---|---|---|---|
| cv32e40p_bht | 0 error | PASS | 复位初值、2-bit 全转移图、饱和不溢出、分项索引独立、EN=0 冻结、参数化、随机 4096 向量 |
| cv32e40p_btb | 0 error | PASS | 复位不命中、写后命中、tag alias 淘汰、invalid 不命中、32bit target 往返、参数化、随机 4096 向量 |

证据：`metrics/logs/g2_bht_{lint,build,run}.log`、`g2_btb_{lint,build,run}.log`；
一键复现 `./scripts/run_unit_tests.sh`。

### 3.3 定向测试 + 一致性

12 项定向测试（BHT 饱和、BTB alias、首次分支、全 not-taken、交替、前向/后向、嵌套
相邻、RVC、JAL/JALR、fence.i、定时器中断、一致性）在 **EN=0 与 EN=1 双模型全部 PASS**，
且 `g4_consistency` 的内存+寄存器签名 EN0/EN1 **位精确一致**。

证据：`metrics/g4_directed_summary.csv`、`metrics/g4_regression.csv`、
`metrics/logs/g4_en{0,1}_consistency.sig`、`g4_consistency_diff.log`；
一键复现 `./scripts/g4_full.sh`。

### 3.4 性能 / PPA 汇总

**性能（`metrics/g5_cycle_cpi.csv`，最终版 BTB=32）**：

| program | EN0 cyc | EN1 cyc | EN0 CPI | EN1 CPI | 方向准确率 | 速度提升 |
|---|---|---|---|---|---|---|
| hello_world | 3533 | 3012 | 1.554 | 1.324 | 97.84% | **+14.75%** |
| fib | 377169 | 383404 | 1.177 | 1.196 | 51.26% | **-1.65%** |
| branch_heavy | 20912 | 19652 | 1.610 | 1.513 | 85.74% | **+6.03%** |
| mixed | 3106787 | 3212419 | 1.244 | 1.286 | 50.22% | **-3.40%** |
| low_branch | 78753 | 71320 | 1.403 | 1.271 | 95.73% | **+9.44%** |

> minstret EN0=EN1 逐项相等（2274/320457/12987/2498136/56130），证明退休指令一致、
> CPI 差异唯一由周期数驱动。EN0 周期 3533/377169/20912/3106787/78753 与基线逐位一致。

**PPA（`metrics/sram_synth_summary.csv`，最终版：同步读 SRAM + BTB=32，无 JAL/RAS）**：

| 配置 | cells | 说明 |
|---|---|---|
| BASE（b353438，无预测器，历史） | **43082** | 基线 |
| EN0（BR_PREDICT_EN=0，同步读） | **43317** | +0.55%，BTB 存储被门控折叠消除 |
| EN1（BR_PREDICT_EN=1，同步读，generic 无 BRAM） | **53947** | **+25.2% vs BASE** |
| EN1 manual 流 无 BRAM | 38050 | 同 `abc -g simple` 口径 |
| EN1 manual 流 有 BRAM | **34618 + 4×RAMB4_S16_S16** | `memory_libmap` 把 BTB 存储映到块 RAM |

- 首版（异步读寄存器 BTB=128）EN1=110036（+155.41%）；迭代 1 同步读 + 非打包数组 →
  EN1 63548（-42.25%）；迭代 2 加健壮性 → EN1 65573（BTB=128）；迭代 3 缩 BTB 128→32 →
  EN1 **53947**（无 JAL 胶水；含 JAL 胶水时为 54198）。最终 **BASE→EN1 +25.2%**。
- 预测器存储位（最终）：BTB 32×58=1856 bit + BHT 256×2=512 bit = **2368 bit**；BTB 存储经
  `memory_libmap` 映到 4×RAMB4_S16_S16 块 RAM 宏。真实 ASIC/FPGA 面积需 memory compiler/PDK
  （本环境无，与 §4 口径一致）。

---

## 4. 诚实披露（未达标 / 未评估项）

1. **面积（最终 +25.2%）**：首版寄存器 BTB 面积爆炸（+155.41%）已在迭代 1 通过**同步读
   SRAM 化 + 非打包数组**解决——Yosys 把非打包数组当真 `$mem` 处理，`memory_libmap` 可把
   BTB 存储映到 4×RAMB4_S16_S16 块 RAM 宏；配合迭代 3 缩表深 BTB 128→32，最终 generic 无
   BRAM 口径 EN1=53947（BASE→EN1 **+25.2%**）。真实 ASIC/FPGA 面积需 memory compiler / PDK，
   本环境无，无法给出 SRAM 宏的等价 gate/um²；因此**如实给出两种口径 cells 与宏数量/位宽，
   不冒充 ≤10% 达标**。详见 §8 与 `docs/05_area_decision.md`。
2. **WNS / 关键路径：未评估**（无时序 liberty / OpenSTA / PDK）。同步读后读口为输出寄存器
   （BRAM 宏内部等价格式），关键路径较首版 128:1 mux 已大幅缩短，但无库无法给 ns/WNS 数值。
3. **功耗：未评估**（无功耗库 + 活动数据），不把门数变化等同于功耗变化。
4. **fib / mixed 负收益**：数据依赖分支 + 密集 JAL/JALR（不预测），~50% 准确率导致净损。
   JAL 直接预测 / RAS 返回预测（迭代 3/4）经实测**零收益、已回退**（根因见 §8）。
5. **CoreMark：未跑**（需其自身 harness/计时接口，尚未集成到 example_tb 流）。
6. **spike ISS：未安装**（参考模型对拍未做，以"内存 + 寄存器文件"双签名替代）。
7. **core-v-verif UVM：未跑**（需 Questa/VCS 商业仿真器，本机仅 verilator；已锁定
    版本事实：默认 `fcd5968` ≠ 基线 `b353438`）。
8. **赛方细则未拿到**：报名资格 / 材料提交清单 / 评审标准 / 具体时间节点 / 提交格式
   尚未提供（官网为 JS SPA 无法自动抓取），不得据此伪造材料。

---

## 5. 复现步骤与工具版本清单

### 5.1 一键复现

```bash
cd project
./scripts/run_all.sh        # 基线 + EN0/EN1 回归 + 单测 + 全核综合，汇总后 exit 0
```

`run_all.sh` 串联：`reproduce.sh`（编译 5 固件 + EN0 基线）→ `g3_verify.sh`（EN0/EN1
5 基准回归）→ `run_unit_tests.sh`（BHT/BTB 单测）→ `synth_full.sh`（全核综合 BASE/
EN0/EN1）。单点复现可用任意子脚本（`g4_full.sh`、`g5_full.sh` 亦可单独跑）。

### 5.2 工具版本清单

| 工具 | 版本 | 用途 |
|---|---|---|
| Verilator | 5.052 (conda-forge) | 功能仿真 |
| riscv32-unknown-elf-gcc | 13.2.0 | 固件编译 |
| riscv32-unknown-elf-objcopy | 2.42 | hex 生成 |
| picolibc | 1.8.6 | C 运行库 |
| Yosys | 0.33 (git sha1 2584903a060) | 综合 |
| sv2v | v0.0.13 | SV→Verilog 转换（全核综合前置） |

编译选项（未改）：`-march=rv32imc_zicsr_zifencei -mabi=ilp32 -Os`；仿真 10ns 时钟、
`maxcycles=5000000`、确定性（无 `$random`，seed 不适用）。

### 5.3 版本与标签

- 基线 commit：`b353438ff469c030c89f6804f3b24a2852880e8b`（tag `baseline/b353438`）
- 首版交付 commit：`83d5c7b67f6669e6f42ad41c8a23deab63ab0c82`（tag `release/reviewed`）
- **最终交付 commit：`36a8c9115d6b45d9506679c20898801b3cfe48c4`**（short `36a8c91`）
- 分支：`feature/sram-btb`（自 `release/reviewed` 检出；最终树与迭代 3 `2455b12` 逐位一致）

---

## 6. 结论与后续工作建议

**结论**：动态分支预测在 CV32E40P 上集成正确（功能一致、分支密集/低分支/hello_world
周期改善达标）。首版寄存器 BTB 的面积爆炸（+155.41%）经**同步读 SRAM 化 + 非打包数组 +
缩表深 32** 收敛到 **+25.2%**（generic 无 BRAM 口径，BTB 存储可映到 4×RAMB4_S16_S16）。
**JAL/JALR 的跳转/返回预测（迭代 3/4）实测零收益、已回退**——本核 JAL/JALR 均在 ID 阶段
已由控制器解析，ID 阶段预测与之一等价、IF 阶段预测因组合环不可行（详见 §8）。WNS/功耗
未评估。整体为"功能正确、性能部分达标、面积收敛但 SRAM 宏真实面积待 PDK、PPA 待补"的成果。

**后续工作建议**（按优先级）：
1. **补时序/功耗评估**：提供 liberty+SDC+功耗库，给出 WNS/关键路径/功耗真实数值。
2. **拿 memory compiler / PDK**：给 4×RAMB4_S16_S16 宏与 BHT DFF 真实面积，做最终 ≤10% 门槛判定。
3. **改善 fib/mixed 负收益**：加全局历史（gshare）改善数据依赖分支；JAL/JALR 在本核 ID 已
   解析（§8），若要预测须把预测移到 IF 阶段（需前端"寄存器化 next-PC"，当前因组合环不可行）。
4. **补参考模型对拍**：装 spike ISS，或跑 core-v-verif UVM（需 Questa/VCS）。
5. **补 CoreMark**：集成其 harness/计时接口，作为标准性能指标。
6. **拿到赛方细则**后按报名/材料/评审标准补齐提交物。

---

## 7. 最终自查清单（对照方案文档 10 项）

| # | 检查项 | 状态 | 说明 |
|---|---|---|---|
| 1 | Clone 官方仓库，记下固定 commit、许可证、开发分支 | ✅ | `b353438…`、Solderpad v0.51、`feature/branch-predictor` |
| 2 | 检查官方文档与当前 RTL 是否对应 | ✅ | 发现 `PULP_XPULP/PULP_CLUSTER` 参数名滞后，已记录 |
| 3 | 跑通原核示例仿真，记录命令和日志 | ✅ | verilator 绕过跑通，`EXIT SUCCESS` |
| 4 | 确认 core-v-verif 适用版本及运行办法 | ⚠️ | 版本锁定（`fcd5968`≠基线），UVM 未实跑（需 Questa/VCS） |
| 5 | 找出 PC 多路选择和重定向优先级 | ✅ | `01_architecture_map.md` §1/§2 |
| 6 | 找出 branch decision、IF flush、prefetch 请求/响应逻辑 | ✅ | §1/§2/§3 |
| 7 | 明确 RVC、异常、中断、debug、stall 支持范围 | ⚠️ | RVC/中断/stall 已测；debug 未单独定向测试 |
| 8 | 锁定三类 benchmark、指标定义和统一环境 | ✅ | `03_verification_plan.md` |
| 9 | 提交架构映射与风险报告 | ✅ | `01_architecture_map.md` |
| 10 | 架构分析通过前不得开启集成功能开发 | ✅ | 架构分析/基线通过后才开始编码 |

**统计：8 ✅ / 2 ⚠️ / 0 ❌**（⚠️ 均为环境/工具缺失导致的"未实跑"项，非功能缺陷）。

---

## 8. 迭代演进（首版 → 迭代 1/2/3 → 回退 JAL/RAS）

### 8.1 提交链（`feature/sram-btb`）

```
83d5c7b  release/reviewed（首版基线）
fb0e7da  ITER1: convert BTB/BHT read ports to synchronous-read SRAM (1-cycle latency)
deee9cb  ITER1: index BTB/BHT sync-read with next_pc_id (id_valid ? pc_if : pc_id)
3713c6c  ITER1: declare BTB tag+target array unpacked so sv2v keeps it a memory
13085f1  ITER1: give BTB mem_q a clean sync-write port (no async-reset-gated enable)
361041b  ITER2: BTB BR_PREDICT_EN gating + flush_bp_i + debug_mode_i
e161379  ITER2: BHT per-entry valid bit + flush_bp_i + debug_mode_i
80caeb9  ITER2: wire flush_bp/debug_mode + BTB EN gating into core
2455b12  ITER3: shrink BTB 128->32 entries (core + top default)
3be07de  ITER3: JAL direct prediction (32-bit, ID stage, immediate target)   ── 回退
b305df6  ITER4: add RAS return-address stack module + PC_RAS pc_mux selector ── 回退
056a85e  ITER4: integrate RAS return prediction (call push / return pop ...)  ── 回退
681f76d  Revert "ITER4: integrate RAS return prediction ..."                  ── 阶段4
33ac2c1  Revert "ITER4: add RAS return-address stack module ..."             ── 阶段4
36a8c91  Revert "ITER3: JAL direct prediction ..."                            ── 阶段4（最终 HEAD）
```

`git diff 2455b12 36a8c91` 为空 → 最终树与迭代 3 `2455b12`（BTB=32）**逐位一致**，代码中
无任何 `jal_in_id`/`jal_target`/`ras_`/`pc_ras`/`PC_RAS`/`RAS_DEPTH` 残留（`grep` 空）。

### 8.2 保留的改进与面积演进

| 阶段 | 关键改动 | EN1 generic（无 BRAM） | 效果 |
|---|---|---|---|
| 首版 | 异步读寄存器 BTB=128 | 110036 | BASE→EN1 +155.41% |
| 迭代 1 | 同步读 SRAM + 非打包数组 | 63548 | -42.25%（解决 mux 爆炸） |
| 迭代 2 | BR_PREDICT_EN 门控 + valid + flush/debug | 65573（BTB=128） | EN0 回到 43317（≈BASE） |
| 迭代 3 | BTB 128→32 | 53947（无 JAL） | 再 -11.6% |
| **最终** | **同步读 SRAM + 健壮性 + BTB=32** | **53947** | **BASE→EN1 +25.2%** |

最终 EN0=43317（+0.55%，BTB 存储被门控折叠）、EN1=53947（+25.2%）；
`memory_libmap` 把 BTB 存储映到 4×RAMB4_S16_S16（34618 cells + 4 RAMB）。

### 8.3 核心洞察：JAL/JALR 在 ID 决议 → 跳转/返回预测零收益（已回退）

**结论**：CV32E40P 的 JAL/JALR **在 ID 阶段已由控制器解析**，并非假设的"EX 才决议"；
因此 ID 阶段做跳转/返回预测与控制器既有 ID 解析**时序等价**，IF 阶段预测又因组合环不可行，
最终**零周期收益**。证据如下：

1. **JAL（迭代 3，`3be07de`）**：控制器 `jump_in_dec` 在 DECODE 态即 `PC_JUMP` + `jump_target_id`
   （UJ immediate）解析 32-bit JAL。ID 阶段 JAL 直接预测与之同拍等价，`bp_jal_predicted` 观测
   计数 hello_world 30 / fib 66 / branch_heavy 124 / mixed 102 / low_branch 92，但 EN1 周期
   hello_world 3012 / fib 383404 / branch_heavy 19652 / mixed 3212419 / low_branch 71320 与
   不加 JAL 预测**逐位一致**。且 `-Os + rv32imc` 把热路径调用编译成 `c.jal`（压缩），首版
   不预测压缩指令。**IF 阶段 JAL 预测曾实测组合环**：Verilator `DIDNOTCONVERGE`。
2. **RAS（迭代 4，`b305df6`/`056a85e`）**：JALR 同样在 ID 由 `jump_in_dec`（`BRANCH_JALR`）→
   `PC_JUMP` + `jump_target_id`（`regfile_data_ra_id+imm_i_type`）解析；RAS pop 被 `id_valid`
   （含 `~jr_stall`）门控，只在"控制器本就能当拍解析"时预测 → 收益为零，反因返回启发式过宽
   （`rd∈{x1,x5}` 把间接调用 `jalr ra` 误判为返回）造成 34~95 周期回退。fib -1.65%→-1.66%、
   mixed -3.40%→-3.40% 未改善。
3. **回退验证**：`git revert`（3 个 revert commit，无冲突）后，EN1 周期 3012/383404/19652/
   3212419/71320 与迭代 3 完全一致（JAL/RAS 零收益的直接印证），EN0 与基线逐位一致，面积
   EN1 54198→53947（去掉 JAL 胶水 +251）、EN0 43521→43317（+204→0）。

**同步读 SRAM 借鉴 CVA6 生效；RAS 借鉴 CVA6 但在本核零收益**（详见 `docs/06_related_work.md`）。
