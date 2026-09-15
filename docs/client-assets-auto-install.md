# Client Assets Auto-Install

This document describes the automatic client assets installation flow introduced in OTClient.

## Goal

### Xiba revision channel (1098 compatibility)

Xiba uses `Services.clientAssets.revisionManifestUrl` for game asset updates.
The asset revision is an opaque string (initially `2000`), **not** a client or
protocol version. Client version, protocol version, feature selection, and runtime
paths stay at 1098. Do not use 2000/10982 as `g_game` versions: upstream numeric
version checks select newer wire formats and protobuf assets.

Before account login **and** world login/reconnect, the client fetches the current
manifest with a cache-busting query. The publisher also sets `Cache-Control: no-store`.
Installed files never bypass this check. A failed check blocks login; retry the login
to retry the check. Cached files are checked against the required DAT/SPR sizes and
SHA-256 hashes; mismatches download automatically. A missing/invalid marker or stale
journal is repaired without downloading if the actual pair matches. Cancellation and old asynchronous callbacks
cannot resume a later login/download operation. Matching revisions do not redownload.

The schema-1 manifest contains `compatibilityVersion`, `revision`, `archiveUrl`,
`archiveSha256`, and `files` entries for `Tibia.dat`/`Tibia.spr` with `size`/`sha256`.
Archive URLs must be HTTPS. Both archive and extracted files are verified, independent
of the upstream fallback settings. Archives contain only `assets/Tibia.dat` and
`assets/Tibia.spr`; OTFI is editor metadata and the runtime flags remain in
`modules/game_features/features.lua`.

`modules/client_assets/asset_revision.lua` owns staging, backup, and recovery.
The archive extracts below `data/things/1098/.asset-update/stage/`, is verified,
and the previous pair is backed up before a pending journal is written. Live files
are replaced synchronously, verified, and recorded in `.asset-revision.json`.
No runtime load/login proceeds with a pending transaction. Failed writes restore
verified backups; interrupted recovery is retried on the next check. A complete pair
matching the current manifest can finish an interrupted commit without rollback or
download. Invalid recovery metadata with mismatched files fails closed for inspection.
Successful browser installs delete their journal and temporary copies, rather than
truncating them: IDBFS autoPersist does not reliably track zero-byte truncations.
Verified cache hits also finish removal of orphaned staging/backups left by an
interrupted cleanup save, without redownloading or replacing the active pair.
This is a journaled two-file replacement, not a filesystem-wide atomic rename.

Desktop I/O consistently targets the workdir. Browser I/O targets the writable
`/user/.otclient` tree backed by the IDBFS `autoPersist` mount. Browser installation
waits for explicit IndexedDB acknowledgments at four boundaries: staged pair/backups
and journal; replaced live files; revision marker and journal removal; temporary-file
cleanup. Success is reported only after all four saves complete. Cache checks first
verify storage readiness, and a missing-marker repair saves the verified files before
committing metadata. Hydration cannot auto-persist partial results over the saved profile.

`g_resources.requestWritableStorageSync()` bridges the Lua request to the shell's
serialized `requestPersistentStorageSync`. Its native completion delivers only an ID
and owned error string on the Lua dispatcher through `onWritableStorageSync`.
Canceled, timed-out, or unloaded requests disconnect their handlers; late callbacks
cannot advance a new installation. Quota, initialization, and sync failures block
login with a useful error rather than falsely claiming a saved installation.
The storage acknowledgment timeout defaults to 120 seconds and can be configured
with `Services.clientAssets.storageSyncTimeout` (milliseconds).

Cache diagnostics distinguish pending journals, missing/invalid revision markers,
revision/archive mismatches, missing files, size mismatches, and hash mismatches.

The runtime's resolved DAT/SPR hashes are checked too. A stale user-directory copy
shadowing a desktop installation blocks login with an explanatory error instead of
loading different files. Inspect that user-directory copy before removing it.
After a new installation or revision change, callers reset the client version to 0
then 1098 to force reload even when the compatibility version did not change.
Unchanged verified assets are not reloaded when moving from account login to world
login. The zero-version event does not load files. Browser file-size checks use
seek-to-end on the physical IDBFS file: reading the entire SPR into a Lua string for
metadata exhausted the fixed WASM heap after the initial sprite load.
Browser backup, activation, and recovery copies also stream in bounded chunks.
If different/corrupt assets are detected after sprites have been loaded, the browser
saves settings and reloads using its existing exit/IDBFS-sync path. Installation then
runs on the fresh heap before sprites are loaded. This avoids retaining the old SPR
alongside archive extraction; auto-login can resume normally after the reload.

Publication tooling and promotion commands live in the server repository at
`infra/client-assets/README.md`. The legacy `manifestUrl` remains the source for
clients/configurations without `revisionManifestUrl`.

Hermetic tests:

```sh
luajit tests/client_asset_revision_test.lua .
luajit tests/client_asset_revision_flow_test.lua .
luajit tests/client_asset_flags_test.lua .
luajit tests/client_asset_world_login_test.lua .
node tests/browser_storage_sync_test.cjs
```

`tests/client_asset_smoke.lua` can be run from `otclientrc.lua` in an isolated Windows
installation/profile. It verifies actual DAT/SPR loading and the custom flags without
logging into a server. If `release/2000.json` exists in that installation, it also
exercises native file activation/reload against the prepared asset metadata.

For the browser fixed-heap regression, install Playwright/Chromium into a temporary
tool directory, then run `tests/browser_asset_memory_test.cjs` with that directory's
`node_modules` on `NODE_PATH` (and its `PLAYWRIGHT_BROWSERS_PATH`, if configured).
It loads the published WASM bundle in a fresh context and injects the current source
Lua locally before startup. It exercises a real asset download, checks with the SPR
already cached, and automatic browser reload/reinstallation. It never logs into an
account or modifies production; its synthetic IDBFS contents disappear with the context.
The memory test requires a WASM bundle containing the native storage sync bridge.

`tests/browser_asset_persistence_test.cjs` uses a disposable **persistent** Chromium
profile and checks IndexedDB immediately after success. It requires exactly one ZIP
download for the first install and zero for page refresh, tab reopen, full browser
process restart, stale-journal repair, and missing-marker repair. A corrupted DAT
requires one repair download. It never uses a game account.

```sh
# With Playwright installed and available on NODE_PATH:
node tests/browser_asset_persistence_test.cjs https://play.xibatd.online/

# Before publication: inject current Lua/shell into a published test bundle.
node tests/browser_asset_persistence_test.cjs --source --transport-shim
```

`--transport-shim` is explicit test-only support for an older WASM that lacks the
new native signal. It replaces just the ID/error transport with transient files
outside `/user`; the source shell, actual `FS.syncfs`, IndexedDB, and asset I/O all
execute normally. The native EM_ASM transport is separately executed by the Node
unit test; `tests/client_storage_sync_smoke.lua` verifies the compiled native
resource binding and dispatcher callbacks in an isolated Windows profile.

### Upstream modern asset installation

For modern Tibia client versions (>= 1281), OTClient must be able to:

1. Detect missing assets for the selected version.
2. Prompt the user to download required assets.
3. Download and install assets automatically.
4. Keep final installed files in the same paths already used by OTC runtime.

## Final Install Paths (Source of Truth)

Installed assets must end up in:

- `data/things/<version>/`
- `data/sounds/<version>/`
- runtime extras (when provided by upstream package), such as `bin/*`, in client runtime paths.

Do not introduce an alternative permanent assets root for runtime loading.

## Main Module

- Lua module: `modules/client_assets/client_assets.lua`
- Enter-game integration: `modules/client_entergame/entergame.lua`
- Modern things/sounds loading: `modules/game_things/things.lua`

## Download / Install Strategy

The flow supports:

- archive installation from the release/tag source ZIP as the default path
- manifest-driven installation as a fallback path when the archive cannot be installed
- manifest hash identifier installation into `data/things/<version>/assets.json.sha256`
- packaged files list (including large binaries distributed as `.zip`/`.rar`)
- extraction of `.zip` and `.rar`
- optional `.lzma` decompression

## Integrity and Security Defaults

Defaults are hardened:

- `strictManifestSha256 = true`
- `allowRawFallbackHashMismatch = false`
- `allowMissingPackedRawFallback = true`

`allowMissingPackedRawFallback` is a narrow compatibility fallback for repository releases that reference official `.lzma`/archive package files not stored in the assets repository. It is only used after the packed file is missing and the client falls back to the raw file from the same manifest/release source. It does not enable arbitrary hash mismatches for normal raw downloads.

Release cache is scoped per source (`releasesUrl` / repository key), avoiding stale cross-source reuse.

## Runtime/Platform Notes

- Desktop targets use `libarchive` for archive extraction when it is available.
- Builds without `libarchive` still extract `.zip` archives through the vendored minizip fallback. This keeps the GitHub source ZIP flow functional on clean desktop builds.
- `.rar` extraction requires `libarchive`. If a packaged `.rar` is optional and the build cannot extract it, installation should fail clearly or skip it according to the package configuration.
- The default flow is archive-first because the release source ZIP is the canonical package for this repository. The manifest path remains a compatibility fallback, not the primary installation path.
- Emscripten login fallback was aligned with native `httpLogin` semantics.

## UX Behavior

- Missing-assets dialog prompts before download.
- Download window supports cancellation.
- Progress supports indeterminate mode when remote does not provide reliable content length.
- Console logs show major phases and final install paths.

## Troubleshooting

### 1) Assets appear downloaded but game still cannot load

Check:

- `data/things/<version>/catalog-content.json`
- `data/things/<version>/assets.json.sha256`
- `data/sounds/<version>/catalog-sound.json` (when sounds are enabled)

### 2) Missing `.lzma` package file

If the console shows a 404 for `*.lzma`, the client is using the manifest fallback instead of the release source ZIP. First check why archive installation failed. The manifest fallback can install raw files through `allowMissingPackedRawFallback`, but this path is slower and should not be the normal flow for clean installs.

### 3) SHA-256 mismatch

By default, mismatches fail installation. Verify upstream files and hashes first before changing integrity flags.

### 4) Slow progress / “stuck”

If Content-Length is missing, UI may run in indeterminate mode during download and extraction. Use console logs to confirm active phase.

## Configuration (init.lua)

`Services.clientAssets` supports runtime behavior controls (repository, archive preference, sounds, packaged files, hash strictness, etc.). Keep secure defaults unless there is a specific compatibility reason to relax.

## Maintenance Checklist

When changing this system, validate:

1. Missing assets prompt appears for modern version.
2. Install completes into `data/things/<version>` and `data/sounds/<version>`.
3. Runtime loads modern assets from those paths.
4. Hash verification behavior matches configuration.
5. Windows/Linux CI remains green; Android does not attempt to resolve unsupported libarchive linkage.
