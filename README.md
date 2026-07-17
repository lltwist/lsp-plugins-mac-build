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

On Sequoia, the Cocoa backend in `lsp-ws-lib` (added 2025) had a
series of bugs that made every LSP VST3 plug-in show a blank window,
ignore mouse input, misplace popups and misbehave on window resize
and on Retina displays. See the upstream PRs below.

This repo:

* Patches `lsp-ws-lib` and `lsp-plugin-fw` with the macOS fixes
  (partially merged upstream, the rest is pending review).
* Builds an x86_64 slice on an Intel Mac (no cross-compile from arm:
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
account). Gatekeeper will refuse the `.pkg` the first time: open it
once, dismiss the warning, then System Settings > Privacy & Security >
"Allow Anyway", and re-open the `.pkg`.

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
git -C modules/lsp-plugin-fw apply ../../../patches/lsp-plugin-fw-vst3-macos-fixes.patch
brew install make pkgconf cairo freetype libsndfile expat
gmake clean && gmake config FEATURES="vst3 ui" && gmake fetch && gmake
gmake install DESTDIR=/path/to/_staged-arm64-saved
```

On the **Intel Mac**, run `./build-on-intel-mac.sh`. It does the
clone, applies both patches, stubs out the AVX2/AVX-512 translation
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
| `patches/lsp-ws-lib-cocoa-ui-fix.patch` | Cocoa UI patch against `lsp-ws-lib` (base `1.2.33`): the seven merged PR #6 fixes, the display-owned redraw tick, and the embedded resize/scaling overhaul. |
| `patches/lsp-plugin-fw-vst3-macos-fixes.patch` | VST3 wrapper patch against `lsp-plugin-fw`: correct the host content scale factor by the display backing scale (on Retina hosts report 2.0, which is a pixel ratio, not a UI zoom). |

## Upstream status

* [`lsp-ws-lib#6`](https://github.com/lsp-plugins/lsp-ws-lib/pull/6),
  Cocoa rendering / mouse routing / popup and lifecycle fixes: merged
  into `devel`.
* [`lsp-ws-lib#7`](https://github.com/lsp-plugins/lsp-ws-lib/pull/7),
  embedded window geometry, live resize, popup placement: open.
* [`lsp-plugin-fw#16`](https://github.com/lsp-plugins/lsp-plugin-fw/pull/16),
  HiDPI content scale correction: open.
* [`lsp-plugins#637`](https://github.com/lsp-plugins/lsp-plugins/pull/637),
  macOS build/install docs: open.
* `lsp-dsp-lib` AVX2/AVX-512 inline-asm rejection on Apple clang:
  fixed upstream via
  [issue #24](https://github.com/lsp-plugins/lsp-dsp-lib/issues/24),
  merged into `devel`. Until a release tag ships it, the stubs in
  `build-on-intel-mac.sh` stay and Intel macOS uses scalar/SSE paths.

Once a new upstream release contains all of the above, the patches in
`patches/` become no-ops (the build script skips them automatically)
and the AVX stubs can be dropped.

## Tested

* macOS 15.7 (Sequoia, arm64) + Ableton Live 12.4.2 + REAPER 7.75
* macOS 15.7.7 (Sequoia, Intel x86_64) + Ableton Live 11.0.12 + REAPER 7.75

Compressor, EQ x8/x16, Limiter, Multiband, Impulse Reverb, Filter
with all dropdowns, knob drags that travel outside the plug-in
window, preset save/load popups, live FX-window resize in REAPER,
UI scaling menu with correct 100% default on Retina displays.

## License

Build scripts: WTFPL / public domain, do whatever.

The plug-ins themselves are LGPL-3.0
([lsp-plugins/lsp-plugins](https://github.com/lsp-plugins/lsp-plugins)).
The packaged `.pkg` redistributes LSP Plugins binaries under the same
license. Source for any binary in a `.pkg` here is fetched from
upstream tags at build time.
