import XCTest
import Security
@testable import SudrfKit

/// Якоря TLS для доменов судов: все три сертификата Минцифры (корень + два
/// промежуточных) обязаны загружаться из ресурсов пакета. Если ресурс потерян
/// (переименован файл, сломан Package.swift), делегат молча деградирует к
/// системным корням и все sudrf-хосты перестанут открываться — тест ловит
/// это на CI, а не у пользователя.
final class TLSAnchorsTests: XCTestCase {

    func testRussianAnchorsLoadFromBundle() {
        let anchors = SudrfTLSDelegate.russianAnchors
        XCTAssertEqual(anchors.count, 3, "корень + Sub CA 2022 + Sub CA 2024")

        let subjects = anchors.compactMap {
            SecCertificateCopySubjectSummary($0) as String?
        }
        XCTAssertTrue(subjects.contains("Russian Trusted Root CA"), "\(subjects)")
        XCTAssertEqual(subjects.filter { $0.contains("Russian Trusted Sub CA") }.count, 2)
    }
}
