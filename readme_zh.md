# codex-web

[English](./README.md) | **中文**

一个运行在你自己 Windows 机器上的 Codex Desktop 浏览器前端。

本 fork 基于 [0xcaff/codex-web](https://github.com/0xcaff/codex-web)，主要目标是让
`codex-web` 可以在 Windows 上可复现地部署，并使用当前 Codex Desktop 的新版界面。

## 这个 fork 和原版的主要区别

- 适配 Windows：安装脚本会从 Microsoft Store 安装的 Codex Desktop 包中复制
  `app.asar`，不再依赖上游偏 Unix/macOS 的 prepare 流程。
- 使用新版 Codex Desktop 界面：当前测试基线是 Windows 包
  `OpenAI.Codex_26.623.19656.0`，其内部 app 资源版本基于
  `26.623.141536`。
- 提供 Windows 一键脚本：
  - `setup-windows.bat`
  - `start-codex-web.bat`
  - `start-codex-web-cloudflare.bat`
- 提供 Cloudflare Quick Tunnel 启动脚本，方便临时从手机或其他浏览器访问。
- 启动时会优先选择 `%LOCALAPPDATA%\OpenAI\Codex\bin\*\codex.exe` 下最新可运行
  的 Codex CLI，然后再回退到 `PATH` 里的 `codex`。

整体设计仍然尽量保持轻量：`codex-web` 负责托管打过补丁的 Desktop webview，并把
它桥接到本机 Codex app-server。你的文件、凭据和 Codex 状态仍然保留在宿主机上。

## 安全模型

请把 `codex-web` 当成“远程控制当前 Windows 用户”的入口来对待。

任何能够访问 Web UI 的人，都可能做到：

- 让 Codex 以运行 `codex-web` 的 Windows 用户身份执行命令；
- 读取或修改该用户有权限访问的文件；
- 使用这台机器上已经登录的 Codex 或 ChatGPT 账号；
- 消耗你的使用额度或计费额度。

不要把它直接暴露到不可信网络。如果你使用 Cloudflare 启动脚本，生成的
`trycloudflare.com` URL 本质上是一个临时公开控制入口，不要公开发布。

如果需要长期远程访问，建议在外层加自己的认证，或者使用 Tailscale、WireGuard、
SSH tunnel 等私有网络方案。

## Windows 快速开始

### 前置条件

请先在 Windows 宿主机上安装：

- Microsoft Store 版 Codex Desktop，并至少启动过一次；
- Node.js 和 npm；
- Git for Windows。安装脚本需要 `patch.exe`，Git for Windows 通常会提供；
- 可选：如果要使用 Cloudflare 启动脚本，请安装 `cloudflared.exe` 并确保它在
  `PATH` 中。

启动 Web UI 前，请确保 Codex 已经登录。你可以通过 Codex Desktop 登录，也可以运行：

```powershell
codex login --device-auth
```

如果 `codex` 不在 `PATH` 里，通常也没关系：Windows 启动脚本会扫描
`%LOCALAPPDATA%\OpenAI\Codex\bin\*\codex.exe`。

### 克隆并构建

```powershell
cd D:\
git clone https://github.com/Yiruma96/codex-web.git
cd D:\codex-web
```

然后运行安装脚本：

```powershell
.\setup-windows.bat
```

也可以直接运行 PowerShell 脚本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-windows.ps1
```

安装脚本会完成这些步骤：

1. 安装 npm 依赖；
2. 查找 Microsoft Store 安装的 `OpenAI.Codex` 包；
3. 把其中的 `app.asar` 复制到 `scratch/`；
4. 只解包 `codex-web` 需要的文件；
5. 应用 webview 和 bridge 相关补丁；
6. 构建 browser 和 server bundle。

`node_modules/`、`scratch/`、server 构建产物、日志、Cloudflare URL 等生成文件不会
提交到仓库。

维护者视角的更详细 Windows 说明见 [WINDOWS_SETUP.md](./WINDOWS_SETUP.md)。

### 本机或 Tailscale 启动

双击：

```text
start-codex-web.bat
```

或者运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-codex-web.ps1 -PreferTailscale
```

脚本会打印可访问的 URL。默认端口是 `8214`。如果不使用 Tailscale，通常打开：

```text
http://127.0.0.1:8214/
```

如果 Tailscale 正在运行，bat 脚本会优先使用你的 Tailscale IP，方便同一 tailnet
里的可信设备访问。

Windows 启动脚本默认认为 `8214` 上只运行一个 active 的 `codex-web` 实例。如果该端口
已被占用，脚本会先停止当前监听该端口的进程树，再启动新的 server。

### 使用 Cloudflare Quick Tunnel 启动

先安装 `cloudflared.exe`，并确保它在 `PATH` 中，然后双击：

```text
start-codex-web-cloudflare.bat
```

或者运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-codex-web-cloudflare.ps1
```

该脚本会先在本机 loopback 上启动 `codex-web`，然后启动 Cloudflare Quick Tunnel。
脚本会打印一个临时公开 URL，例如：

```text
https://example-name.trycloudflare.com
```

同一个 URL 也会写入：

```text
cloudflare-url.txt
```

使用期间请保持控制台窗口打开。关闭窗口会停止 tunnel 和本地 `codex-web` 进程。
Quick Tunnel URL 是临时的，每次重启通常都会变化。

如果希望脚本启动后主动探测公开 URL，可以运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-codex-web-cloudflare.ps1 -ProbePublicUrl
```

## 让你自己的 Codex 帮你部署

如果你已经在 Windows 机器上运行 Codex，可以把下面这个 prompt 复制给 Codex，让它帮你
完成部署：

```text
请在这台 Windows 机器上部署 codex-web。

仓库：https://github.com/Yiruma96/codex-web.git
目标目录：D:\codex-web

要求：
- 不要删除或重置我现有的 %USERPROFILE%\.codex 状态。
- 检查 Node.js、npm、Git for Windows、patch.exe，以及 Microsoft Store 安装的
  OpenAI.Codex 包是否可用。
- 如果 D:\codex-web 不存在，就 clone 仓库；如果已经存在，就检查 Git 状态并谨慎更新。
- 使用 PowerShell 的 -NoProfile 和 -ExecutionPolicy Bypass 运行 setup-windows.ps1。
- setup 成功后，使用 start-codex-web.ps1 本地启动 codex-web。
- 如果我要求远程浏览器访问，再使用 start-codex-web-cloudflare.ps1，但必须提醒我：
  拿到 Cloudflare URL 的任何人都可以操作这个 Codex 实例。
- 最后报告你实际运行的命令、识别到的 Codex Desktop 包版本、选择的 Codex CLI 版本，
  以及最终应该打开的 URL。
```

## 更新

拉取最新仓库，然后重新运行 setup：

```powershell
cd D:\codex-web
git pull
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-windows.ps1
```

如果 Microsoft Store 安装了新的 Codex Desktop 包，并且 setup 在应用 webview 补丁时
失败，通常说明上游 Desktop bundle 有变化。请带上包版本和 setup 日志提交 issue。

## 高级说明

### 指定 Codex CLI

启动脚本会自动检测 Codex CLI。如果你想强制使用某个具体的 `codex.exe`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-codex-web.ps1 `
  -CodexPath "C:\path\to\codex.exe"
```

### 指定 app.asar

如果 setup 找不到 Microsoft Store 包，或者你想测试别的 Desktop bundle：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-windows.ps1 `
  -AppAsarPath "C:\path\to\app.asar"
```

### Unix 和 Nix 路径

上游原项目支持 Unix 风格的 `npx` 和 Nix 用法。本 fork 保留这条路径，但 Windows 上支持
和推荐的是 clone 仓库后运行 `setup-windows.ps1`。在原生 Windows 上，不建议使用上游
的一行式 `npx github:...` 安装方式，因为它的 prepare 脚本预期运行在类 Unix 环境中。

## 常见问题

- `Could not find patch.exe`：安装 Git for Windows，或把 Git 的 `usr\bin` 目录加入
  `PATH`。
- `Could not find a runnable codex CLI`：安装或启动 Codex Desktop，或者传入
  `-CodexPath`。
- setup 找不到 `OpenAI.Codex`：从 Microsoft Store 安装或更新 Codex Desktop，启动一次后
  重新运行 setup。
- Cloudflare URL 在电脑上能打开、手机上打不开：检查 DNS、代理、VPN、运营商网络限制，
  或改用 named Cloudflare tunnel / 自定义域名。
- `8214` 端口被占用：Windows 启动脚本会先停止当前监听者再启动。若你想手动控制，请先
  关闭旧的 `codex-web` 窗口。

## 和上游的关系

这是 [0xcaff/codex-web](https://github.com/0xcaff/codex-web) 的非官方 fork。本仓库
额外做的主要工作是 Windows 安装/启动流程，以及让 patched webview 适配当前 Windows
Codex Desktop 资源。

欢迎提交 issue 和 pull request，尤其是新 Codex Desktop 版本导致补丁需要更新的情况。
