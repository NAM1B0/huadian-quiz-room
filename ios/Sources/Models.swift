import Foundation

enum QuestionKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case single, multiple, judge
    var id: String { rawValue }
    var title: String { switch self { case .single: "单选题"; case .multiple: "多选题"; case .judge: "判断题" } }
    var shortTitle: String { switch self { case .single: "单选"; case .multiple: "多选"; case .judge: "判断" } }
    var symbol: String { switch self { case .single: "circle.inset.filled"; case .multiple: "checkmark.square"; case .judge: "checkmark.circle" } }
}

struct QuestionOption: Codable, Identifiable, Equatable {
    let key: String
    let text: String
    var id: String { key }
}

struct Question: Codable, Identifiable {
    let id: String
    let number: Int
    let type: QuestionKind
    let group: String
    let subsection: String?
    let text: String
    let options: [QuestionOption]
    let answer: [String]
    let pdfPage: Int
    let pdfEndPage: Int
    let printedPage: Int

    func result(for choices: [String]) -> AnswerResult {
        if choices.isEmpty { return .unanswered }
        if Set(choices) == Set(answer) { return .correct }
        if type == .multiple && Set(choices).isSubset(of: Set(answer)) { return .partial }
        return .wrong
    }
}

struct QuestionGroup: Codable, Identifiable {
    let id: String
    let type: QuestionKind
    let part: String
    let title: String
    let count: Int
}

struct QuestionBank: Codable {
    let id: String
    let title: String
    let edition: String
    let total: Int
    let groups: [QuestionGroup]
    let questions: [Question]

    static func load(bundle: Bundle = .main) throws -> QuestionBank {
        guard let url = bundle.url(forResource: "bank", withExtension: "json") else {
            throw StudyError("题库文件缺失，请重新安装完整版本。")
        }
        let bank = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard bank.total == 563, bank.questions.count == 563,
              Set(bank.questions.map(\.id)).count == 563, bank.groups.count == 18 else {
            throw StudyError("题库校验失败，请重新安装完整版本。")
        }
        return bank
    }
    func questions(of type: QuestionKind) -> [Question] { questions.filter { $0.type == type } }
}

enum AnswerResult: String {
    case unanswered, correct, partial, wrong, answered
    var title: String {
        switch self { case .unanswered: "未答"; case .correct: "正确"; case .partial: "漏选"; case .wrong: "错误"; case .answered: "已答" }
    }
}

struct SavedAnswer: Codable, Equatable { var choices: [String]; var updated: Date }
enum ExamStatus: String, Codable, Hashable { case active, submitted }
struct ExamRecord: Codable, Identifiable, Equatable {
    var id: String
    var type: QuestionKind
    var status: ExamStatus
    var order: [String]
    var answers: [String: [String]]
    var currentQuestion: String
    var elapsed: TimeInterval
    var created: Date
    var updated: Date
    var submitted: Date?
    var answeredCount: Int { answers.values.filter { !$0.isEmpty }.count }
    var allAnswered: Bool { order.allSatisfy { !(answers[$0] ?? []).isEmpty } }
}

enum MistakeSource: String, Codable, CaseIterable, Identifiable, Hashable {
    case practice, exam
    var id: String { rawValue }
    var title: String { self == .practice ? "练习错题" : "考试错题" }
}

struct MistakeEntry: Codable, Identifiable, Equatable {
    var id: String
    var source: MistakeSource
    var qid: String
    var examID: String?
    var original: [String]
    var review: [String]
    var dismissed: Bool
    var created: Date
    var updated: Date
}

struct StudySettings: Codable, Equatable {
    var autoRemovePractice = false
    var autoRemoveExam = false
    func autoRemove(_ source: MistakeSource) -> Bool { source == .practice ? autoRemovePractice : autoRemoveExam }
}

struct StudyState: Codable, Equatable {
    var schemaVersion = 1
    var bankID: String
    var practice: [String: SavedAnswer] = [:]
    var exams: [ExamRecord] = []
    var mistakes: [MistakeEntry] = []
    var settings = StudySettings()
    var lastPracticeQuestion: [String: String] = [:]
}

struct PracticeStatistics {
    let total: Int
    let practiced: Int
    let correct: Int
    var accuracy: String {
        guard practiced > 0 else { return "—" }
        let percent = Double(correct) / Double(practiced) * 100
        return percent.rounded() == percent ? String(format: "%.0f%%", percent) : String(format: "%.1f%%", percent)
    }
}

enum QuizMode: Hashable {
    case practice(QuestionKind)
    case exam(String)
    case review(MistakeSource)
}

struct QuizRoute: Identifiable, Hashable {
    let id = UUID()
    var mode: QuizMode
    var keys: [String]
    var initialKey: String?
}

struct StudyError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

func choiceText(_ choices: [String]) -> String { choices.isEmpty ? "未答" : choices.joined(separator: "、") }
func elapsedText(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds))
    return s >= 3600 ? String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}

func shouldAdvance(mode: QuizMode, kind: QuestionKind, result: AnswerResult, submitted: Bool = false) -> Bool {
    guard result != .unanswered, !submitted else { return false }
    switch mode {
    case .practice: return result == .correct
    case .exam: return kind != .multiple
    case .review(.practice): return kind != .multiple && result == .correct
    case .review(.exam): return kind != .multiple
    }
}
