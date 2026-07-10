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
  if ($LASTEXITCODE -ne 0) {
    throw "Windows setup failed with exit code $LASTEXITCODE."
  }
  if (-not (Test-Path -LiteralPath $serverEntry) -or -not (Test-Path -LiteralPath $webviewEntry)) {
    throw "Windows setup completed without producing the required codex-web build outputs."
  }
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

function Get-CodexCliCandidate {
  param([string]$Path)

  try {
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
    $resolvedPath = $resolved.ProviderPath
    $versionOutput = & $resolvedPath --version 2>$null | Select-Object -First 1
    if ($LASTEXITCODE -ne 0) {
      return $null
    }

    $versionText = "0.0.0"
    if ([string]$versionOutput -match 'codex-cli\s+([0-9]+(?:\.[0-9]+)+)') {
      $versionText = $Matches[1]
    }

    $item = Get-Item -LiteralPath $resolvedPath
    return [pscustomobject]@{
      Path = $resolvedPath
      Version = [version]$versionText
      VersionText = $versionText
      LastWriteTimeUtc = $item.LastWriteTimeUtc
    }
  } catch {
    return $null
  }
}

function Resolve-CodexCliPath {
  param([string]$ExplicitPath)

  if ($ExplicitPath) {
    return (Resolve-Path -LiteralPath $ExplicitPath -ErrorAction Stop).ProviderPath
  }

  $candidatePaths = New-Object System.Collections.Generic.List[string]
  $localRuntimeBin = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
  if (Test-Path -LiteralPath $localRuntimeBin) {
    foreach ($runtime in Get-ChildItem -LiteralPath $localRuntimeBin -Directory -ErrorAction SilentlyContinue) {
      $candidate = Join-Path $runtime.FullName "codex.exe"
      if (Test-Path -LiteralPath $candidate) {
        $candidatePaths.Add($candidate)
      }
    }
  }

  foreach ($name in @("codex.exe", "codex")) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) {
      $candidatePaths.Add($cmd.Source)
    }
  }

  $candidates = @(
    $candidatePaths |
      Select-Object -Unique |
      ForEach-Object { Get-CodexCliCandidate -Path $_ } |
      Where-Object { $_ -ne $null }
  )

  if ($candidates.Count -eq 0) {
    throw "Could not find a runnable codex CLI. Re-run with -CodexPath C:\path\to\codex.exe."
  }

  $selected = $candidates |
    Sort-Object -Property @{ Expression = "Version"; Descending = $true }, @{ Expression = "LastWriteTimeUtc"; Descending = $true } |
    Select-Object -First 1

  Write-Host ("Detected Codex CLI version: {0}" -f $selected.VersionText)
  return $selected.Path
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

function Get-PortListener {
  param([int]$ListenPort)

  return Get-NetTCPConnection -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
}

function Get-ProcessCommandLineById {
  param([int]$ProcessId)

  $process = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
  return [string]$process.CommandLine
}

function Get-ChildProcessIds {
  param([int]$ProcessId)

  $children = @(Get-CimInstance Win32_Process | Where-Object { $_.ParentProcessId -eq $ProcessId })
  foreach ($child in $children) {
    Get-ChildProcessIds -ProcessId $child.ProcessId
    $child.ProcessId
  }
}

function Stop-ProcessTree {
  param([int]$ProcessId)

  $ids = @((Get-ChildProcessIds -ProcessId $ProcessId) + $ProcessId)
  $seen = @{}
  foreach ($id in $ids) {
    if ($seen.ContainsKey($id)) {
      continue
    }
    $seen[$id] = $true
    Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
  }
}

function Stop-ExistingListenersOnPort {
  param([int]$ListenPort)

  $listeners = @(Get-NetTCPConnection -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue)
  foreach ($listener in $listeners) {
    $commandLine = Get-ProcessCommandLineById -ProcessId $listener.OwningProcess
    Write-Host ("Port {0} is already used by PID {1}; stopping that process before starting codex-web." -f $ListenPort, $listener.OwningProcess)
    if ($commandLine) {
      Write-Host ("Existing command: {0}" -f $commandLine)
    }
    Stop-ProcessTree -ProcessId $listener.OwningProcess
    Start-Sleep -Milliseconds 700
  }
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

Stop-ExistingListenersOnPort -ListenPort $Port
$existingListeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
if ($existingListeners.Count -gt 0) {
  $listener = $existingListeners | Select-Object -First 1
  throw "Port $Port is still in use by PID $($listener.OwningProcess) after attempting to stop it."
}

$CodexPath = Resolve-CodexCliPath -ExplicitPath $CodexPath
$env:CODEX_CLI_PATH = $CodexPath

Write-Host "Using Codex CLI: $env:CODEX_CLI_PATH"
Write-Host ("Listening on {0}:{1}" -f $HostName, $Port)
Show-CodexWebLinks -ListenHost $HostName -ListenPort $Port -TailscaleInfo $tailscaleInfo

node .\src\server\main.js --host $HostName --port $Port
