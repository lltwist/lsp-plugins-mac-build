#!/bin/bash
# Run this script on an Intel macOS host.
# Output: ~/lsp-build-x86/lsp-plugins-macos-x86_64.tar.gz
# Copy it back to an arm64 host and merge with the arm64 build into
# a universal binary via lipo (see merge-universal.sh).
set -euo pipefail

WORK="${WORK:-$HOME/lsp-build-x86}"
GIT_TAG="${GIT_TAG:-1.2.33}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH="$SCRIPT_DIR/patches/lsp-ws-lib-cocoa-ui-fix.patch"
FW_PATCH="$SCRIPT_DIR/patches/lsp-plugin-fw-vst3-macos-fixes.patch"

echo "==> work dir: $WORK"
mkdir -p "$WORK"
cd "$WORK"

echo "==> checking brew (needed for deps)"
if ! command -v brew >/dev/null; then
  echo "Homebrew not installed. Install:"
  echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
  exit 1
fi

echo "==> installing deps (if missing)"
brew list make >/dev/null 2>&1 || brew install make
brew list pkg-config >/dev/null 2>&1 || brew install pkg-config
brew list cairo >/dev/null 2>&1 || brew install cairo
brew list freetype >/dev/null 2>&1 || brew install freetype
brew list libsndfile >/dev/null 2>&1 || brew install libsndfile
brew list expat >/dev/null 2>&1 || brew install expat

echo "==> cloning LSP Plugins ($GIT_TAG)"
if [ ! -d lsp-plugins ]; then
  git clone --depth 1 --branch "$GIT_TAG" --recursive \
    https://github.com/lsp-plugins/lsp-plugins.git
fi
cd lsp-plugins

echo "==> configuring (VST3 + UI)"
gmake clean 2>&1 | tail -3
SDK_CXX_INC="$(xcrun --show-sdk-path)/usr/include/c++/v1"
if [ -d "$SDK_CXX_INC" ]; then
  echo "    adding -isystem $SDK_CXX_INC (libc++ headers live inside SDK on CLT 16.x)"
  export CFLAGS="${CFLAGS:-} -isystem $SDK_CXX_INC"
  export CXXFLAGS="${CXXFLAGS:-} -isystem $SDK_CXX_INC"
fi
gmake config FEATURES="vst3 ui" 2>&1 | tail -5
gmake fetch 2>&1 | tail -3

if [ -f "$PATCH" ]; then
  echo "==> applying macOS UI patch"
  cd modules/lsp-ws-lib
  if git apply --check "$PATCH" 2>/dev/null; then
    git apply "$PATCH"
    echo "    patch applied"
  else
    echo "    patch already applied or does not match — skipping"
  fi
  cd ../..
else
  echo "WARN: patch $PATCH not found, UI will be broken in Ableton"
fi

if [ -f "$FW_PATCH" ]; then
  echo "==> applying VST3 wrapper macOS patch (no host live-resize, ignore Retina content scale)"
  cd modules/lsp-plugin-fw
  if git apply --check "$FW_PATCH" 2>/dev/null; then
    git apply "$FW_PATCH"
    echo "    patch applied"
  else
    echo "    patch already applied or does not match — skipping"
  fi
  cd ../..
else
  echo "WARN: patch $FW_PATCH not found — window will open at 200% on Retina and scaling menu will misbehave"
fi

echo "==> replacing avx2.cpp and avx512.cpp with stubs (LSP inline asm is rejected by Apple's assembler)"
DSPDIR="modules/lsp-dsp-lib/src/main/x86"
for V in avx2 avx512; do
  cat > "$DSPDIR/$V.cpp" <<EOF
// Stub for macOS Intel build — original inline asm uses GCC GAS syntax
// (e.g. "0x40 + (%%rsp)") that Apple's clang IAS/system as reject.
// Plugins fall back to scalar/SSE paths, which work fine for vocal-chain use.
#include <lsp-plug.in/common/types.h>
namespace lsp {
    namespace x86 { struct cpu_features_t; }
    namespace $V {
        void dsp_init(const lsp::x86::cpu_features_t *f) { (void)f; }
    }
}
EOF
  echo "    $V.cpp replaced with stub"
done

echo "==> building (10-20 min)"
gmake -j$(sysctl -n hw.ncpu)

echo "==> installing into local staging"
STAGED="$WORK/staged"
rm -rf "$STAGED"
mkdir -p "$STAGED"
gmake install DESTDIR="$STAGED" 2>&1 | tail -5

echo
echo "==> done."
find "$STAGED" -name "*.vst3" -type d
echo
file "$STAGED/Library/Audio/Plug-Ins/VST3/lsp-plugins.vst3/Contents/MacOS/lsp-plugins"
echo
cd "$STAGED/Library/Audio/Plug-Ins/VST3"
tar czf "$WORK/lsp-plugins-macos-x86_64.tar.gz" lsp-plugins.vst3
ls -lh "$WORK/lsp-plugins-macos-x86_64.tar.gz"
echo
echo "Archive at: $WORK/lsp-plugins-macos-x86_64.tar.gz"
echo "Ship it back to the arm64 host so merge-universal.sh can combine both slices."
