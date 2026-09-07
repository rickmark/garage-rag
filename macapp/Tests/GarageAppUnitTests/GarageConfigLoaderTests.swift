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
            origin: .config,
            documentCount: 42
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
        XCTAssertEqual(source.documentCount, 42)
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

    func testModelPresetEntryProperties() {
        let preset = ModelPresetEntry(
            name: "BGE-M3 (Embeddings)",
            modelId: "BAAI/bge-m3",
            slug: "bge-m3",
            modelRef: "bge-m3",
            provider: "llama_xpc",
            nativeDims: 1024,
            defaultDims: 1024,
            contextSize: 8192,
            downloadModelId: "CompendiumLabs/bge-m3-GGUF",
            downloadFile: "bge-m3-Q8_0.gguf"
        )

        XCTAssertEqual(preset.id, "bge-m3")
        XCTAssertEqual(preset.slug, "bge-m3")
        XCTAssertEqual(preset.effectiveDims, 1024)
        XCTAssertTrue(preset.isEmbeddingModel)
        XCTAssertEqual(preset.effectiveFilename, "bge-m3-Q8_0.gguf")
        XCTAssertEqual(preset.downloadURLString, "https://huggingface.co/CompendiumLabs/bge-m3-GGUF/resolve/main/bge-m3-Q8_0.gguf")
    }

    func testLoadModelPresetsFromJSON() throws {
        let json = """
        [
            {
                "name": "BGE-M3 (Embeddings)",
                "model_id": "BAAI/bge-m3",
                "slug": "bge-m3",
                "model_ref": "bge-m3",
                "provider": "llama_xpc",
                "native_dims": 1024,
                "default_dims": 1024,
                "context_size": 8192,
                "download_model_id": "CompendiumLabs/bge-m3-GGUF",
                "download_file": "bge-m3-Q8_0.gguf"
            },
            {
                "name": "Nomic Embed Text",
                "model_id": "nomic-ai/nomic-embed-text-v1.5",
                "slug": "nomic-embed-text",
                "model_ref": "nomic-embed-text",
                "provider": "llama_xpc",
                "native_dims": 768,
                "default_dims": 768,
                "context_size": 8192,
                "download_model_id": "nomic-ai/nomic-embed-text-v1.5-GGUF",
                "download_file": "nomic-embed-text-v1.5.Q8_0.gguf"
            }
        ]
        """

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_models_\(UUID().uuidString).json")
        try json.data(using: .utf8)!.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let presets = GarageConfigLoader.loadModelPresets(fileURL: tempURL)
        XCTAssertEqual(presets.count, 2)
        XCTAssertEqual(presets[0].slug, "bge-m3")
        XCTAssertEqual(presets[0].effectiveDims, 1024)
        XCTAssertEqual(presets[1].slug, "nomic-embed-text")
        XCTAssertEqual(presets[1].effectiveDims, 768)
    }

    func testLoadModelPresetsFallbackToDefault() {
        let fakeURL = URL(fileURLWithPath: "/tmp/non_existent_models_\(UUID().uuidString).json")
        let presets = GarageConfigLoader.loadModelPresets(fileURL: fakeURL)
        XCTAssertFalse(presets.isEmpty)
        XCTAssertTrue(presets.contains { $0.slug == "bge-m3" })
        XCTAssertTrue(presets.contains { $0.slug == "nomic-embed-text" })
    }

    func testEmbeddingVectorStatsCalculation() {
        let sampleVector: [Float] = [0.1, -0.2, 0.3, 0.4, -0.5]
        guard let stats = EmbeddingVectorStats(vector: sampleVector) else {
            XCTFail("Stats should not be nil for non-empty vector")
            return
        }

        XCTAssertEqual(stats.count, 5)
        XCTAssertEqual(stats.min, -0.5, accuracy: 0.0001)
        XCTAssertEqual(stats.max, 0.4, accuracy: 0.0001)
        XCTAssertEqual(stats.mean, 0.02, accuracy: 0.0001)
        XCTAssertGreaterThan(stats.l2Norm, 0)
    }
}
