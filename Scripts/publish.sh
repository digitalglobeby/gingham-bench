#!/bin/zsh
# Publishes the bench (the maintainer, after review): creates the public repository
# digitalglobeby/gingham-bench, pushes main, and makes release v1.0 with the notarized Mac app
# (Scripts/release.sh makes it). Needs `gh` signed in with rights on the digitalglobeby org.
#
#   Scripts/publish.sh
set -e
cd "$(dirname "$0")/.."
REPO=digitalglobeby/gingham-bench
VERSION=$(awk '/MARKETING_VERSION:/ { gsub(/"/, "", $2); print $2; exit }' Mac/project.yml)
ZIP="release/GinghamBench-$VERSION.zip"
[[ -f "$ZIP" && -f "$ZIP.sha256" ]] || { echo "✗ no $ZIP: run Scripts/release.sh first"; exit 1 }
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "✗ uncommitted changes"; exit 1 }
[[ "$(git branch --show-current)" == main ]] || { echo "✗ not on main"; exit 1 }

# The repository, public, with this one as its origin; main pushed.
gh repo create "$REPO" --public \
  --description "An open benchmark of Gingham, NSTableView, NSCollectionView and SwiftUI Table on live data (Mac, iPhone, iPad)" \
  --homepage "https://github.com/digitalglobeby/Gingham" --source . --remote origin --push

# The release: the notarized app and its checksum.
NOTES=$(mktemp)
cat > "$NOTES" <<NOTES
Gingham Bench $VERSION for the Mac: signed with Developer ID and notarized; macOS 14 or later on Apple
silicon. Unzip it and open Gingham Bench, or run it from the command line (see the README).

SHA-256: $(cut -d' ' -f1 "$ZIP.sha256")
NOTES
gh release create "v$VERSION" "$ZIP" "$ZIP.sha256" -R "$REPO" --title "Gingham Bench $VERSION" --notes-file "$NOTES" --target main
rm -f "$NOTES"
echo "✓ https://github.com/$REPO (release v$VERSION)"
