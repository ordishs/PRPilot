#!/usr/bin/env bash
#
# Build a signed, notarised, stapled DMG of PRPilot, refresh Casks/prpilot.rb
# with the new version + sha256, and print the follow-up git/gh commands.
#
# One-time setup:
#
#   1. Apple Developer account, with a "Developer ID Application" certificate
#      installed in your login keychain. The signing identity and team id are
#      set on the app target's Release config in project.yml.
#
#   2. Store an App Store Connect API key (or app-specific password) under a
#      keychain profile so notarytool can pick it up non-interactively:
#
#        xcrun notarytool store-credentials prpilot-notary \
#          --apple-id "<your-apple-id>" \
#          --team-id "<your-team-id>" \
#          --password "<app-specific-password>"
#
#   3. Install create-dmg:
#
#        brew install create-dmg
#
#   4. Create a .env file in the repo root (gitignored) — this script loads it:
#
#        DEVELOPMENT_TEAM=ABCDE12345
#        NOTARY_PROFILE=prpilot-notary
#
# Usage:
#
#   scripts/release.sh 0.1.0
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Load release config (DEVELOPMENT_TEAM, NOTARY_PROFILE) from an uncommitted
# .env in the repo root, so the script runs without exporting vars by hand.
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    . "$REPO_ROOT/.env"
    set +a
fi

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM (10-char Apple team id) in .env or the environment}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE (notarytool keychain profile) in .env or the environment}"

VERSION="${1:?Usage: scripts/release.sh <version> (e.g. 0.1.0)}"

BUILD_DIR="build/release"
ARCHIVE="$BUILD_DIR/PRPilot-$VERSION.xcarchive"
EXPORT_DIR="$BUILD_DIR/export-$VERSION"
APP_PATH="$EXPORT_DIR/PR Pilot.app"
ZIP_PATH="$BUILD_DIR/PRPilot-$VERSION.zip"
DMG_PATH="$BUILD_DIR/PRPilot-$VERSION.dmg"
EXPORT_OPTS="$BUILD_DIR/ExportOptions.plist"
# The cask lives in the ordishs/homebrew-tap repo so users can run
# `brew install ordishs/tap/prpilot`. Default to a clone beside this repo;
# override with TAP_DIR in .env if yours is elsewhere.
TAP_DIR="${TAP_DIR:-$REPO_ROOT/../homebrew-tap}"
CASK="$TAP_DIR/Casks/prpilot.rb"

if ! command -v create-dmg >/dev/null; then
    echo "create-dmg is not installed. Run: brew install create-dmg" >&2
    exit 1
fi

if [ ! -f "$CASK" ]; then
    echo "Cask not found at $CASK" >&2
    echo "Clone the tap beside this repo (or set TAP_DIR in .env):" >&2
    echo "  git clone git@github.com:ordishs/homebrew-tap.git \"$TAP_DIR\"" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE" "$EXPORT_DIR" "$ZIP_PATH" "$DMG_PATH"

if command -v xcodegen >/dev/null; then
    xcodegen generate
fi

echo "==> Archiving Release build for $VERSION"
# Signing is configured on the app target's Release config in project.yml
# (Manual / Developer ID Application / DEVELOPMENT_TEAM / hardened runtime), so
# the archive signs the app and its embedded frameworks with the hardened
# runtime notarisation requires. We deliberately do NOT pass CODE_SIGN_IDENTITY /
# DEVELOPMENT_TEAM on the command line: those apply globally and would force the
# SwiftPM library targets (DiffKit, etc.) to sign too, but CLI build settings
# don't propagate into the synthesized package project, so they fall back to the
# wrong team and fail. Library targets statically link into the app and are
# covered by the app-target signature.
xcodebuild \
    -project PRPilot.xcodeproj \
    -scheme PRPilot \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    MARKETING_VERSION="$VERSION" \
    archive

cat >"$EXPORT_OPTS" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
EOF

echo "==> Exporting signed .app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTS"

if [ ! -d "$APP_PATH" ]; then
    echo "Expected $APP_PATH not found after export" >&2
    exit 1
fi

echo "==> Zipping for notarytool"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Submitting to Apple notary service (this can take several minutes)"
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> Stapling notarisation ticket"
xcrun stapler staple "$APP_PATH"

echo "==> Building DMG"
create-dmg \
    --volname "PR Pilot $VERSION" \
    --window-size 540 380 \
    --icon-size 96 \
    --icon "PR Pilot.app" 140 190 \
    --app-drop-link 400 190 \
    "$DMG_PATH" \
    "$APP_PATH"

SHA=$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')

echo "==> Updating $CASK"
python3 - "$CASK" "$VERSION" "$SHA" <<'PY'
import sys, re, pathlib
path, version, sha = sys.argv[1], sys.argv[2], sys.argv[3]
text = pathlib.Path(path).read_text()
text = re.sub(r'^( *version )".*"', rf'\1"{version}"', text, count=1, flags=re.MULTILINE)
text = re.sub(r'^( *sha256 )(:no_check|".*")', rf'\1"{sha}"', text, count=1, flags=re.MULTILINE)
pathlib.Path(path).write_text(text)
PY

echo ""
echo "Release artifacts:"
echo "  DMG:    $DMG_PATH"
echo "  sha256: $SHA"
echo "  cask:   $CASK (updated)"
echo ""
echo "Next steps:"
echo "  # 1) tag the app repo and publish the DMG (ordishs/PRPilot):"
echo "  git tag v$VERSION && git push origin main v$VERSION"
echo "  gh release create v$VERSION \"$DMG_PATH\" --title \"v$VERSION\" --notes \"Release v$VERSION\""
echo "  # 2) publish the updated cask in the tap (ordishs/homebrew-tap):"
echo "  git -C \"$TAP_DIR\" add Casks/prpilot.rb"
echo "  git -C \"$TAP_DIR\" commit -m \"prpilot $VERSION\""
echo "  git -C \"$TAP_DIR\" push"
echo ""
echo "Then users can install via:"
echo "  brew install ordishs/tap/prpilot"
