import AVFAudio
import UIKit

/// The Mac's sound on this device: the audio session it plays through, and what brings it back.
///
/// The engine plays the Mac's sound through RemoteIO (host/audio_mac.c). A phone call, Siri or an alarm
/// interrupts that unit and iOS doesn't start it again; when iOS resets its media services the unit is
/// gone for good. Either way the Mac's sound stayed silent until Henge was relaunched. Here the session is
/// made active again and the engine is told to build a new player (henge_vm_audio_kick). The output
/// (speaker, AirPods, the display's HDMI audio) is logged as it changes, so a device log says where the
/// sound went.
final class HengeAudio {
    static let shared = HengeAudio()
    private var observers: [NSObjectProtocol] = []

    /// At launch, once.
    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            self?.interrupted(note)
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            HengeLog.log("audio", "media services were reset")
            self?.comeBack()
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] note in
            self?.routeChanged(note)
        })
    }

    /// A Mac is starting: its sound needs the session active (RemoteIO won't start in an inactive one).
    func activate() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            HengeLog.log("audio", "session active, output \(Self.describe(session.currentRoute)), \(Int(session.sampleRate)) Hz")
        } catch {
            HengeLog.log("audio", "session not active: \(error.localizedDescription)")
        }
    }

    private func interrupted(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            HengeLog.log("audio", "interrupted")
        case .ended:
            HengeLog.log("audio", "interruption ended")
            comeBack()
        @unknown default:
            break
        }
    }

    private func routeChanged(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        let route = AVAudioSession.sharedInstance().currentRoute
        HengeLog.log("audio", "output now \(Self.describe(route)) (reason \(raw))")
        // A new output, or the old one gone: a fresh player is made for whatever is current. RemoteIO
        // usually follows on its own; this covers the times it stops instead (a display's audio going away).
        if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable { henge_vm_audio_kick() }
    }

    private func comeBack() {
        activate()
        henge_vm_audio_kick()
    }

    private static func describe(_ route: AVAudioSessionRouteDescription) -> String {
        let outputs = route.outputs.map { "\($0.portName) (\($0.portType.rawValue))" }
        return outputs.isEmpty ? "none" : outputs.joined(separator: ", ")
    }
}
