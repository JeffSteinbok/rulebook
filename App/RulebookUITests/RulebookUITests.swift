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
        let reorder = app.buttons["reorder"]
        XCTAssertTrue(reorder.waitForExistence(timeout: 10))
        reorder.tap()
        XCTAssertTrue(app.staticTexts["Reordering rules needs Pro"].waitForExistence(timeout: 5))
    }

    /// The free tier offers no swipe at all: a swipe that only opens a
    /// paywall is a gesture that lies about what it does.
    func testFreeTierHasNoSwipeDelete() {
        let app = launch("-locked")
        let rule = ruleCell(app, named: "Vendor invoices")
        XCTAssertTrue(rule.waitForExistence(timeout: 10))
        rule.swipeLeft()
        XCTAssertFalse(app.buttons["Delete"].waitForExistence(timeout: 2))
    }

    /// The control for the test above: the same swipe, unlocked, does offer
    /// Delete, so the free-tier test is really swiping a rule.
    func testUnlockedSwipeOffersDelete() {
        let app = launch()
        let rule = ruleCell(app, named: "Vendor invoices")
        XCTAssertTrue(rule.waitForExistence(timeout: 10))
        rule.swipeLeft()
        XCTAssertTrue(app.buttons["Delete"].waitForExistence(timeout: 5))
    }

    /// A rule's row, by its name. The list's first cells are the banner,
    /// sync line and filter tabs, so "the first few cells" aren't rules.
    private func ruleCell(_ app: XCUIApplication, named name: String) -> XCUIElement {
        app.collectionViews.cells
            .containing(NSPredicate(format: "label CONTAINS %@", name))
            .firstMatch
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
