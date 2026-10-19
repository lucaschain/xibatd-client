param([string]$Installation = 'D:\XibaTD')
$ErrorActionPreference = 'Stop'
if (Get-Process otclient -ErrorAction SilentlyContinue) { throw 'Close otclient.exe before the isolated UI smoke test.' }
$root = Split-Path $PSScriptRoot -Parent
$name = 'xiba-mutation-smoke-' + [guid]::NewGuid().ToString('N')
$target = Join-Path $root ('build\' + $name)
New-Item -ItemType Directory -Path $target | Out-Null
foreach ($file in @('otclient.exe','init.lua','config.ini')) { Copy-Item (Join-Path $Installation $file) $target }
foreach ($folder in @('data','modules','mods')) { Copy-Item (Join-Path $Installation $folder) $target -Recurse }
# Reuse the native executable; the supported script deploys the current Lua/OTUI.
& (Join-Path $root 'build-windows.ps1') -UIOnly -OutputPath $target
$init = Get-Content (Join-Path $target 'init.lua') -Raw
$init = $init.Replace('g_app.setCompactName("otclient");', ('g_app.setCompactName("' + $name + '");'))
[IO.File]::WriteAllText((Join-Path $target 'init.lua'), $init)
[IO.File]::WriteAllText((Join-Path $target 'local-config.lua'), "Services.updater = nil`nServices.clientAssets.enabled = false`n")
Copy-Item (Join-Path $root 'tests\xibat_raid_mutation_smoke.lua') (Join-Path $target ($name + 'rc.lua'))
Write-Output "Mutation smoke installation: $target"
$process = Start-Process -FilePath (Join-Path $target 'otclient.exe') -WorkingDirectory $target -PassThru
if (-not $process.WaitForExit(30000)) { $process.Kill(); throw "Owned mutation smoke process timed out: $target" }
$resultPath = Join-Path $target 'mutation-smoke-result.json'
if (-not (Test-Path $resultPath)) { throw "Client exited without a smoke result; inspect $target" }
$result = Get-Content $resultPath -Raw
Write-Output $result
$parsed = $result | ConvertFrom-Json
$logPath = Join-Path $target ($name + '.log')
if ((Test-Path $logPath) -and (Select-String -Path $logPath -Pattern '\[error\]|\[fatal\]' -Quiet)) {
    throw "Native client logged an error; inspect $logPath"
}
if ($parsed.writeDir) {
    $screenshot = Join-Path $parsed.writeDir 'raid-mutations.png'
    if (Test-Path $screenshot) { Copy-Item $screenshot $target }
}
if ($parsed.status -ne 'PASS') { throw "Mutation UI smoke failed: $target" }
