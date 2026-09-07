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

/// Detailed result of checking disk access for an individual ingest source path.
public struct SourcePathAccessResult: Identifiable, Hashable, Equatable, Sendable, Codable {
    public var id: String { slug.isEmpty ? rawPath : "\(slug):\(rawPath)" }
    public let slug: String
    public let rawPath: String
    public let resolvedPath: String
    public let exists: Bool
    public let isReadable: Bool
    public let isDirectory: Bool
    public let itemCount: Int?
    public let errorMessage: String?

    public init(
        slug: String,
        rawPath: String,
        resolvedPath: String,
        exists: Bool,
        isReadable: Bool,
        isDirectory: Bool,
        itemCount: Int?,
        errorMessage: String? = nil
    ) {
        self.slug = slug
        self.rawPath = rawPath
        self.resolvedPath = resolvedPath
        self.exists = exists
        self.isReadable = isReadable
        self.isDirectory = isDirectory
        self.itemCount = itemCount
        self.errorMessage = errorMessage
    }

    public var isAccessible: Bool {
        exists && isReadable && errorMessage == nil
    }

    public var statusDescription: String {
        if !exists {
            return "Path does not exist"
        }
        if !isReadable {
            return "Permission denied / not readable"
        }
        if let error = errorMessage {
            return "Error: \(error)"
        }
        if let count = itemCount {
            return "Accessible (\(count) \(count == 1 ? "item" : "items"))"
        }
        return "Accessible"
    }
}

/// Detailed result of a volume access verification test.
public struct VolumeAccessTestResult: Equatable, Sendable {
    public let isAccessible: Bool
    public let testedURL: URL
    public let rootItemsCount: Int
    public let accessibleSubpaths: [String]
    public let inaccessibleSubpaths: [String]
    public let sourcePathResults: [SourcePathAccessResult]
    public let message: String
    public let isSecurityScoped: Bool

    public init(
        isAccessible: Bool,
        testedURL: URL,
        rootItemsCount: Int,
        accessibleSubpaths: [String],
        inaccessibleSubpaths: [String],
        sourcePathResults: [SourcePathAccessResult] = [],
        message: String,
        isSecurityScoped: Bool
    ) {
        self.isAccessible = isAccessible
        self.testedURL = testedURL
        self.rootItemsCount = rootItemsCount
        self.accessibleSubpaths = accessibleSubpaths
        self.inaccessibleSubpaths = inaccessibleSubpaths
        self.sourcePathResults = sourcePathResults
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

    /// Runs a verification test against the root hard drive / volume and each registered ingest source path.
    @discardableResult
    public func testFullVolumeAccess(sourcePaths: [(slug: String, root: String)] = []) -> VolumeAccessTestResult {
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

        // Test each ingest source path
        var sourceResults: [SourcePathAccessResult] = []
        for source in sourcePaths {
            let rawPath = source.root
            let slug = source.slug
            let resolvedPath = (rawPath as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            let exists = fileSystem.fileExists(atPath: resolvedPath, isDirectory: &isDir)
            let isReadable = fileSystem.isReadableFile(atPath: resolvedPath)
            var count: Int? = nil
            var errorMsg: String? = nil

            if exists && isReadable {
                if isDir.boolValue {
                    do {
                        let contents = try fileSystem.contentsOfDirectory(at: URL(fileURLWithPath: resolvedPath))
                        count = contents.count
                    } catch {
                        errorMsg = error.localizedDescription
                    }
                }
            } else if !exists {
                errorMsg = "Path does not exist"
            } else if !isReadable {
                errorMsg = "Permission denied / not readable"
            }

            sourceResults.append(SourcePathAccessResult(
                slug: slug,
                rawPath: rawPath,
                resolvedPath: resolvedPath,
                exists: exists,
                isReadable: isReadable,
                isDirectory: isDir.boolValue,
                itemCount: count,
                errorMessage: errorMsg
            ))
        }

        let rootVolumeAccessible: Bool
        if isRootVolume {
            rootVolumeAccessible = rootAccessible && (!accessibleSubpaths.isEmpty || !rootItems.isEmpty)
        } else {
            rootVolumeAccessible = rootAccessible && fileSystem.isReadableFile(atPath: targetURL.path)
        }

        let allSourcesAccessible = sourceResults.isEmpty || sourceResults.allSatisfy(\.isAccessible)
        let isOverallAccessible = rootVolumeAccessible && allSourcesAccessible

        let message: String
        if !sourceResults.isEmpty {
            let totalCount = sourceResults.count
            if isOverallAccessible {
                message = "Volume & source access verified at '\(targetURL.path)'. All \(totalCount) ingest source \(totalCount == 1 ? "path is" : "paths are") accessible."
            } else if !rootVolumeAccessible {
                message = "Root volume access test failed for '\(targetURL.path)'."
            } else {
                let inaccessible = sourceResults.filter { !$0.isAccessible }
                let details = inaccessible.map { "\($0.slug.isEmpty ? $0.rawPath : $0.slug) (\($0.statusDescription))" }.joined(separator: ", ")
                message = "Volume access granted at '\(targetURL.path)', but \(inaccessible.count) of \(totalCount) ingest source \(totalCount == 1 ? "path is" : "paths are") inaccessible: \(details)"
            }
        } else {
            if rootVolumeAccessible {
                if !accessibleSubpaths.isEmpty {
                    message = "Full volume access verified at '\(targetURL.path)'. Found \(rootItems.count) root items, and \(accessibleSubpaths.count) common directories are readable."
                } else {
                    message = "Volume access verified at '\(targetURL.path)'. Found \(rootItems.count) items."
                }
            } else {
                message = "Volume access test failed for '\(targetURL.path)'. The directory could not be enumerated or read."
            }
        }

        let result = VolumeAccessTestResult(
            isAccessible: isOverallAccessible,
            testedURL: targetURL,
            rootItemsCount: rootItems.count,
            accessibleSubpaths: accessibleSubpaths,
            inaccessibleSubpaths: inaccessibleSubpaths,
            sourcePathResults: sourceResults,
            message: message,
            isSecurityScoped: isSecurityScoped
        )

        self.lastTestResult = result
        if rootVolumeAccessible {
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
