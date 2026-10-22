#!/bin/bash
# Archive for distribution, where Xcode can actually find it.
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD=$(grep 'CURRENT_PROJECT_VERSION:' project.yml | head -1 | awk '{print $2}')
DEST="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
ARCHIVE="$DEST/Plevi $BUILD.xcarchive"

if [ -e "$ARCHIVE" ]; then
    echo "There is already an archive for build $BUILD today:"
    echo "  $ARCHIVE"
    echo "Bump the build number first, or remove that one."
    exit 1
fi

mkdir -p "$DEST"
echo "Archiving build $BUILD…"
xcodebuild archive \
    -project Plevi.xcodeproj \
    -scheme Plevi \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    | grep -E '^\*\*|error:' || true

[ -d "$ARCHIVE" ] || { echo "No archive was written."; exit 1; }

echo
echo "$ARCHIVE"
for key in CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
    printf '  %-28s %s\n' "$key" \
        "$(/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:$key" "$ARCHIVE/Info.plist")"
done
echo
echo "It is in Xcode → Window → Organizer → Archives."
