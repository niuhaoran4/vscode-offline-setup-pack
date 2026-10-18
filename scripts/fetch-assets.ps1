[CmdletBinding()]
param(
    [string]$PackRoot = '',
    [string]$VSCodeVersion = 'latest',
    [string]$PythonVersion = '',
    [string]$MinGWAsset = '',
    [string[]]$Extensions = @(),
    [string]$CodeCli = '',
    [string]$GitHubProxy = '',
    [switch]$MinGWLatest,
    [switch]$IncludeLanguagePack,
    [switch]$SkipExtensions,
    [switch]$UseInstalledExtensions,
    [switch]$PlanOnly,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Load.ps1')
Initialize-ConsoleEncoding

if (-not $PackRoot) { $PackRoot = Split-Path -Parent $PSScriptRoot }

$context = New-PackContext -PackRoot $PackRoot
$logger = New-PackLogger -LogDir $context.LogsDir -Prefix 'fetch'
$exitCode = 1

try {
    $result = Invoke-AssetFetch -Context $context -Logger $logger `
        -VSCodeVersion $VSCodeVersion -PythonVersion $PythonVersion -MinGWAsset $MinGWAsset `
        -Extensions $Extensions -CodeCli $CodeCli -GitHubProxy $GitHubProxy -MinGWLatest:$MinGWLatest `
        -IncludeLanguagePack:$IncludeLanguagePack -SkipExtensions:$SkipExtensions `
        -UseInstalledExtensions:$UseInstalledExtensions -PlanOnly:$PlanOnly -Force:$Force

    if ($PlanOnly) {
        $logger.Ok('计划检查完成，未下载任何文件。')
    }
    else {
        $logger.Ok('资产准备完成。')
        $logger.Info('MANIFEST: ' + $result.ManifestPath)
        $logger.Info('VSCode: ' + $result.VSCodeVersion)
        $logger.Info('Python: ' + $result.PythonVersion)
        $logger.Info('MinGW: ' + $result.MinGW)
        $logger.Info('扩展: ' + @($result.Extensions).Count + ' 个')
        $logger.Info('下一步: 将整个目录复制到目标机，以管理员身份运行 scripts\setup.ps1。')
    }
    $exitCode = 0
}
catch {
    $logger.Error('资产准备失败: ' + $_.Exception.Message)
    if ($_.ScriptStackTrace) { $logger.Detail($_.ScriptStackTrace) }
    $exitCode = 1
}
finally {
    $logger.Summary()
}

exit $exitCode
