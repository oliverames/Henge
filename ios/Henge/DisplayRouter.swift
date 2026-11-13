import SwiftUI
import QuartzCore

/// Owned by SessionView, and shared with its display accessory. Only one layer
/// receives frames; the phone's input views stay alive when the monitor takes over.
@MainActor
final class DisplayRouter: ObservableObject {
    @Published private(set) var isExternal = false
    /// The Mac's screen as macOS has it now: its boot size, then whatever it took since. Nil before a Mac starts,
    /// when the Mac's own setting says.
    @Published private(set) var screen: Size?
    var aspect: CGFloat? { screen.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } }

    /// Whether the Mac's screen follows the space it is shown in (a Mac set to fit, or Retina). Set while it runs.
    private var follows = false
    private var retina = false
    private var running = false
    /// The size each surface would like macOS to have, in pixels: the device's own (nil key) and each external one.
    private var wanted: [UUID?: Size] = [:]
    private var asked: Size?
    private var pending: Task<Void, Never>?

    struct Size: Equatable { var width: Int, height: Int }

    /// The router of the Mac on screen, for the autopilot's display tests.
    static weak var current: DisplayRouter?
    /// A test's stand-in for the device's own space (autopilot "screen W H"): asked for in place of what the device's
    /// layout wants, so a rotation or a fold can be tested with nobody holding the phone. Nil: the real layout.
    var simulated: Size? { didSet { follow() } }
    /// Where the Mac's picture is on the device, in points from its top left, and the device's whole size: what the
    /// autopilot's "check" draws the Mac's screen into, with the panel's corners.
    var picture: CGRect = .zero
    var full: CGSize = .zero
    var isRetina: Bool { retina }
    /// The size asked of macOS last.
    var requested: Size? { asked }
    /// The external display's own density, in pixels per mm, once a surface on it has read the panel's
    /// shape (ExternalMacDisplay). Nil until then; an external display without a figure keeps the 1x default.
    var externalDensity: Float?
    /// Gives the router the external display's density: its panel's pixels over its physical size.
    func setExternalDensity(_ pxmm: Float?) {
        externalDensity = pxmm
        follow()
    }

    private var targets = DisplayTargetSelection()
    private var layers: [UUID: CAMetalLayer] = [:]
    private var selected: UUID?

    func connect(_ id: UUID, layer: CAMetalLayer, role: DisplayTargetSelection.Role) {
        layers[id] = layer
        targets.connect(id, role: role)
        updateTarget()
    }

    func disconnect(_ id: UUID) {
        targets.disconnect(id)
        updateTarget()
        layers.removeValue(forKey: id)
        wanted.removeValue(forKey: id)
    }

    /// A Mac is starting with this screen; `follows` says whether it may change size to the space it is shown in.
    func begin(screen: (width: Int, height: Int), follows: Bool, retina: Bool) {
        self.retina = retina
        self.screen = Size(width: screen.width, height: screen.height)
        asked = self.screen
        self.follows = follows
        running = false
        Self.current = self
    }

    /// macOS is up (or stopped): from now on a new size goes to it as it changes.
    func setRunning(_ on: Bool) {
        running = on
        pending?.cancel()
        if on { follow() }
    }

    /// The size the device's screen (nil) or an external display would give the Mac; nil to stop asking (upright,
    /// zoomed, typing: the Mac keeps what it has).
    func want(_ size: Size?, on surface: UUID? = nil) {
        guard wanted[surface] != size else { return }
        wanted[surface] = size
        follow()
    }

    /// What macOS has taken, read again (the session does once a second): a size asked for before macOS was up to
    /// take it is taken during its boot.
    func sync() {
        var w: UInt32 = 0, h: UInt32 = 0
        guard running, henge_vm_display_size(&w, &h) == 0, w > 0, h > 0 else { return }
        let taken = Size(width: Int(w), height: Int(h))
        if taken != screen {
            screen = taken
            HengeLog.log("display", "macOS took \(w)x\(h)")
            refresh()
        }
    }

    /// Asks macOS for the selected surface's size once it has stayed the same a moment: a rotation, a window being
    /// dragged larger or a display coming and going asks once, not at every step.
    private func follow() {
        guard follows, running else { return }
        let device: UUID? = nil
        // On an external display, its size only: until it says, the Mac keeps what it has.
        let size = targets.isExternal ? selected.flatMap { wanted[$0] } : simulated ?? wanted[device]
        pending?.cancel() // a size asked for a moment ago and not wanted now
        guard let size, size != asked else { return }
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            self.asked = size
            // A Retina Mac keeps its panel's density on the device's own screen. An external display reports its
            // own panel's density (read off its screen by the surface): macOS then treats it as the HiDPI panel it
            // is, and offers the scaled modes a real Mac gets on it. No figure, no panel shape known: 1x.
            let density: Float = self.targets.isExternal
                ? (self.externalDensity ?? 0)
                : (self.retina ? Float(Device.retinaPPI / 25.4) : 0)
            HengeLog.log("display", "asking macOS for \(size.width)x\(size.height), \(density) px/mm")
            henge_vm_set_display_live(UInt32(size.width), UInt32(size.height), density)
            // The layout takes the new shape when macOS does, so the picture is never stretched or squeezed.
            for _ in 0..<50 where !Task.isCancelled && self.screen != size {
                self.sync()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Re-present the latest frame after layout or a return from the background,
    /// even when macOS is idle and isn't submitting another frame.
    func refresh(_ id: UUID? = nil) {
        guard id == nil || id == selected else { return }
        sendTarget()
    }

    private func updateTarget() {
        let next = targets.selected
        if next != selected {
            selected = next
            sendTarget()
            follow()
        }
        if isExternal != targets.isExternal { isExternal = targets.isExternal }
    }

    private func sendTarget() {
        let layer = selected.flatMap { layers[$0] }
        henge_vm_set_display_layer(layer.map { Unmanaged.passUnretained($0).toOpaque() })
    }
}

extension DisplayRouter.Size {
    /// The Mac's screen for a space of this many points at this scale. Retina: every pixel. Otherwise what
    /// Device.fittingScreen picks for a whole device, for any shape: 1920 wide and as tall as the shape asks, or for a
    /// space squarer than 4:3, 1440 tall and as wide as it asks.
    static func fitting(_ points: CGSize, scale: CGFloat, retina: Bool) -> Self? {
        guard points.width >= 100, points.height >= 100 else { return nil }
        if retina {
            return Self(width: Int(points.width * scale) / 8 * 8, height: Int(points.height * scale) / 8 * 8)
        }
        let shape = points.width / points.height
        // Wider than 16:9 stays 1920 x 1080, beside bars, as a Mac set to fit always has on such a phone.
        if shape >= 4.0 / 3 { return Self(width: 1920, height: max(Int((1920 / shape / 8).rounded()) * 8, 1080)) }
        return Self(width: max(Int((1440 * shape / 8).rounded()) * 8, 800), height: 1440)
    }

    /// An external display: the panel's own pixels. macOS scales down from them (a 4K panel's default is
    /// 1920x1080 at 2x), so the guest renders the panel's real resolution and text is sharp, like on a real
    /// Mac at a monitor. Capped at 4096 x 4096 so a 5K+ panel still works at a cost, not a failure.
    static func external(_ points: CGSize, scale: CGFloat) -> Self? {
        guard points.width >= 100, points.height >= 100 else { return nil }
        let px = CGSize(width: points.width * scale, height: points.height * scale)
        let down = min(1, 4096 / px.width, 4096 / px.height)
        return Self(width: Int(px.width * down) / 8 * 8, height: Int(px.height * down) / 8 * 8)
    }
}
