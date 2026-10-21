#!/bin/bash
# Notarizes and staples build/Colchian Dragon.app, producing build/Colchian-Dragon.zip for distribution.
#
# One-time setup (stores an app-specific password in your keychain):
#   xcrun notarytool store-credentials colchian-notary \
#       --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Then:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
#   scripts/notarize.sh
set -euo pipefail

cd "$(dirname "$0")/.."
PROFILE="${NOTARY_PROFILE:-colchian-notary}"
APP="build/Colchian Dragon.app"
ZIP="build/Colchian-Dragon.zip"

codesign --verify --strict "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
spctl --assess --type execute --verbose "$APP"
echo "Notarized: $ZIP"
