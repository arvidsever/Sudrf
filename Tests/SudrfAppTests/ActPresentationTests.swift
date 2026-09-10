import AppKit
import PDFKit
import SwiftData
import SwiftUI
import XCTest
import SudrfKit
@testable import SudrfApp

final class ActPresentationTests: XCTestCase {
    private let shortSource = "Дело № 2-1/2026 Р Е Ш Е Н И Е Именем Российской Федерации установил: обстоятельства доказаны. решил: иск удовлетворить."

    func testActWindowPayloadDecodesLegacyValueWithoutParagraphs() throws {
        let data = Data(#"{"caseNumber":"2-1/2026","actText":"Текст акта"}"#.utf8)

        let payload = try JSONDecoder().decode(ActWindowPayload.self, from: data)

        XCTAssertEqual(payload.caseNumber, "2-1/2026")
        XCTAssertEqual(payload.actText, "Текст акта")
        XCTAssertNil(payload.paragraphs)
    }

    @MainActor
    func testPDFFormatterUsesTheProvidedParagraphSnapshot() {
        let snapshot = [ActParagraph(ordinal: 1, text: shortSource)]

        let snapshotOutput = ActPDFExporter.attributedAct(shortSource, paragraphs: snapshot)
        let currentOutput = ActPDFExporter.attributedAct(
            shortSource, paragraphs: ActParagraphizer.paragraphs(in: shortSource))

        XCTAssertEqual(snapshotOutput.string, shortSource + "\n")
        XCTAssertEqual(currentOutput.string.filter { $0 == "\n" }.count, 7)
    }

    @MainActor
    func testShortAndLongActRenderThroughViewAndPDF() throws {
        let longSource = "Дело № 2-2/2026 Р Е Ш Е Н И Е Именем Российской Федерации "
            + String(repeating: "Суд рассмотрел материалы. ", count: 240)
            + "установил: обстоятельства доказаны. решил: иск удовлетворить."
        let fixtures = [("short", shortSource), ("long", longSource)]

        for (name, source) in fixtures {
            let paragraphs = ActParagraphizer.paragraphs(in: source)
            let rendered = try renderPNG(text: source, paragraphs: paragraphs)
            let pdf = try XCTUnwrap(
                ActPDFExporter.renderData(text: source, paragraphs: paragraphs))
            let document = try XCTUnwrap(PDFDocument(data: pdf))
            let extracted = document.string ?? ""

            XCTAssertFalse(rendered.data.isEmpty)
            XCTAssertGreaterThan(rendered.inkPixels, 100)
            XCTAssertFalse(pdf.isEmpty)
            XCTAssertTrue(extracted.contains("Дело № 2-"))
            XCTAssertTrue(extracted.contains("иск удовлетворить"))
            XCTAssertEqual(document.pageCount > 1, name == "long")

            if let output = ProcessInfo.processInfo.environment["SUDRF_ACT_VISUAL_OUTPUT"] {
                let directory = URL(fileURLWithPath: output, isDirectory: true)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                try rendered.data.write(
                    to: directory.appendingPathComponent("\(name)-act.png"))
                try pdf.write(to: directory.appendingPathComponent("\(name)-act.pdf"))
                try Data(source.utf8).write(
                    to: directory.appendingPathComponent("\(name)-act.txt"))
            }
        }
    }

    @MainActor
    func testRapidSelectionUsesExactStoredSnapshotEndToEnd() throws {
        let defaults = UserDefaults.standard
        let onboardingKey = SpotlightPreferenceStore.onboardingKey
        let savedOnboarding = defaults.object(forKey: onboardingKey)
        defaults.set(false, forKey: onboardingKey)
        defer {
            if let savedOnboarding { defaults.set(savedOnboarding, forKey: onboardingKey) }
            else { defaults.removeObject(forKey: onboardingKey) }
        }
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: "court--msk.sudrf.ru", displayDomain: "court.msk.sudrf.ru",
            courtTitle: "Суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "77", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue, caseNumber: "2-45/2026")
        let act = CaseAct(id: "selected", title: "Решение", date: "01.09.2026",
                          courtShort: "Суд", instanceLevel: .first)
        let other = CaseAct(id: "other", title: "Определение", date: "02.09.2026",
                            courtShort: "Суд", instanceLevel: .appeal)
        let otherText = "ОПРЕДЕЛЕНИЕ определил: отказать."
        let movement = CaseMovement(
            uid: "", caseNumber: context.caseNumber, inForce: false,
            instances: [CaseInstance(
                level: .first, court: "Суд", caseNumber: context.caseNumber,
                judge: nil, domain: context.displayDomain, foundByUID: false,
                result: nil, sessions: [], actID: act.id)],
            complaints: [:], acts: [act, other],
            actBodies: [act.id: shortSource, other.id: otherText],
            category: nil, parties: CaseParties())
        let snapshot = MovementDerivation.snapshot(from: movement, context: context)
        let record = try store.upsert(
            context: context, snapshot: snapshot, movement: movement, collections: [])
        let futureParagraphs = [ActParagraph(ordinal: 77, text: shortSource)]
        let storedActs = try container.mainContext.fetch(FetchDescriptor<CourtActRecord>())
        let storedAct = try XCTUnwrap(storedActs.first { $0.sourceActID == act.id })
        storedAct.paragraphData = try JSONEncoder().encode(futureParagraphs)
        storedAct.paragraphizerVersion = 77
        try container.mainContext.save()
        let router = try AppRouter(
            modelContainer: container, modelContainerIsPrepared: true)

        router.openCase(key: record.key)
        router.selectAct(other.id)
        router.selectAct(act.id)
        XCTAssertEqual(router.openedCase, context.caseNumber)
        XCTAssertEqual(router.liveMovement?.actBodies[act.id], shortSource)
        XCTAssertEqual(router.selectedActID, act.id)
        let storedDocument = try XCTUnwrap(store.courtActDocument(
            caseKey: record.key, sourceActID: act.id))
        XCTAssertEqual(storedDocument.caseKey, record.key)
        XCTAssertEqual(storedDocument.sourceActID, act.id)
        XCTAssertEqual(storedDocument.sourceHash,
                       ActParagraphizer.sourceHash(for: shortSource))
        XCTAssertEqual(storedDocument.paragraphizerVersion, 77)
        XCTAssertEqual(router.selectedActDocument, storedDocument)
        XCTAssertEqual(router.selectedActParagraphs, futureParagraphs)
    }

    func testStaleSummaryReasonsDisableOnlyUnsafeCitationNavigation() {
        let document = document(caseKey: "case", actID: "first", text: shortSource)
        let oldSummary = ActSummary(reasoning: [SummaryClaim(
            text: "Старый вывод", citations: [SummaryCitation(
                paragraphID: "¶1", evidenceQuote: "Дело № 2-1/2026")])])
        let legacy = summarySnapshot(
            oldSummary, sourceHash: document.sourceHash, paragraphizerVersion: 1)
        let changed = summarySnapshot(
            oldSummary, sourceHash: "outdated-source-hash",
            paragraphizerVersion: ActParagraphizer.currentVersion)

        let legacyState = AppRouter.summaryCitationNavigationState(
            saved: legacy, document: document)
        let changedState = AppRouter.summaryCitationNavigationState(
            saved: changed, document: document)

        XCTAssertTrue(legacy.isStale(for: document, identity: nil))
        XCTAssertEqual(legacyState, .paragraphizerChanged(
            saved: 1, current: ActParagraphizer.currentVersion))
        XCTAssertFalse(legacyState.allowsNavigation)
        XCTAssertNotNil(legacyState.warning)
        XCTAssertTrue(changed.isStale(for: document, identity: nil))
        XCTAssertEqual(changedState, .sourceChanged)
        XCTAssertFalse(changedState.allowsNavigation)
        XCTAssertTrue(SummaryCitationNavigationState.available.allowsNavigation)
    }

    @MainActor
    private func renderPNG(text: String, paragraphs: [ActParagraph]) throws
        -> (data: Data, inkPixels: Int) {
        let renderer = ImageRenderer(content:
            ActTextView(text: text, paragraphs: paragraphs)
                .padding(24).frame(width: 700).background(Color.white)
                .environment(\.colorScheme, .light))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let bitmap = try XCTUnwrap(
            image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let inkPixels = stride(from: 0, to: bitmap.pixelsHigh, by: 4).reduce(0) { count, y in
            count + stride(from: 0, to: bitmap.pixelsWide, by: 4).reduce(0) { row, x in
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    return row
                }
                return row + ((color.redComponent < 0.9
                    || color.greenComponent < 0.9
                    || color.blueComponent < 0.9) ? 1 : 0)
            }
        }
        return (try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                inkPixels)
    }

    private func document(caseKey: String, actID: String, text: String) -> ActDocument {
        ActDocument(
            caseKey: caseKey, sourceActID: actID, caseNumber: "2-1/2026",
            judicialUID: nil, court: "Суд", instanceLevel: .first,
            kind: "Решение", date: "", sourceText: text)
    }

    private func summarySnapshot(_ summary: ActSummary, sourceHash: String,
                                 paragraphizerVersion: Int) -> ActSummaryCatalogSnapshot {
        ActSummaryCatalogSnapshot(
            documentID: "case#first", summary: summary, provider: "legacy", model: "legacy",
            promptVersion: "v1", pipelineVersion: "v1", sourceHash: sourceHash,
            generatedAt: .now, paragraphizerVersion: paragraphizerVersion)
    }
}
