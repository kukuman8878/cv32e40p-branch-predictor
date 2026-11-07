# 开源项目调研与可借鉴点（06_related_work.md）

调研时间 2026-11-04。目标：为本项目（CV32E40P + 动态分支预测）找可直接借鉴的开源实现，
重点解决已暴露的**面积爆炸**（寄存器 BTB 被摊平为巨型 mux）与若干正确性/健壮性问题。

## 一、最直接参考：OpenHW Group CVA6 前端（同组织、SystemVerilog）

仓库：https://github.com/openhwgroup/cva6 ，许可证 Solderpad Hardware License v2.0（与本项目基线一致）。

| 文件 | 作用 | 可借鉴点 |
|---|---|---|
| `core/frontend/btb.sv` | BTB，**FPGA/ASIC 双实现** | FPGA 版用 `SyncDpRam`(BRAM) 存目标地址；ASIC 版用 DFF 数组。**直接印证本项目的"SRAM 口径"决策**：真实实现本就该用 SRAM/BRAM，而非 DFF+mux |
| `core/frontend/bht.sv` | 2-bit 饱和 BHT | ① 每项带 `valid` 位处理"首次遇见"；② `flush_bp_i` 在上下文切换/异常时清空预测器；③ `debug_mode_i` 时不训练；④ 复位/冲刷偏置为 `2'b10`（弱跳，与我们选弱不跳相反，属可选策略）；⑤ 饱和更新 `always_comb` 模板清晰可抄 |
| `core/frontend/ras.sv` | 返回地址栈 | 未来加 JAL/JALR 预测（当前首版不做） |
| `core/frontend/frontend.sv` | 前端集成 | 预测如何接进取指 PC 选择的参考 |

关键结论：
1. **面积问题**：CVA6 的 BTB 在 FPGA 上明确用 BRAM（`SyncDpRam`），ASIC 才用 DFF——说明我们遇到的"寄存器 BTB → 128:1 mux 爆炸"是业界公认的坑，解决办法就是 SRAM/BRAM 宏。本项目的 SRAM 口径裁决与 CVA6 实践一致。
2. **健壮性**：可借用 `flush_bp_i`（context switch 清空）、`debug_mode_i` 门控、`valid` 位首次遇见处理。我们当前 BTB 有 tag（比 CVA6 的 ASIC BTB 更强，CVA6 直接映射无 tag）。

## 二、规模相近的 RV32 教育/竞赛核（含 branch_predictor.sv）

| 仓库 | 说明 | 可借鉴点 |
|---|---|---|
| `gws8820/RISCV-CPU` | 6 级 RV32IM FPGA 核，263.7 CoreMark/91 DMIPS@100MHz | 单发射核上做分支预测的成熟实践 |
| `chenyuliu577-cyber/jyd-rv32i-fpga-core` | RV32I FPGA 核（JYD RISC-V 赛题，Vivado） | 与本赛事（CIE RISC-V）同源的竞赛级实现，`Branch_Predictor.sv` |
| `HuayuSha/RISC-V_PIPELINE` | 复旦计组(H) 五级流水线 | 教学级 BHT/BTB 简洁实现 |
| `janomach/the-hardisc` | 加固 RISC-V 核 | `branch_predictor.sv` |
| `kyjiang24/RISCV-out-of-order-CPU` | 乱序核，gshare 预测 | gshare 思路（进阶） |

## 三、高性能参考（Chisel 实现，仅借鉴思路，非可直接抄 Verilog）

- **Rocket Chip**（`rocket` 的 BTB + gshare 方向预测）
- **BOOM**（TAGE 等复杂预测器）

## 四、对下一版迭代的具体建议（按收益/成本排序）

1. **BTB 改 SRAM/BRAM 实现**（借 CVA6 `SyncDpRam` 模式）→ 直接解决 +155% 面积超标。
2. **加 `flush_bp_i`**：fence.i / 异常 / 上下文切换时清空 BTB valid + BHT 复位，增强正确性边界。
3. **加 `debug_mode_i` 门控**：debug 模式下不训练预测器。
4. **BHT 加 `valid` 位**：首次遇见分支不做方向预测，避免冷启动污染（当前弱不跳初始化在"全 taken"负载下会连续误预测）。
5. **缩小表深 + 收窄 tag**：BTB_ENTRIES 128→32，tag 用抗别名位（CVA6 `ANTIALIAS_BITS=8` 思路）。
6. **进阶**：加 RAS 预测 JAL/JALR，改善 fib/mixed 的负收益；再进阶 gshare 改善数据依赖分支。

## 五、迭代结论（阶段 1–4 实测回填，2026-11-06）

上文"四"的 6 条建议中，第 1–5 条已在迭代 1–3 落地并**生效**；第 6 条（RAS 预测 JAL/JALR）
经迭代 3/4 实测**零收益、已回退**。逐条回填：

| # | 建议 | 迭代 | 落地结果 | 是否生效 |
|---|---|---|---|---|
| 1 | BTB 改 SRAM/BRAM | 迭代 1 | 同步读 + 非打包数组，`memory_libmap` 映到 4×RAMB4_S16_S16 | ✅ 生效，EN1 110036→63548（-42.25%） |
| 2 | `flush_bp_i` | 迭代 2 | 复用 `pc_set`/`pc_mux`（FENCEI/EXCEPTION/MRET/URET）清 valid | ✅ 生效（单测 T8 覆盖） |
| 3 | `debug_mode_i` | 迭代 2 | 门控训练、读保留，语义对齐 CVA6 | ✅ 生效（单测 T9 覆盖） |
| 4 | BHT `valid` 位 | 迭代 2 | per-entry valid + flush 清 valid | ✅ 生效（单测 T7 覆盖） |
| 5 | 缩表深 32 | 迭代 3 | BTB_ENTRIES 128→32 | ✅ 生效，EN1 65573→53947（-17.7%） |
| 6 | RAS 预测 JAL/JALR | 迭代 3/4 | JAL 直接预测 + RAS 返回栈 | ❌ **零收益，已回退** |

**关键结论（核心洞察）**：

1. **同步读 SRAM 借鉴 CVA6 生效**：CVA6 FPGA 版 BTB 用 `SyncDpRam`（BRAM）而非 DFF+mux，
   与本项目迭代 1 的"同步读 + 非打包数组"完全同源，实测把面积从 +155.41% 收敛到 +25.2%，
   且 BTB 存储可映到 4×RAMB4_S16_S16 块 RAM 宏。**这是本调研最直接、最有效的一条借鉴。**

2. **RAS 借鉴 CVA6 但在本核零收益**：CVA6 的 `frontend/ras.sv` 返回地址栈借鉴过来机制完整、
   功能正确（call push / return pop / EX 校验 + 恢复），但 CV32E40P 与 CVA6 的**流水线差异**
   决定了收益不同——CV32E40P 的 **JAL/JALR 在 ID 阶段已由控制器解析**（`jump_in_dec`→
   `PC_JUMP`+`jump_target_id`），ID 阶段 RAS 预测与之同拍等价；而 CVA6 是 6 级流水、返回目标
   在更晚阶段决议，RAS 能在更早阶段预测才有收益。此外 CV32E40P 前端无"寄存器化 next-PC"，
   IF 阶段预测会构成组合环（迭代 3 已实证 Verilator `DIDNOTCONVERGE`）。故 RAS 在本核
   **零周期改善**，反而因启发式过宽带来 34~95 周期回退，已随 JAL 预测一并回退。

3. **教训**：跨核借鉴预测器时，必须先核对目标核的**分支/跳转决议阶段**与**前端重定向结构**；
   同一机制的收益强依赖流水线级数与 next-PC 是否寄存器化，不能只看模块接口语义相同。
