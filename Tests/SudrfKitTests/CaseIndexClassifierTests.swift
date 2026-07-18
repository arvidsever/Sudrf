import XCTest
@testable import SudrfKit

final class CaseIndexClassifierTests: XCTestCase {
    func testGarrisonCatalog() {
        let cases: [(String, ProcessKind?, CaseIndexCardRole, CaseMaterialLinkPolicy)] = [
            ("1-20/2026", .upk, .firstInstanceCase, .standalone),
            ("2-20/2026", .civil, .firstInstanceCase, .standalone),
            ("2A-20/2026", .administrative, .firstInstanceCase, .standalone),
            ("3/15-20/2026", .upk, .judicialControlMaterial, .standalone),
            ("4/17-20/2026", .upk, .sentenceExecutionMaterial, .standalone),
            ("5-20/2026", .koap, .firstInstanceCase, .standalone),
            ("8/2-20/2026", .upk, .proceduralMaterial, .standalone),
            ("М-20/2026", nil, .preliminaryIntakeMaterial, .mayBecomeMainCase),
            ("ДА-20/2026", .koap, .disciplinaryMaterial, .standalone),
            ("12-20/2026", .koap, .appellateComplaint, .requiresVerifiedParent),
            ("13а-20/2026", .administrative, .decisionExecutionMaterial, .requiresVerifiedParent),
            ("14-20/2026", .upk, .operationalSearchMaterial, .standalone),
            ("15-20/2026", nil, .otherMaterial, .standalone),
        ]
        for (number, kind, role, policy) in cases {
            let info = CaseIndexClassifier.classify(caseNumber: number, level: .garrison)
            XCTAssertEqual(info?.processKind, kind, number)
            XCTAssertEqual(info?.cardRole, role, number)
            XCTAssertEqual(info?.materialLinkPolicy, policy, number)
        }
    }

    func testSameIndexIsLevelSensitive() {
        XCTAssertEqual(CaseIndexClassifier.classify(caseNumber: "2-3/2026", level: .garrison)?.cardRole,
                       .firstInstanceCase)
        XCTAssertEqual(CaseIndexClassifier.classify(caseNumber: "2-3/2026", level: .circuitOrFleet)?.cardRole,
                       .firstInstanceCase)
        XCTAssertEqual(CaseIndexClassifier.classify(caseNumber: "22-3/2026", level: .circuitOrFleet)?.cardRole,
                       .appellateCase)
    }

    func testGeneralPublicAPIAndCatalog() {
        let cases: [(String, CourtLevel, ProcessKind?, CaseIndexCardRole, CaseMaterialLinkPolicy)] = [
            ("9а-1/2026", .district, .administrative, .preliminaryIntakeMaterial, .mayBecomeMainCase),
            ("9У-1/2026", .district, .upk, .preliminaryIntakeMaterial, .mayBecomeMainCase),
            ("10-1/2026", .district, .upk, .appellateCase, .requiresVerifiedParent),
            ("11а-1/2026", .district, .administrative, .appellateCase, .requiresVerifiedParent),
            ("13-1/2026", .district, .civil, .decisionExecutionMaterial, .requiresVerifiedParent),
            ("22К-1/2026", .subject, .upk, .appellateComplaint, .requiresVerifiedParent),
            ("33а-1/2026", .subject, .administrative, .appellateCase, .requiresVerifiedParent),
            ("7-1/2026", .subject, .koap, .appellateComplaint, .requiresVerifiedParent),
            ("55К-1/2026", .appeal, .upk, .judicialControlMaterial, .standalone),
        ]
        for (number, level, kind, role, policy) in cases {
            let info = CaseIndexClassifier.classify(caseNumber: number, courtLevel: level, branch: .general)
            XCTAssertEqual(info?.processKind, kind, number)
            XCTAssertEqual(info?.cardRole, role, number)
            XCTAssertEqual(info?.materialLinkPolicy, policy, number)
        }
    }

    func testHigherMilitaryCatalog() {
        let cases: [(String, MilitaryCaseIndexLevel, ProcessKind, CaseIndexCardRole)] = [
            ("55-5/2026", .militaryAppeal, .upk, .appellateCase),
            ("55К-5/2026", .militaryAppeal, .upk, .judicialControlMaterial),
            ("66а-5/2026", .militaryAppeal, .administrative, .appellateCase),
            ("7Y-5/2026", .militaryCassation, .upk, .cassationComplaint),
            ("77-5/2026", .militaryCassation, .upk, .cassationCase),
            ("8G-5/2026", .militaryCassation, .civil, .cassationComplaint),
            ("88А-5/2026", .militaryCassation, .administrative, .cassationCase),
            ("16-5/2026", .militaryCassation, .koap, .cassationCase),
            ("55К-5/2026", .militaryCassation, .upk, .judicialControlMaterial),
        ]
        for (number, level, kind, role) in cases {
            let info = CaseIndexClassifier.classify(caseNumber: number, level: level)
            XCTAssertEqual(info?.processKind, kind, number)
            XCTAssertEqual(info?.cardRole, role, number)
        }
    }

    func testCircuitMilitaryCaseNumbersAreNotTreatedAsServiceMail() {
        XCTAssertEqual(CaseIndexClassifier.classify(
            caseNumber: "2-3/2026", courtLevel: .subject,
            branch: .military)?.cardRole, .firstInstanceCase)
        XCTAssertEqual(CaseIndexClassifier.classify(
            caseNumber: "33-3/2026", courtLevel: .subject,
            branch: .military)?.cardRole, .appellateCase)
        XCTAssertEqual(CaseIndexClassifier.classify(
            caseNumber: "7-3/2026", courtLevel: .subject,
            branch: .military)?.processKind, .koap)
    }

    func testNormalizesIndexOnlyWhenNumberIsComplete() {
        XCTAssertEqual(CaseIndexClassifier.normalizedIndex(from: " № 3/1-44/2026 ~ М-2/2026"), "3/1")
        XCTAssertEqual(CaseIndexClassifier.normalizedIndex(from: "8G-44/2026"), "8г")
        XCTAssertNil(CaseIndexClassifier.normalizedIndex(from: "3/1"))
    }
}
