import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var store: StudyStore
    @State private var examMode = false
    @State private var path: [QuizRoute] = []
    @State private var problem: String?
    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    Picker("刷题模式", selection: $examMode) { Text("练习").tag(false); Text("考试").tag(true) }
                        .pickerStyle(.segmented).accessibilityIdentifier("study-mode")
                } header: { Text("公共与行业知识 · 2026 年 9 月") }
                Section {
                    ForEach(QuestionKind.allCases) { kind in
                        let stats = store.statistics(store.bank.questions(of: kind))
                        let active = store.state.exams.first { $0.type == kind && $0.status == .active }
                        Button {
                            do {
                                if examMode { let exam = try store.startExam(kind); path.append(store.makeRoute(.exam(exam.id))) }
                                else { path.append(store.makeRoute(.practice(kind))) }
                            } catch { problem = error.localizedDescription }
                        } label: {
                            HStack(spacing: 15) {
                                Image(systemName: kind.symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack { Text(kind.title).font(.headline).foregroundStyle(.primary); Spacer(); Text("\(stats.total) 题").font(.subheadline).foregroundStyle(.secondary) }
                                    Text(examMode ? (active.map { "继续考试 · 已答 \($0.answeredCount) 题" } ?? "开始新考试") : "已练习 \(stats.practiced) 题 · 答对 \(stats.correct) 题")
                                        .font(.subheadline).foregroundStyle(.secondary)
                                    ProgressView(value: Double(examMode ? (active?.answeredCount ?? 0) : stats.practiced), total: Double(stats.total)).tint(.accentColor)
                                }
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }.padding(.vertical, 12).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("start-" + kind.rawValue)
                    }
                } footer: { Text(examMode ? "每部分内随机出题，全部作答后交卷。" : "答对自动下一题，答案和进度随时保存。") }
            }.navigationTitle("华电题库")
                .navigationDestination(for: QuizRoute.self) { QuizView(route: $0) }
                .studyError($problem)
        }
    }
}

struct RecordsView: View {
    @EnvironmentObject private var store: StudyStore
    @State private var practiceTab = false
    @State private var filter = "all"
    @State private var editing = false
    @State private var selected: Set<String> = []
    @State private var expanded: Set<QuestionKind> = [.single]
    @State private var confirmDeletion = false
    @State private var problem: String?
    private var exams: [ExamRecord] { store.state.exams.filter { filter == "all" || $0.status.rawValue == filter }.sorted { $0.created > $1.created } }
    var body: some View {
        NavigationStack {
            List(selection: $selected) {
                Section {
                    Picker("记录类型", selection: $practiceTab) { Text("考试").tag(false); Text("练习").tag(true) }.pickerStyle(.segmented)
                }
                if practiceTab {
                    Section { StatisticsView(statistics: store.statistics(store.bank.questions)) }
                    ForEach(QuestionKind.allCases) { kind in
                        Section {
                            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(kind) }, set: { if $0 { expanded.insert(kind) } else { expanded.remove(kind) } })) {
                                ForEach(store.bank.groups.filter { $0.type == kind }) { group in
                                    VStack(alignment: .leading, spacing: 9) {
                                        Text(group.part + " · " + group.title).font(.subheadline.weight(.semibold))
                                        StatisticsView(statistics: store.statistics(store.bank.questions.filter { $0.group == group.id }))
                                    }.padding(.vertical, 5)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(kind.title, systemImage: kind.symbol).font(.headline)
                                    StatisticsView(statistics: store.statistics(store.bank.questions(of: kind)))
                                }.padding(.vertical, 5)
                            }
                        }
                    }
                    Section { Text("按普通练习的最新答案统计。正确率＝答对数÷已练习题数；错题复习不改变这些统计。").font(.footnote).foregroundStyle(.secondary) }
                } else {
                    Section {
                        Picker("考试状态", selection: $filter) { Text("全部").tag("all"); Text("未交卷").tag("active"); Text("已交卷").tag("submitted") }.pickerStyle(.segmented)
                    }
                    if exams.isEmpty {
                        ContentUnavailableView("暂无考试记录", systemImage: "doc.text", description: Text("开始考试后，进度会自动保留。"))
                    } else {
                        Section {
                            ForEach(exams) { exam in
                                Group {
                                    if editing { ExamRow(exam: exam) }
                                    else { NavigationLink(value: store.makeRoute(.exam(exam.id))) { ExamRow(exam: exam) } }
                                }.tag(exam.id).accessibilityIdentifier("exam-record-" + exam.id)
                            }
                        }
                    }
                }
            }.navigationTitle("做题记录")
                .environment(\.editMode, Binding(get: { editing ? .active : .inactive }, set: { editing = $0.isEditing }))
                .onChange(of: practiceTab) { _, _ in editing = false; selected.removeAll() }
                .onChange(of: filter) { _, _ in selected.removeAll() }
                .toolbar {
                    if !practiceTab {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(editing ? "完成" : "编辑") { editing.toggle(); selected.removeAll() }.disabled(store.state.exams.isEmpty && !editing)
                        }
                        if editing {
                            ToolbarItemGroup(placement: .bottomBar) {
                                Text("已选 \(selected.count) 场").font(.subheadline)
                                Spacer()
                                Button("删除", systemImage: "trash", role: .destructive) { confirmDeletion = true }.disabled(selected.isEmpty)
                            }
                        }
                    }
                }
                .alert("删除 \(selected.count) 场考试？", isPresented: $confirmDeletion) {
                    Button("取消", role: .cancel) { }
                    Button("删除", role: .destructive) {
                        do { try store.deleteExams(selected); selected.removeAll() } catch { problem = error.localizedDescription }
                    }
                } message: { Text("所选考试及对应考试错题会一起删除。删除前会自动备份，其他考试与练习记录不受影响。") }
                .navigationDestination(for: QuizRoute.self) { QuizView(route: $0) }
                .studyError($problem)
        }
    }
}

struct ExamRow: View {
    @EnvironmentObject private var store: StudyStore
    let exam: ExamRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(exam.type.title).font(.headline)
                Spacer()
                Text(exam.status == .submitted ? "已交卷" : "未交卷").font(.subheadline).foregroundStyle(.secondary)
            }
            Text(exam.created, format: .dateTime.month().day().hour().minute()).font(.subheadline).foregroundStyle(.secondary)
            if exam.status == .submitted {
                Text("答对 \(store.correctCount(exam)) / \(exam.order.count) · 用时 \(elapsedText(exam.elapsed))").font(.subheadline).monospacedDigit()
            } else { Text("已答 \(exam.answeredCount) / \(exam.order.count) · 继续作答").font(.subheadline).monospacedDigit() }
        }.padding(.vertical, 8).accessibilityElement(children: .combine)
    }
}

struct MistakesView: View {
    @EnvironmentObject private var store: StudyStore
    @State private var source: MistakeSource = .practice
    @State private var kind: QuestionKind?
    @State private var problem: String?
    private var entries: [MistakeEntry] { store.visibleMistakes(source, kind: kind) }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("错题来源", selection: $source) {
                        Text("练习 \(store.visibleMistakes(.practice).count)").tag(MistakeSource.practice)
                        Text("考试 \(store.visibleMistakes(.exam).count)").tag(MistakeSource.exam)
                    }.pickerStyle(.segmented)
                    Picker("题型", selection: $kind) { Text("全部").tag(QuestionKind?.none); ForEach(QuestionKind.allCases) { Text($0.shortTitle).tag(Optional($0)) } }.pickerStyle(.segmented)
                    Toggle("答对后自动移出", isOn: Binding(get: { store.state.settings.autoRemove(source) }, set: { enabled in
                        do { try store.setAutoRemove(source, enabled: enabled) } catch { problem = error.localizedDescription }
                    }))
                } footer: { Text(source == .practice ? "普通练习中改对会移出；这里复习答对时，由开关控制。" : "每场考试的错题分别保留；后续考试答对不会覆盖。") }
                if entries.isEmpty {
                    ContentUnavailableView("暂无错题", systemImage: "checkmark.seal", description: Text("继续练习，或切换分类查看。"))
                } else {
                    Section {
                        NavigationLink(value: store.makeRoute(.review(source), filter: kind)) { Label("开始复习 · \(entries.count) 题", systemImage: "play.fill").font(.headline) }
                    }
                    Section {
                        ForEach(entries) { entry in
                            if let question = store.questions[entry.qid] {
                                NavigationLink(value: store.makeRoute(.review(source), initial: entry.id, filter: kind)) {
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text("第 \(question.number) 题 · \(question.type.shortTitle)").font(.subheadline).foregroundStyle(.secondary)
                                        Text(question.text).font(.body).lineLimit(2)
                                        HStack {
                                            Text("原选 " + choiceText(entry.original)).font(.caption).foregroundStyle(.secondary)
                                            if question.result(for: entry.review) == .correct { ResultLabel(result: .correct) }
                                        }
                                        if let examID = entry.examID, let exam = store.exam(examID) { Text(exam.created, format: .dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary) }
                                    }.padding(.vertical, 6)
                                }
                            }
                        }
                    }
                }
            }.navigationTitle("错题集")
                .navigationDestination(for: QuizRoute.self) { QuizView(route: $0) }
                .studyError($problem)
        }
    }
}
