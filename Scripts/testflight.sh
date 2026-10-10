#!/usr/bin/env bash
#
# Archive Rulebook, export it, and upload the build to TestFlight.
#
#   ./Scripts/testflight.sh            # test, archive, export, upload
#   ./Scripts/testflight.sh --dry-run  # test, archive and export only
#
# The same test gate as the Publish TestFlight workflow runs first: the
# library suite, then the app's unit and UI tests on a simulator. A build that
# fails them is never uploaded. SKIP_TESTS=1 bypasses it, for emergencies only.
#
# The App Store Connect app record must already exist: Apple does not allow it
# to be created through the API ("The resource 'apps' does not allow 'CREATE'"),
# only through the App Store Connect UI.

set -euo pipefail

TEAM_ID="${TEAM_ID:-Y7KVX7666P}"
SCHEME="Rulebook"
PROJECT="App/Rulebook.xcodeproj"

# App Store Connect API credentials. The key lives outside the repository.
ASC_KEY_ID="${ASC_KEY_ID:-9L496DA23R}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-517f64b1-e6f9-4185-be4e-ef0faa859ae1}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/Downloads/TestFlight-GitHub-Actions-Backup/AuthKey_${ASC_KEY_ID}.p8}"

PROFILE_NAME="${PROFILE_NAME:-Rulebook App Store}"
# Overridable: while more than one "Apple Distribution" certificate is in the
# keychain the name alone is ambiguous and the archive may pick the wrong one.
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Distribution}"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

if [[ "${SKIP_TESTS:-}" != "1" ]]; then
  echo "==> Library tests"
  swift test --quiet

  echo "==> App unit and UI tests"
  (cd App && xcodegen generate --quiet)
  SIMULATOR_ID="$(xcrun simctl list devices available -j |
    jq -r '[.devices[][] | select(.name | startswith("iPhone"))][0].udid')"
  if [[ -z "$SIMULATOR_ID" || "$SIMULATOR_ID" == "null" ]]; then
    echo "No available iPhone simulator was found." >&2
    exit 1
  fi
  xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    CODE_SIGNING_ALLOWED=NO \
    -quiet
  # Xcode writes the app's MSAL pin into the root Package.resolved, which
  # belongs to Package.swift alone.
  git checkout --quiet -- Package.resolved 2>/dev/null || true
else
  echo "==> SKIP_TESTS=1: uploading without the test gate"
fi

BUILD_DIR="$(mktemp -d -t rulebook-archive)"
ARCHIVE="$BUILD_DIR/Rulebook.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"

# Build number must rise with every upload; the date makes that automatic and
# keeps it meaningful when reading a build list later.
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d.%H%M)}"

echo "==> Archiving (build $BUILD_NUMBER)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -quiet

cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>app-store-connect</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>uploadSymbols</key><true/>
    <key>signingStyle</key><string>manual</string>
    <key>signingCertificate</key><string>Apple Distribution</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>net.steinbok.Rulebook</key><string>$PROFILE_NAME</string>
    </dict>
    <key>destination</key><string>export</string>
</dict>
</plist>
PLIST

echo "==> Exporting"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
  -exportPath "$EXPORT_DIR" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  -quiet

IPA="$(find "$EXPORT_DIR" -name '*.ipa' | head -1)"
echo "==> Built $IPA"

if $DRY_RUN; then
  echo "Dry run: not uploading. Archive kept at $ARCHIVE"
  exit 0
fi

# altool reads the key from a fixed set of directories rather than a path.
mkdir -p "$HOME/.appstoreconnect/private_keys"
cp "$ASC_KEY_PATH" "$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"

echo "==> Validating"
xcrun altool --validate-app -f "$IPA" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo "==> Uploading to TestFlight"
xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"

echo
echo "Uploaded build $BUILD_NUMBER. Processing takes a few minutes;"
echo "it appears in TestFlight once Apple finishes with it."
