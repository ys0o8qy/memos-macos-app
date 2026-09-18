#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[[ "${SKIP_BUILD:-0}" == 1 ]] || bash scripts/build-app.sh
[[ -d dist/Memos.app ]] || { echo 'Missing dist/Memos.app' >&2; exit 1; }
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' dist/Memos.app/Contents/Info.plist)"
actual_architectures="$(lipo -archs dist/Memos.app/Contents/MacOS/MemosPopup)"
case "$actual_architectures" in
  *arm64*x86_64*|*x86_64*arm64*) default_label=universal ;;
  arm64|x86_64) default_label="$actual_architectures" ;;
  *) echo 'Unexpected app architectures' >&2; exit 1 ;;
esac
label="${ARTIFACT_LABEL:-$default_label}"
[[ "$label" =~ ^[a-zA-Z0-9._-]+$ ]] || { echo 'Invalid artifact label' >&2; exit 1; }
stage="$(mktemp -d "$PWD/.build/dmg-stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
ditto dist/Memos.app "$stage/Memos.app"
ln -s /Applications "$stage/Applications"
cp docs/INSTALL.txt "$stage/安装说明.txt"
dmg="$PWD/dist/Memos-$version-$label.dmg"
hdiutil create -volname "Memos" -srcfolder "$stage" -ov -format UDZO "$dmg"
hdiutil verify "$dmg"
shasum -a 256 "$dmg" | sed "s|$PWD/dist/||" > "$dmg.sha256"
echo "Packaged: $dmg"
