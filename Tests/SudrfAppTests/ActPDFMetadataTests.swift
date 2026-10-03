import AppKit
import PDFKit
import XCTest
import SudrfKit
@testable import SudrfApp

@MainActor
final class ActPDFMetadataTests: XCTestCase {
    func testMetadataConstructionUsesAvailableActLabels() throws {
        let actText = "Р Е Ш Е Н И Е\nИменем Российской Федерации\nТекст мотивированного решения."
        let act = CaseAct(id: "selected", title: "Мотивированное решение",
                          date: "21.06.2021", courtShort: "Суд первой инстанции",
                          instanceLevel: .first)
        let movement = CaseMovement(
            uid: "77RS0001-01-2021-000123-45", caseNumber: "3а-1318/2021",
            inForce: true,
            instances: [CaseInstance(
                level: .first, court: "Московский городской суд",
                caseNumber: "3а-1318/2021", judge: nil,
                domain: "mos-gorsud.ru", foundByUID: true, result: nil,
                sessions: [], actID: act.id)],
            complaints: [:], acts: [act], actBodies: [act.id: actText])
        let display = try XCTUnwrap(CourtActPresentation.row(for: act.id, in: movement))
        let metadata = ActPDFMetadata.selectedAct(
            caseNumber: movement.caseNumber, text: display.text,
            sourceTitle: display.sourceTitle, date: display.date,
            courtName: display.courtName, judicialUID: display.judicialUID)

        XCTAssertEqual(metadata.title,
                       "Дело № 3а-1318/2021 — Мотивированное решение от 21.06.2021")
        XCTAssertEqual(display.courtName, "Московский городской суд")
        XCTAssertEqual(metadata.judicialUID, movement.uid)
        let document = PDFDocument()
        metadata.apply(to: document)
        let attributes = try XCTUnwrap(document.documentAttributes)
        XCTAssertEqual(attributes[PDFDocumentAttribute.titleAttribute] as? String, metadata.title)
        XCTAssertEqual(attributes[PDFDocumentAttribute.subjectAttribute] as? String,
                       "Московский городской суд")
        XCTAssertEqual(attributes[PDFDocumentAttribute.keywordsAttribute] as? [String],
                       ["77RS0001-01-2021-000123-45"])
        XCTAssertEqual(attributes[PDFDocumentAttribute.authorAttribute] as? String, "Sudrf")
        XCTAssertEqual(attributes[PDFDocumentAttribute.creatorAttribute] as? String, "Sudrf")
    }

    func testPublishedFileUsesItsProductionNumberAndActLabel() throws {
        let act = CaseAct(
            id: "vs-act", title: "Кассационное определение", date: "15.10.2025",
            courtShort: "ВС РФ", instanceLevel: .vsCassation,
            productionNumber: "3-ИКАД25-3-А2")
        let movement = CaseMovement(
            uid: "published-uid", caseNumber: "3а-85/2025", inForce: true,
            instances: [CaseInstance(
                level: .vsCassation, court: "Верховный Суд РФ",
                caseNumber: "3-ИКАД25-3-А2", judge: nil,
                domain: "vsrf.ru", foundByUID: true, result: nil,
                sessions: [], actID: act.id)],
            complaints: [:], acts: [act],
            actBodies: [act.id: "КАССАЦИОННОЕ ОПРЕДЕЛЕНИЕ\nОставлено без изменения."])
        let display = try XCTUnwrap(CourtActPresentation.row(for: act.id, in: movement))
        let metadata = ActPDFMetadata.selectedAct(
            caseNumber: display.productionNumber ?? movement.caseNumber,
            text: display.text, sourceTitle: display.sourceTitle, date: display.date,
            courtName: display.courtName, judicialUID: display.judicialUID)

        XCTAssertEqual(metadata.title,
                       "Дело № 3-ИКАД25-3-А2 — Кассационное определение от 15.10.2025")
        XCTAssertEqual(metadata.courtName, "Верховный Суд РФ")
        XCTAssertEqual(metadata.judicialUID, "published-uid")
    }

    func testRenderedAndFilePDFMetadataPreservePageContent() throws {
        let text = "Дело № 3а-1318/2021\nМотивированное решение\n21.06.2021\n\n"
            + String(repeating: "Суд рассмотрел материалы дела. Обстоятельства установлены.\n\n",
                     count: 240)
            + "Контрольная строка последней страницы."
        let selectedAttachment = CaseAct(
            id: "moscow-act", title: "Мотивированное решение", date: "21.06.2021",
            courtShort: "Московский городской суд", instanceLevel: .first)
        let metadata = ActPDFMetadata.selectedSearchAct(
            caseNumber: "3а-1318/2021", text: text, selectedAct: selectedAttachment,
            fallbackTitle: "Решение", fallbackDate: "22.06.2021",
            fallbackCourtName: "Суд первой инстанции",
            judicialUID: "77RS0001-01-2021-000123-45")
        let renderedData = try XCTUnwrap(
            ActPDFExporter.renderData(text: text, metadata: metadata))
        let renderedDocument = try XCTUnwrap(PDFDocument(data: renderedData))

        XCTAssertGreaterThan(renderedDocument.pageCount, 1)
        XCTAssertTrue(renderedDocument.string?.contains("Контрольная строка последней страницы") == true)
        assertMetadata(metadata, on: renderedDocument)

        let sourceURL = try XCTUnwrap(Bundle.module.url(
            forResource: "valid", withExtension: "pdf",
            subdirectory: "Fixtures/published-act"))
        let originalFileBytes = try Data(contentsOf: sourceURL)
        let sourceDocument = try XCTUnwrap(PDFDocument(data: originalFileBytes))
        var sourceAttributes = sourceDocument.documentAttributes ?? [:]
        sourceAttributes[PDFDocumentAttribute.titleAttribute] = "Исходный титул"
        sourceAttributes[PDFDocumentAttribute.subjectAttribute] = "Исходный суд"
        sourceAttributes[PDFDocumentAttribute.keywordsAttribute] = ["исходный-уид"]
        sourceDocument.documentAttributes = sourceAttributes
        let annotation = PDFAnnotation(
            bounds: NSRect(x: 20, y: 20, width: 120, height: 24),
            forType: .text, withProperties: nil)
        annotation.contents = "Комментарий к источнику"
        sourceDocument.page(at: 0)?.addAnnotation(annotation)
        let sourceData = try XCTUnwrap(sourceDocument.dataRepresentation())
        let sourcePageCount = sourceDocument.pageCount
        let sourceText = sourceDocument.string
        let serializedSourceDocument = try XCTUnwrap(PDFDocument(data: sourceData))
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sudrf-issue-361-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }

        try ActPDFExporter.write(to: output, text: text, originalPDF: sourceData,
                                 metadata: metadata)

        let fileCopyData = try Data(contentsOf: output)
        let fileDocument = try XCTUnwrap(PDFDocument(data: fileCopyData))
        XCTAssertNotEqual(fileCopyData, sourceData)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalFileBytes,
                       "metadata export must not alter the cached/source PDF fixture")
        XCTAssertEqual(sourceDocument.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String,
                       "Исходный титул")
        XCTAssertEqual(sourceDocument.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String,
                       "Исходный суд")
        XCTAssertEqual(sourceDocument.documentAttributes?[PDFDocumentAttribute.keywordsAttribute] as? [String],
                       ["исходный-уид"])
        XCTAssertEqual(sourceDocument.pageCount, sourcePageCount)
        XCTAssertEqual(serializedSourceDocument.pageCount, sourcePageCount)
        XCTAssertEqual(fileDocument.pageCount, serializedSourceDocument.pageCount)
        XCTAssertEqual(fileDocument.string, serializedSourceDocument.string)
        let sourceAnnotations = try XCTUnwrap(serializedSourceDocument.page(at: 0)).annotations
            .map { "\($0.type ?? "nil"):\($0.contents ?? "nil")" }
        let copiedAnnotations = try XCTUnwrap(fileDocument.page(at: 0)).annotations
            .map { "\($0.type ?? "nil"):\($0.contents ?? "nil")" }
        XCTAssertEqual(copiedAnnotations, sourceAnnotations,
                       "PDFKit metadata rewrite changed source annotations")
        XCTAssertEqual(fileDocument.string, sourceText)
        assertMetadata(metadata, on: fileDocument)

        if let outputPath = ProcessInfo.processInfo.environment["SUDRF_PDF_METADATA_OUTPUT"] {
            let directory = URL(fileURLWithPath: outputPath, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try renderedData.write(to: directory.appendingPathComponent("rendered-text.pdf"))
            try fileCopyData.write(to: directory.appendingPathComponent("file-copy.pdf"))
            try Data((renderedDocument.string ?? "").utf8)
                .write(to: directory.appendingPathComponent("rendered-text.txt"))
            try Data((fileDocument.string ?? "").utf8)
                .write(to: directory.appendingPathComponent("file-copy.txt"))
        }
    }

    private func assertMetadata(_ metadata: ActPDFMetadata, on document: PDFDocument,
                                file: StaticString = #filePath, line: UInt = #line) {
        let attributes = document.documentAttributes ?? [:]
        XCTAssertEqual(attributes[PDFDocumentAttribute.titleAttribute] as? String, metadata.title,
                       file: file, line: line)
        XCTAssertEqual(attributes[PDFDocumentAttribute.subjectAttribute] as? String, metadata.courtName,
                       file: file, line: line)
        XCTAssertEqual(attributes[PDFDocumentAttribute.keywordsAttribute] as? [String],
                       metadata.judicialUID.map { [$0] },
                       file: file, line: line)
        XCTAssertEqual(attributes[PDFDocumentAttribute.authorAttribute] as? String, "Sudrf",
                       file: file, line: line)
        XCTAssertEqual(attributes[PDFDocumentAttribute.creatorAttribute] as? String, "Sudrf",
                       file: file, line: line)
    }
}
