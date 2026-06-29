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

### 5. After PR review and REAPER testing: lifecycle crashes + missing popup grab

On the upstream `lsp-ws-lib` PR review pass — and after installing
REAPER 7.75 to verify the fixes outside Ableton — three additional
problems surfaced:

1. **SIGSEGV in `-[CocoaCairoView triggerRedraw]` on FX-window
   reopen.** The redraw `NSTimer` was scheduled with `target:self`,
   so it retained the view. The view in turn retained the timer via
   a strong property — a classic retain cycle. The view's `-dealloc`
   never ran, so `-stopRedrawLoop` was never called, and the timer
   kept firing past the lifetime of the `CocoaDisplay` it pointed
   at. Easiest repro: open a `MENU` popup, close the FX window with
   the red close button.

2. **Popup widgets (`Menu`, `ComboBox`, `Fraction` dropdown) did
   not close on outside click.** The cocoa backend left
   `IWindow::grab_events` / `ungrab_events` /
   `is_grabbing_events` unimplemented, so the widget framework had
   no way to learn about clicks outside the popup's view bounds.
   The X11 / Win backends use real protocol-level grabs
   (`XGrabPointer`, `WH_MOUSE_LL`); macOS has no equivalent, so we
   approximated it with `[NSEvent addLocalMonitorForEventsMatching
   Mask:]` — the plug-in installs a mouse-down monitor into the
   host's `NSApp`, and on a click outside any grabbing popup we
   synthesize a `UIE_MOUSE_DOWN` at popup-local coords and dispatch
   directly to the topmost grabbing window. The original event is
   not consumed, so the host's chrome (e.g. the FX-window close
   button) still receives the click while a popup is open.

3. **Popup `CocoaWindow`s the framework doesn't explicitly
   `destroy()`.** Defense in depth: `CocoaWindow::destroy()` now
   force-stops the view timer and clears its `display` back-pointer
   before releasing the view, and `CocoaDisplay::destroy()` does
   the same pass over `vWindows` for orphaned popups left over at
   plug-in teardown.

Three more commits on the `fix/cocoa-vst3-embedded-ui` branch
(`f80ff9d`, `ab1ebbb`, `f8abdbb`), bringing the PR total to seven.

While here, the review also pointed out that the original PR was
too bold in promoting aarch64-macOS to `F` in the support matrix
(we still depend on `cairo` + `freetype` from brew rather than a
native `quartz2d` backend, and there are no official builds). The
upgrade was reverted to `E` in `f0152f6` on the docs PR; native
`quartz2d` mirroring the Windows `Direct2D` backend is a natural
follow-up task once this lands.

## What got published

* This repo: the build scripts (`build-on-intel-mac.sh`,
  `merge-universal.sh`), the patch, and the README.
* GitHub releases:
  * [`v1.2.33`](https://github.com/lltwist/lsp-plugins-mac-build/releases/tag/v1.2.33)
    — initial universal `.pkg` (the four original Cocoa fixes).
  * [`v1.2.33-r2`](https://github.com/lltwist/lsp-plugins-mac-build/releases/tag/v1.2.33-r2)
    — rebuild with the three additional fixes from section 5
    (retain-cycle, grab, teardown). Same upstream tag, same .pkg
    name; supersedes r1 for normal users, r1 is kept for rollback.
* Upstream PR
  [`lsp-plugins/lsp-ws-lib#6`](https://github.com/lsp-plugins/lsp-ws-lib/pull/6)
  with the seven Cocoa fixes (Linux untouched, all changes inside
  `#ifdef PLATFORM_MACOSX`).
* Upstream PR
  [`lsp-plugins/lsp-plugins#637`](https://github.com/lsp-plugins/lsp-plugins/pull/637)
  documenting macOS install paths, brew deps, CLT 16.x quirk, the
  codesign-refresh recipe, and bumping the support matrix for
  x86_64-macOS (U → E); aarch64-macOS stays at `E`.

## Tested

* macOS 15.7.1 (Sequoia, arm64, MacBook Pro M1 Max) + Ableton Live
  12.4.2 + REAPER 7.75 + universal `.pkg` → arm64 slice.
* macOS 15.7.7 (Sequoia, Intel x86_64) + Ableton Live 11.0.12 +
  REAPER 7.75 + universal `.pkg` → x86_64 slice.

Compressor, EQ x8/x16, Limiter, Multiband, Impulse Reverb, Noise
Generator, Profiler, Phaser, Filter dropdowns, preset save/load
popups, knob drags that travel outside the plug-in view, popup
outside-click close, plug-in chains on the same track, open/close
cycles of the FX window — all functional on both architectures.
