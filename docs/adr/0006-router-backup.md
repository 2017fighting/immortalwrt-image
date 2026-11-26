# 路由器配置的定时备份：R2 + rclone + AES 口令加密

路由器上唯一"丢了要命"的东西是 `/etc`：LAN/DHCP/防火墙规则、mihomo/honk 订阅
与节点、nikki 的账号与 api_secret、acme 证书私钥、tailscale 身份、frpc token、
dropbear host key、LuCI 的 uhttpd TLS 私钥、WiFi PSK。
镜像可以重建、包可以重装，这些配置不行。而它们恰好全在 `/etc` 里，且
`sysupgrade -b` 一把就能打包（实测本机 737KB / 155 个文件），所以备份问题不是
"备份什么"，而是"备份放到哪、什么时候跑、失败谁知道"。

三条候选路径的可行性是实测出来的，不是猜的：

- **NFS（truenas）**：本机 feed 里根本没有 `kmod-fs-nfs`。25.12 的 kmods 单独成一个
  feed（`releases/25.12.1/targets/x86/64/kmods/<kernel-abi>/`），而本机内核是
  `6.12.94~cecb676a…`（配方构建出的 ABI），官方 feed 是 `6.12.94-1-0413601b…`，
  装不上。要 NFS 就得把 kmod 编进镜像，且保留"NAS 一重启挂载点就 stale"。
  另外 truenas 上根本没有 `/mnt/backup` 的 NFS 导出（导出的全是 `/mnt/nova/*`
  与各 `pvc-*` 数据集），NFS 路线还得先加一条导出。否决。
- **WebDAV（openlist）**：`curl` 自带，零新包，但目的地是同一台 NAS（`/local`
  实际落在 `/mnt/nova/k8s/pvc-650bb10c…/local/`）—— 与 NFS 同故障域，而且
  openlist 跑在 k8s 上，多一层会挂的东西。作备选否决（要用时 rclone 只多写一行
  `[openlist]` remote）。
- **R2（Cloudflare）**：`rclone` 在 feed 里，凭据是一个只对本桶有 Object Read &
  Write 的令牌，异地、无带宽成本、桶私有。选它。

## 决策

- **远端：专用桶 `router-backup` + 专用令牌**。桶由 `wrangler`/CF API 建（location
  WNAM）。令牌用账号 API 生成，资源限定
  `com.cloudflare.edge.r2.bucket.<account>_default_router-backup`，权限只有
  "Bucket Item Read + Write"。实测：本桶读写通，跨桶 `blog-assets` 得到
  `AccessDenied`；桶级探测（`HeadBucket` / `GetBucketVersioning`）必然 403，
  rclone 侧用 `RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true` 关掉，不算失败。
- **凭据走环境变量，不落 `rclone.conf`**：`/etc/router-backup/secrets.conf`（0600，
  不进仓库、不进镜像）→ 脚本导出 `RCLONE_CONFIG_R2_*`。少一个落盘文件，也不会和
  LuCI 的 rclone 面板抢同一个 remote（面板不装，见下）。
- **内容：`sysupgrade -b` 的配置包 + 一份清单**，打成
  `bundle.tar.gz = tar(config.tar.gz, manifest.txt)`。清单里放固件版本、内核、
  feed 行、`apk list -I` 全文（升级只带配置不带包，重装靠它）。`/etc` 之外没有
  未打包的自定义文件（唯一例外是 `/root/hhh.txt` 垃圾桶），所以配置包就是全部
  有效状态。
- **加密：AES-256-CBC / PBKDF2 300k / sha256**，口令从 stdin 喂 `openssl`
  （镜像自带 `openssl-util`），不进 `ps`。口令托管两处：chezmoi 的
  `dot_config/private_router-backup/encrypted_private_env.age`（age）+ 密码管理器。
- **频率：每天 04:17（cron），配置没变就不传**。`sysupgrade -b` 是确定性的
  （实测连跑两次 sha256 相同），所以用上一个包的 sha256 当哨兵：同哈希就 SKIP，
  只在每月 1 号例外（那天要留月归档）。保留：`daily/` 滚动 14 天，`monthly/` 滚动
  190 天（≈6 个月各一份），都用 `rclone delete --min-age`，清理失败只警告。
- **告警：失败才推 ntfy**（自建，home-ops `apps/ntfy`；`https://ntfy.raenzo.com/router`，
  token 是 ntfy 里 Publisher User `router` 的 access token，只能写这一个 topic）。
  2026-11-25 前是 bark（`https://bark.raenzo.com/<device key>`），随 home-ops 那边 bark
  退役改过来；bark 把凭据放在 URL 里，ntfy 把它放在 `Authorization` 头里。路由器实测能
  解析到 LAN 内入口 `192.168.9.64` 并拿到 200（bark 与 ntfy 都验证过）。成功和
  SKIP 不打扰。`curl` 带 `-f`：没有它 401/403 也算成功，日志会写「已推送」而告警
  其实没出去。状态落在 `/root/router-backup.status`、日志
  `/root/router-backup.log`（原地截断留 500 行）。
- **不装 LuCI**：`luci-app-rclone` 会把 remote 和 web 面板一起放到 LAN 上（默认
  账号 `admin/admin`），与"每天传一次 700KB"不成比例。手动入口是
  `/usr/sbin/router-backup [run|status|test-alert]`。
- **不做 sysupgrade 钩子**：不覆盖 `/sbin/sysupgrade`。刷机/大改前手动跑一次
  `router-backup run`，写在 [restore-router.md](../restore-router.md) 里。
- **归档全量保留敏感凭据**：acme 私钥、`dnsapi.conf`（Cloudflare API token）、
  frpc token 都在包里。理由：恢复的价值就在于"不用重签证书、不用重新申请
  token"，风险用加密 + 桶私有 + 口令托管收口。

## Considered Options

- **NFS 挂载 truenas**（否决：kmod 装不上，见上；且 NAS 重启后挂载点 stale，
  失败模式比"上传失败"难受得多）
- **WebDAV 到 openlist（或 rclone 双写）**（本轮否决：同故障域，异地这一条没了；
  脚本已把远端抽象成 rclone remote，将来加一行就能双写）
- **与 `scripts/tf-snapshot.sh` 对齐（age 收件人 + `archive/` 只增不改 + wrangler 上传）**：
  home-ops 里已有先例——tfstate 快照在 host 侧用 `sops -e --age`（收件人取自
  `.sops.yaml`）加密，写到桶锁保护、拒绝覆盖与删除的 `archive/`。本轮不照搬，
  三条都是实测约束：路由器 feed 里没有 `age`/`sops` 二进制（只有 `openssl-util`），
  而备份必须在设备还活着时就已存在（cron 在设备上）；只增不改对 700KB/天 的配置
  快照等于只涨不落；`wrangler` 在设备上也不存在。代价见 Consequences 的最后一条。
- **把口令加密换成 rclone crypt**（否决：仍然是口令，且多一层 remote 配置，
  恢复时还多一个 rclone 依赖）
- **不加密上传**（否决：包里就是 WiFi PSK 与证书私钥，桶配错一次就全泄）
- **gnupg 公钥加密**（否决：feed 里只有 gnupg 1.4，私钥管理比口令多一个失败面，
  而口令已有 chezmoi + 密码管理器两处兜底）
- **`rclone sync` 到固定文件名**（否决：没有历史，覆写即失去"上一个好版本"）
- **整盘/overlay 镜像**（否决：每天几百 MB，跨固件版本不能直接用）
- **配置变更即备份（事件触发）**（否决：`/etc` 每天都有噪音写入（acme、ddns
  日志），会退化成"每天必传"，还得另做去重）

## Consequences

- **一条口令决定生死**：口令丢了 = 备份是废纸。所以 escrow 必须在**两处**，
  且换机时要先验：`router-backup status` 看一眼最新对象，再拿口令解一次
  （做法见 restore 文档的"演练"一节）。
- **当前设备的 rclone 是手工解出来的**：feed 里的 `rclone` 依赖链是
  `fuse3-utils → libfuse3 → kmod-fuse`，而 kmod 无法从官方 feed 装（ABI 不匹配）。
  实测 rclone 二进制是静态 Go、不链 `libfuse3.so`（只有 `rclone mount` 需要
  fuse），所以用 `apk fetch` + `apk extract` 把 `/usr/bin/rclone` 解出来即可，
  S3 读写全部正常。**下一次镜像构建**已经把这个包写进 seed（
  `CONFIG_PACKAGE_rclone=y`），届时 kmod-fuse 由本配方自己编进镜像，设备侧
  回到正常的 apk 管理。
- **`apk` 世界里没有 rclone**：在这台设备上 `apk list -I | grep rclone` 是空的，
  下次 `apk upgrade` 不会动它；镜像升级后由包管理接管。
- **skip 语义依赖 `sysupgrade -b` 的确定性**：上游若改成把时间戳写进归档，
  哨兵会永远对不上，表现为"每天照传一份"——功能不受影响，只是白传 700KB。
  日志里能直接看出来（不再出现 SKIP 行）。
- **顺带修正了一条认识**：25.12 的 kmods 不是"没有源"，而是单独的 `kmods/<abi>`
  feed；本配方不往 distfeeds 里加**kmods 那条 feed**，是因为官方 ABI 与自己的构建
  不一致，kmod 只能自己编进镜像（与原 seed 注释一致；distfeeds 的 host 与行集合
  另由 [ADR-0008](0008-apk-repository-list-in-image.md) 决定，与这里说的不是同一件事）。
- **凭据轮换成本**：换 R2 令牌只需改两台机器的 `secrets.conf` / escrow（桶与对象
  不动）；换加密口令则**历史归档全部作废**——所以口令一旦生成就别再改，
  要换就换一个目录/桶从头开始。
- **与 tfstate 归档刻意不同**：`home-ops-tfstate/archive/` 是 age 加密 + 桶锁
  只增不改；这里是 openssl 对称 + 按时间清理。判断依据是“谁的机器上跑”：host
  侧有 age/sops 与 wrangler，设备侧只有 openssl 与 rclone。两者对齐需要把备份
  改成 host 拉取（依赖这台机器每天在线），那是另一个决策，尚未做。
- **桶里没有开 object versioning**：R2 的 versioning 只能从面板开（CF API 里
  没有对应路由，实测 `/r2/buckets/<bucket>/versioning` → 404），所以脚本本身
  不依赖它。想要“误删也找得回”就去面板开一下，脚本无感。
