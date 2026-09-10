<#
.SYNOPSIS
Builds the Windows client and deploys a runnable tree to D:\XibaTD.

.DESCRIPTION
Run this script from a native Windows checkout. Building from a WSL UNC path is
intentionally rejected because CMake, Ninja, MSVC, and vcpkg need a local Windows
filesystem for reliable incremental builds.

.EXAMPLE
.\build-windows.ps1

.EXAMPLE
.\build-windows.ps1 -AssetsPath '\\wsl.localhost\Ubuntu\home\chain\dev\xibatd-client\data\things\1098' -Run
#>

[CmdletBinding()]
param(
    [string]$OutputPath = 'D:\XibaTD',
    [string]$AssetsPath = '',
    [string]$VcpkgRoot = $env:VCPKG_ROOT,
    [int]$Jobs = 0,
    [switch]$Run
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-VisualStudioEnvironment {
    if (Get-Command cl.exe -ErrorAction SilentlyContinue) {
        return
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
        throw 'Visual Studio Installer (vswhere.exe) was not found. Install Visual Studio with Desktop development with C++.'
    }

    $installationPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $installationPath) {
        throw 'A Visual Studio installation with the x64 C++ toolchain was not found.'
    }

    $devCmd = Join-Path $installationPath 'Common7\Tools\VsDevCmd.bat'
    if (-not (Test-Path -LiteralPath $devCmd -PathType Leaf)) {
        throw "Visual Studio developer environment script was not found: $devCmd"
    }

    $command = "`"$devCmd`" -no_logo -arch=x64 -host_arch=x64 >nul && set"
    $environment = & $env:ComSpec /d /s /c $command
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to initialize the Visual Studio developer environment (exit $LASTEXITCODE)."
    }

    foreach ($line in $environment) {
        if ($line -match '^([^=]+)=(.*)$') {
            Set-Item -Path "Env:$($matches[1])" -Value $matches[2]
        }
    }

    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        throw 'Visual Studio initialized, but cl.exe is still unavailable.'
    }
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE."
    }
}

function Copy-DirectoryTree {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,
        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    & robocopy.exe $Source $Destination /MIR /COPY:DAT /DCOPY:DAT /R:2 /W:1 /XJ /NFL /NDL /NJH /NJS
    if ($LASTEXITCODE -gt 7) {
        throw "Failed to copy '$Source' to '$Destination' (robocopy exit $LASTEXITCODE)."
    }
}

$sourceRoot = (Resolve-Path -LiteralPath $PSScriptRoot).ProviderPath
if ([string]::IsNullOrWhiteSpace($AssetsPath)) {
    $AssetsPath = Join-Path $sourceRoot 'data\things\1098'
}
if ($sourceRoot.StartsWith('\\')) {
    throw 'Build from a native Windows checkout such as C:\src\xibatd-client, not from a \\wsl.localhost or other UNC path.'
}

if (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath = Join-Path $sourceRoot $OutputPath
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

Import-VisualStudioEnvironment

if ([string]::IsNullOrWhiteSpace($VcpkgRoot)) {
    $VcpkgRoot = 'C:\vcpkg'
}
$VcpkgRoot = [System.IO.Path]::GetFullPath($VcpkgRoot)
$vcpkgToolchain = Join-Path $VcpkgRoot 'scripts\buildsystems\vcpkg.cmake'
if (-not (Test-Path -LiteralPath $vcpkgToolchain -PathType Leaf)) {
    throw "vcpkg is not bootstrapped at '$VcpkgRoot'. See docs/building/windows-(cmake).md."
}
$env:VCPKG_ROOT = $VcpkgRoot

foreach ($commandName in 'cmake.exe', 'ninja.exe', 'cl.exe', 'robocopy.exe') {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "Required command is unavailable: $commandName"
    }
}

$requiredAssets = @('Tibia.dat', 'Tibia.spr')
foreach ($asset in $requiredAssets) {
    $assetPath = Join-Path $AssetsPath $asset
    if (-not (Test-Path -LiteralPath $assetPath -PathType Leaf)) {
        throw "Missing Xibat 1098 asset: $assetPath"
    }
}

$runningClient = Get-Process otclient -ErrorAction SilentlyContinue
if ($runningClient) {
    throw 'Stop otclient.exe before building and deploying.'
}

Push-Location $sourceRoot
try {
    Invoke-NativeCommand cmake.exe @(
        '--fresh',
        '--preset', 'windows-release',
        '-DTOGGLE_BIN_FOLDER=ON',
        '-DOPTIONS_ENABLE_IPO=OFF',
        '-DOTCLIENT_BUILD_TESTS=OFF'
    )

    $buildArguments = @('--build', '--preset', 'windows-release', '--target', 'otclient')
    if ($Jobs -gt 0) {
        $buildArguments += @('--parallel', $Jobs.ToString())
    }
    Invoke-NativeCommand cmake.exe $buildArguments
}
finally {
    Pop-Location
}

$builtExecutable = Join-Path $sourceRoot 'build\windows-release\bin\otclient.exe'
if (-not (Test-Path -LiteralPath $builtExecutable -PathType Leaf)) {
    throw "Build completed without producing the expected executable: $builtExecutable"
}

$stagePath = "$OutputPath.__staging"
$backupPath = "$OutputPath.__previous"
Remove-Item -LiteralPath $stagePath -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $backupPath -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $stagePath | Out-Null

foreach ($directory in 'data', 'mods', 'modules') {
    Copy-DirectoryTree (Join-Path $sourceRoot $directory) (Join-Path $stagePath $directory)
}

$stagedAssets = Join-Path $stagePath 'data\things\1098'
New-Item -ItemType Directory -Path $stagedAssets -Force | Out-Null
Get-ChildItem -LiteralPath $AssetsPath -File | Copy-Item -Destination $stagedAssets -Force

Copy-Item -LiteralPath $builtExecutable -Destination (Join-Path $stagePath 'otclient.exe') -Force
foreach ($file in 'init.lua', 'otclientrc.lua', 'config.ini', 'cacert.pem', 'LICENSE') {
    Copy-Item -LiteralPath (Join-Path $sourceRoot $file) -Destination (Join-Path $stagePath $file) -Force
}

$requiredRuntimeFiles = @(
    'otclient.exe',
    'init.lua',
    'otclientrc.lua',
    'config.ini',
    'cacert.pem',
    'data\things\1098\Tibia.dat',
    'data\things\1098\Tibia.spr'
)
foreach ($relativePath in $requiredRuntimeFiles) {
    $runtimePath = Join-Path $stagePath $relativePath
    if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
        throw "Staged runtime file is missing: $runtimePath"
    }
}

try {
    if (Test-Path -LiteralPath $OutputPath) {
        Move-Item -LiteralPath $OutputPath -Destination $backupPath
    }
    Move-Item -LiteralPath $stagePath -Destination $OutputPath
}
catch {
    if ((-not (Test-Path -LiteralPath $OutputPath)) -and (Test-Path -LiteralPath $backupPath)) {
        Move-Item -LiteralPath $backupPath -Destination $OutputPath
    }
    throw
}

Remove-Item -LiteralPath $backupPath -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Windows client deployed to $OutputPath"

if ($Run) {
    Start-Process -FilePath (Join-Path $OutputPath 'otclient.exe') -WorkingDirectory $OutputPath
}
