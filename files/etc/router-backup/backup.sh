#!/bin/sh
#
# router-backup —— 路由器配置的定时快照，远端是 Cloudflare R2 的一个私有桶。
#
# 取舍与依据见 docs/adr/0006-router-backup.md；恢复步骤见 docs/restore-router.md。
#
# 用法：
#   router-backup run          备份一次（cron 的默认入口）
#   router-backup status       最近一次结果（含日志尾部）
#   router-backup test-alert   只发一条 ntfy 测试推送，不碰备份
#
# 输入：
#   /etc/router-backup/backup.conf     非敏感默认值（随镜像分发）
#   /etc/router-backup/secrets.conf    R2 凭据 / 加密口令 / ntfy token
#                                      （**不进仓库**、0600、sysupgrade 保留）
#
# 产出（每次一条记录，两个对象）：
#   daily/immortalwrt-router-<stamp>.tar.gz.enc
#       加密后的 bundle：config.tar.gz（sysupgrade -b）+ manifest.txt（包清单）
#   monthly/immortalwrt-router-<YYYYMM>.tar.gz.enc
#       每月 1 号多存一份，供"上个月还没坏"的回滚点
#
set -u

BASE=/etc/router-backup
CONF=$BASE/backup.conf
SECRETS=$BASE/secrets.conf
LOG=/root/router-backup.log
STATUS=/root/router-backup.status
SENTINEL=/root/router-backup.sha
LOCK=/tmp/router-backup.lock

[ -r "$CONF" ] && . "$CONF"
[ -r "$SECRETS" ] && . "$SECRETS"

log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

set_status() { # <result> <detail> <bytes>
	{
		echo "last_run_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		echo "result=$1"
		echo "detail=$2"
		echo "bytes=${3:-0}"
		echo "log=$LOG"
	} >"$STATUS"
}

# 告警：发到自建 ntfy（home-ops apps/ntfy）。PUT 到 /<topic>，token 走 Authorization
# 头，标题走 X-Title，正文是请求体（纯文本，不拼 JSON，多行照发）。
# <level> 沿用 bark 时代的两个值并映射成 ntfy 优先级：timeSensitive → 4，active → 3。
# -f 必须有：没有它，401/403（token 错、ACL 变了）对 curl 是「传输成功」，日志会写
# 「已推送」而告警其实没出去 —— 这条通道只在失败时用，错一次可能很久都没人发现。
# 发送失败只记日志，绝不改变备份本身的退出码（die() 调用它后 exit 1，退出码来自 die）。
# NTFY_RESULT 给 test-alert 用：ok / 未配置 / 失败原因 —— 人手验证通道时，命令的最后一句话
# 必须说实话（原 bark 版无论成败都打「已发送」，而日志只有 WARN）。
NTFY_RESULT=''
ntfy() { # <title> <body> [level]
	NTFY_RESULT='未配置 NTFY_TOKEN'
	[ -n "${NTFY_TOKEN:-}" ] || return 0
	case "${3:-timeSensitive}" in
		active) NTFY_PRI=3 ;;
		*) NTFY_PRI=4 ;;
	esac
	if http="$(curl -sS -m 10 -f -o /dev/null -w '%{http_code}' \
		-X PUT "$NTFY_SERVER/$NTFY_TOPIC" \
		-H "Authorization: Bearer $NTFY_TOKEN" \
		-H "X-Title: $1" \
		-H "X-Priority: $NTFY_PRI" \
		--data-binary "$2" 2>/dev/null)"; then
		log "ntfy 已推送（$NTFY_SERVER/$NTFY_TOPIC，HTTP $http）"
		NTFY_RESULT=ok
	else
		# http 为空 = 连状态码都没拿到（连不上 / 超时）
		log "WARN ntfy 推送失败（$NTFY_SERVER/$NTFY_TOPIC，HTTP ${http:-000}）—— 告警本身没送出去"
		NTFY_RESULT="推送失败（HTTP ${http:-000}）"
	fi
	return 0
}

die() { # <detail>
	log "ERROR $*"
	set_status failed "$*" 0
	ntfy "路由器备份失败" "$(uname -n): $*"
	exit 1
}

require_secrets() {
	miss=''
	[ -n "${R2_BUCKET:-}" ] || miss="$miss R2_BUCKET"
	[ -n "${R2_ENDPOINT:-}" ] || miss="$miss R2_ENDPOINT"
	[ -n "${R2_ACCESS_KEY_ID:-}" ] || miss="$miss R2_ACCESS_KEY_ID"
	[ -n "${R2_SECRET_ACCESS_KEY:-}" ] || miss="$miss R2_SECRET_ACCESS_KEY"
	[ -n "${BACKUP_PASSPHRASE:-}" ] || miss="$miss BACKUP_PASSPHRASE"
	[ -z "$miss" ] || die "缺少配置项:$miss（见 $BASE/secrets.conf.example）"

	# 凭据走环境变量而不是 rclone.conf：少一个落盘文件，也不会和 LuCI 的
	# rclone 面板抢同一个 [remote]。
	export RCLONE_CONFIG_R2_TYPE=s3
	export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
	export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
	export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
	export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
	export RCLONE_CONFIG_R2_REGION=auto
	# 令牌只对这一个桶有 Object Read & Write：桶级探测（HeadBucket /
	# GetBucketVersioning）必然 403，直接关掉，别当失败。
	export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
}

rclone_r2() {
	rclone "$@" --log-level ERROR --retries 3 --retries-sleep 10s --contimeout 15s --timeout 3m --low-level-retries 10
}

do_run() {
	require_secrets
	mkdir "$LOCK" 2>/dev/null || die "另一份备份还在跑（$LOCK 存在）"

	work=''
	trap 'rm -rf "$work"; rmdir "$LOCK" 2>/dev/null' EXIT INT TERM
	work=$(mktemp -d /tmp/router-backup.XXXXXX) || die "mktemp 失败"

	stamp=$(date -u +%Y%m%dT%H%M%SZ)
	name="immortalwrt-router-$stamp.tar.gz.enc"

	# 1. 配置包：和 LuCI「生成备份」同一个来源，/etc 里 155 个文件约 700KB。
	sysupgrade -b "$work/config.tar.gz" >/dev/null 2>&1 || die "sysupgrade -b 失败"
	cfg_sha=$(sha256sum "$work/config.tar.gz" | awk '{print $1}')

	# 2. 清单：恢复时先看它决定要装哪些包，解密与否都能读（它也在加密包里）。
	{
		echo "# 随机镜像的配置快照清单"
		echo "created_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
		echo "hostname=$(uname -n)"
		echo "kernel=$(uname -srm)"
		echo "config_tar_sha256=$cfg_sha"
		echo
		echo "## /etc/openwrt_release"
		sed -n '/^DISTRIB_/p' /etc/openwrt_release 2>/dev/null
		echo
		echo "## apk feed"
		cat /etc/apk/repositories.d/*.list 2>/dev/null | grep -v '^#'
		echo
		echo "## apk list -I（重装用；升级只带配置不带包）"
		apk list -I 2>/dev/null
	} >"$work/manifest.txt"

	tar -czf "$work/bundle.tar.gz" -C "$work" config.tar.gz manifest.txt ||
		die "打包 bundle 失败"

	# 3. 加密：openssl 是镜像自带的 openssl-util，口令从 stdin 走（不进 ps）。
	printf '%s' "$BACKUP_PASSPHRASE" |
		openssl enc -aes-256-cbc -pbkdf2 -iter 300000 -md sha256 -salt \
			-in "$work/bundle.tar.gz" -out "$work/$name" -pass stdin ||
		die "openssl 加密失败"

	# 4. 配置没变就不上传（每月的 1 号除外：那天要留月归档）。
	if [ "$cfg_sha" = "$(cat "$SENTINEL" 2>/dev/null)" ] && [ "$(date +%d)" != '01' ]; then
		log "SKIP 配置未变（config.tar.gz sha256 $cfg_sha）"
		set_status skipped '配置未变，未上传' 0
		return 0
	fi

	# 5. 上传并**回读校验**：只看 exit code 不够，R2 上少一个字节也算失败。
	local_sha=$(sha256sum "$work/$name" | awk '{print $1}')
	rclone_r2 copyto "$work/$name" "r2:$R2_BUCKET/daily/$name" || die "上传 daily/$name 失败"
	remote_sha=$(rclone_r2 cat "r2:$R2_BUCKET/daily/$name" | sha256sum | awk '{print $1}')
	[ "$remote_sha" = "$local_sha" ] || die "回读校验不一致（本地 $local_sha / 远端 $remote_sha）"

	if [ "$(date +%d)" = '01' ]; then
		mname="immortalwrt-router-$(date -u +%Y%m).tar.gz.enc"
		rclone_r2 copyto "$work/$name" "r2:$R2_BUCKET/monthly/$mname" || die "上传 monthly/$mname 失败"
		log "OK 月归档 monthly/$mname"
	fi

	# 6. 清理：daily 滚动 RETENTION_DAYS 天，monthly 滚动 MONTHLY_KEEP_DAYS 天
	#    （≈6 个月各一份）。清理失败只算警告——备份已经落地了。
	rclone_r2 delete "r2:$R2_BUCKET/daily" --min-age "${RETENTION_DAYS:-14}d" ||
		log "WARN 清理 daily 失败（备份本身已成功）"
	rclone_r2 delete "r2:$R2_BUCKET/monthly" --min-age "${MONTHLY_KEEP_DAYS:-190}d" ||
		log "WARN 清理 monthly 失败（备份本身已成功）"

	printf '%s\n' "$cfg_sha" >"$SENTINEL"
	bytes=$(wc -c <"$work/$name")
	log "OK 上传 daily/$name（$bytes 字节，sha256 $local_sha）"
	set_status ok "daily/$name" "$bytes"
}

do_status() {
	if [ -r "$STATUS" ]; then cat "$STATUS"; else echo 'result=never'; fi
	echo '--- 最近 20 行日志 ---'
	tail -n 20 "$LOG" 2>/dev/null
	# 看状态不该触发告警：缺密钥时安静地跳过远端查询。
	if [ -n "${R2_ACCESS_KEY_ID:-}" ] && [ -n "${R2_SECRET_ACCESS_KEY:-}" ]; then
		require_secrets
		echo '--- 远端最近对象 ---'
		rclone_r2 lsf "r2:$R2_BUCKET/daily" 2>/dev/null | tail -n 5
		rclone_r2 lsf "r2:$R2_BUCKET/monthly" 2>/dev/null | tail -n 6
	else
		echo '--- 远端：没有 secrets.conf，跳过 ---'
	fi
}

case "${1:-run}" in
run | now)
	exec >>"$LOG" 2>&1
	do_run
	# 原地截断（保持 inode）：日志只留最后 500 行，overlay 上不积累。
	tail -n 500 "$LOG" >/tmp/router-backup.log.tmp && cat /tmp/router-backup.log.tmp >"$LOG"
	rm -f /tmp/router-backup.log.tmp
	;;
status) do_status ;;
test-alert)
	ntfy '路由器备份测试' "来自 $(uname -n) 的测试推送" active
	if [ "$NTFY_RESULT" = ok ]; then
		echo "已发送（去手机上看「路由器备份测试」）"
	else
		echo "没发出去：$NTFY_RESULT —— 看 $LOG 里的 WARN" >&2
		exit 1
	fi
	;;
*)
	echo "用法: $0 [run|status|test-alert]" >&2
	exit 2
	;;
esac
