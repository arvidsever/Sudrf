import XCTest
@testable import SudrfKit

final class ActSummaryTests: XCTestCase {
    private let document = ActDocument(
        caseKey: "court/2-10/2026", sourceActID: "a1", caseNumber: "2-10/2026",
        judicialUID: nil, court: "Суд", instanceLevel: .first, kind: "Решение",
        date: "01.07.2026",
        sourceText: "Суд установил обстоятельства дела.\n\nВзыскать 100 рублей.")

    func testValidatorAcceptsExistingParagraphAndVerbatimQuote() throws {
        let summary = ActSummary(disposition: [SummaryClaim(
            text: "Взыскать 100 рублей.",
            citations: [SummaryCitation(paragraphID: "¶2", evidenceQuote: "100 рублей")])])
        XCTAssertNoThrow(try ActSummaryValidator.validate(summary, against: document))
    }

    func testValidatorRejectsUnknownParagraphAndInventedQuote() throws {
        let unknown = ActSummary(disposition: [SummaryClaim(
            text: "Взыскать 100 рублей.",
            citations: [SummaryCitation(paragraphID: "¶99", evidenceQuote: "100 рублей")])])
        XCTAssertThrowsError(try ActSummaryValidator.validate(unknown, against: document))

        let invented = ActSummary(disposition: [SummaryClaim(
            text: "Взыскать 100 рублей.",
            citations: [SummaryCitation(paragraphID: "¶2", evidenceQuote: "200 рублей")])])
        XCTAssertThrowsError(try ActSummaryValidator.validate(invented, against: document))
    }

    func testValidatorRejectsInventedCriticalLiteral() throws {
        let summary = ActSummary(disposition: [SummaryClaim(
            text: "Взыскать 999 рублей.",
            citations: [SummaryCitation(paragraphID: "¶2", evidenceQuote: "Взыскать")])])
        XCTAssertThrowsError(try ActSummaryValidator.validate(summary, against: document))
    }

    func testValidatorNormalizesLegalFormattingButRejectsInventedUIDAndDeadline() throws {
        let source = ActDocument(
            caseKey: "case", sourceActID: "a", caseNumber: "2-10/2026",
            judicialUID: "77RS0001-01-2026-000001-10", court: "Суд",
            instanceLevel: .first, kind: "Решение", date: "1 июля 2026 года",
            sourceText: "1 июля 2026 года взыскать 10\u{00A0}000 рублей в течение 30 дней по пункту 2 статьи 15. УИД 77RS0001-01-2026-000001-10.")
        let citation = SummaryCitation(paragraphID: "¶1", evidenceQuote: "взыскать")
        let valid = ActSummary(disposition: [SummaryClaim(
            text: "1 июля 2026 года взыскать 10 000 рублей в течение 30 дней по пункту 2 статьи 15; УИД 77RS0001-01-2026-000001-10.",
            citations: [citation])])
        XCTAssertNoThrow(try ActSummaryValidator.validate(valid, against: source))

        let invalid = ActSummary(deadlines: [SummaryClaim(
            text: "Срок составляет 45 дней, УИД 77RS0001-01-2026-999999-10.",
            citations: [citation])])
        XCTAssertThrowsError(try ActSummaryValidator.validate(invalid, against: source))
    }

    func testClaimIDIsLocalAndNotRequiredInStructuredJSON() throws {
        let json = #"{"text":"Вывод","citations":[]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SummaryClaim.self, from: json)
        XCTAssertEqual(decoded.text, "Вывод")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        XCTAssertNil(encoded?["id"])
    }
}
