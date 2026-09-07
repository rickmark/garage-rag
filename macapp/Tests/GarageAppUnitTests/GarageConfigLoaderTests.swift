import XCTest
@testable import GarageApp

final class GarageConfigLoaderTests: XCTestCase {

    func testRegisteredSourceProperties() {
        let source = RegisteredSource(
            slug: "dropbox",
            kind: "filesystem",
            root: "~/Dropbox",
            corpusClass: "document",
            trust: "authored",
            allowCloudEnrichment: true,
            enabled: true,
            includeCode: false,
            origin: .config
        )

        XCTAssertEqual(source.id, "dropbox")
        XCTAssertEqual(source.slug, "dropbox")
        XCTAssertEqual(source.kind, "filesystem")
        XCTAssertEqual(source.root, "~/Dropbox")
        XCTAssertEqual(source.corpusClass, "document")
        XCTAssertEqual(source.trust, "authored")
        XCTAssertTrue(source.allowCloudEnrichment)
        XCTAssertTrue(source.enabled)
        XCTAssertFalse(source.includeCode)
        XCTAssertEqual(source.origin, .config)
        XCTAssertFalse(source.expandedRootPath.hasPrefix("~"))
        XCTAssertEqual(source.expandedRootURL.path, (source.root as NSString).expandingTildeInPath)
    }

    func testLoadSourcesFromConfigJSON() throws {
        let json = """
        {
            "$schema": "https://raw.githubusercontent.com/rickmark/garage-rag/refs/heads/main/garage.schema.json",
            "database": {
                "url": "postgresql+psycopg:///rag"
            },
            "sources": [
                {
                    "slug": "dropbox",
                    "root": "~/Dropbox",
                    "kind": "filesystem",
                    "class": "document",
                    "trust": "authored",
                    "include_code": false,
                    "allow_cloud_enrichment": true,
                    "enabled": true
                },
                {
                    "slug": "developer",
                    "root": "~/Developer",
                    "kind": "git",
                    "class": "code",
                    "trust": "authored",
                    "include_code": true,
                    "allow_cloud_enrichment": false,
                    "enabled": true
                }
            ]
        }
        """

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_garage_\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let sources = GarageConfigLoader.loadSourcesFromConfig(fileURL: tempURL)
        XCTAssertEqual(sources.count, 2)

        let dropbox = sources[0]
        XCTAssertEqual(dropbox.slug, "dropbox")
        XCTAssertEqual(dropbox.root, "~/Dropbox")
        XCTAssertEqual(dropbox.kind, "filesystem")
        XCTAssertEqual(dropbox.corpusClass, "document")
        XCTAssertEqual(dropbox.trust, "authored")
        XCTAssertTrue(dropbox.allowCloudEnrichment)
        XCTAssertFalse(dropbox.includeCode)
        XCTAssertEqual(dropbox.origin, .config)

        let dev = sources[1]
        XCTAssertEqual(dev.slug, "developer")
        XCTAssertEqual(dev.root, "~/Developer")
        XCTAssertEqual(dev.kind, "git")
        XCTAssertEqual(dev.corpusClass, "code")
        XCTAssertEqual(dev.trust, "authored")
        XCTAssertFalse(dev.allowCloudEnrichment)
        XCTAssertTrue(dev.includeCode)
        XCTAssertEqual(dev.origin, .config)
    }

    func testLoadSourcesFromNonExistentFile() {
        let fakeURL = URL(fileURLWithPath: "/tmp/non_existent_file_\(UUID().uuidString).json")
        let sources = GarageConfigLoader.loadSourcesFromConfig(fileURL: fakeURL)
        XCTAssertTrue(sources.isEmpty)
    }

    func testLoadSourcesFromMalformedJSON() throws {
        let malformed = "{ this is not valid json }"
        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("malformed_\(UUID().uuidString).json")
        try malformed.data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let sources = GarageConfigLoader.loadSourcesFromConfig(fileURL: tempURL)
        XCTAssertTrue(sources.isEmpty)
    }
}
