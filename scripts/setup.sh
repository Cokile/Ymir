#!/usr/bin/env bash
set -euo pipefail

# Bootstraps a fresh clone so Ymir is ready to build.
#
# Verifies the build toolchain, installs XcodeGen (via Homebrew) if missing,
# and regenerates Ymir.xcodeproj from project.yml. Building and launching the
# app is left to scripts/release_app.sh (see: make release).
#
# Idempotent: safe to re-run. It only installs what's missing.
#
#   scripts/setup.sh   # or: make bootstrap

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Ymir is a macOS app; setup must run on macOS."

# Xcode can't be auto-installed, so check and point at the fix.
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "==> Xcode command line tools not found."
  echo "    Install Xcode from the App Store, then run: sudo xcodebuild -license accept"
  echo "    (or, for just the toolchain: xcode-select --install)"
  fail "xcodebuild is required to build Ymir."
fi
echo "==> Xcode: $(xcodebuild -version | head -1)"

if ! command -v brew >/dev/null 2>&1; then
  echo "==> Homebrew not found."
  echo "    Install it from https://brew.sh, then re-run this script:"
  echo '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  fail "Homebrew is required to install XcodeGen."
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "==> Installing XcodeGen via Homebrew..."
  brew install xcodegen
fi
echo "==> XcodeGen: $(xcodegen --version)"

echo "==> Generating Ymir.xcodeproj from project.yml..."
xcodegen generate

# Warm the same pinned npx package used by the app.
if command -v npm >/dev/null 2>&1; then
  echo "==> npx: $(command -v npx)"
  GATEWAY_VERSION="$(cat Sources/Ymir/Resources/copilot-api-version.txt)"
  [[ "$GATEWAY_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "Invalid pinned gateway version."
  GATEWAY_PACKAGE="@jeffreycao/copilot-api@$GATEWAY_VERSION"
  echo "==> Preparing $GATEWAY_PACKAGE..."
  npx --yes "$GATEWAY_PACKAGE" --help >/dev/null
else
  echo "==> WARNING: npm/npx not found. Ymir needs it at runtime to start copilot-api."
  echo "    Install Node.js (e.g. 'brew install node'), then re-run this script."
fi

echo "==> Setup complete. Build and launch the app with:"
echo "    make release   # or: scripts/release_app.sh"
