Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    $Value | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("xibat-updater-test-" + [Guid]::NewGuid())
$install = Join-Path $testRoot 'Xiba TD'
$stage = Join-Path $install '.update\stage-2'
try {
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    Set-Content -LiteralPath (Join-Path $install 'otclient.exe') -Value 'old executable'
    Set-Content -LiteralPath (Join-Path $install 'obsolete.txt') -Value 'old file'
    Write-JsonFile (Join-Path $install 'managed-files.json') @{ schema = 1; files = @('otclient.exe', 'obsolete.txt') }

    Set-Content -LiteralPath (Join-Path $stage 'otclient.exe') -Value 'new executable'
    Set-Content -LiteralPath (Join-Path $stage 'current.txt') -Value 'new file'
    Write-JsonFile (Join-Path $stage 'update-release.json') @{ schema = 1; sequence = 2; version = '0.1.2'; revision = 'new' }
    Write-JsonFile (Join-Path $stage 'managed-files.json') @{ schema = 1; files = @('otclient.exe', 'current.txt', 'managed-files.json', 'update-release.json') }

    & (Join-Path $PSScriptRoot 'install-update.ps1') -ProcessId 2000000000 -InstallDir $install -StageDir $stage -SkipRestart
    if ((Get-Content -LiteralPath (Join-Path $install 'otclient.exe') -Raw).Trim() -ne 'new executable') {
        throw 'The executable was not replaced.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $install 'current.txt')) -or
        (Test-Path -LiteralPath (Join-Path $install 'obsolete.txt'))) {
        throw 'Managed files were not reconciled.'
    }

    $protectedStage = Join-Path $install '.update\stage-3'
    New-Item -ItemType Directory -Force -Path $protectedStage | Out-Null
    Set-Content -LiteralPath (Join-Path $protectedStage 'otclient.exe') -Value 'bad executable'
    Write-JsonFile (Join-Path $protectedStage 'update-release.json') @{ schema = 1; sequence = 3; version = '0.1.3'; revision = 'bad' }
    Write-JsonFile (Join-Path $protectedStage 'managed-files.json') @{ schema = 1; files = @('otclient.exe', 'DATA/THINGS/1098/Tibia.dat') }
    $protectedRejected = $false
    try {
        & (Join-Path $PSScriptRoot 'install-update.ps1') -ProcessId 2000000000 -InstallDir $install -StageDir $protectedStage -SkipRestart
    } catch {
        $protectedRejected = $true
    }
    if (-not $protectedRejected) {
        throw 'A mixed-case protected asset path was accepted.'
    }

    $rollbackStage = Join-Path $install '.update\stage-4'
    New-Item -ItemType Directory -Force -Path $rollbackStage | Out-Null
    Set-Content -LiteralPath (Join-Path $rollbackStage 'otclient.exe') -Value 'broken executable'
    Write-JsonFile (Join-Path $rollbackStage 'update-release.json') @{ schema = 1; sequence = 4; version = '0.1.4'; revision = 'broken' }
    Write-JsonFile (Join-Path $rollbackStage 'managed-files.json') @{ schema = 1; files = @('otclient.exe', 'missing.txt') }
    try {
        & (Join-Path $PSScriptRoot 'install-update.ps1') -ProcessId 2000000000 -InstallDir $install -StageDir $rollbackStage -SkipRestart
        throw 'An incomplete stage was accepted.'
    } catch {
        if ((Get-Content -LiteralPath (Join-Path $install 'otclient.exe') -Raw).Trim() -ne 'new executable') {
            throw 'Rollback did not restore the installed executable.'
        }
    }

    Write-Host 'Windows updater installer tests passed'
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
