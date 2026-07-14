import XCTest
import SudrfKit
@testable import SudrfApp

final class KoAPMovementTargetTests: XCTestCase {
    private func cart(_ level: CourtLevel, _ id: String) throws -> Cartoteka {
        try XCTUnwrap(CartotekaRegistry.find(level: level, id: id))
    }

    private func targets(level: CourtLevel, id: String, uid: String?,
                         districts: [(domain: String, title: String)] = []) throws
        -> [MovementSearchTarget] {
        try XCTUnwrap(MovementTargetBuilder.targets(
            branch: .general, courtLevel: level, baseCartoteka: cart(level, id),
            caseNumber: "12-1/2026", judicialUID: uid,
            courtTitle: level == .subject ? "Верховный Суд Республики Коми" : "Суд",
            courtCode: "11", region: "Республика Коми",
            displayDomain: level == .subject ? "vs.komi.sudrf.ru" : "syktsud.komi.sudrf.ru",
            districtCourts: districts))
    }

    func testMagistrateTargetsIncludeOptionalAppealAndBothTransitionCourts() throws {
        let result = try targets(
            level: .magistrate, id: "adm", uid: "11MS0062-01-2025-000100-10",
            districts: [("syktsud.komi.sudrf.ru", "Сыктывкарский городской суд")])
        XCTAssertTrue(result.contains { $0.courtLevel == .district && $0.cartotekaIDs == ["admj"] })
        XCTAssertTrue(result.contains { $0.courtLevel == .subject && $0.cartotekaIDs == ["adm33"] })
        XCTAssertTrue(result.contains {
            $0.courtLevel == .cassation && $0.cartotekaIDs == ["adm3"]
                && $0.dateRule == .koapKSOYuBeforeMay2026Possible
        })
    }

    func testMSDistrictAdmjNeverTargetsAdm2() throws {
        let result = try targets(level: .district, id: "admj",
                                 uid: "11MS0062-01-2025-000100-10")
        XCTAssertFalse(result.contains { $0.cartotekaIDs == ["adm2"] })
        XCTAssertTrue(result.contains { $0.cartotekaIDs == ["adm33"] })
    }

    func testRSDistrictAdmjTargetsAdm2AndHistoricalReview() throws {
        let result = try targets(level: .district, id: "admj",
                                 uid: "11RS0001-01-2025-000100-10")
        XCTAssertTrue(result.contains { $0.cartotekaIDs == ["adm2"] })
        XCTAssertTrue(result.contains {
            $0.cartotekaIDs == ["adm33"]
                && $0.dateRule == .koapSubjectBeforeOctober2019Possible
        })
        XCTAssertTrue(result.contains { $0.cartotekaIDs == ["adm3"] })
    }

    func testDistrictAdmAndSubjectReviewCartotekasUseTheirExactRoutes() throws {
        let district = try targets(level: .district, id: "adm",
                                   uid: "11RS0001-01-2025-000100-10")
        XCTAssertTrue(district.contains { $0.cartotekaIDs == ["adm1"] })
        XCTAssertFalse(district.contains { $0.cartotekaIDs == ["adm2"] })

        for id in ["adm1", "adm2"] {
            let subject = try targets(level: .subject, id: id,
                                      uid: "11RS0001-01-2025-000100-10")
            XCTAssertTrue(subject.contains {
                $0.cartotekaIDs == ["adm33"]
                    && $0.dateRule == .koapSubjectBeforeOctober2019Possible
            })
            XCTAssertTrue(subject.contains { $0.cartotekaIDs == ["adm3"] })
        }
    }

    func testFinalReviewAnchorsHaveNoHigherTargets() throws {
        XCTAssertTrue(try targets(level: .subject, id: "adm33",
                                  uid: "11MS0062-01-2025-000100-10").isEmpty)
        XCTAssertTrue(try targets(level: .cassation, id: "adm3",
                                  uid: "11RS0001-01-2025-000100-10").isEmpty)
    }
}
