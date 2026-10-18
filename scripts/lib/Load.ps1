# Single loader for the library surface. Order matters: Common defines PackLogger first.
$libRoot = $PSScriptRoot

. (Join-Path $libRoot 'Common.ps1')
. (Join-Path $libRoot 'Pack.ps1')
. (Join-Path $libRoot 'VSCode.ps1')
. (Join-Path $libRoot 'Python.ps1')
. (Join-Path $libRoot 'MinGW.ps1')
. (Join-Path $libRoot 'UserConfig.ps1')
. (Join-Path $libRoot 'DataRoot.ps1')
. (Join-Path $libRoot 'Verification.ps1')
. (Join-Path $libRoot 'AssetPipeline.ps1')
