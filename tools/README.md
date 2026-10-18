# tools/

这个目录由 `scripts/fetch-assets.ps1` 填充：

- `winlibs-x86_64-posix-seh-gcc-<version>-mingw-w64ucrt-<runtime>-r<rev>.7z`
- `7zr.exe`（解压 `.7z` 用）

也可以放一个已解压的 `mingw64\` 目录（含 `bin\gcc.exe`），安装脚本会优先使用它。文件版本和 SHA256 记录在 `MANIFEST.json` 中。
