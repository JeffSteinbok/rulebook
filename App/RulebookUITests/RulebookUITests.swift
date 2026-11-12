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

    /// The demo account App Review uses: added from the gate, every paid
    /// action open, Pro still on offer, and removable again. Launches without
    /// `-demo`, through the real account flow, from no saved mailboxes.
    func testDemoAccountAddsOpensEverythingAndRemoves() {
        let app = XCUIApplication()
        // Argument-domain defaults: no saved mailboxes, nothing bought.
        app.launchArguments = ["-rulebook.accounts", "<data></data>", "-rulebook.pro.lastKnown", "NO"]
        app.launch()

        let addDemo = app.buttons["Add demo account"]
        XCTAssertTrue(addDemo.waitForExistence(timeout: 10))
        snapshot(app, "1-gate")
        addDemo.tap()

        XCTAssertTrue(app.navigationBars["Rulebook"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Demo account'")).firstMatch.exists)
        snapshot(app, "2-demo-rules")

        // Paid actions go straight through, with no paywall.
        app.buttons["Reorder rules"].tap()
        XCTAssertTrue(app.buttons["Finish reordering"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Reordering rules needs Pro"].exists)
        snapshot(app, "3-reorder")
        app.buttons["Finish reordering"].tap()

        let newRule = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'New rule'")).firstMatch
        newRule.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Editing rules needs Pro"].exists)
        snapshot(app, "4-new-rule")
        app.buttons["Cancel"].tap()

        // The purchase is still reachable, from the menu.
        let bar = app.navigationBars["Rulebook"]
        bar.buttons.element(boundBy: bar.buttons.count - 1).tap()
        XCTAssertTrue(app.buttons["Rulebook Pro"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Add demo account"].exists, "Only one demo account.")
        snapshot(app, "5-menu")
        app.buttons["Manage accounts"].tap()

        let demoRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Demo account'")).firstMatch
        XCTAssertTrue(demoRow.waitForExistence(timeout: 5))
        demoRow.tap()

        let remove = app.buttons["Remove demo account"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        snapshot(app, "6-mailboxes")
        remove.tap()
        app.buttons["Remove"].tap()

        XCTAssertTrue(app.buttons["Add demo account"].waitForExistence(timeout: 10), "Back at the gate.")
        snapshot(app, "7-removed")
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
