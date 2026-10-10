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
                        cartotekaId: ["g": "g1", "p": "p1", "u": "u1"][cartoteka] ?? cartoteka,
                        cartotekaLevelRaw: "district",
                        caseNumber: "2-100/2026")
    }

    private func movement(cartoteka: String = "g", category: String? = "Споры из договоров",
                          caseNumber: String? = nil, inForce: Bool = false,
                          sessions: [CaseSession], extra: [CaseInstance] = [],
                          parties: CaseParties = CaseParties()) -> CaseMovement {
        let number: String
        if let caseNumber {
            number = caseNumber
        } else {
            switch cartoteka {
            case "u": number = "1-100/2026"
            case "adm": number = "5-100/2026"
            default: number = "2-100/2026"
            }
        }
        let first = CaseInstance(level: .first, court: "Сыктывкарский городской суд",
                                 caseNumber: number, judge: nil,
                                 domain: "syktsud.komi.sudrf.ru", foundByUID: false,
                                 result: sessions.last?.result, sessions: sessions)
        return CaseMovement(uid: "11RS0001-01-2026-000100-11", caseNumber: number,
                            inForce: inForce, instances: [first] + extra,
                            complaints: [:], acts: [], category: category, parties: parties)
    }

    private func snapshot(_ movement: CaseMovement, cartoteka: String = "g",
                          today: Date? = nil) -> CaseSnapshot {
        MovementDerivation.snapshot(from: movement, context: context(cartoteka),
                                    today: today ?? self.today)
    }

    private func evaluation(_ movement: CaseMovement, cartoteka: String = "g",
                            receipt: DeadlineTriggerProvenance? = nil) throws
        -> DeadlineRuleEngine.Evaluation {
        try evaluation(movement, cartoteka: cartoteka, receipt: receipt,
                       registry: LegalDeadlineRegistry.load())
    }

    private func evaluation(_ movement: CaseMovement, cartoteka: String = "g",
                            receipt: DeadlineTriggerProvenance? = nil,
                            registry: LegalDeadlineRegistry) throws
        -> DeadlineRuleEngine.Evaluation {
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

    func testDecisionFinalFormConflictingDatesDoNotProduceExactDeadline() throws {
        let mv = movement(sessions: [
            CaseSession(date: "01.03.2026", event: "Судебное заседание", result: "Иск удовлетворён; вынесено решение"),
            CaseSession(date: "03.03.2026", event: "Решение изготовлено в окончательной форме"),
            CaseSession(date: "05.03.2026", event: "Решение изготовлено в окончательной форме"),
        ])
        let result = DeadlineRuleEngine.evaluate(
            registry: try LegalDeadlineRegistry.load(), movement: mv,
            context: DeadlineRuleEngine.Context(movementContext: context("g")),
            timeline: CaseLifecycleResolver.timeline(in: mv, production: .civil),
            today: DateUtil.parse("10.03.2026")!)
        let actual = result.deadlines.map { "\($0.provenance?.trigger.dateRaw ?? "nil") -> \($0.date)" }
        XCTAssertTrue(result.deadlines.isEmpty, "Actual trigger/deadline: \(actual)")
        let assessment = try XCTUnwrap(result.assessments.first { $0.ruleID == "GPK-APPEAL-GENERAL" })
        XCTAssertTrue(assessment.missingEvidenceRaw.contains(DeadlineEvidenceRequirement.finalForm.rawValue),
                      "Actual assessment: \(assessment)")
    }

    func testDecisionFinalFormDoesNotUseIntermediateDeterminationDate() throws {
        let mv = movement(sessions: [
            CaseSession(date: "01.03.2026", event: "Судебное заседание", result: "Иск удовлетворён; вынесено решение"),
            CaseSession(date: "03.03.2026", event: "Решение изготовлено в окончательной форме"),
            CaseSession(date: "10.03.2026", event: "Промежуточное определение изготовлено в окончательной форме"),
        ])
        let result = DeadlineRuleEngine.evaluate(
            registry: try LegalDeadlineRegistry.load(), movement: mv,
            context: DeadlineRuleEngine.Context(movementContext: context("g")),
            timeline: CaseLifecycleResolver.timeline(in: mv, production: .civil),
            today: DateUtil.parse("10.03.2026")!)
        let deadline = try XCTUnwrap(result.deadlines.first { $0.provenance?.ruleID == "GPK-APPEAL-GENERAL" })
        XCTAssertEqual(deadline.provenance?.trigger.dateRaw, "03.03.2026",
                       "Actual trigger: \(String(describing: deadline.provenance?.trigger)); deadline: \(deadline.date)")
    }

    func testDecisionFinalFormRequiresOwnActMembership() throws {
        for cartoteka in ["g", "p"] {
            for form in [
                CaseSession(date: "03.03.2026", event: "Изготовлено мотивированное решение в окончательной форме"),
                CaseSession(date: "03.03.2026", event: "Изготовление акта", result: "Решение изготовлено в окончательной форме"),
            ] {
                let decision = CaseSession(date: "01.03.2026", event: "Судебное заседание", result: "Иск удовлетворён; вынесено решение")
                let mv = movement(cartoteka: cartoteka, sessions: [decision, form, form])
                let result = try evaluation(mv, cartoteka: cartoteka)
                XCTAssertEqual(result.deadlines.first { $0.kind == "appeal" }?.provenance?.trigger.dateRaw, "03.03.2026")
            }
        }
        for wording in ["Принято в окончательной форме", "Решение не изготовлено в окончательной форме",
                        "Согласно решению от 01.03.2026 изготовлено в окончательной форме"] {
            let mv = movement(sessions: [
                .init(date: "01.03.2026", event: "Судебное заседание", result: "Иск удовлетворён; вынесено решение"),
                .init(date: "03.03.2026", event: wording),
            ])
            XCTAssertFalse(try evaluation(mv).deadlines.contains { $0.kind == "appeal" }, wording)
        }
    }

    func testDecisionFinalFormRejectsFutureNegatedAndForeignStatements() throws {
        for wording in ["Решение будет изготовлено в окончательной форме",
                        "Решение изготовлено не в окончательной форме",
                        "Решение нижестоящего суда изготовлено в окончательной форме",
                        "Решение, ранее принятое, изготовлено в окончательной форме"] {
            let mv = movement(sessions: [
                .init(date: "01.03.2026", event: "Судебное заседание", result: "Иск удовлетворён; вынесено решение"),
                .init(date: "03.03.2026", event: wording),
            ])
            XCTAssertFalse(try evaluation(mv).deadlines.contains { $0.kind == "appeal" }, wording)
        }
        for wording in ["Решение не изготовлено в окончательной форме",
                        "Согласно прежнему решению от 01.03.2026 изготовлено в окончательной форме"] {
            let mv = movement(sessions: [
                .init(date: "01.03.2026", event: "Судебное заседание", result: "Иск удовлетворён; вынесено решение"),
                .init(date: "03.03.2026", event: "Решение изготовлено в окончательной форме"),
                .init(date: "10.03.2026", event: wording),
            ])
            XCTAssertEqual(try evaluation(mv).deadlines.first { $0.kind == "appeal" }?.provenance?.trigger.dateRaw, "03.03.2026", wording)
        }
    }

    func testDecisionFinalFormTwoDecisionsRequireExplicitOwnTarget() throws {
        let announcements = [
            CaseSession(date: "01.03.2026", event: "Судебное заседание", result: "Иск удовлетворён; вынесено решение"),
            CaseSession(date: "02.03.2026", event: "Судебное заседание", result: "Иск удовлетворён; вынесено решение"),
        ]
        for (wording, accepted) in [
            ("Решение изготовлено в окончательной форме", false),
            ("Решение от 02.03.2026 изготовлено в окончательной форме", true),
            ("Решение от 01.03.2026 изготовлено в окончательной форме", false),
            ("Определение: решение от 02.03.2026 изготовлено в окончательной форме", false),
        ] {
            var combinedAnnouncements = announcements
            combinedAnnouncements[0].event = "Вынесено решение; составлен протокол"
            for rows in [announcements, announcements.reversed().map { $0 }, combinedAnnouncements] {
                let mv = movement(sessions: rows + [.init(date: "03.03.2026", event: wording)])
                let result = try evaluation(mv)
                XCTAssertEqual(result.deadlines.contains { $0.kind == "appeal" }, accepted, wording)
                var copied = mv
                copied.instances[0].sessions[copied.instances[0].sessions.count - 1].result = "Иск удовлетворён"
                XCTAssertEqual(try evaluation(copied).deadlines.contains { $0.kind == "appeal" }, accepted,
                               "Copied disposition: \(wording)")
            }
        }
    }

    func testDecisionFinalFormAdditionalAndDuplicateAnnouncements() throws {
        let ordinary = CaseSession(date: "01.03.2026", event: "Судебное заседание", result: "Иск удовлетворён; вынесено решение")
        let additional = CaseSession(date: "02.03.2026", event: "Вынесено дополнительное решение", result: "Иск удовлетворён")
        let form = CaseSession(date: "03.03.2026", event: "Дополнительное решение изготовлено в окончательной форме")
        let proved = movement(sessions: [ordinary, additional, additional, form])
        XCTAssertEqual(try evaluation(proved).deadlines.first { $0.kind == "appeal" }?.provenance?.trigger.dateRaw, "03.03.2026")
        let another = CaseSession(date: "04.03.2026", event: "Вынесено дополнительное решение", result: "Иск удовлетворён")
        let ambiguous = movement(sessions: [ordinary, additional, another,
                                            .init(date: "05.03.2026", event: form.event)])
        XCTAssertFalse(try evaluation(ambiguous).deadlines.contains { $0.kind == "appeal" })
    }

    func testDecisionFinalFormEarlierOrdinaryDoesNotBlockAdditionalAct() throws {
        let mv = movement(sessions: [
            .init(date: "01.03.2026", event: "Судебное заседание", result: "Иск удовлетворён; вынесено решение"),
            .init(date: "02.03.2026", event: "Решение изготовлено в окончательной форме"),
            .init(date: "03.03.2026", event: "Вынесено дополнительное решение", result: "Иск удовлетворён"),
            .init(date: "04.03.2026", event: "Дополнительное решение изготовлено в окончательной форме"),
        ])
        XCTAssertEqual(try evaluation(mv).deadlines.first { $0.kind == "appeal" }?.provenance?.trigger.dateRaw, "04.03.2026")
        var sameRow = mv
        sameRow.instances[0].sessions.remove(at: 1)
        sameRow.instances[0].sessions[0].result = "Иск удовлетворён; решение принято в окончательной форме"
        XCTAssertEqual(try evaluation(sameRow).deadlines.first { $0.kind == "appeal" }?.provenance?.trigger.dateRaw, "04.03.2026")
    }

    func testDecisionFinalFormCombinedAnnouncementRemainsOwnAct() throws {
        let mv = movement(sessions: [
            .init(date: "01.03.2026", event: "Вынесено решение; решение изготовлено в окончательной форме",
                  result: "Иск удовлетворён"),
        ])
        XCTAssertEqual(try evaluation(mv).deadlines.first { $0.kind == "appeal" }?.provenance?.trigger.dateRaw, "01.03.2026")
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

    func testMissingFinalFormWarnsWithoutKeepingTerminalFirstActive() {
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
        XCTAssertEqual(snap.stageRaw, CaseStageKind.done.rawValue)
        let presentation = MovementDerivation.lifecyclePresentation(
            from: mv, snapshot: snap, context: context("g"), today: today)
        XCTAssertEqual(presentation.nextEvent, "Нет даты окончательной формы")
        XCTAssertTrue(presentation.nextEventHelp?.contains("GPK-APPEAL-GENERAL") == true)
        XCTAssertTrue(presentation.nextEventHelp?.contains("окончательная форма акта") == true)
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

    func testMissingPackagedRegistryFailsClosedForKnownProduction() {
        let result = DeadlineRuleEngine.unavailable(
            context: .init(movementContext: context("g")))

        XCTAssertTrue(result.deadlines.isEmpty)
        XCTAssertEqual(result.assessments.single(where: {
            $0.ruleID == "GPK-APPEAL-GENERAL"
        })?.status, .needsLegalReview)
        XCTAssertTrue(result.assessments.contains(where: \.isIndeterminate))
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

    func testActiveCalendarMonthRulesUseCalendarArithmeticAndRecordBusinessDayTrace() throws {
        struct Example {
            let ruleID: String
            let kind: String
            let cartoteka: String
            let trigger: String
            let rawEnd: String
            let finalEnd: String
            let formula: String
            let policyID: String
        }
        let examples = [
            Example(ruleID: "GPK-APPEAL-GENERAL", kind: "appeal", cartoteka: "g",
                    trigger: "18.08.2026", rawEnd: "18.09.2026", finalEnd: "18.09.2026",
                    formula: "1 календарный месяц", policyID: "GPK-COUNTING-MONTH-YEAR-CALENDAR"),
            Example(ruleID: "GPK-APPEAL-GENERAL", kind: "appeal", cartoteka: "g",
                    trigger: "31.01.2025", rawEnd: "28.02.2025", finalEnd: "28.02.2025",
                    formula: "1 календарный месяц", policyID: "GPK-COUNTING-MONTH-YEAR-CALENDAR"),
            Example(ruleID: "KAS-APPEAL-GENERAL", kind: "appeal", cartoteka: "p",
                    trigger: "31.01.2024", rawEnd: "29.02.2024", finalEnd: "29.02.2024",
                    formula: "1 календарный месяц", policyID: "KAS-COUNTING-MONTH-YEAR-CALENDAR"),
            Example(ruleID: "GPK-APPEAL-GENERAL", kind: "appeal", cartoteka: "g",
                    trigger: "31.03.2026", rawEnd: "30.04.2026", finalEnd: "30.04.2026",
                    formula: "1 календарный месяц", policyID: "GPK-COUNTING-MONTH-YEAR-CALENDAR"),
            Example(ruleID: "GPK-CASSATION-CSOY", kind: "cassation", cartoteka: "g",
                    trigger: "30.06.2026", rawEnd: "30.09.2026", finalEnd: "30.09.2026",
                    formula: "3 календарных месяца", policyID: "GPK-COUNTING-MONTH-YEAR-CALENDAR"),
            Example(ruleID: "KAS-CASSATION-KSOYU", kind: "cassation", cartoteka: "p",
                    trigger: "31.08.2023", rawEnd: "29.02.2024", finalEnd: "29.02.2024",
                    formula: "6 календарных месяцев", policyID: "KAS-COUNTING-MONTH-YEAR-CALENDAR"),
            Example(ruleID: "KAS-APPEAL-GENERAL", kind: "appeal", cartoteka: "p",
                    trigger: "31.12.2025", rawEnd: "31.01.2026", finalEnd: "02.02.2026",
                    formula: "1 календарный месяц", policyID: "KAS-COUNTING-MONTH-YEAR-CALENDAR"),
            Example(ruleID: "KAS-APPEAL-GENERAL", kind: "appeal", cartoteka: "p",
                    trigger: "04.10.2026", rawEnd: "04.11.2026", finalEnd: "05.11.2026",
                    formula: "1 календарный месяц", policyID: "KAS-COUNTING-MONTH-YEAR-CALENDAR"),
        ]
        let registry = try LegalDeadlineRegistry.load()
        let calendar = try LegalCalendar.load()
        let timeZone = DateUtil.cal.timeZone

        for example in examples {
            let mv: CaseMovement
            if example.kind == "cassation" {
                mv = movement(cartoteka: example.cartoteka,
                              category: example.cartoteka == "p" ? "Оспаривание решения органа" : "Споры из договоров",
                              inForce: true,
                              sessions: [CaseSession(date: example.trigger,
                                                    event: "Решение вступило в законную силу")])
            } else if example.cartoteka == "p" {
                mv = movement(cartoteka: "p", category: "Оспаривание решения органа",
                              sessions: [CaseSession(date: example.trigger, event: "Судебное заседание",
                                                     result: "Административное исковое заявление удовлетворено; решение принято в окончательной форме")])
            } else {
                mv = qualifiedCivilMovement(date: example.trigger)
            }
            let rule = try XCTUnwrap(registry.rule(id: example.ruleID))
            let evaluated = try evaluation(mv, cartoteka: example.cartoteka, registry: registry)
            let deadline = try XCTUnwrap(evaluated.deadlines.single(where: {
                $0.provenance?.ruleID == example.ruleID
            }), example.ruleID)
            let provenance = try XCTUnwrap(deadline.provenance)
            let trace = try XCTUnwrap(provenance.calendarTrace)
            let rawEndDate = try XCTUnwrap(DateUtil.parse(example.rawEnd))
            let rawEnd = try XCTUnwrap(LegalCalendarDate(date: rawEndDate, timeZone: timeZone))
            let shifted = try XCTUnwrap(calendar.movingToNextWorkingDay(rawEnd, forCode: rule.code))
            let calendarFinal = try XCTUnwrap(shifted.date.date(timeZone: timeZone))
            let expectedFinal = try XCTUnwrap(DateUtil.parse(example.finalEnd))

            XCTAssertEqual(evaluated.deadlines.count, 1, example.ruleID)
            XCTAssertEqual(deadline.kind, example.kind, example.ruleID)
            XCTAssertEqual(rule.duration.kind, .months, example.ruleID)
            XCTAssertEqual(rule.duration.unit, .months, example.ruleID)
            XCTAssertEqual(rule.duration.raw, example.formula, example.ruleID)
            XCTAssertEqual(provenance.ruleID, example.ruleID, example.ruleID)
            XCTAssertEqual(provenance.registryRevision, rule.revision, example.ruleID)
            XCTAssertEqual(provenance.sourceHash, rule.sourceHash, example.ruleID)
            XCTAssertEqual(provenance.trigger.dateRaw, example.trigger, example.ruleID)
            XCTAssertEqual(provenance.formula, example.formula, example.ruleID)
            XCTAssertTrue(provenance.policyIDs.contains(example.policyID), example.ruleID)
            XCTAssertEqual(trace.operation, .moveToNextWorkingDay, example.ruleID)
            XCTAssertEqual(trace.start, rawEnd, "raw calendar end for \(example.ruleID)")
            XCTAssertEqual(trace.result, shifted.trace.result, example.ruleID)
            XCTAssertEqual(calendarFinal, expectedFinal, example.ruleID)
            XCTAssertEqual(deadline.date, expectedFinal, example.ruleID)
            XCTAssertEqual(deadline.date, trace.result.date(timeZone: timeZone), example.ruleID)
            XCTAssertEqual(deadline.dateRef, provenance.calculatedDateRef, example.ruleID)
        }
    }

    func testInjectedCalendarYearRuleUsesYearArithmeticWithoutActivatingProductionRule() throws {
        let base = try LegalDeadlineRegistry.load()
        let original = try XCTUnwrap(base.rule(id: "GPK-APPEAL-GENERAL"))
        XCTAssertEqual(original.duration.kind, .months)
        let annual = LegalDeadlineRule(
            ruleID: original.ruleID, stage: original.stage, actContext: original.actContext,
            duration: LegalDeadlineDuration(kind: .years, value: 1, unit: .years,
                                            raw: "1 календарный год"),
            durationText: "1 календарный год", trigger: original.trigger, source: original.source,
            priority: original.priority, notes: original.notes, code: original.code,
            document: original.document, revision: original.revision, sourceHash: original.sourceHash)
        let registry = LegalDeadlineRegistry(
            schemaVersion: base.schemaVersion, sources: base.sources,
            coreRules: base.coreRules.map { $0.ruleID == annual.ruleID ? annual : $0 },
            policies: base.policies, triggerDependencies: base.triggerDependencies,
            constraints: base.constraints, exclusions: base.exclusions,
            openQuestions: base.openQuestions)
        let calendar = try LegalCalendar.load()
        let timeZone = DateUtil.cal.timeZone

        for (trigger, rawEnd, finalEnd) in [("18.08.2025", "18.08.2026", "18.08.2026"),
                                            ("01.03.2023", "01.03.2024", "01.03.2024"),
                                            ("29.02.2024", "28.02.2025", "28.02.2025")] {
            let evaluated = try evaluation(qualifiedCivilMovement(date: trigger), registry: registry)
            let deadline = try XCTUnwrap(evaluated.deadlines.single(where: {
                $0.provenance?.ruleID == annual.ruleID
            }))
            let provenance = try XCTUnwrap(deadline.provenance)
            let trace = try XCTUnwrap(provenance.calendarTrace)
            let rawEndDate = try XCTUnwrap(DateUtil.parse(rawEnd))
            let rawEndDateOnly = try XCTUnwrap(LegalCalendarDate(date: rawEndDate, timeZone: timeZone))
            let shifted = try XCTUnwrap(calendar.movingToNextWorkingDay(rawEndDateOnly,
                                                                       forCode: annual.code))
            let calendarFinal = try XCTUnwrap(shifted.date.date(timeZone: timeZone))
            let expectedFinal = try XCTUnwrap(DateUtil.parse(finalEnd))

            XCTAssertEqual(evaluated.deadlines.count, 1)
            XCTAssertEqual(annual.duration.kind, .years)
            XCTAssertEqual(annual.duration.unit, .years)
            XCTAssertEqual(annual.duration.value, 1)
            XCTAssertEqual(provenance.trigger.dateRaw, trigger)
            XCTAssertEqual(provenance.formula, "1 календарный год")
            XCTAssertEqual(trace.start, rawEndDateOnly)
            XCTAssertEqual(trace.result, shifted.trace.result)
            XCTAssertEqual(calendarFinal, expectedFinal)
            XCTAssertEqual(deadline.date, expectedFinal)
            XCTAssertEqual(deadline.dateRef, provenance.calculatedDateRef)
        }
    }

    func testKASIssue294SelectsElectionAndGeneralPrivateRules() throws {
        let electionCategory = "О защите избирательных прав и права на участие в референдуме (гл. 24 КАС РФ)"
        let decision = movement(
            cartoteka: "p", category: electionCategory, caseNumber: "3а-682/2026",
            sessions: [
                CaseSession(date: "11.09.2026", event: "Судебное заседание",
                            result: "Вынесено решение по делу; в удовлетворении отказано"),
                CaseSession(date: "11.09.2026",
                            event: "Изготовлено мотивированное решение в окончательной форме"),
            ])
        let electionAppeal = try evaluation(decision, cartoteka: "p")
        let appeal = try XCTUnwrap(electionAppeal.deadlines.single(where: { $0.kind == "appeal" }))

        XCTAssertEqual(electionAppeal.deadlines.count, 1)
        XCTAssertEqual(appeal.date, DateUtil.parse("16.09.2026"))
        XCTAssertEqual(appeal.provenance?.ruleID, "KAS-APPEAL-ELECTION")
        XCTAssertEqual(appeal.provenance?.trigger.dateRaw, "11.09.2026")
        XCTAssertTrue(appeal.provenance?.policyIDs.contains(
            "KAS-COUNTING-DAY-CALENDAR-EXCEPTIONS") ?? false)
        XCTAssertTrue(appeal.provenance?.policyIDs.contains(
            "KAS-END-POST-NO-SAFE-HARBOR-ELECTION") ?? false)
        XCTAssertFalse(appeal.provenance?.policyIDs.contains(
            "KAS-END-NONWORKING-NEXT-WORKING") ?? true)

        for number in ["3а-683/2026", "3а-684/2026"] {
            let terminated = movement(
                cartoteka: "p", category: electionCategory, caseNumber: number,
                sessions: [CaseSession(date: "11.09.2026", event: "Судебное заседание",
                                       result: "Производство по делу ПРЕКРАЩЕНО")])
            let evaluated = try evaluation(terminated, cartoteka: "p")
            let deadline = try XCTUnwrap(evaluated.deadlines.single(where: {
                $0.what == "Частная жалоба"
            }))

            XCTAssertEqual(evaluated.deadlines.count, 1, number)
            XCTAssertEqual(deadline.date, DateUtil.parse("16.09.2026"), number)
            XCTAssertEqual(deadline.provenance?.ruleID, "KAS-PRIVATE-ELECTION", number)
        }

        let generic = movement(
            cartoteka: "p",
            category: "Об оспаривании решений, действий (бездействия) иных органов, организаций, наделенных публичными полномочиями",
            caseNumber: "3а-685/2026",
            sessions: [CaseSession(date: "11.09.2026", event: "Судебное заседание",
                                   result: "Производство по делу ПРЕКРАЩЕНО")],
            parties: CaseParties(thirdParties: ["Избирательная комиссия Республики Коми"]))
        let generalPrivate = try evaluation(generic, cartoteka: "p")
        let privateDeadline = try XCTUnwrap(generalPrivate.deadlines.single(where: {
            $0.what == "Частная жалоба"
        }))

        XCTAssertEqual(generalPrivate.deadlines.count, 1)
        XCTAssertEqual(privateDeadline.date, DateUtil.parse("02.10.2026"))
        XCTAssertEqual(privateDeadline.provenance?.ruleID, "KAS-PRIVATE-GENERAL")
        XCTAssertTrue(privateDeadline.provenance?.policyIDs.contains(
            "KAS-COUNTING-DAY-WORKING-GENERAL") ?? false)
        XCTAssertEqual(generalPrivate.assessments.single(where: {
            $0.ruleID == "KAS-PRIVATE-ELECTION"
        })?.status, .notApplicable)

        let referendum = movement(
            cartoteka: "p", category: "О защите права на участие в референдуме",
            sessions: [CaseSession(date: "11.09.2026", event: "Судебное заседание",
                                   result: "Производство по делу ПРЕКРАЩЕНО")])
        let referendumEvaluation = try evaluation(referendum, cartoteka: "p")
        XCTAssertEqual(referendumEvaluation.deadlines.count, 1)
        XCTAssertEqual(referendumEvaluation.deadlines.first?.provenance?.ruleID,
                       "KAS-PRIVATE-ELECTION")
    }

    func testKASIssue294PrivateRulesIgnoreIntermediateActsAndRequireCategory() throws {
        let intermediate = movement(
            cartoteka: "p", category: "Об оспаривании решения органа",
            sessions: [CaseSession(date: "11.09.2026",
                                   event: "Определение о подготовке дела к судебному разбирательству",
                                   result: "Назначено судебное заседание")])
        let evaluatedIntermediate = try evaluation(intermediate, cartoteka: "p")
        XCTAssertFalse(evaluatedIntermediate.deadlines.contains { $0.what == "Частная жалоба" })

        let missingCategory = movement(
            cartoteka: "p", category: nil,
            sessions: [CaseSession(date: "11.09.2026", event: "Судебное заседание",
                                   result: "Производство по делу ПРЕКРАЩЕНО")])
        let evaluatedMissing = try evaluation(missingCategory, cartoteka: "p")
        XCTAssertTrue(evaluatedMissing.deadlines.isEmpty)
        XCTAssertEqual(evaluatedMissing.assessments.single(where: {
            $0.ruleID == "KAS-PRIVATE-GENERAL"
        })?.status, .insufficientEvidence)
    }

    func testKASElectionDeadlineEndingOnWeekendIsNotMoved() throws {
        let mv = movement(
            cartoteka: "p", category: "Защита избирательных прав (гл. 24 КАС РФ)",
            sessions: [CaseSession(date: "15.09.2026", event: "Судебное заседание",
                                   result: "Вынесено решение по делу")])
        let evaluated = try evaluation(mv, cartoteka: "p")
        let deadline = try XCTUnwrap(evaluated.deadlines.single(where: {
            $0.provenance?.ruleID == "KAS-APPEAL-ELECTION"
        }))

        XCTAssertEqual(deadline.date, DateUtil.parse("20.09.2026"))
        XCTAssertNil(deadline.provenance?.calendarTrace)
    }

    func testKASPrivateDeadlinePresentationAndOverrideSurviveRefresh() {
        let mv = movement(
            cartoteka: "p", category: "Об оспаривании решения органа",
            caseNumber: "3а-685/2026",
            sessions: [CaseSession(date: "11.09.2026", event: "Судебное заседание",
                                   result: "Производство по делу ПРЕКРАЩЕНО")])
        let currentDay = DateUtil.parse("12.09.2026")!
        let original = snapshot(mv, cartoteka: "p", today: currentDay)
        XCTAssertTrue(original.nextEvent.hasPrefix("срок частной жалобы:"))

        var edited = original
        edited.deadlines[0].statusRaw = DeadlineStatus.overridden.rawValue
        edited.deadlines[0].dateRef = DateUtil.parse("05.10.2026")!.timeIntervalSinceReferenceDate
        let refreshed = MovementDerivation.preservingConfirmedDeadlines(
            snapshot(mv, cartoteka: "p", today: currentDay), old: edited, today: currentDay)

        XCTAssertEqual(refreshed.deadlines.single(where: { $0.isActive })?.status, .overridden)
        XCTAssertEqual(refreshed.deadlines.single(where: { $0.isActive })?.date,
                       DateUtil.parse("05.10.2026"))
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

    func testKoAPNonWorkingEndpointMovesUsingPackagedCalendarAndRecordsTrace() throws {
        let mv = movement(cartoteka: "adm", category: "Нарушение правил дорожного движения",
                          sessions: [
                            CaseSession(date: "01.04.2026", event: "Судебное заседание",
                                        result: "Постановление по делу об административном правонарушении"),
                          ])
        let receipt = DeadlineTriggerProvenance(
            event: "Вручена копия постановления", result: nil, dateRaw: "09.04.2026",
            court: "Сыктывкарский городской суд", levelRaw: "first", caseNumber: "5-100/2026")
        let evaluated = try evaluation(mv, cartoteka: "adm", receipt: receipt)
        let deadline = try XCTUnwrap(evaluated.deadlines.single(where: {
            $0.kind == "appeal"
        }))
        let trace = try XCTUnwrap(deadline.provenance?.calendarTrace)

        XCTAssertEqual(deadline.date, DateUtil.parse("20.04.2026"))
        XCTAssertEqual(evaluated.assessments.single(where: {
            $0.ruleID == "KOAP-APPEAL-INITIAL-GENERAL"
        })?.status, .applicable)
        XCTAssertEqual(trace.result,
                       try XCTUnwrap(LegalCalendarDate(year: 2026, month: 4, day: 20)))
        XCTAssertTrue(trace.revisions.contains { $0.year == 2026 })
        XCTAssertTrue(deadline.provenance?.policyIDs.contains("KOAP-END-NONWORKING-DAY") ?? false)
    }

    func testCalendarCoverageFailsClosedOutsideConfirmedYears() throws {
        let mv = movement(cartoteka: "adm", category: "Нарушение правил дорожного движения",
                          sessions: [
                            CaseSession(date: "01.01.2012", event: "Судебное заседание",
                                        result: "Постановление по делу об административном правонарушении"),
                          ])
        let receipt = DeadlineTriggerProvenance(
            event: "Вручена копия постановления", result: nil, dateRaw: "01.01.2012",
            court: "Сыктывкарский городской суд", levelRaw: "first", caseNumber: "5-100/2012")
        let evaluated = try evaluation(mv, cartoteka: "adm", receipt: receipt)

        XCTAssertTrue(evaluated.deadlines.isEmpty)
        XCTAssertEqual(evaluated.assessments.single(where: {
            $0.ruleID == "KOAP-APPEAL-INITIAL-GENERAL"
        })?.status, .unsupportedCalculation)

        let unconfirmedMonth = try evaluation(qualifiedCivilMovement(date: "31.12.2027"))
        XCTAssertTrue(unconfirmedMonth.deadlines.isEmpty)
        let assessment = try XCTUnwrap(unconfirmedMonth.assessments.single(where: {
            $0.ruleID == "GPK-APPEAL-GENERAL"
        }))
        XCTAssertEqual(assessment.status, .unsupportedCalculation)
        XCTAssertEqual(assessment.missingPolicyIDs, ["GPK-END-NONWORKING-NEXT-WORKING"])
    }

    func testConfirmed2027CalendarSeparatesMonthEndAndWorkingDayShift() throws {
        let evaluated = try evaluation(qualifiedCivilMovement(date: "31.12.2026"))
        let deadline = try XCTUnwrap(evaluated.deadlines.single(where: { $0.kind == "appeal" }))
        XCTAssertEqual(deadline.date, DateUtil.parse("01.02.2027"))
        let trace = try XCTUnwrap(deadline.provenance?.calendarTrace)
        XCTAssertEqual(trace.start, LegalCalendarDate(year: 2027, month: 1, day: 31))
        XCTAssertEqual(trace.result, LegalCalendarDate(year: 2027, month: 2, day: 1))
        XCTAssertEqual(trace.revisions.map(\.year), [2027])
        XCTAssertEqual(deadline.provenance?.ruleID, "GPK-APPEAL-GENERAL")
    }

    func testExistingKoAPBindingUsesWorkingDayCalendarWithoutActivatingAnotherRule() throws {
        let base = try LegalDeadlineRegistry.load()
        let original = try XCTUnwrap(base.rule(id: "KOAP-APPEAL-INITIAL-GENERAL"))
        let workingDayRule = LegalDeadlineRule(
            ruleID: original.ruleID, stage: original.stage, actContext: original.actContext,
            duration: LegalDeadlineDuration(kind: .workingDays, value: 3, unit: .workingDays,
                                            raw: "3 рабочих дня"),
            durationText: "3 рабочих дня", trigger: original.trigger, source: original.source,
            priority: original.priority, notes: original.notes, code: original.code,
            document: original.document, revision: original.revision, sourceHash: original.sourceHash)
        let fixture = LegalDeadlineRegistry(
            schemaVersion: base.schemaVersion, sources: base.sources,
            coreRules: base.coreRules.map {
                $0.ruleID == workingDayRule.ruleID ? workingDayRule : $0
            }, policies: base.policies, triggerDependencies: base.triggerDependencies,
            constraints: base.constraints, exclusions: base.exclusions,
            openQuestions: base.openQuestions)
        let mv = movement(cartoteka: "adm", category: "Нарушение правил дорожного движения",
                          sessions: [CaseSession(date: "01.04.2026", event: "Судебное заседание",
                                                 result: "Постановление по делу об административном правонарушении")])
        let receipt = DeadlineTriggerProvenance(
            event: "Вручена копия постановления", result: nil, dateRaw: "09.04.2026",
            court: "Сыктывкарский городской суд", levelRaw: "first", caseNumber: "5-100/2026")

        let evaluated = try evaluation(mv, cartoteka: "adm", receipt: receipt, registry: fixture)
        let deadline = try XCTUnwrap(evaluated.deadlines.single(where: { $0.kind == "appeal" }))

        XCTAssertEqual(deadline.date, DateUtil.parse("14.04.2026"))
        XCTAssertEqual(deadline.provenance?.ruleID, "KOAP-APPEAL-INITIAL-GENERAL")
        XCTAssertEqual(deadline.provenance?.calendarTrace?.operation, .addWorkingDays)
        XCTAssertEqual(deadline.provenance?.calendarTrace?.countedWorkingDays, 3)
        XCTAssertEqual(evaluated.assessments.filter { $0.status == .applicable }.count, 1,
                       "fixture must calculate only the applicable KoAP route")
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

    func testPendingKASCassationDoesNotCreateRestartedDeadline() throws {
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
        })?.status, .notApplicable)
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

    func testPartialRefreshKeepsActiveProposedDeadlineButCompleteRefreshSupersedesIt() {
        let original = snapshot(qualifiedCivilMovement())
        let noDeadline = snapshot(movement(sessions: [
            CaseSession(date: "14.04.2026", event: "Регистрация дела"),
        ]))

        let partial = MovementDerivation.preservingConfirmedDeadlines(
            noDeadline, old: original, today: today, preserveActiveProposedWhenMissing: true)
        XCTAssertEqual(partial.deadlines.count, 1)
        XCTAssertTrue(partial.deadlines[0].isActive)
        XCTAssertEqual(partial.deadlines[0].status, .proposed)

        let complete = MovementDerivation.preservingConfirmedDeadlines(
            noDeadline, old: original, today: today)
        XCTAssertEqual(complete.deadlines.count, 1)
        XCTAssertEqual(complete.deadlines[0].lifecycle, .superseded)
    }

    func testStartupRepairsOnlyVerifiedOrphanedSupersededProposedDeadline() {
        let fresh = snapshot(qualifiedCivilMovement())
        var orphaned = fresh
        orphaned.deadlines[0].lifecycleRaw = DeadlineLifecycle.superseded.rawValue

        let repaired = MovementDerivation.repairingOrphanedSupersededProposedDeadlines(
            old: orphaned, fresh: fresh, today: today)
        XCTAssertEqual(repaired.deadlines.count, 1)
        XCTAssertTrue(repaired.deadlines[0].isActive)

        var expired = orphaned
        expired.deadlines[0].lifecycleRaw = DeadlineLifecycle.expiredUnconfirmed.rawValue
        XCTAssertEqual(MovementDerivation.repairingOrphanedSupersededProposedDeadlines(
            old: expired, fresh: fresh, today: today).deadlines[0].lifecycle,
            .expiredUnconfirmed)

        var unsupported = fresh
        unsupported.deadlineAssessments?[0].statusRaw = DeadlineAssessmentStatus.insufficientEvidence.rawValue
        XCTAssertEqual(MovementDerivation.repairingOrphanedSupersededProposedDeadlines(
            old: orphaned, fresh: unsupported, today: today).deadlines[0].lifecycle,
            .superseded)

        var oldNotApplicable = orphaned
        oldNotApplicable.deadlineAssessments?[0].statusRaw =
            DeadlineAssessmentStatus.notApplicable.rawValue
        XCTAssertEqual(MovementDerivation.repairingOrphanedSupersededProposedDeadlines(
            old: oldNotApplicable, fresh: fresh, today: today).deadlines[0].lifecycle,
            .superseded)

        let stale = snapshot(qualifiedCivilMovement(date: "01.01.2026"))
        var staleOrphan = stale
        staleOrphan.deadlines[0].lifecycleRaw = DeadlineLifecycle.superseded.rawValue
        XCTAssertEqual(MovementDerivation.repairingOrphanedSupersededProposedDeadlines(
            old: staleOrphan, fresh: stale, today: today).deadlines[0].lifecycle,
            .superseded)

        var replaced = orphaned
        replaced.deadlines.append(snapshot(qualifiedCivilMovement(date: "14.04.2026")).deadlines[0])
        XCTAssertEqual(MovementDerivation.repairingOrphanedSupersededProposedDeadlines(
            old: replaced, fresh: fresh, today: today).deadlines[0].lifecycle,
            .superseded)

        var userControlled = orphaned
        userControlled.deadlines[0].statusRaw = DeadlineStatus.overridden.rawValue
        XCTAssertEqual(MovementDerivation.repairingOrphanedSupersededProposedDeadlines(
            old: userControlled, fresh: fresh, today: today).deadlines[0].lifecycle,
            .superseded)
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

    func testDeadlineInfoProjectionUsesRegistryAndExposesLifecycle() throws {
        let stored = try XCTUnwrap(snapshot(qualifiedCivilMovement()).deadlines.first)
        let tracked = TrackedDeadline(
            id: "record#\(stored.occurrenceKey ?? stored.kind)", recordKey: "record",
            what: stored.what, caseNumber: "2-100/2026", basis: stored.basis,
            calLabel: stored.calLabel, date: DateUtil.parse("20.05.2026")!, status: .overridden,
            lifecycle: .superseded, provenance: stored.provenance)
        let projection = DeadlineInfoProjection(
            deadline: tracked, registry: try LegalDeadlineRegistry.load())

        XCTAssertTrue(projection.hasProvenance)
        XCTAssertTrue(projection.rule.contains("GPK-APPEAL-GENERAL"))
        XCTAssertEqual(projection.source, "ст. 321 ч. 1 ГПК РФ")
        XCTAssertEqual(projection.formula, "1 календарный месяц")
        XCTAssertTrue(projection.trigger.contains("Судебное заседание"))
        XCTAssertTrue(projection.policies.contains("GPK-COUNTING-MONTH-YEAR-CALENDAR"))
        XCTAssertEqual(projection.calculatedDate, "13 мая")
        XCTAssertTrue(projection.calendar.contains("Проверена рабочая дата окончания"))
        let revisionHash = try XCTUnwrap(stored.provenance?.calendarTrace?.revisions.first?.sourceHash)
        XCTAssertFalse(projection.calendar.contains(revisionHash),
                       "хеш остаётся в provenance, а не в пользовательском объяснении")
        XCTAssertEqual(projection.status, "Дата изменена пользователем")
        XCTAssertEqual(projection.lifecycle, "Не действует")
    }

    func testDeadlineInfoProjectionMarksOldAutomaticCalendarCalculationUnverified() throws {
        var stored = try XCTUnwrap(snapshot(qualifiedCivilMovement()).deadlines.first)
        stored.provenance?.calendarTrace = nil
        let tracked = TrackedDeadline(
            id: "record#\(stored.occurrenceKey ?? stored.kind)", recordKey: "record",
            what: stored.what, caseNumber: "2-100/2026", basis: stored.basis,
            calLabel: stored.calLabel, date: stored.date, status: .proposed,
            lifecycle: .active, provenance: stored.provenance)

        let projection = DeadlineInfoProjection(
            deadline: tracked, registry: try LegalDeadlineRegistry.load())

        XCTAssertEqual(projection.status, "Расчётный")
        XCTAssertEqual(projection.calendar,
                       "Производственный календарь для сохранённого расчёта не проверен")
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
