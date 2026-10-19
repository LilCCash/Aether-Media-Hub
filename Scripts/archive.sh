#!/usr/bin/env bash
# Builds a signed IPA on YOUR Mac, with YOUR Apple developer team. Nothing here contains credentials:
# Xcode uses the certificates and profiles already in your login keychain / Apple ID session.
#
#   1. echo 'DEVELOPMENT_TEAM = ABCDE12345' > Config/Signing.local.xcconfig
#      echo 'APP_BUNDLE_ID = com.yourname.aether' >> Config/Signing.local.xcconfig
#   2. cp Config/ExportOptions.plist.example Config/ExportOptions.plist   # edit teamID / method
#   3. Scripts/archive.sh
#
# Output: build/Aether.xcarchive and build/ipa/Aether.ipa
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -f Config/Signing.local.xcconfig ]; then
  echo "Missing Config/Signing.local.xcconfig (see the comments at the top of this script)." >&2
  exit 1
fi
if [ ! -f Config/ExportOptions.plist ]; then
  echo "Missing Config/ExportOptions.plist (copy Config/ExportOptions.plist.example)." >&2
  exit 1
fi

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen" >&2; exit 1; }
xcodegen generate

rm -rf build/Aether.xcarchive build/ipa
xcodebuild archive \
  -project Aether.xcodeproj -scheme Aether \
  -destination 'generic/platform=iOS' \
  -archivePath build/Aether.xcarchive \
  -allowProvisioningUpdates

xcodebuild -exportArchive \
  -archivePath build/Aether.xcarchive \
  -exportOptionsPlist Config/ExportOptions.plist \
  -exportPath build/ipa \
  -allowProvisioningUpdates

ls -lh build/ipa/*.ipa
echo "Verify the signature with:  codesign -dv --verbose=2 build/Aether.xcarchive/Products/Applications/Aether.app"
