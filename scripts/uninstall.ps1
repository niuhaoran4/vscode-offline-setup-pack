[CmdletBinding()]
param(
    [string]$PackRoot = '',
    [ValidateSet('', 'User', 'Machine', 'All')][string]$Scope = '',
    [switch]$RemoveExtensions,
    [switch]$RestoreSettings,
    [switch]$RemoveVSCode,
    [switch]$RemoveMinGW,
    [switch]$RemoveDataLinks,
    [switch]$DryRun,
    [switch]$AllowElevated,
    [string]$VSCodeDir = '',
    [string]$RunId = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\Load.ps1')
Initialize-ConsoleEncoding

if (-not $PackRoot) { $PackRoot = Split-Path -Parent $PSScriptRoot }

$context = New-PackContext -PackRoot $PackRoot
$logger = New-PackLogger -LogDir $context.LogsDir -Prefix 'uninstall'
$exitCode = 1
$actions = New-Object System.Collections.Generic.List[object]

function Add-UninstallAction {
    param($Actions, $Logger, [string]$Name, [string]$Status, [string]$Detail)
    $Actions.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    if ($Status -eq 'Failed') { $Logger.Error($Name + ': ' + $Detail) }
    elseif ($Status -eq 'Skipped') { $Logger.Detail($Name + ': ' + $Detail) }
    else { $Logger.Ok($Name + ': ' + $Detail) }
}

try {
    $logger.Banner('卸载 / 回滚')
    if (-not $Scope) {
        throw '请指定 -Scope User、-Scope Machine 或 -Scope All。默认不会删除任何内容。'
    }
    if (($Scope -eq 'Machine' -or $Scope -eq 'All') -and -not (Test-IsAdministrator) -and -not $DryRun) {
        throw 'Machine/All 范围需要管理员权限。请以管理员身份重新运行。'
    }
    if (($Scope -eq 'User' -or $Scope -eq 'All') -and (Test-IsAdministrator) -and -not $AllowElevated -and -not $DryRun) {
        throw '检测到管理员上下文。为防止清理错用户，请分开执行：目标用户以普通身份运行 -Scope User；管理员运行 -Scope Machine。若当前账户就是目标用户，可加 -AllowElevated。'
    }
    if ($Scope -eq 'User' -and (Test-IsAdministrator)) {
        $logger.Warn('当前进程以管理员身份运行。请确认当前账户就是目标用户。')
    }

    $projectPaths = Get-UserCodePaths
    $vscode = Get-VSCodeStatus -Context $context -VSCodeDir $VSCodeDir
    $userDataTarget = Get-ReparsePointTarget -Path $projectPaths.CodeRoot
    $extensionsTarget = Get-ReparsePointTarget -Path $projectPaths.ExtensionsDir
    if ($userDataTarget -or $extensionsTarget) {
        $logger.Warn('检测到 VSCode 用户数据或扩展已重定向到其他位置。')
        if ($userDataTarget) { $logger.Info('  用户数据: ' + $userDataTarget) }
        if ($extensionsTarget) { $logger.Info('  扩展: ' + $extensionsTarget) }
        $logger.Info('  卸载程序不会删除 DataRoot 本身；-RemoveExtensions / -RestoreSettings 会通过联接操作目标目录。')
    }
    $python = Get-PythonStatus -Context $context
    $mingw = Get-MinGWStatus -Context $context

    if ($Scope -eq 'User' -or $Scope -eq 'All') {
        $logger.Step('清理用户级内容')

        $pythonExe = $python.Exe
        if (-not $pythonExe) { $pythonExe = Join-Path ([string](Get-PropertyValue -Object $context.Paths.Python -Name 'InstallDir')) 'python.exe' }
        $userScripts = Get-PythonUserScriptsDir -PythonExe $pythonExe
        $pathResult = Remove-PathEntry -Scope User -Entry $userScripts -LogDir $context.LogsDir -Logger $logger -DryRun:$DryRun
        $pathStatus = if ($pathResult.Changed) { 'OK' } else { 'Skipped' }
        Add-UninstallAction -Actions $actions -Logger $logger -Name '用户 PATH' -Status $pathStatus -Detail $userScripts

        if ($RemoveExtensions) {
            $codeCli = $vscode.Cli
            if (-not $codeCli) { $codeCli = Get-VSCodeCliPath -PreferredPath '' }
            if (-not $codeCli) {
                Add-UninstallAction -Actions $actions -Logger $logger -Name '扩展' -Status 'Failed' -Detail '找不到 code CLI'
            }
            else {
                foreach ($asset in @(Get-PackExtensionAssets -Context $context)) {
                    if ($DryRun) {
                        Add-UninstallAction -Actions $actions -Logger $logger -Name ('扩展 ' + $asset.Id) -Status 'Skipped' -Detail 'DryRun，将卸载'
                        continue
                    }
                    $result = Invoke-CodeCli -CodeCli $codeCli -Arguments @('--uninstall-extension', $asset.Id)
                    if ($result.ExitCode -eq 0) {
                        Add-UninstallAction -Actions $actions -Logger $logger -Name ('扩展 ' + $asset.Id) -Status 'OK' -Detail '已卸载'
                    }
                    else {
                        Add-UninstallAction -Actions $actions -Logger $logger -Name ('扩展 ' + $asset.Id) -Status 'Skipped' -Detail ('未卸载或本来就不存在: ' + $result.Output)
                    }
                }
            }
        }

        if ($RestoreSettings) {
            $parentDir = Split-Path -Parent $projectPaths.UserDir
            $leaf = Split-Path -Leaf $projectPaths.UserDir
            $backups = @(Get-ChildItem -LiteralPath $parentDir -Directory -Filter ($leaf + '.backup.*') -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTime -Descending)
            if ($backups.Count -eq 0) {
                Add-UninstallAction -Actions $actions -Logger $logger -Name '恢复用户配置' -Status 'Skipped' -Detail '没有找到 User.backup.*'
            }
            elseif ($DryRun) {
                Add-UninstallAction -Actions $actions -Logger $logger -Name '恢复用户配置' -Status 'Skipped' -Detail ('DryRun，将恢复: ' + $backups[0].FullName)
            }
            else {
                $safety = $projectPaths.UserDir + '.pre-restore.' + (Get-Date -Format 'yyyyMMdd-HHmmss')
                if (Test-Path -LiteralPath $projectPaths.UserDir) {
                    Copy-DirectoryTree -Source $projectPaths.UserDir -Destination $safety -Threads 2 -TimeoutSeconds 600 | Out-Null
                }
                Copy-DirectoryTree -Source $backups[0].FullName -Destination $projectPaths.UserDir -Threads 2 -TimeoutSeconds 600 | Out-Null
                Add-UninstallAction -Actions $actions -Logger $logger -Name '恢复用户配置' -Status 'OK' -Detail ('已从 ' + $backups[0].FullName + ' 恢复；恢复前备份: ' + $safety)
            }
        }

        if ($RemoveDataLinks) {
            $dataLinks = @(
                @{ Name = '用户数据联接'; Path = $projectPaths.CodeRoot }
                @{ Name = '扩展联接'; Path = $projectPaths.ExtensionsDir }
                @{ Name = 'C/C++ 缓存联接'; Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\vscode-cpptools') }
            )
            foreach ($item in $dataLinks) {
                $target = Get-ReparsePointTarget -Path $item.Path
                if (-not $target) {
                    Add-UninstallAction -Actions $actions -Logger $logger -Name $item.Name -Status 'Skipped' -Detail ('不是联接或不存在: ' + $item.Path)
                    continue
                }
                if ($DryRun) {
                    Add-UninstallAction -Actions $actions -Logger $logger -Name $item.Name -Status 'Skipped' -Detail ('DryRun，将移除联接，保留目标: ' + $target)
                    continue
                }
                try {
                    [System.IO.Directory]::Delete($item.Path, $false)
                    Add-UninstallAction -Actions $actions -Logger $logger -Name $item.Name -Status 'OK' -Detail ('已移除联接，目标数据保留在: ' + $target)
                }
                catch {
                    Add-UninstallAction -Actions $actions -Logger $logger -Name $item.Name -Status 'Failed' -Detail $_.Exception.Message
                }
            }
        }
    }

    if ($Scope -eq 'Machine' -or $Scope -eq 'All') {
        $logger.Step('清理机器级内容')

        $vscodePaths = Get-VSCodePaths -Context $context -VSCodeDir $VSCodeDir
        $pythonDir = $python.InstallDir
        if (-not $pythonDir) { $pythonDir = [string](Get-PropertyValue -Object $context.Paths.Python -Name 'InstallDir') }

        $pathEntries = @(
            @{ Name = 'VSCode bin'; Entry = $vscodePaths.BinDir },
            @{ Name = 'Python'; Entry = $pythonDir },
            @{ Name = 'Python Scripts'; Entry = (Join-Path $pythonDir 'Scripts') },
            @{ Name = 'MinGW bin'; Entry = $mingw.BinDir }
        )
        foreach ($item in $pathEntries) {
            if (-not $item.Entry) { continue }
            $result = Remove-PathEntry -Scope Machine -Entry $item.Entry -LogDir $context.LogsDir -Logger $logger -DryRun:$DryRun
            $entryStatus = if ($result.Changed) { 'OK' } else { 'Skipped' }
            Add-UninstallAction -Actions $actions -Logger $logger -Name ('系统 PATH: ' + $item.Name) -Status $entryStatus -Detail $item.Entry
        }

        if ($RemoveMinGW) {
            $configured = [string](Get-PropertyValue -Object $context.Paths.MinGW -Name 'InstallDir')
            if (-not (Test-Path -LiteralPath $mingw.BinDir)) {
                Add-UninstallAction -Actions $actions -Logger $logger -Name 'MinGW 目录' -Status 'Skipped' -Detail '目录不存在'
            }
            elseif (-not (Test-PathEquivalent -Left $mingw.InstallDir -Right $configured)) {
                Add-UninstallAction -Actions $actions -Logger $logger -Name 'MinGW 目录' -Status 'Failed' -Detail ('路径与配置不一致，拒绝删除: ' + $mingw.InstallDir)
            }
            elseif ($DryRun) {
                Add-UninstallAction -Actions $actions -Logger $logger -Name 'MinGW 目录' -Status 'Skipped' -Detail ('DryRun，将删除: ' + $mingw.InstallDir)
            }
            else {
                Remove-Item -LiteralPath $mingw.InstallDir -Recurse -Force
                Add-UninstallAction -Actions $actions -Logger $logger -Name 'MinGW 目录' -Status 'OK' -Detail ('已删除: ' + $mingw.InstallDir)
            }
        }

        if ($RemoveVSCode) {
            if (-not (Test-Path -LiteralPath $vscodePaths.SystemExe)) {
                Add-UninstallAction -Actions $actions -Logger $logger -Name 'VSCode' -Status 'Skipped' -Detail '系统版未安装'
            }
            elseif ($DryRun) {
                Add-UninstallAction -Actions $actions -Logger $logger -Name 'VSCode' -Status 'Skipped' -Detail 'DryRun，将运行系统版卸载程序'
            }
            elseif (@(Get-RunningVSCodeProcesses).Count -gt 0) {
                Add-UninstallAction -Actions $actions -Logger $logger -Name 'VSCode' -Status 'Failed' -Detail 'VSCode 正在运行，请先关闭所有窗口再卸载'
            }
            else {
                $uninstaller = Get-ChildItem -LiteralPath $vscodePaths.SystemDir -Filter 'unins*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($uninstaller) {
                    $code = Invoke-InstallerProcess -FilePath $uninstaller.FullName -Arguments '/VERYSILENT /NORESTART' -TimeoutSeconds 600
                    if ($code -eq 0) {
                        Add-UninstallAction -Actions $actions -Logger $logger -Name 'VSCode' -Status 'OK' -Detail '系统版已卸载'
                    }
                    else {
                        Add-UninstallAction -Actions $actions -Logger $logger -Name 'VSCode' -Status 'Failed' -Detail ('卸载程序退出码 ' + $code)
                    }
                }
                else {
                    Add-UninstallAction -Actions $actions -Logger $logger -Name 'VSCode' -Status 'Failed' -Detail '找不到 unins*.exe'
                }
            }
        }

        $taskName = 'VSCodeOfflinePack-UserConfig'
        try {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($task) {
                if ($DryRun) {
                    Add-UninstallAction -Actions $actions -Logger $logger -Name '计划任务' -Status 'Skipped' -Detail ('DryRun，将删除: ' + $taskName)
                }
                else {
                    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
                    Add-UninstallAction -Actions $actions -Logger $logger -Name '计划任务' -Status 'OK' -Detail ('已删除: ' + $taskName)
                }
            }
            else {
                Add-UninstallAction -Actions $actions -Logger $logger -Name '计划任务' -Status 'Skipped' -Detail '不存在'
            }
        }
        catch {
            Add-UninstallAction -Actions $actions -Logger $logger -Name '计划任务' -Status 'Failed' -Detail $_.Exception.Message
        }

        $activeSetupKey = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\VSCodeOfflinePack'
        if (Test-Path -Path $activeSetupKey) {
            if ($DryRun) {
                Add-UninstallAction -Actions $actions -Logger $logger -Name 'Active Setup' -Status 'Skipped' -Detail 'DryRun，将删除'
            }
            else {
                Remove-Item -Path $activeSetupKey -Recurse -Force
                Add-UninstallAction -Actions $actions -Logger $logger -Name 'Active Setup' -Status 'OK' -Detail '已删除'
            }
        }
        else {
            Add-UninstallAction -Actions $actions -Logger $logger -Name 'Active Setup' -Status 'Skipped' -Detail '不存在'
        }

        $logger.Warn('Python 程序本身未自动卸载。请在“设置 > 应用”中卸载 Python 3.12，或使用 Python 官方卸载程序。')
    }

    Send-EnvironmentChanged | Out-Null
    $logger.Ok('卸载/回滚流程完成。')
    $exitCode = 0
}
catch {
    $logger.Error('卸载/回滚失败: ' + $_.Exception.Message)
    if ($_.ScriptStackTrace) { $logger.Detail($_.ScriptStackTrace) }
    $exitCode = 1
}
finally {
    if ($RunId) {
        $resultPath = Join-Path $context.LogsDir ('uninstall-result-' + $RunId + '.json')
        try {
            $resultObject = [pscustomobject]@{
                schemaVersion = 1
                runId         = $RunId
                exitCode      = $exitCode
                generatedAt   = (Get-Date).ToString('o')
                scope         = $Scope
                actions       = @(ConvertTo-PlainArray $actions)
                logFile       = $logger.LogFile
            }
            Write-Utf8NoBom -Path $resultPath -Content ($resultObject | ConvertTo-Json -Depth 12)
        }
        catch {
            $logger.Warn('写入卸载结果文件失败: ' + $_.Exception.Message)
        }
    }
    $logger.Summary()
}

exit $exitCode
