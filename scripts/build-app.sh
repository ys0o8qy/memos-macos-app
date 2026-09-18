#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/swift-env.sh

configuration="${CONFIGURATION:-release}"
architectures="${ARCHS:-arm64 x86_64}"
version="${VERSION:-0.1.0}"
build_number="${BUILD_NUMBER:-1}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'VERSION must be x.y.z' >&2; exit 1; }
[[ "$build_number" =~ ^[0-9]+$ ]] || { echo 'BUILD_NUMBER must be numeric' >&2; exit 1; }
mkdir -p dist .build
app="$PWD/dist/Memos.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
binaries=()
for architecture in $architectures; do
  [[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || { echo 'Unsupported architecture' >&2; exit 1; }
  scratch="$PWD/.build/package-$architecture"
  swift build --disable-sandbox --configuration "$configuration" --arch "$architecture" --scratch-path "$scratch"
  bin_dir="$(swift build --disable-sandbox --configuration "$configuration" --arch "$architecture" --scratch-path "$scratch" --show-bin-path)"
  binaries+=("$bin_dir/MemosPopup")
done
if [[ ${#binaries[@]} -eq 1 ]]; then
  cp "${binaries[0]}" "$app/Contents/MacOS/MemosPopup"
else
  lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/MemosPopup"
fi
cp Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$app/Contents/Info.plist"
swift scripts/make-icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
plutil -lint "$app/Contents/Info.plist"
lipo -info "$app/Contents/MacOS/MemosPopup"
echo "Built: $app"
