# Asset pipeline: safe downloads, extension closure resolution, manifest generation, pack build.
# Every URL is checked before the request; redirects are checked hop by hop.

function Test-PublicIpAddress {
    param([Parameter(Mandatory)][System.Net.IPAddress]$Address)

    if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        $b = $Address.GetAddressBytes()
        if ($b[0] -eq 0) { return $false }
        if ($b[0] -eq 10) { return $false }
        if ($b[0] -eq 127) { return $false }
        if ($b[0] -eq 169 -and $b[1] -eq 254) { return $false }
        if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return $false }
        if ($b[0] -eq 192 -and $b[1] -eq 168) { return $false }
        if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { return $false }
        if ($b[0] -eq 192 -and $b[1] -eq 0 -and $b[2] -eq 0) { return $false }
        if ($b[0] -eq 192 -and $b[1] -eq 0 -and $b[2] -eq 2) { return $false }
        if ($b[0] -eq 198 -and $b[1] -ge 18 -and $b[1] -le 19) { return $false }
        if ($b[0] -eq 198 -and $b[1] -eq 51 -and $b[2] -eq 100) { return $false }
        if ($b[0] -eq 203 -and $b[1] -eq 0 -and $b[2] -eq 113) { return $false }
        if ($b[0] -ge 224) { return $false }
        return $true
    }

    if ($Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetworkV6) {
        if ([System.Net.IPAddress]::IsLoopback($Address)) { return $false }
        if ($Address.IsIPv6LinkLocal) { return $false }
        if ($Address.IsIPv6SiteLocal) { return $false }
        if ($Address.IsIPv6Multicast) { return $false }

        $b = $Address.GetAddressBytes()
        $allZero = $true
        foreach ($value in $b) { if ($value -ne 0) { $allZero = $false; break } }
        if ($allZero) { return $false }
        if (($b[0] -band 0xFE) -eq 0xFC) { return $false }
        if ($b[0] -eq 0x20 -and $b[1] -eq 0x01 -and $b[2] -eq 0x0D -and $b[3] -eq 0xB8) { return $false }

        $isMapped = $true
        for ($i = 0; $i -lt 10; $i++) { if ($b[$i] -ne 0) { $isMapped = $false; break } }
        if ($isMapped -and $b[10] -eq 0xFF -and $b[11] -eq 0xFF) {
            $v4 = [System.Net.IPAddress]::new([byte[]]($b[12..15]))
            return Test-PublicIpAddress -Address $v4
        }
        return $true
    }

    return $false
}

function Assert-SafeDownloadUrl {
    param(
        [Parameter(Mandatory)][string]$Url,
        [switch]$SkipDnsCheck
    )

    $uri = $null
    if (-not [System.Uri]::TryCreate($Url, [System.UriKind]::Absolute, [ref]$uri)) {
        throw ('URL 格式无效: ' + $Url)
    }
    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') {
        throw ('只允许 http/https URL: ' + $Url)
    }
    if ([string]::IsNullOrWhiteSpace($uri.Host)) {
        throw ('URL 缺少主机名: ' + $Url)
    }

    $hostName = $uri.Host.ToLowerInvariant()
    if ($hostName -eq 'localhost' -or $hostName.EndsWith('.localhost')) {
        throw ('拒绝 localhost URL: ' + $Url)
    }

    $ip = $null
    $hostPart = $hostName.Trim('[', ']')
    if ([System.Net.IPAddress]::TryParse($hostPart, [ref]$ip)) {
        if (-not (Test-PublicIpAddress -Address $ip)) {
            throw ('拒绝环回、私有或保留地址: ' + $Url)
        }
        return $uri
    }

    if (-not $SkipDnsCheck) {
        $addresses = [System.Net.Dns]::GetHostAddresses($hostName)
        if ($addresses.Count -eq 0) {
            throw ('无法解析主机: ' + $hostName)
        }
        foreach ($address in $addresses) {
            if (-not (Test-PublicIpAddress -Address $address)) {
                throw ('域名解析到环回、私有或保留地址，已拒绝: ' + $hostName)
            }
        }
    }

    return $uri
}

function Open-SafeHttpResponse {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSeconds = 60,
        [int]$MaxRedirects = 5,
        [string]$Accept = '*/*'
    )

    $currentUrl = $Url
    for ($hop = 0; $hop -le $MaxRedirects; $hop++) {
        $uri = Assert-SafeDownloadUrl -Url $currentUrl
        $request = [System.Net.HttpWebRequest]::Create($uri)
        $request.Method = 'GET'
        $request.AllowAutoRedirect = $false
        $request.UserAgent = 'VSCode-Offline-Setup-Pack/1.0'
        $request.Accept = $Accept
        $request.Timeout = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        try { $request.Headers.Add('Accept-Encoding', 'identity') } catch { }

        $response = $request.GetResponse()
        $statusCode = [int]$response.StatusCode
        if ($statusCode -eq 301 -or $statusCode -eq 302 -or $statusCode -eq 303 -or $statusCode -eq 307 -or $statusCode -eq 308) {
            $location = [string]$response.Headers['Location']
            $response.Close()
            if ([string]::IsNullOrWhiteSpace($location)) {
                throw ('重定向缺少 Location: ' + $currentUrl)
            }
            $currentUrl = ([System.Uri]::new($uri, $location)).AbsoluteUri
            continue
        }
        if ($statusCode -lt 200 -or $statusCode -ge 300) {
            $response.Close()
            throw ('HTTP ' + $statusCode + ': ' + $currentUrl)
        }
        return [pscustomobject]@{ Response = $response; FinalUri = $uri }
    }

    throw ('重定向次数超过 ' + $MaxRedirects + ': ' + $Url)
}

function Test-FileMagic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('MZ', 'ZIP', '7Z')][string]$Expected
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $bytes = New-Object byte[] 8
    $stream = [System.IO.File]::OpenRead($Path)
    try { $read = $stream.Read($bytes, 0, $bytes.Length) } finally { $stream.Close() }

    if ($Expected -eq 'MZ') {
        return ($read -ge 2 -and $bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A)
    }
    if ($Expected -eq 'ZIP') {
        return ($read -ge 4 -and $bytes[0] -eq 0x50 -and $bytes[1] -eq 0x4B -and ($bytes[2] -eq 3 -or $bytes[2] -eq 5 -or $bytes[2] -eq 7))
    }
    return ($read -ge 6 -and $bytes[0] -eq 0x37 -and $bytes[1] -eq 0x7A -and $bytes[2] -eq 0xBC -and $bytes[3] -eq 0xAF -and $bytes[4] -eq 0x27 -and $bytes[5] -eq 0x1C)
}

function Invoke-SafeDownload {
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [string]$Label = '',
        [ValidateSet('MZ', 'ZIP', '7Z', '')][string]$ExpectedMagic = '',
        [long]$MinimumBytes = 1,
        [switch]$Force,
        $Logger = $null
    )

    if ((Test-Path -LiteralPath $Destination) -and -not $Force) {
        if ($Logger) { $Logger.Detail('已存在，跳过下载: ' + $Destination) }
        return [pscustomobject]@{ Skipped = $true; Path = $Destination; FinalUri = $null }
    }

    $dir = Split-Path -Parent $Destination
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $part = $Destination + '.part'
    if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force }

    if ($Logger) { $Logger.Step('下载' + $(if ($Label) { ' ' + $Label } else { '' }) + ': ' + $Url) }

    $opened = Open-SafeHttpResponse -Url $Url -TimeoutSeconds 120
    $response = $opened.Response
    $stream = $null
    $file = $null
    $success = $false

    try {
        $contentLength = $response.ContentLength
        $compressed = ([string]$response.ContentEncoding -match 'gzip')
        $stream = $response.GetResponseStream()
        if ($compressed) {
            $stream = New-Object System.IO.Compression.GZipStream($stream, [System.IO.Compression.CompressionMode]::Decompress)
        }

        $file = [System.IO.File]::Create($part)
        $buffer = New-Object byte[] 1048576
        $total = 0L
        $nextPercent = 20

        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $file.Write($buffer, 0, $read)
            $total += $read
            if ($Logger -and -not $compressed -and $contentLength -gt 0) {
                $percent = [int](($total * 100) / $contentLength)
                if ($percent -ge $nextPercent) {
                    $Logger.Detail(('  ' + $percent + '%'))
                    $nextPercent += 20
                }
            }
        }

        if (-not $compressed -and $contentLength -gt 0 -and $total -ne $contentLength) {
            throw ('下载不完整: 收到 ' + $total + ' / ' + $contentLength + ' 字节')
        }
        if ($total -lt $MinimumBytes) {
            throw ('文件过小，可能不是有效资产: ' + $total + ' 字节')
        }

        $success = $true
    }
    finally {
        if ($file) { $file.Close() }
        if ($stream) { $stream.Close() }
        $response.Close()
        if (-not $success -and (Test-Path -LiteralPath $part)) {
            Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue
        }
    }

    Move-Item -LiteralPath $part -Destination $Destination -Force

    if ($ExpectedMagic -and -not (Test-FileMagic -Path $Destination -Expected $ExpectedMagic)) {
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
        throw ('文件类型校验失败（期望 ' + $ExpectedMagic + '）: ' + $Destination)
    }

    $sizeMB = [Math]::Round((Get-Item -LiteralPath $Destination).Length / 1MB, 1)
    if ($Logger) { $Logger.Ok(('下载完成: ' + (Split-Path -Leaf $Destination) + ' (' + $sizeMB + ' MB)')) }
    return [pscustomobject]@{ Skipped = $false; Path = $Destination; FinalUri = $opened.FinalUri.AbsoluteUri }
}

function Invoke-SafeJsonRequest {
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Accept = 'application/json',
        [int]$TimeoutSeconds = 60
    )
    $opened = Open-SafeHttpResponse -Url $Url -Accept $Accept -TimeoutSeconds $TimeoutSeconds
    $response = $opened.Response
    $reader = $null
    try {
        $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
        $text = $reader.ReadToEnd()
        return ConvertFrom-Json -InputObject $text -ErrorAction Stop
    }
    finally {
        if ($reader) { $reader.Close() }
        $response.Close()
    }
}

function Test-DownloadedSignature {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedSubjectContains = ''
    )
    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $Path
        if ($signature.Status -ne 'Valid') {
            return [pscustomobject]@{ Ok = $false; Detail = ('签名状态: ' + $signature.Status) }
        }
        if ($ExpectedSubjectContains -and $signature.SignerCertificate.Subject -notmatch [regex]::Escape($ExpectedSubjectContains)) {
            return [pscustomobject]@{ Ok = $false; Detail = ('签名主体不符合预期: ' + $signature.SignerCertificate.Subject) }
        }
        return [pscustomobject]@{ Ok = $true; Detail = $signature.SignerCertificate.Subject }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message }
    }
}

function Get-VSCodeReleaseVersion {
    param(
        [string]$Version = 'latest',
        $Logger = $null
    )
    if ($Version -and $Version -ne 'latest') {
        if ($Version -notmatch '^[0-9][0-9A-Za-z.-]*$') {
            throw ('VSCode 版本号无效: ' + $Version)
        }
        return $Version
    }
    if ($Logger) { $Logger.Info('查询 VSCode 最新稳定版...') }
    $releases = Invoke-SafeJsonRequest -Url 'https://update.code.visualstudio.com/api/releases/stable' -Accept 'application/json'
    $first = @($releases) | Select-Object -First 1
    if (-not $first) { throw 'VSCode releases API 返回为空' }
    return [string]$first
}

function Select-WinLibsAsset {
    param(
        [Parameter(Mandatory)]$Release,
        [string]$ExactName = ''
    )

    $assets = @(Get-PropertyValue -Object $Release -Name 'assets' -Default @())
    if ($ExactName) {
        $exact = $assets | Where-Object { $_.name -eq $ExactName } | Select-Object -First 1
        if (-not $exact) { throw ('winlibs release 中找不到资产: ' + $ExactName) }
        return $exact
    }

    $patterns = @(
        '^winlibs-x86_64-posix-seh-gcc-.*-mingw-w64ucrt-.*\.7z$',
        '^winlibs-x86_64-posix-seh-gcc-.*-mingw-w64ucrt-.*\.zip$',
        '^winlibs-x86_64-posix-seh-gcc-.*-mingw-w64ucrt-.*\.7z$',
        '^winlibs-x86_64-posix-seh-gcc-.*-mingw-w64ucrt-.*\.zip$'
    )

    for ($i = 0; $i -lt $patterns.Count; $i++) {
        $excludeLlvm = ($i -lt 2)
        $candidates = @($assets | Where-Object {
            $_.name -match $patterns[$i] -and
            (-not $excludeLlvm -or $_.name -notmatch 'llvm')
        })
        if ($candidates.Count -gt 0) {
            return ($candidates | Sort-Object -Property size | Select-Object -First 1)
        }
    }

    throw 'winlibs release 中找不到 x86_64 posix-seh UCRT 的 7z/zip 资产'
}

function Test-VsixPackageInfo {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedId = '',
        [string]$ExpectedVersion = ''
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Ok = $false; Id = $null; Version = $null; Error = '文件不存在' }
    }
    if (-not (Test-FileMagic -Path $Path -Expected 'ZIP')) {
        return [pscustomobject]@{ Ok = $false; Id = $null; Version = $null; Error = '不是 ZIP/VSIX 文件' }
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = $null
    $reader = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        $entry = $archive.Entries | Where-Object { ($_.FullName -replace '\\', '/') -eq 'extension/package.json' } | Select-Object -First 1
        if (-not $entry) {
            return [pscustomobject]@{ Ok = $false; Id = $null; Version = $null; Error = 'VSIX 缺少 extension/package.json' }
        }
        $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
        $package = ConvertFrom-Json -InputObject $reader.ReadToEnd() -ErrorAction Stop
        $id = ([string]$package.publisher + '.' + [string]$package.name).ToLowerInvariant()
        $version = [string]$package.version
        if ($ExpectedId -and $id -ne $ExpectedId.ToLowerInvariant()) {
            return [pscustomobject]@{ Ok = $false; Id = $id; Version = $version; Error = ('ID 不匹配，期望 ' + $ExpectedId) }
        }
        if ($ExpectedVersion -and $version -ne $ExpectedVersion) {
            return [pscustomobject]@{ Ok = $false; Id = $id; Version = $version; Error = ('版本不匹配，期望 ' + $ExpectedVersion) }
        }
        return [pscustomobject]@{ Ok = $true; Id = $id; Version = $version; Error = $null }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Id = $null; Version = $null; Error = $_.Exception.Message }
    }
    finally {
        if ($reader) { $reader.Close() }
        if ($archive) { $archive.Dispose() }
    }
}

function Get-ExtensionPackagesFromDirectory {
    param(
        [Parameter(Mandatory)][string]$ExtensionsDir,
        $Logger = $null
    )

    $map = @{}
    if (-not (Test-Path -LiteralPath $ExtensionsDir)) { return $map }

    foreach ($directory in @(Get-ChildItem -LiteralPath $ExtensionsDir -Directory -ErrorAction SilentlyContinue)) {
        $packagePath = Join-Path $directory.FullName 'package.json'
        if (-not (Test-Path -LiteralPath $packagePath)) { continue }

        try {
            $package = ConvertFrom-Json -InputObject (Read-TextFile -Path $packagePath) -ErrorAction Stop
        }
        catch {
            if ($Logger) { $Logger.Warn('跳过无法解析的扩展 package.json: ' + $packagePath) }
            continue
        }

        $publisher = [string](Get-PropertyValue -Object $package -Name 'publisher' -Default '')
        $name = [string](Get-PropertyValue -Object $package -Name 'name' -Default '')
        $version = [string](Get-PropertyValue -Object $package -Name 'version' -Default '')
        if (-not $publisher -or -not $name -or -not $version) { continue }

        $platform = ''
        if ($directory.Name -match '-(win32-x64|win32-arm64|linux-x64|linux-arm64|darwin-x64|darwin-arm64|alpine-x64|web)$') {
            $platform = $matches[1]
        }
        if ($platform -and $platform -ne 'win32-x64') { continue }

        $hardDependencies = New-Object System.Collections.Generic.List[string]
        foreach ($value in @(Get-PropertyValue -Object $package -Name 'extensionDependencies' -Default @())) {
            $dep = ([string]$value).ToLowerInvariant()
            if ($dep -and -not $hardDependencies.Contains($dep)) { $hardDependencies.Add($dep) }
        }

        $packMembers = New-Object System.Collections.Generic.List[string]
        foreach ($value in @(Get-PropertyValue -Object $package -Name 'extensionPack' -Default @())) {
            $member = ([string]$value).ToLowerInvariant()
            if ($member -and -not $packMembers.Contains($member)) { $packMembers.Add($member) }
        }

        $dependencies = New-Object System.Collections.Generic.List[string]
        foreach ($dep in @($hardDependencies)) {
            if (-not $dependencies.Contains($dep)) { $dependencies.Add($dep) }
        }
        foreach ($member in @($packMembers)) {
            if (-not $dependencies.Contains($member)) { $dependencies.Add($member) }
        }

        $id = ($publisher + '.' + $name).ToLowerInvariant()
        $item = [pscustomobject]@{
            Id             = $id
            Publisher      = $publisher
            Name           = $name
            Version        = $version
            DependsOn      = @(ConvertTo-PlainArray $dependencies)
            Dependencies   = @(ConvertTo-PlainArray $hardDependencies)
            PackMembers    = @(ConvertTo-PlainArray $packMembers)
            TargetPlatform = $platform
            Folder         = $directory.FullName
        }

        if (-not $map.ContainsKey($id)) {
            $map[$id] = $item
        }
        elseif ($platform -eq 'win32-x64' -and $map[$id].TargetPlatform -ne 'win32-x64') {
            $map[$id] = $item
        }
    }

    return $map
}

function Resolve-ExtensionsFromDirectory {
    param(
        [Parameter(Mandatory)][string]$ExtensionsDir,
        [Parameter(Mandatory)][string[]]$Roots,
        $Logger = $null
    )

    $map = Get-ExtensionPackagesFromDirectory -ExtensionsDir $ExtensionsDir -Logger $Logger
    if ($map.Count -eq 0) {
        throw ('扩展目录为空或没有有效扩展: ' + $ExtensionsDir)
    }

    $selected = @{}
    $queue = New-Object System.Collections.Generic.Queue[string]
    foreach ($root in $Roots) {
        $key = $root.ToLowerInvariant()
        if (-not $map.ContainsKey($key)) {
            throw ('找不到根扩展: ' + $root + '（已安装目录: ' + $ExtensionsDir + '）')
        }
        if (-not $selected.ContainsKey($key)) {
            $selected[$key] = $true
            $queue.Enqueue($key)
        }
    }

    while ($queue.Count -gt 0) {
        $id = $queue.Dequeue()
        foreach ($dependency in @($map[$id].DependsOn)) {
            if ($map.ContainsKey($dependency)) {
                if (-not $selected.ContainsKey($dependency)) {
                    $selected[$dependency] = $true
                    $queue.Enqueue($dependency)
                }
            }
            elseif ($Logger) {
                $Logger.Warn(('扩展依赖未安装，已忽略: ' + $id + ' -> ' + $dependency))
            }
        }
    }

    # A pack may list a member that in turn lists the pack as a dependency
    # (ms-python.python <-> ms-python.debugpy). Drop the member->pack edge so the
    # install order stays acyclic; all members are installed before the pack.
    $packOf = @{}
    foreach ($id in @($selected.Keys | Sort-Object)) {
        $package = $map[$id]
        foreach ($member in @($package.PackMembers)) {
            if ($selected.ContainsKey($member) -and $member -ne $id) {
                if (-not $packOf.ContainsKey($member)) {
                    $packOf[$member] = New-Object System.Collections.Generic.List[string]
                }
                if (-not $packOf[$member].Contains($id)) { $packOf[$member].Add($id) }
            }
        }
    }

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($id in @($selected.Keys | Sort-Object)) {
        $package = $map[$id]
        $filtered = New-Object System.Collections.Generic.List[string]
        foreach ($dependency in @($package.DependsOn)) {
            if (-not $selected.ContainsKey($dependency)) { continue }
            if ($packOf.ContainsKey($id) -and $packOf[$id].Contains($dependency)) {
                if ($Logger) { $Logger.Detail('打破 pack 环: ' + $id + ' -> ' + $dependency) }
                continue
            }
            $filtered.Add($dependency)
        }
        $result.Add([pscustomobject]@{
            Id             = $package.Id
            Publisher      = $package.Publisher
            Name           = $package.Name
            Version        = $package.Version
            DependsOn      = @(ConvertTo-PlainArray $filtered)
            TargetPlatform = $package.TargetPlatform
            Folder         = $package.Folder
        })
    }

    $sorted = @(Sort-ExtensionAssets -Extensions @(ConvertTo-PlainArray $result))
    if ($Logger) {
        foreach ($asset in $sorted) {
            $Logger.Detail(('扩展闭包: ' + $asset.Id + '@' + $asset.Version + $(if ($asset.TargetPlatform) { ' [' + $asset.TargetPlatform + ']' } else { '' })))
        }
    }
    return (ConvertTo-PlainArray $sorted)
}

function Resolve-ExtensionsWithCode {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Logger,
        [Parameter(Mandatory)][string]$CodeCli,
        [Parameter(Mandatory)][string[]]$Roots
    )

    $temp = Join-Path $Context.LogsDir ('_resolve-' + [guid]::NewGuid().ToString('N'))
    $extensionsDir = Join-Path $temp 'extensions'
    $dataDir = Join-Path $temp 'data'
    try {
        New-Item -ItemType Directory -Path $extensionsDir -Force | Out-Null
        New-Item -ItemType Directory -Path $dataDir -Force | Out-Null

        foreach ($root in $Roots) {
            $Logger.Step('解析扩展及其依赖: ' + $root)
            $result = Invoke-CodeCli -CodeCli $CodeCli -Arguments @(
                '--extensions-dir', $extensionsDir,
                '--user-data-dir', $dataDir,
                '--install-extension', $root,
                '--force'
            )
            if ($result.ExitCode -ne 0) {
                throw ('code --install-extension 失败（' + $root + '）: ' + $result.Output)
            }
            foreach ($line in ($result.Output -split "`r?`n")) {
                if ($line.Trim() -ne '') { $Logger.Detail('  ' + $line.Trim()) }
            }
        }

        return Resolve-ExtensionsFromDirectory -ExtensionsDir $extensionsDir -Roots $Roots -Logger $Logger
    }
    finally {
        if (Test-Path -LiteralPath $temp) {
            try { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

function Get-ExtensionVsixUrl {
    param(
        [Parameter(Mandatory)][string]$Publisher,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Version,
        [string]$TargetPlatform
    )
    $publisherPart = [System.Uri]::EscapeDataString($Publisher)
    $namePart = [System.Uri]::EscapeDataString($Name)
    $versionPart = [System.Uri]::EscapeDataString($Version)
    $url = 'https://marketplace.visualstudio.com/_apis/public/gallery/publishers/' + $publisherPart + '/vsextensions/' + $namePart + '/' + $versionPart + '/vspackage'
    if ($TargetPlatform) {
        $url += '?targetPlatform=' + [System.Uri]::EscapeDataString($TargetPlatform)
    }
    return $url
}

function Get-ExtensionFileName {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Version,
        [string]$TargetPlatform
    )
    $safeId = ($Id -replace '[^A-Za-z0-9._-]', '_')
    $safeVersion = ($Version -replace '[^A-Za-z0-9._-]', '_')
    $name = $safeId + '-' + $safeVersion
    if ($TargetPlatform) { $name += '-' + ($TargetPlatform -replace '[^A-Za-z0-9._-]', '_') }
    return $name + '.vsix'
}

function Invoke-AssetFetch {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Logger,
        [string]$VSCodeVersion = 'latest',
        [string]$PythonVersion = '',
        [string]$MinGWAsset = '',
        [string[]]$Extensions = @(),
        [string]$CodeCli = '',
        [string]$GitHubProxy = '',
        [switch]$MinGWLatest,
        [switch]$IncludeLanguagePack,
        [switch]$SkipExtensions,
        [switch]$UseInstalledExtensions,
        [switch]$PlanOnly,
        [switch]$Force
    )

    foreach ($dir in @($Context.InstallerDir, $Context.ToolsDir, $Context.ExtensionsDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    if (-not $PythonVersion) {
        $PythonVersion = [string](Get-PropertyValue -Object $Context.Paths.Python -Name 'Version' -Default '3.12.10')
    }
    if ($PythonVersion -notmatch '^\d+\.\d+\.\d+$') {
        throw ('Python 版本号无效: ' + $PythonVersion)
    }

    $vscodeVersion = Get-VSCodeReleaseVersion -Version $VSCodeVersion -Logger $Logger
    $vscodeFile = 'VSCodeSetup-x64-' + $vscodeVersion + '.exe'
    $vscodeUrl = 'https://update.code.visualstudio.com/' + $vscodeVersion + '/win32-x64/stable'

    $pythonFile = 'python-' + $PythonVersion + '-amd64.exe'
    $pythonUrl = 'https://www.python.org/ftp/python/' + $PythonVersion + '/' + $pythonFile

    $Logger.Info('VSCode: ' + $vscodeVersion)
    $Logger.Info('Python: ' + $PythonVersion)

    $pinnedMingw = Get-PropertyValue -Object $Context.Paths.MinGW -Name 'Pinned' -Default $null
    $expectedMingwHash = ''
    $shaAsset = $null

    if (-not $MinGWAsset -and -not $MinGWLatest -and $null -ne $pinnedMingw) {
        $mingwName = [string](Get-PropertyValue -Object $pinnedMingw -Name 'Asset' -Default '')
        $mingwUrl = [string](Get-PropertyValue -Object $pinnedMingw -Name 'Url' -Default '')
        $mingwVersion = [string](Get-PropertyValue -Object $pinnedMingw -Name 'Version' -Default '')
        $expectedMingwHash = [string](Get-PropertyValue -Object $pinnedMingw -Name 'Sha256' -Default '')
        $Logger.Info('MinGW（锁定版本）: ' + $mingwName)
    }
    else {
        $release = Invoke-SafeJsonRequest -Url 'https://api.github.com/repos/brechtsanders/winlibs_mingw/releases/latest' -Accept 'application/vnd.github+json'
        $selectedMingw = Select-WinLibsAsset -Release $release -ExactName $MinGWAsset
        $mingwName = [string]$selectedMingw.name
        $mingwUrl = [string]$selectedMingw.browser_download_url
        $mingwVersion = [string](Get-PropertyValue -Object $release -Name 'tag_name' -Default '')
        $digest = [string](Get-PropertyValue -Object $selectedMingw -Name 'digest' -Default '')
        if ($digest -match '^sha256:([0-9a-fA-F]{64})$') { $expectedMingwHash = $matches[1] }
        $shaAsset = @(Get-PropertyValue -Object $release -Name 'assets' -Default @()) | Where-Object { $_.name -eq ($mingwName + '.sha256') } | Select-Object -First 1
        $Logger.Info('MinGW: ' + $mingwName)
    }

    $mingwDownloadUrl = $mingwUrl
    if ($GitHubProxy) {
        $mingwDownloadUrl = $GitHubProxy.TrimEnd('/') + '/' + $mingwUrl
        $Logger.Info('MinGW 下载经公共 GitHub 代理: ' + $GitHubProxy)
    }

    if ($PlanOnly) {
        $Logger.Info('PlanOnly: ' + $vscodeUrl)
        $Logger.Info('PlanOnly: ' + $pythonUrl)
        $Logger.Info('PlanOnly: ' + $mingwDownloadUrl)
        if ($expectedMingwHash) { $Logger.Info('PlanOnly: MinGW SHA256 = ' + $expectedMingwHash) }
        if (-not $SkipExtensions) {
            $roots = if ($Extensions.Count -gt 0) { $Extensions } else { @($Context.Paths.ExtensionRoots) }
            if ($IncludeLanguagePack) { $roots += [string](Get-PropertyValue -Object $Context.Paths.OptionalExtensionRoots -Name 'zh-cn' -Default '') }
            $Logger.Info('PlanOnly: 扩展根 = ' + ($roots -join ', ') + '（实际闭包在下载阶段解析）')
        }
        return [pscustomobject]@{ PlanOnly = $true; VSCodeVersion = $vscodeVersion; PythonVersion = $PythonVersion; MinGW = $mingwName }
    }

    $vscodePath = Join-Path $Context.InstallerDir $vscodeFile
    Invoke-SafeDownload -Url $vscodeUrl -Destination $vscodePath -Label ('VSCode ' + $vscodeVersion) -ExpectedMagic 'MZ' -MinimumBytes 10485760 -Force:$Force -Logger $Logger | Out-Null
    $vscodeSignature = Test-DownloadedSignature -Path $vscodePath -ExpectedSubjectContains 'Microsoft'
    if (-not $vscodeSignature.Ok) { $Logger.Warn('VSCode 安装包数字签名校验未通过（将继续，但请核对来源）: ' + $vscodeSignature.Detail) }
    else { $Logger.Detail('VSCode 签名: ' + $vscodeSignature.Detail) }

    $pythonPath = Join-Path $Context.InstallerDir $pythonFile
    Invoke-SafeDownload -Url $pythonUrl -Destination $pythonPath -Label ('Python ' + $PythonVersion) -ExpectedMagic 'MZ' -MinimumBytes 10485760 -Force:$Force -Logger $Logger | Out-Null
    $pythonSignature = Test-DownloadedSignature -Path $pythonPath -ExpectedSubjectContains 'Python Software Foundation'
    if (-not $pythonSignature.Ok) { $Logger.Warn('Python 安装包数字签名校验未通过（将继续，但请核对来源）: ' + $pythonSignature.Detail) }
    else { $Logger.Detail('Python 签名: ' + $pythonSignature.Detail) }

    $mingwPath = Join-Path $Context.ToolsDir $mingwName
    $mingwMagic = if ($mingwName.ToLowerInvariant().EndsWith('.7z')) { '7Z' } else { 'ZIP' }
    Invoke-SafeDownload -Url $mingwDownloadUrl -Destination $mingwPath -Label ('MinGW ' + $mingwName) -ExpectedMagic $mingwMagic -MinimumBytes 20971520 -Force:$Force -Logger $Logger | Out-Null
    $mingwHash = Get-FileSha256 -Path $mingwPath

    $sevenZipPath = $null
    $sevenZipManifest = $null
    if ($mingwMagic -eq '7Z') {
        $sevenZipPath = Join-Path $Context.ToolsDir '7zr.exe'
        Invoke-SafeDownload -Url 'https://www.7-zip.org/a/7zr.exe' -Destination $sevenZipPath -Label '7-Zip 独立解压器' -ExpectedMagic 'MZ' -MinimumBytes 100000 -Force:$Force -Logger $Logger | Out-Null
        $sevenZipManifest = [pscustomobject]@{
            name    = '7-Zip standalone'
            version = '7zr'
            file    = 'tools/7zr.exe'
            sha256  = (Get-FileSha256 -Path $sevenZipPath)
            url     = 'https://www.7-zip.org/a/7zr.exe'
        }
    }

    if ($expectedMingwHash) {
        if ($mingwHash -ne $expectedMingwHash.ToLowerInvariant()) {
            throw ('winlibs SHA256 与官方锁定值不一致。期望 ' + $expectedMingwHash + '，实际 ' + $mingwHash)
        }
        $Logger.Detail('winlibs SHA256 与官方锁定值一致')
    }
    elseif ($shaAsset) {
        $shaTemp = Join-Path $env:TEMP ('winlibs-' + [guid]::NewGuid().ToString('N') + '.sha256')
        try {
            $shaUrl = [string]$shaAsset.browser_download_url
            if ($GitHubProxy) { $shaUrl = $GitHubProxy.TrimEnd('/') + '/' + $shaUrl }
            Invoke-SafeDownload -Url $shaUrl -Destination $shaTemp -Label 'winlibs SHA256' -MinimumBytes 64 -Force -Logger $null | Out-Null
            $shaText = Read-TextFile -Path $shaTemp
            if ($shaText -match '([0-9a-fA-F]{64})') {
                $upstream = $matches[1].ToLowerInvariant()
                if ($upstream -ne $mingwHash) {
                    throw ('winlibs SHA256 与上游不一致。期望 ' + $upstream + '，实际 ' + $mingwHash)
                }
                $Logger.Detail('winlibs 上游 SHA256 校验通过')
            }
        }
        finally {
            if (Test-Path -LiteralPath $shaTemp) { Remove-Item -LiteralPath $shaTemp -Force -ErrorAction SilentlyContinue }
        }
    }

    $extensionEntries = @()
    if (-not $SkipExtensions) {
        $roots = if ($Extensions.Count -gt 0) { @($Extensions) } else { @($Context.Paths.ExtensionRoots) }
        if ($IncludeLanguagePack) {
            $languagePack = [string](Get-PropertyValue -Object $Context.Paths.OptionalExtensionRoots -Name 'zh-cn' -Default '')
            if ($languagePack) { $roots += $languagePack }
        }
        foreach ($root in $roots) {
            if ($root -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*\.[A-Za-z0-9._-]+$') {
                throw ('扩展 ID 无效: ' + $root)
            }
        }

        if (-not $CodeCli) {
            $command = Get-Command 'code.cmd' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($command) { $CodeCli = $command.Source }
        }

        $resolved = $null
        if (-not $UseInstalledExtensions -and $CodeCli) {
            try {
                $resolved = @(Resolve-ExtensionsWithCode -Context $Context -Logger $Logger -CodeCli $CodeCli -Roots $roots)
            }
            catch {
                $Logger.Warn('用 code CLI 解析扩展闭包失败，回退到本机已安装扩展: ' + $_.Exception.Message)
            }
        }

        if (-not $resolved) {
            $installedDir = Join-Path $env:USERPROFILE '.vscode\extensions'
            $Logger.Info('从本机扩展目录解析闭包: ' + $installedDir)
            $resolved = @(Resolve-ExtensionsFromDirectory -ExtensionsDir $installedDir -Roots $roots -Logger $Logger)
        }

        $index = 0
        foreach ($extension in $resolved) {
            $fileName = Get-ExtensionFileName -Id $extension.Id -Version $extension.Version -TargetPlatform $extension.TargetPlatform
            $filePath = Join-Path $Context.ExtensionsDir $fileName
            $url = Get-ExtensionVsixUrl -Publisher $extension.Publisher -Name $extension.Name -Version $extension.Version -TargetPlatform $extension.TargetPlatform

            $reuse = (Test-Path -LiteralPath $filePath) -and -not $Force
            if ($reuse) {
                $info = Test-VsixPackageInfo -Path $filePath -ExpectedId $extension.Id -ExpectedVersion $extension.Version
                if (-not $info.Ok) { $reuse = $false }
            }
            if (-not $reuse) {
                try {
                    Invoke-SafeDownload -Url $url -Destination $filePath -Label $extension.Id -ExpectedMagic 'ZIP' -MinimumBytes 1024 -Force -Logger $Logger | Out-Null
                }
                catch {
                    if ($extension.TargetPlatform) {
                        $fallbackUrl = Get-ExtensionVsixUrl -Publisher $extension.Publisher -Name $extension.Name -Version $extension.Version -TargetPlatform ''
                        $Logger.Warn('平台特定 vsix 下载失败，尝试通用包: ' + $extension.Id)
                        Invoke-SafeDownload -Url $fallbackUrl -Destination $filePath -Label $extension.Id -ExpectedMagic 'ZIP' -MinimumBytes 1024 -Force -Logger $Logger | Out-Null
                    }
                    else {
                        throw
                    }
                }
            }

            $info = Test-VsixPackageInfo -Path $filePath -ExpectedId $extension.Id -ExpectedVersion $extension.Version
            if (-not $info.Ok) {
                throw ('VSIX 校验失败: ' + $extension.Id + ' - ' + $info.Error)
            }

            $extensionEntries += [pscustomobject]@{
                id             = $extension.Id
                version        = $extension.Version
                file           = 'extensions/' + $fileName
                sha256         = (Get-FileSha256 -Path $filePath)
                targetPlatform = $extension.TargetPlatform
                dependsOn      = @($extension.DependsOn)
                installOrder   = $index
                required       = $true
            }
            $index++
        }
    }

    $mingwManifest = [pscustomobject]@{
        name     = $mingwName
        version  = $mingwVersion
        file     = 'tools/' + $mingwName
        sha256   = $mingwHash
        url      = $mingwUrl
        layout   = 'mingw64'
    }
    if ($sevenZipPath) { $mingwManifest | Add-Member -NotePropertyName sevenZip -NotePropertyValue 'tools/7zr.exe' }
    if ($GitHubProxy) { $mingwManifest | Add-Member -NotePropertyName mirror -NotePropertyValue $GitHubProxy }

    $components = [pscustomobject]@{
        vscode = [pscustomobject]@{
            name = 'Microsoft Visual Studio Code'
            version = $vscodeVersion
            file = 'installer/' + $vscodeFile
            sha256 = (Get-FileSha256 -Path $vscodePath)
            url = $vscodeUrl
        }
        python = [pscustomobject]@{
            name = 'Python'
            version = $PythonVersion
            file = 'installer/' + $pythonFile
            sha256 = (Get-FileSha256 -Path $pythonPath)
            url = $pythonUrl
        }
        mingw = $mingwManifest
    }
    if ($sevenZipManifest) {
        $components | Add-Member -NotePropertyName 'sevenZip' -NotePropertyValue $sevenZipManifest
    }

    $manifest = [pscustomobject]@{
        schemaVersion = 1
        packVersion   = [string]$Context.Version
        generatedAt   = (Get-Date).ToString('o')
        platform      = 'win32-x64'
        components    = $components
        extensions    = @($extensionEntries)
    }

    $manifestText = $manifest | ConvertTo-Json -Depth 10
    Write-Utf8NoBom -Path $Context.ManifestPath -Content $manifestText
    $contextManifest = ConvertFrom-Json -InputObject $manifestText
    $shape = Test-ManifestObject -Manifest $contextManifest
    if (-not $shape.Ok) {
        throw ('生成的 MANIFEST.json 校验失败: ' + ($shape.Problems -join '; '))
    }

    $Logger.Ok('MANIFEST.json 已生成: ' + $Context.ManifestPath)
    $Logger.Info(('扩展数量: ' + $extensionEntries.Count))
    return [pscustomobject]@{
        ManifestPath = $Context.ManifestPath
        VSCodeVersion = $vscodeVersion
        PythonVersion = $PythonVersion
        MinGW = $mingwName
        Extensions = @($extensionEntries)
    }
}

function Build-PackArchive {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Logger,
        [string]$OutputDir = '',
        [switch]$Force
    )

    $validation = Assert-PackAssets -Context $Context -Logger $Logger
    if (-not $validation.Ok) {
        throw ('资产校验失败，未生成 zip: ' + ($validation.Problems -join '; '))
    }

    if (-not $OutputDir) { $OutputDir = Join-Path $Context.Root 'dist' }
    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    $zipName = 'VSCode-Offline-Setup-Pack-' + $Context.Version + '-win32-x64.zip'
    $zipPath = Join-Path $OutputDir $zipName
    if ((Test-Path -LiteralPath $zipPath) -and -not $Force) {
        throw ('目标 zip 已存在（使用 -Force 覆盖）: ' + $zipPath)
    }

    $stagingParent = Join-Path $env:TEMP ('vscode-pack-build-' + [guid]::NewGuid().ToString('N'))
    $stagingRoot = Join-Path $stagingParent ('VSCode-Offline-Setup-Pack-' + $Context.Version)
    try {
        New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null

        foreach ($fileName in @('README.md', 'VERSION', 'NOTICE.md', 'MANIFEST.json', 'Install.cmd', 'Install-D.cmd', 'Repair-WorkShortcut.cmd')) {
            $source = Join-Path $Context.Root $fileName
            if (Test-Path -LiteralPath $source) {
                Copy-Item -LiteralPath $source -Destination $stagingRoot -Force
            }
        }

        foreach ($dirName in @('installer', 'tools', 'extensions', 'config', 'examples', 'scripts', 'docs')) {
            $source = Join-Path $Context.Root $dirName
            if (Test-Path -LiteralPath $source) {
                $destination = Join-Path $stagingRoot $dirName
                New-Item -ItemType Directory -Path $destination -Force | Out-Null
                Copy-DirectoryTree -Source $source -Destination $destination -Threads 8 -TimeoutSeconds 1800 | Out-Null
            }
        }

        foreach ($unwanted in @(
            (Join-Path $stagingRoot 'logs'),
            (Join-Path $stagingRoot 'dist')
        )) {
            if (Test-Path -LiteralPath $unwanted) {
                Remove-Item -LiteralPath $unwanted -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        Get-ChildItem -LiteralPath $stagingRoot -Directory -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like '_resolve-*' -or $_.Name -like 'tmp-mingw-*' } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        Get-ChildItem -LiteralPath $stagingRoot -File -Recurse -Filter '*.part' -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue

        Add-Type -AssemblyName System.IO.Compression
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

        # ZipArchive instead of CreateFromDirectory: the archive must have exactly
        # one forward-slash root folder, independent of the temporary staging name.
        $archive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $basePrefix = $stagingRoot.TrimEnd('\') + '\'
            $rootName = 'VSCode-Offline-Setup-Pack-' + $Context.Version
            foreach ($file in @(Get-ChildItem -LiteralPath $stagingRoot -File -Recurse)) {
                $relative = $file.FullName.Substring($basePrefix.Length)
                $entryName = $rootName + '/' + ($relative -replace '\\', '/')
                $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = $file.LastWriteTime
                $inStream = $null
                $outStream = $null
                try {
                    $inStream = [System.IO.File]::OpenRead($file.FullName)
                    $outStream = $entry.Open()
                    $inStream.CopyTo($outStream)
                }
                finally {
                    if ($outStream) { $outStream.Close() }
                    if ($inStream) { $inStream.Close() }
                }
            }
        }
        finally {
            $archive.Dispose()
        }

        $hash = Get-FileSha256 -Path $zipPath
        $hashFile = $zipPath + '.sha256'
        Write-Utf8NoBom -Path $hashFile -Content ($hash + '  ' + $zipName + [Environment]::NewLine)
        $sizeMB = [Math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 1)
        $Logger.Ok(('安装包已生成: ' + $zipPath + ' (' + $sizeMB + ' MB)'))
        $Logger.Info('SHA256: ' + $hash)
        return [pscustomobject]@{ ZipPath = $zipPath; Sha256 = $hash; SizeMB = $sizeMB; HashFile = $hashFile }
    }
    finally {
        if (Test-Path -LiteralPath $stagingParent) {
            try { Remove-Item -LiteralPath $stagingParent -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}
