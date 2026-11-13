# Corner radius, safe aperture and menu bar leading inset: where macOS reads them

Host: macOS 27.3 dyld shared cache (arm64e), used as a proxy for the 27.2 guest. Differences between 27.2 and 27.3 were not checked.
All addresses are unslid cache addresses. Tools: `ipsw dyld disass --image <X> --quiet` (whole-image disassembly, 2 s per image), `ipsw dyld str` / `macho --strings --symbols --objc --swift`, in-process ctypes calls on this Mac for ObjC IMPs and stub resolution, plus a live call of the SkyLight inset function (below).
Scratch (helper scripts, disassemblies): host scratch, not kept (`xr.py` string xrefs, `callers2.py`, `resolve.py` stub resolver, `show.sh`/`show2.sh` symbolized function dump, `inset.py` live probe).
Labels: PROVEN = read in disassembly or observed live. INFERRED = reasoning from proven pieces, flagged where the last link is missing.

## 0. Short answer

1. The 1964 notch shape gives you the notch, the aux areas and the CoreUI/SkyLight corner radii of a MacBook Pro 14 (about 21 pt). Nothing in CoreUI, SkyLight, HIToolbox or AppKit moves the Apple menu or the clock away from a corner because of a corner radius or bezel arc. PROVEN for the paths below, with the gaps listed in section 6.
2. The only horizontal inset of menu bar content that I found is `SLSMenuBarPrivacyIndicatorInset`, consumed by AppKit as `NSMenuBarDisplayManager leadingInsetForDisplay:` and by SkyLight's status item clipping. It is a lookup table keyed on display pixel density, returns at most 12 pt, and is gated on a display capability bit and on a non-zero IOMFB display area (physical size in inches). It cannot clear a 59 pt radius. See section 4.
3. The notch itself only reserves 20 pt on each side of the notch rectangle in the middle of the bar. It does not push left-hand items inward (section 4).
4. `display-corner-radius` (IORegistry `IODeviceTree:/product`) is read only by libMobileGestalt (MG key `DeviceCornerRadius`). I found no consumer in CoreUI, SkyLight, QuartzCore, CoreDisplay, AppKit, MonitorPanel, HIToolbox or IOMobileFramebuffer user space. The one confirmed caller is UIKitCore `-[UIScreen _displayCornerRadius]` (Catalyst and iOS-on-Mac only).
5. Recommendation: do the inset on the host side (render the guest inside the safe area, or present a guest mode smaller than the panel and mask the corners in Henge). Details in section 5.

## 1. CoreUI `_detectCornerRadius`

PROVEN. `__detectCornerRadius` (0x18f455d74) is a thin wrapper (retain, call 0x18f455dcc, release). Signature is effectively `double _detectCornerRadius(CGPathRef path, int partID)`.

- Input: a `CGPath` built from the SVG nodes of `Eraserhead_<subtype>`, plus a `CUIDisplayShapePartID` (the `w1` argument of `CUICreateDisplayShapeAndComputeCornerRadius`, 0x18f3cd0f8). There is no key lookup, no defaults and no IORegistry/MG access inside it. A NULL path returns 0.0 (0x18f455e84 `cbz x19`).
- The call site is `0x18f3cd45c..0x18f3cd46c`: `if (out) *out = _detectCornerRadius(path, partID)`. When the SVG is not found (subtype 0, no `Eraserhead_<n>` asset) the path is NULL, so the radius is 0 (previous report, section 2).
- Part IDs 5, 6, 7, 8 select the corner by an affine transform of the path bounding box (0x18f455f70..0x18f456078): 5 = top left (translate -minX,-minY), 6 = top right (mirror about maxX), 7 = bottom left, 8 = bottom right; 9 uses the path width. The transformed path goes to 0x18f456644, which bisects scanlines against the path (steps scaled by 10, tolerance in `d1`) to find where the curve leaves the bounding box edge. In other words, the radius is measured geometrically from the SVG arc.
- The only upstream input is therefore the artwork subtype chosen by `MGCopyAnswer("oPeik/9e8lQWMszEjbPzng")` (ArtworkTraits) key `ArtworkDeviceSubType`, or the caller-supplied subtype (section 3.3). I verified the key hashes: `base64(md5("MGCopyAnswer"+name))[:22]` reproduces `oPeik/9e8lQWMszEjbPzng` for `ArtworkTraits`.
- SVG nodes read by `CUICreateDisplayShape*`: `eraserhead-{topleft,left,bottomleft,bottom,bottomright,right,topright}`, `island-outer-{left,top,right,bottom}`, `inner-bezel-{topleft,top1,top2,topright,right,bottomright,bottom,bottomleft,left,island}`. The CFSTR `menubar-bottom` (0x1e2ed6150) exists in CoreUI and in the 1964 SVG (`y = 20.9256`), but I found no code reference to it. INFERRED: unused by this function.
- Observation from `Eraserhead_1964.svg`: the top-left arc radius is 20.9256 and `inner-bezel-top1` runs from x = 20.9256 to the notch. That is the MacBook Pro 14 geometry in SVG units.

## 2. Readers of "display-corner-radius" and its variants

### 2.1 libMobileGestalt (the only reader of the IORegistry property)

PROVEN. The string `display-corner-radius` exists once in the cache, in libMobileGestalt (0x186ef4130), plus the error string `Failed to copyDeviceTreeProperty(IODeviceTree:/product display-corner-radius)` (0x186ef127f, 0x186efaa61).

- It is an MG key, not a plain IOMFB property. Key name `DeviceCornerRadius` (strings 0x186ededd0 and 0x186ef4090). Obfuscated key `y5dppxx/LzxoNuW+iIKR3g` (0x186eec2d9; computed with the md5 recipe above, it matches).
- Table entry: file offset 0x9d240 holds `{key string 0x186eec2d9, getter 0x186ea0e10}`.
- Getter 0x186ea0e10: calls the device-tree helper at 0x186e79d3c with path `IODeviceTree:/product` (cstring 0x186ee915d) and property CFSTR `display-corner-radius` (CFSTR 0x1e261fb20, verified). The result must be `CFData` of exactly 8 bytes (otherwise a log and 0.0). Value = `float(u32[0]) / float(u32[1])` (u32[1] == 0 returns 0.0).
- The Swift module `MobileGestaltPrivate` has the same key (`DeviceCornerRadius.key` 0x186eba330, `DeviceQuery` ext 0x186eba368, a key to property table at 0x186eb5ef4..0x186eb5f90 listing `display-rotation`, `display-corner-radius`, `chrome-identifier`, `framebuffer-identifier`, `special-regions-count`). Exported C entry: `_MobileGestalt_get_deviceCornerRadius` (0x186e83c10), which calls `MGCopyAnswer` with CFSTR at 0x1e2615f00.
- Observed on this host (MacBook Pro 14, M2 Pro): `/product` and `/chosen` both have `display-corner-radius = <00000000>` (4 bytes, ioreg). An earlier version of this note said `/product` had none; it has a 4-byte zero. The getter needs exactly 8 bytes, so on a notch Mac the MG answer is 0 with an error log, and nothing in the OS depends on it for the Mac corner geometry. I found no user-space reader of the `/chosen` copy (kexts are not in the cache and were not examined).
- Callers: no other cache image contains the obfuscated key, so nothing in the cache calls it by that string. UIKitCore calls it by plain name: `___32-[UIScreen _displayCornerRadius]_block_invoke` (0x1ab656690) checks an internal preference (`DisplayCornerRadiusOverride`), then `MGCopyAnswer(CFSTR("DeviceCornerRadius"))` (CFSTR 0x1e54ce120). That is the Catalyst/iOS-on-Mac `UIScreen`, not the macOS menu bar.

### 2.2 Other variants

- `corner-radius` (RenderBox 0x196dbcd1a, LinkPresentation 0x1ce0850a6) and `match-corner-radius` (UIKitCore, AnimationKit) are view/animation properties. Irrelevant.
- `resolution-corner-radius` (MonitorPanel 0x20acfd618) is a key in the display preview image dictionary of System Settings (Displays pane). Cosmetic.
- `DeviceCornerRadius` plain string also appears in AppStoreComponentsDaemonKit, AirPlaySender, ReplicatorEngine, libramrod, ISP mediacapture bundles, UIKitServices (`UISDeviceContextDeviceCornerRadiusKey`). These are payload/dictionary keys; I did not trace them.
- SkyLight string `CornerRadius` (0x182ca41cd, CFSTR 0x1e2258fb0) belongs to `-[SLContentStreamUpdate cornerRadius]` and `_WSSelectiveSharingCreateMetaDataDict`. Unrelated.
- CoreDisplay, QuartzCore, IOMobileFramebuffer, CoreUI: no `display-corner-radius`, `DeviceCornerRadius` or obfuscated-key string.

## 3. Where the radius that WindowServer uses really comes from

### 3.1 SkyLight computes it from the Eraserhead SVG

PROVEN. `WS::Displays::Display::create_bezel_physical_path(unsigned partID, double* radiusOut) const` (0x18286bbb4):
- Returns NULL if `Display::is_dfr` (vtable +0x1c0) or byte `[this+0x2f5]` is set.
- Soft-links `CUICreateDisplayShapeAndComputeCornerRadius` (dlsym wrapper 0x18286e6c4, string 0x182c904aa; call thunk 0x18286cc14) and calls it with subtype 0, so CoreUI uses MG `ArtworkDeviceSubType`.
- Fallback: if the call yields no path and the static `fake_it` byte (0x1eb1b7118) is set, it calls again with subtype `0x7ac` (1964) (0x18286bcd8, 0x18286bda0). `fake_it` is set from the WindowServer boolean preference `FakePhysicalSarlacc` (CFSTR 0x1e2253670, `_WSBooleanPreferenceForKey` 0x18286f374). So there is a second route to the 1964 notch shape that needs no change to `/product`, but it needs a WindowServer preference in the guest. A sibling static `has_physical_sarlacc::fake_it` exists (0x1eb1b7128); I did not trace it.

`WS::Displays::Display::evaluate_display_parts` (0x18286c100) calls it 9 times:
- Parts 5, 6, 7, 8 (corners): path stored at `+0x110/+0x118/+0x120/+0x128`, radius stored at `+0x190` (TL), `+0x198` (TR), `+0x1a0` (BL), `+0x1a8` (BR), each multiplied by the sum of two scale fields of the display (`radius * ([+0x98] + [+0xa8])`, 0x18286c394..0x18286c510). A copy goes to `+0x2b0` when `current_mode_has_rounded_corners` (0x18286bf90), 0x18286ca30..0x18286ca44.
- Parts 1 and 3: rects at `+0x130` and `+0x150` (left and right aux areas, clamped by `validate_and_clamp_bezel_rect` 0x18286bf34). Part 2: path at `+0x100`. Part 9: island path `+0x108`, sarlacc rect `+0x170`.
- Menu bar height (`[this+0x2f0]`): if `current_mode_has_notch` (0x18286be6c), height = floor(rect +0x168 + 4 or 5), raised to at least 26 when `WS::Features::solarium_menubar_enabled()` is true, in 0x18286c5b4..0x18286c658; else a width-based or constant value (0x18286c614..0x18286c654). This is what turns a notch shape into the observed `safeAreaInsets.top` (32.5 in your run; the exact arithmetic of the 32.5 was not reconstructed).
- Notch rect: `has_sarlacc` (0x18286ce24) is true if the sarlacc rect at `+0x1d0` is non-empty. `current_mode_has_notch` (0x18286be6c) is true only when the notch rect at `+0x1b0` is non-empty AND the current mode is not a safe aperture (`SLCADisplay::is_safe_aperture_implicitly()`, vtable +0x160). See [menu-bar-corner-levers.md](menu-bar-corner-levers.md), section 4. Exposed as `WSDisplayGetSarlaccRect` (0x18286d8c8) and `PKGDisplayGetSarlaccRect` (0x182b11734).

### 3.2 Who uses the corner radii

PROVEN: the WindowServer side only.
- `SLSDisplayGetCornerRadii` (0x18284d38c) copies four doubles from the display record (offsets `+0xd0..+0xe8`).
- `PKGDisplay` creates corner layers/windows with the radii (`create_corner_window` 0x182b13d88, `compute_corner_region` 0x182b1432c, `update_corner_windows` 0x182b15a08, `corner_layer` 0x182b0ed8c). These draw the black rounded display corners that WindowServer composites.
- `Display::render_attributes` (0x18286b5d8) reads the stored values for the compositor.
- Window radii APIs (`CGXWindow::set_corner_radii` etc.) are per-window, not display-derived.
NOT FOUND: AppKit does not call `SLSDisplayGetCornerRadii` or `SLSDisplayIsSafeAperture` (I resolved all 41,743 `bl` stub targets of AppKit; none map to them). `-[NSScreen _cornerRadius]` (0x18b3b2b18) returns a field of the Swift `NSScreenManager` state (offset 0x70 of a 0x1b8 copy), or 0.0 if the state array is empty; I did not find where that field is filled. In AppKit the `_cornerRadius` selector callers are window and view code (NSThemeFrame, NSVisualEffectView, NSWindow resizing, corner styles), none of them `NSMenuBar*`.

### 3.3 Caller-supplied subtype

`CUICreateDisplayShape`/`...AndComputeCornerRadius` take `x0 = subtype` and skip the MG lookup when it is non-zero (0x18f3cd144). In SkyLight only `create_bezel_physical_path` and the fake route call it, with 0 and 1964.

## 4. Does the radius or bezel shape feed menu bar item placement?

### 4.1 Safe areas (NSScreen)

- `-[NSScreen safeAreaInsets]` (0x18b3b29a8) calls `-[NSScreen _notchFrame]` (selector stub 0x1900214b0, call at 0x18b3b29cc) and returns the notch height as the top inset, switching on a presentation mode (0x18b3b0ce4). The left and right insets are zero in the branches I read (0x18b3b2a0c..0x18b3b2ab8). PROVEN for the call, INFERRED for the exact mode meanings.
- `auxiliaryTopLeftArea` (0x18b3b4d74) and `auxiliaryTopRightArea` (0x18b3b4e84) derive from the same notch frame.
- `-[NSScreen _bottomCornerAvoidanceRect]` (0x18b3b2c3c) and `_bottomCompatibilityMargin` (0x18b3b2b74) are the only NSScreen members that I read that depend on corner values; callers are in window code (NSWindow fullscreen/resizing: 0x18ad73b3c, 0x18ae7ccf8, 0x18b1cfbe0), not menu bar code.
- So the corner radius does not feed `safeAreaInsets`. The notch (sarlacc) rect does.

### 4.2 Menu bar layout (HIToolbox)

PROVEN in disassembly:
- `HIMenuBarView::GetNotchWidth` (0x18efefbe0): takes the notch rect from `MBDisplays::GetNotchBounds` (0x18f090d54), outsets it by 20 pt on each side (`x -= 20`, `width += 40`, 0x18efefca0..0x18efefcbc).
- `HIMenuBarView::EnsureBarLayout` (0x18f1c8a68) and `ReallocateSpaceBeforeNotch` (0x18eff045c): titles that would cross the notch are condensed or truncated so the last one ends before the notch. `GetAvailableSpace` (0x18f1c93fc) subtracts `ReservedStatusItemSpace` on the right. No corner input.
- First title origin: `LayoutEachTitle` (0x18eff14f4) starts at `sStandardHalfExtra + 10` (theme constant, plus `GetThemeMenuTitleExtra`). The left edge is therefore constant and relative to the bar bounds; the bounds come from `MBDisplays::GetMenuBarBounds` (0x18f090ec8), which is the display width.

### 4.3 The one leading inset: privacy indicator inset

PROVEN chain:
1. AppKit `NSMenuBarLocalDisplayWindow` (method at 0x18b2044f8) calls `-[NSMenuBarRepresentation setLeadingInset:]` (0x18aa3c13c, call at 0x18b204690) with `-[NSMenuBarDisplayManager leadingInsetForDisplay:]` (0x18b0fae00).
2. `leadingInsetForDisplay:` calls a soft-linked function resolved by the block at 0x18b104218 (dlsym string `SLSMenuBarPrivacyIndicatorInset`, store to 0x1ed9a23c8).
3. SkyLight client `SLSMenuBarPrivacyIndicatorInset` (0x182a4d02c) does a MIG call (msg id 0x1513). Server handler `_XMenuBarPrivacyIndicatorInset` (0x182b83ee4).
4. Handler: looks up the `PKGDisplay`, requires `PKGDisplay[+0xc7] == 1`; gets the current mode (`0x182b12e40`: pixel size, point size, scale = pixelW/pointW) and the physical size (`PKGDisplayGetPhysicalSize` 0x182b12fa8, which is `SLCADisplay::physical_size` 0x182b05ed4 reading `[this+0x4f0/0x4f8]`); then calls `+[PKGSystemStatusIndicatorsShim additionalBarInsetForModePixelWidth:pixelHeight:pointWidth:pointHeight:scale:physicalSize:]` (IMP 0x182c0a714, table lookup 0x182c00ab0) and returns the result.
5. `PKGDisplay[+0xc7]` is set in the constructor (0x182b13918) from vtable slot `+0x620`, which is `SLCADisplay::supports_secure_indicators()` (0x182b067ac) = bit 2 of byte `[this+0xae0]`. I did not find the instruction that sets that bit (so I do not know what real hardware property drives it). INFERRED: it reflects DCP/CA hardware support for secure (privacy) indicators.
6. The same table value also insets the status item area: `RepositionAndClipStatusItemList` (0x182a51300) does `CGRectInset(fullMenuBarRect, inset, 0)` at 0x182a51424, only when `PKGDisplay[+0xc7] == 1` and `WS::Features::menu_bar_qfa_enabled()` (0x182b2fea8) is false.

Table (14 records of 80 bytes, built in 0x182c00788; I dumped it live). Key = `max(pointW/physW, pointH/physH)` in points per inch, the first record with key >= d (or within 0.1) wins, physical size is `CAWindowServerDisplay panelPhysicalSize` in inches (QuartzCore logs "Panel Physical Size: %.2f x %.2f inches"; value from `IOMobileFramebufferGetDisplayArea`, which calls `IOConnectCallStructMethod` selector 0x1d; QuartzCore 0x18e208680; virtual displays use `kCAVirtualDisplayPhysicalWidth/Height`).

| Record key (pt/in) | Inset (record[5], pt) |
|---|---|
| 85.5 to 128.1 (rows 0-8) | 0 |
| 148.9, 151.5 | 2 |
| 174.6 | 4 |
| 186.3 | 6 |
| 219.0 (last row, also the fallback above it) | 12 |

Verified live by calling the shim on this Mac with an iPhone-like mode (393x852 pt @3x): physical width 3.5 in gives 0, 3.0 in gives 2, 2.5 in gives 4, 2.0 in gives 12. A 14-inch MacBook Pro geometry gives 0, and mm-valued physical sizes give 0 (the table assumes inches). Physical size 0 or negative selects the first record, so also 0.

Consequences: the maximum is 12 pt, and only when (a) `supports_secure_indicators`, (b) IOMFB reports a non-zero display area, (c) the point density is at least about 149 pt/in. A 59 pt radius needs roughly 76 px of left margin at mid menu bar height (about 177 px at the very top), so this path cannot solve it even in the best case.

### 4.4 Right side and privacy indicators

`SLSMenuBarAgentManager.MenuBarMetrics.PrivacyIndicator.Location` has `controlCenter`, `screenCorner`, `centerHUD` (SkyLight Swift types). A screen-corner indicator exists for devices with corner hardware indicators; its placement is server-side, not a general inset of menu extras. I did not trace what selects `screenCorner`.

### 4.5 What I did not analyze

- Swift layout code of `NSMenuBarRepresentation.layoutMenuBar` (0x18aa3c54c) and how it consumes `leadingInset` beyond the setter (only the setter and init read the ivar through the ivar offset variable).
- `SolariumMenuBarContext::update_layers/update_pills` (0x1829b2a70, 0x1829b5214): the call lists contain no display-corner accessors that I could identify; the pills follow item bounds supplied by the app side (`get_app_bar_info_on_space` 0x182953aec). INFERRED: no corner-derived inset there.
- Kernel/DCP/AppleCLCD behavior (selector 0x1d of the IOMFB user client, whether the paravirt IOMFB variant implements it). The `virt_` function table exists in IOMFB (`_virt_GetDisplaySize` etc.) but there is no `virt_GetDisplayArea` symbol; `IOMobileFramebufferOpen` (0x1b5ed72ac) installs `kern_GetDisplayArea` at table slot +0xee0. Which table a Henge guest ends up with is unknown. If the call fails, QuartzCore leaves the size at (0, 0) and the inset is 0.

## 5. Bottom line: guest-visible inputs and what they do

| Guest-visible input | Effect | Moves Apple menu / clock? |
|---|---|---|
| `/product artwork-device-subtype` = 1964 (done) | Eraserhead_1964 shape: notch, aux areas, menu bar height, 21 pt corner windows | No (only the notch area in the middle) |
| WindowServer pref `FakePhysicalSarlacc` | Same 1964 fallback when subtype lookup fails | No |
| `/product display-corner-radius` (8 bytes, num/den) | Only the MG `DeviceCornerRadius` answer (UIKit `UIScreen._displayCornerRadius` in Catalyst apps) | No |
| `/chosen display-corner-radius` | No user-space reader found | No |
| Panel physical size (IOMFB DisplayArea in inches, or `kCAVirtualDisplayPhysical*`) plus `supports_secure_indicators` | 0, 2, 4, 6 or 12 pt leading and status-item inset | Up to 12 pt, not enough, and gating bit unknown |
| Different `Eraserhead_N` SVG | Only possible by changing `SystemAppearance.bundle/Assets.car` on the sealed system volume; changes radii/rects, not the title origin | No |

What to do instead (host side, outside the guest):
1. Present the guest in a rectangle that is inside the iPhone's rounded panel, or keep the full-panel mode and have Henge's presentation layer draw an opaque black corner mask of radius 177 Mac px plus a safe margin for the menu bar band. The Apple menu then needs about 76 to 177 px of horizontal clearance (at 32 px bar height; computed from a 177 px circle), which only the host can guarantee.
2. If the guest must own the geometry, set a guest display mode narrower than the framebuffer so the unused columns sit under the physical corners.
3. Do not spend more time on corner-radius properties: none of them feeds the layout.

## 6. Confidence and gaps

- PROVEN: sections 1, 2.1, 3.1 (except noted), 4.2, 4.3 chain steps 1-4 and 6 and the table values (live call).
- INFERRED: the meaning of the `supports_secure_indicators` bit source, `safeAreaInsets` mode branches, "unused" `menubar-bottom`, "no corner-derived inset in Solarium pills".
- Not checked: macOS 27.2 binaries (host is 27.3), kernelcache/kexts (AppleCLCD, paravirt GPU), the Swift layout in AppKit's `NSMenuBarRepresentation`, and where `NSScreen._state.cornerRadius` is filled.
