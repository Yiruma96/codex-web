@echo off
setlocal

cd /d "%~dp0"

rem Recommended company-network path:
rem browser -> Cloudflare -> Tencent cloudflared -> FRP -> local WSS server.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-codex-web-via-tencent.ps1" -Port 8215 -PublicUrl "https://lines-convert-mining-artwork.trycloudflare.com/" -PublicLabel "Cloudflare"

if errorlevel 1 (
  echo.
  echo codex-web Tencent plus Cloudflare tunnel exited with an error.
)

echo.
echo Press any key to close this window.
pause >nul
