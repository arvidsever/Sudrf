import XCTest
@testable import SudrfKit

final class CourtActHeadingNormalizerTests: XCTestCase {
    func testKnownTitlesKeepWordBoundariesAcrossWhitespaceVariants() {
        let nbsp = "\u{00a0}"
        let variants: [(String, String)] = [
            ("РЕШЕНИЕ", "РЕШЕНИЕ"),
            ("ЗАОЧНОЕ РЕШЕНИЕ", "ЗАОЧНОЕ РЕШЕНИЕ"),
            ("З А О Ч Н О Е Р Е Ш Е Н И Е", "ЗАОЧНОЕ РЕШЕНИЕ"),
            ("З  А  О  Ч  Н  О  Е   Р  Е  Ш  Е  Н  И  Е", "ЗАОЧНОЕ РЕШЕНИЕ"),
            ("З\(nbsp)\(nbsp)А\(nbsp)О\(nbsp)Ч\(nbsp)Н\(nbsp)О\(nbsp)Е\(nbsp)Р\(nbsp)Е\(nbsp)Ш\(nbsp)Е\(nbsp)Н\(nbsp)И\(nbsp)Е", "ЗАОЧНОЕ РЕШЕНИЕ"),
            ("ОПРЕДЕЛЕНИЕ", "ОПРЕДЕЛЕНИЕ"),
            ("ПОСТАНОВЛЕНИЕ", "ПОСТАНОВЛЕНИЕ"),
            ("ПРИГОВОР", "ПРИГОВОР"),
        ]

        for (source, canonical) in variants {
            XCTAssertEqual(CourtActHeadingNormalizer.normalize(source), [.title(canonical)], source)
        }
    }

    func testSubtitleAndCompoundHeadingNormalizeAsComponents() {
        XCTAssertEqual(CourtActHeadingNormalizer.normalize("Именем Российской Федерации"), [
            .subtitle("Именем Российской Федерации"),
        ])
        XCTAssertEqual(CourtActHeadingNormalizer.normalize(
            "Р Е Ш Е Н И ЕИменем Российской Федерации"), [
                .title("РЕШЕНИЕ"), .subtitle("Именем Российской Федерации"),
            ])
    }

    func testMixedCaseTitleAndProseRemainUnchanged() {
        for source in ["Решение", "РЕШЕНИЕ суда", "Суд вынес РЕШЕНИЕ", "РЕШЕНИЕ."] {
            XCTAssertNil(CourtActHeadingNormalizer.normalize(source), source)
        }
    }
}
