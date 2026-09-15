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
grep -E '^CONFIG_TARGET_x86_64=y|^CONFIG_TARGET_ROOTFS_SQUASHFS=y|^CONFIG_TARGET_ROOTFS_PARTSIZE=|^CONFIG_PACKAGE_(natmapt|luci-app-natmapt|stuntman-client|mihomo-alpha|nikki|luci-app-nikki)=y' .config
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

step "7/8 官方工具链"
echo "$TOOLCHAIN_SHA256  $TOOLCHAIN_TARBALL" | sha256sum -c -
tar -C . -I zstd -xf "$TOOLCHAIN_TARBALL"

step "8/8 make world"
# -j 并行失败时，stamp 机制可让重跑只补未完成阶段：降级 -j1 V=s 重跑以
# 暴露被吞的真错误（r3 教训：package/install 3 秒无输出即失败，默认冗长
# 度下看不到原因），然后照常退出非零。
if make -j"$(nproc)"; then
	:
else
	echo "::warning::world -j 失败，降级 -j1 V=s 重跑暴露错误..."
	make -j1 V=s || true
	exit 1
fi

step "产物"
ls -l bin/targets/x86/64/*.img.gz bin/targets/x86/64/sha256sums
