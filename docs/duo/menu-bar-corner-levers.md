# Menu bar clearance from rounded corners: guest-visible levers (2026-11-13)

Host: MacBook Pro 14 (M2 Pro, J414s), macOS 27.3 (26C5035r), dyld shared cache arm64e. Addresses are unslid cache addresses (MenuBarAgent addresses are its own image). This builds on [../display-corners.md](../display-corners.md) and [corner-radius-readers.md](corner-radius-readers.md) and does not repeat them.

Labels: **PROVEN** = read in disassembly or observed live on this Mac. **INFERRED** = reasoning from proven pieces, with the missing link named.

Scratch (scripts, symbolized disassemblies): host scratch, not kept (`slsym.dis` = symbolized SkyLight, `mba.dis` = MenuBarAgent, `ax3`/`axprobe` = AX probes, `modes` = mode lister, `ns.js` = NSScreen probe). Nothing on this Mac was changed: no defaults written, no mode switched.

## Short answer

MacBooks do not inset the menu bar for their corners. The Apple menu item starts at a hard-coded 10 pt (glyph at about 20 pt) and the rightmost status item ends about 20 to 23 pt from the right edge. A MacBook's top corner arc is about 21 pt, so the fixed margins are enough there. On the Duo the arc is about 88 pt (in guest points at 2x), so the same margins put the Apple glyph about 18 pt inside the arc.

The only guest-visible horizontal inset in macOS 27.3 is the privacy-indicator inset (at most 12 pt). It is gated on QuartzCore's "Medina" check, which is a ChipID allowlist or a hashed device-type list, not an IOMFB property. Even at 12 pt it leaves the glyph about 11 pt clipped.

The best lever is a host-side "safe aperture", which is what MacBooks do for their below-notch modes: give the guest a mode shorter than the panel and present it 1:1 at the bottom with a black band of about 60 px at the top. That clears both the Apple logo and the clock and costs 2.9% of the panel. Details and the other levers are ranked at the end.

## 1. Live measurements on this MacBook Pro 14

The lid was closed for the first half of the session and opened later, so the built-in display was read when it came online. AX menu bar readings come from the active app's bar on the main display (Studio Display), because AX exposes only that bar.

| Reading | Value | Label |
|---|---|---|
| Built-in `NSScreen.frame` | 1512 x 982 pt @2x | PROVEN |
| Built-in `safeAreaInsets` (top, left, bottom, right) | 32, 0, 0, 0 | PROVEN |
| `auxiliaryTopLeftArea` / `RightArea` | width 663.5 pt each, height 32 (notch gap 185 pt) | PROVEN |
| `-[NSScreen _cornerRadius]` | 0 on every screen, built-in included | PROVEN |
| `SLSDisplayGetCornerRadii(did, &tl, &tr, &bl, &br)` (signature is 5 args) | built-in: TL 0, TR 0, BL 20.194, BR 20.191; externals all 0 | PROVEN |
| `SLSMenuBarPrivacyIndicatorInset` | 0.0 on all three displays | PROVEN |
| IOMFB `IOMFBSupportsSecureIndicator` (internal `disp0` shim) | No | PROVEN |
| `/product` | `artwork-device-subtype` 0x7ac (1964), `partially-occluded-display` 1, `display-corner-radius` = 4-byte 0 | PROVEN |
| `/chosen` | `chip-id` 0x6020, `target-type` J414s, `display-corner-radius` 4-byte 0 | PROVEN |
| Apple menu AX item (Safari and Terminal, 2560 pt Studio Display and an 800 pt virtual display) | x = 10, width 34, bar height 30 | PROVEN |
| Rightmost status item (MenuBarAgent extras bar) | ends at 2539-2540 of 2560 (20-21 pt margin); 777.25 of 800 on the virtual display (22.75 pt) | PROVEN |

Notes:

- The prior doc said this Mac's `/product` has no `display-corner-radius`. It has a 4-byte zero, which MobileGestalt rejects (it needs 8 bytes), so the conclusion there stands.
- SkyLight reports zero top corner radii on a notched MacBook in the full-height mode and 20.19 pt bottom radii. The 1964 SVG's top arc is 20.93 units. So the top corners are treated as part of the menu bar band, not as an input to anything horizontal.
- Geometry check, MacBook: with r = 21 pt and the glyph box at x 20..34, y 9..23 in a 32 pt bar, the arc intrudes 3.8 pt at the glyph's top edge and 0.6 pt at mid-bar. The fixed 20 pt glyph margin clears it. PROVEN for the margin (section 3), arithmetic for the clearance.
- Below-notch modes (`CGDisplayCopyAllDisplayModes` with duplicate low-res modes): every HiDPI size comes in a pair, for example 1512 x 982 (3024 x 1964, aspect 1.5397, native) and 1512 x 945 (3024 x 1890, 16:10). Width is identical and the height drops by the 37 pt notch strip. No mode has a different horizontal extent. PROVEN. See section 4 for how SkyLight makes and classifies them.

## 2. Preference keys that touch menu bar horizontal layout

### Strings in AppKit, HIToolbox and SkyLight (PROVEN as strings; effect noted where traced)

- `HIMenuBarEnableSmallTitleExtra`, `HIMenuBarEnableExtraSpaceReallocation`, `HIMenuBarReduceHighlightForSmallTitleExtra` (HIToolbox). `GetThemeMenuTitleExtra` (0x18f1a7a00) returns the constant 20, or 15/17 when the small-title-extra once-flag is set. That is the spacing between titles. PROVEN.
- `sStandardHalfExtra` (0x1eb708e38) is a HIToolbox global. In 27.3, app menu titles are laid out by AppKit (`NSMenuBarRepresentation`, section 3), not by `HIMenuBarView::LayoutEachTitle`. The live x = 10 matches the AppKit code exactly. PROVEN for AppKit; INFERRED that the HIToolbox path no longer positions app menus.
- `NSStatusItemSpacing`, `NSStatusItemSelectionPadding`, `NSStatusItemShowSpacing`, `NSStatusItemForceNeverClip`, `NSStatusItemUseControlCenter`, `NSStatusItemAgent`, `NSMenuEnableMenuBarAgent`, `NSMenuBarUseAgentNavigation`, `NSStatusBarDisableReplicants`. These cover status item padding and hosting, not a margin from the screen edge. Not traced further. The rightmost item's margin comes from MenuBarAgent and SkyLight metrics (below).
- `com.apple.universalaccess` `menuBarOptions.allowHalfScreenWidthForStatusItems`, read by `+[NSMenuBarRepresentation updateLayoutPreferences]` (0x18aa3facc). It caps status item width. PROVEN.
- `NSMenuBarWindowApertureFrame` is a window property key. The aperture comes from `NSScreen _notchFrame` (section 3). PROVEN.

### SkyLight WindowServer preferences found through direct accessor calls (PROVEN)

Found through `_WSBooleanPreferenceForKey`, `_WSPreferenceIsSet`, `_WSIntegerPreferenceForKey`, `_WSServerWidePreferenceForKey` and `_WSUserPreferenceForKey`:

- `FakePhysicalSarlacc`: read in `Display::create_bezel_physical_path` (fallback to the 1964 shape, already documented) and in `post_process_resolved_modes` (safe-aperture mode synthesis).
- `FlagSafeApertureModesAsUnupported` [sic]: read in `SLCADisplay::create_safe_aperture_mode_legacy` and `post_process_resolved_modes`. It flags the below-notch modes.
- `FGMB`: `WS::Features::solarium_menubar_enabled` (menu bar height floor of 26).
- `SkipInternalDisplays`, `SkipExternalDisplays`, `Dullahan`, `DisableFeatureA`, `DisplayHUD`: `CAWSManager::initialize`.
- `ShieldDebug`, `DefaultVFBWide/High/Scale/Format`, `ExternalDisplayPolicy`, `ForceVirtualDisplayPQ`, `ConnectionIdleTimerDelay`.

None of these sets a horizontal inset. Gap: SkyLight also reads preferences through `CFPreferences` directly and through `WS::Features` flags, and this sweep covered only the WS accessor wrappers.

### QuartzCore preferences and environment that matter here (PROVEN)

- `com.apple.coreanimation` `CAEnableMedina` (Boolean): the gate for secure indicators (section 5).
- `CA_DISPLAY_OVERSCANNED` (environment variable read by WindowServer's QuartzCore): forces every digital mode to "overscanned", which unlocks underscan (section 4).
- `FilterDisplayModes`, `IgnoreUnsafeDisplayModes` and related keys in `com.apple.coreanimation` filter modes only.

## 3. AppKit `NSMenuBarRepresentation`: how `leadingInset` is applied

This is an ObjC class, not Swift. `layoutMenuBar` (0x18aa3c54c) only schedules `layoutMenuBarIfNeeded`. The geometry is in `-_layoutEachTitle:withExtra:withBlock:` (0x18aa3f1b4). PROVEN:

```
cursor   = leadingInset + 20                    // ivar at MergedGlobals+0xb18
halfX    = floor(extra / 2)
item 0   : leading pad = 10 (constant), width extra = min(extra, 20)
item 1   : leading pad = min(halfX, 10)
others   : leading pad = halfX
aperture : if aperture.width > 0 and cursor <= aperture.maxX and cursor + titleW > aperture.minX,
           the title jumps to aperture.maxX
```

So the Apple item's frame origin is `leadingInset + 10`, which matches the live x = 10. The aperture is set by `-setApertureFrame:` (0x18aa3c058), which outsets it with `NSInsetRect(frame, -20, 0)`. Its callers (`NSMenuBarDisplayManager _notifyNotchBoundsChangedOnDisplay:`, `NSMenuBarPresentationInstance _setBoundsAndUpdateResolution`, `NSMenuBarLocalDisplayWindow _applyFrameToReplicants`) all take it from `NSScreen _notchFrame` / `notchBoundsForDisplay:`. That rect is SkyLight's notch rect from the Eraserhead SVG, which is centered in every shipped shape.

There is no trailing inset in this class. Status items are now hosted by `/System/Library/CoreServices/MenuBarAgent.app` (a new process in 27.x), which gets its bar `frame` and privacy-indicator `requiredWidth`/`location` from SkyLight's `SLSMenuBarAgentManager.MenuBarMetrics`.

Sources of `leadingInset`: exactly two setters, `-[NSMenuBarImpl ensureRepresentationViewForDisplayID:]` (via `initWithBackingView:leadingInset:`) and `-[NSMenuBarLocalDisplayWindow _applyFrameToReplicants]` (via `setLeadingInset:`). Both pass `-[NSMenuBarDisplayManager leadingInsetForDisplay:]` (0x18b0fae00), which tail-calls the soft-linked `SLSMenuBarPrivacyIndicatorInset` and returns 0 if the symbol is missing. There is no other source. PROVEN.

MenuBarAgent: it reads `NSScreen _cornerRadius`, `_notchFrame` and `_isSafeAperture`, and carries keys such as `ConcentricMinimumPadding`, `ExpandedConcentricPadding`, `EdgePaddingThreshold` and `leading/trailingConcentricPaddingOverride`. Those keys sit in a settings table with `MitosisRestorationProgress`, `EmptySensorRegionHeight`, `ContentSensorRegionHeight` and `MaximumPillHeight`, so they are the Live Activity "sensor region" UI around the notch or island, not edge padding. The `_cornerRadius` read (wrapper at 0x10031d6b4) feeds a display description struct built with the display timing and pixel counts. I did not trace that struct to a layout use. Since `_cornerRadius` is 0 even on a notched MacBook, it cannot be what keeps items off the corners there. Corner-concentric padding: INFERRED absent; the struct consumer was not traced.

## 4. SkyLight display mode, notch and corner inputs

- `Display::current_mode_has_notch` (0x18286be6c) = notch rect `+0x1b0` is non-empty AND NOT `SLCADisplay::is_safe_aperture_implicitly()` (vtable +0x160). PROVEN. This corrects the prior wording.
- `Display::current_mode_has_rounded_corners` (0x18286bf90) = any corner path at `+0x110..+0x128` AND NOT `is_safe_aperture_implicitly()`. PROVEN.
- `SLCADisplay::is_safe_aperture_implicitly` (0x182ad90a8) = `has_sarlacc()` AND (`is_mirror_slave()` OR `is_rotated()` OR the current mode's pixel aspect ratio (`+0x8ec`/`+0x8f0`) does NOT approximately match `native_aspect_ratio()` (vtable +0xd8, the native pixel size)). PROVEN.
- So a "below-notch" mode is not described by any IOMFB inset attribute. It is any mode whose aspect ratio differs from the native panel on a display that has a notch. SkyLight synthesizes these modes itself: `SLCADisplay::create_safe_aperture_mode_legacy` (0x182ad658c) takes the bezel path's bounding box, scales it to the mode and subtracts the strip from the mode height. Width is unchanged. PROVEN for the call chain; the width arithmetic matches the live mode list.
- In a safe-aperture mode, SkyLight reports no notch and no rounded corners. The visible area is a plain rectangle whose top corners are hidden in the black strip. That is exactly the shape a Henge host-side band would produce.
- Mode-level left/right safe or active area: none exists. The IOMFB mode dictionaries QuartzCore reads (`update_digital_modes` 0x18e2051f8: `HorizontalAttributes`/`VerticalAttributes` `Active`, `NativeFormat*Pixels`, `IsOverscanned`, `PixelRepetition`, `ColorModes`, `DownstreamFormat` and so on) have no inset field. PROVEN for that function.
- Underscan is the only general mechanism that insets the picture on all sides. `SLSDisplaySetUnderscan` leads to `CAWSManager::mig_set_underscan_value_for_display` (0x182af5fb0), which applies `setOverscanAmounts:(u,u)` with `kCAWindowServerOverscanScaleContent` only if `-[CADisplay isOverscanned]` (bit 0 of `CA::Display+0x2e2`). That bit comes from each timing's `IsOverscanned` in `update_digital_modes`, or is forced for all modes by the environment variable `CA_DISPLAY_OVERSCANNED=1`. `update_digital_modes` runs only when the IOMFB display kind (`+0x2bc`) is 1 or 2 (digital out) and `IOMobileFramebufferGetSupportedDigitalOutModes` returns timing and color arrays. PROVEN. Whether the paravirtual display's IOMFB answers that call is unknown: the AppleParavirtGPU kext is not in this Mac's kernelcache and no guest kernelcache is on disk. CA itself takes separate x and y amounts, but SkyLight passes the same value for both, so underscan is uniform.
- Radius scale fields: `+0x98` is the first field of a `CGAffineTransform` (a at +0x98, b +0xa0, c +0xa8, d +0xb0, tx +0xb8, ty +0xc0) that maps SVG units to the current mode, used directly in `CGPathCreateCopyByTransformingPath(path, this+0x98)`. Each corner radius is stored as `r * (a + c)` (`fmadd` at 0x18286c3b0, part 6 to `+0x198`, and the same for the others), which equals the x scale whether or not the display is rotated. `evaluate_display_parts` also bails out unless the current and native sizes (vtable +0xa8 and +0xd8) are both greater than 1. PROVEN. Where the transform is filled was not traced.

## 5. `supports_secure_indicators` (`SLCADisplay+0xae0` bit 2)

PROVEN chain:
1. `SLCADisplay::make_display(CAWindowServerDisplay*, unsigned, bool)` at 0x182aee548..0x182aee578: if the CA object responds to `supportsSecureIndicators` (selector stub 0x18801d550), bit 0x4 of the byte at `+0xae0` is set to `[display supportsSecureIndicators]`. The next bit (0x8) is `supportsSILVerificationOnly`.
2. `-[CAWindowServerDisplay supportsSecureIndicators]` (0x18e16c058) = (impl != nil) && `CADeviceSupportsMedina()`. There is no per-display IOMFB property in this path.
3. `CADeviceSupportsMedina` (block 0x18e12c4b8, dispatch_once):
   - `medina = MGIsDeviceOneOfType(5 hashed product types)`, the table at 0x18e261bb8 (not decoded);
   - if the key `CAEnableMedina` exists in `com.apple.coreanimation`: `medina = CAEnableMedina && MGGetSInt64Answer("ChipID") ∈ {0x8132, 0x8140, 0x8142, 0x8150, 0x8320, 0x8160, 0x6050, 0x8152}` (table at 0x18e254d10).
4. `IOMFBSupportsSecureIndicator` (No on this MacBook) is read separately by QuartzCore to enable or disable the secure-indicator layer ("IOMFB didn't publish property kIOMFBSupportsSecureIndicator, disabling SIL"). It is not what sets the SkyLight bit. PROVEN for the strings; the exact read site was not traced.

What Henge would need to turn on the 12 pt table entry: a guest `/Library/Preferences/com.apple.coreanimation.plist` with `CAEnableMedina = YES` (INFERRED that WindowServer's `CFPreferencesGetAppBooleanValue` sees the any-user domain), a guest ChipID in that list (INFERRED to come from the `/chosen chip-id` that Henge's device tree supplies; spoofing it risks the kernel, AMFI and every other chip-id consumer), the display built in, and a non-zero `IOMobileFramebufferGetDisplayArea` (kernel selector 0x1d; paravirt support unknown). Reporting a physical width of 6.5 in or less at 1424 pt gives at least 219 pt/in, which selects 12 pt. The trailing (status item) side also gets the inset, but only while `WS::Features::menu_bar_qfa_enabled()` is false.

## 6. Island subtypes 1986 and 2266

The SVG group IDs name the boards: 1986 = `K114-bezels`, 2266 = `K116-bezels` (same 855 and 982 unit widths as J314 MBP 14 / J316 MBP 16). For the rest: 1506 = J700 (no notch), 1665 = J413, 1864 = J415, 1964 = J314, 2234 = J316. PROVEN from the SVGs. INFERRED: K114/K116 are unreleased island versions of the 14- and 16-inch MacBook Pro.

Island devices get no side inset that I found. SkyLight computes an island menu bar height from the scale fields (`current_mode_has_centerhud`, rect `+0x1d0`). AppKit's aperture skip applies to whatever `_notchFrame` returns, which is centered. MenuBarAgent's concentric keys belong to the Live Activity sensor region. INFERRED, with the same untraced MenuBarAgent struct as in section 3.

## 7. Spoofing model, board, target type or product type

- SkyLight `evaluate_display_parts` calls `MGGetProductType` only for the notch menu bar height: +4 pt for product type 0xf83b64fa, otherwise +5, when Solarium is off. That is vertical only. PROVEN.
- Other SkyLight `MGIsDeviceOneOfType`/`MGGetProductType` uses are in display info, APT, idle timers, capture, recompositing and UUID versioning. None is in a menu bar layout path. PROVEN by listing every call site.
- AppKit: `"MacBook"` is used only by `NSWindowSidecarMenuController imageForIPad:`. `_NSHardwareModel` (`hw.model`) is used by Sidecar, by a model-string getter near the NSScreen methods, and by the display-name localizer ("Built-in Retina Display"). None of these is in `NSMenuBar*`. HIToolbox and CoreUI have no model strings. PROVEN for the call sites.
- The only identity input that changes a horizontal value is QuartzCore's Medina device-type/ChipID gate (section 5), capped at 12 pt.
- The artwork subtype (`/product artwork-device-subtype`) changes the notch, corner and bar height (documented before), and moves the AppKit aperture skip only around the centered notch.

## Ranked levers

Duo geometry used: panel 2853 x 2007 px, r = 177 px; guest 2848 x 2000 px at 2x, so r = 88.3 guest pt. Apple glyph box (from the live item frame): x 20..34 pt, y 7..23 pt in a 30 pt bar. Clock glyph right edge about 26.5 pt from the right edge. Clearance = R minus the distance from the corner circle's center; positive means visible. Target is 2 pt (4 px) of clearance.

| Rank | Lever | Apple glyph clearance | Clock | Cost | Where it lives |
|---|---|---|---|---|---|
| 1 | **Host-side top band** ("Henge safe aperture"): guest mode 1424 x 972 pt (2848 x 1944 px), presented 1:1 at the bottom of the panel with a black top band of 58 to 63 px | +2 pt at a 58 px band (+2.9 pt at 60 px) | clears (needs about 44 px) | 2.9% of panel; bottom corners still round (88 pt), so add an equal bottom band (5.8%) if maximized windows and the Dock edge matter | Henge host + mode list only. Guest sees a plain shorter mode. If the display stays built in with the 1964 shape, SkyLight treats a non-native aspect as safe aperture (no notch, no corners), as on a MacBook. |
| 2 | **Host-side symmetric inset**: guest mode about 1389 x 981 pt (2778 x 1962 px) 1:1, centered (37 px sides, 22 px top and bottom) | +2 pt | clears | 4.8%; clears all four corners | Same as 1 |
| 3 | **Guest underscan 2.5%**: `CA_DISPLAY_OVERSCANNED=1` in WindowServer's environment plus an underscan value (`SLSDisplaySetUnderscan` or persisted in `com.apple.windowserver.displays`) | +2.5 pt | clears | 2.5% each axis, non-integer rescale (blurry text) | Guest data volume only. Needs the paravirt display to be digital-out (kind 1/2) and to answer `IOMobileFramebufferGetSupportedDigitalOutModes`, both unverified. Setting the env for a system daemon (for example `launchctl config system setenv`) is also unverified. |
| 4 | **Privacy-indicator inset 12 pt** (Medina + physical size) | -10.6 pt (clipped) | -7.1 pt (clipped) | ChipID spoof risk | Guest `CAEnableMedina` plus `/chosen chip-id` spoof plus display area. With rank 1, it would cut the band from about 30 pt to 16 pt, which is not worth the risk. |
| 5 | Artwork subtype, `display-corner-radius`, `FakePhysicalSarlacc`, model, board or target spoofing, HIToolbox title-extra prefs | -17.9 pt (no change) | no change | none | Dead ends for horizontal layout |

What a Duo boot needs to test each:
1. **Top band**: Henge advertises a 2848 x 1944 (and/or 2848 x 1940) mode, the presenter offsets the guest image down by 63 px (2007 - 1944) and fills the strip black. Then `check` and `snap`, plus the JXA probe for `NSScreen.frame`/`safeAreaInsets`, plus an AX probe of the Apple item and the rightmost MenuBarAgent item (the `ax3` probe from the host scratch, not kept; it reads `AXMenuBar` children's `AXPosition`/`AXSize`). Pass when the Apple logo and the clock are fully visible in `snap` and the probe shows `safeAreaInsets` 0 (or 32.5 top with the 1964 shape in a native-aspect mode).
2. **Symmetric inset**: same with a 2778 x 1962 mode centered (38 px left/right, 22 px top/bottom).
3. **Underscan**: boot with the display external (`HV_PVG_EXTERNAL=1`). In the guest, `sudo launchctl config system setenv CA_DISPLAY_OVERSCANNED 1` and reboot, then check whether System Settings > Displays shows an Underscan slider or call `SLSDisplaySetUnderscan(did, 0.025)`. Read `-[CADisplay isOverscanned]`. Fails early if the paravirt IOMFB has no digital-out modes.
4. **Privacy inset**: only with a disposable guest. `/chosen chip-id` 0x8150 via `HV_ADT_PATCH`, `defaults write /Library/Preferences/com.apple.coreanimation CAEnableMedina -bool YES`, display built in, then read `SLSMenuBarPrivacyIndicatorInset` and `AppleMobileDisp` display area. Expect at most 12 pt even if everything works.

## Not checked

- macOS 27.2 guest binaries (host is 27.3).
- The guest kernelcache and kexts (AppleParavirtGPUIOGPUFamily: `GetSupportedDigitalOutModes`, `GetDisplayArea`).
- The MenuBarAgent display-description consumer of `_cornerRadius`, and its trailing-edge constant (measured live as 20 to 23 pt instead).
- SkyLight preferences read through `CFPreferences` or `WS::Features` rather than the WS accessors.
- The writer of the SVG-to-mode transform at `Display+0x98`.
- Which display kind (`+0x2bc`) a Henge display gets.
- The five Medina device-type hashes.
- The rightmost status item on the built-in display specifically (AX exposed only the main display's bar).
