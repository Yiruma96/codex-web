# codex-web

A browser frontend for Codex Desktop, running on a Windows machine you control.

This fork is based on [0xcaff/codex-web](https://github.com/0xcaff/codex-web)
and focuses on making the project usable on Windows with the current Codex
Desktop web UI.

## What is different in this fork

- Windows support: setup copies `app.asar` from the installed Microsoft Store
  Codex Desktop package instead of relying on the upstream Unix/macOS prepare
  path.
- Current Codex Desktop UI: this fork is tested against the Windows package
  `OpenAI.Codex_26.623.19656.0` with internal app resources based on
  `26.623.141536`.
- One-click Windows launchers:
  - `setup-windows.bat`
  - `start-codex-web.bat`
  - `start-codex-web-cloudflare.bat`
- Cloudflare Quick Tunnel support for temporary remote access from a phone or
  another browser.
- Runtime selection that prefers the newest runnable local Codex CLI under
  `%LOCALAPPDATA%\OpenAI\Codex\bin\*\codex.exe`, then falls back to `PATH`.

The goal is still to stay thin: `codex-web` serves the patched Desktop webview
and bridges it to the local Codex app server. Your files, credentials, and
Codex state remain on the host machine.

## Security model

Treat `codex-web` as remote control for your Windows user account.

Anyone who can reach the web UI can potentially:

- ask Codex to run commands as the user running `codex-web`;
- read or modify files that user can access;
- use the Codex or ChatGPT account already signed in on that machine;
- consume usage quota or billing credits.

Do not expose this directly to an untrusted network. If you use the Cloudflare
launcher, the generated `trycloudflare.com` URL is effectively a temporary
public control URL. Do not post it publicly.

For safer long-term access, put your own authentication layer in front of it, or
use a private network such as Tailscale, WireGuard, or an SSH tunnel.

## Windows quick start

### Prerequisites

Install these on the Windows host:

- Codex Desktop from Microsoft Store, launched at least once.
- Node.js and npm.
- Git for Windows. The setup script also needs `patch.exe`, which Git for
  Windows normally provides.
- Optional: `cloudflared.exe` on `PATH` if you want the Cloudflare launcher.

Make sure Codex is signed in before starting the web UI. Either sign in through
Codex Desktop, or run:

```powershell
codex login --device-auth
```

If `codex` is not on `PATH`, that is usually fine: the Windows launch scripts
also scan `%LOCALAPPDATA%\OpenAI\Codex\bin\*\codex.exe`.

### Clone and build

```powershell
cd D:\
git clone https://github.com/Yiruma96/codex-web.git
cd D:\codex-web
```

Then run setup:

```powershell
.\setup-windows.bat
```

Or run the PowerShell script directly:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-windows.ps1
```

The setup script will:

1. install npm dependencies;
2. find the installed Microsoft Store `OpenAI.Codex` package;
3. copy its `app.asar` into `scratch/`;
4. extract only the files needed by `codex-web`;
5. apply the webview and bridge patches;
6. build the browser and server bundles.

Generated files such as `node_modules/`, `scratch/`, server build outputs,
logs, and Cloudflare URLs are intentionally not committed.

For maintainer-oriented details and the longer Windows notes, see
[WINDOWS_SETUP.md](./WINDOWS_SETUP.md).

### Start locally or over Tailscale

Double-click:

```text
start-codex-web.bat
```

Or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-codex-web.ps1 -PreferTailscale
```

The script prints the URL to open. By default the service uses port `8214`.
Without Tailscale this is normally:

```text
http://127.0.0.1:8214/
```

With Tailscale running, the batch file prefers your Tailscale IP so another
trusted device in your tailnet can open the UI.

The Windows start scripts assume one active `codex-web` instance on port `8214`.
If something is already listening on that port, the script stops that process
tree before starting the new server.

### Start with Cloudflare Quick Tunnel

Install `cloudflared.exe` and make sure it is on `PATH`, then double-click:

```text
start-codex-web-cloudflare.bat
```

Or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-codex-web-cloudflare.ps1
```

This starts `codex-web` on local loopback and then starts a Cloudflare Quick
Tunnel. The script prints a temporary public URL like:

```text
https://example-name.trycloudflare.com
```

The same URL is also written to:

```text
cloudflare-url.txt
```

Keep the console window open while using the tunnel. Closing it stops both the
tunnel and the local `codex-web` process. Quick Tunnel URLs are ephemeral, so
expect a new URL each time you restart the launcher.

You can ask the script to probe the public URL after startup:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-codex-web-cloudflare.ps1 -ProbePublicUrl
```

## Ask Codex to deploy it for you

If you already have Codex running on the Windows machine, you can paste this
prompt into Codex and let it perform the setup:

```text
Set up codex-web on this Windows machine.

Repository: https://github.com/Yiruma96/codex-web.git
Target directory: D:\codex-web

Requirements:
- Do not delete or reset my existing %USERPROFILE%\.codex state.
- Verify Node.js, npm, Git for Windows, patch.exe, and the Microsoft Store
  OpenAI.Codex package are available.
- Clone or update the repository at D:\codex-web.
- Run setup-windows.ps1 with PowerShell using -NoProfile and
  -ExecutionPolicy Bypass.
- If setup succeeds, start codex-web locally with start-codex-web.ps1.
- If I ask for remote browser access, use start-codex-web-cloudflare.ps1, but
  warn me that anyone with the Cloudflare URL can control this Codex instance.
- Report the exact commands you ran, the Codex Desktop package version found,
  the Codex CLI version selected, and the final URL to open.
```

## Updating

Pull the latest repository changes, then rerun setup:

```powershell
cd D:\codex-web
git pull
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-windows.ps1
```

If Microsoft Store installs a newer Codex Desktop package and setup fails while
patching the webview, the upstream Desktop bundle likely changed. Open an issue
with the package version and the setup log.

## Advanced notes

### Override the Codex CLI

The launch scripts auto-detect Codex CLI candidates. To force a specific CLI:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-codex-web.ps1 `
  -CodexPath "C:\path\to\codex.exe"
```

### Build against a specific app.asar

If setup cannot locate the Microsoft Store package, or you want to test another
Desktop bundle:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\setup-windows.ps1 `
  -AppAsarPath "C:\path\to\app.asar"
```

### Unix and Nix path

The original upstream project supports Unix-style `npx` and Nix usage. This
fork keeps that path, but the Windows-supported route is the clone +
`setup-windows.ps1` flow above. On native Windows, do not use the upstream
one-shot `npx github:...` install path; its prepare script expects a Unix-like
toolchain.

## Troubleshooting

- `Could not find patch.exe`: install Git for Windows or add Git's `usr\bin`
  directory to `PATH`.
- `Could not find a runnable codex CLI`: install or launch Codex Desktop, or
  pass `-CodexPath`.
- Setup cannot find `OpenAI.Codex`: install/update Codex Desktop from Microsoft
  Store, launch it once, then rerun setup.
- Cloudflare URL works on the PC but not on the phone: check DNS, proxy, VPN,
  carrier filtering, or use a named Cloudflare tunnel/custom domain.
- Port `8214` is occupied: the Windows launcher will stop the current listener
  before starting. Close any old `codex-web` window first if you want to control
  that manually.

## Relationship to upstream

This is an unofficial fork of
[0xcaff/codex-web](https://github.com/0xcaff/codex-web). The main additional
work here is Windows packaging/setup and adapting the patched webview to the
current Windows Codex Desktop resources.

Issues and pull requests are welcome, especially for new Codex Desktop versions
that need patch updates.
