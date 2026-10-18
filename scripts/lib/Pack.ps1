# Pack context, manifest validation, and extension dependency ordering.
# The manifest is the single source of truth for asset versions and hashes.

function New-PackContext {
    param([Parameter(Mandatory)][string]$PackRoot)

    $root = (Resolve-Path -LiteralPath $PackRoot).Path.TrimEnd('\')
    $pathsFile = Join-Path $root 'scripts\paths.psd1'
    if (-not (Test-Path -LiteralPath $pathsFile)) {
        throw ('不是有效的安装包目录，缺少 scripts\paths.psd1: ' + $root)
    }

    $paths = Import-PowerShellDataFile -Path $pathsFile
    $manifestPath = Join-Path $root 'MANIFEST.json'
    $manifest = $null
    if (Test-Path -LiteralPath $manifestPath) {
        $manifestText = Read-TextFile -Path $manifestPath
        try {
            $manifest = ConvertFrom-Json -InputObject $manifestText -ErrorAction Stop
        }
        catch {
            throw ('MANIFEST.json 无法解析: ' + $_.Exception.Message)
        }
    }

    $logsDir = Join-Path $root 'logs'
    if (-not (Test-Path -LiteralPath $logsDir)) {
        New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
    }

    return [pscustomobject]@{
        Root         = $root
        Paths        = $paths
        Manifest     = $manifest
        ManifestPath = $manifestPath
        InstallerDir = Join-Path $root 'installer'
        ToolsDir     = Join-Path $root 'tools'
        ExtensionsDir = Join-Path $root 'extensions'
        ConfigDir    = Join-Path $root 'config'
        ExamplesDir  = Join-Path $root 'examples'
        DocsDir      = Join-Path $root 'docs'
        LogsDir      = $logsDir
        DistDir      = Join-Path $root 'dist'
        Version      = $paths.PackVersion
    }
}

function Test-SafeRelativePath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $false }
    if ($Path -match '^[A-Za-z]:') { return $false }
    if ($Path -match '(^|[\\/])\.\.([\\/]|$)') { return $false }
    if ($Path -match '[\x00-\x1F]') { return $false }
    return $true
}

function Test-ManifestObject {
    param($Manifest)

    $problems = New-Object System.Collections.Generic.List[string]

    if ($null -eq $Manifest) {
        $problems.Add('MANIFEST.json 不存在或为空。请先运行 scripts\fetch-assets.ps1。')
        return [pscustomobject]@{ Ok = $false; Problems = @(ConvertTo-PlainArray $problems) }
    }

    $schemaVersion = Get-PropertyValue -Object $Manifest -Name 'schemaVersion'
    if ([int]$schemaVersion -ne 1) {
        $problems.Add(('不支持的 manifest schemaVersion: ' + $schemaVersion))
    }

    $platform = [string](Get-PropertyValue -Object $Manifest -Name 'platform' -Default '')
    if ($platform -ne 'win32-x64') {
        $problems.Add(('manifest platform 不是 win32-x64: ' + $platform))
    }

    $components = Get-PropertyValue -Object $Manifest -Name 'components'
    $componentNames = @('vscode', 'python', 'mingw')
    if ($null -ne (Get-PropertyValue -Object $components -Name 'sevenZip')) {
        $componentNames += 'sevenZip'
    }
    foreach ($name in $componentNames) {
        $component = Get-PropertyValue -Object $components -Name $name
        if ($null -eq $component) {
            $problems.Add(('manifest 缺少组件: ' + $name))
            continue
        }
        $file = [string](Get-PropertyValue -Object $component -Name 'file' -Default '')
        if (-not (Test-SafeRelativePath -Path $file)) {
            $problems.Add(('组件 ' + $name + ' 的 file 不是安全的相对路径: ' + $file))
        }
        $version = [string](Get-PropertyValue -Object $component -Name 'version' -Default '')
        if ([string]::IsNullOrWhiteSpace($version)) {
            $problems.Add(('组件 ' + $name + ' 缺少 version'))
        }
        $hash = [string](Get-PropertyValue -Object $component -Name 'sha256' -Default '')
        if ($hash -notmatch '^[0-9a-fA-F]{64}$') {
            $problems.Add(('组件 ' + $name + ' 的 sha256 无效'))
        }
    }

    $extensions = @(Get-PropertyValue -Object $Manifest -Name 'extensions' -Default @())

    $seenIds = @{}
    foreach ($extension in $extensions) {
        $id = [string](Get-PropertyValue -Object $extension -Name 'id' -Default '')
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9._-]+$') {
            $problems.Add(('扩展 id 无效: ' + $id))
        }
        $normalized = $id.ToLowerInvariant()
        if ($seenIds.ContainsKey($normalized)) {
            $problems.Add(('扩展 id 重复: ' + $id))
        }
        else {
            $seenIds[$normalized] = $true
        }

        $version = [string](Get-PropertyValue -Object $extension -Name 'version' -Default '')
        if ([string]::IsNullOrWhiteSpace($version)) {
            $problems.Add(('扩展 ' + $id + ' 缺少 version'))
        }

        $file = [string](Get-PropertyValue -Object $extension -Name 'file' -Default '')
        if (-not (Test-SafeRelativePath -Path $file)) {
            $problems.Add(('扩展 ' + $id + ' 的 file 不是安全的相对路径: ' + $file))
        }

        $hash = [string](Get-PropertyValue -Object $extension -Name 'sha256' -Default '')
        if ($hash -notmatch '^[0-9a-fA-F]{64}$') {
            $problems.Add(('扩展 ' + $id + ' 的 sha256 无效'))
        }

        $order = Get-PropertyValue -Object $extension -Name 'installOrder'
        if ($null -eq $order -or [int]$order -lt 0) {
            $problems.Add(('扩展 ' + $id + ' 缺少有效的 installOrder'))
        }

        $dependencies = @(Get-PropertyValue -Object $extension -Name 'dependsOn' -Default @())
        foreach ($dependency in $dependencies) {
            if (-not $seenIds.ContainsKey(([string]$dependency).ToLowerInvariant()) -and
                -not ($extensions | Where-Object { ([string](Get-PropertyValue -Object $_ -Name 'id' -Default '')).ToLowerInvariant() -eq ([string]$dependency).ToLowerInvariant() })) {
                $problems.Add(('扩展 ' + $id + ' 依赖的 ' + $dependency + ' 不在 manifest 中'))
            }
        }
    }

    return [pscustomobject]@{ Ok = ($problems.Count -eq 0); Problems = @(ConvertTo-PlainArray $problems) }
}

function Get-PackExtensionAssets {
    param([Parameter(Mandatory)]$Context)
    if (-not $Context.Manifest) { return @() }

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($extension in @(Get-PropertyValue -Object $Context.Manifest -Name 'extensions' -Default @())) {
        $file = [string](Get-PropertyValue -Object $extension -Name 'file' -Default '')
        $result.Add([pscustomobject]@{
            Id             = [string](Get-PropertyValue -Object $extension -Name 'id' -Default '')
            Version        = [string](Get-PropertyValue -Object $extension -Name 'version' -Default '')
            File           = $file
            FullPath       = (Join-Path $Context.Root $file)
            Sha256         = [string](Get-PropertyValue -Object $extension -Name 'sha256' -Default '')
            DependsOn      = @(Get-PropertyValue -Object $extension -Name 'dependsOn' -Default @())
            InstallOrder   = [int](Get-PropertyValue -Object $extension -Name 'installOrder' -Default 0)
            Required       = [bool](Get-PropertyValue -Object $extension -Name 'required' -Default $true)
            TargetPlatform = [string](Get-PropertyValue -Object $extension -Name 'targetPlatform' -Default '')
        })
    }
    return (ConvertTo-PlainArray $result)
}

function Get-PackAsset {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Component
    )
    if (-not $Context.Manifest) {
        throw '缺少 MANIFEST.json。请先在有网机器上运行 scripts\fetch-assets.ps1。'
    }
    $components = Get-PropertyValue -Object $Context.Manifest -Name 'components'
    $asset = Get-PropertyValue -Object $components -Name $Component
    if ($null -eq $asset) {
        throw ('MANIFEST.json 中缺少组件: ' + $Component)
    }
    $file = [string](Get-PropertyValue -Object $asset -Name 'file' -Default '')
    return [pscustomobject]@{
        Data     = $asset
        File     = $file
        FullPath = (Join-Path $Context.Root $file)
    }
}

function Assert-PackAssets {
    param(
        [Parameter(Mandatory)]$Context,
        $Logger = $null,
        [switch]$SkipExtensions,
        [switch]$SkipHashes
    )

    $problems = New-Object System.Collections.Generic.List[string]
    $assets = New-Object System.Collections.Generic.List[object]

    if (-not $Context.Manifest) {
        $problems.Add('缺少 MANIFEST.json。请先在有网机器上运行 scripts\fetch-assets.ps1。')
        return [pscustomobject]@{ Ok = $false; Problems = @(ConvertTo-PlainArray $problems); Assets = @() }
    }

    $shape = Test-ManifestObject -Manifest $Context.Manifest
    foreach ($problem in $shape.Problems) { $problems.Add($problem) }

    $rootFull = [System.IO.Path]::GetFullPath($Context.Root).TrimEnd('\') + '\'

    $componentNames = @('vscode', 'python', 'mingw')
    $manifestComponents = Get-PropertyValue -Object $Context.Manifest -Name 'components'
    if ($null -ne (Get-PropertyValue -Object $manifestComponents -Name 'sevenZip')) {
        $componentNames += 'sevenZip'
    }

    foreach ($name in $componentNames) {
        $asset = $null
        try {
            $asset = Get-PackAsset -Context $Context -Component $name
        }
        catch {
            $problems.Add($_.Exception.Message)
            continue
        }
        $full = [System.IO.Path]::GetFullPath($asset.FullPath)
        if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            $problems.Add(('组件 ' + $name + ' 的路径逃逸出安装包目录: ' + $full))
            continue
        }
        if (-not (Test-Path -LiteralPath $full)) {
            $problems.Add(('组件 ' + $name + ' 文件不存在: ' + $full))
            continue
        }
        $size = (Get-Item -LiteralPath $full).Length
        if ($size -le 0) {
            $problems.Add(('组件 ' + $name + ' 文件为空: ' + $full))
            continue
        }
        if (-not $SkipHashes) {
            $expected = [string](Get-PropertyValue -Object $asset.Data -Name 'sha256' -Default '')
            $actual = Get-FileSha256 -Path $full
            if ($expected -and $actual -ne $expected.ToLowerInvariant()) {
                $problems.Add(('组件 ' + $name + ' SHA256 不匹配（文件损坏或被替换）: ' + $full))
                continue
            }
        }
        if ($Logger) { $Logger.Detail(('资产校验通过: ' + $name + ' -> ' + (Split-Path $full -Leaf))) }
        $assets.Add([pscustomobject]@{ Kind = 'component'; Name = $name; FullPath = $full; Version = [string](Get-PropertyValue -Object $asset.Data -Name 'version' -Default '') })
    }

    if (-not $SkipExtensions) {
        foreach ($extension in @(Get-PackExtensionAssets -Context $Context)) {
            $full = [System.IO.Path]::GetFullPath($extension.FullPath)
            if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                $problems.Add(('扩展 ' + $extension.Id + ' 的路径逃逸出安装包目录: ' + $full))
                continue
            }
            if (-not (Test-Path -LiteralPath $full)) {
                $problems.Add(('扩展 ' + $extension.Id + ' 文件不存在: ' + $full))
                continue
            }
            if ((Get-Item -LiteralPath $full).Length -le 0) {
                $problems.Add(('扩展 ' + $extension.Id + ' 文件为空: ' + $full))
                continue
            }
            if (-not $SkipHashes) {
                $actual = Get-FileSha256 -Path $full
                if ($extension.Sha256 -and $actual -ne $extension.Sha256.ToLowerInvariant()) {
                    $problems.Add(('扩展 ' + $extension.Id + ' SHA256 不匹配: ' + $full))
                    continue
                }
            }
            $assets.Add([pscustomobject]@{ Kind = 'extension'; Name = $extension.Id; FullPath = $full; Version = $extension.Version })
        }
    }

    return [pscustomobject]@{ Ok = ($problems.Count -eq 0); Problems = @(ConvertTo-PlainArray $problems); Assets = @(ConvertTo-PlainArray $assets) }
}

function Sort-ExtensionAssets {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Extensions)

    $nodes = New-Object System.Collections.Generic.List[object]
    $byId = @{}
    $index = 0
    foreach ($extension in @($Extensions)) {
        $id = [string](Get-PropertyValue -Object $extension -Name 'id' -Default '')
        if ([string]::IsNullOrWhiteSpace($id)) { throw '扩展条目缺少 id' }
        $key = $id.ToLowerInvariant()
        if ($byId.ContainsKey($key)) { throw ('扩展 id 重复: ' + $id) }
        $node = [pscustomobject]@{
            Id       = $key
            Asset    = $extension
            Index    = $index
            Indegree = 0
            Deps     = New-Object System.Collections.Generic.List[string]
        }
        $byId[$key] = $node
        $nodes.Add($node)
        $index++
    }

    $dependents = @{}
    foreach ($node in $nodes) {
        $dependents[$node.Id] = New-Object System.Collections.Generic.List[object]
    }

    foreach ($node in $nodes) {
        $dependencies = @(Get-PropertyValue -Object $node.Asset -Name 'dependsOn' -Default @())
        foreach ($dependency in $dependencies) {
            $depKey = ([string]$dependency).ToLowerInvariant()
            if (-not $byId.ContainsKey($depKey)) {
                throw ('扩展 ' + $node.Asset.id + ' 依赖的 ' + $dependency + ' 不在资产清单中')
            }
            if ($depKey -eq $node.Id) { throw ('扩展 ' + $node.Asset.id + ' 不能依赖自身') }
            $node.Deps.Add($depKey)
            $node.Indegree++
            $dependents[$depKey].Add($node)
        }
    }

    $ready = @($nodes | Where-Object { $_.Indegree -eq 0 } | Sort-Object -Property Index)
    $ordered = New-Object System.Collections.Generic.List[object]

    while ($ready.Count -gt 0) {
        $ready = @($ready | Sort-Object -Property Index)
        $current = $ready[0]
        if ($ready.Count -eq 1) { $ready = @() } else { $ready = @($ready[1..($ready.Count - 1)]) }
        $ordered.Add($current.Asset)
        foreach ($dependent in $dependents[$current.Id]) {
            $dependent.Indegree--
            if ($dependent.Indegree -eq 0) {
                $ready += $dependent
            }
        }
    }

    if ($ordered.Count -ne $nodes.Count) {
        $cycle = @($nodes | Where-Object { $_.Indegree -gt 0 } | ForEach-Object { $_.Asset.id }) -join ', '
        throw ('扩展依赖存在循环，无法排序: ' + $cycle)
    }

    return (ConvertTo-PlainArray $ordered)
}
