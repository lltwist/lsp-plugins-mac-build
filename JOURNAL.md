# Project journal

A short retrospective on what this project actually turned into.

## Original ask

A friend uses Ableton Live 11 on an Intel Mac and wanted to try LSP
Plugins. The community macOS packager
([Marvo2011/lsp-macos-pkg](https://github.com/Marvo2011/lsp-macos-pkg))
ships an arm64-only `.pkg`, so it does not load on Intel hosts. Goal:
produce a single universal (arm64 + x86_64) `.pkg` that installs LSP
Plugins on both architectures.

## What we hit along the way

### 1. The macOS Cocoa UI in `lsp-ws-lib` was effectively non-functional in VST3 hosts

The Cocoa backend was added to `lsp-ws-lib` in June 2025 and works
for standalone runs, but in a VST3 plug-view inside Ableton (any
version) it had four independent bugs that, together, made the UI
blank and unresponsive:

1. `CocoaCairoView` was not layer-backed, so on Sequoia 15 AppKit
   never called `-drawRect:`.
2. `do_main_iteration()` — the thing that drives `UIE_REDRAW` →
   widget render → `ForceExpose` notification → `setNeedsDisplay:` —
   was never called, because the host-runloop hook
   (`register_run_loop()` in the VST3 wrapper) is wrapped in
   `#ifdef VST_USE_RUNLOOP_IFACE`, which is Linux-only.
3. `CocoaWindow::set_parent()` was not overridden, so the host's
   parent NSView (passed via `IPlugView::attached`) was ignored. The
   wrapper init path even added the view as a subview of
   `[pCocoaWindow contentView]`, which is the *host's* main document
   content view, not the plug-in slot.
4. `CocoaDisplay::handle_event` looked the target window up via
   `[nsevent window]`, which in embedded mode is always the host's
   NSWindow. That returned null and every mouse event was dropped.
   Even after fixing the lookup, a knob drag that travelled outside
   the embedded view would lose the target — so widgets stayed
   "grabbed" until the user clicked elsewhere.

Fixes for all four are in `patches/lsp-ws-lib-cocoa-ui-fix.patch`
and as the upstream PR
[`fix/cocoa-vst3-embedded-ui`](https://github.com/lltwist/lsp-ws-lib/tree/fix/cocoa-vst3-embedded-ui).

### 2. `lsp-dsp-lib` does not assemble under Apple's clang

The AVX2 and AVX-512 translation units in `lsp-dsp-lib` use GCC AT&T
inline-asm operands like `0xe0 + (%rsp)` (an arithmetic expression on
top of a register-indirect memory operand). GCC's gas accepts this
and folds it into `0xe0(%rsp)`; Apple's clang IAS (and the system
`as` it wraps) rejects it with "expected relocatable expression".
`-fno-integrated-as` does not help, since system `as` re-enters
clang IAS internally.

Workaround in `build-on-intel-mac.sh`: replace `avx2.cpp` and
`avx512.cpp` with stubs whose `dsp_init()` is a no-op. The dispatch
in `x86.cpp` keeps calling them, the linker is happy, and the
plug-ins fall back to scalar / SSE paths. For vocal-chain use this
is invisible. A proper fix belongs in `lsp-dsp-lib`'s asm templates
and is out of scope for this project.

### 3. Apple's Command Line Tools 16.x moved libc++ headers

On a fresh Sequoia + CLT 16.4 install, `clang++ -v` looks for the
libc++ headers in
`/Library/Developer/CommandLineTools/usr/include/c++/v1/`, but
that directory is empty — the actual headers live in
`$(xcrun --show-sdk-path)/usr/include/c++/v1/`. `#include <thread>`
fails until you point clang at the right place with
`-isystem $(xcrun --show-sdk-path)/usr/include/c++/v1`. The
`build-on-intel-mac.sh` script exports this for `CXXFLAGS` and
`CFLAGS` before configuring.

### 4. Bundles fail signature verification after `lipo`

If you `lipo` two `.vst3` bundles together and don't re-sign, the
`_CodeSignature/CodeResources` manifest no longer matches the bundle
contents. `codesign --verify` fails with "code has no resources but
signature indicates they must be present", and Ableton's plug-in
scanner silently drops the bundle. Fix is to refresh the ad-hoc
signature:

```
codesign --remove-signature <bundle>.vst3
codesign --force --deep --sign - <bundle>.vst3
```

Both this and the lipo step are baked into `merge-universal.sh`.

## What got published

* This repo: the build scripts (`build-on-intel-mac.sh`,
  `merge-universal.sh`), the patch, and the README.
* GitHub release: a built
  [`LSP-Plugins-1.2.33-macos-universal.pkg`](https://github.com/lltwist/lsp-plugins-mac-build/releases/tag/v1.2.33).
* Upstream PR to
  [`lsp-plugins/lsp-ws-lib`](https://github.com/lsp-plugins/lsp-ws-lib)
  with the four Cocoa fixes (Linux untouched, all changes inside
  `#ifdef PLATFORM_MACOSX`).
* Upstream PR to
  [`lsp-plugins/lsp-plugins`](https://github.com/lsp-plugins/lsp-plugins)
  documenting macOS install paths, brew deps, CLT 16.x quirk, the
  codesign-refresh recipe, and bumping the support matrix for
  aarch64-macOS (E → F) and x86_64-macOS (U → E).

## Tested

* macOS 15.7.1 (Sequoia, arm64, MacBook Pro M1 Max) + Ableton Live
  12.4.2 + universal `.pkg` → arm64 slice.
* macOS 15.7.7 (Sequoia, Intel x86_64) + Ableton Live 11.0.12 +
  universal `.pkg` → x86_64 slice.

Compressor, EQ x8/x16, Limiter, Multiband, Impulse Reverb, Filter
dropdowns, preset save/load popups, knob drags that travel outside
the plug-in view — all functional on both architectures.
