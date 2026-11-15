# Logitech HID++ on iPhone: extra findings from a device log

Upstream path: `docs/research/input-notes.md`. Written 2026-11-14.

[`docs/mouse-on-iphone.md`](https://github.com/Leviidev/Henge/pull/191) (added by PR #191) already covers what iOS exposes, the HID++ framing, the set-up sequence and how input is handed back. This note adds only what a device log of an early build of #151 (before the final #191 code) shows beyond that page. The log is from an iPhone Duo (iOS 27.3) with an MX Master 4 and AssistiveTouch off, macOS 27.2 guest booting.

## What the MX Master 4 reports

Feature indices from the root feature on this firmware: wireless device status at 4, reprogrammable controls (`0x1B04`) at 13, high-resolution wheel at 18, thumbwheel at 19. Indices are assigned by the device, so look them up each time, as Henge does.

The control list has nine entries. Flags are as the mouse reported them (second byte pair is `flags2`):

| Control | flags / flags2 | Note |
|---|---|---|
| 0x50, 0x51 | 0x01 / 0x04 | left, right: not divertable |
| 0x52, 0x53, 0x56 | 0x31 / 0x05 | middle, back, forward |
| 0xC3, 0xC4, 0x1A0 | 0x31 / 0x05 | divertable, not mapped to a USB button |
| 0xD7 | 0xA0 / 0x03 | the only control with the raw-motion capability bit (`flags2 & 0x02`) |

- On this mouse raw motion rides on `0xD7`, not on `0xC3`. `MouseBluetooth.swift` has a comment that the gesture button (0xC3) carries motion on an MX Master; for this model that is not true, but the code falls back to the first control with the bit set, which picked 0xD7 correctly. The comment is out of date for the MX Master 4.
- That early build diverted all six divertable buttons. Pressing 0xC3 and 0x1A0 then produced `down (not mapped)` and `up (not mapped)` and did nothing else, so those buttons were dead while Henge held the mouse. The #191 code diverts only buttons that map to a USB button, plus the motion control, which is why the wheel-mode button (0xC4) still works there. I have not rerun the final build against this log.

## Timing

- Set-up took about 0.8 s from enabling notifications to "passing through": 27 requests at roughly 30 ms each, one request in flight at a time.
- The mouse's reconfiguration event (feature 4) arrived during the first set-up, about 60 ms in. Set-up continued and finished once; it did not restart from the top.
- Raw motion reports arrived about every 15 ms (about 66 per second), each with signed 16-bit dx and dy. That caps how smooth motion can be over this channel, and it is a property of the Bluetooth connection, not of Henge.
- The first clicks, at 13 to 20 s into the run, went to the virtio mouse and macOS ignored them. Henge switched to the USB mouse at 21 s. This matches the note in `mouse-on-iphone.md` that clicks during early boot can look dead.

## Services on the connected mouse

Besides `0x180A` and `0x180F` and the Logitech HID++ service, the MX Master 4 exposes a second Logitech service, `0xFD72`, with six or more characteristics. Nothing reads it. Other connected accessories on the phone (a smart lock, earbuds, a watch) also list vendor services in the same discovery pass. None is a mouse, but it shows the pass sees any peripheral iOS has connected, which matters if another brand's mouse carries a vendor channel.

## Nothing found for

GameController with AssistiveTouch off: 20 one-second polls all read buttons `000` and scroll `0.0` while HID++ delivered more than 120 moves. This only repeats what `mouse-on-iphone.md` says.
