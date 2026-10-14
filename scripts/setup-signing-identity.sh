#!/bin/bash
# Creates (once) a *stable* self-signed code-signing identity for KRemote.
#
# Why: an ad-hoc signature ("codesign --sign -") has a designated requirement of
# the form `cdhash H"..."`, which changes on every build. macOS binds keychain
# ACLs to that requirement, so every app update invalidates the ACL of every
# stored password and macOS re-prompts for each one. Signing with a fixed
# certificate changes the requirement to
#   designated => identifier "..." and certificate leaf = H"..."
# which is identical across builds, so "Always Allow" sticks.
#
# No Apple Developer account is needed. The identity lives in its own keychain
# (not the login keychain, which cannot be written to non-interactively).
set -euo pipefail

DIR="${KM_SIGNING_DIR:-$HOME/hermes-build/signing}"
KC="$DIR/kremote-signing.keychain-db"
PW="${KM_SIGNING_PASSWORD:-kremote-signing}"
IDENTITY="KRemote Dev"

mkdir -p "$DIR"
cd "$DIR"

if security find-certificate -c "$IDENTITY" "$KC" >/dev/null 2>&1; then
  echo "Signing identity '$IDENTITY' already present in $KC"
else
  echo "Creating signing identity '$IDENTITY'…"

  cat > cnf.cnf <<'CNF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = KRemote Dev
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = critical, CA:false
CNF

  openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
    -keyout k.key -out k.crt -config cnf.cnf -extensions v3 >/dev/null 2>&1

  # Start clean if a half-built keychain is lying around.
  security delete-keychain "$KC" 2>/dev/null || true
  security create-keychain -p "$PW" "$KC"
  # No auto-lock timeout: the keychain is unlocked explicitly before signing.
  security set-keychain-settings "$KC"
  security unlock-keychain -p "$PW" "$KC"
  security import k.crt -k "$KC" -T /usr/bin/codesign -A >/dev/null
  security import k.key -k "$KC" -T /usr/bin/codesign -A >/dev/null
  # Without a partition list, codesign still refuses to use the key headlessly.
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
  rm -f k.key k.crt cnf.cnf
fi

# Put the keychain on the user search list without dropping the existing ones.
EXISTING=$(security list-keychains -d user | tr -d ' "' | grep -v "$KC" | tr '\n' ' ')
# shellcheck disable=SC2086
security list-keychains -d user -s $EXISTING "$KC"

echo
security find-identity -v -p codesigning "$KC"
echo
echo "Done. Sign with:  codesign --force --deep --sign \"$IDENTITY\" App.app"
echo "The workflow unlocks this keychain with the SIGNING_KEYCHAIN_PASSWORD secret."
