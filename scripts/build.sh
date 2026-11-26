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

step "4/9 honk：源码克隆 + Rust 工具链 + bpf-linker（ADR-0004）"
# daeuniverse feed 只带打包 Makefile：honk/Makefile 的 Build/Prepare 硬检查
# 同目录 ./src（他们的 CI 也是自己 clone 源码）。按 pins.env 的 HONK_TAG
# 克隆；feeds install 建立的 package/feeds/daeuniverse/honk 是指向 feeds/
# 的符号链接，透过它写进 feeds/daeuniverse/honk/src。
honk_pkg="package/feeds/daeuniverse/honk"
[ -d "$honk_pkg" ] || { echo "::error:: $honk_pkg 不存在（feeds install 没装进 daeuniverse feed？）"; exit 1; }
if [ ! -d "$honk_pkg/src" ]; then
	git clone --depth 1 --branch "$HONK_TAG" https://github.com/daeuniverse/honk.git "$honk_pkg/src"
else
	src_tag=$(git -C "$honk_pkg/src" describe --tags --exact-match 2>/dev/null || true)
	if [ "$src_tag" != "$HONK_TAG" ]; then
		echo "::error:: $honk_pkg/src 已是 ${src_tag:-未知}，与 pins.env 的 HONK_TAG=$HONK_TAG 不符 —— 升 tag 请先删旧源码树再重跑"
		exit 1
	fi
fi
# honk 包 build.sh 的环境要求：cargo/rustc/rustup 在 PATH，rust-toolchain.toml
# 钉的两条工具链（根目录 stable + crates/honk-ebpf nightly）已装，外加预编译
# bpf-linker。缺 rustup 则装（default-toolchain none：cargo 只在 honk 目录里
# 用，由 toml 解析工具链）；在两个目录各跑一次 cargo --version，让 rustup
# 代理按 toml 自动装钉住的工具链与组件——版本号不在这里抄，升 tag 自动跟随。
if ! command -v rustup >/dev/null 2>&1; then
	curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none
fi
mkdir -p "$HOME/.cargo/bin"
[ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
( cd "$honk_pkg/src" && cargo --version >/dev/null )
( cd "$honk_pkg/src/crates/honk-ebpf" && cargo --version >/dev/null )
# 交叉目标：feed 的 honk/build.sh 用 `cargo build --target x86_64-unknown-linux-musl`
# 编 honk-core，而 rustup 只会装 host triple 的 std —— 缺 musl 目标的 std 就在
# "error[E0463]: can't find crate for `core`" 上失败（2026-11-16 的 run
# 43844686114 挂了 53 分钟就死在这里）。triple 与该脚本的 case 映射一致
#（x86_64 → x86_64-unknown-linux-musl）；不写死 --toolchain，让 honk 目录里的
# rust-toolchain.toml 决定装到哪条工具链上（升 HONK_TAG 自动跟随）。
( cd "$honk_pkg/src" && rustup target add x86_64-unknown-linux-musl )
( cd "$honk_pkg/src" && rustup target list --installed | grep -qx x86_64-unknown-linux-musl ) \
	|| { echo "::error:: rustup 里没有 x86_64-unknown-linux-musl 目标 —— honk-core 会编不过"; exit 1; }
# boring-sys（BoringSSL）在构建期用 cmake + bindgen(libclang) 生成绑定，
# 上游 CI 为此装 cmake 与 libclang-dev。缺了会在 honk 的 C 依赖阶段失败，
# 日志离根因很远，这里先给一条预警（CI 的 apt 步骤已装）。
command -v cmake >/dev/null 2>&1 \
	|| echo "::warning:: 宿主没有 cmake —— honk 的 boring-sys 会构建失败；装 cmake 与 libclang（Debian/Ubuntu 包名）后重跑"
# bpf-linker：版本与 sha256 直接引用 honk 源码 .github/ci/pins.env 的钉值
# （与源码同源；已实测 0.11.0 的 x86_64-musl 资产与该哈希相符）。预编译
# 静态二进制放进 ~/.cargo/bin（已在 PATH）。
# shellcheck disable=SC1090
. "$honk_pkg/src/.github/ci/pins.env"
if ! "$HOME/.cargo/bin/bpf-linker" --version 2>/dev/null | grep -qF "$BPF_LINKER_VERSION"; then
	bpf_dir=$(mktemp -d)
	curl -fsSL -o "$bpf_dir/bpf-linker.tar.zst" \
		"https://github.com/aya-rs/bpf-linker/releases/download/v${BPF_LINKER_VERSION}/bpf-linker-x86_64-unknown-linux-musl.tar.zst"
	echo "$BPF_LINKER_SHA256  $bpf_dir/bpf-linker.tar.zst" | sha256sum -c -
	tar -I zstd -xf "$bpf_dir/bpf-linker.tar.zst" -C "$HOME/.cargo/bin" bpf-linker
	rm -rf "$bpf_dir"
fi
"$HOME/.cargo/bin/bpf-linker" --version

step "5/9 seed 配置 + 动态版本标识"
cat "$RECIPE_DIR/config/x86-64.seed" > .config
[ -n "${FW_VERSION:-}" ] && echo "CONFIG_VERSION_NUMBER=\"$FW_VERSION\"" >> .config
[ -n "${FW_CODE:-}" ] && echo "CONFIG_VERSION_CODE=\"$FW_CODE\"" >> .config

step "6/9 make defconfig（展开 seed）+ 存活审计"
make defconfig
echo "--- 关键选择核对 ---"
grep -E '^CONFIG_TARGET_x86_64=y|^CONFIG_TARGET_ROOTFS_SQUASHFS=y|^CONFIG_TARGET_ROOTFS_PARTSIZE=|^CONFIG_PACKAGE_(natmapt|luci-app-natmapt|stuntman-client|honk|luci-app-honk|ip-full|tailscale|luci-app-tailscale-community|vmlinux-btf-builtin)=y|^# CONFIG_PACKAGE_vmlinux-btf is not set$' .config
# 审计：seed 里每个显式选择都必须在展开后的 .config 中存活。任何一行
# 丢失都立即失败——静默丢包的镜像不允许出门（r2 事故的教训）。
missing=""
while IFS= read -r line; do
	case "$line" in
		'') continue ;;
		# 否定行（# CONFIG_X is not set）也要审：ext4 变体就是靠它关掉的，
		# 静默被 defconfig 拉回来会令 Release 多出不一致的镜像
		'# CONFIG_'*' is not set')
			grep -qxF "$line" .config || missing="$missing
$line"
			continue
		;;
		'#'*) continue ;;
	esac
	grep -qF "$line" .config || missing="$missing
$line"
done < "$RECIPE_DIR/config/x86-64.seed"
if [ -n "$missing" ]; then
	echo "::error:: seed 选择在 defconfig 后丢失（依赖不满足或符号消失）：$missing"
	exit 1
fi
echo "存活审计通过：seed 全部选择均在 .config 中"

step "7/9 镜像签名钥（BUILD_KEY_APK_SEC/PUB，buildroot 顶层 private-key.pem）"
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

step "8/9 官方工具链（预置进 staging_dir/，跳过工具链编译）"
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

step "9/9 make world"
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
# ADR-0007：honk 的 UDP 接收追踪回退走 fentry/fexit，需 ftrace 才有挂接点。
# generic fragment 里 FTRACE/FUNCTION_TRACER 都是「not set」，只有 seed 的
# CONFIG_KERNEL_* 能翻回来；丢了不会让构建失败，只会在设备上静默降级。
for sym in 'CONFIG_FTRACE' 'CONFIG_FUNCTION_TRACER' 'CONFIG_DYNAMIC_FTRACE' \
	'CONFIG_DYNAMIC_FTRACE_WITH_DIRECT_CALLS'; do
	grep -qx "$sym=y" "$kconfig" \
		|| { echo "::error:: $kconfig 缺 $sym=y（ftrace 门没开？见 ADR-0007）"; exit 1; }
done
# CONFIG_DEBUG_INFO_BTF=y 也可能“下了但没编进”：直接看 vmlinux 的段
vmlinux=$(dirname "$kconfig")/vmlinux
if [ ! -f "$vmlinux" ]; then
	echo "::warning:: 找不到 $vmlinux，跳过 .BTF 段校验（仅核对了 .config）"
elif command -v readelf >/dev/null 2>&1; then
	readelf -SW "$vmlinux" 2>/dev/null | grep -q '\.BTF' \
		|| { echo "::error:: $vmlinux 无 .BTF 段——设备上 /sys/kernel/btf 会不存在"; exit 1; }
	# ftrace 的 call-site 表（gcc -mrecord-mcount 的 __mcount_loc）被链接脚本并进
	# .init.data，所以最终 vmlinux 里没有同名段，只能靠 __start/__stop_mcount_loc
	# 这对符号判断，而且两端相等就代表表是空的。配置对了但没有调用点，设备上
	# ftrace_location() 仍是空表，fentry 照样挂不上（ADR-0007）。
	mcount_start=$(readelf -sW "$vmlinux" 2>/dev/null | awk '$8=="__start_mcount_loc"{print $2; exit}')
	mcount_stop=$(readelf -sW "$vmlinux" 2>/dev/null | awk '$8=="__stop_mcount_loc"{print $2; exit}')
	[ -n "$mcount_start" ] && [ -n "$mcount_stop" ] \
		|| { echo "::error:: $vmlinux 缺 __start/__stop_mcount_loc 符号——ftrace 的调用点表没编进去（见 ADR-0007）"; exit 1; }
	[ "$mcount_start" != "$mcount_stop" ] \
		|| { echo "::error:: $vmlinux 的 __mcount_loc 表为空（$mcount_start）——没有任何可挂钩的调用点"; exit 1; }
else
	echo "::warning:: 无 readelf，跳过 .BTF 段校验（仅核对了 .config）"
fi
echo "内核配置核对通过：$kconfig（.BTF 已入 vmlinux，ftrace 调用点表非空）"

step "sysupgrade 可升级性核对（ADR-0005）"
# 本配方只覆盖 x86 platform.sh 里的 platform_do_upgrade（p2 写有效载荷而非
# 整块 8192MB），其余行为全部来自上游原文。三件事必须成立，否则不出包：
#   1. 上游副本与钉住的 tag 逐字节一致（上游修了 bug 而副本没跟上 = 静默丢修复）
#   2. 覆盖层真的铺进了 rootfs（r5 事故：cp 摊平导致 files/ 整体失效）
#   3. 产物仍是 sysupgrade 可直接消费的镜像（x86 platform_check_image 认
#      eb63/eb48 + 分区表，缺一就会被拒）
recipe_platform=files/lib/upgrade/platform.sh
recipe_upstream=files/lib/upgrade/x86-platform-upstream
[ -f "$recipe_platform" ] && [ -f "$recipe_upstream" ] \
	|| { echo "::error:: files/lib/upgrade/ 缺 platform.sh 或 x86-platform-upstream"; exit 1; }
upstream_raw="https://raw.githubusercontent.com/${IMMORTALWRT_REPO#https://github.com/}"
upstream_raw="${upstream_raw%.git}/${IMMORTALWRT_TAG}/target/linux/x86/base-files/lib/upgrade/platform.sh"
curl -fsSL --retry 3 "$upstream_raw" -o /tmp/platform.upstream.pinned.sh \
	|| { echo "::error:: 拉不到上游原文：$upstream_raw"; exit 1; }
cmp -s /tmp/platform.upstream.pinned.sh "$recipe_upstream" \
	|| { echo "::error:: $recipe_upstream 与 $IMMORTALWRT_TAG 的上游原文不一致 —— 升上游后必须重新同步该副本并复核覆盖的差异"; exit 1; }
echo "上游副本与 $IMMORTALWRT_TAG 一致"

rootdir=$(ls -d build_dir/target-*/root-x86 2>/dev/null | head -1)
[ -n "$rootdir" ] || { echo "::error:: 找不到 root-x86 构建目录（TARGET_DIR 路径变了？）"; exit 1; }
for f in platform.sh x86-platform-upstream; do
	[ -f "$rootdir/lib/upgrade/$f" ] \
		|| { echo "::error:: 镜像 rootfs 里没有 /lib/upgrade/$f —— files/ 覆盖层没铺进去"; exit 1; }
done
grep -q 'RAMFS_COPY_DATA=.*x86-platform-upstream' "$rootdir/lib/upgrade/platform.sh" \
	|| { echo "::error:: 镜像里的 /lib/upgrade/platform.sh 不是本配方版本（缺 RAMFS_COPY_DATA）"; exit 1; }
cmp -s "$recipe_upstream" "$rootdir/lib/upgrade/x86-platform-upstream" \
	|| { echo "::error:: 镜像里的上游副本与配方不一致"; exit 1; }
# 上游平台脚本的其余函数（check_image / copy_config / bootloader）必须仍在上游原文里：# 镜像里的副本与本地产物一致即可证明 files/ 覆盖层真的铺进去了
cmp -s "$recipe_upstream" "$rootdir/lib/upgrade/x86-platform-upstream" \
	|| { echo "::error:: 镜像里的上游副本与配方不一致"; exit 1; }
echo "覆盖层核对通过：$rootdir/lib/upgrade/"

# files/ 覆盖层里的设备侧脚本（ADR-0006 的备份）：它们坏掉不会让构建失败，只会让
# 夜间备份静默不跑，所以在这里断言“真进了 rootfs 且带执行位”——与 lib/upgrade 那几条
# 平级。punchd 的 init 与 /etc/punch 默认值**不再**在这里断言：它们是 net/punchd 这个包
# 的内容（feed 钉在 feeds.extra），包有问题会让“包真的装进固件”那条断言先炸。
for f in etc/router-backup/backup.sh etc/router-backup/backup.conf etc/uci-defaults/90-router-backup; do
	[ -f "$rootdir/$f" ] \
		|| { echo "::error:: 镜像 rootfs 里没有 /$f —— files/ 覆盖层没铺进去"; exit 1; }
done
for f in etc/router-backup/backup.sh etc/uci-defaults/90-router-backup; do
	[ -x "$rootdir/$f" ] \
		|| { echo "::error:: 镜像里的 /$f 没有执行位 —— 设备侧会 permission denied（cron / uci-defaults 都要能直接跑）"; exit 1; }
done
echo "设备侧脚本核对通过：/etc/router-backup/* 与 /etc/uci-defaults/90-router-backup 就位且该可执行的可执行；punchd 由 net/punchd 包提供"

# /sbin/sysupgrade 不是包，是 base-files 里的一个文件（manifest 只列包，2026-11-16
# run 43853250434 就因为这个误报白跑了一轮 88 分钟的直接断言），所以这里分成
# 两条：文件断言看它真在 rootfs 里，包断言只列 manifest 里确实存在的包。
[ -s "$rootdir/sbin/sysupgrade" ] \
	|| { echo "::error:: 镜像 rootfs 缺 /sbin/sysupgrade（base-files 没装进去？）"; exit 1; }
[ -x "$rootdir/sbin/sysupgrade" ] \
	|| echo "::warning:: /sbin/sysupgrade 没有执行位 —— 设备侧直接跑 sysupgrade 会 permission denied，核对 base-files 的安装规则"
manifest=$(ls bin/targets/x86/64/*.manifest 2>/dev/null | head -1)
[ -n "$manifest" ] || { echo "::error:: 找不到 bin/targets/x86/64/*.manifest"; exit 1; }
for pkg in base-files fstools mkf2fs kmod-fs-f2fs grub2-bios-setup partx-utils; do
	grep -qE "^$pkg " "$manifest" \
		|| { echo "::error:: 镜像 manifest 缺 $pkg（sysupgrade 在设备上跑不起来：分区操作/重建 overlay/写引导各需一个）"; exit 1; }
done
echo "manifest 核对通过：base-files/fstools/mkf2fs/grub2-bios-setup/partx-utils 均在，/sbin/sysupgrade 在 rootfs 里"

# 产物魔数：x86 的 platform_check_image 只看 "eb48|eb63" + offset 510 的 55aa，
# 再加一段能解析的分区表；squashfs 分区的载荷必须是 hsqs（否则首启无根）。
# 只核对 combined 镜像：*rootfs.img.gz 没有引导码与分区表，本来就不是
# sysupgrade 目标（ADR-0005 写明）；ext4 变体只核引导码与分区表，squashfs
# 变体额外要求最大分区起点是 hsqs 且分区尺寸 = 8192MB。
python3 - bin/targets/x86/64/*combined*.img.gz <<'PY' || exit 1
import gzip, glob, struct, sys

fail = False
for path in sys.argv[1:]:
    with gzip.open(path, 'rb') as f:
        head = f.read(4096)
        if head[:2] not in (b'\xeb\x63', b'\xeb\x48'):
            print(f'::error:: {path}: 引导码 {head[:2].hex()} 不是 eb63/eb48')
            fail = True
            continue
        if head[510:512] != b'\x55\xaa':
            print(f'::error:: {path}: offset 510 不是 55aa（无分区表签名）')
            fail = True
            continue
        parts = []
        if head[512:520] == b'EFI PART':
            ents = head[1024:1024 + 128 * 4]
            for i in range(4):
                e = ents[i * 128:(i + 1) * 128]
                if e[:16] == b'\x00' * 16:
                    continue
                first, last = struct.unpack('<QQ', e[32:48])
                parts.append((first, last + 1))
        else:
            for i in range(4):
                e = head[446 + i * 16:446 + (i + 1) * 16]
                if e[4] == 0:
                    continue
                first, cnt = struct.unpack('<II', e[8:16])
                parts.append((first, first + cnt))
        if len(parts) < 2:
            print(f'::error:: {path}: 解析出的分区不足 2 个')
            fail = True
            continue
        root_start, root_end = max(parts, key=lambda p: p[1] - p[0])
        root_mb = (root_end - root_start) * 512 // (1024 * 1024)
        table = 'GPT' if head[512:520] == b'EFI PART' else 'MBR'
        if 'squashfs' not in path:
            print(f'sysupgrade 镜像核对通过：{path}（{table}，rootfs {root_mb}MB，ext4 变体只核引导码与分区表）')
            continue
        f.seek(root_start * 512)
        if f.read(4) != b'hsqs':
            print(f'::error:: {path}: 最大分区起点处不是 squashfs 魔数')
            fail = True
            continue
        # 配方固定 rootfs 分区 8192MB、kernel 分区 32MB：尺寸必须对得上，
        # 否则 sysupgrade 的分区布局比较会走“整盘写”分支（ADR-0005 的边界）
        if root_mb != 8192:
            print(f'::error:: {path}: rootfs 分区 {root_mb}MB ≠ 8192MB（与 ADR-0005 的兼容边界不符）')
            fail = True
            continue
        print(f'sysupgrade 镜像核对通过：{path}（{table}，rootfs {root_mb}MB，载荷 hsqs）')
sys.exit(1 if fail else 0)
PY

step "apk 仓库清单核对（ADR-0008：distfeeds 只许 6 行进镜像）"
# 生成物在 base-files 安装阶段写出（include/feeds.mk 的 FeedSourcesAppendAPK：
# feeds.conf 的每个 feed 名 × CONFIG_FEED_<name>），所以「多一行」只能靠比对
# 整份文件发现。判据刻意不写死 host 与版本：
#   - host 来自 CONFIG_VERSION_REPO（出厂钉的是镜像站），换镜像站不该改断言
#   - 版本段来自 %V，即 .config 的 CONFIG_VERSION_NUMBER，升钉点自动跟随
# 于是断言只钉「releases/<版本>/<路径>」这一段：%V 没被替换、版本号没跟上、
# 多出/少了 feed 行，三种都会当场失败，而不是等设备上 apk update 非 0。
distfeed_file="$rootdir/etc/apk/repositories.d/distfeeds.list"
[ -f "$distfeed_file" ] \
	|| { echo "::error:: 镜像 rootfs 里没有 /etc/apk/repositories.d/distfeeds.list（base-files 没装进去？）"; exit 1; }
distfeed_ver=$(sed -n 's/^CONFIG_VERSION_NUMBER="\([^"]*\)"$/\1/p' .config)
[ -n "$distfeed_ver" ] \
	|| { echo "::error:: .config 里没有 CONFIG_VERSION_NUMBER（defconfig 没跑成？）"; exit 1; }
# 去掉 host（含镜像站多出来的路径段）与 releases/ 前缀后，剩下的就是「版本/路径」
distfeed_actual=$(grep -v '^[[:space:]]*$' "$distfeed_file" | sed 's#.*/releases/##' | LC_ALL=C sort)
distfeed_expected=$(printf '%s\n' \
	"targets/x86/64/packages/packages.adb" \
	"packages/x86_64/base/packages.adb" \
	"packages/x86_64/luci/packages.adb" \
	"packages/x86_64/packages/packages.adb" \
	"packages/x86_64/routing/packages.adb" \
	"packages/x86_64/telephony/packages.adb" \
	| sed "s#^#$distfeed_ver/#" | LC_ALL=C sort)
if [ "$distfeed_actual" != "$distfeed_expected" ]; then
	echo "::error:: /etc/apk/repositories.d/distfeeds.list 与预期不符（ADR-0008）"
	echo "  实际（去掉 host 与 releases/ 之后）："
	printf '%s\n' "$distfeed_actual" | sed 's/^/    /'
	echo "  预期："
	printf '%s\n' "$distfeed_expected" | sed 's/^/    /'
	echo "  常见原因：feeds.conf 里新增的源 feed 没在 seed 里关掉 CONFIG_FEED_<name>，"
	echo "  或者 CONFIG_VERSION_REPO 的 %V 没被替换成 CONFIG_VERSION_NUMBER。"
	exit 1
fi
echo "apk 仓库清单核对通过：distfeeds.list 恰好 6 行"
sed -n 's#^\(https\?://[^/]*\).*#  host: \1#p' "$distfeed_file" | sort -u

step "产物"
# 只列会发布的那两个（ADR-0005：ext4 变体已关，rootfs.img.gz 不发）
ls -l bin/targets/x86/64/*squashfs-combined*.img.gz bin/targets/x86/64/sha256sums
