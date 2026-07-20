import XCTest
@testable import SudrfKit

final class ActDocumentTests: XCTestCase {
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
}
