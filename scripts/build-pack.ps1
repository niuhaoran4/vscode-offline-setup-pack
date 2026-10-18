[CmdletBinding()]
param(
    [string]$PackRoot = '',
    [string]$OutputDir = '',
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Load.ps1')
Initialize-ConsoleEncoding

if (-not $PackRoot) { $PackRoot = Split-Path -Parent $PSScriptRoot }

$context = New-PackContext -PackRoot $PackRoot
$logger = New-PackLogger -LogDir $context.LogsDir -Prefix 'build'
$exitCode = 1

try {
    $result = Build-PackArchive -Context $context -Logger $logger -OutputDir $OutputDir -Force:$Force
    $logger.Info('ZIP: ' + $result.ZipPath)
    $logger.Info('SHA256: ' + $result.Sha256)
    $exitCode = 0
}
catch {
    $logger.Error('打包失败: ' + $_.Exception.Message)
    if ($_.ScriptStackTrace) { $logger.Detail($_.ScriptStackTrace) }
    $exitCode = 1
}
finally {
    $logger.Summary()
}

exit $exitCode
