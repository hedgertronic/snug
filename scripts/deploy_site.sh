#!/usr/bin/env bash
# Stages site/ and appcast.xml into dist/, with /download redirecting to the version's zip on its GitHub release (so GitHub counts every
# download: the site's button, install.sh, Homebrew and Sparkle updates), then deploys dist/ to snugshot.app with wrangler.
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
zip_url="https://github.com/hedgertronic/snug/releases/download/v$version/Snug-$version.zip"

# A real deploy needs the version's zip on its GitHub release and its appcast item; a dry run stages whatever is there.
if [[ -z "$dry_run" ]]; then
  curl -fsIL -o /dev/null "$zip_url" || { echo "no $zip_url: create the v$version GitHub release with the zip first" >&2; exit 1; }
  grep -q "<sparkle:shortVersionString>$version<" appcast.xml || { echo "appcast.xml has no $version item" >&2; exit 1; }
fi

if [[ -e dist ]]; then trash dist; fi
mkdir dist
rsync -a --exclude '_shots' --exclude '.gitignore' --exclude '.DS_Store' site/ dist/
# The page names its stylesheet and script by content, so a browser never pairs a new page with an old cached style.css or snug.js.
for asset in style.css snug.js; do
  hash="$(shasum -a 256 "dist/$asset" | cut -c1-12)"
  grep -q "\"$asset\"" dist/index.html || { echo "dist/index.html does not link $asset" >&2; exit 1; }
  sed -i '' "s|\"$asset\"|\"$asset?v=$hash\"|" dist/index.html
done
[[ -f appcast.xml ]] && cp appcast.xml dist/appcast.xml
printf '/download %s 302\n' "$zip_url" > dist/_redirects

npm_config_ignore_scripts=true npx -y wrangler@4.149.0 deploy $dry_run
