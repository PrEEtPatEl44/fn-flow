#!/bin/bash
# Builds build/Nemotron Flow.app (release) with Info.plist, bundled runtime scripts,
# and a code signature (your Apple Development identity if present, else ad-hoc).
#
#   scripts/build_app.sh            # build
#   scripts/build_app.sh --install  # build and copy to ~/Applications
#   scripts/build_app.sh --run      # build and launch

set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Nemotron Flow.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/nemotron_flow"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NemotronFlow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp runtime/install_runtime.sh runtime/server.py "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/install_runtime.sh"

# macOS ties the Accessibility grant to the code signature. Ad-hoc signatures change on
# every build (so the grant silently stops applying); a stable identity keeps it.
# Prefer a real Apple identity; otherwise create a local self-signed one, kept in its own
# keychain so the login keychain is untouched.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
KEYCHAIN_ARGS=()
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="Nemotron Flow Local Signing"
    SIGN_DIR="$HOME/Library/Application Support/NemotronFlow/signing"
    KEYCHAIN="$SIGN_DIR/signing.keychain-db"
    KEYCHAIN_PW="nemotron-flow-local"
    if [[ ! -f "$KEYCHAIN" ]]; then
        echo "Creating local code-signing identity (one time)..."
        mkdir -p "$SIGN_DIR"
        TMP="$(mktemp -d)"
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$IDENTITY" \
            -addext "keyUsage=critical,digitalSignature" \
            -addext "extendedKeyUsage=critical,codeSigning" \
            -addext "basicConstraints=critical,CA:false" 2>/dev/null
        openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
            -out "$TMP/id.p12" -passout pass:"$KEYCHAIN_PW"
        security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
        security set-keychain-settings "$KEYCHAIN" # no auto-lock
        security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$KEYCHAIN_PW" -T /usr/bin/codesign
        security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PW" "$KEYCHAIN" >/dev/null
        rm -rf "$TMP"
    fi
    security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
    KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")
fi
codesign --force --deep "${KEYCHAIN_ARGS[@]}" --sign "$IDENTITY" "$APP"
echo "Signed with: $IDENTITY"
echo "Built: $APP"

case "${1:-}" in
    --install)
        mkdir -p "$HOME/Applications"
        rm -rf "$HOME/Applications/Nemotron Flow.app"
        cp -R "$APP" "$HOME/Applications/"
        echo "Installed: ~/Applications/Nemotron Flow.app"
        open "$HOME/Applications/Nemotron Flow.app"
        ;;
    --run)
        open "$APP"
        ;;
esac
