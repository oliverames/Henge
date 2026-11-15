# JIT setup on iOS 27: what we learned

Upstream path: `docs/research/jit-setup-notes.md`. Written 2026-11-14.

These notes cover how Henge gets JIT on iOS 27 and what went wrong along the way: TXM detection, RemotePairing port selection, LocalDevVPN routing, LiveContainer, and the address-space holds that broke macOS installs. Evidence comes from device logs on an iPhone Duo (iPhone19,4, A20 Pro, iOS 27.3) unless another source is named. Upstream main is `e98920c`. Device test runs from 2026-11-12 are in [`docs/duo/test-results-2026-11-12.md`](https://github.com/Leviidev/Henge/pull/193), which PR #193 adds; I don't repeat them here.

I label each statement as observed (in a log or a PR thread), read from source, or inferred.

## How JIT gets claimed on a TXM device

On a device that enforces the Trusted Execution Monitor (TXM), `MAP_JIT` memory can't execute. Henge's own log says so in the failing case: `TXM device: MAP_JIT cannot execute here, not probing` ([#160](https://github.com/Leviidev/Henge/issues/160)). So Henge asks a debugger to allocate the executable region for it. In a successful Duo log the sequence is:

1. `StikDebug attach probe OK` after the built-in helper attaches. The probe is a `brk` the debugger must answer.
2. The address map is logged, the app's reserved block is released, and Henge asks for a 1,536 MiB region.
3. `BreakGetJITMapping returned 0x...`, then a dual mapping (read-write view and read-execute view) and a self-test that runs generated code and gets 42.
4. The debugger detaches. The region stays.

Henge claims the region at launch, before the guest download, because the debugger does not stay attached (observed in the log line `claiming 1536 MiB of JIT memory now`).

Why the placement matters (read from `henge-ios-jit.c` and merged PR [#2](https://github.com/Leviidev/Henge/pull/2)): iOS gives an app with extended virtual addressing room above 0x7000000000, but generated code placed there never runs, and the self-test hangs with the debugger still attached. Below that address the free room changes with each launch. Henge keeps a zero-fill block in its own `__DATA` so the hole exists, releases it just before the debugger allocates, and relies on first-fit allocation. Henge refuses a region that comes back at or above 0x7000000000.

## TXM detection

Henge used a model table (`HengeLog.expectsTXM(model:)`: every iOS 27 device except iPad8,11 and iPad8,12). A new model or a wrong entry sent setup down the wrong path with nothing in the log to show it.

PR [#192](https://github.com/Leviidev/Henge/pull/192) (from #147) reads the device instead. The boot loader lists memory it set aside for TXM under `IODeviceTree:/chosen/memory-map` as a property named `TXM`, only on devices that run it, and apps can read that node. The code reads property names only, through IOKit loaded with `dlsym`, and falls back to the table if the tree can't be read.

- Observed on the Duo: the boot banner reads `TXM : YES; model table expects YES` in four separate runs.
- Not observed: a disagreement between the two answers, or the fallback path.
- Open: StikJIT also has its own TXM answer. #192 logs when the two disagree. We have not seen one.

## RemotePairing port selection

StikJIT needs the port of the device's own `_remotepairing._tcp` service. Since iOS 26 the device picks the port itself, and the default StikJIT assumes (49152) is often wrong.

What each report observed:

- PR [#52](https://github.com/Leviidev/Henge/pull/52) (merged): an iPhone19,4 on iOS 27.2 listened on 62398; 49152 timed out. The helper now looks the port up with Bonjour (`RSDPortResolver`).
- Every Apple device on the network advertises the same service type, and the resolver took the first answer. Reports of the wrong device winning: an iPad mini on iPadOS 27.2 got an iPhone's 49499 ([#130](https://github.com/Leviidev/Henge/pull/130)); an iPad on iOS 26 got an iPhone's 54318 ([#166](https://github.com/Leviidev/Henge/pull/166)); my Duo got an Apple TV on the same network in two separate runs. On the Duo it only worked because the Apple TV also used 49152.
- On the Duo (iOS 27.3), four runs of a build that preferred the loopback result logged `resolved _remotepairing._tcp to port 49152 ... via loopback interface lo0`. So the device's own service did show up on `lo0` with the other devices on `en0`.
- #130 reports the opposite case: a device that did not see its own advertisement at all. A "prefer lo0" rule would fail there.

Where the PRs stand:

- [#166](https://github.com/Leviidev/Henge/pull/166) (`eltomato89`) and [#130](https://github.com/Leviidev/Henge/pull/130) (`DrRamm`) are open. Both collect every advertised port and check which one answers on this device. #130 also puts the entry whose host matches this device first and confirms with `StikJIT.isDDIMounted`. They edit the same two helper files, so one should land.
- My own "prefer loopback" PR (#140) is closed in favor of #166, because it depended on the device seeing its own advertisement.

Open question: the check asks "does this port accept a connection on the device's address?". Through LocalDevVPN that address loops back to the same phone, so a port open for some other reason could pass. We have no sign of it happening; I note it because the check can't tell the two cases apart.

## LocalDevVPN routing

What it is (from my 2026-11-12 research, partly from reading LocalDevVPN's source; I did not re-verify it in detail): a packet reflector. It routes 10.7.0.1/32 into a tunnel and swaps each packet's source and destination, so the phone reaches its own RemotePairing service. StikJIT targets 10.7.0.1 by default.

Observed:

- With the tunnel off, the Duo logged `10.7.0.1 routes through en0`. After LocalDevVPN connected at launch, `10.7.0.1 routes through utun7`. This is the route-based check from #149, now in [#192](https://github.com/Leviidev/Henge/pull/192). Henge used to count any tunnel with a 10.7 address as connected.
- Issue [#19](https://github.com/Leviidev/Henge/issues/19) shows why a route check matters: LocalDevVPN showed Connected while iOS sent Henge's traffic over cellular, and the Developer Disk Image download failed with a TLS error on a campus network. It passed on a home connection with no proxy.

Without LocalDevVPN (not working yet): #192 adds a Device address setting that sets `StikJIT.Configuration.deviceAddress` and skips LocalDevVPN. Ideas to try are a router rule that reflects 10.7.0.1, or the phone's own address on a network that routes to it. Reaching the device at 127.0.0.1 or its Wi-Fi address is **untested**: a run on the Duo did not take the setting (the preference write did not apply), so it is not a negative result either. Tailscale as the reflector looks unlikely to work (it does not reflect packets, and iOS allows one active VPN); I did not test that. I found no on-device way to do this without a VPN on iOS 26 or 27.

## LiveContainer

Issue [#47](https://github.com/Leviidev/Henge/issues/47) and [#160](https://github.com/Leviidev/Henge/issues/160).

- LiveContainer's own "Launch with JIT" attaches a debugger that does not answer Henge's trap, so the first claim fails. That failure used to be final for the launch. [#192](https://github.com/Leviidev/Henge/pull/192) (from #146) retries once when a debugger traces the process (`P_TRACED`), and waits on `JITBootstrap.debuggerUsable` instead of `CS_DEBUGGED`, which stays set after a debugger lets go.
- LiveContainer nightlies have Helper Process Support, which runs a guest app's extensions. With it on, Built-in StikJIT works inside LiveContainer. #192 reads the setting from `guestAppInfo`.
- Not tested inside LiveContainer by me. #192 says the same.

#160 is a different failure, and #192 does not change it. In that log the probe succeeded (`attach probe OK`), so the debugger does answer traps. The region then came back at 0x7000458000, which Henge rejects, and the failure text says `StikDebug is not servicing traps`, which is misleading here. The largest free gap below 0x7000000000 was 1,372 MiB against 1,536 MiB requested. An earlier launch in the same log claimed the region at 0x1085e4000. The block Henge released was itself at 0x7000458000, where the reserve should have been in the app image. **Inferred:** in LiveContainer Henge is loaded into LiveContainer's process, so its `__DATA` reserve is not mapped with the process image and the loader places it wherever it fits. That would explain why quitting and reopening sometimes works. It is not confirmed.

## High address holds and install failures

Read from source: the JIT prewarm holds 40 GB at 0x7000000000, 16 GB at 0x7c00000000 and 4 GB at 0x7b00000000 for Mac apps' allocators (Chromium-style reservations), 60 GB in all. They are released only when QEMU starts. The JIT region's writable view sits at 0x7a00000000, in the 4 GiB gap between holds.

Observed on the Duo, with the holds in place:

- Largest free mapping 2,560 MiB, which is the 4,096 MiB gap minus the 1,536 MiB view.
- The macOS 27.2 install failed twice. First: "needs more storage" (misleading). Second: "Cannot build the machine".
- With [#121](https://github.com/Leviidev/Henge/pull/121) merged, 61,440 MiB of unused reservations were released before the VM was created, the largest mapping went to 16,896 MiB, the guest got its 4,096 MB, and the restore finished.

Independent report in [#169](https://github.com/Leviidev/Henge/pull/169): an iPad logged `guest RAM 2048 MB (asked 8192 ... largest mapping 2560)` and the Mac failed to start, with Mac apps off.

Both PRs release the holds unless a Mac app already took them. Open: whether the holds can exist at all when a process has no extended addressing (the #160 log says `extended addressing: no` and `32 GB can be reserved in one piece`; no hold lines appear in it).

## PRs that act on this

| PR | What it does |
|---|---|
| [#192](https://github.com/Leviidev/Henge/pull/192) | LiveContainer retry and helper setting, TXM from the device tree, plain advice for device-state helper errors, device address setting and route-based LocalDevVPN check |
| [#166](https://github.com/Leviidev/Henge/pull/166), [#130](https://github.com/Leviidev/Henge/pull/130) | Pick only a RemotePairing port that answers on this device |
| [#121](https://github.com/Leviidev/Henge/pull/121), [#169](https://github.com/Leviidev/Henge/pull/169) | Release the high holds before sizing guest RAM and installing |
| [#189](https://github.com/Leviidev/Henge/pull/189) | StikDebug script: only `brk` is a command, stop on a refused attach, read full registers |

## Open questions

1. Does the Device address setting work at 127.0.0.1 or a Wi-Fi address on a real phone?
2. Does #192 fix the #47 pattern inside LiveContainer? Untested.
3. Is the #160 placement failure caused by Henge's image being loaded rather than being the process executable? Needs a LiveContainer log with the reserve's address printed at launch.
4. The failure text `StikDebug is not servicing traps` should differ when the probe succeeded and only placement failed.
5. Do two open ports on the device ever make the #166/#130 check pick the wrong one?
6. Can the holds be made smaller, or created lazily, so the same cap can't recur for the next allocation done before QEMU starts?
