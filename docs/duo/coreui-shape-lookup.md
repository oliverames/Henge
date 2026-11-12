# CoreUI display-shape lookup and Henge recovery/aux research

Host: macOS 27.3 dyld shared cache (arm64e). Guest is 27.2; the host copy is used as a proxy (CoreUI differences between 27.2 and 27.3 not checked).
Tools: `ipsw dyld disass` (symbols, `--vaddr`), `ipsw dyld macho CoreUI --strings` for CFSTRs, in-process ObjC runtime (ctypes) to get method IMPs. Scratch: /private/tmp/claude-501/-Users-oliverames-Developer/dd0bcb52-4e09-4bba-b6cd-00c5e9237670/scratchpad/agent-coreui/ (full.ann = annotated disassembly of the whole function).

## 1. Files
Copied 7 files (Eraserhead_1506/1665/1864/1964/1986/2234/2266.svg) to
/Users/oliverames/Developer/Forks/henge-worktrees/project-files/display-shapes/
(/mnt/project-files does not exist on this Mac; that is the path.)
Host `assetutil --info` of SystemAppearance.bundle/Contents/Resources/Assets.car lists exactly these seven Eraserhead_<N> names.

## 2. CoreUI: CUICreateDisplayShapeAndComputeCornerRadius (0x18f3cd0f8)
`CUICreateDisplayShape` (0x18f3cdcbc) is `mov x2,#0; b CUICreateDisplayShapeAndComputeCornerRadius`.

Annotated excerpt (args: x0 = subtype or 0, w1 = shape kind 0..9, x2 = out corner radius*):
```
18f3cd144 cbnz x0, 18f3cd194            ; caller supplied a subtype -> skip lookup
18f3cd148 adrp/add x0 = CFSTR "oPeik/9e8lQWMszEjbPzng"  (MobileGestalt obfuscated key)
18f3cd154 bl MGCopyAnswer               ; returns a dictionary
18f3cd160 x2 = CFSTR "ArtworkDeviceSubType"
18f3cd164 bl -[NSDictionary objectForKey:]
18f3cd168 bl -[NSNumber integerValue]   -> x21 = subtype
18f3cd178 cbnz x21, 18f3cd194
18f3cd17c bl MGGetProductType           ; fallback only when subtype == 0
18f3cd180 w8 = 0x5fa96328 ; cmp x0,x8 ; csel x21 = 0x5e2 (1506) if equal else 0
18f3cd194 str x21,[sp]
18f3cd19c x0 = CFSTR "Eraserhead"; x2 = CFSTR "_%lld"
18f3cd1a8 bl -[NSString stringByAppendingFormat:]      -> "Eraserhead_<subtype>"
18f3cd1b8 bl +[CUISharedArtCatalog sharedInstance]
18f3cd1dc bl -[CUICatalog namedVectorImageWithName:scaleFactor:deviceIdiom:deviceSubtype:displayGamut:layoutDirection:sizeClassHorizontal:sizeClassVertical:appearanceName:]
          (scale 1.0, idiom 7, everything else 0/nil)
18f3cd1e4 cbz x21, 18f3cd45c            ; not found -> skip to corner-radius only
18f3cd1fc isKindOfClass:CUINamedVectorSVGImage ; 18f3cd208 -svgDocument ; CGSVGDocumentGetRootNode ...
```
Then it reads SVG nodes by id: eraserhead-{topleft,left,bottomleft,bottom,bottomright,right,topright}, island-outer-{left,top,right,bottom}, inner-bezel-{topleft,top1,top2,topright,right,bottomright,bottom,bottomleft,left,island} (CFSTRs at 0x18f3cd350-0x18f3cd7a8). Not found path: `_detectCornerRadius` only (0x18f3cd45c-0x18f3cd468).

Stubs resolved by reading the objc selector stub (adrp/add selector, `b objc_msgSend`) with `ipsw dyld disass --vaddr`: 0x190066910 objectForKey:, 0x19005d650 integerValue, 0x1900860b0 stringByAppendingFormat:, 0x190082ba0 sharedInstance, 0x1900db400 namedVectorImageWithName:..., 0x190086e00 svgDocument. (The earlier dladdr approach prints "?" for these because they are objc stubs, not symbols.)

### How SystemAppearance.bundle is located (PROVEN by disassembly)
`+[CUISharedArtCatalog sharedInstance]` (0x18f34d638) dispatch_once block `___37+[CUISharedArtCatalog sharedInstance]_block_invoke` (0x18f34d6c8):
```
18f34d6e4  x0 = NSBundle
18f34d6e8  x2 = CFSTR "com.apple.systemappearance"
18f34d6f0  bl +[NSBundle bundleWithIdentifier:]
18f34d6f8  cbnz x0, ...                       ; non-nil -> use it
18f34d700  x2 = CFSTR "/System/Library/CoreServices/SystemAppearance.bundle"
18f34d708  bl +[NSBundle bundleWithPath:]     ; fallback
18f34d718  x2 = CFSTR "Assets"
18f34d728  bl -[CUISharedArtCatalog initWithName:fromBundle:error:]   (name "Assets", error nil)
```
So: opened by **bundle identifier first (`com.apple.systemappearance`), then by absolute path `/System/Library/CoreServices/SystemAppearance.bundle`**, catalog name `Assets`. Host Info.plist CFBundleIdentifier = `com.apple.systemappearance` (verified with PlistBuddy).

Chain after that (PROVEN):
- `-[CUISharedArtCatalog initWithName:fromBundle:error:]` (0x18f34d744) -> super -[CUICatalog initWithName:fromBundle:error:] (0x18f34d7e0); also sets NSCache named `com.apple.systemappearance-cache-` + name.
- CUICatalog init calls `+[CUIThemeFacet themeNamed:forBundleIdentifier:error:]` (0x18f347684) with the bundle's `bundleIdentifier`. It builds a cache key `"<bundleID> <name>"` (default name `AppThemeBits`) and runs `___RunTimeThemeRefForBundleIdentifierAndName_block_invoke` (0x18f3478f4): in-memory theme-ref dictionary lookup first; then if the id has prefix `kCUIMutableStructureThemeStoreBundlePrefix` -> CUIMutableStructuredThemeStore; else `[NSBundle bundleWithIdentifier:id]` and `pathForResource:@"Assets" ofType:@"car" inDirectory:nil` -> `[[CUIStructuredThemeStore alloc] initWithPath:]`. Error strings: "RunTimeThemeRefForBundleIdentifierAndName() couldn't find %@.car in bundle with identifier: %@".
- Effective file: /System/Library/CoreServices/SystemAppearance.bundle/Contents/Resources/Assets.car (host: exists, 3,386,040 bytes, Oct 31).

### What is NOT checked first (PROVEN for the paths above, INFERRED beyond them)
In CUICreateDisplayShapeAndComputeCornerRadius, sharedInstance, its block, CUICatalog initWithName:fromBundle:error:, CUIThemeFacet themeNamed:..., and the RunTimeThemeRef block, I found no defaults key, no getenv, no /Library or ~/Library path and no /var/folders cache. The only pre-checks are: (a) the caller-supplied subtype argument, (b) MobileGestalt "ArtworkDeviceSubType", (c) the in-process theme-ref cache and NSCache (memory only). CoreUI's cstring table has no preference-key or env-var names for this (only CUIShowDebugLogs, DYLD_LIBRARY_PATH in unrelated code). I did not disassemble CUIStructuredThemeStore initWithPath: / CUICommonAssetStorage internals, so a file-level cache there is not excluded (INFERRED unlikely; the only cache-ish strings are `com.apple.CoreUI.UICatalog-cache`, used by defaultUICatalogForBundle:, a different entry point).

### Nearby strings
CFSTRs: com.apple.systemappearance (0x1e2ed3570), SystemAppearance (0x1e2ed3590, not used on this path), /System/Library/CoreServices/SystemAppearance.bundle (0x1e2ed8310), Assets (0x1e2ed8330), com.apple.systemappearance-cache- (0x1e2ed8350), AppThemeBits (0x1e2ed6cf0), `%@%@%@%@%@.car` (0x1e2ed7110), ArtworkDeviceSubType (0x1e2ed60f0), Eraserhead (0x1e2ed6410), `_%lld` (0x1e2ed6430). Cstrings: SystemAppearance.bundle (0x18f4ab8f0), /System/Library/CoreServices (0x18f4ab923).

### Consequence for the guest (INFERRED)
The artwork shown is chosen by MobileGestalt ArtworkDeviceSubType. If the guest returns 0 (or the product type VirtualMac2,1 is not 0x5fa96328), the name is "Eraserhead_0", the lookup finds nothing and only `_detectCornerRadius` runs. A match needs subtype in {1506,1665,1864,1964,1986,2234,2266}. The fallback 1506 applies only to product type hash 0x5fa96328 (which product that is was not identified). Fixing means making the guest's MobileGestalt `ArtworkTraits`-style answer (key "oPeik/9e8lQWMszEjbPzng"; name is my guess from the dictionary contents) report one of those subtypes, not changing where Assets.car is found.

## 3. Henge source (worktree duo-combined, HEAD 66ab459)

### Recovery boot: no option exists (PROVEN by grep, absence)
`grep -i recovery|boot-args|bootargs|nvram|localpolicy|startUpFromMacOSRecovery` over host/, devices/, ios/Henge/, core/, docs/ finds no recovery boot mode, no boot-args/NVRAM handling, no LocalPolicy code. The only "recovery" hits are libirecovery (tools/build_ios_restore.sh:31,70; host/install.c:5; host/libusb_shim.c:3,10; devices/virtio_usb.h:10 = USB iBoot recovery mode in the restore flow) and the disk layout note ios/Henge/DiskGrowth.swift:9,25-26 (a 5 GB recovery container at the end of the disk, so recoveryOS is installed on the disk).
Only two boot modes exist:
- normal ROM boot;
- installer/DFU: `HvVmConfig.installer` (host/vm.h:22) -> cfg.run_installer1/2 = 1 (host/vm.c:418-422, env `HV_RUN_INSTALLER="a,b"` experiment) written at cfg offsets 0x028/0x034 (devices/cfg.c:22,25,98,101; devices/cfg.h:14) and attaches the virtio USB device port (devices/vmapple.c:329-333). Installer session entry: ios/Henge/Native/henge-vm.c:233,238.
No equivalent of VZ's startUpFromMacOSRecovery (power-button-hold) is implemented. INFERRED: on real VZ, recovery selection is done by iBoot reading its own state (NVRAM/power button input) rather than a cfg word; so a Henge implementation would most plausibly write the NVRAM variable iBoot honours into the aux image, or emulate the power-button signal. Which one is not established from this source or from this research.

### Where NVRAM / LocalPolicy / aux storage live
- Henge has **no separate NVRAM or LocalPolicy file**. NVRAM and iBoot's persistent data sit inside the auxiliary storage image, which the guest reads and writes as a block device. (INFERRED from Virtualization.framework's auxiliary-storage design and the code below; Henge never parses it.) The "AvpRtc" NVRAM offset is the only NVRAM mention (devices/vmapple.c:66, comment).
- LocalPolicy on Apple silicon macOS lives in the iBoot system container on the disk (disk.img), not in aux (INFERRED; DiskGrowth.swift:25 names the "iBoot system container" as the first container; not read).
- Creation: `henge_make_aux(path)` ios/Henge/Native/henge-vm.c:249-258 (declared henge-vm.h:22-23): writes a 24-byte header `a5 d5 b3 fe 97 ad 1d 27 | 01 00.. | 01 00..` then `ftruncate(33570816)` (32 MB + 16 KB), file mode 0600. Caller: ios/Henge/Installer.swift:210 inside `prepare(name:ramMB:rom:)` (~197-217), together with disk.img (64 GB sparse), machine.json (ecid, seed, ramMB), AVPBooter ROM copy.
- Paths: ios/Henge/Machines.swift:36 (`aux` = `<machine dir>/auxiliary.bin`), :75 (required files), :187 (file list), :258 (copy on clone/export). Desktop export: tools/export_ios.sh:14.
- Open/serve: host/vm.c:407 opens aux with offset `c->aux_offset ? : 16384` (the first 16 KB is metadata the guest never sees; host/disk.h:6-7); CLI flag `--aux-offset` host/main.c:1123; host/hvf_ref.c:149. Guest access via the bdif MMIO device: devices/bdif.c (DEVID_AUX 0x10000 at line 9; capacity register 154-155; `command()` 161-186 does sector read/write; `bdif_write` 188-199), created in devices/vmapple.c:302 (`hv_bdif_create(m, VMAPPLE_BDOOR, root, aux)`), header devices/bdif.h:32. Snapshot of bdif state: host/snapshot.c:492,551; snapshot also records aux inode/size (host/vm.h:86).
- Aux writes go through `hv_disk_write` (host/disk.c), so anything iBoot stores there persists in auxiliary.bin immediately (not cached in a Henge struct).

## Proven vs inferred summary
Proven: Eraserhead_%lld naming; MobileGestalt ArtworkDeviceSubType source; lookup via CUISharedArtCatalog -> NSBundle bundleWithIdentifier "com.apple.systemappearance" then path fallback -> Assets.car; no env/defaults/Library/var-folders check on that path; Henge has no recovery-boot code; aux creation/open/bdif locations.
Inferred: guest behavior when subtype is 0; meaning of MG key oPeik...; NVRAM and LocalPolicy placement; how real VZ selects recovery; 27.2 equals 27.3 for this code.
