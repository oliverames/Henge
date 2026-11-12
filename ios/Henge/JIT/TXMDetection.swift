// SPDX-License-Identifier: GPL-2.0-or-later
import Darwin
import Foundation

/// Whether this device runs the Trusted Execution Monitor, read from the device itself.
///
/// With TXM only an attached debugger that answers Henge's trap requests can grant executable memory, so it decides
/// which JIT paths can work at all. The device tree says so directly: the boot loader lists the memory it carved out
/// for TXM under /chosen/memory-map, as a property named "TXM", and only on devices that run it. Apps may read that
/// node. The model table in HengeLog.expectsTXM stays as the answer when the device tree cannot be read.
enum TXMDetection {
    /// true or false when the device tree answered; nil when it could not be read.
    static let fromDeviceTree: Bool? = readDeviceTree()

    private typealias EntryFromPath = @convention(c) (mach_port_t, UnsafePointer<CChar>) -> UInt32
    private typealias CreateProperty = @convention(c) (UInt32, CFString, CFAllocator?, UInt32) -> Unmanaged<CFTypeRef>?
    private typealias Release = @convention(c) (UInt32) -> Int32

    private static func readDeviceTree() -> Bool? {
        // IOKit has no Swift module on iOS; its C functions are public and always present.
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let fromPath = dlsym(iokit, "IORegistryEntryFromPath"),
              let property = dlsym(iokit, "IORegistryEntryCreateCFProperty"),
              let release = dlsym(iokit, "IOObjectRelease") else { return nil }
        let entryFromPath = unsafeBitCast(fromPath, to: EntryFromPath.self)
        let createProperty = unsafeBitCast(property, to: CreateProperty.self)
        let objectRelease = unsafeBitCast(release, to: Release.self)

        // kIOMainPortDefault is MACH_PORT_NULL.
        let entry = entryFromPath(0, "IODeviceTree:/chosen/memory-map")
        guard entry != 0 else { return nil }
        defer { _ = objectRelease(entry) }
        // kIORegistryEntryPropertyKeysKey: the node's property names, without reading their values.
        guard let keys = createProperty(entry, "IORegistryEntryPropertyKeys" as CFString, nil, 0)?
                .takeRetainedValue() as? [String] else { return nil }
        return keys.contains("TXM")
    }
}
