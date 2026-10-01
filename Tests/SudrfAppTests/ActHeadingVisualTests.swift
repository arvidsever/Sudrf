import AppKit
import PDFKit
import SwiftUI
import XCTest
import SudrfKit
@testable import SudrfApp

@MainActor
final class ActHeadingVisualTests: XCTestCase {
    func fixture() throws -> ActDocument {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/issue359_2-7212_2025.html")
        let card = try CaseCardParser.parse(html: String(contentsOf: url, encoding: .utf8))
        return ActDocument(caseKey: "qa/2-7212/2025", sourceActID: "qa-act",
            caseNumber: "2-7212/2025", judicialUID: nil, court: "Тестовый суд",
            instanceLevel: .first, kind: "Заочное решение", date: "18.08.2025",
            sourceText: try XCTUnwrap(card.actText))
    }

    func windows() throws -> [(NSWindow, NSHostingView<AnyView>)] {
        let document = try fixture()
        let panel = CourtActContent(text: document.sourceText, pdfData: nil,
                                   paragraphs: document.paragraphs)
        let separate = ActWindowView(payload: ActWindowPayload(
            caseNumber: document.caseNumber, actText: document.sourceText,
            paragraphs: document.paragraphs))
        return [("Панель акта", AnyView(panel)), ("Отдельное окно", AnyView(separate))].map {
            let hosted = NSHostingView(rootView: AnyView($0.1
                .background(Color(nsColor: .textBackgroundColor))
                .environment(\.colorScheme, .light)
                .frame(width: 660, height: 480)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 480),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Sudrf QA #359 — \($0.0), изолированные данные"
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = hosted
            return (window, hosted)
        }
    }

    func testIsolatedNativeViewsAndExportedPDF() throws {
        guard let path = ProcessInfo.processInfo.environment["SUDRF_HEADING359_QA_OUTPUT"] else {
            throw XCTSkip("Opt-in native GUI/PDF acceptance; use Docs/qa/issue-359/run.sh")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let views = try windows()
        defer { views.forEach { $0.0.close() } }
        for (index, item) in views.enumerated() {
            let (window, view) = item
            window.center()
            window.makeKeyAndOrderFront(nil)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
            view.displayIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            var inkPixels = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                       color.alphaComponent > 0.5, color.redComponent < 0.8 {
                        inkPixels += 1
                    }
                }
            }
            XCTAssertGreaterThan(inkPixels, 25, "Empty native capture")
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(index == 0 ? "panel.png" : "window.png"))
        }
        let source = try fixture()
        let pdfURL = output.appendingPathComponent("heading.pdf")
        try ActPDFExporter.write(to: pdfURL, text: source.sourceText, paragraphs: source.paragraphs)
        let pdf = try XCTUnwrap(PDFDocument(url: pdfURL))
        let text = try XCTUnwrap(pdf.string)
        XCTAssertTrue(text.contains("ЗАОЧНОЕ РЕШЕНИЕ"), text)
        XCTAssertFalse(text.contains("ЗАОЧНОЕРЕШЕНИЕ"), text)
        try text.write(to: output.appendingPathComponent("heading-extracted.txt"), atomically: true, encoding: .utf8)
    }
}
