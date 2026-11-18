#!/usr/bin/env bash
# Usage: tools/bump.sh 1.2.1   — sets the version everywhere; commit + push to release.
set -euo pipefail
cd "$(dirname "$0")/.."
V="${1:?usage: tools/bump.sh X.Y.Z}"
echo "$V" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "version must be X.Y.Z" >&2; exit 1; }
echo "$V" > VERSION
sed -i.bak -E "s|^(// @version +).*|\1$V|" web/streammkv.user.js && rm -f web/streammkv.user.js.bak
sed -i.bak -E "s|^version: .*|version: $V|" app/pubspec.yaml && rm -f app/pubspec.yaml.bak
echo "version → $V"
echo "next: git commit -am \"Release v$V\" && git push   (CI builds and publishes the release)"
