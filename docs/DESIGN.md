# 设计说明：深模块与接缝

本文用 `codebase-design` 的词汇描述这个安装包的内部结构：**Module（模块）**、**Interface（接口）**、**Implementation（实现）**、**Seam（接缝）**、**Adapter（适配器）**、**Depth（深度）**、**Leverage（杠杆）**、**Locality（局部性）**。

目标不是把脚本拆得越多越好，而是让每个模块的接口尽量小、实现尽量深，并把不可避免的外部依赖集中在少数接缝上。

---

## 1. 问题空间与约束

约束来自需求本身：

- 只支持 Windows x64，只做 VSCode 安装版（系统级）。
- 机器级组件（VSCode、Python、MinGW、系统 PATH）需要管理员权限。
- 用户级配置和扩展必须写到“启动安装的用户”，而不是“提权后的管理员”。
- 目标机离线；所有资产来自包内，安装前要能校验完整性。
- 重复运行必须幂等；旧配置要先备份。
- 安装完成后要能用真实编译、运行、gdb 调试来证明环境可用，而不只是 `--version`。

这些约束决定了三个关键接缝：

1. **权限接缝**：机器级安装与用户级注入分开。
2. **资产接缝**：联网准备资产与离线安装分开，`MANIFEST.json` 是两者之间的契约。
3. **产品接缝**：每个产品（VSCode/Python/MinGW）的“检测、安装、验证”收在一个模块里，入口脚本只编排。

---

## 2. 模块地图

```
scripts/
├── setup.ps1                  Adapter：机器级编排 + 提权 + 用户注入决策
├── inject-config.ps1          Adapter：当前用户配置注入
├── verify.ps1                 Adapter：验证报告
├── fetch-assets.ps1           Adapter：联网资产准备
├── build-pack.ps1             Adapter：交付打包
├── uninstall.ps1              Adapter：卸载/回滚
└── lib/
    ├── Common.ps1             Module：日志、身份、提权、PATH 注册表、进程
    ├── Pack.ps1               Module：PackContext、清单校验、扩展拓扑排序
    ├── VSCode.ps1             Module：VSCode 产品
    ├── Python.ps1             Module：Python 产品
    ├── MinGW.ps1              Module：MinGW 产品
    ├── UserConfig.ps1         Module：用户配置、扩展安装、用户 PATH
    ├── DataRoot.ps1           Module：用户数据/扩展/已知缓存的重定向与迁移
    ├── Verification.ps1       Module：验证与冒烟测试
    ├── AssetPipeline.ps1      Module：安全下载、扩展闭包、MANIFEST、zip
    └── Load.ps1               Module：单一加载入口
```

入口脚本是**浅适配器**：解析参数、创建上下文和日志、调用深模块。真正的行为在 `lib/` 里，`Locality` 集中在那里：改安装参数只改 `paths.psd1`，改 PATH 逻辑只改 `Common.ps1`，改扩展安装只改 `UserConfig.ps1`。

---

## 3. 接口契约

### 3.1 PackContext（Pack.ps1）

**接口**

```powershell
New-PackContext -PackRoot <path> -> PackContext
Get-PackAsset -Context <ctx> -Component vscode|python|mingw -> Asset
Get-PackExtensionAssets -Context <ctx> -> Asset[]
Assert-PackAssets -Context <ctx> [-SkipExtensions] [-SkipHashes] -> { Ok, Problems, Assets }
```

**契约**

- `PackContext` 是只读数据：根目录、各子目录、`paths.psd1` 内容、`MANIFEST.json` 对象。
- 没有 `MANIFEST.json` 时，`New-PackContext` 仍成功，但 `Get-PackAsset` 和 `Assert-PackAssets` 会给出明确的“先运行 fetch-assets.ps1”错误。
- 资产路径必须是相对路径，不能逃逸出包目录；`Test-SafeRelativePath` 拒绝绝对路径、`..` 和控制字符。
- `Assert-PackAssets` 在安装前执行 SHA256 校验；`-SkipHashes` 只用于明确的快速路径，不作为默认。
- `Sort-ExtensionAssets` 接收带 `id` / `dependsOn` 的对象，返回依赖在前的顺序；缺失依赖或真环会抛出，不静默跳过。

**隐藏的实现**

- JSON 解析、`PSCustomObject`/哈希表兼容、泛型列表转数组、相对路径安全检查、SHA256 计算、重复 ID 检查。
- 调用方不需要知道 `ConvertTo-PlainArray` 或 PowerShell 5.1 的 `@($list)` 兼容问题。

**测试面**

单元测试直接调用 `Test-ManifestObject`、`Test-SafeRelativePath`、`Sort-ExtensionAssets`、`Wait-ElevatedResult` 等纯逻辑；真实资产的存在性与 SHA256 校验由 `setup.ps1` / `verify.ps1` 在集成阶段执行。

### 3.2 PackLogger（Common.ps1）

**接口**

```powershell
[PackLogger]::new($logFile, $title)
.Info/.Warn/.Error/.Step/.Ok/.Detail($message)
.Stage($name, $status, $message)
.Banner($message)
.Summary()
```

**契约**

- 每次写入同时落到 UTF-8（无 BOM）日志和控制台。
- `Warn` / `Error` 计数供 `Summary` 使用；`Stage` 把状态映射到级别和颜色。
- 日志文件路径由 `New-PackLogger -LogDir -Prefix` 生成，文件名带时间戳。
- 不做日志脱敏；README 明确提示交付前可删除 `logs\`。

**隐藏的实现**

- 时间戳格式、控制台颜色、文件追加、阶段列表、编码。

### 3.3 环境与 PATH（Common.ps1）

**接口**

```powershell
Test-IsAdministrator
Get-CurrentUserSid / Get-CurrentUserName
Invoke-ElevatedChild -ScriptPath -ArgumentList -WorkingDirectory -ResultFile -RunId
Add-PathEntry -Scope Machine|User -Entry -LogDir [-DryRun]
Remove-PathEntry -Scope Machine|User -Entry -LogDir [-DryRun]
Get-EffectivePath [-Expand]
Send-EnvironmentChanged
Test-PlatformPrerequisites
Invoke-CapturedProcess / Invoke-InstallerProcess
```

**契约**

- `Add-PathEntry` 只追加、不重排；比较时忽略大小写、正反斜杠、尾部斜杠和引号。
- 写入 `HKLM\...\Environment` 或 `HKCU\Environment` 时保持 `REG_EXPAND_SZ`，不把 `%SystemRoot%` 展开成字面路径。
- 写入前把原值保存为 `logs\path-<scope>-<timestamp>.txt`，并尝试 `reg export` 一份 `.reg`。
- `Add-PathEntry` 本身不广播；入口在所有 PATH 修改完成后调用一次 `Send-EnvironmentChanged`。
- `Invoke-ElevatedChild` 通过结果文件而不是 `Process.ExitCode` 作为主契约，因为提权进程的进程句柄可能因完整性级别不可访问。
- `Invoke-CapturedProcess` 把 stdout/stderr 分离并合并返回，所有外部进程调用都通过它，便于统一超时和日志。

**隐藏的实现**

- 注册表视图、PATH 规范化、`reg.exe` 备份、`SendMessageTimeout(HWND_BROADCAST, WM_SETTINGCHANGE, "Environment")`、进程异步读取和超时杀死。

### 3.4 产品模块（VSCode.ps1 / Python.ps1 / MinGW.ps1）

**接口**

```powershell
Install-VSCodeProduct    -Context -Logger [-ReplaceUserInstall] [-DryRun] -> ProductResult
Install-PythonProduct    -Context -Logger [-DryRun] -> ProductResult
Install-MinGWProduct     -Context -Logger [-DryRun] [-Force] -> ProductResult
Get-VSCodeStatus / Get-PythonStatus / Get-MinGWStatus -> Status
```

**ProductResult 契约**

```
Name, Status (Installed|Skipped|Planned|Failed), Version, Path, Message, Blocker
```

**契约**

- 检测已安装时返回 `Skipped`，不重复安装；所有产品都幂等。
- `DryRun` 只读注册表/文件系统并返回 `Planned`，不启动安装器、不写 PATH。
- VSCode 检测到用户级安装时，默认返回 `Failed + Blocker`，绝不静默双装；只有显式 `-ReplaceUserInstall` 才卸载用户版。
- Python 检测系统版时优先默认路径，其次注册表；安装后必须在预期位置找到 `python.exe`，否则失败。
- MinGW 先找 `tools\mingw64` 预解压目录，否则解压 `.7z`/`.zip`；部署后必须存在 `gcc.exe`、`g++.exe`、`gdb.exe`；`mingw32-make.exe` 是可选警告。
- 每个产品只负责自己的 PATH 追加；不负责用户配置和扩展。

**隐藏的实现**

- Inno Setup / Python installer 的静默参数和退出码、用户级 VSCode 的卸载器查找、winlibs 目录结构探测、robocopy 多线程复制、7-Zip 独立解压器查找、gcc/gdb 版本解析。

**为什么深**

删除任一产品模块，入口脚本就要重复“检测路径 + 静默参数 + 退出码 + 验证 + PATH”这一整串逻辑，而且 `verify.ps1` 还要再实现一份检测。模块把这份复杂度收在一处，`Leverage` 来自 `setup.ps1` 和 `verify.ps1` 两个调用方，`Locality` 来自“换安装参数只改一个文件”。

### 3.5 用户配置（UserConfig.ps1）

**接口**

```powershell
Invoke-UserConfiguration -Context -Logger -PythonExe -MinGWGcc -MinGWGdb -CodeCli
    [-DryRun] [-ForceExtensions] [-NoBackup] [-SkipSettings] [-SkipExtensions]
    [-SkipUserPath] [-Locale] -> UserConfigResult

Install-Extensions -Context -Logger -CodeCli [-Force] [-DryRun] -> ExtensionResult
Write-UserSettings -Context -Logger -PythonExe -MinGWGcc -MinGWGdb [-Locale] [-DryRun] -> SettingsResult
```

**契约**

- 必须在目标用户上下文运行；入口脚本在管理员上下文会拒绝（除非显式 `-AllowElevated`）。
- 写配置前先备份整个 `%APPDATA%\Code\User`；备份失败则中止，不覆盖。
- 模板渲染后必须通过“无残留占位符 + JSON 可解析”两道检查，否则不写。
- 文件以无 BOM UTF-8 写入。
- 扩展按 `Sort-ExtensionAssets` 的顺序安装；单个 CLI 返回非零不直接判死，最终以 `--list-extensions` 为准。
- 用户 PATH 只追加 pip `--user` 的 Scripts，不碰系统 PATH。
- `argv.json` 只有在能安全解析时才改写；带注释的文件会提示手动切换语言。

**隐藏的实现**

- 模板替换、备份命名、snippets 复制、扩展 ID/版本解析、Code CLI 输出捕获、pack 环处理、用户级 PATH。

### 3.5.1 用户数据重定向（DataRoot.ps1）

**接口**

```powershell
Get-VSCodeDataLayout -DataRoot [-UserProfile] [-AppData] [-LocalAppData] -> Layout
Enable-VSCodeDataRoot -Logger -DataRoot [-MigrateExisting] [-SkipCache]
    [-DryRun] -> DataRootResult
```

**契约**

- 通过 NTFS 目录联接把默认路径透明地指向 DataRoot，快捷方式、`code.cmd`、`setup.ps1`、`inject-config.ps1` 都不需要额外参数。
- 默认重定向三项：`%APPDATA%\Code`、`%USERPROFILE%\.vscode\extensions`、`%LOCALAPPDATA%\Microsoft\vscode-cpptools`。
- 已存在普通目录时，必须显式 `-MigrateExisting`；否则停止，不静默忽略旧数据。
- 迁移顺序是“复制 → 校验文件数量和总大小 → 删除原目录 → 建立联接”。任何一步失败都保留目标副本，并给出可重试的提示。
- 已存在指向其他位置的联接时停止，不自动改指向。
- `-DryRun` 只输出计划，不创建、不移动任何文件。
- `DataRoot` 必须是本地固定磁盘的绝对路径，且不能位于被重定向的目录内部。

**隐藏的实现**

- 联接目标解析、迁移中断后的续跑、robocopy 退出码处理、源/目标文件计数、缓存策略。

### 3.6 验证（Verification.ps1）

**接口**

```powershell
Invoke-PackVerification -Context -Logger [-Scope All|Machine|User]
    [-VSCodeDir] [-SkipExtensions] [-SkipSmokeTest] -> VerificationResult
```

**契约**

- 只读检查，不安装、不写配置。
- `Scope Machine`：平台、VSCode/Python/MinGW、机器 PATH、真实编译/运行/gdb。
- `Scope User`：settings、keybindings/snippets、扩展、用户 PATH、VSCode 运行状态。
- 冒烟测试必须在临时目录内完成，结束后清理；它验证的是“能编译、能运行、能调试”，不是“文件存在”。
- 任何关键检查失败都返回 `Ok = false`；警告不判失败。
- 结果同时写 `logs\verify-<timestamp>.json`。

**隐藏的实现**

- 命令解析（临时合并 PATH）、路径等价比较、扩展版本对比、gdb 批处理、临时目录清理。

### 3.7 资产流水线（AssetPipeline.ps1）

**接口**

```powershell
Invoke-AssetFetch -Context -Logger [-VSCodeVersion] [-PythonVersion] [-MinGWAsset]
    [-Extensions] [-CodeCli] [-IncludeLanguagePack] [-SkipExtensions]
    [-UseInstalledExtensions] [-PlanOnly] [-Force] -> FetchResult

Build-PackArchive -Context -Logger [-OutputDir] [-Force] -> { ZipPath, Sha256, SizeMB }
```

**契约**

- `fetch-assets.ps1` 是唯一的联网组件；`setup.ps1` / `inject-config.ps1` 不联网。
- 所有 HTTP 请求在请求前和每次重定向前校验：只允许 `http`/`https`，拒绝 localhost、环回、私有、链路本地、CGNAT、文档/保留地址。
- winlibs 默认使用 `paths.psd1` 中锁定的资产名、官方 URL 和 SHA256，不依赖 GitHub API；本机 hosts/加速器把 GitHub 指向 127.0.0.1 时，可用 `-GitHubProxy` 指定解析到公网 IP 的加速前缀，但下载后仍必须匹配官方 SHA256。
- 下载先写 `.part`，校验大小和文件魔数（MZ / ZIP / 7Z），再原子移动。
- 扩展闭包来自 `code --extensions-dir <isolated> --user-data-dir <isolated>` 的实际安装结果；如果 code 不可用，回退到本机已安装扩展目录。
- 写入 `MANIFEST.json` 前计算所有 SHA256，并重新读取、用 `Test-ManifestObject` 校验。
- `Build-PackArchive` 在打包前再次执行 `Assert-PackAssets`；zip 内不包含 `logs`、`dist`、`_resolve` 等运行时目录。

**隐藏的实现**

- DNS/IP 分类、重定向循环、gzip 解压、进度、签名检查、winlibs 资产选择、扩展 package.json 解析、pack 环打破、拓扑排序、Zip64 打包。

---

## 4. 接缝与适配器

### 4.1 外部接缝

| 外部依赖 | 接缝位置 | 适配器 |
| --- | --- | --- |
| 文件系统 | `Common.ps1` 的读写函数、产品模块 | 本地文件系统 |
| Windows 注册表 | `Common.ps1` 的 PATH 函数 | `Microsoft.Win32.Registry` |
| 进程/安装器 | `Invoke-CapturedProcess` / `Invoke-InstallerProcess` | 真实进程 |
| 网络 | `AssetPipeline.ps1` 的 `Invoke-SafeDownload` / `Invoke-SafeJsonRequest` | `HttpWebRequest` |
| 用户身份 | `Test-IsAdministrator` / `Get-CurrentUserSid` | WindowsIdentity |
| 计划任务/Active Setup | `setup.ps1` 的两个注册函数 | Windows 内置机制 |

这些是**真正的**外部接缝，不是为测试硬造出来的端口。按照“一个适配器只是假设的接缝，两个适配器才是真接缝”的原则，我们没有为每个外部调用再包一层接口；测试通过 `-DryRun`、纯函数和干净 VM 来覆盖。

### 4.2 内部接缝

只有纯计算/字符串处理有内部接缝，并且只在单元测试里直接调用：

- `Merge-PathList` / `Remove-PathEntryFromList` / `ConvertTo-PathEntryNormalized`
- `Resolve-ConfigTemplate` / `Test-RenderedConfig`
- `Test-ManifestObject` / `Test-SafeRelativePath`
- `Sort-ExtensionAssets`
- `Test-PublicIpAddress` / `Assert-SafeDownloadUrl`
- `Test-FileMagic` / `Test-VsixPackageInfo`

它们不暴露在入口脚本的接口里；调用方不需要知道这些细节。

### 4.3 权限接缝

`setup.ps1` 的机器级阶段和 `inject-config.ps1` 的用户级阶段是这次设计的核心接缝：

```
启动用户
  └─ setup.ps1（可能是普通权限）
       ├─ 记录 OriginalUserSid / OriginalUserName
       ├─ UAC 提权
       └─ 提权进程
            ├─ 比较 CurrentSid == OriginalUserSid
            ├─ 相同：机器安装 + 直接 Invoke-UserConfiguration
            └─ 不同：机器安装 + 计划任务/Active Setup/手动注入
```

这条接缝避免了一个非常隐蔽的错误：标准用户在 UAC 中输入管理员凭据后，`$env:APPDATA` 指向管理员账户，配置会写错人。比较 SID 是这里的唯一权威判断。

---

## 5. 关键不变量与顺序

1. **先校验资产，再安装**：`Assert-PackAssets` 在 `setup.ps1` 的产品安装之前执行；hash 不匹配直接停止。
2. **先备份，再覆盖**：`Invoke-UserConfiguration` 在任何配置写入之前备份整个 `User` 目录。
3. **PATH 只追加、不重排**：避免覆盖机器上已有的 Python/GCC；冲突由验证报告提示。
4. **PATH 写入保持 `REG_EXPAND_SZ`**：否则 `%SystemRoot%` 会被展开，破坏 PATH 的可移植性。
5. **所有 PATH 修改后广播一次**：让 Explorer 刷新环境块，新的 VSCode 进程才能继承新 PATH。
6. **VSCode 不双装**：系统版存在就跳过；用户版存在时默认阻塞，显式 `-ReplaceUserInstall` 才卸载。
7. **扩展先装依赖，再装 pack**：`Sort-ExtensionAssets` 保证成员在前；`ms-python.python` 与 `debugpy` 的 pack 环通过“成员到 pack 的边”来打破。
8. **扩展安装以最终列表为准**：CLI 的非零退出码可能只是离线依赖解析失败；最终 `--list-extensions` 才是结果。
9. **用户配置只在目标用户上下文写**：提权账户不同就延迟注入，不猜。
10. **验证包含真实编译/运行/gdb**：文件存在不等于工具链可用。

---

## 6. 测试面

**接口就是测试面**。测试分三层：

1. **单元测试**（`scripts/tests/run-tests.ps1`）：直接调用纯函数，覆盖 PATH 合并、模板渲染、清单校验、扩展拓扑、URL/IP 安全、文件魔数、VSIX 校验、pack 环。
2. **计划/演练测试**：`fetch-assets.ps1 -PlanOnly`、`setup.ps1 -DryRun`、`inject-config.ps1 -DryRun`。它们在真实文件系统和真实清单上走一遍接口，但不修改系统。
3. **干净机集成测试**：在 Windows Sandbox 和完整 VM 上跑实际安装、断网、重启、多用户、重复运行。冒烟测试会真实编译、运行和 gdb 调试。

测试矩阵见 [TESTING.md](TESTING.md)。单元测试不碰注册表、不联网、不安装任何东西。

---

## 7. 删除测试

- 删除 `Common.ps1`：PATH、提权、进程、日志的复杂度会重新散落到每个入口和产品模块。
- 删除 `Pack.ps1`：清单校验和扩展拓扑会在 `setup.ps1`、`inject-config.ps1`、`verify.ps1`、`fetch-assets.ps1` 各出现一份。
- 删除任一产品模块：入口和验证都要重复“检测 + 安装 + 校验 + PATH”的整串逻辑。
- 删除 `UserConfig.ps1`：`setup.ps1` 和 `inject-config.ps1` 会各自实现一份配置渲染和扩展安装，两份逻辑必然漂移。
- 删除 `AssetPipeline.ps1`：安全下载、重定向校验、扩展闭包、MANIFEST 生成会混进入口，安全约束难以集中审查。

每个模块都通过了删除测试：删掉它，复杂度会重新分散到多个调用方。

---

## 8. 设计决策记录

| 决策 | 理由 | 代价 |
| --- | --- | --- |
| 系统级安装，不做便携版 | 满足“任何用户/新终端可用” | 需要管理员；VSCode 配置仍按用户 |
| `setup.ps1` 与 `inject-config.ps1` 分离 | 权限接缝清晰，避免写错用户 | 多一个入口和一次可能的登录任务 |
| MinGW 用 winlibs 完整包，装到 `C:\mingw64` | 一个包包含 gcc/g++/gdb/make；路径无空格 | 需要 7zr 解压；约 110MB 压缩包 |
| 扩展在准备阶段解析真实闭包 | 依赖树会变（Jupyter 不再是硬依赖，debugpy 拆出） | 准备机器需要 code CLI 或本机扩展 |
| `MANIFEST.json` + SHA256 | 离线可复现、可校验、可审计 | 更新资产需要重新生成清单 |
| 扩展安装以最终列表为准 | 离线时 CLI 可能因依赖解析返回非零 | 需要额外一次 `--list-extensions` |
| 默认不自动 kill VSCode | 避免丢失未保存文件 | 扩展生效需要用户重启窗口 |
| Active Setup 作为可选项 | 新用户零操作，但路径写死 | 移动包后失效 |
| 不自动卸载 Python | 避免误删用户环境或留下半卸载状态 | 卸载需要用户走系统设置 |

---

## 9. 文件与职责

| 文件 | 职责 | 不做什么 |
| --- | --- | --- |
| `paths.psd1` | 固定路径、产品参数、扩展根 | 不记录版本/哈希（在 MANIFEST） |
| `config/settings.json` | 最终用户配置模板 | 不包含用户个性化内容 |
| `config/snippets/*.json` | 代码片段 | 不包含项目级配置 |
| `examples/hello-cpp` | 验收样例，预配置 tasks/launch | 不依赖全局 launch 配置 |
| `scripts/lib/Common.ps1` | 宿主服务 | 不安装产品 |
| `scripts/lib/Pack.ps1` | 清单和扩展排序 | 不下载、不安装 |
| `scripts/lib/AssetPipeline.ps1` | 联网准备与打包 | 不修改目标机环境 |
| `scripts/setup.ps1` | 机器级编排 | 不实现安装细节 |
| `scripts/inject-config.ps1` | 用户级编排 | 不写系统 PATH |
| `scripts/verify.ps1` | 验证 | 不修复、不安装 |
