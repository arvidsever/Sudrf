import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class DeadlineRuleEngineTests: XCTestCase {
    private let today = DateUtil.parse("01.05.2026")!

    private func context(_ cartoteka: String) -> MovementContext {
        MovementContext(branchRaw: "general", region: "Республика Коми",
                        searchDomain: "syktsud--komi.sudrf.ru",
                        displayDomain: "syktsud.komi.sudrf.ru",
                        courtTitle: "Сыктывкарский городской суд",
                        courtLevelRaw: "district", courtCode: "11RS0001",
                        cartotekaId: cartoteka, cartotekaLevelRaw: "district",
                        caseNumber: "2-100/2026")
    }

    private func movement(cartoteka: String = "g", category: String? = "Споры из договоров",
                          inForce: Bool = false, sessions: [CaseSession],
                          extra: [CaseInstance] = []) -> CaseMovement {
        let number: String
        switch cartoteka {
        case "u": number = "1-100/2026"
        case "adm": number = "5-100/2026"
        default: number = "2-100/2026"
        }
        let first = CaseInstance(level: .first, court: "Сыктывкарский городской суд",
                                 caseNumber: number, judge: nil,
                                 domain: "syktsud.komi.sudrf.ru", foundByUID: false,
                                 result: sessions.last?.result, sessions: sessions)
        return CaseMovement(uid: "11RS0001-01-2026-000100-11", caseNumber: number,
                            inForce: inForce, instances: [first] + extra,
                            complaints: [:], acts: [], category: category)
    }

    private func snapshot(_ movement: CaseMovement, cartoteka: String = "g",
                          today: Date? = nil) -> CaseSnapshot {
        MovementDerivation.snapshot(from: movement, context: context(cartoteka),
                                    today: today ?? self.today)
    }

    private func evaluation(_ movement: CaseMovement, cartoteka: String = "g",
                            receipt: DeadlineTriggerProvenance? = nil) throws
        -> DeadlineRuleEngine.Evaluation {
        let registry = try LegalDeadlineRegistry.load()
        let production = ProductionType(cartotekaId: cartoteka)
        return DeadlineRuleEngine.evaluate(
            registry: registry, movement: movement,
            context: DeadlineRuleEngine.Context(movementContext: context(cartoteka),
                                                deliveryOrReceipt: receipt),
            timeline: CaseLifecycleResolver.timeline(in: movement, production: production),
            today: today)
    }

    private func qualifiedCivilMovement(date: String = "13.04.2026") -> CaseMovement {
        movement(sessions: [
            CaseSession(date: date, event: "Судебное заседание",
                        result: "Иск удовлетворён; решение принято в окончательной форме"),
        ])
    }

    func testGPKGeneralUsesRegistryMonthAndRecordsProvenance() throws {
        let snap = snapshot(qualifiedCivilMovement(date: "02.02.2026"))
        let deadline = try XCTUnwrap(snap.deadlines.single(where: { $0.kind == "appeal" }))
        let provenance = try XCTUnwrap(deadline.provenance)

        XCTAssertEqual(deadline.date, DateUtil.parse("02.03.2026"))
        XCTAssertEqual(provenance.ruleID, "GPK-APPEAL-GENERAL")
        XCTAssertGreaterThan(provenance.registryRevision, 0)
        XCTAssertFalse(provenance.sourceHash?.isEmpty ?? true)
        XCTAssertEqual(provenance.trigger.dateRaw, "02.02.2026")
        XCTAssertEqual(provenance.trigger.event, "Судебное заседание")
        XCTAssertTrue(provenance.policyIDs.contains("GPK-COUNTING-MONTH-YEAR-CALENDAR"))
        XCTAssertEqual(provenance.formula, "1 календарный месяц")
        XCTAssertEqual(provenance.source, "ст. 321 ч. 1 ГПК РФ")
        XCTAssertEqual(provenance.calculatedDateRef, deadline.dateRef)
        XCTAssertNotEqual(deadline.date, DateUtil.addDays(DateUtil.parse("02.02.2026")!, 30))
    }

    func testMissingFinalFormFailsClosedAndKeepsTerminalFirstActiveWithReason() {
        let mv = movement(sessions: [
            CaseSession(date: "13.04.2026", event: "Судебное заседание",
                        result: "Иск удовлетворён"),
        ])
        let snap = snapshot(mv)

        XCTAssertTrue(snap.deadlines.isEmpty)
        XCTAssertEqual(snap.deadlineAssessments?.single(where: {
            $0.ruleID == "GPK-APPEAL-GENERAL"
        })?.status, .insufficientEvidence)
        XCTAssertTrue(snap.deadlineAssessments?.single(where: {
            $0.ruleID == "GPK-APPEAL-GENERAL"
        })?.missingEvidenceRaw.contains(DeadlineEvidenceRequirement.finalForm.rawValue) ?? false)
        XCTAssertEqual(snap.stageRaw, CaseStageKind.first.rawValue)
        XCTAssertTrue(snap.nextEvent.contains("GPK-APPEAL-GENERAL"))
        XCTAssertTrue(snap.nextEvent.contains("окончательная форма акта"))
    }

    func testKnownSpecialCategoryDisplacesGeneralRule() {
        let mv = movement(category: "Упрощенное производство", sessions: [
            CaseSession(date: "13.04.2026", event: "Судебное заседание",
                        result: "Иск удовлетворён; решение принято в окончательной форме"),
        ])
        let snap = snapshot(mv)

        XCTAssertTrue(snap.deadlines.isEmpty)
        XCTAssertEqual(snap.deadlineAssessments?.single(where: {
            $0.ruleID == "GPK-APPEAL-GENERAL"
        })?.status, .notApplicable)
        XCTAssertEqual(snap.stageRaw, CaseStageKind.done.rawValue)
    }

    func testNoKnownCategoryIsInsufficientEvidenceRatherThanGeneralDeadline() {
        let mv = movement(category: nil, sessions: [
            CaseSession(date: "13.04.2026", event: "Судебное заседание",
                        result: "Иск удовлетворён; решение принято в окончательной форме"),
        ])
        let snap = snapshot(mv)

        XCTAssertTrue(snap.deadlines.isEmpty)
        XCTAssertEqual(snap.deadlineAssessments?.first?.status, .insufficientEvidence)
        XCTAssertTrue(snap.deadlineAssessments?.first?.missingEvidenceRaw.contains(
            DeadlineEvidenceRequirement.caseCategory.rawValue) ?? false)
    }

    func testKASActivatedRulesUseRegistryCalendarMonths() throws {
        let appealMovement = movement(cartoteka: "p", category: "Оспаривание решения органа",
                                      sessions: [
                                        CaseSession(
                                            date: "02.02.2026", event: "Судебное заседание",
                                            result: "Административное исковое заявление удовлетворено; решение принято в окончательной форме"),
                                      ])
        let appeal = try evaluation(appealMovement, cartoteka: "p")
        XCTAssertEqual(appeal.deadlines.single(where: { $0.kind == "appeal" })?.date,
                       DateUtil.parse("02.03.2026"))
        XCTAssertEqual(appeal.deadlines.single(where: { $0.kind == "appeal" })?.provenance?.ruleID,
                       "KAS-APPEAL-GENERAL")

        let cassationMovement = movement(cartoteka: "p", category: "Оспаривание решения органа",
                                         inForce: true, sessions: [
                                            CaseSession(date: "03.02.2026",
                                                        event: "Решение вступило в законную силу"),
                                         ])
        let cassation = try evaluation(cassationMovement, cartoteka: "p")
        XCTAssertEqual(cassation.deadlines.single(where: { $0.kind == "cassation" })?.date,
                       DateUtil.parse("03.08.2026"))
        XCTAssertEqual(cassation.deadlines.single(where: { $0.kind == "cassation" })?.provenance?.ruleID,
                       "KAS-CASSATION-KSOYU")
    }

    func testKoAPRequiresProvedReceiptAndDoesNotSubstituteDecisionDate() throws {
        let mv = movement(cartoteka: "adm", category: "Нарушение правил дорожного движения",
                          sessions: [
                            CaseSession(date: "01.04.2026", event: "Судебное заседание",
                                        result: "Постановление по делу об административном правонарушении"),
                          ])
        let noReceipt = snapshot(mv, cartoteka: "adm")
        XCTAssertTrue(noReceipt.deadlines.isEmpty)
        XCTAssertEqual(noReceipt.deadlineAssessments?.first?.status, .insufficientEvidence)
        XCTAssertTrue(noReceipt.deadlineAssessments?.first?.missingEvidenceRaw.contains(
            DeadlineEvidenceRequirement.deliveryOrReceipt.rawValue) ?? false)

        let receipt = DeadlineTriggerProvenance(
            event: "Вручена копия постановления", result: nil, dateRaw: "06.04.2026",
            court: "Сыктывкарский городской суд", levelRaw: "first", caseNumber: "5-100/2026")
        let evaluated = try evaluation(mv, cartoteka: "adm", receipt: receipt)
        let deadline = try XCTUnwrap(evaluated.deadlines.single(where: { $0.kind == "appeal" }))
        XCTAssertEqual(deadline.date, DateUtil.parse("16.04.2026"))
        XCTAssertEqual(deadline.provenance?.ruleID, "KOAP-APPEAL-INITIAL-GENERAL")
        XCTAssertEqual(deadline.provenance?.trigger.dateRaw, "06.04.2026")
    }

    func testWeekendEndpointIsUnsupportedRatherThanInventingWorkingDay() throws {
        let mv = movement(cartoteka: "adm", category: "Нарушение правил дорожного движения",
                          sessions: [
                            CaseSession(date: "01.04.2026", event: "Судебное заседание",
                                        result: "Постановление по делу об административном правонарушении"),
                          ])
        let receipt = DeadlineTriggerProvenance(
            event: "Вручена копия постановления", result: nil, dateRaw: "09.04.2026",
            court: "Сыктывкарский городской суд", levelRaw: "first", caseNumber: "5-100/2026")
        let evaluated = try evaluation(mv, cartoteka: "adm", receipt: receipt)
        let assessment = try XCTUnwrap(evaluated.assessments.single(where: {
            $0.ruleID == "KOAP-APPEAL-INITIAL-GENERAL"
        }))

        XCTAssertTrue(evaluated.deadlines.isEmpty)
        XCTAssertEqual(assessment.status, .unsupportedCalculation)
        XCTAssertTrue(assessment.missingPolicyIDs.contains("KOAP-END-NONWORKING-DAY"))
    }

    func testHistoricalCassationDoesNotSuppressNewRoundAppealRule() {
        let oldAppeal = CaseInstance(
            level: .appeal, court: "Верховный суд Республики Коми", caseNumber: "33-1/2026",
            judge: nil, domain: "vs.komi.sudrf.ru", foundByUID: true,
            result: "Жалоба оставлена без удовлетворения", sessions: [
                CaseSession(date: "01.03.2026", event: "Рассмотрено",
                            result: "Жалоба оставлена без удовлетворения"),
            ])
        let remand = CaseInstance(
            level: .cassation, court: "Третий КСОЮ", caseNumber: "8Г-1/2026",
            judge: nil, domain: "3kas.sudrf.ru", foundByUID: true,
            result: "Направлено на новое рассмотрение", sessions: [
                CaseSession(date: "10.04.2026", event: "Рассмотрено",
                            result: "Направлено на новое рассмотрение"),
            ])
        let returnedFirst = CaseInstance(
            level: .first, court: "Сыктывкарский городской суд", caseNumber: "2-200/2026",
            judge: nil, domain: "syktsud.komi.sudrf.ru", foundByUID: true,
            result: "Иск удовлетворён", sessions: [
                CaseSession(date: "13.04.2026", event: "Судебное заседание",
                            result: "Иск удовлетворён; решение принято в окончательной форме"),
            ])
        let mv = CaseMovement(uid: "new-round", caseNumber: "2-200/2026", inForce: false,
                              instances: [oldAppeal, remand, returnedFirst], complaints: [:], acts: [],
                              category: "Споры из договоров")
        let snap = snapshot(mv)

        XCTAssertEqual(snap.deadlines.single(where: { $0.kind == "appeal" })?.provenance?.ruleID,
                       "GPK-APPEAL-GENERAL")
        XCTAssertEqual(snap.deadlines.single(where: { $0.kind == "appeal" })?.date,
                       DateUtil.parse("13.05.2026"))
    }

    func testKASCassationOpenQuestionNeverCreatesRestartedDeadline() throws {
        let cassation = CaseInstance(
            level: .cassation, court: "Третий КСОЮ", caseNumber: "8а-1/2026",
            judge: nil, domain: "3kas.sudrf.ru", foundByUID: true, result: nil,
            sessions: [CaseSession(date: "20.04.2026", event: "Регистрация производства")])
        let mv = movement(cartoteka: "p", category: "Оспаривание решения органа",
                          inForce: true, sessions: [
                            CaseSession(date: "10.04.2026", event: "Решение вступило в законную силу"),
                          ], extra: [cassation])
        let assessed = try evaluation(mv, cartoteka: "p")

        XCTAssertTrue(assessed.deadlines.isEmpty)
        XCTAssertEqual(assessed.assessments.single(where: {
            $0.ruleID == "KAS-CASSATION-KSOYU"
        })?.status, .needsLegalReview)
    }

    func testNotApplicableAssessmentPreservesExistingTerminalClassification() {
        let mv = movement(sessions: [
            CaseSession(date: "13.04.2026", event: "Судебное заседание",
                        result: "Иск удовлетворён"),
        ])
        let resolution = CaseLifecycleResolver.resolve(
            movement: mv, deadlines: [], deadlineAssessments: [
                DeadlineRuleAssessment(ruleID: "GPK-APPEAL-GENERAL", kind: "appeal",
                                       statusRaw: DeadlineAssessmentStatus.notApplicable.rawValue),
            ], today: today)

        XCTAssertEqual(resolution.stage, .done)
        XCTAssertEqual(resolution.completionReason, .terminalFirst("Иск удовлетворён"))
    }

    func testUserDateIsPreservedOnlyForSameOccurrenceAndInactiveDoesNotRevive() {
        let original = snapshot(qualifiedCivilMovement())
        let userDate = DateUtil.parse("20.05.2026")!.timeIntervalSinceReferenceDate
        var userEdited = original
        userEdited.deadlines[0].statusRaw = DeadlineStatus.overridden.rawValue
        userEdited.deadlines[0].dateRef = userDate

        let same = MovementDerivation.preservingConfirmedDeadlines(original, old: userEdited,
                                                                    today: today)
        XCTAssertEqual(same.deadlines.single(where: { $0.isActive })?.status, .overridden)
        XCTAssertEqual(same.deadlines.single(where: { $0.isActive })?.dateRef, userDate)

        let changedTrigger = snapshot(qualifiedCivilMovement(date: "14.04.2026"))
        let replaced = MovementDerivation.preservingConfirmedDeadlines(changedTrigger, old: same,
                                                                        today: today)
        XCTAssertEqual(replaced.deadlines.filter(\.isActive).count, 1)
        XCTAssertEqual(replaced.deadlines.single(where: { $0.isActive })?.status, .proposed)
        XCTAssertTrue(replaced.deadlines.contains {
            $0.lifecycle == .superseded && $0.status == .overridden && $0.dateRef == userDate
        })

        let missingFromRefresh = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(movement(category: "Споры из договоров", sessions: [
                CaseSession(date: "14.04.2026", event: "Регистрация дела"),
            ])), old: same, today: today)
        XCTAssertEqual(missingFromRefresh.deadlines.single(where: { $0.isActive })?.status, .overridden)
        XCTAssertEqual(missingFromRefresh.deadlines.single(where: { $0.isActive })?.dateRef, userDate)

        var inactiveOld = original
        inactiveOld.deadlines[0].lifecycleRaw = DeadlineLifecycle.superseded.rawValue
        let noResurrection = MovementDerivation.preservingConfirmedDeadlines(
            original, old: inactiveOld, today: today)
        XCTAssertFalse(noResurrection.deadlines.contains(where: \.isActive))
        XCTAssertEqual(noResurrection.deadlines.count, 1)
        XCTAssertEqual(noResurrection.deadlines[0].lifecycle, .superseded)
    }

    func testRetentionAndLegacySnapshotDecodeKeepUserDate() throws {
        var fresh = snapshot(qualifiedCivilMovement())
        fresh.deadlines[0].dateRef = DateUtil.addDays(today, -15).timeIntervalSinceReferenceDate
        let retained = MovementDerivation.preservingConfirmedDeadlines(fresh, old: nil, today: today)
        XCTAssertEqual(retained.deadlines[0].lifecycle, .expiredUnconfirmed)
        let noExpiredResurrection = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(qualifiedCivilMovement()), old: retained, today: today)
        XCTAssertFalse(noExpiredResurrection.deadlines.contains(where: \.isActive))
        XCTAssertEqual(noExpiredResurrection.deadlines[0].lifecycle, .expiredUnconfirmed)

        var legacySource = snapshot(qualifiedCivilMovement())
        legacySource.deadlines[0].statusRaw = DeadlineStatus.confirmed.rawValue
        legacySource.deadlines[0].dateRef = DateUtil.parse("25.05.2026")!.timeIntervalSinceReferenceDate
        let data = try JSONEncoder().encode(legacySource)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var deadlines = try XCTUnwrap(object["deadlines"] as? [[String: Any]])
        deadlines[0].removeValue(forKey: "occurrenceKey")
        deadlines[0].removeValue(forKey: "provenance")
        deadlines[0].removeValue(forKey: "lifecycleRaw")
        object["deadlines"] = deadlines
        object.removeValue(forKey: "deadlineAssessments")
        let decoded = try JSONDecoder().decode(
            CaseSnapshot.self, from: JSONSerialization.data(withJSONObject: object))

        XCTAssertNil(decoded.deadlineAssessments)
        XCTAssertNil(decoded.deadlines[0].occurrenceKey)
        XCTAssertNil(decoded.deadlines[0].provenance)
        XCTAssertEqual(decoded.deadlines[0].lifecycle, .active)
        XCTAssertEqual(decoded.deadlines[0].status, .confirmed)
        XCTAssertEqual(decoded.deadlines[0].date, DateUtil.parse("25.05.2026"))
    }
}

private extension Collection where Element == StoredDeadline {
    func single(where predicate: (StoredDeadline) -> Bool) -> StoredDeadline? {
        let matches = filter(predicate)
        return matches.count == 1 ? matches[0] : nil
    }
}

private extension Collection where Element == DeadlineRuleAssessment {
    func single(where predicate: (DeadlineRuleAssessment) -> Bool) -> DeadlineRuleAssessment? {
        let matches = filter(predicate)
        return matches.count == 1 ? matches[0] : nil
    }
}
