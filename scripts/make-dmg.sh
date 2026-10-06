#!/bin/bash
# Builds a distributable Sweep.dmg (Phase 6).
#
# Unsigned (local testing):     scripts/make-dmg.sh
# Developer ID + notarized:     SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#                               NOTARY_PROFILE="your-notarytool-keychain-profile" \
#                               scripts/make-dmg.sh
#
# NOTARY_PROFILE is a keychain profile created once with:
#   xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <team> --password <app-specific>
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Sweep"
DERIVED="build/release"
DIST="dist"
APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
DMG="$DIST/$APP_NAME.dmg"

echo "==> Building Release…"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
    -derivedDataPath "$DERIVED" build ${SIGN_IDENTITY:+CODE_SIGN_IDENTITY="$SIGN_IDENTITY"} | tail -2

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    echo "==> Signing with Developer ID…"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
fi

echo "==> Creating dmg…"
mkdir -p "$DIST"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

if [[ -n "${SIGN_IDENTITY:-}" && -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarizing…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
    echo "==> Notarized and stapled."
elif [[ -z "${SIGN_IDENTITY:-}" ]]; then
    echo "NOTE: unsigned build — fine for local testing, Gatekeeper will warn on other Macs."
fi

echo "==> Done: $DMG"
