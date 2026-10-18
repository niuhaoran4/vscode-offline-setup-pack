[CmdletBinding()]
param(
    [string]$PackRoot = '',
    [switch]$DryRun,
    [switch]$ForceExtensions,
    [switch]$NoBackup,
    [switch]$SkipSettings,
    [switch]$SkipExtensions,
    [switch]$SkipUserPath,
    [string]$DataRoot = '',
    [switch]$MigrateData,
    [switch]$SkipCacheRelocation,
    [string]$VSCodeDir = '',
    [ValidateSet('', 'zh-cn', 'en')][string]$Locale = 'zh-cn',
    [switch]$NonInteractive,
    [switch]$AllowElevated,
    [string]$RunId = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Load.ps1')
Initialize-ConsoleEncoding

if (-not $PackRoot) { $PackRoot = Split-Path -Parent $PSScriptRoot }

$context = New-PackContext -PackRoot $PackRoot
$currentUser = Get-CurrentUserName
$safeUser = ($currentUser -replace '[^A-Za-z0-9._-]', '_')
$logger = New-PackLogger -LogDir $context.LogsDir -Prefix ('inject-' + $safeUser)

$exitCode = 1
$result = $null

try {
    $logger.Banner('VSCode 用户配置注入')
    $logger.Info('用户: ' + $currentUser + ' (' + (Get-CurrentUserSid) + ')')
    $logger.Info('VSCode 用户目录: ' + (Get-UserCodePaths).UserDir)

    if ((Test-IsAdministrator) -and -not $AllowElevated -and -not $DryRun) {
        throw '当前进程以管理员身份运行。请以目标用户身份运行（不要右键“以管理员身份运行”），否则可能把配置写到管理员账户。若已确认当前就是目标用户，可加 -AllowElevated。'
    }

    if ($MigrateData -and -not $DataRoot) {
        throw '-MigrateData 需要配合 -DataRoot 使用。'
    }
    if ($SkipCacheRelocation -and -not $DataRoot) {
        throw '-SkipCacheRelocation 需要配合 -DataRoot 使用。'
    }

    if (-not $DryRun) {
        Unblock-PackFiles -PackRoot $context.Root -Logger $logger | Out-Null
    }

    $assets = Assert-PackAssets -Context $context -Logger $logger -SkipExtensions:$SkipExtensions
    if (-not $assets.Ok) {
        throw ('资产校验失败:' + [Environment]::NewLine + ($assets.Problems -join [Environment]::NewLine))
    }

    $vscodeStatus = Get-VSCodeStatus -Context $context -VSCodeDir $VSCodeDir
    $codeCli = $vscodeStatus.Cli
    if (-not $codeCli) { $codeCli = Get-VSCodeCliPath -PreferredPath '' }

    if ($DataRoot) {
        if (-not $vscodeStatus.SystemInstalled -or -not $codeCli) {
            throw '未检测到可用的系统版 VSCode / code CLI，已跳过 DataRoot 重定向。请先运行 setup.ps1 完成 VSCode 安装。'
        }
        $logger.Step('重定向 VSCode 用户数据到 DataRoot')
        $dataRootResult = Enable-VSCodeDataRoot -Logger $logger -DataRoot $DataRoot -MigrateExisting:$MigrateData -SkipCache:$SkipCacheRelocation -DryRun:$DryRun
        $logger.Stage('DataRoot', 'OK', ('用户数据/扩展 -> ' + $DataRoot))
    }

    $pythonStatus = Get-PythonStatus -Context $context
    $pythonExe = $pythonStatus.Exe
    if (-not $pythonExe) {
        $pythonExe = Join-Path ([string](Get-PropertyValue -Object $context.Paths.Python -Name 'InstallDir')) 'python.exe'
        $logger.Warn('未检测到系统版 Python，配置将指向预期路径: ' + $pythonExe)
    }

    $mingwStatus = Get-MinGWStatus -Context $context
    $mingwGcc = Join-Path $mingwStatus.BinDir 'gcc.exe'
    $mingwGdb = Join-Path $mingwStatus.BinDir 'gdb.exe'
    if (-not $mingwStatus.Exists) {
        $logger.Warn('未检测到 ' + $mingwStatus.BinDir + '，配置将指向预期路径。')
    }

    $vscodeStatus = Get-VSCodeStatus -Context $context -VSCodeDir $VSCodeDir
    if (-not $vscodeStatus.SystemInstalled) {
        $logger.Warn('未检测到系统版 VSCode。' + $(if ($codeCli) { '将使用现有 code CLI 注入，但结果可能不完整。' } else { '找不到 code CLI，扩展无法安装。' }))
    }

    if ($Locale -eq 'zh-cn' -and -not $SkipExtensions) {
        $languagePack = @(Get-PackExtensionAssets -Context $context) | Where-Object { $_.Id -eq 'ms-ceintl.vscode-language-pack-zh-hans' } | Select-Object -First 1
        if (-not $languagePack) {
            $logger.Warn('指定了 zh-cn，但 MANIFEST 中没有中文语言包扩展。')
        }
    }

    $result = Invoke-UserConfiguration -Context $context -Logger $logger `
        -PythonExe $pythonExe -MinGWGcc $mingwGcc -MinGWGdb $mingwGdb -CodeCli $codeCli `
        -DryRun:$DryRun -ForceExtensions:$ForceExtensions -NoBackup:$NoBackup `
        -SkipSettings:$SkipSettings -SkipExtensions:$SkipExtensions -SkipUserPath:$SkipUserPath -Locale $Locale

    if ($result.Ok) {
        $exitCode = 0
        if ($DryRun) {
            $logger.Ok('DryRun 完成：未写入配置、未安装扩展。')
            $logger.Info('去掉 -DryRun 后正式执行。')
        }
        else {
            $logger.Ok('用户配置注入完成。')
            $logger.Info('请重启 VSCode 窗口（或退出后重新打开）使扩展和设置生效。')
            $logger.Info('验证命令: powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $context.Root 'scripts\verify.ps1') + '"')
        }
    }
    else {
        $exitCode = 1
        $logger.Error('用户配置注入未全部通过，请查看日志。')
    }
}
catch {
    $logger.Error('配置注入异常终止: ' + $_.Exception.Message)
    if ($_.ScriptStackTrace) { $logger.Detail($_.ScriptStackTrace) }
    $exitCode = 1
}
finally {
    if ($RunId) {
        $resultPath = Join-Path $context.LogsDir ('inject-result-' + $RunId + '.json')
        try {
            $resultObject = [pscustomobject]@{
                schemaVersion = 1
                runId         = $RunId
                exitCode      = $exitCode
                generatedAt   = (Get-Date).ToString('o')
                user          = $currentUser
                sid           = (Get-CurrentUserSid)
                result        = $result
                logFile       = $logger.LogFile
            }
            Write-Utf8NoBom -Path $resultPath -Content ($resultObject | ConvertTo-Json -Depth 12)
            $logger.Info('注入结果已写入: ' + $resultPath)
        }
        catch {
            $logger.Warn('写入注入结果文件失败: ' + $_.Exception.Message)
        }
    }
    $logger.Summary()
}

exit $exitCode
