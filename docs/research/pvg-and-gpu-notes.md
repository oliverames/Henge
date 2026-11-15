# PVG and GPU notes

What I've worked out about how Henge's ParavirtualizedGraphics (PVG) replay talks to the guest, what Apple's own host does with the same guest data, and where the two differ. It covers the display page and its events, surfaces and page lists, task and pipeline lifetime, the AGX crash in #102, the first-boot kernel panic, the Safari blank-page cause, linear textures, the pipeline archive, and a short section on the two panics that aren't GPU bugs (the restore panic behind #73 and the stale panic log).

I wrote these notes so someone else can pick up a thread without redoing the disassembly. Every claim carries one of three tags:

- **Confirmed**: read from a disassembly, a log, or a test I ran, and I checked it.
- **Inferred**: follows from confirmed facts, but nobody has reproduced it on a device.
- **Open**: unresolved, or two sources disagree.

## Test setup and caveats

- Device: an iPhone Duo (A20 Pro, iOS 27.3), guest macOS 27.2 (26B123), 4 to 6 vCPUs, 6 to 8 GB guest RAM. Henge's own Metal replay (`devices/pvg_metal.m`) draws the guest's GPU work on the phone.
- Apple's host code was read on a Mac running macOS 27.3 (26C5035r). The guest is 27.2 and the #102 reporter's crash is on iOS 27.2, so every Apple offset below is a 27.3 offset. Where 27.2 mattered I say so.
- Binaries and private-framework internals: I read the dyld shared cache (extracted with `/usr/lib/dsc_extractor.bundle`) and standalone Mach-O files, disassembled with `llvm-objdump`. I've kept disassembly excerpts to a few instructions. Addresses are unslid.
- Fork commit SHAs below are in the `oliverames/Henge` fork, not upstream.
- Debug knobs used: `HV_PVG_OPS=1` (logs the first FIFO commands of each kind), `HV_PVG_TRACE`, `HV_PVG_PLANAR_COPY=1`, `HV_PVG_EXTERNAL=1`, `HV_PVG_ARCHIVE=0|reset`, `HV_ADT_PATCH` (device-tree edits), `HV_SHADER_DUMP=1`.

## Upstream PRs that act on this research

| PR | What it does |
|---|---|
| [#187](https://github.com/Leviidev/Henge/pull/187) | Multi-plane surfaces draw on guest pages; surface page lists are read as two-level page tables |
| [#188](https://github.com/Leviidev/Henge/pull/188) | Delete task frees the named task (fixes #102); function and pipeline checks match Apple's; compiled pipelines are archived across launches |
| [#190](https://github.com/Leviidev/Henge/pull/190) | Display events, live mode changes, built-in panel flags, `+0x68` is `protectionOptions` |
| [#137](https://github.com/Leviidev/Henge/pull/137) | A linear texture's last row needs only its width |
| [#142](https://github.com/Leviidev/Henge/pull/142) | aux disk discard, so the guest can clear its panic store |
| [#144](https://github.com/Leviidev/Henge/pull/144) | Test that aux writes over bdif land past the file header |
| [#73](https://github.com/Leviidev/Henge/pull/73), [#161](https://github.com/Leviidev/Henge/pull/161) | Other people's PRs that this research bears on |
| [#193](https://github.com/Leviidev/Henge/pull/193) | Rounded-corner notes (the corner research is not repeated here) |

## 1. Where Apple's host does the work

**Confirmed.** The code that turns guest objects into Metal objects is not in `ParavirtualizedGraphics.framework`. The framework's FIFO parser (`-[PGFIFO processFifo]`) decodes commands and hands them to an XPC service,
`com.apple.gpusw.ParavirtualizedGraphicsGPUTask`, which owns the Metal objects. I searched the in-cache framework for `newRenderPipelineDescriptorWithSerializedData:deserializationContext:` and `functionWithFunctionRef:` and found no references. They live in the standalone GPUTask binary, which has C++ symbols, so its disassembly is far more readable than the framework's.

The classes that matter: `PGResourceManager` (C++, one per task), `PGResourceManagerDeserializationContext` (conforms to `MTLDeserializationContext`), `_PGDeserializer`, and the `PGDeserializer{Render,Compute,Blit,Info}Decoder` family.

### FIFO opcodes that create or destroy things

`-[PGFIFO processFifo]` takes the low 16 bits of the command header as the opcode and jumps through a 0x46-entry table. Anything above 0x45 goes to the default branch. These are the ones that matter for object and task lifetime:

| op | Method | Payload as Apple reads it |
|---|---|---|
| 0x38 | CmdDefineTask2 | `createTaskID:(p[0] >> 1) taskRoot:*(u64*)(p+4) length:p[3]` |
| 0x20 | CmdDeleteTask | `deleteTaskID:p[0]`, **unshifted** |
| 0x33 | CmdSetObjectList | task p[0], list page p[1] `<< 14`, length p[2], no placement list |
| 0x44 | CmdSetObjectAndPlacementList | task p[0], object list and placement list offsets and lengths |
| 0x28 | CmdDeleteObject | needs `p[2] + 4 <= size`; task 0 refused; `deleteObjectWithSerializedData:p+4 size:size-4` |
| 0x25 | CmdDeleteResource | `{task, ref}` |
| 0x22 | CmdUnmapMemory | task memory unmap |

Content-only commands are 0x34 Invalidate, 0x35 Synchronize, 0x3e SynchronizeAndDiscard, 0x3f Discard.

**Confirmed:** there is no batched object destroy, no generation counter and no "list changed" notification. 0x33 and 0x44 only repoint the lists; existing objects are kept.

## 2. Task and object lifetime (the cause behind #102)

### What Apple does

- **Confirmed.** Each task has one `PGResourceManager` with a table per object type, keyed by ref. `deleteTaskID:` tears the manager down and removes the task. `createTaskID:` throws "Host task already exists" if the ID is still live, so a guest must send 0x20 before it reuses an ID. Task IDs are below 0x100.
- **Confirmed.** Objects are created lazily from the guest's object-list entry on the first lookup. A table hit is returned without re-reading or comparing the entry. Apple never revalidates; it relies on explicit deletes (0x28 per object, 0x25 per resource, 0x20 for the whole task).
- **Confirmed.** 0x28 routes on the serializer tag. Each tag erases the ref from one table and clears its placement entry:

| Tag | Object |
|---|---|
| 0x3e8, 0x3e9, 0x3f4 | PGResource (buffers, textures, heaps, ICBs) |
| 0x3ea | DepthStencilState |
| 0x3eb | SamplerState |
| 0x3ed | Function |
| 0x3ee | ComputePipelineState |
| 0x3ef | RenderPipelineState |
| 0x3f1 | Fence |
| 0x3f6 | RasterizationRateMap |

Other tags are logged and ignored. A 0x28 payload under 16 bytes passes the FIFO check but fails `deleteObject`'s own 12-byte check, so Apple deletes nothing.

### What Henge did wrong

**Confirmed from code and disassembly.** Henge's handler for 0x20 removed the task `args[0] >> 1`. Apple uses `p[0]` as is; only 0x38 shifts. So when a guest process ended, Henge kept that task's whole ref-to-object cache (MTLFunctions, pipelines, buffers, textures) and dropped the cache of an unrelated live task (ID / 2).

**Confirmed from a device log.** With `HV_PVG_OPS=1` on the Duo, the first 0x38 carried word `00000002`, and the 0x44, 0x43 and 0x25 that followed it all named task 1, so 0x38 does shift (2 >> 1 = 1). The later 0x22 and 0x20 named task 2 directly. One caveat: the log only shows the first command of each kind, so the single logged 0x20 is consistent with the unshifted reading but doesn't prove it alone. The proof is Apple's disassembly.

**Inferred.** When the guest reuses the task ID for a new process, Henge's `objs` for that ID still holds the dead process's objects. Any ref whose 12-byte entry matches (same type, size and task-relative address) returns the old process's MTLFunction or pipeline. Every function record is 20 bytes and processes start with similar allocation patterns, so a match is likely. I could not reproduce this crash.

**Fix:** use `args[0]` unshifted in the 0x20 handler, and clear the task's lists in pvg_lite. That is in #188 (replaces #133).

**Test on the Duo (macOS 27.2 guest):** I opened and quit 20 apps 25 seconds apart, then 6 Finder windows with sidebars. No crash, every window drew, pvg-metal logged 894,275 draws with 0 failed and no pipeline or function-ref complaints. I haven't seen the original crash on my own device, so this shows no regression, not a fix. The reporter's setup (a macOS 15.6.1 guest on iOS 27.2) is untested.

## 3. How Apple deserializes functions and pipelines

All **confirmed** from the GPUTask disassembly (macOS 27.3). Henge's differences are in #188.

### Function records

`PGResourceManager::createObject<id<MTLFunction>>`:

1. The object-list entry's type byte must be 6.
2. It reads a 12-byte function header `{u64 offset, u32 length}`, then an 8-byte serializer header `{u32 command, u32 size}`. That makes the record the same 20 bytes Henge reads.
3. The serializer command must be 0xF.
4. `getData(offset, length)` gives the library bytes; it then calls `[device newLibraryWithData:error:]`.
5. `[[library functionNames] count]` must be exactly 1, and Apple takes `functionNames[0]`.

Apple reads **no function name, no function constants and no specialized name**. One library, one function.

### Function lookup

`-[PGResourceManagerDeserializationContext functionWithFunctionRef:]`:

- Ref 0 returns nil as a success (not counted as a lookup failure).
- Otherwise the lookup uses a **function-only table** (`PGResourceManager+0x118`). On a miss it reads the object-list entry and calls `createObject<id<MTLFunction>>`, which rejects any type other than 6. So a ref that names a buffer, texture or pipeline can never come back as a function.
- On failure it sets `hadLookupFailure`, records the first reason and returns nil.

### Render, tile and compute pipelines

Entry type 7 is a render pipeline state; the serializer command routes 0xE to render and 0x33 to tile. The render path:

1. Reads `{u32, u32 length}`; if the remaining cursor bytes are less than `length`, fails with "Insufficient data in command".
2. `[ctx resetFailureState]`, then `[device newRenderPipelineDescriptorWithSerializedData:data deserializationContext:ctx]`.
3. If the placement entry exists, `setResourceIndex:` and `setForceResourceIndex:YES`.
4. Fails if `hadLookupFailure`, and fails if `vertexFunction == nil`. It changes nothing else on the descriptor.
5. `[device newRenderPipelineStateWithDescriptor:desc options:0 reflection:NULL error:&err]`, then writes `resourceIndex` back.

Compute does the same and requires a non-nil `computeFunction`. **Apple has no compute stand-in:** a nil function is a creation failure.

Differences found in Henge before #188: the lookup returned any object type; ref 0 counted as a failure; no check of the serializer command (0xF) or the one-function rule; `makeSerialized` used `w[3]` as a data length without checking `16 + w[3] <= size` (a heap over-read); no nil check on the vertex or tile function; no `resourceIndex`.

Henge still keeps a stand-in compute kernel (Metal's deserializer aborts on a nil compute function in Henge's setup, per #188), which is a deliberate difference from Apple.

## 4. The #102 crash: AGX segfault in `makeSerialized`

The report: iPhone (A20 Pro, iOS 27.2), macOS 15.6.1 guest, a Finder window opened, SIGSEGV with the fault inside `AGXMetalG19P` under `-[HvReplay makeSerialized:length:task:]`, at the `newRenderPipelineStateWithDescriptor:` call. pvg-metal had logged `0 failed` for 27,521 draws before it.

### Symbolication

**Confirmed that the frames line up; inferred that 27.2 matches.** The 27.2 driver isn't on my Mac, so I used the Duo's iOS 27.3 `AGXMetalG19P` (with local symbols). The four reported offsets land on one coherent call chain, each a return address right after a `bl`:

| 27.2 offset | 27.3 symbol |
|---|---|
| +0x41D068 | `-[AGXG19FamilyDevice newRenderPipelineStateWithDescriptor:error:] + 132` |
| +0x4684C | `UserCommonShaderFactory::createRenderPipeline_impl<...>(...) + 1468` |
| +0x49044 | `...::createFragmentProgramVariant<...>(...) + 3804` |
| +0x4A530 | `Program<HAL400::FragmentProgramVariant, ...>::getOrCreateCompileOptions(unsigned long, ReflectionKey const&) + 60` |

The faulting spot is the lock at the top of `getOrCreateCompileOptions`:

```
add x0, x0, #0x6d8
bl  os_unfair_lock_lock      ; return address = frame +0x4A530
ldr x22, [x20, #0x6b0]
```

The report's `libsystem_platform +16788` directly above that frame fits a fault inside `os_unfair_lock_lock`, on `this+0x6d8`. I compared the macOS 27.3 copy of the same driver for selector names; the instruction sequences match the iOS copy one for one, apart from stub addresses and the PAC prologue (`pacibsppc` on iOS, `pacibsp` on macOS).

### Where `this` comes from

1. `createRenderPipeline_impl` calls `populateRenderPipelineDescriptorInfo`, then passes `info->+0x20` into `createFragmentProgramVariant`, which passes it as `this`.
2. `populateRenderPipelineDescriptorInfo` fills `info[0..3]` with the descriptor's fragment, vertex, object and mesh functions, then runs a block under `dispatch_sync`:
   ```
   holder = [fragmentFunction vendorPrivate]
   if (!holder) { holder = [AGXG19FamilyComputeOrFragmentOrTileProgram new]; [fn setVendorPrivate:holder]; }
   prog = holder->+0x10                     ; _frag
   if (!prog) holder->+0x10 = prog = [AGXG19FamilyFragmentProgram new];
   info->+0x20 = prog + 8
   ```
   The vertex, object and mesh stages do the same with their own holder classes.
3. **Confirmed:** no class or function-type check anywhere. AGX trusts whatever `vendorPrivate` already holds.

Class layouts (from the macOS 27.3 driver through the ObjC runtime):

| Class | Size | Ivars |
|---|---|---|
| ComputeOrFragmentOrTileProgram | 0x20 | +8 `_compute`, +0x10 `_frag`, +0x18 `_tile` |
| FragmentProgram | 0x708 | +8 `_impl`; lock at `_impl+0x6d8` is in bounds |
| VertexProgram | 0x5c8 | +8 `_impl`, which starts with `keys[0] = {vptr, int streamType, ...}` |
| MeshProgram, ObjectProgram | 0x5e8, 0x508 | +8 `_impl` |

### The failure mode

**Inferred, not reproduced.** If the fragment slot holds an MTLFunction whose `vendorPrivate` AGX already set as another stage's holder (the same function object was used earlier as a vertex, object or mesh function), then AGX reads `VertexProgram+0x10` (a small integer or padding) as an `AGXG19FamilyFragmentProgram*`, adds 8, and locks at `+0x6d8`. That is a SIGSEGV in `os_unfair_lock_lock` at a low address, matching the top of the reported stack. A compute or tile kernel in the fragment slot would not crash here, because it shares the holder class and `_frag` is created lazily.

Apple's host can't do this, because each function ref is its own MTLFunction. In Henge, the stale-task path in section 2 is a direct way to put one object in two stage slots.

**Open, and cheap to settle:** the reporter's `.ips` should carry the fault address. A small address a little above 0x6e0 would confirm the stage-mismatch reading. I didn't download it. A guard in `makeSerialized` that requires `fragmentFunction.functionType == MTLFunctionTypeFragment` (and `vertexFunction` to be a vertex function) before creating, with a log of refs, names and the `vendorPrivate` class on a mismatch, would turn a crash into a log line.

Other things that would also crash here: a non-MTLFunction object that answers `vendorPrivate` with something non-nil. An object that doesn't answer it raises an ObjC exception, not SIGSEGV.

## 5. Surfaces and page lists

### The layout (confirmed)

`-[PGIOSurfaceHostDevice mapSurface:]` in the framework: a surface's page list is a **page table**, not a flat array.

- Entry = (16 KB page number << 2) | flags. Flag `01` is a leaf page, `11` a table page.
- Up to 4096 pages (64 MB) are flat in the list page: 16 KB / 4 bytes = 4096 entries.
- More than that, the list page is the **root** of up to 4096 table pages of 4096 entries each.

I checked this at the `tbnz` on bit 0, the `lsr #2` that gives 4096 entries per page, and the `bics` against 3 for table entries (value 11) and `and #3` for leaf entries (value 01). The guest kext wasn't available to cross-check the guest side. A fork by Veyron (commit `0672f05c`) reached the same two-level reading independently, which I used as a cross-check.

Henge's `newSurface` read the list as `n * 4` contiguous bytes with `(v & ~1) << 12`. For a surface over 64 MB it therefore mapped the table pages as if they were pixels, then `vm_remap`-aliased junk entries into the Metal buffer. The fix is `surface_page_entry` in `devices/pvg_metal.m` (fork commit `c65a236`; upstream #172, now in #187).

Separately, pvg_lite's own task-memory reader already walks a multi-level table (`run = 4096 - in`), so the code base had both readers.

### The first-boot kernel panic

What happened: the macOS 27.2 restore finished, I started the Mac with 6 GB of guest RAM (the install had used 4 GB), and about 80 seconds into the first boot the kernel panicked.

**Confirmed from the saved log:**

- The guest created two surfaces of 3840x2640, fourcc RGhA, 79,200 KB each (4,950 pages). They are the last two surface lines before the first undefined instruction.
- Henge logged three "undefined" EL1 instructions at three kernel text addresses. The panic text names the first: `Undefined kernel instruction: pc=0xfffffe002a1743d8 instr=8350d68`. The others were `05f00ac4` and `e7ffdeff`. The kernel text looks overwritten.
- `0x08350d68` and `0x05f00ac4` read as half-float pairs, which fits RGhA pixels landing on kernel text.
- A nested panic followed ("Nested panic detected - entry count: 2").
- `0xe7ffdeff` shows up again at the same offset from the vector base (+0x5eea8) in a later, unrelated boot of the same log, so it is probably the kernel's own panic trap and not corruption. That makes `08350d68` and `05f00ac4` the interesting two. **Inferred**, not checked against a kernel image.

**Inferred root cause:** the flat read of a 4,950-page list. Entries past the first page came from whatever memory followed the list page, and `vm_remap` aliased those guest pages into the GPU's buffer, so the GPU wrote pixels there, including over kernel text. It fits the timing and the numbers, but it is **not proven**:

- The 1x boot that would exercise the fix (a Mac at 1920x1320, where the 3840x2640 surfaces appear) was never run on the Duo. My build at Retina made surfaces up to 38,964 KB, under the 64 MB threshold, so it didn't exercise the path.
- The same >64 MB surfaces appeared again in a second boot with no panic. So size alone isn't the trigger. What the junk entries point at decides whether anything breaks. That second boot's guest may have been silently corrupted.
- #187 is not device-tested in its combined form; #172 was tested through the unit harness only.

**Open:** run the 1x boot on a device with and without the fix and watch for the panic and for `pvg-metal` surface lines with 4,950 pages.

## 6. Why Safari showed blank pages on macOS 27

README and Install tab used to warn that Safari's pages may stay blank on 27. The cause is in how multi-plane surfaces were handled. The full write-up is in `docs/duo/safari-notes.md`; this is the short version with the facts I'd want next to the code.

- **Confirmed.** macOS 27's WebKit draws page tiles into `b3a8` surfaces (`kCVPixelFormatType_30RGBLE_8A_BiPlanar`: plane 0 is 10-10-10 RGB, plane 1 is 8-bit alpha) in its GPU process, and WindowServer composites them. In the Duo logs the layout was plane 0 at offset 0 with 1536-byte rows and 352 rows, plane 1 at offset 540,672 with 512-byte rows.
- **Confirmed from code.** Henge drew one-plane surfaces straight into the guest's pages (textures sit on a buffer that aliases the pages by `vm_remap`). A multi-plane surface got its own host IOSurface. Guest pixels were copied in when a sampled hash changed, and **nothing copied the GPU's drawing back** (`synchronize` and `page:toGuest:` cover only guest-backed objects).
- **Inferred.** The tile WebKit drew existed only in the host copy. When the last mapping of the surface closed, the copy was dropped, and the next mapping (by WindowServer or the GPU process again) was rebuilt from guest memory that had never been drawn in. Alpha 0 means a fully transparent tile, so the page looks blank. A guest CPU write to a plane also changed its hash and copied stale bytes over the GPU's drawing.
- **Fix** (#187, replaces #143): each plane gets a linear texture on the guest pages at that plane's offset and row stride, the same way one-plane surfaces work. `HV_PVG_PLANAR_COPY=1` brings back the old path for A/B runs. A view that can't sit on the pages gets a host IOSurface copy and a log line ("cannot sit on its pages; host copy").
- **Verification:** on the Duo, boot B showed a fully drawn Wikipedia article. The "before" half (`HV_PVG_PLANAR_COPY=1`) was **not run**, so I haven't shown the old path blank on my device. The earlier Duo logs never loaded a real web page, only the Start Page. #187's text says the original change was tested on an iPhone with macOS 27.2.

## 7. Linear textures (#137)

**Confirmed with a probe on an M2 Pro.** Metal's rule for a buffer-backed texture is:

- Required length = `offset + row * (height - 1) + width * bytesPerPixel`, not `offset + row * height`.
- With `MTL_DEBUG_LAYER=1`, a buffer one byte short asserts "Length required by texture offset, bytes per row, height and array length(114480) exceed buffer capacity(114479)". **Release Metal doesn't check the length at all**, so a short buffer is not caught there.
- The offset and bytes-per-row alignment checks abort even in release Metal. For BGRA8 on that Mac the minimum is 16 bytes (`minimumLinearTextureAlignmentForPixelFormat`), and bytesPerRow 1448 or 1444, and offset 11956, all abort.

The case that mattered: a 72x72 BGRA8 icon on rows of 1,440 bytes at offset 11,952 in a 114,688-byte buffer needs 114,480 bytes. Henge's `linear_texture_fits` demanded whole rows (115,632) and refused with "can't sit on rows", so the icon was never drawn. After #137 on the Duo (20 apps and several Finder folders) there were no such lines and pvg-metal logged 1,081,457 draws with 0 failed.

**Open:** I measured the minimums on a Mac. The A20's alignment minimum isn't something I queried on the phone.

## 8. The display page, events and live mode changes

These are the facts behind #190. The guest's `AppleParavirtDisplay` is in `AppleParavirtGPUIOGPUFamily`.

### Page offsets

| Offset | Meaning | Source |
|---|---|---|
| +0x14 | Panel size macOS was given | read for pointer sizing |
| +0x60 | Display flags. 0 or 2 makes `createDisplayAttributes` set the framebuffer's `external` | 27 disassembly |
| +0x68 | `protectionOptions` (read by `get_protection_options`) | 27 disassembly |
| +0x100, +0x104 | Event register and mask. `start_hardware` sets 0xc | 27 disassembly |
| +0x200 | Mode sequence number; the guest acks it | trace and source |
| +0x1014 | Per-port event bitmask, read to clear | PVG framework |
| +0x1234 | Per-port 2-bit connection type (BAR). 0 resolves to external | 27 disassembly |

### Events

- **Confirmed.** In macOS 27's `AppleParavirtDisplay::handleHostInterrupt`, bit 2 (value 4) calls `createDisplayAttributes` and bit 3 (value 8) calls `destroyDisplayAttributes`. **Event 8 is the driver's disconnect, not a refresh.** The first mode list at hotplug raises event 4; a later change raises event 4 only. Raising 8 drops DisplayAttributes.
- **Confirmed.** The guest times its own refresh with an `IOTimerEventSource`, so the host needs no refresh event. With `HV_PVG_VBLANK=1` the host tore the display down at the refresh rate; that experiment is removed.
- **Confirmed** from the framework's `_PGDisplayNub` state machine: the guest acks a mode through a FIFO command (`CmdDisplayAck`), the live change can only start from state 2 with events 0xc, and a newer size waits until the guest has acked the one before it.
- The Mac-host path (`devices/pvg_mac.m`) uses Apple's real `PGDisplay`, whose readwrite `modeList` simulates a hotplug on first set. `PGDisplay` has no corner or cutout concept, so rounded corners need a host-side mask.

### Live resize results

- A first live-resize build **failed on fold/unfold**: after the first mode (`display ack 1`) the host published 1920x1184 (`display mode ... seq 2, mask c`) and the guest never acked it. The build that followed Apple's state machine (fork `b42f997`) passed with acks 2 and 3 about 100 ms apart (1920x1320 folded, 2848x2000 unfolded). The working builds log `+100 e` on the mode line and the failing one doesn't; I haven't decoded that field.
- The autopilot `check` run (rotate, tall, outer, back) acked every mode, with no stretching and a 1.002 pixel ratio at full screen.
- Pointer position wasn't verifiable from `check` or `snap`, because they omit Henge's pointer overlay.

### Built-in panel

**Confirmed.** `AppleParavirtGPU::start` reads each port's connection type at +0x1234 and treats 0 as external; `createDisplayAttributes` reads flags at +0x60 and sets `external` for 0 or 2. Returning 1 at +0x1234 for port 0 and writing 1 at +0x60 gives `primary` = 0 and no `external` flag, verified on the Duo. That is #190 (replaces #154). The rest of the corner chain (the CoreUI shape, the device-tree subtype) is in `docs/display-corners.md` and #193.

### Open: what +0x68 means

- #161 found that a macOS 15.6.1 getter reads a 64-bit time at +0x68, and reports that writing the refresh time there removed WindowServer's "Timer delayed by <uptime>s" lines and an interrupt storm on 15.6.1.
- The macOS 27 disassembly says +0x68 is `protectionOptions`, and on the Duo writing a counter there stalled desktop bring-up.
- Both can be true if the field changed meaning between 15 and 27. I don't know that. I've said as much on #161; limiting the write to guest versions where it is the refresh time would reconcile the two. Nobody has checked the 26.x kernels.

## 9. The pipeline archive (#188, from #152)

iOS clears its own Metal shader cache between launches, so Henge compiles every macOS pipeline from scratch each boot. #188 saves pipelines in `MTLBinaryArchive` files named for the OS build and GPU.

**Confirmed from the logs:**

- Rewriting one archive file each time kept only the newest pipelines. Writing a new numbered file with just the additions fixed that.
- Render pipelines with no fragment function can't be archived: Metal fails with "expecting 'fragment' stage in pipeline no. N", and the whole batch is lost. The first logs show this error on many saves. The fix (fork `586223d`) skips archiving those pipelines. On the fixed build, the first boot wrote files 0..10 with 0 not saveable, and the second boot loaded 11 files (12.9 MB) and served 527 pipelines from archives against 15 compiled.
- A pipeline loaded from an archive logs about 0.1 ms; a compiled one logs 0 to 2 ms.

**Open, and worth knowing before anyone quotes the numbers:** the PR text quotes 420 to 550 ms per pipeline. The log's "compiled (N ms each)" figures never exceed 2 ms, so the logged counter either measures only part of the compile or the slow cost was seen under different conditions (a cold compiler cache). I haven't resolved it. The archive's benefit is the hit rate in the last bullet above, not a measured per-pipeline time.

## 10. Readback and network (item 15)

- **Confirmed from the stats lines.** Setup Assistant ran at about 30 fps with GPU encode time and wait time negligible (a late stats line: encoding 0.07 s, waiting for the GPU 0.01 s over about 2,000 execs). There was a roughly 170 second readback phase early in boot where "synced" went from 1,790 to 14,665 and "remaps" from 781 to 2,746.
- **Confirmed.** Network works over a wired virtio-net en0: 77,342 frames out and 567,448 in, 415 DNS answers, 0 timeouts. No Wi-Fi device is modelled, so the Wi-Fi icon is off.
- **Confirmed.** Memory headroom stayed above 3 GB before jetsam; resident memory fell from about 5.6 GB to 2 GB while the physical footprint stayed high (iOS compressing guest pages). The hidden cost of paging them back in is **open**.

## 11. Two panics that aren't GPU bugs

### The restore panic behind #73 and #144

- **Confirmed.** During the macOS 27.2 restore, iBSS finds no vPMU header in the aux file, takes its init path, writes 10 bytes (`55 4d 50 76 01 00 00 00 04 00`, "UMPv", version 1, halfword 4) to aux sector 32768 over bdif, and panics at `70b7ca7d373f8bb:144` if that write fails. That sector is device offset 0x1000000, file offset 0x1004000 after the 16 KB aux header.
- **Confirmed.** Upstream commit f0eec63 (Tu Phan, 2026-11-07) made bdif serve aux writes (`devices/bdif.c`, `DATA_FLAGS_WRITE` 0x00010001). A macOS 27.2 install on my Duo finished on a tree with f0eec63 and without #73. The auxiliary file afterward held exactly those 10 bytes at 0x1004000, written by the guest, and no log shows the :144 panic.
- **Inferred.** That makes #73's seed redundant on a tree with f0eec63. #73's base already contains f0eec63, so the author may have hit the panic on a build where the bdif write failed for another reason, and that reason is the thing to find. The #73 description names a bounds-checked registration helper that runs before the buffer exists; I haven't reproduced or disassembled that path.
- #144 adds a regression test for the write path: an aux write must succeed and land at file offset 16384 + sector * 512. It fails if bdif's write branch is disabled.
- The research folder for #73 held no other restore-panic findings. The rest of it is a fork survey and a JIT comparison, which belong elsewhere.

### The stale panic log (#142)

After one kernel panic, macOS showed the same report at every boot.

- **Confirmed.** `/usr/libexec/DumpPanic` (launchd job `com.apple.DumpPanic`, run at boot) finds the panic store as an IOMedia by property, reads 0x240000 bytes, and clears it with `DKIOCUNMAP`, not zeroes. The message "Embedded panic log header contains invalid panic log offset" comes from `PanicProcessingSupport.framework`, called by DumpPanic.
- **Confirmed from the disassembly.** DumpPanic unmaps as soon as the read succeeds, before any decode, so a malformed header can't block the clear. It unmaps one extent of one block at offset 0, which is the header only. The rest of the 2.25 MB read stays non-zero.
- **Confirmed.** Henge's virtio-blk advertised only SEG_MAX, RO, BLK_SIZE and FLUSH, so the unmap failed and the PEEP record at aux 0x1504000 survived. #142 offers `VIRTIO_BLK_F_DISCARD` and `WRITE_ZEROES` on the aux disk only and zeroes the given range (fork `13d8e61`). On the Duo with that build, a new boot made no new report and DumpPanic logged no unlink failure. Two forks independently made the same change (Veyron `5727a7a`, lingbing09 `680e89dd`).
- **Inferred.** The malformed header ("PANI" magic at the odd offset 0x1504341) probably comes from pvpanic halting the VM (`devices/vmapple.c`, the pvpanic write handler) before the guest finishes writing it. Deferring that halt is untried.
- **Open.** The old panic text beyond the first block is still on the disk after DumpPanic's unmap. Whether the decoder drops a record with a zero magic, as the strings suggest, hasn't been checked. If a dialog returns after the fixed build's second boot, clear the PEEP region once (back up `auxiliary.bin` first).
- **Open.** The only unsupported aux request in my logs was type 0x4d at sector 9. I don't know what it is.

## Open questions, in the order I'd chase them

1. Fault address in the #102 `.ips` (confirms or kills the stage-mismatch reading).
2. A 1x boot on a device to exercise the >64 MB surface path, with and without #187.
3. What `+0x68` means on macOS 26 and 27 versus 15, and whether the refresh time belongs there at all.
4. The pipeline compile time: why the logged cost is 0 to 2 ms against the 420 to 550 ms quoted.
5. Safari "before" run with `HV_PVG_PLANAR_COPY=1`, to show the old path blank on a device.
6. The `+100 e` field in the mode-change log and why the first live-resize build never got its ack.
7. The A20's linear-texture alignment minimum on the phone itself.

## Reproducing the analysis

- Extract the framework: `/usr/lib/dsc_extractor.bundle` on the macOS dyld cache. The GPUTask service is a standalone Mach-O at `/System/Library/Frameworks/ParavirtualizedGraphics.framework/Versions/A/XPCServices/com.apple.gpusw.ParavirtualizedGraphicsGPUTask.xpc/Contents/MacOS/`. Take the arm64e slice.
- The GPUTask binary's `__objc_stubs` calls need their selectors decoded from `__objc_selrefs` chained fixups before the disassembly reads well; I annotated each stub that way.
- For AGX, the iOS device-support symbols for the phone's OS carry `AGXMetalG19P` with local symbols. The macOS dyld cache has the same driver built from the same templates, and its stubs can be named from the mapped cache.
- To see what the guest sends: `HV_PVG_OPS=1`, then compare the first 0x38 and 0x20 words against the commands that follow.
