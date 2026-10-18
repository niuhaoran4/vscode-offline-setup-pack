# installer/

这个目录由 `scripts/fetch-assets.ps1` 填充：

- `VSCodeSetup-x64-<version>.exe`
- `python-<version>-amd64.exe`

文件版本、SHA256 和下载 URL 记录在根目录的 `MANIFEST.json` 中。不要手工修改文件名；安装脚本按清单查找。
