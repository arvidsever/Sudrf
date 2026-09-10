import XCTest
@testable import SudrfApp
import SudrfKit

final class ActFormatterTests: XCTestCase {
    func testShortSingleLineProducesStyledBlocksFromSharedParagraphs() {
        let source = "Дело № 2-1/2026 Р Е Ш Е Н И Е Именем Российской Федерации установил: обстоятельства доказаны. решил: иск удовлетворить."
        let paragraphs = ActParagraphizer.paragraphs(in: source)

        XCTAssertEqual(CourtActFormatter.parse(source, paragraphs: paragraphs), [
            .meta("Дело № 2-1/2026"),
            .title("Р Е Ш Е Н И Е"),
            .subtitle("Именем Российской Федерации"),
            .verb("установил:"),
            .paragraph("обстоятельства доказаны."),
            .verb("решил:"),
            .paragraph("иск удовлетворить."),
        ])
    }

    func testFormatterRecognizesWhitespaceVariants() {
        let paragraphs = [
            ActParagraph(ordinal: 1, text: "Дело\u{00a0}№\u{00a0}2-1/2026"),
            ActParagraph(ordinal: 2, text: "П О С Т А Н О В Л Е Н И Е"),
            ActParagraph(ordinal: 3, text: "Именем\u{00a0}Российской\u{00a0}Федерации"),
        ]

        XCTAssertEqual(CourtActFormatter.parse("", paragraphs: paragraphs), [
            .meta("Дело\u{00a0}№\u{00a0}2-1/2026"),
            .title("П О С Т А Н О В Л Е Н И Е"),
            .subtitle("Именем Российской Федерации"),
        ])
    }

    func testStandaloneVerbWithoutColonIsStyledButProseIsNot() {
        let paragraphs = [
            ActParagraph(ordinal: 1, text: "решил"),
            ActParagraph(ordinal: 2, text: "У С Т А Н О В И Л :"),
            ActParagraph(ordinal: 3, text: "Суд установил обстоятельства"),
        ]

        XCTAssertEqual(CourtActFormatter.parse("", paragraphs: paragraphs), [
            .verb("решил"),
            .verb("У С Т А Н О В И Л :"),
            .paragraph("Суд установил обстоятельства"),
        ])
    }

    func testParagraphAndBlockIdentityRemainAlignedAfterSegmentation() {
        let source = "ОПРЕДЕЛЕНИЕ определил: заявление возвратить."
        let paragraphs = ActParagraphizer.paragraphs(in: source)
        let blocks = CourtActFormatter.parseIdentified(source, paragraphs: paragraphs)

        XCTAssertEqual(blocks.map(\.paragraphID), paragraphs.map(\.id))
        XCTAssertEqual(blocks.map(\.blockID), paragraphs.map(\.id))
    }
}
