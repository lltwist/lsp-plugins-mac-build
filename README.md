# lsp-plugins-mac-build

Universal (arm64 + x86_64) macOS `.pkg` installer for
[LSP Plugins](https://lsp-plug.in/), with the macOS UI fixes that are
needed for VST3 hosts (Ableton Live etc.) on Sequoia (15.x).

## Why this exists

The official LSP Plugins repository ships a Linux-first build system.
The community macOS packaging at
[Marvo2011/lsp-macos-pkg](https://github.com/Marvo2011/lsp-macos-pkg)
produces an arm64-only `.pkg`, which is fine on Apple Silicon Macs
but does not load on Intel hosts (Ableton Live 11 etc.).

On Sequoia, the Cocoa backend in `lsp-ws-lib` (added 2025) has four
bugs that together make every LSP VST3 plug-in show a blank window
and ignore mouse input in any host. See the upstream PRs below.

This repo:

* Patches `lsp-ws-lib` with the four Cocoa fixes (pending upstream).
* Builds an x86_64 slice on an Intel Mac (no cross-compile from arm —
  brew on Apple Silicon has no x86_64 bottles for cairo/freetype, and
  LSP's `lsp-dsp-lib` ships AVX2/AVX-512 inline asm in GCC-AT&T syntax
  that Apple's clang IAS rejects; both are sidestepped here).
* Merges the two slices into a universal Mach-O via `lipo`, ad-hoc
  signs the bundle, and wraps it in a `.pkg` installer.

## What's in the installer

One file: `/Library/Audio/Plug-Ins/VST3/lsp-plugins.vst3`, a universal
bundle containing ~190 LSP VST3 plug-ins (Compressor, EQ, Multiband,
Impulse Reverb, Dynamics, Limiter, Filters, etc.).

The bundle is ad-hoc signed (Developer-ID signing requires an Apple
account). Gatekeeper will refuse the `.pkg` the first time — open it
once, dismiss the warning, then System Settings → Privacy & Security
→ "Allow Anyway" → re-open the `.pkg`.

## Quick install

Download the latest `LSP-Plugins-*-macos-universal.pkg` from the
[releases page](../../releases) and double-click.

Or, if you cloned this repo and built it yourself:

```
open LSP-Plugins-1.2.33-macos-universal.pkg
```

## Build it yourself

Prerequisites:

* An Apple Silicon Mac (for the arm64 slice).
* An Intel Mac running Sequoia 15.x with Command Line Tools 16.x (for
  the x86_64 slice), reachable via SSH or directly.
* Homebrew on both machines.

On the **arm64 Mac**:

```
git clone https://github.com/lsp-plugins/lsp-plugins.git --recursive
cd lsp-plugins
git -C modules/lsp-ws-lib apply ../../../patches/lsp-ws-lib-cocoa-ui-fix.patch
brew install make pkgconf cairo freetype libsndfile expat
gmake clean && gmake config FEATURES="vst3 ui" && gmake fetch && gmake
gmake install DESTDIR=/path/to/_staged-arm64-saved
```

On the **Intel Mac**, run `./build-on-intel-mac.sh`. It does the
clone, applies the same patch, stubs out the AVX2/AVX-512 translation
units, and produces `~/lsp-build-x86/lsp-plugins-macos-x86_64.tar.gz`.

Copy that tar back to the arm64 Mac, extract it into
`_staged-x86_64/Library/Audio/Plug-Ins/VST3/`, and run
`./merge-universal.sh`. The output is the `.pkg`.

## Files

| File | Purpose |
|---|---|
| `build-on-intel-mac.sh` | Drives the x86_64 build on an Intel Mac. Applies the Cocoa UI patch, stubs AVX2/AVX-512 (Apple clang can't assemble LSP's inline asm), and handles the CLT 16.x libc++ header path issue. |
| `merge-universal.sh` | `lipo`-merges the arm64 and x86_64 slices, ad-hoc signs the bundle (resign is mandatory after `lipo`, otherwise hosts reject it with "code has no resources but signature indicates they must be present"), and packages a `.pkg`. |
| `make-pkg.sh` | Older variant that builds a `.pkg` from `build-arm64/` and `build-x86_64/` produced manually. Kept for reference; prefer `merge-universal.sh`. |
| `patches/lsp-ws-lib-cocoa-ui-fix.patch` | Four-commit patch against `lsp-ws-lib`. Same content as the upstream PR (link below); once merged this becomes unnecessary. |

## Upstream status

* **`lsp-plugins/lsp-ws-lib` PR** — Cocoa rendering / mouse routing
  fixes (the meat of the work). When merged, the patch in `patches/`
  becomes a no-op and `build-on-intel-mac.sh` will skip it
  automatically.
* **`lsp-plugins/lsp-plugins` PR** — README updates for macOS install
  paths, brew deps, CLT 16.x quirk, codesign refresh recipe, and a
  support-matrix bump.
* **`lsp-plugins/lsp-dsp-lib`** — the AVX2 / AVX-512 inline-asm syntax
  problem is not in any PR; the stubs in `build-on-intel-mac.sh` are
  a workaround. An asm-template fix in `lsp-dsp-lib` would let Intel
  macOS use the SIMD-accelerated paths.

## Tested

* macOS 15.7.1 (Sequoia, arm64) + Ableton Live 12.4.2
* macOS 15.7.7 (Sequoia, Intel x86_64) + Ableton Live 11.0.12

Compressor, EQ x8/x16, Limiter, Multiband, Impulse Reverb, Filter
with all dropdowns, knob drags that travel outside the plug-in
window, preset save/load popups — all functional.

## License

Build scripts: WTFPL / public domain — do whatever.

The plug-ins themselves are LGPL-3.0
([lsp-plugins/lsp-plugins](https://github.com/lsp-plugins/lsp-plugins)).
The packaged `.pkg` redistributes LSP Plugins binaries under the same
license. Source for any binary in a `.pkg` here is fetched from
upstream tags at build time.
