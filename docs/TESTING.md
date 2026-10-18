# 测试与验收

本文是发布前的测试矩阵。分三层：单元测试、计划/演练测试、干净机集成测试。

---

## 1. 单元测试

不修改系统、不联网、不安装任何东西：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\tests\run-tests.ps1
```

当前覆盖 30 项：

- 泛型列表转数组、null 处理；
- PATH 合并、去重、大小写/斜杠规范化、变量保留；
- 注册表 PATH 值的精确移除；
- `settings.json` 模板渲染与 JSON 校验、残留占位符拒绝；
- keybindings / snippets JSON 校验；
- 扩展拓扑排序、缺失依赖、循环依赖；
- MANIFEST 结构校验、重复 ID、危险相对路径、无效 SHA256；
- 文件魔数 MZ / ZIP / 7Z；
- VSIX 内 `extension/package.json` 的 ID/版本校验；
- 扩展闭包与 pack 环打破（成员先装、pack 后装）；
- 安装器退出码解释；
- 扩展文件名非法字符清理；
- URL 安全：localhost、127.0.0.1、10.x、192.168.x、172.16.x、169.254.x、IPv6 环回、非 http/https；
- IP 分类：公网、私有、环回、链路本地、组播、文档地址、IPv6 ULA；
- 提权结果等待：匹配 runId 的结果文件被接受，不匹配的 runId 被忽略并超时；
- 安装目录校验：绝对路径、UNC、盘符根目录、固定磁盘；
- VSCode 安装参数：`/DIR`、`/LOG` 和带空格路径的引号；
- 自定义安装目录与 DataRoot 布局解析；
- DataRoot：创建/复用联接、拒绝未加 `-MigrateData` 的旧目录、迁移旧数据、DryRun 不改盘；
- 一键启动脚本：`Install.cmd` 调用 `setup.ps1`，`Install-D.cmd` 调用 `Install.cmd`。

预期结果：`30 通过, 0 失败`，退出码 0。

---

## 2. 资产准备测试（联网机）

```powershell
# 只解析版本和 URL，不下载
.\scripts\fetch-assets.ps1 -PlanOnly

# 正式下载、解析扩展闭包、生成 MANIFEST
.\scripts\fetch-assets.ps1

# 如果本机 hosts/加速器把 GitHub 指向 127.0.0.1，安全检查会拒绝私有地址。
# 使用解析到公网 IP 的 GitHub 加速前缀；脚本仍校验官方 SHA256。
.\scripts\fetch-assets.ps1 -GitHubProxy https://ghfast.top/
```

检查：

```powershell
$m = Get-Content .\MANIFEST.json -Raw | ConvertFrom-Json
$m.schemaVersion          # 1
$m.platform               # win32-x64
$m.components.vscode.version
$m.components.python.version
$m.components.mingw.name
$m.extensions | Select-Object id, version, targetPlatform, installOrder, dependsOn
```

通过标准：

- 三个组件文件存在，SHA256 与 manifest 一致；
- 扩展数量大于 0，ID 唯一，`dependsOn` 中的 ID 都在清单里；
- 扩展安装顺序中，依赖在前；
- 所有文件都是有效的 MZ / ZIP / 7Z（VSIX 是 ZIP）；
- winlibs 上游 `.sha256` 与本地计算值一致；
- VSCode/Python 的 Authenticode 签名检查通过（或至少明确记录警告）。

失败处理：

- SHA256 不匹配：重新运行 `fetch-assets.ps1 -Force`，不要使用损坏资产。
- 扩展闭包解析失败：确认 `code` 在 PATH，或加 `-CodeCli`；也可以加 `-UseInstalledExtensions` 从本机扩展目录解析。
- python.org 下载慢：等待；或换网络后重新运行（已下载的组件会跳过）。

---

## 3. 计划/演练测试（目标机或开发机）

```powershell
# 只读预检和计划
.\scripts\setup.ps1 -DryRun

# 只渲染配置、检查扩展，不写 APPDATA
.\scripts\inject-config.ps1 -DryRun
```

通过标准：

- 平台检查通过（x64、Windows build ≥ 17763、C 盘 ≥ 5GB）；
- 资产清单与 SHA256 校验通过；
- 每个产品返回 `Planned` 或正确的 `Skipped`；
- 如果存在用户级 VSCode 且未加 `-ReplaceUserInstall`，计划会明确报告阻塞，而不是静默双装；
- 配置模板渲染后是有效 JSON，没有残留 `{{...}}`；
- 扩展资产存在且文件有效。

注意：`-DryRun` 仍然会写 `logs\` 下的日志和结果文件；不会安装、不会写注册表、不会写用户配置。

---

## 4. 干净机集成测试矩阵

建议用虚拟机快照 + Windows Sandbox 组合：

- **Windows Sandbox**：快速回归安装脚本、配置渲染、扩展安装（Sandbox 每次重置，不适合测试重启/多用户持久性）。
- **完整 VM**（Hyper-V/VMware/VirtualBox）：测试重启、注销、多用户、断网、卸载。

### 用例 A：干净 Windows 11 x64

前置：没有 VSCode、Python、MinGW；没有旧 `settings.json`。

步骤：

1. 把包放到 `C:\vscode-offline-pack`。
2. 在管理员 PowerShell 运行 `setup.ps1`。
3. UAC 点“是”。
4. 等待完成；记录退出码。
5. 注销并重新登录。
6. 新开 PowerShell，运行 `verify.ps1`。
7. 打开 `examples\hello-cpp`，按 F5；打开 `examples\hello-py`，按 F5。

通过标准：

- `setup.ps1` 退出码 0；
- `verify.ps1` 退出码 0，包含冒烟测试通过；
- `code/python/gcc/g++/gdb --version` 都可用；
- 扩展全部存在；
- 默认界面为简体中文，`code --list-extensions` 包含 `ms-ceintl.vscode-language-pack-zh-hans`；
- 两个示例都能运行/调试。

### 用例 B：已装用户级 VSCode

前置：`%LOCALAPPDATA%\Programs\Microsoft VS Code` 存在，系统版不存在。

步骤：

1. 运行 `setup.ps1`（不带 `-ReplaceUserInstall`）。
2. 确认 VSCode 阶段 `Failed`，其他组件仍安装，退出码非 0。
3. 关闭 VSCode，运行 `setup.ps1 -ReplaceUserInstall`。
4. 确认用户版被卸载、系统版安装成功。

通过标准：

- 第一次不会出现两个 VSCode；
- 第二次卸载用户版后系统版可用；
- 用户配置/扩展目录保留（`%APPDATA%\Code` 和 `%USERPROFILE%\.vscode` 不被删除）。

### 用例 C：已装其他 Python / MinGW

前置：系统 PATH 中已有 Python 3.11 和另一个 gcc（例如 `D:\mingw64`）。

步骤：

1. 运行 `setup.ps1`。
2. 运行 `verify.ps1`。

通过标准：

- 不覆盖已有工具链，只追加；
- `verify.ps1` 对“命令解析到非本包路径”给出 WARN，而不是静默通过；
- VSCode 的 `settings.json` 仍指向包安装的 Python/MinGW。

### 用例 D：已有 settings.json

前置：用户已有自定义 `settings.json`。

步骤：

1. 运行 `inject-config.ps1`。
2. 检查 `%APPDATA%\Code\User.backup.*`。

通过标准：

- 旧配置有完整备份；
- 新配置与 `config\settings.json` 渲染结果一致；
- 备份目录里能找到旧文件。

### 用例 E：非管理员启动

步骤：

1. 普通 PowerShell 运行 `setup.ps1`。
2. UAC 点“否”。

通过标准：

- 脚本明确提示无法提权，退出码 1；
- 不产生半安装状态；
- 再次以管理员运行可以继续（幂等）。

### 用例 F：标准用户 + 管理员凭据提权

前置：标准用户 `student`，UAC 中输入管理员 `admin` 的密码。

步骤：

1. `student` 运行 `setup.ps1`，UAC 输入 `admin` 凭据。
2. 观察日志中的“当前进程与启动用户相同: False”。
3. 确认没有写入 `admin` 的 `%APPDATA%\Code`。
4. 确认注册了 `VSCodeOfflinePack-UserConfig` 计划任务，或生成了手动注入脚本。
5. `student` 注销再登录，等待任务运行。
6. `student` 运行 `verify.ps1`。

通过标准：

- 机器级组件安装成功；
- 配置写到 `student`，不是 `admin`；
- `student` 的扩展全部安装；
- 没有权限错误。

### 用例 G：多用户

步骤：

1. 用户 A 完成安装和注入。
2. 用户 B 登录，运行 `inject-config.ps1`（不要管理员）。
3. 用户 B 打开 VSCode，运行 `verify.ps1`。

通过标准：

- B 的配置/扩展独立写入 B 的 `%APPDATA%` / `%USERPROFILE%`；
- A 的配置不被覆盖；
- 程序、Python、MinGW、系统 PATH 对 B 可用。

### 用例 H：断网安装

步骤：

1. 在联网机完成 `fetch-assets.ps1`。
2. 复制到目标机，禁用网卡。
3. 运行 `setup.ps1` 和 `verify.ps1`。

通过标准：

- 安装和验证全程不访问网络；
- 扩展全部安装；
- 没有 Marketplace 相关阻塞。

### 用例 I：重复运行

步骤：

1. 连续运行 `setup.ps1` 两次。
2. 连续运行 `inject-config.ps1` 两次。

通过标准：

- 第二次运行不会破坏环境；
- PATH 不重复；
- 配置有多次备份，但最终内容一致；
- 扩展已安装时跳过或 `--force` 重装，不失败。

### 用例 J：中文用户名 / 中文路径 / 长路径

步骤：

1. 新建中文用户名账户，或在中文路径下解压包。
2. 运行安装和验证。

通过标准：

- 脚本给出路径警告；
- 安装仍能完成（如果安装器/解压器支持）；
- 如果失败，日志明确指出路径问题，README 建议移动短路径。

### 用例 K：卸载/回滚

步骤：

1. `uninstall.ps1 -Scope User -RemoveExtensions -RestoreSettings`（目标用户，非管理员）。
2. `uninstall.ps1 -Scope Machine -RemoveMinGW -RemoveVSCode`（管理员）。
3. 新开终端检查命令。

通过标准：

- 用户 PATH 中的 pip Scripts 被移除；
- 扩展按清单卸载；
- 配置从备份恢复；
- 系统 PATH 中被本包添加的条目被移除；
- MinGW/VSCode 按显式开关删除；
- PATH 备份文件仍在 `logs\` 中。

### 用例 L：Windows Sandbox 快速回归

适用：只验证安装器参数、配置渲染、扩展安装。

注意：

- Sandbox 内每次重置，不能验证重启/多用户持久性；
- 断网测试需要完整 VM；
- 记录 Sandbox 内的日志并导出。

### 用例 M：安装到 D 盘

前置：干净 Windows x64，D: 为固定本地磁盘，无系统版 VSCode。

步骤：

1. 运行 `setup.ps1 -VSCodeDir D:\VSCode -DataRoot D:\VSCodeData`。
2. 完成后运行 `verify.ps1`。

通过标准：

- 程序位于 `D:\VSCode\Code.exe`，系统 PATH 包含 `D:\VSCode\bin`；
- `%APPDATA%\Code` 是指向 `D:\VSCodeData\user-data` 的联接；
- `%USERPROFILE%\.vscode\extensions` 是指向 `D:\VSCodeData\extensions` 的联接；
- `%LOCALAPPDATA%\Microsoft\vscode-cpptools` 是指向 `D:\VSCodeData\cache\vscode-cpptools` 的联接；
- `verify.ps1` 报告实际安装目录和重定向目标，0 failures；
- 卸载程序仍能通过注册表发现 D: 安装。

反例：已有系统版 VSCode 在 C: 时，加 `-VSCodeDir D:` 应明确失败，不安装第二个系统版。

### 用例 N：已有数据迁移到 D 盘

前置：已有系统版 VSCode，`%APPDATA%\Code` 和 `%USERPROFILE%\.vscode\extensions` 有数据。

步骤：

1. 关闭所有 VSCode 窗口。
2. 运行 `setup.ps1 -DataRoot D:\VSCodeData -MigrateData`（或 `inject-config.ps1` 同参数）。
3. 打开 VSCode，检查设置、扩展和工作区历史。

通过标准：

- 旧目录被联接替换，原路径仍可访问；
- DataRoot 下文件数量和大小与迁移前一致；
- 扩展和设置正常加载；
- 不加 `-MigrateData` 时脚本停止并提示，而不是静默忽略旧数据；
- `-DryRun` 不创建、不移动任何文件。

---

## 5. 验收清单（发布前逐项勾选）

- [ ] `run-tests.ps1` 30/30 通过。
- [ ] `Install.cmd` / `Install-D.cmd` 在包根目录存在，双击能启动安装。
- [ ] `fetch-assets.ps1 -PlanOnly` 成功。
- [ ] `fetch-assets.ps1` 生成 MANIFEST，所有 SHA256 校验通过。
- [ ] `setup.ps1 -DryRun` 在干净机上无阻塞。
- [ ] 干净 Win11 用例 A 通过。
- [ ] 默认中文界面生效，语言包在扩展列表中。
- [ ] `-Locale en` 可把界面切回英文。
- [ ] 用户级 VSCode 用例 B 通过。
- [ ] 已有工具链用例 C 通过（WARN 而非静默覆盖）。
- [ ] 已有配置用例 D 通过。
- [ ] UAC 拒绝用例 E 通过。
- [ ] 标准用户 + 管理员凭据用例 F 通过。
- [ ] 多用户用例 G 通过。
- [ ] 断网用例 H 通过。
- [ ] 重复运行用例 I 通过。
- [ ] 中文路径用例 J 有明确结论。
- [ ] 卸载/回滚用例 K 通过。
- [ ] D 盘安装用例 M 通过。
- [ ] D 盘数据迁移用例 N 通过。
- [ ] `build-pack.ps1` 生成 zip，`.sha256` 与 zip 匹配。
- [ ] zip 解压后目录结构完整，`MANIFEST.json` 在内，`logs`/`dist` 不在。
- [ ] README 的版本号、路径、参数与实际一致。

---

## 6. 日志与证据

每次运行都会在 `logs\` 生成：

- `setup-<timestamp>.log` / `setup-parent-<timestamp>.log`
- `setup-result-<runId>.json`（阶段状态、验证摘要）
- `inject-<user>-<timestamp>.log`（以及可选的 `inject-result-<runId>.json`）
- `verify-<timestamp>.log` / `verify-<timestamp>.json`
- `fetch-<timestamp>.log` / `build-<timestamp>.log`
- `path-<scope>-<timestamp>.txt` / `.reg`（PATH 修改前备份）

交付前如果要保护隐私，删除 `logs\`；它本来也不会进入 `build-pack.ps1` 生成的 zip。

---

## 7. 测试限制

- 无法在无头环境自动验证 VSCode GUI 的“解释器已选中”和“C++ 扩展图形化调试”。`verify.ps1` 用 gdb CLI 冒烟测试覆盖编译/运行/调试链路；GUI 部分由示例工程 F5 手工验收。
- Marketplace 的扩展版本会变化；测试以 `MANIFEST.json` 锁定的版本为准。
- Windows Sandbox 不能验证重启/多用户持久性；必须用完整 VM。
- 不同杀毒软件可能拦截静默安装或解压；测试时记录拦截行为并在 README 中提示。
- python.org 在部分网络下下载很慢；这属于网络问题，不是安装逻辑失败。
