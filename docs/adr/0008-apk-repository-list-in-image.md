# 镜像里的 apk 仓库清单只列上游真发布了的 6 条，出厂仓库钉镜像站

设备上 `/etc/apk/repositories.d/distfeeds.list` 长期带着几条 404：

```text
https://mirrors.vsean.net/openwrt/releases/25.12.1/packages/x86_64/video/packages.adb
https://mirrors.vsean.net/openwrt/releases/25.12.1/packages/x86_64/openwrtfeeds/packages.adb
https://mirrors.vsean.net/openwrt/releases/25.12.1/packages/x86_64/daeuniverse/packages.adb
https://mirrors.vsean.net/openwrt/releases/25.12.1/packages/x86_64/nikki/packages.adb      # 早期版本
```

决定：**这个文件里只留 target packages 与 base/luci/packages/routing/telephony 这 6 条**，
用 seed 里的 `# CONFIG_FEED_<name> is not set` 关掉多出来的 feed 行；**出厂仓库的 host 换成
`mirrors.vsean.net`，版本段用 `%V` 随钉点自动跟随**；`scripts/build.sh` 末尾断言生成的文件
恰好是这 6 行。

## 这些行是谁写的

不是有人手写坏，是 `package/base-files/Makefile` 在安装阶段生成的：

```make
$(call FeedSourcesAppendAPK,$(1)/etc/apk/repositories.d/distfeeds.list)
$(VERSION_SED_SCRIPT) $(1)/etc/apk/repositories.d/distfeeds.list
```

`include/feeds.mk` 的 `FeedSourcesAppendAPK` 规则是「`feeds.conf` 里的每个 feed 名 ×
`CONFIG_FEED_<name>` → 一行 `%U/packages/%A/<feed>/packages.adb`」，`%U` = `CONFIG_VERSION_REPO`、
`%A` = `ARCH_PACKAGES`。`CONFIG_FEED_<name>` 是 tristate，`scripts/feeds` 生成的
`tmp/.config-feeds.in` 里对装过的 feed 给 `default y` —— 也就是说 **feed 只要进了
`feeds.conf`，就默认会出现在镜像的仓库清单里**。

而本仓库的 `feeds.conf` = `feeds.conf.default` + `feeds.extra`，于是：

| 行 | 来源 | 为什么 404 |
|---|---|---|
| `openwrtfeeds` | `feeds.extra` 的源 feed 钉点 | 二进制包在 `2017fighting.github.io/openwrt-feeds`，上游镜像站没有这个目录 |
| `daeuniverse` | 同上（ADR-0004） | 二进制包在 `openwrt.daeuniverse.org`，同上 |
| `nikki` | 历史上的第三条源 feed | 同上；`feeds.extra` 去 nikki 后这行自行消失，正好证明是它写的 |
| `video` | **上游** `feeds.conf.default` 的 `src-git video https://github.com/openwrt/video.git` | 发布目录只有 `base/luci/packages/routing/telephony`（25.12.1、25.12.2 的目录索引都核过）；上游自己的发布流水线用的是另一份 `feeds.conf`（发布目录里能下到，5 行，无 video） |

`nikki` 那行随钉点删除而消失、`daeuniverse` 那行随 ADR-0004 出现 —— 这条因果链本身就是
「生成物跟着 `feeds.conf` 走」的证据。

## 不只是难看

把 r20 的发布镜像解出 rootfs，chroot 进去跑镜像自带的 `apk`（不做任何修改）：

```text
WARNING: updating and opening https://…/packages/x86_64/video/packages.adb: No such file or directory
WARNING: updating and opening https://…/packages/x86_64/openwrtfeeds/packages.adb: No such file or directory
…
9 unavailable, 0 stale; 319 distinct packages available
```

**退出码 = 不可用仓库的条数**（9 条时 `EXIT=9`；手工删掉 video 与 openwrtfeeds 两行后
变成 `7 unavailable` / `EXIT=7`）。于是这个镜像里 `apk update` 永远非 0：任何
`set -e`、`apk update && …` 的脚本都会在那个点断掉（`openwrt-feeds` 的 `feed.sh` 正是
`apk update` 之后接 `echo success`），LuCI 包管理器也会把这几条当错误显示。

顺带核过：`mirrors.vsean.net` 只是 `downloads.immortalwrt.org` 的门面（302 到
`mirrors.pku.edu.cn`），**同一批路径在官方源上一样 404** —— 换镜像站修不了这件事。

## 决策的三段

1. **清单**：`config/x86-64.seed` 里三条否定行
   （`CONFIG_FEED_openwrtfeeds` / `CONFIG_FEED_daeuniverse` / `CONFIG_FEED_video`）。
   只影响生成物：feed 照旧 `update`/`install`、包照旧编，`CONFIG_FEED_*` 在整棵树里除了
   `FeedSourcesAppend*` 没有第二个用途。✅ 我们的二进制 feed 走 `files/etc/apk/repositories.d/`
   那两个 **预置注册**（`@daeuniverse` 标签那套），跟 distfeeds 是两条独立通路。
2. **出厂仓库**：`CONFIG_VERSION_REPO="https://mirrors.vsean.net/openwrt/releases/%V"`。
   版本段用 `%V`（= `CONFIG_VERSION_NUMBER`）而不是写死 `25.12.x`，升 `IMMORTALWRT_TAG` 时
   这一行不动。这也是把"在设备上手改 distfeeds.list 换成国内镜像"这个手工动作固化下来。
3. **守卫**：`build.sh` 末尾把生成物按 `releases/<版本>/<路径>` 归一化后与 6 条路径做集合比对，
   多一行少一行都失败。判据刻意不写死 host 与版本，所以换镜像站、升钉点时断言不用改；
   而 `%V` 没被替换、版本号没跟上、新增源 feed 忘记关，三种都会当场红。

## Considered Options

- **在 `build.sh` 里过滤 `feeds.conf`（照上游发布流水线的做法剔掉 video）**：否决。
  video 一离开 `feeds.conf`，`CONFIG_FEED_video` 符号就消失，seed 里的否定行会让
  "存活审计"失败 —— 两处机制、两处要改，而收益只是少下一次 feed。
- **`files/` 覆盖整份 `distfeeds.list`**：否决。要抄进版本号与架构，升钉点必须同步改文件，
  还得再加一条"文件里的版本 == `FW_VERSION`"的断言；而它换来的能力（换 host）用
  `CONFIG_VERSION_REPO` 就有，且那里是上游自己的旋钮。
- **构建时 `curl -I` 每条 URL**：否决。最贴近真实，但把 CI 押在公网可用性上（镜像站抖动
  就红在无关步骤），而且它抓不到"上游明天删掉 video feed"这类只有下次构建才发现的问题。
- **只清自定义两条，video 算上游的账**：否决。它同样让 `apk update` 非 0，等于修一半。
- **给上游提 issue 代替本地关掉**：做了也仍要在本地关（issue 不等于发布）；video 那行的
  处置留作可选项，不影响本 ADR。

## Consequences

- **新增源 feed 多一条纪律**：`feeds.extra` 加一行 `src-git`，必须同时在 seed 里加
  `# CONFIG_FEED_<name> is not set`；漏了会被构建期断言拦下（README「常见变更」表里有一行
  说明这件事）。
- **上游若删掉 video feed**，`CONFIG_FEED_video` 符号随之消失、`defconfig` 丢掉那行，
  存活审计会在构建里报"seed 选择丢失"——这是有意的：钉点升级时强制人看一眼仓库清单。
- **镜像站是单点**：`mirrors.vsean.net` 挂了设备侧 `apk` 全挂，且 apk 的仓库之间是并集语义，
  没有"fallback 到官方源"这回事（同一 feed 配两次会产生重复包）。要换域名就改
  `CONFIG_VERSION_REPO` 再跑一轮构建。
- **设备上的手改不保留**：`/etc/apk` 不在 sysupgrade 的保留清单里（`sbin/sysupgrade` 只显式
  剔掉 `/etc/apk/world`），所以默认升级（保留配置、不加 `-c`/`-o`）会换上镜像里的这一份，
  手改的行与 `distfeeds.list.bak` 都不会留下 —— 这正是把镜像站钉进配方的原因。用
  `-c`/`-o` 仍会把陈旧的整份 `/etc/apk` 带回来（ADR-0005 的同一提醒）。
- 已核（离线，无需真机）：
  - 从 `v25.12.1-r20` 发布镜像里取出的 `distfeeds.list` 就是上文那 8 行，`openwrtfeeds` 与
    `video` 各一行；
  - 同一台机器 chroot 跑镜像自带的 apk：9 条时退出码 9，删两行后 7 条时退出码 7；
  - `downloads.immortalwrt.org` 与 `mirrors.vsean.net` 上 `video`/`openwrtfeeds`/`daeuniverse`/
    `nikki` 全部 404，`base`/`luci`/`packages`/`routing`/`telephony` 全部 200；
  - 新增断言用「植入违规」自测：多一行 feed、版本段差一个补丁号、`%V` 未替换、文件缺失
    四种都返回 1；干净 6 行（host 换成 vsean）与行尾多一个空行都返回 0。
- **未验证**：这套改动要等下一次构建（`v25.12.2-r24+`）才会在真产物里出现；届时的判据是
  构建日志里的「apk 仓库清单核对通过：distfeeds.list 恰好 6 行」以及设备上 `apk update`
  退出码为 0。
