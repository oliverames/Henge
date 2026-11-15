# Performance on an iPhone Duo: measurements, method, and open questions

This is a write-up of my performance work on Henge on 2026-11-12 and 2026-11-13, so other contributors can reuse the method and pick up what I didn't finish. It covers one device, one guest OS and a handful of boots, and is mostly profiling and counting rather than benchmark scores. Every number traces to a log listed under Sources. Where I computed something, I say how. Inferences are marked.

## Summary

- Translated code was about 83% of busy time in the last profile window (67% guest user code, 16% guest kernel). About 35% of translated-code samples landed on three loads from the software TLB entry. I have not shown why (cache misses, sampling skid, or something else).
- The old whole-cache flush fired every 55 to 300 seconds depending on activity. The segmented ring (#186) removes it. With the ring, each eviction stops the guest for 112 to 268 ms, about 1% of wall time. The cache still turns over about every 100 seconds, which I can't explain yet.
- The phone reached the logged "Hot" thermal state about 1.5 to 2 minutes after the machine started and stayed there. Translated block rate in Hot is well below Normal, but workload and thermal state are confounded in my data.
- The TLB size A/B (HV_TLB_BITS 14/12/10) was built and never run. There is no valid Speedometer comparison between builds.

## 1. What was measured, and on what

| Item | Value | Source |
|---|---|---|
| Device | iPhone Duo, model iPhone19,4, A20 Pro, 6 cores, 11,569 MiB RAM | boot banner in [prof], [duo] |
| Host OS | iOS 27.3, JIT enabled through a debugger attach (TXM present) | boot banner |
| Host memory limit | about 6,140 MiB before jetsam at app launch | native log in [prof] |
| Guest | macOS 27.2 (build 26B123), after Setup Assistant, with Henge's lighter-macOS command applied | [duo] RESULTS.md |
| Profile run | 4 vCPUs, 6 GB, 1536 MB code cache | `booting with` line in [prof] |
| Duo boots (B, C0, C1, F) | 6 vCPUs, 8 GB, 1536 MB code cache | `booting with` line in each log |
| Build | `-O2 -g`, arm64, iOS 17 minimum, iPhoneOS 27.3 SDK, Xcode 27.3 beta | build-baseline-perf log |
| Engine | 4 TLB tables of 2^14 entries x 32 B, so 2 MB of TLB per vCPU | core/cpu.h:20-25, 123; #134 |

The builds were integration builds from my fork (oliverames/Henge) that combined the PRs in section 4 with others. The profile build used fork commits 00e6669 and 9c55a00 (the EL-split profiler); the TLB A/B apps came from fork commit 236774e. All three are in oliverames/Henge.

Boots were not cooled to Normal between runs. Several started already Hot (section 3.4), so they are not clean A/B pairs.

## 2. Method and knobs

Settings go in `Documents/henge-env.txt` in the app container, one `KEY=VALUE` per line. That file wins over defaults and Settings toggles (ios/Henge/EngineTuning.swift). The autopilot (`HENGE_AUTOPILOT=1` at launch, with `henge-autopilot.txt` in Documents) scripts the guest: `mac`, `wait N`, `snap NAME`, `cmd space`, `type TEXT`, `log MARKER`, `knob NAME VALUE`, `cpus N`, `stop`, `exit` (ios/Henge/Autopilot.swift). Logs are `Documents/henge.log` and `henge-native.log`; the log rotates at each launch, so pull it before launching again.

| Knob | What it does |
|---|---|
| `HV_STATS=N` | An engine stats block every N seconds (block rate, translation share, exceptions, TLB flushes, code cache held and flushes/evictions, TLBI ack waits, light refills by mapping, process switches). |
| `HV_PROF_IOS=1` / `=2` | Sampling profiler. 1 reports samples by host image, and by guest EL with #134; 2 also counts the translated instruction word under each sample and appends it to `hvprof-words.txt`. `HV_PROF_IOS_SECS` sets the window (default 30). The sampler reads each CPU thread's PC, which stops the thread briefly, so sampling is not free (host/prof_ios.c). |
| `HV_TLB_BITS=N` | Build setting, not env: `ENGINE_DEFS=-DHV_TLB_BITS=N` (7 to 14, default 14) on both `make ios-lib` and the Xcode build. Each table is 32 << N bytes. |
| `HV_JIT_SEGMENTS=N` | Code cache ring size. Default 8; 1 restores the whole-cache flush. |
| `HV_FAULT_BENCH=1` | Times mprotect, signal faults, Mach faults and vm_remap at boot. |
| `HV_SHARED_KEEP=1/2` | Keep user TLB entries across a process switch for the dyld shared region; 2 adds a staleness check. |
| `HV_EL0_WINDOW=bits` | Prototype that maps guest user memory directly. |
| `HV_SUPERBLOCKS`, `HV_WFI_SPIN`, `HV_HOIST_CHECK`, `HV_QOS`, `HV_RECHECK`, `HV_SYNC_WAIT`, `HV_HZ` | Existing engine knobs I wanted to A/B. `HV_RECHECK`, `HV_SYNC_WAIT`, `HV_SUPERBLOCKS`, `HV_WFI_SPIN` and `HV_HOIST_CHECK` can be changed at runtime with the autopilot `knob` command, which flushes the code cache. |

To profile: put `HV_PROF_IOS=2` and `HV_STATS=10` in henge-env.txt, boot, do something repeatable, copy the three logs off the phone, and run `python3 tools/prof_words.py hvprof-words.txt`. #134 includes `tools/prof_words.py`, verified with `gh pr diff 134 --name-only`.

I also wrote an A/B harness (shell wrappers around `xcrun devicectl`, a report parser and two autopilot plans). It runs interleaved variants with an equal cool-down gap and prints medians per label. It is not in any repo. Its README says the device-driving parts had not been run at the time it was written; the 2026-11-12 boots used separate runner scripts, and I only checked the report parser against one real log. Treat it as a design, not a tested tool, and ask if you want it contributed.

## 3. Findings

### 3.1 Where the time goes

Seven profile windows in [prof] (about 45 s apart, 120,000 samples each, during boot, one Finder window and a Safari launch):

| Window | Idle | JIT, of busy | el0 | el1 | Other images |
|---|---|---|---|---|---|
| 1 | 11.7% | 76.7% | 47.0% | 29.8% | 5.2% |
| 4 | 33.3% | 79.3% | 59.4% | 20.0% | 4.2% |
| 7 | 27.8% | 82.8% | 66.9% | 15.8% | 3.0% |

Windows 2, 3, 5 and 6 fall between these (JIT 68.9% to 77.2%). Window 7 is the figure quoted in #134.

Word-level view of the same run (`hvprof-words.txt`, 519,422 translated-code samples, classified by `tools/prof_words.py`, reproduced here by rerunning the script):

| Category | Share |
|---|---|
| TLB tag/addend load | 34.72% |
| Other, mostly copied guest code | 22.29% |
| Other load/store | 13.79% |
| Branch | 10.44% |
| `x28` (HvCpu context) load/store | 9.41% |
| The access itself, `[addr, addend]` | 4.46% |
| All other TLB steps (slot index, tag check, subtract, slot address) | 2.0% (summed by me) |

Three single words make up 34.68% of all samples: 15.40%, 12.17% and 7.11%. They are `ldr x15, [x7, #0x580 / #0x598 / #0x588]`. From the entry layout in core/cpu.h I read these as the read tag, the addend and the write tag (inference from offsets, not checked against the emitter). Including the other TLB steps, about 36.7% of samples are in the TLB check sequence (computed).

Caveats. A PC sample lands on the instruction that is waiting, so a load that misses cache gets the blame, but skid can also move blame to a neighbour. The TLB is 2 MB per vCPU, so cache misses are plausible, but I did not confirm it. The A/B that would help (smaller tables) was not run.

### 3.2 Software TLB refills

From 23 `HV_STATS` windows in [prof]:

| Refills (K/s) | Median | Range |
|---|---|---|
| All light refills | 629 | 430 to 1,314 |
| EL0, 16 KB page mappings | 427 | 292 to 806 |
| EL1, 16 KB page mappings | 226 | 120 to 656 |
| EL1, block mappings | 11 | 5 to 21 |
| EL0 block mappings | 0 | 0 to 144 |
| Any big block mapping | 0 | 0 in every window |

Of user light fills, 95.5% came from the dyld shared region (sum of the shared-region column over the sum of both columns, my calculation). Process switches ran at a median of 9.3K saved and 8.0K restored per second, with 130 per second dropped by a TLBI. The zero for big block mappings ruled out a kernel physmap shortcut in the refill path, which is stated in #134. The shared-region share and switch rate are what motivated `HV_SHARED_KEEP` in #157. That option has not been run on a device.

### 3.3 Code cache: fill, flush and eviction

Whole-cache flushes, builds without the ring:

| Run | Config | Full flushes | Spacing |
|---|---|---|---|
| [prof] | 4 vCPUs, boot plus Finder and Safari | 3 in 305 s | about 55 to 90 s |
| final2 sample [harness] | 4 vCPUs, desktop use, older build | 8 by 1,569 s | 162 to 300 s |
| 2026-11-13 `HV_JIT_SEGMENTS=1` [logs13] | 6 vCPUs | 6 in 594 s | about 70 to 185 s |

Each flush happened when the 1,536 MB region held about 5.2 to 5.5M blocks, about 290 bytes a block (1,531 MB / 5.516M in [prof]; computed). The share of time spent translating spiked after a flush: 17%, 18% and 13% in the windows after the three [prof] flushes against a median of 6 to 8%, and 29% and 25% after the first two flushes in the [logs13] run. The "again: va" retranslation percentage in these logs is not usable: its median sat at 71 to 90% in every duo build because the seen-address bitmaps were never cleared (core/dispatch.c). #186 resets them per eviction; a 2026-11-13 run with that fix showed 2%.

Eviction with the ring (`HV_JIT_SEGMENTS=8`), all before the O(segment) change in #177:

| Run | Evictions | Total stopped | Avg per eviction | Phases (exits / blocks / icache) | Stopped, % of wall |
|---|---|---|---|---|---|
| C0, default knobs, 811 s | 61 | 8,192 ms | 134 ms | 72% / 25% / 4% | 1.0% |
| C1, tuned knobs, 390 s | 42 | 4,713 ms | 112 ms | 72% / 25% / 4% | 1.2% |
| B, 234 s | 16 | 4,290 ms | 268 ms | 82% / 15% / 4% | 1.8% |
| docked baseline [logs13], 646 s | 23 | 4,687 ms | 204 ms | 75% / 21% / 4% | 0.7% |

Averages and percentages are my division of the totals in each log's last `HV_STATS` block. The first eviction in C0 took 1,023 ms; later ones were shorter. The exits phase (undoing chained exits) dominates, which is what #177 targets. I found no on-device number for #177 itself, and #186's own "Untested" list says so. A line in the fork's status doc (33 evictions averaging 250 ms) does not match any log I could find, so I'm not using it.

In C0 the guest translated about 14 MB/s of new code (61 evictions x 192 MB per segment = 11.4 GB over 811 s; computed). That is a lot for a desktop that looks idle, and it is the largest open question here.

C0 against F (`HV_JIT_SEGMENTS=1`, 643 s, 8 full flushes) shows the structural difference (0 full flushes against 8) but no speed difference I can defend. Median `[perf]` block rate while Hot was 71K/s against 78K/s, and median "cpu thread ran" was 73.5% against 60%. Both boots started Hot, ran different lengths and differ in uptime at the end.

### 3.4 Thermal

| Run | First thermal reading | First Hot | Hot share of 10 s perf lines |
|---|---|---|---|
| [prof] | Warm | stats t = 93 s | 24 of 31 |
| final2 [harness] | Normal | 111 s | 155 of 164 |
| B | Normal | 80 s | 17 of 24 |
| C0, C1, F | already Hot | n/a | 90%, 100%, 100% |

Medians in the same logs, which mix thermal state with workload (the cool samples are mostly boot):

| Run | Normal | Warm | Hot |
|---|---|---|---|
| [prof], blocks/s | none | 185,533 | 81,961 |
| final2, blocks/s | 149,652 | 66,579 | 48,980 |
| final2, "cpu thread ran" | 87% | 85% | 75% |

I read the drop in "cpu thread ran" as iOS taking the core away from the vCPU thread (inference; the field is the printing thread's CPU time over wall time). The harness gap between boots (150 s) does not equalise a hot phone. A fair comparison needs each boot to start at Normal, with the share of intervals per thermal level reported.

### 3.5 TLBI ack waits

`HV_STATS` reports the share of one CPU spent waiting for other vCPUs to acknowledge a TLBI.

| Run | Median ack wait, while Hot |
|---|---|
| final2 (4 vCPUs) | 25% (3.4 to 5.5% while Normal or Warm) |
| C0 / C1 / F (6 vCPUs) | 17.6% / 18.9% / 27.2% |
| B (6 vCPUs) | 8.7% |
| [prof] (4 vCPUs, profiler on) | 4.9% |

The jump with heat appeared in final2 but not in [prof], so it isn't a rule yet. In F, waits longer than 1 ms account for 16 to 22% of one CPU's time and waits under 10 µs for 0.1%. For waits past 100 µs, the vCPU being waited on was off a core 3 to 9 times a second and running 7 to 9 times a second (F stats lines). I read that as iOS descheduling vCPUs (inference). `HV_SYNC_WAIT=1` (sleep instead of spin) and a vCPU count A/B are the obvious next tests.

### 3.6 Idle and WFI

The guest rarely idles after boot. Stats blocks in [prof] report 0% idle for every window from 27 s to 117 s, and later windows mix 0 with 12 to 145; the sampler's idle share was 11 to 33%. The stats "% idle" field can exceed 100 (values like 113, 145 and 174 appear), so don't read it as a percentage. `HV_WFI_SPIN` defaults to 0. C1 ran it at 50 µs together with three other knobs, so it is not isolated.

### 3.7 Host primitives (fault bench, boot B)

| Operation | Cost |
|---|---|
| mprotect | 376 ns per call |
| Signal fault | 2,034 ns per fault (5,120 faults, 0 stray) |
| Mach thread-port fault | 5,210 ns per fault |
| vm_remap | 1,100 ns per page; first touch after, 322 ns per page |

Inference for `HV_EL0_WINDOW`: a fault plus a remap is roughly 3.1 µs per first touch. At the 629K/s median refill rate in 3.2, that would be about 2 s of CPU per second if every refill became a first touch, so the window only pays if it removes most refills and first touches are much rarer than refills. I have not measured the first-touch rate.

### 3.8 Speedometer

- Every automated Speedometer reading from 2026-11-12 ("29") is invalid. The reader parsed an AppleScript error line, because "Allow JavaScript from Apple Events" never took effect in guest Safari ([duo] RESULTS.md).
- The one score seen on screen that day was 3.44 on boot F (`HV_JIT_SEGMENTS=1`, superblocks off, Hot throughout). My reference target was 50.4 (a MacBook Neo), so that is about 6.8% (computed).
- On 2026-11-13 I reported 6.36 from a docked baseline build (8 GB, 6 vCPUs, ring cache, external monitor). No automated capture backs it. That is about 12.6% of the target (computed). The runs differ in build, display and probably thermal state, so the 1.85x ratio between 6.36 and 3.44 (computed) is not a measured improvement. The log in [logs13] I could pair with it shows 55 of 64 perf lines Hot, but I can't confirm it is the same boot as the score.
- A valid automated run needs the Safari toggle set once in the guest. No clean run of current `main` exists.

## 4. Findings and the PRs they led to

| Finding | PR |
|---|---|
| 83% JIT, EL split, 35% on TLB loads, refills by mapping size, TLB size build setting, `prof_words.py` | [#134](https://github.com/Leviidev/Henge/pull/134) |
| Whole-cache flush every minute or three, retranslation spikes, eviction cost dominated by exits | [#186](https://github.com/Leviidev/Henge/pull/186) (replaces #132, #145, #175, #177) |
| Shared-region refills, process-switch rate, fault costs | [#157](https://github.com/Leviidev/Henge/pull/157) (stacked on #134) |
| Network batching, drawable retry, `-O3` | [#176](https://github.com/Leviidev/Henge/pull/176). Not derived from the profiles here and untested on a device. |

#78, #80 and #81 (cache fallback size, vCPU QoS, superblocks) were measured on a Mac only. I did not re-measure them on the phone. Whether v0.2 to v0.3 regressed in the way [#120](https://github.com/Leviidev/Henge/issues/120) reports is not something this data answers.

## 5. Invalid or inconclusive

- All automated Speedometer scores, and any claim of a Speedometer improvement.
- The TLB size A/B: the 14, 12 and 10 builds exist and were never booted.
- The code cache A/B (C0 against F): counts are valid, speed is not (different durations, both started Hot). The `jit-ab` folder holds only its inputs.
- The tuned boot (C1: superblocks, hoist check, QoS=ui, WFI spin 50, a device-tree patch): four knobs at once, started Hot. No conclusion.
- "again: va" in the duo-boot logs, and the stats "% idle" field above 100.
- Thermal against workload: nothing here separates the two.
- Profiler cost: sampling stops threads, so profiled boots run slower than unprofiled ones.
- Handoff-note figures from earlier boots (blocks/s 345K Normal, 95K Warm, 50K Hot) come from logs I did not re-read. I reproduced the pattern in final2 only.

## 6. Open questions worth picking up

1. Why does an idle-looking desktop translate about 14 MB/s of new code? Count translations whose physical page was already translated under another VA, flag set or page generation.
2. Run the TLB A/B (14, 12, 10; boot to desktop, Finder, Safari; `HV_PROF_IOS=2`; delete `hvprof-words.txt` between runs) and see if the 35% moves. If it does not, the loads are not cache misses.
3. Run `HV_SYNC_WAIT=1`, vCPU count 2/4/6, and dropping a vCPU when Hot against the TLBI wait share.
4. Measure the first-touch rate under `HV_EL0_WINDOW` before investing in it, and do the `HV_SHARED_KEEP=2` correctness boot.
5. Cheaper emitter changes sketched in my handoff from source only, none measured: a physical-aperture fast path for kernel accesses, sharing one tag check across accesses to the same page in a block, packing tag and addend for one `ldp`.
6. `HV_RECHECK=0` (about 13% smaller code per core/machine.c) as a cache-pressure A/B.
7. A repeatable Speedometer harness, started at Normal, with the thermal share reported.
8. Other hosts. I only have the iPhone; an iPad with a different guest may behave differently.

## Sources

Raw logs stay in my local `henge-worktrees` folder and are not in the repo. I can attach any of them.

- [prof]: `prof-2026-11-12/` (`henge.log`, `henge-native.log`, `hvprof-words.txt`, `words-by-kind.txt`, plans, env files).
- [duo]: `duo-results-2026-11-12/` (`RESULTS.md`, boots B, C0, C1, F).
- [harness]: `harness/` (README, scripts, `runs/_sample/henge.log`, a 1,658 s run on an older build).
- [logs13]: the fork's `logs/2026-11-13/` (`analysis-stats.tsv`, `runs/henge.log`).
- My unpublished handoff notes of 2026-11-12 (items 13, 15, 19, 21, 22), the fork's `docs/status-2026-11-13.md`, and the tracking issue oliverames/Henge#21.
- Builds: `build-baseline-perf-*.log`. A/B inputs: `tlb-ab-2026-11-12/`, `jit-ab-2026-11-12/`.
- PR text: #134, #157, #176, #186 and issue #120 on Leviidev/Henge.
