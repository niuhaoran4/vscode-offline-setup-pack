[CmdletBinding()]
param(
    [string]$PackRoot = '',
    [string]$VSCodeDir = '',
    [switch]$SkipExtensions,
    [switch]$SkipSmokeTest,
    [switch]$Json
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Load.ps1')
Initialize-ConsoleEncoding

if (-not $PackRoot) { $PackRoot = Split-Path -Parent $PSScriptRoot }

$context = New-PackContext -PackRoot $PackRoot
$logger = New-PackLogger -LogDir $context.LogsDir -Prefix 'verify'
$exitCode = 1

try {
    $result = Invoke-PackVerification -Context $context -Logger $logger -Scope All -VSCodeDir $VSCodeDir -SkipExtensions:$SkipExtensions -SkipSmokeTest:$SkipSmokeTest
    if ($Json) {
        Write-Output ($result | ConvertTo-Json -Depth 12)
    }
    $exitCode = if ($result.Ok) { 0 } else { 1 }
}
catch {
    $logger.Error('验证异常终止: ' + $_.Exception.Message)
    if ($_.ScriptStackTrace) { $logger.Detail($_.ScriptStackTrace) }
    $exitCode = 1
}
finally {
    $logger.Summary()
}

exit $exitCode
