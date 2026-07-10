# Windows setup

This fork runs the Codex workspace from the ChatGPT Desktop bundle in a normal
web browser. It tracks [0xcaff/codex-web](https://github.com/0xcaff/codex-web)
and ports each upstream macOS patch to the equivalent Windows bundle location.

## Desktop package identity

After the ChatGPT integration, the current Microsoft Store package still uses
the technical identity `OpenAI.Codex`. Its manifest displays `ChatGPT`, its
executable is `app\ChatGPT.exe`, and the embedded ASAR declares
`codexAppBrand: "chatgpt"`.

These versions are different and should not be mixed:

| Layer                          | Current validated value      |
| ------------------------------ | ---------------------------- |
| Store/Appx package             | `OpenAI.Codex 26.707.3563.0` |
| Embedded ASAR                  | `26.707.31123`               |
| Electron                       | `42.1.0`                     |
| Upstream macOS patch reference | `26.707.30751` (`28b9a81`)   |

The setup script selects the newest installed Appx package by default, extracts
its `package.json`, and requires `codexAppBrand=chatgpt`. It passes the ASAR
version—not the Appx version—to the Windows patcher.

## Requirements

- Windows 10 or 11.
- The latest ChatGPT-branded Codex workspace app from Microsoft Store.
- Node.js 22 or newer with npm.
- A signed-in Codex CLI. The launcher checks
  `%LOCALAPPDATA%\OpenAI\Codex\bin\*\codex.exe` before falling back to `PATH`.
- Optional: Tailscale for private remote access.
- Optional: `cloudflared.exe` for the Quick Tunnel launcher.

Git for Windows is useful for cloning the repository, but `patch.exe` is no
longer part of the Windows build path.

## Build

From a fresh clone, run:

```powershell
git clone https://github.com/Yiruma96/codex-web.git
cd codex-web
.\setup-windows.bat
```

The batch file invokes `setup-windows.ps1`, which:

1. installs npm dependencies without running the Unix-only `prepare` hook;
2. rebuilds `better-sqlite3` for the local Node.js runtime;
3. finds and copies the installed desktop `app.asar`;
4. extracts only the files required by codex-web;
5. validates the ChatGPT brand and records Appx, ASAR, and Electron versions;
6. applies the Windows equivalents of the current upstream patch set;
7. builds the browser preload and Node server.

Close any running codex-web server before rebuilding. A running server keeps
`better_sqlite3.node` open and Windows will correctly refuse to replace it.

To select an exact installed Appx version:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-windows.ps1 `
  -AppVersion 26.707.3563.0
```

If that version is not installed, setup fails instead of silently using a
different build.

To test a copied ASAR directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-windows.ps1 `
  -AppAsarPath C:\path\to\app.asar
```

An explicit ASAR must still declare `codexAppBrand=chatgpt`.

## Start

For local access, or private access over Tailscale, double-click:

```text
start-codex-web.bat
```

The default local URL is <http://127.0.0.1:8214/>. The paired PowerShell entry
point is:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-codex-web.ps1 `
  -PreferTailscale
```

The `.bat` file depends on `start-codex-web.ps1`; keep both files together.

For an ephemeral Cloudflare Quick Tunnel, double-click:

```text
start-codex-web-cloudflare.bat
```

Its paired script is `start-codex-web-cloudflare.ps1`. It writes the current
temporary URL to `cloudflare-url.txt` and cleans up the project server and
tunnel when the window closes.

Anyone who receives a working Cloudflare URL can operate Codex with the
permissions of your Windows account. Do not publish the URL. Prefer Tailscale,
WireGuard, an SSH tunnel, or an authenticated reverse proxy for regular use.

## Updating

The desktop webview is compiled and its chunk names change between releases.
After either this repository or the Microsoft Store app updates:

1. stop the running codex-web server;
2. pull the repository update;
3. rerun `setup-windows.bat`;
4. confirm the Appx, ASAR, brand, and Electron values printed by setup;
5. test a new task, an existing task, prompt prefill, and file selection.

The Windows patcher fails when a semantic anchor is missing or ambiguous. That
is intentional: a successful build must not silently skip a desktop change.
For the next upgrade, compare both:

- the latest commits and `patches/*.patch` in upstream `0xcaff/codex-web`;
- the previous Windows patcher and the latest known-good commit in this fork.

The current port maps upstream's ChatGPT/macOS changes to Windows semantic
chunks such as `app-main-*`, `composer-*`, `rpc-*`, and
`local-conversation-thread-*`; it does not reuse stale filename hashes.

## Generated files

Setup recreates these local artifacts:

```text
node_modules/
scratch/
src/server/**/*.js
src/server/**/*.d.ts
src/server/**/*.map
codex-web.*.log
cloudflare-url.txt
```

They are excluded from source control. Do not delete or reset
`%USERPROFILE%\.codex`; that directory contains the user's Codex state and is
not a build artifact.

## Troubleshooting

- `EBUSY` or `EPERM` for `better_sqlite3.node`: close the existing codex-web
  server, then rerun setup.
- `codexAppBrand` is not `chatgpt`: the selected ASAR is from the old desktop
  generation; update the Store app or provide the correct ASAR.
- A patch reports zero or multiple matches: the desktop bundle changed. Port
  the corresponding newest upstream patch to the new Windows chunk; do not
  weaken the match count check.
- `Could not find a runnable codex CLI`: install/sign in to the desktop runtime,
  put `codex` on `PATH`, or pass `-CodexPath` to a start PowerShell script.
- PowerShell profile `PSSecurityException` messages are unrelated startup noise
  when the actual command succeeds. The provided batch files use `-NoProfile`.
