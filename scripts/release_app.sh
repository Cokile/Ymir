#!/usr/bin/env bash
set -euo pipefail

# Builds a standalone Release build of Ymir and installs it into /Applications,
# then relaunches it. Re-run this after code changes to update the installed app.
#
# Override the install location if needed:
#   DEST_DIR=~/Applications scripts/release_app.sh

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/Ymir.xcodeproj"
SCHEME="Ymir"
CONFIG="Release"
APP_NAME="Ymir"
DERIVED="$ROOT/build/xcode"
BUILT_APP="$DERIVED/Build/Products/$CONFIG/$APP_NAME.app"
DEST_DIR="${DEST_DIR:-/Applications}"
DEST_APP="$DEST_DIR/$APP_NAME.app"
SIGN_IDENTITY="${SIGN_IDENTITY:-Ymir Self-Signed}"

cd "$ROOT"

echo "==> Building $SCHEME ($CONFIG)..."
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  -destination 'platform=macOS' \
  build

if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: build product not found at $BUILT_APP" >&2
  exit 1
fi

# Re-sign with a stable self-signed identity so the code signature (and thus
# TCC/notification permissions) stays constant across rebuilds.
if ! security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
  echo "==> Signing identity '$SIGN_IDENTITY' not found; creating it..."
  SIGN_IDENTITY="$SIGN_IDENTITY" "$ROOT/scripts/make_signing_cert.sh"
fi
echo "==> Signing with '$SIGN_IDENTITY'..."
codesign --force --deep --sign "$SIGN_IDENTITY" "$BUILT_APP"

# Quit a running instance so we can replace the bundle and relaunch cleanly.
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "==> Quitting running $APP_NAME..."
  osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

echo "==> Installing to $DEST_APP..."
mkdir -p "$DEST_DIR"
if [[ -w "$DEST_DIR" ]]; then
  rm -rf "$DEST_APP"
  # ditto preserves the bundle structure and code signature.
  ditto "$BUILT_APP" "$DEST_APP"
else
  echo "    $DEST_DIR is not writable; using sudo (you may be prompted for your password)."
  sudo rm -rf "$DEST_APP"
  sudo ditto "$BUILT_APP" "$DEST_APP"
fi

# Locally built apps aren't quarantined, but strip the flag just in case.
xattr -dr com.apple.quarantine "$DEST_APP" >/dev/null 2>&1 || true

# Finder and Launch Services can cache app icons by bundle identity. Refresh the
# installed bundle metadata so /Applications notices icon-only updates.
touch "$DEST_APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f -R -trusted "$DEST_APP" >/dev/null 2>&1 || true

echo "==> Launching $APP_NAME..."
open "$DEST_APP"

echo "==> Done: $DEST_APP"
