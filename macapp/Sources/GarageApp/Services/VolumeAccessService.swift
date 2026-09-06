import Foundation
import AppKit

/// Represents the status of volume access inside the sandbox.
public enum VolumeAccessStatus: Equatable {
    case notConfigured
    case accessGranted(url: URL, isSecurityScoped: Bool)
    case accessDenied(reason: String)
    case staleBookmark(url: URL)

    public var isGranted: Bool {
        if case .accessGranted = self {
            return true
        }
        return false
    }

    public var displayDescription: String {
        switch self {
        case .notConfigured:
            return "Not configured (no root volume selected)"
        case .accessGranted(let url, let isSecurityScoped):
            let scopeLabel = isSecurityScoped ? "security-scoped" : "direct"
            return "Granted: \(url.path) (\(scopeLabel))"
        case .accessDenied(let reason):
            return "Denied: \(reason)"
        case .staleBookmark(let url):
            return "Stale bookmark: \(url.path) (needs re-grant)"
        }
    }
}

/// Detailed result of a volume access verification test.
public struct VolumeAccessTestResult: Equatable {
    public let isAccessible: Bool
    public let testedURL: URL
    public let rootItemsCount: Int
    public let accessibleSubpaths: [String]
    public let inaccessibleSubpaths: [String]
    public let message: String
    public let isSecurityScoped: Bool

    public init(
        isAccessible: Bool,
        testedURL: URL,
        rootItemsCount: Int,
        accessibleSubpaths: [String],
        inaccessibleSubpaths: [String],
        message: String,
        isSecurityScoped: Bool
    ) {
        self.isAccessible = isAccessible
        self.testedURL = testedURL
        self.rootItemsCount = rootItemsCount
        self.accessibleSubpaths = accessibleSubpaths
        self.inaccessibleSubpaths = inaccessibleSubpaths
        self.message = message
        self.isSecurityScoped = isSecurityScoped
    }
}

/// Protocol defining bookmark storage for testing and persistence.
public protocol VolumeBookmarkStoring {
    func loadBookmarkData() -> Data?
    func saveBookmarkData(_ data: Data, path: String)
    func loadBookmarkPath() -> String?
    func clearBookmark()
}

/// Standard UserDefaults-backed bookmark store.
public final class UserDefaultsVolumeBookmarkStore: VolumeBookmarkStoring {
    private let defaults: UserDefaults
    private let bookmarkKey: String
    private let pathKey: String

    public init(
        defaults: UserDefaults = .standard,
        bookmarkKey: String = "garage.rootVolumeBookmark",
        pathKey: String = "garage.rootVolumePath"
    ) {
        self.defaults = defaults
        self.bookmarkKey = bookmarkKey
        self.pathKey = pathKey
    }

    public func loadBookmarkData() -> Data? {
        defaults.data(forKey: bookmarkKey)
    }

    public func saveBookmarkData(_ data: Data, path: String) {
        defaults.set(data, forKey: bookmarkKey)
        defaults.set(path, forKey: pathKey)
    }

    public func loadBookmarkPath() -> String? {
        defaults.string(forKey: pathKey)
    }

    public func clearBookmark() {
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: pathKey)
    }
}

/// Protocol for filesystem operations to enable testing.
public protocol FileSystemAccessing {
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool
    func isReadableFile(atPath path: String) -> Bool
}

/// Standard FileManager-backed filesystem accessor.
public final class DefaultFileSystemAccessor: FileSystemAccessing {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    }

    public func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        fileManager.fileExists(atPath: path, isDirectory: isDirectory)
    }

    public func isReadableFile(atPath path: String) -> Bool {
        fileManager.isReadableFile(atPath: path)
    }
}

/// Service managing full volume access, security-scoped bookmark lifecycle, and verification.
@MainActor
public final class VolumeAccessService: ObservableObject {
    @Published public private(set) var status: VolumeAccessStatus = .notConfigured
    @Published public private(set) var activeRootURL: URL?
    @Published public private(set) var lastTestResult: VolumeAccessTestResult?

    private let bookmarkStore: VolumeBookmarkStoring
    private let fileSystem: FileSystemAccessing
    private var isAccessingSecurityScope = false

    public init(
        bookmarkStore: VolumeBookmarkStoring = UserDefaultsVolumeBookmarkStore(),
        fileSystem: FileSystemAccessing = DefaultFileSystemAccessor()
    ) {
        self.bookmarkStore = bookmarkStore
        self.fileSystem = fileSystem
    }

    deinit {
        MainActor.assumeIsolated {
            stopAccessingCurrentScope()
        }
    }

    /// Automatically restores persisted bookmark and validates access.
    @discardableResult
    public func restoreAndVerifyAccess() -> Bool {
        guard let bookmarkData = bookmarkStore.loadBookmarkData() else {
            // Check if root is directly accessible (e.g. Non-sandboxed development environment)
            let rootURL = URL(fileURLWithPath: "/")
            if fileSystem.isReadableFile(atPath: rootURL.path) {
                activeRootURL = rootURL
                status = .accessGranted(url: rootURL, isSecurityScoped: false)
                return true
            }
            status = .notConfigured
            return false
        }

        var isStale = false
        do {
            #if os(macOS)
            let resolvedURL: URL
            do {
                resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            } catch {
                resolvedURL = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
            }
            #else
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            #endif

            stopAccessingCurrentScope()

            let started = resolvedURL.startAccessingSecurityScopedResource()
            if started {
                isAccessingSecurityScope = true
                activeRootURL = resolvedURL

                if isStale {
                    status = .staleBookmark(url: resolvedURL)
                    // Attempt to refresh stale bookmark
                    _ = try? persistSecurityScopedBookmark(for: resolvedURL)
                } else {
                    status = .accessGranted(url: resolvedURL, isSecurityScoped: true)
                }
                return true
            } else if fileSystem.isReadableFile(atPath: resolvedURL.path) {
                activeRootURL = resolvedURL
                status = .accessGranted(url: resolvedURL, isSecurityScoped: false)
                return true
            } else {
                status = .accessDenied(reason: "Failed to start accessing security-scoped resource for \(resolvedURL.path)")
                return false
            }
        } catch {
            status = .accessDenied(reason: "Failed to resolve stored bookmark: \(error.localizedDescription)")
            return false
        }
    }

    /// Displays an NSOpenPanel configured to assist the user in choosing the root hard-drive.
    public func promptForRootVolumeSelection() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Select Root Hard Drive"
        panel.message = "To grant Garage access to index files across your system, select your root hard drive (e.g. Macintosh HD or root '/') and click Grant Access."
        panel.prompt = "Grant Access"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = false
        panel.directoryURL = URL(fileURLWithPath: "/")

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }

        do {
            try grantAccess(for: selectedURL)
            return selectedURL
        } catch {
            status = .accessDenied(reason: "Failed to create security-scoped bookmark: \(error.localizedDescription)")
            return nil
        }
    }

    /// Grants access for a user-selected URL and saves the security-scoped bookmark.
    public func grantAccess(for url: URL) throws {
        stopAccessingCurrentScope()

        let started = url.startAccessingSecurityScopedResource()
        if started {
            isAccessingSecurityScope = true
        }

        activeRootURL = url
        try persistSecurityScopedBookmark(for: url)
        status = .accessGranted(url: url, isSecurityScoped: started)

        _ = testFullVolumeAccess()
    }

    /// Revokes stored bookmark and terminates security-scoped access.
    public func revokeAccess() {
        stopAccessingCurrentScope()
        bookmarkStore.clearBookmark()
        activeRootURL = nil
        lastTestResult = nil
        status = .notConfigured
    }

    /// Runs a verification test against the root hard drive / volume to verify full volume read access.
    @discardableResult
    public func testFullVolumeAccess() -> VolumeAccessTestResult {
        let targetURL = activeRootURL ?? URL(fileURLWithPath: "/")
        var isSecurityScoped = false

        if isAccessingSecurityScope {
            isSecurityScoped = true
        }

        var rootItems: [URL] = []
        var rootAccessible = false
        do {
            rootItems = try fileSystem.contentsOfDirectory(at: targetURL)
            rootAccessible = true
        } catch {
            rootAccessible = false
        }

        let isRootVolume = targetURL.path == "/" || targetURL.path.hasPrefix("/Volumes")
        let commonSubpaths = ["System", "Library", "Applications", "Users", "Volumes"]
        var accessibleSubpaths: [String] = []
        var inaccessibleSubpaths: [String] = []

        if isRootVolume {
            for subpath in commonSubpaths {
                let subURL = targetURL.path == "/" ? URL(fileURLWithPath: "/\(subpath)") : targetURL.appendingPathComponent(subpath)
                if fileSystem.isReadableFile(atPath: subURL.path) {
                    accessibleSubpaths.append("/\(subpath)")
                } else {
                    inaccessibleSubpaths.append("/\(subpath)")
                }
            }
        }

        let isAccessible: Bool
        if isRootVolume {
            isAccessible = rootAccessible && (!accessibleSubpaths.isEmpty || !rootItems.isEmpty)
        } else {
            isAccessible = rootAccessible && fileSystem.isReadableFile(atPath: targetURL.path)
        }

        let message: String
        if isAccessible {
            if !accessibleSubpaths.isEmpty {
                message = "Full volume access verified at '\(targetURL.path)'. Found \(rootItems.count) root items, and \(accessibleSubpaths.count) common directories are readable."
            } else {
                message = "Volume access verified at '\(targetURL.path)'. Found \(rootItems.count) items."
            }
        } else {
            message = "Volume access test failed for '\(targetURL.path)'. The directory could not be enumerated or read."
        }

        let result = VolumeAccessTestResult(
            isAccessible: isAccessible,
            testedURL: targetURL,
            rootItemsCount: rootItems.count,
            accessibleSubpaths: accessibleSubpaths,
            inaccessibleSubpaths: inaccessibleSubpaths,
            message: message,
            isSecurityScoped: isSecurityScoped
        )

        self.lastTestResult = result
        if isAccessible {
            self.status = .accessGranted(url: targetURL, isSecurityScoped: isSecurityScoped)
        } else {
            self.status = .accessDenied(reason: message)
        }

        return result
    }

    private func persistSecurityScopedBookmark(for url: URL) throws {
        #if os(macOS)
        let bookmarkData: Data
        do {
            bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            // Fallback for non-sandboxed or un-entitled environments (such as unit test bundles)
            bookmarkData = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
        #else
        let bookmarkData = try url.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #endif
        bookmarkStore.saveBookmarkData(bookmarkData, path: url.path)
    }

    private func stopAccessingCurrentScope() {
        if isAccessingSecurityScope, let active = activeRootURL {
            active.stopAccessingSecurityScopedResource()
            isAccessingSecurityScope = false
        }
    }
}
