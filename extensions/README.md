# extensions/

这个目录由 `scripts/fetch-assets.ps1` 填充，包含扩展根及其真实依赖闭包的 `.vsix` 文件。

`MANIFEST.json` 记录每个扩展的：

- `id` / `version`
- `file` / `sha256`
- `targetPlatform`（如 `win32-x64`）
- `dependsOn`（依赖 ID）
- `installOrder`（拓扑排序后的安装顺序）

安装时按 `installOrder` 顺序执行，最后用 `code --list-extensions` 复核。不要手工改文件名或清单，除非你清楚依赖关系。
