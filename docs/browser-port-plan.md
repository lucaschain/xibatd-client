# Browser Port Plan

## Status

Planning baseline for turning the existing Emscripten target into a supported
desktop-browser client.

Agreed decisions:

- Existing desktop clients continue to use plain TCP.
- Browser clients use secure WebSockets (`wss`) on port 443.
- Browser endpoints use URL paths, initially `/login` and
  `/world/<world-id>`.
- TCP and WebSocket connections carry the same application protocol bytes.
- The browser remains a C++/Lua WebAssembly client. This is not an HTML/JS UI
  rewrite.
- Initial browser support targets current desktop browsers. Mobile browser
  support is out of scope for the first release.

Current implementation status:

- Phase 0 is complete and recorded in `docs/building/browser-baseline.md`.
- Phase 1 client endpoint configuration is implemented.
- Phase 2 client-side `WebConnection` hardening is implemented and passes the
  pinned browser build, Chromium startup smoke test, and clean-close login
  response regression test.
- The additive server WebSocket transport is implemented. Local Chromium login
  and gameplay are validated over `ws://127.0.0.1:7173`; production TLS/WSS
  deployment and Firefox validation remain pending.

## Goals

- Run the complete client in a supported desktop browser.
- Preserve the existing game protocol, encryption, checksums, compression, and
  packet formats.
- Support desktop TCP and browser WebSocket clients at the same time.
- Provide reproducible browser builds and automated runtime smoke tests.
- Deploy through HTTPS/WSS with the headers required by WebAssembly pthreads.
- Make browser settings and downloaded client assets persistent.
- Reach acceptable initial download size, startup time, and memory use for
  desktop browsers.

## Non-Goals

- Replacing the Lua/OTUI interface with HTML and CSS.
- Removing or changing the native TCP transport.
- Designing a new game protocol specifically for browsers.
- Supporting mobile Safari or low-memory mobile devices in the first release.
- Moving runtime assets away from their standard OTC virtual paths.

## Existing Browser Foundation

The repository already contains most of the compile-time platform port:

- Emscripten target selection in `CMakeLists.txt`.
- Browser-specific linking and packaging in `src/CMakeLists.txt`.
- Reproducible build entry point in `Dockerfile.browser` and
  `Dockerfile.browser.sh`.
- Browser build CI in `.github/workflows/reusable-build-browser.yml`.
- WebGL 2 window, rendering, input, and clipboard support in
  `src/framework/platform/browserwindow.cpp`.
- Browser game transport in `src/framework/net/webconnection.cpp`.
- Fetch and WebSocket HTTP support in
  `src/framework/net/protocolhttp.cpp`.
- IDBFS setup in `browser/shell.html`.
- A local server with the required isolation headers in
  `tools/emscripten-web-serve.py`.

The work is therefore a browser productization and hardening project, not a
port from zero.

## Transport Architecture

### Protocol Contract

The application protocol remains a byte-stream protocol for both transports.
The native framing already includes the packet length and must remain intact.

Client to server:

1. The protocol constructs the normal native packet.
2. A TCP client writes those bytes to its socket.
3. A browser client sends those same bytes in a binary WebSocket message.
4. The server feeds the resulting bytes into the same packet accumulator and
   decoder used by TCP sessions.

Server to client follows the same rule in reverse.

WebSocket message boundaries must not become protocol boundaries. Both client
and server must correctly handle:

- One native packet split across multiple incoming chunks.
- Multiple native packets in one incoming chunk.
- A two-byte native packet header split from its body.
- A complete native packet in one WebSocket message, which is the preferred
  send behavior for observability and debugging.

Do not add another length prefix or JSON envelope around WebSocket messages.
The current browser client requests the `binary` WebSocket subprotocol; the
server or gateway must accept it unless the client requirement is deliberately
removed on both sides.

### Server Structure

Use one shared protocol session with transport adapters:

```text
                     +----------------------+
TCP listener ------> | TCP transport        |
                     +----------------------+ \
                                               > Shared login/game session
                     +----------------------+ /
WS listener -------> | WebSocket transport  |
                     +----------------------+
```

The transport interface should expose only the operations the protocol needs:

- Deliver received byte chunks.
- Send a byte span.
- Close the connection.
- Report connection state and remote address.
- Apply transport-level backpressure and limits.

The existing TCP listeners and behavior remain unchanged. WebSocket support is
additive.

### Public Endpoints

Initial production topology:

```text
tcp://game.example.com:7171       Native login
tcp://game.example.com:7172       Native world
wss://play.example.com/login      Browser login
wss://play.example.com/world/<id> Browser world
```

A TLS reverse proxy listens on 443, performs the HTTP Upgrade, and routes each
path to the correct WebSocket-capable backend. The proxy configuration must:

- Preserve binary WebSocket frames.
- Use sufficiently long read and idle timeouts for gameplay sessions.
- Disable response buffering for upgraded connections.
- Forward the remote address through a trusted mechanism.
- Validate or allowlist the browser application's `Origin`.
- Apply connection, frame-size, and rate limits.
- Forward ping, pong, close, and failure states correctly.
- Use a publicly trusted TLS certificate.

Per-message compression should initially be disabled. The application already
uses protocol compression/encryption where appropriate, and compression adds
latency, memory use, and implementation complexity.

## Browser Endpoint Configuration

The browser connection URL must be explicit configuration, not inferred from a
release build or a native port number.

The current implementation must be replaced because it:

- Selects `ws` or `wss` using `NDEBUG`.
- Constructs only `scheme://host:port` and cannot represent a path.
- Rewrites game port 7172 to 443 in `ProtocolGame::login`.

Add browser-only endpoint configuration to each server definition. The exact
Lua/C++ shape should remain small, but it must represent at least:

```lua
webSocket = {
    loginUrl = 'wss://play.example.com/login',
    worldUrlTemplate = 'wss://play.example.com/world/{worldId}'
}
```

Requirements:

- Native builds continue to consume the existing host and port fields.
- Browser builds use the configured full WebSocket URL.
- World selection supplies a stable world identifier to the URL template.
- Login responses do not need to replace native host/port values for desktop
  clients.
- Missing or invalid browser endpoint configuration produces a clear login
  error rather than silently rewriting a port.
- Local development can explicitly use `ws://localhost:<port>/...`.

## Work Phases

### Phase 0: Reproduce and Measure the Current Build

Deliverables:

- Pin a tested Emscripten SDK version in `Dockerfile.browser` instead of using
  `latest`.
- Build the existing browser artifact from a clean environment.
- Serve it with `tools/emscripten-web-serve.py`.
- Record generated artifact sizes, initial download size, startup duration,
  WASM heap use, and browser console errors.
- Confirm the application reaches the login screen in Chromium and Firefox.
- Document the exact build and local-run commands.

Exit criteria:

- A clean checkout produces the same browser bundle in CI and locally.
- The bundle starts without an Emscripten abort or an uncaught JavaScript
  exception.
- Baseline metrics are recorded for comparison with later phases.

### Phase 1: Dual-Transport Connectivity

Server work:

- Add the WebSocket transport adapter without changing the TCP adapter.
- Accept binary messages and append their payloads to the shared protocol input
  buffer.
- Send protocol output as binary WebSocket messages.
- Implement `/login` and `/world/<world-id>` routing.
- Accept the `binary` subprotocol used by the current browser client.
- Add frame-size, buffered-byte, connection, and handshake limits.
- Reject text messages and malformed upgrade requests.

Client work:

- Add explicit full-URL browser endpoint configuration.
- Remove the 7172-to-443 rewrite.
- Stop deriving transport security from `NDEBUG`.
- Preserve the existing native `Connection` path for non-Emscripten builds.

Exit criteria:

- An existing desktop build logs in and plays over TCP with no packet changes.
- A browser build logs in and plays over WSS using the same account and world.
- Packet captures show equivalent application bytes after removing TCP or
  WebSocket framing.

### Phase 2: WebConnection Correctness

Refactor `src/framework/net/webconnection.*` while preserving the `Protocol`
byte-stream API.

Client implementation status: complete. WebSocket events are copied and
serialized through the dispatcher, stale socket events are ignored, pending
reads complete asynchronously without polling, receive bytes are bounded to
256 KiB across queued and buffered data, and cleanup closes only the current
socket while delivering at most one error callback. The forced game logout
workaround was removed. The Emscripten 6.0.8 Docker build and Chromium startup
smoke test passed on 2026-08-31. Live login and world lifecycle validation over
the local server WebSocket transport passed on 2026-09-01.

Required fixes:

- Initialize and deinitialize the Emscripten WebSocket library at application
  scope, not when an individual socket closes.
- Close and delete each WebSocket handle explicitly.
- Make open, message, error, and close callbacks safe if the owning C++ object
  is destroyed.
- Correctly reset state for both login and world connections.
- Replace the current sleep-and-retry read loop with an event-driven pending
  read that completes when enough buffered bytes arrive.
- Enforce a bounded receive buffer.
- Report meaningful connection, timeout, protocol, and clean-close errors.
- Handle sends that fail or encounter backpressure.
- Ensure only one close/error notification reaches the protocol session.
- Remove the forced game logout workaround once close propagation is reliable.

Exit criteria:

- Repeated login, cancel, reconnect, character change, logout, and network-loss
  cycles do not leak handles or leave stale callbacks.
- Login and game WebSockets can coexist with HTTP subsystem WebSockets.
- Closing one socket does not affect another socket.

### Phase 3: Browser Runtime Hardening

Required work:

- Copy wheel and touch event data before dispatching asynchronous callbacks.
- Accept valid pointer coordinates at zero.
- Add device-pixel-ratio-aware canvas sizing and coordinate translation.
- Implement browser fullscreen or hide the unsupported setting.
- Handle tab visibility changes and audio context suspend/resume.
- Detect and report WebGL context loss.
- Implement browser-safe URL opening where native code currently uses a stub.
- Verify clipboard behavior in a secure context.
- Review keyboard event suppression so required browser and accessibility
  shortcuts are not unnecessarily blocked.

Exit criteria:

- Input, resizing, focus changes, and rendering work on current Chromium,
  Firefox, and Edge desktop releases.
- A suspended and resumed tab either continues safely or reconnects with a clear
  error.
- No callback accesses Emscripten event memory after the callback returns.

### Phase 4: Persistence and Asset Delivery

The initial build preloads `data`, `mods`, and `modules`, while the WASM heap is
fixed at 1 GiB. This can be used for early connectivity work but is not the
desired production delivery model.

Required work:

- Measure which assets are needed before the login screen and before entering a
  world.
- Split boot-critical files from large versioned sprite, thing, and sound data.
- Download versioned assets on demand with visible progress and actionable
  storage errors.
- Persist downloaded assets in IDBFS or an OPFS-backed filesystem.
- Mount persistent backing storage so runtime virtual paths remain
  `data/things/<version>/`, `data/sounds/<version>/`, and other expected OTC
  locations.
- Flush completed install transactions before reporting success.
- Handle quota exhaustion, interrupted installs, stale versions, and browser
  storage eviction.
- Add cache versioning so a deployment does not combine incompatible JS, WASM,
  modules, and data packages.
- Revisit the fixed 1 GiB heap after asset loading no longer requires the full
  preload.

Mandatory invariants:

- Do not make `client-assets/` or another new root the permanent runtime source
  of truth.
- Keep `strictManifestSha256 = true`.
- Keep `allowRawFallbackHashMismatch = false`.
- Preserve desktop archive extraction.
- Do not introduce unsupported `libarchive` linkage on Android.

Exit criteria:

- Installed assets survive a page reload and browser restart.
- Runtime loading continues through standard OTC virtual paths.
- A failed or interrupted install cannot be mistaken for a complete version.
- Initial transfer size and time-to-login meet the release budget established
  after Phase 0.

### Phase 5: Automation and Production Release

CI work:

- Keep the existing browser compile job.
- Add a browser runtime smoke job using a real headless browser.
- Start a local server with COOP, COEP, and CORP headers.
- Assert that the Start action initializes WASM and renders the login screen.
- Fail on Emscripten aborts, uncaught exceptions, and severe WebGL errors.
- Add an integration environment with TCP and WSS listeners using the shared
  protocol implementation.

Operational work:

- Deploy static assets over HTTPS with immutable versioned filenames.
- Preserve required cross-origin isolation headers at the CDN and reverse
  proxy.
- Ensure all fetched cross-origin resources satisfy COEP/CORS requirements.
- Add WebSocket connection counts, handshake failures, close codes, buffered
  bytes, message rates, and session duration metrics.
- Define rollback behavior for incompatible browser bundles.

Exit criteria:

- Every release verifies native TCP and browser WSS login/gameplay.
- Production hosting reports `crossOriginIsolated === true`.
- Browser and server errors provide enough context to diagnose transport,
  asset, and runtime failures.

## Verification Matrix

### Transport Compatibility

| Client | Login transport | World transport | Required result |
|---|---|---|---|
| Existing desktop build | TCP | TCP | No behavioral regression |
| New desktop build | TCP | TCP | No behavioral regression |
| Browser development build | WS | WS | Login and gameplay work locally |
| Browser release build | WSS | WSS | Login and gameplay work through 443 |

### Packet Stream Cases

- Header and body delivered together.
- Header split across received chunks.
- Body split across several received chunks.
- Several complete packets delivered together.
- Maximum valid packet size.
- Zero, oversized, truncated, and malformed packet lengths.
- Encrypted, checksum, sequenced, compressed, and raw packet modes.
- Server close during login, game login, and active gameplay.
- Client cancel and logout while writes are pending.

### Browser Runtime Cases

- First load with an empty browser cache.
- Reload with a warm preload cache.
- Settings survive reload.
- Assets survive reload after a completed install.
- Interrupted asset download resumes or restarts safely.
- Temporary network loss and server restart.
- Browser tab background and foreground transitions.
- Canvas resize, display scaling, and fullscreen.
- Keyboard, mouse, wheel, text input, clipboard, and focus loss.

## Security Requirements

- Production browser connections use WSS only.
- Validate WebSocket `Origin` against the deployed client origins.
- Reject text frames for the game transport.
- Bound frame size, accumulated receive bytes, connection rate, and concurrent
  sessions per source.
- Apply the same authentication and session validation to TCP and WebSocket
  transports.
- Do not trust reverse-proxy client-address headers from untrusted peers.
- Keep manifest SHA-256 validation strict for downloaded client assets.
- Avoid placing credentials or session keys in WebSocket URLs or query strings.
- Do not log decrypted credentials or full authentication packets.

## Initial Effort Bands

These are engineering estimates, not delivery commitments:

| Milestone | Estimated effort |
|---|---:|
| Reproducible baseline | 1-3 person-weeks |
| Dual-transport proof of concept | 1-2 person-weeks after baseline |
| Playable internal browser build | 3-6 person-weeks total |
| Supported desktop-browser MVP | 2-3 person-months total |
| Production hardening and asset delivery | 2-4 person-months total |

The largest schedule variables are server integration, current browser runtime
stability, initial asset size, and persistence behavior.

## Recommended Starting Sequence

1. Pin Emscripten and produce the current browser artifact.
2. Add a minimal WSS transport to the server and route `/login` and one world.
3. Replace hardcoded browser URL construction with explicit endpoint
   configuration.
4. Prove browser login and gameplay before changing asset packaging.
5. Harden WebConnection lifecycle and add the dual-transport integration tests.
6. Add runtime browser CI.
7. Address input, HiDPI, persistence, bundle size, and memory in that order.

## First Milestone Definition

The first milestone is complete when:

- A clean Docker build produces a launchable browser bundle.
- The bundle is served with the required isolation headers.
- The browser connects to `wss://<host>/login` and
  `wss://<host>/world/<id>`.
- The same server still accepts existing desktop clients over TCP.
- Login, character selection, world entry, movement, chat, and logout work.
- No application packet format differs between TCP and WebSocket sessions.
- Known runtime defects and baseline performance measurements are recorded for
  the next milestone.
