# Henge Worklog

Tracking issue: `oliverames/Henge#21` ([Testing still needed for open upstream PRs](https://github.com/oliverames/Henge/issues/21))
Latest status log: [docs/status-2026-11-13.md](docs/status-2026-11-13.md)

## 2026-11-13 - Session wrap-up: fork main consolidation, Henge.ipa rebuild, and upstream PR submission (#128-#182)

**What changed**
- Merged remaining ready fork branches onto `origin/main` through `520b228`: `duo-retina` (`c3a218c`), `ipsw-read-build` (`b6b3853`), `tl_bundle.m` linking / `tl_cf_main_bundle` guard / `CFBundleGetMainBundle` test (`cacdb57`), and `.gitignore` `.DS_Store` + `docs/duo/safari-notes.md` (`520b228`).
- Fixed `Makefile:100` (`f7070a0`) so `$(B)/test_vm_lifecycle` links `$(B)/fault_bench.o`, and carried the same fix into PR `#157` (`413ac91`).
- Added the remaining standalone AssistiveTouch/GameController diagnostics (`a0f5801`, `363f4ef`) to `ios/Henge/Hardware.swift` in PR `#181` (`220232b`).
- Removed the temporary `pr-prep` and `verify-pr` worktrees so only `/Users/oliverames/Developer/Forks/henge` remains.
- Rebuilt `/Users/oliverames/Developer/Forks/henge/Henge.ipa` (`9.4M`, `HengeBuildCommit = 520b2288a4de`, untracked) from fork `main` (`Makefile:100` and doc commits followed without affecting the IPA).
- Submitted and verified all remaining fork fixes as clean, `MERGEABLE` upstream PRs on `Leviidev/Henge` (`#171`–`#182`, joining `#128`–`#165` for 40 open `MERGEABLE` PRs total), including standalone splits for `#180` (`upstream-docked-usb-mouse-shortcuts`, `35bee9d`), `#181` (`upstream-iphone-assistivetouch-mouse`, `220232b`), and `#182` (`upstream-docked-display`, `9ca77d3`). Note: `#128` and `#153` overlap in `henge-jit.js`, `#132`/`#145`/`#175`/`#177` overlap in engine files, and `#143`/`#172`/`#182` overlap in `devices/pvg_metal.m` so merging one will require conflict resolution in siblings.
- Updated `docs/status-2026-11-13.md`, created `WORKLOG.md`, updated `oliverames/Henge#21`, and verified `make -j8 test`, `make test-vm-lifecycle`, `build/test_dns_lifecycle`, `build/test_pvg_lifecycle`, `make -C tl test`, `make test-tl-glue`, `test-display-routing`, `test-download-storage`, `test-jit-advice`, `test-remote-pairing-choice`, `test-disk-growth`, `test-jit-script`, `ios/scripts/check_display.sh`, plus an iOS Swift compile check on PR `#181`.

**Decisions made**
- Kept `Makefile:172` `-O3 -mcpu=apple-m4` on `$(IB)/tl/%.o` fork-only rather than adding it to PR `#176` so upstream iOS builds remain portable to older Apple Silicon SoCs.
- Split docked display (`#182` on `#154`), iPhone pointer/BLE external lock (`#181` on `#151`), and xHCI USB mouse + Mac shortcuts (`#180` on `upstream/main`) into clean upstream PRs without cross-PR build dependencies, leaving the combined `#151` + `#180` `HIDPPMouse` `0x53`/`0x56` USB routing and `#128` + `#153` / `ipsw-read-build` + `#115` integrations on fork `main`.
- Left `device-build` (`3ff3bea` = external PR `Leviidev/Henge#121`) local-only and left `jit-duotest-*` (`DUO TEST ONLY`) and archival/split branches (`baseline-*`, `duo-*`, `held-test*`, `integration/2026-11-13`, `fork-picks`, `upstream-*`) unmerged on `main`.
- Upstreaming proceeded regardless of device test state as requested, with known bugs (`UIScreen.screens.count > 1` in `ios/Henge/SessionView.swift:755` and `width >= 2560` in `devices/pvg_lite.c:276, 327, 873`) explicitly documented on `#182`, `docs/status-2026-11-13.md`, and `oliverames/Henge#21`.

**Left off at**
- **Status: Ready for next session to resume on-device Duo Chickadee testing and corner/performance fixes** (`fork main` and `Henge.ipa` built and synced; zero uncommitted work; 40 upstream PRs `MERGEABLE`).
- Immediate next fixes before re-testing Duo Retina & corners on Chickadee (`00008160-00100CA20260000A`, via `xcrun devicectl` + Xcode, SSH only once macOS boots):
  1. Remove `UIScreen.screens.count > 1` from `docked` detection in `ios/Henge/SessionView.swift:755`.
  2. Remove the `(size >> 32) >= 2560` / `(cur >> 32) >= 2560` external heuristic in `devices/pvg_lite.c:276, 327, 873` so Retina (`2848x2000`) stays built-in unless `HV_PVG_EXTERNAL=1`.
  3. Solve the corner/menu-bar clipping issue cleanly without black bars or bands (respecting Oliver's explicit constraint).
- Clear stale Chickadee UserDefaults (`henge.perf.superblocks`, `henge.perf.wfiSpin`) before running clean `main` Speedometer 3.1 benchmarks and A/B profiling (`HV_PROF_IOS=2`, `HV_TLB_BITS`, `HV_EL0_WINDOW=36`, `-mcpu=apple-m4`, `HV_SHARED_KEEP=2`).

**Open questions**
- `NEW`: How should macOS menu bar items and screen content avoid Chickadee's 59 pt rounded corners without black bars or bands, given `docs/duo/corner-radius-readers.md` showed macOS WindowServer/CoreUI/AppKit ignores `display-corner-radius` and caps `SLSMenuBarPrivacyIndicatorInset` at 12 pt?
- `NEW`: How does current `main` (`#175`–`#177`, `c3a218c`) score on clean Speedometer 3.1 on Chickadee (`HV_SUPERBLOCKS=0 HV_WFI_SPIN=0`), and why does the 1.5 GB code cache refill rapidly?
- `Still open` (`oliverames/Henge#21`): Hardware verification for external docked display HiDPI/4K/shortcuts/BLE lock and untested PRs (`#128`, `#129`, `#134`, `#138`, `#139`, `#146`–`#149`, `#151`+`#181`, `#171`–`#174`, `#178`–`#182`).
