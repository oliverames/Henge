import Foundation
import UniformTypeIdentifiers

private final class StorageState: @unchecked Sendable {
    let lock = NSLock()
    var activeDirectory: URL?
    var activeIPSW: URL?
    var isExternal: Bool = false
}

private let storageState = StorageState()

/// Manages the download and storage location for macOS restore images (.ipsw),
/// allowing users to download to and install from external drives (USB-C flash drives, SSDs, SD cards).
@MainActor
final class DownloadStorage: ObservableObject {
    static let shared = DownloadStorage()

    private let bookmarkKey = "henge.downloadStorageBookmark"
    private let nameKey = "henge.downloadStorageName"

    @Published private(set) var customDirectoryURL: URL?
    @Published private(set) var customDirectoryName: String?
    @Published private(set) var isExternal: Bool = false
    @Published private(set) var isReachable: Bool = true

    @Published private(set) var customIPSWURL: URL?
    @Published private(set) var customIPSWName: String?

    private var accessingCustomFolder = false
    private var accessingCustomIPSW = false

    private init() {
        restoreBookmark()
    }

    // MARK: Directories

    nonisolated static var defaultDirectory: URL {
        Machines.root.appendingPathComponent("Restore images", isDirectory: true)
    }

    nonisolated static var isExternal: Bool {
        storageState.lock.lock()
        defer { storageState.lock.unlock() }
        return storageState.isExternal
    }

    nonisolated static var currentDirectory: URL {
        storageState.lock.lock()
        defer { storageState.lock.unlock() }
        return storageState.activeDirectory ?? defaultDirectory
    }

    nonisolated static var currentIPSW: URL? {
        storageState.lock.lock()
        defer { storageState.lock.unlock() }
        return storageState.activeIPSW
    }

    var locationDisplayName: String {
        if isExternal {
            let name = customDirectoryName ?? "External Storage"
            return "External: \(name)"
        }
        return "Internal Storage"
    }

    // MARK: Free Space

    nonisolated static func availableSpace(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        if let available = values?.volumeAvailableCapacity, available > 0 {
            return Int64(available)
        }
        return nil
    }

    var internalAvailableSpace: Int64? {
        Self.availableSpace(at: URL(fileURLWithPath: NSHomeDirectory()))
    }

    var externalAvailableSpace: Int64? {
        guard isExternal, let url = customDirectoryURL, isReachable else { return nil }
        return Self.availableSpace(at: url)
    }

    var availableSpace: Int64? {
        isExternal ? externalAvailableSpace : internalAvailableSpace
    }

    // MARK: Directory Configuration

    func setCustomDirectory(_ url: URL) -> Bool {
        stopAccessingCustomFolder()

        guard url.startAccessingSecurityScopedResource() else {
            HengeLog.log("storage", "Cannot access external folder: \(url.path)")
            return false
        }
        accessingCustomFolder = true

        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
            let displayName = url.lastPathComponent.isEmpty ? "External Storage" : url.lastPathComponent
            UserDefaults.standard.set(displayName, forKey: nameKey)

            storageState.lock.lock()
            storageState.activeDirectory = url
            storageState.isExternal = true
            storageState.lock.unlock()

            customDirectoryURL = url
            customDirectoryName = displayName
            isExternal = true
            isReachable = true

            HengeLog.log("storage", "External download directory set to: \(displayName) (\(url.path))")
            return true
        } catch {
            HengeLog.log("storage", "Failed to create security-scoped bookmark: \(error.localizedDescription)")
            stopAccessingCustomFolder()
            return false
        }
    }

    func resetToDefault() {
        stopAccessingCustomFolder()
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: nameKey)

        storageState.lock.lock()
        storageState.activeDirectory = nil
        storageState.isExternal = false
        storageState.lock.unlock()

        customDirectoryURL = nil
        customDirectoryName = nil
        isExternal = false
        isReachable = true

        HengeLog.log("storage", "Download storage reset to internal storage")
    }

    // MARK: Custom IPSW Configuration

    func setCustomIPSW(_ url: URL) -> Bool {
        stopAccessingCustomIPSW()

        guard url.startAccessingSecurityScopedResource() else {
            HengeLog.log("storage", "Cannot access IPSW file: \(url.path)")
            return false
        }
        accessingCustomIPSW = true

        storageState.lock.lock()
        storageState.activeIPSW = url
        storageState.lock.unlock()

        customIPSWURL = url
        customIPSWName = url.lastPathComponent
        HengeLog.log("storage", "Custom IPSW selected: \(url.lastPathComponent)")
        return true
    }

    func clearCustomIPSW() {
        stopAccessingCustomIPSW()

        storageState.lock.lock()
        storageState.activeIPSW = nil
        storageState.lock.unlock()

        customIPSWURL = nil
        customIPSWName = nil
    }

    // MARK: Security-Scoped Lifecycles

    private func restoreBookmark() {
        guard let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) else { return }
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
            guard url.startAccessingSecurityScopedResource() else {
                HengeLog.log("storage", "Could not access restored bookmark: \(url.path)")
                isExternal = true
                isReachable = false
                customDirectoryName = UserDefaults.standard.string(forKey: nameKey) ?? "External Storage"
                return
            }
            accessingCustomFolder = true

            let name = UserDefaults.standard.string(forKey: nameKey) ?? (url.lastPathComponent.isEmpty ? "External Storage" : url.lastPathComponent)
            var isDir: ObjCBool = false
            let reachable = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue

            storageState.lock.lock()
            storageState.activeDirectory = reachable ? url : nil
            storageState.isExternal = true
            storageState.lock.unlock()

            customDirectoryURL = url
            customDirectoryName = name
            isExternal = true
            isReachable = reachable

            if isStale {
                if let refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
                }
            }
            HengeLog.log("storage", "Restored external download directory: \(name) (\(url.path)), reachable: \(reachable)")
        } catch {
            HengeLog.log("storage", "Failed to resolve external download directory bookmark: \(error.localizedDescription)")
            resetToDefault()
        }
    }

    func checkReachability() {
        guard isExternal, let url = customDirectoryURL else { return }
        var isDir: ObjCBool = false
        let reachable = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        if reachable != isReachable {
            isReachable = reachable
            storageState.lock.lock()
            storageState.activeDirectory = reachable ? url : nil
            storageState.lock.unlock()
        }
    }

    private func stopAccessingCustomFolder() {
        if accessingCustomFolder, let url = customDirectoryURL {
            url.stopAccessingSecurityScopedResource()
            accessingCustomFolder = false
        }
    }

    private func stopAccessingCustomIPSW() {
        if accessingCustomIPSW, let url = customIPSWURL {
            url.stopAccessingSecurityScopedResource()
            accessingCustomIPSW = false
        }
    }
}
