# 第三方组件与许可说明

本安装包本身是部署脚本；`installer/`、`tools/`、`extensions/` 中的二进制资产由 `scripts/fetch-assets.ps1` 从官方来源下载，不属于本项目的代码。

## Visual Studio Code

- 来源：`https://update.code.visualstudio.com/`
- 许可：Microsoft Visual Studio Code 的许可条款。
- 说明：安装包来自 Microsoft 官方更新服务器；`fetch-assets.ps1` 会尝试验证 Authenticode 签名。

## Python

- 来源：`https://www.python.org/ftp/python/`
- 许可：Python Software Foundation License。
- 说明：安装包来自 python.org；`fetch-assets.ps1` 会尝试验证 Authenticode 签名。

## MinGW-w64 / winlibs

- 来源：`https://github.com/brechtsanders/winlibs_mingw/releases`
- 许可：GCC 及其运行库、MinGW-w64、GDB 等各自的开源许可（GPL/LGPL 等，含 GCC 运行库例外）。
- 说明：包含 GCC、G++、GDB、mingw32-make。用 GCC 编译并分发的程序需要遵守相应开源许可；静态链接时尤其要注意 LGPL/GPL 条款。

## 7-Zip 独立解压器（7zr.exe）

- 来源：`https://www.7-zip.org/a/7zr.exe`
- 许可：7-Zip 的 LGPL 许可，含 unRAR 限制说明。
- 说明：仅用于解压 winlibs 的 `.7z` 资产。

## Marketplace 扩展

扩展 `.vsix` 来自 Visual Studio Marketplace，受各自许可约束。默认包含：

- `ms-python.python`（MIT）
- `ms-python.vscode-pylance`（Microsoft 专有许可，仅允许在 Visual Studio Code 中使用）
- `ms-python.debugpy`（MIT）
- `ms-python.vscode-python-envs`（MIT）
- `ms-vscode.cpptools`（Microsoft 许可）
- `ms-ceintl.vscode-language-pack-zh-hans`（MIT，简体中文语言包）

**再分发提示**：个人或组织内部部署通常没有问题；如果要把本安装包对外分发，请先逐项确认扩展许可是否允许再分发。Pylance 和 C/C++ 扩展的许可对此有明确约束。

## 安全与免责

- `fetch-assets.ps1` 只从公开的官方来源下载，校验 SHA256，并尽可能校验 Authenticode 签名。
- 本项目不提供任何明示或暗示的担保；在生产环境部署前，请在测试机上完成本文档描述的验收流程。
- 安装系统级软件、修改系统 PATH、卸载用户级 VSCode 都是有影响的操作；请在执行前确认目标机器和备份。
