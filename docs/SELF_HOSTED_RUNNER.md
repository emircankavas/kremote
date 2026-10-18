# Self-hosted runner (Mac mini)

CI and Release run on a **self-hosted Forgejo Actions runner** installed on the
Mac mini. The repository and its CI now live on Forgejo
(`https://forgejo.kavas.dev/emircan/kremote`), not GitHub.

## Why self-hosted

The build needs a real Mac (Xcode, the Metal toolchain, an arm64 host) and the
macOS toolchain is heavy; keeping it on the Mac mini that already exists avoids
paying for hosted macOS minutes and keeps caches warm.

## What is installed

- Runner service: `dev.kavas.forgejo-runner` (launchd, starts at login,
  survives reboot).
- Home: `~/forgejo-runner`, labels: `self-hosted`, `macOS`, `ARM64` (and the
  `macos*` variants used by other repos on this host).
- Workflows select it with `runs-on: [self-hosted, macOS, ARM64]`.
- Node.js is installed under `~/forgejo-runner/node` — the runner needs it on
  `PATH` to execute JavaScript actions (`actions/checkout`, …).
- Registration uses Forgejo's **offline** flow (no GitHub token): the uuid and
  40-hex token come from `forgejo-cli actions register` on the server.

Reproduce on a fresh Mac:

```bash
# on the Forgejo host (in-cluster): mint a runner secret for this scope
kubectl -n forgejo exec deploy/forgejo -- su-exec git /usr/local/bin/gitea \
  forgejo-cli actions generate-secret
kubectl -n forgejo exec deploy/forgejo -- su-exec git /usr/local/bin/gitea \
  forgejo-cli actions register --secret <SECRET> --scope emircan --name macmini-macos \
  --labels "macOS,ARM64,macos,macos-15,macos-26,self-hosted"

# on the Mac: build the runner (Forgejo publishes no darwin binary) and configure
GOOS=darwin GOARCH=arm64 go build -o forgejo-runner .
mkdir -p ~/forgejo-runner/cache
# config.yaml holds server.connections.{url,uuid,token} + the label list
```

## Host-specific requirements

These are baked into the workflows because a stock runner does not need them,
and this Mac does:

1. **Metal Toolchain.** Xcode 27 no longer ships the `metal` compiler, so any
   dependency with a `.metal` file (SwiftTerm) fails with *"cannot execute tool
   'metal'"*. Fix once per machine:
   `xcodebuild -downloadComponent MetalToolchain` (~840 MB).
2. **`arch=arm64` must be pinned** in the `xcodebuild` destination. A generic
   `platform=macOS` destination resolves to **x86_64** on this host while SwiftPM
   builds dependencies for arm64 only, producing *"Unable to resolve module
   dependency: 'KRemoteCore'"*.
3. **Homebrew is at `/opt/homebrew/bin` and is not on the default PATH.** The
   workflow prepends it explicitly. `brew` provides the FreeRDP build deps
   (cmake/ninja/pkgconf/openssl/openh264/jansson/uriparser/jpeg-turbo), not
   freerdp itself.
4. **Node.js** must be on the runner's `PATH` (`~/forgejo-runner/node/bin`), or
   every `uses:` step dies in ~2 s.
5. **Xcode license** must be accepted on the host:
   `sudo xcodebuild -license accept`.

## Security

Self-hosted runners must never be exposed to fork pull requests: a PR from a
fork would execute arbitrary code on the Mac. This is only safe because the
repository is private.

```bash
# to remove the runner entirely
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/dev.kavas.forgejo-runner.plist
```

## Stable code-signing identity

Keychain items are protected by an ACL tied to the app's **designated
requirement**. Under an ad-hoc signature (`codesign --sign -`) that requirement
is a content hash (`cdhash H"..."`) which changes on every build, so each update
invalidates the ACL of every stored password and macOS re-prompts for each one
after an update — "Always Allow" does not survive.

The fix is a *stable* identity. `scripts/setup-signing-identity.sh` creates a
self-signed code-signing certificate (no Apple Developer account needed) in a
dedicated keychain at `~/hermes-build/signing/kremote-signing.keychain-db` and
puts it on the user search list. Signing with it yields:

```
designated => identifier "com.emircankavas.kremote" and certificate leaf = H"..."
```

which is identical for every build, so the keychain grants persist across
updates.

The release workflow unlocks that keychain with the repository secret
`SIGNING_KEYCHAIN_PASSWORD` (the keychain password chosen at setup) and signs
with `codesign --sign "KRemote Dev"`. If the secret or the keychain is missing
the workflow warns and falls back to ad-hoc.

To recreate the identity on a new machine, run the script with the same password
as the secret:

```bash
KM_SIGNING_PASSWORD='<secret>' bash scripts/setup-signing-identity.sh
```
