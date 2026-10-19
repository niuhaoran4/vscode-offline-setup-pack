# VSCode 离线全自动安装配置包

版本：1.0.1  
平台：Windows 10 1809+ / Windows 11，x64  
形态：VSCode 系统级安装版 + Python 系统级安装 + MinGW-w64 + 离线扩展

[**⬇ 下载完整离线安装包（Windows x64，约 512 MB）**](https://github.com/niuhaoran4/vscode-offline-setup-pack/releases/latest)

这个包把一台干净的 Windows 电脑配置成可以直接写 C/C++ 和 Python 的环境：VSCode、Python、MinGW 都安装到系统级路径并写入系统 PATH；VSCode 配置和扩展按当前 Windows 用户注入；整个过程不依赖 Marketplace 和互联网（资产准备阶段除外）。

> **GitHub 仓库说明**：仓库只保存脚本、配置、文档和示例，不包含 `installer/`、`tools/` 中的安装包、`extensions/*.vsix`、`dist/` 和 `logs/`。  
> - 想直接使用：从上面的 **Releases** 下载完整 ZIP（公开仓库，无需登录）。  
> - 如果下载的是源码 ZIP：双击 `Install.cmd`，它会自动从 Releases 下载完整包（约 512 MB，需要联网），解压后继续安装。  
> - 源码仓库不把 500 MB 二进制塞进 Git 历史，这是 GitHub 的常规做法。

> **第三方组件提示**：Release 内含 Microsoft Marketplace 扩展（包括 Pylance、C/C++），公开再分发前请确认各自许可；详见 `NOTICE.md`。

---

## 第一次使用：只要三步

> **推荐直接下载 Release 完整包。** 如果误下载了源码 ZIP，也可以双击 `Install.cmd`，它会自动下载完整包（约 512 MB，需要联网）。

1. 打开 [Releases](https://github.com/niuhaoran4/vscode-offline-setup-pack/releases)，下载  
   `VSCode-Offline-Setup-Pack-1.0.1-win32-x64.zip`。
2. 把 ZIP **完整解压**到一个短英文路径，例如：

   ```text
   C:\vscode-offline-pack
   ```

   不要在压缩包里直接双击运行。
3. 双击 **`Install.cmd`**，UAC 弹窗点“是”，然后等它自动装完。

如果双击的是源码包里的 `Install.cmd`，它会提示是否下载完整包；按 `Y` 或等 15 秒，它会自动下载、解压并继续安装。

默认装到 C 盘，界面是简体中文，安装过程不需要联网。**第一次使用建议就选 C 盘，最省事；只有 C 盘空间紧张时再考虑 D 盘。**

想全部放到 D 盘，就双击 **`Install-D.cmd`**。D 盘必须是固定本地 NTFS 盘，盘符不能经常变化。

装完后注销重新登录，或至少新开一个 PowerShell。打开解压目录下的：

```text
examples\hello-cpp
```

在 VSCode 里按 **F5**，能编译运行就说明环境正常。

**常见问题**

- 双击后提示“Windows 已保护你的电脑”：点“更多信息”→“仍要运行”。
- 双击没反应：在 PowerShell 里执行 `.\Install.cmd`。
- 看到 `scripts\setup.ps1 not found`：说明你是在 ZIP 压缩包里直接运行。请先完整解压，再运行 `Install.cmd`。
- 下载的是源码 ZIP：直接双击 `Install.cmd`，按提示下载完整包；或从 Releases 手动下载完整 ZIP。
- `Install-D.cmd` 双击没反应：先完整解压；如果仍然没反应，在 PowerShell 里执行 `.\Install-D.cmd` 查看错误。
- 直接双击即可，脚本会自己请求 UAC；不要右键“以管理员身份运行”再用另一个管理员账户提权，否则当前用户的配置会延迟到下次登录。
- `hello-cpp` 链接失败（`undefined reference to std::...`）：旧版示例误用了 `gcc.exe`；1.0.1 已改为 `g++.exe` 并默认 `-static`。请更新到 1.0.1。
- 出现 `IsPathRooted ... 路径中具有非法字符`：旧版在 PowerShell 5.1 下遇到 pyenv 畸形 PATH 项会崩溃；1.0.1 已兼容，请更新。
- 杀毒软件拦截时，先把解压目录加入临时白名单。

---

## 0. 先看这里

- **需要管理员权限一次**：安装系统级组件必须经过 UAC。脚本会自动请求提权，你只需要在 UAC 窗口点“是”。标准用户在 UAC 中输入管理员密码时，脚本会识别出“当前管理员不是启动用户”，不会把配置写错人。
- **VSCode 程序全局，配置和扩展按用户**：这是 VSCode 安装版的固有限制。程序、Python、MinGW、系统 PATH 对所有用户生效；`settings.json`、扩展、代码片段在 `%APPDATA%\Code` 和 `%USERPROFILE%\.vscode` 下，需要每个用户注入一次。脚本会为启动用户自动注入，其他用户可以用 `inject-config.ps1` 或 Active Setup 处理。
- **全局 Python 的 pip 写入受限**：普通用户不能往 `C:\Program Files\Python312\Lib\site-packages` 写包。日常请用项目内 `.venv`，或用 `pip install --user`（脚本已把用户级 Scripts 目录加入用户 PATH）。详见第 6 节。
- **离线指的是安装阶段**：安装包、Python、MinGW、扩展 `.vsix` 都已经在包内；目标机断网也能完成安装。资产准备阶段仍然需要一台联网机器运行 `fetch-assets.ps1`。

---

## 1. 包含的组件

具体版本和 SHA256 记录在 `MANIFEST.json` 中，由 `fetch-assets.ps1` 在准备阶段生成并锁定。

| 组件 | 来源 | 安装位置 | 作用 |
| --- | --- | --- | --- |
| Visual Studio Code（系统版） | Microsoft 官方更新服务器 | `C:\Program Files\Microsoft VS Code` | 编辑器 |
| Python 3.12 | python.org 官方安装包 | `C:\Program Files\Python312` | Python 解释器、pip、py launcher |
| MinGW-w64（winlibs，GCC + gdb + make） | winlibs GitHub Release | `C:\mingw64` | gcc、g++、gdb、mingw32-make |
| VSCode 扩展闭包 | Marketplace 离线 `.vsix` | 当前用户 `%USERPROFILE%\.vscode\extensions` | Python、Pylance、debugpy、C/C++、简体中文语言包 |

默认扩展根：`ms-python.python`、`ms-vscode.cpptools`。准备阶段会用 `code` CLI 在隔离目录中解析真实依赖闭包（包括 Pylance、debugpy、python-envs 等），不靠手写清单。本包已包含 `ms-ceintl.vscode-language-pack-zh-hans`，安装时默认写入 `zh-cn`；需要英文界面时加 `-Locale en`。

---

## 2. 目录结构

```
VSCode-Offline-Setup-Pack/
├── README.md
├── VERSION
├── Install.cmd                # 双击一键安装（默认 C 盘，自动验证）
├── Install-D.cmd              # 双击一键安装到 D 盘（程序 + 数据）
├── MANIFEST.json              # 资产版本、相对路径、SHA256、扩展依赖与安装顺序
├── installer/                 # VSCode / Python 安装包
├── tools/                     # winlibs .7z + 7zr.exe
├── extensions/                # 离线 .vsix（按依赖闭包下载）
├── config/
│   ├── settings.json          # 含 {{PYTHON_EXE}} / {{MINGW_GCC}} 等占位符
│   ├── keybindings.json
│   └── snippets/
├── examples/
│   ├── hello-cpp/             # F5 即用的 C++ 示例（预配置 tasks/launch）
│   └── hello-py/
├── scripts/
│   ├── setup.ps1              # 机器级安装入口，自动提权
│   ├── inject-config.ps1      # 当前用户配置注入入口，不提权
│   ├── verify.ps1             # 验证入口，含编译/运行/gdb 冒烟测试
│   ├── fetch-assets.ps1       # 联网准备资产，生成 MANIFEST.json
│   ├── build-pack.ps1         # 校验并生成交付 zip
│   ├── uninstall.ps1          # 卸载 / 回滚
│   ├── paths.psd1             # 固定路径与产品参数
│   ├── lib/                   # 深模块实现（安装、配置、数据重定向、验证、资产流水线）
│   └── tests/run-tests.ps1    # 单元测试
├── docs/
│   ├── DESIGN.md              # 模块接口、接缝、测试面（codebase-design）
│   └── TESTING.md             # 测试矩阵与验收步骤
├── logs/                      # 运行时日志、PATH 备份、结果 JSON（不进入交付 zip）
└── dist/                      # build-pack.ps1 输出（不进入交付 zip）
```

---

## 3. 快速开始

### 3.1 在一台联网机器上准备资产

要求：Windows x64、能访问 Microsoft / python.org / GitHub / Marketplace、磁盘至少 5GB 空闲。推荐这台机器本身装了 VSCode，这样可以用 `code` CLI 解析扩展依赖闭包。

```powershell
# 先看计划，不下载
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\fetch-assets.ps1 -PlanOnly

# 正式下载并生成 MANIFEST.json
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\fetch-assets.ps1
```

常用选项：

| 选项 | 说明 |
| --- | --- |
| `-VSCodeVersion latest` | VSCode 版本；也可锁定具体版本，如 `1.142.0` |
| `-PythonVersion 3.12.10` | Python 版本，默认取 `paths.psd1` |
| `-MinGWAsset <文件名>` | 指定 winlibs release 中的资产名 |
| `-Extensions ms-python.python,ms-vscode.cpptools` | 覆盖默认扩展根 |
| `-IncludeLanguagePack` | 加入简体中文语言包 |
| `-CodeCli <code.cmd 路径>` | 指定用于解析闭包的 code CLI |
| `-UseInstalledExtensions` | 不调用 code，直接从本机 `%USERPROFILE%\.vscode\extensions` 解析闭包 |
| `-SkipExtensions` | 只准备程序，不准备扩展 |
| `-MinGWLatest` | 忽略 `paths.psd1` 中的锁定版本，查询 GitHub 最新 release（需要能访问 api.github.com） |
| `-GitHubProxy https://ghfast.top/` | 本机 hosts/加速器把 GitHub 指向 127.0.0.1 时，通过公共 GitHub 加速前缀下载 winlibs；仍校验官方 SHA256 |
| `-Force` | 强制重新下载 |

下载完成后检查：

```powershell
Get-Content .\MANIFEST.json -Raw | ConvertFrom-Json | Select-Object packVersion, platform, generatedAt
Get-ChildItem .\installer, .\tools, .\extensions
```

> 从 python.org 下载 Python 安装包在部分网络下会比较慢；这是官方源的带宽问题，不是脚本卡死。`fetch-assets.ps1` 会显示进度。

**GitHub 被本机加速器/hosts 指向 127.0.0.1 时**

有些 GitHub 加速器（例如 Watt Toolkit / Steam++）会把 `github.com`、`api.github.com`、`objects.githubusercontent.com` 写入 hosts 并指向 127.0.0.1。`fetch-assets.ps1` 的安全检查会拒绝环回/私有地址，这是预期行为，不会静默绕过。处理方式：

```powershell
# 用解析到公网 IP 的 GitHub 加速前缀；脚本仍会逐跳校验并在下载后比对官方 SHA256
.\scripts\fetch-assets.ps1 -GitHubProxy https://ghfast.top/
```

- 默认 winlibs 版本锁定在 `scripts\paths.psd1`，不需要访问 GitHub API；只有 `-MinGWLatest` 或指定 `-MinGWAsset` 时才查询 API。
- 代理只影响准备阶段；生成的 `MANIFEST.json` 记录官方 URL 和实际使用的 `mirror`，目标机安装完全离线。
- 如果不想用第三方加速前缀，也可以关闭本机 GitHub 加速器后直接运行，或手动把 winlibs `.7z` 放进 `tools\` 并按 `paths.psd1` 的名称命名。

### 3.2 复制到目标机

1. 把整个目录复制到目标机，建议放在短英文路径，例如 `C:\vscode-offline-pack`。不要放在 OneDrive 同步目录、中文长路径或 U 盘根目录。
2. 如果目录是从网盘/邮件/压缩包传来的，PowerShell 脚本和 `.vsix` 可能带“来自其他计算机”标记。`setup.ps1` 会自动对包内文件执行 `Unblock-File`；也可以手动执行：
   ```powershell
   Get-ChildItem .\scripts -Recurse | Unblock-File
   ```

### 3.3 运行安装

在目标机上，右键开始菜单里的 PowerShell，选择“以管理员身份运行”，然后：

```powershell
cd C:\vscode-offline-pack
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1
```

也可以直接双击 `Install.cmd`：它会自动提权、安装、验证，最后暂停显示结果。  
全部放 D 盘就双击 `Install-D.cmd`（D 盘必须是固定 NTFS 盘；已有 C 盘系统版 VSCode 时先卸载）。

常用选项：

| 选项 | 说明 |
| --- | --- |
| `-ReplaceUserInstall` | 检测到用户级 VSCode 时，先静默卸载用户版，再安装系统版 |
| `-DryRun` | 只做预检、资产校验和计划输出，不安装、不写配置 |
| `-SkipUserConfig` | 只装机器级组件，不注入当前用户配置 |
| `-SkipExtensions` | 不安装扩展（只写配置） |
| `-Force` | 强制重新部署 MinGW、强制重装扩展 |
| `-NoUserTask` | 提权账户与启动用户不同时，不注册登录注入任务 |
| `-UseActiveSetup` | 管理员代装/不同用户场景下注册 Active Setup，让每个新用户首次登录自动注入（当前用户会直接注入） |
| `-VSCodeDir D:\VSCode` | 指定 VSCode 程序安装目录；安装器会收到对应的 `/DIR`，目录必须是固定本地磁盘 |
| `-DataRoot D:\VSCodeData` | 把用户数据、扩展和已知缓存重定向到该目录（通过目录联接，原有路径继续可用） |
| `-MigrateData` | `-DataRoot` 指向新目录时，迁移已有的 `%APPDATA%\Code` 和 `%USERPROFILE%\.vscode\extensions` |
| `-SkipCacheRelocation` | 使用 `-DataRoot` 时不重定向 C/C++ 扩展缓存 |
| `-Locale zh-cn` | 界面语言，默认 `zh-cn`；可改成 `-Locale en`。语言包已包含在包内 |

**同一个用户提权**（最常见）：脚本装完机器级组件后，直接给启动用户写入配置和扩展。  
**标准用户 + 管理员凭据提权**：脚本只做机器级安装，然后为原用户注册一个登录时运行的配置注入任务，并尝试立即启动；如果失败，原用户下次登录会自动运行，或手动运行 `scripts\inject-config.ps1`。

### 3.3.1 安装到 D 盘（可选）

程序、扩展、用户数据和已知缓存可以一起放到 D 盘：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1 `
    -VSCodeDir D:\VSCode `
    -DataRoot D:\VSCodeData `
    -MigrateData
```

- `-VSCodeDir` 传给 VSCode 安装器的 `/DIR`，程序本体安装到 `D:\VSCode`。
- `-DataRoot` 创建三个目录联接（junction），默认路径仍然可用：
  - `%APPDATA%\Code` → `D:\VSCodeData\user-data`
  - `%USERPROFILE%\.vscode\extensions` → `D:\VSCodeData\extensions`
  - `%LOCALAPPDATA%\Microsoft\vscode-cpptools` → `D:\VSCodeData\cache\vscode-cpptools`
- `-MigrateData` 用于已经有 VSCode 用户数据或扩展的机器：先复制并校验文件数量和大小，确认无误后才移除原目录并建立联接。没有该参数时，脚本检测到旧目录会停止，不会静默忽略。
- 迁移前必须关闭所有 VSCode 窗口。D 盘必须是固定本地磁盘，盘符不能经常变化；不支持 UNC 网络路径。
- `-DataRoot` 是**按用户**的数据目录。多用户机器请为每个用户使用不同目录，例如 `D:\VSCodeData\student1`；不要用 Active Setup 指向同一个共享目录。
- 只重定向已知的 C/C++ 扩展缓存；其他第三方扩展自己的缓存可能仍在 `%LOCALAPPDATA%`，需要单独处理。
- 卸载不会删除 `D:\VSCodeData` 本身。`-RemoveExtensions` 和 `-RestoreSettings` 会通过联接操作目标目录，执行前请确认。

### 3.4 验证

**注销并重新登录**（或至少关闭所有终端和 VSCode）后，打开新的 PowerShell：

```powershell
code --version
python --version
gcc --version
g++ --version
gdb --version

powershell -NoProfile -ExecutionPolicy Bypass -File C:\vscode-offline-pack\scripts\verify.ps1
```

`verify.ps1` 会检查：

- 系统版 VSCode、Python、MinGW 是否安装；
- `code` / `python` / `gcc` / `g++` / `gdb` 当前解析到哪个路径；
- 系统 PATH 是否包含三个关键目录（VSCode bin、Python、MinGW bin）；
- 用户 `settings.json` 的 Python 解释器和 C++ 编译器路径是否正确；
- 扩展清单是否全部安装；
- 实际编译、运行、gdb 批处理是否成功（冒烟测试）。

### 3.5 打开示例

在 VSCode 中打开 `examples\hello-cpp`，按 `F5`，应该能编译并进入调试。  
再打开 `examples\hello-py`，按 `F5` 选择 `Python File`，应该能运行。

---

## 4. 全局与按用户的边界

| 内容 | 作用域 | 位置 |
| --- | --- | --- |
| VSCode 程序 | 所有用户 | `C:\Program Files\Microsoft VS Code` |
| Python 程序 | 所有用户 | `C:\Program Files\Python312` |
| MinGW | 所有用户 | `C:\mingw64` |
| 系统 PATH | 所有用户 | `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment` |
| VSCode `settings.json` / `keybindings.json` / snippets | 当前用户 | `%APPDATA%\Code\User` |
| VSCode 扩展 | 当前用户 | `%USERPROFILE%\.vscode\extensions` |
| pip `--user` 的 Scripts | 当前用户 | `%APPDATA%\Python\Python312\Scripts` |

### 多用户

- **启动用户自己提权**：安装完成后配置已经就绪。
- **管理员代装**：脚本检测到提权账户不是启动用户时，不会写用户配置，而是：
  - 默认注册计划任务 `VSCodeOfflinePack-UserConfig`，在启动用户下次登录时运行 `inject-config.ps1`；
  - 或使用 `-UseActiveSetup` 注册 Active Setup（适用于管理员代装/多用户场景），每个新用户首次登录时自动运行；
  - 或让目标用户自己运行：
    ```powershell
    powershell -NoProfile -ExecutionPolicy Bypass -File C:\vscode-offline-pack\scripts\inject-config.ps1
    ```
- **已有其他用户**：让他们在自己的账户下运行一次 `inject-config.ps1`。不要以管理员身份运行该脚本，否则可能写到管理员账户。
- **不要移动安装包**：计划任务和 Active Setup 使用固定的包路径。移动后这些自动注入会失败，需要重新运行 `setup.ps1` 或手动注入。

---

## 5. 配置与扩展

### settings.json

`config\settings.json` 是唯一来源，安装时替换占位符后写入：

```json
{
  "python.defaultInterpreterPath": "{{PYTHON_EXE}}",
  "C_Cpp.default.compilerPath": "{{MINGW_GCC}}",
  "C_Cpp.default.intelliSenseMode": "windows-gcc-x64",
  "terminal.integrated.defaultProfile.windows": "PowerShell",
  "update.mode": "none",
  "extensions.autoCheckUpdates": false,
  "extensions.autoUpdate": false,
  "telemetry.telemetryLevel": "off"
}
```

脚本会：

1. 先备份整个 `%APPDATA%\Code\User` 到 `User.backup.<时间戳>`；
2. 渲染并校验 JSON，确认没有残留 `{{...}}`；
3. 以无 BOM UTF-8 写入；
4. 复制 `keybindings.json` 和 snippets；
5. 默认写入 `%APPDATA%\Code\argv.json` 的 `zh-cn` locale；`-Locale en` 可改英文（带注释的 `argv.json` 不会被破坏，脚本会提示手动切换）。

### 扩展

`fetch-assets.ps1` 用隔离的 `code --extensions-dir` 安装根扩展，读取实际安装出来的 `package.json`，得到完整闭包和依赖关系，写入 `MANIFEST.json` 的 `dependsOn` / `installOrder`。`inject-config.ps1` 按拓扑顺序安装，并在最后用 `code --list-extensions` 复核。

这解决了两类离线部署常见问题：

- 新版 `ms-python.python` 的 pack 依赖是 Pylance、debugpy、python-envs，不再是猜测的 Jupyter 列表；
- `ms-python.python` 和 `ms-python.debugpy` 存在互相引用的 pack 环，安装顺序会打破环并保证成员先装、pack 后装。

离线安装时，如果 VSCode 仍尝试为缺失依赖访问 Marketplace，CLI 可能返回非零退出码；脚本不会仅凭退出码判定失败，而是以最终 `--list-extensions` 结果为准。

---

## 6. Python 与 pip

系统级 Python 的 `site-packages` 位于 `C:\Program Files\Python312`，普通用户没有写权限。推荐做法：

```powershell
cd C:\path\to\your-project
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install requests
```

VSCode 的 Python 扩展会自动识别项目内的 `.venv`，调试和终端都会使用它。  
如果确实要往用户目录装包：

```powershell
python -m pip install --user requests
```

`inject-config.ps1` 已经把 `%APPDATA%\Python\Python312\Scripts` 加入用户 PATH，`--user` 安装的命令行工具可以直接使用。  
不要把 `C:\Program Files\Python312` 的 `site-packages` 权限开放给普通用户，那会破坏系统级安装的安全边界。

---

## 7. 验收标准

1. 在干净的 Windows 10 22H2 / Windows 11 x64 上，以管理员身份运行 `setup.ps1`，除一次 UAC 确认外无需人工干预。
2. 新开终端后：
   - `code --version` 可用；
   - `python --version` 可用；
   - `gcc --version`、`g++ --version`、`gdb --version` 可用。
3. `verify.ps1` 通过，包含实际编译、运行和 gdb 批处理。
4. VSCode 打开后 Python 解释器已指向 `C:\Program Files\Python312\python.exe`，C/C++ 扩展能编译调试。
5. 扩展全部安装，`settings.json` 与模板渲染结果一致。
6. 重复运行脚本不破坏环境，旧配置有备份。
7. 断开网络后，从包内资产完成安装（`fetch-assets.ps1` 除外）。
8. 第二个 Windows 用户运行 `inject-config.ps1` 后配置生效；或使用计划任务/Active Setup 自动注入。

完整的测试矩阵见 [docs/TESTING.md](docs/TESTING.md)。

---

## 8. 故障排查

| 现象 | 处理 |
| --- | --- |
| `code` 不是内部或外部命令 | 注销重登或至少新开终端；检查系统 PATH 是否有 `C:\Program Files\Microsoft VS Code\bin`；也可直接用 `C:\Program Files\Microsoft VS Code\bin\code.cmd` |
| `python` 打开 Microsoft Store | 打开“设置 > 应用 > 高级应用设置 > 应用执行别名”，关闭 `python.exe` / `python3.exe`；然后用 `where python` 确认 |
| `python` 解析到旧版本 | 机器上已有其他 Python 在 PATH 前面；`where python` 查看顺序，必要时调整 PATH 顺序。VSCode 内部仍使用 `settings.json` 中的绝对路径 |
| `gcc` / `gdb` 找不到 | 新开终端；检查 `C:\mingw64\bin` 是否在系统 PATH；运行 `C:\mingw64\bin\gcc.exe --version` |
| gdb 调试时报 DLL 缺失 | 确认 `C:\mingw64\bin` 在 PATH 中；不要只拷贝 gdb.exe 到别处运行 |
| 扩展缺失或标红 | 以目标用户运行 `inject-config.ps1 -ForceExtensions`，或查看 `code --list-extensions --show-versions`。离线环境下依赖警告可以忽略，但最终列表必须包含包内 ID |
| VSCode 提示需要重启 | 关闭所有 VSCode 窗口再打开；扩展安装后不会热加载 |
| 检测到用户级 VSCode 后停止 | 先卸载用户版，或用 `setup.ps1 -ReplaceUserInstall` |
| 脚本被 PowerShell 拦截 | `Get-ChildItem .\scripts -Recurse | Unblock-File`，并用 `-ExecutionPolicy Bypass` 运行 |
| UAC 被拒绝 | 重新运行并在 UAC 中点“是”；标准用户需要输入管理员密码 |
| 包在 OneDrive/中文长路径下报错 | 移动到 `C:\vscode-offline-pack` 后重试 |
| 准备阶段提示“域名解析到环回、私有或保留地址” | 本机 hosts/加速器把 GitHub 指向了 127.0.0.1；用 `-GitHubProxy https://ghfast.top/`，或关闭加速器后重试 |
| MinGW 解压失败 | 确认 `tools\7zr.exe` 存在；重新运行 `fetch-assets.ps1` |
| SHA256 不匹配 | 资产损坏或被替换；重新运行 `fetch-assets.ps1 -Force`，不要跳过校验 |
| 杀毒软件拦截静默安装 | 将安装包目录和 `C:\Program Files\Microsoft VS Code`、`C:\mingw64` 加入临时白名单，安装完成后移除 |
| 系统 PATH 修改后旧终端不生效 | 脚本会广播环境变更，但最可靠的是注销重登；至少关闭所有终端和 VSCode 后重开 |

日志在 `logs\` 下，文件名带时间戳。`setup-result-<runId>.json` 记录每个阶段的状态；`path-*.txt/.reg` 是 PATH 修改前的备份。

---

## 9. 卸载与回滚

```powershell
# 清理当前用户：用户 PATH、可选扩展、可选恢复配置
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1 -Scope User

# 清理机器级：系统 PATH、可选删除 MinGW / VSCode、计划任务、Active Setup
# 需要管理员 PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1 -Scope Machine -RemoveMinGW -RemoveVSCode

# 先看会做什么，不实际执行
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1 -Scope All -DryRun
```

注意：

- 默认不会删除任何东西，必须显式指定 `-Scope`。
- `-Scope User` 请以目标用户身份运行；管理员上下文下脚本会拒绝执行 User/All，避免清理错用户。
- `-RemoveVSCode` / `-RemoveMinGW` 是显式破坏性开关；VSCode 正在运行时不会卸载。
- Python 程序本身不自动卸载。请在“设置 > 应用”中卸载 Python 3.12，或使用官方卸载程序。
- PATH 修改前的值保存在 `logs\path-*.txt` 和 `.reg` 中，可手工恢复。
- `-RestoreSettings` 会从最新的 `User.backup.*` 恢复，并在恢复前再备份当前配置。
- `-RemoveDataLinks` 只移除用户数据/扩展/缓存联接，`DataRoot` 里的数据保留；不指定时联接保持不动。

---

## 10. 版本锁定与更新

- `MANIFEST.json` 锁定每个组件的版本、相对路径和 SHA256；`setup.ps1` / `inject-config.ps1` 在安装前校验包内资产，损坏或不匹配会停止。已存在的系统级 VSCode / Python / MinGW 只会被检测并跳过，不会强制降级或升级到清单版本。
- 更新 VSCode / Python / MinGW / 扩展：在联网机器上重新运行 `fetch-assets.ps1`（必要时加 `-Force`），生成新的 `MANIFEST.json`，再复制到目标机运行 `setup.ps1`。
- 更新 winlibs：默认使用 `paths.psd1` 中锁定的 GCC 16.2.0 资产。要换新版本，使用 `-MinGWLatest` 或 `-MinGWAsset` 生成新 manifest，然后把 `paths.psd1` 的 `Pinned` 更新为新的名称/URL/SHA256，保证下次可复现。
- 新增扩展：用 `-Extensions` 指定新的根扩展，准备阶段会重新解析闭包；或者手动把 `.vsix` 放入 `extensions\` 并更新 `MANIFEST.json`（不推荐手改）。
- 中文界面：包内已包含简体中文语言包，默认写入 `zh-cn`。如果界面没有切换，重启 VSCode，或在命令面板运行“Configure Display Language”；需要英文时用 `-Locale en` 重新注入配置。

---

## 11. 安全、许可与已知限制

**安全**

- `fetch-assets.ps1` 只允许 `http`/`https`，在每次请求和每次重定向前校验主机，拒绝 localhost、环回、私有和保留地址。
- VSCode 和 Python 安装包做 Authenticode 签名校验（不通过只警告，便于离线/根证书异常环境继续）。
- winlibs 使用官方 release 的 `.sha256` 校验，所有资产再写入本地 `MANIFEST.json` 的 SHA256。
- 脚本不收集、不上传任何用户数据；`telemetry.telemetryLevel` 设为 `off`。
- 日志可能包含用户名和路径，交付前可删除 `logs\`。

**许可**

- VSCode 安装包来自 Microsoft 官方更新服务器；Python 来自 python.org；MinGW 来自 winlibs GitHub Release；扩展来自 Marketplace。
- Pylance、C/C++ 等扩展的许可对再分发有约束。个人或组织内部使用通常没有问题；如果要对外分发本包，请先确认各扩展的许可条款。详见 `NOTICE.md`。

**已知限制**

- VSCode 配置/扩展不能全局共享，这是产品限制，不是脚本缺陷。
- 全局 Python 的 pip 写入需要 venv 或 `--user`。
- 修改系统 PATH 后，已经打开的进程不会自动获得新环境；注销重登最可靠。
- 计划任务/Active Setup 依赖固定的包路径；移动包后需要重新运行 `setup.ps1` 或手动注入。
- 使用 `-VSCodeDir` / `-DataRoot` 时，目标盘必须是固定本地磁盘且盘符稳定；盘符变化或磁盘移除会导致 PATH、快捷方式、卸载信息和目录联接失效。
- `-DataRoot` 是用户级目录；多用户机器不要共享同一个 `DataRoot`。
- 离线环境无法自动更新扩展；版本以 `MANIFEST.json` 为准。
- 用 MinGW 编译的 exe 默认依赖 `C:\mingw64\bin` 下的 DLL；分发到其他机器时请加 `-static`。
- Windows 10 已于 2025 年 10 月结束支持；如果目标机仍是 Windows 10，请确保已安装最新补丁。本包支持 Windows 10 1809+，但主要测试目标是 Windows 11。

---

## 12. 开发与测试

```powershell
# 单元测试（不修改系统）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\tests\run-tests.ps1

# 资产计划检查（联网，不下载）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\fetch-assets.ps1 -PlanOnly

# 安装计划检查（只读）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\setup.ps1 -DryRun

# 打包（会校验所有资产 SHA256）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-pack.ps1
```

设计说明见 [docs/DESIGN.md](docs/DESIGN.md)，测试矩阵见 [docs/TESTING.md](docs/TESTING.md)。
