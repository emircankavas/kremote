# Release channels

How KRemote is released now that everything lives on Forgejo. There is **no
GitHub anywhere** — not in CI, not in the update path, not in the dependency
graph.

## Repositories

| Repo | Visibility | Holds |
| --- | --- | --- |
| `forgejo.kavas.dev/emircan/kremote` | private | source, CI, release workflow |
| `forgejo.kavas.dev/emircan/kremote-releases` | **public** | the `.dmg`/`.zip` assets and the appcasts |

The source repo is private, so an installed app cannot read its release API
without a token. Everything the app fetches at runtime is in the public repo:

- `appcast-stable.json` — written only by a stable release
- `appcast-beta.json` — written by a pre-release, and also refreshed by a stable
  release so beta users are offered the finished build

Both live on the public repo's `main` branch and are read as
`https://forgejo.kavas.dev/emircan/kremote-releases/raw/branch/main/appcast-<channel>.json`.

## Branches

- `main` — the shipped line. Equals the newest stable tag.
- `beta` — integration branch. All 1.8.0 work lands here first; CI runs on both.

## Cutting a beta

```bash
cd /d/projects/kremote
git checkout beta

# 1. Bump the build number (the updater compares it after the marketing version)
#    project.yml: CURRENT_PROJECT_VERSION: 30 -> 31
#    project.yml: MARKETING_VERSION: "1.8.0-beta.2"

# 2. Land the work and wait for CI
git commit -am "…"
git push origin beta
#    CI green on beta is the gate; do not tag a red commit.

# 3. Tag and push — the tag IS the release trigger
git tag -a v1.8.0-beta.2 -m "KRemote 1.8.0 beta 2"
git push origin v1.8.0-beta.2
```

The release workflow then:

1. derives the channel from the tag suffix (`1.8.0-beta.2` → beta, `1.8.0` →
   stable),
2. stamps the tag into `Info.plist` and **fails** if the built bundle reports a
   different version,
3. builds, embeds the FreeRDP libraries, signs, and packages `.dmg` + `.zip`,
4. publishes to `kremote-releases` as a **pre-release** and rewrites
   `appcast-beta.json`,
5. fetches the published appcast back over the public URL and verifies the
   version and both asset URLs (`scripts/check-appcast.py`).

A green release run therefore means the app will actually see the release.

## Promoting to stable

All four are required:

1. CI green on the exact `beta` HEAD being promoted.
2. The newest `v1.8.0-beta.N` has been installed and smoke-tested on the Mac mini
   (launch, SSH session, SFTP session, Software Update on the Beta channel).
3. `RELEASE_NOTES.md` covers the whole cycle.
4. Emircan approves — recorded as a comment on the epic card.

Then:

```bash
git checkout main
git merge --ff-only beta          # main must not diverge
# project.yml: MARKETING_VERSION: "1.8.0"  (drop the suffix)
git commit -am "Release 1.8.0"
git push origin main
git tag -a v1.8.0 -m "KRemote 1.8.0"
git push origin v1.8.0
git checkout beta && git merge main && git push origin beta
```

The stable run writes `appcast-stable.json` **and** `appcast-beta.json`, so beta
users are offered 1.8.0 as well.

## Rolling back a bad pre-release

Beta users are only ever offered what the beta appcast says, so a rollback is a
single file edit:

```bash
# Re-point appcast-beta.json at the last good beta (or at the current stable).
curl -X PUT -H "Authorization: token $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"tag_name\":\"…\"}" https://forgejo.kavas.dev/api/v1/emircan/…   # see below
```

In practice: re-publish the good appcast with `scripts/publish-release.py` after
deleting the bad release, or set `prerelease: true` and edit the `version`/assets
in the appcast through the contents API. Then delete the bad release from the
public repo. Never delete a **stable** release that users may already have
installed — ship a patch (`v1.7.12`) instead.

## Manual publish

The workflow runs `scripts/publish-release.py`; it is idempotent and can be run
by hand (it reuses an existing release for the tag and replaces stale assets):

```bash
FORGEJO_TOKEN=… python3 scripts/publish-release.py \
  --tag v1.8.0-beta.3 --version 1.8.0-beta.3 --channel beta \
  --notes RELEASE_NOTES.md \
  --dmg KRemote-1.8.0-beta.3.dmg --zip KRemote-1.8.0-beta.3.zip
```

## Secrets and mirrors

- `FORGEJO_TOKEN` (repo secret on the source repo) — push rights to
  `kremote-releases`. Set with the Actions secrets API.
- Dependency mirrors, all public on the same Forgejo: `swift-crypto`,
  `swift-asn1` (reached through `Packages/KRemoteCore/.swiftpm/configuration/mirrors.json`,
  because swift-crypto depends on it), `SwiftTerm`, `FreeRDP` (source tarball),
  and `xcodegen` (binary release asset).
- `SIGNING_KEYCHAIN_PASSWORD` is optional. Without it the bundle is ad-hoc
  signed and macOS re-prompts for stored passwords after each update.
