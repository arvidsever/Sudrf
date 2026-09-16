import XCTest
@testable import SudrfKit

/// Synthetic source-contract fixtures, not captures of live court cards.
final class MaterialProcessParserTests: XCTestCase {
    private func fixture(_ rows: String, lower: String = "") -> String {
        """
        <html><body><h2>ДЕЛО № 15-1/2026</h2>
        <ul class="tabs"><li id="tab1">ДЕЛО</li><li id="tab2">РАССМОТРЕНИЕ В НИЖЕСТОЯЩЕМ СУДЕ</li></ul>
        <div id="cont1"><table><tr><td>Уникальный идентификатор дела</td><td>00RS0000-00-2026-000001-00</td></tr>
        \(rows)</table></div><div id="cont2"><table>\(lower)</table></div></body></html>
        """
    }

    func testFourPublishedProcessKinds() throws {
        for (label, kind): (String, ProcessKind) in [
            ("Гражданское", .civil), ("Административное (КАС)", .administrative),
            ("Уголовное", .upk), ("Административное правонарушение", .koap)
        ] {
            let card = try CaseCardParser.parse(html: fixture(
                "<tr><td>Вид производства</td><td>\(label)</td></tr>"))
            XCTAssertEqual(card.processKind, kind, label)
        }
    }

    func testLowerCourtAndNestedTablesDoNotSupplyKind() throws {
        let row = "<tr><td>Вид производства</td><td>КоАП РФ</td></tr>"
        let html = fixture("<tr><td>Справка</td><td><table>\(row)</table></td></tr>", lower: row)
        XCTAssertNil(try CaseCardParser.parse(html: html).processKind)
    }

    func testConflictingDuplicateAndUnknownValuesAreUnknown() throws {
        for rows in [
            "<tr><td>Вид производства</td><td>КоАП РФ</td></tr><tr><td>Вид судопроизводства</td><td>Уголовное</td></tr>",
            "<tr><td>Вид производства</td><td>КоАП РФ</td></tr><tr><td>Вид производства</td><td>Уголовное</td></tr>",
            "<tr><td>Вид производства</td><td>Неизвестный вид</td></tr>",
            "<tr><td>Категория</td><td>статья КоАП РФ</td></tr>"
        ] {
            XCTAssertNil(try CaseCardParser.parse(html: fixture(rows)).processKind)
        }
    }

    func testOwnConflictSurvivesStoredEvidenceAndBlocksFallback() throws {
        let card = try CaseCardParser.parse(html: fixture(
            "<tr><td>Вид производства</td><td>КоАП РФ</td></tr><tr><td>Вид судопроизводства</td><td>Уголовное</td></tr>"))
        XCTAssertEqual(card.processKindConflict, true)
        let evidence = CaseInstance.SourceEvidence(card: card, cartotekaID: "g1", courtLevel: .district)
        let restored = try JSONDecoder().decode(CaseInstance.SourceEvidence.self,
                                                from: JSONEncoder().encode(evidence))
        let classification = CaseIndexClassifier.classifyMaterialContext(
            caseNumber: "15-1/2026", courtLevel: .district, cartotekaID: restored.cartotekaID,
            sourceProcessKind: restored.ownProcessKind,
            sourceProcessKindConflict: restored.ownProcessKindConflict, verifiedRelatedKinds: [.civil])
        XCTAssertNil(classification.processKind)
        XCTAssertEqual(classification.basis, .conflict)
        XCTAssertNil(try JSONDecoder().decode(CaseInstance.SourceEvidence.self,
                                              from: Data("{}".utf8)).ownProcessKindConflict)
    }

    func testFieldNormalizationAndRepeatedConsistentValues() throws {
        let card = try CaseCardParser.parse(html: fixture(
            "<tr><td>ВИД СУДОПРОИЗВОДСТВА</td><td> КАС РФ </td></tr><tr><td>Вид производства</td><td>Административное (КАС)</td></tr>"))
        XCTAssertEqual(card.processKind, .administrative)
        XCTAssertEqual(card.processKindConflict, false)
    }

    func testComplaintWithoutUIDUsesItsOwnMetadata() throws {
        let html = """
        <html><body><h2>ДЕЛО № 16-1/2026</h2>
        <ul class="tabs"><li id="tab1">ЖАЛОБА</li></ul>
        <div id="cont1"><table><tr><th>ДЕЛО</th></tr>
        <tr><td>Вид производства</td><td>КоАП РФ</td></tr>
        <tr><td>Дата поступления</td><td>01.01.2026</td></tr></table></div>
        </body></html>
        """
        XCTAssertEqual(try CaseCardParser.parse(html: html).processKind, .koap)
    }

    func testVintageOwnMetadata() throws {
        let html = """
        <html><body><div class="case-num">ДЕЛО № 15-1/2026</div>
        <div id="tab_content_Case"><table><tr><td>Вид производства</td><td>КоАП РФ</td></tr></table></div>
        </body></html>
        """
        XCTAssertEqual(try CaseCardParser.parse(html: html).processKind, .koap)
    }
}
