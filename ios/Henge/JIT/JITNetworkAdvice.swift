// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// What the current network path offers, copied from NWPath by the app so this file stays Foundation-only.
struct NetworkPathSnapshot: Equatable {
    var isSatisfied: Bool
    var usesWiFi: Bool
    var usesCellular: Bool
    var usesWired: Bool
}

enum NetworkSituation: Equatable {
    case wifi
    case cellularOnly
    case wired
    case offline

    init(_ path: NetworkPathSnapshot) {
        if !path.isSatisfied {
            self = .offline
        } else if path.usesWiFi {
            self = .wifi
        } else if path.usesWired {
            self = .wired
        } else {
            // A satisfied path with no known interface type is not the cellular case: it keeps the plain VPN advice.
            self = path.usesCellular ? .cellularOnly : .wifi
        }
    }
}

/// What the user can be offered to do next.
enum JITAdviceAction: Equatable {
    case connectLocalDevVPN
    case pairAgain
}

struct JITAdvice: Equatable {
    var message: String
    var actions: [JITAdviceAction]
}

/// Why the built-in helper could not reach this device, read from its error text.
enum JITConnectionProblem: Equatable {
    /// Nothing answered at LocalDevVPN's address: the VPN is off or not routing, or iOS sent the connection elsewhere.
    case unreachable
    /// The device closed the connection, usually because it no longer accepts
    /// this pairing (every new pairing replaces the last).
    case pairing

    init?(helperMessage: String) {
        let text = helperMessage.lowercased()
        let has = { (needles: [String]) in needles.contains(where: text.contains) }
        if has(["connectionreset", "connection reset", "device refused connection"]) {
            self = .pairing
        } else if has(["connectionrefused", "connection refused", "timedout", "timed out",
                       "networkunreachable", "network unreachable", "hostunreachable",
                       "host unreachable", "no route"]) {
            self = .unreachable
        } else {
            return nil
        }
    }
}

/// A helper failure that is about this device's state, not the network: StikJIT passes the device's own error names
/// (DeveloperModeNotEnabled, InvalidHostID, ...) or its own sentences through, which mean nothing to most people.
enum JITDeviceProblem: Equatable {
    case developerModeOff
    case locked
    case trustPending
    /// The device does not accept this pairing (made for another device, replaced by a newer one, or refused).
    case pairingRejected
    /// The pairing file itself could not be read.
    case pairingFileUnreadable
    case diskImage
    /// The connection dropped because the device slept or the screen locked.
    case slept
    case debugserver

    init?(helperMessage: String) {
        let text = helperMessage.lowercased()
        let has = { (needles: [String]) in needles.contains(where: text.contains) }
        if has(["developer mode is not enabled", "developermodenotenabled"]) {
            self = .developerModeOff
        } else if has(["passwordprotected", "device locked", "devicelocked"]) {
            self = .locked
        } else if has(["pairing trust dialog pending", "pairingdialogresponsepending"]) {
            self = .trustPending
        } else if has(["invalidhostid", "user denied pairing", "userdeniedpairing", "device does not have pairing file"]) {
            self = .pairingRejected
        } else if has(["failed to read pairing file", "pairing file error", "not a remote pairing file"]) {
            self = .pairingFileUnreadable
        } else if has(["heartbeat timeout", "device went to sleep"]) {
            self = .slept
        } else if has(["disk image", "image not mounted", "imagenotmounted", "ddinotmounted", "ddidownload", "ddifilesmissing"]) {
            self = .diskImage
        } else if has(["debugserver connection"]) {
            self = .debugserver
        } else {
            return nil
        }
    }

    var advice: JITAdvice {
        switch self {
        case .developerModeOff:
            return JITAdvice(message: "Developer Mode is off. Turn it on in Settings › Privacy & Security › Developer Mode, "
                                    + "let the device restart and confirm, then try again.", actions: [])
        case .locked:
            return JITAdvice(message: "This device was locked. Unlock it, keep Henge open, then try again.", actions: [])
        case .trustPending:
            return JITAdvice(message: "This device is waiting for you to trust the pairing. Answer the prompt, "
                                    + "then try again.", actions: [])
        case .pairingRejected:
            return JITAdvice(message: "This device no longer accepts Henge's pairing. That happens after pairing "
                                    + "another tool, erasing the device, or using a pairing file made for a different device. "
                                    + "Pair again.", actions: [.pairAgain])
        case .pairingFileUnreadable:
            return JITAdvice(message: "Henge's pairing file could not be read. Pair again, or import a fresh pairing file.",
                             actions: [.pairAgain])
        case .diskImage:
            return JITAdvice(message: "The Developer Disk Image could not be downloaded or mounted. Check that this device "
                                    + "is online, tap Reset Developer Disk Image, then Check setup again.", actions: [])
        case .slept:
            return JITAdvice(message: "The connection dropped when this device slept or locked. Keep the screen on with "
                                    + "Henge open, then try again.", actions: [.connectLocalDevVPN])
        case .debugserver:
            return JITAdvice(message: "This device's debugging service did not accept the helper. This usually means the "
                                    + "Developer Disk Image is not mounted: tap Check setup, then Enable JIT.", actions: [])
        }
    }
}

enum JITNetworkAdvice {
    static func advice(forHelperMessage helperMessage: String, situation: NetworkSituation) -> JITAdvice? {
        if let device = JITDeviceProblem(helperMessage: helperMessage) { return device.advice }
        guard let problem = JITConnectionProblem(helperMessage: helperMessage) else { return nil }
        if problem == .pairing {
            return JITAdvice(
                message: "This device closed the connection, which usually means it no longer accepts "
                       + "Henge's pairing. Pair again, and check that LocalDevVPN is connected.",
                actions: [.pairAgain, .connectLocalDevVPN])
        }
        guard situation == .cellularOnly else {
            return JITAdvice(message: "Henge couldn't reach this device. Connect LocalDevVPN, then try again.",
                             actions: [.connectLocalDevVPN])
        }
        return JITAdvice(
            message: "LocalDevVPN can show Connected while iOS still sends Henge's connection over cellular. "
                   + "Turn Cellular Data off in Control Center, wait 2 seconds, then turn it back on. "
                   + "Or join any Wi-Fi once; a hotspot works. "
                   + "Keep LocalDevVPN connected, turn off other VPNs such as Tailscale, then try again.",
            actions: [.connectLocalDevVPN])
    }
}

enum JITRetryDecision: Equatable {
    case retry(after: TimeInterval)
    case giveUp
}

/// Whether to try the helper again by itself after it failed to connect.
///
/// On cellular, iOS tends to send the first connection to 10.7.0.1 out over the mobile network instead of through
/// LocalDevVPN, and later ones go through. So an unreachable error on cellular is retried: at most 2 retries (3
/// attempts in all), 4 seconds apart -- long enough for the routing to settle, short enough to feel like one try.
enum JITRetryPolicy {
    static let maxAttempts = 3

    /// Shown while waiting to try attempt `nextAttempt` (the first retry is attempt 2).
    static func statusText(nextAttempt: Int) -> String {
        "Retrying over LocalDevVPN (\(nextAttempt) of \(maxAttempts))…"
    }

    static func decision(situation: NetworkSituation, problem: JITConnectionProblem, attempt: Int) -> JITRetryDecision {
        guard situation == .cellularOnly, problem == .unreachable else { return .giveUp }
        return attempt < maxAttempts ? .retry(after: 4) : .giveUp
    }
}
