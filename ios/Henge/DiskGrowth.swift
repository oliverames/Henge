import Foundation

/// Growing a stopped Mac's disk: which sizes are offered, and when it is refused. A disk only ever grows, and only
/// as far as the largest size listed here.
enum DiskGrowth {
    static let sizesGB = [96, 128, 192, 256]

    /// What macOS has to do afterwards: it keeps using the old size until its APFS container is grown inside it.
    /// Source: Tart's macOS disk resize notes, https://tart.run/faq/ (it runs the same two commands from Recovery).
    static let guestSteps = "diskutil repairDisk disk0, then diskutil apfs resizeContainer disk0s2 0"

    static func choices(currentBytes: Int64) -> [Int] { sizesGB.filter { Int64($0) << 30 > currentBytes } }

    /// Why a disk cannot be grown now, or nil. `vmState` is henge_vm_state(): 1 running, 3 starting or stopping, 4 paused.
    static func refusal(vmState: Int32, currentBytes: Int64, newGB: Int) -> String? {
        if [1, 3, 4].contains(vmState) { return "Stop the Mac first." }
        if !choices(currentBytes: currentBytes).contains(newGB) { return "The disk can only grow to a larger size." }
        return nil
    }
}
