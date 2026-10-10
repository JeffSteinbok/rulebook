import XCTest

/// The real UI on the demo mailbox: `-demo` runs on the in-memory seed with no
/// sign-in, and `-locked` adds the free tier's entitlement checks. StoreKit
/// answers from Rulebook.storekit (the test plan in the scheme).
final class RulebookUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo"] + arguments
        app.launch()
        return app
    }

    func testRulesListShowsTheDemoMailbox() {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Rulebook"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'rule'")).firstMatch.exists)
    }

    func testFreeTierReorderAsksForPro() {
        let app = launch("-locked")
        let reorder = app.buttons["Reorder"]
        XCTAssertTrue(reorder.waitForExistence(timeout: 10))
        reorder.tap()
        XCTAssertTrue(app.staticTexts["Reordering rules needs Pro"].waitForExistence(timeout: 5))
    }

    func testFreeTierSwipeDeleteAsksForPro() throws {
        let app = launch("-locked")
        XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: 10))
        // Some seed rules are read-only and offer no swipe; use the first that does.
        for index in 0..<min(6, app.collectionViews.cells.count) {
            app.collectionViews.cells.element(boundBy: index).swipeLeft()
            let delete = app.buttons["Delete"]
            if delete.waitForExistence(timeout: 2) {
                delete.tap()
                XCTAssertTrue(app.staticTexts["Deleting rules needs Pro"].waitForExistence(timeout: 5))
                return
            }
        }
        XCTFail("No row offered swipe-to-delete.")
    }

    func testNewRuleCancelAsksBeforeDiscarding() {
        let app = launch()
        let newRule = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'New rule'")).firstMatch
        XCTAssertTrue(newRule.waitForExistence(timeout: 10))
        newRule.tap()

        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Half-made rule")

        app.buttons["Cancel"].tap()
        let discard = app.buttons["Discard changes"]
        XCTAssertTrue(discard.waitForExistence(timeout: 3), "Cancel with a draft must ask first.")
        discard.tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 3), "Discarding closes the editor.")
    }

    func testLargestTextPassesTheAccessibilityAudit() throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("performAccessibilityAudit needs iOS 17.") }
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10))
        try app.performAccessibilityAudit(for: [.dynamicType, .textClipped, .sufficientElementDescription]) { issue in
            // Navigation-bar and search-field text is sized by the system, which
            // caps it on purpose; nothing the app sets changes that.
            if let element = issue.element,
               element.elementType == .searchField || app.navigationBars.firstMatch.frame.contains(element.frame) {
                return true
            }
            print("AUDIT: \(issue.auditType) \(issue.compactDescription) — \(issue.element?.debugDescription ?? "no element")")
            return false
        }
    }
}
