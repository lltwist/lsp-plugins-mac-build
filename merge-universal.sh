#!/bin/bash
# Merge arm64 and x86_64 LSP Plugins builds into a universal binary via lipo,
# then wrap into a macOS .pkg installer.
#
# Expects:
#   _staged-arm64-saved/Library/Audio/Plug-Ins/VST3/lsp-plugins.vst3
#   _staged-x86_64/Library/Audio/Plug-Ins/VST3/lsp-plugins.vst3
#
# Produces:
#   LSP-Plugins-1.2.33-macos-universal.pkg

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ARM="$HERE/_staged-arm64-saved/Library/Audio/Plug-Ins/VST3/lsp-plugins.vst3"
X86="$HERE/_staged-x86_64/Library/Audio/Plug-Ins/VST3/lsp-plugins.vst3"
OUT_PARENT="$HERE/_staged-universal/Library/Audio/Plug-Ins/VST3"
OUT_BUNDLE="$OUT_PARENT/lsp-plugins.vst3"
PKG="$HERE/LSP-Plugins-1.2.33-macos-universal.pkg"

[ -d "$ARM" ] || { echo "missing arm64 bundle: $ARM"; exit 1; }
[ -d "$X86" ] || { echo "missing x86_64 bundle: $X86"; exit 1; }

echo "==> base from arm64 (sharing Info.plist + Resources)"
rm -rf "$HERE/_staged-universal"
mkdir -p "$OUT_PARENT"
cp -R "$ARM" "$OUT_BUNDLE"

echo "==> merging Mach-O binaries with lipo"
lipo -create \
  "$ARM/Contents/MacOS/lsp-plugins" \
  "$X86/Contents/MacOS/lsp-plugins" \
  -output "$OUT_BUNDLE/Contents/MacOS/lsp-plugins"
echo
file "$OUT_BUNDLE/Contents/MacOS/lsp-plugins"
ls -lh "$OUT_BUNDLE/Contents/MacOS/lsp-plugins"

echo
echo "==> ad-hoc codesign (so Gatekeeper lets Ableton load it)"
codesign --remove-signature "$OUT_BUNDLE" 2>/dev/null || true
codesign --force --deep --sign - "$OUT_BUNDLE"
codesign --verify --verbose=2 "$OUT_BUNDLE"

echo
echo "==> packaging into .pkg installer"
pkgbuild \
  --root "$HERE/_staged-universal" \
  --identifier in.lsp-plug.LSPPlugins \
  --version 1.2.33 \
  --install-location "/" \
  "$PKG"

echo
echo "Done: $PKG"
ls -lh "$PKG"
echo
echo "Install:  open '$PKG'"
echo "Or CLI:   sudo installer -pkg '$PKG' -target /"
