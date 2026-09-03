#!/bin/sh
# immortalwrt-image 配方构建器 —— 在 immortalwrt buildroot 检出内运行。
# 由 .github/workflows/build.yml 调用；也可本地复现（见 README）。
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

step "1/7 铺 files/ 覆盖层（uci-defaults + apk 公钥 + feed 注册）"
cp -a "$RECIPE_DIR/files/." .
find files -type f | sort

step "2/7 feeds.conf = feeds.conf.default + 配方钉住的源 feed"
cp feeds.conf.default feeds.conf
grep -E '^src-' "$RECIPE_DIR/feeds.extra" >> feeds.conf
cat feeds.conf

step "3/7 镜像签名钥（BUILD_KEY_APK_SEC/PUB，buildroot 顶层 private-key.pem）"
if [ -n "${IMAGE_SIGN_KEY:-}" ]; then
	printf '%s' "$IMAGE_SIGN_KEY" | base64 -d > private-key.pem
	chmod 600 private-key.pem
	# buildroot 规则：公钥名必须恰为 public-key.pem（package/base-files 会
	# 把它复制进镜像 /etc/apk/keys/）
	openssl ec -in private-key.pem -pubout > public-key.pem
	echo "installed pinned signing key (public-key.pem)"
else
	echo "::warning::IMAGE_SIGN_KEY 未设置 —— buildroot 将随机生成密钥对（每次构建不同）。运行 keygen workflow 并配置 Actions secret 以固定。"
fi

step "4/7 seed 配置 + 动态版本标识"
cat "$RECIPE_DIR/config/x86-64.seed" > .config
[ -n "${FW_VERSION:-}" ] && echo "CONFIG_VERSION_NUMBER=\"$FW_VERSION\"" >> .config
[ -n "${FW_CODE:-}" ] && echo "CONFIG_VERSION_CODE=\"$FW_CODE\"" >> .config

step "5/7 feeds update + install"
./scripts/feeds update -a
./scripts/feeds install -a

step "6/7 make defconfig（展开 seed）"
make defconfig
echo "--- 关键选择核对 ---"
grep -E '^CONFIG_TARGET_x86_64=y|^CONFIG_TARGET_ROOTFS_SQUASHFS=y|^CONFIG_TARGET_ROOTFS_PARTSIZE=|^CONFIG_PACKAGE_(natmapt|luci-app-natmapt|stuntman-client|mihomo-alpha|nikki|luci-app-nikki)=y' .config

step "7/7 官方工具链 + make world"
echo "$TOOLCHAIN_SHA256  $TOOLCHAIN_TARBALL" | sha256sum -c -
tar -C . -I zstd -xf "$TOOLCHAIN_TARBALL"
make -j"$(nproc)"

step "产物"
ls -l bin/targets/x86/64/*.img.gz bin/targets/x86/64/sha256sums
