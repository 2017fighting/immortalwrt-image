#!/bin/bash
# 在虚拟机里验证 sysupgrade（ADR-0005）：刷旧镜像 → 改配置打标记 → sysupgrade
# 到新镜像 → 重启后核对“配置带回来了 / overlay 重建了 / 守卫生效了”。
#
# 用法：
#   scripts/verify-sysupgrade.sh --old <old.img.gz> --new <new.img.gz> [选项]
#
#   --work DIR        工作目录（默认 /var/tmp/verify-sysupgrade），镜像与串口日志都在里面
#   --disk SIZE       虚拟盘大小（默认 16G；必须 ≥ 镜像解压后体积）
#   --expect-guard    要求升级后 LAN IP 仍是升级前改过的值（新镜像含 99-lan-ip 守卫）
#   --expect-capped   要求日志里出现 "Squashfs payload"（旧镜像已含 ADR-0005 补丁）
#   --timeout SEC     等待升级重启的上限（默认 1800；旧版整块写 8.2GB 要 11–14 分钟）
#   --keep            跑完不关机、不删工作目录，便于人工进控制台
#
# 依赖：qemu-system-x86_64 + OVMF + socat + python3；主机没有这些时自动退到
# docker（alpine 容器里装 qemu-system-x86_64/ovmf/socat/python3，需要 /dev/kvm）。
#
# 判定（任何一条不满足即非零退出）：
#   1. 升级后设备能起来（看到新一次开机 + shell 提示符）
#   2. overlay 是新建的：f2fs UUID 变了，且升级前写进 /overlay 的标记文件消失
#      （ADR-0005 的 64KB 零区就是为这条：不清旧 f2fs 签名会复用旧 overlay）
#   3. 配置被带回：/etc/config/network 存在且 uci 可读
#   4. --expect-guard 时：LAN IP 仍是升级前改过的值（不被 99-lan-ip 重置）
#   5. --expect-capped 时：日志里出现 "Squashfs payload"（旧系统带补丁，p2 只写载荷）
set -eu

OLD_IMG=""; NEW_IMG=""
WORK=/var/tmp/verify-sysupgrade
DISK=16G
EXPECT_GUARD=0
EXPECT_CAPPED=0
TIMEOUT=1800
KEEP=0

die() { printf '::error:: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

while [ $# -gt 0 ]; do
	case "$1" in
		--old) OLD_IMG=$2; shift 2;;
		--new) NEW_IMG=$2; shift 2;;
		--work) WORK=$2; shift 2;;
		--disk) DISK=$2; shift 2;;
		--expect-guard) EXPECT_GUARD=1; shift;;
		--expect-capped) EXPECT_CAPPED=1; shift;;
		--timeout) TIMEOUT=$2; shift 2;;
		--keep) KEEP=1; shift;;
		-h|--help) sed -n '2,30p' "$0"; exit 0;;
		*) die "未知参数：$1（--help 看用法）";;
	esac
done
[ -n "$OLD_IMG" ] && [ -n "$NEW_IMG" ] || die "必须同时给 --old 与 --new"
case "$OLD_IMG" in /*) ;; *) OLD_IMG=$PWD/$OLD_IMG;; esac
case "$NEW_IMG" in /*) ;; *) NEW_IMG=$PWD/$NEW_IMG;; esac
[ -f "$OLD_IMG" ] || die "找不到 --old 镜像：$OLD_IMG"
[ -f "$NEW_IMG" ] || die "找不到 --new 镜像：$NEW_IMG"

# ---------- 运行时：本机 qemu 优先，否则 docker ----------
RUNTIME=host
CT=verify-sysupgrade
if ! command -v qemu-system-x86_64 >/dev/null 2>&1 || ! ls /usr/share/OVMF/OVMF_CODE.fd >/dev/null 2>&1; then
	command -v docker >/dev/null 2>&1 || die "主机没有 qemu+OVMF，也没有 docker —— 装一个再来"
	RUNTIME=docker
fi

mkdir -p "$WORK"
OLD_GZ=$WORK/old.img.gz
NEW_GZ=$WORK/fw-new.img.gz
DISK_IMG=$WORK/disk.img
LOG=$WORK/serial.log
SOCK=$WORK/console.sock
HTTP_PORT=${HTTP_PORT:-8099}

cp -f "$OLD_IMG" "$OLD_GZ"
cp -f "$NEW_IMG" "$NEW_GZ"

if [ "$RUNTIME" = docker ]; then
	W=/data
	docker rm -f "$CT" >/dev/null 2>&1 || true
	docker run -d --name "$CT" --device /dev/kvm --network host \
		-v "$WORK:/data" alpine sleep infinity >/dev/null
	docker exec "$CT" sh -c 'apk add --no-cache qemu-system-x86_64 qemu-img ovmf socat python3 >/dev/null 2>&1' \
		|| die "容器里装 qemu 失败（网络？）"
else
	W=$WORK
fi
rt() { if [ "$RUNTIME" = docker ]; then docker exec "$CT" sh -c "$1"; else sh -c "$1"; fi; }

cleanup() {
	[ "$KEEP" -eq 1 ] && { printf '\n--keep：虚拟机仍在跑，日志 %s：%s\n' "$LOG" "$SOCK"; return 0; }
	rt 'pkill -f qemu-system-x86_64 || true; pkill -f "http.server '"$HTTP_PORT"'" || true' >/dev/null 2>&1 || true
	[ "$RUNTIME" = docker ] && docker rm -f "$CT" >/dev/null 2>&1 || true
	return 0
}
trap cleanup EXIT

# ---------- 串口助手 ----------
# 文本一律走 stdin，避免两层 shell 的引号地狱
socat_send() { # <text>
	if [ "$RUNTIME" = docker ]; then
		printf '%s\n' "$1" | docker exec -i "$CT" socat -t 20 - "UNIX-CONNECT:$W/console.sock" >/dev/null 2>&1 || true
	else
		printf '%s\n' "$1" | socat -t 20 - "UNIX-CONNECT:$SOCK" >/dev/null 2>&1 || true
	fi
}
# 串口控制台在收到输入前不一定把 banner/提示符吐出来（实测：不敲回车就一直
# 停在 br-lan forwarding 那几行），所以每轮都先敲一个空行再找提示符。
wait_prompt() { # [时间上限秒]
	local limit=${1:-180} i=0
	while [ "$i" -lt "$((limit / 2))" ]; do
		socat_send ''
		sleep 1
		if tail -c 400 "$LOG" 2>/dev/null | tr -d '\r' | grep -q 'root@ImmortalWrt[^ ]*# $'; then
			sleep 1; return 0
		fi
		sleep 1; i=$((i + 1))
	done
	return 1
}
# 只看日志的某个偏移之后：重启前后都会出现同样的字串（br-lan forwarding 等），
# 不区分就会把第一次开机的旧行当成“新一次开机”
wait_log() { # <pattern> <时间上限秒> [起始偏移]
	local pat=$1 limit=${2:-300} from=${3:-1} i=0
	while [ "$i" -lt "$((limit / 2))" ]; do
		tail -c +"$from" "$LOG" 2>/dev/null | tr -d '\r' | grep -q "$pat" && return 0
		sleep 2; i=$((i + 1))
	done
	return 1
}

# ---------- 准备虚拟盘 ----------
log "准备虚拟盘（$DISK）"
rm -f "$DISK_IMG" "$LOG" "$SOCK"
rt "gzip -dc $W/old.img.gz > $W/base.img" || die "解压旧镜像失败"
truncate -s "$DISK" "$DISK_IMG" 2>/dev/null || rt "truncate -s $DISK $W/disk.img"
rt "dd if=$W/base.img of=$W/disk.img conv=notrunc bs=8M status=none && rm -f $W/base.img" \
	|| die "写入虚拟盘失败"

OVMF_CODE=$(rt 'ls /usr/share/OVMF/OVMF_CODE.fd 2>/dev/null || true')
if [ -n "$OVMF_CODE" ]; then
	rt "cp -f /usr/share/OVMF/OVMF_VARS.fd $W/OVMF_VARS.fd"
	BOOT_ARGS="-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
-drive if=pflash,format=raw,file=$W/OVMF_VARS.fd"
	BOOT_MODE=UEFI
else
	BOOT_ARGS=""
	BOOT_MODE=BIOS
fi

log "启动虚拟机（$BOOT_MODE，串口日志 $LOG）"
rt "cd $W && nohup python3 -m http.server $HTTP_PORT --bind 0.0.0.0 >$W/http.log 2>&1 &" >/dev/null 2>&1 || true
rt "nohup qemu-system-x86_64 -machine q35,accel=kvm -cpu host -m 3072 -smp 4 \
$BOOT_ARGS \
-drive file=$W/disk.img,format=raw,if=virtio,cache=writeback \
-netdev user,id=n0,hostfwd=tcp::18080-:80,hostfwd=tcp::12222-:22 -device virtio-net-pci,netdev=n0 \
-display none \
-chardev socket,id=c0,path=$W/console.sock,server=on,wait=off,logfile=$W/serial.log \
-serial chardev:c0 -monitor none >$W/qemu.out 2>&1 &" >/dev/null 2>&1
wait_log 'br-lan.*entered forwarding' 120 || die "旧镜像 2 分钟内没起来（看 $LOG / $W/qemu.out）"
wait_prompt 120 || die "等不到控制台提示符（看 $LOG）"
socat_send 'stty cols 200'; sleep 1

# ---------- 改配置、打标记 ----------
log "改 LAN 网段、写标记、取基线"
socat_send 'ip addr add 10.0.2.15/24 dev br-lan'; sleep 1
socat_send 'uci set network.lan.ipaddr="192.168.99.1/24"; uci commit network; echo "MARK-lan=$(uci get network.lan.ipaddr)"'
sleep 2
socat_send 'touch /overlay/MARKER-verify; echo "MARK-uuid=$(block info | sed -n "s|.*loop0: UUID=\"\([^\"]*\)\".*|\1|p")"'
sleep 2
grep -q 'MARK-lan=192.168.99.1/24' "$LOG" || die "旧系统里改 LAN 失败（看 $LOG）"
UUID_OLD=$(tr -d '\r' <"$LOG" | sed -n 's/.*MARK-uuid=\([0-9a-f-]*\).*/\1/p' | tail -1)
[ -n "$UUID_OLD" ] || die "取不到旧 overlay UUID（看 $LOG）"
printf '   旧 LAN=%s / 旧 overlay UUID=%s\n' 192.168.99.1/24 "$UUID_OLD"

# ---------- 升级 ----------
log "把新镜像传入 guest 并 sysupgrade（保留配置）"
socat_send "cd /tmp && wget -q -O fw.img.gz http://10.0.2.2:$HTTP_PORT/fw-new.img.gz; echo \"MARK-dl=\$?\""
sleep 5
grep -q 'MARK-dl=0' "$LOG" || die "guest 取不到新镜像（HTTP 服务没起？看 $W/http.log）"
T0=$(date +%s)
socat_send '( sysupgrade /tmp/fw.img.gz & )'
sleep 3
log "等升级完成并重启（上限 ${TIMEOUT}s）"
wait_log 'Restarting system' "$TIMEOUT" || die "等不到重启：升级可能卡住了（看 $LOG 尾部）"
T1=$(date +%s)
OFF=$(stat -c %s "$LOG")
sleep 8
wait_log 'br-lan.*entered forwarding' 180 "$((OFF + 1))" || die "升级后设备没起来（看 $LOG 尾部）"
wait_prompt 180 || die "升级后等不到控制台提示符（看 $LOG 尾部）"
socat_send 'stty cols 200'
sleep 1

# ---------- 判定 ----------
log "核对判据"
FAIL=0
ok() { printf '  [ok]   %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }

socat_send 'echo "MARK-uptime=$(cut -d. -f1 /proc/uptime)"'
sleep 2
UP=$(tr -d '\r' <"$LOG" | sed -n 's/.*MARK-uptime=\([0-9]*\).*/\1/p' | tail -1)
[ -n "$UP" ] && [ "$UP" -lt 600 ] && ok "设备重启过（uptime ${UP}s，升级总耗时 $((T1 - T0))s 含备份与重启）" \
	|| bad "uptime 看不出重启（$UP）"

socat_send 'echo "MARK-uuid2=$(block info | sed -n "s|.*loop0: UUID=\"\([^\"]*\)\".*|\1|p")"'
sleep 2
UUID_NEW=$(tr -d '\r' <"$LOG" | sed -n 's/.*MARK-uuid2=\([0-9a-f-]*\).*/\1/p' | tail -1)
if [ -n "$UUID_NEW" ] && [ "$UUID_NEW" != "$UUID_OLD" ]; then
	ok "overlay 重建（f2fs UUID $UUID_OLD → $UUID_NEW）"
else
	bad "overlay UUID 没变（$UUID_OLD → $UUID_NEW）：旧 overlay 被复用了"
fi

socat_send 'ls /overlay/MARKER-verify >/dev/null 2>&1 && echo "MARK-marker=kept" || echo "MARK-marker=gone"'
sleep 2
if tr -d '\r' <"$LOG" | grep -q 'MARK-marker=gone'; then
	ok "升级前写进 /overlay 的标记文件已消失（旧 overlay 未被沿用）"
else
	bad "标记文件还在：旧 overlay 被沿用"
fi

socat_send 'echo "MARK-net=$(test -s /etc/config/network && echo yes || echo no)"'
sleep 2
tr -d '\r' <"$LOG" | grep -q 'MARK-net=yes' && ok "/etc/config/network 被带回" || bad "/etc/config/network 丢了"

socat_send 'echo "MARK-lan2=$(uci -q get network.lan.ipaddr)"'
sleep 2
LAN_NEW=$(tr -d '\r' <"$LOG" | sed -n 's/.*MARK-lan2=\([^ ]*\).*/\1/p' | tail -1)
if [ "$EXPECT_GUARD" -eq 1 ]; then
	[ "$LAN_NEW" = "192.168.99.1/24" ] && ok "LAN IP 被保留（$LAN_NEW，99-lan-ip 守卫生效）" \
		|| bad "LAN IP 被重置成 $LAN_NEW（期望 192.168.99.1/24）"
else
	printf '  [info] 升级后 LAN=%s（未要求，--expect-guard 可断言）\n' "${LAN_NEW:-?}"
fi

if grep -q 'Squashfs payload' "$LOG"; then
	ok "旧系统的 platform.sh 带 ADR-0005 补丁（p2 只写有效载荷）"
elif [ "$EXPECT_CAPPED" -eq 1 ]; then
	bad "日志里没有 \"Squashfs payload\"：补丁没生效（看 $LOG）"
else
	printf '  [info] 旧系统无补丁（整块写 p2），写入耗时见日志\n'
fi

grep -q 'MARK-dl=0' "$LOG" && printf '  [info] 日志与虚拟盘保留在 %s\n' "$WORK"
[ "$FAIL" -eq 0 ] && { log "通过"; exit 0; } || { log "未通过"; exit 1; }
