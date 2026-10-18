# hello-cpp

用途：验证 VSCode C/C++ 扩展、MinGW gcc/g++ 和 gdb 是否全部就绪。

1. 在 VSCode 中打开本目录（`文件 > 打开文件夹`）。
2. 打开 `main.cpp`。
3. 按 `F5`，选择 `C/C++: gcc.exe 生成并调试`。
4. 终端应输出：

```
MinGW toolchain is ready:
  - gcc
  - g++
  - gdb
```

`tasks.json` 和 `launch.json` 使用绝对路径：

- 编译器：`C:/mingw64/bin/gcc.exe`
- 调试器：`C:/mingw64/bin/gdb.exe`

如果要生成可以拷到其他电脑运行的 exe，请在 `tasks.json` 的 `args` 中加上 `-static`，例如：

```json
"args": ["-fdiagnostics-color=always", "-g", "-static", "${file}", "-o", "${fileDirname}/${fileBasenameNoExtension}.exe"]
```

不加 `-static` 时，exe 依赖 `C:\mingw64\bin` 下的运行库 DLL；本机运行没有问题，拷到没有 MinGW 的机器会缺 DLL。
