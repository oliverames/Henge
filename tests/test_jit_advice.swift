import Foundation

@main
struct JITAdviceTests {
    static func main() {
        // Situation: Wi-Fi.
        let onWiFi = NetworkPathSnapshot(isSatisfied: true, usesWiFi: true, usesCellular: false, usesWired: false)
        precondition(NetworkSituation(onWiFi) == .wifi)

        // Situation: cellular data is the only way out.
        let onCellular = NetworkPathSnapshot(isSatisfied: true, usesWiFi: false, usesCellular: true, usesWired: false)
        precondition(NetworkSituation(onCellular) == .cellularOnly)

        // Situation: no usable path at all, whatever interfaces are listed.
        let offline = NetworkPathSnapshot(isSatisfied: false, usesWiFi: true, usesCellular: true, usesWired: false)
        precondition(NetworkSituation(offline) == .offline)

        // Situation: Wi-Fi wins when cellular is also usable.
        let both = NetworkPathSnapshot(isSatisfied: true, usesWiFi: true, usesCellular: true, usesWired: false)
        precondition(NetworkSituation(both) == .wifi)

        // Situation: a wired connection is not cellular, so it is not the misrouting case.
        let cabled = NetworkPathSnapshot(isSatisfied: true, usesWiFi: false, usesCellular: true, usesWired: true)
        precondition(NetworkSituation(cabled) == .wired)

        // Advice: the helper's real timeout over cellular blames iOS routing, not a missing VPN.
        let timeout = "Timed out connecting to 10.7.0.1:49152"
        let cellular = JITNetworkAdvice.advice(forHelperMessage: timeout, situation: .cellularOnly)
        precondition(cellular != nil)
        let text = cellular?.message ?? ""
        for phrase in ["LocalDevVPN", "cellular", "Cellular Data", "Control Center", "Wi-Fi", "hotspot", "Tailscale"] {
            precondition(text.contains(phrase), "cellular advice should mention \(phrase)")
        }
        precondition(!text.contains("!"))
        precondition(cellular?.actions == [.connectLocalDevVPN])

        // Advice: on Wi-Fi the same timeout still means LocalDevVPN is off.
        let wifiAdvice = JITNetworkAdvice.advice(forHelperMessage: timeout, situation: .wifi)
        precondition(wifiAdvice?.message == "Henge couldn't reach this device. Connect LocalDevVPN, then try again.")
        precondition(wifiAdvice?.actions == [.connectLocalDevVPN])

        // Advice: a pairing error keeps the pairing advice on every network.
        let reset = "Connection reset by peer while talking to the device"
        for situation in [NetworkSituation.wifi, .cellularOnly, .offline, .wired] {
            let pairing = JITNetworkAdvice.advice(forHelperMessage: reset, situation: situation)
            precondition(pairing?.message.contains("Pair again") == true, "pairing advice on \(situation)")
            precondition(pairing?.message.contains("Cellular Data") == false)
            precondition(pairing?.actions == [.pairAgain, .connectLocalDevVPN])
        }

        // Advice: an error about the device's state gets its own plain explanation, on any network, and never the
        // cellular advice.
        let deviceErrors: [(String, JITDeviceProblem, String)] = [
            ("idevice error: DeveloperModeNotEnabled", .developerModeOff, "Developer Mode"),
            ("Developer mode is not enabled", .developerModeOff, "Settings"),
            ("lockdownd: PasswordProtected", .locked, "Unlock"),
            ("device locked", .locked, "Unlock"),
            ("PairingDialogResponsePending", .trustPending, "trust"),
            ("lockdownd error: InvalidHostID", .pairingRejected, "Pair again"),
            ("UserDeniedPairing", .pairingRejected, "Pair again"),
            ("Pairing file error: failed to read pairing file", .pairingFileUnreadable, "Pair again"),
            ("heartbeat timeout", .slept, "screen on"),
            ("The Developer Disk Image was not mounted after the mount operation completed.", .diskImage, "Reset Developer Disk Image"),
            ("Developer Disk Image is not mounted", .diskImage, "Check setup"),
            ("Failed to establish a debugserver connection to the target process.", .debugserver, "Check setup"),
        ]
        for (message, problem, phrase) in deviceErrors {
            precondition(JITDeviceProblem(helperMessage: message) == problem, "\(message) should read as \(problem)")
            for situation in [NetworkSituation.wifi, .cellularOnly] {
                let advice = JITNetworkAdvice.advice(forHelperMessage: message, situation: situation)
                precondition(advice?.message.contains(phrase) == true, "\(message) advice should mention \(phrase)")
                precondition(advice?.message.contains("Cellular Data") == false)
                precondition(advice?.message.contains("!") == false)
            }
        }
        precondition(JITNetworkAdvice.advice(forHelperMessage: "InvalidHostID", situation: .wifi)?.actions == [.pairAgain])

        // Advice: an error that is about neither the network nor the device is shown as it came.
        precondition(JITNetworkAdvice.advice(forHelperMessage: "The JIT script threw an exception", situation: .wifi) == nil)
        // A timeout is still a connection problem, not a device one.
        precondition(JITDeviceProblem(helperMessage: "Timed out connecting to 10.7.0.1:49152") == nil)

        // Retry: the first connection over cellular is the one iOS misroutes, so try again shortly.
        guard case .retry(let wait) = JITRetryPolicy.decision(situation: .cellularOnly, problem: .unreachable, attempt: 1) else {
            preconditionFailure("an unreachable first attempt on cellular should be retried")
        }
        precondition(wait > 0 && wait <= 10, "the wait should be short")

        // Retry: the second retry is the last; the third failure is final.
        guard case .retry = JITRetryPolicy.decision(situation: .cellularOnly, problem: .unreachable, attempt: 2) else {
            preconditionFailure("the second attempt should still be followed by a retry")
        }
        precondition(JITRetryPolicy.decision(situation: .cellularOnly, problem: .unreachable, attempt: 3) == .giveUp)
        precondition(JITRetryPolicy.decision(situation: .cellularOnly, problem: .unreachable, attempt: 4) == .giveUp)

        // Retry: never on Wi-Fi, never for pairing errors, and only on cellular.
        for situation in [NetworkSituation.wifi, .wired, .offline] {
            precondition(JITRetryPolicy.decision(situation: situation, problem: .unreachable, attempt: 1) == .giveUp,
                         "no automatic retry on \(situation)")
        }
        for attempt in 1...3 {
            precondition(JITRetryPolicy.decision(situation: .cellularOnly, problem: .pairing, attempt: attempt) == .giveUp)
        }

        // Retry: what the screen says while it waits.
        let retrying = JITRetryPolicy.statusText(nextAttempt: 2)
        precondition(retrying.hasPrefix("Retrying") && retrying.contains("2 of 3") && !retrying.contains("!"))
        precondition(JITRetryPolicy.statusText(nextAttempt: 3).contains("3 of 3"))
        print("JIT advice: all checks passed")
    }
}
