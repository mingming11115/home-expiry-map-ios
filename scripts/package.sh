#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
xcodebuild_bin="$DEVELOPER_DIR/usr/bin/xcodebuild"
archive_path="$project_dir/dist/ExpiryMap.xcarchive"
export_path="$project_dir/dist/export"

bash "$project_dir/scripts/generate-app-icons.sh"
"$xcodebuild_bin" -project "$project_dir/ExpiryMap.xcodeproj" -scheme ExpiryMap \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$project_dir/build-native" -archivePath "$archive_path" \
  -allowProvisioningUpdates "$@" archive
"$xcodebuild_bin" -exportArchive -archivePath "$archive_path" \
  -exportPath "$export_path" \
  -exportOptionsPlist "$project_dir/scripts/ExportOptions.plist" \
  -allowProvisioningUpdates
printf 'Development IPA: %s/ExpiryMap.ipa\n' "$export_path"
