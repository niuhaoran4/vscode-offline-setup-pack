# Python product module: find an existing system Python, otherwise install 3.12 all-users.

function Find-SystemPython {
    param([Parameter(Mandatory)]$Context)

    $expectedDir = [string](Get-PropertyValue -Object $Context.Paths.Python -Name 'InstallDir')
    $expectedExe = Join-Path $expectedDir 'python.exe'
    if (Test-Path -LiteralPath $expectedExe) {
        return [pscustomobject]@{
            Found = $true; Exe = $expectedExe; InstallDir = $expectedDir; Source = 'default-path'
        }
    }

    $version = [string](Get-PropertyValue -Object $Context.Paths.Python -Name 'Version' -Default '3.12')
    $parts = $version.Split('.')
    $shortVersion = $parts[0] + '.' + $parts[1]

    foreach ($regPath in @(
        ('HKLM:\SOFTWARE\Python\PythonCore\' + $shortVersion + '\InstallPath'),
        ('HKLM:\SOFTWARE\WOW6432Node\Python\PythonCore\' + $shortVersion + '\InstallPath')
    )) {
        if (-not (Test-Path -LiteralPath $regPath)) { continue }
        try {
            $key = Get-Item -LiteralPath $regPath
            $installDir = [string]$key.GetValue('')
            $executable = [string]$key.GetValue('ExecutablePath')
            if (-not $executable -and $installDir) {
                $executable = Join-Path $installDir 'python.exe'
            }
            if ($executable -and (Test-Path -LiteralPath $executable)) {
                return [pscustomobject]@{
                    Found = $true; Exe = $executable; InstallDir = (Split-Path -Parent $executable); Source = 'registry'
                }
            }
        }
        catch { }
    }

    return [pscustomobject]@{ Found = $false; Exe = $null; InstallDir = $null; Source = $null }
}

function Get-PythonVersion {
    param([AllowNull()][AllowEmptyString()][string]$ExePath)
    if ([string]::IsNullOrWhiteSpace($ExePath) -or -not (Test-Path -LiteralPath $ExePath)) { return $null }
    try {
        $result = Invoke-CapturedProcess -FilePath $ExePath -ArgumentList @('--version') -TimeoutSeconds 30
        return $result.Output.Trim()
    }
    catch {
        return $null
    }
}

function Install-PythonProduct {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Logger,
        [switch]$DryRun
    )

    $existing = Find-SystemPython -Context $Context
    if ($existing.Found) {
        $version = Get-PythonVersion -ExePath $existing.Exe
        Add-PathEntry -Scope Machine -Entry $existing.InstallDir -LogDir $Context.LogsDir -Logger $Logger -DryRun:$DryRun | Out-Null
        $scriptsDir = Join-Path $existing.InstallDir 'Scripts'
        if (Test-Path -LiteralPath $scriptsDir) {
            Add-PathEntry -Scope Machine -Entry $scriptsDir -LogDir $Context.LogsDir -Logger $Logger -DryRun:$DryRun | Out-Null
        }
        $Logger.Ok(('检测到系统版 Python: ' + $version + ' -> ' + $existing.Exe))
        return [pscustomobject]@{
            Name = 'Python'; Status = 'Skipped'; Version = $version; Path = $existing.Exe;
            InstallDir = $existing.InstallDir; Message = '已安装，跳过'; Blocker = $false
        }
    }

    $asset = $null
    try {
        $asset = Get-PackAsset -Context $Context -Component 'python'
    }
    catch {
        return [pscustomobject]@{
            Name = 'Python'; Status = 'Failed'; Version = $null; Path = $null; InstallDir = $null;
            Message = $_.Exception.Message; Blocker = $true
        }
    }

    $assetVersion = [string](Get-PropertyValue -Object $asset.Data -Name 'version' -Default '')
    if (-not (Test-Path -LiteralPath $asset.FullPath)) {
        return [pscustomobject]@{
            Name = 'Python'; Status = 'Failed'; Version = $assetVersion; Path = $asset.FullPath; InstallDir = $null;
            Message = 'Python 安装包不存在，请重新运行 fetch-assets.ps1'; Blocker = $true
        }
    }

    if ($DryRun) {
        $expectedDir = [string](Get-PropertyValue -Object $Context.Paths.Python -Name 'InstallDir')
        return [pscustomobject]@{
            Name = 'Python'; Status = 'Planned'; Version = $assetVersion; Path = $asset.FullPath;
            InstallDir = $expectedDir; Message = '将安装系统版 Python'; Blocker = $false
        }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $installerLog = Join-Path $Context.LogsDir ('python-install-' + $stamp + '.log')
    $arguments = '/quiet InstallAllUsers=1 PrependPath=1 Include_launcher=1 InstallLauncherAllUsers=1 Include_test=0 SimpleInstall=1 /log "' + $installerLog + '"'

    $Logger.Step('正在静默安装 Python ' + $assetVersion + '（所有用户）')
    $Logger.Detail('安装日志: ' + $installerLog)

    try {
        $exitCode = Invoke-InstallerProcess -FilePath $asset.FullPath -Arguments $arguments -TimeoutSeconds 1800
    }
    catch {
        return [pscustomobject]@{
            Name = 'Python'; Status = 'Failed'; Version = $assetVersion; Path = $asset.FullPath; InstallDir = $null;
            Message = $_.Exception.Message; Blocker = $true
        }
    }

    $installed = Find-SystemPython -Context $Context
    if ($exitCode -ne 0 -and $exitCode -ne 3010 -and -not ($exitCode -eq 1638 -and $installed.Found)) {
        $meaning = Get-InstallerExitMeaning -Product Python -ExitCode $exitCode
        return [pscustomobject]@{
            Name = 'Python'; Status = 'Failed'; Version = $assetVersion; Path = $asset.FullPath; InstallDir = $null;
            Message = ('安装失败: ' + $meaning + '（退出码 ' + $exitCode + '，日志 ' + $installerLog + '）'); Blocker = $true
        }
    }

    if (-not $installed.Found) {
        return [pscustomobject]@{
            Name = 'Python'; Status = 'Failed'; Version = $assetVersion; Path = $asset.FullPath; InstallDir = $null;
            Message = '安装程序返回成功，但未找到系统版 python.exe'; Blocker = $true
        }
    }

    $pythonVersion = Get-PythonVersion -ExePath $installed.Exe
    Add-PathEntry -Scope Machine -Entry $installed.InstallDir -LogDir $Context.LogsDir -Logger $Logger | Out-Null
    $scriptsDir = Join-Path $installed.InstallDir 'Scripts'
    if (Test-Path -LiteralPath $scriptsDir) {
        Add-PathEntry -Scope Machine -Entry $scriptsDir -LogDir $Context.LogsDir -Logger $Logger | Out-Null
    }

    $Logger.Ok(('Python 安装完成: ' + $pythonVersion + ' -> ' + $installed.Exe))
    return [pscustomobject]@{
        Name = 'Python'; Status = 'Installed'; Version = $pythonVersion; Path = $installed.Exe;
        InstallDir = $installed.InstallDir; Message = '系统级安装完成'; Blocker = $false
    }
}

function Get-PythonStatus {
    param([Parameter(Mandatory)]$Context)
    $found = Find-SystemPython -Context $Context
    $all = @()
    try {
        $all = @(Get-Command 'python.exe' -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source)
    }
    catch { }
    $version = $null
    if ($found.Found -and $found.Exe) {
        $version = Get-PythonVersion -ExePath $found.Exe
    }
    return [pscustomobject]@{
        Found       = $found.Found
        Exe         = $found.Exe
        InstallDir  = $found.InstallDir
        Version     = $version
        AllCommands = $all
    }
}
