# Self-hosted runner (Mac mini)

CI and Release run on a **self-hosted GitHub Actions runner** installed on the
Mac mini, not on GitHub-hosted macOS runners.

## Why

GitHub-hosted **macOS** runner minutes are billed at a **10x multiplier**
against a private repository's included quota (2,000 min on GitHub Free becomes
~200 macOS minutes/month). Self-hosted runner usage is free of charge. Since
this repo is private and the Mac mini is already here, self-hosting removes the
recurring cost entirely.

## What is installed

- Runner service: `actions.runner.emircankavas-kremote.macmini-kremote`
  (launchd, starts at login, survives reboot).
- Home: `~/actions-runner`, labels: `self-hosted`, `macOS`, `ARM64`.
- Workflows select it with `runs-on: [self-hosted, macOS, ARM64]`.

Reproduce on a fresh Mac (needs a fresh registration token — they expire hourly):

```bash
# get a token with the GitHub CLI (or the repo's Settings > Actions > Runners)
gh api -X POST repos/emircankavas/kremote/actions/runners/registration-token --jq .token

mkdir -p ~/actions-runner && cd ~/actions-runner
VER=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"].lstrip("v"))')
curl -fsSL -o runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v${VER}/actions-runner-osx-arm64-${VER}.tar.gz"
tar xzf runner.tar.gz && rm runner.tar.gz
./config.sh --url https://github.com/emircankavas/kremote \
  --token "$TOKEN" --name macmini-kremote --work _work --unattended --replace
./svc.sh install && ./svc.sh start
```

## Host-specific requirements

These are baked into the workflows because a stock GitHub runner does not need
them, and this Mac does:

1. **Metal Toolchain.** Xcode 27 no longer ships the `metal` compiler, so any
   dependency with a `.metal` file (SwiftTerm) fails with *"cannot execute tool
   'metal'"*. Fix once per machine:
   `xcodebuild -downloadComponent MetalToolchain` (~840 MB).
2. **`arch=arm64` must be pinned** in the `xcodebuild` destination. A generic
   `platform=macOS` destination resolves to **x86_64** on this host while SwiftPM
   builds dependencies for arm64 only, producing *"Unable to resolve module
   dependency: 'KRemoteCore'"*.
3. **XcodeGen without Homebrew.** `brew install xcodegen` is not used; the
   workflow downloads the official release zip into `~/hermes-build/bin`, which
   `PATH` is prepended in the relevant steps.
4. **Xcode license** must be accepted on the host:
   `sudo xcodebuild -license accept`.
5. The project already builds in **Swift 6 language mode** on Xcode 27 — see the
   `TerminalSessionView` fix in commit `a94000d`.

## Security

Self-hosted runners must never be exposed to fork pull requests: a PR from a
fork would execute arbitrary code on the Mac. This is only safe because the
repository is private. If it is ever made public, remove the runner (or
restrict workflow runs to approved contributors) first.

```bash
# to remove the runner entirely
cd ~/actions-runner && ./svc.sh stop && ./svc.sh uninstall && ./config.sh remove --token <TOKEN>
```
