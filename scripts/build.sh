#!/bin/sh
# immortalwrt-image 配方构建器 —— 在 immortalwrt buildroot 检出内运行。
# 由 .github/workflows/build.yml 调用；也可本地复现（见 README）。
#
# 时序红线：seed 写入 .config 必须在 `feeds update` 之后！
# scripts/feeds 的 update 子命令结尾会无条件 refresh_config()：若 .config
# 已存在，它先删 tmp/.packageinfo 再跑 make defconfig——此刻 package/feeds/*
# 符号链接尚未建立，所有 feed 包符号"未知即丢弃"。曾因此构建出无任何
# 内置包的镜像（v25.12.1-r2 事故）。顺序固定为：
#   feeds.conf → feeds update/install（无 .config）→ 写 seed → defconfig
#
# 输入（环境变量）：
#   RECIPE_DIR        本配方仓库的绝对路径            （必填）
#   BUILDROOT         immortalwrt 检出的绝对路径      （必填）
#   TOOLCHAIN_TARBALL 官方工具链 tar.zst 的路径       （必填）
#   IMAGE_SIGN_KEY     base64 openssl EC 私钥（镜像 apk 索引签名；缺省则
#                     buildroot 自行随机生成，每次构建不同，见 README 密钥章节）
#   FW_VERSION        CONFIG_VERSION_NUMBER（如 25.12.1，CI 从钉点推导）
#   FW_CODE           CONFIG_VERSION_CODE（如 r42+1a2b3c4，配方修订标识）
set -eu

RECIPE_DIR=${RECIPE_DIR:?RECIPE_DIR is required}
BUILDROOT=${BUILDROOT:?BUILDROOT is required}
TOOLCHAIN_TARBALL=${TOOLCHAIN_TARBALL:?TOOLCHAIN_TARBALL is required}

# PATH 清洗（2026-11-14 本地复现事故）：GNU find 的 -execdir 出于安全拒绝
# PATH 里含空白的条目，WSL 默认把 Windows PATH 互导进来（/mnt/c/Program
# Files/Bandizip 这类），package/install 组装 rootfs 时必挂且默认冗长度下
# 看不到原因。统一滤掉空条目、含空白条目和相对条目（. 开头）。
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vE '^$|[[:space:]]|^\.' | paste -sd: -)
export PATH

# 钉点（上游 tag、工具链哈希）与 feed 钉点（feeds.extra）都在配方仓库里
. "$RECIPE_DIR/pins.env"

cd "$BUILDROOT"

step() { printf '\n==> %s\n' "$1"; }

step "1/8 铺 files/ 覆盖层（uci-defaults + apk 公钥 + feed 注册）"
# 必须落成 buildroot 顶层的 files/ 目录——rootfs 阶段只认 $(TOPDIR)/files
#（include/rootfs.mk 的 prepare_rootfs）。曾误写成 cp .../files/. .，把内容
# 摊平到 buildroot 根，覆盖层整体静默失效（r5 事故：keys/feed 注册/LAN IP
# 全没进镜像；且 find|sort 管道返回 sort 的退出码，set -e 也没拦住）。
cp -a "$RECIPE_DIR/files" .
[ -n "$(find files -type f 2>/dev/null)" ] || {
	echo "::error:: buildroot/files/ 为空——覆盖层没有铺入（配方仓库 files/ 丢了？）"
	exit 1
}
find files -type f | sort

step "2/8 feeds.conf = feeds.conf.default + 配方钉住的源 feed"
cp feeds.conf.default feeds.conf
grep -E '^src-' "$RECIPE_DIR/feeds.extra" >> feeds.conf
cat feeds.conf

step "3/8 feeds update + install（此刻 .config 必须不存在，见文件头时序红线）"
[ ! -e .config ] || { echo "::error:: .config 已存在，feeds update 会用它做不完整元数据刷新"; exit 1; }
./scripts/feeds update -a
./scripts/feeds install -a

step "4/8 seed 配置 + 动态版本标识"
cat "$RECIPE_DIR/config/x86-64.seed" > .config
[ -n "${FW_VERSION:-}" ] && echo "CONFIG_VERSION_NUMBER=\"$FW_VERSION\"" >> .config
[ -n "${FW_CODE:-}" ] && echo "CONFIG_VERSION_CODE=\"$FW_CODE\"" >> .config

step "5/8 make defconfig（展开 seed）+ 存活审计"
make defconfig
echo "--- 关键选择核对 ---"
grep -E '^CONFIG_TARGET_x86_64=y|^CONFIG_TARGET_ROOTFS_SQUASHFS=y|^CONFIG_TARGET_ROOTFS_PARTSIZE=|^CONFIG_PACKAGE_(natmapt|luci-app-natmapt|stuntman-client|mihomo-alpha|mihomo-bare|tailscale|luci-app-tailscale-community)=y' .config
# 审计：seed 里每个显式选择都必须在展开后的 .config 中存活。任何一行
# 丢失都立即失败——静默丢包的镜像不允许出门（r2 事故的教训）。
missing=""
while IFS= read -r line; do
	case "$line" in
		''|'#'*) continue ;;
	esac
	grep -qF "$line" .config || missing="$missing
$line"
done < "$RECIPE_DIR/config/x86-64.seed"
if [ -n "$missing" ]; then
	echo "::error:: seed 选择在 defconfig 后丢失（依赖不满足或符号消失）：$missing"
	exit 1
fi
echo "存活审计通过：seed 全部选择均在 .config 中"

step "6/8 镜像签名钥（BUILD_KEY_APK_SEC/PUB，buildroot 顶层 private-key.pem）"
if [ -n "${IMAGE_SIGN_KEY:-}" ]; then
	printf '%s' "$IMAGE_SIGN_KEY" | base64 -d > private-key.pem
	chmod 600 private-key.pem
	# buildroot 规则：公钥名必须恰为 public-key.pem（package/base-files 会
	# 把它复制进镜像 /etc/apk/keys/）
	openssl ec -in private-key.pem -pubout > public-key.pem
	# 一致性：secret 推导的公钥必须与仓库提交的 keys/image-build.pub.pem
	# 一致——防止换了 secret 忘了同步仓库里的备查公钥
	if [ -f "$RECIPE_DIR/keys/image-build.pub.pem" ]; then
		if ! cmp -s public-key.pem "$RECIPE_DIR/keys/image-build.pub.pem"; then
			echo "::error:: IMAGE_SIGN_KEY 与 keys/image-build.pub.pem 不一致：换钥后请同步更新仓库公钥（或删除该备查文件）"
			exit 1
		fi
	fi
	echo "installed pinned signing key (public-key.pem)"
else
	echo "::warning::IMAGE_SIGN_KEY 未设置 —— buildroot 将随机生成密钥对（每次构建不同）。运行 keygen workflow 并配置 Actions secret 以固定。"
fi

step "7/8 官方工具链（预置进 staging_dir/，跳过工具链编译）"
# 官方 toolchain tarball 只含 toolchain-<arch>_gcc-<ver>_<libc>/ 本体（bin/
# lib/include/info.mk），不含 stamp/。而 make world → prepare 走的门禁是
# $(TOOLCHAIN_DIR)/stamp/.toolchain_compile：timestamp.pl 要求
# stamp/.gcc_final_installed 新于源码树 toolchain/ 才不递归编工具链。
# 此前只 `tar -C .` 解到 buildroot 顶层（目录名 immortalwrt-toolchain-*/，
# buildroot 根本不看），每次构建照旧从源码编 GCC——本地复现实测白多花
# ~25 分钟，CI 同病（4h 超时的大头）。修法：解压 → 挪进 staging_dir/ →
# 补 .gcc_final_installed/.toolchain_compile 两个 stamp（touch 晚于
# checkout，恒新于 toolchain/ 源码）→ world 直接从 tools/内核/包开始。
# 幂等：stamp 在则整段跳过，本地增量重跑不重复解压。
grep -q '^CONFIG_USE_MUSL=y' .config \
	|| { echo "::error:: 工具链预置按 musl 写死（seed 改了 libc？需同步改本步骤）"; exit 1; }
tc_gcc=$(sed -n 's/^CONFIG_GCC_VERSION="\([^"]*\)"$/\1/p' .config)
[ -n "$tc_gcc" ] || { echo "::error:: .config 里没有 CONFIG_GCC_VERSION（defconfig 没跑成？）"; exit 1; }
# 目录名 = buildroot 自己拼 TOOLCHAIN_DIR 的规则（x86_64 本配方钉死）
tc_name="toolchain-x86_64_gcc-${tc_gcc}_musl"
tc_stamp="staging_dir/$tc_name/stamp/.toolchain_compile"
if [ -e "$tc_stamp" ]; then
	echo "已预置（$tc_stamp 存在），跳过解压"
else
	echo "$TOOLCHAIN_SHA256  $TOOLCHAIN_TARBALL" | sha256sum -c -
	tar -I zstd -xf "$TOOLCHAIN_TARBALL"
	# tarball 顶层唯一目录：<...>.Linux-x86_64/<tc_name>/ ——名字必须与 .config
	# 推导一致（防止钉点配错：tarball 的 gcc 版本和上游 tag 不配套）
	set -- */toolchain-x86_64_gcc-*_musl
	[ -d "$1" ] && [ $# -eq 1 ] \
		|| { echo "::error:: 期望 tarball 内恰好一个 toolchain-x86_64_gcc-*_musl 目录，实际：$*"; exit 1; }
	[ "$(basename "$1")" = "$tc_name" ] \
		|| { echo "::error:: tarball 工具链目录 $1 与 .config 期望的 $tc_name 不符（TOOLCHAIN_URL 与 IMMORTALWRT_TAG 配套错了？）"; exit 1; }
	# 半途而废的旧状态（mv 后、touch 前被打断）会让 mv 嵌套，先清掉再挪
	[ ! -e "staging_dir/$tc_name" ] || rm -rf "staging_dir/$tc_name"
	mv "$1" staging_dir/
	rm -rf immortalwrt-toolchain-*
	mkdir -p "staging_dir/$tc_name/stamp"
	# 顺序别乱：.gcc_final_installed 必须是 timestamp.pl 比较集里最新的；
	# .toolchain_compile 再晚于它，make 连 timestamp.pl 都不用跑
	touch "staging_dir/$tc_name/stamp/.gcc_final_installed"
	touch "staging_dir/$tc_name/stamp/.toolchain_compile"
	# 冒烟：交叉编译器真的能编目标代码（tarball 损坏/架构不符当场暴露）
	mkdir -p tmp
	echo 'int main(void){return 0;}' \
		| "staging_dir/$tc_name/bin/x86_64-openwrt-linux-musl-gcc" -x c -o "tmp/.tc-smoke.$$" - \
		|| { echo "::error:: 预置的交叉编译器编译失败（tarball 损坏？sha256 怎么过的…）"; exit 1; }
	rm -f "tmp/.tc-smoke.$$"
	echo "预置完成：$tc_name（world 将跳过工具链编译）"
fi

step "8/8 make world"
# 内存水位预警（2026-11-14 本地教训）：x86 镜像组装阶段的 dd（8G rootfs
# 分区填充）实测会吃 ~14G 匿名内存，15G RAM + 4G swap 的机器会被 OOM 击杀
# ——日志里只剩 "world Terminated"，极难归因。CI 由 workflow 预加 8G swap
# 兜底；本地内存紧张时在此预警，加 swap 后重跑即可。
mem_mb=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
swap_mb=$(awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo)
if [ $((mem_mb + swap_mb)) -lt 20000 ]; then
	echo "::warning::内存+swap 共 ${mem_mb}M+${swap_mb}M < 20G —— 镜像组装的 dd 内存尖峰(~14G)可能触发 OOM；建议加 swap 再跑（CI workflow 有同款保险）"
fi
# 预编 dwarves：大并行度下 tools/dwarves 有确定性竞态（2026-11-14 本地
# 12 核两次全新 buildroot 均在同一处挂，且并行轮零错误输出；CI 4 核无恙）。
# 先单独串行把它编掉（实测单线程仅 ~11s），world 的 -j 大军到来时 stamp
# 已在，竞态无从触发。失败不阻断：真错误会在 world 里照常暴露。
make -j1 tools/dwarves/compile \
	|| echo "::warning:: tools/dwarves 预编失败（留给 world 正常流程处理）"
# -j 并行失败时，stamp 机制可让重跑只补未完成阶段：先并行重试一次——
# 大多数并行竞态（如上）重跑即翻篇；仍败再降级 -j1 V=s 暴露真错误
# （r3 教训：默认冗长度下看不到原因；但直接 -j1 会把内核/Go 包全部
# 单线程重编，本地 12 核实测从 ~40min 涨到 ~2.5h），然后照常退出非零。
if make -j"$(nproc)"; then
	:
elif make -j"$(nproc)"; then
	echo "::warning::world -j 首轮失败，并行重试成功（竞态？已在上面日志）"
else
	echo "::warning::world -j 两轮皆败，降级 -j1 V=s 重跑暴露错误..."
	make -j1 V=s || true
	exit 1
fi

step "内核配置核对（ADR-0002：BTF 与 nfqueue 必须真的落进内核 .config）"
# seed 存活审计（step 5）只看 buildroot .config；这里看的是**内核** .config——
# KERNEL_DEBUG_INFO_REDUCED 默认 y 会静默挤掉 DEBUG_INFO_BTF，症状是镜像能启动、
# 但 eBPF 数据面在设备上报缺 BTF。以前只靠人读文档，现在当场失败。
kconfig=$(find build_dir -maxdepth 4 -type f -name .config -path '*linux-x86_64*' 2>/dev/null | head -1)
[ -n "$kconfig" ] || { echo "::error:: 找不到内核 .config（build_dir 路径模式变了？）"; exit 1; }
grep -qx 'CONFIG_DEBUG_INFO_BTF=y' "$kconfig" \
	|| { echo "::error:: $kconfig 缺 CONFIG_DEBUG_INFO_BTF=y（KERNEL_* 被 kconfig 丢弃？见 ADR-0002）"; exit 1; }
grep -qx '# CONFIG_DEBUG_INFO_REDUCED is not set' "$kconfig" \
	|| { echo "::error:: $kconfig 仍开着 DEBUG_INFO_REDUCED，BTF 会被丢弃"; exit 1; }
for sym in 'CONFIG_NF_TABLES' 'CONFIG_NFT_QUEUE' 'CONFIG_NETFILTER_NETLINK_QUEUE'; do
	grep -qxE "$sym=[ym]" "$kconfig" \
		|| { echo "::error:: $kconfig 缺 $sym=y|m（kmod-nft-queue / kmod-nfnetlink-queue 没进内核？）"; exit 1; }
done
# CONFIG_DEBUG_INFO_BTF=y 也可能“下了但没编进”：直接看 vmlinux 的段
vmlinux=$(dirname "$kconfig")/vmlinux
if [ ! -f "$vmlinux" ]; then
	echo "::warning:: 找不到 $vmlinux，跳过 .BTF 段校验（仅核对了 .config）"
elif command -v readelf >/dev/null 2>&1; then
	readelf -S "$vmlinux" 2>/dev/null | grep -q '\.BTF' \
		|| { echo "::error:: $vmlinux 无 .BTF 段——设备上 /sys/kernel/btf 会不存在"; exit 1; }
else
	echo "::warning:: 无 readelf，跳过 .BTF 段校验（仅核对了 .config）"
fi
echo "内核配置核对通过：$kconfig（.BTF 已入 vmlinux）"

step "产物"
ls -l bin/targets/x86/64/*.img.gz bin/targets/x86/64/sha256sums
