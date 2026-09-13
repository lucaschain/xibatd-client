# Desktop Auto-Update

Windows portable clients check the website API before loading login modules:

```text
https://xibatd.online/api/client/updates/windows-x64
```

The website retrieves `client/windows/latest/update.json` from the public client
bucket, verifies its Ed25519 signature and release metadata, and caches it for one
minute. Publishing a client does not require restarting or redeploying the website.

## Release Contract

`publish-windows.yml` assigns the GitHub workflow run number as the monotonically
increasing release sequence. It packages a managed-file inventory, signs the exact
JSON payload with `xibat-client-update-signing-key` in Google Secret Manager, uploads
immutable artifacts, and then replaces the `latest/` pointers. A run cannot promote
over an equal or newer sequence.

The Windows workflow uses the dedicated `xibat-windows-publisher` service account
through the workflow-restricted `xibat-windows-github` identity pool. Browser builds
use a different publisher and cannot read the signing key or modify Windows pointers.

The matching public key and key ID are compiled into the client. Never put the
private key in source, GitHub variables, build artifacts, logs, or OpenTofu state.
Key rotation requires a client release that trusts the new public key before the
publisher starts signing with it.

The current public DER key, encoded as Base64, is:

```text
MCowBQYDK2VwAyEAHmXfV/TVMnijkVUC09VHaB+VqueWPpPbJqQ8zsL9N6w=
```

## Client Behavior

- Windows checks automatically at startup. Other platforms continue immediately.
- A validated response with no newer release continues to login normally.
- Windows updates are mandatory when available; the player can update or exit, but
  cannot continue with the installed release.
- Check, metadata validation, download, staging, and installer-launch errors offer
  Retry or Exit only. They never load the normal client modules.
- Canceling a download returns to the same Retry-or-Exit state.
- Installer failures restore the backup, restart into the updater gate, and report
  the failure with Retry or Exit before making another update check.
- Invalid signed metadata is never installed.
- Downloads are checked with SHA-256 before extraction.
- The signed archive is staged under `.update/`.
- `updater/install-update.ps1` waits for the client to exit, locks the installation,
  backs up managed files, replaces them, removes obsolete managed files, and restarts
  the client.
- Failed replacement restores the backup. `data/things`, `data/sounds`, `.update`,
  and files outside the managed inventory are not removed by the updater.

The first auto-update-capable release is a bootstrap release. Existing users must
install that portable ZIP manually; later Windows releases update automatically.

## Verification

Run Lua contract coverage with:

```sh
luajit tests/xibat_updater_test.lua "$PWD"
```

Windows build and installation smoke tests must use `build-windows.ps1` from a
native Windows checkout. Verify an older release updates to a newer sequence and
that `data/things/1098`, user settings, and login state survive.
