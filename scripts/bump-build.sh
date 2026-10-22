#!/bin/bash
# Increments CURRENT_PROJECT_VERSION in project.yml and regenerates the Xcode project.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_YML="$ROOT/project.yml"

current=$(grep -E '^\s*CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | grep -oE '[0-9]+')

if [[ "${1:-}" == "--print" ]]; then
    echo "$current"
    exit 0
fi

next=$((current + 1))
# BSD sed (macOS) in-place edit.
sed -i '' -E "s/^([[:space:]]*CURRENT_PROJECT_VERSION:)[[:space:]]*[0-9]+/\1 $next/" "$PROJECT_YML"

cd "$ROOT"
xcodegen generate >/dev/null

echo "Build $current → $next"
echo "Now add the build $next entry to CHANGELOG.md before installing."
