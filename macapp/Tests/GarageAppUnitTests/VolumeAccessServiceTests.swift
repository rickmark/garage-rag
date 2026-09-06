import XCTest
import AppKit
@testable import GarageApp

final class MockVolumeBookmarkStore: VolumeBookmarkStoring {
    var storedData: Data?
    var storedPath: String?

    func loadBookmarkData() -> Data? {
        storedData
    }

    func saveBookmarkData(_ data: Data, path: String) {
        storedData = data
        storedPath = path
    }

    func loadBookmarkPath() -> String? {
        storedPath
    }

    func clearBookmark() {
        storedData = nil
        storedPath = nil
    }
}

final class MockFileSystemAccessor: FileSystemAccessing {
    var directoryContents: [URL] = []
    var shouldThrowOnContents = false
    var readablePaths: Set<String> = []

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        if shouldThrowOnContents {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: nil)
        }
        return directoryContents
    }

    func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        isDirectory?.pointee = true
        return true
    }

    func isReadableFile(atPath path: String) -> Bool {
        readablePaths.contains(path)
    }
}

@MainActor
final class VolumeAccessServiceTests: XCTestCase {

    func testInitialStateNotConfiguredWhenUnreadable() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        mockFS.readablePaths = [] // root not readable

        let service = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        XCTAssertEqual(service.status, .notConfigured)
        XCTAssertFalse(service.status.isGranted)
        XCTAssertNil(service.activeRootURL)
        XCTAssertNil(service.lastTestResult)
    }

    func testDirectAccessFallbackWhenRootReadable() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        mockFS.readablePaths = ["/"]

        let service = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        let restored = service.restoreAndVerifyAccess()

        XCTAssertTrue(restored)
        XCTAssertTrue(service.status.isGranted)
        XCTAssertEqual(service.activeRootURL?.path, "/")
        if case .accessGranted(let url, let isSecurityScoped) = service.status {
            XCTAssertEqual(url.path, "/")
            XCTAssertFalse(isSecurityScoped)
        } else {
            XCTFail("Expected .accessGranted")
        }
    }

    func testGrantAccessPersistsBookmark() throws {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        let testDir = URL(fileURLWithPath: NSTemporaryDirectory())
        mockFS.readablePaths = [testDir.path, "/Users", "/System", "/Library"]
        mockFS.directoryContents = [testDir.appendingPathComponent("test1")]

        let service = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        try service.grantAccess(for: testDir)

        XCTAssertNotNil(mockStore.storedData)
        XCTAssertEqual(mockStore.storedPath, testDir.path)
        XCTAssertEqual(service.activeRootURL?.path, testDir.path)
        XCTAssertTrue(service.status.isGranted)
    }

    func testRevokeAccessClearsBookmarkAndState() throws {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        let testDir = URL(fileURLWithPath: NSTemporaryDirectory())
        mockFS.readablePaths = [testDir.path]

        let service = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        try service.grantAccess(for: testDir)

        XCTAssertNotNil(mockStore.storedData)
        service.revokeAccess()

        XCTAssertNil(mockStore.storedData)
        XCTAssertNil(mockStore.storedPath)
        XCTAssertNil(service.activeRootURL)
        XCTAssertNil(service.lastTestResult)
        XCTAssertEqual(service.status, .notConfigured)
    }

    func testTestFullVolumeAccessSuccess() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        mockFS.readablePaths = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes"]
        mockFS.directoryContents = [
            URL(fileURLWithPath: "/System"),
            URL(fileURLWithPath: "/Library"),
            URL(fileURLWithPath: "/Users")
        ]

        let service = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        let result = service.testFullVolumeAccess()

        XCTAssertTrue(result.isAccessible)
        XCTAssertEqual(result.rootItemsCount, 3)
        XCTAssertTrue(result.accessibleSubpaths.contains("/System"))
        XCTAssertTrue(result.accessibleSubpaths.contains("/Users"))
        XCTAssertTrue(result.inaccessibleSubpaths.isEmpty)
        XCTAssertTrue(result.message.contains("Full volume access verified"))
        XCTAssertEqual(service.lastTestResult, result)
        XCTAssertTrue(service.status.isGranted)
    }

    func testTestFullVolumeAccessFailureWhenDirectoryListingFails() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()
        mockFS.shouldThrowOnContents = true
        mockFS.readablePaths = []

        let service = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        let result = service.testFullVolumeAccess()

        XCTAssertFalse(result.isAccessible)
        XCTAssertEqual(result.rootItemsCount, 0)
        XCTAssertTrue(result.accessibleSubpaths.isEmpty)
        XCTAssertTrue(result.message.contains("Volume access test failed"))
        XCTAssertFalse(service.status.isGranted)
        if case .accessDenied(let reason) = service.status {
            XCTAssertTrue(reason.contains("Volume access test failed"))
        } else {
            XCTFail("Expected .accessDenied")
        }
    }

    func testUserDefaultsVolumeBookmarkStore() {
        let suiteName = "test.garage.volumeaccess.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = UserDefaultsVolumeBookmarkStore(defaults: defaults)
        XCTAssertNil(store.loadBookmarkData())
        XCTAssertNil(store.loadBookmarkPath())

        let sampleData = Data("sample_bookmark_data".utf8)
        let samplePath = "/Volumes/Macintosh HD"
        store.saveBookmarkData(sampleData, path: samplePath)

        XCTAssertEqual(store.loadBookmarkData(), sampleData)
        XCTAssertEqual(store.loadBookmarkPath(), samplePath)

        store.clearBookmark()
        XCTAssertNil(store.loadBookmarkData())
        XCTAssertNil(store.loadBookmarkPath())
    }

    func testVolumeAccessStatusDisplayDescriptions() {
        let notConfigured = VolumeAccessStatus.notConfigured
        XCTAssertEqual(notConfigured.displayDescription, "Not configured (no root volume selected)")
        XCTAssertFalse(notConfigured.isGranted)

        let granted = VolumeAccessStatus.accessGranted(url: URL(fileURLWithPath: "/"), isSecurityScoped: true)
        XCTAssertTrue(granted.displayDescription.contains("Granted: / (security-scoped)"))
        XCTAssertTrue(granted.isGranted)

        let denied = VolumeAccessStatus.accessDenied(reason: "Permission denied")
        XCTAssertEqual(denied.displayDescription, "Denied: Permission denied")
        XCTAssertFalse(denied.isGranted)

        let stale = VolumeAccessStatus.staleBookmark(url: URL(fileURLWithPath: "/"))
        XCTAssertTrue(stale.displayDescription.contains("Stale bookmark: / (needs re-grant)"))
        XCTAssertFalse(stale.isGranted)
    }
}
