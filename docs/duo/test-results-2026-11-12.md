# Duo combined-build results, 2026-11-12 (Chickadee, iPhone19,4, iOS 27.3; guest macOS 27.2 26B123; 6 vCPU, 8 GB)

Build: duo-combined (fork main 2701e15+, page-table c65a236, jit-segment-eviction fb5e5bc (= 4cdb03b), held-test-2, nhti1f ac5d90b, pvg-delete-task-102b, pvg-builtin-display, Safari dbb87b9, 7a6fo2 83d707a, aux-panic-discard 13d8e61, display-check-pill ca59b8c, mouse h9xhyd, shader jrb3nb 586223d). make test: all suites 0 failures.

## Verified
- Built-in display (pvg-builtin-display): AppleParavirtDisplay "primary" = 0, no "external" (boot A, C1). Corner root cause fixed at the driver level.
- Notch: ADT subtype 1964 (C1) gives safeAreaInsets.top 32.5, auxTopLeft 0..625 x 32.5, auxTopRight 799..1424, menubar 22. No patch (C0, F): all 0. Apple logo still clipped by the Duo's 59 pt corner: macOS keeps its normal left margin. Subtype 1506 (boot B) has no notch in its artwork, so no change.
- Stale panic dialog (13d8e61): boot B showed the last report; C0 made no new report, DumpPanic logged no "unlink" failure. PASS.
- Safari blank pages (dbb87b9): boot B, Wikipedia Vermont fully drawn. "Before" half (PLANAR_COPY=1) not run.
- AGX icons (102b): 20 apps + Finder folders, 0 "can't sit on rows"/"linear texture failed", 98000 execs 0 failed draws, no panic; Utilities icons all drawn.
- Shader cache (586223d): C1 boot 1 filled 246+49+3+46+24+3+1... files 0..10, 0 not saveable; F boot 2 loaded 11 files (12.9 MB), 527 pipelines from archives vs 15 compiled, 0 not saveable. PASS.
- Mouse HID++ (a45c4ef on C0): movement works, clicks forwarded to virtio (raw 0/2) but no effect reported by Oliver; main wheel 0, thumbwheel pans; C3/1A0 unmapped. d6edc7b/41617d2/163324c built, not yet tested by hand.
- JIT: TXM YES; "10.7.0.1 routes through utun7"; loopback pairing (#140) PASS; hw.ncpu 6 (#141 guest side).
- StikDebug duotest (981c5ba): (a) detached cleanly, detachResponse OK, JIT live (3 continues, port lookup resolved Kaitlins-iPad.local); (b) E96 failure 0.63 s after attach request, no 90 s wait. PASS.
- Code cache (stats line, uptime differs per boot): C0 SEG 8 @811 s: 61 evictions 8192 ms (blocks 2015, exits 5886, icache 291), 0 full flushes. C1 SEG 8 tuned @390 s: 42 evictions 4713 ms (1156/3369/188). F SEG 1 @643 s: 0 evictions, 8 full flushes. SSH up: C1 182 s, F 130 s.
- Thermal: Hot for nearly every stats interval on C0 (72 Hot/8 Warm), C1 (38 Hot), F (63 Hot).

## Speedometer 3.1
- Automated readings ("29") were invalid: the reader parsed the "29:162" AppleScript error line because "Allow JavaScript from Apple Events" never took effect. No automated score is valid.
- Only confirmed score: 3.44, seen on screen by Oliver at ~17:29 on boot F (SEG 1, superblocks off). MacBook Neo target 50.4. No earlier verified baseline exists, so improvement can't be claimed.

## Not run
- Safari "before" (PLANAR_COPY=1); boot M (SHARED_KEEP=2 + fault bench + corner radius 177 ADT); TLB 14/12/10; -mcpu=apple-m4 (built, duo-m4); tuned vs default Speedometer A/B; Game Mode off; 1x large-surface panic boot; JIT device-address (127.0.0.1 / Wi-Fi) path (prefs write didn't take); fork-picks refused-attach on OLD build; AssistiveTouch-on mouse run and dot check (needs hands); Magic Mouse; docked desk (hotplug, AirPods, shortcuts); MG direct read in guest.
- Final mouse build 163324c is built (scratchpad Henge-final.app) but not installed, to avoid interrupting the running Mac.
