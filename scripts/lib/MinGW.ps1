# MinGW-w64 product module: extract winlibs, deploy to a fixed path, verify gcc/g++/gdb.

function Get-ToolVersionLine {
    param([Parameter(Mandatory)][string]$ExePath)
    if (-not (Test-Path -LiteralPath $ExePath)) { return $null }
    try {
        $result = Invoke-CapturedProcess -FilePath $ExePath -ArgumentList @('--version') -TimeoutSeconds 60
        $line = ($result.Output -split "`r?`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
        return $line
    }
    catch {
        return $null
    }
}

function Get-MinGWStatus {
    param([Parameter(Mandatory)]$Context)
    $installDir = [string](Get-PropertyValue -Object $Context.Paths.MinGW -Name 'InstallDir')
    $binDir = Join-Path $installDir 'bin'
    $required = @(Get-PropertyValue -Object $Context.Paths.MinGW -Name 'RequiredBinaries' -Default @())
    $optional = @(Get-PropertyValue -Object $Context.Paths.MinGW -Name 'OptionalBinaries' -Default @())

    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($name in $required) {
        $path = Join-Path $binDir $name
        if (-not (Test-Path -LiteralPath $path)) { $missing.Add($name) }
    }

    return [pscustomobject]@{
        InstallDir = $installDir
        BinDir     = $binDir
        Exists     = (Test-Path -LiteralPath (Join-Path $binDir 'gcc.exe'))
        Missing    = @(ConvertTo-PlainArray $missing)
        Gcc        = (Get-ToolVersionLine -ExePath (Join-Path $binDir 'gcc.exe'))
        GPlusPlus  = (Get-ToolVersionLine -ExePath (Join-Path $binDir 'g++.exe'))
        Gdb        = (Get-ToolVersionLine -ExePath (Join-Path $binDir 'gdb.exe'))
        Make       = (Get-ToolVersionLine -ExePath (Join-Path $binDir 'mingw32-make.exe'))
        OptionalMissing = @($optional | Where-Object { -not (Test-Path -LiteralPath (Join-Path $binDir $_)) })
    }
}

function Find-MinGWRoot {
    param([Parameter(Mandatory)][string]$Root)

    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($Root)
    $candidates.Add((Join-Path $Root 'mingw64'))

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'bin\gcc.exe')) {
            return $candidate
        }
    }

    try {
        $directory = Get-ChildItem -LiteralPath $Root -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\gcc.exe') } |
            Select-Object -First 1
        if ($directory) { return $directory.FullName }
    }
    catch { }

    return $null
}

function Expand-MinGWArchive {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Logger,
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$Destination
    )

    if (-not (Test-Path -LiteralPath $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    $extension = [System.IO.Path]::GetExtension($ArchivePath).ToLowerInvariant()
    if ($extension -eq '.zip') {
        $Logger.Detail('解压 zip: ' + (Split-Path -Leaf $ArchivePath))
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [System.IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $Destination)
        return
    }

    if ($extension -eq '.7z') {
        $sevenZip = $null
        foreach ($candidate in @('7zr.exe', '7z.exe', '7za.exe')) {
            $path = Join-Path $Context.ToolsDir $candidate
            if (Test-Path -LiteralPath $path) { $sevenZip = $path; break }
        }
        if (-not $sevenZip) {
            $command = Get-Command '7z.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($command) { $sevenZip = $command.Source }
        }
        if (-not $sevenZip) {
            throw '解压 .7z 需要 tools\7zr.exe。请重新运行 fetch-assets.ps1 下载 7-Zip 独立解压器。'
        }

        $Logger.Detail('解压 7z: ' + (Split-Path -Leaf $ArchivePath))
        $result = Invoke-CapturedProcess -FilePath $sevenZip -ArgumentList @('x', $ArchivePath, ('-o' + $Destination), '-y') -TimeoutSeconds 1800
        if ($result.ExitCode -ne 0 -and $result.ExitCode -ne 1) {
            throw ('7-Zip 解压失败（退出码 ' + $result.ExitCode + '）: ' + $result.Output)
        }
        return
    }

    throw ('不支持的 MinGW 压缩格式: ' + $extension)
}

function Install-MinGWProduct {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Logger,
        [switch]$DryRun,
        [switch]$Force
    )

    $installDir = [string](Get-PropertyValue -Object $Context.Paths.MinGW -Name 'InstallDir')
    $binDir = Join-Path $installDir 'bin'
    $targetGcc = Join-Path $binDir 'gcc.exe'
    $required = @(Get-PropertyValue -Object $Context.Paths.MinGW -Name 'RequiredBinaries' -Default @())

    $targetComplete = Test-Path -LiteralPath $targetGcc
    foreach ($name in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $binDir $name))) { $targetComplete = $false }
    }

    if ($targetComplete -and -not $Force) {
        Add-PathEntry -Scope Machine -Entry $binDir -LogDir $Context.LogsDir -Logger $Logger -DryRun:$DryRun | Out-Null
        $version = Get-ToolVersionLine -ExePath $targetGcc
        $Logger.Ok(('检测到 MinGW: ' + $version + ' -> ' + $installDir))
        return [pscustomobject]@{
            Name = 'MinGW'; Status = 'Skipped'; Version = $version; Path = $installDir;
            BinDir = $binDir; Message = '已安装，跳过'; Blocker = $false
        }
    }

    $asset = $null
    $preExtracted = Join-Path $Context.ToolsDir 'mingw64'
    $usePreExtracted = Test-Path -LiteralPath (Join-Path $preExtracted 'bin\gcc.exe')

    if (-not $usePreExtracted) {
        try {
            $asset = Get-PackAsset -Context $Context -Component 'mingw'
        }
        catch {
            return [pscustomobject]@{
                Name = 'MinGW'; Status = 'Failed'; Version = $null; Path = $null; BinDir = $null;
                Message = $_.Exception.Message; Blocker = $true
            }
        }
        if (-not (Test-Path -LiteralPath $asset.FullPath)) {
            return [pscustomobject]@{
                Name = 'MinGW'; Status = 'Failed'; Version = $null; Path = $asset.FullPath; BinDir = $null;
                Message = 'MinGW 压缩包不存在，请重新运行 fetch-assets.ps1'; Blocker = $true
            }
        }
    }

    $assetVersion = if ($asset) { [string](Get-PropertyValue -Object $asset.Data -Name 'version' -Default '') } else { 'pre-extracted' }

    if ($DryRun) {
        Add-PathEntry -Scope Machine -Entry $binDir -LogDir $Context.LogsDir -Logger $Logger -DryRun | Out-Null
        return [pscustomobject]@{
            Name = 'MinGW'; Status = 'Planned'; Version = $assetVersion; Path = $installDir; BinDir = $binDir;
            Message = '将部署 MinGW 到 ' + $installDir; Blocker = $false
        }
    }

    $tempRoot = Join-Path $Context.LogsDir ('tmp-mingw-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $sourceRoot = $null
    $installed = $false

    try {
        if ($usePreExtracted) {
            $sourceRoot = $preExtracted
            $Logger.Info('使用已解压的 MinGW 目录: ' + $sourceRoot)
        }
        else {
            New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
            $Logger.Step('正在解压 MinGW 压缩包（约需数分钟）')
            Expand-MinGWArchive -Context $Context -Logger $Logger -ArchivePath $asset.FullPath -Destination $tempRoot
            $sourceRoot = Find-MinGWRoot -Root $tempRoot
            if (-not $sourceRoot) {
                throw '解压后未找到 mingw64\bin\gcc.exe。压缩包结构可能已变化。'
            }
            $Logger.Detail('解压目录: ' + $sourceRoot)
        }

        foreach ($name in $required) {
            if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot ('bin\' + $name)))) {
                throw ('MinGW 源目录缺少 ' + $name + ': ' + $sourceRoot)
            }
        }

        $Logger.Step('正在部署 MinGW 到 ' + $installDir)
        if (-not (Test-Path -LiteralPath $installDir)) {
            New-Item -ItemType Directory -Path $installDir -Force | Out-Null
        }
        Copy-DirectoryTree -Source $sourceRoot -Destination $installDir -Threads 8 -TimeoutSeconds 1800 | Out-Null
        $installed = $true
    }
    catch {
        return [pscustomobject]@{
            Name = 'MinGW'; Status = 'Failed'; Version = $assetVersion; Path = $installDir; BinDir = $binDir;
            Message = $_.Exception.Message; Blocker = $true
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            try { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
    }

    if (-not $installed) {
        return [pscustomobject]@{
            Name = 'MinGW'; Status = 'Failed'; Version = $assetVersion; Path = $installDir; BinDir = $binDir;
            Message = '部署未完成'; Blocker = $true
        }
    }

    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $binDir $_)) })
    if ($missing.Count -gt 0) {
        return [pscustomobject]@{
            Name = 'MinGW'; Status = 'Failed'; Version = $assetVersion; Path = $installDir; BinDir = $binDir;
            Message = ('部署完成但缺少: ' + ($missing -join ', ')); Blocker = $true
        }
    }

    $version = Get-ToolVersionLine -ExePath (Join-Path $binDir 'gcc.exe')
    $gdbVersion = Get-ToolVersionLine -ExePath (Join-Path $binDir 'gdb.exe')
    Add-PathEntry -Scope Machine -Entry $binDir -LogDir $Context.LogsDir -Logger $Logger | Out-Null
    $Logger.Ok(('MinGW 部署完成: ' + $version))
    $Logger.Detail(('gdb: ' + $gdbVersion))

    return [pscustomobject]@{
        Name = 'MinGW'; Status = 'Installed'; Version = $version; Path = $installDir; BinDir = $binDir;
        Message = '部署完成'; Blocker = $false
    }
}
