import XCTest
import IngestClient
@testable import GarageApp

final class IngestFileOpenAccessTests: XCTestCase {

    func testIngestEngineTestsOpeningFilesInDirectory() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("garage_test_open_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sampleFile1 = tempDir.appendingPathComponent("document1.txt")
        let sampleFile2 = tempDir.appendingPathComponent("document2.txt")
        try "Content 1".write(to: sampleFile1, atomically: true, encoding: .utf8)
        try "Content 2".write(to: sampleFile2, atomically: true, encoding: .utf8)

        let request = VolumeAccessTestRequest(
            rootBookmarkData: nil,
            sourceBookmarks: nil,
            sourcePaths: [
                SourcePathTestItem(slug: "test-dir", root: tempDir.path)
            ]
        )

        let result = IngestEngine.shared.testVolumeAccess(request: request)
        XCTAssertEqual(result.sourcePathResults.count, 1)

        let sourceRes = result.sourcePathResults[0]
        XCTAssertTrue(sourceRes.exists)
        XCTAssertTrue(sourceRes.isReadable)
        XCTAssertTrue(sourceRes.isDirectory)
        XCTAssertEqual(sourceRes.itemCount, 2)
        XCTAssertEqual(sourceRes.canOpenFiles, true)
        XCTAssertEqual(sourceRes.sampleFilesTested, 2)
        XCTAssertEqual(sourceRes.sampleFilesOpened, 2)
        XCTAssertNil(sourceRes.fileOpenErrorMessage)
        XCTAssertTrue(sourceRes.isAccessible)
        XCTAssertTrue(sourceRes.statusDescription.contains("test file(s) opened") || sourceRes.statusDescription.contains("Accessible"))
    }

    func testIngestEngineTestsOpeningSingleFile() throws {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("garage_test_single_file_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sampleFile = tempDir.appendingPathComponent("single_doc.txt")
        try "Single file content".write(to: sampleFile, atomically: true, encoding: .utf8)

        let request = VolumeAccessTestRequest(
            rootBookmarkData: nil,
            sourceBookmarks: nil,
            sourcePaths: [
                SourcePathTestItem(slug: "single-file", root: sampleFile.path)
            ]
        )

        let result = IngestEngine.shared.testVolumeAccess(request: request)
        XCTAssertEqual(result.sourcePathResults.count, 1)

        let sourceRes = result.sourcePathResults[0]
        XCTAssertTrue(sourceRes.exists)
        XCTAssertTrue(sourceRes.isReadable)
        XCTAssertFalse(sourceRes.isDirectory)
        XCTAssertEqual(sourceRes.canOpenFiles, true)
        XCTAssertEqual(sourceRes.sampleFilesTested, 1)
        XCTAssertEqual(sourceRes.sampleFilesOpened, 1)
        XCTAssertNil(sourceRes.fileOpenErrorMessage)
        XCTAssertTrue(sourceRes.isAccessible)
    }

    @MainActor
    func testVolumeAccessServicePropagatesFileOpenFailure() {
        let mockStore = MockVolumeBookmarkStore()
        let mockFS = MockFileSystemAccessor()

        let folderURL = URL(fileURLWithPath: "/Users/testuser/Documents")
        let fileURL = folderURL.appendingPathComponent("protected.docx")

        mockFS.readablePaths = ["/", "/Users", "/Users/testuser", "/Users/testuser/Documents", fileURL.path]
        mockFS.directoryContents = [fileURL]
        mockFS.unopenablePaths = [fileURL.path] // readable but cannot open handle

        let service = VolumeAccessService(bookmarkStore: mockStore, fileSystem: mockFS)
        let result = service.testFullVolumeAccess(sourcePaths: [
            (slug: "documents", root: "/Users/testuser/Documents")
        ])

        XCTAssertEqual(result.sourcePathResults.count, 1)
        let sourceRes = result.sourcePathResults[0]
        XCTAssertTrue(sourceRes.exists)
        XCTAssertTrue(sourceRes.isReadable)
        XCTAssertEqual(sourceRes.canOpenFiles, false)
        XCTAssertEqual(sourceRes.sampleFilesTested, 1)
        XCTAssertEqual(sourceRes.sampleFilesOpened, 0)
        XCTAssertFalse(sourceRes.isAccessible)
        XCTAssertTrue(sourceRes.statusDescription.contains("opening files failed"))
    }
}
