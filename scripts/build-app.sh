#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Pindo.app must be built on macOS 14+ with Xcode 15+ or its Command Line Tools." >&2
  exit 1
fi
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_dir"
app_dir="$repo_dir/dist/Pindo.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
if [[ "${PINDO_UNIVERSAL:-0}" == "1" ]]; then
  # SwiftPM 的两个架构可能共享默认产物路径，给每个架构独立的构建目录。
  arm_build="$repo_dir/.build/pindo-universal/arm64"
  intel_build="$repo_dir/.build/pindo-universal/x86_64"
  swift build -c release --product Pindo --scratch-path "$arm_build" --arch arm64 --jobs "${PINDO_BUILD_JOBS:-4}"
  arm_binary_dir="$(swift build -c release --scratch-path "$arm_build" --arch arm64 --show-bin-path)"
  swift build -c release --product Pindo --scratch-path "$intel_build" --arch x86_64 --jobs "${PINDO_BUILD_JOBS:-4}"
  intel_binary_dir="$(swift build -c release --scratch-path "$intel_build" --arch x86_64 --show-bin-path)"
  /usr/bin/lipo "$arm_binary_dir/Pindo" -verify_arch arm64
  /usr/bin/lipo "$intel_binary_dir/Pindo" -verify_arch x86_64
  /usr/bin/lipo -create "$arm_binary_dir/Pindo" "$intel_binary_dir/Pindo" -output "$app_dir/Contents/MacOS/Pindo"
  /usr/bin/lipo "$app_dir/Contents/MacOS/Pindo" -verify_arch arm64
  /usr/bin/lipo "$app_dir/Contents/MacOS/Pindo" -verify_arch x86_64
else
  swift build -c release --product Pindo --jobs "${PINDO_BUILD_JOBS:-4}"
  binary_dir="$(swift build -c release --show-bin-path)"
  cp "$binary_dir/Pindo" "$app_dir/Contents/MacOS/Pindo"
fi
cp "$repo_dir/Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "$repo_dir/Resources/Pindo.icns" "$app_dir/Contents/Resources/Pindo.icns"
for event in added deleted completed started; do
  cp "$repo_dir/Sources/Pindo/Resources/feedback-$event.wav" "$app_dir/Contents/Resources/"
done
for language in en zh-Hans; do
  translations="$repo_dir/Sources/Pindo/Resources/$language.lproj/Pindo.strings"
  /usr/bin/plutil -lint "$translations"
  mkdir -p "$app_dir/Contents/Resources/$language.lproj"
  cp "$translations" "$app_dir/Contents/Resources/$language.lproj/Pindo.strings"
done
if [[ -n "${PINDO_VERSION:-}" ]]; then
  [[ "$PINDO_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "PINDO_VERSION must be X.Y.Z" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PINDO_VERSION" "$app_dir/Contents/Info.plist"
fi
if [[ -n "${PINDO_BUILD_NUMBER:-}" ]]; then
  [[ "$PINDO_BUILD_NUMBER" =~ ^[0-9]+$ ]] || { echo "PINDO_BUILD_NUMBER must be numeric" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $PINDO_BUILD_NUMBER" "$app_dir/Contents/Info.plist"
fi
chmod +x "$app_dir/Contents/MacOS/Pindo"
/usr/bin/plutil -lint "$app_dir/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app_dir"
/usr/bin/codesign --verify --deep --strict "$app_dir"
echo "Built: $app_dir"
echo "Run: open \"$app_dir\""
