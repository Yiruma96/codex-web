param(
  [int]$Port = 8214,
  [string]$CodexPath = "",
  [string]$PublicUrl = "https://codex.xieran.top/",
  [string]$PublicLabel = "Public"
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
  Write-Host "codex-web build outputs are missing. Running Windows setup first..."
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $setupScript
  if ($LASTEXITCODE -ne 0) {
    throw "Windows setup failed with exit code $LASTEXITCODE."
  }
}

function Update-PreloadCacheVersion {
  $webviewRoot = Join-Path $PSScriptRoot "scratch\asar\webview"
  $indexPath = Join-Path $webviewRoot "index.html"
  $preloadPath = Join-Path $webviewRoot "assets\preload.js"
  if (-not (Test-Path -LiteralPath $indexPath) -or -not (Test-Path -LiteralPath $preloadPath)) {
    throw "Browser build outputs are incomplete; index.html or preload.js is missing."
  }

  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  $preloadStream = [System.IO.File]::OpenRead($preloadPath)
  try {
    $preloadHashBytes = $sha256.ComputeHash($preloadStream)
  } finally {
    $preloadStream.Dispose()
    $sha256.Dispose()
  }
  $preloadHash = (-join ($preloadHashBytes | ForEach-Object { $_.ToString("x2") })).Substring(0, 16)
  $indexHtml = [System.IO.File]::ReadAllText($indexPath)
  $versionedPreload = "assets/preload.js?v=$preloadHash"
  $updatedIndexHtml = [regex]::Replace(
    $indexHtml,
    'assets/preload\.js(?:\?v=[^"'']*)?',
    $versionedPreload
  )
  if ($updatedIndexHtml -eq $indexHtml -and $indexHtml -notmatch [regex]::Escape($versionedPreload)) {
    throw "Could not locate the preload.js script reference in index.html."
  }
  if ($updatedIndexHtml -ne $indexHtml) {
    $utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($indexPath, $updatedIndexHtml, $utf8WithoutBom)
    Write-Host ("Updated browser preload cache version: {0}." -f $preloadHash)
  }
}

function Get-CodexCliCandidate {
  param([string]$Path)

  try {
    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $global:LASTEXITCODE = 0
    $versionLines = @(& $resolvedPath --version 2>$null)
    $nativeExitCode = $LASTEXITCODE
    if ($nativeExitCode -ne 0) { return $null }
    $versionOutput = $versionLines | Select-Object -First 1
    $versionText = "0.0.0"
    if ([string]$versionOutput -match 'codex-cli\s+([0-9]+(?:\.[0-9]+)+)') {
      $versionText = $Matches[1]
    }
    $item = Get-Item -LiteralPath $resolvedPath
    $desktopRuntimeBin = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
    $installedCliRoot = Join-Path $env:LOCALAPPDATA "Programs\OpenAI\Codex\bin"
    $sourcePriority = 0
    if ($resolvedPath.StartsWith($desktopRuntimeBin + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
      $sourcePriority = 300
    } elseif ($resolvedPath.StartsWith($installedCliRoot + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
      $sourcePriority = 200
    } elseif ($resolvedPath -match '[\\/]\.vscode[\\/]extensions[\\/]') {
      $sourcePriority = 100
    }
    return [pscustomobject]@{
      Path = $resolvedPath
      Version = [version]$versionText
      VersionText = $versionText
      SourcePriority = $sourcePriority
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

  foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'codex.exe'" -ErrorAction SilentlyContinue)) {
    if ($process.ExecutablePath) {
      $candidatePaths.Add([string]$process.ExecutablePath)
    }
  }

  $runtimeBin = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
  if (Test-Path -LiteralPath $runtimeBin) {
    foreach ($candidate in @(Get-ChildItem -LiteralPath $runtimeBin -Filter "codex.exe" -File -Recurse -ErrorAction SilentlyContinue)) {
      $candidatePaths.Add($candidate.FullName)
    }
  }

  $installedCli = Join-Path $env:LOCALAPPDATA "Programs\OpenAI\Codex\bin\codex.exe"
  if (Test-Path -LiteralPath $installedCli) {
    $candidatePaths.Add($installedCli)
  }

  foreach ($name in @("codex.exe", "codex")) {
    foreach ($command in @(Get-Command $name -All -ErrorAction SilentlyContinue)) {
      $commandPath = if ($command.Path) { $command.Path } else { $command.Source }
      if ($commandPath) { $candidatePaths.Add([string]$commandPath) }
    }
  }

  $candidates = New-Object System.Collections.Generic.List[object]
  foreach ($candidatePath in @($candidatePaths | Select-Object -Unique)) {
    $candidate = Get-CodexCliCandidate -Path $candidatePath
    if ($candidate) { $candidates.Add($candidate) }
  }
  if ($candidates.Count -eq 0) {
    throw "Could not find a runnable codex CLI."
  }
  $selected = $candidates |
    Sort-Object -Property @{ Expression = "Version"; Descending = $true }, @{ Expression = "SourcePriority"; Descending = $true }, @{ Expression = "LastWriteTimeUtc"; Descending = $true } |
    Select-Object -First 1
  Write-Host ("Detected Codex CLI version: {0}" -f $selected.VersionText)
  return $selected.Path
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
    if (-not $seen.ContainsKey($id)) {
      $seen[$id] = $true
      Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
    }
  }
}

function Stop-ExistingListenersOnPort {
  param([int]$ListenPort)
  foreach ($listener in @(Get-NetTCPConnection -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue)) {
    Write-Host ("Stopping existing listener on port {0} (PID {1})." -f $ListenPort, $listener.OwningProcess)
    Stop-ProcessTree -ProcessId $listener.OwningProcess
    Start-Sleep -Milliseconds 700
  }
  if (Get-NetTCPConnection -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue) {
    throw "Port $ListenPort is still in use."
  }
}

function Stop-ExistingFrpcForProject {
  param([string]$FrpRoot)
  $pattern = [regex]::Escape($FrpRoot)
  foreach ($process in @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq "frpc.exe" -and [string]$_.CommandLine -match $pattern
  })) {
    Write-Host ("Stopping existing FRP client (PID {0})." -f $process.ProcessId)
    Stop-ProcessTree -ProcessId $process.ProcessId
  }
}

function Wait-ForLocalServer {
  param([int]$ListenPort, [int]$TimeoutSeconds = 30)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/" -f $ListenPort) -UseBasicParsing -TimeoutSec 3
      if ($response.StatusCode -eq 200) { return }
    } catch {
      Start-Sleep -Milliseconds 500
    }
  }
  throw "Timed out waiting for codex-web on port $ListenPort."
}

function Stop-ExistingCloudflareForProject {
  $projectPattern = [regex]::Escape($PSScriptRoot)
  foreach ($process in @(Get-CimInstance Win32_Process | Where-Object {
    $_.Name -eq "cloudflared.exe" -and [string]$_.CommandLine -match $projectPattern
  })) {
    Write-Host ("Stopping existing Cloudflare tunnel for this project (PID {0})." -f $process.ProcessId)
    Stop-ProcessTree -ProcessId $process.ProcessId
  }

  $scriptPattern = [regex]::Escape((Join-Path $PSScriptRoot "start-codex-web-cloudflare.ps1"))
  foreach ($process in @(Get-CimInstance Win32_Process | Where-Object {
    $_.ProcessId -ne $PID -and $_.Name -like "powershell*" -and [string]$_.CommandLine -match $scriptPattern
  })) {
    Write-Host ("Stopping existing Cloudflare launcher (PID {0})." -f $process.ProcessId)
    Stop-ProcessTree -ProcessId $process.ProcessId
  }
}

function Initialize-WebCodexHome {
  $sourceCodexHome = if ($env:CODEX_HOME) {
    [System.IO.Path]::GetFullPath($env:CODEX_HOME)
  } else {
    Join-Path $env:USERPROFILE ".codex"
  }
  $webCodexHome = Join-Path $env:USERPROFILE ".codex-web"
  $prepareScript = Join-Path $PSScriptRoot "scripts\prepare-web-codex-home.mjs"

  if (-not (Test-Path -LiteralPath $sourceCodexHome -PathType Container)) {
    throw "Codex home was not found: $sourceCodexHome"
  }
  if (-not (Test-Path -LiteralPath $prepareScript -PathType Leaf)) {
    throw "Web Codex home preparation script is missing: $prepareScript"
  }

  & node.exe $prepareScript --source $sourceCodexHome --target $webCodexHome
  if ($LASTEXITCODE -ne 0) {
    throw "Could not prepare the local-only Web Codex state directory."
  }

  $env:CODEX_HOME = $webCodexHome
  Write-Host "Codex Web execution target: local machine."
}

function Get-PhysicalDefaultRoute {
  $candidates = foreach ($route in @(Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction Stop)) {
    if (-not $route.NextHop -or $route.NextHop -eq "0.0.0.0") { continue }

    $adapter = Get-NetAdapter -InterfaceIndex $route.ifIndex -IncludeHidden -ErrorAction SilentlyContinue
    if (-not $adapter -or -not $adapter.HardwareInterface -or $adapter.Status -ne "Up") { continue }

    [pscustomobject]@{
      InterfaceIndex = [int]$route.ifIndex
      InterfaceAlias = [string]$route.InterfaceAlias
      NextHop = [string]$route.NextHop
      TotalMetric = [int]$route.RouteMetric + [int]$route.InterfaceMetric
    }
  }

  return $candidates | Sort-Object TotalMetric | Select-Object -First 1
}

function Ensure-DirectRoute {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [Parameter(Mandatory = $true)]
    [string]$RouteHelper
  )

  $physicalRoute = Get-PhysicalDefaultRoute
  if (-not $physicalRoute) {
    throw "Could not find an active physical network adapter with an IPv4 default gateway."
  }

  $destinationPrefix = "$Destination/32"
  $matchingRoute = @(
    Get-NetRoute -AddressFamily IPv4 -DestinationPrefix $destinationPrefix -ErrorAction SilentlyContinue |
      Where-Object {
        $_.ifIndex -eq $physicalRoute.InterfaceIndex -and
        $_.NextHop -eq $physicalRoute.NextHop
      }
  ) | Select-Object -First 1

  if (-not $matchingRoute) {
    Write-Host ("Adding direct route: {0} -> {1} via {2}." -f $Destination, $physicalRoute.InterfaceAlias, $physicalRoute.NextHop)
    Write-Host "Windows will ask for administrator approval to add this route."

    $elevationArguments = @(
      "-NoProfile"
      "-ExecutionPolicy"
      "Bypass"
      "-File"
      ('"{0}"' -f $RouteHelper)
      "-Destination"
      $Destination
      "-InterfaceIndex"
      [string]$physicalRoute.InterfaceIndex
      "-NextHop"
      $physicalRoute.NextHop
    )

    try {
      $routeProcess = Start-Process `
        -FilePath "powershell.exe" `
        -ArgumentList $elevationArguments `
        -Verb RunAs `
        -WindowStyle Hidden `
        -Wait `
        -PassThru
    } catch {
      throw "The direct route was not added. Administrator approval is required."
    }

    if ($routeProcess.ExitCode -ne 0) {
      throw "The elevated route helper exited with code $($routeProcess.ExitCode)."
    }
  }

  $selectedRoute = Find-NetRoute -RemoteIPAddress $Destination -ErrorAction Stop | Select-Object -First 1
  if ($selectedRoute.InterfaceIndex -ne $physicalRoute.InterfaceIndex) {
    throw "The route to $Destination is still using $($selectedRoute.InterfaceAlias), not $($physicalRoute.InterfaceAlias)."
  }

  Write-Host ("Direct route ready: {0} -> {1} via {2}." -f $Destination, $physicalRoute.InterfaceAlias, $physicalRoute.NextHop)
}

Ensure-CodexWebBuild
Update-PreloadCacheVersion

$frpRoot = Join-Path $PSScriptRoot "scratch\frp"
$frpcExe = Join-Path $frpRoot "frpc.exe"
$frpcConfig = Join-Path $frpRoot "frpc.toml"
$routeHelper = Join-Path $frpRoot "set-direct-route.ps1"
if (-not (Test-Path -LiteralPath $frpcExe)) {
  throw "FRP client is missing: $frpcExe"
}
if (-not (Test-Path -LiteralPath $frpcConfig)) {
  throw "FRP client configuration is missing: $frpcConfig"
}
if (-not (Test-Path -LiteralPath $routeHelper)) {
  throw "Direct route helper is missing: $routeHelper"
}

$cloudflareUrl = "https://lines-convert-mining-artwork.trycloudflare.com/"
Set-Content -LiteralPath (Join-Path $PSScriptRoot "cloudflare-url.txt") -Value $cloudflareUrl -Encoding ascii

$lockHashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($PSScriptRoot.ToLowerInvariant()))
$lockHash = -join ($lockHashBytes | ForEach-Object { $_.ToString("x2") })
$mutex = [System.Threading.Mutex]::new($false, "Global\codex-web-tencent-$lockHash")
$hasMutex = $false
$serverProcess = $null
try {
  try { $hasMutex = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $hasMutex = $true }
  if (-not $hasMutex) {
    $activePorts = @(
      8214, 8215 | Where-Object {
        Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $_ -State Listen -ErrorAction SilentlyContinue
      }
    )
    Write-Host "Another codex-web Tencent FRP launcher is already running."
    if ($activePorts.Count -gt 0) {
      Write-Host ("Active local port(s): {0}." -f ($activePorts -join ", "))
    }
    Write-Host "Close its window before switching public entry points."
    exit 2
  }

  Ensure-DirectRoute -Destination "43.153.184.34" -RouteHelper $routeHelper

  Stop-ExistingFrpcForProject -FrpRoot $frpRoot

  $codexExe = Resolve-CodexCliPath -ExplicitPath $CodexPath
  Initialize-WebCodexHome
  $env:CODEX_CLI_PATH = $codexExe
  Write-Host "Using Codex CLI: $codexExe"

  $existingServerHealthy = $false
  $existingListener = Get-NetTCPConnection -LocalAddress 127.0.0.1 -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  if ($existingListener) {
    try {
      $response = Invoke-WebRequest `
        -Uri ("http://127.0.0.1:{0}/" -f $Port) `
        -UseBasicParsing `
        -TimeoutSec 5
      $existingServerHealthy = $response.StatusCode -eq 200
    } catch {
      $existingServerHealthy = $false
    }
  }

  if ($existingServerHealthy) {
    Write-Host "Reusing the existing codex-web server on http://127.0.0.1:$Port/."
  } else {
    Stop-ExistingListenersOnPort -ListenPort $Port
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
  }
  & $frpcExe verify -c $frpcConfig
  if ($LASTEXITCODE -ne 0) { throw "FRP configuration validation failed." }

  Write-Host ""
  Write-Host "Tencent FRP tunnel"
  Write-Host "------------------"
  Write-Host "Local:     http://127.0.0.1:$Port/"
  Write-Host ("{0}: {1}" -f $PublicLabel, $PublicUrl)
  Write-Host "Transport: one persistent WebSocket at /__backend/ipc"
  Write-Host "Access:    public URL without an application password"
  Write-Host ""
  Write-Host "Keep this window open while using codex-web."
  Write-Host "Press Ctrl+C or close this window to stop the local server and tunnel."
  Write-Host ""

  & $frpcExe -c $frpcConfig
  if ($LASTEXITCODE -ne 0) { throw "frpc exited with code $LASTEXITCODE." }
} finally {
  if ($serverProcess -and -not $serverProcess.HasExited) {
    $cloudflarePattern = [regex]::Escape($PSScriptRoot)
    $cloudflareStillRunning = @(
      Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
          $_.Name -eq "cloudflared.exe" -and [string]$_.CommandLine -match $cloudflarePattern
        }
    ).Count -gt 0
    if ($cloudflareStillRunning) {
      Write-Host "Leaving the shared codex-web server running for the Cloudflare tunnel."
    } else {
      Stop-ProcessTree -ProcessId $serverProcess.Id
    }
  }
  if ($hasMutex) { $mutex.ReleaseMutex() }
  $mutex.Dispose()
}
