# immortalwrt-image

ImmortalWrt x86_64 软路由的**镜像配方**：用纯声明式的配置层把钉住的
[immortalwrt/immortalwrt](https://github.com/immortalwrt/immortalwrt) 官方发布版
编译成个人固件。本仓库不含任何 ImmortalWrt 源码，CI 直接 checkout 上游
 tag，一切定制见 [ADR-0001](docs/adr/0001-separate-overlay-repo.md)。

**产出**：squashfs 镜像（rootfs 8GB，EFI/BIOS 双出，GRUB 零秒直启），
LAN 默认 `192.168.9.1`。内置 [openwrt-feeds](https://github.com/2017fighting/openwrt-feeds)
全量（natmapt 全家桶含全部通知/下载器联动子包 + stuntman-client + mihomo 核
与裸核外壳）+ frpc/acme/tailscale（含社区 LuCI 面板）/sqm/statistics 等常用应用，预置 Pages feed 公钥与注册
（设备侧 `apk update && apk upgrade` 即可在线升级包）。

## 仓库结构

| 路径 | 角色 |
|---|---|
| `pins.env` | 钉点：上游 tag + 官方工具链 URL/sha256 |
| `feeds.extra` | 源 feed 钉点：openwrt-feeds（^commit，唯一一行） |
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
`192.168.9.1`。

## 常见变更

| 想要什么 | 改哪里 |
|---|---|
| 加/减内置包 | `config/x86-64.seed` 加/删一行 `CONFIG_PACKAGE_xxx=y` |
| 升级上游（如 v25.12.2） | `pins.env` 三项（tag、URL、sha256 取自官方 sha256sums） |
| 升级 openwrt-feeds（含 mihomo 核/外壳） | `feeds.extra` 的 `^commit` |
| 改 LAN IP | `files/etc/uci-defaults/99-lan-ip` |
| 换 feed 公钥 | `files/etc/apk/keys/2017fighting.pem` |

推送到 main 即自动重建发布。

## 当前产物与已验证的事实

最新一版 **`v25.12.1-r12`**（配方 `b4df67a`，2026-11-13，构建 1h24m）已验证：

- **eBPF 的门开着**：`CONFIG_KERNEL_DEBUG_INFO_BTF=y` 真的进了内核，vmlinux 带
  `.BTF` 段（构建末尾的「内核配置核对」步骤会当场断言，失败即不出包）。
  设备侧一条命令可确认：`ls -l /sys/kernel/btf/vmlinux`。见 [ADR-0002](docs/adr/0002-ebpf-datapath-kernel-btf.md)。
- **镜像内容**：natmapt 全家桶 + stuntman-client + `mihomo-alpha`（核，装
  `/usr/libexec/mihomo`）+ `mihomo-bare`（裸核外壳）；**没有** nikki 栈。
  设备侧：`apk list -I | grep -E 'mihomo-(alpha|bare)'`。
- **待下一版验证**：r12 之后 seed 补了 `tailscale` + `luci-app-tailscale-community`
  + 中文语言包（r12 产物里没有，换成这里下载的旧镜像就得自己 `apk add`）。
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
