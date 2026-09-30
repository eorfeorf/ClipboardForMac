#!/bin/zsh
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

app_path="$project_dir/dist/ClipboardForMac.app"
mkdir -p "$app_path/Contents/MacOS"

case "${1:-}" in
    "")
        swift build --configuration release
        cp "$project_dir/.build/release/ClipboardForMac" "$app_path/Contents/MacOS/ClipboardForMac"
        ;;
    --universal)
        for arch in arm64 x86_64; do
            swift build --configuration release \
                --triple "$arch-apple-macosx14.0" \
                --scratch-path "$project_dir/.build/$arch"
        done
        lipo -create \
            "$project_dir/.build/arm64/arm64-apple-macosx/release/ClipboardForMac" \
            "$project_dir/.build/x86_64/x86_64-apple-macosx/release/ClipboardForMac" \
            -output "$app_path/Contents/MacOS/ClipboardForMac"
        ;;
    *)
        print -u2 "Usage: $0 [--universal]"
        exit 2
        ;;
esac

cp "$project_dir/Resources/Info.plist" "$app_path/Contents/Info.plist"
codesign --force --sign - "$app_path"

print "App created: $app_path"
