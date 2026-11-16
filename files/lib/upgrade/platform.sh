#!/bin/sh
# x86 sysupgrade 写入范围收窄（本配方自有改动，理由与回退见 ADR-0005）
#
# 上游 target/linux/x86/base-files/lib/upgrade/platform.sh 在“分区布局未变”时
# 按分区表给的大小逐分区整块写，p2 就是 CONFIG_TARGET_ROOTFS_PARTSIZE 那么大
#（本配方 8192MB）。但 p2 的真实内容只有 squashfs 的 bytes_used（约 38MB），
# 后面全是零填充；overlay 在每次首启由 fstools 按 bytes_used 对齐到 p2 尾部
# 重新 mkfs。整块写 8.2GB 的收益为零，代价是设备侧写盘时间：
# 2026-11-16 实测目标机 MV-32（写 1GiB/85s，约 12MB/s）要 11–14 分钟，而
# 这期间 /rom 与 overlay 被就地覆盖、uhttpd 早被 kill_remaining 杀掉，
# 用户侧没有进度、只剩“卡死”—— 一次被误判为失败的真升级。
#
# 改法：squashfs 分区只写“有效载荷 + 一个对齐零区”：
#   bytes_used 向上对齐 ROOTDEV_OVERLAY_ALIGN(64KB) 后，再多写 64KB 零。
#   前半段保证新 squashfs 完整；后半段的零抹掉旧 overlay 在**新**起点上的
#   文件系统签名，从而保证首启一定重新 mkfs（fstools 的 mount_root 会
#   volume_identify() 探测到旧 f2fs 就直接挂载，不抹就会把旧 overlay 连同
#   旧 apk 数据库一起复用，语义与上游整块写不一致）。
# 读不出 squashfs 魔数、或算出来的长度不在 (1MB, 分区大小) 内时，退回上游的
# 整块写：宁可慢，不写出坏镜像。
#
# 上游原文以未改动的副本放在 /lib/upgrade/x86-platform-upstream —— 刻意**不带
# .sh 后缀**：lib/upgrade/stage2 与 do_stage2 都会 `include /lib/upgrade`，
# 把该目录下所有 *.sh 按字母序 source 一遍；副本若叫 *.sh 且排在后面，就会把
# 下面的覆盖定义又盖回上游实现（2026-11-16 虚拟机实测踩到：补丁静默失效，
# 写入仍是 8.2GB）。它的 ramfs 拷贝靠下面这行 RAMFS_COPY_DATA 保证
#（switch_to_ramfs 只自动拷贝 /lib/upgrade/*.sh 与 do_stage2）。
# CI 会核对副本与 pins.env 钉住的上游 tag 完全一致，漂移即构建失败（见 scripts/build.sh）。
RAMFS_COPY_DATA="$RAMFS_COPY_DATA /lib/upgrade/x86-platform-upstream"
. /lib/upgrade/x86-platform-upstream

_sqfs_payload_bytes() { # <image> <start-sector> → 打印要写的字节数；失败返回非零
	local blk=/tmp/.platform-p2.head magic bytes_used pad

	get_image_dd "$1" of="$blk" ibs=512 skip="$2" count=1 2>/dev/null || return 1
	[ -f "$blk" ] || return 1

	# 用 hexdump 而不是 od：镜像里的 busybox 没编 od（实测 "od: not found"）
	# squashfs 4.0 超级块魔数 "hsqs"
	magic=$(hexdump -v -n 4 -e '4/1 "%02x"' "$blk" 2>/dev/null)
	if [ "$magic" != "68737173" ]; then
		rm -f "$blk"
		return 1
	fi

	# bytes_used：超级块偏移 40 处的 8 字节小端整数
	bytes_used=$(hexdump -v -s 40 -n 8 -e '8/1 "%u "' "$blk" 2>/dev/null \
		| awk '{ s = 0; for (i = 8; i >= 1; i--) s = s * 256 + $i; print s }')
	rm -f "$blk"

	[ -n "$bytes_used" ] || return 1
	[ "$bytes_used" -gt 1048576 ] || return 1

	# 对齐到 overlay 起点，再多写 64KB 零抹旧签名
	pad=$(( ( (bytes_used + 65535) / 65536 ) * 65536 + 65536 ))
	# 512 字节扇区取整
	echo $(( (pad + 511) / 512 * 512 ))
}

platform_do_upgrade() {
	local diskdev partdev diff

	export_bootdevice && export_partdevice diskdev 0 || {
		v "Unable to determine upgrade device"
		return 1
	}

	sync

	if [ "$UPGRADE_OPT_SAVE_PARTITIONS" = "1" ]; then
		get_partitions "/dev/$diskdev" bootdisk

		v "Extract boot sector from the image"
		get_image_dd "$1" of=/tmp/image.bs count=63 bs=512b

		get_partitions /tmp/image.bs image

		#compare tables
		diff="$(grep -F -x -v -f /tmp/partmap.bootdisk /tmp/partmap.image)"
	else
		diff=1
	fi

	if [ -n "$diff" ]; then
		get_image_dd "$1" of="/dev/$diskdev" bs=4096 conv=fsync

		# Separate removal and addtion is necessary; otherwise, partition 1
		# will be missing if it overlaps with the old partition 2
		partx -d - "/dev/$diskdev"
		partx -a - "/dev/$diskdev"

		return 0
	fi

	#iterate over each partition from the image and write it to the boot disk
	while read part start size; do
		if export_partdevice partdev $part; then
			# 本配方唯一的偏离：squashfs 分区只写有效载荷（见文件头）
			count="$size"
			payload_bytes=$(_sqfs_payload_bytes "$1" "$start" 2>/dev/null) || payload_bytes=""
			if [ -n "$payload_bytes" ]; then
				payload_sectors=$(( payload_bytes / 512 ))
				if [ "$payload_sectors" -gt 0 ] && [ "$payload_sectors" -lt "$size" ]; then
					v "Squashfs payload $((payload_sectors / 2048))MB of $((size / 2048))MB partition, rest is padding"
					count="$payload_sectors"
				fi
			fi
			v "Writing image to /dev/$partdev..."
			get_image_dd "$1" of="/dev/$partdev" ibs=512 obs=1M skip="$start" count="$count" conv=fsync
		else
			v "Unable to find partition $part device, skipped."
		fi
	done < /tmp/partmap.image

	v "Writing new UUID to /dev/$diskdev..."
	get_image_dd "$1" of="/dev/$diskdev" bs=1 skip=440 count=4 seek=440 conv=fsync

	platform_do_bootloader_upgrade "$diskdev"
	local parttype=ext4
	part_magic_efi "/dev/$diskdev" || return 0

	if export_partdevice partdev 1; then
		part_magic_fat "/dev/$partdev" && parttype=vfat
		mount -t $parttype -o rw,noatime "/dev/$partdev" /mnt
		set -- $(dd if="/dev/$diskdev" bs=1 skip=1168 count=16 2>/dev/null | hexdump -v -e '8/1 "%02x "" "2/1 "%02x""-"6/1 "%02x"')
		sed -i "s/\(PARTUUID=\)[a-f0-9-]\+/\1$4$3$2$1-$6$5-$8$7-$9/ig" /mnt/boot/grub/grub.cfg
		umount /mnt
	fi
}
