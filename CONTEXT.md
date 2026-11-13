# immortalwrt-image

本仓库是一个**镜像配方**：用纯声明式的配置层把钉住的上游 ImmortalWrt 发布版变成个人固件。与 [openwrt-feeds](https://github.com/2017fighting/openwrt-feeds)（产出包 feed）平级的姊妹上下文。

## Language

**配方**:
本仓库的全部内容——seed 配置、files 覆盖层、feed 引用、钉点的总和。描述"固件长什么样"，不包含任何 ImmortalWrt 源码。
_Avoid_: build plan（那是 openwrt-feeds 侧 SDK 打包的描述；本仓库构建的是镜像）、配置仓库（太泛）

**上游**:
官方 immortalwrt/immortalwrt 仓库。配方在 CI 里直接 checkout 它的钉住 tag，不经过任何中间 fork；2017fighting/immortalwrt 从此不参与构建（纯个人镜像，可有可无）。
_Avoid_: fork（易被理解为携带定制提交的 fork）

**内置**:
包在镜像构建期间从源码编译并安装进固件，出厂即有、不依赖网络。本仓库对自有 feed 包的默认预装方式。
_Avoid_: 预装（与"预置"混淆）

**预置**:
把信任与入口烘进镜像——feed 公钥和注册行，使设备开机即可在线 `apk` 升级。与"内置"互补，不互斥。
_Avoid_: 预装（与"内置"混淆）

**双信任域**:
两把互不通用的签名钥匙：镜像签名域（key-build 对，签镜像自带的包索引，换钥对存量设备零影响）与 feed 签名域（openwrt-feeds 的 APK_SIGN_KEY，签 Pages 二进制 feed）。
_Avoid_: "签名密钥"不加点名域

**feed 钉点**:
`feeds.extra` 里唯一一行 `src-git openwrtfeeds <url>^<commit>`——镜像内置的 natmapt 全家桶与 mihomo 核/外壳全在这一个 commit 里。nikki 桥已随 openwrt-feeds `docs/adr/0001` 拆掉，镜像侧再无第二条源 feed；升级 = 改 `^commit`，上游拆包时钉点必须同步跳过去（新包在旧 commit 里不存在）。
_Avoid_: 桥（现在没有桥了，别把单行钉点叫桥）

**钉**:
配方对构建对象版本的唯一声明（上游 tag、工具链、feed 钉点 commit 都钉在一处）。钉动则配方动；不动则产物可复现。
_Avoid_: 锁定（含义漂移）

**配方修订号**:
同一钉点下配方自身变更的序号（发布 tag `v<上游tag>-r<N>` 中的 `r<N>`）。区分"上游变了"和"我变了"。

**数据面**:
代理引擎在内核侧接管流量的那一层——mihomo 是 TUN 加 `auto-route`/`auto-redirect`，honk 是 TC/TCX 加 `daens` 命名空间。与"核"（用户态的代理进程）分开说：换核不一定换数据面，反之亦然。
_Avoid_: 转发层（那指 nft/ip rule 手写的转面，与数据面是两种实现路径）

**门**:
镜像里预先打开、当前没有使用者的内核能力开关（如 `CONFIG_KERNEL_DEBUG_INFO_BTF`）。开的理由只有一个：让将来的数据面不必再动一次内核重编；门开着不改变任何运行时行为。
_Avoid_: 预留、预置（"预置"在本文里专指 feed 公钥与注册）
