# Codex Web 远程访问最终方案

> 最后核对：2026-07-14。本文是本项目远程访问、腾讯云 FRP、Cloudflare、
> `xieran.top`、Windows TUN 兼容和公司网络探查的唯一最终说明。
> 后续不要再同时维护其他 Tencent/Cloudflare 迁移说明；新的实测结论直接更新本文。

## 1. 最终决定

项目以本仓库（整理时目录名为 `codex-web-old`）的原生 WebSocket 实现为最终基准。
实验目录 `codex-web` 中后来加入的强制 HTTPS IPC、轮询或应用层分片没有合入。
将本目录改名为 `codex-web` 不影响启动器，因为所有本地路径都从脚本所在目录解析。

推荐的公司访问链路是：

```text
公司浏览器
  -> Cloudflare 边缘（HTTPS / HTTP/2，WSS 可用）
  -> 腾讯云东京的 cloudflared
  -> 腾讯云本机 127.0.0.1:8081
  -> frps / FRP TCP 隧道
  -> 笔记本 127.0.0.1:8215
  -> Codex Web 原生 /__backend/ipc WebSocket
```

这条链路的公网入口是：

```text
https://lines-convert-mining-artwork.trycloudflare.com/
```

个人网络或手机可以使用备用链路：

```text
浏览器 -> https://codex.xieran.top/ -> 腾讯云 Nginx 127.0.0.1:8080
       -> FRP -> 笔记本 127.0.0.1:8214 -> Codex Web WSS
```

公司代理会拦截 `xieran.top` 的 WSS，因此它不是公司环境的可用替代品。

## 2. 启动文件

### 2.1 公司环境：Cloudflare + 腾讯云

双击：

```text
with-tencent.bat
```

它启动本地 8215、连接腾讯云 FRP，并使用腾讯云上已经运行的 cloudflared
发布上述 Cloudflare 地址。cloudflared 不在笔记本上运行，因此笔记本的 TUN、
酒店网络或本地 UDP 状态不会直接影响 Cloudflare connector。

### 2.2 手机或个人网络：xieran.top

双击：

```text
with-xieran.bat
```

它启动本地 8214，通过 FRP 接入腾讯云 Nginx 和 `codex.xieran.top`。
协议仍然是原生 WSS，而不是 HTTPS polling。

### 2.3 原生本机 Cloudflare 对照

原有文件：

```text
start-codex-web-cloudflare.bat
```

仍表示“笔记本直接运行 cloudflared”。它保留作故障对照，但不是当前推荐方案。
在 TUN、UDP 不稳定或公司/酒店网络质量差时，它可能比腾讯云 connector 更容易抖动。

### 2.4 使用约束

- `with-tencent.bat` 与 `with-xieran.bat` 是两个替代入口，不要同时运行；
- 关闭当前窗口并确认 FRP 退出后，再切换另一个 BAT；
- 第一次运行或物理网络发生变化时，Windows 可能请求管理员权限添加直连路由；
- `scratch/frp` 包含 FRP 二进制和受控配置，被 Git 忽略，不得提交；
- 启动器均通过项目根目录动态定位文件，目录改名后仍可工作。

## 3. 本机组件和端口

| 组件 | 本机地址 | 腾讯云入口 | 用途 |
|---|---|---|---|
| Codex Web（xieran） | `127.0.0.1:8214` | `127.0.0.1:8080` | 手机/个人网络备用入口 |
| Codex Web（Cloudflare） | `127.0.0.1:8215` | `127.0.0.1:8081` | 公司推荐入口 |
| frpc | 出站到 `43.153.184.34:3389/TCP` | frps | 反向隧道控制连接 |

两个 Web 端口运行的是同一份源码，只是给不同公网入口预留了独立 FRP proxy。
此前同时看到 8214 和 8215，并不表示存在两个不同产品版本。

启动器还会准备独立的 `%USERPROFILE%\.codex-web` 状态目录：普通配置、会话等
通过 junction/hard link 复用真实 `.codex`，但远程连接选择会被清理，确保网页端执行目标
保持为本机，不会误选腾讯云 SSH remote。

## 4. 腾讯云组件

当前服务器：腾讯云轻量应用服务器，东京，2 核 CPU、2 GB 内存、50 GB SSD、
每月 1 TB 流量。它只承担转发，资源足够，性能瓶颈通常是网络 RTT 和公司代理，
不是 CPU 或磁盘。

关键服务：

| 服务 | 状态/作用 |
|---|---|
| `frps.service` | 接收笔记本 frpc，控制端口为 3389/TCP |
| `nginx.service` | `xieran.top` HTTPS、静态缓存和 WebSocket reverse proxy |
| `codex-cloudflared.service` | Cloudflare connector，origin 为 `http://127.0.0.1:8081` |
| `codex-nettest.service` | 独立公司网络诊断服务，不参与 Codex 会话 |

`codex-cloudflared.service` 当前固定使用 `protocol: http2`。这表示腾讯云 connector
到 Cloudflare 的传输选择；公司浏览器实测同样显示 `h2`，但两段连接不能混为一谈。

同一个 tunnel 配置在腾讯云上只能保留一个受 systemd 管理的 cloudflared 进程。
2026-07-14 最终查明服务器曾同时启用 `codex-cloudflare.service`（旧）和
`codex-cloudflared.service`（现用）；两个单元的 `ExecStart` 完全相同，都会读取
`codex-quick-tunnel.yml`。Cloudflare 因而把请求分配给两个 connector，其中旧实例
持有失效 origin 长连接时就表现为间歇或持续 502。现已执行
`systemctl disable --now codex-cloudflare.service`，只保留启用且运行中的
`codex-cloudflared.service`。不修改 Codex Web、IPC 或 FRP 参数后，公网首页、
WSS 101 和约 133 KB 的真实 IPC 同步立即恢复。

排查时不能只看一个 service 是 `active`：还要使用 `systemctl list-unit-files` 查找
名称相近的旧单元，并对比 `systemctl show -p MainPID --value
codex-cloudflared.service` 与 `pgrep -af cloudflared`。读取同一配置的进程只能有一个。

8080/8081 只监听腾讯云 loopback，不应直接暴露公网。公网安全组只需要实际使用的
SSH、HTTP/HTTPS、FRP 控制端口等；FRP token、SSH 密钥和其他凭据不得写入本文或 Git。

## 5. Windows TUN 问题与最终处理

ChatGPT/Codex 桌面应用需要 TUN 虚拟网卡才能正常走代理，因此不能简单关闭 TUN。
此前的问题是：全局 TUN 可能把 frpc 到腾讯云的连接再次送入代理节点，造成绕路、
TCP 套 TCP、重传放大、连接抖动，甚至让诊断结果随代理软件和节点变化。

最终做法是对腾讯云公网 IP 建立 `/32` 物理网卡直连路由：

```text
43.153.184.34/32 -> 当前物理 Wi-Fi/有线网卡默认网关
```

`start-codex-web-via-tencent.ps1` 每次启动会：

1. 找到处于 Up 状态的物理网卡默认路由；
2. 检查腾讯云 `/32` 是否已经指向该接口和网关；
3. 缺失时通过 UAC 调用 `scratch/frp/set-direct-route.ps1` 添加；
4. 用 `Find-NetRoute` 再次验证腾讯云确实没有走 TUN。

因此可以继续保留 TUN。代理软件换成其他产品也没关系，只要 Windows 仍能识别物理默认
网关。如果从公司 Wi-Fi 切换到手机热点，旧路由可能需要重新添加；启动器会进行检查。
规则/局部代理通常比全局代理更干净，但不再是 FRP 正常工作的必要条件。

排查命令：

```powershell
Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '43.153.184.34/32'
Find-NetRoute -RemoteIPAddress '43.153.184.34'
```

## 6. 公司防火墙完整实验

实验使用同一腾讯云测试服务，从三种入口发起 GET、不同大小和 Content-Type 的 POST、
Codex 风格 `/api/v1/sync`、`/__backend/ipc/http`、应用层分片、SSE 和 WebSocket。
每项都有服务器回执，因此能够区分腾讯云/Nginx 返回和公司代理在上游拦截。

### 6.1 腾讯 IP + 纯 HTTP

| 项目 | 结果 |
|---|---|
| GET 与 2/6 KB query | 200，约 143–145 ms，HTTP/1.1 |
| 1/4 KB POST | 200，腾讯云收到 |
| 64 KB text/binary/multipart | 403，腾讯云未收到 |
| 256 KB POST | 403，腾讯云未收到 |
| 16 个 4 KB 分片 | 全部 200 |
| `ws://` 普通和 IPC 路径 | 全部失败，腾讯云未收到 |
| SSE | 200 |

直接 IP HTTPS 证书包含正确的 `IP Address:43.153.184.34` SAN，并由 Let's Encrypt
签发，但公司 Chrome/TLS 检查仍返回 `ERR_CERT_INVALID`。纯 HTTP 仅用于诊断，
不能承载密码或真实 Codex 数据。

### 6.2 xieran.top + HTTPS

| 项目 | 结果 |
|---|---|
| GET | 200，约 142–193 ms，HTTP/1.1 |
| 4 KB POST | 200 |
| 64 KB text/binary/multipart | 200 |
| 256 KB普通和 `/sync` POST | 403，腾讯云未收到 |
| 16 个 4 KB 分片 | 全部 200 |
| `wss://` 普通和 IPC 路径 | 全部失败，腾讯云未收到 |
| SSE | 200 |

这证明 403 不是 Nginx、FRP 或 Codex 返回的，也不只是“文件上传”或某个 URL 路径：
普通 text/plain 在达到阈值后同样被公司代理拦截。用户没有附加文件时，Codex 仍会把
会话状态、事件和 IPC 参数序列化后发送；对 DLP/公司代理而言，这仍是出站上传。

### 6.3 Cloudflare + HTTPS

| 项目 | 结果 |
|---|---|
| GET | 全部 200，约 406–427 ms，HTTP/2 |
| 1/4/64/256 KB POST | 全部 200，腾讯云收到 |
| text/binary/multipart | 全部 200 |
| `/sync` 与 IPC HTTP 路径 | 全部 200 |
| 16 个 4 KB 分片 | 全部 200，约 156–163 ms/次 |
| WSS 1/64/256 KB | 全部 101，握手和消息均到达腾讯云 |
| SSE | 200 |

结论：公司并非全局禁止 WebSocket，而是对 Cloudflare 入口采用了不同策略。
在已测试范围内，Cloudflare 是唯一同时允许大请求、WSS 和 HTTP/2 的入口。

## 7. 延迟和使用体感

公司实测呈现两个阶段：

- 首次 GET：Cloudflare 约 410 ms，xieran/IP 约 144 ms，所以冷启动资源发现更慢；
- 连接建立后的 POST：Cloudflare 多数约 156–163 ms，xieran 约 287–345 ms，
  Cloudflare 后续交互反而快约 40%–50%；
- 新建 WSS 连接约 1–1.45 秒，但正常 Codex 维持一个长连接，不会每个事件重新握手；
- SSE 实验自身包含约一秒等待，不能用约 1.2 秒的总耗时比较网络；
- 浏览器报告 `h2` 而不是 `h3`，说明公司浏览器到 Cloudflare 本次没有使用 QUIC。

Codex Web 冷启动会加载大量桌面 Webview 资源，并通过 IPC 恢复状态和会话。HTTP 200
或 loading 图标不代表可用；必须等完整 UI、WSS 和真实消息收发都成功。浏览器缓存与
Cloudflare/NGINX 资源缓存生效后，切换已打开会话通常明显更快。

2026-07-14 最终切换实测中，`xieran.top` 在个人网络上也能完成首页 200、WSS 101
和约 133 KB 的真实 IPC 往返；这只证明其服务端链路正确，不推翻公司环境会在到达
腾讯云之前拦截该域名 WSS 的结论。推荐 Cloudflare 链路移除重复 connector 后，
同样完成了首页 200、WSS 101 和完整 IPC 往返。

## 8. 为什么不采用其他方案

### 8.1 xieran.top 作为公司主入口

否决。公司代理拦截 WSS，并在大约 64–256 KB 之间触发请求体策略。即使页面能加载，
真实 IPC sync 仍可能 403。

### 8.2 强制 HTTPS IPC、轮询与分片

否决。4 KB 分片能绕过单请求大小阈值，但会把原本一个持久 WebSocket 变成大量请求。
Codex 的鼠标状态、窗口状态、thread hydration 和消息事件频率较高，会显著增加连接数、
延迟和实现复杂度；而 Cloudflare 原生 WSS 已经完全可用。最终源码不保留强制 fallback。

### 8.3 腾讯公网 IP 直接访问

否决。公司侧 IP HTTPS 证书处理失败，纯 HTTP 不安全，明文 WS 也被拦截。

### 8.4 笔记本直接运行 cloudflared

保留为对照但不推荐。链路更短，却容易受本地 TUN、酒店/公司网络、UDP 和代理节点影响。
把 connector 放到东京腾讯云会增加一个明确的中转点，但换来稳定的云侧出口；笔记本
只需通过 `/32` 直连维护一条 FRP TCP 连接。

### 8.5 QUIC、HTTP/2 与付费 Cloudflare

理论上 QUIC 在丢包网络上可以减少 TCP 队头阻塞，但公司浏览器实测只协商到 HTTP/2，
而腾讯云 connector 当前 HTTP/2 已稳定工作。付费套餐不会自动改变公司代理策略，
也不能保证更低 RTT；没有当前链路的实际故障时，不为“可能更快”主动更换。

### 8.6 国内 3 Mbps VPS或其他廉价海外 VPS

Codex Web 的瓶颈不仅是带宽，还包括 RTT、长连接稳定性和公司策略。国内 3 Mbps 对首次
加载大量资源并不理想；廉价海外 VPS 的路由和 IP 信誉也不可预期。当前腾讯云东京的
云厂商网络、1 TB 流量和固定资源更适合作为长期中转。

### 8.7 VMess 与 FRP 冲突

VMess 不是本次 403/WSS 失败的根因；真正证据指向公司代理策略和 TUN 路由。
如果不再需要自建代理，可以不在腾讯云部署 VMess，减少端口和维护面。FRP 本身只承担
Codex Web 反向隧道。

## 9. 认证与安全边界

测试期间 Basic Auth 曾导致 manifest 401，并让 WebSocket 鉴权更复杂；移除鉴权后，
`xieran.top` WSS 仍然失败，证明 401 不是根因。当前 Cloudflare URL 没有应用层密码，
随机 hostname 也不等于真正认证。

因此必须认识到：拿到 URL 的人可能访问页面。不要把 URL公开发布；如需长期多人使用，
应优先评估 Cloudflare Access、可信身份认证或定期重建 tunnel，而不是把密码硬编码到
BAT/Nginx。任何认证变更都必须重新验证 manifest、静态资源、WSS 和真实消息发送。

## 10. 日常验收与排障

### 最小验收

1. 双击所需 BAT；
2. 本地对应端口返回完整页面；
3. 公网页面不只显示 loading，而是完整渲染；
4. DevTools 中 `/__backend/ipc` 返回 101；
5. 打开旧会话并新建会话；
6. 发送固定文本并收到回复；
7. 保持运行至少 15 分钟，确认没有新增 502/504。

### 常见现象

| 现象 | 优先检查 |
|---|---|
| BAT 找不到 Codex CLI | 当前桌面 CLI 路径、`codex.exe --version`、显式 `-CodexPath` |
| already running 但入口不对 | 是否同时启动两个 BAT；关闭旧窗口后再切换 |
| `frp not found` 或 502 | frpc 是否注册、8214/8215 是否监听、8080/8081 映射是否匹配 |
| 页面 200 但一直 loading | JS/CSS、preload、WSS 101、IPC 帧，而不是只看首页状态 |
| 公司 xieran 403 | 预期的公司代理行为；改用 `with-tencent.bat` |
| Cloudflare 初次加载慢 | 冷资源和首次 hydration；再测 warm 会话与 WSS 是否持续 |
| TUN 开启后 FRP 抖动 | `Find-NetRoute 43.153.184.34` 是否走物理接口 |
| Cloudflare 502，但腾讯云 8081 是 200 | 查找是否同时启用了 `codex-cloudflare` 和 `codex-cloudflared`；同一配置只能有一个 connector |
| 运行十几分钟后 502 | 重复 connector、FRP keepalive、frps proxy 注册和 origin socket 积压 |

## 11. 更新与回滚

桌面 ASAR、Electron、Codex CLI/app-server 都是版本敏感边界。升级时：

1. 先保留当前可用目录和 `scratch/frp` 的本机备份；
2. 阅读 `UPGRADING.md`、`WINDOWS_SETUP.md` 和 `ARCHITECTURE.md`；
3. 在独立目录完成 ASAR patch 和本地 WSS 验证；
4. 再验证 FRP、Cloudflare、真实消息和 15 分钟稳定性；
5. 成功后更新本文中的版本、链路和实测数据。

不要把 HTTP 200、进程存在或 loading 图标写成“验收通过”。不要用强制 HTTP IPC
替换已验证的 WSS，除非未来公司策略发生变化且重新完成全套对照实验。

## 12. 下次交给 Codex 的提示词

```text
请先完整阅读项目根目录 REMOTE_ACCESS_FINAL.md，再阅读
UPGRADING.md、WINDOWS_SETUP.md 和 ARCHITECTURE.md。

当前生产入口是 with-tencent.bat：本地 8215 -> FRP -> 腾讯云 8081
-> 腾讯云 cloudflared -> Cloudflare。备用 with-xieran.bat 使用本地 8214
-> 腾讯云 8080 -> codex.xieran.top。两者都必须保持原生 WSS。

操作前先检查 git status、8214/8215、frpc、腾讯云 frps/nginx/cloudflared
和 TUN 下 43.153.184.34/32 的实际路由。不得泄露或提交 scratch/frp 中的凭据。
腾讯云上使用 codex-quick-tunnel.yml 的 cloudflared 必须只有 systemd MainPID 一个；
确认旧的 codex-cloudflare.service 保持 disabled/inactive，现用的
codex-cloudflared.service 保持 enabled/active。存在两个 connector 时，Cloudflare
仍可能把请求路由到坏连接。
本地完整 UI、WSS 101、真实消息收发和至少 15 分钟稳定性全部通过后，
才可以修改生产启动链路或更新本文的已验证基线。
```
