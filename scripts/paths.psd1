@{
    SchemaVersion    = 1
    PackName         = 'VSCode-Offline-Setup-Pack'
    PackVersion      = '1.0.2'
    Platform         = 'win32-x64'
    MinimumOSBuild   = 17763
    MinimumFreeSpaceGB = 5

    VSCode = @{
        InstallDir    = 'C:\Program Files\Microsoft VS Code'
        ExeName       = 'Code.exe'
        CliRelative   = 'bin\code.cmd'
        MergeTasks    = '!runcode,addcontextmenufiles,addcontextmenufolders,associatewithfiles,addtopath'
    }

    Python = @{
        Version           = '3.12.10'
        InstallDir        = 'C:\Program Files\Python312'
        ExeName           = 'python.exe'
        UserScriptsPattern = '%APPDATA%\Python\Python{major}{minor}\Scripts'
    }

    MinGW = @{
        InstallDir       = 'C:\mingw64'
        RequiredBinaries = @('gcc.exe', 'g++.exe', 'gdb.exe')
        OptionalBinaries = @('mingw32-make.exe')
        Pinned = @{
            Asset   = 'winlibs-x86_64-posix-seh-gcc-16.2.0-mingw-w64ucrt-14.0.0-r3.7z'
            Version = '16.2.0posix-23.1.3-14.0.0-ucrt-r3'
            Url     = 'https://github.com/brechtsanders/winlibs_mingw/releases/download/16.2.0posix-23.1.3-14.0.0-ucrt-r3/winlibs-x86_64-posix-seh-gcc-16.2.0-mingw-w64ucrt-14.0.0-r3.7z'
            Sha256  = 'db014a73b71907c6c778fd1c938056cddcae9023f89f8dfff7783d9e45baf975'
            Size    = 111718557
        }
    }

    Paths = @{
        MachineEnvironmentKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
        UserEnvironmentKey    = 'HKCU:\Environment'
    }

    ExtensionRoots = @(
        'ms-python.python'
        'ms-vscode.cpptools'
    )

    OptionalExtensionRoots = @{
        'zh-cn' = 'ms-ceintl.vscode-language-pack-zh-hans'
    }

    Locales = @('zh-cn', 'en')
}
