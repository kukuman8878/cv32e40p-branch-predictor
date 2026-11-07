# G1 基线冻结：验证计划与环境记录

> Agent A（实施）在 G1 Gate 的交付：固定工具链/编译选项/仿真参数，跑出原核三类
> 基准程序的周期基线，并固化"一条命令复现"。本文件即环境记录。
> 未改动任何 `rtl/*.sv`；所有绕过仅落在 `project/tb/` 与 `project/tests/`。

---

## 1. 固定版本

| 项目 | 固定值 | 证据/来源 |
|---|---|---|
| 基线仓库 | https://github.com/openhwfoundation/cv32e40p | `git rev-parse HEAD` |
| 固定 commit | `b353438ff469c030c89f6804f3b24a2852880e8b` | detached HEAD，禁止更新上游 |
| RISC-V GCC | `riscv32-unknown-elf-gcc (13.2.0-11ubuntu1+12) 13.2.0` | `~/.riscv/bin`，Ubuntu 包 |
| Binutils | GNU ld / objcopy `2.42-1ubuntu1+6` | 同上 |
| C 库 | picolibc `1.8.6`（非 newlib） | `/usr/lib/picolibc/riscv64-unknown-elf` |
| Verilator | `5.052 2026-09-05 rev conda-forge build` | conda-forge |
| 仿真器 | 仅 Verilator（无 Questa） | G0 已确认 |

## 2. 编译选项（所有程序一致，与 example_tb Makefile 同构）

```bash
ARCH=rv32imc_zicsr_zifencei     # gcc13 把 zicsr/zifencei 从 base 'i' 拆出，需显式；
ABI=ilp32                        #   功能上等价于 example_tb 的 -march=rv32imc
OPT=-Os
CFLAGS="-march=$ARCH -mabi=$ABI -Os -g -w"
LDFLAGS="-nostdlib -static -T project/tests/link.ld"
LDLIBS="-lc -lgcc"               # -lc 为 picolibc；-lgcc 提供软除法/软乘法辅助
INCDIR=~/.riscv/riscv32-unknown-elf/include
LIBDIR=~/.riscv/riscv32-unknown-elf/lib/rv32im/ilp32   # 必须显式 rv32 multilib 子目录
```

链接对象（顺序固定）：
```
crt0.S  <prog>.c  syscalls.c  vectors.S
```

> **两个与 example_tb 原 Makefile 的必要差异（如实记录）：**
> 1. `-march=rv32imc` → `-march=rv32imc_zicsr_zifencei`：gcc 13.2.0 下 `csrw/csrr/mret`
>    等 CSR 指令必须显式开启 `zicsr`（`zifencei` 对应 `fence.i`），否则汇编报
>    `unrecognized opcode`。CV32E40P 支持两者，故语义与 `rv32imc` 一致。
> 2. `-lc` 由 newlib 换成 **picolibc 1.8.6**，且必须 `-L .../lib/rv32im/ilp32`：
>    顶层 `libc.a` 是 rv64（ELFCLASS64），直接 `-L .../lib` 会选到它而链接失败。

## 3. syscall / stdio 适配（均在新文件，未动 RTL）

`example_tb` 自带的 `custom/syscalls.c` 面向 newlib（`_write`/`_read`… 下划线风格 +
`#include <newlib.h>`）。picolibc 接口不同：

- picolibc libc 引用 **无下划线** POSIX 名：`write/read/close/lseek/fstat/isatty/open/
  unlink/getpid/kill/gettimeofday/times/sysconf/getentropy` 与 `sbrk`、`_exit`。
- picolibc 的 tinystdio 中 `stdin/stdout/stderr` **不在 libc.a 内**（仅弱引用），需宿主
  提供；官方 `libdummyhost.a`（no-op）/`libsemihost.a`（ARM 半主机）都无法驱动
  example_tb 的存储映射 stdout（`0x10000000`）。

因此新建 `project/tests/syscalls.c`，实现：
1. 上述 POSIX syscall 桩；
2. `stdout/stderr` 的 `FILE` 设备，其 `put` 写 `0x10000000`（mm_ram.sv 打印外设）；
3. `_exit` 写 `0x20000004`（触发 `exit_valid_o` → `$finish`）；
4. `sbrk` 基于 link.ld 的 `.heap`（`__heap_start`/`__heap_end`）。

`crt0.S`/`link.ld`/`vectors.S` 沿用 example_tb 原文件（picolibc 提供 `__libc_init_array`/
`__libc_fini_array`/`atexit`/`exit`/`memset`/`puts`/`printf` 等所需符号，链接通过）。

## 4. hex 生成（字节粒度结论）

`riscv32-unknown-elf-objcopy -O verilog`（binutils 2.42）输出**已按字节粒度**
（每 token 2 位十六进制、每行 16 字节、`@addr` 标记），与 `dp_ram.mem`（`logic[7:0]` 字节
数组）的 `$readmemh` 语义一致，**可直接加载**。G0 记录的"objcopy 32-bit 字格式截断坑"
系当时无工具链、手写 hex 时对 objcopy 行为的推断；实测此坑在当前 binutils 下不存在。

```bash
riscv32-unknown-elf-objcopy -O verilog <prog>.elf <prog>.hex
```

## 5. 仿真参数（固定）

| 参数 | 值 | 说明 |
|---|---|---|
| 时钟周期 | 10 ns（CLK_PHASE_HI/LO 各 5ns） | `project/tb/tb_top.sv` |
| BOOT_ADDR | `0x180` | tb_top 参数 |
| RAM_ADDR_WIDTH | 22（4 MB） | tb_top 参数 |
| 内存延迟 | dp_ram 默认（1 拍流水，无额外 stall） | `mm_ram.sv` 无 gnt 延迟 |
| 随机 stall | 关闭（`rnd_stall_regs` 默认 0） | 确定性仿真 |
| 随机中断 | 关闭（`cv32e40p_random_interrupt_generator` 在 VERILATOR 下不例化） | `mm_ram.sv` `ifndef VERILATOR` |
| seed | 无随机源，**不需要 seed** | 3 次重跑 cycle 一致（见 §7） |
| 上限 | `+maxcycles=5000000`（watchdog） | 超时 `$fatal(2)` |
| 周期计数 | tb 自由运行计数器 `cycle_count_q`（rst_n 释放后每个 posedge +1），`$finish` 时打印 `[CYCLE] cycle_count = N` | `project/tb/tb_top.sv` |
| 退出判定 | 程序 `_exit(0)` 写 `0x20000004` → `EXIT SUCCESS`；grep 日志判定 PASS/FAIL | |

## 6. 原核回归结果（第 1 条交付）

| 程序 | 结果 | 退出码 | 周期数 | 日志 |
|---|---|---|---|---|
| hello_world（"hello world!"） | PASS | 0（EXIT SUCCESS） | 3533 | `project/metrics/logs/hello_world_run.log` |
| fib（fib(20)=6765） | PASS | 0 | 377169 | `project/metrics/logs/fib_run.log` |

## 7. 三类基准程序基线周期数（第 2 条交付）

同一 crt0/link.ld/syscalls、同一编译选项、确定性仿真（3 次重跑 branch_heavy 均为
20912 周期）：

| 类别 | 程序 | 自检结果 | 周期数 | 源文件 | hex |
|---|---|---|---|---|---|
| 分支密集型 branch-heavy | 快排 + 多级 if/else 分类扫描 | PASS | **20912** | `project/tests/branch_heavy.c` | `project/metrics/branch_heavy/branch_heavy.hex` |
| 混合应用型 mixed | 递归 fib(24) + 分支/算术循环 | PASS | **3106787** | `project/tests/mixed.c` | `project/metrics/mixed/mixed.hex` |
| 低分支型 low-branch | 16×16 整数矩阵乘 + 校验和 | PASS | **78753** | `project/tests/low_branch.c` | `project/metrics/low_branch/low_branch.hex` |

> 周期数语义：`cycle_count_q` 从 reset 释放后的第一个 posedge 起计，到 `exit_valid`
> 触发 `$finish` 的 posedge 为止。预测关闭（现状，IF 无条件分支预测）下的基线，
> 供 G2 起"预测关闭 vs 预测开启"对照使用。

## 8. 复现命令（第 4 条交付）

```bash
cd /home/kukuman/RISC/project
./scripts/reproduce.sh
```

单步等价流程：
1. `./scripts/reproduce.sh` 内部顺序执行：编译 5 个程序 → `objcopy -O verilog` →
   `./scripts/build_tb.sh`（Verilator 编译，RTL 只读）→ 逐个 `Vtb_top +firmware=... +maxcycles=...`
   → 打印汇总表。
2. 环境快照写入 `project/metrics/logs/environment_g1.txt`。

## 9. 日志采集方式（第 3 条交付）

- 编译日志：`project/metrics/logs/<prog>_compile.log`
- 运行日志：`project/metrics/logs/<prog>_run.log`（含 stdout、`[CYCLE]`、`EXIT SUCCESS/FAILURE`）
- Verilator 构建日志：`project/metrics/logs/build_tb.log`
- 环境快照：`project/metrics/logs/environment_g1.txt`

## 10. 上一轮 P2 关闭（第 5 条交付）

- **B-G0-001（已关）**：`docs/01_architecture_map.md` 中 `branch_req` 行号
  `if_stage:217-218` → `218-219`（两处：取指路径图 §1、事务风险 §3）。已复核源码
  `rtl/cv32e40p_if_stage.sv:217-218`（`if (pc_set_i)` @217 / `branch_req=1'b1` @218）。
- **B-G0-002（已关）**：已装 riscv32-unknown-elf-gcc（13.2.0）+ picolibc，并在同一
  commit `b353438` 上跑通真实 hello_world（EXIT SUCCESS，3533 周期）与 fib；CoreMark
  尚未集成到 example_tb 流（CoreMark 需要其自身 harness/计时接口，列为 G1 未完成项，见提交单）。
- **B-G0-003（已关，环境记录）**：正式 core-v-verif 验证必须显式
  `CV_CORE_HASH=b353438ff469c030c89f6804f3b24a2852880e8b`（或改用本地 RTL 路径），
  禁止使用默认 `fcd5968`。本 Gate 未实跑 core-v-verif（需 Questa/VCS），仅锁定该事实。

## 11. 未改动声明

`rtl/*.sv`、`example_tb/**`、`bhv/**` 均为只读；仓库 `git status` 仅新增 `sim_build/`
（未跟踪）。G1 全部产物在 `project/`（`tests/`、`tb/`、`metrics/`、`scripts/`、`docs/`、`reviews/`）。
