import XCTest
@testable import GarageApp

final class LMStudioTokenStoreTests: XCTestCase {

    func testLMStudioTokenErrorDescriptions() {
        let readError = LMStudioTokenError.keychainRead(-25300)
        XCTAssertTrue(readError.localizedDescription.contains("could not read LM Studio API token"))
        XCTAssertTrue(readError.localizedDescription.contains("-25300"))

        let writeError = LMStudioTokenError.keychainWrite(-50)
        XCTAssertTrue(writeError.localizedDescription.contains("could not save LM Studio API token"))

        let deleteError = LMStudioTokenError.keychainDelete(-34018)
        XCTAssertTrue(deleteError.localizedDescription.contains("could not remove LM Studio API token"))
    }
}
