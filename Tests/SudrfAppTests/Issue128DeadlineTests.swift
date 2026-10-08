import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

@MainActor
final class Issue128DeadlineTests: XCTestCase {
    private let today = DateUtil.parse("01.09.2026")!

    private func context(_ number: String, cartoteka: String = "g1") -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru", displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: "11RS0001",
            cartotekaId: cartoteka, cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: number, caseID: "issue-128-\(number)", caseUID: "issue-128-card")
    }

    private func movement(_ number: String, category: String = "Споры из договоров",
                          sessions: [CaseSession], acts: [CaseAct] = [])
        -> CaseMovement {
        let first = CaseInstance(level: .first, court: "Сыктывкарский городской суд",
                                 caseNumber: number, judge: nil,
                                 domain: "syktsud.komi.sudrf.ru", foundByUID: false,
                                 result: sessions.last?.result, sessions: sessions)
        return CaseMovement(uid: "11RS0001-01-2026-000128-11", caseNumber: number,
                            inForce: false, instances: [first], complaints: [:], acts: acts,
                            category: category)
    }

    private func snapshot(_ movement: CaseMovement, _ context: MovementContext) -> CaseSnapshot {
        MovementDerivation.snapshot(from: movement, context: context, today: today)
    }

    private func legacyDeadline(status: DeadlineStatus, lifecycle: DeadlineLifecycle = .active,
                                triggerDay: String = "09.07")
        -> StoredDeadline {
        StoredDeadline(kind: "appeal", what: "Апелляционная жалоба",
                       basis: "1 месяц со дня решения (\(triggerDay)) — расчётный, проверьте",
                       calLabel: "Апелляция",
                       dateRef: DateUtil.parse("25.08.2026")!.timeIntervalSinceReferenceDate,
                       statusRaw: status.rawValue, occurrenceKey: nil,
                       lifecycleRaw: lifecycle.rawValue)
    }

    private func appealOccurrenceKey(for movement: CaseMovement) -> String {
        let timeline = CaseLifecycleResolver.timeline(in: movement, production: .civil)
        let session = movement.instances[0].sessions[0]
        let round = timeline.currentRoundStart?.instance.id
            ?? timeline.deadlineFirst?.id ?? movement.uid
        let source = [round, CaseInstance.Level.first.rawValue, movement.caseNumber,
                      session.date, session.event, session.result ?? ""].joined(separator: "\u{1F}")
        return "GPK-APPEAL-GENERAL|" + Data(source.utf8).base64EncodedString()
    }

    func testActiveCasesWithoutFinalActNeverProduceAppealDeadline() {
        let examples: [(String, String, String, [CaseSession])] = [
            ("2-6027/2026", "g1", "Споры из договоров", [
                .init(date: "22.06.2026", event: "Регистрация иска (заявления, жалобы) в суде"),
                .init(date: "23.06.2026", event: "Передача материалов судье"),
                .init(date: "26.06.2026", event: "Решение вопроса о принятии иска к рассмотрению", result: "Оставление иска без движения"),
                .init(date: "09.07.2026", event: "Рассмотрение исправленных материалов, поступивших в суд", result: "Иск (заявление, жалоба) принят к производству"),
                .init(date: "09.07.2026", event: "Вынесено определение о подготовке дела к судебному разбирательству"),
                .init(date: "09.07.2026", event: "Вынесено определение о назначении дела к судебному разбирательству"),
                .init(date: "27.08.2026", event: "Судебное заседание"),
            ]),
            ("2а-5090/2026", "p1", "Оспаривание решения органа", [
                .init(date: "26.08.2026", event: "Судебное заседание", result: "Административное дело отложено"),
                .init(date: "05.10.2026", event: "Судебное заседание", result: nil),
            ]),
            ("2-3685/2026", "g1", "Споры из договоров", [
                .init(date: "27.08.2026", event: "Исковое заявление принято к производству"),
                .init(date: "28.08.2026", event: "Передача материалов судье"),
            ]),
        ]

        for (number, cartoteka, category, sessions) in examples {
            let current = movement(number, category: category, sessions: sessions)
            let value = snapshot(current, context(number, cartoteka: cartoteka))
            XCTAssertFalse(value.deadlines.contains { $0.kind == "appeal" }, number)
            XCTAssertEqual(value.stageRaw, CaseStageKind.first.rawValue, number)
            if number == "2-6027/2026" {
                let afterHearing = MovementDerivation.snapshot(
                    from: current, context: context(number),
                    today: DateUtil.parse("22.09.2026")!)
                XCTAssertFalse(afterHearing.deadlines.contains { $0.kind == "appeal" }, number)
            }
        }
    }

    func testFinalFormAndAdditionalDecisionAreTheOnlyPositiveTriggers() throws {
        let ordinary = snapshot(movement("2-6000/2026", sessions: [
            .init(date: "18.08.2026", event: "Судебное заседание",
                  result: "Иск удовлетворён; решение принято в окончательной форме"),
        ]), context("2-6000/2026"))
        XCTAssertEqual(ordinary.deadlines.first(where: { $0.kind == "appeal" })?.date,
                       DateUtil.parse("18.09.2026"))

        let additional = snapshot(movement("2-476/2026", sessions: [
            .init(date: "18.08.2026", event: "Вынесено дополнительное решение",
                  result: "Иск удовлетворён; дополнительное решение принято в окончательной форме"),
        ]), context("2-476/2026"))
        XCTAssertEqual(additional.deadlines.first(where: { $0.kind == "appeal" })?.date,
                       DateUtil.parse("18.09.2026"))
    }

    func testProvenFalseLegacyAppealsBecomeImmutableHistoryWithoutLosingFields() throws {
        let current = movement("2-6027/2026", sessions: [
            .init(date: "09.07.2026", event: "Определение", result: "Недостатки устранены; исковое заявление принято к производству"),
        ])
        let rule = try XCTUnwrap(LegalDeadlineRegistry.load().rule(id: "GPK-APPEAL-GENERAL"))
        for status in [DeadlineStatus.proposed, .confirmed, .overridden] {
            var old = snapshot(current, context("2-6027/2026"))
            var original = legacyDeadline(status: status)
            if status == .confirmed {
                original.occurrenceKey = appealOccurrenceKey(for: current)
                let session = current.instances[0].sessions[0]
                original.provenance = DeadlineProvenance(
                    ruleID: rule.ruleID, registryRevision: rule.revision, sourceHash: rule.sourceHash,
                    trigger: .init(event: session.event, result: session.result, dateRaw: session.date,
                                   court: current.instances[0].court, levelRaw: CaseInstance.Level.first.rawValue,
                                   caseNumber: current.caseNumber), policyIDs: [], formula: original.basis,
                    source: rule.source, calculatedDateRef: original.dateRef)
            }
            old.deadlines = [original]
            let repaired = MovementDerivation.preservingConfirmedDeadlines(
                snapshot(current, context("2-6027/2026")), old: old, today: today,
                movement: current, context: context("2-6027/2026"))
            XCTAssertEqual(repaired.deadlines.count, 1, status.rawValue)
            let archived = repaired.deadlines.first
            var expected = original
            expected.lifecycleRaw = DeadlineLifecycle.superseded.rawValue
            XCTAssertEqual(archived, expected, status.rawValue)
        }
    }

    func testActualIssue128IntermediateRowsIndividuallyDisproveLegacyAppeal() {
        let value = context("2-6027/2026")
        let rows = [
            (CaseSession(date: "26.06.2026",
                         event: "Решение вопроса о принятии иска к рассмотрению",
                         result: "Оставление иска без движения"), "26.06"),
            (CaseSession(date: "09.07.2026",
                         event: "Рассмотрение исправленных материалов, поступивших в суд",
                         result: "Иск (заявление, жалоба) принят к производству"), "09.07"),
            (CaseSession(date: "09.07.2026",
                         event: "Вынесено определение о подготовке дела к судебному разбирательству"), "09.07"),
            (CaseSession(date: "09.07.2026",
                         event: "Вынесено определение о назначении дела к судебному разбирательству"), "09.07"),
        ]
        for (row, triggerDay) in rows {
            let current = movement("2-6027/2026", sessions: [row])
            var old = snapshot(current, value)
            old.deadlines = [legacyDeadline(status: .proposed, triggerDay: triggerDay)]
            let repaired = MovementDerivation.preservingConfirmedDeadlines(
                snapshot(current, value), old: old, today: today,
                movement: current, context: value)
            XCTAssertEqual(repaired.deadlines.first?.lifecycle, .superseded, row.event)
        }
    }

    func testClosedFalseLegacyDeadlineDoesNotReviveAndLaterPrivateActGetsNewProposal() throws {
        let inactive = movement("2-3685/2026", sessions: [
            .init(date: "09.07.2026", event: "Определение",
                  result: "Недостатки устранены; исковое заявление принято к производству"),
            .init(date: "28.08.2026", event: "Передача материалов судье"),
        ])
        var old = snapshot(inactive, context("2-3685/2026"))
        old.deadlines = [legacyDeadline(status: .confirmed, lifecycle: .superseded)]

        let stillInactive = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(inactive, context("2-3685/2026")), old: old, today: today,
            movement: inactive, context: context("2-3685/2026"))
        XCTAssertEqual(stillInactive.deadlines.first(where: { $0.basis == legacyDeadline(status: .confirmed).basis })?.lifecycle,
                       .superseded)

        let final = movement("2-3685/2026", sessions: [
            .init(date: "09.07.2026", event: "Определение",
                  result: "Недостатки устранены; исковое заявление принято к производству"),
            .init(date: "18.09.2026", event: "Судебное заседание",
                  result: "Исковое заявление возвращено"),
        ])
        let refreshed = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(final, context("2-3685/2026")), old: stillInactive, today: today,
            movement: final, context: context("2-3685/2026"))
        let proposal = try XCTUnwrap(refreshed.deadlines.first {
            $0.kind == "appeal" && $0.isActive
        })
        XCTAssertEqual(proposal.status, .proposed)
        XCTAssertEqual(proposal.provenance?.ruleID, "GPK-PRIVATE-COMPLAINT-GENERAL")
        XCTAssertNotNil(proposal.occurrenceKey)
        XCTAssertEqual(refreshed.deadlines.first(where: {
            $0.basis == legacyDeadline(status: .confirmed).basis
        })?.lifecycle, .superseded)

        let repeated = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(final, context("2-3685/2026")), old: refreshed, today: today,
            movement: final, context: context("2-3685/2026"))
        XCTAssertEqual(repeated.deadlines.filter { $0.kind == "appeal" && $0.isActive }.count, 1)
        XCTAssertEqual(repeated.deadlines.first(where: {
            $0.basis == legacyDeadline(status: .confirmed).basis
        })?.lifecycle, .superseded)

        let general = movement("2-3685/2026", sessions: [
            .init(date: "09.07.2026", event: "Определение",
                  result: "Недостатки устранены; исковое заявление принято к производству"),
            .init(date: "01.10.2026", event: "Судебное заседание",
                  result: "Иск удовлетворён; решение принято в окончательной форме"),
        ])
        let afterGeneral = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(general, context("2-3685/2026")), old: repeated, today: today,
            movement: general, context: context("2-3685/2026"))
        XCTAssertEqual(afterGeneral.deadlines.first(where: { $0.isActive })?.provenance?.ruleID,
                       "GPK-APPEAL-GENERAL")
    }

    func testSupersededPriorRoundFalseDeadlineDoesNotSuppressPrivateActAfterRemand() {
        let value = context("2-6027/2026")
        let oldFirst = CaseInstance(
            level: .first, court: value.courtTitle, caseNumber: value.caseNumber, judge: nil,
            domain: value.displayDomain, foundByUID: false,
            result: "Исковое заявление принято к производству", sessions: [
                .init(date: "09.07.2026", event: "Определение",
                      result: "Исковое заявление принято к производству"),
            ])
        let newRoundAccepted = CaseInstance(
            level: .first, court: value.courtTitle, caseNumber: value.caseNumber, judge: nil,
            domain: value.displayDomain, foundByUID: true,
            result: "Исковое заявление принято к производству", sessions: [
                .init(date: "01.09.2026", event: "Определение",
                      result: "Исковое заявление принято к производству"),
            ])
        let oldMovement = CaseMovement(uid: "11RS0001-01-2026-000128-11",
                                       caseNumber: value.caseNumber, inForce: false,
                                       instances: [oldFirst, newRoundAccepted], complaints: [:], acts: [],
                                       category: "Споры из договоров")
        var old = snapshot(oldMovement, value)
        old.deadlines = [legacyDeadline(status: .confirmed, lifecycle: .superseded)]
        let appeal = CaseInstance(level: .appeal, court: "Верховный суд Республики Коми",
                                  caseNumber: "33-6027/2026", judge: nil,
                                  domain: "vs.komi.sudrf.ru", foundByUID: true,
                                  result: "Оставлено без изменения", sessions: [])
        let remand = CaseInstance(level: .cassation, court: "Третий КСОЮ",
                                  caseNumber: "8Г-6027/2026", judge: nil,
                                  domain: "3kas.sudrf.ru", foundByUID: true,
                                  result: "Направлено на новое рассмотрение", sessions: [
                                    .init(date: "20.08.2026", event: "Рассмотрено",
                                          result: "Направлено на новое рассмотрение"),
                                  ])
        let returned = CaseInstance(level: .first, court: value.courtTitle,
                                    caseNumber: value.caseNumber, judge: nil,
                                    domain: value.displayDomain, foundByUID: true,
                                    result: "Исковое заявление возвращено", sessions: [
                                        .init(date: "18.09.2026", event: "Судебное заседание",
                                              result: "Исковое заявление возвращено"),
                                    ])
        let current = CaseMovement(uid: oldMovement.uid, caseNumber: value.caseNumber,
                                   inForce: false,
                                   instances: [oldFirst, appeal, remand, newRoundAccepted, returned],
                                   complaints: [:], acts: [], category: "Споры из договоров")
        let repaired = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(current, value), old: old, today: today, movement: current, context: value)
        XCTAssertEqual(repaired.deadlines.filter { $0.kind == "appeal" && $0.isActive }.map {
            $0.provenance?.ruleID
        }, ["GPK-PRIVATE-COMPLAINT-GENERAL"])
        XCTAssertTrue(repaired.deadlines.contains {
            $0.basis == legacyDeadline(status: .confirmed).basis && $0.lifecycle == .superseded
        })
    }

    func testAmbiguousLegacyAppealStaysVisibleAndRequestsReview() {
        let value = context("2-128/2026")
        let privateAct = movement("2-128/2026", sessions: [
            .init(date: "18.08.2026", event: "Судебное заседание",
                  result: "Исковое заявление возвращено"),
        ])
        var old = snapshot(privateAct, value)
        var legacy = legacyDeadline(status: .confirmed)
        legacy.occurrenceKey = nil
        legacy.basis = "Старый импорт без акта"
        old.deadlines = [legacy]
        old.deadlineAssessments = nil

        let repaired = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(privateAct, value), old: old, today: today,
            movement: privateAct, context: value)

        XCTAssertEqual(repaired.deadlines.count, 1)
        XCTAssertTrue(repaired.deadlines[0].isActive)
        XCTAssertEqual(repaired.deadlines[0].basis, legacy.basis)
        XCTAssertEqual(repaired.deadlineAssessments?.first(where: {
            $0.ruleID == "GPK-PRIVATE-COMPLAINT-GENERAL"
        })?.status, .needsLegalReview)
    }

    func testAmbiguousLegacyDateAndMultipleSourceRowsAreNotArchived() {
        let value = context("2-128/2026")
        let contradictory = movement("2-128/2026", sessions: [
            .init(date: "09.07.2025", event: "Судебное заседание", result: "Отложено"),
            .init(date: "09.07.2026", event: "Судебное заседание",
                  result: "Иск удовлетворён; решение принято в окончательной форме"),
        ])
        var old = snapshot(contradictory, value)
        old.deadlines = [legacyDeadline(status: .confirmed)]
        let repaired = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(contradictory, value), old: old, today: today,
            movement: contradictory, context: value)

        XCTAssertTrue(repaired.deadlines.contains {
            $0.basis == legacyDeadline(status: .confirmed).basis && $0.isActive
        })
        XCTAssertEqual(repaired.deadlineAssessments?.first(where: {
            $0.ruleID == "GPK-APPEAL-GENERAL"
        })?.status, .needsLegalReview)
    }

    func testAmbiguousOldAutomaticProposalPastGraceKeepsFieldsAndWarns() {
        let value = context("2-128/2026")
        let ambiguous = movement("2-128/2026", sessions: [
            .init(date: "09.07.2025", event: "Судебное заседание", result: "Отложено"),
            .init(date: "09.07.2026", event: "Судебное заседание",
                  result: "Иск удовлетворён; решение принято в окончательной форме"),
        ])
        var old = snapshot(ambiguous, value)
        var proposal = legacyDeadline(status: .proposed)
        proposal.dateRef = DateUtil.parse("20.08.2026")!.timeIntervalSinceReferenceDate
        old.deadlines = [proposal]
        let asOf = DateUtil.parse("10.09.2026")!
        XCTAssertGreaterThan(DateUtil.daysBetween(proposal.date, asOf), AppRouter.deadlineGraceDays)
        let repaired = MovementDerivation.preservingConfirmedDeadlines(
            MovementDerivation.snapshot(from: ambiguous, context: value, today: asOf),
            old: old, today: asOf,
            movement: ambiguous, context: value)
        XCTAssertEqual(repaired.deadlines.first, proposal)
        XCTAssertEqual(repaired.deadlineAssessments?.first(where: {
            $0.ruleID == "GPK-APPEAL-GENERAL"
        })?.status, .needsLegalReview)

        var deferredRetention: [StoredDeadline] = []
        var combined = MovementDerivation.preservingConfirmedDeadlines(
            MovementDerivation.snapshot(from: ambiguous, context: value, today: asOf),
            old: old, today: asOf, movement: ambiguous, context: value,
            deferredRetention: &deferredRetention)
        combined = MovementDerivation.preservingConfirmedDeadlines(
            combined, old: snapshot(ambiguous, value), today: asOf,
            movement: ambiguous, context: value,
            deferredRetention: &deferredRetention)
        combined = MovementDerivation.applyingDeadlineRetention(
            to: combined, today: asOf, preserving: deferredRetention)
        XCTAssertEqual(combined.deadlines.first, proposal)
        XCTAssertEqual(combined.deadlineAssessments?.first(where: {
            $0.ruleID == "GPK-APPEAL-GENERAL"
        })?.status, .needsLegalReview)
    }

    func testNegatedPreparatoryRowsCannotDisproveLegacyDeadline() {
        let value = context("2-6027/2026")
        for text in ["Подготовка дела не проводилась", "Заседание не было назначено",
                     "Материалы не были переданы"] {
            let current = movement("2-6027/2026", sessions: [
                .init(date: "09.07.2026", event: text),
            ])
            var old = snapshot(current, value)
            old.deadlines = [legacyDeadline(status: .proposed)]
            let repaired = MovementDerivation.preservingConfirmedDeadlines(
                snapshot(current, value), old: old, today: today,
                movement: current, context: value)
            XCTAssertTrue(repaired.deadlines.first?.isActive ?? false, text)
        }
    }

    func testWrongProvenanceCourtLevelOrRoundCannotDisproveLegacyDeadline() throws {
        let value = context("2-6027/2026")
        let current = movement("2-6027/2026", sessions: [
            .init(date: "09.07.2026", event: "Определение",
                  result: "Исковое заявление принято к производству"),
        ])
        let rule = try XCTUnwrap(LegalDeadlineRegistry.load().rule(id: "GPK-APPEAL-GENERAL"))
        let session = current.instances[0].sessions[0]
        for (court, level, key) in [
            ("Другой суд", "first", nil),
            (value.courtTitle, "appeal", nil),
            (value.courtTitle, "first", "GPK-APPEAL-GENERAL|wrong-round"),
        ] {
            var old = snapshot(current, value)
            var deadline = legacyDeadline(status: .confirmed)
            deadline.occurrenceKey = key
            deadline.provenance = .init(
                ruleID: rule.ruleID, registryRevision: rule.revision, sourceHash: rule.sourceHash,
                trigger: .init(event: session.event, result: session.result, dateRaw: session.date,
                               court: court, levelRaw: level, caseNumber: current.caseNumber),
                policyIDs: [], formula: deadline.basis, source: rule.source,
                calculatedDateRef: deadline.dateRef)
            old.deadlines = [deadline]
            let repaired = MovementDerivation.preservingConfirmedDeadlines(
                snapshot(current, value), old: old, today: today,
                movement: current, context: value)
            XCTAssertTrue(repaired.deadlines.first?.isActive ?? false, "\(court)/\(level)/\(key ?? "")")
        }
    }

    func testPartialRefreshCannotArchiveProvenFinalProposal() {
        let value = context("2-6000/2026")
        let final = movement("2-6000/2026", sessions: [
            .init(date: "18.08.2026", event: "Судебное заседание",
                  result: "Иск удовлетворён; решение принято в окончательной форме"),
        ])
        let old = snapshot(final, value)
        let partial = movement("2-6000/2026", sessions: [
            .init(date: "19.08.2026", event: "Техническая ошибка обновления"),
        ])

        let preserved = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(partial, value), old: old, today: today,
            preserveActiveProposedWhenMissing: true, movement: partial, context: value)
        XCTAssertEqual(preserved.deadlines.first?.occurrenceKey, old.deadlines.first?.occurrenceKey)
        XCTAssertTrue(preserved.deadlines.first?.isActive ?? false)
        XCTAssertEqual(preserved.deadlines.first?.status, .proposed)
    }

    func testPartialRefreshDoesNotRetainProvenFalseLegacyAppeal() {
        let value = context("2-6027/2026")
        let current = movement("2-6027/2026", sessions: [
            .init(date: "09.07.2026", event: "Решение вопроса о принятии искового заявления",
                  result: "Иск принят к производству"),
        ])
        var old = snapshot(current, value)
        old.deadlines = [legacyDeadline(status: .proposed)]
        let repaired = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(current, value), old: old, today: today,
            preserveActiveProposedWhenMissing: true, movement: current, context: value)
        XCTAssertEqual(repaired.deadlines.first?.lifecycle, .superseded)
    }

    func testAcceptanceQuestionWithoutOutcomeCannotDisproveLegacyAppeal() {
        let value = context("2-6027/2026")
        let unknown = movement("2-6027/2026", sessions: [
            .init(date: "09.07.2026", event: "Решение вопроса о принятии искового заявления"),
        ])
        var old = snapshot(unknown, value)
        old.deadlines = [legacyDeadline(status: .proposed)]
        let preserved = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(unknown, value), old: old, today: today,
            movement: unknown, context: value)
        XCTAssertTrue(preserved.deadlines.first?.isActive ?? false)
    }

    func testLegacyEvidenceFromAnotherCardCannotBeProvenFalse() {
        let value = context("2-6027/2026")
        let current = movement("2-6027/2026", sessions: [
            .init(date: "09.07.2026", event: "Определение",
                  result: "Недостатки устранены; исковое заявление принято к производству"),
        ])
        var old = snapshot(current, value)
        old.sessions[0].sourceCardID = "another-card"
        old.deadlines = [legacyDeadline(status: .confirmed)]
        let repaired = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(current, value), old: old, today: today,
            movement: current, context: value)
        XCTAssertTrue(repaired.deadlines.contains {
            $0.basis == legacyDeadline(status: .confirmed).basis && $0.isActive
        })
    }

    func testKASKnownNonfinalLegacyAppealIsArchivedUnderKASRule() {
        let value = context("2а-5090/2026", cartoteka: "p1")
        let current = movement("2а-5090/2026", category: "Оспаривание решения органа", sessions: [
            .init(date: "09.07.2026", event: "Определение",
                  result: "Административное исковое заявление принято к производству"),
        ])
        var old = snapshot(current, value)
        old.deadlines = [legacyDeadline(status: .proposed)]
        let repaired = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(current, value), old: old, today: today,
            movement: current, context: value)
        XCTAssertEqual(repaired.deadlines.first?.lifecycle, .superseded)
        XCTAssertEqual(repaired.deadlineAssessments?.first(where: {
            $0.ruleID == "KAS-APPEAL-GENERAL"
        })?.status, .insufficientEvidence)
    }

    func testSameDayFinalOrBlockingRowMakesActiveLegacyEvidenceAmbiguous() {
        let value = context("2-6027/2026")
        let intermediate = movement("2-6027/2026", sessions: [
            .init(date: "09.07.2026", event: "Определение",
                  result: "Исковое заявление принято к производству"),
        ])
        var old = snapshot(intermediate, value)
        old.deadlines = [legacyDeadline(status: .proposed)]
        var fresh = intermediate
        fresh.instances[0].sessions.append(.init(
            date: "09.07.2026", event: "Судебное заседание",
            result: "Иск удовлетворён; решение принято в окончательной форме"))
        let afterFinal = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(fresh, value), old: old, today: today, movement: fresh, context: value)
        XCTAssertTrue(afterFinal.deadlines.contains {
            $0.basis == legacyDeadline(status: .proposed).basis && $0.isActive
        })
        XCTAssertEqual(afterFinal.deadlineAssessments?.first(where: {
            $0.ruleID == "GPK-APPEAL-GENERAL"
        })?.status, .needsLegalReview)

        var withBlocking = intermediate
        withBlocking.instances[0].sessions.append(.init(
            date: "09.07.2026", event: "Судебное заседание",
            result: "Исковое заявление возвращено"))
        var oldWithBlocking = snapshot(withBlocking, value)
        oldWithBlocking.deadlines = [legacyDeadline(status: .proposed)]
        let afterBlocking = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(withBlocking, value), old: oldWithBlocking, today: today,
            movement: withBlocking, context: value)
        XCTAssertTrue(afterBlocking.deadlines.contains {
            $0.basis == legacyDeadline(status: .proposed).basis && $0.isActive
        })
        XCTAssertTrue(afterBlocking.deadlineAssessments?.contains {
            $0.status == .needsLegalReview
        } ?? false)
    }

    func testClosedFalseHistoryDoesNotSuppressSameDayGeneralDecisionAfterRepeat() {
        let value = context("2-6027/2026")
        let localToday = DateUtil.parse("15.07.2026")!
        let intermediate = movement("2-6027/2026", sessions: [
            .init(date: "09.07.2026", event: "Определение",
                  result: "Исковое заявление принято к производству"),
        ])
        var old = snapshot(intermediate, value)
        old.deadlines = [legacyDeadline(status: .confirmed, lifecycle: .superseded)]
        let final = movement("2-6027/2026", sessions: [
            .init(date: "09.07.2026", event: "Судебное заседание",
                  result: "Иск удовлетворён; решение принято в окончательной форме"),
        ])
        let first = MovementDerivation.preservingConfirmedDeadlines(
            MovementDerivation.snapshot(from: final, context: value, today: localToday),
            old: old, today: localToday, movement: final, context: value)
        let repeated = MovementDerivation.preservingConfirmedDeadlines(
            MovementDerivation.snapshot(from: final, context: value, today: localToday),
            old: first, today: localToday, movement: final, context: value)
        XCTAssertEqual(repeated.deadlines.filter(\.isActive).map { $0.provenance?.ruleID },
                       ["GPK-APPEAL-GENERAL"])
        XCTAssertTrue(repeated.deadlines.contains {
            $0.basis == legacyDeadline(status: .confirmed).basis && $0.lifecycle == .superseded
        })
    }

    func testPersistentPreparationAndStoreUpdateKeepCaseStateAndNoFalseFeed() throws {
        for (status, lifecycle) in [
            (DeadlineStatus.proposed, DeadlineLifecycle.active),
            (.confirmed, .active), (.overridden, .active), (.confirmed, .superseded),
        ] {
        let number = "2-6027/2026"
        let value = context(number)
        let initial = movement(number, sessions: [
            .init(date: "09.07.2026", event: "Судебное заседание", result: "Отложено"),
            .init(date: "21.09.2026", event: "Судебное заседание", result: nil),
        ], acts: [.init(id: "act-128", title: "Определение", date: "09.07.2026",
                         courtShort: "Сыктывкарский городской суд", instanceLevel: .first)])
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-128-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store")
        let store = try TrackedStore(container: SudrfModelContainerFactory.make(
            inMemory: false, storeURL: url), prepared: true)
        var old = snapshot(initial, value)
        old.deadlines = [legacyDeadline(status: status, lifecycle: lifecycle)]
        let record = try store.reconcileAndUpsert(context: value, snapshot: snapshot(initial, value),
                                                   movement: initial, collections: ["Проверка"])
        record.snapshot = old // Simulates the persisted legacy projection before startup repair.
        let seed = CaseEvent.make(
            kind: .judicialActPublished, occurrence: ["issue-128-seed"],
            observedAt: Date(timeIntervalSinceReferenceDate: 1), evidence: .init())
        record.eventJournal = CaseEventJournal(events: [seed])
        try store.save()
        let key = record.key
        let fetchedAt = try XCTUnwrap(record.movementFetchedAt)
        _ = try TrackedStorePreparation.prepare(context: store.container.mainContext, today: today)
        let prepared = try XCTUnwrap(store.record(forKey: key))
        XCTAssertEqual(prepared.snapshot?.deadlines.count, 1)
        XCTAssertTrue(prepared.snapshot?.deadlines.allSatisfy {
            $0.basis == legacyDeadline(status: .proposed).basis && $0.lifecycle == .superseded
        } == true)
        XCTAssertEqual(prepared.collectionNames, ["Проверка"])
        XCTAssertEqual(prepared.movement?.acts, initial.acts)
        XCTAssertEqual(prepared.movementFetchedAt, fetchedAt)
        XCTAssertEqual(prepared.eventJournal?.events, [seed])

        let reopened = try TrackedStore(container: SudrfModelContainerFactory.make(
            inMemory: false, storeURL: url), prepared: true)
        let persisted = try XCTUnwrap(reopened.record(forKey: key))
        XCTAssertEqual(persisted.snapshot?.deadlines, prepared.snapshot?.deadlines)
        XCTAssertEqual(persisted.collectionNames, ["Проверка"])
        XCTAssertEqual(persisted.movement?.acts, initial.acts)
        XCTAssertEqual(persisted.movementFetchedAt, fetchedAt)
        XCTAssertEqual(persisted.eventJournal?.events, [seed])

        let persistedDeadlines = persisted.snapshot?.deadlines
        let journal = persisted.eventJournal
        let refreshedSnapshot = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(initial, value), old: persisted.snapshot, today: today,
            movement: initial, context: value)
        let updated = try reopened.reconcileAndUpsert(
            context: value, snapshot: refreshedSnapshot, movement: initial,
            collections: ["Проверка"])
        XCTAssertEqual(updated.snapshot?.deadlines, persistedDeadlines)
        XCTAssertEqual(updated.collectionNames, ["Проверка"])
        XCTAssertEqual(updated.movement?.acts, initial.acts)
        XCTAssertEqual(updated.eventJournal, journal)

        let partialSnapshot = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(initial, value), old: updated.snapshot, today: today,
            preserveActiveProposedWhenMissing: true, movement: initial, context: value)
        let repeated = try reopened.reconcileAndUpsert(
            context: value, snapshot: partialSnapshot, movement: initial,
            collections: ["Проверка"], preserveActiveProposedDeadlinesOnPartial: true)
        XCTAssertEqual(repeated.snapshot?.deadlines, persistedDeadlines)
        XCTAssertEqual(repeated.eventJournal, journal)
        }
    }
}
