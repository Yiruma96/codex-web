param(
  [string]$AppVersion = "26.623.19656.0",
  [string]$AppAsarPath = "",
  [switch]$SkipInstall
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $PSScriptRoot

$setupLockHashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($PSScriptRoot.ToLowerInvariant()))
$setupLockHash = -join ($setupLockHashBytes | ForEach-Object { $_.ToString("x2") })
$setupMutex = [System.Threading.Mutex]::new($false, "Global\codex-web-setup-$setupLockHash")
$setupHasMutex = $false

try {
  $setupHasMutex = $setupMutex.WaitOne()
} catch [System.Threading.AbandonedMutexException] {
  $setupHasMutex = $true
}

function Resolve-RequiredCommand {
  param(
    [string[]]$Names,
    [string]$ErrorMessage
  )

  foreach ($name in $Names) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($command) {
      return $command.Source
    }
  }

  throw $ErrorMessage
}

function Resolve-PatchCommand {
  $command = Get-Command patch.exe -ErrorAction SilentlyContinue
  if ($command) {
    return $command.Source
  }

  $candidates = @(
    "C:\Program Files\Git\usr\bin\patch.exe",
    "C:\Program Files (x86)\Git\usr\bin\patch.exe",
    "C:\installation\Git\usr\bin\patch.exe"
  )

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate) {
      return $candidate
    }
  }

  throw "Could not find patch.exe. Install Git for Windows, then re-run setup-windows.bat."
}

function Get-PatchedFiles {
  $files = @{}
  foreach ($patchFile in Get-ChildItem -LiteralPath "patches" -Filter "*.patch" -File) {
    foreach ($match in Select-String -LiteralPath $patchFile.FullName -Pattern '^\+\+\+ b/(.+)$') {
      $relative = $match.Matches[0].Groups[1].Value
      $files[(Join-Path "scratch\asar" $relative)] = $true
    }
  }

  return @($files.Keys | Sort-Object)
}

function Invoke-Step {
  param(
    [string]$Name,
    [scriptblock]$Action
  )

  Write-Host ""
  Write-Host "== $Name =="
  & $Action
}

function Invoke-NativeCommand {
  param(
    [string]$FilePath,
    [string[]]$Arguments,
    [string]$Name
  )

  & $FilePath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "$Name failed with exit code $LASTEXITCODE."
  }
}

function Extract-ZipEntry {
  param(
    [string]$ZipPath,
    [string]$EntryName,
    [string]$DestinationPath
  )

  Add-Type -AssemblyName System.IO.Compression.FileSystem

  $resolvedZipPath = (Resolve-Path -LiteralPath $ZipPath).ProviderPath
  $resolvedDestination = [System.IO.Path]::GetFullPath((Join-Path $PWD $DestinationPath))
  New-Item -ItemType Directory -Force -Path ([System.IO.Path]::GetDirectoryName($resolvedDestination)) | Out-Null

  $zip = [System.IO.Compression.ZipFile]::OpenRead($resolvedZipPath)
  try {
    $entry = $zip.Entries | Where-Object { $_.FullName -eq $EntryName } | Select-Object -First 1
    if (-not $entry) {
      throw "Could not find $EntryName in $ZipPath."
    }
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $resolvedDestination, $true)
  } finally {
    $zip.Dispose()
  }
}

function Resolve-CodexDesktopAsar {
  param(
    [string]$RequestedVersion,
    [string]$ExplicitAsarPath
  )

  if ($ExplicitAsarPath) {
    if (-not (Test-Path -LiteralPath $ExplicitAsarPath)) {
      throw "Could not find app.asar at $ExplicitAsarPath."
    }

    return @{
      Version = $RequestedVersion
      Path = (Resolve-Path -LiteralPath $ExplicitAsarPath).ProviderPath
      Source = "explicit"
    }
  }

  $packages = @(Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue |
    Sort-Object { [version]$_.Version } -Descending)

  if ($RequestedVersion) {
    $requestedPackage = $packages | Where-Object { [string]$_.Version -eq $RequestedVersion } | Select-Object -First 1
    if ($requestedPackage) {
      $packages = @($requestedPackage) + @($packages | Where-Object { $_.PackageFullName -ne $requestedPackage.PackageFullName })
    }
  }

  foreach ($package in $packages) {
    $candidate = Join-Path $package.InstallLocation "app\resources\app.asar"
    if (Test-Path -LiteralPath $candidate) {
      return @{
        Version = [string]$package.Version
        Path = $candidate
        Source = $package.PackageFullName
      }
    }
  }

  throw "Could not find installed OpenAI.Codex app.asar. Install or update Codex Desktop from Microsoft Store, or pass -AppAsarPath C:\path\to\app.asar."
}

function Resolve-PwaSourceIcon {
  param([string]$AssetsPath)

  $preferred = Join-Path $AssetsPath "app-D0g8sCle.png"
  if (Test-Path -LiteralPath $preferred) {
    return $preferred
  }

  $fallback = Get-ChildItem -LiteralPath $AssetsPath -Filter "app-*.png" -File |
    Sort-Object Name |
    Select-Object -First 1

  if ($fallback) {
    return $fallback.FullName
  }

  throw "Could not find Codex app icon under $AssetsPath."
}

if (-not (Test-Path -LiteralPath "package.json")) {
  throw "Run this script from the codex-web repository root."
}

$node = Resolve-RequiredCommand -Names @("node.exe", "node") -ErrorMessage "Could not find Node.js. Install Node.js 22+ and re-run setup-windows.bat."
$npm = Resolve-RequiredCommand -Names @("npm.cmd", "npm") -ErrorMessage "Could not find npm. Install Node.js and re-run setup-windows.bat."
$patch = Resolve-PatchCommand
$codexDesktopAsar = Resolve-CodexDesktopAsar -RequestedVersion $AppVersion -ExplicitAsarPath $AppAsarPath
$AppVersion = $codexDesktopAsar.Version
$asarPath = "scratch\app-$AppVersion.asar"
$asarOut = "scratch\asar"

Write-Host "Using Node:  $node"
Write-Host "Using npm:   $npm"
Write-Host "Using patch: $patch"
Write-Host "Using Codex Desktop app.asar: $($codexDesktopAsar.Path)"
Write-Host "Codex Desktop package source: $($codexDesktopAsar.Source)"

if (-not $SkipInstall) {
  Invoke-Step "Install npm dependencies" {
    Invoke-NativeCommand -FilePath $npm -Arguments @("install", "--ignore-scripts") -Name "npm install"
  }

  Invoke-Step "Rebuild native modules" {
    Invoke-NativeCommand -FilePath $npm -Arguments @("rebuild", "better-sqlite3") -Name "npm rebuild better-sqlite3"
  }
}

Invoke-Step "Copy Codex Desktop app.asar" {
  New-Item -ItemType Directory -Force -Path "scratch" | Out-Null
  Copy-Item -LiteralPath $codexDesktopAsar.Path -Destination $asarPath -Force
}

Invoke-Step "Extract required app.asar files" {
  Invoke-NativeCommand -FilePath $node -Arguments @(".\scripts\extract-needed-asar.mjs", "--asar", $asarPath, "--out", $asarOut, "--force") -Name "extract-needed-asar"
}

Invoke-Step "Copy browser assets" {
  Copy-Item -Path ".\assets\*" -Destination ".\scratch\asar\webview\" -Force
}

Invoke-Step "Generate PWA icon" {
  $pwaSourceIcon = Resolve-PwaSourceIcon -AssetsPath "scratch\asar\webview\assets"
  Invoke-NativeCommand -FilePath $node -Arguments @(
    ".\scripts\generate-pwa-icon.mjs",
    $pwaSourceIcon,
    "scratch\asar\webview\assets\pwa-icon-512.png"
  ) -Name "generate-pwa-icon"
}

Invoke-Step "Prettify patch targets" {
  $prettier = Join-Path $PSScriptRoot "node_modules\.bin\prettier.cmd"
  if (-not (Test-Path -LiteralPath $prettier)) {
    throw "prettier.cmd was not found. Re-run setup without -SkipInstall."
  }

  $patchedFiles = Get-PatchedFiles | Where-Object { Test-Path -LiteralPath $_ }
  if ($patchedFiles.Count -gt 0) {
    Invoke-NativeCommand -FilePath $prettier -Arguments (@("--ignore-path", "NUL", "--ignore-unknown", "--write") + $patchedFiles) -Name "prettier patch targets"
  }
}

Invoke-Step "Apply portable codex-web patches" {
  $patches = @(
    "webview-remove-csp.patch",
    "webview-preload.patch",
    "webview-favicon.patch",
    "webview-pwa.patch",
    "sentry-disable-shell.patch"
  )

  foreach ($patchName in $patches) {
    $patchPath = Join-Path $PSScriptRoot "patches\$patchName"
    Write-Host "Applying $patchName"
    Invoke-NativeCommand -FilePath $patch -Arguments @("--batch", "--forward", "--strip", "1", "--directory", $asarOut, "--input", $patchPath) -Name "patch $patchName"
  }

  Remove-Item -LiteralPath "scratch\asar\node_modules\better-sqlite3" -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-Step "Apply Windows Codex Desktop patches" {
  Invoke-NativeCommand -FilePath $node -Arguments @(
    ".\scripts\patch-windows-asar.mjs",
    "--root",
    $asarOut,
    "--app-version",
    $AppVersion
  ) -Name "patch-windows-asar"
}

Invoke-Step "Build browser bundle" {
  Invoke-NativeCommand -FilePath $npm -Arguments @("run", "build:browser") -Name "npm run build:browser"
}

Invoke-Step "Build server bundle" {
  Invoke-NativeCommand -FilePath $npm -Arguments @("run", "build:server") -Name "npm run build:server"
}

Write-Host ""
Write-Host "Windows setup complete."
Write-Host ("Local start:      {0}" -f (Join-Path $PSScriptRoot "start-codex-web.bat"))
Write-Host ("Cloudflare start: {0}" -f (Join-Path $PSScriptRoot "start-codex-web-cloudflare.bat"))

if ($setupHasMutex) {
  $setupMutex.ReleaseMutex()
}
$setupMutex.Dispose()
