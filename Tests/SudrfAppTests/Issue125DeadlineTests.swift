import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class Issue125DeadlineTests: XCTestCase {
    private struct Example {
        var code: String
        var material: Bool
        var movement: CaseMovement
        var context: MovementContext
    }

    private func example(code: String, material: Bool = false,
                         event: String, result: String? = nil,
                         decisionDate: String? = nil,
                         sessionDate: String? = nil, category: String? = nil,
                         missingCategory: Bool = false,
                         caseNumber overrideNumber: String? = nil) -> Example {
        let cartoteka = material ? "m" : (code == "GPK" ? "g1" : "p1")
        let number = overrideNumber ?? (material
            ? (code == "GPK" ? "13-125/2026" : "13а-125/2026")
            : (code == "GPK" ? "2-125/2026" : "2а-125/2026"))
        let process: ProcessKind = code == "GPK" ? .civil : .administrative
        let sourceCategory = code == "GPK" ? "ГПК РФ" : "КАС РФ"
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru", displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: "11RS0001",
            cartotekaId: cartoteka, cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: number,
            baseInstanceLevelRaw: material ? CaseInstance.Level.material.rawValue : CaseInstance.Level.first.rawValue)
        let session = CaseSession(date: sessionDate ?? decisionDate ?? "11.09.2026", event: event,
                                  result: result)
        let instance = CaseInstance(
            level: material ? .material : .first,
            court: context.courtTitle, caseNumber: number, judge: nil,
            domain: context.displayDomain, foundByUID: false,
            result: result, sessions: [session],
            sourceEvidence: .init(decisionDate: decisionDate,
                                  cartotekaID: cartoteka,
                                  sourceCourtLevel: .district,
                                  sourceBranch: .general,
                                  category: sourceCategory,
                                  ownProcessKind: process))
        let movement = CaseMovement(
            uid: "11RS0001-01-2026-000125-11", caseNumber: number,
            inForce: false, instances: [instance], complaints: [:], acts: [],
            category: missingCategory ? nil
                : (category ?? (code == "GPK" ? "Споры из договоров" : "Оспаривание решения органа")))
        return Example(code: code, material: material, movement: movement, context: context)
    }

    private func evaluate(_ example: Example) throws -> DeadlineRuleEngine.Evaluation {
        let classification = MaterialProductionContext.resolve(
            context: example.context, movement: example.movement)
        return DeadlineRuleEngine.evaluate(
            registry: try LegalDeadlineRegistry.load(), movement: example.movement,
            context: .init(movementContext: example.context),
            timeline: CaseLifecycleResolver.timeline(
                in: example.movement, production: classification.production),
            today: DateUtil.parse("01.05.2026")!)
    }

    func testFourBlockingDeterminationsUseOneRegistryDeadlineForBothCodesAndScopes() throws {
        for code in ["GPK", "KAS"] {
            let claim = code == "GPK" ? "искового заявления" : "административного искового заявления"
            let determinations = [
                "Определение о возврате \(claim) заявителю",
                "Определение об отказе в принятии \(claim)",
                "Определение об оставлении \(claim) без рассмотрения",
                "Определение о прекращении производства по делу",
            ]
            for material in [false, true] {
                for event in determinations {
                    let result = try evaluate(example(code: code, material: material,
                                                      event: event))
                    let expectedRule = code == "GPK"
                        ? "GPK-PRIVATE-COMPLAINT-GENERAL" : "KAS-PRIVATE-GENERAL"
                    XCTAssertEqual(result.deadlines.count, 1, "\(code), material=\(material), \(event)")
                    XCTAssertEqual(result.deadlines.first?.provenance?.ruleID, expectedRule)
                    XCTAssertEqual(result.deadlines.first?.date, DateUtil.parse("02.10.2026"))
                    XCTAssertEqual(result.deadlines.first?.provenance?.trigger.dateRaw, "11.09.2026")
                }
            }
        }
    }

    func testDatedCardResultCanCompleteItsSameDayMaterialsReturnEvent() throws {
        let cardResult = "Заявление ВОЗВРАЩЕНО заявителю не исправлены недостатки"
        let result = try evaluate(example(
            code: "KAS", material: true,
            event: "Материалы возвращены в связи с истечением срока, данного для исправления недостатков",
            result: cardResult, decisionDate: "25.11.2025",
            category: "Нормативные правовые акты и акты, содержащие разъяснения законодательства (глава 21 КАС РФ)"))

        XCTAssertEqual(result.deadlines.count, 1)
        XCTAssertEqual(result.deadlines.first?.provenance?.ruleID, "KAS-PRIVATE-GENERAL")
        XCTAssertEqual(result.deadlines.first?.provenance?.trigger.result, cardResult)
        XCTAssertEqual(result.deadlines.first?.date, DateUtil.parse("16.12.2025"))
    }

    func testKASElectionReturnKeepsExistingFiveCalendarDayRule() throws {
        let result = try evaluate(example(
            code: "KAS", event: "Решение вопроса о принятии к производству",
            result: "Административное исковое заявление возвращено",
            decisionDate: "26.06.2025",
            category: "Защита избирательных прав (глава 24 КАС РФ)"))

        XCTAssertEqual(result.deadlines.count, 1)
        XCTAssertEqual(result.deadlines.first?.provenance?.ruleID, "KAS-PRIVATE-ELECTION")
        XCTAssertEqual(result.deadlines.first?.date, DateUtil.parse("01.07.2025"))
    }

    func testPrivateComplaintCalendarCountsAcrossYearEndAndFailsClosedOutsideCoverage() throws {
        let yearEnd = try evaluate(example(
            code: "GPK", event: "Определение о прекращении производства по делу",
            decisionDate: "31.12.2025"))
        XCTAssertEqual(yearEnd.deadlines.first?.date, DateUtil.parse("30.01.2026"))

        let outsideCoverage = try evaluate(example(
            code: "GPK", event: "Определение о прекращении производства по делу",
            decisionDate: "04.01.2027"))
        XCTAssertTrue(outsideCoverage.deadlines.isEmpty)
        XCTAssertEqual(outsideCoverage.assessments.first(where: {
            $0.ruleID == "GPK-PRIVATE-COMPLAINT-GENERAL"
        })?.status, .unsupportedCalculation)
    }

    func testIntermediateNegatedQuotedUndatedAndNumberOnlyEvidenceDoNotCreateDeadline() throws {
        let examples = [
            example(code: "GPK", event: "Судебное заседание",
                    result: "Исковое заявление оставлено без движения"),
            example(code: "GPK", event: "Определение о возврате заявления",
                    result: "Заявление не возвращено заявителю"),
            example(code: "GPK", event: "Ранее вынесенное определение о возврате заявления"),
            example(code: "GPK", event: "Определение о возврате заявления",
                    result: nil, decisionDate: nil, sessionDate: "—"),
            example(code: "GPK", event: "Вынесено определение",
                    result: "В прекращении производства по делу отказано"),
            example(code: "GPK", event: "Вынесено определение",
                    result: "Отказано в удовлетворении заявления о прекращении производства по делу"),
            example(code: "KAS", event: "Вынесено определение",
                    result: "Отказано в удовлетворении заявления о прекращении производства по делу"),
            example(code: "GPK", event: "Определение об отказе в удовлетворении заявления о возврате искового заявления"),
            example(code: "KAS", event: "Определение об отказе в удовлетворении заявления о возврате искового заявления"),
            example(code: "GPK", event: "Определение о прекращении производства по делу",
                    result: "В удовлетворении заявления о прекращении производства по делу отказано"),
            example(code: "KAS", event: "Определение о прекращении производства по делу",
                    result: "В удовлетворении заявления о прекращении производства по делу отказано"),
            example(code: "GPK", event: "Определение об оставлении искового заявления без рассмотрения",
                    result: "Отказано в удовлетворении заявления об оставлении искового заявления без рассмотрения"),
            example(code: "KAS", event: "Определение об оставлении искового заявления без рассмотрения",
                    result: "Отказано в удовлетворении заявления об оставлении искового заявления без рассмотрения"),
            example(code: "GPK", event: "Подготовка дела к судебному разбирательству",
                    result: "Назначено судебное заседание"),
            example(code: "GPK", event: "Судебное заседание",
                    result: "Рассмотрение отложено"),
            example(code: "GPK", event: "Заявлен отвод судье"),
            example(code: "GPK", event: "Рассмотрено ходатайство о прекращении производства по делу"),
            example(code: "GPK", event: "Приобщены доказательства возврата искового заявления"),
            example(code: "GPK", event: "Судебное заседание",
                    result: "Ходатайство о возврате искового заявления удовлетворено"),
            example(code: "GPK", event: "Судебное заседание", result: nil,
                    sessionDate: "—", caseNumber: "9а-66/2025"),
            example(code: "GPK", event: "Судебное заседание", result: nil,
                    caseNumber: "9а-66/2025"),
            example(code: "GPK", event: "Определение об отказе в принятии заявления об обеспечении иска"),
            example(code: "GPK", event: "Определение о возврате заявления о восстановлении срока"),
            example(code: "GPK", event: "Определение о возврате заявления о замене стороны по делу"),
            example(code: "GPK", event: "Материалы возвращены после истечения срока исправления",
                    result: "Заявление о восстановлении срока возвращено заявителю",
                    decisionDate: "11.09.2026"),
        ]
        for value in examples {
            XCTAssertTrue(try evaluate(value).deadlines.isEmpty, "\(value.movement.instances[0].sessions)")
        }
    }

    func testSameDayCardOutcomeDoesNotOverrideAnExplicitDecision() throws {
        let base = example(code: "GPK", event: "Судебное заседание",
                           result: "Иск удовлетворён")
        var movement = base.movement
        movement.instances[0].result = "Заявление возвращено заявителю"
        movement.instances[0].sourceEvidence?.decisionDate = "11.09.2026"
        let result = try evaluate(Example(code: base.code, material: base.material,
                                          movement: movement, context: base.context))

        XCTAssertTrue(result.deadlines.isEmpty)
        XCTAssertEqual(result.assessments.first(where: {
            $0.ruleID == "GPK-PRIVATE-COMPLAINT-GENERAL"
        })?.status, .insufficientEvidence)
    }

    func testPreviousRoundBlockingActDoesNotCarryIntoTheRemandedRound() throws {
        let current = example(code: "GPK", event: "Исковое заявление принято к производству",
                              sessionDate: "10.04.2026")
        let number = current.movement.caseNumber
        let oldFirst = CaseInstance(
            level: .first, court: current.context.courtTitle, caseNumber: number,
            judge: nil, domain: "archive.sudrf.ru", foundByUID: false,
            result: "Исковое заявление возвращено заявителю",
            sessions: [CaseSession(date: "01.03.2026",
                                   event: "Определение о возврате искового заявления")])
        let remandResult = "Решение отменено, дело направлено на новое рассмотрение в суд первой инстанции"
        let appeal = CaseInstance(
            level: .appeal, court: "Верховный суд Республики Коми", caseNumber: "33-125/2026",
            judge: nil, domain: "vs.komi.sudrf.ru", foundByUID: false,
            result: remandResult,
            sessions: [CaseSession(date: "01.04.2026", event: "Результат рассмотрения",
                                   result: remandResult)])
        var movement = current.movement
        movement.instances.append(contentsOf: [oldFirst, appeal])
        let example = Example(code: current.code, material: false,
                              movement: movement, context: current.context)
        let classification = MaterialProductionContext.resolve(
            context: example.context, movement: example.movement)
        let timeline = CaseLifecycleResolver.timeline(
            in: example.movement, production: classification.production)

        XCTAssertEqual(timeline.currentRoundStart?.instance.caseNumber, number)
        XCTAssertEqual(timeline.deadlineFirst?.sessions.map(\.date), ["10.04.2026"])
        XCTAssertTrue(try evaluate(example).deadlines.isEmpty)
    }

    func testSameDayConflictingDeterminationsAreInsufficientForMainAndMaterial() throws {
        for code in ["GPK", "KAS"] {
            for material in [false, true] {
                let base = example(code: code, material: material,
                                   event: "Определение о возврате искового заявления")
                var movement = base.movement
                movement.instances[0].sessions.append(CaseSession(
                    date: "11.09.2026", event: "Определение о прекращении производства по делу"))
                let conflicted = Example(code: code, material: material,
                                         movement: movement, context: base.context)
                let result = try evaluate(conflicted)
                XCTAssertTrue(result.deadlines.isEmpty)
                let privateRule = code == "GPK"
                    ? "GPK-PRIVATE-COMPLAINT-GENERAL" : "KAS-PRIVATE-GENERAL"
                XCTAssertEqual(result.assessments.first(where: { $0.ruleID == privateRule })?.status,
                               .insufficientEvidence)
                XCTAssertTrue(result.assessments.first(where: { $0.ruleID == privateRule })?
                    .missingEvidenceRaw.contains(DeadlineEvidenceRequirement.actType.rawValue) ?? false)
            }
        }
    }

    func testAcceptedWithdrawalTerminatesWholeProceedingButPartialTerminationDoesNot() throws {
        let acceptedWithdrawal = "Производство по делу ПРЕКРАЩЕНО административный истец отказался от административного иска и отказ принят судом"
        for code in ["GPK", "KAS"] {
            let privateRule = code == "GPK"
                ? "GPK-PRIVATE-COMPLAINT-GENERAL" : "KAS-PRIVATE-GENERAL"
            for material in [false, true] {
                let whole = try evaluate(example(
                    code: code, material: material,
                    event: "Определение о прекращении производства по делу",
                    result: acceptedWithdrawal))
                XCTAssertEqual(whole.deadlines.count, 1,
                               "\(code), material=\(material): accepted withdrawal")
                XCTAssertEqual(whole.deadlines.first?.provenance?.ruleID, privateRule)

                let partial = try evaluate(example(
                    code: code, material: material,
                    event: "Определение о прекращении производства по делу в части требований"))
                XCTAssertTrue(partial.deadlines.isEmpty,
                              "\(code), material=\(material): partial termination")
            }
        }
    }

    func testMunicipalPrivateComplaintAndMissingCategoryHandling() throws {
        let municipal = try evaluate(example(
            code: "KAS", event: "Определение о возврате административного искового заявления",
            category: "Оспаривание нормативных актов органов муниципальных образований"))
        XCTAssertEqual(municipal.deadlines.first?.provenance?.ruleID, "KAS-PRIVATE-GENERAL")

        let missing = try evaluate(example(
            code: "KAS", material: true,
            event: "Определение о возврате административного искового заявления",
            missingCategory: true))
        XCTAssertTrue(missing.deadlines.isEmpty)
        XCTAssertEqual(missing.assessments.first(where: { $0.ruleID == "KAS-PRIVATE-GENERAL" })?.status,
                       .insufficientEvidence)
    }
}
