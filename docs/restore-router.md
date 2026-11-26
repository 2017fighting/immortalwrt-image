# 恢复路由器：从 R2 上的加密配置包回到一台可用设备

配套决策见 [ADR-0006](adr/0006-router-backup.md)。这里只有"手怎么动"。

**先记住三条事实**：

1. 备份每天 04:17 自动跑一次（`/etc/crontabs/root`），配置没变的那天只有一行
   `SKIP`，不会多传。
2. 每个 `.tar.gz.enc` 解出来是 `config.tar.gz`（`sysupgrade -b` 的格式）+
   `manifest.txt`（固件版本、feed 行、`apk list -I` 全文）。
3. 解包口令在 **chezmoi 的 `~/.config/router-backup/env`**（age 加密，本机
   `chezmoi apply` 后是明文 0600）+ 你的密码管理器。两处都丢了，
   包就是废纸 —— 这是这套方案唯一的单点。

## 手边先要有的东西

```sh
# 本机（escrow 解开之后）
. ~/.config/router-backup/env          # R2_ROUTER_* / ROUTER_BACKUP_PASSPHRASE
export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
  RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ROUTER_ACCESS_KEY_ID" \
  RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_ROUTER_SECRET_ACCESS_KEY" \
  RCLONE_CONFIG_R2_ENDPOINT="$R2_ROUTER_ENDPOINT" \
  RCLONE_CONFIG_R2_REGION=auto RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true

rclone lsf r2:router-backup/daily | tail -5     # 最近几份
mkdir -p /tmp/restore && cd /tmp/restore
rclone copy r2:router-backup/daily/immortalwrt-router-<stamp>.tar.gz.enc .

printf '%s' "$ROUTER_BACKUP_PASSPHRASE" |
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 300000 -md sha256 \
    -pass stdin -in immortalwrt-router-<stamp>.tar.gz.enc -out bundle.tar.gz
tar xzf bundle.tar.gz        # → config.tar.gz + manifest.txt
head -20 manifest.txt        # 确认这是你想要的那个固件版本/日期
```

## 路径 A：重刷本配方构建的镜像（主路径）

1. 从 [immortalwrt-image releases](https://github.com/2017fighting/immortalwrt-image/releases)
   拿同版本（或更新的）`*-squashfs-combined-efi.img.gz`（UEFI）/
   `*-squashfs-combined.img.gz`（BIOS）。
2. 首刷：照 README「刷机」那条 `dd`；或设备还能进系统时直接
   `sysupgrade -n <img>`（`-n` = 不保留配置，反正我们要覆盖回自己的）。
3. 设备起来后 LAN 是 `192.168.9.1/24`，ssh 进去。
4. 覆盖配置并重启：

```sh
# 本机
scp 不支持（dropbear 没有 sftp-server），用 tar 流：
tar -C /tmp/restore -cf - config.tar.gz | ssh root@192.168.9.1 'tar -xf - -C /tmp'
ssh root@192.168.9.1 '
  sysupgrade -r /tmp/config.tar.gz     # 只解包进 /etc，不重启
  chmod 600 /etc/router-backup/secrets.conf
  reboot
'
```

`sysupgrade -r` 会把 `/etc` 恢复成备份里的样子 —— 包括 `/etc/router-backup/`
（secrets、脚本）与 `/etc/sysupgrade.conf` 里那行 `/etc/router-backup/`。
重启后 `90-router-backup` 是镜像自带的（在 `/etc/uci-defaults/`），会把 cron 与
`/usr/sbin/router-backup` 重新接上。

5. 验收：

```sh
router-backup status        # 应显示 result=ok（第一次手动 `router-backup run`）
ping -c1 1.1.1.1            # 网络、DNS、代理规则按备份里的 uci 恢复
```

## 路径 B：官方 ImmortalWrt 镜像 + 包清单（备选）

用于本地构建环境坏掉、但设备要活过来的情况。自定义 feed 必须能访问
（`openwrt-feeds` Pages 源 + daeuniverse），否则 honk/punchd 装不回来（punchd 依赖的
官方 `natmap` 在上游 packages 源里，那份源本来就有）。另外：旧 `manifest.txt` 里的
`natmapt` / `stuntman-client` / `mihomo-*` 已经不再发布（openwrt-feeds ADR-0002），
按清单装到这几个名字会直接 "no such package"，跳过即拉倒。

```sh
# 1. 刷官方 x86/64 25.12.x combined-efi 镜像，起来后 LAN 是 192.168.1.1
# 2. 先补信任与 feed（同仓库 files/etc/apk/ 的两个来源），再按清单装包：
grep -E ' x86_64 ' /tmp/restore/manifest.txt | awk '{print $1}' | head    # 看一眼
ssh root@192.168.1.1 'apk update && apk add rclone'                      # 至少先有 rclone
# 3. 恢复 /etc（同路径 A 的 sysupgrade -r），reboot
```

官方镜像不带本配方的 `files/` 覆盖层（`/etc/router-backup/` 脚本、
`90-router-backup`、LAN 默认值），所以路径 B 之后要跑一次
`scripts/deploy-router-backup.sh` 把脚本与接线推上去（或者直接改用路径 A）。

## 演练（不动机器，只验"包读得出来"）

每季度做一次，5 分钟：

```sh
# 接「手边先要有的东西」全部命令到 `tar xzf bundle.tar.gz` 为止，然后：
want=$(sed -n 's/^config_tar_sha256=//p' manifest.txt)
[ "$want" = "$(sha256sum config.tar.gz | awk '{print $1}')" ] && echo "校验通过"
tar tzf config.tar.gz | wc -l          # 155 左右（文件数随配置增长）
tar tzf config.tar.gz | grep -E 'etc/config/(network|dhcp|firewall)$'
```

三项都对 = 归档可用、口令正确、清单与包一致。**不要**在演练里 `sysupgrade -r`
到正在工作的路由器上。

## 出事时的判断表

| 现象 | 大概率原因 | 动作 |
|---|---|---|
| `router-backup run` 说「缺少配置项」 | `/etc/router-backup/secrets.conf` 丢了 | 从 escrow 重建（`secrets.conf.example` 是模板） |
| 上传失败、`SignatureDoesNotMatch` | secret 用错（API 生成的令牌要 `sha256(token value)`，见 ADR-0006） | 面板重发令牌并核对 |
| 跨桶/桶级探测 403 | 正常：令牌只对本桶有 Object Read & Write | 无需处理 |
| `bucket not found` | `backup.conf` 里桶名被改 | `R2_BUCKET=router-backup` |
| 日志里再也没有 `SKIP` | `/etc` 天天在变（某个包写日志进 `/etc`） | 无害，只是每天多传 700KB；要省流量就把那个路径挪到 `/tmp` |
| 手机没收到过任何失败告警 | ntfy token 错 / ntfy 不在 LAN 内可达 | `router-backup test-alert` 手测；日志里有 `WARN ntfy 推送失败`（带 HTTP 状态码：401 = token，000 = 连不上） |
