#!/bin/zsh
# Makes the prebuilt app for GitHub Releases: archives Gingham Bench (Release), exports it signed
# with Developer ID, notarizes it with Apple's notary service (an App Store Connect API key),
# staples the ticket and zips it: release/GinghamBench-<version>.zip (+ its SHA-256).
# Nothing is uploaded anywhere but to the notary service.
#
#   Scripts/release.sh
#
# Needs (the maintainer's, not in this repository):
# - the "Developer ID Application" certificate of team CX4XTQ23ND in the keychain;
# - ASC_KEY_ID and ASC_ISSUER in the environment or in Scripts/release.local.sh (git-ignored);
# - the API key at ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8 (read by notarytool,
#   never printed or copied).
set -e
cd "$(dirname "$0")/.."
[[ -f Scripts/release.local.sh ]] && source Scripts/release.local.sh
[[ -n "$ASC_KEY_ID" && -n "$ASC_ISSUER" ]] || { echo "✗ set ASC_KEY_ID and ASC_ISSUER (or Scripts/release.local.sh)"; exit 1 }
TEAM=CX4XTQ23ND
AUTH_KEY="$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"
[[ -f "$AUTH_KEY" ]] || { echo "✗ no App Store Connect API key at ~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8"; exit 1 }
DEVELOPER_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*('"$TEAM"')\)".*/\1/p' | head -1)
[[ -n "$DEVELOPER_ID" ]] || { echo "✗ no Developer ID Application certificate of team $TEAM in the keychain"; exit 1 }
if [[ -n "$(git status --porcelain -- Mac Shared)" ]]; then
  echo "⚠︎ Mac/ or Shared/ has uncommitted changes: the app is built from the working tree"
fi
VERSION=$(awk '/MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' Mac/project.yml)
BUILD=$(awk '/CURRENT_PROJECT_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' Mac/project.yml)
COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "uncommitted")
OUT=release
WORK="$OUT/work"
LOG="$OUT/log.txt"
rm -rf "$WORK"; mkdir -p "$WORK"
: > "$LOG"
KEY=(-authenticationKeyPath "$AUTH_KEY" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER")

# (The commit goes into the log too: Scripts/publish.sh checks the zip is of the commit it pushes.
# The version is project.yml's, also when the generated project wasn't made again after a raise.)
echo "▸ archive Gingham Bench $VERSION ($BUILD) of $COMMIT with $(xcodebuild -version | head -1)" | tee -a "$LOG"
xcodebuild clean archive -project Mac/GinghamBench.xcodeproj -scheme GinghamBench -configuration Release \
  -destination "generic/platform=macOS" -archivePath "$WORK/GinghamBench.xcarchive" -derivedDataPath "$WORK/DerivedData" \
  -allowProvisioningUpdates "${KEY[@]}" BENCH_COMMIT="$(Scripts/bench-commit.sh)" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" >> "$LOG" 2>&1 \
  || { echo "✗ archive failed:"; grep -E "error:" "$LOG" | head -5; exit 1 }

# Signed here with the keychain's Developer ID: the app needs no provisioning profile.
cat > "$WORK/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>export</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict>
</plist>
PLIST
echo "▸ export with $DEVELOPER_ID"
xcodebuild -exportArchive -archivePath "$WORK/GinghamBench.xcarchive" -exportOptionsPlist "$WORK/export.plist" \
  -exportPath "$WORK/export" >> "$LOG" 2>&1 || { echo "✗ export failed:"; grep -E "error:" "$LOG" | tail -5; exit 1 }
APP="$WORK/export/Gingham Bench.app"
codesign --verify --deep --strict "$APP" || { echo "✗ the exported app's signature doesn't verify"; exit 1 }

echo "▸ notarize (the notary service usually answers within minutes)"
ditto -c -k --keepParent "$APP" "$WORK/notarize.zip"
RESULT=$(xcrun notarytool submit "$WORK/notarize.zip" --key "$AUTH_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" \
  --wait --timeout 40m --output-format json 2>> "$LOG")
echo "$RESULT" >> "$LOG"
STATUS=$(echo "$RESULT" | python3 -c 'import sys, json; t = sys.stdin.read(); print(json.loads(t[t.index("{"):]).get("status", "?") if "{" in t else "?")')
if [[ "$STATUS" != Accepted ]]; then
  ID=$(echo "$RESULT" | python3 -c 'import sys, json; t = sys.stdin.read(); print(json.loads(t[t.index("{"):]).get("id", "") if "{" in t else "")')
  echo "✗ notarization: $STATUS"
  [[ -n "$ID" ]] && xcrun notarytool log "$ID" --key "$AUTH_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER" | head -40
  exit 1
fi
xcrun stapler staple "$APP" >> "$LOG" 2>&1
xcrun stapler validate "$APP" > /dev/null
spctl --assess --type execute -vv "$APP" 2>&1 | sed 's/^/  /'

ZIP="$OUT/GinghamBench-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
echo "✓ $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' ')): Gingham Bench $VERSION ($BUILD) of $COMMIT, signed with Developer ID, notarized, stapled; not published"
