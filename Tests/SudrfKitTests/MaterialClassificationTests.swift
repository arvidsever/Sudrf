import XCTest
@testable import SudrfKit

final class MaterialClassificationTests: XCTestCase {
    func testExplicitConflictBlocksOwnIndexAndRelatedFallbacks() {
        for cart in ["g1", "m", "unknown"] {
            let value = CaseIndexClassifier.classifyMaterialContext(
                caseNumber: "13-1/2026", courtLevel: .district, cartotekaID: cart,
                sourceProcessKind: .civil, sourceProcessKindConflict: true, verifiedRelatedKinds: [.civil])
            XCTAssertNil(value.processKind)
            XCTAssertEqual(value.basis, .conflict)
        }
    }

    func testKnownMaterialWithoutCourtLevelUsesVerifiedRelationWithoutIndexGuess() {
        let value = CaseIndexClassifier.classifyMaterialContext(
            caseNumber: "2-1/2026", cardRole: .otherMaterial, verifiedRelatedKinds: [.koap])
        XCTAssertEqual(value.processKind, .koap)
        XCTAssertEqual(value.cardRole, .otherMaterial)
        XCTAssertEqual(value.basis, .verifiedRelation)
        XCTAssertNil(CaseIndexClassifier.classifyMaterialContext(caseNumber: "2-1/2026").processKind)
    }

    func testVerifiedParentSuppliesEveryCodeForGenericMaterial() {
        for kind: ProcessKind in [.civil, .administrative, .upk, .koap] {
            let value = CaseIndexClassifier.classifyMaterialContext(
                caseNumber: "15-108/2026", courtLevel: .district,
                cartotekaID: "m", verifiedRelatedKinds: [kind, kind])
            XCTAssertEqual(value.cardRole, .otherMaterial)
            XCTAssertEqual(value.processKind, kind)
            XCTAssertEqual(value.basis, .verifiedRelation)
        }
    }

    func testVerifiedRelationIsStrongerThanIndex() {
        let value = CaseIndexClassifier.classifyMaterialContext(
            caseNumber: "13-108/2026", courtLevel: .district,
            cartotekaID: "m", verifiedRelatedKinds: [.koap])
        XCTAssertEqual(value.processKind, .koap)
        XCTAssertEqual(value.basis, .verifiedRelation)
    }

    func testOwnSourceAndRelationConflictsDoNotGuess() {
        for value in [
            CaseIndexClassifier.classifyMaterialContext(
                caseNumber: "15-108/2026", courtLevel: .district,
                cartotekaID: "p1", sourceProcessKind: .koap),
            CaseIndexClassifier.classifyMaterialContext(
                caseNumber: "15-108/2026", courtLevel: .district,
                sourceProcessKind: .koap, verifiedRelatedKinds: [.civil]),
            CaseIndexClassifier.classifyMaterialContext(
                caseNumber: "15-108/2026", courtLevel: .district,
                cartotekaID: "m", verifiedRelatedKinds: [.upk, .civil])
        ] {
            XCTAssertNil(value.processKind)
            XCTAssertEqual(value.basis, .conflict)
        }
    }

    func testSpecializedCartotekaContinuesPastAmbiguousPreliminaryIndex() {
        for level: CourtLevel in [.district, .subject] {
            let value = CaseIndexClassifier.classifyMaterialContext(
                caseNumber: "М-123/2026", courtLevel: level, cartotekaID: "p1")
            XCTAssertEqual(value.cardRole, .preliminaryIntakeMaterial)
            XCTAssertEqual(value.processKind, .administrative)
            XCTAssertEqual(value.basis, .ownSource)
        }
    }

    func testUnknownAndGeneralCartotekaDoNotDefaultToCivil() {
        for cart in ["m", "unknown", "g999", "u999"] {
            let value = CaseIndexClassifier.classifyMaterialContext(
                caseNumber: "15-123/2026", courtLevel: .district, cartotekaID: cart)
            XCTAssertNil(value.processKind)
            XCTAssertEqual(value.basis, .unknown)
        }
        let invalidForLevel = CaseIndexClassifier.classifyMaterialContext(
            caseNumber: "unknown-1/2026", courtLevel: .appeal, cartotekaID: "u1")
        XCTAssertNil(invalidForLevel.processKind)
    }

    func testUnknownNumberInMaterialCartotekaHasMaterialRole() {
        let value = CaseIndexClassifier.classifyMaterialContext(
            caseNumber: "не опубликован", courtLevel: .district,
            cartotekaID: "m", verifiedRelatedKinds: [.administrative])
        XCTAssertEqual(value.cardRole, .otherMaterial)
        XCTAssertEqual(value.processKind, .administrative)
    }

    func testKnownIndicesAndLevelsStayDistinct() {
        let district = CaseIndexClassifier.classifyMaterialContext(
            caseNumber: "2-1/2026", courtLevel: .district)
        let subject = CaseIndexClassifier.classifyMaterialContext(
            caseNumber: "2-1/2026", courtLevel: .subject)
        XCTAssertEqual(district.processKind, .civil)
        XCTAssertEqual(subject.processKind, .upk)
        let control = CaseIndexClassifier.classifyMaterialContext(
            caseNumber: "55К-1/2026", courtLevel: .appeal, branch: .military)
        XCTAssertEqual(control.cardRole, .judicialControlMaterial)
        XCTAssertEqual(control.processKind, .upk)
        XCTAssertEqual(control.basis, .index)
    }

    func testRelatedKindDoesNotReclassifyMainCaseOrAppeal() {
        for number in ["2-1/2026", "12-1/2026"] {
            let value = CaseIndexClassifier.classifyMaterialContext(
                caseNumber: number, courtLevel: .district, verifiedRelatedKinds: [.upk])
            XCTAssertNotEqual(value.processKind, .upk)
            XCTAssertNotEqual(value.basis, .verifiedRelation)
            XCTAssertFalse(value.cardRole!.isMaterial)
        }
    }

    func testDisciplinaryIndexDoesNotSupplyKoap() {
        let value = CaseIndexClassifier.classifyMaterialContext(
            caseNumber: "ДА-1/2026", courtLevel: .district, branch: .military,
            cartotekaID: "m")
        XCTAssertEqual(value.cardRole, .disciplinaryMaterial)
        XCTAssertNil(value.processKind)
    }

    func testSpecialProceedingsAreCompatibleWithCivilSource() {
        let value = CaseIndexClassifier.classifyMaterialContext(
            caseNumber: "М-1/2026", courtLevel: .district, cartotekaID: "g1",
            sourceProcessKind: .special, verifiedRelatedKinds: [.civil])
        XCTAssertEqual(value.processKind, .special)
        XCTAssertEqual(value.basis, .ownSource)
    }
}
