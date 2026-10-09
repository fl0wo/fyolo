---
title: 零前置远程访问：把 dev tunnels 的形状搬到 fyolo
status: draft
type: rfc
created: 2026-08-27
updated: 2026-08-30
related:
  - 20260705-remote-access-relay-strategy.md
  - 20260827-fyolod-lifecycle-reconcile.md
  - 20260730-fyolod-session-protocol.md
  - 20260814-remote-to-device.md
---

# 零前置远程访问：把 dev tunnels 的形状搬到 fyolo

> 手机扫码连上一台 Linux，用户在那台机器上**不需要预先有任何东西** —— 没有域名、
> 没有反向代理、没有 root、没有开放端口。这份 RFC 记录 VS Code dev tunnels 的做法、
> 哪些能搬哪些搬不了、fyolo 的具体形态、relay 部署在哪，以及公开之前必须先修的东西。

## 0. 动笔前核对过什么

外部事实来自 dev tunnels 的官方文档与逆向分析（见 §9 出处）。仓库内的每一条都在
`main`（`b5d1f8a`）和 `ukvps` 上当场验证过。

| 结论 | 出处 |
| --- | --- |
| fyolod 拒绝一切非环回绑定，在解析 flag 时就拒 | `wss.rs` `parse_bind` |
| fyolod 整个 crate 没有 TLS，依赖层面就排除了 | `fyolod/Cargo.toml:32`（"No `connect`, no `native-tls`, no `rustls`"） |
| 任何 TLS 终结器前面，同源回退必然拒绝 | `wss.rs` `origin_worked_examples` 第二条断言 |
| `pair` 从不接触守护进程，也不检查监听器 | `wss.rs` `run_pair` —— 只读 token 和 origin 文件 |
| 手机把 `https://h/p/` 转成 `wss://h/p/ws`，origin 取 `scheme://host[:port]` 不带路径 | `ios/Sources/Models.swift` `websocketURL` / `originValue` |
| 手机配对时会先拨号握手、拿到 `hello_ok` 才落盘 | `Models.swift` `pair(invite:)` |
| 手机持久化 `address` / `token` / `origin`，按 `host_id` 索引 | `Models.swift` `adopt(invite:hostID:)` |
| tunelo 的 relay 与客户端共用 `crates/protocol`，两端都已用 `quinn` + `rustls` | `jiweiyuan/tunelo` 三个 `Cargo.toml` |
| `ukvps` 上的 tunelo 是 **0.2.0** —— `--identity` 是 0.3.0 才有的 | `tunelo --version` |
| `*.tunelo.net` 通配 DNS 已解析，证书含 `*.tunelo.net` | `getent hosts`、`/etc/nginx/sites-enabled/tunelo.net` |

## 0.1 写完之后（2026-08-30 复核）

这份 RFC 是 8-27 写的。到 8-30，§4.2 整条和 §6 里的两条已经落地了。下面每一行都是
当场在 `ukvps` 上复核过的现状，**不是计划**。

| 原文说 | 现在 | 出处 |
| --- | --- | --- |
| §4.2 步骤 6「两者都挂 `systemctl --user`」是计划 | 已实现。Publish 一下写两个 unit、`loginctl enable-linger`，`kill -9` 两个进程后 8 秒内都回来且地址不变 | `RemoteTunnel.swift` `RemoteSystemdUnit`；`feb228c` / `d3691a0` |
| §4.3「三处必须逐字节相同」靠人守 | 地址由 Mac 从隧道日志**读回**再写进守护进程，`RemotePairing.invite` 的 `--url` 参数已删除 | 同上 |
| `pair` 成功 ≠ 可达（§0 已列）——但没人管 | 画二维码之前先按手机的规则拨一次号，比对 `host_id`；不通就退回「尚未发布」 | `RemoteTunnelService.handshake` |
| §6.1 tunelo 需要 0.3.0 `--identity` | 已满足，稳定子域名跨重启与 `kill -9` 复核过 | `4a6c5284842fef36.tunelo.net` |
| §6.5 Linux systemd user unit「lifecycle RFC 明确 defer 了」 | **已发布**（`a1a8cdc` / PR #522），且 app 侧那份重复的 unit 也已经拆掉（PR #530） | `fyolod/src/service.rs` `systemd::unit`；`RemoteTunnel.swift` `arm` |

### 一个必须记下来的冲突（已修，保留经过）

`fyolod.service` 现在有**两个写者**，策略不同：

| | `fyolod service install`（#522） | `RemoteTunnel.swift`（本 RFC 这条线） |
| --- | --- | --- |
| `ExecStart` | `fyolod serve` | `fyolod serve --wss … --wss-origin …` |
| 重启 | `Restart=on-failure` | `Restart=always` + `StartLimitIntervalSec=0` |
| WSS 从哪来 | 磁盘上的 `wss.bind`，或 `FYOLOD_WSS` drop-in | 焊在命令行里 |

后写的覆盖先写的。`ukvps` 上现在是 app 写的那份，而客户端 autostart 起来的
`fyolod serve` 占着 socket，于是 unit 每 3 秒起一次、每次绑不上就退出 ——
**`NRestarts=74377`**，`fyolod status` 报 `service: none`。

盒子今天仍然可达，但**不是靠这个 unit**：`wss.bind` / `wss.origin` 在磁盘上，
autostart 起来的那个守护进程从磁盘把自己武装好了。也就是说这条线目前**没有**在
兑现它自己写下的「扛重启」。

`service.rs` 的注释已经把出口指明了：*"WSS is deliberately not on the command
line: the bind survives in `wss.bind` beside the socket, or in a `FYOLOD_WSS`
drop-in."* 守护进程侧把 `Restart=on-failure` 的理由也写清楚了 ——
`fyolod stop` 发 `SIGTERM` 后要等 socket 排空，`always` 会和那次排空抢。

**已收敛（2026-08-30，PR #530 `614a00c`）。** app 不再自己写 `fyolod.service`，
`arm` 改成四步：停掉命令行里带 `--wss` 的旧 unit（那是 app 写的标志，`service
install` 写的从不带）→ 写
`~/.config/systemd/user/fyolod.service.d/override.conf`，只有
`Environment="FYOLOD_WSS=…"` / `FYOLOD_WSS_ORIGIN=…` → `fyolod stop --force`
→ `fyolod service install`。`Restart` 策略回到守护进程自己说了算。

**为什么是 drop-in 而不是 `wss.bind`。** `wss.bind` / `wss.origin` / `pair.token`
都在 `state_dir()` = `$XDG_RUNTIME_DIR/fyolod/`，那是 tmpfs —— 重启就没了。而
`service install` 只覆盖 unit 文件，不动 `.d/`。守护进程每次启动都读环境变量
（`wss.rs` 的优先级：`--wss` > `FYOLOD_WSS` > `wss.bind`），所以 drop-in 是唯一
一份跨重启还在、又不会被 `service install` 冲掉的武装记录。

**代价记一笔**：环境变量武装起来的监听器**不会**把 origin 回写到 `wss.origin`，
而 `pair` 是另一个进程 —— 所以 `RemotePairing.invite` 现在得先
`systemctl --user show fyolod -p Environment` 把 origin 读回来，再用
`FYOLOD_WSS_ORIGIN='…' fyolod pair --json` 出邀请。§4.3「三处逐字节相同」这条
约束因此多了一个必须对齐的地方，不是少了一个。

隧道那个 unit（`fyolo-tunnel.service`）没有第二个写者，保持现状 —— 它的
`Restart=always` + `StartLimitIntervalSec=0` 是对的：隧道掉了就该一直重连。

## 1. 问题

今天要让手机连上一台 Linux，用户必须**已经**拥有：一个域名、一个反向代理、以及
root。这三样任何一样缺失，流程就断在一句无法执行的错误上。

这不是 onboarding 的门槛，这是**放弃 onboarding**。对照物很清楚：`code tunnel`
一条命令、设备码登录、URL 当场给你，机器本身零前置。

**本 RFC 的标准线：用户在目标机器上不需要预先有任何东西。**

## 2. dev tunnels 实际是怎么做的

| 机制 | 做法 |
| --- | --- |
| 方向 | **两端都出站**，不需要任何入站连接 |
| 拓扑 | 全局控制面 `global.rel.tunnels.api.visualstudio.com` 分配区域集群 `[clusterId]`，数据面独立域名；集群列表是公开 API |
| 命名 | 通配 `*.devtunnels.ms`，一条隧道端口一个子域名（`tunnelid-3000.devtunnels.ms`） |
| TLS | 在服务入口终结，用 Microsoft CA 签的服务证书，之后重写 header |
| **端到端** | WebSocket 建好之后，**里面再跑一层 SSH**（AES-256-CTR / HMAC-SHA256-ETM），所以 relay 转的是密文 |
| 外层鉴权 | `tunnel-relay-client` 子协议 + connect JWT；内层 SSH 用户名 `tunnel`、`None` 认证，因为外层已鉴权 |
| Token | 四种、24 小时过期：client（连）/ host（承载）/ manage-ports / management。刷新必须用真实身份，management token 自己刷不了 |
| 客户端携带 | `X-Tunnel-Authorization: tunnel <TOKEN>`，**故意不用** `Authorization`，避免和应用自己的鉴权撞车 |
| 默认可见性 | 私有；`--allow-anonymous` 才公开 |
| 反滥用 | 浏览器首次访问有反钓鱼插页；非 GET、非 HTML、带 `X-Tunnel-Authorization` 时跳过 |

## 3. 哪些能搬，哪些搬不了

### 能搬，而且我们已经在半路上

**出站-only 的 host。** fyolod 的 `parse_bind` 已经拒绝一切非环回地址 —— 最难的
那一半（"绝不开放端口"）不是要做的事，是**已经做完的事**。

**host token 与 client token 分离。** 这正是 `20260705` 那份 doc 里"防白嫖 = 只
gate `Register`"的工业级写法：承载隧道要 host token，连接隧道要 client token，两者
不可互换。visitor 面只能连已注册的 owner，天然守住。

**通配 DNS = 一条记录。** `20260705` 已经点出 BYO cloudflared named tunnel 的天花板
是**单 zone DNS 记录配额**（一台机器一条）。自建 relay + `*.domain` 通配，全部用户
共用一条记录 —— 那堵墙对我们不存在。这是自己跑 relay 相对白嫖别人最实在的好处，
比省流量费实在。

**分区域是后来才做的。** 先全局单点，把集群分配留成一个可加的间接层，不要现在建。

### 搬不了，以及为什么

**SSH-in-WebSocket 的端到端加密。** 这是 dev tunnels 设计里最漂亮的一笔 —— relay
看不见明文，所以**不需要被信任**。搬不过来，因为它要求 iOS 端有一个 SSH 实现，
而"never embed SSH or crypto"是 `CLAUDE.md` 的非谈判项 #3。

后果必须直说：**v1 的 relay 看得见终端明文。** 这不是可以含糊过去的细节，它直接
顶在 `CLAUDE.md` 的另一句上 —— "The code never leaves hardware the user controls"。
处理方式是 §7 的两条：如实披露 + 逃生口必须一样好用。

**账号身份。** dev tunnels 靠 GitHub / Microsoft 登录。fyolo 没有账号体系，也不
打算有。替代方案在 `20260705` 已经定过：**Ed25519 设备密钥对**，
`subdomain = base32(SHA-256(pubkey))`（Syncthing 同款），归属靠 relay 发 challenge、
客户端私钥签名自证。理由是身份与证明合一、纯 Rust 跨平台、避开硬件指纹的隐私雷。

**注意这条推翻了一个更早的想法**：用 `host_id` 做路由键是错的。`host_id` 是无证明的
bearer 标识，谁报谁就是 —— 那正是下面 §6 抢注 bug 的成因。

## 3.5 关键修正：fyolo 要的是 rendezvous，不是 tunnel

看过 [getpaseo/paseo-relay](https://github.com/getpaseo/paseo-relay)（Elixir/OTP，
Syn 做分布式所有权注册）之后，上面 §6 的блок清单有一半是**自找的**。

paseo 的路由键**是查询参数，不是主机名**：客户端带 `serverId` / `role` /
可选 `connectionId` 连上来（每项 ≤256 字节，超了在建状态之前就 400），relay 按
`serverId` 把两端配对。payload 全程 opaque —— relay 不解析、不关心。

**把路由从主机名换成查询参数，一整类问题直接不存在：**

| 子域名模型（tunelo / dev tunnels） | 查询参数模型（paseo） |
| --- | --- |
| 通配 DNS + 通配证书 | **一个主机名，普通证书** |
| relay 分配子域名 → 可被抢注 | 路由键是**客户端自带的身份**，没有可抢的东西 |
| 名字会轮转 → 手机被甩掉 | 键 = 设备密钥，只要密钥在就不变 |
| `--wss-origin` **每台机器一个值**，要钉、会填错 | origin 是 `https://relay.example`，**所有设备同一个常量** |
| 用户面：子域名、DNS、证书 | 用户面：**一个 relay URL** |

最后两行是重点。§4.3 里那个"三处必须逐字节相同否则 403"的坑，在这个模型下**不是被
自动化绕过去，而是根本不存在** —— origin 是编译期常量，不是每台机器要配的值。

而 §6 的前两条阻塞项（tunelo 0.2.0 没有 `--identity`、`resolve_subdomain` 抢注）
**都是子域名分配机制的产物**。换模型即消失，不用修。

### 为什么会绕这一圈

因为 tunelo 是**通用隧道**（把任意本地端口发布成一个公网 URL，ngrok 那类），而
fyolo 需要的是**会合**（把两条已经认识彼此的连接接起来）。前者是后者的超集，
多出来的那部分 —— 公网 HTTP 端点、子域名、通配证书 —— 正是六条阻塞项的全部来源。

**用手上有的工具，不等于用对了工具。**

### 落地取舍

- **偷设计，不偷依赖。** paseo-relay 是 Elixir，而且它的契约是"protocol-compatible
  with Paseo"；照抄会让 fyolo 去适配别人的 v2 query contract。会合本身很小 ——
  Rust 里用 axum + tungstenite 大约几百行，还能继续用 `tunelo-protocol` 那套共享类型。
- **BEAM 的集群和分区处理是真本事**（Syn 收敛后败方 WebSocket 以 `1012` 关闭）。
  真到多节点再考虑是不是值得换语言，单节点阶段不需要。
- **TLS 的负担落在 relay 运营者身上，位置是对的。** paseo relay 默认绑
  `127.0.0.1:4000`，前面放反代 —— 那是**我们的**机器，不是用户的。用户侧仍然零前置。
- **E2EE 有现成的挂钩。** paseo 校验 `e2ee_hello` 帧里的 X25519 公钥（canonical padded
  Base64、32 字节）但不强制 —— **relay 负责撮合，加密留在两端**。这条路以后要走的话，
  需要开例外的是**端点**，不是 relay。

## 4. 设计

### 4.1 组件

```
手机 ──wss──▶ relay(你的) ◀──出站 QUIC/wss── tunelo client ──▶ 127.0.0.1:8790 fyolod
                                                （同一台用户机器）
Mac ──ssh──▶ 用户机器            控制面：部署、配对、验证
```

四件东西，只有一件是新的（托管 relay）；其余三件都已存在。

### 4.2 零前置安装

"Set Up this device" 现在已经在 scp `fyolod`。扩成：

1. 部署 `fyolod`（已有）
2. 部署 `tunelo` 客户端（同一机制，多一个静态二进制）
3. fyolod 绑 loopback 起 `--wss 127.0.0.1:8790`
4. tunelo 出站连 relay，拿到**稳定**子域名
5. origin 钉住该子域名 → `fyolod pair --json` → 二维码
6. 两者都挂 `systemctl --user`，配 `loginctl enable-linger`

用户做的事：点一下。**1–6 已经实现**（`RemoteTunnel.swift`），但第 6 步的守护进程
那一半写法是错的 —— 见 §0.1 的冲突：隧道 unit 归 app 写，`fyolod.service` 应该归
`fyolod service install` 写。

**全程不需要 root。** `~/.local/bin` + `systemctl --user` + linger。nginx 那条路必须
sudo，而很多人的 VPS 账号没有 sudo，或不愿在安装流程里交出去。这一条本身就足以
决定默认路径选哪个。

### 4.3 URL 机制（已核对，不是推导）

设子域名为 `d.relay.example`：

- 邀请 `url` = `https://d.relay.example`
- 手机拨 `wss://d.relay.example/ws`（`websocketURL` 在路径后接 `/ws`）
- 手机发 `Origin: https://d.relay.example`（`originValue`，不带路径）
- fyolod 侧 `--wss-origin https://d.relay.example`

三处必须**逐字节相同**，否则 403。所以 URL 只能有一个来源：**Mac 把 origin 写到机器上，
`pair` 从机器自己的 `wss.origin` 派生邀请** —— 绝不在配对时传 `--url`。

**这条现在由代码守，不由人守**：地址是 Mac 从隧道日志读回来的（读回来的值没法手打错），
`RemotePairing.invite` 的 `--url` 参数已经删掉 —— 它只改邀请上**印**的地址，不改守护
进程**接受**的 origin，留着就是一个「扫得进、连不上」的陷阱。

但读回来也只证明隧道说过这个地址。`pair` 从不接触守护进程（§0），所以邀请一律先按
手机的规则拨一次号、比对 `host_id`，通了才画二维码；不通就退回「尚未发布」并给出
重新发布的入口 —— 对拿着手机的人来说，「连不上的盒子」和「没发布的盒子」是同一件事。

### 4.4 分层：按"用户已经有什么"，不按"我们想卖什么"

| 路径 | 用户必须已经有 | 操作 |
| --- | --- | --- |
| **托管 relay（默认）** | **什么都不用有** | 点一下 |
| 自建 relay | 自己的 tunelo / CF named tunnel | 填一个 endpoint |
| 反向代理 | 域名 + nginx/Caddy + root | 贴一段配置 |
| Tailscale | tailnet + 手机装 App | 一条命令 |

后三条不是装饰，是 §3 那条"relay 看得见明文"的对价。它们必须和默认路径**一样好用**，
否则 `fyolo is FREE` 这句话就站不住。

## 5. Relay 部署在哪

**不要放在 `ukvps`。** 那台机器同时是 tunelo.net 的生产宿主、手工起的 fyolod 实验场。
给付费用户做中转的机器，不该是开发箱。

**一台独立 VPS 起步，不要 nginx，也不要 Traefik。** relay 已经直接依赖 `rustls` 和
`quinn` —— 它自己就终止 TLS。前面再放一层是第二次终结 + 多一跳，而且 **Traefik 代不了
tunelo 的 QUIC**（它讲 HTTP/3，tunelo 是 quinn 上的自定义协议）。

- 通配证书 `*.relay.example`，DNS-01
- **ACME 做在 relay 进程里**（`instant-acme` / `rustls-acme`）→ 一个二进制、一个产物、
  零 sidecar。这在后面上多区域时直接省掉一整套编排

**也不要用 Go 重写。** `crates/protocol` 是 relay 和客户端共用的；换语言 = 一个线上
协议两份实现，漂移的症状是"某些用户连不上"这种最难查的类型。

**多区域推迟。** 真撞到"用户在另一个大洲、延迟不能忍"再动，那时优先 Fly.io
（Dockerfile 已有，Rust 原样跑，anycast），dev-tunnels 那种 global→cluster 分配是
更后面的事。

## 6. 公开之前必须先修

1. ~~**tunelo 0.3.0 的 `--identity`。**~~ **已解决**（2026-08-30）。`ukvps` 上是 0.3.0，
   `4a6c5284842fef36.tunelo.net` 跨进程重启、`kill -9`、换 provider 都没变。稳定名字
   是整条路的地基，这块地基现在有了。
2. **抢注 / DoS。** `crates/relay/src/router.rs::resolve_subdomain` 在 owner 断线时把
   子域名交给下一个来者；password 只 gate `Attach`，不 gate `Register` 回收。修法 =
   owner 用私钥自证回收。带着这个上线等于谁都能顶掉别人的机器。
3. **Register 准入。** 用已有的 Lemon Squeezy 后端签短期 Ed25519 token，relay 内嵌
   公钥验签 —— 私钥在后端，**开源不泄密**。
4. **`--max-session 0`。** `crates/tunelo/src/main.rs:100` 默认 86400 秒；`ukvps` 的
   relay unit 命令行上没写这个 flag，所以吃的就是这个默认 —— 隧道每 24 小时被切一次。
   **未解决**，而且这是别人生产服务的策略，不是本 RFC 能顺手改的。
   隧道 unit 的 `Restart=always` + 稳定 `--identity` *应该*让客户端被切之后自己回来
   并夺回同一个子域名 —— 但这只在 `kill -9` 下验证过，没有跨过一个真实的 24 小时窗口，
   也没验证客户端被 relay 切断时是**退出**还是**挂在一条死连接上**。后者的话重启永远
   不触发。
5. ~~**Linux systemd user unit。**~~ **已发布**（2026-08-29，`a1a8cdc` / PR #522）：
   `fyolod service install` 在 Linux 上写 `fyolod.service`，`Restart=on-failure`，
   `spawn_daemon` 在 unit 持有 socket 时改走 `systemctl --user start`。
   app 侧一度又写了一份同名 unit，两个写者策略不同，在 `ukvps` 上空转了
   `NRestarts≈74000` 次；PR #530 已收敛成 drop-in（见 §0.1）。
6. **滥用预案。** 一个公开的、能把任意本地端口暴露到公网的服务**一定**会被拿去做 C2
   和钓鱼 —— dev tunnels 的逆向分析文章标题就叫 "The Accidental C2"，微软的反钓鱼插页
   就是为此而设。上线前要有：滥用举报入口、按 Register token 吊销的能力、以及速率限制。

## 7. 非目标

- **v1 不做端到端加密。** 见 §3。以后要做，路径是 WebSocket 里加一层 Noise/X25519 —— 那
  需要对非谈判项 #3 开一个有意识的例外，不能顺手做。
- **不做 P2P / STUN / ICE。** `20260705` 已经算过：fyolo 只传终端帧、不传视频，纯中转
  完全够用，不必上打洞那套复杂度。
- **不做账号体系。** 身份是设备密钥对，准入是签名 token。
- **不取代 BYO / nginx / Tailscale。** 它们从"兜底"升格为"逃生口"，地位反而更重要。

## 7.1 备选方案：把 tunelo 作为 crate 嵌进 fyolod

**方案**：不再部署独立的 tunelo 客户端进程，而是把 `tunelo-client` 作为 crate 编进
fyolod，由 fyolod 自己出站连官方 relay，直接在那条连接上跑会话协议。

**它确实更干净，四条都是真的好处：**

1. **一个进程、一个 unit、一个产物。** 部署就是 scp 一个二进制。
2. **消掉 loopback 那一跳。** 现在是 relay → tunelo → TCP 127.0.0.1:8790 → fyolod；
   嵌进去就是 relay → fyolod。少一次拷贝、少一条 TCP 连接。
3. **`--wss` 监听器可能整个不需要了。** 出站建连就没有端口要绑，`wss.bind` 这个文件、
   "监听器起没起"这个状态、以及本地端口暴露面，一并消失。
4. **origin 自己钉自己。** fyolod 注册时就知道自己的子域名，`--wss-origin` 不再是
   一个人要手填、填错就 403 的值。**整条链路里最容易错的一步被消灭了**，而不是被
   文档绕过去。

**但它撞的是非谈判项 #3，而且撞在记录这条规则的那个文件上。**

`fyolod/Cargo.toml:32` 白纸黑字：*"No `connect`, no `native-tls`, no `rustls`"*。
嵌 tunelo 就是把 `quinn` + `rustls` + `ed25519-dalek` 拉进 **持有用户 shell 的那个
进程**。fyolod 今天连一次出站 TLS 都不发起 —— 这个极小的攻击面是刻意的，不是疏忽。

还有三条次级代价：

- **版本被焊死。** 今天 tunelo 能独立升级（现场 0.2.0 → 需要 0.3.0）；嵌进去之后，
  relay 协议每动一次就要发一次 fyolod。
- **逃生口被削弱。** 走 nginx / Tailscale / cloudflared 的用户，本来只要"不跑那个进程"；
  嵌进去之后，那些代码在他们的守护进程里永远存在。
- **"一个产物"的收益大半是幻觉。** 第二个二进制是 **Mac 替用户装的**，用户那边仍然
  只点一下。少一个进程对**我们**有价值（少一处监督、少一处调试），对用户几乎无感。

**结论：现在不嵌。**

理由不是"嵌不好"，而是**这两个选择的可逆性不对称**：保持分离，以后想嵌，靠
`tunelo-protocol` 这个共享 crate 就是一次机械改动；先嵌了再想拆，逃生口和版本解耦
都已经烂在里面了。在 relay 这个产品还没被验证之前，选可逆的那个。

而且 §7.1 列的四条好处里，**前三条可以不嵌就拿到**：让 sidecar 自己把 `wss.bind` 和
`wss.origin` 写回去，第 4 条（origin 自动钉）也一并解决 —— 那是自动化，不是架构。
真正只有嵌入才能拿到的，只有"少一跳 loopback"和"少一个进程"。用一条非谈判项去换
这两样，不划算。

**若将来要嵌**，前提和上 E2E 一样：对非谈判项 #3 开一个**有意识的、写下来的例外**，
在这份 RFC 里记录，而不是让它悄悄漂移过去。

## 8. 待评审的问题

1. **免费层拿不拿得到托管 relay？** 若是，白嫖防护就必须先到位（§6.3）；若否，免费层
   的默认路径退回 BYO cloudflared named tunnel（免费、稳定域名、零服务器），而
   `fyolo is FREE` 的成色取决于那条路有多好用。
2. **明文这件事写在哪、怎么写。** 代码里 `tunnelFootnote` 已有"说清楚手机流量过谁的
   服务器"的先例。托管 relay 是我们自己的服务器，措辞不能比说 cloudflared 时更含糊。
3. **配对由谁经手。** 现在是 Mac 通过 SSH 代跑 `fyolod pair --json`（控制面在 Mac）。
   要不要允许手机直接向 relay 报到？前者不需要新协议，后者能去掉"必须有一台 Mac"。
4. **`upgrading` 与本 RFC 的耦合。** 武装监听器和钉 origin 都需要重启守护进程，也就是
   lifecycle RFC §5.2 的 `stop --if-idle`。实现时走的是 `fyolod stop --force`，并在
   点下去之前把会被结束的会话**按命令行逐条列出来**让人确认 —— 「是不是该结束」取决于
   那是个跑到一半的 agent 还是一个停在提示符的登录 shell，只报个数字答不了这个问题。
   `--if-idle` 落地后这里可以退回到「空闲就不问」。

## 9. 出处

- [Developing with Remote Tunnels — VS Code](https://code.visualstudio.com/docs/remote/tunnels)
- [What are dev tunnels? — Microsoft Learn](https://learn.microsoft.com/en-us/azure/developer/dev-tunnels/overview)
- [Dev tunnels security — Microsoft Learn](https://learn.microsoft.com/en-us/azure/developer/dev-tunnels/security)
- [The Accidental C2: Exploring Dev Tunnels for Remote Access — XPN Infosec](https://blog.xpnsec.com/accidental-c2/)
- [microsoft/dev-tunnels-ssh](https://github.com/microsoft/dev-tunnels-ssh)
