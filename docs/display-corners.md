# Rounded corners: how macOS does it, and where Henge stands

Notes from the work on fitting the Mac's screen to the iPhone Duo's inner panel (November 2026). The goal is macOS's own corner support, the same machinery a MacBook Pro uses, fed only through what Henge controls: the device tree and the paravirtual display. Changing locked macOS system files (the sealed system volume, `Assets.car`, authenticated-root) is ruled out.

## The panel

The Duo's inner screen is 951 x 669 pt at 3x (2853 x 2007 px). Its corner radius is 59 pt, which is `UIScreen._displayCornerRadius` read on the device (`Device.displayCornerRadius`, logged as "corner radius X pt" when a Mac starts). Apple doesn't publish corner radii. On a Retina Mac at 2848 x 2000, 59 pt is about 177 Mac pixels, and the corner hides the first ~88 Mac pixels of each side at the middle of a 24 pt menu bar.

## How macOS gets a panel's shape

Traced in macOS 27.x (SkyLight, CoreUI, QuartzCore, the guest's AppleParavirtGPUIOGPUFamily kext):

1. **Only a built-in display gets a shape.** SkyLight's `create_bezel_physical_path` runs only for built-in displays. A display is built in when QuartzCore's displayType is 0, which means its IOMobileFramebuffer service has none of the Booleans `external`, `AppleTV` or `dfr`.
2. **The paravirtual display used to say external.** `AppleParavirtGPU::start` reads each port's 2-bit connection type at BAR +0x1234 and calls `markExternalPort` for type 2, which a 0 also resolves to. `createDisplayAttributes` reads flags at display page +0x60: with 0 or 2 it sets `IOMFBUUID` and `external`, and with any other bit it sets `primary` = port. Henge now answers +0x1234 = 1 and +0x60 = 1 (`devices/pvg_lite.c`; `HV_PVG_EXTERNAL=1` restores the old answer). The guest then shows `primary` = 0 and no `external`. The one cost is that the driver doesn't set `IOMFBUUID` on this path.
3. **The shape is an SVG chosen by model.** CoreUI's `CUICreateDisplayShapeAndComputeCornerRadius` reads MobileGestalt `ArtworkDeviceSubType`, which comes from the device tree's `/product artwork-device-subtype` (0 on the virtual Mac). It loads `Eraserhead_<subtype>` from SystemAppearance.bundle's `Assets.car`. No defaults key, environment variable or user path is checked first. The shipped subtypes are 1506 (plain rounded rectangle, r about 18), 1665, 1864, 1964 and 2234 (notched, r about 21), and 1986 and 2266 (island, r 32.5). None matches the Duo.
4. **The safe area comes from the shape.** NSScreen's `safeAreaInsets`, `auxiliaryTopLeftArea` and `_cornerRadius` come from SkyLight display part rects filled from that SVG (`menubar-bottom`, the notch or island, the bezel). The menu bar, Dock and Control Center use them.

## What has been tested on the Duo

All of these used `HV_ADT_PATCH` (`host/vm.c`), which edits or adds u32 properties in the guest's device tree before IOKit reads it.

| Boot | Display | Device tree | Result |
|---|---|---|---|
| 177 | external | `display-corner-radius` 177 in /chosen and /product, `partially-occluded-display` 1 | Nothing moved. The display was still external. |
| A | built in | none | `primary` = 0, no `external`; boots normally |
| B | built in | subtype 1506 | No inset, as on a notch-free MacBook. |
| C1 | built in | subtype 1964 (MacBook Pro 14) | `safeAreaInsets` top 32.5, left 0, right 0; a 32.5 pt menu bar split around the notch. The Apple logo is still clipped, because 1964's corners are much smaller than the Duo's. |

So macOS's native machinery works on Henge's Mac once the display is built in. What's missing is a radius that matches the panel.

## Why MacBooks keep the menu bar off their corners

Traced on a MacBook Pro 14 under macOS 27.3. The full write-up, with addresses and PROVEN/INFERRED labels, is [duo/menu-bar-corner-levers.md](duo/menu-bar-corner-levers.md).

- MacBooks don't inset the menu bar for their corners at all. AppKit places the Apple item at a fixed 10 pt leading pad and starts titles at `leadingInset + 20`. The rightmost status item ends 20 to 23 pt from the right edge. A MacBook's top corner arc is about 21 pt, so these fixed margins are enough there. The Duo's arc is about 88 guest pt, so the same margins leave the Apple logo about 18 pt inside the curve.
- `leadingInset` has exactly one source, `SLSMenuBarPrivacyIndicatorInset`. It returns at most 12 pt and is gated by QuartzCore's `CADeviceSupportsMedina`, which is a ChipID or hashed device-type allowlist, not a display property. Even at 12 pt the logo stays clipped.
- SkyLight's safe-aperture modes (the "below the notch" sizes) crop only the height. Any mode whose aspect ratio differs from the native panel on a notched display counts as a safe aperture, and SkyLight then reports no notch and no rounded corners.
- No display mode or IOMFB timing carries a left or right inset.
- Underscan insets all four sides, but only for displays QuartzCore treats as overscanned digital outputs. Whether the paravirtual display can qualify is unknown.
- Spoofing the model, board, target or artwork subtype changes only the bar height and the notch, not the horizontal margins.

### Recommended path

Do the inset on the host. Henge advertises a 2848 x 1944 safe-aperture mode and presents it 1:1 at the bottom of the panel with a black band across the top (63 px for that mode; about 58 px is the minimum that clears the logo by 2 pt). That clears both the Apple logo and the clock and costs about 3% of the panel. An optional symmetric mode, 2778 x 1962 centered (about 37 px each side, 22 px top and bottom), clears all four corners for 4.8%.

Duo tests, in order:

1. Top band: advertise 2848 x 1944, offset the guest image down by 63 px and fill the strip black. Run `check` and `snap`, the JXA probe for `NSScreen.frame` and `safeAreaInsets`, and an AX probe of the Apple item and the rightmost status item. It passes when the Apple logo and the clock are fully visible.
2. Symmetric inset: the same with a centered 2778 x 1962 mode.
3. Underscan: boot with `HV_PVG_EXTERNAL=1`, set `CA_DISPLAY_OVERSCANNED=1` for WindowServer, then try an underscan of 0.025. It fails early if the paravirtual framebuffer has no digital-out modes.
4. Privacy inset, disposable guest only: `/chosen chip-id` 0x8150 through `HV_ADT_PATCH` plus `CAEnableMedina`. Expect at most 12 pt.

Island subtype 2266 and a `display-corner-radius` boot are no longer worth a Duo run: neither feeds horizontal layout.

## Testing without hands

Autopilot (`ios/Henge/Autopilot.swift`) has `screen W H` (a simulated rotation or fold), `check NAME` (the panel view with its corners, Henge's pointer and controls, plus the numbers in henge.log) and `snap` at the live mode. A JXA probe over SSH reads the guest's side:

```
osascript -l JavaScript -e 'ObjC.import("AppKit"); var s=$.NSScreen.mainScreen; JSON.stringify([s.safeAreaInsets, s.auxiliaryTopLeftArea])'
```

## Reference material

- The CoreUI lookup disassembly is in [duo/coreui-shape-lookup.md](duo/coreui-shape-lookup.md), and the shipped Eraserhead SVGs are in [duo/display-shapes/](duo/display-shapes/).
- The 2026-11-12 Duo test results are in [duo/test-results-2026-11-12.md](duo/test-results-2026-11-12.md). That file covers the code cache, shader cache, stale panic, Safari, JIT and mouse results, plus the list of tests that did not run.
- The trace of corner radius readers is in [duo/corner-radius-readers.md](duo/corner-radius-readers.md). Its bottom line: no guest-visible input moves the menu bar away from a rounded corner. `display-corner-radius` is read only by MobileGestalt (`DeviceCornerRadius`, an 8-byte `/product` value, u32/u32), and only UIKit uses it. Menu bar insets come from the notch and a pixel-density table of at most 12 pt, so the remaining fix is host-side. The follow-up, [duo/menu-bar-corner-levers.md](duo/menu-bar-corner-levers.md), ranks the host-side options.
