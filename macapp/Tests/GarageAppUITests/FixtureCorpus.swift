import XCTest

/// What the made-up corpus in `macapp/Tests/Fixtures/corpus` holds, as its README lists it.
/// `garage_python/tests/test_fixture_corpus.py` checks the same facts against the real extractors.
enum FixtureCorpus {
    struct Document {
        let file: String
        let title: String
        /// An invented word that only this file contains.
        let token: String
    }

    static let quillonBridge = Document(file: "quillon-bridge.md", title: "The Quillon Bridge", token: "zorvexine")
    static let lighthouse = Document(file: "marrowgate-lighthouse.txt", title: "Marrowgate Lighthouse", token: "plimbrate")
    static let tideTables = Document(file: "tide_tables.rs", title: "tide_tables.rs", token: "tessaroon")
    static let lanternFestival = Document(file: "lantern-festival.eml", title: "The Brindlecombe lantern festival", token: "wendleflock")
    static let orchard = Document(file: "ashvale-orchard.pdf", title: "The Ashvale Orchard Survey", token: "orbanquet")
    static let glassworks = Document(file: "tavish-glassworks.docx", title: "A History of Tavish Glassworks", token: "glimmerhaft")

    /// What a source added through the Sources page indexes: code is off there, so not the Rust file.
    static let indexedWithoutCode = [quillonBridge, lighthouse, lanternFestival, orchard, glassworks]
    /// Chunks of `indexedWithoutCode`: the Markdown note splits at its second heading.
    static let chunksWithoutCode = 6
    static let quillonBridgeChunks = 2
}

extension GarageUITestCase {
    /// A copy of the fixture corpus in this test's data folder, to add as a source. The bundle's own
    /// copy is never a source: an ingest would record paths inside the test bundle.
    func copyFixtureCorpus(named name: String = "corpus", file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let bundled = try XCTUnwrap(
            Bundle(for: GarageUITestCase.self).resourceURL?.appendingPathComponent("corpus", isDirectory: true),
            "the UI test bundle has no resources folder",
            file: file,
            line: line
        )
        guard FileManager.default.fileExists(atPath: bundled.path) else {
            XCTFail("the UI test bundle has no corpus at \(bundled.path)", file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        let copy = dataDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.copyItem(at: bundled, to: copy)
        return copy
    }
}
