import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class AppealChronologyLifecycleTests: XCTestCase {
    private let today = DateUtil.parse("12.09.2026")!

    private func first(_ number: String = "3а-681/2026", kinds: [String]? = nil,
                       accepted: String = "01.09.2026", continued: String? = nil) -> CaseInstance {
        var rows = [CaseSession(date: accepted, event: "Заявление принято к производству")]
        if let continued {
            rows.append(CaseSession(date: continued, event: "Вынесено определение о назначении дела к судебному заседанию"))
        }
        return CaseInstance(level: .first, court: "Верховный суд Республики Коми",
                            caseNumber: number, judge: nil, domain: "vs--komi.sudrf.ru",
                            foundByUID: false, result: nil, sessions: rows,
                            sourceEvidence: .init(appealKinds: kinds))
    }

    private func appeal(procedure: String? = nil) -> CaseInstance {
        CaseInstance(level: .appeal, court: "Второй апелляционный суд", caseNumber: "66а-726/2026",
                     judge: nil, domain: "2ap.sudrf.ru", foundByUID: true,
                     result: "Определение оставлено без изменения", sessions: [
                        CaseSession(date: "07.09.2026", event: "Регистрация жалобы"),
                        CaseSession(date: "08.09.2026", event: "Рассмотрение жалобы", result: "Определение оставлено без изменения")
                     ], sourceEvidence: .init(reviewProcedure: procedure, receiptDate: "07.09.2026", decisionDate: "08.09.2026"))
    }

    private func movement(_ instances: [CaseInstance]) -> CaseMovement {
        CaseMovement(uid: "11OS0000-01-2026-000704-31", caseNumber: "3а-681/2026",
                     inForce: false, instances: instances, complaints: [:], acts: [])
    }

    func testLaterAcceptedRegistrationRetainsAllCardsAndDefinesCurrentRound() {
        var old = first("9а-77/2026", accepted: "04.09.2026")
        old.result = "ОТКАЗАНО в принятии заявления"
        var reviewed = appeal()
        reviewed.result = "определение отменено полностью с разрешением вопроса по существу"
        reviewed.sessions[1].result = reviewed.result
        let current = first(accepted: "09.09.2026")
        for instances in [[old, reviewed, current], [current, old, reviewed]] {
            let mv = movement(instances)
            let timeline = CaseLifecycleResolver.timeline(in: mv, production: .kas)
            XCTAssertEqual(timeline.instances.count, 3)
            XCTAssertFalse(timeline.hasAppealInCurrentRound)
            XCTAssertNil(timeline.currentAppeal)
            let resolution = CaseLifecycleResolver.resolve(movement: mv, production: .kas, deadlines: [], today: today)
            XCTAssertEqual(resolution.stage, .first)
            XCTAssertEqual(resolution.currentInstance?.caseNumber, "3а-681/2026")
        }
    }

    func testPrivateOnlyAndLaterAppointmentKeepFirstWithoutDroppingAppeal() {
        for production: ProductionType in [.civil, .kas] {
            let mv = movement([first(kinds: ["Частная жалоба"], continued: "09.09.2026"), appeal()])
            let timeline = CaseLifecycleResolver.timeline(in: mv, production: production)
            XCTAssertEqual(timeline.instances.count, 2)
            XCTAssertFalse(timeline.hasAppealInCurrentRound)
            XCTAssertFalse(timeline.hasAmbiguousAppealEffect)
            XCTAssertEqual(CaseLifecycleResolver.resolve(movement: mv, production: production, deadlines: [], today: today).stage, .first)
        }
    }

    func testOrdinaryBothMissingAndSoleJudgeDoNotProvePrivateAppeal() {
        for kinds: [String]? in [["Апелляционная жалоба"], ["Частная жалоба", "Апелляционная жалоба"], nil, []] {
            let mv = movement([first(kinds: kinds), appeal(procedure: "Единоличное рассмотрение дела")])
            let timeline = CaseLifecycleResolver.timeline(in: mv, production: .kas)
            XCTAssertTrue(timeline.hasAppealInCurrentRound)
            XCTAssertFalse(timeline.hasAmbiguousAppealEffect)
        }
    }

    func testFutureHearingAloneDoesNotProveLaterContinuation() {
        var home = first(kinds: ["Частная жалоба"])
        home.sessions.append(CaseSession(date: "14.09.2026", event: "Судебное заседание"))
        let mv = movement([home, appeal()])
        XCTAssertTrue(CaseLifecycleResolver.timeline(in: mv, production: .kas).hasAmbiguousAppealEffect)
        XCTAssertFalse(CaseLifecycleResolver.resolve(movement: mv, production: .kas, deadlines: [], today: today).isCompleted)
    }

    func testExplicitPreviousRegistrationCannotConcludeNewCaseWithOverlappingDates() {
        var review = appeal()
        review.sourceEvidence?.lowerCourt = .init(courtTitle: "Верховный суд Республики Коми", caseNumber: "9а-77/2026")
        let mv = movement([first(kinds: ["Частная жалоба"]), review])
        XCTAssertTrue(CaseLifecycleResolver.timeline(in: mv, production: .kas).hasAmbiguousAppealEffect)
        XCTAssertFalse(CaseLifecycleResolver.resolve(movement: mv, production: .kas, deadlines: [], today: today).isCompleted)
    }

    func testSoleJudgeRequiresLaterPublishedContinuation() {
        let mv = movement([first(continued: "09.09.2026"), appeal(procedure: "Единоличное рассмотрение")])
        XCTAssertFalse(CaseLifecycleResolver.timeline(in: mv, production: .kas).hasAppealInCurrentRound)
        XCTAssertEqual(CaseLifecycleResolver.resolve(movement: mv, production: .kas, deadlines: [], today: today).stage, .first)
    }

    func testCriminalIndexedComplaintCannotFinishMainTrial() {
        var home = first("1-146/2026")
        home.sessions.append(CaseSession(date: "14.09.2026", event: "Судебное заседание"))
        var review = appeal()
        review.caseNumber = "22К-3295/2026"
        let mv = movement([home, review])
        let timeline = CaseLifecycleResolver.timeline(in: mv, production: .crim)
        XCTAssertEqual(timeline.instances.count, 2)
        XCTAssertFalse(timeline.hasAppealInCurrentRound)
        XCTAssertEqual(CaseLifecycleResolver.resolve(movement: mv, production: .crim, deadlines: [], today: today).stage, .first)
        // A separately tracked complaint without the main case stays a review.
        XCTAssertTrue(CaseLifecycleResolver.timeline(in: movement([review]), production: .crim).hasAppealInCurrentRound)
    }

    func testClericalEventIsNotContinuation() {
        var home = first(kinds: ["Частная жалоба"])
        home.sessions.append(CaseSession(date: "10.09.2026", event: "Дело сдано в отдел судебного делопроизводства"))
        XCTAssertTrue(CaseLifecycleResolver.timeline(in: movement([home, appeal()]), production: .kas).hasAmbiguousAppealEffect)
    }
    func testOtherPreviousRegistrationCannotBorrowCurrentPrivateOnlyEvidence() {
        var review = appeal()
        review.sourceEvidence?.lowerCourt = .init(caseNumber: "9а-77/2026")
        let mv = movement([first(kinds: ["Частная жалоба"], continued: "09.09.2026"), review])
        let timeline = CaseLifecycleResolver.timeline(in: mv, production: .kas)
        XCTAssertTrue(timeline.hasAppealInCurrentRound)
        XCTAssertTrue(timeline.hasAmbiguousAppealEffect)
    }

    func testEarlierScheduledHearingDoesNotOverrideOrdinaryAppealOutcome() {
        var home = first(kinds: ["Апелляционная жалоба"], continued: "05.09.2026")
        home.sessions.append(CaseSession(date: "14.09.2026", event: "Судебное заседание"))
        let result = CaseLifecycleResolver.resolve(movement: movement([home, appeal()]),
                                                   production: .kas, deadlines: [], today: today)
        XCTAssertEqual(result.stage, .done)
    }

    func testAmbiguousAppealProducesNoAutomaticDeadline() throws {
        let mv = movement([first(kinds: ["Частная жалоба"]), appeal()])
        let context = MovementContext(branchRaw: "general", region: "Республика Коми",
                                     searchDomain: "vs--komi.sudrf.ru", displayDomain: "vs.komi.sudrf.ru",
                                     courtTitle: "Верховный суд Республики Коми", courtLevelRaw: "subject",
                                     courtCode: "11OS0000", cartotekaId: "p1", cartotekaLevelRaw: "subject",
                                     caseNumber: mv.caseNumber)
        let evaluation = DeadlineRuleEngine.evaluate(registry: try LegalDeadlineRegistry.load(), movement: mv,
            context: .init(movementContext: context, deliveryOrReceipt: nil),
            timeline: CaseLifecycleResolver.timeline(in: mv, production: .kas), today: today)
        XCTAssertTrue(evaluation.deadlines.isEmpty)
        XCTAssertFalse(evaluation.assessments.isEmpty)
        XCTAssertTrue(evaluation.assessments.allSatisfy { $0.status == .needsLegalReview })
    }

    func testSameCardAcceptedAfterRefusalAndReviewDoesNotKeepOldTerminalResult() {
        var home = first(kinds: ["Частная жалоба"])
        home.result = "ОТКАЗАНО в принятии заявления"
        home.sessions.append(CaseSession(date: "05.09.2026", event: "Решение вопроса о принятии", result: home.result))
        home.sessions.append(CaseSession(date: "09.09.2026", event: "Заявление принято к производству"))
        let mv = movement([home, appeal()])
        let timeline = CaseLifecycleResolver.timeline(in: mv, production: .kas)
        XCTAssertFalse(timeline.hasAppealInCurrentRound)
        let result = CaseLifecycleResolver.resolve(movement: mv, production: .kas, deadlines: [], today: today)
        XCTAssertEqual(result.stage, .first)
        XCTAssertFalse(result.isCompleted)
    }

    func testLaterPublishedFirstResultIsNotHiddenByAcceptance() {
        var home = first(accepted: "09.09.2026")
        home.result = "Производство по делу прекращено"
        home.sourceEvidence?.decisionDate = "10.09.2026"
        let result = CaseLifecycleResolver.resolve(movement: movement([appeal(), home]),
                                                   production: .kas, deadlines: [], today: today)
        XCTAssertTrue(result.isCompleted)
        XCTAssertEqual(result.stage, .done)
    }

    func testFutureHearingWithAssignedResultIsNotAssignmentEvent() {
        var home = first(kinds: ["Частная жалоба"])
        home.sessions.append(CaseSession(date: "14.09.2026", event: "Судебное заседание", result: "Назначено заседание"))
        let timeline = CaseLifecycleResolver.timeline(in: movement([home, appeal()]), production: .kas)
        XCTAssertTrue(timeline.hasAmbiguousAppealEffect)
        XCTAssertTrue(timeline.hasAppealInCurrentRound)
    }

    func testGenericCivilAcceptanceIncludingComplaintWordStartsNewRound() {
        var home = first()
        home.sessions.append(CaseSession(date: "09.09.2026", event: "Иск (заявление, жалоба) принято к производству"))
        let timeline = CaseLifecycleResolver.timeline(in: movement([home, appeal()]), production: .civil)
        XCTAssertEqual(timeline.currentRoundDate, DateUtil.parse("09.09.2026"))
        XCTAssertFalse(timeline.hasAppealInCurrentRound)
    }

    func testComplaintAcceptanceAloneDoesNotRestartFirstInstance() {
        var home = first()
        home.sessions.append(CaseSession(date: "09.09.2026", event: "Апелляционная жалоба принята к производству"))
        let timeline = CaseLifecycleResolver.timeline(in: movement([home, appeal()]), production: .civil)
        XCTAssertNil(timeline.currentRoundDate)
        XCTAssertTrue(timeline.hasAppealInCurrentRound)
    }

}
