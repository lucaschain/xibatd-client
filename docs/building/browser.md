# Browser Build

The browser client is built as a WebAssembly application with Emscripten. The
supported build runs inside Docker so local and CI builds use the same compiler
and dependency environment.

## Prerequisites

- Docker with BuildKit support.
- Python 3 for the local static server.
- Enough free disk space for the Emscripten SDK, vcpkg dependencies, build
  intermediates, and output bundle.

The Emscripten version is pinned by `EMSDK_VERSION` in `Dockerfile.browser`.
Changing it requires a successful clean browser build and runtime smoke test.

## Build

From the repository root:

```bash
bash Dockerfile.browser.sh
```

The wrapper builds the `otclient-web` image and copies the static output to
`build-emscripten-web/`. Complete build output is written to
`docker-browser-build.log`.

The generated directory contains the HTML launcher, JavaScript runtime,
WebAssembly module, and preloaded data package. Emscripten may emit additional
worker files when its packaging behavior changes.

## Run Locally

The pthread-enabled WebAssembly build requires cross-origin isolation. Do not
serve it with a generic static server that omits COOP and COEP headers.

Run:

```bash
python3 tools/emscripten-web-serve.py \
  --root build-emscripten-web \
  --port 8000
```

Then open `http://localhost:8000/otclient.html` in a current desktop browser and
select **Start**.

The helper adds the required cross-origin isolation headers. Production hosting
must provide equivalent headers over HTTPS.

## Configure WebSockets

Browser builds require explicit login and world WebSocket endpoints in the
selected `Servers_init` entry. Native builds ignore this table and continue to
use the existing TCP host and port.

Production example:

```lua
["game.example.com"] = {
    port = 7171,
    protocol = 1098,
    httpLogin = false,
    browserWebSocket = {
        login = "wss://play.example.com/login",
        world = "wss://play.example.com/world/{worldId}"
    }
}
```

Local development can use an explicit insecure endpoint:

```lua
browserWebSocket = {
    login = "ws://127.0.0.1:8080/login",
    world = "ws://127.0.0.1:8080/world/{worldId}"
}
```

The world template supports `{worldId}` and `{worldName}`. World names are
percent-encoded as one URL path segment. A template requiring `{worldId}` fails
with a clear error when a legacy login response does not include an ID; use
`{worldName}` for those protocols.

WebSocket payloads contain the unchanged native protocol bytes. The server must
accept the `binary` WebSocket subprotocol and feed binary payload bytes into the
same stream-oriented packet decoder used by TCP sessions. Do not add another
length prefix around WebSocket messages.

Use `wss://` when the client page is served over HTTPS. Browsers block insecure
`ws://` connections from secure pages except in limited local-development
contexts.

## Baseline Check

For a browser toolchain or packaging change, verify all of the following:

- The Docker build exits successfully.
- `docker-browser-build.log` reports the expected pinned Emscripten version.
- The page reports `crossOriginIsolated === true`.
- Selecting **Start** reaches the client login screen.
- The browser console contains no Emscripten abort, uncaught exception, or
  severe WebGL error.
- Chromium and Firefox both launch the bundle.
- Generated artifact sizes and startup observations are recorded in
  `docs/building/browser-baseline.md`.

## Troubleshooting

If Docker is installed through Docker Desktop under WSL, enable integration for
the active WSL distribution. `docker version` must show both a client and a
server before running the build.

If the page reports that shared memory is unavailable, inspect the response
headers and verify that the browser reports `crossOriginIsolated` as true.

If external files are fetched at runtime, those responses must also satisfy the
deployment's CORS and Cross-Origin-Embedder-Policy requirements.
