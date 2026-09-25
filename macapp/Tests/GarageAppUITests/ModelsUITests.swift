import XCTest

/// The Models page's three tabs on an empty registry. Nothing is registered, downloaded or loaded:
/// the preset Add buttons and Embed All are left alone.
final class ModelsUITests: GarageUITestCase {

    /// Picks a tab in the segmented control, which macOS exposes as radio buttons titled by segment.
    private func selectTab(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let segment = element(identifier: "models.tab").radioButtons
            .matching(NSPredicate(format: "label == %@ OR title == %@", name, name)).firstMatch
        XCTAssertTrue(segment.waitForExistence(timeout: 10), "no \(name) segment", file: file, line: line)
        segment.click()
    }

    func testOverallShowsEachKindOfModel() throws {
        try launchApp()
        waitForBackend()
        open(section: "models")

        XCTAssertTrue(element(identifier: "models.tab").waitForExistence(timeout: 15), "no tab control")
        for heading in ["Embedding", "Fact Distillation", "Providers"] {
            XCTAssertTrue(element(text: heading).waitForExistence(timeout: 15), "Overall does not show \"\(heading)\"")
        }
        XCTAssertTrue(element(text: "No embedding model").waitForExistence(timeout: 30), "an empty registry does not say there is no embedding model")
        XCTAssertTrue(element(text: "No distillation model").exists, "no facts model does not say so")
        XCTAssertTrue(element(text: "Llama XPC").exists, "Providers does not list Llama XPC")
        XCTAssertTrue(element(identifier: "models.overall.manageEmbedding").exists, "the Embedding card has no Manage button")
        XCTAssertTrue(element(identifier: "models.overall.manageDistillation").exists, "the Fact Distillation card has no Manage button")
        // Tab contents stay on their tabs.
        XCTAssertFalse(element(text: "Text Embedding Models").exists, "Overall shows the Embedding tab's list")
        XCTAssertFalse(element(text: "Fact Prompts").exists, "Overall shows the Distillation tab's prompts")
    }

    func testManageButtonsAndTheSegmentsSwitchTabs() throws {
        try launchApp()
        waitForBackend()
        open(section: "models")

        let manageEmbedding = element(identifier: "models.overall.manageEmbedding")
        XCTAssertTrue(manageEmbedding.waitForExistence(timeout: 15), "no Manage button on the Embedding card")
        click(manageEmbedding)
        XCTAssertTrue(element(text: "Text Embedding Models").waitForExistence(timeout: 10), "Manage did not open the Embedding tab")
        XCTAssertTrue(element(text: "No embedding model yet").waitForExistence(timeout: 30), "the Embedding tab does not say the registry is empty")
        XCTAssertTrue(element(identifier: "models.addCustom").exists, "the Embedding tab offers no custom model")
        XCTAssertFalse(element(identifier: "models.overall.manageEmbedding").exists, "the Overall cards stayed on the Embedding tab")

        // The custom-model form is folded away until asked for.
        XCTAssertFalse(element(identifier: "models.custom.slug").exists, "the custom model form is open before anyone asked for it")
        click(element(identifier: "models.addCustom"))
        XCTAssertTrue(element(identifier: "models.custom.slug").waitForExistence(timeout: 10), "Custom model… did not open the form")
        let register = element(identifier: "models.custom.register")
        XCTAssertTrue(register.exists, "the custom model form has no Register button")
        XCTAssertFalse(register.isEnabled, "Register is enabled with an empty form")

        selectTab("Overall")
        XCTAssertTrue(element(identifier: "models.overall.manageDistillation").waitForExistence(timeout: 10), "the Overall segment did not go back")
        click(element(identifier: "models.overall.manageDistillation"))
        XCTAssertTrue(element(text: "Fact Distillation Model").waitForExistence(timeout: 10), "Manage did not open the Distillation tab")
        XCTAssertTrue(element(text: "Fact Prompts").waitForExistence(timeout: 10), "the Distillation tab does not list the prompts")
        XCTAssertFalse(element(text: "Text Embedding Models").exists, "the Embedding list stayed on the Distillation tab")

        selectTab("Embedding")
        XCTAssertTrue(element(text: "Text Embedding Models").waitForExistence(timeout: 10), "the Embedding segment did not switch tabs")
        XCTAssertFalse(element(text: "Fact Prompts").exists, "the prompts stayed on the Embedding tab")
    }
}
