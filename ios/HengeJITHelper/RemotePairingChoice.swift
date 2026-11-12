// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// Which `_remotepairing._tcp` result to use. Compiled into both Henge and its JIT helper.
///
/// Every device on the Wi-Fi can advertise that service (an Apple TV did, on port 49152), and the first
/// result to arrive is not always this phone's. The phone's own service comes in on the loopback
/// interface, so a loopback result wins; a result on another interface is only used if none shows up in time.
/// StikDebug makes the same choice (https://github.com/StikDebug/StikDebug, JITEnableContext.swift).
enum RemotePairingChoice {
    /// How long after the first result to hold out for a loopback one. The phone's own advertisement is
    /// answered locally, so it normally lands within moments of the first result; the helper gives up
    /// after 4 s and Henge's own lookup after 3 s, so this leaves room to connect to whatever is chosen.
    static let loopbackWait: TimeInterval = 1.5

    enum Decision: Equatable {
        case none
        case wait
        case loopback(Int)
        case fallback(Int)
    }

    /// `interfaces` holds, for each result so far in arrival order, the names of the interfaces it came in on.
    /// `waited` is the time since the first result arrived.
    static func choose(interfaces: [[String]], waited: TimeInterval) -> Decision {
        if interfaces.isEmpty { return .none }
        if let index = interfaces.firstIndex(where: { $0.contains(where: isLoopback) }) {
            return .loopback(index)
        }
        return waited >= loopbackWait ? .fallback(0) : .wait
    }

    static func isLoopback(_ interfaceName: String) -> Bool {
        interfaceName.hasPrefix("lo")
    }
}
