param(
  [string]$HostName = "",
  [int]$Port = 8214,
  [string]$CodexPath = "",
  [switch]$PreferTailscale
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

function Ensure-CodexWebBuild {
  $serverEntry = Join-Path $PSScriptRoot "src\server\main.js"
  $webviewEntry = Join-Path $PSScriptRoot "scratch\asar\webview\index.html"
  if ((Test-Path -LiteralPath $serverEntry) -and (Test-Path -LiteralPath $webviewEntry)) {
    return
  }

  $setupScript = Join-Path $PSScriptRoot "setup-windows.ps1"
  if (-not (Test-Path -LiteralPath $setupScript)) {
    throw "Build outputs are missing and setup-windows.ps1 was not found."
  }

  Write-Host "codex-web build outputs are missing. Running Windows setup first..."
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupScript
}

function Get-TailscaleInfo {
  $info = [ordered]@{
    Available = $false
    IPv4 = $null
    DNSName = $null
    HostName = $null
  }

  $tailscale = Get-Command tailscale.exe -ErrorAction SilentlyContinue
  if (-not $tailscale) {
    $tailscale = Get-Command tailscale -ErrorAction SilentlyContinue
  }
  if (-not $tailscale) {
    return [pscustomobject]$info
  }

  try {
    $status = & $tailscale.Source status --json | ConvertFrom-Json
    $self = $status.Self
    if ($self) {
      $info.Available = [bool]$self.Online
      $info.HostName = $self.HostName
      if ($self.DNSName) {
        $info.DNSName = [string]$self.DNSName
        $info.DNSName = $info.DNSName.TrimEnd(".")
      }
      foreach ($ip in @($self.TailscaleIPs)) {
        if ($ip -match '^\d+\.\d+\.\d+\.\d+$') {
          $info.IPv4 = [string]$ip
          break
        }
      }
    }
  } catch {
    # Keep startup working even if tailscale is installed but unavailable.
  }

  return [pscustomobject]$info
}

function Show-CodexWebLinks {
  param(
    [string]$ListenHost,
    [int]$ListenPort,
    [object]$TailscaleInfo
  )

  Write-Host ""
  Write-Host "codex-web links"
  Write-Host "---------------"

  if ($ListenHost -eq "127.0.0.1" -or $ListenHost -eq "localhost" -or $ListenHost -eq "0.0.0.0") {
    Write-Host ("Local:     http://127.0.0.1:{0}/" -f $ListenPort)
  }

  if ($TailscaleInfo.Available -and $TailscaleInfo.IPv4) {
    if ($ListenHost -eq $TailscaleInfo.IPv4 -or $ListenHost -eq "0.0.0.0") {
      Write-Host ("Tailnet:   http://{0}:{1}/" -f $TailscaleInfo.IPv4, $ListenPort)
      if ($TailscaleInfo.DNSName) {
        Write-Host ("MagicDNS:  http://{0}:{1}/" -f $TailscaleInfo.DNSName, $ListenPort)
      }
    } else {
      Write-Host ("Tailnet:   Tailscale is online as {0}, but this server is listening on {1}." -f $TailscaleInfo.IPv4, $ListenHost)
      Write-Host "           Restart with -PreferTailscale to expose it inside your tailnet."
    }
  } else {
    Write-Host "Tailnet:   Tailscale address was not detected."
  }

  Write-Host ""
  Write-Host "If this window started the server, keep it open while using codex-web."
  Write-Host "Only use the Tailnet link from devices you trust."
  Write-Host ""
}

Ensure-CodexWebBuild

$tailscaleInfo = Get-TailscaleInfo
if (-not $HostName) {
  if ($PreferTailscale -and $tailscaleInfo.Available -and $tailscaleInfo.IPv4) {
    $HostName = $tailscaleInfo.IPv4
  } else {
    $HostName = "127.0.0.1"
  }
}

$existingListeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
if ($existingListeners.Count -gt 0) {
  $listener = $existingListeners | Select-Object -First 1
  Write-Host ("codex-web already appears to be running on {0}:{1} (PID {2})." -f $listener.LocalAddress, $listener.LocalPort, $listener.OwningProcess)
  Show-CodexWebLinks -ListenHost $listener.LocalAddress -ListenPort $Port -TailscaleInfo $tailscaleInfo
  exit 0
}

if (-not $CodexPath) {
  $cmd = Get-Command codex.exe -ErrorAction SilentlyContinue
  if (-not $cmd) {
    $cmd = Get-Command codex -ErrorAction SilentlyContinue
  }

  if (-not $cmd) {
    throw "Could not find codex on PATH. Re-run with -CodexPath C:\path\to\codex.exe."
  }

  $CodexPath = $cmd.Source
}

$env:CODEX_CLI_PATH = $CodexPath

Write-Host "Using Codex CLI: $env:CODEX_CLI_PATH"
Write-Host ("Listening on {0}:{1}" -f $HostName, $Port)
Show-CodexWebLinks -ListenHost $HostName -ListenPort $Port -TailscaleInfo $tailscaleInfo

node .\src\server\main.js --host $HostName --port $Port
