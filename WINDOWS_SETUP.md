# Windows setup notes

This repo is `codex-web`, a browser wrapper around Codex Desktop's webview and
main-process bridge. The upstream one-shot `npx --yes github:0xcaff/codex-web`
path is Unix-oriented. On Windows, use the notes below instead.

Current local checkout:

```text
D:\codex-web
```

Current known-good shape:

```text
Browser UI                  http://127.0.0.1:8214/
codex-web server            node src/server/main.js
Codex CLI/app-server        C:\Users\a2108\AppData\Local\Programs\OpenAI\Codex\bin\codex.exe
Codex shared state          C:\Users\a2108\.codex
Pinned Desktop web assets   Codex-darwin-arm64-26.513.20950.zip
```

## Fresh clone quick start

Clone the repository, then double-click:

```text
setup-windows.bat
```

This installs dependencies, downloads the pinned Codex Desktop app bundle,
extracts only the files codex-web needs, applies the web patches, and builds the
browser/server bundles. After setup, use one of the start scripts below.

The start scripts also auto-run `setup-windows.ps1` when build outputs are
missing, so a direct double-click on a start script can recover a fresh checkout
as long as Node.js, Git for Windows, and network access are available.

Generated runtime/build artifacts are intentionally not committed:

```text
node_modules/                         about 138 MB locally
scratch/                              about 475 MB locally
scratch/asar/                         about 145 MB locally
scratch/Codex-darwin-arm64-*.zip      about 330 MB locally
Codex.app/                            about 141 MB locally when extracted at repo root
src/server/*.js/*.d.ts/*.map          small, rebuilt by setup
cloudflare-url.txt                    per-run secret-ish temporary URL
codex-web.*.log                       local logs
```

For a true no-build distribution, create a GitHub Release zip instead of
committing those files to git history.

## Start the existing local build

For normal use, double-click:

```text
D:\codex-web\start-codex-web.bat
```

The batch file starts codex-web in a black console window and prints the links
you can use. It does not open a browser automatically. If the batch file starts
the server, keep that window open while using codex-web. If codex-web is already
running, it only prints the links and waits for a keypress.

When Tailscale is running, the batch file prefers the Tailscale IP so another
trusted device in your tailnet can open a link like:

```text
http://100.114.14.30:8214/
http://yiruma.taile610ba.ts.net:8214/
```

From PowerShell:

```powershell
cd D:\codex-web
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-codex-web.ps1 -PreferTailscale
```

Then open:

```text
http://127.0.0.1:8214/
```

The script auto-detects `codex.exe` from `PATH` and sets `CODEX_CLI_PATH`.
Override it when needed:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-codex-web.ps1 `
  -CodexPath "C:\Users\a2108\AppData\Local\Programs\OpenAI\Codex\bin\codex.exe"
```

## Start with Cloudflare Tunnel

Use this when you want to open codex-web from a phone or another device without
joining the same Tailscale tailnet.

Double-click:

```text
D:\codex-web\start-codex-web-cloudflare.bat
```

The batch file starts codex-web on local loopback only:

```text
http://127.0.0.1:8214/
```

Then it starts a Cloudflare Quick Tunnel and prints a temporary public URL like:

```text
https://example-name.trycloudflare.com
```

The same URL is also written to:

```text
D:\codex-web\cloudflare-url.txt
```

Keep the black console window open while using the Cloudflare URL. Closing it
stops both the tunnel and the local codex-web process. Quick Tunnel URLs are
ephemeral, so expect a new URL each time you restart the script.

The startup script is guarded by a Windows named mutex. If you double-click the
batch file multiple times, the first window owns the running tunnel and later
windows only print the existing URL/process IDs. They do not create additional
Cloudflare tunnels. If the window was closed in a way that left orphaned
`cloudflared` or `node.exe` processes, the next successful startup cleans this
project's old tunnel processes before creating a fresh one.

`cloudflared` runs in the foreground of the black console window. This is
intentional: the window lifetime is the tunnel lifetime, and it makes repeated
clicks and shutdown behavior easier to reason about.

On this Windows machine, direct access to `api.trycloudflare.com` may time out,
while the configured Windows user proxy works. The script therefore detects the
current user proxy, such as `127.0.0.1:7893`, and uses it only to request the
Quick Tunnel URL. The actual `cloudflared` connector still runs normally.

The script also writes an isolated Cloudflare config under `scratch/` so it does
not accidentally load `C:\Users\a2108\.cloudflared\config.yml`. This matters if
that default config has an existing named tunnel or ingress rules.

Optional public probe from PowerShell:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-codex-web-cloudflare.ps1 -ProbePublicUrl
```

If the URL works from the PC but not from the phone, the remaining issue is
usually the phone network's DNS/proxy path for `*.trycloudflare.com`, not
codex-web itself. Try mobile VPN/private DNS, or move to a named Cloudflare
tunnel on a custom domain.

Security note: anyone who has the Cloudflare URL can operate this Codex instance
as this Windows user. Do not post the URL publicly.

## What is running

This setup does not control the existing Codex Desktop window. It runs a
separate local web service:

```text
Browser
  -> codex-web Node/Fastify server
  -> fake Electron IPC bridge
  -> extracted old Codex Desktop main bundle
  -> local codex.exe app-server
```

The web version and the official Desktop app may share `C:\Users\a2108\.codex`,
so login state and transcript files can eventually line up after a restart or
refresh. They are not the same app-server process.

## Fresh Windows build

Use this when recloning or rebuilding after upstream changes.

```powershell
cd D:\
git clone https://github.com/0xcaff/codex-web.git codex-web
cd D:\codex-web
```

Install dependencies without running the Unix `prepare` script:

```powershell
npm.cmd install --ignore-scripts
npm.cmd rebuild better-sqlite3
```

Download the pinned Codex Desktop app bundle:

```powershell
New-Item -ItemType Directory -Force scratch | Out-Null
Invoke-WebRequest `
  -Uri "https://persistent.oaistatic.com/codex-app-prod/Codex-darwin-arm64-26.513.20950.zip" `
  -OutFile "scratch\Codex-darwin-arm64-26.513.20950.zip"
Expand-Archive -LiteralPath "scratch\Codex-darwin-arm64-26.513.20950.zip" -DestinationPath "scratch" -Force
```

Extract only the files codex-web needs. Full `asar extract` can fail on Windows
when the archive references unpacked native files.

```powershell
node .\scripts\extract-needed-asar.mjs `
  --asar "scratch\Codex.app\Contents\Resources\app.asar" `
  --out "scratch\asar" `
  --force
```

If you extracted the zip to the repo root instead of `scratch`, use:

```powershell
node .\scripts\extract-needed-asar.mjs `
  --asar "Codex.app\Contents\Resources\app.asar" `
  --out "scratch\asar" `
  --force
```

Copy the codex-web assets into the extracted webview:

```powershell
Copy-Item -LiteralPath .\assets\* -Destination .\scratch\asar\webview\ -Force
```

Generate the PWA icon:

```powershell
.\node_modules\.bin\sharp.cmd `
  -i "scratch\asar\webview\assets\app-D0g8sCle.png" `
  -o "scratch\asar\webview\assets\pwa-icon-512.png" `
  -f png resize 384 384 --fit inside -- flatten white `
  -- extend 64 64 64 64 --background white -- removeAlpha
```

Apply the patch set. If Git Bash or WSL is available, the upstream
`scripts/prepare_asar` patch commands are the reference. On pure PowerShell,
patching may need manual intervention when upstream Codex Desktop changes
bundle hashes or formatting. The patch target files are listed in `patches/`.

Build the browser and server bundles:

```powershell
npm.cmd run build:browser
npm.cmd run build:server
```

Start:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start-codex-web.ps1
```

## Updating this repo

Before updating, stop any running local service:

```powershell
Get-CimInstance Win32_Process |
  Where-Object { $_.CommandLine -match 'D:\\codex-web|src[\\/]server[\\/]main.js' } |
  Select-Object ProcessId,Name,CommandLine
```

Stop only the `node.exe` process that is running `D:\codex-web`.

Then:

```powershell
cd D:\codex-web
git status --short --branch
git pull --rebase
npm.cmd install --ignore-scripts
npm.cmd rebuild better-sqlite3
npm.cmd run build:browser
npm.cmd run build:server
```

If upstream changes the pinned Codex Desktop app version or patch files, rerun
the fresh build extraction steps above. Expect patch conflicts when the extracted
Desktop webview/main bundle changed significantly.

## Local generated files

These files are local build/runtime outputs and are not part of upstream source:

```text
scratch/
node_modules/
src/server/*.js
src/server/*.d.ts
src/server/*.map
src/server/electron/*.js
src/server/electron/*.d.ts
src/server/electron/*.map
codex-web.stdout.log
codex-web.stderr.log
cloudflare-url.txt
start-codex-web.ps1
start-codex-web.bat
start-codex-web-cloudflare.ps1
start-codex-web-cloudflare.bat
WINDOWS_SETUP.md
```

The repository `.gitignore` already ignores `scratch*`, `node_modules/`, and
`sentry`. Other generated files can remain untracked locally unless you decide
to maintain a Windows fork.

## Known Windows caveats

- `npm warn cleanup EPERM` during `npx` cleanup is usually not the real failure.
  The main issue is the Unix `prepare` script.
- PowerShell profile `PSSecurityException` noise is unrelated to codex-web.
  Running commands with `powershell -NoProfile` avoids it.
- The web UI uses an older extracted Codex Desktop webview/main bundle while the
  app-server is your local current `codex.exe`. Some new Desktop features may not
  work, and protocol warnings such as `expectedVersion=6` versus `version=8` can
  appear.
- Do not expose `127.0.0.1:8214` to untrusted networks. Anyone who can use this
  UI can operate Codex with this Windows user's permissions.
