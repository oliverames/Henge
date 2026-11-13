import Foundation
import UIKit

/// Testing a build on a phone nobody is holding. Henge follows Documents/henge-autopilot.txt when it is
/// launched with HENGE_AUTOPILOT set, as in
///   xcrun devicectl device process launch -e '{"HENGE_AUTOPILOT":"1"}' --device ID BUNDLE
/// or, for a launch by hand (a locked phone driven through iPhone Mirroring), once: at launch
/// Documents/henge-autopilot-once.txt is renamed to henge-autopilot.txt and followed, so the next
/// launch runs nothing. Put the files there with devicectl device copy to. One command per line,
/// picking up lines added later while it runs:
///   mac [NAME]         start that Mac (the one used last without a name) once JIT is on
///   wait SECONDS
///   type TEXT          typed into the Mac (the log shows only how long it is)
///   key CODE           a Linux key code (28 is Return, 1 is Escape)
///   cmd KEY            KEY (a character, or space) with Command held
///   move X Y, click X Y  the pointer to a spot on the Mac's screen (its pixels), and a click there
///   pointer            where the pointer is now, into the log
///   knob NAME VALUE    a translation knob (core/machine.h)
///   cpus N             the CPUs setting (1 to the device's core count) for the next Mac started; it stays, so set it back afterwards
///   env NAME [VALUE]   set (or unset) an engine environment setting for the next Mac started
///   balloon MB         ask the Mac for that much of its memory back (HV_BALLOON set), log what it gave
///   snap [NAME]        the Mac's screen, at the size macOS has now, into Documents/NAME.jpg (snap.jpg)
///   screen W H         act as if the device's space for the Mac were W x H points (a rotation, a fold or unfold),
///                      so a Mac that follows its space is asked for that size; "screen off" goes back to the real one
///   check [NAME]       what the device's panel shows: the Mac's screen where the layout puts it, cut by the panel's
///                      rounded corners, with the pointer at the size Henge draws it and Henge's own controls
///                      over it, into Documents/NAME.png (the controls alone in NAME-ui.png)
///                      (check.png), and the sizes, corners and pointer into the log
///   log TEXT           a marker in henge.log
///   stop               stop the Mac
///   exit               quit Henge
/// Each command is written to henge.log as it runs, so the log has the timeline.
enum Autopilot {
    private static let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    /// Launched for testing: by environment, or by a one-time file (used up here).
    static let enabled: Bool = {
        if ProcessInfo.processInfo.environment["HENGE_AUTOPILOT"] != nil { return true }
        let once = docs.appendingPathComponent("henge-autopilot-once.txt"), plan = docs.appendingPathComponent("henge-autopilot.txt")
        guard FileManager.default.fileExists(atPath: once.path) else { return false }
        try? FileManager.default.removeItem(at: plan)
        return (try? FileManager.default.moveItem(at: once, to: plan)) != nil
    }()

    @MainActor static func run(start: @escaping (VirtualMac) -> Void) async {
        guard enabled else { return }
        let url = docs.appendingPathComponent("henge-autopilot.txt")
        HengeLog.log("autopilot", "following \(url.lastPathComponent)")
        var done = 0 // lines already run
        while !Task.isCancelled {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            var lines = text.components(separatedBy: "\n")
            lines.removeLast() // only whole lines: the last piece has no newline yet
            if lines.count < done { done = 0 } // a new file
            while done < lines.count, !Task.isCancelled {
                let line = lines[done].trimmingCharacters(in: .whitespaces)
                done += 1
                if line.isEmpty || line.hasPrefix("#") { continue }
                /* What is typed may be a password: the log gets its length only. */
                HengeLog.log("autopilot", line.hasPrefix("type ") ? "type (\(line.count - 5) characters)" : line)
                await perform(line, start: start)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    @MainActor private static func perform(_ line: String, start: (VirtualMac) -> Void) async {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "mac":
            for _ in 0..<240 where !JITBootstrap.ready { try? await Task.sleep(nanoseconds: 500_000_000) }
            guard JITBootstrap.ready else { HengeLog.log("autopilot", "JIT is not on; not starting a Mac"); return }
            let all: [VirtualMac] = Machines.shared.all
            var mac: VirtualMac?
            if arg.isEmpty {
                mac = all.max { a, b in (a.lastUsed ?? a.added) < (b.lastUsed ?? b.added) }
            } else {
                mac = all.first { $0.name.lowercased() == arg.lowercased() }
            }
            guard let mac else {
                HengeLog.log("autopilot", "no Mac called \(arg); there are \(all.map(\.name))")
                return
            }
            start(mac)
        case "wait":
            try? await Task.sleep(nanoseconds: UInt64((Double(arg) ?? 0) * 1e9))
        case "type":
            await Keys.typeSlowly(arg)
        case "key":
            if let code = UInt16(arg) { Keys.press(code) }
        case "move", "click": // guest display pixels: nudged there in small steps, as macOS accelerates big ones
            let xy = arg.split(separator: " ").compactMap { Int32($0) }
            guard xy.count == 2 else { HengeLog.log("autopilot", "\(parts[0]) wants X Y"); return }
            var px: Int32 = 0, py: Int32 = 0
            for _ in 0..<1500 {
                guard henge_vm_pointer(&px, &py) == 0 else { break }
                let dx = xy[0] - px, dy = xy[1] - py
                if abs(dx) < 3 && abs(dy) < 3 { break }
                henge_vm_mouse_move(max(-16, min(16, dx)), max(-16, min(16, dy)))
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            if parts[0] == "click" {
                henge_vm_mouse_button(0, 1)
                try? await Task.sleep(nanoseconds: 120_000_000)
                henge_vm_mouse_button(0, 0)
            }
        case "pointer":
            var px: Int32 = 0, py: Int32 = 0
            let rc = henge_vm_pointer(&px, &py)
            HengeLog.log("autopilot", "pointer \(rc == 0 ? "at \(px), \(py)" : "not known yet")")
        case "cmd": // "cmd space", "cmd q": the key with Command held
            if let c = arg == "space" ? " " : arg.first { Keys.chord(125, c) }
        case "knob":
            let kv = arg.split(separator: " ")
            if kv.count == 2, let value = Int32(kv[1]) {
                let found = henge_vm_knob(String(kv[0]), value)
                HengeLog.log("autopilot", found != 0 ? "knob \(kv[0]) = \(value)" : "no knob \(kv[0]) (or no Mac running)")
            }
        case "snap": // the Mac's screen, full size, into Documents/snap.jpg (or NAME.jpg): "snap", "snap safari"
            let name = arg.isEmpty ? "snap" : arg
            let url = docs.appendingPathComponent("\(name).jpg")
            let size = macSize()
            if let image = MacPreview.capture(width: size.width, height: size.height),
               let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.9), (try? data.write(to: url, options: .atomic)) != nil {
                HengeLog.log("autopilot", "snap \(url.lastPathComponent) \(size.width)x\(size.height), \(data.count / 1024) KB")
            } else {
                HengeLog.log("autopilot", "snap: no screen to read")
            }
        case "screen": // "screen 951 669", "screen off"
            guard let display = DisplayRouter.current else { HengeLog.log("autopilot", "screen: no Mac on screen"); break }
            let wh = arg.split(separator: " ").compactMap { Double($0) }
            if arg == "off" {
                display.simulated = nil
                HengeLog.log("autopilot", "screen: the device's own space again")
            } else if wh.count == 2 {
                let scale = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.scale }.first ?? 3
                let size = DisplayRouter.Size.fitting(CGSize(width: wh[0], height: wh[1]), scale: scale, retina: display.isRetina)
                display.simulated = size
                HengeLog.log("autopilot", "screen \(wh[0])x\(wh[1]) pt: asking for \(size.map { "\($0.width)x\($0.height)" } ?? "nothing")")
            } else {
                HengeLog.log("autopilot", "screen wants W H (points) or off")
            }
        case "check":
            check(arg.isEmpty ? "check" : arg)
        case "cpus": // "cpus 2": the CPU count the next Mac started gets (the CPUs setting, kept: put it back after a test)
            if let n = Int(arg), (1...Device.maxCPUs).contains(n) {
                UserDefaults.standard.set(n, forKey: "henge.cpus")
                HengeLog.log("autopilot", "cpus \(n) for the next start")
            } else {
                HengeLog.log("autopilot", "cpus wants 1 to \(Device.maxCPUs)")
            }
        case "env": // "env HV_QOS ui": an engine setting read when the next Mac starts (one not in henge-env.txt, which wins)
            let kv = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                setenv(kv[0], kv[1], 1)
                HengeLog.log("autopilot", "env \(kv[0])=\(kv[1]) for the next start")
            } else if kv.count == 1 {
                unsetenv(kv[0])
                HengeLog.log("autopilot", "env \(kv[0]) unset")
            }
        case "balloon": // "balloon 2048": ask the Mac to hand 2 GB of its memory back (needs HV_BALLOON in henge-env.txt)
            let got = henge_vm_balloon(Int(arg) ?? -1)
            HengeLog.log("autopilot", got < 0 ? "no balloon (set HV_BALLOON in henge-env.txt)" : "balloon: the Mac has handed over \(got) MB")
        case "tlsamples": // the sample Mac programs into Documents/Mac Apps (Mac apps without macOS)
            guard let dmg = Bundle.main.url(forResource: "tl-samples", withExtension: "dmg") else { HengeLog.log("autopilot", "no samples in this build"); break }
            try? FileManager.default.createDirectory(at: MacAppsStore.folder, withIntermediateDirectories: true)
            var err = [CChar](repeating: 0, count: 512)
            let n = henge_tl_import_dmg(dmg.path, MacAppsStore.folder.path, &err, err.count)
            HengeLog.log("autopilot", "tlsamples: \(n) copied \(String(cString: err))")
        case "tl": // "tl Hello (C)": run a program from Documents/Mac Apps (or a path) through the translation layer; output to the log
            let url = arg.hasPrefix("/") ? URL(fileURLWithPath: arg) : MacAppsStore.folder.appendingPathComponent(arg)
            guard let app = MacApp(url: url) else { HengeLog.log("autopilot", "tl: \(url.path) is not a Mac app or program"); break }
            let out = MacAppsStore.output(for: app)
            let exe = app.executable
            let (rc, why) = await Task.detached { () -> (Int32, String) in
                var err = [CChar](repeating: 0, count: 512)
                let rc = henge_tl_run(exe, out.path, &err, err.count)
                return (rc, String(cString: err))
            }.value
            let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            HengeLog.log("autopilot", "tl: \(app.name) returned \(rc) \(why)")
            for line in text.prefix(4000).split(separator: "\n").prefix(40) { HengeLog.log("tl-out", String(line)) }
        case "log": // already in the log; the wall clock too, to line it up with things measured elsewhere
            HengeLog.log("autopilot", String(format: "at %.3f", Date().timeIntervalSince1970))
        case "stop":
            henge_vm_stop()
        case "exit":
            HengeLog.log("autopilot", "quitting")
            try? await Task.sleep(nanoseconds: 300_000_000)
            exit(0)
        default:
            HengeLog.log("autopilot", "unknown command")
        }
    }

    /// The Mac's screen as macOS has it now, or 1920 x 1080 before it says.
    @MainActor private static func macSize() -> DisplayRouter.Size {
        var w: UInt32 = 0, h: UInt32 = 0
        if henge_vm_display_size(&w, &h) == 0, w > 0, h > 0 { return DisplayRouter.Size(width: Int(w), height: Int(h)) }
        return DisplayRouter.current?.screen ?? DisplayRouter.Size(width: 1920, height: 1080)
    }

    /// The device's panel as a person sees it, less Henge's own controls: black, the Mac's screen in the rectangle
    /// the layout gives it, everything outside the panel's rounded corners cut away. The log gets what to compare:
    /// the mode against what was asked for, the picture's scale on each axis (equal unless it is stretched), and
    /// how far into the Mac's screen each corner reaches, in the Mac's pixels.
    @MainActor private static func check(_ name: String) {
        guard let display = DisplayRouter.current else { HengeLog.log("autopilot", "check: no Mac on screen"); return }
        let mac = macSize(), full = display.full, picture = display.picture
        let scale = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.scale }.first ?? 3
        // The panel's corners belong to the phone's own screen: a Mac on an external display has no shape cut
        // out of it, so its picture is not clipped here either.
        let radius = display.isExternal ? 0 : Device.displayCornerRadius
        let asked = display.requested.map { "\($0.width)x\($0.height)" } ?? "none"
        let sx = picture.width * scale / CGFloat(mac.width), sy = picture.height * scale / CGFloat(mac.height)
        HengeLog.log("check", "mode \(mac.width)x\(mac.height), asked \(asked), device \(Int(full.width))x\(Int(full.height)) pt at \(Int(scale))x, picture \(Int(picture.minX)),\(Int(picture.minY)) \(Int(picture.width))x\(Int(picture.height)) pt")
        HengeLog.log("check", String(format: "device px per Mac px: %.3f across, %.3f down%@", sx, sy, abs(sx - sy) > 0.01 ? " (STRETCHED)" : ""))
        // The corner arc, in the Mac's pixels: how much of the Mac's screen it hides at the corners, at the
        // middle of a 24 pt menu bar (macOS's own on a Mac without a notch, 2x on Retina).
        let rMac = radius * scale / sx
        let inset = max(0, min(picture.minX, picture.minY)) * scale / sx // picture inside the panel: the arc starts further out
        let r = max(0, rMac - inset)
        let barMiddle: CGFloat = display.isRetina ? 24 : 12
        let hidden = r > barMiddle ? r - (r * r - (r - barMiddle) * (r - barMiddle)).squareRoot() : 0
        HengeLog.log("check", String(format: "corner radius %.0f pt = %.0f Mac px; at the menu bar's middle (y %.0f) the first %.0f Mac px of each side are hidden; diagonal depth %.0f Mac px", radius, r, barMiddle, hidden, r * (1 - 1 / 2.0.squareRoot())))
        guard let image = MacPreview.capture(width: mac.width, height: mac.height) else { HengeLog.log("check", "no screen to read"); return }
        let pointer = pointerOnDevice(mac: mac, picture: picture)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        // Henge's own controls, as UIKit draws the window: the Mac's layer comes out black there (it is Metal), so the
        // window is laid over the Mac's screen with "lighten", which keeps the Mac where the window is black. Also
        // saved alone as NAME-ui.png, where a device screenshot comes back black.
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        let ui = window.map { w in
            UIGraphicsImageRenderer(size: w.bounds.size, format: format).image { _ in
                _ = w.drawHierarchy(in: w.bounds, afterScreenUpdates: false)
            }
        }
        let png = UIGraphicsImageRenderer(size: full, format: format).pngData { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: full))
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: full), cornerRadius: radius).addClip()
            UIImage(cgImage: image).draw(in: picture)
            if let pointer { pointer.image.draw(in: pointer.rect) }
            ui?.draw(in: CGRect(origin: .zero, size: full), blendMode: .lighten, alpha: 1)
        }
        let url = docs.appendingPathComponent("\(name).png")
        if (try? png.write(to: url, options: .atomic)) != nil {
            HengeLog.log("check", "\(url.lastPathComponent), \(png.count / 1024) KB")
        }
        if let data = ui?.pngData(), (try? data.write(to: docs.appendingPathComponent("\(name)-ui.png"), options: .atomic)) != nil {
            HengeLog.log("check", "\(name)-ui.png: Henge's controls alone")
        } else {
            HengeLog.log("check", "no window to draw Henge's controls from")
        }
    }

    /// The pointer as Henge draws it over the Mac's screen: its glyph at Henge's scale, where the Mac says it is, in
    /// device points. Logged: the glyph, the scale, and the size it comes out on the device.
    @MainActor private static func pointerOnDevice(mac: DisplayRouter.Size, picture: CGRect) -> (image: UIImage, rect: CGRect)? {
        var w: UInt32 = 0, h: UInt32 = 0
        var hx: Int32 = 0, hy: Int32 = 0, scale: Int32 = 0, shown: Int32 = 0
        var glyph = [UInt8](repeating: 0, count: 512 * 512 * 4)
        guard henge_vm_cursor(&glyph, glyph.count, &w, &h, &hx, &hy, &scale, &shown) == 0, w > 0, h > 0, w <= 512, h <= 512 else {
            HengeLog.log("check", "pointer: none from macOS yet")
            return nil
        }
        var px: Int32 = 0, py: Int32 = 0
        let at = henge_vm_pointer(&px, &py) == 0
        let perMac = picture.width / CGFloat(max(mac.width, 1)) // device points per Mac pixel
        let size = CGSize(width: CGFloat(w) * CGFloat(scale) * perMac, height: CGFloat(h) * CGFloat(scale) * perMac)
        HengeLog.log("check", String(format: "pointer glyph %ux%u hot %d,%d, Henge scale %d, drawn %ux%u Mac px = %.1fx%.1f pt on the device, %@, %@",
                                     w, h, hx, hy, scale, w * UInt32(scale), h * UInt32(scale), size.width, size.height,
                                     shown != 0 ? "shown" : "hidden", at ? "at \(px),\(py)" : "position unknown"))
        guard at, shown != 0 else { return nil }
        let bytes = glyph.prefix(Int(w * h * 4))
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cg = CGImage(width: Int(w), height: Int(h), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(w) * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let origin = CGPoint(x: picture.minX + (CGFloat(px) - CGFloat(hx * scale)) * perMac,
                             y: picture.minY + (CGFloat(py) - CGFloat(hy * scale)) * perMac)
        return (UIImage(cgImage: cg), CGRect(origin: origin, size: size))
    }
}
