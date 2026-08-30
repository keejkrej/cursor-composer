#!/usr/bin/env pwsh
# Install cc (Cursor Composer) and the Cursor SDK Bridge.
#
#   irm https://github.com/keejkrej/cursor-composer/releases/latest/download/install.ps1 | iex
#
# Optional env:
#   CC_VERSION      Release tag without leading v (default: latest)
#   CC_REPO         GitHub repo (default: keejkrej/cursor-composer)
#   CC_INSTALL_DIR  Directory for binaries (default: %USERPROFILE%\.cc\bin)
#   CC_ARCHIVE      Local archive path (skip GitHub download)
#   CC_SKIP_PATH    Set to 1 to skip user PATH edits

$ErrorActionPreference = "Stop"

$Repo = if ($env:CC_REPO) { $env:CC_REPO } else { "keejkrej/cursor-composer" }
$InstallDir = if ($env:CC_INSTALL_DIR) {
    $env:CC_INSTALL_DIR
} else {
    Join-Path $env:USERPROFILE ".cc\bin"
}

function Get-ArchName {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $arch = $env:PROCESSOR_ARCHITEW6432 }
    switch ($arch) {
        "AMD64" { return "x64" }
        "ARM64" { return "arm64" }
        default { throw "unsupported architecture: $arch" }
    }
}

function Get-DownloadUrl([string]$Filename) {
    $version = $env:CC_VERSION
    if ([string]::IsNullOrWhiteSpace($version)) {
        return "https://github.com/$Repo/releases/latest/download/$Filename"
    }
    $tag = $version.TrimStart("v")
    return "https://github.com/$Repo/releases/download/v$tag/$Filename"
}

function Find-Payload([string]$Root, [string]$Name) {
    $match = Get-ChildItem -Path $Root -Recurse -File |
        Where-Object { $_.Name -eq $Name -or $_.Name -eq "$Name.exe" } |
        Select-Object -First 1
    if (-not $match) { throw "archive is missing $Name" }
    return $match.FullName
}

$arch = Get-ArchName
$filename = "cc-windows-$arch.zip"
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("cc-install-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

try {
    if ($env:CC_ARCHIVE) {
        if (-not (Test-Path $env:CC_ARCHIVE)) { throw "CC_ARCHIVE not found: $($env:CC_ARCHIVE)" }
        $archive = $env:CC_ARCHIVE
        Write-Host "Installing from $archive"
    } else {
        $url = Get-DownloadUrl $filename
        $archive = Join-Path $work $filename
        Write-Host "Downloading $url"
        Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing
        try {
            $sumsUrl = Get-DownloadUrl "SHA256SUMS"
            $sums = Invoke-WebRequest -Uri $sumsUrl -UseBasicParsing
            $line = ($sums.Content -split "`n") | Where-Object { $_ -match [regex]::Escape($filename) } | Select-Object -First 1
            if ($line) {
                $expected = ($line -split "\s+")[0]
                $actual = (Get-FileHash -Algorithm SHA256 $archive).Hash.ToLowerInvariant()
                if ($expected.ToLowerInvariant() -ne $actual) {
                    throw "checksum mismatch for $filename"
                }
            }
        } catch {
            Write-Warning "Skipping checksum: $($_.Exception.Message)"
        }
    }

    $unpacked = Join-Path $work "unpacked"
    Expand-Archive -Path $archive -DestinationPath $unpacked -Force
    $ccSrc = Find-Payload $unpacked "cc"
    $bridgeSrc = Find-Payload $unpacked "cursor-sdk-bridge"
    Copy-Item $ccSrc (Join-Path $InstallDir (Split-Path $ccSrc -Leaf)) -Force
    Copy-Item $bridgeSrc (Join-Path $InstallDir (Split-Path $bridgeSrc -Leaf)) -Force
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

if ($env:CC_SKIP_PATH -ne "1") {
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $userPath) { $userPath = "" }
    $parts = $userPath -split ";" | Where-Object { $_ }
    if ($parts -notcontains $InstallDir) {
        $newPath = if ($userPath.Trim().Length -eq 0) { $InstallDir } else { "$InstallDir;$userPath" }
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        $env:Path = "$InstallDir;$env:Path"
        Write-Host "Added $InstallDir to your user PATH"
    }
}

Write-Host "Installed $(Join-Path $InstallDir 'cc.exe')"
Write-Host "Installed $(Join-Path $InstallDir 'cursor-sdk-bridge.exe')"
Write-Host ""
Write-Host "Set CURSOR_API_KEY, then run:"
Write-Host "  cc"
