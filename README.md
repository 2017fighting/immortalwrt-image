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

## 常见变更

| 想要什么 | 改哪里 |
|---|---|
| 加/减内置包 | `config/x86-64.seed` 加/删一行 `CONFIG_PACKAGE_xxx=y` |
| 升级上游（如 v25.12.2） | `pins.env` 三项（tag、URL、sha256 取自官方 sha256sums） |
| 升级 openwrt-feeds | `feeds.extra` 的 `^commit` |
| 升级 honk（引擎） | `pins.env` 的 `HONK_TAG` + `feeds.extra` 的 daeuniverse `^commit`（两者配套，见 ADR-0004） |
| 设备在线升级 honk | `apk add honk@daeuniverse luci-app-honk@daeuniverse luci-lib-daeuniverse@daeuniverse luci-i18n-daeuniverse-zh-cn@daeuniverse` |
| 回退 mihomo | 设备上 `apk add mihomo-alpha mihomo-bare`（openwrt-feeds Pages 源已预置；先停 honk，两引擎数据面互斥） |
| 改 LAN IP | `files/etc/uci-defaults/99-lan-ip` |
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
  （本镜像内核自带 BTF，恰好成立）。honk 硬依赖的 `kmod-veth` / `kmod-sched-bpf`
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
- 12 核等大并行度下 tools/dwarves 有竞态，build.sh 会预先串行编掉它。
- 同一 buildroot 重跑 build.sh 会因已存在 `.config` 拒绝（时序红线）；
  增量重建直接在 buildroot 里 `make -j$(nproc)` 即可，stamp 会续跑。
- honk 构建需联网拉取 rustup/Rust 工具链、crates.io 依赖、doona 与
  bpf-linker 产物——版本全由 honk 源码的钉点文件决定，build.sh 自动准备
  rustup 与 bpf-linker，无需预装（ADR-0004）。
