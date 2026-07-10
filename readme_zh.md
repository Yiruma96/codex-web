# codex-web Windows 版

[English](./README.md) | **中文**

这是 [0xcaff/codex-web](https://github.com/0xcaff/codex-web) 的 Windows
适配版：把 ChatGPT Desktop 中的 Codex 工作区界面运行在浏览器里，后端仍在你自己的
Windows 机器上运行。

## 本次迁移

Codex Desktop 已合并到 ChatGPT Desktop。当前 Windows 商店包有一组容易混淆的
标识：

| 层级                   | 当前验证值                    |
| ---------------------- | ----------------------------- |
| 商店/Appx 技术身份     | `OpenAI.Codex 26.707.3563.0`  |
| 应用显示名和可执行文件 | `ChatGPT` / `app\ChatGPT.exe` |
| ASAR 内部版本          | `26.707.31123`                |
| ASAR 品牌              | `codexAppBrand=chatgpt`       |
| Electron               | `42.1.0`                      |

因此安装脚本不会用 `OpenAI.Codex`、`productName` 等名字猜品牌，而是解包后严格检查
`codexAppBrand=chatgpt`。Appx 版本与 ASAR 版本分别记录，不能混用。

本次 Windows patch 以两个地方为依据：

1. 上游 `0xcaff/codex-web` 的最新提交和 `patches/*.patch`，尤其是针对
   ChatGPT/macOS `26.707.30751` 的 `28b9a81`；
2. 本仓库合并前最后一版 Windows 适配提交，用来参考 Windows ASAR 提取、bundle
   定位、Electron shim 和启动脚本。

新 patch 按上游每项改动的语义重新定位到 Windows `26.707.31123` bundle，不复用
旧版本的文件哈希或失效字符串点位。

## 快速开始

先安装或更新 Microsoft Store 中显示为 ChatGPT 的 Codex 工作区应用，并安装
Node.js 22+。然后运行：

```powershell
git clone https://github.com/Yiruma96/codex-web.git
cd codex-web
.\setup-windows.bat
```

setup 会自动完成：

1. 安装 npm 依赖并重建 `better-sqlite3`；
2. 从最新的 `OpenAI.Codex` Appx 包复制 `app.asar`；
3. 校验 ChatGPT 品牌、ASAR 版本和 Electron 版本；
4. 应用最新版 Windows webview/bridge patch；
5. 构建浏览器和服务器代码。

构建前请关闭旧的 codex-web 服务。Windows 不允许替换正在被 Node 使用的
`better_sqlite3.node`。

## 启动

本机或 Tailscale 访问：

```text
start-codex-web.bat
```

默认本机地址是 <http://127.0.0.1:8214/>。BAT 依赖同目录下的
`start-codex-web.ps1`，两者都要保留。

临时 Cloudflare Quick Tunnel：

```text
start-codex-web-cloudflare.bat
```

它依赖 `start-codex-web-cloudflare.ps1`，并把临时地址写入
`cloudflare-url.txt`。

拿到 Cloudflare 地址的人可以用当前 Windows 用户权限操作 Codex。不要公开这个
地址；长期使用建议选择 Tailscale、WireGuard、SSH tunnel，或带认证的反向代理。

## 高级选项

指定一个已安装的 Appx 版本：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-windows.ps1 `
  -AppVersion 26.707.3563.0
```

找不到指定版本时会直接失败，不会偷偷回退到其他版本。

指定一个独立的 `app.asar`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-windows.ps1 `
  -AppAsarPath C:\path\to\app.asar
```

指定 Codex CLI：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-codex-web.ps1 `
  -CodexPath C:\path\to\codex.exe
```

启动脚本默认先查找 `%LOCALAPPDATA%\OpenAI\Codex\bin\*\codex.exe`，再回退到
`PATH`。

## 更新

仓库或 Microsoft Store 应用更新后，都要停止旧服务并重新运行：

```powershell
git pull
.\setup-windows.bat
```

如果 patch 报告匹配数为 0 或大于 1，说明新版 desktop bundle 已变化。正确做法是
参考上游最新 patch 重新定位 Windows 点位，而不是放宽校验或跳过补丁。

完整的版本边界、更新步骤和故障排查见 [WINDOWS_SETUP.md](./WINDOWS_SETUP.md)。

## 安全说明

任何能访问 Web UI 的人，都可能：

- 以运行 codex-web 的 Windows 用户身份执行命令；
- 读取或修改该用户可访问的文件和凭据；
- 使用本机已登录的 Codex/ChatGPT 账户并消耗额度。

不要把 codex-web 直接暴露到不可信网络，也不要删除或重置
`%USERPROFILE%\.codex`；那是用户状态，不是构建缓存。
