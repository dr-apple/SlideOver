#!/bin/zsh
# Neue Version veröffentlichen: ./release.sh 1.2.0
# Baut die App, erstellt ein GitHub-Release mit ZIP – installierte Apps aktualisieren sich dann selbst.
set -e
cd "$(dirname "$0")"
VERSION=${1:?Version angeben, z.B. ./release.sh 1.2.0}
echo "$VERSION" > VERSION
git add -A
git commit -m "Release v$VERSION" || true
VERSION=$VERSION ./build.sh
ZIP=build/SlideOver-$VERSION.zip
ditto -c -k --keepParent build/SlideOver.app "$ZIP"
git tag "v$VERSION"
git push origin main "v$VERSION"
gh release create "v$VERSION" "$ZIP" --title "SlideOver $VERSION" --generate-notes
echo "Release v$VERSION veröffentlicht."
