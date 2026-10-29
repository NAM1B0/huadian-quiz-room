import XCTest

@MainActor
final class PhoneUITests: XCTestCase {
    var app: XCUIApplication!
    override func setUp() {
        super.setUp(); continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication(); app.launchEnvironment["HUADIAN_TEST_SESSION"] = UUID().uuidString
    }
    func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func enter(_ kind: String = "single") {
        XCTAssertTrue(app.buttons["start-" + kind].waitForExistence(timeout: 15)); app.buttons["start-" + kind].tap()
        XCTAssertTrue(app.staticTexts["question-number"].waitForExistence(timeout: 5))
    }
    func testPracticePhoneLayoutPersistenceAndPreviewReset() {
        app.launch(); shot("01-home-iPhone13Pro"); enter()
        shot("02-practice-iPhone13Pro")
        app.buttons["option-A"].tap()
        app.swipeUp(); XCTAssertTrue(app.staticTexts["correct-answer"].waitForExistence(timeout: 3))
        shot("03-feedback-iPhone13Pro")
        app.buttons["question-board"].tap(); XCTAssertTrue(app.buttons["board-1"].waitForExistence(timeout: 3))
        shot("04-number-board-iPhone13Pro"); app.buttons["board-1"].tap()
        app.swipeDown(); app.switches["show-answers"].tap()
        app.terminate(); app.launch(); enter()
        XCTAssertEqual(app.switches["show-answers"].value as? String, "0")
        XCTAssertTrue(app.buttons["option-A"].label.contains("已选择"))
    }
    func testCorrectSingleAdvancesAndMultipleExamDoesNot() {
        app.launch(); enter(); app.swipeUp(); app.buttons["option-C"].tap()
        let next = app.staticTexts["question-number"]
        XCTAssertTrue(NSPredicate(format: "label CONTAINS %@", "第 2 题").evaluate(with: next) || waitForText("第 2 题", element: next))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.segmentedControls["study-mode"].buttons["考试"].tap(); enter("multiple")
        let number = app.staticTexts["question-number"].label
        app.buttons["option-A"].tap()
        // Waiting also catches unintended delayed auto-advance.
        let unchanged = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", number), object: app.staticTexts["question-number"])
        XCTAssertEqual(XCTWaiter.wait(for: [unchanged], timeout: 2), .timedOut)
        XCTAssertFalse(app.staticTexts["correct-answer"].exists)
        app.buttons["next-question"].tap(); XCTAssertNotEqual(app.staticTexts["question-number"].label, number)
    }
    private func waitForText(_ text: String, element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 3) == .completed
    }
    func testRecordsStatisticsAndDeletion() {
        app.launchArguments = ["--fixture"]; app.launch()
        app.tabBars.buttons["记录"].tap(); XCTAssertTrue(app.buttons["编辑"].waitForExistence(timeout: 5))
        app.buttons["编辑"].tap(); shot("05-exam-record-edit")
        app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'exam-record-'")).firstMatch.tap()
        app.buttons["删除"].tap()
        XCTAssertTrue(app.sheets.buttons["删除"].waitForExistence(timeout: 5)); app.sheets.buttons["删除"].tap()
        XCTAssertTrue(app.staticTexts["暂无考试记录"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap(); app.segmentedControls.buttons["练习"].tap()
        shot("06-practice-statistics")
        XCTAssertTrue(app.staticTexts["50%"].firstMatch.exists)
    }
    func testDarkLargeTextAndLandscape() {
        app.launchArguments = ["--dark", "--large-text"]; app.launch(); enter()
        shot("07-dark-accessibility-text")
        app.swipeUp(); shot("08-dark-accessibility-options")
        app.terminate(); app.launchArguments = ["--dark"]; app.launch(); enter()
        XCUIDevice.shared.orientation = .landscapeLeft
        shot("09-landscape-dark")
        XCTAssertTrue(app.buttons["next-question"].isHittable)
    }
    func testSubmitLocksAnswersAndNextEntryCreatesNewExam() {
        app.launchArguments = ["--exam-fixture"]; app.launch()
        app.segmentedControls["study-mode"].buttons["考试"].tap(); enter("judge")
        app.buttons["submit-toolbar"].tap()
        XCTAssertTrue(app.sheets.buttons["交卷"].waitForExistence(timeout: 5)); app.sheets.buttons["交卷"].tap()
        XCTAssertTrue(app.staticTexts["correct-answer"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["option-A"].isEnabled)
        shot("10-submitted-readonly")
        app.navigationBars.buttons.element(boundBy: 0).tap(); enter("judge")
        XCTAssertFalse(app.staticTexts["correct-answer"].exists)
        XCTAssertTrue(app.buttons["option-A"].isEnabled)
    }

    func testPDFDataAndQuestionEntrypointsDisplayAndNavigate() {
        app.launch(); app.tabBars.buttons["数据"].tap()
        app.buttons["open-source-pdf"].tap()
        let status = app.staticTexts["pdf-page-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForText("40 / 161", element: status))
        XCTAssertFalse(app.staticTexts["原文暂时无法打开"].exists)
        shot("11-pdf-from-data-portrait")
        app.swipeUp()
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (label CONTAINS %@)", "40 / 161"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 5), .completed)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(status.waitForExistence(timeout: 3)); shot("12-pdf-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["题库"].tap(); enter()
        app.buttons["question-board"].tap()
        let search = app.textFields["jump-number"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("245")
        app.buttons["board-245"].tap()
        app.buttons["更多操作"].tap(); app.buttons["查看题库原文"].tap()
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertTrue(waitForText("95 / 161", element: status))
        shot("13-pdf-question-245-page95")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["question-number"].label.contains("第 245 题"))
    }

    func testPDFMissingResourceShowsRetryAndAllowsBack() {
        app.launchArguments = ["--missing-pdf"]; app.launch()
        app.tabBars.buttons["数据"].tap(); app.buttons["open-source-pdf"].tap()
        XCTAssertTrue(app.staticTexts["原文暂时无法打开"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["重试"].isHittable)
        app.buttons["重试"].tap(); shot("14-pdf-load-error")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["导出学习记录"].exists)
    }
}
