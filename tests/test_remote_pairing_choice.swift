import Foundation

@main
struct RemotePairingChoiceTests {
    static func main() {
        let wait = RemotePairingChoice.loopbackWait

        // Situation: no results yet.
        precondition(RemotePairingChoice.choose(interfaces: [], waited: 0) == .none)
        precondition(RemotePairingChoice.choose(interfaces: [], waited: 100) == .none)

        // Situation: only the phone's own service, on loopback.
        precondition(RemotePairingChoice.choose(interfaces: [["lo0"]], waited: 0) == .loopback(0))

        // Situation: an Apple TV on Wi-Fi answers first. Hold out for loopback instead of taking it.
        let appleTVFirst = [["en0"]]
        precondition(RemotePairingChoice.choose(interfaces: appleTVFirst, waited: 0) == .wait)
        precondition(RemotePairingChoice.choose(interfaces: appleTVFirst, waited: wait - 0.1) == .wait)

        // Situation: the loopback result arrives after the Apple TV's, and wins.
        let loopbackSecond = [["en0"], ["lo0"]]
        precondition(RemotePairingChoice.choose(interfaces: loopbackSecond, waited: 0.2) == .loopback(1))
        precondition(RemotePairingChoice.choose(interfaces: loopbackSecond, waited: wait + 1) == .loopback(1))

        // Situation: a result seen on several interfaces counts as loopback if one of them is.
        precondition(RemotePairingChoice.choose(interfaces: [["en0"], ["en0", "lo0"]], waited: 0) == .loopback(1))

        // Situation: nothing but other devices. After the wait, fall back to the first.
        let others = [["en0"], ["awdl0"]]
        precondition(RemotePairingChoice.choose(interfaces: others, waited: wait) == .fallback(0))
        precondition(RemotePairingChoice.choose(interfaces: others, waited: wait + 2) == .fallback(0))

        // Interface names: lo0 and friends are loopback, Wi-Fi and the VPN's utun are not.
        precondition(RemotePairingChoice.isLoopback("lo0"))
        precondition(!RemotePairingChoice.isLoopback("en0"))
        precondition(!RemotePairingChoice.isLoopback("utun4"))

        print("test_remote_pairing_choice: all passed")
    }
}
