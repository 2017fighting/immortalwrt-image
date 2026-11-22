# 开 FTRACE / FUNCTION_TRACER / DYNAMIC_FTRACE，让 honk 的 UDP 接收追踪回退能挂接

配方里加 `CONFIG_KERNEL_FTRACE=y`、`CONFIG_KERNEL_FUNCTION_TRACER=y`、
`CONFIG_KERNEL_DYNAMIC_FTRACE=y`，并在 `scripts/build.sh` 的内核核对步骤里断言它们
（以及自动选中的 `CONFIG_DYNAMIC_FTRACE_WITH_DIRECT_CALLS=y`）真的进了内核 `.config`，
且 vmlinux 里的 ftrace 调用点表非空。

起因是 [ADR-0004](0004-honk-dataplane-switch.md) 落地后设备上的一条启动告警：

```text
WARN honk_core::ebpf::real::programs: kernel UDP trace attach unavailable
  error=attach honk_udp_receive_candidate on __skb_recv_udp:
        `bpf_raw_tracepoint_open` failed: Resource busy (os error 16)
  ipv4_unavailable=true ipv6_unavailable=true
WARN honk_core::control::lifecycle: UDP receive trace unavailable error=… ipv4_unavailable=true ipv6_unavailable=true
```

（`ssh router`，ImmortalWrt 25.12.1，kernel `6.12.94`，honk-core v0.1.0-beta.6。）

## 这条告警是什么

honk 的 UDP 拓扑需要每个数据报的接收优先级 `SO_PRIORITY`（内核用它标出 TPROXY 转发
来的报文，据此把客户端与 reply 关联起来）。它有两个来源：

1. `SO_RCVPRIORITY`（把 `SO_PRIORITY` 附在 `recvmsg` 辅助数据里）——**Linux 6.14 才有**
   （uapi commit `e45469e594`，`include/uapi/asm-generic/socket.h` 的 `SO_RCVPRIORITY 82`；
   6.12/6.13 的 uapi 里没有这个宏）。
2. 回退路径：fentry/fexit 挂 `udp_recvmsg` / `udpv6_recvmsg` / 共享的 `__skb_recv_udp`，
   从内核里把 priority 抄进 map（`crates/honk-core/src/ebpf/real/receive_trace.rs`）。

本机是 6.12，所以只有第 2 条可用 —— 而它在没有 ftrace 的内核上挂不上：

- `register_fentry()`（`kernel/bpf/trampoline.c`）只有在 `ftrace_location(ip)` 非零时才走
  `register_ftrace_direct`；
- 没有 `CONFIG_FTRACE` 时，`ftrace_location()` 是 `include/linux/ftrace.h` 里返回 0 的桩函数，
  于是走 `bpf_arch_text_poke(ip, BPF_MOD_CALL, NULL, new_addr)`；
- 该路径要求函数入口处的那 5 个字节恰好是 nop 才肯写入，否则
  `__bpf_arch_text_poke` 直接返回 `-EBUSY`（`arch/x86/net/bpf_jit_comp.c`：`memcmp(ip, old_insn, X86_PATCH_SIZE)` 不符即 `goto out`）。

实测支持这个判断（全部只读）：

| 探测 | 结果 |
|---|---|
| `/sys/kernel/debug/tracing/available_tracers` | 只有 `nop` |
| `/sys/kernel/debug/tracing/available_filter_functions` | 文件不存在 |
| `/proc/kallsyms` 里 `ftrace_location` / `register_ftrace_function` / `__start_mcount_loc` / `__fentry__` | 全无 |
| `target/linux/generic/config-6.12`（钉住 tag） | `# CONFIG_FTRACE is not set`、`# CONFIG_FUNCTION_TRACER is not set`、`# CONFIG_KPROBES is not set` |
| `target/linux/x86/config-6.12` | `CONFIG_FUNCTION_ALIGNMENT=4`、`CONFIG_FUNCTION_PADDING_BYTES=4`（不是 16） |
| 从 `/boot/vmlinuz` 解压出的 vmlinux | 无 `__start_mcount_loc` / `__stop_mcount_loc` 符号；`udp_recvmsg` / `__skb_recv_udp` / `udpv6_recvmsg` 入口都是 `push rbp`，没有 5 字节 nop |

对齐只有 4 字节、入口没有 nop——`bpf_arch_text_poke` 认不出可改写的指令，于是 EBUSY。

## 决策

在配方里把 ftrace 打开，作为「门」的一类（见 [ADR-0002](0002-ebpf-datapath-kernel-btf.md) 的
「门」概念）：

```text
CONFIG_KERNEL_FTRACE=y
CONFIG_KERNEL_FUNCTION_TRACER=y
CONFIG_KERNEL_DYNAMIC_FTRACE=y
```

三点说明：

- **为什么必须写 `CONFIG_KERNEL_*`**：generic fragment 里是 `# CONFIG_FTRACE is not set`，而
  `config/Config-kernel.in` 的 `KERNEL_FTRACE` 没有默认值。`kernel-defaults.mk` 的
  `Kernel/Configure/Default` 把 `.config` 里的 `CONFIG_KERNEL_*` awk 成无前缀行**追加在
  fragment 之后**，后写的赢——与 ADR-0002 处理 `DEBUG_INFO_REDUCED` 同一道理。
- **`CONFIG_DYNAMIC_FTRACE_WITH_DIRECT_CALLS` 不写进 seed**：它 `def_bool y`
  （`depends on DYNAMIC_FTRACE_WITH_ARGS`，x86_64 `select HAVE_DYNAMIC_FTRACE_WITH_ARGS`），
  会随 `DYNAMIC_FTRACE` 自动成为 y。但它是 fentry 走 `register_ftrace_direct` 的前提，所以
  在 build.sh 里断言而不是在 seed 里写一行可能被 kconfig 丢掉的冗余。
- **为什么不再等**：6.12 没有 `SO_RCVPRIORITY`，而钉住的 ImmortalWrt 25.12 系列就是 6.12
  （上游 master 已到 6.18，但升内核是另一次决策，见 ADR-0002 的钉点口径）。

## Considered Options

- 什么都不做，接受降级（否决：降级只丢「内核路由证据」——honk 的流无法把客户端 UDP 报文与
  内核 TPROXY 路由决策对上，`/runtime` 的 `degradations` 常驻 `udp_trace` 一条。代价只是
  ftrace 的镜像体积与函数入口开销，比常驻降级的排查成本低）。
- 只开 `CONFIG_KERNEL_KPROBES`（否决：它在 `Config-kernel.in` 里只 `select KERNEL_FTRACE`，
  不带 `FUNCTION_TRACER` / `DYNAMIC_FTRACE`；而 `register_fentry` 只认 `ftrace_location`
  给出的位置，没有 `__mcount_loc` 它依旧是桩函数返回 0）。
- 等 honk 换用别的机制（否决：honk 侧没有第二套方案；本机 6.12 上 `SO_RCVPRIORITY` 不存在，
  回退就是唯一路径，正因如此它才叫回退）。
- 自己升到 6.18 kernel（否决：ImmortalWrt 25.12 系列钉 6.12，换内核 = 换整个目标配置与
  kmod ABI，远超本条的收益）。

## Consequences

- 内核体积与构建时间小幅增加：`FUNCTION_TRACER` 给每个函数的入口插一条 `-mfentry` 调用
  （编译期被 `-mnop-mcount` 折成 5 字节 nop，不 tracing 时无运行时开销），
  `DYNAMIC_FTRACE` 额外落 `__mcount_loc` 表（每函数 8 字节）。该段被链接脚本并进
  `.init.data`（`include/asm-generic/vmlinux.lds.h` 的 `MCOUNT_REC()`），所以最终镜像里
  没有同名段，只能用 `__start_mcount_loc`/`__stop_mcount_loc` 这对符号判断。
- 构建链要求 gcc 支持 `-mfentry` / `-mrecord-mcount`：钉住的工具链是 gcc 14.3.0，支持。
  x86 的 `select HAVE_DYNAMIC_FTRACE_NO_PATCHABLE` 让这条路径不依赖
  `CALL_PADDING`（本机 `FUNCTION_PADDING_BYTES=4`）。
- 设备侧验收（刷机后跑一遍）：
  - `cat /sys/kernel/debug/tracing/available_tracers` 应出现 `function`（不再是只有 `nop`）；
  - 启动日志里不再有 `kernel UDP trace attach unavailable`；
  - `GET /api/v1/runtime` 的 `degradations` 里不再有 `udp_trace`。
- 失败即不出包：`scripts/build.sh` 的内核核对步骤新增 `CONFIG_FTRACE` /
  `CONFIG_FUNCTION_TRACER` / `CONFIG_DYNAMIC_FTRACE` /
  `CONFIG_DYNAMIC_FTRACE_WITH_DIRECT_CALLS` 四条 `.config` 断言，以及 vmlinux 里
  `__start_mcount_loc`/`__stop_mcount_loc` 存在且不相等的断言（配置对了但调用点表没落进
  镜像，设备上 `ftrace_location()` 仍是空表、fentry 照样挂不上——这正是 ADR-0002 里
  「下了但没编进」的同款故障）。这组断言在本机用「植入违规」的方式自测过：缺任一条符号、
  fragment 原样（全 not set）、`__mcount_loc` 空表、vmlinux 被 strip、无 `.BTF` 段、
  vmlinux 路径不存在，六种情况都返回 1；正常骨架返回 0。
- **未验证**：本次提交只做到「构建期断言 + 文档」，真机效果要等下一次发布刷机后才算数；
  在刷机之前，设备上的 `udp_trace` 降级仍然存在（与 ADR-0004 的实施状态一致，不影响路由与
  UDP 投递）。
