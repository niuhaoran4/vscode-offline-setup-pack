[CmdletBinding()]
param(
    [string]$PackRoot = '',
    [switch]$Elevated,
    [string]$RunId = '',
    [string]$OriginalUserSid = '',
    [string]$OriginalUserName = '',
    [string]$OriginalUserProfile = '',
    [switch]$ReplaceUserInstall,
    [switch]$SkipUserConfig,
    [switch]$SkipExtensions,
    [switch]$DryRun,
    [switch]$Force,
    [switch]$NoUserTask,
    [switch]$UseActiveSetup,
    [string]$VSCodeDir = '',
    [string]$DataRoot = '',
    [switch]$MigrateData,
    [switch]$SkipCacheRelocation,
    [ValidateSet('', 'zh-cn', 'en')][string]$Locale = 'zh-cn'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Load.ps1')
Initialize-ConsoleEncoding

if (-not $PackRoot) { $PackRoot = Split-Path -Parent $PSScriptRoot }

function Get-InjectExtraArguments {
    param([string]$DataRoot, [switch]$MigrateData)
    $extra = ''
    if ($DataRoot) { $extra += ' -DataRoot ' + (ConvertTo-CommandLineArgument $DataRoot) }
    if ($MigrateData) { $extra += ' -MigrateData' }
    return $extra
}

function Register-UserConfigTask {
    param($Context, $Logger, [string]$UserId, [string]$Locale, [string]$DataRoot = '', [switch]$MigrateData)
    $taskName = 'VSCodeOfflinePack-UserConfig'
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $injectScript = Join-Path $Context.Root 'scripts\inject-config.ps1'
    $argument = '-NoProfile -ExecutionPolicy Bypass -File "' + $injectScript + '" -NonInteractive'
    if ($Locale) { $argument += ' -Locale ' + $Locale }
    $argument += Get-InjectExtraArguments -DataRoot $DataRoot -MigrateData:$MigrateData

    try {
        $action = New-ScheduledTaskAction -Execute $powershell -Argument $argument
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserId
        $principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        $Logger.Ok('已注册用户配置注入任务: ' + $taskName)
        try {
            Start-ScheduledTask -TaskName $taskName
            $Logger.Info('已尝试立即启动配置注入任务；如果未运行，将在该用户下次登录时自动运行。')
        }
        catch {
            $Logger.Info('配置注入任务将在该用户下次登录时运行。')
        }
        return $true
    }
    catch {
        $Logger.Warn('注册计划任务失败: ' + $_.Exception.Message)
        return $false
    }
}

function Register-ActiveSetup {
    param($Context, $Logger, [string]$Locale, [string]$DataRoot = '', [switch]$MigrateData)
    $keyPath = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\VSCodeOfflinePack'
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $injectScript = Join-Path $Context.Root 'scripts\inject-config.ps1'
    $stub = '"' + $powershell + '" -NoProfile -ExecutionPolicy Bypass -File "' + $injectScript + '" -NonInteractive'
    if ($Locale) { $stub += ' -Locale ' + $Locale }
    $stub += Get-InjectExtraArguments -DataRoot $DataRoot -MigrateData:$MigrateData

    try {
        if (-not (Test-Path -Path $keyPath)) {
            New-Item -Path $keyPath -Force | Out-Null
        }
        New-ItemProperty -Path $keyPath -Name 'StubPath' -Value $stub -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $keyPath -Name 'Version' -Value '1,0,0,0' -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $keyPath -Name 'IsInstalled' -Value 1 -PropertyType DWord -Force | Out-Null
        $Logger.Ok('已注册 Active Setup：每个新用户首次登录时自动注入配置。')
        $Logger.Warn('Active Setup 使用固定包路径；移动安装包会导致注入失败。')
        return $true
    }
    catch {
        $Logger.Warn('注册 Active Setup 失败: ' + $_.Exception.Message)
        return $false
    }
}

function Write-InjectInstruction {
    param($Context, $Logger, [string]$UserId, [string]$DataRoot = '', [switch]$MigrateData)
    $safeUser = ($UserId -replace '[^A-Za-z0-9._-]', '_')
    $path = Join-Path $Context.LogsDir ('RUN-INJECT-AS-' + $safeUser + '.cmd')
    $injectScript = Join-Path $Context.Root 'scripts\inject-config.ps1'
    $extra = Get-InjectExtraArguments -DataRoot $DataRoot -MigrateData:$MigrateData
    $content = "@echo off`r`necho Run this file as $UserId (NOT as administrator).`r`necho.`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$injectScript`"$extra`r`necho.`r`npause`r`n"
    Write-Utf8NoBom -Path $path -Content $content
    $Logger.Info('已生成手动注入脚本: ' + $path)
    return $path
}

$isAdmin = Test-IsAdministrator
$currentSid = Get-CurrentUserSid
$currentUser = Get-CurrentUserName

if (-not $isAdmin -and -not $Elevated -and -not $DryRun) {
    try {
        $context = New-PackContext -PackRoot $PackRoot
        $parentLogger = New-PackLogger -LogDir $context.LogsDir -Prefix 'setup-parent'
        $runId = [guid]::NewGuid().ToString('N')
        $resultFile = Join-Path $context.LogsDir ('setup-result-' + $runId + '.json')
        if (Test-Path -LiteralPath $resultFile) { Remove-Item -LiteralPath $resultFile -Force }

        $childArguments = @(
            '-PackRoot', $context.Root,
            '-Elevated',
            '-RunId', $runId,
            '-OriginalUserSid', $currentSid,
            '-OriginalUserName', $currentUser,
            '-OriginalUserProfile', $env:USERPROFILE
        )
        if ($ReplaceUserInstall) { $childArguments += '-ReplaceUserInstall' }
        if ($SkipUserConfig) { $childArguments += '-SkipUserConfig' }
        if ($SkipExtensions) { $childArguments += '-SkipExtensions' }
        if ($Force) { $childArguments += '-Force' }
        if ($NoUserTask) { $childArguments += '-NoUserTask' }
        if ($UseActiveSetup) { $childArguments += '-UseActiveSetup' }
        if ($VSCodeDir) { $childArguments += @('-VSCodeDir', $VSCodeDir) }
        if ($DataRoot) { $childArguments += @('-DataRoot', $DataRoot) }
        if ($MigrateData) { $childArguments += '-MigrateData' }
        if ($SkipCacheRelocation) { $childArguments += '-SkipCacheRelocation' }
        if ($Locale) { $childArguments += @('-Locale', $Locale) }

        $parentLogger.Banner('需要管理员权限')
        $parentLogger.Info('即将弹出 UAC 提示，请点击“是”。安装窗口会单独打开并自动运行。')

        $elevated = Invoke-ElevatedChild -ScriptPath $PSCommandPath -ArgumentList $childArguments -WorkingDirectory $context.Root -ResultFile $resultFile -RunId $runId -TimeoutSeconds 7200
        if ($elevated.Result) {
            $parentLogger.Info('提权安装退出码: ' + $elevated.ExitCode)
            foreach ($stage in @($elevated.Result.stages)) {
                if ($null -eq $stage) { continue }
                $message = '  ' + $stage.Name + ': ' + $stage.Status
                if ($stage.Message) { $message += ' - ' + $stage.Message }
                Write-Host $message
            }
            if ($elevated.Result.logFile) {
                $parentLogger.Info('完整日志: ' + $elevated.Result.logFile)
            }
            if ($elevated.ExitCode -eq 0) {
                $parentLogger.Ok('安装完成。请注销并重新登录（或至少关闭所有终端）以刷新 PATH。')
            }
            else {
                $parentLogger.Error('安装未全部通过，请查看上面的阶段结果和日志。')
            }
            exit $elevated.ExitCode
        }

        $parentLogger.Warn('提权进程已结束，但未找到结果文件；以进程退出码为准。')
        exit $elevated.ExitCode
    }
    catch {
        Write-Host ('无法完成提权安装: ' + $_.Exception.Message) -ForegroundColor Red
        if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray }
        exit 1
    }
}

if ($Elevated -and -not $isAdmin) {
    Write-Host '提权失败：当前进程不是管理员。请重新运行并在 UAC 中点击“是”。' -ForegroundColor Red
    exit 1
}

if (-not $RunId) { $RunId = [guid]::NewGuid().ToString('N') }
$context = New-PackContext -PackRoot $PackRoot
$logger = New-PackLogger -LogDir $context.LogsDir -Prefix 'setup'
$stages = New-Object 'System.Collections.Generic.List[object]'
$exitCode = 1
$machineVerification = $null
$userVerification = $null
$userConfigResult = $null
$userConfigDeferred = $false
$vscodeResult = $null
$pythonResult = $null
$mingwResult = $null
$sameUser = $true
if ($OriginalUserSid) { $sameUser = ($currentSid -eq $OriginalUserSid) }

try {
    $logger.Banner('VSCode 离线环境安装')
    $logger.Info('安装包目录: ' + $context.Root)
    $logger.Info('当前用户: ' + $currentUser + ' (' + $currentSid + ')')
    if ($OriginalUserSid) {
        $logger.Info('启动用户: ' + $OriginalUserName + ' (' + $OriginalUserSid + ')')
        $logger.Info('当前进程与启动用户相同: ' + $sameUser)
    }
    else {
        $logger.Info('当前进程即启动用户')
    }

    if (-not $isAdmin -and -not $DryRun) {
        throw '当前进程没有管理员权限，无法安装系统级组件。'
    }

    if ($context.Root -match '(?i)onedrive') {
        $logger.Warn('安装包位于 OneDrive 同步目录，可能出现文件占用或路径过长问题。建议移动到 C:\vscode-offline-pack。')
    }
    if ($context.Root -match '[^\x00-\x7F]') {
        $logger.Warn('安装包路径包含非 ASCII 字符。少数安装器和解压工具可能异常，建议使用纯英文短路径。')
    }
    if ($context.Root.Length -gt 100) {
        $logger.Warn('安装包路径较长，可能导致解压或扩展安装失败。建议使用短路径。')
    }

    if ($MigrateData -and -not $DataRoot) {
        throw '-MigrateData 需要配合 -DataRoot 使用。'
    }
    if ($SkipCacheRelocation -and -not $DataRoot) {
        throw '-SkipCacheRelocation 需要配合 -DataRoot 使用。'
    }

    if ($VSCodeDir) {
        $vscodeDirCheck = Test-InstallDirectory -Path $VSCodeDir -MinimumFreeSpaceGB 2 -Label 'VSCode 安装目录'
        foreach ($problem in $vscodeDirCheck.Problems) { $logger.Error($problem) }
        foreach ($warning in $vscodeDirCheck.Warnings) { $logger.Warn($warning) }
        if (-not $vscodeDirCheck.Ok) {
            throw ('VSCode 安装目录无效: ' + ($vscodeDirCheck.Problems -join '; '))
        }
        $VSCodeDir = $vscodeDirCheck.FullPath
        $logger.Info('VSCode 安装目录: ' + $VSCodeDir)
    }
    else {
        $logger.Info('VSCode 安装目录: 自动检测（默认 ' + [string](Get-PropertyValue -Object $context.Paths.VSCode -Name 'InstallDir') + '）')
    }

    if ($DataRoot) {
        $dataRootCheck = Test-InstallDirectory -Path $DataRoot -MinimumFreeSpaceGB 3 -Label 'DataRoot'
        foreach ($problem in $dataRootCheck.Problems) { $logger.Error($problem) }
        foreach ($warning in $dataRootCheck.Warnings) { $logger.Warn($warning) }
        if (-not $dataRootCheck.Ok) {
            throw ('DataRoot 无效: ' + ($dataRootCheck.Problems -join '; '))
        }
        $DataRoot = $dataRootCheck.FullPath
        $logger.Info('VSCode 数据目录: ' + $DataRoot)
        if ($MigrateData) { $logger.Info('现有用户数据和扩展将迁移到 DataRoot') }
        if ($SkipUserConfig) {
            $logger.Warn('已指定 -SkipUserConfig，本次不会创建 DataRoot 联接；目标用户运行 inject-config.ps1 时需要加 -DataRoot。')
        }
        elseif ($UseActiveSetup -or -not $sameUser) {
            $logger.Warn('DataRoot 在多用户场景下会被多个用户共享；建议为每个用户使用独立目录。')
        }
    }

    if (-not $DryRun) {
        Unblock-PackFiles -PackRoot $context.Root -Logger $logger | Out-Null
    }

    $logger.Step('预检')
    $platform = Test-PlatformPrerequisites -MinimumOSBuild ([int]$context.Paths.MinimumOSBuild) -MinimumFreeSpaceGB ([int]$context.Paths.MinimumFreeSpaceGB)
    foreach ($problem in $platform.Problems) { $logger.Error('平台检查: ' + $problem) }
    foreach ($warning in $platform.Warnings) { $logger.Warn('平台检查: ' + $warning) }
    if (-not $platform.Ok) {
        throw ('平台预检失败: ' + ($platform.Problems -join '; '))
    }
    $logger.Ok('平台检查通过: x64, Windows build ' + $platform.Build)

    $assetValidation = Assert-PackAssets -Context $context -Logger $logger -SkipExtensions:$SkipExtensions
    if (-not $assetValidation.Ok) {
        throw ('资产校验失败:' + [Environment]::NewLine + ($assetValidation.Problems -join [Environment]::NewLine))
    }
    $logger.Ok('资产清单与 SHA256 校验通过')

    $vscodeBefore = Get-VSCodeStatus -Context $context -VSCodeDir $VSCodeDir
    $running = @(Get-RunningVSCodeProcesses)
    if ($running.Count -gt 0) {
        $logger.Warn('检测到 VSCode 正在运行。扩展安装后需要重启 VSCode 窗口；如果更换用户级安装，脚本会要求先关闭。')
    }
    if ($vscodeBefore.UserInstalled -and -not $vscodeBefore.SystemInstalled) {
        if ($ReplaceUserInstall) {
            $logger.Info('检测到用户级 VSCode，将按 -ReplaceUserInstall 卸载后安装系统版。')
        }
        else {
            $logger.Warn('检测到用户级 VSCode（' + $vscodeBefore.UserExe + '）。VSCode 安装阶段会停止，其他组件仍会安装。')
            $logger.Info('处理方式：先手动卸载用户版，或重新运行并加上 -ReplaceUserInstall。')
        }
    }

    foreach ($commandName in @('code.cmd', 'python.exe', 'gcc.exe')) {
        $source = Get-CommandFirstSource -Name $commandName
        if ($source) { $logger.Info('当前 PATH 中的 ' + $commandName + ': ' + $source) }
    }

    $logger.Step('安装系统级组件')
    $vscodeResult = Install-VSCodeProduct -Context $context -Logger $logger -ReplaceUserInstall:$ReplaceUserInstall -VSCodeDir $VSCodeDir -DryRun:$DryRun
    $stages.Add($vscodeResult)
    $logger.Stage($vscodeResult.Name, $vscodeResult.Status, $vscodeResult.Message)

    $pythonResult = Install-PythonProduct -Context $context -Logger $logger -DryRun:$DryRun
    $stages.Add($pythonResult)
    $logger.Stage($pythonResult.Name, $pythonResult.Status, $pythonResult.Message)

    $mingwResult = Install-MinGWProduct -Context $context -Logger $logger -DryRun:$DryRun -Force:$Force
    $stages.Add($mingwResult)
    $logger.Stage($mingwResult.Name, $mingwResult.Status, $mingwResult.Message)

    $env:Path = Get-EffectivePath -Expand

    if (-not $DryRun) {
        $machineVerification = Invoke-PackVerification -Context $context -Logger $logger -Scope Machine -VSCodeDir $VSCodeDir -SkipExtensions
        if ($machineVerification.Ok) {
            $logger.Stage('MachineVerify', 'OK', '机器级验证通过')
        }
        else {
            $logger.Stage('MachineVerify', 'Failed', ($machineVerification.Failures | ForEach-Object { $_.Name }) -join ', ')
        }
    }
    else {
        $logger.Info('DryRun: 跳过安装后验证')
    }

    $pythonStatus = Get-PythonStatus -Context $context
    $pythonExe = $pythonStatus.Exe
    if (-not $pythonExe) {
        $pythonExe = Join-Path ([string](Get-PropertyValue -Object $context.Paths.Python -Name 'InstallDir')) 'python.exe'
    }

    $mingwStatus = Get-MinGWStatus -Context $context
    $mingwGcc = Join-Path $mingwStatus.BinDir 'gcc.exe'
    $mingwGdb = Join-Path $mingwStatus.BinDir 'gdb.exe'

    $vscodeNow = Get-VSCodeStatus -Context $context -VSCodeDir $VSCodeDir
    $codeCli = $vscodeNow.Cli
    if (-not $codeCli) { $codeCli = Get-VSCodeCliPath -PreferredPath '' }

    if ($Locale -eq 'zh-cn' -and -not $SkipExtensions) {
        $languagePack = @(Get-PackExtensionAssets -Context $context) | Where-Object { $_.Id -eq 'ms-ceintl.vscode-language-pack-zh-hans' } | Select-Object -First 1
        if (-not $languagePack) {
            $logger.Warn('指定了 zh-cn，但 MANIFEST 中没有中文语言包扩展。界面语言可能不会改变。')
        }
    }

    if ($SkipUserConfig) {
        $logger.Warn('已指定 -SkipUserConfig，未写入当前用户配置。')
        $injectCommand = 'powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $context.Root 'scripts\inject-config.ps1') + '"'
        if ($DataRoot) {
            $injectCommand += ' -DataRoot "' + $DataRoot + '"'
            if ($MigrateData) { $injectCommand += ' -MigrateData' }
        }
        $logger.Info('请让目标用户运行: ' + $injectCommand)
    }
    elseif ($sameUser) {
        if ($VSCodeDir -and $vscodeResult.Status -eq 'Failed') {
            throw 'VSCode 安装阶段失败，已跳过用户配置注入。请先处理上面的 VSCode 错误。'
        }
        if ($DataRoot) {
            if (-not $vscodeNow.SystemInstalled -or -not $codeCli) {
                throw 'VSCode 系统版或 code CLI 不可用，已跳过用户数据重定向和配置注入。请先修复 VSCode 安装。'
            }
            $logger.Step('重定向 VSCode 用户数据到 DataRoot')
            $dataRootResult = Enable-VSCodeDataRoot -Logger $logger -DataRoot $DataRoot -MigrateExisting:$MigrateData -SkipCache:$SkipCacheRelocation -DryRun:$DryRun
            $logger.Stage('DataRoot', 'OK', ('用户数据/扩展 -> ' + $DataRoot))
        }

        $logger.Step('注入当前用户配置')
        $userConfigResult = Invoke-UserConfiguration -Context $context -Logger $logger `
            -PythonExe $pythonExe -MinGWGcc $mingwGcc -MinGWGdb $mingwGdb -CodeCli $codeCli `
            -DryRun:$DryRun -ForceExtensions:$Force -SkipExtensions:$SkipExtensions -Locale $Locale
        if ($userConfigResult.Ok) {
            $configStageMessage = if ($DryRun) { 'DryRun：配置与扩展检查通过' } else { '配置与扩展已就绪' }
            $logger.Stage('UserConfig', 'OK', $configStageMessage)
        }
        else {
            $logger.Stage('UserConfig', 'Failed', '配置或扩展未全部完成')
        }

        if (-not $DryRun) {
            $userVerification = Invoke-PackVerification -Context $context -Logger $logger -Scope User -VSCodeDir $VSCodeDir -SkipExtensions:$SkipExtensions
            if ($userVerification.Ok) {
                $logger.Stage('UserVerify', 'OK', '用户级验证通过')
            }
            else {
                $logger.Stage('UserVerify', 'Failed', ($userVerification.Failures | ForEach-Object { $_.Name }) -join ', ')
            }
        }
    }
    else {
        $userConfigDeferred = $true
        $logger.Warn('当前是另一个管理员账户。为避免把配置写到错误用户，本次不注入用户配置。')
        $logger.Info('目标用户: ' + $OriginalUserName)

        if ($UseActiveSetup) {
            if (-not (Register-ActiveSetup -Context $context -Logger $logger -Locale $Locale -DataRoot $DataRoot -MigrateData:$MigrateData)) {
                Write-InjectInstruction -Context $context -Logger $logger -UserId $OriginalUserName -DataRoot $DataRoot -MigrateData:$MigrateData | Out-Null
            }
        }
        elseif (-not $NoUserTask) {
            if (-not (Register-UserConfigTask -Context $context -Logger $logger -UserId $OriginalUserName -Locale $Locale -DataRoot $DataRoot -MigrateData:$MigrateData)) {
                Write-InjectInstruction -Context $context -Logger $logger -UserId $OriginalUserName -DataRoot $DataRoot -MigrateData:$MigrateData | Out-Null
            }
        }
        else {
            Write-InjectInstruction -Context $context -Logger $logger -UserId $OriginalUserName -DataRoot $DataRoot -MigrateData:$MigrateData | Out-Null
        }
    }

    $critical = $false
    foreach ($productResult in @($vscodeResult, $pythonResult, $mingwResult)) {
        if ($null -ne $productResult -and ($productResult.Status -eq 'Failed' -or $productResult.Blocker)) {
            $critical = $true
        }
    }
    if ($machineVerification -and -not $machineVerification.Ok) { $critical = $true }
    if ($userConfigResult -and -not $userConfigResult.Ok) { $critical = $true }
    if ($userVerification -and -not $userVerification.Ok) { $critical = $true }
    $exitCode = if ($critical) { 1 } else { 0 }

    if ($exitCode -eq 0) {
        if ($DryRun) {
            $logger.Ok('DryRun 完成：未安装、未写配置、未修改 PATH。')
            $logger.Info('去掉 -DryRun 后正式执行。')
        }
        else {
            $logger.Ok('安装流程完成。')
            $logger.Info('请注销并重新登录（或至少关闭所有终端）以刷新 PATH。')
            $logger.Info('验证命令: powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $context.Root 'scripts\verify.ps1') + '"')
            $logger.Info('示例工程: ' + (Join-Path $context.ExamplesDir 'hello-cpp') + '，打开后按 F5。')
            if ($userConfigDeferred) {
                $logger.Warn('用户配置已延迟：请让 ' + $OriginalUserName + ' 登录后等待任务运行，或手动运行 scripts\inject-config.ps1。')
            }
        }
    }
    else {
        $logger.Error('安装流程未全部通过。请根据上面的错误修复后重复运行（脚本是幂等的）。')
        if ($vscodeResult -and $vscodeResult.Status -eq 'Failed' -and $vscodeResult.Message -match '用户级 VSCode') {
            $logger.Info('可尝试: scripts\setup.ps1 -ReplaceUserInstall')
        }
    }
}
catch {
    $logger.Error('安装流程异常终止: ' + $_.Exception.Message)
    if ($_.ScriptStackTrace) { $logger.Detail($_.ScriptStackTrace) }
    $exitCode = 1
}
finally {
    $resultPath = Join-Path $context.LogsDir ('setup-result-' + $RunId + '.json')
    try {
        $resultObject = [pscustomobject]@{
            schemaVersion = 1
            runId         = $RunId
            exitCode      = $exitCode
            generatedAt   = (Get-Date).ToString('o')
            elevated      = $isAdmin
            originalUser  = [pscustomobject]@{ sid = $OriginalUserSid; name = $OriginalUserName }
            currentUser   = [pscustomobject]@{ sid = $currentSid; name = $currentUser }
            sameUser      = $sameUser
            stages        = @($stages | Where-Object { $null -ne $_ } | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; Status = $_.Status; Version = $_.Version; Path = $_.Path; Message = $_.Message }
            })
            machineVerification = $machineVerification
            userConfig    = [pscustomobject]@{ deferred = $userConfigDeferred; result = $userConfigResult }
            userVerification = $userVerification
            logFile       = $logger.LogFile
        }
        Write-Utf8NoBom -Path $resultPath -Content ($resultObject | ConvertTo-Json -Depth 12)
        $logger.Info('安装结果已写入: ' + $resultPath)
    }
    catch {
        $logger.Warn('写入安装结果文件失败: ' + $_.Exception.Message)
    }
    $logger.Summary()
}

exit $exitCode
