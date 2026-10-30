import Foundation
import Combine

struct LocalBackup: Identifiable {
    let url: URL
    var id: String { url.lastPathComponent }
    var title: String { url.deletingPathExtension().lastPathComponent }
}

protocol StudyPersistence {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func backup(_ data: Data, reason: String) throws
    func listBackups() throws -> [LocalBackup]
    func readBackup(_ backup: LocalBackup) throws -> Data
}

final class DiskPersistence: StudyPersistence {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("study.json") }
    private var backupDirectory: URL { directory.appendingPathComponent("Backups", isDirectory: true) }

    init(directory: URL? = nil) throws {
        self.directory = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("HuadianQuiz", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
    }
    func read() throws -> Data? {
        FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
    }
    func write(_ data: Data) throws {
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func backup(_ data: Data, reason: String) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = reason == "每日备份" ? "yyyy-MM-dd" : "yyyy-MM-dd-HHmmss"
        let suffix = reason == "每日备份" ? "" : "-" + UUID().uuidString.prefix(6)
        let url = backupDirectory.appendingPathComponent(formatter.string(from: Date()) + "-" + reason + suffix + ".json")
        if reason == "每日备份", FileManager.default.fileExists(atPath: url.path) { return }
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func listBackups() throws -> [LocalBackup] {
        try FileManager.default.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }.map(LocalBackup.init)
    }
    func readBackup(_ backup: LocalBackup) throws -> Data {
        guard backup.url.deletingLastPathComponent().standardizedFileURL == backupDirectory.standardizedFileURL else { throw StudyError("备份位置无效。") }
        return try Data(contentsOf: backup.url)
    }
}

@MainActor
final class StudyStore: ObservableObject {
    let bank: QuestionBank
    let questions: [String: Question]
    let persistence: StudyPersistence
    @Published private(set) var state: StudyState
    @Published private(set) var sessionGeneration = UUID()

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
    }
    init(bank: QuestionBank, persistence: StudyPersistence) throws {
        self.bank = bank; self.questions = Dictionary(uniqueKeysWithValues: bank.questions.map { ($0.id, $0) }); self.persistence = persistence
        if let bytes = try persistence.read() {
            state = try Self.decoder().decode(StudyState.self, from: bytes)
            try validate(state)
            try persistence.backup(bytes, reason: "每日备份")
        } else { state = StudyState(bankID: bank.id) }
    }
    func validated(_ choices: [String], qid: String) throws -> [String] {
        guard let question = questions[qid], Set(choices).count == choices.count,
              Set(choices).isSubset(of: Set(question.options.map(\.key))),
              question.type == .multiple || choices.count <= 1 else { throw StudyError("题号或选项无效，请重新选择。") }
        return choices.sorted()
    }
    func validate(_ candidate: StudyState) throws {
        guard candidate.schemaVersion == 1, candidate.bankID == bank.id else { throw StudyError("备份格式或题库版本不匹配。") }
        for (qid, saved) in candidate.practice { _ = try validated(saved.choices, qid: qid) }
        guard Set(candidate.exams.map(\.id)).count == candidate.exams.count,
              Set(candidate.mistakes.map(\.id)).count == candidate.mistakes.count else { throw StudyError("备份包含重复记录。") }
        for kind in QuestionKind.allCases {
            guard candidate.exams.filter({ $0.type == kind && $0.status == .active }).count <= 1 else { throw StudyError("同一题型不能有多套未交卷考试。") }
        }
        for exam in candidate.exams {
            let expected = Set(bank.questions(of: exam.type).map(\.id))
            guard !exam.id.isEmpty, exam.order.count == expected.count, Set(exam.order) == expected,
                  expected.contains(exam.currentQuestion), exam.elapsed.isFinite, exam.elapsed >= 0 else { throw StudyError("考试记录不完整，未导入。") }
            for (qid, choices) in exam.answers {
                guard expected.contains(qid) else { throw StudyError("考试中存在其他题型。") }
                _ = try validated(choices, qid: qid)
            }
            if exam.status == .submitted && (!exam.allAnswered || exam.submitted == nil) { throw StudyError("已交卷记录缺少答案或交卷时间。") }
        }
        for item in candidate.mistakes {
            _ = try validated(item.original, qid: item.qid); _ = try validated(item.review, qid: item.qid)
            if item.source == .exam && !candidate.exams.contains(where: { $0.id == item.examID && $0.status == .submitted && $0.order.contains(item.qid) }) { throw StudyError("错题缺少对应的考试记录。") }
        }
        for (kind, qid) in candidate.lastPracticeQuestion {
            guard questions[qid]?.type.rawValue == kind else { throw StudyError("练习位置无效。") }
        }
    }
    private func commit(_ next: StudyState, backupReason: String? = nil) throws {
        try validate(next)
        let bytes = try Self.encoder().encode(next)
        if let reason = backupReason { try persistence.backup(export(), reason: reason) }
        try persistence.write(bytes)
        state = next
    }
    func export() throws -> Data { try Self.encoder().encode(state) }
    func decodeImport(_ bytes: Data) throws -> StudyState {
        guard bytes.count <= 50_000_000 else { throw StudyError("备份超过 50 MB，请先检查文件是否正确。") }
        let imported = try Self.decoder().decode(StudyState.self, from: bytes)
        try validate(imported); return imported
    }
    func restore(_ imported: StudyState) throws {
        try commit(imported, backupReason: "恢复前")
        sessionGeneration = UUID()
    }
    func exam(_ id: String) -> ExamRecord? { state.exams.first { $0.id == id } }
    func mistake(_ id: String) -> MistakeEntry? { state.mistakes.first { $0.id == id } }
    func practiceResult(_ qid: String) -> AnswerResult {
        guard let saved = state.practice[qid], !saved.choices.isEmpty else { return .unanswered }
        return saved.isChecked ? questions[qid]?.result(for: saved.choices) ?? .unanswered : .pending
    }
    func reviewResult(_ id: String) -> AnswerResult {
        guard let item = mistake(id), !item.review.isEmpty else { return .unanswered }
        return item.isReviewChecked ? questions[item.qid]?.result(for: item.review) ?? .unanswered : .pending
    }
    func statistics(_ list: [Question]) -> PracticeStatistics {
        let practiced = list.filter { state.practice[$0.id]?.isChecked == true }
        let correct = practiced.filter { $0.result(for: state.practice[$0.id]?.choices ?? []) == .correct }.count
        return PracticeStatistics(total: list.count, practiced: practiced.count, correct: correct)
    }
    func correctCount(_ exam: ExamRecord) -> Int { exam.order.filter { questions[$0]?.result(for: exam.answers[$0] ?? []) == .correct }.count }
    func visibleMistakes(_ source: MistakeSource, kind: QuestionKind? = nil) -> [MistakeEntry] {
        state.mistakes.filter { !$0.dismissed && $0.source == source && (kind == nil || questions[$0.qid]?.type == kind) }
            .sorted { $0.created == $1.created ? (Int($0.qid) ?? 0) < (Int($1.qid) ?? 0) : $0.created > $1.created }
    }
    func savePractice(_ qid: String, choices: [String], check: Bool = false) throws {
        let answer = try validated(choices, qid: qid)
        let result = questions[qid]?.result(for: answer)
        let checked = !answer.isEmpty && (questions[qid]?.type != .multiple || check || result == .correct)
        if (state.practice[qid]?.choices ?? []) == answer && (answer.isEmpty || state.practice[qid]?.isChecked == checked) { return }
        var next = state; let stamp = Date(); let key = "practice:" + qid
        if answer.isEmpty { next.practice.removeValue(forKey: qid) }
        else { next.practice[qid] = SavedAnswer(choices: answer, updated: stamp, checked: checked) }
        if checked && result != .correct {
            if let index = next.mistakes.firstIndex(where: { $0.id == key }) {
                next.mistakes[index].original = answer; next.mistakes[index].review = []
                next.mistakes[index].reviewChecked = false
                next.mistakes[index].dismissed = false; next.mistakes[index].updated = stamp
            } else { next.mistakes.append(MistakeEntry(id: key, source: .practice, qid: qid, original: answer, review: [], dismissed: false, created: stamp, updated: stamp)) }
        } else if answer.isEmpty || (checked && result == .correct) {
            if let index = next.mistakes.firstIndex(where: { $0.id == key }) { next.mistakes[index].dismissed = true; next.mistakes[index].updated = stamp }
        }
        if let kind = questions[qid]?.type { next.lastPracticeQuestion[kind.rawValue] = qid }
        try commit(next)
    }
    func rememberPractice(_ qid: String, kind: QuestionKind) throws {
        guard questions[qid]?.type == kind else { throw StudyError("练习题号无效。") }
        if state.lastPracticeQuestion[kind.rawValue] == qid { return }
        var next = state; next.lastPracticeQuestion[kind.rawValue] = qid; try commit(next)
    }
    func startExam(_ kind: QuestionKind) throws -> ExamRecord {
        if let existing = state.exams.first(where: { $0.type == kind && $0.status == .active }) { return existing }
        var order: [String] = []
        for group in bank.groups where group.type == kind {
            let original = bank.questions.filter { $0.group == group.id }.map(\.id)
            var shuffled = original.shuffled()
            if shuffled == original && shuffled.count > 1 { shuffled.append(shuffled.removeFirst()) }
            order += shuffled
        }
        let stamp = Date()
        let exam = ExamRecord(id: UUID().uuidString.lowercased(), type: kind, status: .active, order: order, answers: [:], currentQuestion: order[0], elapsed: 0, created: stamp, updated: stamp)
        var next = state; next.exams.insert(exam, at: 0); try commit(next); return exam
    }
    func saveExam(_ id: String, qid: String, choices: [String], elapsed: TimeInterval = 0) throws {
        let answer = try validated(choices, qid: qid)
        guard let index = state.exams.firstIndex(where: { $0.id == id }), state.exams[index].status == .active,
              state.exams[index].order.contains(qid) else { throw StudyError("考试已交卷或不存在，不能修改答案。") }
        var next = state
        if answer.isEmpty { next.exams[index].answers.removeValue(forKey: qid) } else { next.exams[index].answers[qid] = answer }
        next.exams[index].elapsed += max(0, min(elapsed, 15)); next.exams[index].currentQuestion = qid; next.exams[index].updated = Date()
        try commit(next)
    }
    func positionExam(_ id: String, qid: String) throws {
        guard let index = state.exams.firstIndex(where: { $0.id == id }), state.exams[index].order.contains(qid) else { throw StudyError("考试记录不存在。") }
        if state.exams[index].status != .active || state.exams[index].currentQuestion == qid { return }
        var next = state; next.exams[index].currentQuestion = qid; try commit(next)
    }
    func addExamTime(_ id: String, seconds: TimeInterval) throws {
        guard let index = state.exams.firstIndex(where: { $0.id == id }), state.exams[index].status == .active, seconds > 0 else { return }
        var next = state; next.exams[index].elapsed += min(seconds, 15); try commit(next)
    }
    func submit(_ id: String, elapsed: TimeInterval = 0) throws {
        guard let index = state.exams.firstIndex(where: { $0.id == id }) else { throw StudyError("考试记录不存在。") }
        if state.exams[index].status == .submitted { return }
        guard state.exams[index].allAnswered else { throw StudyError("请完成全部题目后再交卷。") }
        var next = state; let stamp = Date(); let exam = next.exams[index]
        next.exams[index].status = .submitted; next.exams[index].submitted = stamp; next.exams[index].updated = stamp
        next.exams[index].elapsed += max(0, min(elapsed, 15))
        for qid in exam.order where questions[qid]?.result(for: exam.answers[qid] ?? []) != .correct {
            next.mistakes.append(MistakeEntry(id: "exam:" + id + ":" + qid, source: .exam, qid: qid, examID: id, original: exam.answers[qid] ?? [], review: [], dismissed: false, created: stamp, updated: stamp))
        }
        try commit(next)
    }
    @discardableResult
    func review(_ id: String, choices: [String], check: Bool = false) throws -> MistakeEntry {
        guard let index = state.mistakes.firstIndex(where: { $0.id == id && !$0.dismissed }) else { throw StudyError("这条错题已移出，请返回错题集。") }
        let item = state.mistakes[index]; let answer = try validated(choices, qid: item.qid)
        var next = state; next.mistakes[index].review = answer; next.mistakes[index].updated = Date()
        let checked = !answer.isEmpty && (questions[item.qid]?.type != .multiple || check)
        next.mistakes[index].reviewChecked = checked
        next.mistakes[index].dismissed = checked && questions[item.qid]?.result(for: answer) == .correct && state.settings.autoRemove(item.source)
        try commit(next); return next.mistakes[index]
    }
    func setAutoRemove(_ source: MistakeSource, enabled: Bool) throws {
        var next = state
        if source == .practice { next.settings.autoRemovePractice = enabled } else { next.settings.autoRemoveExam = enabled }
        try commit(next)
    }
    func deleteExams(_ ids: Set<String>) throws {
        guard state.exams.contains(where: { ids.contains($0.id) }) else { return }
        var next = state; next.exams.removeAll { ids.contains($0.id) }
        next.mistakes.removeAll { $0.examID.map(ids.contains) ?? false }
        try commit(next, backupReason: "删除考试前")
    }
    func makeRoute(_ mode: QuizMode, initial: String? = nil, filter: QuestionKind? = nil) -> QuizRoute {
        switch mode {
        case .practice(let kind):
            return QuizRoute(mode: mode, keys: bank.questions(of: kind).map(\.id), initialKey: initial ?? state.lastPracticeQuestion[kind.rawValue])
        case .exam(let id):
            return QuizRoute(mode: mode, keys: exam(id)?.order ?? [], initialKey: initial ?? exam(id)?.currentQuestion)
        case .review(let source):
            return QuizRoute(mode: mode, keys: visibleMistakes(source, kind: filter).map(\.id), initialKey: initial)
        }
    }
}
