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

### 6. Upstream merges (2026-06-30 to 2026-07-01)

- **lsp-ws-lib PR #6 merged into `devel` on 2026-06-30 by @sadko4u.**
  Before merging, sadko4u suggested a cleaner shape for the redraw
  path: instead of a per-view `NSTimer` plus proxy, own a single
  60 Hz tick on `CocoaDisplay` and dispatch redraws to registered
  windows from there. Implemented that as an 8th commit
  (`81f07cc refactor(cocoa): own redraw tick on CocoaDisplay, drop
  per-view NSTimer`), which also lets `CocoaWindow::destroy()` and
  `CocoaDisplay::destroy()` drop the earlier defensive stop-timer
  passes. CHANGELOG on `devel` now credits the contribution to
  `lltwist`.

- **lsp-dsp-lib AVX2/AVX-512 asm rejection filed as
  [lsp-plugins/lsp-dsp-lib#24](https://github.com/lsp-plugins/lsp-dsp-lib/issues/24)**
  with a reproducer on Intel Sequoia + Apple clang 17. sadko4u
  turned it around fast: rewrote `lanczos.h` inline-asm to use
  plain `0xN(%[memOp])` operand forms instead of `0xN + %[memOp]`
  arithmetic, pushed to branch `github-issue-24`, then merged to
  `devel` on 2026-07-01. Verified clean build on both Intel and
  Apple Silicon before confirming. Once a new upstream release
  ships with these commits, the avx2/avx512 stubs baked into
  `build-on-intel-mac.sh` can be dropped and AVX code paths turned
  back on for Intel Mac users.

- **lsp-plugins docs PR #637 still open.** Support matrix currently
  shows `E` for both `aarch64` and `x86_64` on the macOS column
  (matches sadko4u's ask); waiting on merge from his side.

- **Resize investigation.** Also tried to plug the REAPER-only
  embedded resize bug (host frame drag stretches/clips the plug-in
  UI). Hooked `-setFrameSize:` on `CocoaCairoView` to emit
  `UIE_RESIZE` so `pSurface` gets recreated, which worked, but the
  widget framework's `Window::UIE_RESIZE` handler then loops back
  through `CocoaWindow::set_geometry()` and calls
  `[[pCocoaView window] setFrame: animate:NO]` at the framework's
  preferred size — in embedded mode `[pCocoaView window]` is the
  host NSWindow, so the framework kept shoving the view back to its
  original size. The ping-pong is visible cleanly in the logs
  (`951×551 → 944×548 → 951×551`). Rolled the prototype back rather
  than ship half-working; captured the finding in the PR comment as
  a follow-up item. Ableton doesn't expose the FX-panel resize
  handle so users hit the in-plug-in `MENU → Scaling` control
  instead and it "just works" there.

### 7. Embedded resize / scaling overhaul (2026-07-02)

Took another run at the REAPER resize follow-up. Direction changed
along the way (agreed with the user): instead of adaptive host-drag
resize, adopt the **Ableton model** — the embedded view is fixed-size,
all size changes are plug-in-initiated via `MENU → Scaling` →
`IPlugFrame::resizeView`, and host live-resize is declined.

Root causes found (each one produced its own broken build during
testing; logs captured by launching REAPER from a pty and NSLog
tracing):

1. **`bWrapper` is FALSE in VST3 hosted mode.** The plug-in window is
   created via `create_window()` and only becomes embedded later when
   `IPlugView::attached()` → `set_parent()` reparents the view into
   the host's slot NSView. Any "embedded" logic keyed on `bWrapper`
   silently never ran. The correct discriminator is
   `pCocoaParentView != nil`.

2. **`set_geometry()` resized the host's NSWindow.** In embedded mode
   `[pCocoaView window]` is the host FX window; driving it from the
   plug-in violates the VST3 geometry contract and produced the
   `951 → 944 → 951` ping-pong. Now: embedded `set_geometry()` sizes
   only our subview + cairo surface, then emits `UIE_RESIZE` to the
   tk handler for re-layout; the host window is never touched.

3. **`update_window_hints()` set `contentMin/MaxSize` on the host
   window.** REAPER's FX window content = plug-in view + 392×284 of
   REAPER chrome (sidebar/toolbars). Clamping the host window content
   to the view size ratcheted the window by exactly +392×+284 per
   resize round-trip until it outgrew the screen. Embedded mode now
   never touches host window size hints.

4. **`get_absolute_geometry()` reported the (stale) host slot size.**
   `slot_ui_resize` in the VST3 wrapper reads this rectangle and
   passes it to `resizeView` — so scaling asked the host for the size
   it already had, and the FX window never followed `MENU → Scaling`.
   Embedded mode now reports origin-from-slot + size-from-`sSize`.

5. **Retina content-scale treated as UI zoom.** REAPER calls
   `setContentScaleFactor(2.0)` on HiDPI; the wrapper stored it as a
   200 % scaling override, so "Default" scale opened the window at
   double size (beyond the screen — which also pushed the scaling
   submenu off-screen, making it look broken). On macOS this factor
   is the backing ratio, already handled by AppKit; it is now ignored
   (`#ifdef PLATFORM_MACOSX` in `setContentScaleFactor`).

Supporting changes: `CocoaWindow::show()` asserts OUR size to the
host right after `UIE_SHOW` (tk must be mapped for `UIE_RESIZE` to
be processed — emitting earlier gets dropped): the emitted
`UIE_RESIZE` fires tk `SLOT_RESIZE`, the VST3 wrapper turns it into
`resizeView`, and the host sizes its slot to the plug-in layout.
This deliberately does NOT adopt the host slot size — an earlier
adopt-the-slot variant faithfully inherited the garbage FX-window
size REAPER had remembered from the ratchet-era sessions (opening
"full screen" with a stretched layout, and pushing the bottom-bar
scaling popup off-screen, which made it look like the menu did not
open). A `NSViewFrameDidChangeNotification` observer on the slot
view follows host-applied resizes (`resizeView` confirmations);
`canResize()` returns `kResultFalse` on macOS so hosts treat the
view as fixed-size. REAPER's own FX window frame stays
user-resizable (that's REAPER chrome, not ours) — dragging it
crops/letterboxes the fixed view, same as any fixed-size VST3
there, and the next FX-window open snaps back to the correct size.

Verified in REAPER 7.75 (arm64, live log trace): opens at the
layout size at the current scaling (stale host-remembered sizes
purged), `MENU → Scaling` converges in a single
`set_geometry` ↔ `slot frame changed` round-trip in both
directions, no ping-pong, no ratchet, FX open/close cycles clean,
"Default" scale = 100 %, bottom-bar scaling popups open on-screen.

The changes live in two patches now:
`patches/lsp-ws-lib-cocoa-ui-fix.patch` (base `1.2.33`, includes the
seven merged PR #6 fixes + redraw-tick refactor + this) and
`patches/lsp-plugin-fw-vst3-macos-fixes.patch` (base `1.0.38`:
`canResize` + `setContentScaleFactor`), both applied by
`build-on-intel-mac.sh`. Still to do: Ableton re-check on both
arches, then upstream PRs (`lsp-ws-lib` on top of `devel` post-#6,
new `lsp-plugin-fw` PR).

## Upstream status (as of 2026-07-02)

| Change | Upstream repo | Status |
| --- | --- | --- |
| Cocoa VST3 embedded UI (8 commits) | `lsp-plugins/lsp-ws-lib` PR #6 | **merged** into `devel` on 2026-06-30 |
| AVX2/AVX-512 asm fix on Intel macOS | `lsp-plugins/lsp-dsp-lib` issue #24 | **merged** into `devel` on 2026-07-01 |
| macOS README (paths, brew, CLT quirk, codesign) | `lsp-plugins/lsp-plugins` PR #637 | open, waiting on merge |
| Cocoa VST3 embedded resize/scaling overhaul (5 root causes) | `lsp-plugins/lsp-ws-lib` | local patch — verified in REAPER 7.75 arm64; pending Ableton re-check + new PR |
| VST3 macOS: no host live-resize, ignore Retina content scale | `lsp-plugins/lsp-plugin-fw` | local patch — verified in REAPER 7.75 arm64; pending Ableton re-check + new PR |

Once a new upstream release tag ships that includes these three
merges, the downstream mac-build here can bump `GIT_TAG` and drop
the local `patches/lsp-ws-lib-cocoa-ui-fix.patch` and the
`avx2.cpp` / `avx512.cpp` stub logic in `build-on-intel-mac.sh`.

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
