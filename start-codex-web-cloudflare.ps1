param(
  [int]$Port = 8214,
  [string]$CodexPath = "",
  [string]$CloudflaredPath = "",
  [switch]$ProbePublicUrl
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

function Resolve-CommandPath {
  param(
    [string]$ExplicitPath,
    [string[]]$Names,
    [string]$ErrorMessage
  )

  if ($ExplicitPath) {
    $resolved = Resolve-Path -LiteralPath $ExplicitPath -ErrorAction Stop
    return $resolved.ProviderPath
  }

  foreach ($name in $Names) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) {
      return $cmd.Source
    }
  }

  throw $ErrorMessage
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

function Quote-ProcessArgument {
  param([string]$Value)

  if ($Value -match '[\s"]') {
    return '"' + ($Value -replace '"', '\"') + '"'
  }

  return $Value
}

function Invoke-CurlCapture {
  param(
    [string]$CurlPath,
    [string[]]$Arguments
  )

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $CurlPath @Arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  return [pscustomobject]@{
    ExitCode = $exitCode
    Output = $output
  }
}

function Get-CloudflareApiProxy {
  foreach ($name in @("HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy")) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($value) {
      return $value
    }
  }

  try {
    $settings = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction Stop
    if ($settings.ProxyEnable -ne 1 -or -not $settings.ProxyServer) {
      return $null
    }

    $server = [string]$settings.ProxyServer
    if ($server -match '(?i)(?:https|http)=([^;]+)') {
      $server = $Matches[1]
    } elseif ($server -match '(?i)socks=([^;]+)') {
      $server = "socks5h://$($Matches[1])"
    }

    if ($server -match '^[a-z][a-z0-9+.-]*://') {
      return $server
    }

    return "http://$server"
  } catch {
    return $null
  }
}

function New-CloudflareQuickTunnel {
  param(
    [string]$Proxy,
    [string]$CurlPath
  )

  $curlArgs = @("--silent", "--show-error", "--max-time", "30")
  if ($Proxy) {
    $curlArgs += @("-x", $Proxy)
  }
  $curlArgs += @("-X", "POST", "https://api.trycloudflare.com/tunnel")

  $result = Invoke-CurlCapture -CurlPath $CurlPath -Arguments $curlArgs
  $raw = $result.Output.Trim()
  if ($result.ExitCode -ne 0) {
    throw "Failed to request a Cloudflare Quick Tunnel. curl exited with code $($result.ExitCode): $raw"
  }

  $response = $raw | ConvertFrom-Json
  if (-not $response.success) {
    throw "Cloudflare Quick Tunnel API returned an error: $raw"
  }

  return $response.result
}

function Test-CloudflareTunnelUrl {
  param(
    [string]$Url,
    [string]$Proxy,
    [string]$CurlPath
  )

  $curlArgs = @("--head", "--silent", "--show-error", "--max-time", "15")
  if ($Proxy) {
    $curlArgs += @("-x", $Proxy)
  }
  $curlArgs += $Url

  $result = Invoke-CurlCapture -CurlPath $CurlPath -Arguments $curlArgs
  $output = $result.Output.Trim()

  return [pscustomobject]@{
    Success = ($result.ExitCode -eq 0 -and $output -match 'HTTP/\S+\s+200\b')
    ExitCode = $result.ExitCode
    Output = $output
  }
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

function Get-AncestorProcessIds {
  param([int]$ProcessId)

  $ids = @()
  $current = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
  while ($current -and $current.ParentProcessId) {
    $parentId = [int]$current.ParentProcessId
    $ids += $parentId
    $current = Get-CimInstance Win32_Process -Filter "ProcessId = $parentId" -ErrorAction SilentlyContinue
  }

  return $ids
}

function Stop-ExistingListenersOnPort {
  param([int]$ListenPort)

  $listeners = @(Get-NetTCPConnection -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue)
  foreach ($listener in $listeners) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $($listener.OwningProcess)" -ErrorAction SilentlyContinue
    $commandLine = [string]$process.CommandLine
    Write-Host ("Port {0} is already used by PID {1}; stopping that process before starting codex-web." -f $ListenPort, $listener.OwningProcess)
    if ($commandLine) {
      Write-Host ("Existing command: {0}" -f $commandLine)
    }
    Stop-ProcessTree -ProcessId $listener.OwningProcess
    Start-Sleep -Milliseconds 700
  }

  $remainingListeners = @(Get-NetTCPConnection -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue)
  if ($remainingListeners.Count -gt 0) {
    $listener = $remainingListeners | Select-Object -First 1
    throw "Port $ListenPort is still in use by PID $($listener.OwningProcess) after attempting to stop it."
  }
}

function Stop-ExistingCloudflaredForProject {
  $processes = Get-ProjectCloudflaredProcesses

  foreach ($process in $processes) {
    Write-Host ("Stopping existing cloudflared for this project (PID {0})." -f $process.ProcessId)
    Stop-ProcessTree -ProcessId $process.ProcessId
    Start-Sleep -Milliseconds 300
  }
}

function Get-ProjectCloudflaredProcesses {
  $configPathPattern = [regex]::Escape((Join-Path $PSScriptRoot "scratch\cloudflared-codex-web.yml"))
  $credentialsPathPattern = [regex]::Escape((Join-Path $PSScriptRoot "scratch\quick-tunnel-credentials.json"))
  return @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq "cloudflared.exe" -and (
      [string]$_.CommandLine -match $configPathPattern -or
      [string]$_.CommandLine -match $credentialsPathPattern
    )
  })
}

function Get-ProjectCodexWebProcesses {
  param([int]$ListenPort)

  $projectPathPattern = [regex]::Escape($PSScriptRoot)
  return @(Get-CimInstance Win32_Process | Where-Object {
    [string]$_.CommandLine -match 'src[\\/]server[\\/]main\.js' -and
    [string]$_.CommandLine -match $projectPathPattern -and
    [string]$_.CommandLine -match "--port $ListenPort"
  })
}

function Get-CloudflaredForHostname {
  param([string]$Hostname)

  $hostnamePattern = [regex]::Escape($Hostname)
  return @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq "cloudflared.exe" -and [string]$_.CommandLine -match $hostnamePattern
  })
}

function Stop-ExistingScriptHostsForProject {
  $scriptPathPattern = [regex]::Escape((Join-Path $PSScriptRoot "start-codex-web-cloudflare.ps1"))
  $ancestorIds = @(Get-AncestorProcessIds -ProcessId $PID)
  $processes = @(Get-CimInstance Win32_Process | Where-Object {
    $_.ProcessId -ne $PID -and
    $ancestorIds -notcontains $_.ProcessId -and
    $_.Name -like "powershell*" -and
    [string]$_.CommandLine -match $scriptPathPattern
  })

  foreach ($process in $processes) {
    Write-Host ("Stopping existing codex-web Cloudflare script host (PID {0})." -f $process.ProcessId)
    Stop-ProcessTree -ProcessId $process.ProcessId
    Start-Sleep -Milliseconds 300
  }
}

function Show-ExistingInstance {
  param(
    [string]$UrlPath,
    [int]$ListenPort
  )

  Write-Host "codex-web Cloudflare tunnel is already running or starting."
  if (Test-Path -LiteralPath $UrlPath) {
    $url = (Get-Content -LiteralPath $UrlPath -Raw).Trim()
    if ($url) {
      Write-Host ("Cloudflare: {0}" -f $url)
    }
  } else {
    Write-Host "Cloudflare: URL is not ready yet."
  }

  foreach ($process in (Get-ProjectCodexWebProcesses -ListenPort $ListenPort)) {
    Write-Host ("codex-web PID: {0}" -f $process.ProcessId)
  }
  foreach ($process in (Get-ProjectCloudflaredProcesses)) {
    Write-Host ("cloudflared PID: {0}" -f $process.ProcessId)
  }
}

function Wait-ForLocalServer {
  param(
    [int]$ListenPort,
    [int]$TimeoutSeconds = 30
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $listener = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue
    if ($listener) {
      try {
        $response = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/" -f $ListenPort) -UseBasicParsing -TimeoutSec 3
        if ($response.StatusCode -eq 200) {
          return
        }
      } catch {
        # Listener exists but the HTTP app is still starting.
      }
    }
    Start-Sleep -Milliseconds 500
  }

  throw "Timed out waiting for codex-web on http://127.0.0.1:$ListenPort/."
}

Ensure-CodexWebBuild

$codexExe = Resolve-CodexCliPath -ExplicitPath $CodexPath

$cloudflaredExe = Resolve-CommandPath `
  -ExplicitPath $CloudflaredPath `
  -Names @("cloudflared.exe", "cloudflared") `
  -ErrorMessage "Could not find cloudflared on PATH. Install Cloudflare Tunnel or pass -CloudflaredPath C:\path\to\cloudflared.exe."

$curlExe = Resolve-CommandPath `
  -ExplicitPath "" `
  -Names @("curl.exe") `
  -ErrorMessage "Could not find curl.exe on PATH. Windows 10/11 normally includes it."

$serverProcess = $null
$tunnelProcess = $null
$script:tunnelUrl = $null
$script:currentTunnelHostname = $null
$scratchPath = Join-Path $PSScriptRoot "scratch"
$tunnelUrlPath = Join-Path $PSScriptRoot "cloudflare-url.txt"
$tunnelConfigPath = Join-Path $scratchPath "cloudflared-codex-web.yml"
$tunnelCredentialsPath = Join-Path $scratchPath "quick-tunnel-credentials.json"
$lockHashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($PSScriptRoot.ToLowerInvariant()))
$lockHash = -join ($lockHashBytes | ForEach-Object { $_.ToString("x2") })
$mutexName = "Global\codex-web-cloudflare-$lockHash"
$mutex = [System.Threading.Mutex]::new($false, $mutexName)
$hasMutex = $false

try {
  $hasMutex = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
  $hasMutex = $true
}

if (-not $hasMutex) {
  Show-ExistingInstance -UrlPath $tunnelUrlPath -ListenPort $Port
  $mutex.Dispose()
  exit 0
}

try {
  Stop-ExistingScriptHostsForProject
  Stop-ExistingCloudflaredForProject
  Stop-ExistingListenersOnPort -ListenPort $Port
  Stop-ExistingCloudflaredForProject
  New-Item -ItemType Directory -Force -Path $scratchPath | Out-Null
  Remove-Item -LiteralPath $tunnelUrlPath -Force -ErrorAction SilentlyContinue

  $env:CODEX_CLI_PATH = $codexExe
  Write-Host "Using Codex CLI: $env:CODEX_CLI_PATH"
  Write-Host "Using cloudflared: $cloudflaredExe"
  Write-Host "Starting codex-web on http://127.0.0.1:$Port/ ..."

  $serverProcess = Start-Process `
    -FilePath "node.exe" `
    -ArgumentList @(".\src\server\main.js", "--host", "127.0.0.1", "--port", "$Port") `
    -WorkingDirectory $PSScriptRoot `
    -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $PSScriptRoot "codex-web.stdout.log") `
    -RedirectStandardError (Join-Path $PSScriptRoot "codex-web.stderr.log") `
    -PassThru

  Wait-ForLocalServer -ListenPort $Port

  Write-Host ""
  Write-Host "Local:      http://127.0.0.1:$Port/"
  Write-Host "Requesting Cloudflare Quick Tunnel..."
  Write-Host ""
  Write-Host "Security: anyone with the Cloudflare URL can operate this Codex instance."
  Write-Host "Close this window to stop the tunnel and the local codex-web process."
  Write-Host ""

  $apiProxy = Get-CloudflareApiProxy
  if ($apiProxy) {
    Write-Host "Cloudflare API proxy: $apiProxy"
  }

  $quickTunnel = New-CloudflareQuickTunnel -Proxy $apiProxy -CurlPath $curlExe
  $script:currentTunnelHostname = $quickTunnel.hostname
  $script:tunnelUrl = "https://$($quickTunnel.hostname)"
  Set-Content -LiteralPath $tunnelUrlPath -Value $script:tunnelUrl -Encoding ascii

  @"
ingress:
  - service: http://127.0.0.1:$Port
"@ | Set-Content -LiteralPath $tunnelConfigPath -Encoding ascii

  $credentials = [ordered]@{
    AccountTag = $quickTunnel.account_tag
    TunnelID = $quickTunnel.id
    TunnelSecret = $quickTunnel.secret
  }
  $credentials | ConvertTo-Json | Set-Content -LiteralPath $tunnelCredentialsPath -Encoding ascii

  Write-Host ("Cloudflare: {0}" -f $script:tunnelUrl)
  Write-Host ("Saved URL:  {0}" -f $tunnelUrlPath)
  Write-Host ""
  Write-Host "Starting cloudflared connector..."
  Write-Host ""

  if ($ProbePublicUrl) {
    Write-Host "Public probe is skipped until cloudflared is running in this foreground window."
    Write-Host ""
  }

  Write-Host "Tunnel is running. Keep this window open while using codex-web."
  Write-Host "Press Ctrl+C or close this window to stop it."
  Write-Host ""

  $cloudflaredArgs = @(
    "--config"
    $tunnelConfigPath
    "tunnel"
    "--credentials-file"
    $tunnelCredentialsPath
    "--url"
    "http://127.0.0.1:$Port"
    "--hostname"
    $quickTunnel.hostname
    "--no-autoupdate"
    "run"
    $quickTunnel.id
  )

  & $cloudflaredExe @cloudflaredArgs
  $cloudflaredExitCode = $LASTEXITCODE
  if ($cloudflaredExitCode -ne 0) {
    throw "cloudflared exited with code $cloudflaredExitCode."
  }
} finally {
  if ($script:currentTunnelHostname) {
    foreach ($process in (Get-CloudflaredForHostname -Hostname $script:currentTunnelHostname)) {
      Stop-ProcessTree -ProcessId $process.ProcessId
    }
  }
  if ($tunnelProcess -and -not $tunnelProcess.HasExited) {
    Stop-ProcessTree -ProcessId $tunnelProcess.Id
  }
  if ($serverProcess -and -not $serverProcess.HasExited) {
    Stop-ProcessTree -ProcessId $serverProcess.Id
  }
  if ($hasMutex) {
    $mutex.ReleaseMutex()
  }
  $mutex.Dispose()
}
