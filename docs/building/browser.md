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
