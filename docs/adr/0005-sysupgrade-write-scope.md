# sysupgrade：只写 squashfs 有效载荷，LAN 默认值加守卫

镜像从 r5 起就一直在发，但“升得了”这件事从未验过。2026-11-16 一次真实失败
（LuCI 上传、勾了保留配置、机器是 UEFI、镜像也是 `combined-efi`）表现为：
页面打不开、ping 还通、设备一小时不重启，最后整盘 dd 回去。诊断结论不是死机——
`stage2` 的 `kill_remaining` 在写盘前 TERM/KILL 掉 uhttpd，页面失联是设计如此；
真正的问题是写入量。上游 x86 的 `platform_do_upgrade` 在分区布局未变时按**分区表
的大小**逐分区整块写，而 p2 就是 `CONFIG_TARGET_ROOTFS_PARTSIZE`：本配方 8192MB，
其中真实内容只有 squashfs 的 `bytes_used`（约 35MB），其余是零填充。目标机
（MV-32，29.5G 内置 SSD）实测写速约 12MB/s，写满 8.2GB 要 11–14 分钟，而用户侧
没有任何进度可言，十分钟就足以让人认定失败并重刷。

同时顺手验出第二处：`files/etc/uci-defaults/99-lan-ip` 是无条件 `uci set`，而
`/etc/uci-defaults/` 会在**每次保留配置升级后的首启**整批重跑（`/etc/init.d/boot`
的 `uci_apply_defaults`），于是虚拟机里把 LAN 改成 `192.168.99.1/24` 再升级，
升级后变回 `192.168.9.1` —— 一次升级就可能把用户挡在自己网段之外。

## 决策

- **产物不变**：`*-squashfs-combined-efi.img.gz`（UEFI）与
  `*-squashfs-combined.img.gz`（BIOS）本身就是 sysupgrade 镜像（`eb63` 引导码 +
  MBR/GPT + 分区表），`platform_check_image` 就认这个。不发额外命名副本，不加
  `metadata.json`（x86 的 `SUPPORTED_DEVICES` 为空，`append-metadata` 本来就不写），
  不为 sysupgrade 新增任何镜像定义。
- **覆盖 `platform_do_upgrade` 的写入范围**：`files/lib/upgrade/platform.sh` 只改
  “per-partition 写”这一步——squashfs 分区写 `bytes_used` 向上对齐到
  `ROOTDEV_OVERLAY_ALIGN`(64KB) 再多 64KB 零，其余分区与上游一致（`dd` 参数、
  磁盘签名、`platform_do_bootloader_upgrade`、EFI 的 `grub.cfg` PARTUUID 改写全抄
  上游）。多于 64KB 的那段零不是凑数：`mount_root` 会 `volume_identify()` 探测
  overlay 起点，不抹掉旧 f2fs 签名就会**复用旧 overlay**，把上一个版本的
  `/lib/apk/db` 一起带回新系统。
- **上游原文单独存一份**：`files/lib/upgrade/x86-platform-upstream` 是
  `target/linux/x86/base-files/lib/upgrade/platform.sh` 的逐字节副本，由我们的
  `platform.sh` source。**刻意不带 `.sh` 后缀**——`stage2` 的 `include /lib/upgrade`
  会把该目录所有 `*.sh` 按字母序 source 一遍，副本若叫 `*.sh` 且排在后面，就会把
  覆盖定义盖回上游实现（本次实测踩到：补丁静默失效，写入仍是 8.2GB，日志里连
  一行提示都没有）。ramfs 拷贝靠 `RAMFS_COPY_DATA` 补上，因为
  `switch_to_ramfs` 只自动拷 `*.sh` 与 `do_stage2`。
- **失败即回退**：读不出 `hsqs` 魔数、或算出的长度不在 (1MB, 分区大小) 内时，
  退回上游的整块写。宁可慢，不写出坏镜像。
- **`99-lan-ip` 加守卫**：只有 `network.lan.ipaddr` 仍是上游默认 `192.168.1.1`
  （含 `/24` 写法）或未设置时才写 `192.168.9.1/24`；其余一律不动，且恒 `exit 0`
  （非零会让 `uci_apply_defaults` 每次开机重试）。
- **配置保留策略不动**：默认保留，不加定制 keep 清单——已核实 honk 的
  `/etc/config/honk` + `/etc/honk/config.dae`（改动后按 `.conffiles_static` 哈希进
  备份）+ 包自带 `keep.d/honk`（`/etc/honk/data/`，订阅正文与 state db）、
  tailscale 的 `/etc/tailscale/`（buildroot 自动生成的 `keep.d/tailscale`）都在
  默认范围内，订阅/节点/节点身份不会丢。
- **CI 出包前断言**（`scripts/build.sh` 新增步骤）：上游副本与钉住 tag 逐字节
  一致；`files/lib/upgrade/` 的两个文件确实进了 `root-x86/` 且有执行位；
  manifest 含 `sysupgrade`/`base-files`/`fstools`/`mkf2fs`/`kmod-fs-f2fs`/
  `grub2-bios-setup`/`partx-utils`；每个 `*combined*.img.gz` 解压后引导码是
  `eb63`/`eb48`、offset 510 是 `55aa`、分区表可解析，squashfs 变体的最大分区
  起点是 `hsqs` 且尺寸恰为 8192MB（尺寸一变，布局比较就会走“整盘写”）。
- **文档写全操作面**：Release 正文与 README 都说明两种文件都可 sysupgrade、
  默认保留配置、**别用 `-c`/`-o`**（25.12 的排除清单不含 `distfeeds.list` 之类，
  而 apk 的 `!etc/apk` 保护让陈旧仓库永不自我纠正）、什么会丢（`/root`、`/opt`、
  额外分区）、自己 apk 装的包要重装、回滚靠事前留旧 `.img.gz`。

## Considered Options

- **改小 `PARTSIZE`（如 2048）**（否决：与写入范围无关，仍要整块写 2GB；且是一次
  破坏性变更，要先整盘重刷一次才回到 sysupgrade 轨道。分区尺寸本身仍由
  ADR-0005 之外的历史决策维持 8192）
- **只写文档、不改机制**（否决：目标机写速 12MB/s 是硬事实，8.2GB 的等待不会因为
  文档写得清楚就消失；用户侧也没有进度可看）
- **改 `default_do_upgrade` 或 `-p` 强制整盘写**（否决：整盘写把额外分区与分区表
  一起重写，比现状更危险）
- **沿用上游写法、把副本命名成 `platform.x86-upstream.sh`**（实测否决：被
  `include` 再次 source，覆盖静默失效）
- **做一键在线升级（owut / attended sysupgrade）**（本轮否决：25.12 只有客户端，
  服务端要自建 ASU + imagebuilder，2C4G/50–200GB 量级；本地 sysupgrade 先做实）
- **加定制 keep 白名单**（否决：honk/tailscale 的配置本就在默认范围内，
  白名单只会多一处漂移面）

## Consequences

- **与上游共享一个函数体的风险**：`platform_do_upgrade` 是从上游复制后改的，
  上游若改了它（新增分区处理、改 UUID/GPT 逻辑），零件不会自动跟。缓解手段是
  CI 对**上游副本**做逐字节比对（漂移即构建失败），升上游时必须人工复核覆盖
  的那一段差异。`platform_check_image`、`platform_copy_config`、
  `platform_do_bootloader_upgrade` 全部来自上游原文，未复制。
- **写入语义仍与上游等价**：`bytes_used` 之后不再写零，但 overlay 起点由
  `bytes_used` 决定、且对齐那段被显式抹零，所以首启一定重新 mkfs；`/sysupgrade.tgz`
  的恢复顺序不变。
- **CI 多一次外网取文件**：断言要拉 `raw.githubusercontent.com` 上钉住 tag 的
  `platform.sh`。构建本来就要联网（工具链、rustup），不新增失败面量级；但仍
  多了一个钉住 tag 必须存在的隐含依赖。
- **诊断知识写进 README**：升级期间 LuCI 必然失联（`kill_remaining`），
  不能再被当成失败信号；`-c`/`-o` 是陷阱；保留配置的边界（什么丢、什么留）
  有明文。
- **补丁只对“已经装上这一版”的设备生效**：升级时执行的是**正在运行**的系统里的
  `/lib/upgrade/platform.sh`，不是新镜像里的。所以 r12 及更早的设备升到含补丁的
  版本时，走的仍是旧的整块写（8.2GB、目标机上 11–14 分钟）——这一次要耐心等，
  **装上新版之后**的每一次升级才是 35MB / 秒级。反过来，`99-lan-ip` 的守卫来自
  **新镜像的 rootfs**，所以升到新版的这一次就已经生效。
- **实测数字**（同一台开发机 KVM/OVMF、16G 虚拟盘、Release 里的真镜像）：
  `r12 → r20`（旧系统无补丁）全程 69 秒；`r20 → r20`（带补丁）日志为
  `Squashfs payload 36MB of 8192MB partition`，写盘+重启 2 秒、全程 20 秒。
  目标机 MV-32 写速 12MB/s 对应整块写 11–14 分钟，与 2026-11-16 那次
  “卡死十几分钟”的现象完全对得上。
- 在线一键升级仍待后续决策：25.12 的客户端是 `owut` + `luci-app-attendedsysupgrade`
  （`auc` 已删），默认服务器是 ImmortalWrt 的 `https://sysupgrade.kyarucloud.moe`；
  自建 ASU 对本配方自定义 feed 与 8192 partsize 的实际成功率未验证。
