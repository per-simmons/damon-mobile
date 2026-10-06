#!/bin/bash
# Build the iPhone app and install it over the wireless pairing (phone unlocked, same network).
#   DEVELOPMENT_TEAM=ABCDE12345 BUNDLE_ID=com.yourname.damon DEVICE=<id from `xcrun devicectl list devices`> ios/install.sh
# Signing uses the Apple ID signed into Xcode (Xcode → Settings → Accounts).
set -euo pipefail
cd "$(dirname "$0")"
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple developer team ID}"
: "${BUNDLE_ID:?set BUNDLE_ID, e.g. com.yourname.damon}"
: "${DEVICE:?set DEVICE (xcrun devicectl list devices)}"
export DEVELOPMENT_TEAM BUNDLE_ID
xcodegen generate -q
xcodebuild -project Damon.xcodeproj -scheme Damon -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/device build CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration -quiet
xcrun devicectl device install app --device "$DEVICE" build/device/Build/Products/Release-iphoneos/Damon.app
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" || true
