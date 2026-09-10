import XCTest
@testable import SudrfKit

final class ActDocumentTests: XCTestCase {
    func testCurrentParagraphizerRevisionIsTwo() {
        XCTAssertEqual(ActParagraphizer.currentVersion, 2)
    }

    func testStableIDHashAndParagraphNumbers() {
        let source = "  Дело № 2-1/2026  \r\n\r\nПервый абзац.\r\nВторой   абзац. "
        let first = ActDocument(
            caseKey: "court/2-1/2026", sourceActID: "act-7",
            caseNumber: "2-1/2026", judicialUID: "UID", court: "Суд",
            instanceLevel: .first, kind: "Решение", date: "01.07.2026",
            sourceText: source)
        let second = ActDocument(
            caseKey: "court/2-1/2026", sourceActID: "act-7",
            caseNumber: "2-1/2026", judicialUID: "UID", court: "Суд",
            instanceLevel: .first, kind: "Решение", date: "01.07.2026",
            sourceText: source.replacingOccurrences(of: "\r\n", with: "\n"))

        XCTAssertEqual(first.id, "court/2-1/2026#act-7")
        XCTAssertEqual(first.sourceHash, second.sourceHash)
        XCTAssertEqual(first.paragraphs.map(\.id), ["¶1", "¶2", "¶3"])
        XCTAssertEqual(first.paragraphs.map(\.ordinal), [1, 2, 3])
        XCTAssertEqual(first.paragraphs[2].text, "Второй абзац.")
    }

    func testChangedTextChangesHashButNotDocumentID() {
        func document(_ text: String) -> ActDocument {
            ActDocument(caseKey: "case", sourceActID: "act", caseNumber: "1",
                        judicialUID: nil, court: "Суд", instanceLevel: .appeal,
                        kind: "Определение", date: "", sourceText: text)
        }
        XCTAssertEqual(document("Один").id, document("Два").id)
        XCTAssertNotEqual(document("Один").sourceHash, document("Два").sourceHash)
    }

    func testLongSingleLineIsSplitDeterministically() {
        let sentence = "Суд установил обстоятельства и исследовал доказательства. "
        let source = String(repeating: sentence, count: 80)
        let first = ActParagraphizer.paragraphs(in: source)
        let second = ActParagraphizer.paragraphs(in: source)

        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(first.count, 1)
        XCTAssertEqual(first.map(\.id), first.indices.map { "¶\($0 + 1)" })
        XCTAssertTrue(first.allSatisfy { !$0.text.isEmpty && $0.text.count <= 2_400 })
    }

    func testShortSingleLineRestoresCourtActStructure() {
        let source = "УИД 11RS0001-01-2026-000001-10 Дело № 2-1/2026 Р Е Ш Е Н И Е Именем Российской Федерации Суд рассмотрел дело установил: иск подтверждён. решил: иск удовлетворить."

        XCTAssertEqual(
            ActParagraphizer.paragraphs(in: source).map(\.text),
            [
                "УИД 11RS0001-01-2026-000001-10",
                "Дело № 2-1/2026",
                "Р Е Ш Е Н И Е",
                "Именем Российской Федерации",
                "Суд рассмотрел дело",
                "установил:",
                "иск подтверждён.",
                "решил:",
                "иск удовлетворить.",
            ])
    }

    func testNonBreakingSpacesAndSpacedTitleAreRecognized() {
        let nbsp = "\u{00a0}"
        let source = "Дело\(nbsp)№\(nbsp)2-8/2026 П О С Т А Н О В Л Е Н И Е Именем\(nbsp)Российской\(nbsp)Федерации постановил: жалобу оставить без удовлетворения."

        XCTAssertEqual(
            ActParagraphizer.paragraphs(in: source).map(\.text),
            [
                "Дело № 2-8/2026",
                "П О С Т А Н О В Л Е Н И Е",
                "Именем Российской Федерации",
                "постановил:",
                "жалобу оставить без удовлетворения.",
            ])
    }

    func testStructuralVerbWithoutColonRemainsOrdinaryProse() {
        let source = "Суд установил обстоятельства и решил вопрос о расходах."
        XCTAssertEqual(ActParagraphizer.paragraphs(in: source).map(\.text), [source])
    }

    func testUppercaseTitleInsideReasonsIsNotPromoted() {
        let source = "Суд исследовал РЕШЕНИЕ районного суда и отклонил ссылку."
        let paragraphs = ActParagraphizer.paragraphs(in: source)

        XCTAssertFalse(paragraphs.contains { $0.text == "РЕШЕНИЕ" })
        XCTAssertEqual(nonWhitespace(paragraphs.map(\.text).joined()),
                       nonWhitespace(source))
    }

    func testCourtNameBeforeTitleIsAcceptedOnlyWithImmediateSubtitle() {
        let source = "Сыктывкарский городской суд РЕШЕНИЕ Именем Российской Федерации установил: требования подтверждены."
        XCTAssertEqual(ActParagraphizer.paragraphs(in: source).map(\.text), [
            "Сыктывкарский городской суд",
            "РЕШЕНИЕ",
            "Именем Российской Федерации",
            "установил:",
            "требования подтверждены.",
        ])
    }

    func testInitialMarkersMayPlaceCaseNumberAfterTitle() {
        let source = "РЕШЕНИЕ Дело № 2-1/2026 Именем Российской Федерации установил: требования подтверждены."
        XCTAssertEqual(ActParagraphizer.paragraphs(in: source).map(\.text), [
            "РЕШЕНИЕ",
            "Дело № 2-1/2026",
            "Именем Российской Федерации",
            "установил:",
            "требования подтверждены.",
        ])
    }

    func testSpacedStructuralVerbIsIsolatedWithItsPunctuation() {
        let source = "РЕШЕНИЕ У С Т А Н О В И Л : требования подтверждены."
        XCTAssertEqual(ActParagraphizer.paragraphs(in: source).map(\.text), [
            "РЕШЕНИЕ", "У С Т А Н О В И Л :", "требования подтверждены.",
        ])
    }

    func testMissingUIDLabelIsNotTreatedAsMetadata() {
        let source = "УИД отсутствует РЕШЕНИЕ суда исследовано."
        XCTAssertEqual(ActParagraphizer.paragraphs(in: source).map(\.text), [source])
    }

    func testStructuralMarkersDoNotDependOnLegacyLengthThreshold() {
        let prefix = "РЕШЕНИЕ установил: "
        for totalLength in [1_199, 1_200, 1_201] {
            let source = prefix + String(repeating: "а", count: totalLength - prefix.count)
            let paragraphs = ActParagraphizer.paragraphs(in: source)

            XCTAssertEqual(source.count, totalLength)
            XCTAssertEqual(paragraphs.prefix(2).map(\.text), ["РЕШЕНИЕ", "установил:"])
            XCTAssertEqual(nonWhitespace(paragraphs.map(\.text).joined()),
                           nonWhitespace(source))
        }
    }

    func testSingleLineSegmentationPreservesTextAndPunctuation() {
        let source = "Дело № 7-3/2026 ОПРЕДЕЛЕНИЕ Суд, исследовав материалы, определил: заявление вернуть; расходы — 0 руб."
        let paragraphs = ActParagraphizer.paragraphs(in: source)

        XCTAssertEqual(nonWhitespace(paragraphs.map(\.text).joined()),
                       nonWhitespace(source))
        XCTAssertEqual(paragraphs.map(\.text), ActParagraphizer.paragraphs(in: source).map(\.text))
    }

    func testExistingMultilineBoundariesArePreserved() {
        let source = "РЕШЕНИЕ\nИменем Российской Федерации\nСуд установил обстоятельства.\nрешил"
        XCTAssertEqual(ActParagraphizer.paragraphs(in: source).map(\.text), [
            "РЕШЕНИЕ", "Именем Российской Федерации",
            "Суд установил обстоятельства.", "решил",
        ])
    }

    private func nonWhitespace(_ text: String) -> String {
        String(text.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        })
    }
}
