#!/bin/sh
# Installs Snug into /Applications and opens it:
#   curl -fsSL https://snugshot.app/install.sh | sh
# It downloads the notarized zip from https://snugshot.app/download, checks its signature and Gatekeeper's assessment, and copies
# Snug.app into /Applications. An installed Snug is left alone; it updates itself (Snug menu → Check for Updates).
set -eu

app=/Applications/Snug.app
team=F925RYHG3H

[ "$(uname -s)" = Darwin ] || { echo "Snug is a Mac app." >&2; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 26 ] || { echo "Snug needs macOS 26 or later; this Mac has $(sw_vers -productVersion)." >&2; exit 1; }
if [ -e "$app" ]; then
  echo "Snug is already in /Applications. It updates itself: Snug menu → Check for Updates."
  exit 0
fi

work=$(mktemp -d)
trap '/usr/bin/trash "$work" >/dev/null 2>&1 || true' EXIT
echo "Downloading Snug..."
curl -fsSL https://snugshot.app/download -o "$work/Snug.zip"
ditto -x -k "$work/Snug.zip" "$work"
codesign --verify --deep --strict "$work/Snug.app"
codesign -dv "$work/Snug.app" 2>&1 | grep -q "^TeamIdentifier=$team\$" || { echo "Snug.app is not signed by Snug's developer." >&2; exit 1; }
spctl --assess --type execute "$work/Snug.app" 2>/dev/null || { echo "Gatekeeper rejected Snug.app." >&2; exit 1; }
ditto "$work/Snug.app" "$app"
echo "Installed $app"
open "$app"
