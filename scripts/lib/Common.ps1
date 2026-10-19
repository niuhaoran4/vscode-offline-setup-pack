# Common host services: logging, identity, elevation, PATH registry, process execution.
# This file is dot-sourced by lib\Load.ps1. Keep the public surface small.

class PackLogger {
    [string]$LogFile
    [string]$Title
    [int]$Warnings
    [int]$Errors
    [System.Collections.Generic.List[object]]$Stages
    [System.Text.UTF8Encoding]$Utf8

    PackLogger([string]$logFile, [string]$title) {
        $this.LogFile = $logFile
        $this.Title = $title
        $this.Warnings = 0
        $this.Errors = 0
        $this.Stages = New-Object 'System.Collections.Generic.List[object]'
        $this.Utf8 = New-Object System.Text.UTF8Encoding($false)

        $dir = [System.IO.Path]::GetDirectoryName($logFile)
        if ($dir -and -not [System.IO.Directory]::Exists($dir)) {
            [System.IO.Directory]::CreateDirectory($dir) | Out-Null
        }
        [System.IO.File]::WriteAllText($logFile, '', $this.Utf8)
    }

    [void] WriteLine([string]$Level, [string]$Message, [string]$Color) {
        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $line = '[' + $timestamp + '] [' + $Level + '] ' + $Message
        [System.IO.File]::AppendAllText($this.LogFile, $line + [Environment]::NewLine, $this.Utf8)
        if ([string]::IsNullOrEmpty($Color)) {
            Write-Host $line
        }
        else {
            Write-Host $line -ForegroundColor $Color
        }
        if ($Level -eq 'WARN') { $this.Warnings++ }
        if ($Level -eq 'ERROR') { $this.Errors++ }
    }

    [void] Info([string]$Message) { $this.WriteLine('INFO', $Message, $null) }
    [void] Step([string]$Message) { $this.WriteLine('STEP', $Message, 'Cyan') }
    [void] Ok([string]$Message) { $this.WriteLine('OK', $Message, 'Green') }
    [void] Warn([string]$Message) { $this.WriteLine('WARN', $Message, 'Yellow') }
    [void] Error([string]$Message) { $this.WriteLine('ERROR', $Message, 'Red') }
    [void] Detail([string]$Message) { $this.WriteLine('DETAIL', $Message, 'DarkGray') }

    [void] Banner([string]$Message) {
        $line = ('=' * 78)
        [System.IO.File]::AppendAllText($this.LogFile, $line + [Environment]::NewLine + $Message + [Environment]::NewLine + $line + [Environment]::NewLine, $this.Utf8)
        Write-Host ''
        Write-Host $line -ForegroundColor DarkCyan
        Write-Host $Message -ForegroundColor Cyan
        Write-Host $line -ForegroundColor DarkCyan
        Write-Host ''
    }

    [void] Stage([string]$Name, [string]$Status, [string]$Message) {
        $this.Stages.Add([pscustomobject]@{ Name = $Name; Status = $Status; Message = $Message })
        $level = 'INFO'
        $color = 'Gray'
        if ($Status -eq 'Failed' -or $Status -eq 'Error') {
            $level = 'ERROR'
            $color = 'Red'
        }
        elseif ($Status -eq 'Warning' -or $Status -eq 'Skipped-Warn') {
            $level = 'WARN'
            $color = 'Yellow'
        }
        elseif ($Status -eq 'OK' -or $Status -eq 'Installed' -or $Status -eq 'Skipped') {
            $level = 'OK'
            $color = 'Green'
        }
        $this.WriteLine($level, (('{0}: {1}' -f $Name, $Status) + $(if ($Message) { ' - ' + $Message } else { '' })), $color)
    }

    [void] Summary() {
        Write-Host ''
        if ($this.Errors -gt 0) {
            Write-Host (('完成，但有 {0} 个错误、{1} 个警告。日志: {2}' -f $this.Errors, $this.Warnings, $this.LogFile)) -ForegroundColor Red
        }
        elseif ($this.Warnings -gt 0) {
            Write-Host (('完成，有 {0} 个警告。日志: {1}' -f $this.Warnings, $this.LogFile)) -ForegroundColor Yellow
        }
        else {
            Write-Host (('全部检查通过。日志: {0}' -f $this.LogFile)) -ForegroundColor Green
        }
    }
}

function Initialize-ConsoleEncoding {
    # Do not change [Console]::OutputEncoding: on a legacy Chinese console that
    # turns Write-Host text into mojibake. Log files are always UTF-8 no BOM.
    try { $global:OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }
}

function Test-IsAdministrator {
    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-CurrentUserSid {
    return [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-CurrentUserName {
    return [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Resolve-UserProfilePath {
    param([Parameter(Mandatory)][string]$Sid)
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $Sid
    if (Test-Path -LiteralPath $key) {
        try {
            $path = (Get-ItemProperty -LiteralPath $key -Name ProfileImagePath -ErrorAction Stop).ProfileImagePath
            if ($path) { return [Environment]::ExpandEnvironmentVariables($path) }
        }
        catch { }
    }
    return $null
}

function ConvertTo-CommandLineArgument {
    param([AllowNull()][string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }

    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Invoke-CapturedProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 120,
        [string]$WorkingDirectory,
        [hashtable]$Environment = @{}
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw ('找不到可执行文件: ' + $FilePath)
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (($ArgumentList | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    foreach ($key in $Environment.Keys) {
        $psi.EnvironmentVariables[[string]$key] = [string]$Environment[$key]
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $process.Start()) {
        throw ('无法启动进程: ' + $FilePath)
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $exited = $process.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)
    if (-not $exited) {
        try { $process.Kill() } catch { }
        try { $process.WaitForExit(5000) | Out-Null } catch { }
        throw ('进程超时（' + $TimeoutSeconds + ' 秒）: ' + $FilePath)
    }

    $stdout = ''
    $stderr = ''
    try { $stdout = $stdoutTask.Result } catch { }
    try { $stderr = $stderrTask.Result } catch { }
    $exitCode = $process.ExitCode
    $process.Dispose()

    $combined = ($stdout + $stderr).Trim()
    return [pscustomobject]@{
        ExitCode = $exitCode
        StdOut   = $stdout
        StdErr   = $stderr
        Output   = $combined
    }
}

function Invoke-InstallerProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Arguments,
        [int]$TimeoutSeconds = 1800
    )
    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw ('找不到安装程序: ' + $FilePath)
    }
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru
    if (-not $process.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)) {
        try { $process.Kill() } catch { }
        throw ('安装程序超时（' + $TimeoutSeconds + ' 秒）: ' + $FilePath)
    }
    $exitCode = $process.ExitCode
    $process.Dispose()
    return $exitCode
}

function Wait-ElevatedResult {
    param(
        [Parameter(Mandatory)][string]$ResultFile,
        [Parameter(Mandatory)][string]$RunId,
        [int]$TimeoutSeconds = 7200,
        [int]$PollMilliseconds = 500
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $ResultFile) {
            try {
                $result = ConvertFrom-Json -InputObject (Read-TextFile -Path $ResultFile)
                if ($result.runId -eq $RunId) {
                    return [pscustomobject]@{
                        ExitCode   = [int]$result.exitCode
                        Result     = $result
                        ResultFile = $ResultFile
                    }
                }
            }
            catch { }
        }
        Start-Sleep -Milliseconds ([Math]::Max(1, $PollMilliseconds))
    }

    return $null
}

function Invoke-ElevatedChild {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$ResultFile,
        [Parameter(Mandatory)][string]$RunId,
        [int]$TimeoutSeconds = 7200,
        [string]$Verb = 'runas'
    )

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powershell)) {
        throw ('找不到 Windows PowerShell: ' + $powershell)
    }

    $allArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $ArgumentList
    $argumentString = (($allArguments | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' ')

    # Start-Process -Verb RunAs has produced a PS 5.1 parameter-binding failure
    # ("PSCustomObject -> SwitchParameter") on some machines. Use ShellExecute
    # through ProcessStartInfo instead: there are no PowerShell switch parameters
    # involved, and the child still writes setup-result-<runId>.json in its finally
    # block, which is the only status source we read.
    try {
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $powershell
        $startInfo.Arguments = $argumentString
        $startInfo.WorkingDirectory = $WorkingDirectory
        $startInfo.UseShellExecute = $true
        if ($Verb) { $startInfo.Verb = $Verb }
        $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Normal
        $null = [System.Diagnostics.Process]::Start($startInfo)
    }
    catch {
        throw ('无法请求管理员权限（UAC 可能被拒绝）: ' + $_.Exception.Message)
    }

    $elevated = Wait-ElevatedResult -ResultFile $ResultFile -RunId $RunId -TimeoutSeconds $TimeoutSeconds
    if ($elevated) { return $elevated }

    throw ('提权进程超时（' + $TimeoutSeconds + ' 秒），未收到结果文件: ' + $ResultFile)
}

function Test-PlatformPrerequisites {
    param(
        [int]$MinimumOSBuild = 17763,
        [int]$MinimumFreeSpaceGB = 5,
        [string]$Drive = 'C'
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    $architecture = $env:PROCESSOR_ARCHITECTURE
    if ($env:PROCESSOR_ARCHITEW6432) { $architecture = $env:PROCESSOR_ARCHITEW6432 }
    if ($architecture -ne 'AMD64') {
        $problems.Add(('仅支持 x64 Windows，当前架构: ' + $architecture))
    }

    $build = [Environment]::OSVersion.Version.Build
    if ($build -lt $MinimumOSBuild) {
        $problems.Add(('Windows 版本过低: build ' + $build + '，需要 >= ' + $MinimumOSBuild + '（Windows 10 1809 或更高）'))
    }

    try {
        $driveInfo = New-Object System.IO.DriveInfo -ArgumentList $Drive
        $freeGB = [Math]::Round($driveInfo.AvailableFreeSpace / 1GB, 2)
        if ($freeGB -lt $MinimumFreeSpaceGB) {
            $problems.Add(('C 盘剩余空间不足: ' + $freeGB + ' GB，需要至少 ' + $MinimumFreeSpaceGB + ' GB'))
        }
    }
    catch {
        $warnings.Add(('无法读取 C 盘剩余空间: ' + $_.Exception.Message))
    }

    return [pscustomobject]@{
        Ok           = ($problems.Count -eq 0)
        Problems     = @(ConvertTo-PlainArray $problems)
        Warnings     = @(ConvertTo-PlainArray $warnings)
        Architecture = $architecture
        Build        = $build
    }
}

function Test-InstallDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MinimumFreeSpaceGB = 2,
        [string]$Label = '目录'
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]
    $full = $null

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $problems.Add($Label + ' 不能为空')
    }
    elseif ($Path -match '^\\\\') {
        $problems.Add($Label + ' 不支持 UNC 网络路径: ' + $Path)
    }
    elseif (-not [System.IO.Path]::IsPathRooted($Path)) {
        $problems.Add($Label + ' 必须是绝对路径: ' + $Path)
    }
    else {
        try {
            $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
        }
        catch {
            $problems.Add($Label + ' 路径无效: ' + $_.Exception.Message)
        }
    }

    if ($full) {
        if ($full -match '^[A-Za-z]:$') {
            $problems.Add($Label + ' 不能直接使用盘符根目录: ' + $full)
        }

        $systemRoot = ([System.IO.Path]::GetFullPath($env:SystemRoot)).TrimEnd('\')
        if ($full.Equals($systemRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($systemRoot + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
            $problems.Add($Label + ' 不能位于 Windows 目录下: ' + $full)
        }

        if ($full.Length -gt 100) {
            $warnings.Add($Label + ' 路径较长（' + $full.Length + ' 字符），建议使用短路径: ' + $full)
        }

        try {
            $drive = [System.IO.Path]::GetPathRoot($full).Substring(0, 2)
            $driveInfo = New-Object System.IO.DriveInfo -ArgumentList $drive
            if ($driveInfo.DriveType -ne [System.IO.DriveType]::Fixed) {
                $problems.Add($Label + ' 必须位于本地固定磁盘，当前类型: ' + $driveInfo.DriveType + '（' + $drive + '）')
            }
            else {
                if ($driveInfo.DriveFormat -ne 'NTFS') {
                    $warnings.Add($Label + ' 所在磁盘不是 NTFS（' + $driveInfo.DriveFormat + '），目录联接或权限可能受限')
                }
                if ($driveInfo.AvailableFreeSpace -lt ($MinimumFreeSpaceGB * 1GB)) {
                    $freeGB = [Math]::Round($driveInfo.AvailableFreeSpace / 1GB, 2)
                    $problems.Add($Label + ' 所在磁盘剩余空间不足: ' + $freeGB + ' GB，需要至少 ' + $MinimumFreeSpaceGB + ' GB')
                }
            }
        }
        catch {
            $problems.Add($Label + ' 无法读取磁盘信息: ' + $_.Exception.Message)
        }
    }

    return [pscustomobject]@{
        Ok       = ($problems.Count -eq 0)
        FullPath = $full
        Problems = @(ConvertTo-PlainArray $problems)
        Warnings = @(ConvertTo-PlainArray $warnings)
    }
}

function Get-PropertyValue {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function ConvertTo-PlainArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Collections.IList]) {
        if ($Value.GetType().IsGenericType) {
            try { return $Value.ToArray() } catch { }
        }
        return @($Value)
    }
    return @($Value)
}

function ConvertTo-ForwardSlash {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $Path }
    return $Path.Replace('\', '/')
}

function Read-TextFile {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][string]$Content
    )
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if ($dir -and -not [System.IO.Directory]::Exists($dir)) {
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Unblock-PackFiles {
    param(
        [Parameter(Mandatory)][string]$PackRoot,
        $Logger = $null
    )
    $count = 0
    try {
        foreach ($file in @(Get-ChildItem -LiteralPath $PackRoot -Recurse -File -ErrorAction SilentlyContinue)) {
            try {
                $null = Get-Item -LiteralPath $file.FullName -Stream 'Zone.Identifier' -ErrorAction Stop
                Unblock-File -LiteralPath $file.FullName -ErrorAction Stop
                $count++
            }
            catch { }
        }
    }
    catch {
        if ($Logger) { $Logger.Warn('解除文件锁定失败: ' + $_.Exception.Message) }
    }
    if ($Logger -and $count -gt 0) {
        $Logger.Info('已解除 ' + $count + ' 个文件的“来自其他计算机”标记')
    }
    return $count
}

function Test-JsonText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    try {
        $null = ConvertFrom-Json -InputObject $Text -ErrorAction Stop
        return [pscustomobject]@{ Ok = $true; Error = $null }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message }
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Split-PathList {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function ConvertTo-PathEntryNormalized {
    param([AllowNull()][string]$Entry)
    if ([string]::IsNullOrWhiteSpace($Entry)) { return '' }
    $value = $Entry.Trim().Trim('"')
    try { $value = [Environment]::ExpandEnvironmentVariables($value) } catch { }
    $value = $value.TrimEnd('\')

    # PATH can contain entries that are not valid paths at all (for example
    # pyenv-win shims such as: cscript //nologo "...\pyenv.vbs"\shims).
    # .NET Framework throws on IsPathRooted() for those entries; normalization
    # must not break PATH merging. Keep the raw entry for comparison/preservation.
    try {
        if ([System.IO.Path]::IsPathRooted($value)) {
            try { $value = [System.IO.Path]::GetFullPath($value).TrimEnd('\') } catch { }
        }
    }
    catch { }

    return $value.ToLowerInvariant()
}

function Merge-PathList {
    param(
        [AllowNull()][string]$CurrentValue,
        [Parameter(Mandatory)][string]$NewEntry
    )
    $entries = @(Split-PathList -Value $CurrentValue)
    $target = ConvertTo-PathEntryNormalized -Entry $NewEntry
    foreach ($entry in $entries) {
        if ((ConvertTo-PathEntryNormalized -Entry $entry) -eq $target) {
            return [pscustomobject]@{ Changed = $false; Value = ($entries -join ';'); Entry = $NewEntry }
        }
    }
    $entries += $NewEntry
    return [pscustomobject]@{ Changed = $true; Value = ($entries -join ';'); Entry = $NewEntry }
}

function Remove-PathEntryFromList {
    param(
        [AllowNull()][string]$CurrentValue,
        [Parameter(Mandatory)][string]$Entry
    )
    $entries = @(Split-PathList -Value $CurrentValue)
    $target = ConvertTo-PathEntryNormalized -Entry $Entry
    $kept = @($entries | Where-Object { (ConvertTo-PathEntryNormalized -Entry $_) -ne $target })
    $changed = ($kept.Count -ne $entries.Count)
    return [pscustomobject]@{ Changed = $changed; Value = ($kept -join ';') }
}

function Test-PathEntryPresent {
    param(
        [AllowNull()][string]$Value,
        [Parameter(Mandatory)][string]$Entry
    )
    $target = ConvertTo-PathEntryNormalized -Entry $Entry
    foreach ($item in @(Split-PathList -Value $Value)) {
        if ((ConvertTo-PathEntryNormalized -Entry $item) -eq $target) { return $true }
    }
    return $false
}

function Get-EnvironmentRegistryLocation {
    param([ValidateSet('Machine', 'User')][string]$Scope)
    if ($Scope -eq 'Machine') {
        return [pscustomobject]@{
            Hive    = [Microsoft.Win32.Registry]::LocalMachine
            SubKey  = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
            RegPath = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        }
    }
    return [pscustomobject]@{
        Hive    = [Microsoft.Win32.Registry]::CurrentUser
        SubKey  = 'Environment'
        RegPath = 'HKCU\Environment'
    }
}

function Get-EnvironmentPathValue {
    param([ValidateSet('Machine', 'User')][string]$Scope)
    $location = Get-EnvironmentRegistryLocation -Scope $Scope
    $key = $location.Hive.OpenSubKey($location.SubKey, $false)
    if (-not $key) { return '' }
    try {
        return [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    finally {
        $key.Close()
    }
}

function Set-EnvironmentPathValue {
    param(
        [ValidateSet('Machine', 'User')][string]$Scope,
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$LogDir
    )

    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    $location = Get-EnvironmentRegistryLocation -Scope $Scope
    $key = $location.Hive.OpenSubKey($location.SubKey, $true)
    if (-not $key) {
        $key = $location.Hive.CreateSubKey($location.SubKey)
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupBase = Join-Path $LogDir ('path-' + $Scope.ToLowerInvariant() + '-' + $timestamp)
    $backupTxt = $backupBase + '.txt'
    $backupReg = $backupBase + '.reg'
    $regError = $null

    try {
        $current = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        Write-Utf8NoBom -Path $backupTxt -Content $current

        $regExe = Join-Path $env:SystemRoot 'System32\reg.exe'
        $regResult = Invoke-CapturedProcess -FilePath $regExe -ArgumentList @('export', $location.RegPath, $backupReg, '/y') -TimeoutSeconds 30
        $regError = $null
        if ($regResult.ExitCode -ne 0) {
            $regError = $regResult.Output
        }

        $key.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    }
    finally {
        $key.Close()
    }

    return [pscustomobject]@{
        BackupTxt  = $backupTxt
        BackupReg  = $backupReg
        RegError   = $regError
    }
}

function Add-PathEntry {
    param(
        [ValidateSet('Machine', 'User')][Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Entry,
        [Parameter(Mandatory)][string]$LogDir,
        $Logger = $null,
        [switch]$DryRun
    )

    $current = Get-EnvironmentPathValue -Scope $Scope
    $merged = Merge-PathList -CurrentValue $current -NewEntry $Entry
    if (-not $merged.Changed) {
        if ($Logger) { $Logger.Detail(('PATH 已包含（跳过）: ' + $Entry)) }
        return [pscustomobject]@{ Scope = $Scope; Entry = $Entry; Changed = $false; Planned = $false; BackupTxt = $null }
    }

    if ($DryRun) {
        if ($Logger) { $Logger.Detail(('将追加 ' + $Scope + ' PATH: ' + $Entry)) }
        return [pscustomobject]@{ Scope = $Scope; Entry = $Entry; Changed = $true; Planned = $true; BackupTxt = $null }
    }

    $backup = Set-EnvironmentPathValue -Scope $Scope -Value $merged.Value -LogDir $LogDir
    if ($Logger) {
        $Logger.Info(('已追加 ' + $Scope + ' PATH: ' + $Entry))
        $Logger.Detail(('PATH 备份: ' + $backup.BackupTxt))
        if ($backup.RegError) { $Logger.Warn(('reg export 失败，文本备份仍可用: ' + $backup.RegError)) }
    }
    return [pscustomobject]@{ Scope = $Scope; Entry = $Entry; Changed = $true; Planned = $false; BackupTxt = $backup.BackupTxt }
}

function Remove-PathEntry {
    param(
        [ValidateSet('Machine', 'User')][Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Entry,
        [Parameter(Mandatory)][string]$LogDir,
        $Logger = $null,
        [switch]$DryRun
    )

    $current = Get-EnvironmentPathValue -Scope $Scope
    $result = Remove-PathEntryFromList -CurrentValue $current -Entry $Entry
    if (-not $result.Changed) {
        if ($Logger) { $Logger.Detail(('PATH 不含该项（跳过）: ' + $Entry)) }
        return [pscustomobject]@{ Scope = $Scope; Entry = $Entry; Changed = $false; Planned = $false }
    }

    if ($DryRun) {
        if ($Logger) { $Logger.Detail(('将移除 ' + $Scope + ' PATH: ' + $Entry)) }
        return [pscustomobject]@{ Scope = $Scope; Entry = $Entry; Changed = $true; Planned = $true }
    }

    $backup = Set-EnvironmentPathValue -Scope $Scope -Value $result.Value -LogDir $LogDir
    if ($Logger) {
        $Logger.Info(('已从 ' + $Scope + ' PATH 移除: ' + $Entry))
        $Logger.Detail(('PATH 备份: ' + $backup.BackupTxt))
    }
    return [pscustomobject]@{ Scope = $Scope; Entry = $Entry; Changed = $true; Planned = $false; BackupTxt = $backup.BackupTxt }
}

function Get-EffectivePath {
    param([switch]$Expand)
    $machine = Get-EnvironmentPathValue -Scope Machine
    $user = Get-EnvironmentPathValue -Scope User
    $value = (@($machine, $user) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ';'
    if ($Expand) {
        $value = [Environment]::ExpandEnvironmentVariables($value)
    }
    return $value
}

function Send-EnvironmentChanged {
    try {
        if (-not ('PackNativeEnvironment' -as [type])) {
            Add-Type -Namespace PackNativeEnvironment -Name NativeMethods -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
'@
        }
        $result = [IntPtr]::Zero
        [PackNativeEnvironment.NativeMethods]::SendMessageTimeout([IntPtr]0xffff, 0x001A, [IntPtr]::Zero, 'Environment', 2, 5000, [ref]$result) | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Get-InstallerExitMeaning {
    param(
        [ValidateSet('VSCode', 'Python')][string]$Product,
        [int]$ExitCode
    )
    if ($ExitCode -eq 0) { return '成功' }

    if ($Product -eq 'VSCode') {
        switch ($ExitCode) {
            1 { return '用户取消' }
            2 { return '安装程序致命错误' }
            3 { return '初始化失败' }
            4 { return '安装失败' }
            5 { return '需要重启' }
            default { return ('未知退出码 ' + $ExitCode) }
        }
    }

    switch ($ExitCode) {
        3010 { return '成功，需要重启' }
        1602 { return '用户取消' }
        1603 { return '安装失败' }
        1638 { return '已安装其他版本' }
        default { return ('未知退出码 ' + $ExitCode) }
    }
}

function Copy-DirectoryTree {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [int]$Threads = 8,
        [int]$TimeoutSeconds = 1800
    )
    $robocopy = Join-Path $env:SystemRoot 'System32\robocopy.exe'
    $result = Invoke-CapturedProcess -FilePath $robocopy -ArgumentList @(
        $Source, $Destination, '/E', '/COPY:DAT', '/R:1', '/W:1', ('/MT:' + $Threads),
        '/NFL', '/NDL', '/NJH', '/NJS', '/NP'
    ) -TimeoutSeconds $TimeoutSeconds
    if ($result.ExitCode -ge 8) {
        throw ('robocopy 复制失败（退出码 ' + $result.ExitCode + '）: ' + $Source + ' -> ' + $Destination)
    }
    return $result.ExitCode
}

function New-PackLogger {
    param(
        [Parameter(Mandatory)][string]$LogDir,
        [string]$Prefix = 'pack'
    )
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logFile = Join-Path $LogDir ($Prefix + '-' + $stamp + '.log')
    return [PackLogger]::new($logFile, $Prefix)
}
