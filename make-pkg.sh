#!/bin/bash
# Собирает macOS installer .pkg из готовых VST3-бандлов LSP Plugins.
# Ожидает что arm64 и x86_64 сборки уже сделаны в build-arm64/ и build-x86_64/,
# либо запускается с одной из них (universal lipo если есть обе).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD_ARM="$HERE/build-arm64"
BUILD_X86="$HERE/build-x86_64"
UNI="$HERE/build-universal"
OUTPKG="$HERE/LSP-Plugins-universal.pkg"
VERSION="1.2.33"
IDENTIFIER="in.lsp-plug.LSPPlugins"

rm -rf "$UNI" && mkdir -p "$UNI/Library/Audio/Plug-Ins/VST3"

# Find VST3 bundles in the build dirs
copy_bundles() {
  local src="$1"
  if [ ! -d "$src" ]; then return 0; fi
  find "$src" -name "*.vst3" -type d -maxdepth 6 | while read bundle; do
    cp -R "$bundle" "$UNI/Library/Audio/Plug-Ins/VST3/"
  done
}

# Prefer arm64 as base
copy_bundles "$BUILD_ARM"
# If there are x86_64 binaries that don't exist in arm64, copy them too
copy_bundles "$BUILD_X86"

# If both architectures exist, lipo-merge the binaries into universal
if [ -d "$BUILD_ARM" ] && [ -d "$BUILD_X86" ]; then
  echo "Merging arm64 + x86_64 with lipo..."
  find "$UNI/Library/Audio/Plug-Ins/VST3" -type d -name "*.vst3" | while read uni_bundle; do
    name=$(basename "$uni_bundle" .vst3)
    arm_bin=$(find "$BUILD_ARM" -path "*/${name}.vst3/Contents/MacOS/*" -type f | head -1)
    x86_bin=$(find "$BUILD_X86" -path "*/${name}.vst3/Contents/MacOS/*" -type f | head -1)
    target_bin=$(find "$uni_bundle/Contents/MacOS" -type f | head -1)
    if [ -n "$arm_bin" ] && [ -n "$x86_bin" ] && [ -n "$target_bin" ]; then
      lipo -create "$arm_bin" "$x86_bin" -output "$target_bin"
      echo "  $name → universal"
    fi
  done
fi

echo "==> building .pkg installer"
pkgbuild \
  --root "$UNI" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location "/" \
  "$OUTPKG"

echo
echo "Done: $OUTPKG"
ls -la "$OUTPKG"
