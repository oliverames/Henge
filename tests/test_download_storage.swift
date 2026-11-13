import Foundation

enum HengeLog {
    static func log(_ category: String, _ message: String) {}
}

enum Machines {
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("HengeTestRoot", isDirectory: true)
    }
}

struct MacOSRelease: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    let bytes: Int64
    let note: String
    var macBytes: Int64 = 24 << 30

    static let all: [MacOSRelease] = [
        MacOSRelease(id: "22G120", name: "macOS Ventura 13.6",
                     url: URL(string: "https://updates.cdn-apple.com/2023FallFCS/fullrestores/042-55833/C0830847-A2F8-458F-B680-967991820931/UniversalMac_13.6_22G120_Restore.ipsw")!,
                     bytes: 12_297 << 20, note: "Ventura", macBytes: 23 << 30),
        MacOSRelease(id: "23G93", name: "macOS Sonoma 14.6.1",
                     url: URL(string: "https://updates.cdn-apple.com/2024SummerFCS/fullrestores/062-52859/932E0A8F-6644-4759-82DA-F8FA8DEA806A/UniversalMac_14.6.1_23G93_Restore.ipsw")!,
                     bytes: 14_106 << 20, note: "Sonoma", macBytes: 26 << 30),
        MacOSRelease(id: "24G90", name: "macOS Sequoia 15.6.1",
                     url: URL(string: "https://updates.cdn-apple.com/2025SummerFCS/fullrestores/093-10809/CFD6DD38-DAF0-40DA-854F-31AAD1294C6F/UniversalMac_15.6.1_24G90_Restore.ipsw")!,
                     bytes: 16_035 << 20, note: "Sequoia"),
    ]

    static let recommended = all.first { $0.id == "24G90" } ?? all[0]
}

enum TestInstaller {
    static var imageDirectory: URL { DownloadStorage.currentDirectory }

    static func imagePath(_ r: MacOSRelease) -> URL {
        if let custom = DownloadStorage.currentIPSW, isMatchingIPSW(custom, release: r) {
            return custom
        }
        let dir = imageDirectory
        let standard = dir.appendingPathComponent("\(r.id).ipsw")
        if FileManager.default.fileExists(atPath: standard.path) {
            return standard
        }
        let appleFile = dir.appendingPathComponent(r.url.lastPathComponent)
        if FileManager.default.fileExists(atPath: appleFile.path) {
            return appleFile
        }
        return standard
    }

    static func isMatchingIPSW(_ file: URL, release r: MacOSRelease) -> Bool {
        let name = file.lastPathComponent.lowercased()
        for other in MacOSRelease.all where other.id != r.id {
            if name.contains(other.id.lowercased()) { return false }
        }
        if name.contains(r.id.lowercased()) { return true }
        if r.id == "24G90" && (name.contains("15.6") || name.contains("sequoia")) { return true }
        if r.id == "23G93" && (name.contains("14.6") || name.contains("sonoma")) { return true }
        if r.id == "22G120" && (name.contains("13.6") || name.contains("ventura")) { return true }
        return r == MacOSRelease.recommended
    }

    static func imageSize(_ r: MacOSRelease) -> Int64? {
        let values = try? imagePath(r).resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize, Int64(size) > r.bytes / 2 else { return nil }
        return Int64(size)
    }

    static func haveImage(_ r: MacOSRelease) -> Bool { imageSize(r) != nil }

    static func downloadNeeded(_ r: MacOSRelease) -> Int64 {
        haveImage(r) ? 0 : r.bytes
    }

    static func internalSpaceNeeded(_ r: MacOSRelease) -> Int64 {
        if DownloadStorage.isExternal {
            return r.macBytes
        }
        return downloadNeeded(r) + r.macBytes
    }
}

@main
struct DownloadStorageTests {
    @MainActor
    static func main() {
        let storage = DownloadStorage.shared
        storage.resetToDefault()

        // 1. Initial State
        precondition(!storage.isExternal, "storage should initially be internal")
        precondition(DownloadStorage.currentDirectory == DownloadStorage.defaultDirectory, "default directory should be used")
        precondition(storage.locationDisplayName == "Internal Storage", "display name should be Internal Storage")

        // 2. Set Custom External Directory
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("HengeTest-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let success = storage.setCustomDirectory(tempDir)
        precondition(success, "setting custom directory should succeed")
        precondition(storage.isExternal, "storage should now be external")
        precondition(DownloadStorage.currentDirectory == tempDir, "current directory should match custom directory")
        precondition(storage.isReachable, "custom directory should be reachable")
        precondition(storage.locationDisplayName.contains(tempDir.lastPathComponent), "display name should reflect folder")

        // 3. IPSW Matching
        let sequoia = MacOSRelease.all.first { $0.id == "24G90" }!
        let sonoma = MacOSRelease.all.first { $0.id == "23G93" }!

        let sequoiaFile = URL(fileURLWithPath: "/tmp/UniversalMac_15.6.1_24G90_Restore.ipsw")
        let sonomaFile = URL(fileURLWithPath: "/tmp/UniversalMac_14.6.1_23G93_Restore.ipsw")

        precondition(TestInstaller.isMatchingIPSW(sequoiaFile, release: sequoia), "sequoia IPSW should match sequoia release")
        precondition(!TestInstaller.isMatchingIPSW(sequoiaFile, release: sonoma), "sequoia IPSW should not match sonoma release")
        precondition(TestInstaller.isMatchingIPSW(sonomaFile, release: sonoma), "sonoma IPSW should match sonoma release")

        // 4. Image Path & Download Needed
        let emptyPath = TestInstaller.imagePath(sequoia)
        precondition(emptyPath == tempDir.appendingPathComponent("\(sequoia.id).ipsw"), "empty path should default to id.ipsw")
        precondition(!TestInstaller.haveImage(sequoia), "should not have image before writing")
        precondition(TestInstaller.downloadNeeded(sequoia) == sequoia.bytes, "download needed should equal image bytes")

        // Simulate an Apple CDN IPSW on external storage (sparse file so no disk space allocated)
        let mockIPSW = tempDir.appendingPathComponent(sequoia.url.lastPathComponent)
        FileManager.default.createFile(atPath: mockIPSW.path, contents: nil)
        let fh = try! FileHandle(forWritingTo: mockIPSW)
        try! fh.truncate(atOffset: UInt64(sequoia.bytes / 2 + 1024))
        try! fh.close()

        let foundPath = TestInstaller.imagePath(sequoia)
        precondition(foundPath == mockIPSW, "should detect Apple CDN filename in external directory")
        precondition(TestInstaller.haveImage(sequoia), "haveImage should be true when IPSW is present")
        precondition(TestInstaller.downloadNeeded(sequoia) == 0, "download needed should be 0 when image is present")

        // 5. Space Calculation (External vs Internal)
        // With external storage active, internal space needed is only macBytes (24 GB)
        precondition(TestInstaller.internalSpaceNeeded(sequoia) == sequoia.macBytes, "internal space needed when external should only be macBytes")

        // Remove mock IPSW to test when download is still needed
        try? FileManager.default.removeItem(at: mockIPSW)
        precondition(TestInstaller.downloadNeeded(sequoia) == sequoia.bytes)
        precondition(TestInstaller.internalSpaceNeeded(sequoia) == sequoia.macBytes, "when external, internal space is STILL only macBytes even if download needed")

        // Switch to internal storage
        storage.resetToDefault()
        precondition(!storage.isExternal)
        precondition(TestInstaller.internalSpaceNeeded(sequoia) == sequoia.macBytes + sequoia.bytes, "when internal, internal space must include download + macBytes")

        // 6. Custom IPSW Selection
        let customFile = tempDir.appendingPathComponent("Custom_Restore.ipsw")
        FileManager.default.createFile(atPath: customFile.path, contents: nil)
        let fh2 = try! FileHandle(forWritingTo: customFile)
        try! fh2.truncate(atOffset: UInt64(sequoia.bytes / 2 + 1024))
        try! fh2.close()
        let ipswSuccess = storage.setCustomIPSW(customFile)
        precondition(ipswSuccess, "setting custom IPSW should succeed")
        precondition(DownloadStorage.currentIPSW == customFile, "current IPSW should match custom file")
        precondition(TestInstaller.imagePath(MacOSRelease.recommended) == customFile, "imagePath should return custom IPSW")

        storage.clearCustomIPSW()
        precondition(DownloadStorage.currentIPSW == nil, "current IPSW should be cleared")

        print("Download storage: all checks passed")
    }
}
