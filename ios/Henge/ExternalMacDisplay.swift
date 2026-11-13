import SwiftUI

/// The accessory only presents the existing Mac's pixels. It never owns or
/// starts a VM, and hardware input continues through the phone's SessionView.
/// The Mac takes the display's own shape and pixels while it is shown there (DisplayRouter).
struct ExternalMacDisplay: View {
    let presentation: MacPresentation
    /// The id this display's view connects to the router under; a display scene passes its own. Kept as state:
    /// the accessory makes this view again at every update, and the size it asks for is filed under this id.
    @State private var surface: UUID
    @ObservedObject private var display: DisplayRouter

    init(presentation: MacPresentation, surface: UUID = UUID()) {
        self.presentation = presentation
        _surface = State(initialValue: surface)
        display = presentation.display
    }

    var body: some View {
        GeometryReader { geometry in
            let aspect = display.aspect ?? presentation.aspect
            let width = min(geometry.size.width, geometry.size.height * aspect)
            BootDisplay(display: presentation.display, role: .external, surface: surface)
                .frame(width: width, height: width / aspect)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DisplayScale { scale in want(geometry.size, scale: scale) })
                .onChange(of: geometry.size) { want($0) }
        }
        .background(.black)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .preferredColorScheme(.dark)
    }

    @State private var scale: CGFloat = 0

    private func want(_ size: CGSize, scale: CGFloat? = nil) {
        if let scale { self.scale = scale }
        guard self.scale > 0 else { return }
        // The panel's density goes with its shape: macOS needs both to treat the monitor as the HiDPI
        // display it is (iOS reports neither, so the diagonal comes from the app's settings, Device).
        display.setExternalDensity(Device.externalDensity(points: size, scale: self.scale))
        display.want(DisplayRouter.Size.external(size, scale: self.scale), on: surface)
    }
}

/// The scale of the screen a view is on (an external display's own, which UIScreen.main is not), once it is on one.
private struct DisplayScale: UIViewRepresentable {
    let found: (CGFloat) -> Void

    final class Probe: UIView {
        var found: ((CGFloat) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let screen = window?.windowScene?.screen else { return }
            let scale = screen.nativeScale
            DispatchQueue.main.async { [found] in found?(scale) }
        }
    }

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        view.found = found
        return view
    }

    func updateUIView(_ view: Probe, context: Context) { view.found = found }
}

/// Puts the session's Mac on an external display. iOS 27 delivers that scene only to this
/// accessory; earlier iOS connects it to ExternalDisplaySceneDelegate (LegacyExternalDisplay),
/// which is told about the session either way and acts only where iOS gives it scenes.
struct ExternalMacDisplayModifier: ViewModifier {
    let presentation: MacPresentation

    @ViewBuilder
    func body(content: Content) -> some View {
        let session = content
            .onAppear { LegacyExternalDisplay.shared.begin(presentation) }
            .onDisappear { LegacyExternalDisplay.shared.end(presentation) }
        if #available(iOS 27.0, *) { // the compiler requires this to call the iOS 27 sceneAccessory API
            session.sceneAccessory {
                ExternalNonInteractiveAccessory {
                    ExternalMacDisplay(presentation: presentation)
                }
            }
        } else {
            session
        }
    }
}
