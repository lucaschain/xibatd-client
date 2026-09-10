# Building The Xibat Client

`build-windows.ps1` is the only supported way to build this project. Run it from a
native Windows checkout in PowerShell:

```powershell
.\build-windows.ps1
```

Do not use direct CMake commands, the Visual Studio build UI, `vc18\otclient.sln`,
WSL/Linux builds, or Docker builds for a supported Xibat client artifact. Those paths
are retained as upstream or development references and do not perform the complete
Xibat build and deployment contract.

The script:

- Initializes the Visual Studio x64 compiler environment.
- Selects the repository's `windows-release` CMake preset and project-managed vcpkg.
- Performs a fresh configuration and builds the `otclient` target.
- Stages the executable, Lua/OTUI modules, configuration, and Tibia 1098 assets.
- Atomically deploys the runnable client to `D:\XibaTD` by default.

## Prerequisites

Install the Windows compiler and vcpkg prerequisites described in
[windows-(cmake).md](windows-(cmake).md). Keep the source checkout on a native Windows
filesystem, such as `C:\src\xibatd-client`; the script rejects WSL UNC paths.

The default asset directory is `data\things\1098` under the checkout and must contain
`Tibia.dat` and `Tibia.spr`. Stop any running `otclient.exe` before building.

## Options

### UI-only deployment

For Lua, OTUI, and UI image changes, close the client and run:

```powershell
.\build-windows.ps1 -UIOnly
```

This updates `modules`, `mods`, and UI resources under `data` in the existing
installation, without compiling or requiring Visual Studio/vcpkg. It excludes
`data\things` and `data\sounds`, preserves the executable and root configuration,
and does not delete destination files. Use the full build/deployment for C++ changes,
root startup/configuration changes, or when removed files need to be cleared.

`-OutputPath` selects the installation and `-Run` optionally reopens it. Success is
reported as `Client UI deployed to <path> (executable unchanged)`.

### Full build options

```powershell
.\build-windows.ps1 -Jobs 8
.\build-windows.ps1 -OutputPath 'D:\XibaTD-Test'
.\build-windows.ps1 -AssetsPath 'C:\TibiaAssets\1098'
.\build-windows.ps1 -Run
```

`-Run` starts the deployed client after a successful build. A successful command must
end with `Windows client deployed to <path>`.
