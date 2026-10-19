# Raid mutation selection

The replacement client supports the versioned mutation extension advertised by the
raid selector. The authoritative game/ownership/reward contract is maintained in the
server repository at `docs/refactor/49-raid-mutations.md`; server wire limits and
encoding live in `forgottenserver/src/raid_mutation_protocol.{h,cpp}`.

## Client ownership

- `modules/game_xibat_raid/raid_mutation_contract.lua`: bounded response validation,
  precision-safe decimal identity strings, and presentation of authoritative summaries.
- `raid_mutations.lua` and `raid_mutations.otui`: selection, conflicts, preview,
  expiry, explicit confirmation, party configuration locking, and read-only inspection.
- `raid_mutation_status.otui`: the event-driven current-run badge.
- `raid_selector.lua`: capability detection, original-server fallback, and lifecycle
  integration with the existing raid list and reset timer.

Selection requests echo the selector session and a monotonically changing request ID.
Only the current matching response can update the view. The client sends mutation
IDs for preview and the resulting server token for acceptance; it never sends reward
amounts or effect strengths. Party-lobby selections are locked, and changing a selection
destroys any confirmation of its previous token.

The summary shows combined factors, gold/Ascension XP bonuses including cap flags,
and conditional completion-loot quantities/probabilities. Random loot is identified
as conditional on successful completion/final-wave eligibility. Active status uses
the exact server run/generation identity, and stale clears cannot hide a newer run.
Server-provided status survives a deferred game-start callback during reconnect.

Without a mutation capability advertisement the client retains its original normal
raid request. With an installed but empty/unconfigured catalog, the new flow still
supports a normal raid. Production catalog content and bootstrap loading are separate
server work; the UI does not synthesize mutations or balance values.

## Verification

From the client checkout:

```sh
luajit tests/xibat_protocol_lifecycle_test.lua .
```

This tests legacy fallback, malformed/superseded responses, conflict presentation,
expiry, old confirmation callbacks, single-flight acceptance, locked party joins,
64-bit string identities, reconnect snapshots, and module/event teardown.

For native Windows UI verification, close the client and run:

```powershell
.\tools\test-raid-mutations.ps1
```

The runner copies an existing native installation (default `D:\XibaTD`) into a uniquely
named ignored `build/` directory and calls `build-windows.ps1 -UIOnly -OutputPath ...`
to install current Lua/OTUI. It uses a unique profile with updater/assets fetching
disabled, launches only its owned client process, and feeds offline synthetic packets.
No game login or player database is involved. It verifies native widget parenting,
viewport/column layout, preview rows, read-only active status, and terminal clearing.
Results and a screenshot are retained in the printed directory. Native error logs,
missing results, or timeout fail the test. See `docs/building/xibat-windows.md` for
the supported Windows build/deployment gate.
