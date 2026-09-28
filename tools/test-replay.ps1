param(
    [Parameter(Mandatory=$true)][string]$Recording,
    [string]$Installation = 'D:\XibaTD'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$name = 'xiba-replay-smoke-' + [guid]::NewGuid().ToString('N')
$target = Join-Path $root ('build\' + $name)
New-Item -ItemType Directory -Path $target | Out-Null
# Use an already-built client; build-windows.ps1 remains the only build/deploy gate.
foreach ($file in @('otclient.exe','init.lua','config.ini')) {
    Copy-Item (Join-Path $Installation $file) $target
}
foreach ($folder in @('data','modules','mods')) {
    Copy-Item (Join-Path $Installation $folder) $target -Recurse
}
$init = Get-Content (Join-Path $target 'init.lua') -Raw
$init = $init.Replace('g_app.setCompactName("otclient");', ('g_app.setCompactName("' + $name + '");'))
[IO.File]::WriteAllText((Join-Path $target 'init.lua'), $init)
[IO.File]::WriteAllText((Join-Path $target 'local-config.lua'), "Services.updater = nil`nServices.clientAssets.enabled = false`n")
Copy-Item (Join-Path $root 'tests\xibat_replay_smoke.lua') (Join-Path $target ($name + 'rc.lua'))
New-Item -ItemType Directory -Path (Join-Path $target 'records') | Out-Null
Copy-Item $Recording (Join-Path $target 'records\run.rec')
Write-Output "Replay smoke installation: $target"
$process = Start-Process -FilePath (Join-Path $target 'otclient.exe') -WorkingDirectory $target -PassThru
if (-not $process.WaitForExit(360000)) {
    $process.Kill()
    throw "Owned replay smoke process timed out: $target"
}
$resultPath = Join-Path $target 'replay-smoke-result.json'
if (-not (Test-Path $resultPath)) { throw "Client exited without a smoke result; inspect $target" }
$result = Get-Content $resultPath -Raw
Write-Output $result
if (($result | ConvertFrom-Json).status -ne 'PASS') { throw "Replay smoke failed: $target" }
