#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
"$project_dir/scripts/build-app.sh" --universal

version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$project_dir/Resources/Info.plist")
archive="$project_dir/dist/ClipboardForMac-v$version-macOS-universal.zip"
ditto -c -k --norsrc --keepParent "$project_dir/dist/ClipboardForMac.app" "$archive"
cd "$project_dir/dist"
shasum -a 256 "${archive:t}" > "${archive:t}.sha256"
print "Release archive: $archive"
