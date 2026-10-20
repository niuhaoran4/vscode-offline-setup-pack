[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\Load.ps1')

$script:Passed = 0
$script:Failed = 0
$script:FailureMessages = New-Object System.Collections.Generic.List[string]

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ($Expected -ne $Actual) {
        throw ($Message + '（期望=' + [string]$Expected + '，实际=' + [string]$Actual + '）')
    }
}

function Assert-Throws {
    param([scriptblock]$Body, [string]$Message)
    $threw = $false
    try { & $Body } catch { $threw = $true }
    if (-not $threw) { throw ($Message + '（没有抛出异常）') }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host ('[PASS] ' + $Name) -ForegroundColor Green
    }
    catch {
        $script:Failed++
        $script:FailureMessages.Add($Name + ': ' + $_.Exception.Message)
        Write-Host ('[FAIL] ' + $Name + ' - ' + $_.Exception.Message) -ForegroundColor Red
    }
}

$packRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$tempRoot = Join-Path $env:TEMP ('vscode-pack-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    Test-Case 'ConvertTo-PlainArray 处理泛型列表与 null' {
        $list = New-Object System.Collections.Generic.List[object]
        $list.Add('a')
        $list.Add('b')
        $array = @(ConvertTo-PlainArray $list)
        Assert-Equal 2 $array.Count '泛型列表元素数'
        Assert-Equal 0 @(ConvertTo-PlainArray $null).Count 'null 应变为空数组'

        $strings = New-Object System.Collections.Generic.List[string]
        $strings.Add('x')
        Assert-Equal 1 @(ConvertTo-PlainArray $strings).Count '字符串列表元素数'
    }

    Test-Case 'Merge-PathList 追加、去重并保留变量' {
        $result = Merge-PathList -CurrentValue 'C:\Windows;%SystemRoot%\System32' -NewEntry 'C:\mingw64\bin'
        Assert-True $result.Changed '应追加新路径'
        Assert-True ($result.Value -like '*;C:\mingw64\bin') '新路径应在末尾'
        Assert-True ($result.Value -like '*%SystemRoot%\System32*') '应保留原有变量写法'

        $duplicate = Merge-PathList -CurrentValue $result.Value -NewEntry 'c:/MINGW64/bin/'
        Assert-True (-not $duplicate.Changed) '大小写和尾部斜杠不应造成重复'

        $quoted = Merge-PathList -CurrentValue '' -NewEntry '"C:\Program Files\Python312"'
        Assert-True ($quoted.Value -eq '"C:\Program Files\Python312"') '应保留带引号的原始写法'
    }

    Test-Case 'Remove-PathEntryFromList 精确移除' {
        $result = Remove-PathEntryFromList -CurrentValue 'C:\A;c:\b\;C:\C' -Entry 'C:\B'
        Assert-True $result.Changed '应检测到移除'
        Assert-Equal 'C:\A;C:\C' $result.Value '移除后的值'
    }

    Test-Case 'Get-PropertyValue 支持哈希表和对象' {
        $hash = @{ InstallDir = 'C:\X' }
        Assert-Equal 'C:\X' (Get-PropertyValue -Object $hash -Name 'InstallDir') '哈希表读取'
        Assert-Equal 'fallback' (Get-PropertyValue -Object $hash -Name 'Missing' -Default 'fallback') '哈希表默认值'

        $object = [pscustomobject]@{ value = 42 }
        Assert-Equal 42 (Get-PropertyValue -Object $object -Name 'value') '对象读取'
    }

    Test-Case '路径规范化与等价比较' {
        Assert-True (Test-PathEquivalent -Left 'C:/mingw64/bin' -Right 'C:\mingw64\bin\') '正反斜杠和尾部斜杠'
        Assert-True (-not (Test-PathEquivalent -Left 'C:\mingw64\bin' -Right 'C:\msys64\bin')) '不同路径'
        Assert-Equal 'C:/Program Files/Python312/python.exe' (ConvertTo-ForwardSlash -Path 'C:\Program Files\Python312\python.exe') '正斜杠转换'
    }

    Test-Case 'settings.json 模板渲染为有效 JSON' {
        $template = Read-TextFile -Path (Join-Path $packRoot 'config\settings.json')
        $values = @{
            PYTHON_EXE   = 'C:/Program Files/Python312/python.exe'
            MINGW_GCC    = 'C:/mingw64/bin/gcc.exe'
            MINGW_GDB    = 'C:/mingw64/bin/gdb.exe'
            PACK_VERSION = '1.0.0'
            INSTALL_DATE = '2026-10-18'
        }
        $rendered = Resolve-ConfigTemplate -Template $template -Values $values
        $validation = Test-RenderedConfig -Text $rendered
        Assert-True $validation.Ok ('渲染结果应有效: ' + ($validation.Problems -join '; '))
        $json = ConvertFrom-Json -InputObject $rendered
        Assert-Equal 'C:/Program Files/Python312/python.exe' $json.'python.defaultInterpreterPath' 'Python 解释器路径'
        Assert-Equal 'windows-gcc-x64' $json.'C_Cpp.default.intelliSenseMode' 'IntelliSense 模式'
    }

    Test-Case '未替换占位符会被拒绝' {
        $result = Test-RenderedConfig -Text '{ "x": "{{MISSING}}" }'
        Assert-True (-not $result.Ok) '应报告未替换占位符'
    }

    Test-Case 'keybindings 与 snippets 均为有效 JSON' {
        Assert-True (Test-JsonText -Text (Read-TextFile -Path (Join-Path $packRoot 'config\keybindings.json'))).Ok 'keybindings'
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $packRoot 'config\snippets') -Filter '*.json')) {
            Assert-True (Test-JsonText -Text (Read-TextFile -Path $file.FullName)).Ok ('snippet ' + $file.Name)
        }
    }

    Test-Case '扩展拓扑排序：依赖在前' {
        $assets = @(
            [pscustomobject]@{ id = 'b'; dependsOn = @('a') }
            [pscustomobject]@{ id = 'a'; dependsOn = @() }
            [pscustomobject]@{ id = 'c'; dependsOn = @('b', 'a') }
        )
        $sorted = @(Sort-ExtensionAssets -Extensions $assets)
        Assert-Equal 3 $sorted.Count '排序结果数量'
        Assert-Equal 'a,b,c' (($sorted | ForEach-Object { $_.id }) -join ',') '排序顺序'
    }

    Test-Case '扩展排序拒绝缺失依赖与循环' {
        Assert-Throws { Sort-ExtensionAssets -Extensions @([pscustomobject]@{ id = 'a'; dependsOn = @('missing') }) } '缺失依赖应抛出'
        Assert-Throws {
            Sort-ExtensionAssets -Extensions @(
                [pscustomobject]@{ id = 'a'; dependsOn = @('b') }
                [pscustomobject]@{ id = 'b'; dependsOn = @('a') }
            )
        } '循环依赖应抛出'
    }

    Test-Case 'manifests：有效清单通过、无效清单被拒绝' {
        $hash = 'a' * 64
        $base = [pscustomobject]@{
            schemaVersion = 1
            platform = 'win32-x64'
            components = [pscustomobject]@{
                vscode = [pscustomobject]@{ version = '1.0.0'; file = 'installer/v.exe'; sha256 = $hash }
                python = [pscustomobject]@{ version = '3.12.10'; file = 'installer/p.exe'; sha256 = $hash }
                mingw  = [pscustomobject]@{ version = 'gcc'; file = 'tools/m.7z'; sha256 = $hash }
                sevenZip = [pscustomobject]@{ version = '7zr'; file = 'tools/7zr.exe'; sha256 = $hash }
            }
            extensions = @(
                [pscustomobject]@{ id = 'pub.ext'; version = '1.0.0'; file = 'extensions/e.vsix'; sha256 = $hash; installOrder = 0; dependsOn = @() }
            )
        }
        Assert-True (Test-ManifestObject -Manifest $base).Ok '有效清单应通过'

        $badHash = [pscustomobject]@{
            schemaVersion = 1
            platform = 'win32-x64'
            components = [pscustomobject]@{
                vscode = [pscustomobject]@{ version = '1.0.0'; file = '../v.exe'; sha256 = 'bad' }
                python = [pscustomobject]@{ version = '3.12.10'; file = 'installer/p.exe'; sha256 = $hash }
                mingw  = [pscustomobject]@{ version = 'gcc'; file = 'tools/m.7z'; sha256 = $hash }
            }
            extensions = @(
                [pscustomobject]@{ id = 'pub.ext'; version = '1.0.0'; file = 'extensions/e.vsix'; sha256 = $hash; installOrder = 0 }
                [pscustomobject]@{ id = 'pub.ext'; version = '2.0.0'; file = 'extensions/e2.vsix'; sha256 = $hash; installOrder = 1 }
            )
        }
        Assert-True (-not (Test-ManifestObject -Manifest $badHash).Ok) '无效清单应被拒绝'
    }

    Test-Case '安全路径校验阻止目录穿越' {
        Assert-True (Test-SafeRelativePath -Path 'installer\a.exe') '普通相对路径'
        Assert-True (-not (Test-SafeRelativePath -Path '..\evil.exe')) '.. 穿越'
        Assert-True (-not (Test-SafeRelativePath -Path 'C:\evil.exe')) '绝对路径'
        Assert-True (-not (Test-SafeRelativePath -Path '/etc/passwd')) '根路径'
    }

    Test-Case 'IP 地址分类拒绝环回、私有和保留地址' {
        Assert-True (Test-PublicIpAddress -Address ([System.Net.IPAddress]::Parse('8.8.8.8'))) '8.8.8.8'
        Assert-True (-not (Test-PublicIpAddress -Address ([System.Net.IPAddress]::Parse('10.0.0.1')))) '10.0.0.1'
        Assert-True (-not (Test-PublicIpAddress -Address ([System.Net.IPAddress]::Parse('127.0.0.1')))) '127.0.0.1'
        Assert-True (-not (Test-PublicIpAddress -Address ([System.Net.IPAddress]::Parse('192.168.1.1')))) '192.168.1.1'
        Assert-True (-not (Test-PublicIpAddress -Address ([System.Net.IPAddress]::Parse('169.254.1.1')))) '169.254.1.1'
        Assert-True (-not (Test-PublicIpAddress -Address ([System.Net.IPAddress]::Parse('224.0.0.1')))) '224.0.0.1'
        Assert-True (-not (Test-PublicIpAddress -Address ([System.Net.IPAddress]::Parse('::1')))) '::1'
        Assert-True (-not (Test-PublicIpAddress -Address ([System.Net.IPAddress]::Parse('fc00::1')))) 'fc00::1'
        Assert-True (-not (Test-PublicIpAddress -Address ([System.Net.IPAddress]::Parse('2001:db8::1')))) '2001:db8::1'
    }

    Test-Case 'URL 安全校验阻止 localhost 和非公网地址' {
        Assert-Throws { Assert-SafeDownloadUrl -Url 'http://localhost/a' -SkipDnsCheck } 'localhost'
        Assert-Throws { Assert-SafeDownloadUrl -Url 'https://127.0.0.1/a' -SkipDnsCheck } '127.0.0.1'
        Assert-Throws { Assert-SafeDownloadUrl -Url 'https://10.1.2.3/a' -SkipDnsCheck } '10.1.2.3'
        Assert-Throws { Assert-SafeDownloadUrl -Url 'https://192.168.0.1/a' -SkipDnsCheck } '192.168.0.1'
        Assert-Throws { Assert-SafeDownloadUrl -Url 'https://172.16.0.1/a' -SkipDnsCheck } '172.16.0.1'
        Assert-Throws { Assert-SafeDownloadUrl -Url 'https://169.254.1.1/a' -SkipDnsCheck } '169.254.1.1'
        Assert-Throws { Assert-SafeDownloadUrl -Url 'https://[::1]/a' -SkipDnsCheck } 'IPv6 loopback'
        Assert-Throws { Assert-SafeDownloadUrl -Url 'ftp://example.com/a' -SkipDnsCheck } '非 http/https'
        $ok = Assert-SafeDownloadUrl -Url 'https://example.com/a' -SkipDnsCheck
        Assert-True ($null -ne $ok) '公网域名应允许'
    }

    Test-Case '文件魔数识别 MZ / ZIP / 7Z' {
        $mz = Join-Path $tempRoot 'a.exe'
        $zip = Join-Path $tempRoot 'a.zip'
        $seven = Join-Path $tempRoot 'a.7z'
        [System.IO.File]::WriteAllBytes($mz, [byte[]](0x4D, 0x5A, 0x00, 0x00))
        [System.IO.File]::WriteAllBytes($zip, [byte[]](0x50, 0x4B, 0x03, 0x04))
        [System.IO.File]::WriteAllBytes($seven, [byte[]](0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C))
        Assert-True (Test-FileMagic -Path $mz -Expected MZ) 'MZ'
        Assert-True (Test-FileMagic -Path $zip -Expected ZIP) 'ZIP'
        Assert-True (Test-FileMagic -Path $seven -Expected 7Z) '7Z'
        Assert-True (-not (Test-FileMagic -Path $zip -Expected MZ)) 'ZIP 不应被识别为 MZ'
    }

    Test-Case 'VSIX 包内 ID 与版本校验' {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $source = Join-Path $tempRoot 'vsix-src'
        $extensionDir = Join-Path $source 'extension'
        New-Item -ItemType Directory -Path $extensionDir -Force | Out-Null
        $package = [pscustomobject]@{ publisher = 'pub'; name = 'ext'; version = '1.0.0' }
        Write-Utf8NoBom -Path (Join-Path $extensionDir 'package.json') -Content ($package | ConvertTo-Json -Depth 5)
        $vsix = Join-Path $tempRoot 'pub.ext-1.0.0.vsix'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($source, $vsix, [System.IO.Compression.CompressionLevel]::Optimal, $false)

        $info = Test-VsixPackageInfo -Path $vsix -ExpectedId 'pub.ext' -ExpectedVersion '1.0.0'
        Assert-True $info.Ok ('应通过: ' + $info.Error)
        $wrong = Test-VsixPackageInfo -Path $vsix -ExpectedId 'pub.other'
        Assert-True (-not $wrong.Ok) '错误 ID 应被拒绝'
    }

    Test-Case '扩展闭包打破 pack 环并按成员优先排序' {
        $extensionsDir = Join-Path $tempRoot 'extensions'
        $rootDir = Join-Path $extensionsDir 'ms-a.root-1.0.0-win32-x64'
        $memberDir = Join-Path $extensionsDir 'ms-a.member-1.0.0-win32-x64'
        $otherDir = Join-Path $extensionsDir 'ms-a.other-1.0.0-win32-x64'
        foreach ($dir in @($rootDir, $memberDir, $otherDir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

        Write-Utf8NoBom -Path (Join-Path $rootDir 'package.json') -Content (@{ publisher = 'ms'; name = 'a.root'; version = '1.0.0'; extensionPack = @('ms.a.member') } | ConvertTo-Json -Depth 5)
        Write-Utf8NoBom -Path (Join-Path $memberDir 'package.json') -Content (@{ publisher = 'ms'; name = 'a.member'; version = '1.0.0'; extensionDependencies = @('ms.a.root') } | ConvertTo-Json -Depth 5)
        Write-Utf8NoBom -Path (Join-Path $otherDir 'package.json') -Content (@{ publisher = 'ms'; name = 'a.other'; version = '1.0.0' } | ConvertTo-Json -Depth 5)

        $resolved = @(Resolve-ExtensionsFromDirectory -ExtensionsDir $extensionsDir -Roots @('ms.a.root'))
        Assert-Equal 2 $resolved.Count '闭包应包含根与成员'
        Assert-Equal 'ms.a.member' $resolved[0].Id '成员应先安装'
        Assert-Equal 'ms.a.root' $resolved[1].Id 'pack 最后安装'
        Assert-Equal 0 @($resolved[0].DependsOn).Count '成员到 pack 的环边应被移除'
    }

    Test-Case '安装器退出码解释' {
        Assert-Equal '成功' (Get-InstallerExitMeaning -Product Python -ExitCode 0) '0'
        Assert-Equal '成功，需要重启' (Get-InstallerExitMeaning -Product Python -ExitCode 3010) '3010'
        Assert-Equal '用户取消' (Get-InstallerExitMeaning -Product VSCode -ExitCode 1) 'VSCode 1'
        Assert-Equal '已安装其他版本' (Get-InstallerExitMeaning -Product Python -ExitCode 1638) '1638'
    }

    Test-Case '扩展文件名清理非法字符' {
        $name = Get-ExtensionFileName -Id 'pub/../evil' -Version '1.0.0' -TargetPlatform 'win32-x64'
        Assert-True ($name -notmatch '[\\/]') '文件名不应包含路径分隔符'
        Assert-True ($name -like '*.vsix') '应保留 .vsix 后缀'
    }

    Test-Case 'Wait-ElevatedResult 读取匹配的结果文件' {
        $runId = [guid]::NewGuid().ToString('N')
        $file = Join-Path $tempRoot ('setup-result-' + $runId + '.json')
        $payload = [pscustomobject]@{
            runId    = $runId
            exitCode = 0
            stages   = @([pscustomobject]@{ Name = 'VSCode'; Status = 'Installed'; Message = 'ok' })
        }
        Write-Utf8NoBom -Path $file -Content ($payload | ConvertTo-Json -Depth 5)

        $result = Wait-ElevatedResult -ResultFile $file -RunId $runId -TimeoutSeconds 5 -PollMilliseconds 50
        Assert-True ($null -ne $result) '应返回结果对象'
        Assert-Equal 0 $result.ExitCode '退出码'
        Assert-Equal 'Installed' $result.Result.stages[0].Status '阶段状态'
    }

    Test-Case 'Wait-ElevatedResult 拒绝不匹配的 runId 并超时' {
        $runId = [guid]::NewGuid().ToString('N')
        $otherRunId = [guid]::NewGuid().ToString('N')
        $file = Join-Path $tempRoot ('setup-result-' + $otherRunId + '.json')
        Write-Utf8NoBom -Path $file -Content ([pscustomobject]@{ runId = $otherRunId; exitCode = 1 } | ConvertTo-Json)

        $result = Wait-ElevatedResult -ResultFile $file -RunId $runId -TimeoutSeconds 1 -PollMilliseconds 50
        Assert-True ($null -eq $result) '不匹配的 runId 不应被接受'
    }

    Test-Case 'Test-InstallDirectory 校验绝对路径和固定磁盘' {
        $ok = Test-InstallDirectory -Path $tempRoot -MinimumFreeSpaceGB 0.1 -Label 'test'
        Assert-True $ok.Ok ('临时目录应有效: ' + ($ok.Problems -join '; '))

        Assert-True (-not (Test-InstallDirectory -Path 'relative\dir' -MinimumFreeSpaceGB 0.1 -Label 'test').Ok) '相对路径应被拒绝'
        Assert-True (-not (Test-InstallDirectory -Path '\\server\share' -MinimumFreeSpaceGB 0.1 -Label 'test').Ok) 'UNC 应被拒绝'
        Assert-True (-not (Test-InstallDirectory -Path ($env:SystemDrive + '\') -MinimumFreeSpaceGB 0.1 -Label 'test').Ok) '盘符根目录应被拒绝'
    }

    Test-Case 'VSCode 安装参数包含带引号的 /DIR' {
        $arguments = Get-VSCodeInstallerArguments -MergeTasks '!runcode' -InstallDir 'D:\VSCode' -LogPath 'C:\logs\v.log'
        Assert-True ($arguments -like '*/DIR="D:\VSCode"*') '应包含 /DIR'
        Assert-True ($arguments -like '*/LOG="C:\logs\v.log"*') '应包含 /LOG'

        $spaced = Get-VSCodeInstallerArguments -MergeTasks 'x' -InstallDir 'D:\My Apps\VSCode' -LogPath 'C:\a b.log'
        Assert-True ($spaced -like '*/DIR="D:\My Apps\VSCode"*') '带空格目录应加引号'
    }

    Test-Case 'Get-VSCodePaths 支持自定义安装目录' {
        $fakeContext = [pscustomobject]@{
            Paths = @{ VSCode = @{ InstallDir = 'C:\Program Files\Microsoft VS Code'; ExeName = 'Code.exe'; CliRelative = 'bin\code.cmd' } }
        }
        $paths = Get-VSCodePaths -Context $fakeContext -VSCodeDir 'D:\VSCode'
        Assert-Equal 'D:\VSCode' $paths.InstallDir '安装目录'
        Assert-Equal 'D:\VSCode\Code.exe' $paths.SystemExe '主程序'
        Assert-Equal 'D:\VSCode\bin\code.cmd' $paths.SystemCli 'CLI'
        Assert-Equal 'D:\VSCode\bin' $paths.BinDir 'bin'
    }

    Test-Case 'VSCode 数据目录布局' {
        $layout = Get-VSCodeDataLayout -DataRoot 'D:\VSCodeData' -UserProfile 'C:\Users\test' -AppData 'C:\Users\test\AppData\Roaming' -LocalAppData 'C:\Users\test\AppData\Local'
        Assert-Equal 'D:\VSCodeData\user-data' $layout.UserData '用户数据'
        Assert-Equal 'D:\VSCodeData\extensions' $layout.Extensions '扩展'
        Assert-Equal 'C:\Users\test\AppData\Roaming\Code' $layout.UserDataLink '用户数据联接'
        Assert-Equal 'C:\Users\test\.vscode\extensions' $layout.ExtensionsLink '扩展联接'
        Assert-Equal 'C:\Users\test\AppData\Local\Microsoft\vscode-cpptools' $layout.CppToolsLink '缓存联接'
    }

    Test-Case 'Enable-VSCodeDataRoot 创建并复用联接' {
        $root = Join-Path $tempRoot 'data-fresh'
        $profile = Join-Path $root 'profile'
        $appData = Join-Path $root 'appdata\roaming'
        $localAppData = Join-Path $root 'appdata\local'
        $dataRoot = Join-Path $root 'VSCodeData'
        New-Item -ItemType Directory -Path $profile, $appData, $localAppData -Force | Out-Null
        $logger = New-PackLogger -LogDir (Join-Path $root 'logs') -Prefix 'data-test'

        $first = Enable-VSCodeDataRoot -Logger $logger -DataRoot $dataRoot -UserProfile $profile -AppData $appData -LocalAppData $localAppData -SkipRunningCheck
        Assert-Equal 3 @($first.Actions).Count '应创建三个联接'
        Assert-True (Test-DataLinkMatches -Link (Join-Path $appData 'Code') -Target (Join-Path $dataRoot 'user-data')) '用户数据联接'
        Assert-True (Test-DataLinkMatches -Link (Join-Path $profile '.vscode\extensions') -Target (Join-Path $dataRoot 'extensions')) '扩展联接'
        Assert-True (Test-DataLinkMatches -Link (Join-Path $localAppData 'Microsoft\vscode-cpptools') -Target (Join-Path $dataRoot 'cache\vscode-cpptools')) '缓存联接'

        $second = Enable-VSCodeDataRoot -Logger $logger -DataRoot $dataRoot -UserProfile $profile -AppData $appData -LocalAppData $localAppData -SkipRunningCheck
        Assert-Equal 3 @($second.Actions | Where-Object { $_.Action -eq 'Unchanged' }).Count '重复执行应保持不变'
    }

    Test-Case 'Enable-VSCodeDataRoot 未加 MigrateData 时拒绝旧目录' {
        $root = Join-Path $tempRoot 'data-refuse'
        $profile = Join-Path $root 'profile'
        $appData = Join-Path $root 'appdata\roaming'
        $localAppData = Join-Path $root 'appdata\local'
        $dataRoot = Join-Path $root 'VSCodeData'
        New-Item -ItemType Directory -Path (Join-Path $appData 'Code\User') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $appData 'Code\User\settings.json') -Value '{}' -Encoding UTF8
        New-Item -ItemType Directory -Path $profile, $localAppData -Force | Out-Null
        $logger = New-PackLogger -LogDir (Join-Path $root 'logs') -Prefix 'data-test'

        Assert-Throws {
            Enable-VSCodeDataRoot -Logger $logger -DataRoot $dataRoot -UserProfile $profile -AppData $appData -LocalAppData $localAppData -SkipRunningCheck
        } '未加 -MigrateData 应拒绝'
    }

    Test-Case 'Enable-VSCodeDataRoot 迁移旧数据并保留内容' {
        $root = Join-Path $tempRoot 'data-migrate'
        $profile = Join-Path $root 'profile'
        $appData = Join-Path $root 'appdata\roaming'
        $localAppData = Join-Path $root 'appdata\local'
        $dataRoot = Join-Path $root 'VSCodeData'
        New-Item -ItemType Directory -Path (Join-Path $appData 'Code\User') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $appData 'Code\User\settings.json') -Value '{"test":1}' -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $profile '.vscode\extensions\ext1') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $profile '.vscode\extensions\ext1\package.json') -Value '{"name":"ext1"}' -Encoding UTF8
        New-Item -ItemType Directory -Path (Join-Path $localAppData 'Microsoft\vscode-cpptools') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $localAppData 'Microsoft\vscode-cpptools\cache.bin') -Value 'cache' -Encoding ASCII
        $logger = New-PackLogger -LogDir (Join-Path $root 'logs') -Prefix 'data-test'

        Enable-VSCodeDataRoot -Logger $logger -DataRoot $dataRoot -UserProfile $profile -AppData $appData -LocalAppData $localAppData -MigrateExisting -SkipRunningCheck | Out-Null

        Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'user-data\User\settings.json')) '用户数据应复制到 DataRoot'
        Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'extensions\ext1\package.json')) '扩展应复制到 DataRoot'
        Assert-True (Test-Path -LiteralPath (Join-Path $dataRoot 'cache\vscode-cpptools\cache.bin')) '缓存应复制到 DataRoot'
        Assert-True (Test-Path -LiteralPath (Join-Path $appData 'Code\User\settings.json')) '原路径应通过联接继续可读'
        Assert-True (Test-DataLinkMatches -Link (Join-Path $appData 'Code') -Target (Join-Path $dataRoot 'user-data')) '用户数据联接'
    }

    Test-Case 'Enable-VSCodeDataRoot 的 DryRun 不修改磁盘' {
        $root = Join-Path $tempRoot 'data-dryrun'
        $profile = Join-Path $root 'profile'
        $appData = Join-Path $root 'appdata\roaming'
        $localAppData = Join-Path $root 'appdata\local'
        $dataRoot = Join-Path $root 'VSCodeData'
        New-Item -ItemType Directory -Path (Join-Path $appData 'Code\User') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $appData 'Code\User\settings.json') -Value '{}' -Encoding UTF8
        New-Item -ItemType Directory -Path $profile, $localAppData -Force | Out-Null
        $logger = New-PackLogger -LogDir (Join-Path $root 'logs') -Prefix 'data-test'

        Enable-VSCodeDataRoot -Logger $logger -DataRoot $dataRoot -UserProfile $profile -AppData $appData -LocalAppData $localAppData -MigrateExisting -DryRun -SkipRunningCheck | Out-Null

        Assert-True ($null -eq (Get-ReparsePointTarget -Path (Join-Path $appData 'Code'))) 'DryRun 不应创建联接'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $dataRoot 'user-data'))) 'DryRun 不应创建目标目录'
    }

    Test-Case '一键启动脚本存在并引用安装入口' {
        $mainLauncher = Join-Path $packRoot 'Install.cmd'
        $dLauncher = Join-Path $packRoot 'Install-D.cmd'
        $repairLauncher = Join-Path $packRoot 'Repair-WorkShortcut.cmd'
        Assert-True (Test-Path -LiteralPath $mainLauncher) 'Install.cmd 应存在'
        Assert-True (Test-Path -LiteralPath $dLauncher) 'Install-D.cmd 应存在'
        Assert-True (Test-Path -LiteralPath $repairLauncher) 'Repair-WorkShortcut.cmd 应存在'
        Assert-True ((Read-TextFile -Path $mainLauncher) -match 'setup\.ps1') 'Install.cmd 应调用 setup.ps1'
        Assert-True ((Read-TextFile -Path $dLauncher) -match 'Install\.cmd') 'Install-D.cmd 应调用 Install.cmd'
    }

    Test-Case 'PATH 合并与移除兼容畸形项' {
        $malformed = 'cscript //nologo "D:\pyenv-win\pyenv-win\bin\..\libexec\pyenv.vbs"\shims;cscript //nologo "D:\pyenv-win\pyenv-win\bin\..\libexec\pyenv.vbs"\bin;C:\Windows'
        $merged = Merge-PathList -CurrentValue $malformed -NewEntry 'C:\mingw64\bin'
        Assert-True $merged.Changed '应追加新路径'
        Assert-True ($merged.Value -like '*C:\mingw64\bin*') '应包含新路径'
        Assert-True ($merged.Value -like '*pyenv.vbs*') '畸形项应原样保留'

        $removed = Remove-PathEntryFromList -CurrentValue $merged.Value -Entry 'C:\mingw64\bin'
        Assert-True $removed.Changed '应移除新路径'
        Assert-True (-not (Test-PathEntryPresent -Value $removed.Value -Entry 'C:\mingw64\bin')) '移除后不应存在'
        Assert-True ($removed.Value -like '*pyenv.vbs*') '畸形项仍应保留'
        $null = ConvertTo-PathEntryNormalized -Entry $malformed
    }

    Test-Case 'hello-cpp 使用 g++ 编译并匹配 launch 任务' {
        $tasks = ConvertFrom-Json -InputObject (Read-TextFile -Path (Join-Path $packRoot 'examples\hello-cpp\.vscode\tasks.json'))
        $launch = ConvertFrom-Json -InputObject (Read-TextFile -Path (Join-Path $packRoot 'examples\hello-cpp\.vscode\launch.json'))
        $task = @($tasks.tasks)[0]
        Assert-True ($task.command -match 'g\+\+\.exe$') 'tasks.json 应使用 g++.exe'
        Assert-True ($task.label -match 'g\+\+\.exe') '任务标签应显示 g++'
        Assert-True (@($task.args) -contains '-static') 'C++ 示例应静态链接运行库'
        Assert-Equal $task.label $launch.configurations[0].preLaunchTask 'preLaunchTask 应匹配任务标签'
        $pathEntry = @($launch.configurations[0].environment | Where-Object { $_.name -eq 'PATH' }) | Select-Object -First 1
        Assert-True ($pathEntry -and $pathEntry.value -like 'C:\mingw64\bin;*') 'launch 应优先使用包内 MinGW bin'
    }

    Test-Case 'Invoke-ElevatedChild 通过 ProcessStartInfo 启动并读取结果' {
        $runId = [guid]::NewGuid().ToString('N')
        $resultFile = Join-Path $tempRoot ('elevated-result-' + $runId + '.json')
        $childScript = Join-Path $tempRoot ('elevated-child-' + $runId + '.ps1')
        $escapedResult = $resultFile.Replace('\', '\\')
        $childBody = @"
`$obj = [pscustomobject]@{ runId = '$runId'; exitCode = 0; stages = @([pscustomobject]@{ Name = 'Test'; Status = 'OK'; Message = 'ok' }) }
[System.IO.File]::WriteAllText('$escapedResult', (`$obj | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding(`$false)))
"@
        Write-Utf8NoBom -Path $childScript -Content $childBody

        $elevated = Invoke-ElevatedChild -ScriptPath $childScript -ArgumentList @() -WorkingDirectory $tempRoot -ResultFile $resultFile -RunId $runId -TimeoutSeconds 30 -Verb ''
        Assert-True ($null -ne $elevated) '应返回结果'
        Assert-Equal 0 $elevated.ExitCode '退出码'
        Assert-Equal 'Test' $elevated.Result.stages[0].Name '阶段名称'
    }

    Test-Case 'JSONC 解析支持注释和尾逗号' {
        $jsonc = @'
{
  // line comment
  "url": "https://example.com/a//b",
  /* block comment */
  "count": 2,
}
'@
        $obj = ConvertFrom-Json -InputObject (ConvertFrom-JsoncText -Text $jsonc)
        Assert-Equal 'https://example.com/a//b' $obj.url '字符串中的 // 应保留'
        Assert-Equal 2 $obj.count '尾逗号应被兼容'
    }

    Test-Case '工作目录包含 tasks.json 和 py 目录' {
        $context = [pscustomobject]@{ ConfigDir = (Join-Path $packRoot 'config') }
        $logger = New-PackLogger -LogDir (Join-Path $tempRoot 'work-logs') -Prefix 'work-test'
        $workDir = Join-Path $tempRoot 'work-project'

        $result = Initialize-WorkDirectory -Context $context -Logger $logger -WorkDir $workDir
        Assert-True (Test-Path -LiteralPath (Join-Path $workDir '.vscode\tasks.json')) 'tasks.json 应存在'
        Assert-True (Test-Path -LiteralPath (Join-Path $workDir 'py')) 'py 目录应存在'
        Assert-Equal $workDir $result.WorkDir '返回工作目录'

        $tasks = ConvertFrom-Json -InputObject (Read-TextFile -Path (Join-Path $workDir '.vscode\tasks.json'))
        Assert-Equal 2 @($tasks.tasks).Count '应有两个构建任务'
        Assert-True ((@($tasks.tasks)[1].command) -match 'g\+\+\.exe$') 'C++ 任务应使用 g++'
        Assert-True ([bool](@($tasks.tasks)[1].group.isDefault)) 'C++ 任务应为默认构建'

        $tasksPath = Join-Path $workDir '.vscode\tasks.json'
        Write-Utf8NoBom -Path $tasksPath -Content '{"sentinel":true}'
        Initialize-WorkDirectory -Context $context -Logger $logger -WorkDir $workDir | Out-Null
        Assert-Equal '{"sentinel":true}' (Read-TextFile -Path $tasksPath) '重复执行不应覆盖已有 tasks.json'
    }

    Test-Case '桌面工作区快捷方式创建' {
        $desktop = Join-Path $tempRoot 'desktop'
        $work = Join-Path $tempRoot 'shortcut-work'
        New-Item -ItemType Directory -Path $desktop, $work -Force | Out-Null
        $exe = Join-Path $env:SystemRoot 'System32\notepad.exe'
        $logger = New-PackLogger -LogDir (Join-Path $tempRoot 'shortcut-logs') -Prefix 'shortcut-test'

        $result = Set-WorkShortcut -WorkDir $work -VSCodeExe $exe -Desktop $desktop -Logger $logger
        Assert-True $result.Ok ('快捷方式应创建成功: ' + $result.Message)
        Assert-True (Test-Path -LiteralPath $result.ShortcutPath) '快捷方式文件应存在'

        $shell = New-Object -ComObject WScript.Shell
        try {
            $shortcut = $shell.CreateShortcut($result.ShortcutPath)
            Assert-Equal $exe $shortcut.TargetPath '快捷方式目标'
            Assert-True ($shortcut.Arguments -like ('*' + $work + '*')) '快捷方式参数应包含工作目录'
        }
        finally {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host ('测试完成: ' + $script:Passed + ' 通过, ' + $script:Failed + ' 失败') -ForegroundColor $(if ($script:Failed -eq 0) { 'Green' } else { 'Red' })
if ($script:Failed -gt 0) {
    Write-Host '失败明细:' -ForegroundColor Red
    foreach ($message in $script:FailureMessages) { Write-Host ('  - ' + $message) -ForegroundColor Red }
    exit 1
}
exit 0
