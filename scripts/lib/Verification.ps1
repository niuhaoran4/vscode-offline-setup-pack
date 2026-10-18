# Verification module: read-only checks plus a real compile/run/gdb smoke test.

function Test-PathEquivalent {
    param([AllowNull()][string]$Left, [AllowNull()][string]$Right)
    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) { return $false }
    try {
        $leftPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Left.Replace('/', '\')))
        $rightPath = [System.IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Right.Replace('/', '\')))
        return $leftPath.TrimEnd('\').Equals($rightPath.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)
    }
    catch {
        return ($Left.Trim().Replace('/', '\').ToLowerInvariant() -eq $Right.Trim().Replace('/', '\').ToLowerInvariant())
    }
}

function Get-CommandFirstSource {
    param([Parameter(Mandatory)][string]$Name)
    $previous = $env:Path
    try {
        $env:Path = Get-EffectivePath -Expand
        $command = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return $command.Source }
        return $null
    }
    finally {
        $env:Path = $previous
    }
}

function Add-VerificationCheck {
    param(
        [Parameter(Mandatory)]$Checks,
        [Parameter(Mandatory)]$Logger,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS', 'WARN', 'FAIL', 'SKIP')][string]$Status,
        [string]$Detail = '',
        [bool]$Critical = $true
    )
    $Checks.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail; Critical = $Critical })
    switch ($Status) {
        'PASS' { $Logger.Ok(('[' + $Status + '] ' + $Name + $(if ($Detail) { ' - ' + $Detail } else { '' }))) }
        'WARN' { $Logger.Warn(('[' + $Status + '] ' + $Name + $(if ($Detail) { ' - ' + $Detail } else { '' }))) }
        'FAIL' { $Logger.Error(('[' + $Status + '] ' + $Name + $(if ($Detail) { ' - ' + $Detail } else { '' }))) }
        'SKIP' { $Logger.Detail(('[' + $Status + '] ' + $Name + $(if ($Detail) { ' - ' + $Detail } else { '' }))) }
    }
}

function Invoke-SmokeTest {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Logger,
        [Parameter(Mandatory)][string]$GccPath,
        [Parameter(Mandatory)][string]$GdbPath
    )

    $temp = Join-Path $env:TEMP ('vscode-pack-smoke-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $temp -Force | Out-Null
        $source = Join-Path $temp 'hello.c'
        $exe = Join-Path $temp 'hello.exe'
        $code = '#include <stdio.h>' + [Environment]::NewLine + 'int main(void) { printf("PACK_SMOKE_OK\n"); return 0; }' + [Environment]::NewLine
        Write-Utf8NoBom -Path $source -Content $code

        $childEnvironment = @{ 'PATH' = (Get-EffectivePath -Expand) }
        $compile = Invoke-CapturedProcess -FilePath $GccPath -ArgumentList @('-g', $source, '-o', $exe) -TimeoutSeconds 120 -WorkingDirectory $temp -Environment $childEnvironment
        if ($compile.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
            return [pscustomobject]@{ Ok = $false; Stage = 'compile'; Detail = ('gcc 编译失败: ' + $compile.Output) }
        }

        $run = Invoke-CapturedProcess -FilePath $exe -ArgumentList @() -TimeoutSeconds 30 -WorkingDirectory $temp -Environment $childEnvironment
        if ($run.ExitCode -ne 0 -or $run.Output -notmatch 'PACK_SMOKE_OK') {
            return [pscustomobject]@{ Ok = $false; Stage = 'run'; Detail = ('编译产物运行失败: ' + $run.Output) }
        }

        $gdb = Invoke-CapturedProcess -FilePath $GdbPath -ArgumentList @('--batch', '-ex', 'run', '-ex', 'quit', $exe) -TimeoutSeconds 120 -WorkingDirectory $temp -Environment $childEnvironment
        if ($gdb.ExitCode -ne 0 -or $gdb.Output -notmatch 'PACK_SMOKE_OK') {
            return [pscustomobject]@{ Ok = $false; Stage = 'gdb'; Detail = ('gdb 调试失败: ' + $gdb.Output) }
        }

        return [pscustomobject]@{ Ok = $true; Stage = 'all'; Detail = 'gcc 编译、运行、gdb 批处理全部通过' }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Stage = 'exception'; Detail = $_.Exception.Message }
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            try { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

function Invoke-PackVerification {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Logger,
        [ValidateSet('All', 'Machine', 'User')][string]$Scope = 'All',
        [string]$VSCodeDir = '',
        [switch]$SkipExtensions,
        [switch]$SkipSmokeTest
    )

    $checks = New-Object System.Collections.Generic.List[object]
    $Logger.Banner('验证报告（Scope: ' + $Scope + '）')

    $checkMachine = ($Scope -eq 'All' -or $Scope -eq 'Machine')
    $checkUser = ($Scope -eq 'All' -or $Scope -eq 'User')

    if ($checkMachine) {
        $platform = Test-PlatformPrerequisites -MinimumOSBuild ([int]$Context.Paths.MinimumOSBuild) -MinimumFreeSpaceGB ([int]$Context.Paths.MinimumFreeSpaceGB)
        if ($platform.Ok) {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name '平台' -Status 'PASS' -Detail ('x64, Windows build ' + $platform.Build)
        }
        else {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name '平台' -Status 'FAIL' -Detail ($platform.Problems -join '; ')
        }
        foreach ($warning in $platform.Warnings) {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name '平台警告' -Status 'WARN' -Detail $warning -Critical $false
        }

        $vscode = Get-VSCodeStatus -Context $Context -VSCodeDir $VSCodeDir
        if ($vscode.SystemInstalled) {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'VSCode 系统版' -Status 'PASS' -Detail ($vscode.SystemExe + ' (' + $vscode.Version + ')')
        }
        elseif ($vscode.UserInstalled) {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'VSCode 系统版' -Status 'FAIL' -Detail ('只检测到用户级安装: ' + $vscode.UserExe + '；请用 -ReplaceUserInstall 重装')
        }
        else {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'VSCode 系统版' -Status 'FAIL' -Detail '未安装'
        }

        $codeCli = Get-VSCodeCliPath -PreferredPath $vscode.Cli
        if ($codeCli) {
            $codeResult = Invoke-CodeCli -CodeCli $codeCli -Arguments @('--version')
            if ($codeResult.ExitCode -eq 0) {
                $firstLine = (($codeResult.Output -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'code 命令' -Status 'PASS' -Detail ($firstLine + ' (' + $codeCli + ')')
            }
            else {
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'code 命令' -Status 'FAIL' -Detail $codeResult.Output
            }
        }
        else {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'code 命令' -Status 'FAIL' -Detail '找不到 code.cmd'
        }

        $python = Get-PythonStatus -Context $Context
        if ($python.Found) {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'Python 系统版' -Status 'PASS' -Detail ($python.Exe + ' (' + $python.Version + ')')
            $pythonFirst = Get-CommandFirstSource -Name 'python.exe'
            if ($pythonFirst -and (Test-PathEquivalent -Left $pythonFirst -Right $python.Exe)) {
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'python 命令解析' -Status 'PASS' -Detail $pythonFirst
            }
            else {
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'python 命令解析' -Status 'WARN' -Detail ('当前解析到: ' + $pythonFirst + '；期望: ' + $python.Exe + '（可能存在旧 Python 在 PATH 前面）') -Critical $false
            }
        }
        else {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'Python 系统版' -Status 'FAIL' -Detail '未安装'
        }

        $mingw = Get-MinGWStatus -Context $Context
        if ($mingw.Exists -and $mingw.Missing.Count -eq 0) {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'MinGW' -Status 'PASS' -Detail ($mingw.Gcc + '; ' + $mingw.Gdb)
            foreach ($name in @('gcc.exe', 'g++.exe', 'gdb.exe')) {
                $first = Get-CommandFirstSource -Name $name
                $expected = Join-Path $mingw.BinDir $name
                if ($first -and (Test-PathEquivalent -Left $first -Right $expected)) {
                    Add-VerificationCheck -Checks $checks -Logger $Logger -Name ($name + ' 命令解析') -Status 'PASS' -Detail $first
                }
                else {
                    Add-VerificationCheck -Checks $checks -Logger $Logger -Name ($name + ' 命令解析') -Status 'WARN' -Detail ('当前解析到: ' + $first + '；期望: ' + $expected) -Critical $false
                }
            }
            if ($mingw.OptionalMissing.Count -gt 0) {
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'MinGW 可选工具' -Status 'WARN' -Detail ('缺少: ' + ($mingw.OptionalMissing -join ', ')) -Critical $false
            }
        }
        else {
            $missingText = if ($mingw.Missing.Count -gt 0) { $mingw.Missing -join ', ' } else { 'gcc.exe' }
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'MinGW' -Status 'FAIL' -Detail ('缺少: ' + $missingText)
        }

        $machinePath = Get-EnvironmentPathValue -Scope Machine
        $pathChecks = @(
            @{ Name = 'VSCode bin'; Entry = $vscode.BinDir },
            @{ Name = 'Python'; Entry = $python.InstallDir },
            @{ Name = 'MinGW bin'; Entry = $mingw.BinDir }
        )
        foreach ($item in $pathChecks) {
            if (-not $item.Entry) {
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name ('系统 PATH: ' + $item.Name) -Status 'FAIL' -Detail ($item.Name + ' 未安装')
                continue
            }
            if (Test-PathEntryPresent -Value $machinePath -Entry $item.Entry) {
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name ('系统 PATH: ' + $item.Name) -Status 'PASS' -Detail $item.Entry
            }
            else {
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name ('系统 PATH: ' + $item.Name) -Status 'FAIL' -Detail ('缺少 ' + $item.Entry)
            }
        }

        if (-not $SkipSmokeTest -and $mingw.Exists -and $mingw.Missing.Count -eq 0) {
            $smoke = Invoke-SmokeTest -Context $Context -Logger $Logger -GccPath (Join-Path $mingw.BinDir 'gcc.exe') -GdbPath (Join-Path $mingw.BinDir 'gdb.exe')
            if ($smoke.Ok) {
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name '编译调试冒烟测试' -Status 'PASS' -Detail $smoke.Detail
            }
            else {
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name '编译调试冒烟测试' -Status 'FAIL' -Detail ($smoke.Stage + ': ' + $smoke.Detail)
            }
        }
        else {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name '编译调试冒烟测试' -Status 'SKIP' -Detail 'MinGW 不可用或已跳过' -Critical $false
        }
    }

    if ($checkUser) {
        $userPaths = Get-UserCodePaths

        $userDataTarget = Get-ReparsePointTarget -Path $userPaths.CodeRoot
        if ($userDataTarget) {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name '用户数据目录' -Status 'PASS' -Detail ('已重定向: ' + $userDataTarget) -Critical $false
        }
        else {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name '用户数据目录' -Status 'PASS' -Detail ('默认位置: ' + $userPaths.CodeRoot) -Critical $false
        }

        $extensionsTarget = Get-ReparsePointTarget -Path $userPaths.ExtensionsDir
        if ($extensionsTarget) {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name '扩展目录' -Status 'PASS' -Detail ('已重定向: ' + $extensionsTarget) -Critical $false
        }
        else {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name '扩展目录' -Status 'PASS' -Detail ('默认位置: ' + $userPaths.ExtensionsDir) -Critical $false
        }

        $codeCli = $null
        $vscodeStatus = Get-VSCodeStatus -Context $Context -VSCodeDir $VSCodeDir
        $codeCli = Get-VSCodeCliPath -PreferredPath $vscodeStatus.Cli

        $settingsPython = Get-PythonStatus -Context $Context
        $expectedPython = $settingsPython.Exe
        if (-not $expectedPython) {
            $expectedPython = Join-Path ([string](Get-PropertyValue -Object $Context.Paths.Python -Name 'InstallDir')) 'python.exe'
        }

        if (Test-Path -LiteralPath $userPaths.Settings) {
            $settingsText = Read-TextFile -Path $userPaths.Settings
            $settingsJson = Test-JsonText -Text $settingsText
            if (-not $settingsJson.Ok) {
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name '用户 settings.json' -Status 'FAIL' -Detail $settingsJson.Error
            }
            else {
                $settings = ConvertFrom-Json -InputObject $settingsText
                $pythonPath = [string](Get-PropertyValue -Object $settings -Name 'python.defaultInterpreterPath' -Default '')
                $compilerPath = [string](Get-PropertyValue -Object $settings -Name 'C_Cpp.default.compilerPath' -Default '')

                if ($pythonPath -and (Test-PathEquivalent -Left $pythonPath -Right $expectedPython)) {
                    Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'Python 解释器配置' -Status 'PASS' -Detail $pythonPath
                }
                else {
                    Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'Python 解释器配置' -Status 'FAIL' -Detail ('当前: ' + $pythonPath)
                }

                $mingwInstall = [string](Get-PropertyValue -Object $Context.Paths.MinGW -Name 'InstallDir')
                if ($compilerPath -and (Test-PathEquivalent -Left $compilerPath -Right (Join-Path $mingwInstall 'bin\gcc.exe'))) {
                    Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'C++ 编译器配置' -Status 'PASS' -Detail $compilerPath
                }
                else {
                    Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'C++ 编译器配置' -Status 'FAIL' -Detail ('当前: ' + $compilerPath)
                }

                $updateMode = [string](Get-PropertyValue -Object $settings -Name 'update.mode' -Default '')
                if ($updateMode -eq 'none') {
                    Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'VSCode 更新已锁定' -Status 'PASS' -Detail 'update.mode=none'
                }
                else {
                    Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'VSCode 更新已锁定' -Status 'WARN' -Detail ('update.mode=' + $updateMode) -Critical $false
                }
            }
        }
        else {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name '用户 settings.json' -Status 'FAIL' -Detail ('不存在: ' + $userPaths.Settings)
        }

        if (Test-Path -LiteralPath $userPaths.Keybindings) {
            $keybindings = Test-JsonText -Text (Read-TextFile -Path $userPaths.Keybindings)
            if ($keybindings.Ok) {
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'keybindings.json' -Status 'PASS' -Detail $userPaths.Keybindings
            }
            else {
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'keybindings.json' -Status 'FAIL' -Detail $keybindings.Error
            }
        }
        else {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'keybindings.json' -Status 'WARN' -Detail '不存在' -Critical $false
        }

        $packagedSnippets = @(Get-ChildItem -LiteralPath (Join-Path $Context.ConfigDir 'snippets') -Filter '*.json' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
        if (Test-Path -LiteralPath $userPaths.SnippetsDir) {
            $installedSnippets = @(Get-ChildItem -LiteralPath $userPaths.SnippetsDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            $missingSnippets = @($packagedSnippets | Where-Object { $installedSnippets -notcontains $_ })
            if ($missingSnippets.Count -eq 0) {
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name '代码片段' -Status 'PASS' -Detail ('包内 ' + $packagedSnippets.Count + ' 个片段已安装')
            }
            else {
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name '代码片段' -Status 'WARN' -Detail ('缺少: ' + ($missingSnippets -join ', ')) -Critical $false
            }
        }
        else {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name '代码片段' -Status 'WARN' -Detail '目录不存在' -Critical $false
        }

        if (-not $SkipExtensions) {
            $extensionAssets = @(Get-PackExtensionAssets -Context $Context)
            if ($extensionAssets.Count -eq 0) {
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name '扩展' -Status 'WARN' -Detail 'MANIFEST.json 未包含扩展（可能是用 -SkipExtensions 生成的包）' -Critical $false
            }
            elseif ($codeCli) {
                $installed = Get-InstalledExtensionMap -CodeCli $codeCli
                if (-not $installed.Ok) {
                    Add-VerificationCheck -Checks $checks -Logger $Logger -Name '扩展' -Status 'FAIL' -Detail $installed.Output
                }
                else {
                    $missing = New-Object System.Collections.Generic.List[string]
                    $versionMismatch = New-Object System.Collections.Generic.List[string]
                    foreach ($asset in $extensionAssets) {
                        $key = $asset.Id.ToLowerInvariant()
                        if (-not $installed.Map.ContainsKey($key)) {
                            $missing.Add($asset.Id)
                        }
                        elseif ($installed.Map[$key] -ne $asset.Version) {
                            $versionMismatch.Add(($asset.Id + ' 已装 ' + $installed.Map[$key] + '，包内 ' + $asset.Version))
                        }
                    }
                    if ($missing.Count -eq 0) {
                        Add-VerificationCheck -Checks $checks -Logger $Logger -Name '扩展' -Status 'PASS' -Detail ('包内 ' + $extensionAssets.Count + ' 个扩展均已安装')
                    }
                    else {
                        Add-VerificationCheck -Checks $checks -Logger $Logger -Name '扩展' -Status 'FAIL' -Detail ('缺少: ' + ($missing -join ', '))
                    }
                    foreach ($mismatch in $versionMismatch) {
                        Add-VerificationCheck -Checks $checks -Logger $Logger -Name '扩展版本' -Status 'WARN' -Detail $mismatch -Critical $false
                    }
                }
            }
            else {
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name '扩展' -Status 'FAIL' -Detail '找不到 code CLI'
            }
        }

        $userPath = Get-EnvironmentPathValue -Scope User
        $pythonStatus = Get-PythonStatus -Context $Context
        if ($pythonStatus.Found) {
            $scriptsDir = Get-PythonUserScriptsDir -PythonExe $pythonStatus.Exe
            if (Test-PathEntryPresent -Value $userPath -Entry $scriptsDir) {
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name '用户 PATH: pip --user Scripts' -Status 'PASS' -Detail $scriptsDir
            }
            else {
                Add-VerificationCheck -Checks $checks -Logger $Logger -Name '用户 PATH: pip --user Scripts' -Status 'WARN' -Detail ('缺少 ' + $scriptsDir + '（仅影响 pip install --user 的命令行工具）') -Critical $false
            }
        }

        if (@(Get-RunningVSCodeProcesses).Count -gt 0) {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name 'VSCode 运行状态' -Status 'WARN' -Detail 'VSCode 正在运行；扩展更新后请重启窗口' -Critical $false
        }
    }

    $exampleDir = Join-Path $Context.ExamplesDir 'hello-cpp'
    $exampleFiles = @(
        (Join-Path $exampleDir 'main.cpp'),
        (Join-Path $exampleDir '.vscode\tasks.json'),
        (Join-Path $exampleDir '.vscode\launch.json')
    )
    $missingExample = @($exampleFiles | Where-Object { -not (Test-Path -LiteralPath $_) })
    if ($missingExample.Count -eq 0) {
        $tasksJson = Test-JsonText -Text (Read-TextFile -Path (Join-Path $exampleDir '.vscode\tasks.json'))
        $launchJson = Test-JsonText -Text (Read-TextFile -Path (Join-Path $exampleDir '.vscode\launch.json'))
        if ($tasksJson.Ok -and $launchJson.Ok) {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name '示例工程' -Status 'PASS' -Detail 'examples\hello-cpp 可直接 F5'
        }
        else {
            Add-VerificationCheck -Checks $checks -Logger $Logger -Name '示例工程' -Status 'FAIL' -Detail 'tasks.json 或 launch.json 无效'
        }
    }
    else {
        Add-VerificationCheck -Checks $checks -Logger $Logger -Name '示例工程' -Status 'WARN' -Detail ('缺少: ' + ($missingExample -join ', ')) -Critical $false
    }

    $failures = @($checks | Where-Object { $_.Status -eq 'FAIL' -and $_.Critical })
    $warnings = @($checks | Where-Object { $_.Status -eq 'WARN' })
    $report = [pscustomobject]@{
        schemaVersion = 1
        generatedAt   = (Get-Date).ToString('o')
        scope         = $Scope
        ok            = ($failures.Count -eq 0)
        failures      = $failures.Count
        warnings      = $warnings.Count
        checks        = @(ConvertTo-PlainArray $checks)
    }

    $reportPath = Join-Path $Context.LogsDir ('verify-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    Write-Utf8NoBom -Path $reportPath -Content ($report | ConvertTo-Json -Depth 10)
    $Logger.Info('验证报告已写入: ' + $reportPath)

    return [pscustomobject]@{ Ok = ($failures.Count -eq 0); Checks = @(ConvertTo-PlainArray $checks); Failures = $failures; Warnings = $warnings; ReportPath = $reportPath }
}
