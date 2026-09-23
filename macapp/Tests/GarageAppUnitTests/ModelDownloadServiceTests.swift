import XCTest
import ModelDownloadClient
@testable import GarageApp

/// Under `--data-directory` the app must point the model download service at its own models
/// folder: the XPC service never sees the app's arguments and would use the real one.
final class ModelDownloadServiceTests: XCTestCase {

    @MainActor
    func testOverrideIsSentToTheServiceOnRefresh() async throws {
        let engine = ModelDownloaderEngine()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GarageModelsOverride_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let realDefault = engine.getModelsDirectoryPath()

        let service = ModelDownloadService(
            client: ModelDownloadClient(inProcessEngine: engine),
            modelsDirectoryOverride: folder.path
        )
        await service.refresh()

        XCTAssertEqual(engine.getModelsDirectoryPath(), folder.path)
        XCTAssertEqual(service.modelsDirectory, folder.path, "the app shows the folder the service now uses")
        XCTAssertNotEqual(service.modelsDirectory, realDefault)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    @MainActor
    func testOverrideIsResentAfterTheServiceForgetsIt() async throws {
        // A relaunched XPC service starts from its own default again; the next call re-asserts.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("GarageModelsOverride_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let relaunched = ModelDownloaderEngine()
        XCTAssertNotEqual(relaunched.getModelsDirectoryPath(), folder.path)
        let service = ModelDownloadService(
            client: ModelDownloadClient(inProcessEngine: relaunched),
            modelsDirectoryOverride: folder.path
        )
        await service.refresh()
        XCTAssertEqual(relaunched.getModelsDirectoryPath(), folder.path)
    }

    @MainActor
    func testNoOverrideLeavesTheServiceDefault() async throws {
        let engine = ModelDownloaderEngine()
        let before = engine.getModelsDirectoryPath()
        let service = ModelDownloadService(
            client: ModelDownloadClient(inProcessEngine: engine),
            modelsDirectoryOverride: nil
        )
        await service.refresh()
        XCTAssertEqual(engine.getModelsDirectoryPath(), before)
    }

    @MainActor
    func testDefaultIsNoOverrideWithoutDataDirectoryArgument() {
        // The test host is not launched with --data-directory.
        XCTAssertNil(ModelDownloadService().modelsDirectoryOverride)
    }
}
