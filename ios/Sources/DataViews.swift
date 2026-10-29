import SwiftUI
import UniformTypeIdentifiers
import PDFKit

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct DataView: View {
    @EnvironmentObject private var store: StudyStore
    @State private var exportDocument: BackupDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var candidate: StudyState?
    @State private var confirmRestore = false
    @State private var problem: String?
    @State private var restored = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { do { exportDocument = BackupDocument(data: try store.export()); exporting = true } catch { problem = error.localizedDescription } }
                    label: { Label("导出学习记录", systemImage: "square.and.arrow.up") }
                    Button { importing = true } label: { Label("导入备份", systemImage: "square.and.arrow.down") }
                    NavigationLink { BackupsView() } label: { Label("自动备份", systemImage: "clock.arrow.circlepath") }
                } header: { Text("学习记录") }
                footer: { Text("记录保存在本机。卸载前请导出备份，避免丢失。可导入 iOS 的 JSON 备份或 Windows 版导出的 SQLite 备份。") }
                Section {
                    LabeledContent("题库", value: "2026 年 9 月版 · 563 题")
                    LabeledContent("版本", value: "1.0.4 · iOS")
                    LabeledContent("系统", value: "iOS 26 或更新版本")
                    NavigationLink { PDFScreen(page: 40, embedded: true) } label: { Label("题库原文", systemImage: "doc.richtext") }
                    Link(destination: URL(string: "https://github.com/NAM1B0/huadian-quiz-room")!) { Label("项目与更新", systemImage: "arrow.up.right.square") }
                } header: { Text("关于") } footer: { Text("华电公共题库练习室。离线使用，无需登录。题库按原 PDF 整理，仅供学习，请以官方材料为准。") }
            }.navigationTitle("数据与备份")
                .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json, defaultFilename: "华电学习备份-" + Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))) { result in
                    if case .failure(let error) = result { problem = error.localizedDescription }
                }
                .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .data]) { result in
                    do {
                        let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 50_000_000 else { throw StudyError("备份超过 50 MB，请检查文件。") }
                        let bytes = try Data(contentsOf: url)
                        if bytes.starts(with: Array("SQLite format 3\0".utf8)) {
                            candidate = try WindowsBackupImporter.read(url: url, bankID: store.bank.id)
                            if let candidate { try store.validate(candidate) }
                        } else { candidate = try store.decodeImport(bytes) }
                        confirmRestore = true
                    } catch { candidate = nil; problem = error.localizedDescription }
                }
                .alert("用备份替换当前记录？", isPresented: $confirmRestore) {
                    Button("取消", role: .cancel) { candidate = nil }
                    Button("备份并恢复", role: .destructive) {
                        do { if let candidate { try store.restore(candidate); restored = true }; candidate = nil }
                        catch { problem = error.localizedDescription }
                    }
                } message: { Text("备份包含 \(candidate?.practice.count ?? 0) 道练习、\(candidate?.exams.count ?? 0) 场考试。恢复前会自动保存现有记录；Windows 备份导入后，手机与电脑各自保存进度。") }
                .alert("已恢复学习记录", isPresented: $restored) { Button("好") { } }
                .studyError($problem)
        }
    }
}

struct BackupsView: View {
    @EnvironmentObject private var store: StudyStore
    @State private var backups: [LocalBackup] = []
    @State private var candidate: StudyState?
    @State private var confirm = false
    @State private var restored = false
    @State private var problem: String?
    var body: some View {
        List {
            Section {
                if backups.isEmpty { Text("还没有自动备份").foregroundStyle(.secondary) }
                ForEach(backups) { backup in
                    Button {
                        do { candidate = try store.decodeImport(store.persistence.readBackup(backup)); confirm = true }
                        catch { problem = error.localizedDescription }
                    } label: { Label(backup.title, systemImage: "doc.badge.clock").font(.subheadline).padding(.vertical, 8) }
                }
            } footer: { Text("每天首次打开，以及删除考试或恢复数据前，自动保存一份备份。备份也在本机，卸载前请导出。") }
        }.navigationTitle("自动备份").navigationBarTitleDisplayMode(.inline)
            .task { reload() }
            .alert("恢复这份备份？", isPresented: $confirm) {
                Button("取消", role: .cancel) { candidate = nil }
                Button("备份并恢复", role: .destructive) {
                    do { if let candidate { try store.restore(candidate); restored = true; reload() }; candidate = nil }
                    catch { problem = error.localizedDescription }
                }
            } message: { Text("当前记录将被替换，替换前会另存一份备份。") }
            .alert("已恢复学习记录", isPresented: $restored) { Button("好") { } }
            .studyError($problem)
    }
    private func reload() { do { backups = try store.persistence.listBackups() } catch { problem = error.localizedDescription } }
}

struct PDFScreen: View {
    let page: Int
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        if embedded { content }
        else {
            NavigationStack { content.toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } } }
        }
    }
    private var content: some View {
        PDFReader(page: page).navigationTitle("题库原文").navigationBarTitleDisplayMode(.inline).ignoresSafeArea(edges: .bottom)
    }
}

struct PDFReader: UIViewRepresentable {
    let page: Int
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayDirection = .vertical; view.displayMode = .singlePageContinuous
        if let url = Bundle.main.url(forResource: "题库原文", withExtension: "pdf"), let document = PDFDocument(url: url) {
            view.document = document
            if let target = document.page(at: max(0, min(page - 1, document.pageCount - 1))) {
                DispatchQueue.main.async { view.go(to: target) }
            }
        }
        return view
    }
    func updateUIView(_ uiView: PDFView, context: Context) { }
}
