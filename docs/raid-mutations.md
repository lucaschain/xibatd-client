# Client-local raid configuration (wire v2)

**Raid list → Configure / Deploy → local settings → Deploy.** Configure only opens
the window. Raid switching, checkbox selection, combined factors, capped bonuses and
loot previews are entirely local. There is no browsing timeout, preview token,
Refresh button, or confirmation popup. The existing lobby/globe gameplay follows admission.

The server supplies a shared `mutationCatalog` and per-raid `raidConfiguration` offers
when opening the menu. The menu advertises `mutationVersion: 2`; each raid references
its expected `configurationRevision`. Offers contain immutable content identities and
current party-lobby information, not permissions or reservations. A locked party offer
carries its pinned summary even if the global catalog has since changed.

Deploy sends exactly one request containing raid/modifier IDs, revision/catalog hashes
and the expected lobby channel/generation. The server validates current entry rules
and computes authoritative effects/rewards. If state changed, it sends current data
with a rejection; the client keeps valid choices and waits for another explicit Deploy.
It never sends calculated reward amounts and never retries admission automatically.

## Sources

- `modules/game_xibat_raid/raid_mutation_contract.lua`: bounded v2 metadata validation,
  local presentation calculations, compatibility/conflict/limit checks.
- `raid_mutations.lua` / `raid_mutations.otui`: compact native checkboxes, cached local
  selections, direct deployment, failure recovery and read-only run inspection.
- `raid_mutation_status.otui`: event-driven current-run badge.
- `raid_selector.lua`: initial data integration and normal-raid fallback for older servers.
- Server `docs/refactor/49-raid-mutations.md`: authoritative lifecycle/reward/wire contract.
  Source encoding/limits are in `forgottenserver/src/raid_mutation_protocol.{h,cpp}`.

The local summary is a display estimate from server-authored definitions. Floating-point
presentation is not authoritative integer stat rounding; native exact arithmetic and
all current-state checks run at Deploy. The server computes the final configuration hash.
Run/generation identities stay decimal strings to preserve 64-bit precision in Lua.

Catalog content and startup loading are server-owned. The starter catalog and calibration
limits are documented in server `docs/refactor/50-mutation-catalog-rollout.md`.
The obsolete v1 catalog/preview/accept RPC workflow is removed. Matching v2 server/client
updates are required for local modifiers; an older server still supports normal admission
through the configuration window's Deploy button.

## Verification

The optional v2 `elite` operands (`shareBps`, `healthBps`) appear on catalog definitions
and selected entries in pinned summaries. Preview rows distinguish elite-only health
from effects on all enemies. Selection still sends only IDs, not elite operands.
The server uses the existing outfit shader string for `Outfit - Raid Elite`, registered
by `game_shaders`, and prefixes the displayed creature name with `Elite`. This shader
is not offered as a player cosmetic. The native smoke renders a synthetic elite outfit;
WebGL compilation/linking is checked separately from full browser gameplay.

The native parser preserves OTCv8 outfit shader names when the separate creature-shader
extension is absent, including initial creature data and later outfit updates. Full
Windows/browser rebuilds are needed; UI-only deployment cannot install that fix.
The current Xibat replacement-client handshake uses Redemption's separate
`GameCreatureShader` extension, negotiated by the server, rather than the OTCv8
outfit extension. The server sends the shader on creature descriptions and subsequent
outfit changes. An offline outfit smoke alone does not verify this negotiation;
server integration tests cover the replacement-client feature and creature packets.

Validation note (November 2026): the first actual elite-render smoke timed out while
Windows logged Display event 4101 (Intel `igfxn` stopped responding and recovered).
A later isolated run passed and produced the expected golden outline. The November 11
retest also passed, with zero new System Display recovery events (4101) during the
test and a visually confirmed golden outline. Its artifacts are under
`build/xiba-mutation-smoke-2bd1ee51a11442518d25742a07b86aeb`.
The user reported another fullscreen game running during the original incident;
the cause of that reset remains unproven. WebGL compilation/linking also passed.
These short checks do not establish long-session stability or full browser gameplay.
The build remains isolated under `build/elite-validation`; production rollout is pending.

Local gameplay follow-up (November 11): the user confirmed the shader after the
Redemption negotiation fix, then reported a client exit when killing an elite.
The Windows dump `otclient.exe.9876.dmp` resolves the original exception to
`ThingType::getExactHeight` from `Creature::internalDraw`, indexing texture positions
before an asynchronous texture load completed. `getExactHeight` now returns an
uncached zero while that texture/its positions are unavailable, retrying on later draws.
The dump also shows a secondary failure in `Stacktrace`: it called `GlobalFree` on
a stack-allocated symbol buffer. That invalid free is removed and the symbol header
size/alignment corrected. The offline smoke enables async loading and creates/removes
additional cold elite outfits; it does not reproduce an actual networked enemy death.
The original debugger report and matching executable/PDB are retained locally under
`build/crash-analysis`.
The updated Windows build passed the async cold-outfit creation/removal smoke
(`build/xiba-mutation-smoke-5c31b85f0f83408cbf6032cbb59f5ce1`) with zero new
Display 4101 events and was installed locally in `D:\XibaTD` for gameplay retesting.
The user subsequently confirmed that killing an elite worked without the reported crash.

```sh
luajit tests/xibat_protocol_lifecycle_test.lua .
```

This proves zero outbound requests while configuring/switching raids, immediate local
composition/caps/conflicts, one IDs-only Deploy without a popup, single-flight handling,
rejection recovery without losing valid selections, locked parties, precision-safe
identities, reconnect status and cleanup. Shared synthetic v2 operands are in
`tests/raid_mutation_fixture.lua`.

For native Windows rendering, close the client and run:

```powershell
.\tools\test-raid-mutations.ps1
```

The runner copies an existing installation (default `D:\XibaTD`) into a unique ignored
`build/` directory and calls the supported `build-windows.ps1 -UIOnly` gate there. A
unique offline profile receives synthetic initial data, then native checkbox changes
calculate/render the preview with no server. It checks viewport/column layout, native
checkbox behavior, the absence of Refresh, read-only status and terminal clearing.
Results/screenshots remain in the printed directory. Missing results, native errors
or timeout fail the test; only its own test process may be stopped.
