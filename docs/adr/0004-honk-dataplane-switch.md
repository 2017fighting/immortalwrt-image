# 数据面换为 honk（eBPF TC/TCX），mihomo 出镜像

[ADR-0002](0002-ebpf-datapath-kernel-btf.md) 只承诺「门开着」：BTF 编进内核、
honk 的 kmod 依赖进 seed，现网仍跑 mihomo。本 ADR 兑现那笔欠账——数据面整个
换成 dae 系的 honk，`mihomo-alpha` / `mihomo-bare` 从 seed 移除。动机不变：
mihomo 的 sing-tun 数据面对 DNAT 回程 conntrack-blind（mihomo #1493 / #1368
仍 OPEN，上游修复无期），只能靠 mihomo-bare 里的 6 行回程豁免 nft 打补丁；
honk 的 TC/TCX 数据面在内核挂载点分流，DNAT 回程问题从架构上消失，豁免 nft
随壳一起退役。

## 决策

- **honk 内置 + 预置升级源**（与 openwrt-feeds 的「内置/预置」双轨同构）：
  `feeds.extra` 第二条源 feed `daeuniverse ^commit`（打包层），源码由 build.sh
  按 `pins.env` 的 `HONK_TAG` 克隆进 feed 包的 `./src`——daeuniverse feed 不含
  honk 源码，Makefile 硬检查该目录；`files/etc/apk/` 烘 daeuniverse 公钥与
  `@daeuniverse` 注册行，设备可在线升级。
- **全套件位**：`honk`（自带 doona 面板 `:9527`）+ `luci-app-honk` +
  `luci-i18n-daeuniverse-zh-cn`；`luci-lib-daeuniverse` / `vmlinux-btf-builtin` /
  `kmod-sched-core` / `libstdcpp` / `v2ray-geoip` / `v2ray-geosite` 由 DEPENDS
  自动解析，不显式抄。
- **mihomo 彻底移除**；`CONFIG_PACKAGE_ip-full=y` 显式顶替 mihomo-alpha 带走的
  `ip` 虚拟包（luci-app-tailscale-community 的 LUCI_DEPENDS 依赖它，r4 事故的
  反面：虚拟包必须恰好一个提供者）。
- **配置包默认起步**（`/etc/honk/config.dae`，br-lan 全直连，服务默认不自启）；
  订阅与节点只在设备侧经 doona 填，镜像零凭据（与 tailscale 同哲学：配方是
  公开仓库）。
- **一步到位**：单个版本同时删 mihomo、加 honk，不出双引擎并存的中间态。
  回退路径 = 设备上 `apk add mihomo-alpha mihomo-bare`（openwrt-feeds Pages
  源与公钥仍预置）；断代理 ≠ 断网，直连路由不受数据面切换影响。
- **升级通道文档化手动**：`apk add honk@daeuniverse …`（内置包来源是镜像本地
  索引，apk 不会自动跟 @daeuniverse 源；不做 uci-defaults 首启自动切换——
  首启不一定有网，失败静默且留垃圾）。

## Considered Options

- 双引擎并存过渡（否决：TC/TCX 与 TUN auto-route 两套数据面互踩，上游文档也
  明说二选一；镜像背两套引擎无意义）
- 仅预置不内置（否决：出厂不带引擎，断网首配无代理可用）
- 仅内置不预置升级源（否决：honk 安全更新只能等整镜像重刷，而 daeuniverse
  官方有签名二进制 feed）
- 改 mihomo 转面为 tproxy/redirect（ADR-0002 已否：等于把 nikki 600 行 ucode
  搬回来）
- 继续等 mihomo 上游修复（ADR-0002 已否：回程豁免不是修，是带病延年）

## Consequences

- 构建新增外部输入，全部有钉：daeuniverse feed commit（`feeds.extra`）、honk
  源码 tag（`pins.env` 的 `HONK_TAG`，须与 feed Makefile 的 `HONK_GIT_TAG`
  默认值配套——Makefile 把该 tag 嵌进二进制版本）、Rust 工具链
  （源码 `rust-toolchain.toml`：根目录 stable 1.99.1 + `crates/honk-ebpf`
  nightly-2026-10-20）、bpf-linker 与 doona 的版本+sha256（源码
  `.github/ci/pins.env`，build.sh 直接引用不另抄；已实测 bpf-linker 0.11.0
  x86_64-musl 资产与钉值哈希相符）。构建期需联网（rustup、crates.io、
  doona/bpf-linker 下载），build.sh 自动备齐 rustup、bpf-linker 与交叉目标
  `x86_64-unknown-linux-musl`（rustup 默认只装 host triple 的 std，缺了就
  在 `error[E0463]: can't find crate for core` 上失败——2026-11-16 的 run
  43844686114 即此）；宿主还要有 **cmake + libclang**（boring-sys 的 CMake 与
  bindgen 依赖，上游 honk CI 与本仓 CI 的 apt 行都装了这两个）。
- daeuniverse feed 的 `dae` 与 immortalwrt 官方 feed `net/dae` 同名：feeds
  install 先到先得（官方在前），daeuniverse 的 dae 不生效。无碍——seed 只选
  honk；但 seed 永远不要选 dae（要换引擎时换 feed 钉点，不是选同名包）。
- 换数据面的既有代价照单全收（ADR-0002 已预告）：配置重写为 dae 语法、无
  fake-ip 引擎、mihomo fork 的 `preferred-ip` / `disable-qtype-64` 失效。
- 回程豁免 nft（住 mihomo-bare 包内）随包消失；openwrt-feeds 侧的 mihomo 包
  不动——那是姊妹仓库的决策范围，且它正是回退路径的货源。
- CONTEXT 词汇随之改写：「feed 钉点」从唯一一行变两行；「数据面」例证换
  honk 现役；「门」有了使用者。
- 设备侧运维（不进本仓库）：刷机后 doona 建管理员、迁移订阅与规则、停用
  mihomo-headless-worker 的配置下发。
- **修正（2026-11-16）**：本文「决策」里说 `vmlinux-btf-builtin` 由 DEPENDS
  自动解析，这个假设是错的 —— 空壳包的 `PROVIDES:=@vmlinux-btf` 优先级为 0
  （上游注释：never picked by itself），而真包 `vmlinux-btf` 恰与依赖同名，
  `defconfig` 会选真包，`make world` 在 `Build/Prepare` 里因缺 `VMLINUX_BTF_SRC`
  报 "the BTF blob is missing at ''" 整轮失败（run 43833796071）。现在 seed 显式写
  `CONFIG_PACKAGE_vmlinux-btf-builtin=y` 与 `# CONFIG_PACKAGE_vmlinux-btf is not set`，
  并靠 seed 否定行审计在 defconfig 之后立刻失败（不再烧掉一小时）。
