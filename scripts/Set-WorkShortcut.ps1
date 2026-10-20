[CmdletBinding()]
param([Parameter(Mandatory)][string]$WorkDir)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Load.ps1')

$work = [System.IO.Path]::GetFullPath($WorkDir).TrimEnd('\')
if (-not (Test-Path -LiteralPath $work)) {
    throw ('Work directory not found: ' + $work)
}

$context = New-PackContext -PackRoot (Split-Path $PSScriptRoot -Parent)
$logger = New-PackLogger -LogDir $context.LogsDir -Prefix 'shortcut'

try {
    $vscode = Get-VSCodePaths -Context $context
    if (-not (Test-Path -LiteralPath $vscode.SystemExe)) {
        throw ('System VSCode not found: ' + $vscode.SystemExe)
    }
    $result = Set-WorkShortcut -WorkDir $work -VSCodeExe $vscode.SystemExe -Logger $logger
    if (-not $result.Ok) { throw $result.Message }
    Write-Host ('Shortcut updated: ' + $result.ShortcutPath)
    exit 0
}
catch {
    Write-Host ('ERROR: ' + $_.Exception.Message)
    exit 1
}
finally {
    $logger.Summary()
}
