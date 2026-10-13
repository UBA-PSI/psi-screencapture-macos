#!/bin/sh
# Builds screenrec, signs it with a Developer ID certificate, has Apple notarize it
# and leaves screenrec-<version>-macos-universal.zip in the current directory.
#
# Usage: ./release.sh 1.0.0
#
# Needs in the environment:
#   SIGN_IDENTITY                 e.g. "Developer ID Application: Jane Doe (TEAMID1234)"
#   APPLE_ID                      Apple Developer account
#   APPLE_TEAM_ID                 team ID
#   APPLE_APP_SPECIFIC_PASSWORD   app-specific password for notarization
set -eu
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh VERSION}"
: "${SIGN_IDENTITY:?}" "${APPLE_ID:?}" "${APPLE_TEAM_ID:?}" "${APPLE_APP_SPECIFIC_PASSWORD:?}"
ZIP="screenrec-$VERSION-macos-universal.zip"

./build.sh
# Notarization requires the hardened runtime and a secure timestamp.
codesign --force --options runtime --timestamp \
    --identifier de.uni-bamberg.psi.screenrec --sign "$SIGN_IDENTITY" screenrec
codesign --verify --strict --verbose=2 screenrec

rm -f "$ZIP"
zip -j "$ZIP" screenrec README.md LICENSE
xcrun notarytool submit "$ZIP" --wait \
    --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD"
# A bare executable cannot be stapled. Gatekeeper fetches the ticket online on first launch.
echo "$ZIP"
