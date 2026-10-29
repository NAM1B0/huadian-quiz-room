import XCTest
import SQLite3
@testable import HuadianQuiz

final class MemoryPersistence: StudyPersistence {
    var data: Data?
    var backups: [Data] = []
    var failWrites = false
    var failBackups = false
    func read() throws -> Data? { data }
    func write(_ bytes: Data) throws { if failWrites { throw StudyError("模拟磁盘写入失败") }; data = bytes }
    func backup(_ bytes: Data, reason: String) throws { if failBackups { throw StudyError("模拟备份失败") }; backups.append(bytes) }
    func listBackups() throws -> [LocalBackup] { [] }
    func readBackup(_ backup: LocalBackup) throws -> Data { throw StudyError("无备份") }
}

@MainActor
final class StudyStoreTests: XCTestCase {
    func makeStore(_ disk: MemoryPersistence = MemoryPersistence()) throws -> StudyStore { try StudyStore(bank: .load(), persistence: disk) }
    func wrong(_ q: Question) -> [String] { [q.options.first { !q.answer.contains($0.key) }?.key ?? q.answer[0]] }

    func testBankAndPartialScoring() throws {
        let store = try makeStore()
        XCTAssertEqual(store.bank.questions.count, 563)
        XCTAssertEqual(store.bank.groups.count, 18)
        XCTAssertEqual(store.bank.questions(of: .single).count, 245)
        XCTAssertEqual(store.bank.questions(of: .multiple).count, 181)
        XCTAssertEqual(store.bank.questions(of: .judge).count, 137)
        let q = try XCTUnwrap(store.bank.questions.first { $0.type == .multiple && $0.answer.count > 1 && $0.answer.count < $0.options.count })
        XCTAssertEqual(q.result(for: []), .unanswered)
        XCTAssertEqual(q.result(for: [q.answer[0]]), .partial)
        XCTAssertEqual(q.result(for: Array(q.answer.reversed())), .correct)
        XCTAssertEqual(q.result(for: q.answer + wrong(q)), .wrong)
    }

    func testPracticeLatestStatisticsAndRestart() throws {
        let disk = MemoryPersistence(); let store = try makeStore(disk); let q = store.bank.questions[0]
        try store.savePractice(q.id, choices: wrong(q))
        XCTAssertEqual(store.statistics(store.bank.questions).practiced, 1)
        XCTAssertEqual(store.statistics(store.bank.questions).correct, 0)
        XCTAssertEqual(store.visibleMistakes(.practice).count, 1)
        try store.review("practice:" + q.id, choices: q.answer)
        XCTAssertEqual(store.visibleMistakes(.practice).count, 1)
        XCTAssertEqual(store.statistics(store.bank.questions).correct, 0)
        try store.savePractice(q.id, choices: q.answer)
        XCTAssertEqual(store.statistics(store.bank.questions).accuracy, "100%")
        XCTAssertTrue(store.visibleMistakes(.practice).isEmpty)
        let resumed = try makeStore(disk)
        XCTAssertEqual(resumed.state.practice[q.id]?.choices, q.answer)
        XCTAssertEqual(resumed.makeRoute(.practice(.single)).initialKey, q.id)
        try resumed.savePractice(q.id, choices: [])
        XCTAssertEqual(resumed.statistics(store.bank.questions).practiced, 0)
        XCTAssertEqual(resumed.statistics(store.bank.questions).accuracy, "—")
    }

    func testPracticeReviewAutoRemovalIsIndependent() throws {
        let store = try makeStore(); let q = store.bank.questions[0]
        try store.savePractice(q.id, choices: wrong(q)); let key = "practice:" + q.id
        try store.review(key, choices: q.answer)
        XCTAssertFalse(try XCTUnwrap(store.mistake(key)).dismissed)
        try store.setAutoRemove(.practice, enabled: true)
        XCTAssertFalse(try XCTUnwrap(store.mistake(key)).dismissed, "Enabling alone is not retroactive")
        try store.review(key, choices: q.answer)
        XCTAssertTrue(try XCTUnwrap(store.mistake(key)).dismissed)
        XCTAssertEqual(store.state.practice[q.id]?.choices, wrong(q))
        XCTAssertFalse(store.state.settings.autoRemoveExam)
    }

    func testShuffleStaysWithinPartsAndActiveExamResumes() throws {
        let disk = MemoryPersistence(); let store = try makeStore(disk)
        let exam = try store.startExam(.multiple)
        var offset = 0
        for group in store.bank.groups where group.type == .multiple {
            let expected = store.bank.questions.filter { $0.group == group.id }.map(\.id)
            let actual = Array(exam.order[offset..<(offset + expected.count)])
            XCTAssertEqual(Set(actual), Set(expected)); XCTAssertNotEqual(actual, expected)
            offset += expected.count
        }
        let q = try XCTUnwrap(store.questions[exam.order[3]])
        try store.saveExam(exam.id, qid: q.id, choices: [q.answer[0]], elapsed: 4)
        XCTAssertThrowsError(try store.submit(exam.id))
        let resumed = try makeStore(disk); let again = try resumed.startExam(.multiple)
        XCTAssertEqual(again.id, exam.id); XCTAssertEqual(again.order, exam.order)
        XCTAssertEqual(again.currentQuestion, q.id); XCTAssertEqual(again.elapsed, 4)
        XCTAssertEqual(again.answers[q.id], [q.answer[0]])
    }

    func complete(_ store: StudyStore, wrongFirst: Bool) throws -> ExamRecord {
        let exam = try store.startExam(.judge)
        for (index, id) in exam.order.enumerated() {
            let q = try XCTUnwrap(store.questions[id]); try store.saveExam(exam.id, qid: id, choices: index == 0 && wrongFirst ? wrong(q) : q.answer)
        }
        try store.submit(exam.id, elapsed: 3)
        return try XCTUnwrap(store.exam(exam.id))
    }

    func testSubmissionLocksAnswersAndNewAttemptKeepsOldMistakes() throws {
        let store = try makeStore(); let first = try complete(store, wrongFirst: true)
        XCTAssertEqual(first.status, .submitted); XCTAssertEqual(store.visibleMistakes(.exam).count, 1)
        let item = try XCTUnwrap(store.visibleMistakes(.exam).first)
        XCTAssertThrowsError(try store.saveExam(first.id, qid: item.qid, choices: []))
        try store.submit(first.id)
        XCTAssertEqual(store.visibleMistakes(.exam).count, 1, "Resubmission is idempotent")
        let second = try complete(store, wrongFirst: false)
        XCTAssertNotEqual(first.id, second.id); XCTAssertEqual(store.visibleMistakes(.exam).count, 1)
        XCTAssertEqual(store.visibleMistakes(.exam)[0].examID, first.id)
        try store.setAutoRemove(.exam, enabled: true)
        try store.review(item.id, choices: try XCTUnwrap(store.questions[item.qid]).answer)
        XCTAssertTrue(store.visibleMistakes(.exam).isEmpty)
        XCTAssertEqual(store.exam(first.id)?.answers, first.answers)
        let third = try store.startExam(.judge); XCTAssertTrue(third.answers.isEmpty)
    }

    func testDeleteSelectedExamsBacksUpAndPreservesOtherData() throws {
        let disk = MemoryPersistence(); let store = try makeStore(disk)
        let first = try complete(store, wrongFirst: true); let second = try store.startExam(.multiple)
        try store.savePractice("1", choices: ["A"])
        let before = store.state; try store.deleteExams([first.id])
        XCTAssertNil(store.exam(first.id)); XCTAssertNotNil(store.exam(second.id))
        XCTAssertEqual(store.state.practice, before.practice)
        XCTAssertTrue(store.state.mistakes.allSatisfy { $0.examID != first.id })
        let backup = try store.decodeImport(XCTUnwrap(disk.backups.last))
        XCTAssertEqual(backup.exams.count, 2)
        try store.restore(backup); XCTAssertNotNil(store.exam(first.id))
        try store.deleteExams([second.id]); XCTAssertNotEqual(try store.startExam(.multiple).id, second.id)
    }

    func testFailedWritesOrBackupNeverMutateState() throws {
        let disk = MemoryPersistence(); let store = try makeStore(disk)
        let exam = try store.startExam(.single); let before = store.state
        disk.failWrites = true
        XCTAssertThrowsError(try store.savePractice("1", choices: ["A"]))
        XCTAssertEqual(store.state, before)
        XCTAssertThrowsError(try store.deleteExams([exam.id])); XCTAssertEqual(store.state, before)
        disk.failWrites = false; disk.failBackups = true
        XCTAssertThrowsError(try store.deleteExams([exam.id])); XCTAssertEqual(store.state, before)
        disk.failBackups = false; try store.deleteExams([exam.id]); XCTAssertTrue(store.state.exams.isEmpty)
    }

    func testBackupValidationRejectsInvalidData() throws {
        let store = try makeStore(); var invalid = store.state
        invalid.bankID = "different"; XCTAssertThrowsError(try store.restore(invalid))
        invalid = store.state; invalid.practice["1"] = SavedAnswer(choices: ["A", "B"], updated: Date())
        XCTAssertThrowsError(try store.validate(invalid))
        invalid.practice = ["99999": SavedAnswer(choices: ["A"], updated: Date())]
        XCTAssertThrowsError(try store.validate(invalid))
        let exam = try store.startExam(.single); invalid = store.state; invalid.exams.append(exam)
        XCTAssertThrowsError(try store.validate(invalid))
        invalid = store.state; invalid.exams[0].order.removeLast(); XCTAssertThrowsError(try store.validate(invalid))
        XCTAssertThrowsError(try store.decodeImport(Data("not a backup".utf8)))
    }

    func testAutoAdvanceMatrix() {
        for kind in QuestionKind.allCases {
            for result in [AnswerResult.correct, .wrong, .partial, .unanswered] {
                XCTAssertEqual(shouldAdvance(mode: .practice(kind), kind: kind, result: result), result == .correct)
                XCTAssertEqual(shouldAdvance(mode: .exam("test"), kind: kind, result: result), kind != .multiple && result != .unanswered)
                XCTAssertEqual(shouldAdvance(mode: .review(.practice), kind: kind, result: result), kind != .multiple && result == .correct)
                XCTAssertEqual(shouldAdvance(mode: .review(.exam), kind: kind, result: result), kind != .multiple && result != .unanswered)
                XCTAssertFalse(shouldAdvance(mode: .exam("test"), kind: kind, result: result, submitted: true))
            }
        }
    }

    func testDiskRoundTripAndClockBounds() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = try DiskPersistence(directory: directory)
        let store = try StudyStore(bank: .load(), persistence: disk)
        let exam = try store.startExam(.single)
        try store.addExamTime(exam.id, seconds: 5); try store.addExamTime(exam.id, seconds: -5)
        try store.addExamTime(exam.id, seconds: 1000)
        XCTAssertEqual(store.exam(exam.id)?.elapsed, 20)
        let reopened = try StudyStore(bank: .load(), persistence: disk)
        XCTAssertEqual(reopened.exam(exam.id)?.elapsed, 20)
        XCTAssertEqual(try disk.listBackups().count, 1)
    }

    func testWindowsBackupImport() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite3")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE practice(qid TEXT,answer TEXT,updated TEXT);
        CREATE TABLE exams(id TEXT,type TEXT,status TEXT,ordering TEXT,answers TEXT,current_q TEXT,elapsed REAL,created TEXT,updated TEXT,submitted TEXT);
        CREATE TABLE mistakes(id TEXT,source TEXT,qid TEXT,exam_id TEXT,original TEXT,review TEXT,dismissed INTEGER,created TEXT,updated TEXT);
        CREATE TABLE settings(key TEXT,value TEXT);
        INSERT INTO practice VALUES('1','["C"]','2026-10-29T10:12:00+08:00');
        INSERT INTO settings VALUES('autoRemove:practice','true');
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        let store = try makeStore(); let imported = try WindowsBackupImporter.read(url: url, bankID: store.bank.id)
        try store.validate(imported); try store.restore(imported)
        XCTAssertEqual(store.state.practice["1"]?.choices, ["C"])
        XCTAssertTrue(store.state.settings.autoRemovePractice)
    }
}
