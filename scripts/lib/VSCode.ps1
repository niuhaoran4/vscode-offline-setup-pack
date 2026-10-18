# Visual Studio Code product module: detect, replace a per-user install, install system-wide.

function Find-SystemVSCodeInstallDir {
    param([Parameter(Mandatory)]$Context)

    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $items = @(Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue | Where-Object {
        $displayName = [string](Get-PropertyValue -Object $_ -Name 'DisplayName' -Default '')
        $installLocation = [string](Get-PropertyValue -Object $_ -Name 'InstallLocation' -Default '')
        $displayName -like 'Microsoft Visual Studio Code*' -and $installLocation
    })
    foreach ($item in $items) {
        $dir = ([string](Get-PropertyValue -Object $item -Name 'InstallLocation' -Default '')).TrimEnd('\')
        if ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'Code.exe'))) {
            return $dir
        }
    }

    $defaultDir = [string](Get-PropertyValue -Object $Context.Paths.VSCode -Name 'InstallDir')
    if ($defaultDir -and (Test-Path -LiteralPath (Join-Path $defaultDir 'Code.exe'))) {
        return $defaultDir.TrimEnd('\')
    }
    return $null
}

function Resolve-VSCodeInstallDir {
    param(
        [Parameter(Mandatory)]$Context,
        [string]$VSCodeDir = ''
    )

    if ($VSCodeDir) {
        return ([System.IO.Path]::GetFullPath($VSCodeDir)).TrimEnd('\')
    }
    $discovered = Find-SystemVSCodeInstallDir -Context $Context
    if ($discovered) { return $discovered }
    return ([string](Get-PropertyValue -Object $Context.Paths.VSCode -Name 'InstallDir')).TrimEnd('\')
}

function Get-VSCodePaths {
    param(
        [Parameter(Mandatory)]$Context,
        [string]$VSCodeDir = ''
    )
    $installDir = Resolve-VSCodeInstallDir -Context $Context -VSCodeDir $VSCodeDir
    $exeName = [string](Get-PropertyValue -Object $Context.Paths.VSCode -Name 'ExeName' -Default 'Code.exe')
    $cliRelative = [string](Get-PropertyValue -Object $Context.Paths.VSCode -Name 'CliRelative' -Default 'bin\code.cmd')
    $userDir = Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code'
    return [pscustomobject]@{
        InstallDir = $installDir
        SystemDir = $installDir
        SystemExe = (Join-Path $installDir $exeName)
        SystemCli = (Join-Path $installDir $cliRelative)
        BinDir    = (Join-Path $installDir 'bin')
        UserDir   = $userDir
        UserExe   = (Join-Path $userDir $exeName)
        UserCli   = (Join-Path $userDir $cliRelative)
    }
}

function Get-VSCodeInstallerArguments {
    param(
        [Parameter(Mandatory)][string]$MergeTasks,
        [Parameter(Mandatory)][string]$InstallDir,
        [Parameter(Mandatory)][string]$LogPath
    )

    return '/VERYSILENT /NORESTART /ALLUSERS /MERGETASKS=' + $MergeTasks +
        ' /DIR="' + $InstallDir + '" /LOG="' + $LogPath + '"'
}

function Get-VSCodeCliPath {
    param([AllowNull()][AllowEmptyString()][string]$PreferredPath)
    if ($PreferredPath -and (Test-Path -LiteralPath $PreferredPath)) {
        return $PreferredPath
    }
    $command = Get-Command 'code.cmd' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    $command = Get-Command 'code' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

function Get-VSCodeVersion {
    param([Parameter(Mandatory)][string]$ExePath)
    if (-not (Test-Path -LiteralPath $ExePath)) { return $null }
    try {
        return (Get-Item -LiteralPath $ExePath).VersionInfo.ProductVersion
    }
    catch {
        return $null
    }
}

function Get-RunningVSCodeProcesses {
    try {
        return @(Get-Process -Name 'Code' -ErrorAction SilentlyContinue)
    }
    catch {
        return @()
    }
}

function Invoke-UserVSCodeUninstall {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Logger,
        [Parameter(Mandatory)]$Paths
    )

    if (-not (Test-Path -LiteralPath $Paths.UserExe)) {
        return $true
    }

    $running = @(Get-RunningVSCodeProcesses)
    if ($running.Count -gt 0) {
        $Logger.Error('检测到 VSCode 正在运行。请先关闭所有 VSCode 窗口，再执行 -ReplaceUserInstall。')
        return $false
    }

    $uninstaller = Get-ChildItem -LiteralPath $Paths.UserDir -Filter 'unins*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $uninstaller) {
        $Logger.Error('找不到用户级 VSCode 的卸载程序。请在 Windows 设置中卸载“Microsoft Visual Studio Code”，然后重新运行。')
        return $false
    }

    $Logger.Info('正在卸载用户级 VSCode: ' + $uninstaller.FullName)
    try {
        $exitCode = Invoke-InstallerProcess -FilePath $uninstaller.FullName -Arguments '/VERYSILENT /NORESTART' -TimeoutSeconds 600
        if ($exitCode -ne 0) {
            $Logger.Error(('用户级 VSCode 卸载失败，退出码: ' + $exitCode))
            return $false
        }
    }
    catch {
        $Logger.Error('用户级 VSCode 卸载失败: ' + $_.Exception.Message)
        return $false
    }

    Start-Sleep -Seconds 2
    if (Test-Path -LiteralPath $Paths.UserExe) {
        $Logger.Error('用户级 VSCode 仍然存在，未继续安装系统版。')
        return $false
    }
    return $true
}

function Install-VSCodeProduct {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Logger,
        [switch]$ReplaceUserInstall,
        [string]$VSCodeDir = '',
        [switch]$DryRun
    )

    $paths = Get-VSCodePaths -Context $Context -VSCodeDir $VSCodeDir

    if ($VSCodeDir) {
        $existing = Find-SystemVSCodeInstallDir -Context $Context
        if ($existing -and -not (Test-PathEquivalent -Left $existing -Right $paths.SystemDir)) {
            $message = '检测到系统版 VSCode 已安装在 ' + $existing + '。为避免两个系统版并存，请先运行 uninstall.ps1 -Scope Machine -RemoveVSCode，或把 -VSCodeDir 指向现有目录。'
            $Logger.Error($message)
            return [pscustomobject]@{
                Name = 'VSCode'; Status = 'Failed'; Version = (Get-VSCodeVersion -ExePath (Join-Path $existing 'Code.exe'));
                Path = $existing; Cli = $null; Message = $message; Blocker = $true
            }
        }
    }

    if (Test-Path -LiteralPath $paths.SystemExe) {
        $version = Get-VSCodeVersion -ExePath $paths.SystemExe
        $cli = Get-VSCodeCliPath -PreferredPath $paths.SystemCli
        if (-not $cli) {
            return [pscustomobject]@{
                Name = 'VSCode'; Status = 'Failed'; Version = $version; Path = $paths.SystemExe; Cli = $null;
                Message = '系统版 VSCode 已存在，但找不到 bin\code.cmd'; Blocker = $true
            }
        }
        Add-PathEntry -Scope Machine -Entry $paths.BinDir -LogDir $Context.LogsDir -Logger $Logger -DryRun:$DryRun | Out-Null
        $Logger.Ok(('检测到系统版 VSCode: ' + $version))
        return [pscustomobject]@{
            Name = 'VSCode'; Status = 'Skipped'; Version = $version; Path = $paths.SystemExe; Cli = $cli;
            Message = '已安装，跳过'; Blocker = $false
        }
    }

    if (Test-Path -LiteralPath $paths.UserExe) {
        if (-not $ReplaceUserInstall) {
            $message = '检测到用户级 VSCode（' + $paths.UserDir + '）。为避免两个版本并存，已停止。' +
                       '请先卸载用户版，或使用 -ReplaceUserInstall 让脚本静默卸载后安装系统版。'
            $Logger.Error($message)
            return [pscustomobject]@{
                Name = 'VSCode'; Status = 'Failed'; Version = (Get-VSCodeVersion -ExePath $paths.UserExe);
                Path = $paths.UserExe; Cli = $null; Message = $message; Blocker = $true
            }
        }

        $Logger.Step('检测到用户级 VSCode，准备静默卸载（-ReplaceUserInstall）')
        if ($DryRun) {
            $Logger.Detail('DryRun: 将卸载用户级 VSCode，然后安装系统版')
        }
        elseif (-not (Invoke-UserVSCodeUninstall -Context $Context -Logger $Logger -Paths $paths)) {
            return [pscustomobject]@{
                Name = 'VSCode'; Status = 'Failed'; Version = $null; Path = $paths.UserExe; Cli = $null;
                Message = '用户级 VSCode 卸载失败'; Blocker = $true
            }
        }
    }

    $asset = $null
    try {
        $asset = Get-PackAsset -Context $Context -Component 'vscode'
    }
    catch {
        return [pscustomobject]@{
            Name = 'VSCode'; Status = 'Failed'; Version = $null; Path = $null; Cli = $null;
            Message = $_.Exception.Message; Blocker = $true
        }
    }

    $assetVersion = [string](Get-PropertyValue -Object $asset.Data -Name 'version' -Default '')
    if (-not (Test-Path -LiteralPath $asset.FullPath)) {
        return [pscustomobject]@{
            Name = 'VSCode'; Status = 'Failed'; Version = $assetVersion; Path = $asset.FullPath; Cli = $null;
            Message = 'VSCode 安装包不存在，请重新运行 fetch-assets.ps1'; Blocker = $true
        }
    }

    if ($DryRun) {
        Add-PathEntry -Scope Machine -Entry $paths.BinDir -LogDir $Context.LogsDir -Logger $Logger -DryRun | Out-Null
        return [pscustomobject]@{
            Name = 'VSCode'; Status = 'Planned'; Version = $assetVersion; Path = $asset.FullPath; Cli = $paths.SystemCli;
            Message = '将静默安装系统版'; Blocker = $false
        }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $installerLog = Join-Path $Context.LogsDir ('vscode-install-' + $stamp + '.log')
    $mergeTasks = [string](Get-PropertyValue -Object $Context.Paths.VSCode -Name 'MergeTasks')
    $arguments = Get-VSCodeInstallerArguments -MergeTasks $mergeTasks -InstallDir $paths.SystemDir -LogPath $installerLog

    $Logger.Step('正在静默安装 VSCode ' + $assetVersion + '（系统级）')
    $Logger.Detail('安装日志: ' + $installerLog)

    try {
        $exitCode = Invoke-InstallerProcess -FilePath $asset.FullPath -Arguments $arguments -TimeoutSeconds 1800
    }
    catch {
        return [pscustomobject]@{
            Name = 'VSCode'; Status = 'Failed'; Version = $assetVersion; Path = $asset.FullPath; Cli = $null;
            Message = $_.Exception.Message; Blocker = $true
        }
    }

    if ($exitCode -ne 0) {
        $meaning = Get-InstallerExitMeaning -Product VSCode -ExitCode $exitCode
        return [pscustomobject]@{
            Name = 'VSCode'; Status = 'Failed'; Version = $assetVersion; Path = $asset.FullPath; Cli = $null;
            Message = ('安装失败: ' + $meaning + '（退出码 ' + $exitCode + '，日志 ' + $installerLog + '）'); Blocker = $true
        }
    }

    if (-not (Test-Path -LiteralPath $paths.SystemExe)) {
        return [pscustomobject]@{
            Name = 'VSCode'; Status = 'Failed'; Version = $assetVersion; Path = $paths.SystemExe; Cli = $null;
            Message = '安装程序返回成功，但未找到 Code.exe'; Blocker = $true
        }
    }

    $version = Get-VSCodeVersion -ExePath $paths.SystemExe
    $cli = Get-VSCodeCliPath -PreferredPath $paths.SystemCli
    Add-PathEntry -Scope Machine -Entry $paths.BinDir -LogDir $Context.LogsDir -Logger $Logger | Out-Null
    $Logger.Ok('VSCode 安装完成: ' + $version)

    return [pscustomobject]@{
        Name = 'VSCode'; Status = 'Installed'; Version = $version; Path = $paths.SystemExe; Cli = $cli;
        Message = '系统级安装完成'; Blocker = $false
    }
}

function Get-VSCodeStatus {
    param(
        [Parameter(Mandatory)]$Context,
        [string]$VSCodeDir = ''
    )
    $paths = Get-VSCodePaths -Context $Context -VSCodeDir $VSCodeDir
    $systemInstalled = Test-Path -LiteralPath $paths.SystemExe
    $userInstalled = Test-Path -LiteralPath $paths.UserExe
    $cli = $null
    if ($systemInstalled) { $cli = Get-VSCodeCliPath -PreferredPath $paths.SystemCli }
    return [pscustomobject]@{
        SystemInstalled = $systemInstalled
        UserInstalled   = $userInstalled
        SystemDir       = $paths.SystemDir
        SystemExe       = $paths.SystemExe
        UserExe         = $paths.UserExe
        Cli             = $cli
        Version         = (Get-VSCodeVersion -ExePath $paths.SystemExe)
        BinDir          = $paths.BinDir
    }
}
