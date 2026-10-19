# hello-cpp

用途：验证 VSCode C/C++ 扩展、MinGW gcc/g++ 和 gdb 是否全部就绪。

1. 在 VSCode 中打开本目录（`文件 > 打开文件夹`）。
2. 打开 `main.cpp`。
3. 按 `F5`，选择 `C/C++: g++.exe 生成并调试`。
4. 终端应输出：

```
MinGW toolchain is ready:
  - gcc
  - g++
  - gdb
```

`tasks.json` 和 `launch.json` 使用绝对路径：

- 编译器：`C:/mingw64/bin/g++.exe`（C++ 必须用 g++ 链接 libstdc++；纯 C 文件可改用 gcc.exe）
- 调试器：`C:/mingw64/bin/gdb.exe`

如果要生成可以拷到其他电脑运行的 exe，`tasks.json` 已经默认加了 `-static`，生成的 exe 不依赖 MinGW 的 DLL。  
如果去掉 `-static`，exe 会依赖 `C:\mingw64\bin` 下的运行库 DLL；运行时该目录必须排在 PATH 前面。
