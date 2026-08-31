# Browser Build Baseline

This file records measured results from the pinned browser build. Update it when
the Emscripten version, WebAssembly link settings, or asset packaging changes.

## Environment

| Item | Value |
|---|---|
| Date | 2026-08-31 |
| Git revision | `a0e33ef7e` plus the Phase 0 browser changes |
| Emscripten | 6.0.8 |
| Build type | Release |
| Host | WSL 2 with Docker Desktop 4.87.0 |
| Chromium | 151.0.7922.34, Playwright headless |
| Firefox | 153.0, Playwright headless |

## Build Result

The pinned Docker build completed successfully. The build stage took 1888.2
seconds (31 minutes 28 seconds). Most of that time was the clean vcpkg dependency
build.

The build log confirms:

```text
emcc (Emscripten gcc/clang-like replacement + linker emulating GNU ld) 6.0.8
```

Emscripten reports that `USE_PTHREADS` is deprecated in favor of the standard
`-pthread` flag. This does not fail the current build but should be removed from
the link settings during browser build cleanup.

## Artifact Sizes

| Artifact | Bytes | Approximate size |
|---|---:|---:|
| `otclient.html` | 3,740 | 4 KiB |
| `otclient.js` | 591,943 | 578 KiB |
| `otclient.wasm` | 12,078,302 | 11.5 MiB |
| `otclient.data` | 280,805,899 | 267.8 MiB |
| Total | 293,479,884 | 279.9 MiB |

Emscripten emits a warning for the 267 MiB asset bundle and notes that browsers
may have trouble loading it. The preload package is the dominant artifact and
the first packaging optimization target.

## Runtime Result

The local server returned COOP, COEP, and CORP headers. Both tested browsers
reported `crossOriginIsolated === true`.

### Chromium

- The Start button became available 2.6 seconds after navigation over localhost.
- The application reported startup completion about 5.6 seconds after Start was
  selected.
- The login screen rendered at a 1280x720 canvas.
- No Emscripten abort, unhandled rejection, or page error was observed.
- Startup logs contain a non-fatal error because optional `/config.ini` is not
  present.

### Firefox

- The Start button became available 3.7 seconds after navigation over localhost.
- Default Playwright headless settings rejected WebGL 2 on this host.
- Forcing Firefox software WebGL allowed the application to report startup
  completion without a JavaScript exception.
- The headless OffscreenCanvas remained black and retained a 300x150 backing
  size, so rendered login-screen support is not validated for Firefox.
- An interactive, hardware-accelerated Firefox test remains required.

### Memory

The link configuration reserves a fixed 1 GiB WebAssembly heap. Chromium did
not expose `performance.measureUserAgentSpecificMemory()` in this headless test,
so total process memory was not measured separately.

## Known Baseline Constraints

- The build uses a fixed 1 GiB WebAssembly heap.
- `data`, `mods`, and `modules` are included in the preload package.
- The runtime requires WebAssembly pthreads, SharedArrayBuffer, WebGL 2, and
  cross-origin isolation.
- Firefox's headless software-rendering path does not currently produce a
  visible OffscreenCanvas frame.
- Chromium logs a missing optional `/config.ini` as an error during startup.
