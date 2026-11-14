# 开 KERNEL_DEBUG_INFO_BTF，为 eBPF 数据面留门

配方里加 `CONFIG_KERNEL_DEBUG_INFO_BTF=y` 与 `# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set`（+ `kmod-nft-queue` / `kmod-nfnetlink-queue` 两个 kmod）。起因是核对「dae 系 honk（TC/TCX 数据面 + `daens` 命名空间）能否跑在这台路由器上」：在设备上逐项实测（`ssh router`，ImmortalWrt 25.12.1，kernel `6.12.94`，x86_64）后，九项内核要求里**八项已就绪，只缺 raw BTF**——引擎启动必读 BTF 做 loader 的 target BTF 与 process-name/RX-trace 结构体偏移，而 ImmortalWrt 默认 `DEBUG_INFO_BTF=n`：`/sys/kernel/btf` 不存在，也没有 `/usr/lib/debug/boot/vmlinux`。这一项无法在设备上补，只能重编内核，于是提前在配方里把门留着（开关不改变任何运行时行为，未跑该引擎时无人读 BTF）。

实测记录（可复现，全部只读或可逆）：

| 要求 | 证据 | 结论 |
|---|---|---|
| Linux ≥ 6.12 | `uname -r` = `6.12.94` | 就绪 |
| `NET_NS` | `ip netns add/del` rc=0（源码 fragment 里 `# CONFIG_NET_NS is not set` 是死行，被 `KERNEL_NET_NS` 默认 y 覆盖，必须以实测为准） | 就绪 |
| `CGROUPS` + `CGROUP_BPF` | `/sys/fs/cgroup` 为 cgroup2（`nsdelegate`）；`/proc/kallsyms` 有 26 个 `cgroup_bpf` 符号，含 `__cgroup_bpf_run_filter_sock_ops` | 就绪 |
| `NET_XGRESS`（TCX） | kallsyms 13 个 `tcx_*` | 就绪 |
| `NET_CLS_ACT` | `tcf_classify` / `tcf_exts_*` 等 12 个符号 | 就绪 |
| `BPF_SYSCALL` + `BPF_JIT` | `/proc/sys/net/core/bpf_jit_enable=1`、`/proc/sys/kernel/unprivileged_bpf_disabled` 存在 | 就绪 |
| bpffs | `bpffs on /sys/fs/bpf type bpf (mode=700)` | 就绪 |
| raw BTF | `/sys/kernel/btf` 缺失，无 `/usr/lib/debug/boot/vmlinux` | **缺** |
| `NFT_QUEUE` / `NFNETLINK_QUEUE` | `nft add rule … queue` 报错；kallsyms 无 `nfqnl_*` | 缺，但引擎按 best-effort 降级 |

**Considered Options**:

- 不动内核，继续 mihomo 现网 + 6 行回程豁免 nft（否决于当下：上游没修 —— mihomo #1493 / #1368 仍 OPEN，sing-tun 的 `Fix Docker DNAT handling with auto route` PR #16 自 2026-07-27 挂在 CONFLICTING，实现层 `tun_linux.go` 至今仍是 `not iif lo → table 2022` 的 conntrack-blind 规则；留着门不等于今天换）
- 用官方 `kernel-debug.tar.zst` 里的 vmlinux 离线 `pahole -J` 生成 BTF（否决：那是 DWARF，转出的 BTF 只对同配置内核有效，本配方自编的内核结构体偏移不同，错配的 BTF 比没有更危险）
- 等内核或引擎自己解决（否决：BTF 是引擎启动的硬前提，与上游进度无关）
- 改 mihomo 的转面为 tproxy/redirect（否决：核不装 tproxy 规则，等于把 nikki 那 600 多行 ucode 搬回来，回到「迷你 nikki」的老路）

**Consequences**:

- 内核带 `.BTF`，`KERNEL_DEBUG_INFO_BTF` 会 `select DWARVES`（构建链拉 pahole）、并默认带 `DEBUG_INFO_BTF_MODULES`；镜像体积与构建时间小幅增加，与运行时行为无关。
- `kmod-nft-queue` / `kmod-nfnetlink-queue` 常驻但当前无人使用；留它们的唯一理由是让将来的 UDP 模糊暂存不必再动一次内核。
- `CONFIG_DEBUG_INFO=y`（x86 target fragment）与 `# CONFIG_DEBUG_INFO_REDUCED is not set`（generic fragment）已满足 BTF 的两个依赖，但**只有 fragment 不够**：`kernel-defaults.mk` 的 `Kernel/Configure/Default` 把 `.config` 里的 `CONFIG_KERNEL_*` awk 成无前缀行**追加在 fragment 之后**，后写的赢；而 `KERNEL_DEBUG_INFO_REDUCED` 在 `Config-kernel.in` 里 `default y`，会覆盖 generic fragment 的 `not set`。不显式加那行 `# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set`，BTF 会被 kconfig 静默丢弃（与仓库之前遇到的「defconfig 静默丢包」同类故障）。
- `select DWARVES` 拉的是 `tools/dwarves`（上游已有，`1.31`），不需要配方额外声明；构建机必须是 Linux（`!HOST_OS_MACOS`）。
- 已用 CI 验证（`v25.12.1-r12`，run 43461690646）：`make world` 之后的核对步骤打印
  `内核配置核对通过：build_dir/target-x86_64_musl/linux-x86_64/linux-6.12.94/.config（.BTF 已入 vmlinux）`，
  即 `KERNEL_DEBUG_INFO_REDUCED` 那行「not set」确实起了作用，BTF 没有被 kconfig 丢弃。
- 「是否真的把数据面换成 honk」是独立决策，代价与收益另记（配置重写为 dae 语法、无 fake-ip 引擎、fork 的 `preferred-ip`/`disable-qtype-64` 失效；收益是 DNAT 回程问题从架构上消失）。本 ADR 只承诺「门开着」。
