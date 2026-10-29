import XCTest
import PDFKit
@testable import HuadianQuiz

@MainActor
final class PDFReaderTests: XCTestCase {
    func testBundledPDFContainsReadableAndRenderableQuestionPages() throws {
        let url = try XCTUnwrap(BundledPDF.url)
        XCTAssertEqual(url.lastPathComponent, "question-bank.pdf")
        let document = try BundledPDF.read(url: url)
        XCTAssertEqual(document.pageCount, 161)
        let firstQuestionPage = try XCTUnwrap(document.page(at: 39))
        XCTAssertTrue(firstQuestionPage.string?.contains("第一部分") == true)
        XCTAssertTrue(document.page(at: 94)?.string?.contains("245") == true)
        let bitmap = try XCTUnwrap(firstQuestionPage.thumbnail(of: CGSize(width: 390, height: 552), for: .mediaBox).cgImage)
        let bytes = try XCTUnwrap(bitmap.dataProvider?.data)
        // A successful PDF parse alone does not prove that a page can be drawn.
        let pixels = bytes as Data
        XCTAssertGreaterThan(Set(pixels).count, 20, "A blank page has too few pixel values")
    }

    func testReaderFitsAndLocatesPageAfterViewportLayout() async throws {
        let document = try BundledPDF.read(url: BundledPDF.url)
        let controller = PDFReaderController(document: document, page: 95) { _ in }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 760))
        window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(controller.pdfView.document === document)
        XCTAssertEqual(document.index(for: try XCTUnwrap(controller.pdfView.currentPage)), 94)
        XCTAssertGreaterThan(controller.pdfView.scaleFactor, 0)
        XCTAssertGreaterThan(controller.pdfView.documentView?.bounds.height ?? 0, 0)
        XCTAssertFalse(controller.pdfView.visiblePages.isEmpty)
        window.frame = CGRect(x: 0, y: 0, width: 760, height: 390)
        controller.view.setNeedsLayout(); controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(controller.pdfView.visiblePages.isEmpty)
        XCTAssertEqual(document.index(for: try XCTUnwrap(controller.pdfView.currentPage)), 94)
    }

    func testMissingOrCorruptPDFProducesAnActionableError() throws {
        XCTAssertThrowsError(try BundledPDF.read(url: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("安装包"))
        }
        let invalid = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("not a PDF".utf8).write(to: invalid)
        defer { try? FileManager.default.removeItem(at: invalid) }
        XCTAssertThrowsError(try BundledPDF.read(url: invalid)) { error in
            XCTAssertTrue(error.localizedDescription.contains("无法读取"))
        }
    }
}
