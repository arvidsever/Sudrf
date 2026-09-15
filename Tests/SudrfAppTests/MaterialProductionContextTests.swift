import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class MaterialProductionContextTests: XCTestCase {
    private let uid = "11RS0001-01-2026-000100-11"
    private func instance(_ number: String, id: String, cart: String, uid: String? = nil,
                          level: CaseInstance.Level = .first) -> CaseInstance {
        CaseInstance(level: level, court: "Сыктывкарский городской суд", caseNumber: number,
                     judge: nil, domain: "syktsud--komi.sudrf.ru", foundByUID: false,
                     result: nil, sessions: [],
                     sourceURL: URL(string: "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=\(id)&delo_id=1500001&srv_num=1"),
                     sourceEvidence: .init(judicialUID: uid, cartotekaID: cart,
                                           sourceCourtLevel: .district, sourceBranch: .general))
    }
    private func movement(_ instances: [CaseInstance]) -> CaseMovement {
        CaseMovement(uid: uid, caseNumber: instances[0].caseNumber, inForce: false,
                     instances: instances, complaints: [:], acts: [])
    }

    func testFullJudicialUIDSuppliesKoAPToAmbiguousMaterial() {
        let material = instance("15-100/2026", id: "1", cart: "m", uid: uid, level: .material)
        let parent = instance("5-200/2026", id: "2", cart: "adm", uid: uid)
        let result = MaterialProductionContext.resolve(instance: material, movement: movement([parent, material]))
        XCTAssertEqual(result.production, .koap)
        XCTAssertEqual(result.basis, .verifiedRelation)
    }

    func testConflictingRelatedMainKindsStayUnknown() {
        let material = instance("15-100/2026", id: "1", cart: "m", uid: uid, level: .material)
        let koap = instance("5-200/2026", id: "2", cart: "adm", uid: uid)
        let civil = instance("2-200/2026", id: "3", cart: "g1", uid: uid)
        let result = MaterialProductionContext.resolve(instance: material,
                                                       movement: movement([koap, material, civil]))
        XCTAssertNil(result.production)
        XCTAssertEqual(result.basis, .conflict)
    }

    func testTechnicalGUIDDoesNotEstablishJudicialUIDRelation() {
        let guid = "5989d6d8-c622-4602-a2a4-77bfa94c7429"
        let material = instance("15-100/2026", id: "1", cart: "m", uid: guid, level: .material)
        let parent = instance("5-200/2026", id: "2", cart: "adm", uid: guid)
        XCTAssertNil(MaterialProductionContext.resolve(instance: material,
                         movement: movement([parent, material])).production)
    }

    func testExactPreviousRegistrationLinkWorksInEitherDirection() throws {
        let original = instance("15-100/2026", id: "1", cart: "m", level: .material)
        let main = instance("5-200/2026", id: "2", cart: "adm")
        for reverse in [false, true] {
            var material = original
            var parent = main
            if reverse {
                parent.previousRegistration = .init(caseNumber: material.caseNumber,
                                                     url: try XCTUnwrap(material.sourceURL))
            } else {
                material.previousRegistration = .init(caseNumber: parent.caseNumber,
                                                       url: try XCTUnwrap(parent.sourceURL))
            }
            XCTAssertEqual(MaterialProductionContext.resolve(instance: material,
                movement: movement([parent, material])).production, .koap)
        }
    }

    func testFailedRelatedCardDoesNotSupplyContext() {
        let material = instance("15-100/2026", id: "1", cart: "m", uid: uid, level: .material)
        var parent = instance("5-200/2026", id: "2", cart: "adm", uid: uid)
        parent.transientError = true
        XCTAssertNil(MaterialProductionContext.resolve(instance: material,
                         movement: movement([parent, material])).production)
    }
    func testHistoricalUIDDiscoveryUsesExactMainContextWithoutGuessingMaterialCourtLevel() throws {
        var material = instance("15-100/2026", id: "1", cart: "m", level: .material)
        material.sourceEvidence = nil
        material.foundByUID = true
        var parent = instance("5-200/2026", id: "2", cart: "adm")
        parent.sourceEvidence = nil
        let context = MovementContext(
            branchRaw: "general", region: "Республика Коми", searchDomain: parent.domain,
            displayDomain: parent.domain, courtTitle: parent.court, courtLevelRaw: "district",
            courtCode: "11RS0001", cartotekaId: "adm", cartotekaLevelRaw: "district",
            caseNumber: parent.caseNumber, cardURLString: try XCTUnwrap(parent.sourceURL).absoluteString,
            judicialUID: uid)
        let dossier = movement([parent, material])
        XCTAssertEqual(MaterialProductionContext.resolve(instance: material, movement: dossier,
                                                         baseContext: context).production, .koap)
        material.sourceEvidence = .init(judicialUID: "11RS0001-01-2026-000999-11")
        XCTAssertNil(MaterialProductionContext.resolve(instance: material,
                         movement: movement([parent, material]), baseContext: context).production)
    }

    func testOwnCategoryCodeMarkerCanClassifyWithoutIndex() {
        var material = instance("15-100/2026", id: "1", cart: "m", level: .material)
        material.sourceEvidence?.category = "Вопросы исполнения постановления (КоАП РФ)"
        XCTAssertEqual(MaterialProductionContext.resolve(instance: material,
                        movement: movement([material])).production, .koap)
    }

    // Public card references from the archived issue-269 snapshot of 8 September 2026.
    // Participants and judges are intentionally omitted.
    func testArchivedKoAPMaterial15InheritsFromVerifiedMainCard() {
        var material = instance("15-108/2026", id: "41135412", cart: "m", level: .material)
        material.sourceEvidence = nil
        material.foundByUID = true
        material.domain = "syktsud.komi.sudrf.ru"
        material.sourceURL = URL(string: "https://syktsud.komi.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case&case_id=41135412&case_uid=fcc2a1b8-0721-4d42-8811-d31575cce284&delo_id=1610001")
        var parent = instance("5-469/2026", id: "35768698", cart: "adm")
        parent.sourceEvidence = nil
        parent.sourceURL = URL(string: "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case&case_id=35768698&case_uid=46a9b300-ffc6-44b6-b478-df808b52281b&delo_id=1500001")
        let context = MovementContext(
            branchRaw: "general", region: "Республика Коми", searchDomain: parent.domain,
            displayDomain: parent.domain, courtTitle: parent.court, courtLevelRaw: "district",
            courtCode: "11RS0001", cartotekaId: "adm", cartotekaLevelRaw: "district",
            caseNumber: parent.caseNumber, cardURLString: parent.sourceURL?.absoluteString,
            judicialUID: "11RS0001-01-2026-005022-94")
        var dossier = movement([parent, material])
        dossier.uid = "11RS0001-01-2026-005022-94"
        let result = MaterialProductionContext.resolve(instance: material, movement: dossier,
                                                       baseContext: context)
        XCTAssertEqual(result.production, .koap)
        XCTAssertEqual(result.basis, .verifiedRelation)
    }

    func testDirectLinkDoesNotOverrideContradictingJudicialUID() throws {
        var material = instance("15-100/2026", id: "1", cart: "m", uid: uid, level: .material)
        let parent = instance("5-200/2026", id: "2", cart: "adm", uid: "11RS0001-01-2026-000999-11")
        material.previousRegistration = .init(caseNumber: parent.caseNumber,
                                               url: try XCTUnwrap(parent.sourceURL))
        let result = MaterialProductionContext.resolve(instance: material,
                                                       movement: movement([parent, material]))
        XCTAssertNil(result.production)
        XCTAssertEqual(result.basis, .conflict)
    }

    func testForeignSourceHostCannotConfirmRelation() {
        let material = instance("15-100/2026", id: "1", cart: "m", uid: uid, level: .material)
        var parent = instance("5-200/2026", id: "2", cart: "adm", uid: uid)
        parent.domain = "other.sudrf.ru"
        XCTAssertNil(MaterialProductionContext.resolve(instance: material,
                         movement: movement([parent, material])).production)
    }

    func testNestedMilitaryMaterialUsesRootBranchForOldCache() {
        var material = instance("55К-100/2026", id: "1", cart: "m", level: .material)
        material.sourceEvidence = .init(sourceCourtLevel: .cassation)
        let context = MovementContext(
            branchRaw: CourtBranch.military.rawValue, region: "", searchDomain: "military.sudrf.ru",
            displayDomain: "military.sudrf.ru", courtTitle: "Окружной военный суд",
            courtLevelRaw: CourtLevel.subject.rawValue, cartotekaId: "u1",
            cartotekaLevelRaw: CourtLevel.subject.rawValue, caseNumber: "2-100/2026")
        let result = MaterialProductionContext.resolve(instance: material,
            movement: movement([material]), baseContext: context)
        XCTAssertEqual(result.production, .crim)
        XCTAssertTrue(result.isMaterial)
        XCTAssertEqual(result.basis, .index)
    }

}
