# 跟随 openwrt-feeds 的 punchd-only 收编：natmap 改用官方包，natmapt / stuntman / mihomo 一起消失

姊妹仓库 `openwrt-feeds` 的 `cde46ab`（`docs/adr/0002`）把 feed 收成一个包：只留
`net/punchd`，删掉 `natmapt`（含 `luci-app-natmapt` 与 5 个脚本子包）、`stuntman`、
`mihomo-bare`、`mihomo-alpha`；`punchd` 的依赖从 `+natmapt` 改成 `+natmap`（官方
`openwrt/packages` 的包）。本仓库跟着做：`feeds.extra` 的 `^commit` 跳到 `cde46ab`，
seed 里 `CONFIG_PACKAGE_natmapt=y` + `CONFIG_PACKAGE_stuntman-client=y` 换成
`CONFIG_PACKAGE_natmap=y`（仍在 `punchd` 旁边），`build.sh` 的关键选择核对同步换名字。

**不跟不行的原因**很简单：这两条包在那个 commit 里已经不存在，seed 里选着它们的
镜像会在「存活审计」阶段失败（`defconfig` 丢行即报错），而 `punchd` 的依赖也换成了
另一个包名。

## 为什么 natmap 要显式写进 seed

`punchd` 只 `exec` 一个外部程序：`natmap`（每个 punch 起一个子进程把端口绑上）。
这个二进制现在来自**官方 packages feed**，不是我们那条源 feed —— 是镜像里第一个
「跨 feed 的硬依赖」。`+natmap` 本来会被 `defconfig` 自动选上，但那样 seed 里就完全
看不出这个二进制的出处，换/删时也看不见 diff。显式写一行，与 `kmod-veth` /
`vmlinux-btf-builtin` 同一个理由。

顺带核过：`natmap` 确实在钉住的上游里（immortalwrt/packages `84bd863` 的 `net/natmap`，
20260214），也在 25.12.2 的发布索引里（`packages/x86_64/packages/index.json`，4888 个包里
有它）——所以设备侧 `apk add natmap` 也走得通，与镜像里那份是同一个包。

## 这次真的丢掉的能力

- **回退 mihomo 没了**。[ADR-0004](0004-honk-dataplane-switch.md) 承诺的「honk 不行就
  `apk add mihomo-alpha mihomo-bare`」失效：这两个包随姊妹仓库 ADR 0002 删除，而上游
  feed 里**根本没有** mihomo（25.12.2 的 `packages` / `luci` / `routing` / `telephony` /
  `base` / `targets` 六个索引里都没有 `mihomo`）。honk 出问题时只剩**回刷旧镜像**一条路
  （旧 `.img.gz` 要自己留着）。
- **natmapt 的 `/www/natmap/<name>.json` 契约没了**：那个 LuCI 状态页随
  `luci-app-natmapt` 一起消失，外部读者只能从集群侧（punch-controller 的观测状态）取。
- **stuntman 的 NAT 类型测试没了**：它只服务于那个页面。

## 老设备迁移（运维动作，没办法用包声明自动化）

`natmap` 与 `natmapt` 抢同一批文件（`/usr/bin/natmap`、`/etc/config/natmap`、
`/etc/init.d/natmap`），而 apk 3 没有 conflicts 字段（`apk-package(5)` 只有
depends/provides），所以只能：

```sh
apk del natmapt luci-app-natmapt
apk add punchd            # 依赖会把官方 natmap 一起装上
/etc/init.d/punchd enable && /etc/init.d/punchd start    # 先放好 /etc/punch/token
```

**默认升级（保留配置）不需要卸包**：升级换的是整块新 rootfs，包集合跟着镜像走，旧
`natmapt` 不会被带过去。带过来的只有 `/etc/config/natmap`（`/etc/config/` 在保留
清单里），里面还是 natmapt 的 schema —— 官方 `natmap` 的同名 conffile 认不出它，
`punchd` 也不读它（直接 `exec` 二进制），不影响运行；想干净就 `rm` 掉。

## Considered Options

- **留在旧 `^commit` 上不动**（否决：那等于让镜像永久钉在一个已经废弃的 feed 上，
  姊妹仓库后续的 punchd 修复再也进不来；而且 `punchd` 的依赖分裂成两套源码树）。
- **照旧把 natmapt 的二进制从旧 commit 里编进镜像**（否决：两个包抢同一批文件，
  punchd 只用二进制，其余 init/UCI/脚本子包没有消费者；这正是姊妹仓库收编的理由）。
- **顺手装 `luci-app-natmap`（官方 luci feed 里有）找补回一个页面**（否决：punchd 不走
  UCI，页面上的实例与集群里的 `Punch` CR 是两套状态 —— 又回到「两个映射状态」的老问题）。
- **自己维护一份 mihomo 包保回退路径**（否决：等于把姊妹仓库刚删掉的东西在本仓库
  复活，且要自己跟上游 mihomo 版本；真出问题回刷上一版镜像更省事）。

## Consequences

- **distfeeds 不受影响**：`natmap` 在 `packages` feed 里，而这一行本来就在镜像的 6 行
  清单中（[ADR-0008](0008-apk-repository-list-in-image.md) 的断言不用改）。
- **镜像里多一个官方 `natmap` 的服务单元**：`/etc/init.d/natmap` 默认不自启，别
  `enable` 它 —— 那会是第二套往同一批端口打洞的东西。
- **构建多编一个 natmap**（C，几十 KB）；`punchd` 仍要 `golang/host`（`PKG_BUILD_DEPENDS`），
  与本条无关，早已在构建里。
- **`docs/restore-router.md` 的路径 B 要跳着读**：旧备份的 `manifest.txt` 里
  `natmapt` / `stuntman-client` / `mihomo-*` 现在都会 "no such package"。
- 已核（离线）：`immortalwrt/packages@84bd863` 有 `net/natmap`、无 `net/mihomo`；
  `immortalwrt/luci@d6167ea` 有 `luci-app-natmap`、无 `luci-app-mihomo`；v25.12.2 主树
  无 mihomo/natmap 包；25.12.2 六份发布索引里 `natmap` 在、`mihomo` 全无。
- **未验证**：下一次构建（`v25.12.2-r24+`）才会证明 `natmap` 真的装进镜像、`punchd` 的
  `Depends:` 在设备侧解得开；判据是构建日志的存活审计与 `apk list -I | grep natmap`。
