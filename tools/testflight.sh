#!/bin/zsh
# tools/testflight.sh
# Archives Ladle for the App Store and uploads it to App Store Connect, where it goes to TestFlight.
# The build number is the commit count, so every upload from a new commit is higher than the last.
#
# Needs an App Store Connect Team key with the Admin role, for cloud signing:
#   ASC_KEY_ID      the key's ID; the key is ~/.appstoreconnect/private_keys/AuthKey_<id>.p8
#   ASC_ISSUER_ID   the issuer ID shown above the keys
set -euo pipefail
cd "$(dirname "$0")/.."
: ${ASC_KEY_ID:?set ASC_KEY_ID} ${ASC_ISSUER_ID:?set ASC_ISSUER_ID}
key=~/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8
[[ -f $key ]] || { echo "no key at $key" >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "commit first: the build number comes from HEAD" >&2; exit 1; }

out=build/testflight
rm -rf $out
trap 'rm -rf build/testflight-dd' EXIT
auth=(-allowProvisioningUpdates -authenticationKeyPath $key -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID)

[[ -f Config/Domains.xcconfig ]] || cp Config/Domains.example.xcconfig Config/Domains.xcconfig
xcodegen generate -q
xcodebuild archive -project Ladle.xcodeproj -scheme Ladle -configuration Release \
  -destination 'generic/platform=iOS' -archivePath $out/Ladle.xcarchive \
  -derivedDataPath build/testflight-dd \
  CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD) $auth

cat > $out/export.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath $out/Ladle.xcarchive -exportOptionsPlist $out/export.plist \
  -exportPath $out/export $auth
echo "uploaded build $(git rev-list --count HEAD) from $(git rev-parse --short HEAD)"
