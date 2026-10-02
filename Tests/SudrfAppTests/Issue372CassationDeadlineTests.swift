import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

enum Issue372CassationFixtures {
    private struct Entry: Decodable {
        let id: String
        let movement: CaseMovement
    }

    static func all() throws -> [String: CaseMovement] {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "issue372_movement_examples", withExtension: "json", subdirectory: "Fixtures"))
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
        return Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0.movement) })
    }

    static func movement(_ id: String) throws -> CaseMovement {
        try XCTUnwrap(all()[id], "Missing #372 fixture: \(id)")
    }
}

final class Issue372CassationDeadlineTests: XCTestCase {
    private let today = DateUtil.parse("26.09.2026")!

    private func context(for movement: CaseMovement, kas: Bool = false,
                         level: String? = nil, region: String = "Республика Коми") -> MovementContext {
        let first = movement.instances.first(where: { $0.level == .first })!
        let courtLevel = level ?? (first.domain.hasPrefix("vs-") ? "subject" : "district")
        let domain = first.domain
        return MovementContext(
            branchRaw: "general", region: region,
            searchDomain: domain, displayDomain: domain.replacingOccurrences(of: "--", with: "."),
            courtTitle: first.court, courtLevelRaw: courtLevel,
            cartotekaId: kas ? "p1" : "g1", cartotekaLevelRaw: courtLevel,
            caseNumber: movement.caseNumber)
    }

    private func evaluate(_ movement: CaseMovement, context: MovementContext? = nil,
                          kas: Bool = false) throws -> DeadlineRuleEngine.Evaluation {
        let movementContext = context ?? self.context(for: movement, kas: kas)
        let production = ProductionType(cartotekaId: movementContext.cartotekaId)
        return DeadlineRuleEngine.evaluate(
            registry: try LegalDeadlineRegistry.load(), movement: movement,
            context: .init(movementContext: movementContext),
            timeline: CaseLifecycleResolver.timeline(in: movement, production: production),
            today: today)
    }

    private func assessment(_ result: DeadlineRuleEngine.Evaluation, _ ruleID: String) -> DeadlineRuleAssessment? {
        result.assessments.first(where: { $0.ruleID == ruleID })
    }

    private func cassation(_ result: DeadlineRuleEngine.Evaluation) -> StoredDeadline? {
        result.deadlines.first(where: { $0.kind == "cassation" })
    }

    func testPreSeptember2024CivilAppealUsesAnnouncementAndHistoricalRegistryRule() throws {
        let result = try evaluate(Issue372CassationFixtures.movement("old-gpk-appeal"))
        let deadline = try XCTUnwrap(cassation(result))
        let trigger = try XCTUnwrap(deadline.provenance?.trigger)

        XCTAssertEqual(deadline.provenance?.ruleID, "GPK-CASSATION-CSOY-2019")
        XCTAssertEqual(trigger.caseNumber, "33-657/2020")
        XCTAssertEqual(trigger.dateRaw, "30.01.2020")
        XCTAssertEqual(deadline.date, DateUtil.parse("30.04.2020"))
        XCTAssertEqual(assessment(result, "GPK-CASSATION-CSOY-2019")?.status, .applicable)
    }

    func testPostRemandMainAppealWinsOverLaterPrivateReviewAndSeparateCassationCard() throws {
        let movement = try Issue372CassationFixtures.movement("remand-main-vs-private")
        let timeline = CaseLifecycleResolver.timeline(in: movement, production: .civil)
        let result = try evaluate(movement)
        let deadline = try XCTUnwrap(cassation(result))
        let trigger = try XCTUnwrap(deadline.provenance?.trigger)

        XCTAssertEqual(timeline.currentAppeal?.caseNumber, "33-9844/2023")
        XCTAssertEqual(timeline.currentRoundStart?.instance.caseNumber, "33-9844/2023")
        XCTAssertEqual(timeline.currentRoundDate, DateUtil.parse("30.11.2023"))
        XCTAssertEqual(trigger.caseNumber, "33-9844/2023")
        XCTAssertEqual(trigger.dateRaw, "30.11.2023")
        XCTAssertEqual(deadline.provenance?.ruleID, "GPK-CASSATION-CSOY-2019")
    }

    func testReturnedAppealDoesNotCountAsMeritsDetermination() throws {
        let result = try evaluate(Issue372CassationFixtures.movement("returned-appeal"))
        let assessment = try XCTUnwrap(assessment(result, "GPK-CASSATION-CSOY"))

        XCTAssertNil(cassation(result))
        XCTAssertEqual(assessment.status, .insufficientEvidence)
        XCTAssertTrue(assessment.missingEvidenceRaw.contains(DeadlineEvidenceRequirement.finalAct.rawValue))
    }

    func testReviewOfKASCostMaterialDoesNotBecomeTheMainCaseCassationTrigger() throws {
        let movement = try Issue372CassationFixtures.movement("kas-material-cost-branch")
        let context = context(for: movement, kas: true)
        let timeline = CaseLifecycleResolver.timeline(in: movement, production: .kas)
        let result = try evaluate(movement, context: context)
        let assessment = try XCTUnwrap(assessment(result, "KAS-CASSATION-KSOYU"))

        XCTAssertNil(timeline.currentAppeal)
        XCTAssertNil(cassation(result))
        XCTAssertTrue(assessment.missingEvidenceRaw.contains(DeadlineEvidenceRequirement.legalForce.rawValue))
    }

    func testCassationOfCostDeterminationDoesNotReviveMainFirstInstance() throws {
        let movement = try Issue372CassationFixtures.movement("main-cassation-vs-material-cost")
        let timeline = CaseLifecycleResolver.timeline(in: movement, production: .civil)
        let result = try evaluate(movement)
        let resolution = CaseLifecycleResolver.resolve(movement: movement, production: .civil,
            deadlines: result.deadlines, deadlineAssessments: result.assessments, today: today)

        XCTAssertNil(timeline.currentAppeal)
        XCTAssertNil(timeline.currentRoundStart)
        XCTAssertNil(cassation(result))
        XCTAssertEqual(resolution.stage, .done)
    }

    func testSupremeCourtReviewDoesNotShowKSOYUCassationWarning() throws {
        let movement = try Issue372CassationFixtures.movement("vsrf-review")
        let context = context(for: movement, kas: true, level: "subject")
        let result = try evaluate(movement, context: context, kas: true)
        let assessment = try XCTUnwrap(assessment(result, "KAS-CASSATION-KSOYU"))
        let snapshot = MovementDerivation.snapshot(from: movement, context: context, today: today)

        XCTAssertEqual(assessment.status, .notApplicable)
        XCTAssertFalse(snapshot.nextEvent.localizedCaseInsensitiveContains("КСОЮ"))
    }

    func testUnsupported2017CassationRegimeDoesNotUseModernKSOYUFormula() throws {
        let result = try evaluate(Issue372CassationFixtures.movement("historical-gpk"))
        let assessment = try XCTUnwrap(assessment(result, "GPK-CASSATION-CSOY"))

        XCTAssertNil(cassation(result))
        XCTAssertEqual(assessment.status, .unsupportedCalculation)
        XCTAssertTrue(assessment.missingPolicyIDs.contains("historicalCassationRegime"))
    }

    func testOwnModernFinalFormWinsOverAnnouncementAndQuotedLowerCourtAct() throws {
        let movement = modernCivilMovement(appealSessions: [
            CaseSession(date: "05.09.2025", event: "Судебное заседание", result: "Вынесено решение"),
            CaseSession(date: "10.09.2025", event: "Составлено мотивированное апелляционное определение в окончательной форме"),
        ], body: "В деле упомянуто решение от 18 августа 2025 года, изготовленное в окончательной форме.\n\nОПРЕДЕЛИЛ: апелляционную жалобу оставить без удовлетворения.")
        let result = try evaluate(movement)
        let trigger = try XCTUnwrap(cassation(result)?.provenance?.trigger)

        XCTAssertEqual(trigger.dateRaw, "10.09.2025")
        XCTAssertEqual(trigger.caseNumber, "33-3720/2025")
    }

    func testSyntheticOperativeRowDoesNotProveItsQuotedFinalFormDate() throws {
        let movement = modernCivilMovement(appealSessions: [
            CaseSession(date: "05.09.2025", event: "Резолютивная часть опубликованного акта",
                        result: "Вынесено решение; мотивированное апелляционное определение изготовлено 10 сентября 2025 года"),
        ], body: "До резолютивной части процитировано решение от 18 августа 2025 года, изготовленное в окончательной форме.\n\nОПРЕДЕЛИЛ: апелляционную жалобу оставить без удовлетворения.")
        let result = try evaluate(movement)
        let assessment = try XCTUnwrap(assessment(result, "GPK-CASSATION-CSOY"))

        XCTAssertNil(cassation(result))
        XCTAssertTrue(assessment.isIndeterminate)
    }

    func testConflictingOwnFinalFormDatesFailClosed() throws {
        let movement = modernCivilMovement(appealSessions: [
            CaseSession(date: "10.09.2025", event: "Составлено мотивированное апелляционное определение в окончательной форме"),
        ], body: "ОПРЕДЕЛИЛ: мотивированное апелляционное определение изготовлено 11 сентября 2025 года.")
        let result = try evaluate(movement)

        XCTAssertNil(cassation(result))
        XCTAssertTrue(try XCTUnwrap(assessment(result, "GPK-CASSATION-CSOY")).isIndeterminate)
    }

    func testDecisionDateBoundaryConflictDoesNotProduceConfidentDeadline() throws {
        let movement = modernCivilMovement(
            caseNumber: "2-3721/2024", appealNumber: "33-3721/2024",
            appealSessions: [
                CaseSession(date: "30.08.2024", event: "Судебное заседание", result: "Вынесено решение"),
                CaseSession(date: "03.09.2024", event: "Составлено мотивированное апелляционное определение в окончательной форме"),
            ], body: "ОПРЕДЕЛИЛ: мотивированное апелляционное определение изготовлено 2 сентября 2024 года.",
            appealDecisionDate: "30.08.2024")
        let result = try evaluate(movement)

        XCTAssertNil(cassation(result))
        XCTAssertTrue(try XCTUnwrap(assessment(result, "GPK-CASSATION-CSOY")).isIndeterminate)
    }

    func testHistoricalAnnouncementDoesNotBecomeModernFromFinalFormRowWithoutTerminalSession() throws {
        let movement = modernCivilMovement(
            caseNumber: "2-3725/2024", appealNumber: "33-3725/2024",
            appealSessions: [CaseSession(date: "03.09.2024",
                event: "Составлено мотивированное апелляционное определение в окончательной форме")],
            body: "ОПРЕДЕЛИЛ: апелляционную жалобу оставить без удовлетворения.",
            appealDecisionDate: "30.08.2024", firstDecisionDate: "01.08.2024")
        var copy = movement
        if let appealIndex = copy.instances.firstIndex(where: { $0.level == .appeal }) {
            copy.instances[appealIndex].result = "Жалоба оставлена без удовлетворения"
        }
        let result = try evaluate(copy)
        let deadline = try XCTUnwrap(cassation(result))

        XCTAssertEqual(deadline.provenance?.ruleID, "GPK-CASSATION-CSOY-2019")
        XCTAssertEqual(deadline.provenance?.trigger.dateRaw, "30.08.2024")
    }

    func testOwnLinkedCaseActDateConflictIsDetectedWithoutTerminalSession() throws {
        let movement = modernCivilMovement(
            caseNumber: "2-3726/2024", appealNumber: "33-3726/2024",
            appealSessions: [CaseSession(date: "03.09.2024",
                event: "Составлено мотивированное апелляционное определение в окончательной форме")],
            body: "ОПРЕДЕЛИЛ: апелляционную жалобу оставить без удовлетворения.",
            appealDecisionDate: "30.08.2024", firstDecisionDate: "01.08.2024")
        var copy = movement
        if let appealIndex = copy.instances.firstIndex(where: { $0.level == .appeal }) {
            copy.instances[appealIndex].result = "Жалоба оставлена без удовлетворения"
        }
        copy.acts = [CaseAct(id: "fixture-own-appeal-act", title: "Апелляционное определение",
            date: "02.09.2024", courtShort: "Верховный суд Республики Коми", instanceLevel: .appeal)]
        let result = try evaluate(copy)
        let assessment = try XCTUnwrap(assessment(result, "GPK-CASSATION-CSOY"))

        XCTAssertNil(cassation(result))
        XCTAssertTrue(assessment.isIndeterminate)
        XCTAssertTrue(assessment.missingEvidenceRaw.contains(DeadlineEvidenceRequirement.finalAct.rawValue))
    }

    func testPendingAppealBlocksFallbackToFirstInstanceLegalForceDate() throws {
        let movement = civilMovement(
            caseNumber: "2-3722/2025", appealNumber: "33-3722/2025",
            firstSessions: [
                CaseSession(date: "01.05.2025", event: "Изготовлено мотивированное решение в окончательной форме"),
                CaseSession(date: "02.06.2025", event: "Решение вступило в законную силу"),
            ], appealSessions: [CaseSession(date: "10.06.2025", event: "Передача дела судье")])
        let result = try evaluate(movement)

        XCTAssertNil(cassation(result))
        XCTAssertTrue(try XCTUnwrap(assessment(result, "GPK-CASSATION-CSOY")).isIndeterminate)
    }

    func testMainAppealOfReturnedApplicationIsNotExcludedAsPrivateDetermination() throws {
        let movement = civilMovement(
            caseNumber: "2-3723/2026", appealNumber: "33-3723/2026",
            firstSessions: [CaseSession(date: "01.05.2026",
                event: "Решение вопроса о принятии заявления к производству", result: "Заявление возвращено")],
            appealSessions: [CaseSession(date: "15.05.2026", event: "Судебное заседание",
                result: "Определение отменено полностью с разрешением вопроса по существу")],
            appealResult: "Определение отменено полностью с разрешением вопроса по существу")
        let timeline = CaseLifecycleResolver.timeline(in: movement, production: .civil)

        XCTAssertEqual(timeline.currentAppeal?.caseNumber, "33-3723/2026")
        XCTAssertTrue(timeline.hasAppealInCurrentRound)
    }

    func testLinkedCaseActDateSelectsHistoricalRegimeWithoutSourceDecisionDate() throws {
        let movement = modernCivilMovement(
            caseNumber: "2-3728/2024", appealNumber: "33-3728/2024",
            appealSessions: [CaseSession(date: "03.09.2024",
                event: "Составлено мотивированное апелляционное определение в окончательной форме")],
            body: "ОПРЕДЕЛИЛ: апелляционную жалобу оставить без удовлетворения.",
            appealDecisionDate: nil, firstDecisionDate: "01.08.2024")
        var copy = movement
        if let index = copy.instances.firstIndex(where: { $0.level == .appeal }) {
            copy.instances[index].result = "Жалоба оставлена без удовлетворения"
        }
        copy.acts = [CaseAct(id: "fixture-own-appeal-act", title: "Апелляционное определение",
            date: "30.08.2024", courtShort: "Верховный суд Республики Коми", instanceLevel: .appeal)]
        let result = try evaluate(copy)
        let deadline = try XCTUnwrap(cassation(result))

        XCTAssertEqual(deadline.provenance?.ruleID, "GPK-CASSATION-CSOY-2019")
        XCTAssertEqual(deadline.provenance?.trigger.dateRaw, "30.08.2024")
    }

    func testSameDayMainAndPrivateAppealsKeepCassationTargetingMainAct() {
        let court = "Сыктывкарский городской суд"
        let uid = "fixture-same-day-shared-uid"
        let first = CaseInstance(level: .first, court: court, caseNumber: "2-3729/2025",
            judge: nil, domain: "syktsud--komi.sudrf.ru", foundByUID: false,
            result: "Иск удовлетворён", sessions: [
                CaseSession(date: "01.05.2025", event: "Судебное заседание", result: "Иск удовлетворён"),
            ], sourceEvidence: .init(appealKinds: ["Апелляционная жалоба", "Частная жалоба"],
                                    judicialUID: uid))
        let mainAppeal = CaseInstance(level: .appeal, court: "Верховный суд Республики Коми",
            caseNumber: "33-3729/2025", judge: nil, domain: "vs--komi.sudrf.ru", foundByUID: true,
            result: "Решение изменено без направления дела на новое рассмотрение", sessions: [
                CaseSession(date: "15.05.2025", event: "Судебное заседание", result: "Вынесено решение"),
            ], sourceEvidence: .init(lowerCourt: .init(courtTitle: court, caseNumber: "2-3729/2025"),
                                    decisionDate: "15.05.2025", judicialUID: uid))
        let privateAppeal = CaseInstance(level: .appeal, court: "Верховный суд Республики Коми",
            caseNumber: "33-3729/2025-частная", judge: nil, domain: "vs--komi.sudrf.ru", foundByUID: true,
            result: "Определение оставлено без изменения", sessions: [
                CaseSession(date: "15.05.2025", event: "Судебное заседание", result: "Вынесено решение"),
            ], sourceEvidence: .init(lowerCourt: .init(courtTitle: court, caseNumber: "2-3729/2025"),
                                    decisionDate: "15.05.2025", judicialUID: uid))
        let cassation = CaseInstance(level: .cassation,
            court: "Третий кассационный суд общей юрисдикции", caseNumber: "88-3729/2025",
            judge: nil, domain: "3kas.sudrf.ru", foundByUID: true,
            result: "Апелляционное определение отменено с направлением на новое рассмотрение",
            sessions: [CaseSession(date: "01.06.2025", event: "Судебное заседание",
                result: "Апелляционное определение отменено с направлением на новое рассмотрение")],
            actID: "fixture-main-cassation",
            sourceEvidence: .init(lowerCourt: .init(courtTitle: court, caseNumber: "2-3729/2025"),
                                  decisionDate: "01.06.2025", judicialUID: uid))
        let movement = CaseMovement(uid: "fixture-same-day-appeals-372", caseNumber: "2-3729/2025",
            inForce: false, instances: [first, mainAppeal, privateAppeal, cassation], complaints: [:],
            acts: [], actBodies: ["fixture-main-cassation":
                "ОПРЕДЕЛИЛ: решение по основному требованию от 15 мая 2025 года отменить, дело направить на новое рассмотрение в суд апелляционной инстанции."],
            category: "Трудовые споры", parties: CaseParties())

        let timeline = CaseLifecycleResolver.timeline(in: movement, production: .civil)

        XCTAssertEqual(timeline.currentAppeal?.caseNumber, "33-3729/2025")
        XCTAssertTrue(timeline.lifecycleOrdered.contains { $0.instance.caseNumber == "88-3729/2025" })
        XCTAssertFalse(timeline.lifecycleOrdered.contains { $0.instance.caseNumber == "33-3729/2025-частная" })
    }

    func testMainReviewOfPostRemandBlockingOrderIsNotClassifiedAsPrivate() {
        let court = "Сыктывкарский городской суд"
        let uid = "fixture-post-remand-shared-uid"
        let oldFirst = CaseInstance(level: .first, court: court, caseNumber: "2-3730/2025",
            judge: nil, domain: "syktsud--komi.sudrf.ru", foundByUID: false,
            result: "Иск удовлетворён", sessions: [
                CaseSession(date: "01.05.2025", event: "Судебное заседание", result: "Иск удовлетворён"),
            ], sourceEvidence: .init(judicialUID: uid))
        let remand = CaseInstance(level: .cassation,
            court: "Третий кассационный суд общей юрисдикции", caseNumber: "88-3730/2025",
            judge: nil, domain: "3kas.sudrf.ru", foundByUID: true,
            result: "Решение отменено, дело направлено на новое рассмотрение в суд первой инстанции",
            sessions: [CaseSession(date: "01.06.2025", event: "Судебное заседание",
                result: "Решение отменено, дело направлено на новое рассмотрение в суд первой инстанции")],
            sourceEvidence: .init(judicialUID: uid))
        let resumedFirst = CaseInstance(level: .first, court: court, caseNumber: "2-3730/2025-2",
            judge: nil, domain: "syktsud--komi.sudrf.ru", foundByUID: true,
            result: "Производство по делу прекращено", sessions: [
                CaseSession(date: "15.06.2025", event: "Определение о прекращении производства по делу",
                    result: "Производство по делу прекращено"),
            ], sourceEvidence: .init(judicialUID: uid))
        let mainReview = CaseInstance(level: .appeal, court: "Верховный суд Республики Коми",
            caseNumber: "33-3730/2025", judge: nil, domain: "vs--komi.sudrf.ru", foundByUID: true,
            result: "Определение отменено полностью с разрешением вопроса по существу", sessions: [
                CaseSession(date: "30.06.2025", event: "Судебное заседание", result: "Вынесено решение"),
            ], actID: "fixture-post-remand-order",
            sourceEvidence: .init(lowerCourt: .init(courtTitle: court, caseNumber: "2-3730/2025-2",
                decisionDate: "15.06.2025"), decisionDate: "30.06.2025", judicialUID: uid))
        let movement = CaseMovement(uid: "fixture-post-remand-order-372", caseNumber: "2-3730/2025",
            inForce: false, instances: [oldFirst, remand, resumedFirst, mainReview], complaints: [:],
            acts: [], actBodies: ["fixture-post-remand-order":
                "ОПРЕДЕЛИЛ: определение Сыктывкарского городского суда от 15 июня 2025 года о прекращении производства по делу отменить полностью с разрешением вопроса по существу."],
            category: "Трудовые споры", parties: CaseParties())

        let timeline = CaseLifecycleResolver.timeline(in: movement, production: .civil)

        XCTAssertEqual(timeline.currentRoundStart?.instance.caseNumber, "2-3730/2025-2")
        XCTAssertEqual(timeline.currentRoundDate, DateUtil.parse("15.06.2025"))
        XCTAssertEqual(timeline.currentAppeal?.caseNumber, "33-3730/2025")
    }

    func testRemandStartsAtPostDecisionMainAppealInsteadOfRemandDateOrLaterPrivateReview() {
        let court = "Сыктывкарский городской суд"
        let first = CaseInstance(level: .first, court: court, caseNumber: "2-3724/2025",
            judge: nil, domain: "syktsud--komi.sudrf.ru", foundByUID: false,
            result: "Иск удовлетворён", sessions: [
                CaseSession(date: "01.05.2025", event: "Дело принято к производству"),
                CaseSession(date: "10.05.2025", event: "Судебное заседание", result: "Иск удовлетворён"),
            ], sourceEvidence: .init(appealKinds: ["Апелляционная жалоба", "Частная жалоба"],
                                    judicialUID: "fixture-remand-shared-uid"))
        let appealBeforeRemand = CaseInstance(level: .appeal, court: "Верховный суд Республики Коми",
            caseNumber: "33-3724/2025", judge: nil, domain: "vs--komi.sudrf.ru", foundByUID: true,
            result: "Определение отменено", sessions: [
                CaseSession(date: "15.05.2025", event: "Судебное заседание", result: "Определение отменено"),
            ], sourceEvidence: .init(lowerCourt: .init(courtTitle: court, caseNumber: "2-3724/2025"),
                                    judicialUID: "fixture-remand-shared-uid"))
        let remand = CaseInstance(level: .cassation, court: "Третий кассационный суд общей юрисдикции",
            caseNumber: "88-3724/2025", judge: nil, domain: "3kas.sudrf.ru", foundByUID: true,
            result: "Апелляционное определение отменено, дело направлено на новое рассмотрение в суд апелляционной инстанции",
            sessions: [CaseSession(date: "01.06.2025", event: "Судебное заседание",
                result: "Апелляционное определение отменено, дело направлено на новое рассмотрение в суд апелляционной инстанции")],
            sourceEvidence: .init(judicialUID: "fixture-remand-shared-uid"))
        let mainAppeal = CaseInstance(level: .appeal, court: "Верховный суд Республики Коми",
            caseNumber: "33-3724/2025-2", judge: nil, domain: "vs--komi.sudrf.ru", foundByUID: true,
            result: "Апелляционная жалоба рассмотрена", sessions: [
                CaseSession(date: "15.06.2025", event: "Дело принято к производству"),
            ], sourceEvidence: .init(lowerCourt: .init(courtTitle: court, caseNumber: "2-3724/2025"),
                                    judicialUID: "fixture-remand-shared-uid"))
        let laterPrivateReview = CaseInstance(level: .appeal, court: "Верховный суд Республики Коми",
            caseNumber: "33-3724/2025-частная", judge: nil, domain: "vs--komi.sudrf.ru", foundByUID: true,
            result: "Определение оставлено без изменения", sessions: [
                CaseSession(date: "25.06.2025", event: "Рассмотрена частная жалоба",
                    result: "Определение оставлено без изменения"),
            ], sourceEvidence: .init(lowerCourt: .init(courtTitle: court, caseNumber: "2-3724/2025"),
                                    judicialUID: "fixture-remand-shared-uid"))
        let movement = CaseMovement(uid: "fixture-remand-round-372", caseNumber: "2-3724/2025",
            inForce: false, instances: [first, appealBeforeRemand, remand, mainAppeal, laterPrivateReview],
            complaints: [:], acts: [], category: "Общие вопросы", parties: CaseParties())

        let timeline = CaseLifecycleResolver.timeline(in: movement, production: .civil)

        XCTAssertEqual(timeline.currentRoundStart?.instance.caseNumber, "33-3724/2025-2")
        XCTAssertEqual(timeline.currentRoundDate, DateUtil.parse("15.06.2025"))
        XCTAssertEqual(timeline.currentAppeal?.caseNumber, "33-3724/2025-2")
    }

    private func modernCivilMovement(caseNumber: String = "2-3720/2025",
                                     appealNumber: String = "33-3720/2025",
                                     appealSessions: [CaseSession], body: String,
                                     appealDecisionDate: String? = "05.09.2025",
                                     firstDecisionDate: String = "01.08.2025") -> CaseMovement {
        let actID = "fixture-own-appeal-act"
        let movement = civilMovement(caseNumber: caseNumber, appealNumber: appealNumber,
            firstSessions: [CaseSession(date: firstDecisionDate, event: "Изготовлено мотивированное решение в окончательной форме")],
            appealSessions: appealSessions, actID: actID,
            appealDecisionDate: appealDecisionDate)
        var copy = movement
        copy.actBodies[actID] = body
        return copy
    }

    private func civilMovement(caseNumber: String, appealNumber: String,
                               firstSessions: [CaseSession], appealSessions: [CaseSession],
                               actID: String? = nil, appealDecisionDate: String? = nil,
                               appealResult: String? = nil) -> CaseMovement {
        let court = "Сыктывкарский городской суд"
        let domain = "syktsud--komi.sudrf.ru"
        let uid = "synthetic-shared-uid"
        let first = CaseInstance(level: .first, court: court, caseNumber: caseNumber,
            judge: nil, domain: domain, foundByUID: false, result: nil,
            sessions: firstSessions,
            sourceEvidence: .init(decisionDate: firstSessions.last?.date, judicialUID: uid))
        let appeal = CaseInstance(level: .appeal, court: "Верховный суд Республики Коми",
            caseNumber: appealNumber, judge: nil, domain: "vs--komi.sudrf.ru", foundByUID: true,
            result: appealResult, sessions: appealSessions, actID: actID,
            sourceEvidence: .init(lowerCourt: .init(courtTitle: court, caseNumber: caseNumber),
                                  decisionDate: appealDecisionDate, judicialUID: uid))
        return CaseMovement(uid: "fixture-synthetic-372", caseNumber: caseNumber,
            inForce: false, instances: [first, appeal], complaints: [:], acts: [],
            category: "Общие вопросы", parties: CaseParties())
    }
}
