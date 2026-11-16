# immortalwrt-image

ImmortalWrt x86_64 软路由的**镜像配方**：用纯声明式的配置层把钉住的
[immortalwrt/immortalwrt](https://github.com/immortalwrt/immortalwrt) 官方发布版
编译成个人固件。本仓库不含任何 ImmortalWrt 源码，CI 直接 checkout 上游
 tag，一切定制见 [ADR-0001](docs/adr/0001-separate-overlay-repo.md)。

**产出**：squashfs 镜像（rootfs 8GB，EFI/BIOS 双出，GRUB 零秒直启），
LAN 默认 `192.168.9.1/24`。内置 [openwrt-feeds](https://github.com/2017fighting/openwrt-feeds)
全量（natmapt 全家桶含全部通知/下载器联动子包 + stuntman-client）+ honk
全套（dae 系 eBPF 数据面引擎 + LuCI 服务页 + 中文，源码内置，[ADR-0004](docs/adr/0004-honk-dataplane-switch.md)）
+ acme/tailscale（含社区 LuCI 面板）/sqm/statistics 等常用应用，预置两个
二进制 feed 的公钥与注册（openwrt-feeds Pages + daeuniverse；设备侧
`apk update && apk upgrade` 即可在线升级包）。

## 仓库结构

| 路径 | 角色 |
|---|---|
| `pins.env` | 钉点：上游 tag + 官方工具链 URL/sha256 + honk 源码 tag |
| `feeds.extra` | 源 feed 钉点：openwrt-feeds + daeuniverse（各 ^commit） |
| `config/x86-64.seed` | diffconfig 最小集（目标/文件系统/内置包选择） |
| `files/` | 覆盖层：uci-defaults 改 LAN IP、apk 公钥、feed 注册 |
| `files/lib/upgrade/` | sysupgrade 覆盖：`platform.sh` 只写 p2 的 squashfs 有效载荷（ADR-0005），`x86-platform-upstream` 是钉住 tag 的上游原文副本 |
| `scripts/build.sh` | 构建器：铺配方 → defconfig → 工具链 → make world |
| `.github/workflows/` | `build.yml`（构建+发布）、`keygen.yml`（一次性签名钥） |

词汇表见 [CONTEXT.md](CONTEXT.md)。

## 首次使用（一次性）

1. **签名钥**（可选但推荐）：Actions → keygen → Run workflow，把输出的 base64
   私钥设为 secret `IMAGE_SIGN_KEY`。不设也能构建（buildroot 每次随机生成，
   见 workflow 内说明）；换钥对存量设备零影响。
2. push 到 main（或手动 Run build）→ 产物出现在 GitHub Releases，
   tag 形如 `v25.12.1-r7`。

## 刷机

```sh
gunzip < immortalwrt-25.12.1-x86-64-generic-squashfs-combined-efi.img.gz | \
  sudo dd of=/dev/sdX bs=4M conv=fsync status=progress
```

EFI 启动用 `combined-efi`，传统 BIOS 用 `combined`。首启 LAN 口 IP
`192.168.9.1/24`。

Release 只发 squashfs 的这两个 combined 镜像（`CONFIG_TARGET_ROOTFS_EXT4FS`
在 seed 里显式关掉）：ext4 根没有只读 `/rom` + overlay 的恢复出厂/回滚语义，
与本配方不一致；`*rootfs.img.gz` 也不再发布（没有引导码与分区表，既不能首刷
也不能 sysupgrade）。

## 升级（sysupgrade）

Release 里的 `*-squashfs-combined-efi.img.gz`（UEFI）与 `*-squashfs-combined.img.gz`
（传统 BIOS）**本身就是 sysupgrade 镜像** —— 既能 dd 首刷，也能直接交给设备的
`sysupgrade` 或 LuCI「系统 → 备份/刷写固件」页。`*-rootfs.img.gz` 只有分区内容、
没有引导码与分区表，不能用来 sysupgrade。

```sh
# 设备侧（镜像先传到 /tmp，或用 LuCI 上传）
sysupgrade /tmp/immortalwrt-x86-64-generic-squashfs-combined-efi.img.gz
```

- **默认保留配置**（LuCI 的勾选框要自己勾上）。`/etc/config/`、`/etc/dropbear/`、
  base-files 的若干文件，以及各包声明的 conffile / `keep.d` 会随 `/sysupgrade.tgz`
  带过去：honk 的 `/etc/honk/config.dae` 与 `/etc/honk/data/`（订阅与 state db）、
  tailscale 的 `/etc/tailscale/tailscaled.state` 都在其中，升级后不用重新登录。
  不勾（等于 `-n`）是干净刷写，LAN 回到 `192.168.9.1`。
- **升级中 LuCI 会先失联**：`stage2` 的 `kill_remaining` 会在写盘前 TERM/KILL 掉
  uhttpd，页面必然打不开、ping 可能还通。这是设计如此，不代表失败。
- **别用 `-c`/`-o`**（保存整个 overlay）：25.12 的排除清单不含
  `repositories.d/distfeeds.list` 等，会把陈旧的 `/etc/apk/*` 带回新系统；而 apk
  对 `/etc/apk` 有 `!etc/apk` 保护，永远不会再自我纠正。用默认保留或 `-n`。
- **改过的 LAN 网段不会被升级重置**：`/etc/uci-defaults/99-lan-ip` 在每次保留配置
  升级后的首启都会重跑，所以带守卫——只有 `network.lan.ipaddr` 仍是上游默认的
  `192.168.1.1` 时才写成 `192.168.9.1/24`（ADR-0005）。
- **写盘量不是 8GB**：分区表没变时只写 p2 的 squashfs 有效载荷（约 35MB），
  不再整块写 8192MB —— 目标机实测写速约 12MB/s，整块写要 11–14 分钟（ADR-0005）。
  镜像文件本身的解压体积仍是 8GB，首刷的 dd 照旧按 8GB 走。
- **补丁只对装上新版的设备生效**：升级时跑的是**当前系统**里的 `platform.sh`，
  所以从 r12 及更早版本升上来那一次仍是整块写 8.2GB（可能十几分钟，别拔电）；
  装上新版之后每次升级才是秒级。
- **什么会丢**：`/root`、`/opt` 与任何不在上面清单里的自建文件；盘上额外的分区
  （extroot、数据盘）—— 布局与镜像不同会触发“整盘写”分支。要长期保留的文件写进
  `/etc/sysupgrade.conf`（LuCI 刷写页底部可编辑），数据放外挂盘。
- **自己 apk 装的包要重装**：升级只带配置，不带包。升级前 `apk list -I` 存一份，
  回来对照 `apk add`。
- **回滚**：x86 squashfs 没有 A/B。升级前把当前版本的 `.img.gz` 留在本机或 U 盘，
  失败就照「刷机」那行 `dd` 回去。
- **兼容边界**：跨配方修订（r12→r13）与跨上游 tag 都可以 sysupgrade；改
  `CONFIG_TARGET_ROOTFS_PARTSIZE`（8192）属于破坏性变更（分区表变 + 布局比较走
  整盘写），届时按首刷处理。

## 常见变更

| 想要什么 | 改哪里 |
|---|---|
| 加/减内置包 | `config/x86-64.seed` 加/删一行 `CONFIG_PACKAGE_xxx=y` |
| 升级上游（如 v25.12.2） | `pins.env` 三项（tag、URL、sha256 取自官方 sha256sums） |
| 升级 openwrt-feeds | `feeds.extra` 的 `^commit` |
| 升级 honk（引擎） | `pins.env` 的 `HONK_TAG` + `feeds.extra` 的 daeuniverse `^commit`（两者配套，见 ADR-0004） |
| 设备在线升级 honk | `apk add honk@daeuniverse luci-app-honk@daeuniverse luci-lib-daeuniverse@daeuniverse luci-i18n-daeuniverse-zh-cn@daeuniverse` |
| 回退 mihomo | 设备上 `apk add mihomo-alpha mihomo-bare`（openwrt-feeds Pages 源已预置；先停 honk，两引擎数据面互斥） |
| 改 LAN IP | `files/etc/uci-defaults/99-lan-ip`（只在仍是上游默认值时生效） |
| 改 sysupgrade 写入行为 / 分区尺寸 | `files/lib/upgrade/platform.sh`（ADR-0005）或 `config/x86-64.seed` 的 `CONFIG_TARGET_ROOTFS_PARTSIZE`（破坏性） |
| 换 feed 公钥 | `files/etc/apk/keys/2017fighting.pem` |

推送到 main 即自动重建发布。

## 当前产物与已验证的事实

最新一版 **`v25.12.1-r12`**（配方 `b4df67a`，2026-11-13，构建 1h24m）已验证：

- **eBPF 的门开着**：`CONFIG_KERNEL_DEBUG_INFO_BTF=y` 真的进了内核，vmlinux 带
  `.BTF` 段（构建末尾的「内核配置核对」步骤会当场断言，失败即不出包）。
  设备侧一条命令可确认：`ls -l /sys/kernel/btf/vmlinux`。见 [ADR-0002](docs/adr/0002-ebpf-datapath-kernel-btf.md)；
  该门自下一版起有了使用者（honk，[ADR-0004](docs/adr/0004-honk-dataplane-switch.md)）。
- **honk 源码内置走「内核自带 BTF」那条路**：daeuniverse 官方对 ImmortalWrt 只
  加一行 packages 源（不加 kmods 源），BTF 依赖由空包 `vmlinux-btf-builtin` 满足
  —— 但**必须把它显式写进 seed**：空壳包的 `PROVIDES:=@vmlinux-btf` 是优先级 0，
  真包又与依赖同名，`defconfig` 会挑真包，`make world` 随后因缺 `VMLINUX_BTF_SRC`
  报 "the BTF blob is missing" 整轮失败（2026-11-16 的 run 43833796071 就是这么
  挂的，且 honk 那次提交后一直没有成功构建过）。honk 硬依赖的 `kmod-veth` / `kmod-sched-bpf`
  在 ImmortalWrt distfeeds 没有 kmods 源、只能来自本镜像的构建，seed 直接编进去。
  daeuniverse feed 只带打包 Makefile，honk 源码由 build.sh 按 `HONK_TAG` 克隆；
  Rust 工具链（stable + nightly）、bpf-linker、doona 的版本与哈希全由 honk
  源码自带的钉点文件决定（ADR-0004）。
- **镜像内容**：natmapt 全家桶 + stuntman-client + `honk`（eBPF 引擎，自带
  doona 面板 `:9527`）+ `luci-app-honk` + 中文；**没有** mihomo（回退在线装回，
  见上表），**没有** nikki 栈。设备侧：`apk list -I | grep -Ei 'honk|daeuniverse'`。
- **待下一版验证**：r12 之后 seed 补了 `tailscale` + `luci-app-tailscale-community`
  + 中文语言包 + `ip-full`（r12 产物里没有，换成这里下载的旧镜像就得自己
  `apk add`），外加 honk 全套与 `kmod-sched-bpf` / `kmod-veth`；自下一版起
  mihomo 移除、honk 内置（ADR-0004）。
- **sysupgrade 实测可用，且写入量已收窄**（[ADR-0005](docs/adr/0005-sysupgrade-write-scope.md)）：
  在 KVM/OVMF 虚拟机里刷 r12 镜像后做“保留配置”升级，改过的 `/etc/config`
  完整带回、overlay 重建为新 f2fs、设备正常启动。上游的整块写（p2 8192MB）
  在虚拟 NVMe 上要 48 秒，目标机 MV-32 实测写速约 12MB/s（写 1GiB/85s）
  对应 11–14 分钟；本配方的“只写有效载荷”把 p2 写入压到 35MB，同一虚拟机
  上从 48 秒降到 2–3 秒，而且旧 overlay 依然会被重新格式化（写 64KB 零区
  抹掉旧 f2fs 签名，实测上一轮写的标记文件升级后消失）。
- **`99-lan-ip` 的守卫实测**：`192.168.1.1` / `192.168.1.1/24` / 未设置 → 写成
  `192.168.9.1/24`；`192.168.99.1/24` → 原样保留；退出码恒 0（否则
  `/etc/init.d/boot` 会把它当失败、每次开机重试）。
- **构建环境钉 24.04**：`ubuntu-latest` 迁到 26.04 后连续三次以
  "lost communication with the server" 收场，钉回 24.04 后一次通过。见
  [ADR-0003](docs/adr/0003-pin-runner-image.md)。该条今后仍会漂移，需要一次
  显式决策再动。

## 与 openwrt-feeds 的关系

姊妹仓库：openwrt-feeds 产出**二进制包 feed**（GitHub Pages，给已刷机的设备在线装包）；
本仓库产出**固件镜像**（GitHub Releases，给整机刷写）。镜像构建直接 `src-git`
消费 openwrt-feeds 的源码 Makefile，不依赖其二进制 feed；二进制 feed 只服务
运行中的设备。签名钥为双信任域，互不通用（CONTEXT.md）。

## 本地复现

```sh
git clone https://github.com/immortalwrt/immortalwrt.git -b v25.12.1 --depth 1
curl -fL -o toolchain.tar.zst "$(grep TOOLCHAIN_URL= pins.env | cut -d= -f2)"
RECIPE_DIR=$PWD BUILDROOT=$PWD/immortalwrt \
  TOOLCHAIN_TARBALL=$PWD/toolchain.tar.zst FW_VERSION=25.12.1 FW_CODE=local \
  sh scripts/build.sh
```

本地提示（均由 build.sh 自动处理或预警，此处仅供排障）：

- PATH 里含空格/相对条目会被自动清洗（WSL 互导的 Windows PATH 会注
  入 `/mnt/c/Program Files/...`，令 find -execdir 拒绝工作）。
- 内存+swap 建议 ≥ 20G：x86 镜像组装的 dd 有 ~14G 内存尖峰，不足会
  被 OOM 击杀且日志只剩 `world Terminated`；不足时先加 swap 再跑。
- 改动涉及升级行为时，用 `scripts/verify-sysupgrade.sh --old <旧镜像>
  --new <新镜像>` 在虚拟机里跑一遍真升级（自动断言“重启过 / overlay 重建 /
  配置带回”，`--expect-guard` 断言 LAN 守卫，`--expect-capped` 断言只写载荷）。
  主机没有 qemu+OVMF 时自动退到 docker。
- 12 核等大并行度下 tools/dwarves 有竞态，build.sh 会预先串行编掉它。
- 同一 buildroot 重跑 build.sh 会因已存在 `.config` 拒绝（时序红线）；
  增量重建直接在 buildroot 里 `make -j$(nproc)` 即可，stamp 会续跑。
- honk 构建需联网拉取 rustup/Rust 工具链、crates.io 依赖、doona 与
  bpf-linker 产物——版本全由 honk 源码的钉点文件决定，build.sh 自动准备
  rustup 与 bpf-linker，无需预装（ADR-0004）。
