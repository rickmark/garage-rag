import XCTest
@testable import GarageApp

final class LlamaDiagnosticTests: XCTestCase {
    /// The Built-in Engine row tokenizes only when the engine's health says a model is loaded;
    /// otherwise the tokenizer check is skipped rather than failing the row.
    func testHealthReportsLoadedModelOnlyWhenStatusIsOK() {
        XCTAssertTrue(XPCServiceManager.llamaHealthReportsLoadedModel(#"{"status": "ok"}"#))
        XCTAssertFalse(XPCServiceManager.llamaHealthReportsLoadedModel(#"{"status": "no_model_loaded"}"#))
        XCTAssertFalse(XPCServiceManager.llamaHealthReportsLoadedModel(#"{"status": "loading model"}"#))
        XCTAssertFalse(XPCServiceManager.llamaHealthReportsLoadedModel("not json"))
        XCTAssertFalse(XPCServiceManager.llamaHealthReportsLoadedModel("{}"))
    }
}
