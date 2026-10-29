import SwiftUI
import Combine

struct QuizView: View {
    let route: QuizRoute
    @EnvironmentObject private var store: StudyStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @State private var key: String
    @State private var showAnswers = false
    @State private var board = false
    @State private var pdf = false
    @State private var confirmSubmit = false
    @State private var problem: String?
    @State private var pending: Task<Void, Never>?
    @State private var tickStart: TimeInterval?
    @State private var liveSeconds: TimeInterval = 0
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(route: QuizRoute) {
        self.route = route
        _key = State(initialValue: route.initialKey.flatMap { route.keys.contains($0) ? $0 : nil } ?? route.keys.first ?? "")
    }
    private var exam: ExamRecord? { if case .exam(let id) = route.mode { return store.exam(id) }; return nil }
    private var review: MistakeEntry? { if case .review = route.mode { return store.mistake(key) }; return nil }
    private var question: Question? {
        if case .exam = route.mode, exam == nil { return nil }
        return store.questions[review?.qid ?? key]
    }
    private var activeExam: Bool { exam?.status == .active }
    private var locked: Bool { exam?.status == .submitted || review?.dismissed == true }
    private var canPreview: Bool {
        switch route.mode { case .practice, .review(.practice): true; default: false }
    }
    private var choices: [String] { answer(for: key) }
    private var position: Int { (route.keys.firstIndex(of: key) ?? 0) + 1 }
    private var title: String {
        switch route.mode {
        case .practice(let kind): return kind.title + "练习"
        case .exam: return (exam?.type.shortTitle ?? "") + (activeExam ? "考试" : "考试回顾")
        case .review(let source): return source.title
        }
    }

    var body: some View {
        Group {
            if let question { questionPage(question) }
            else { ContentUnavailableView("题目已不存在", systemImage: "doc.questionmark", description: Text("请返回题库重新进入。")) }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if let exam {
                ToolbarItem(placement: .topBarTrailing) {
                    Text(elapsedText(exam.elapsed + liveSeconds)).font(.caption).monospacedDigit()
                        .accessibilityLabel("累计用时 " + elapsedText(exam.elapsed + liveSeconds))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !activeExam { Button("查看题库原文", systemImage: "doc.richtext") { cancelAdvance(); pdf = true } }
                    if !locked { Button("清空本题选择", systemImage: "eraser") { save([]) }.disabled(choices.isEmpty) }
                    if activeExam { Button("交卷", systemImage: "checkmark.seal") { cancelAdvance(); confirmSubmit = true }.disabled(exam?.allAnswered != true) }
                } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("更多操作")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { navigationBar }
        .sheet(isPresented: $board) {
            QuestionBoard(items: boardItems, groups: store.bank.groups, current: key, activeExam: activeExam,
                          canSubmit: exam?.allAnswered == true, choose: { jump($0); board = false }, submit: { board = false; confirmSubmit = true })
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $pdf) { PDFScreen(page: question?.pdfPage ?? 40) }
        .alert("确认交卷？", isPresented: $confirmSubmit) {
            Button("继续检查", role: .cancel) { }
            Button("交卷") { submit() }
        } message: { Text("交卷后显示成绩和正确答案，本场答案将不能再修改。") }
        .studyError($problem)
        .onAppear { startClock() }
        .onDisappear { cancelAdvance(); flushClock(); tickStart = nil; liveSeconds = 0 }
        .onChange(of: scene) { _, next in
            if next == .active { startClock() } else { cancelAdvance(); flushClock(); tickStart = nil; liveSeconds = 0 }
        }
        .onChange(of: pdf) { _, visible in
            if visible { flushClock(); tickStart = nil; liveSeconds = 0 } else { startClock() }
        }
        .onReceive(ticker) { _ in
            guard activeExam, scene == .active, let start = tickStart else { return }
            liveSeconds = max(0, ProcessInfo.processInfo.systemUptime - start)
            if liveSeconds >= 5 { flushClock() }
        }
    }

    private func questionPage(_ q: Question) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(groupTitle(q)).font(.subheadline).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline) {
                        Text("第 \(q.number) 题 · \(q.type.shortTitle)").font(.headline).accessibilityIdentifier("question-number")
                        Spacer(minLength: 8)
                        Text("\(position) / \(route.keys.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if let subsection = q.subsection, !subsection.isEmpty { Text(subsection).font(.caption).foregroundStyle(.secondary) }
                }
                if canPreview {
                    Toggle("显示整套正确答案", isOn: $showAnswers).font(.subheadline).accessibilityIdentifier("show-answers")
                }
                if case .review(let source) = route.mode {
                    DisclosureGroup("复习设置") {
                        Toggle("答对后自动移出", isOn: Binding(get: { store.state.settings.autoRemove(source) }, set: { enabled in
                            do { try store.setAutoRemove(source, enabled: enabled) } catch { problem = error.localizedDescription }
                        })).padding(.top, 8)
                    }.font(.subheadline)
                }
                if let exam, exam.status == .submitted {
                    Label("已交卷 · 答对 \(store.correctCount(exam)) / \(exam.order.count)", systemImage: "checkmark.seal")
                        .font(.subheadline.weight(.semibold)).padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                Text(q.text).font(.title3).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled).accessibilityIdentifier("question-text")
                VStack(spacing: 12) { ForEach(q.options) { option in optionButton(option, question: q) } }
                if activeExam {
                    if q.type == .multiple { Text("选好后，点击“下一题”。").font(.footnote).foregroundStyle(.secondary) }
                    if exam?.allAnswered == true {
                        Button("全部已答 · 交卷") { cancelAdvance(); confirmSubmit = true }
                            .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                    }
                } else if showAnswers || !choices.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        if !choices.isEmpty { ResultLabel(result: q.result(for: choices)).accessibilityIdentifier("answer-result") }
                        Text("正确答案：" + choiceText(q.answer)).font(.headline).accessibilityIdentifier("correct-answer")
                        if let review { Text("原选择：" + choiceText(review.original)).font(.subheadline).foregroundStyle(.secondary) }
                        if review?.dismissed == true { Label("已从错题集移出", systemImage: "checkmark").font(.subheadline) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                if position == route.keys.count && !activeExam {
                    Text("已到最后一题，可打开题号检查其他题目。").font(.footnote).foregroundStyle(.secondary)
                }
            }.padding(20).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
        }.id(key).background(Color(.systemBackground))
    }

    private func optionButton(_ option: QuestionOption, question q: Question) -> some View {
        let selected = choices.contains(option.key)
        let reveal = !activeExam && (showAnswers || !choices.isEmpty)
        let correctOption = reveal && q.answer.contains(option.key)
        let wrongOption = reveal && selected && !q.answer.contains(option.key)
        let stroke: Color = correctOption ? .green : wrongOption ? .red : selected ? .accentColor : Color(.separator)
        return Button {
            var next = choices
            if q.type == .multiple {
                if next.contains(option.key) { next.removeAll { $0 == option.key } } else { next.append(option.key) }
            } else { next = [option.key] }
            save(next)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: q.type == .multiple ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary).frame(width: 24).padding(.top, 1)
                Text(option.key).font(.body.weight(.semibold)).frame(minWidth: 16)
                Text(option.text).font(.body).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                if correctOption || wrongOption { Image(systemName: correctOption ? "checkmark" : "xmark").font(.caption.weight(.bold)).foregroundStyle(stroke) }
            }.foregroundStyle(.primary).padding(16).frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .background(selected ? Color.accentColor.opacity(0.07) : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(stroke, lineWidth: selected || correctOption ? 2 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(locked).accessibilityIdentifier("option-" + option.key)
            .accessibilityLabel(option.key + "，" + option.text + (selected ? "，已选择" : "") + (correctOption ? "，正确选项" : ""))
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var navigationBar: some View {
        HStack(spacing: 8) {
            Button { move(-1) } label: { Label("上一题", systemImage: "chevron.left").labelStyle(.titleOnly).frame(maxWidth: .infinity, minHeight: 44) }
                .disabled(neighbor(-1) == nil).accessibilityIdentifier("previous-question")
            Button { cancelAdvance(); board = true } label: { Label("题号", systemImage: "square.grid.3x3").frame(maxWidth: .infinity, minHeight: 44) }
                .accessibilityIdentifier("question-board")
            Button { move(1) } label: { Label("下一题", systemImage: "chevron.right").labelStyle(.titleOnly).frame(maxWidth: .infinity, minHeight: 44) }
                .disabled(neighbor(1) == nil).accessibilityIdentifier("next-question")
        }.font(.subheadline.weight(.semibold)).buttonStyle(.bordered).padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
    }

    private func groupTitle(_ q: Question) -> String {
        store.bank.groups.first { $0.id == q.group }.map { $0.part + " · " + $0.title } ?? q.group
    }
    private func answer(for item: String) -> [String] {
        switch route.mode {
        case .practice: return store.state.practice[item]?.choices ?? []
        case .exam: return exam?.answers[item] ?? []
        case .review: return store.mistake(item)?.review ?? []
        }
    }
    private var boardItems: [BoardItem] {
        route.keys.compactMap { item in
            let mistake: MistakeEntry? = { if case .review = route.mode { return store.mistake(item) }; return nil }()
            guard mistake?.dismissed != true, let q = store.questions[mistake?.qid ?? item] else { return nil }
            let selected = answer(for: item)
            return BoardItem(id: item, question: q, result: activeExam && !selected.isEmpty ? .answered : q.result(for: selected))
        }
    }
    private func neighbor(_ direction: Int) -> String? {
        guard let index = route.keys.firstIndex(of: key) else { return nil }
        var candidate = index + direction
        while route.keys.indices.contains(candidate) {
            let item = route.keys[candidate]
            if case .review = route.mode {
                if store.mistake(item)?.dismissed == false { return item }
            } else { return item }
            candidate += direction
        }
        return nil
    }
    private func cancelAdvance() { pending?.cancel(); pending = nil }
    private func move(_ direction: Int) { cancelAdvance(); if let next = neighbor(direction) { jump(next) } }
    private func jump(_ next: String) {
        cancelAdvance()
        guard route.keys.contains(next) else { return }
        do {
            switch route.mode {
            case .practice(let kind): try store.rememberPractice(next, kind: kind)
            case .exam(let id): try store.positionExam(id, qid: next)
            case .review: break
            }
            key = next
        } catch { problem = error.localizedDescription }
    }
    private func save(_ next: [String]) {
        cancelAdvance()
        guard !locked, let q = question else { return }
        do {
            switch route.mode {
            case .practice: try store.savePractice(q.id, choices: next)
            case .exam(let id): try store.saveExam(id, qid: q.id, choices: next, elapsed: clockDelta); resetClock()
            case .review: try store.review(key, choices: next)
            }
            if shouldAdvance(mode: route.mode, kind: q.type, result: q.result(for: next), submitted: exam?.status == .submitted) {
                let savedKey = key
                pending = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(650))
                    guard !Task.isCancelled, key == savedKey, scene == .active else { return }
                    if let next = neighbor(1) { jump(next) }
                    else if review?.dismissed == true { dismiss() }
                }
            }
        } catch { problem = error.localizedDescription }
    }
    private var clockDelta: TimeInterval { tickStart.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? 0 }
    private func startClock() { if activeExam && scene == .active && !pdf && tickStart == nil { tickStart = ProcessInfo.processInfo.systemUptime } }
    private func resetClock() { tickStart = activeExam && scene == .active && !pdf ? ProcessInfo.processInfo.systemUptime : nil; liveSeconds = 0 }
    private func flushClock() {
        guard let exam, activeExam, tickStart != nil else { return }
        do { try store.addExamTime(exam.id, seconds: clockDelta); resetClock() } catch { problem = error.localizedDescription }
    }
    private func submit() {
        guard let exam else { return }
        cancelAdvance()
        do { try store.submit(exam.id, elapsed: clockDelta); tickStart = nil; liveSeconds = 0 }
        catch { problem = error.localizedDescription }
    }
}

struct BoardItem: Identifiable { let id: String; let question: Question; let result: AnswerResult }

struct QuestionBoard: View {
    let items: [BoardItem]
    let groups: [QuestionGroup]
    let current: String
    let activeExam: Bool
    let canSubmit: Bool
    let choose: (String) -> Void
    let submit: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    @State private var search = ""
    private var filtered: [BoardItem] { search.isEmpty ? items : items.filter { String($0.question.number) == search } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack {
                        TextField("输入原题号", text: $search).keyboardType(.numberPad).textFieldStyle(.roundedBorder).frame(minHeight: 44).accessibilityIdentifier("jump-number")
                        if let unanswered = items.first(where: { $0.result == .unanswered }) {
                            Button("去未答") { choose(unanswered.id) }.frame(minHeight: 44).font(.subheadline)
                        }
                    }
                    HStack(spacing: 14) {
                        if activeExam { ResultLabel(result: .answered); ResultLabel(result: .unanswered) }
                        else { ResultLabel(result: .correct); ResultLabel(result: .wrong); ResultLabel(result: .partial) }
                    }.accessibilityElement(children: .combine)
                    ForEach(groups) { group in
                        let members = filtered.filter { $0.question.group == group.id }
                        if !members.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(group.type.shortTitle + " · " + group.part + " · " + group.title).font(.headline)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: textSize.isAccessibilitySize ? 76 : 48), spacing: 10)], spacing: 10) {
                                    ForEach(members) { item in
                                        Button { choose(item.id) } label: {
                                            VStack(spacing: 3) {
                                                Text(String(item.question.number)).font(.subheadline.weight(.semibold)).monospacedDigit()
                                                Image(systemName: item.result.symbol).font(.caption2).foregroundStyle(item.result.color)
                                            }.frame(maxWidth: .infinity, minHeight: 48).padding(.vertical, 2)
                                                .foregroundStyle(.primary)
                                                .background(item.result.color.opacity(item.result == .unanswered ? 0.06 : 0.15), in: RoundedRectangle(cornerRadius: 10))
                                                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(item.id == current ? Color.accentColor : .clear, lineWidth: 2))
                                        }.buttonStyle(.plain).accessibilityLabel("第 \(item.question.number) 题，\(item.result.title)" + (item.id == current ? "，当前题目" : ""))
                                            .accessibilityIdentifier("board-" + item.id)
                                    }
                                }
                            }
                        }
                    }
                    if filtered.isEmpty { Text("未找到这个题号").foregroundStyle(.secondary) }
                    if activeExam {
                        Button(canSubmit ? "全部已答 · 交卷" : "还有 \(items.filter { $0.result == .unanswered }.count) 题未答", action: submit)
                            .buttonStyle(.borderedProminent).controlSize(.large).disabled(!canSubmit).frame(maxWidth: .infinity)
                    }
                }.padding(20)
            }.navigationTitle("题号").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
