import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class Issue319LifecycleTests: XCTestCase {
    private let today = DateUtil.parse("22.09.2026")!

    private func movement(number: String, instances: [CaseInstance]) -> CaseMovement {
        CaseMovement(uid: "11RS0001-01-2026-003190-11", caseNumber: number,
                     inForce: false, instances: instances, complaints: [:], acts: [])
    }

    private func instance(level: CaseInstance.Level = .first,
                          number: String, result: String?,
                          sessions: [CaseSession]) -> CaseInstance {
        CaseInstance(level: level, court: "Сыктывкарский городской суд",
                     caseNumber: number, judge: nil,
                     domain: "syktsud.komi.sudrf.ru", foundByUID: false,
                     result: result, sessions: sessions)
    }

    func testIndeterminateDeadlineNoLongerKeepsExactTerminalOutcomeActive() {
        let result = "Производство по делу прекращено"
        let first = instance(number: "2-431/2026", result: result, sessions: [
            CaseSession(date: "10.02.2026", event: "Судебное заседание", result: result),
        ])
        let assessment = DeadlineRuleAssessment(
            ruleID: "GPK-APPEAL-GENERAL", kind: "appeal",
            statusRaw: DeadlineAssessmentStatus.insufficientEvidence.rawValue,
            missingEvidenceRaw: [DeadlineEvidenceRequirement.finalForm.rawValue])

        let resolution = CaseLifecycleResolver.resolve(
            movement: movement(number: first.caseNumber, instances: [first]),
            production: .civil, deadlines: [], deadlineAssessments: [assessment],
            today: today)

        XCTAssertEqual(resolution.stage, .done)
        XCTAssertEqual(resolution.completionReason, .terminalFirst(result))
    }

    func testStandaloneRootMaterialParticipatesButNestedMaterialDoesNot() {
        let rootResult = "ОТКАЗАНО в принятии заявления"
        let root = instance(level: .material, number: "9а-292/2025",
                            result: rootResult, sessions: [
            CaseSession(date: "12.08.2025", event: "Решение вопроса о принятии",
                        result: rootResult),
        ])
        let rootMovement = movement(number: root.caseNumber, instances: [root])
        XCTAssertEqual(CaseLifecycleResolver.resolve(
            movement: rootMovement, production: .kas, deadlines: [], today: today).stage,
                       .done)

        let first = instance(number: "2-100/2026", result: nil, sessions: [
            CaseSession(date: "01.09.2026", event: "Иск принят к производству"),
        ])
        let nested = instance(level: .material, number: "13-6644/2023",
                              result: "Производство прекращено", sessions: [
            CaseSession(date: "20.09.2026", event: "Рассмотрение материала",
                        result: "Производство прекращено"),
        ])
        let nestedResolution = CaseLifecycleResolver.resolve(
            movement: movement(number: first.caseNumber, instances: [first, nested]),
            production: .civil, deadlines: [], today: today)
        XCTAssertEqual(nestedResolution.stage, .first)
        XCTAssertEqual(nestedResolution.currentInstance?.caseNumber, first.caseNumber)
        XCTAssertNil(nestedResolution.completionReason)
    }

    func testStandaloneMaterialFamiliesUseTheirOwnTerminalOutcome() {
        for number in ["15-12/2026", "13-33/2026", "4/17-8/2026", "3/10-5/2026"] {
            let root = instance(level: .material, number: number,
                                result: "Удовлетворено", sessions: [
                CaseSession(date: "12.08.2026", event: "Рассмотрение материала",
                            result: "Удовлетворено"),
            ])
            let source = movement(number: number, instances: [root])
            let resolution = CaseLifecycleResolver.resolve(
                movement: source, production: .crim, deadlines: [], today: today)
            XCTAssertEqual(resolution.stage, .done, number)
            XCTAssertEqual(resolution.currentInstance?.caseNumber, number)
        }
    }

    func testDuplicateRootMaterialIdentityFailsClosed() {
        let first = instance(level: .material, number: "13-33/2026",
                             result: "Удовлетворено", sessions: [
            CaseSession(date: "12.08.2026", event: "Рассмотрение материала",
                        result: "Удовлетворено"),
        ])
        var duplicate = first
        duplicate.domain = "other.sudrf.ru"
        let resolution = CaseLifecycleResolver.resolve(
            movement: movement(number: first.caseNumber, instances: [first, duplicate]),
            production: .crim, deadlines: [], today: today)
        XCTAssertEqual(resolution.stage, .first)
        XCTAssertNil(resolution.completionReason)
    }

    func testReturnedKoAPProtocolIsTerminalButGenericReturnIsNot() {
        let exact = "Протокол об административном правонарушении и другие материалы дела возвращены для устранения недостатков"
        let returned = instance(number: "5-32/2026", result: exact, sessions: [
            CaseSession(date: "10.01.2026", event: "Рассмотрение дела", result: exact),
        ])
        XCTAssertEqual(CaseLifecycleResolver.resolve(
            movement: movement(number: returned.caseNumber, instances: [returned]),
            production: .koap, deadlines: [], today: today).stage, .done)

        let generic = instance(number: "5-33/2026",
                               result: "Материалы дела возвращены в суд первой инстанции",
                               sessions: [CaseSession(
                                date: "10.01.2026", event: "Материалы дела возвращены")])
        XCTAssertEqual(CaseLifecycleResolver.resolve(
            movement: movement(number: generic.caseNumber, instances: [generic]),
            production: .koap, deadlines: [], today: today).stage, .first)
    }

    func testLaterExactTerminalOutcomeBeatsAmbiguousAppealFallback() {
        let terminal = "Производство по делу прекращено"
        var first = instance(number: "2-2353/2023", result: terminal, sessions: [
            CaseSession(date: "01.09.2026", event: "Иск принят к производству"),
            CaseSession(date: "09.09.2026", event: "Иск повторно принят к производству"),
            CaseSession(date: "11.09.2026", event: "Судебное заседание", result: terminal),
        ])
        first.sourceEvidence = .init(decisionDate: "11.09.2026")
        let appeal = CaseInstance(
            level: .appeal, court: "Верховный Суд Республики Коми",
            caseNumber: "33-100/2026", judge: nil,
            domain: "vs.komi.sudrf.ru", foundByUID: true,
            result: "Оставлено без изменения", sessions: [
                CaseSession(date: "05.09.2026", event: "Судебное заседание",
                            result: "Оставлено без изменения"),
            ], sourceEvidence: .init(decisionDate: "05.09.2026"))
        let source = movement(number: first.caseNumber, instances: [first, appeal])
        XCTAssertTrue(CaseLifecycleResolver.timeline(
            in: source, production: .civil).hasAmbiguousAppealEffect)
        XCTAssertEqual(CaseLifecycleResolver.resolve(
            movement: source, production: .civil, deadlines: [], today: today).stage,
                       .done)
    }
}
