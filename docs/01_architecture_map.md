# G0 架构分析：CV32E40P 分支预测集成前的基础架构地图

> 本文件为 Agent A（分析与实施）在 **G0 架构分析 Gate** 的只读分析产出，不改动任何功能 RTL。
> 所有 `文件:行号` 引用均来自基线 commit `b353438ff469c030c89f6804f3b24a2852880e8b` 的实际源码，未确认之处已标注。

---

## 0. 仓库与版本事实

| 项目 | 值 | 证据 |
|---|---|---|
| 上游仓库 | https://github.com/openhwfoundation/cv32e40p | clone 成功 |
| 真实 commit hash | `b353438ff469c030c89f6804f3b24a2852880e8b` | `git rev-parse HEAD` |
| 默认分支 | `master` | `git symbolic-ref refs/remotes/origin/HEAD` → `refs/remotes/origin/master` |
| 许可证 | Solderpad Hardware License v0.51（可视为 Apache-2.0 兼容） | `LICENSE` 第 1 行；`README.md` 头 |
| 流水线级数 | 4 级：IF / ID / EX / WB | `docs/source/pipeline.rst:29`、`docs/source/intro.rst:21` |
| 分支/跳转决议位置 | 跳转(JAL/JALR)在 **ID**，条件分支在 **EX** | `docs/source/pipeline.rst` 阶段说明 |

### 文档与 RTL 对应性核对结果

- 官方 `docs/source/pipeline.rst` 说明 4 级顺序流水线，与 RTL 模块名一致：
  `cv32e40p_if_stage.sv`(IF)、`cv32e40p_id_stage.sv`(ID)、`cv32e40p_ex_stage.sv`(EX)、写回由 `cv32e40p_load_store_unit.sv`(LSU, WB)。
- **发现一处不一致（重要）**：`example_tb/core/cv32e40p_tb_subsystem.sv:18-19` 与 `tb_top.sv:20-21` 仍使用旧参数名
  `PULP_XPULP` / `PULP_CLUSTER`，而当前 RTL `rtl/cv32e40p_top.sv:27-28` 已重命名为
  `COREV_PULP` / `COREV_CLUSTER`。即 **example_tb 相对当前 master RTL 是滞后的**，未经修改无法直接编译。

---

## 1. 取指路径图（文字版）

```
[PC 选择 mux]  cv32e40p_if_stage.sv:155-171 (always_comb, pc_mux_i 选择)
   PC_BOOT     -> boot_addr_i{31:2,2'b0}                     (if_stage:160)
   PC_JUMP     -> jump_target_id_i   (JAL/JALR, 来自 ID)     (if_stage:161)
   PC_BRANCH   -> jump_target_ex_i   (条件分支, 来自 EX)      (if_stage:162)
   PC_EXCEPTION-> exc_pc             (mtvec 向量/异常)        (if_stage:163)
   PC_MRET/URET/DRET -> mepc/uepc/depc (xRET 返回)           (if_stage:164-166)
   PC_FENCEI   -> pc_id_o + 4                                  (if_stage:167)
   PC_HWLOOP   -> hwlp_target_i                                (if_stage:168)
         |
         v
[branch_req 触发]  branch_req = pc_set_i                      (if_stage:217-218)
         |
         v
[prefetch_buffer]  cv32e40p_prefetch_buffer.sv
         |-- prefetch_controller (if_stage 实例化:179-209)
         |      - FSM IDLE/BRANCH_WAIT, 目标地址 replay  (prefetch_controller:168-199)
         |      - 提交 OBI trans, 计数 cnt_q                (prefetch_controller:146,223-243)
         |-- fetch FIFO (FIFO_DEPTH=2)                     (prefetch_buffer:60,123-140)
         |      - fall-through: fetch_rdata_o = fifo_empty?resp:fifo (prefetch_buffer:144)
         |-- obi_interface -> instr_req_o/instr_addr_o      (prefetch_buffer:150-182)
         v
[取指总线]  instr_req_o / instr_gnt_i / instr_rvalid_i / instr_rdata_i
         v
[aligner]  cv32e40p_aligner.sv  (RVC 半字对齐, 产生 pc_if_o)
         |-- 分支目标半字未对齐 -> BRANCH_MISALIGNED       (aligner:222-223)
         v
[compressed_decoder]  RVC -> RV32I 解压                    (if_stage:273-281)
         v
[IF/ID 流水线寄存器]  instr_valid_id_o, instr_rdata_id_o,
                      pc_id_o, is_compressed_id_o           (if_stage:230-252)
         v
[ID stage]  cv32e40p_id_stage.sv
         |-- JAL/JALR 目标计算 (JT_JAL/JT_COND/JT_JALR)      (id_stage:575-580)
         |-- jump_target_o -> if_stage jump_target_id_i       (id_stage:584)
         v
[EX stage]  cv32e40p_ex_stage.sv
         |-- branch_decision_o = alu_cmp_result               (ex_stage:250)
         |-- jump_target_o    = alu_operand_c_i (分支目标)    (ex_stage:251)
         v
[重定向回 IF]  controller 生成 pc_set_o/pc_mux_o (PC_BRANCH/PC_JUMP/PC_EXCEPTION)
              -> if_stage pc_set_i/branch_req -> prefetch flush
```

**关键结论**：条件分支的决议（taken/not-taken）在 **EX 阶段**才产生（`ex_stage.sv:250`），
因此未预测时每条条件分支会有固定的流水线气泡；跳转（JAL/JALR）在 **ID 阶段**即已知目标，
由 `controller.sv:543-554` 直接 `PC_JUMP` 重定向。分支预测器的核心价值在于把条件分支的
重定向从 EX 提前到 IF（预测），从而消除 EX 阶段的预测气泡。

---

## 2. 信号表（含 file:line）

### 2.1 取指请求 / 授权 / 返回

| 信号 | 方向/含义 | 文件:行号 |
|---|---|---|
| `instr_req_o` | 取指请求（IF→总线） | rtl/cv32e40p_if_stage.sv:53 |
| `instr_addr_o` | 取指地址 | rtl/cv32e40p_if_stage.sv:54 |
| `instr_gnt_i` | 取指授权 | rtl/cv32e40p_if_stage.sv:55 |
| `instr_rvalid_i` | 取指数据有效 | rtl/cv32e40p_if_stage.sv:56 |
| `instr_rdata_i` | 取指数据 | rtl/cv32e40p_if_stage.sv:57 |
| `req_i` | ID 阶段取指请求使能 | rtl/cv32e40p_if_stage.sv:50 |
| `instr_req_o`（控制器侧） | 控制器取指请求 | rtl/cv32e40p_controller.sv:72 |

### 2.2 指令有效 / 译码

| 信号 | 含义 | 文件:行号 |
|---|---|---|
| `instr_valid_id_o` | IF/ID 指令有效 | rtl/cv32e40p_if_stage.sv:62 |
| `instr_rdata_id_o` | IF/ID 指令数据 | rtl/cv32e40p_if_stage.sv:63 |
| `is_compressed_id_o` | 压缩指令标志 | rtl/cv32e40p_if_stage.sv:64 |
| `illegal_c_insn_id_o` | 非法压缩指令 | rtl/cv32e40p_if_stage.sv:65 |
| `pc_if_o` / `pc_id_o` | IF PC / ID PC | rtl/cv32e40p_if_stage.sv:66-67 |
| `instr_valid_i`（控制器） | 输入指令有效 | rtl/cv32e40p_controller.sv:69 |
| `is_fetch_failed_o` | 取指失败 | rtl/cv32e40p_if_stage.sv:68 |

### 2.3 分支 / 跳转决议

| 信号 | 含义 | 文件:行号 |
|---|---|---|
| `branch_in_ex_o` | EX 阶段存在条件分支 | rtl/cv32e40p_id_stage.sv:70（赋值 1598） |
| `branch_decision_i` | 分支 taken 决议（来自 EX） | rtl/cv32e40p_id_stage.sv:71 |
| `branch_taken_ex` | `= branch_in_ex_o && branch_decision_i` | rtl/cv32e40p_id_stage.sv:558 |
| `jump_target_o`（ID） | 跳转目标（JAL/JALR） | rtl/cv32e40p_id_stage.sv:72,584 |
| `jump_target_id_i` | IF 阶段跳转目标输入 | rtl/cv32e40p_if_stage.sv:86 |
| `jump_target_ex_i` | IF 阶段分支目标输入 | rtl/cv32e40p_if_stage.sv:87 |
| `branch_decision_o` | EX 比较结果（taken） | rtl/cv32e40p_ex_stage.sv:250 |
| `jump_target_o`（EX） | EX 分支目标 | rtl/cv32e40p_ex_stage.sv:251 |
| `ctrl_transfer_insn_in_dec` | 译码阶段转移类型 | rtl/cv32e40p_core.sv:162 |
| `jump_in_dec` | `= JALR \|\| JAL` | rtl/cv32e40p_controller.sv:295 |
| `branch_in_id` | `= BRANCH_COND` | rtl/cv32e40p_controller.sv:297 |

### 2.4 flush / stall

| 信号 | 含义 | 文件:行号 |
|---|---|---|
| `clear_instr_valid_o` | 清 IF/ID 指令有效 | rtl/cv32e40p_id_stage.sv:76,556 |
| `pc_set_o` | 重定向 PC（触发 branch_req） | rtl/cv32e40p_id_stage.sv:77 / controller.sv:75 |
| `pc_mux_o` | PC 选择 | rtl/cv32e40p_id_stage.sv:78 / controller.sv:76 |
| `halt_if_o` | 暂停 IF | rtl/cv32e40p_id_stage.sv:88 / controller.sv:188 |
| `halt_id_o` | 暂停 ID | rtl/cv32e40p_controller.sv:189 |
| `id_ready_o` | ID 就绪 | rtl/cv32e40p_id_stage.sv:90,1679 |
| `fifo_flush_o` | 分支时冲刷取指 FIFO | rtl/cv32e40p_prefetch_controller.sv:305 |
| `flush_cnt_q` | 分支后待丢弃的旧响应计数 | rtl/cv32e40p_prefetch_controller.sv:89-90,322-341 |
| `fetch_valid_o` | `= (fifo_valid\|resp_valid) && !(branch_i\|(flush_cnt_q>0))` | rtl/cv32e40p_prefetch_controller.sv:123 |
| `branch_i`（prefetch） | 取指侧分支指示 | rtl/cv32e40p_prefetch_controller.sv:51 |

### 2.5 异常 / 中断 / debug 优先级（DECODE 状态内，自上而下即优先级）

| 优先级 | 条件 | 动作 | 文件:行号 |
|---|---|---|---|
| 1 | `branch_taken_ex_i`（EX 分支 taken） | `PC_BRANCH`+`pc_set` | controller.sv:432-439 |
| 2 | `data_err_i`（数据错误） | `FLUSH_WB` | controller.sv:447-460 |
| 3 | `is_fetch_failed_i` | `FLUSH_WB` | controller.sv:464-478 |
| 4 | `debug_req_pending / trigger_match` | `DBG_FLUSH` | controller.sv:491-497 |
| 5 | `irq_req_ctrl_i` | `PC_EXCEPTION`+`EXC_PC_IRQ` | controller.sv:500-527 |
| 6 | `illegal_insn_i` | `FLUSH_EX` | controller.sv:531-536 |
| 7 | `jump_in_dec`(JAL/JALR) | `PC_JUMP` | controller.sv:543-554 |
| 8 | ebreak/wfi/ecall/fencei/mret… | 各类 flush | controller.sv:556-596 |

---

## 3. 事务风险说明（重定向后旧取指的作废）

CV32E40P **不使用显式 epoch/tag**，而是采用 **“冲刷计数器 + FIFO flush”** 机制：

1. **FIFO 冲刷**：分支发生时 `fifo_flush_o = branch_i`（`prefetch_controller.sv:305`），
   直接清空取指 FIFO 中已缓冲但尚未发射到 ID 的旧路径指令。
2. **在途响应丢弃**：`flush_cnt_q` 在分支瞬间被置为“当时在途事务数 `cnt_q`”
   （`prefetch_controller.sv:328-331`），随后每收到一个旧响应 `flush_cnt_q` 减 1，
   直到归零。在此期间 `fetch_valid_o` 被强制为 0（`prefetch_controller.sv:123`），
   旧路径返回的数据不会进入流水线。
3. **PC 重定向入口**：`pc_set_i` → `branch_req`（`if_stage.sv:217-218`）→ prefetch
   controller 的 `branch_i`，由 FSM 的 `BRANCH_WAIT` 保证分支目标地址在被总线授权前
   保持稳定（`prefetch_controller.sv:188-197`）。

**对分支预测集成的影响（关键）**：
- 上述机制假定“重定向点就是 `pc_set_i` 拉高的那一拍”。若预测器把重定向提前到 IF
  （预测跳转），必须复用同一 `pc_set_i/branch_i/flush` 路径，否则会出现**新取指与旧
  取指混流**。
- 预测器**自身需要 epoch/tag**（或等价机制）来标记“本预测结果属于哪一代取指”，以
  防止 EX 阶段姗姗来迟的真实分支决议错误地更新了新一代预测状态（污染 BHT/BTB）。
- **训练禁止时机**：在 (a) `flush_cnt_q>0` 的旧响应冲刷期、(b) 异常/中断/debug 的
  `PC_EXCEPTION` 重定向、(c) `is_fetch_failed` / `instr_err` 期间，应禁止更新预测器，
  因为此时 PC 与“实际执行指令”的对应关系已破坏。

---

## 4. 集成可行性报告

### 4.1 可插入位置

- **预测重定向注入点**：`cv32e40p_if_stage.sv:159-171` 的 `pc_mux_i` case 是唯一 PC
  来源多路选择点。新增 `PC_PREDICT` 分支（扩展 `pc_mux_i` 编码，定义于
  `rtl/include/cv32e40p_pkg.sv`），或复用 `PC_BRANCH` 通道但以预测结果驱动
  `jump_target_ex_i`。
- **BTB/BHT 查询点**：IF 阶段 `pc_if_o`（`if_stage.sv:66`）或 `pc_id_o`。推荐以
  `pc_if_o` 作为预测索引，保证与取指同拍。
- **训练/更新点**：EX 阶段 `branch_decision_o`（`ex_stage.sv:250`）与 `pc_ex`
  （`id_stage.sv` 输出 `pc_ex_o`，见 `core.sv:578`）组合出“真实分支结果 + 分支 PC”，
  用于更新 BHT 计数器和 BTB tag/target。

### 4.2 旁路与寄存器路径

- 预测器的时延必须 ≤ 取指路径关键路径预算。当前 IF 阶段组合路径为：
  `pc_if_o` → 预测器 → `pc_mux_i` → `branch_addr_n` → prefetch `branch_i/addr`。
  若预测器组合逻辑过大，可在 `pc_if_o` 后打一拍寄存器，代价是重定向延迟 +1 周期。
- 必须避免在 `trans_addr`（`prefetch_controller.sv:62`）到 `instr_addr_o` 之间引入
  额外组合逻辑，否则会恶化 OBI 地址关键路径。

### 4.3 潜在组合环

- 预测器输出 → `pc_mux_i` → `branch_addr_n` → prefetch → `fetch_valid` → aligner →
  `pc_if_o` → 预测器查询。**该回路天然存在**，务必保证预测器查询与结果更新之间
  有寄存（时序），禁止用 `pc_if_o` 直接组合式更新又同拍读回形成组合环。
- 建议：预测器索引/查询用组合，更新用 `always_ff` 寄存，与现有 `flush_cnt_q`、
  `cnt_q` 时序风格一致。

### 4.4 RVC 半字对齐与目标 PC 校验

- 分支目标必须是半字对齐：`aligner.sv:222-223` 以 `branch_addr_i[1]` 判断是否进入
  `BRANCH_MISALIGNED`；prefetch buffer 断言 `branch_addr_i[0]==0`
  （`prefetch_buffer.sv:202-207`）。
- 预测目标地址在送入 `pc_mux_i` 前必须保证 bit[0]=0；BTB 存储的目标地址应做
  `[1:0]=2'b0` 对齐，并回读校验 tag 防止误预测到非法半字。
- RVC 压缩指令（`is_compressed_id_o`）影响 PC 递增步长（2 或 4，见
  `id_stage.sv:642`），BTB 索引/目标必须与半字粒度一致。

---

## 5. 对照实验规范（可执行建议）

> 赛方细则未提供（待核实开放项），以下为可执行的基线对照建议，供 G5 综合/PPA 与仿真
> 对比使用。

| 维度 | 建议固定值 | 说明 |
|---|---|---|
| 编译器版本 | `riscv32-unknown-elf-gcc` 固定一个 release（如 riscv-gnu-toolchain 固定 tag） | 本机**未安装**，需先装 SDK |
| 软件镜像 | 同一份 hello_world / CoreMark / Dhrystone 二进制（.hex） | 基线 commit 的 `example_tb/core/custom/hello_world.c` |
| 仿真器 | Verilator 5.052（本机已装） | 已实测可跑通（见 §6） |
| 仿真内存延迟 | 固定 `mm_ram` 默认 1 拍延迟；用 `+maxcycles` 统一上限 | `example_tb/core/mm_ram.sv` |
| 频率约束 | 约束文件 `constraints/` 下（待确认具体 SDC 目标频率） | G5 再定 |
| 综合库 | 未确认（yosys 未装，G5 阶段再定） | 记录于风险清单 P2 |
| seed | 随机 stall 使用固定 seed | `riscv_gnt_stall/rvalid_stall` |
| 日志采集 | 统一 `+verbose` + `trace_core*.log`（或 VCD），保存 `$finish` 退出码与 `EXIT SUCCESS/FAILURE` | 见 §6 示例 |
| 关键对比指标 | 周期数（`$finish` 时刻）、误预测数、CPI、综合面积/时序 | 预测关闭 vs 预测开启两轮 |

---

## 6. 仿真执行记录（原核自带 example_tb + verilator）

### 6.1 官方流程（README 指定 vsim + RISC-V 工具链）

命令：
```bash
cd example_tb/core && make custom-vsim-run
```
结果：**失败**。`make` 退出码 `2`；`vlib-10.7b: not found`（子进程 127）。
原因：Questasim（vsim/vlog/vlib/vopt）与 `riscv32-unknown-elf-gcc` 均未安装
（`which` 均无结果）。日志：`project/logs/make_custom_vsim_run_FAIL.log`。

### 6.2 Verilator 直接编译（未修改源码）

命令（等价于 `project/logs/verilator_build_script.sh`）：
```bash
verilator --binary --timing -Wall -Wno-fatal ... <manifest RTL> <example_tb *.sv> --top-module tb_top
```
结果：**失败**，两类硬错误：
1. `PINNOTFOUND: PULP_XPULP / PULP_CLUSTER not found on cv32e40p_top`
   （example_tb 参数名滞后，见 §0）。
2. `MODMISSING: cv32e40p_clock_gate`（该模块在 `bhv/cv32e40p_sim_clock_gate.sv`，
   属 manifest 内但需显式加入文件列表）。
3. 若把 `-I rtl` 加入 include 路径，会连带 `fp_wrapper.sv` 自动被发现而报
   `fpnew_pkg not found`（FPU=0 时应排除 `cv32e40p_fp_wrapper.sv`）。

### 6.3 本地绕过后跑通（不改仓库 RTL，仅改 `sim_build/` 下的 tb 副本）

工作区：`cv32e40p/sim_build/`（仓库内 `rtl/` 与 `example_tb/` 未改动）。

所做绕过：
1. tb 副本内 `PULP_XPULP/PULP_CLUSTER` → `COREV_PULP/COREV_CLUSTER`（`sim_build/tb/`）。
2. 文件列表加入 `bhv/cv32e40p_sim_clock_gate.sv`，排除 `cv32e40p_fp_wrapper.sv`。
3. 手写最小固件（lui+sw 写 0x2000_0004 触发 exit + 自旋），因 `dp_ram.mem` 是
   `logic[7:0]` 字节数组，verilator 下 `$readmemh` 按“每行 1 字节”截断，故 hex 采用
   字节粒度（每行 2 位十六进制）；`objcopy -O verilog` 的 32-bit 字格式在本 verilator
   字节数组上会截断失效（记录为已知坑）。

编译结果：`verilator` 退出码 `0`，生成 `Vtb_top`。
运行结果：
```
./obj_dir/Vtb_top +firmware=minimal.hex +verbose
```
退出码 `0`；stdout 关键行：
```
EXIT SUCCESS
- Verilator: $finish at 110ns
```
完整日志：`project/logs/verilator_run_success.log`。

> 结论：原核 example_tb 在当前工具链（无 Questa/无 RISC-V gcc）下无法按 README 原样
> 运行；经本地绕过（参数名修正 + 排除 FP wrapper + 字节粒度 hex）后，**核心 RTL 可在
> Verilator 下编译并正确执行最小程序、正常触发 `EXIT SUCCESS`**。此过程**未改动**任何
> 功能 RTL，绕过文件均位于 `sim_build/`（未提交）。

---

## 7. core-v-verif 版本/运行办法（浅层核实）

- 仓库：https://github.com/openhwgroup/core-v-verif（浅克隆成功，HEAD=`1dfa483…`）。
- `cv32e40p/sim/ExternalRepos.mk:16-25` 指明 Makefile 自动克隆 cv32e40p RTL 到
  `$CORE_V_VERIF/core-v-cores/cv32e40p`，默认 `CV_CORE_BRANCH=master`、`CV_CORE_HASH=fcd5968`
  （注释说明为“与 v1.0.0 RTL freeze 逻辑等价但更新”的版本），`CV_CORE_TAG=cv32e40p_v1.0.0`
  指向冻结版。
- **注意**：core-v-verif 默认锁定的 cv32e40p 版本（`fcd5968`）与本项目基线
  `b353438` 不一致；集成验证时应显式 `CV_CORE_HASH=b353438…` 或改用本地 RTL 路径。
- 支持仿真器：vsim/VCS/DSIM/verilator（`cv32e40p/sim/core/Makefile:155-156` 有
  `VERILATOR` 配置，且有 `tb_top_verilator.sv`），但完整 UVM 环境需 Questa/VCS 类
  商业仿真器；本机仅 verilator 可用，UVM 流程**未实跑**（浅层核实）。

---

## 8. 风险清单（分级）

### P0（阻断集成，必须先解决）
1. **重定向时序不匹配**：现有 flush 机制（`flush_cnt_q`）假定 EX 阶段决议；预测提前到
   IF 后，预测重定向与真实决议需共享同一 `pc_set_i/branch_i`，否则旧取指混流、状态污染。
2. **预测器状态污染**：无 epoch/tag 时，EX 迟到的真实分支结果可能更新到已换代的新预测
   状态（BHT/BTB 表项），需自建代际标记。
3. **example_tb 与 RTL 版本不一致**：`PULP_XPULP/PULP_CLUSTER` 参数名已改名，集成验证
   基线需先修正 tb 或锁定一致版本。
4. **RVC 半字对齐**：预测目标未对齐会导致 `BRANCH_MISALIGNED` 或非法取指，BTB 目标必须
   强制对齐并校验 tag。

### P1（高风险，需设计约束）
5. **组合环风险**：预测器在 `pc_if_o`→预测→`pc_mux_i`→prefetch→`pc_if_o` 回路中，查询与
   更新必须寄存隔离。
6. **训练禁止条件未定义**：异常/中断/debug/flush 期是否禁止训练需明确，否则污染。
7. **IF 关键路径恶化**：预测器查询逻辑叠加在取指 PC 路径上，可能拖慢 `instr_addr_o`。
8. **core-v-verif 版本不一致**：默认 `fcd5968` ≠ 基线 `b353438`，验证环境需锁定版本。

### P2（低风险/待核实）
9. **RISC-V 工具链缺失**：本机无 `riscv32-unknown-elf-gcc`，官方固件编译无法进行，需装
   SDK 才能跑真实 benchmark（CoreMark/Dhrystone）。
10. **综合库/频率目标未确认**：yosys 未装、赛方细则未给，G5 综合阶段前需补齐。
11. **example_tb 仅“最小 sanity”**：README 明确“不可用于验证改动”，正式验证须走
    core-v-verif。
12. **`objcopy -O verilog` 字节序/字宽坑**：verilator 下字节数组 `$readmemh` 行为与
    Questa 可能不一致，固件加载需统一字节粒度格式。
