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
    private func tapOption(_ key: String) {
        let button = app.buttons["option-" + key]
        for _ in 0..<3 where !button.isHittable {
            if button.frame.midY < app.frame.midY { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(button.isHittable); button.tap()
    }
    private func assertNoAutomaticNext(_ number: String) {
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", number), object: app.staticTexts["question-number"])
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 1.2), .timedOut)
    }
    func testMultiplePracticeCheckThenNextAndDraftRestart() {
        app.launch(); enter("multiple"); tapOption("A")
        XCTAssertFalse(app.staticTexts["correct-answer"].exists)
        XCTAssertFalse(app.buttons["option-B"].label.contains("正确选项"))
        app.terminate(); app.launch(); enter("multiple")
        XCTAssertTrue(app.buttons["option-A"].label.contains("已选择"))
        XCTAssertFalse(app.staticTexts["correct-answer"].exists)
        let first = app.staticTexts["question-number"].label
        app.buttons["next-question"].tap(); app.swipeUp()
        XCTAssertTrue(app.staticTexts["correct-answer"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["question-number"].label, first)
        shot("15-multiple-practice-checked-stays")
        tapOption("D"); XCTAssertFalse(app.staticTexts["correct-answer"].exists)
        app.buttons["next-question"].tap()
        XCTAssertTrue(app.staticTexts["correct-answer"].exists)
        XCTAssertEqual(app.staticTexts["question-number"].label, first)
        app.buttons["next-question"].tap()
        XCTAssertTrue(waitForText("第 247 题", element: app.staticTexts["question-number"]))
        for key in ["A", "C", "D"] { tapOption(key) }
        XCTAssertTrue(waitForText("第 248 题", element: app.staticTexts["question-number"]))
        app.buttons["question-board"].tap()
        let search = app.textFields["jump-number"]; search.tap(); search.typeText("426")
        app.buttons["board-426"].tap(); tapOption("A")
        XCTAssertTrue(app.buttons["next-question"].isEnabled)
        app.buttons["next-question"].tap(); app.swipeUp()
        XCTAssertTrue(app.staticTexts["correct-answer"].exists)
        XCTAssertTrue(app.staticTexts["question-number"].label.contains("第 426 题"))
    }
    private func enterReview(_ source: String, kind: String, autoRemove: Bool = false) {
        app.launchArguments = ["--review-fixture"]; app.launch()
        app.tabBars.buttons["错题"].tap()
        app.segmentedControls["review-source"].buttons.matching(NSPredicate(format: "label BEGINSWITH %@", source)).firstMatch.tap()
        app.segmentedControls["review-kind"].buttons[kind].tap()
        if autoRemove {
            let toggle = app.switches["review-auto-remove"]
            // SwiftUI exposes the whole row as the switch; its center is the label.
            if toggle.value as? String == "0" { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }
            XCTAssertEqual(toggle.value as? String, "1", "The removal switch must actually be on")
        }
        app.buttons["start-review"].tap()
        XCTAssertTrue(app.staticTexts["question-number"].waitForExistence(timeout: 5))
    }
    func testBothMultipleReviewsCheckBeforeFeedbackAndRemoval() {
        for source in ["练习", "考试"] {
            enterReview(source, kind: "多选", autoRemove: true)
            let first = app.staticTexts["question-number"].label
            for key in ["A", "B", "C"] { tapOption(key) }
            XCTAssertTrue(app.buttons["option-A"].isEnabled)
            XCTAssertFalse(app.staticTexts["correct-answer"].exists)
            assertNoAutomaticNext(first)
            app.buttons["next-question"].tap(); app.swipeUp()
            XCTAssertTrue(app.staticTexts["correct-answer"].waitForExistence(timeout: 3))
            shot("16-" + source + "-multiple-review-checked")
            XCTAssertFalse(app.buttons["option-A"].isEnabled)
            XCTAssertTrue(app.staticTexts["已从错题集移出"].exists)
            XCTAssertEqual(app.staticTexts["question-number"].label, first)
            app.buttons["next-question"].tap()
            XCTAssertTrue(waitForText("第 247 题", element: app.staticTexts["question-number"]))
            app.terminate()
        }
    }
    func testBothSingleAndJudgeReviewsOnlyAdvanceWhenCorrect() {
        for source in ["练习", "考试"] {
            for (kind, wrong, correct, next) in [("单选", "A", "C", "第 2 题"), ("判断", "B", "A", "第 428 题")] {
                enterReview(source, kind: kind)
                let first = app.staticTexts["question-number"].label
                tapOption(wrong); assertNoAutomaticNext(first)
                app.swipeUp(); XCTAssertTrue(app.staticTexts["correct-answer"].exists)
                tapOption(correct)
                XCTAssertTrue(waitForText(next, element: app.staticTexts["question-number"]))
                app.terminate()
            }
        }
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
        let status = app.staticTexts["pdf-page-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        // Query the settled label once. Repeated predicate polling forces PDFKit
        // to rebuild its large accessibility tree on every sample on slow runners.
        let initialLocation = status.label
        XCTAssertTrue(initialLocation.contains("40 / 161"), "Unexpected PDF location: " + initialLocation)
        XCTAssertFalse(app.staticTexts["原文暂时无法打开"].exists)
        shot("11-pdf-from-data-portrait")
        // A single short scroll can leave the same PDF page visible. Drag inside
        // the reading area far enough to cross a page boundary, with a bounded
        // number of gestures; still fail if the reader cannot change pages.
        let scrollStart = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        let scrollEnd = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        for _ in 0..<3 {
            scrollStart.press(forDuration: 0.1, thenDragTo: scrollEnd)
            if status.label != initialLocation { break }
        }
        XCTAssertNotEqual(status.label, initialLocation, "The PDF must scroll to another page")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(status.waitForExistence(timeout: 3)); shot("12-pdf-landscape")
        XCUIDevice.shared.orientation = .portrait
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["题库"].tap(); enter()
        app.buttons["question-board"].tap()
        let search = app.textFields["jump-number"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("245")
        app.buttons["board-245"].tap()
        XCTAssertTrue(app.staticTexts["question-number"].label.contains("第 245 题"))
        app.buttons["更多操作"].tap(); app.buttons["查看题库原文"].tap()
        XCTAssertTrue(status.waitForExistence(timeout: 20))
        shot("13-pdf-question-245-page95")
        let questionLocation = status.label
        XCTAssertTrue(questionLocation.contains("95 / 161"), "Unexpected PDF location: " + questionLocation)
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
