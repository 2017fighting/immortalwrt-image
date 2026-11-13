# 钉住 runner 镜像 24.04，并给构建加心跳探针与 swap

`runs-on` 从 `ubuntu-latest` 改为钉死的 `ubuntu-24.04`，同时加两个 CI 侧的保险：8G swap 与构建期间每分钟一次的内存/负载/磁盘探针。起因是一次连续失败：2026-11-13 的两个 run（`a8522a5` 之后的 `6acf963`，两次 attempt）都在 `make[3] -C target/linux install` 阶段以

```
##[error]The runner has received a shutdown signal...
##[error]The operation was canceled.
```

收场，job 的 annotation 写得很清楚：**"The hosted runner lost communication with the server. Anything in your workflow that terminates the runner process, starves it for CPU/Memory, or blocks its network access can cause this error."** —— 不是编译错误，是 runner 自己失联后被回收。

关键证据是它**与本次改动无关**：更早的 2026-10-22 run（`a8522a5`，还带着 nikki 桥）annotation 一字不差，同样是 lost communication；而 2026-09-15 那次成功构建跑在 `ubuntu-24.04`（runner image `20260828.587`）上，1h38m 顺利出镜像。时间线正好压在 GitHub 的 `ubuntu-latest` 迁移公告上（runner 日志里的 notice：「The ubuntu-latest label will migrate to Ubuntu 26 beginning October 19, 2026」，见 actions/runner-images#14748）：**迁移之后三次运行无一成功，迁移之前成功过**。失败的两轮都跑在 `ubuntu-26.04`（`20261111.196`）。

## Considered Options

- **继续用 `ubuntu-latest`，只加 swap 与探针**（否决：把「构建能不能出包」交给上游镜像的滚动更新；26.04 上具体是什么导致失联我们无从查证，钉死才能把变量收掉）
- **钉 `ubuntu-22.04`**（否决：24.04 是已经验证过能出镜像的那一版，22.04 需要重新验证一遍，收益为零）
- **换自托管 runner / 大内存机器**（否决于当下：这台构建机一年跑不了几次，收益不抵运维；若 24.04 后续也失联，再回到这个选项）
- **拆小 `make world`（分阶段跑，缩短单段时长）**（否决：world 的依赖图由 buildroot 自己管，外部切段只会制造「stamp 认为该重编」的假依赖，r3 事故的教训）

## Consequences

- 构建环境固定为 `ubuntu-24.04` + 16G 内存 + 8G swap；`ubuntu-latest` 的迁移（26.x 稳定后）需要一次显式决策再来改，而不是被动跟随。
- swap 的存在让内存尖峰变成「变慢」而不是「心跳发不出去」——内核开 `DEBUG_INFO_BTF` 后 GCC 的常驻内存与镜像装配阶段的峰值都比以前高，这是这次加的第二个理由。
- 构建日志里每分钟多一行 `[monitor HH:MM:SS] MemAvailable=… SwapFree=… load=… disk_avail=…`；万一再失联，日志末尾就是现场，不必再靠 annotation 反推。
- 探针与 swap 都在 GitHub 托管 runner 上完成，不影响产物：镜像内容、签名与 release 流程不变。
