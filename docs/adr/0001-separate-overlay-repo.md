# 独立配方仓库，不改 immortalwrt fork

要构建个人 ImmortalWrt 固件（自有 feed 内置、预置 feed 公钥与注册、改 LAN IP、squashfs），定制层全部住在 buildroot 树外（seed 配置 + files 覆盖 + feeds.conf.local），这正是 OpenWrt 构建体系为"用户定制"设计的官方通道；因此决定新建独立的配方仓库 `immortalwrt-image`（GitHub Actions + shell + seed + files），CI 直接 checkout 钉住的上游 immortalwrt/immortalwrt tag 后把配方铺上去构建；个人 fork（若有）只是镜像，不参与构建。

**Considered Options**:

- 直接在 fork 上提交定制（否决：把"上游镜像"和"我的配方"两个概念焊死，每次同步都是 merge/rebase 心智负担，CI 与固件发布混进镜像仓库）
- 混合——配方仓库 + fork 携带源码补丁（否决于当下：目前是纯配置层；若未来确需源码补丁，fork 加提交、配方钉 fork commit 即可演进到此形态，配方结构不变）

**Consequences**:

- 配方即固件——一个页面能看完的仓库就是全部意图；版本钉点集中一处，产物可复现。
- openwrt-feeds 仓库不为此改动：它继续只管二进制包 feed，镜像侧仅消费它的 Makefile 与公钥。
- key-build 钥匙丢失的恢复成本为零（sysupgrade 整体替换 /rom 与内置公钥），不需备份策略。
