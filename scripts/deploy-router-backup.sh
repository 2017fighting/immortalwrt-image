#!/bin/sh
#
# 把 files/etc/router-backup/ 与 files/etc/uci-defaults/90-router-backup 推到
# 已经在跑的路由器上，跑一遍接线。用途是**改脚本后立刻生效**，不用整轮构建；
# 镜像构建自带同一份文件（files/ 覆盖层），两边不产生第二个源。
#
# 走 `tar -C ... | ssh tar -x` 而不是 scp：dropbear 没有 sftp-server，
# OpenSSH 9 的 scp 默认走 SFTP，对 ImmortalWrt 会直接 "Connection closed"。
#
# 不做的事：不动 /etc/router-backup/secrets.conf（密钥从 ADR-0006 记的那份
# chezmoi escrow 来）。缺它时照推，只是备份会以「缺少配置项」失败并推 bark。
#
# 用法：scripts/deploy-router-backup.sh [ssh-host]     # 默认 router
#
set -eu

HOST=${1:-${ROUTER_HOST:-router}}
here=$(cd "$(dirname "$0")/.." && pwd)
src=$here/files/etc

ssh "$HOST" 'mkdir -p /etc/router-backup /etc/uci-defaults'

tar -C "$src" -cf - router-backup uci-defaults/90-router-backup |
	ssh "$HOST" 'tar -xf - -C /etc'

ssh "$HOST" '
	sh /etc/uci-defaults/90-router-backup
	rm -f /etc/uci-defaults/90-router-backup
	if [ ! -r /etc/router-backup/secrets.conf ]; then
		echo "注意：/etc/router-backup/secrets.conf 不存在，备份会以「缺少配置项」失败并推 bark。" >&2
	fi
	echo "--- 接线结果 ---"
	grep -n "router-backup" /etc/crontabs/root || echo "cron: 未写入"
	grep -qx "/etc/router-backup/" /etc/sysupgrade.conf && echo "sysupgrade 保留: /etc/router-backup/"
	ls -l /usr/sbin/router-backup
'
