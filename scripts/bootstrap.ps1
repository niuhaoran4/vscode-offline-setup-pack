[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Destination,
    [string]$Repository = 'niuhaoran4/vscode-offline-setup-pack',
    [switch]$PlanOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Assert-GitHubUrl {
    param([Parameter(Mandatory)][string]$Url)
    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) {
        throw ('Invalid URL: ' + $Url)
    }
    if ($uri.Scheme -ne 'https') {
        throw ('Only HTTPS is allowed: ' + $Url)
    }
    $hostName = $uri.Host.ToLowerInvariant()
    $allowed = @('api.github.com', 'github.com', 'objects.githubusercontent.com')
    if ($allowed -notcontains $hostName) {
        throw ('Unexpected download host: ' + $hostName)
    }
    $ip = $null
    if ([System.Net.IPAddress]::TryParse($hostName, [ref]$ip)) {
        throw ('IP literal hosts are not allowed: ' + $hostName)
    }
    if ($hostName -match '^(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|169\.254\.|0\.0\.0\.0)$') {
        throw ('Private or reserved hosts are not allowed: ' + $hostName)
    }
}

if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw ('Invalid GitHub repository: ' + $Repository)
}

$destinationRoot = [System.IO.Path]::GetFullPath($Destination).TrimEnd('\')
$existing = @(Get-ChildItem -LiteralPath $destinationRoot -Directory -Filter 'VSCode-Offline-Setup-Pack-*' -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'scripts\setup.ps1') })
if ($existing.Count -gt 0) {
    Write-Host ('Full package already extracted: ' + $existing[0].FullName)
    return [pscustomobject]@{
        PackageRoot = $existing[0].FullName
        AssetName   = $null
        Sha256      = $null
        Downloaded  = $false
    }
}

$apiUrl = 'https://api.github.com/repos/' + $Repository + '/releases/latest'
Assert-GitHubUrl -Url $apiUrl
$headers = @{
    'User-Agent' = 'VSCode-Offline-Setup-Pack'
    'Accept'     = 'application/vnd.github+json'
}

Write-Host ('Querying latest release: ' + $Repository)
$release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -TimeoutSec 60
$zipAssets = @($release.assets | Where-Object { $_.name -match '^VSCode-Offline-Setup-Pack-.*-win32-x64\.zip$' })
if ($zipAssets.Count -eq 0) {
    throw 'No VSCode-Offline-Setup-Pack-*-win32-x64.zip asset found in the latest release.'
}
$zipAsset = $zipAssets | Select-Object -First 1
$shaAsset = @($release.assets | Where-Object { $_.name -eq ($zipAsset.name + '.sha256') }) | Select-Object -First 1
$zipUrl = [string]$zipAsset.browser_download_url
Assert-GitHubUrl -Url $zipUrl

if ($PlanOnly) {
    Write-Host ('Plan: ' + $zipAsset.name + ' (' + [Math]::Round($zipAsset.size / 1MB, 1) + ' MB)')
    Write-Host ('URL:  ' + $zipUrl)
    if ($shaAsset) { Write-Host ('SHA:  ' + $shaAsset.browser_download_url) }
    return [pscustomobject]@{
        PackageRoot = $null
        AssetName   = $zipAsset.name
        Sha256      = $null
        Downloaded  = $false
    }
}

if (-not (Test-Path -LiteralPath $destinationRoot)) {
    New-Item -ItemType Directory -Path $destinationRoot -Force | Out-Null
}

$zipPath = Join-Path $destinationRoot $zipAsset.name
$shaPath = Join-Path $destinationRoot ($zipAsset.name + '.sha256')
$curl = Get-Command 'curl.exe' -ErrorAction SilentlyContinue

Write-Host ('Downloading ' + $zipAsset.name + ' (' + [Math]::Round($zipAsset.size / 1MB, 1) + ' MB)...')
if ($curl) {
    & $curl.Source --ssl-no-revoke --http1.1 -L --fail --retry 3 --retry-delay 5 --max-time 3600 -o $zipPath $zipUrl
    if ($LASTEXITCODE -ne 0) {
        throw ('Download failed with curl exit code ' + $LASTEXITCODE)
    }
}
else {
    Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 3600
}

if ($shaAsset) {
    $shaUrl = [string]$shaAsset.browser_download_url
    Assert-GitHubUrl -Url $shaUrl
    Invoke-WebRequest -Uri $shaUrl -OutFile $shaPath -UseBasicParsing -TimeoutSec 120
    $shaText = [System.IO.File]::ReadAllText($shaPath)
    if ($shaText -notmatch '([0-9a-fA-F]{64})') {
        throw 'The downloaded SHA256 file is invalid.'
    }
    $expected = $matches[1].ToLowerInvariant()
    $actual = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw ('SHA256 mismatch. Expected ' + $expected + ', got ' + $actual)
    }
    Write-Host ('SHA256 verified: ' + $actual)
}

Write-Host 'Extracting...'
Expand-Archive -LiteralPath $zipPath -DestinationPath $destinationRoot -Force
$package = @(Get-ChildItem -LiteralPath $destinationRoot -Directory -Filter 'VSCode-Offline-Setup-Pack-*' |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'scripts\setup.ps1') }) | Select-Object -First 1
if (-not $package) {
    throw 'Extracted package root not found.'
}

Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $shaPath -Force -ErrorAction SilentlyContinue

Write-Host ('Package ready: ' + $package.FullName)
return [pscustomobject]@{
    PackageRoot = $package.FullName
    AssetName   = $zipAsset.name
    Sha256      = if ($shaAsset) { $actual } else { $null }
    Downloaded  = $true
}
