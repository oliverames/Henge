import SwiftUI
import UIKit
import GameController

/// What this device is, for what the app says and suggests.
enum Device {
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    static let name = isPad ? "iPad" : "iPhone"

    /// A Mac's screen that fills this device on its side: 1920 wide, as tall as the shape asks. iPads and
    /// squarer phones (iPhone Duo, about 1.46:1) would get bars above and below at 16:9. Phones wider
    /// than 16:9 come out at 1920×1080, as before.
    static var fittingScreen: (width: Int, height: Int) {
        let size = UIScreen.main.bounds.size
        let shape = max(size.width, size.height) / max(min(size.width, size.height), 1)
        return (1920, min(max(Int((1920 / shape / 8).rounded()) * 8, 1080), 1440))
    }

    /// Preserve the iPad's shape while reducing the virtual GPU's pixel work.
    static var performanceScreen: (width: Int, height: Int) {
        let fit = fittingScreen
        return (1600, Int((Double(fit.height) * 5 / 6 / 8).rounded()) * 8)
    }

    /// The panel itself, on its side: every physical pixel, and its real size in mm so that macOS
    /// sees a Retina density and draws at 2x (looks like half the pixels, sharp as the iPad's own UI).
    /// Every iPad with an M chip is 264 ppi.
    static var retinaScreen: (width: Int, height: Int) {
        let n = UIScreen.main.nativeBounds.size
        return (Int(max(n.width, n.height)) / 8 * 8, Int(min(n.width, n.height)) / 8 * 8)
    }
    static var retinaMM: (width: Int, height: Int) {
        let s = retinaScreen
        return (Int((Double(s.width) / 264 * 25.4).rounded()), Int((Double(s.height) / 264 * 25.4).rounded()))
    }

    /// How much memory to suggest for a new Mac: what leaves this device room for iOS.
    static var suggestedRAMGB: Int {
        let mb = ProcessInfo.processInfo.physicalMemory >> 20
        // m4 fork: an 8 GB iPad (7.4 GB usable) thrashes and kills the Mac at 6 GB: 16 GB devices only.
        // A 6 GB device (5.7 GB usable) could not build a 4 GB Mac, and installed a 3 GB one (#70); 4 GB devices, 2.
        return mb >= 14_000 ? 8 : mb >= 10_000 ? 6 : mb >= 7_000 ? 4 : mb >= 5_000 ? 3 : 2
    }

    /// The choices for a Mac's memory, in GB.
    static let memoryChoices = 1...16

    /// What a choice risks on this device, if anything. An install always gets at least 2 GB (Installer.install).
    static func memoryNote(_ gb: Int) -> String? {
        if gb < 4 { return "macOS has little room under 4 GB, so it can be very slow." }
        if gb > suggestedRAMGB { return "More than \(suggestedRAMGB) GB is a lot for this \(name): iOS may close Henge when macOS gets busy." }
        return nil
    }

    /// The virtual CPU offers Armv8.5 instructions (core/sysreg.c), and macOS uses them. They run as
    /// they are, so the chip needs them too: A14, M1 and later, which is iPhone13,x and iPad13,x up.
    static let chipTooOld: Bool = {
        let model = HengeLog.deviceModel
        guard model.hasPrefix("iPhone") || model.hasPrefix("iPad"),
              let major = Int(model.drop { !$0.isNumber }.prefix { $0.isNumber }) else { return false }
        return major < 13
    }()

    static let chipTooOldText = "macOS won't run on this \(name). Henge needs an A14 or M1 chip or newer."
}

/// A keyboard attached to the device. iOS reports each key going down and coming up by its HID usage,
/// which is what the Mac's USB keyboard sends, so every key and modifier goes straight across.
enum HardwareKeys {
    private static var held: Set<UInt8> = []
    private static var lastKey: CFTimeInterval = 0

    /// With the on-screen keyboard's view holding the keyboard, iOS may also offer a hardware key as
    /// text, and again as it repeats. The Mac has the key already, and repeats it itself.
    static var keyJustPressed: Bool {
        held.contains { $0 < 0xe0 } || CACurrentMediaTime() - lastKey < 0.1
    }

    /// Sends the presses that are keys, and returns the rest.
    static func send(_ presses: Set<UIPress>, down: Bool) -> Set<UIPress> {
        var rest = Set<UIPress>()
        // A chord can arrive in one unordered Set. Press modifiers first and
        // release them last so the guest sees the intended shortcut.
        let ordered = presses.sorted { a, b in
            let aCode = a.key?.keyCode.rawValue ?? 0
            let bCode = b.key?.keyCode.rawValue ?? 0
            let aModifier = (0xe0...0xe7).contains(aCode)
            let bModifier = (0xe0...0xe7).contains(bCode)
            if aModifier != bModifier { return down ? aModifier : !aModifier }
            return aCode < bCode
        }
        for press in ordered {
            guard let raw = press.key?.keyCode.rawValue, raw >= 0x04, raw <= 0xe7 else {
                rest.insert(press)
                continue
            }
            let usage = UInt8(raw)
            henge_vm_key_hid(usage, down ? 1 : 0)
            if usage < 0xe0 { lastKey = CACurrentMediaTime() }
            if down {
                held.insert(usage)
            } else {
                held.remove(usage)
                if usage < 0xe0 { StickyKeys.shared.releaseAll() } // one key after a tap on ⌃, ⌥ or ⌘
            }
        }
        return rest
    }

    /// iPadOS can keep a key's release when it takes over, as it does for ⌘-Tab: the Mac must not
    /// go on thinking the key is down.
    static func releaseAll() {
        for usage in held { henge_vm_key_hid(usage, 0) }
        held.removeAll()
    }
}

/// While a Mac runs, a keyboard's ⌘ shortcuts are the Mac's. iOS 26 gave every app a main menu, and its
/// standard commands (⌘H Hide, ⌘M Minimize, ⌘W Close, ⌘Q Quit, ⌘, Settings, ⌘F Find, ⌘Z, ⌘C, ⌘V and the
/// rest) are matched before a key reaches a view, so the shortcut worked on Henge instead of the Mac (#122).
/// The main menu is built without them while a session is on screen. What iOS itself reserves (⌘Tab,
/// ⌘Space, the Globe key's shortcuts) still goes to iOS: no app can take those.
@MainActor
enum MacShortcuts {
    private static var configured = false
    private(set) static var macOnScreen = false

    /// Once, at launch: the menu is rebuilt through this handler from then on.
    static func configure() {
        guard #available(iOS 26.0, *), !configured else { return }
        configured = true
        UIMainMenuSystem.shared.setBuildConfiguration(UIMainMenuSystem.Configuration()) { builder in
            guard macOnScreen else { return }
            let menus: [UIMenu.Identifier] = [.hide, .quit, .preferences, .services, .close, .newItem, .document, .print,
                                              .undoRedo, .standardEdit, .find, .edit, .format, .view, .toolbar,
                                              .sidebar, .fullscreen, .minimizeAndZoom, .bringAllToFront, .window,
                                              .help, .file]
            for menu in menus where builder.menu(for: menu) != nil { builder.remove(menu: menu) }
        }
    }

    static func setMacOnScreen(_ on: Bool) {
        guard on != macOnScreen else { return }
        macOnScreen = on
        guard #available(iOS 26.0, *), configured else { return }
        UIMainMenuSystem.shared.setNeedsRebuild()
        HengeLog.log("input", "Henge's menu shortcuts \(on ? "off: the Mac has the keyboard" : "back")")
    }
}

/// Asks iPadOS to hand the pointer over, so a trackpad or mouse drives only the Mac's pointer. It does
/// that only for an app filling the screen. SwiftUI has no way to ask, so the answer is added to the
/// class of the window's root view controller, which is who iPadOS asks.
enum PointerLock {
    private static var wanted = false
    private static var patched: Set<ObjectIdentifier> = []

    static func set(_ on: Bool) {
        wanted = on
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows {
            guard let root = window.rootViewController else { continue }
            let kind: AnyClass = type(of: root)
            if patched.insert(ObjectIdentifier(kind)).inserted {
                let answer: @convention(block) (UIViewController) -> Bool = { _ in wanted }
                class_replaceMethod(kind, #selector(getter: UIViewController.prefersPointerLocked), imp_implementationWithBlock(answer), "B@:")
            }
            root.setNeedsUpdateOfPrefersPointerLocked()
        }
    }

    /// iPadOS only locks the pointer to an app that fills the screen: in a window (Stage Manager, or iPadOS 26's windows)
    /// the request is ignored and the system pointer stays separate from the Mac's (#18). An iPhone never locks it, and
    /// its apps are always full screen, so the hint is for iPad only.
    static var refused: Bool {
        guard Device.isPad, wanted, GCMouse.current != nil else { return false }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
        return !scenes.isEmpty && !scenes.contains { $0.pointerLockState?.isLocked == true }
    }
}

/// A Magic Keyboard's trackpad or a mouse, while a Mac is running. GameController gives the raw motion,
/// which macOS then accelerates as it would for its own mouse. Once macOS has the Mac's USB mouse, it all
/// goes there: real right, middle, back and forward buttons and the Mac's own Mouse settings. Before that
/// (early boot) it goes to the virtio mouse, whose right button is a Control-click.
///
/// GameController calls the handlers on its handler queue, the main queue unless told otherwise, where
/// they waited behind SwiftUI layout and drawing: a mouse lagged behind the touch trackpad (#122). Here
/// they run on a queue of their own, and everything below that the handlers touch belongs to it.
final class HardwareMouse {
    static let shared = HardwareMouse()
    static let speedKey = "henge.mouse.speed"
    static let reverseKey = "henge.mouse.reverse"
    static let scrollSpeedKey = "henge.mouse.scrollSpeed"

    private let queue = DispatchQueue(label: "henge.mouse", qos: .userInteractive)
    private var started = false
    private var observers: [NSObjectProtocol] = []
    private var mice: [GCMouse] = []
    // The rest is the queue's.
    private var buttons = PhysicalMouseButtons(swapsRightAndMiddle: false)
    private var usbHeld: UInt32 = 0 // buttons down on the USB mouse, as its report's bits
    private var buttonsLogged = 0
    private var restX: Float = 0, restY: Float = 0
    private var restWheel: Float = 0, restPan: Float = 0
    private var speed: Float = 1
    private var reverse = false
    private var scrollsLogged = 0 // the first few, to see what a device's raw values look like
    private var lastScrollFirst: Float = 0, lastScrollSecond: Float = 0
    private var lastRoute: Bool?

    func start() {
        if started { stop() } // again after a boot: fresh settings, and one set of observers
        started = true
        let defaults = UserDefaults.standard
        let speed = defaults.object(forKey: Self.speedKey) == nil ? 1 : Float(defaults.double(forKey: Self.speedKey))
        let reverse = defaults.bool(forKey: Self.reverseKey)
        let swapButtons = defaults.bool(forKey: PhysicalMouseButtons.swapKey)
        queue.sync {
            self.speed = speed
            self.reverse = reverse
            self.buttons = PhysicalMouseButtons(swapsRightAndMiddle: swapButtons)
            self.usbHeld = 0
            self.buttonsLogged = 0
            self.restX = 0; self.restY = 0; self.restWheel = 0; self.restPan = 0
            self.lastScrollFirst = 0; self.lastScrollSecond = 0
            self.lastRoute = nil
        }
        HengeLog.log("input", "physical mouse: swap right/middle \(swapButtons ? "on" : "off")")
        GCMouse.mice().forEach(attach)
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidConnect, object: nil, queue: .main) { [weak self] note in
            if let mouse = note.object as? GCMouse { self?.attach(mouse) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .GCMouseDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let self, let mouse = note.object as? GCMouse else { return }
            self.releaseButtons()
            self.mice.removeAll { $0 === mouse }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIPointerLockState.didChangeNotification, object: nil, queue: .main) { note in
            // The scene comes in the user info: the notification's object isn't it.
            let scene = note.userInfo?[UIPointerLockState.sceneUserInfoKey] as? UIScene
            let locked = scene?.pointerLockState?.isLocked ?? false
            HengeLog.log("input", "pointer lock: \(locked ? "on" : "off")")
        })
        PointerLock.set(true)
    }

    func stop() {
        guard started else { return }
        started = false
        PointerLock.set(false)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        for mouse in mice {
            guard let input = mouse.mouseInput else { continue }
            input.mouseMovedHandler = nil
            input.leftButton.pressedChangedHandler = nil
            input.rightButton?.pressedChangedHandler = nil
            input.middleButton?.pressedChangedHandler = nil
            input.auxiliaryButtons?.forEach { $0.pressedChangedHandler = nil }
            input.scroll.valueChangedHandler = nil
        }
        mice.removeAll()
        releaseButtons() // after the handlers: none can press again behind it
    }

    /// Any thread but the mouse's own queue.
    func releaseButtons() {
        queue.sync {
            for button in buttons.releaseAll() where usbHeld & (1 << UInt32(button)) == 0 {
                henge_vm_mouse_button(button, 0)
            }
            if usbHeld != 0 {
                usbHeld = 0
                henge_vm_usb_mouse_buttons(0)
            }
        }
    }

    private func attach(_ mouse: GCMouse) {
        guard let input = mouse.mouseInput, !mice.contains(where: { $0 === mouse }) else { return }
        mice.append(mouse)
        mouse.handlerQueue = queue
        let aux = input.auxiliaryButtons?.count ?? 0
        HengeLog.log("input", "mouse: \(mouse.vendorName ?? "?"), right button \(input.rightButton != nil), middle \(input.middleButton != nil), more buttons \(aux)")
        input.mouseMovedHandler = { [weak self] _, dx, dy in self?.moved(dx, dy) }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(0, pressed) }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(1, pressed) }
        input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in self?.button(2, pressed) }
        // The first two extra buttons are a mouse's side buttons: the USB mouse's back and forward.
        for (i, extra) in (input.auxiliaryButtons ?? []).prefix(2).enumerated() {
            extra.pressedChangedHandler = { [weak self] _, _, pressed in self?.sideButton(UInt32(3 + i), pressed) }
        }
        input.scroll.valueChangedHandler = { [weak self] _, first, second in self?.scrolled(first, second) }
    }

    /// Whether this event goes to the USB mouse. Logged when it changes, so a device log shows the handover.
    private func usbRoute() -> Bool {
        let usb = henge_vm_usb_mouse_ready() != 0
        if usb != lastRoute {
            lastRoute = usb
            HengeLog.log("input", "physical mouse: to the Mac's \(usb ? "USB mouse" : "virtio mouse")")
        }
        return usb
    }

    /// GameController's Y runs upward. What doesn't make a whole step yet waits for the next move.
    private func moved(_ dx: Float, _ dy: Float) {
        restX += dx * speed
        restY -= dy * speed
        let x = restX.rounded(), y = restY.rounded()
        guard x != 0 || y != 0 else { return }
        restX -= x
        restY -= y
        if usbRoute() { henge_vm_usb_mouse_move(Int32(x), Int32(y)) }
        else { henge_vm_mouse_move(Int32(x), Int32(y)) }
    }

    private func button(_ physicalButton: Int32, _ pressed: Bool) {
        guard let guestButton = buttons.event(physicalButton, pressed: pressed) else { return }
        let bit = UInt32(1) << UInt32(guestButton)
        // A release goes where its press went, even if the route changed in between.
        let usb = pressed ? usbRoute() : usbHeld & bit != 0
        if buttonsLogged < 32 {
            buttonsLogged += 1
            HengeLog.log("input", "physical mouse button: raw=\(physicalButton) guest=\(guestButton) \(pressed ? "down" : "up") \(usb ? "usb" : "virtio")")
        }
        if usb {
            usbHeld = pressed ? usbHeld | bit : usbHeld & ~bit
            henge_vm_usb_mouse_buttons(usbHeld)
        } else {
            henge_vm_mouse_button(guestButton, pressed ? 1 : 0)
        }
        if !pressed { DispatchQueue.main.async { StickyKeys.shared.releaseAll() } }
    }

    /// Back (3) and forward (4): only the USB mouse has them.
    private func sideButton(_ bit: UInt32, _ pressed: Bool) {
        let mask = UInt32(1) << bit
        guard pressed ? usbRoute() : usbHeld & mask != 0 else { return }
        usbHeld = pressed ? usbHeld | mask : usbHeld & ~mask
        henge_vm_usb_mouse_buttons(usbHeld)
    }

    /// GameController puts vertical motion on the first axis and horizontal on the second.
    private func scrolled(_ first: Float, _ second: Float) {
        // GameController reports both axis states when either one changes. On a
        // Magic Keyboard it calls us twice per movement, with one stale axis in
        // each call; sending both values doubles the scroll and adds sideways drift.
        let verticalChanged = first != lastScrollFirst
        let horizontalChanged = second != lastScrollSecond
        lastScrollFirst = first
        lastScrollSecond = second
        let mostlyVertical = abs(first) > 2 * abs(second)
        let mostlyHorizontal = abs(second) > 2 * abs(first)
        let verticalRaw = verticalChanged && !mostlyHorizontal ? -first : 0
        let horizontalRaw = horizontalChanged && !mostlyVertical ? second : 0
        let way: Float = reverse ? -1 : 1
        let configured = UserDefaults.standard.object(forKey: Self.scrollSpeedKey) == nil
            ? 0.3 : UserDefaults.standard.double(forKey: Self.scrollSpeedKey) // the session's slider changes it live
        let scrollScale = Float(configured.isFinite ? min(max(configured, 0.1), 1.5) : 0.3)
        if usbRoute() {
            // The USB mouse takes wheel detents, and macOS accelerates them as it does a real wheel's.
            // A wheel's notch is one raw unit; a trackpad's smaller steps add up until they make one.
            let perUnit = scrollScale / 0.3
            restWheel += verticalRaw * way * perUnit // positive is away from the user, as the virtio wheel's is
            restPan += horizontalRaw * way * perUnit
            let wheel = max(-16, min(16, restWheel.rounded(.towardZero)))
            let pan = max(-16, min(16, restPan.rounded(.towardZero)))
            restWheel -= wheel
            restPan -= pan
            if abs(restWheel) > 4 { restWheel = 0 } // a capped burst doesn't play on afterwards
            if abs(restPan) > 4 { restPan = 0 }
            if scrollsLogged < 24 {
                scrollsLogged += 1
                HengeLog.log("input", "scroll raw: \(first), \(second); usb detents: \(Int(pan)), \(Int(wheel))")
            }
            if wheel != 0 || pan != 0 { henge_vm_usb_mouse_scroll(Int32(wheel), Int32(pan)) }
            return
        }
        // macOS accelerates virtio wheel units roughly quadratically, so use a tunable square root
        // and cap each event to keep a small pad gesture from jumping across a page.
        let horizontal = Int32(way) * Self.wheelUnits(horizontalRaw, scale: scrollScale)
        let vertical = Int32(way) * Self.wheelUnits(verticalRaw, scale: scrollScale)
        if scrollsLogged < 24 {
            scrollsLogged += 1
            HengeLog.log("input", "scroll raw: \(first), \(second); units: \(horizontal), \(vertical)")
        }
        if horizontal != 0 || vertical != 0 { henge_vm_mouse_scroll(horizontal, vertical) }
    }

    private static func wheelUnits(_ value: Float, scale: Float) -> Int32 {
        guard value.isFinite else { return 0 }
        let units = Int32(min(32, (22 * scale * abs(value).squareRoot()).rounded()))
        return value < 0 ? -units : units
    }
}
