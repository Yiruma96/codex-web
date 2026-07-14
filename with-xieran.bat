@echo off
setlocal

cd /d "%~dp0"

rem Alternate personal/mobile path:
rem browser -> codex.xieran.top -> Tencent nginx -> FRP -> local WSS server.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-codex-web-via-tencent.ps1" -Port 8214 -PublicUrl "https://codex.xieran.top/" -PublicLabel "xieran.top"

if errorlevel 1 (
  echo.
  echo codex-web xieran.top tunnel exited with an error.
)

echo.
echo Press any key to close this window.
pause >nul
