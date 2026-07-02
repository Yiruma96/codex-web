param(
  [string]$AppVersion = "26.513.20950",
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

if (-not (Test-Path -LiteralPath "package.json")) {
  throw "Run this script from the codex-web repository root."
}

$node = Resolve-RequiredCommand -Names @("node.exe", "node") -ErrorMessage "Could not find Node.js. Install Node.js 22+ and re-run setup-windows.bat."
$npm = Resolve-RequiredCommand -Names @("npm.cmd", "npm") -ErrorMessage "Could not find npm. Install Node.js and re-run setup-windows.bat."
$patch = Resolve-PatchCommand
$zipUrl = "https://persistent.oaistatic.com/codex-app-prod/Codex-darwin-arm64-$AppVersion.zip"
$zipPath = "scratch\Codex-darwin-arm64-$AppVersion.zip"
$asarPath = "scratch\app.asar"
$asarOut = "scratch\asar"

Write-Host "Using Node:  $node"
Write-Host "Using npm:   $npm"
Write-Host "Using patch: $patch"

if (-not $SkipInstall) {
  Invoke-Step "Install npm dependencies" {
    & $npm install --ignore-scripts
  }

  Invoke-Step "Rebuild native modules" {
    & $npm rebuild better-sqlite3
  }
}

Invoke-Step "Download pinned Codex Desktop bundle" {
  New-Item -ItemType Directory -Force -Path "scratch" | Out-Null
  if (Test-Path -LiteralPath $zipPath) {
    Write-Host "Already downloaded: $zipPath"
  } else {
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath
  }
}

Invoke-Step "Extract app.asar from Codex Desktop zip" {
  if (Test-Path -LiteralPath $asarPath) {
    Write-Host "Already extracted: $asarPath"
  } else {
    Extract-ZipEntry `
      -ZipPath $zipPath `
      -EntryName "Codex.app/Contents/Resources/app.asar" `
      -DestinationPath $asarPath
  }
}

Invoke-Step "Extract required app.asar files" {
  & $node ".\scripts\extract-needed-asar.mjs" --asar $asarPath --out $asarOut --force
}

Invoke-Step "Copy browser assets" {
  Copy-Item -Path ".\assets\*" -Destination ".\scratch\asar\webview\" -Force
}

Invoke-Step "Generate PWA icon" {
  & $node `
    ".\scripts\generate-pwa-icon.mjs" `
    "scratch\asar\webview\assets\app-D0g8sCle.png" `
    "scratch\asar\webview\assets\pwa-icon-512.png"
}

Invoke-Step "Prettify patch targets" {
  $prettier = Join-Path $PSScriptRoot "node_modules\.bin\prettier.cmd"
  if (-not (Test-Path -LiteralPath $prettier)) {
    throw "prettier.cmd was not found. Re-run setup without -SkipInstall."
  }

  $patchedFiles = Get-PatchedFiles
  if ($patchedFiles.Count -gt 0) {
    & $prettier --ignore-path NUL --ignore-unknown --write @patchedFiles
  }
}

Invoke-Step "Apply codex-web patches" {
  $patches = @(
    "webview-remove-csp.patch",
    "webview-style.patch",
    "webview-preload.patch",
    "webview-favicon.patch",
    "webview-pwa.patch",
    "webview-thread-title.patch",
    "webview-initial-route.patch",
    "webview-electron-shim-close-sidebar.patch",
    "webview-prosemirror-inputmode.patch",
    "webview-use-atfs-for-local-files.patch",
    "webview-prompt-search-param.patch",
    "webview-statsig-override-adapter.patch",
    "sentry-disable-shell.patch",
    "sentry-disable-webview.patch"
  )

  foreach ($patchName in $patches) {
    $patchPath = Join-Path $PSScriptRoot "patches\$patchName"
    Write-Host "Applying $patchName"
    & $patch --batch --forward --strip 1 --directory $asarOut --input $patchPath
  }

  Remove-Item -LiteralPath "scratch\asar\node_modules\better-sqlite3" -Recurse -Force -ErrorAction SilentlyContinue
}

Invoke-Step "Build browser bundle" {
  & $npm run build:browser
}

Invoke-Step "Build server bundle" {
  & $npm run build:server
}

Write-Host ""
Write-Host "Windows setup complete."
Write-Host ("Local start:      {0}" -f (Join-Path $PSScriptRoot "start-codex-web.bat"))
Write-Host ("Cloudflare start: {0}" -f (Join-Path $PSScriptRoot "start-codex-web-cloudflare.bat"))

if ($setupHasMutex) {
  $setupMutex.ReleaseMutex()
}
$setupMutex.Dispose()
