# Rounded corners on the iPhone Duo (notes, 2026-11-12)

The Duo's inner panel has a 59 pt corner radius. In the 2848x2000 Retina mode Henge uses, that's 177 Mac px. At the menu bar's middle (y 24), the first 88 Mac px of each side sit under the arc, so the Apple menu and the clock get clipped.

## What decides how macOS treats the corners

- SkyLight draws bezel artwork and computes a notch only for a built-in display. The chain that decides this:
  - `SLCADisplay::is_builtin` comes from QuartzCore's displayType.
  - displayType comes from IOMobileFramebuffer.
  - An IOMobileFramebuffer service with a Boolean `external` (or `AppleTV`, or `dfr`) property is not built-in.
- The paravirtual GPU driver (AppleParavirtDisplay, in AppleParavirtGPUIOGPUFamily) sets `external` = true in two cases. One is when the per-port connection type at BAR+0x1234 resolves to 2, and 0 resolves to 2. The other is when the display page +0x60 flags are 0 or 2. Henge answered 0 for both.
- The fix is on branch pvg-builtin-display: +0x1234 = 1 and +0x60 = 1. HV_PVG_EXTERNAL=1 restores the old answers. It's verified on the Duo: the ioreg shows `"primary" = 0` and no `external`.
- CoreUI's `CUICreateDisplayShapeAndComputeCornerRadius` works like this:
  - It reads the artwork subtype from MobileGestalt (`oPeik/9e8lQWMszEjbPzng`, giving ArtworkDeviceSubType, which comes from the device tree's /product `artwork-device-subtype`).
  - It builds `Eraserhead_<subtype>`.
  - It looks that name up in SystemAppearance.bundle's Assets.car, by bundle id `com.apple.systemappearance` first, then by path.
  - No defaults key, env var or /Library override is read first. The full disassembly is in coreui-shape-lookup.md.
- Assets.car on macOS 27.3 has seven shapes: 1506, 1665, 1864, 1964, 1986, 2234 and 2266. The SVGs are in display-shapes/.
  - 1506 has no notch and no menubar-bottom.
  - 1964 (MacBook Pro 14) has a notch, with `menubar-bottom` at 7.38 mm.
  - 2266 has an island.

## Results on the Duo

| Boot | ADT patch | safeAreaInsets.top | auxTopLeft | Apple logo |
| --- | --- | --- | --- | --- |
| C0, F | none (subtype 0) | 0 | none | clipped |
| B | subtype 1506 | 0 (no notch in the artwork) | none | clipped |
| C1 | subtype 1964 | 32.5 pt | 0..625 x 32.5 (notch 625..799) | clipped |

With 1964, macOS takes the notch and the taller menu bar, but it keeps its normal left margin. So the Apple menu still sits inside the Duo's arc.

## Plan

- Corner radius: test the device tree's `display-corner-radius`, with HV_ADT_PATCH `product/artwork-device-subtype=1964,chosen/display-corner-radius=177,+product/display-corner-radius=177`. Only ADT values that Henge sets at boot are in scope. This boot hasn't run yet; it's tracked in the testing-gaps issue.
- Never modify sealed system files in the guest, such as Assets.car or SystemAppearance.bundle. Authenticated root stays on.
- Prefer macOS's own corner and safe-area support (built-in display, artwork subtype, corner radius) over Henge-side masking or a black strip.
- Still open: which reader of `display-corner-radius`, if any, feeds menu bar placement.
