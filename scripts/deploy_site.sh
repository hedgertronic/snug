#!/usr/bin/env bash
# Stages site/, appcast.xml and the release zip into dist/, then deploys dist/ to snugshot.app with wrangler.
# Usage: scripts/deploy_site.sh [--dry-run]
# SNUG_VERSION overrides the VERSION read from scripts/build.py.
#   --dry-run  stages dist/ and runs `wrangler deploy --dry-run`, which builds the upload without sending it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

dry_run=""
case "${1:-}" in
  "") ;;
  --dry-run) dry_run="--dry-run" ;;
  *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

version="${SNUG_VERSION:-$(sed -n 's/^VERSION = "\(.*\)"$/\1/p' scripts/build.py)}"
[[ -n "$version" ]] || { echo "no VERSION in scripts/build.py" >&2; exit 1; }
archive="build/release/Snug-$version.zip"

# A real deploy needs the notarized zip and its appcast item; a dry run stages whatever is there.
if [[ -z "$dry_run" ]]; then
  [[ -f "$archive" ]] || { echo "missing $archive: run scripts/build.py --release first" >&2; exit 1; }
  grep -q "<sparkle:shortVersionString>$version<" appcast.xml || { echo "appcast.xml has no $version item" >&2; exit 1; }
fi

if [[ -e dist ]]; then trash dist; fi
mkdir dist
rsync -a --exclude '_shots' --exclude '.gitignore' --exclude '.DS_Store' site/ dist/
[[ -f appcast.xml ]] && cp appcast.xml dist/appcast.xml
[[ -f "$archive" ]] && cp "$archive" "dist/Snug-$version.zip"
printf '/download /Snug-%s.zip 302\n' "$version" > dist/_redirects

npm_config_ignore_scripts=true npx -y wrangler@4.149.0 deploy $dry_run
