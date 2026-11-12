import Foundation

@main
struct DiskGrowthTests {
    static func main() {
        let gb: Int64 = 1 << 30

        // A new 64 GB Mac is offered every size; a 128 GB one only the larger ones; a 256 GB one nothing.
        precondition(DiskGrowth.choices(currentBytes: 64 * gb) == [96, 128, 192, 256])
        precondition(DiskGrowth.choices(currentBytes: 128 * gb) == [192, 256])
        precondition(DiskGrowth.choices(currentBytes: 256 * gb).isEmpty)

        // A disk between two sizes (an imported one) is offered only what is bigger than it.
        precondition(DiskGrowth.choices(currentBytes: 100 * gb) == [128, 192, 256])

        // Allowed when stopped and larger.
        precondition(DiskGrowth.refusal(vmState: 0, currentBytes: 64 * gb, newGB: 128) == nil)
        precondition(DiskGrowth.refusal(vmState: 2, currentBytes: 64 * gb, newGB: 128) == nil)

        // Refused while the Mac is running, starting or stopping, or paused.
        for state: Int32 in [1, 3, 4] {
            precondition(DiskGrowth.refusal(vmState: state, currentBytes: 64 * gb, newGB: 128) != nil)
        }

        // Refused for the same size, a smaller one, or one that is not on the list.
        precondition(DiskGrowth.refusal(vmState: 2, currentBytes: 128 * gb, newGB: 128) != nil)
        precondition(DiskGrowth.refusal(vmState: 2, currentBytes: 128 * gb, newGB: 96) != nil)
        precondition(DiskGrowth.refusal(vmState: 2, currentBytes: 64 * gb, newGB: 1024) != nil)
        print("disk growth ok")
    }
}
