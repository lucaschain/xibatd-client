[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,
    [Parameter(Mandatory = $true)]
    [string]$InstallDir,
    [Parameter(Mandatory = $true)]
    [string]$StageDir,
    [switch]$SkipRestart
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ManagedPath {
    param([string]$Root, [string]$RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "Invalid managed path '$RelativePath'."
    }
    $normalized = $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    if ($normalized.Equals('.update', [StringComparison]::OrdinalIgnoreCase) -or
        $normalized.StartsWith(".update$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase) -or
        $normalized.Equals('data\things', [StringComparison]::OrdinalIgnoreCase) -or
        $normalized.StartsWith('data\things\', [StringComparison]::OrdinalIgnoreCase) -or
        $normalized.Equals('data\sounds', [StringComparison]::OrdinalIgnoreCase) -or
        $normalized.StartsWith('data\sounds\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Protected path '$RelativePath' cannot be managed by the application updater."
    }
    $rootPath = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $fullPath = [IO.Path]::GetFullPath((Join-Path $rootPath $normalized))
    if (-not $fullPath.StartsWith($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Managed path '$RelativePath' escapes its root."
    }
    return $fullPath
}

function Write-UpdateStatus {
    param([string]$Root, [hashtable]$Status)

    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $statusPath = Join-Path $Root 'status.json'
    $temporaryPath = Join-Path $Root 'status.json.new'
    try {
        $json = $Status | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $statusPath -Force
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

$installRoot = [IO.Path]::GetFullPath($InstallDir).TrimEnd([IO.Path]::DirectorySeparatorChar)
$stageRoot = [IO.Path]::GetFullPath($StageDir).TrimEnd([IO.Path]::DirectorySeparatorChar)
$updateRoot = Join-Path $installRoot '.update'
try {
    if (-not $stageRoot.StartsWith(($updateRoot + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The update stage must be inside the installation update directory.'
    }

$manifestPath = Join-Path $stageRoot 'managed-files.json'
$releasePath = Join-Path $stageRoot 'update-release.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
    -not (Test-Path -LiteralPath $releasePath -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $stageRoot 'otclient.exe') -PathType Leaf)) {
    throw 'The staged update is incomplete.'
}

$newFiles = @((Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json).files)
$oldManifestPath = Join-Path $installRoot 'managed-files.json'
$oldFiles = @()
if (Test-Path -LiteralPath $oldManifestPath -PathType Leaf) {
    $oldFiles = @((Get-Content -LiteralPath $oldManifestPath -Raw | ConvertFrom-Json).files)
}
if ($newFiles.Count -eq 0 -or $newFiles.Count -gt 20000) {
    throw 'The staged managed-file inventory is invalid.'
}

$lockPath = Join-Path $updateRoot 'install.lock'
New-Item -ItemType Directory -Force -Path $updateRoot | Out-Null
$lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    Wait-Process -Id $ProcessId -ErrorAction SilentlyContinue

    $backupRoot = Join-Path $updateRoot ("backup-" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    $created = [Collections.Generic.List[string]]::new()
    $backedUp = [Collections.Generic.List[string]]::new()

    try {
        $allFiles = @($oldFiles + $newFiles | Sort-Object -Unique)
        foreach ($relative in $allFiles) {
            $destination = Resolve-ManagedPath $installRoot $relative
            if (Test-Path -LiteralPath $destination -PathType Leaf) {
                $backup = Resolve-ManagedPath $backupRoot $relative
                New-Item -ItemType Directory -Force -Path (Split-Path -Parent $backup) | Out-Null
                Copy-Item -LiteralPath $destination -Destination $backup -Force
                $backedUp.Add($relative)
            } else {
                $created.Add($relative)
            }
        }

        foreach ($relative in $newFiles) {
            $source = Resolve-ManagedPath $stageRoot $relative
            $destination = Resolve-ManagedPath $installRoot $relative
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
                throw "Staged file '$relative' is missing."
            }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            $temporary = $destination + '.update-new'
            Copy-Item -LiteralPath $source -Destination $temporary -Force
            Move-Item -LiteralPath $temporary -Destination $destination -Force
        }

        $newSet = @{}
        foreach ($relative in $newFiles) { $newSet[$relative.ToLowerInvariant()] = $true }
        foreach ($relative in $oldFiles) {
            if (-not $newSet.ContainsKey($relative.ToLowerInvariant())) {
                $obsolete = Resolve-ManagedPath $installRoot $relative
                Remove-Item -LiteralPath $obsolete -Force -ErrorAction SilentlyContinue
            }
        }

        Copy-Item -LiteralPath $manifestPath -Destination $oldManifestPath -Force
        Copy-Item -LiteralPath $releasePath -Destination (Join-Path $installRoot 'update-release.json') -Force
        Write-UpdateStatus $updateRoot @{ status = 'installed' }
    } catch {
        $installError = $_
        foreach ($relative in $created) {
            Remove-Item -LiteralPath (Resolve-ManagedPath $installRoot $relative) -Force -ErrorAction SilentlyContinue
        }
        foreach ($relative in $backedUp) {
            $backup = Resolve-ManagedPath $backupRoot $relative
            $destination = Resolve-ManagedPath $installRoot $relative
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
            Copy-Item -LiteralPath $backup -Destination $destination -Force
        }
        throw $installError
    }
} finally {
    $lock.Dispose()
}

Get-ChildItem -LiteralPath $updateRoot -Directory -Filter 'backup-*' |
    Where-Object { $_.FullName -ne $backupRoot } |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $updateRoot 'package.zip') -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue
if (-not $SkipRestart) {
    Start-Process -FilePath (Join-Path $installRoot 'otclient.exe') -WorkingDirectory $installRoot
}
} catch {
    $installError = $_
    try {
        Write-UpdateStatus $updateRoot @{ status = 'rolled_back'; error = $installError.Exception.Message }
    } catch {
        [Console]::Error.WriteLine("Unable to record update failure: $($_.Exception.Message)")
    }
    if (-not $SkipRestart) {
        Wait-Process -Id $ProcessId -ErrorAction SilentlyContinue
        Start-Process -FilePath (Join-Path $installRoot 'otclient.exe') -WorkingDirectory $installRoot
    }
    throw $installError
}
