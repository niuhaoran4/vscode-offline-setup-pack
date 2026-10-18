# hello-py

用途：验证 Python 解释器和 Python 扩展。

1. 在 VSCode 中打开本目录。
2. 打开 `main.py`。
3. 按 `F5`，选择 `Python File`。
4. 终端应输出 Python 版本、解释器路径和平台信息。

该示例不需要额外安装任何第三方库。

如果项目需要第三方库，建议在项目目录内创建虚拟环境：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install <包名>
```

VSCode 的 Python 扩展会自动识别 `.venv`，不需要手动修改全局 `settings.json`。
