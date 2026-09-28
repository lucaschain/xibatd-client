# Balance-lab replay

Server balance suites can export the first trial with `policy_lab.py run --record`.
They retain the normal unrecorded same-seed replay as a gameplay-parity check.

1. Deploy the Lua/OTUI module with `build-windows.ps1 -UIOnly` while the client is closed.
2. Copy the exported `run.rec` to `records/hive-timeout.rec` under the client's process
   working directory (normally `D:\XibaTD`). Keep its manifest and enemy telemetry
   alongside the original balance result for provenance and diagnosis.
3. Open **Run replay** in the top menu and enter `hive-timeout.rec`. Alternatively:
   `modules.client_replay.play('hive-timeout.rec')` in the Lua terminal.

The client loads its normal Xibat 1098 assets/features. Playback is sequential at normal
speed using the existing native PacketPlayer, with Stop available from the replay window.
It shows only the captured player viewport. The separate `enemies.jsonl` includes sampled
off-screen targets and positions; it does not provide a free-camera scene. Matching
assets are required; the record is not a video or an independent game simulation.

Verification:

```powershell
.\tools\test-replay.ps1 -Recording 'C:\path\run.rec'
```

This copies an already-built installation to a unique directory under `build/`, uses
an isolated profile, disables network updating there, and plays the Hive timeout fixture.
It expects at least 300 seconds of playback and captures parser errors. It is specific
to that baseline timeout, not a general success-run validator. A user-closed replay fails
this smoke gate. The initial interactive smoke entered the game but ended early while
the field-blocking problem was investigated; full-duration playback is not yet verified.

The standalone Lua entry-point tests run with `luajit tests/xibat_replay_test.lua`.
