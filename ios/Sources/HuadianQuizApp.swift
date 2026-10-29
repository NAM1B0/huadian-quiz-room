import SwiftUI

@main
struct HuadianQuizApp: App {
    var body: some Scene { WindowGroup { AppLoader() } }
}

@MainActor
struct AppLoader: View {
    @State private var store: StudyStore?
    @State private var problem: String?
    var body: some View {
        Group {
            if let store { MainTabs().environmentObject(store) }
            else if let problem {
                ContentUnavailableView {
                    Label("暂时无法打开", systemImage: "exclamationmark.triangle")
                } description: { Text(problem + "\n原记录不会被自动清空。") }
                actions: { Button("重试", action: load).buttonStyle(.borderedProminent) }
            } else { ProgressView("正在读取题库…") }
        }.task { if store == nil { load() } }
        #if DEBUG
        .preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--dark") ? .dark : nil)
        .dynamicTypeSize(ProcessInfo.processInfo.arguments.contains("--large-text") ? .accessibility3 : .large)
        #endif
    }
    private func load() {
        do {
            let bank = try QuestionBank.load()
            var directory: URL?
            #if DEBUG
            if let session = ProcessInfo.processInfo.environment["HUADIAN_TEST_SESSION"], UUID(uuidString: session) != nil {
                directory = FileManager.default.temporaryDirectory.appendingPathComponent("UITest-" + session, isDirectory: true)
            }
            #endif
            let loaded = try StudyStore(bank: bank, persistence: DiskPersistence(directory: directory))
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--fixture"), loaded.state.practice.isEmpty, loaded.state.exams.isEmpty {
                try loaded.savePractice("1", choices: ["A"])
                try loaded.savePractice("2", choices: bank.questions.first { $0.id == "2" }!.answer)
                _ = try loaded.startExam(.multiple)
            }
            if ProcessInfo.processInfo.arguments.contains("--exam-fixture"), loaded.state.exams.isEmpty {
                let exam = try loaded.startExam(.judge)
                for qid in exam.order { try loaded.saveExam(exam.id, qid: qid, choices: loaded.questions[qid]!.answer) }
            }
            #endif
            store = loaded; problem = nil
        } catch { problem = error.localizedDescription }
    }
}

struct MainTabs: View {
    @EnvironmentObject private var store: StudyStore
    var body: some View {
        TabView {
            Tab("题库", systemImage: "books.vertical") { LibraryView() }
            Tab("记录", systemImage: "list.bullet.clipboard") { RecordsView() }
            Tab("错题", systemImage: "bookmark") { MistakesView() }
            Tab("数据", systemImage: "externaldrive") { DataView() }
        }.tint(.accentColor).id(store.sessionGeneration)
    }
}

extension View {
    func studyError(_ error: Binding<String?>) -> some View {
        alert("操作未完成", isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } })) {
            Button("知道了", role: .cancel) { error.wrappedValue = nil }
        } message: { Text(error.wrappedValue ?? "") }
    }
}

extension AnswerResult {
    var color: Color {
        switch self { case .correct: .green; case .wrong: .red; case .partial: .gray; case .answered: .blue; case .unanswered: Color(.tertiaryLabel) }
    }
    var symbol: String {
        switch self { case .correct: "checkmark.circle.fill"; case .wrong: "xmark.circle.fill"; case .partial: "minus.circle.fill"; case .answered: "circle.inset.filled"; case .unanswered: "circle" }
    }
}

struct ResultLabel: View {
    let result: AnswerResult
    var body: some View {
        HStack(spacing: 5) { Image(systemName: result.symbol).foregroundStyle(result.color); Text(result.title) }
            .font(.caption).accessibilityElement(children: .combine)
    }
}

struct StatisticsView: View {
    let statistics: PracticeStatistics
    @Environment(\.dynamicTypeSize) private var size
    var body: some View {
        let layout = size.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(alignment: .top, spacing: 14))
        layout {
            stat("已练习 / 总题数", "\(statistics.practiced) / \(statistics.total)")
            stat("当前答对", "\(statistics.correct)")
            stat("正确率", statistics.accuracy)
        }.padding(.vertical, 6)
    }
    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
    }
}
