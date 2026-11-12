# Safari pages blank on macOS 27 (2026-11-12)

Branch `claude/project-thread-up72g7`, commit bd8436f (on fork main a0f5801). Duo test build: worktree `duo-test-safari` (= duo-test-ce 4072e18 + bd8436f, merge 1849e89).

## What was already known
- README and Installer.swift: "Safari's pages may stay blank" on 27 (upstream, iPhone 17 Pro).
- macOS 27's WebKit draws page tiles into `b3a8` IOSurfaces (kCVPixelFormatType_30RGBLE_8A_BiPlanar: plane 0 RGB 10-10-10, plane 1 8-bit alpha) in its GPU process; WindowServer composites them. Upstream fixed two earlier causes: views honour the plane index (332f548) and mappings of the same guest memory share one host IOSurface (d3bb8ba).
- Duo logs on this Mac (prof-2026-11-12, agx-102-results) never loaded a real web page: only the Start Page, which renders (prof-2026-11-12/r1-safari.jpg). They show 352x352 b3a8 surfaces at boot, never a "shares the host surface" line, and never a view on plane 1.

## Root cause (from the code; not yet reproduced on a device)
Multi-plane surfaces were the only surfaces not drawn in place. A one-plane surface's textures sit on a buffer that aliases the guest's pages (vm_remap), so the GPU's output is in guest memory. A multi-plane surface got a separate host IOSurface. Guest pages were copied in when a sampled hash changed (sync_iosurface), and nothing ever copied the GPU's output back: `synchronize` and `page:toGuest:` cover only guest_backed objects. So the pixels WebKit's GPU process drew existed only in that host copy, and they were lost when:
1. the last mapping of the surface went (`hv_pvg_metal_unmap` drops the planar entry): the next mapping of the same tile, by WindowServer or the GPU process again, got a new host IOSurface filled from guest pages that were never drawn. Alpha plane 0 means a fully transparent tile, a blank page. Tiles are mapped and unmapped per process as WebKit recycles them;
2. the 512-entry planar table was emptied;
3. any guest CPU write to a plane changed its hash, and the stale guest bytes were copied over the GPU's drawing (suspect a);
4. a CPU-side reader (IOSurfaceLock in the guest) looked at the guest pages (suspect b).
The sampled hash (suspect c) only decides when guest pixels get copied in, and with the fix those copies don't happen for views on the pages. The plane layout (suspect d) matched in the Duo logs: plane 0 at 0, rows of 1536 bytes, 352 rows; plane 1 at 540672, rows of 512 bytes. Host rows and heights were identical.

## Fix (bd8436f, devices/pvg_metal.m)
Each plane's view sits on the surface's guest-page buffer at `first + plane offset` with the plane's row stride (newTextureWithDescriptor:offset:bytesPerRow:), the way one-plane surfaces work. GPU writes land in guest memory immediately, so every process, mapping lifetime and CPU reader sees them, with no copies and no hashes. The host IOSurface path stays as a lazy fallback (`newIOSurface:`) for a view that fails linear_texture_fits, logged as "cannot sit on its pages; host copy". `HV_PVG_PLANAR_COPY=1` restores the old path for A/B. The descriptor parse is now shared (read_plane/plane_layout).

## Verification so far (Mac, research only; doesn't count as verification)
- `make build/hengevm` builds with no warnings. The Duo app builds: duo-test-safari/ios/build/DerivedDataDev/Build/Products/Debug-iphoneos/Henge.app.
- Mac boot of an APFS clone of duo-backups/2026-11-12-macos-27.2-after-setup with `--phone` (Henge's own Metal replay, as on iOS): login window renders, 32,000 execs and 97,346 draws with 0 failed, no panic. No multi-plane surface appears before login, so the new path itself was not exercised. Without `--phone`, the Mac host uses Apple's ParavirtualizedGraphics and can't show this bug at all.
- Blocker: that backup predates auto-login, so Safari can't be opened on the Mac without Oliver's password, and offline account changes need root. A fresh backup with auto-login (HANDOFF item 38) would allow Mac-side traces. Its Tailscale state would collide with the Duo's node unless Tailscale is stopped first.

## Duo test plan
Install duo-test-safari's Henge.app. Guest auto-logs in; SSH via Tailscale works (macos-duo).
1. Before (old path): add `HV_PVG_PLANAR_COPY=1` to Documents/henge-env.txt, boot, wait for the desktop, then
   `ssh oliverames@macos-duo 'open -a Safari https://en.wikipedia.org/wiki/Vermont'`; snaps at 40 s, then after Page Down x2 (autopilot `key 78`, HID Page Down) and a snap each. Then open https://www.apple.com (video/large images).
2. After (fix): remove that line, reboot the guest, repeat step 1 exactly.
3. Regressions on the "after" boot: desktop/lock-screen wallpaper not green; a video plays with correct colour (apple.com hero video, or QuickTime on any .mov); Finder windows of /Applications and /System/Applications show their icons; the Start Page still renders.
4. Logs: copy henge-native.log after each run. Grep `fourcc b3a8`, `on its pages at`, `cannot sit on its pages`, `shares the host surface`, `failed`, `panic`.
Pass: the "after" snaps show the article's text and images at every scroll position, `on its pages at` lines for the b3a8 and 420f/x420 surfaces, no `cannot sit on its pages` for b3a8, 0 failed, no panic, regressions clean. If "before" is also not blank, the bug didn't reproduce on this page: try a heavier one (https://www.nytimes.com) before concluding.
