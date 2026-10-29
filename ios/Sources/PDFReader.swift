import SwiftUI
import PDFKit

enum BundledPDF {
    // ASCII resource paths survive unzip/re-sign/repack on Windows as well as iOS.
    static var url: URL? { Bundle.main.url(forResource: "question-bank", withExtension: "pdf") }

    static func read(url: URL?) throws -> PDFDocument {
        guard let url, let data = try? Data(contentsOf: url) else {
            throw StudyError("安装包中缺少题库原文。请下载最新的 iOS 安装包并覆盖安装。")
        }
        guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else {
            throw StudyError("题库原文无法读取。请重新下载安装包；学习记录无需清空。")
        }
        return document
    }
}

struct PDFPageRequest: Identifiable, Equatable {
    let page: Int
    var id: Int { page }
}

struct PDFScreen: View {
    let page: Int
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var currentPage = 0
    @State private var problem: String?

    var body: some View {
        if embedded { content }
        else {
            NavigationStack {
                content.toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                }
            }
        }
    }

    private var content: some View {
        Group {
            if let document {
                PDFReader(document: document, page: page) { currentPage = $0 }
            } else if let problem {
                ContentUnavailableView {
                    Label("原文暂时无法打开", systemImage: "doc.badge.ellipsis")
                } description: { Text(problem) }
                actions: { Button("重试", action: load).buttonStyle(.borderedProminent) }
                .accessibilityIdentifier("pdf-load-error")
            } else {
                ProgressView("正在打开原文…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("题库原文").navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let document {
                HStack {
                    Text("PDF 第 \(currentPage == 0 ? min(max(page, 1), document.pageCount) : currentPage) / \(document.pageCount) 页")
                        .font(.footnote).monospacedDigit()
                        .accessibilityIdentifier("pdf-page-status")
                    Spacer()
                    if let url = BundledPDF.url {
                        ShareLink(item: url) { Label("导出 PDF", systemImage: "square.and.arrow.up") }
                            .font(.subheadline).frame(minHeight: 44)
                    }
                }.padding(.horizontal, 20).background(.bar)
            }
        }
        .task { if document == nil { load() } }
    }

    private func load() {
        do {
            #if DEBUG
            let missing = ProcessInfo.processInfo.environment["HUADIAN_TEST_SESSION"] != nil && ProcessInfo.processInfo.arguments.contains("--missing-pdf")
            document = try BundledPDF.read(url: missing ? nil : BundledPDF.url)
            #else
            document = try BundledPDF.read(url: BundledPDF.url)
            #endif
            problem = nil
        } catch { document = nil; problem = error.localizedDescription }
    }
}

struct PDFReader: UIViewControllerRepresentable {
    let document: PDFDocument
    let page: Int
    var pageChanged: (Int) -> Void

    func makeUIViewController(context: Context) -> PDFReaderController {
        PDFReaderController(document: document, page: page, pageChanged: pageChanged)
    }
    func updateUIViewController(_ controller: PDFReaderController, context: Context) {
        controller.pageChanged = pageChanged
    }
}

final class PDFReaderController: UIViewController {
    let pdfView = PDFView()
    private let document: PDFDocument
    private let initialPage: Int
    private var previousSize = CGSize.zero
    private var configured = false
    private var initialPresentationCompleted = false
    var pageChanged: (Int) -> Void

    init(document: PDFDocument, page: Int, pageChanged: @escaping (Int) -> Void) {
        self.document = document; initialPage = page; self.pageChanged = pageChanged
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.displayDirection = .vertical
        pdfView.displayMode = .singlePageContinuous
        pdfView.pageShadowsEnabled = true
        pdfView.accessibilityIdentifier = "pdf-reader"
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pdfView)
        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: view.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(reportPage), name: .PDFViewPageChanged, object: pdfView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = pdfView.bounds.size
        guard size.width > 0, size.height > 0, size != previousSize else { return }
        previousSize = size
        // PDFKit must calculate its initial scale and destination after Auto Layout
        // supplies a real viewport. A zero-size representable can remain blank.
        let target = configured && initialPresentationCompleted ? pdfView.currentPage : initialTarget
        if !configured {
            configured = true
            pdfView.document = document
        }
        pdfView.autoScales = true
        pdfView.layoutDocumentView()
        let scale = pdfView.scaleFactorForSizeToFit
        if scale.isFinite, scale > 0 { pdfView.scaleFactor = scale }
        if let target { position(at: target) }
        reportPage()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !initialPresentationCompleted else { return }
        initialPresentationCompleted = true
        // A sheet changes its viewport during presentation. Anchor the requested
        // page once the transition is complete, not an adjacent transient page.
        pdfView.layoutDocumentView()
        if let target = initialTarget { position(at: target) }
        reportPage()
    }

    private var initialTarget: PDFPage? {
        document.page(at: min(max(initialPage - 1, 0), document.pageCount - 1))
    }
    private func position(at page: PDFPage) {
        let bounds = page.bounds(for: .mediaBox)
        pdfView.go(to: PDFDestination(page: page, at: CGPoint(x: bounds.minX, y: bounds.maxY)))
    }

    @objc private func reportPage() {
        guard let page = pdfView.currentPage else { return }
        let number = document.index(for: page) + 1
        guard number > 0, number <= document.pageCount else { return }
        DispatchQueue.main.async { [weak self] in self?.pageChanged(number) }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}
