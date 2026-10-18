# VSCode data relocation: user data, extensions and known extension caches.
# Junctions keep the default paths working for shortcuts, code.cmd and this pack.

function Get-VSCodeDataLayout {
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [string]$UserProfile = $env:USERPROFILE,
        [string]$AppData = $env:APPDATA,
        [string]$LocalAppData = $env:LOCALAPPDATA
    )

    $root = [System.IO.Path]::GetFullPath($DataRoot).TrimEnd('\')
    return [pscustomobject]@{
        Root           = $root
        UserData       = Join-Path $root 'user-data'
        Extensions     = Join-Path $root 'extensions'
        CacheRoot      = Join-Path $root 'cache'
        CppToolsCache  = Join-Path $root 'cache\vscode-cpptools'
        UserDataLink   = Join-Path $AppData 'Code'
        ExtensionsLink = Join-Path $UserProfile '.vscode\extensions'
        CppToolsLink   = Join-Path $LocalAppData 'Microsoft\vscode-cpptools'
    }
}

function Get-ReparsePointTarget {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) { return $null }
        $target = $item.Target
        if ($target -is [System.Array]) { $target = $target[0] }
        if (-not $target) { return $null }
        return ([System.IO.Path]::GetFullPath([string]$target)).TrimEnd('\')
    }
    catch {
        return $null
    }
}

function Test-DataLinkMatches {
    param(
        [Parameter(Mandatory)][string]$Link,
        [Parameter(Mandatory)][string]$Target
    )

    $actual = Get-ReparsePointTarget -Path $Link
    if (-not $actual) { return $false }
    return (Test-PathEquivalent -Left $actual -Right $Target)
}

function Copy-DirectoryForMove {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )

    $output = & robocopy $Source $Target /E /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP 2>&1
    $code = $LASTEXITCODE
    if ($code -ge 8) {
        $tail = @($output | Select-Object -Last 10) -join [Environment]::NewLine
        throw ('复制失败（robocopy 退出码 ' + $code + '）: ' + $Source + ' -> ' + $Target + [Environment]::NewLine + $tail)
    }

    $sourceFiles = @(Get-ChildItem -LiteralPath $Source -Recurse -File -Force -ErrorAction SilentlyContinue)
    $targetFiles = @(Get-ChildItem -LiteralPath $Target -Recurse -File -Force -ErrorAction SilentlyContinue)
    if ($targetFiles.Count -lt $sourceFiles.Count) {
        throw ('复制后文件数量不一致: 源 ' + $sourceFiles.Count + '，目标 ' + $targetFiles.Count + '（' + $Target + '）')
    }

    $sourceBytes = ($sourceFiles | Measure-Object -Property Length -Sum).Sum
    $targetBytes = ($targetFiles | Measure-Object -Property Length -Sum).Sum
    if ($null -eq $sourceBytes) { $sourceBytes = 0 }
    if ($null -eq $targetBytes) { $targetBytes = 0 }
    if ($targetBytes -lt $sourceBytes) {
        throw ('复制后文件总大小不一致: 源 ' + $sourceBytes + ' 字节，目标 ' + $targetBytes + ' 字节（' + $Target + '）')
    }
}

function New-DirectoryJunction {
    param(
        [Parameter(Mandatory)][string]$Link,
        [Parameter(Mandatory)][string]$Target
    )

    $parent = Split-Path -Parent $Link
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Target)) {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
    }
    if (Test-Path -LiteralPath $Link) {
        throw ('创建联接前路径已存在: ' + $Link)
    }

    New-Item -ItemType Junction -Path $Link -Target $Target -ErrorAction Stop | Out-Null
    if (-not (Test-DataLinkMatches -Link $Link -Target $Target)) {
        throw ('联接创建后校验失败: ' + $Link + ' -> ' + $Target)
    }
}

function Test-DataRootInsideLink {
    param($Layout, [string]$Root)

    foreach ($link in @($Layout.UserDataLink, $Layout.ExtensionsLink, $Layout.CppToolsLink)) {
        $normalizedLink = [System.IO.Path]::GetFullPath($link).TrimEnd('\')
        if ($Root.Equals($normalizedLink, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if ($Root.StartsWith($normalizedLink + '\', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Enable-VSCodeDataRoot {
    param(
        [Parameter(Mandatory)]$Logger,
        [Parameter(Mandatory)][string]$DataRoot,
        [string]$UserProfile = $env:USERPROFILE,
        [string]$AppData = $env:APPDATA,
        [string]$LocalAppData = $env:LOCALAPPDATA,
        [switch]$MigrateExisting,
        [switch]$SkipCache,
        [switch]$SkipRunningCheck,
        [switch]$DryRun
    )

    $validation = Test-InstallDirectory -Path $DataRoot -MinimumFreeSpaceGB 3 -Label 'DataRoot'
    foreach ($problem in $validation.Problems) { $Logger.Error($problem) }
    foreach ($warning in $validation.Warnings) { $Logger.Warn($warning) }
    if (-not $validation.Ok) {
        throw ('DataRoot 无效: ' + ($validation.Problems -join '; '))
    }

    $layout = Get-VSCodeDataLayout -DataRoot $validation.FullPath -UserProfile $UserProfile -AppData $AppData -LocalAppData $LocalAppData
    if (Test-DataRootInsideLink -Layout $layout -Root $layout.Root) {
        throw ('DataRoot 不能位于 VSCode 用户数据或扩展目录内部: ' + $layout.Root)
    }

    if (-not $DryRun -and -not $SkipRunningCheck) {
        $running = @(Get-RunningVSCodeProcesses)
        if ($running.Count -gt 0) {
            throw '检测到 VSCode 正在运行。请先关闭所有 VSCode 窗口，再迁移用户数据和扩展。'
        }
    }

    $pairs = @(
        [pscustomobject]@{ Name = 'VSCode 用户数据'; Link = $layout.UserDataLink; Target = $layout.UserData }
        [pscustomobject]@{ Name = 'VSCode 扩展'; Link = $layout.ExtensionsLink; Target = $layout.Extensions }
    )
    if (-not $SkipCache) {
        $pairs += [pscustomobject]@{ Name = 'C/C++ 扩展缓存'; Link = $layout.CppToolsLink; Target = $layout.CppToolsCache }
    }

    $actions = New-Object System.Collections.Generic.List[object]
    foreach ($pair in $pairs) {
        $link = $pair.Link
        $target = $pair.Target
        $existingTarget = Get-ReparsePointTarget -Path $link

        if ($existingTarget) {
            if (Test-PathEquivalent -Left $existingTarget -Right $target) {
                $Logger.Ok(($pair.Name + ' 已指向: ' + $target))
                $actions.Add([pscustomobject]@{ Name = $pair.Name; Action = 'Unchanged'; Link = $link; Target = $target })
                continue
            }
            throw ($pair.Name + ' 已存在指向其他位置的联接: ' + $link + ' -> ' + $existingTarget + '；请先手动移除该联接。')
        }

        if (Test-Path -LiteralPath $link) {
            $item = Get-Item -LiteralPath $link -Force
            if (-not $item.PSIsContainer) {
                throw ($pair.Name + ' 路径已存在且不是目录: ' + $link)
            }
            if (-not $MigrateExisting) {
                throw ('检测到现有 ' + $pair.Name + ' 目录: ' + $link + '。请加 -MigrateData 迁移到 ' + $target + '，或先手动移动。')
            }

            if ($DryRun) {
                $Logger.Info(('DryRun: 将迁移 ' + $pair.Name + ' ' + $link + ' -> ' + $target))
                $actions.Add([pscustomobject]@{ Name = $pair.Name; Action = 'Planned-Migrate'; Link = $link; Target = $target })
                continue
            }

            $sourceFiles = @(Get-ChildItem -LiteralPath $link -Recurse -File -Force -ErrorAction SilentlyContinue)
            $targetFiles = @()
            if (Test-Path -LiteralPath $target) {
                $targetFiles = @(Get-ChildItem -LiteralPath $target -Recurse -File -Force -ErrorAction SilentlyContinue)
            }
            if ($targetFiles.Count -gt 0 -and $targetFiles.Count -ne $sourceFiles.Count) {
                throw ('目标目录已存在且文件数量不一致，拒绝覆盖: ' + $target + '（源 ' + $sourceFiles.Count + '，目标 ' + $targetFiles.Count + '）')
            }

            if ($targetFiles.Count -eq 0) {
                Copy-DirectoryForMove -Source $link -Target $target
            }
            else {
                $Logger.Warn(('检测到上次迁移的副本，继续完成切换: ' + $target))
            }

            $Logger.Step(('正在切换 ' + $pair.Name + ': ' + $link + ' -> ' + $target))
            $backup = $link + '.pre-move.' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            $counter = 1
            while (Test-Path -LiteralPath $backup) {
                $backup = $link + '.pre-move.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $counter
                $counter++
            }
            try {
                Move-Item -LiteralPath $link -Destination $backup -ErrorAction Stop
            }
            catch {
                throw ('无法移动原目录（可能仍被 VSCode 占用）: ' + $link + '；目标副本已保留在 ' + $target + '。')
            }

            New-DirectoryJunction -Link $link -Target $target

            try {
                Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction Stop
                $Logger.Detail('已清理迁移前的旧目录: ' + $backup)
            }
            catch {
                $Logger.Warn('迁移完成，但旧目录清理失败，请手动删除: ' + $backup)
            }

            $Logger.Ok(($pair.Name + ' 已迁移到: ' + $target))
            $actions.Add([pscustomobject]@{ Name = $pair.Name; Action = 'Migrated'; Link = $link; Target = $target })
            continue
        }

        if ($DryRun) {
            $Logger.Info(('DryRun: 将创建 ' + $pair.Name + ' 联接 ' + $link + ' -> ' + $target))
            $actions.Add([pscustomobject]@{ Name = $pair.Name; Action = 'Planned-Create'; Link = $link; Target = $target })
            continue
        }

        New-DirectoryJunction -Link $link -Target $target
        $Logger.Ok(($pair.Name + ' 已重定向: ' + $link + ' -> ' + $target))
        $actions.Add([pscustomobject]@{ Name = $pair.Name; Action = 'Created'; Link = $link; Target = $target })
    }

    return [pscustomobject]@{
        Ok      = $true
        Layout  = $layout
        Actions = @(ConvertTo-PlainArray $actions)
    }
}
