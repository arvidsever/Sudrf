import XCTest
@testable import SudrfKit

final class KoAPProceduralRoleTests: XCTestCase {
    func testUIDCourtKinds() {
        XCTAssertEqual(KoAPProceduralRole.uidCourtKind("11MS0062-01-2025-000100-10"), .magistrate)
        XCTAssertEqual(KoAPProceduralRole.uidCourtKind("11RS0001-01-2025-000100-10"), .district)
        XCTAssertNil(KoAPProceduralRole.uidCourtKind(nil))
    }

    func testDistrictAdmjRoles() {
        XCTAssertEqual(KoAPProceduralRole.resolve(
            courtLevel: .district, cartotekaID: "admj",
            judicialUID: "11MS0062-01-2025-000100-10"), .magistrateAppeal)
        XCTAssertEqual(KoAPProceduralRole.resolve(
            courtLevel: .district, cartotekaID: "admj",
            judicialUID: "11RS0001-01-2025-000100-10"), .authorityJudicialReview)
        XCTAssertEqual(KoAPProceduralRole.resolve(
            courtLevel: .district, cartotekaID: "admj", judicialUID: nil,
            lowerCourtTitle: "Судебный участок № 62"), .magistrateAppeal)
    }

    func testSubjectCartotekaRoles() {
        XCTAssertEqual(KoAPProceduralRole.resolve(
            courtLevel: .subject, cartotekaID: "adm1", judicialUID: nil), .subjectReview)
        XCTAssertEqual(KoAPProceduralRole.resolve(
            courtLevel: .subject, cartotekaID: "adm2", judicialUID: nil), .subjectReview)
        XCTAssertEqual(KoAPProceduralRole.resolve(
            courtLevel: .subject, cartotekaID: "adm33", judicialUID: nil), .finalActReview)
        XCTAssertEqual(KoAPProceduralRole.resolve(
            courtLevel: .cassation, cartotekaID: "adm3", judicialUID: nil), .finalActReview)
    }

    func testKoAPTransitionDateRules() {
        XCTAssertTrue(MovementDateRule.koapKSOYuBeforeMay2026Possible
            .matches(legalForceDate: "09.05.2026"))
        XCTAssertFalse(MovementDateRule.koapKSOYuBeforeMay2026Possible
            .matches(legalForceDate: "10.05.2026"))
        XCTAssertTrue(MovementDateRule.koapKSOYuBeforeMay2026Possible
            .matches(legalForceDate: nil))
        XCTAssertTrue(MovementDateRule.koapSubjectBeforeOctober2019Possible
            .matches(legalForceDate: "30.09.2019"))
        XCTAssertFalse(MovementDateRule.koapSubjectBeforeOctober2019Possible
            .matches(legalForceDate: "01.10.2019"))
    }
}
