# Per-user configuration module: backup, render settings, install VSIX closure, user PATH.
# This module must run as the target user, never as a different elevated administrator.

function Get-UserCodePaths {
    param(
        [string]$UserProfile = $env:USERPROFILE,
        [string]$AppData = $env:APPDATA
    )
    $codeRoot = Join-Path $AppData 'Code'
    $userDir = Join-Path $codeRoot 'User'
    return [pscustomobject]@{
        CodeRoot      = $codeRoot
        UserDir       = $userDir
        Settings      = (Join-Path $userDir 'settings.json')
        Keybindings   = (Join-Path $userDir 'keybindings.json')
        SnippetsDir   = (Join-Path $userDir 'snippets')
        Argv          = (Join-Path $codeRoot 'argv.json')
        ExtensionsDir = (Join-Path $UserProfile '.vscode\extensions')
    }
}

function Get-DefaultWorkDir {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not [string]::IsNullOrWhiteSpace($desktop)) {
        return (Join-Path $desktop 'work')
    }
    return (Join-Path $env:USERPROFILE 'work')
}

function Initialize-WorkDirectory {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Logger,
        [string]$WorkDir = '',
        [switch]$DryRun
    )

    if (-not $WorkDir) { $WorkDir = Get-DefaultWorkDir }
    if (-not [System.IO.Path]::IsPathRooted($WorkDir)) {
        throw ('工作目录必须是绝对路径: ' + $WorkDir)
    }

    $workPath = [System.IO.Path]::GetFullPath($WorkDir).TrimEnd('\')
    $vscodeDir = Join-Path $workPath '.vscode'
    $tasksPath = Join-Path $vscodeDir 'tasks.json'
    $pythonDir = Join-Path $workPath 'py'
    $templatePath = Join-Path $Context.ConfigDir 'work-tasks.json'
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw ('缺少工作目录模板: ' + $templatePath)
    }

    if ($DryRun) {
        $Logger.Detail('DryRun: 将创建/检查工作目录: ' + $workPath)
        return [pscustomobject]@{ WorkDir = $workPath; Tasks = $tasksPath; PythonDir = $pythonDir; Created = $false; Planned = $true }
    }

    New-Item -ItemType Directory -Path $vscodeDir, $pythonDir -Force | Out-Null
    $created = $false
    if (-not (Test-Path -LiteralPath $tasksPath)) {
        Copy-Item -LiteralPath $templatePath -Destination $tasksPath -Force
        $created = $true
        $Logger.Ok('已创建工作目录任务: ' + $tasksPath)
    }
    else {
        $Logger.Detail('工作目录任务已存在（跳过）: ' + $tasksPath)
    }
    $Logger.Info('工作目录: ' + $workPath)

    return [pscustomobject]@{ WorkDir = $workPath; Tasks = $tasksPath; PythonDir = $pythonDir; Created = $created; Planned = $false }
}

function ConvertFrom-JsoncText {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $Text = $Text.TrimStart([char]0xFEFF)
    $builder = New-Object System.Text.StringBuilder
    $inString = $false
    $escaped = $false
    $inLineComment = $false
    $inBlockComment = $false

    for ($i = 0; $i -lt $Text.Length; $i++) {
        $c = $Text[$i]
        $next = [char]0
        if ($i + 1 -lt $Text.Length) { $next = $Text[$i + 1] }

        if ($inLineComment) {
            if ($c -eq "`r" -or $c -eq "`n") {
                $inLineComment = $false
                [void]$builder.Append($c)
            }
            continue
        }
        if ($inBlockComment) {
            if ($c -eq '*' -and $next -eq '/') {
                $inBlockComment = $false
                $i++
            }
            continue
        }
        if ($inString) {
            [void]$builder.Append($c)
            if ($escaped) { $escaped = $false }
            elseif ($c -eq [char]92) { $escaped = $true }
            elseif ($c -eq '"') { $inString = $false }
            continue
        }
        if ($c -eq '"') {
            $inString = $true
            [void]$builder.Append($c)
            continue
        }
        if ($c -eq '/' -and $next -eq '/') {
            $inLineComment = $true
            $i++
            continue
        }
        if ($c -eq '/' -and $next -eq '*') {
            $inBlockComment = $true
            $i++
            continue
        }
        [void]$builder.Append($c)
    }

    $clean = $builder.ToString()
    $clean = $clean -replace ',\s*([}\]])', '$1'
    return $clean.Trim()
}

function Resolve-ConfigTemplate {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Template,
        [Parameter(Mandatory)][hashtable]$Values
    )
    $rendered = $Template
    foreach ($key in $Values.Keys) {
        $token = '{{' + [string]$key + '}}'
        $rendered = $rendered.Replace($token, [string]$Values[$key])
    }
    return $rendered
}

function Test-RenderedConfig {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $problems = New-Object System.Collections.Generic.List[string]
    if ($Text -match '\{\{[A-Z0-9_]+\}\}') {
        $matchesFound = [regex]::Matches($Text, '\{\{[A-Z0-9_]+\}\}') | ForEach-Object { $_.Value } | Select-Object -Unique
        $problems.Add(('存在未替换的占位符: ' + ($matchesFound -join ', ')))
    }
    $json = Test-JsonText -Text $Text
    if (-not $json.Ok) {
        $problems.Add(('JSON 无效: ' + $json.Error))
    }
    return [pscustomobject]@{ Ok = ($problems.Count -eq 0); Problems = @(ConvertTo-PlainArray $problems) }
}

function Backup-UserCodeDirectory {
    param(
        [Parameter(Mandatory)][string]$UserDir,
        [Parameter(Mandatory)][string]$LogDir,
        $Logger = $null
    )
    if (-not (Test-Path -LiteralPath $UserDir)) { return $null }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = $UserDir + '.backup.' + $stamp
    $counter = 1
    while (Test-Path -LiteralPath $backup) {
        $backup = $UserDir + '.backup.' + $stamp + '-' + $counter
        $counter++
    }

    if ($Logger) { $Logger.Step('正在备份 VSCode 用户配置: ' + $UserDir) }
    Copy-DirectoryTree -Source $UserDir -Destination $backup -Threads 2 -TimeoutSeconds 600 | Out-Null
    if ($Logger) { $Logger.Ok('配置备份完成: ' + $backup) }
    return $backup
}

function Invoke-CodeCli {
    param(
        [Parameter(Mandatory)][string]$CodeCli,
        [string[]]$Arguments = @()
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = & $CodeCli @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    catch {
        $lines = @($_.Exception.Message)
        $exitCode = 1
    }
    finally {
        $ErrorActionPreference = $previous
    }
    $output = (($lines | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    return [pscustomobject]@{ ExitCode = [int]$exitCode; Output = $output }
}

function Get-InstalledExtensionMap {
    param([Parameter(Mandatory)][string]$CodeCli)

    $result = Invoke-CodeCli -CodeCli $CodeCli -Arguments @('--list-extensions', '--show-versions')
    $map = @{}
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{ Ok = $false; Map = $map; Output = $result.Output; ExitCode = $result.ExitCode }
    }

    foreach ($line in ($result.Output -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ($trimmed -match '^(?<id>[^@\s]+)@(?<version>\S+)\s*$') {
            $map[$matches['id'].ToLowerInvariant()] = $matches['version']
        }
    }
    return [pscustomobject]@{ Ok = $true; Map = $map; Output = $result.Output; ExitCode = $result.ExitCode }
}

function Install-Extensions {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Logger,
        [Parameter(Mandatory)][string]$CodeCli,
        [switch]$Force,
        [switch]$DryRun
    )

    $assets = @(Get-PackExtensionAssets -Context $Context)
    if ($assets.Count -eq 0) {
        return [pscustomobject]@{ Ok = $true; Total = 0; Installed = 0; Skipped = 0; Failed = 0; Warnings = 0; Missing = @(); Message = 'manifest 中没有扩展，跳过' }
    }

    try {
        $ordered = @(Sort-ExtensionAssets -Extensions $assets)
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Total = $assets.Count; Installed = 0; Skipped = 0; Failed = 0; Missing = @(); Message = $_.Exception.Message }
    }

    $installedMap = @{}
    if (-not $DryRun) {
        $installedNow = Get-InstalledExtensionMap -CodeCli $CodeCli
        if (-not $installedNow.Ok) {
            $Logger.Error('无法读取已安装扩展列表: ' + $installedNow.Output)
        }
        else {
            $installedMap = $installedNow.Map
        }
    }

    $installedCount = 0
    $skippedCount = 0
    $failedCount = 0
    $installWarnings = 0

    foreach ($asset in $ordered) {
        $id = $asset.Id.ToLowerInvariant()
        if (-not (Test-Path -LiteralPath $asset.FullPath)) {
            $Logger.Error(('扩展文件不存在: ' + $asset.FullPath))
            $failedCount++
            continue
        }

        $currentVersion = $null
        if ($installedMap.ContainsKey($id)) { $currentVersion = $installedMap[$id] }
        if (-not $Force -and $currentVersion -eq $asset.Version) {
            $Logger.Detail(('扩展已安装（跳过）: ' + $asset.Id + '@' + $currentVersion))
            $skippedCount++
            continue
        }

        if ($DryRun) {
            $Logger.Detail(('DryRun: 将安装 ' + $asset.Id + '@' + $asset.Version))
            continue
        }

        $Logger.Step(('安装扩展 ' + $asset.Id + '@' + $asset.Version))
        $result = Invoke-CodeCli -CodeCli $CodeCli -Arguments @('--install-extension', $asset.FullPath, '--force')
        if ($result.ExitCode -ne 0) {
            # VSCode may return non-zero only because a dependency/pack member was
            # resolved from the marketplace and the machine is offline. The final
            # --list-extensions check below is the source of truth.
            $Logger.Warn(('扩展安装返回非零退出码: ' + $asset.Id + '（' + $result.ExitCode + '），以最终列表为准'))
            foreach ($line in ($result.Output -split "`r?`n")) {
                if ($line.Trim() -ne '') { $Logger.Detail('  ' + $line.Trim()) }
            }
            $installWarnings++
            continue
        }

        $Logger.Ok(('已安装扩展: ' + $asset.Id + '@' + $asset.Version))
        $installedCount++
    }

    if ($DryRun) {
        return [pscustomobject]@{
            Ok = $true; Total = $assets.Count; Installed = 0; Skipped = 0; Failed = 0; Warnings = 0; Missing = @();
            Message = 'DryRun，未实际安装'
        }
    }

    $after = Get-InstalledExtensionMap -CodeCli $CodeCli
    $missing = New-Object System.Collections.Generic.List[string]
    $verificationOk = $after.Ok
    if ($after.Ok) {
        foreach ($asset in $ordered) {
            if (-not $after.Map.ContainsKey($asset.Id.ToLowerInvariant())) {
                $missing.Add($asset.Id)
            }
        }
    }
    else {
        $Logger.Error('扩展安装后无法重新读取扩展列表: ' + $after.Output)
        $failedCount++
    }

    foreach ($id in $missing) {
        $Logger.Error(('扩展未生效: ' + $id))
        $failedCount++
    }

    $ok = ($verificationOk -and $failedCount -eq 0 -and $missing.Count -eq 0)
    return [pscustomobject]@{
        Ok        = $ok
        Total     = $assets.Count
        Installed = $installedCount
        Skipped   = $skippedCount
        Failed    = $failedCount
        Warnings  = $installWarnings
        Missing   = @(ConvertTo-PlainArray $missing)
        Message   = if ($ok) { '扩展全部就绪' } else { '存在扩展安装失败或缺失' }
    }
}

function Get-PythonUserScriptsDir {
    param([Parameter(Mandatory)][string]$PythonExe)

    $version = $null
    try {
        $result = Invoke-CapturedProcess -FilePath $PythonExe -ArgumentList @('-c', 'import sys; print(str(sys.version_info[0]) + str(sys.version_info[1]))') -TimeoutSeconds 30
        if ($result.ExitCode -eq 0) {
            $version = $result.Output.Trim()
        }
    }
    catch { }

    if (-not $version -or $version -notmatch '^\d{2,3}$') {
        $parent = Split-Path -Leaf (Split-Path -Parent $PythonExe)
        if ($parent -match 'Python(\d{2,3})') { $version = $matches[1] }
    }
    if (-not $version) { $version = '312' }

    $suffix = 'Python' + $version
    $scripts = Join-Path (Join-Path (Join-Path $env:APPDATA 'Python') $suffix) 'Scripts'
    return [Environment]::ExpandEnvironmentVariables($scripts)
}

function Write-UserSettings {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Logger,
        [Parameter(Mandatory)][string]$PythonExe,
        [Parameter(Mandatory)][string]$MinGWGcc,
        [Parameter(Mandatory)][string]$MinGWGdb,
        [string]$Locale,
        [switch]$DryRun
    )

    $paths = Get-UserCodePaths
    if (-not $DryRun) {
        foreach ($dir in @($paths.UserDir, $paths.SnippetsDir)) {
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
        }
    }

    $values = @{
        PYTHON_EXE   = (ConvertTo-ForwardSlash -Path $PythonExe)
        MINGW_GCC    = (ConvertTo-ForwardSlash -Path $MinGWGcc)
        MINGW_GDB    = (ConvertTo-ForwardSlash -Path $MinGWGdb)
        PACK_VERSION = [string]$Context.Version
        INSTALL_DATE = (Get-Date -Format 'yyyy-MM-dd')
    }

    $settingsTemplatePath = Join-Path $Context.ConfigDir 'settings.json'
    $settingsTemplate = Read-TextFile -Path $settingsTemplatePath
    $renderedSettings = Resolve-ConfigTemplate -Template $settingsTemplate -Values $values
    $validation = Test-RenderedConfig -Text $renderedSettings
    if (-not $validation.Ok) {
        throw ('settings.json 渲染失败: ' + ($validation.Problems -join '; '))
    }

    $keybindingsTemplatePath = Join-Path $Context.ConfigDir 'keybindings.json'
    $keybindingsTemplate = Read-TextFile -Path $keybindingsTemplatePath
    $keybindingsValidation = Test-RenderedConfig -Text $keybindingsTemplate
    if (-not $keybindingsValidation.Ok) {
        throw ('keybindings.json 无效: ' + ($keybindingsValidation.Problems -join '; '))
    }

    $snippetFiles = @(Get-ChildItem -LiteralPath (Join-Path $Context.ConfigDir 'snippets') -Filter '*.json' -File)
    foreach ($snippet in $snippetFiles) {
        $content = Read-TextFile -Path $snippet.FullName
        $snippetValidation = Test-RenderedConfig -Text $content
        if (-not $snippetValidation.Ok) {
            throw ('代码片段无效: ' + $snippet.Name + ' - ' + ($snippetValidation.Problems -join '; '))
        }
    }

    if ($DryRun) {
        $Logger.Detail('DryRun: settings.json 渲染与 JSON 校验通过')
        $Logger.Detail('DryRun: keybindings.json 与 snippets 校验通过')
        return [pscustomobject]@{ Settings = $paths.Settings; Keybindings = $paths.Keybindings; Snippets = @($snippetFiles.Name); Locale = $Locale }
    }

    Write-Utf8NoBom -Path $paths.Settings -Content $renderedSettings
    Write-Utf8NoBom -Path $paths.Keybindings -Content $keybindingsTemplate
    foreach ($snippet in $snippetFiles) {
        Write-Utf8NoBom -Path (Join-Path $paths.SnippetsDir $snippet.Name) -Content (Read-TextFile -Path $snippet.FullName)
    }

    $Logger.Ok('已写入 settings.json、keybindings.json 和 ' + $snippetFiles.Count + ' 个代码片段')

    if ($Locale) {
        $argvBackup = $null
        try {
            if (Test-Path -LiteralPath $paths.Argv) {
                $argvBackup = $paths.Argv + '.backup.' + (Get-Date -Format 'yyyyMMdd-HHmmss')
                Copy-Item -LiteralPath $paths.Argv -Destination $argvBackup -Force
                $argvText = Read-TextFile -Path $paths.Argv
                $argvObject = $null
                try {
                    $argvObject = ConvertFrom-Json -InputObject (ConvertFrom-JsoncText -Text $argvText)
                }
                catch {
                    $Logger.Warn('argv.json 无法解析，已备份并重建最小配置: ' + $argvBackup)
                    $argvObject = $null
                }
                if ($null -eq $argvObject) {
                    $argvObject = [pscustomobject]@{}
                }
            }
            else {
                $argvObject = [pscustomobject]@{}
            }

            $argvObject | Add-Member -NotePropertyName 'locale' -NotePropertyValue $Locale -Force
            Write-Utf8NoBom -Path $paths.Argv -Content ($argvObject | ConvertTo-Json -Depth 10)
            $Logger.Ok('已设置 VSCode 显示语言: ' + $Locale + '（完全退出 VSCode 后重新打开生效）')
        }
        catch {
            $Logger.Warn('设置显示语言失败: ' + $_.Exception.Message)
        }
    }

    return [pscustomobject]@{
        Settings    = $paths.Settings
        Keybindings = $paths.Keybindings
        Snippets    = @($snippetFiles.Name)
        Locale      = $Locale
    }
}

function Invoke-UserConfiguration {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Logger,
        [Parameter(Mandatory)][string]$PythonExe,
        [Parameter(Mandatory)][string]$MinGWGcc,
        [Parameter(Mandatory)][string]$MinGWGdb,
        [string]$CodeCli,
        [switch]$DryRun,
        [switch]$ForceExtensions,
        [switch]$NoBackup,
        [switch]$SkipSettings,
        [switch]$SkipExtensions,
        [switch]$SkipUserPath,
        [string]$Locale
    )

    $paths = Get-UserCodePaths
    $result = [pscustomobject]@{
        Backup          = $null
        Settings        = $null
        Extensions      = $null
        WorkDir         = $null
        UserPathChanged = $false
        Ok              = $true
    }

    $running = @(Get-RunningVSCodeProcesses)
    if ($running.Count -gt 0) {
        $Logger.Warn('检测到 VSCode 正在运行。配置会写入磁盘，但扩展安装后需要重启 VSCode 窗口才能生效。')
    }

    $workResult = Initialize-WorkDirectory -Context $Context -Logger $Logger -DryRun:$DryRun
    $result.WorkDir = $workResult.WorkDir

    if (-not $NoBackup -and -not $DryRun) {
        $result.Backup = Backup-UserCodeDirectory -UserDir $paths.UserDir -LogDir $Context.LogsDir -Logger $Logger
    }

    if (-not $SkipSettings) {
        $loggerSettings = Write-UserSettings -Context $Context -Logger $Logger -PythonExe $PythonExe -MinGWGcc $MinGWGcc -MinGWGdb $MinGWGdb -Locale $Locale -DryRun:$DryRun
        $result.Settings = $loggerSettings
    }

    if (-not $SkipUserPath) {
        $userScripts = Get-PythonUserScriptsDir -PythonExe $PythonExe
        $pathResult = Add-PathEntry -Scope User -Entry $userScripts -LogDir $Context.LogsDir -Logger $Logger -DryRun:$DryRun
        $result.UserPathChanged = [bool]$pathResult.Changed
    }

    if (-not $SkipExtensions) {
        if (-not $CodeCli) {
            $Logger.Error('找不到 code 命令行，无法安装扩展。请先确保系统版 VSCode 已安装。')
            $result.Extensions = [pscustomobject]@{ Ok = $false; Total = 0; Installed = 0; Skipped = 0; Failed = 1; Missing = @(); Message = '找不到 code CLI' }
            $result.Ok = $false
        }
        else {
            $extensionResult = Install-Extensions -Context $Context -Logger $Logger -CodeCli $CodeCli -Force:$ForceExtensions -DryRun:$DryRun
            $result.Extensions = $extensionResult
            if (-not $extensionResult.Ok) { $result.Ok = $false }
        }
    }

    Send-EnvironmentChanged | Out-Null
    return $result
}
