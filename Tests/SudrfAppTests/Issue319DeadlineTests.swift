import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class Issue319DeadlineTests: XCTestCase {
    private let today = DateUtil.parse("01.11.2026")!

    private func context(cartoteka: String, number: String,
                         judicialUID: String? = nil) -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: "11RS0001",
            cartotekaId: cartoteka, cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: number, judicialUID: judicialUID)
    }

    private func movement(number: String, level: CaseInstance.Level = .first,
                          category: String? = "Общая категория",
                          sessions: [CaseSession]) -> CaseMovement {
        let instance = CaseInstance(
            level: level, court: "Сыктывкарский городской суд", caseNumber: number,
            judge: nil, domain: "syktsud.komi.sudrf.ru", foundByUID: false,
            result: sessions.last?.result, sessions: sessions)
        return CaseMovement(
            uid: "11RS0001-01-2026-000100-11", caseNumber: number, inForce: false,
            instances: [instance], complaints: [:], acts: [], category: category)
    }

    private func evaluate(_ movement: CaseMovement, context: MovementContext,
                          receipt: DeadlineTriggerProvenance? = nil) throws
        -> DeadlineRuleEngine.Evaluation {
        let production = ProductionType(cartotekaId: context.cartotekaId)
        return DeadlineRuleEngine.evaluate(
            registry: try LegalDeadlineRegistry.load(), movement: movement,
            context: .init(movementContext: context, deliveryOrReceipt: receipt),
            timeline: CaseLifecycleResolver.timeline(in: movement, production: production),
            today: today)
    }

    func testGPKTerminationUsesPrivateComplaintInsteadOfDecisionAppeal() throws {
        for number in ["2-431/2026", "2-425/2026", "2-2353/2023"] {
            let result = try evaluate(movement(number: number, sessions: [
                CaseSession(date: "11.09.2026", event: "Судебное заседание",
                            result: "Производство по делу ПРЕКРАЩЕНО"),
            ]), context: context(cartoteka: "g1", number: number))

            XCTAssertEqual(result.deadlines.count, 1, number)
            XCTAssertEqual(result.deadlines.first?.provenance?.ruleID,
                           "GPK-PRIVATE-COMPLAINT-GENERAL", number)
            XCTAssertEqual(result.deadlines.first?.date, DateUtil.parse("02.10.2026"), number)
            XCTAssertEqual(result.assessments.first(where: {
                $0.ruleID == "GPK-APPEAL-GENERAL"
            })?.status, .notApplicable, number)
        }
    }

    func testKASRefusalToAcceptUsesPrivateComplaint() throws {
        let number = "9а-179/2019"
        let result = try evaluate(movement(
            number: number, level: .material,
            category: "Об оспаривании решения органа", sessions: [
                CaseSession(date: "11.09.2026", event: "Рассмотрение заявления",
                            result: "ОТКАЗАНО в принятии административного искового заявления"),
            ]), context: context(cartoteka: "p1", number: number))

        XCTAssertEqual(result.deadlines.count, 1)
        XCTAssertEqual(result.deadlines.first?.provenance?.ruleID, "KAS-PRIVATE-GENERAL")
        XCTAssertEqual(result.deadlines.first?.date, DateUtil.parse("02.10.2026"))
        XCTAssertNil(result.assessments.first(where: {
            $0.ruleID == "KAS-APPEAL-GENERAL"
        }))
    }

    func testKoAPAuthorityReviewUsesSubsequentRule() throws {
        for number in ["12-447/2026", "12-461/2026", "12-424/2026"] {
            let uid = "11RS0001-01-2026-000100-11"
            let result = try evaluate(movement(number: number, sessions: [
                CaseSession(date: "01.09.2026", event: "Рассмотрение жалобы",
                            result: "Решение: постановление оставлено без изменения"),
                CaseSession(date: "03.09.2026", event: "Вручена копия решения"),
            ]), context: context(cartoteka: "admj", number: number, judicialUID: uid))

            XCTAssertEqual(result.deadlines.count, 1, number)
            XCTAssertEqual(result.deadlines.first?.provenance?.ruleID,
                           "KOAP-APPEAL-SUBSEQUENT-GENERAL", number)
            XCTAssertEqual(result.assessments.first(where: {
                $0.ruleID == "KOAP-APPEAL-INITIAL-GENERAL"
            })?.status, .notApplicable, number)
        }
    }

    func testKoAPReferendumCategorySelectsOnlySpecialRules() throws {
        let category = "Нарушение законодательства о референдуме"
        let initial = try evaluate(movement(number: "5-40/2026", category: category, sessions: [
            CaseSession(date: "01.09.2026", event: "Судебное заседание",
                        result: "Постановление по делу об административном правонарушении"),
            CaseSession(date: "03.09.2026", event: "Вручена копия постановления"),
        ]), context: context(cartoteka: "adm", number: "5-40/2026"))
        XCTAssertEqual(initial.deadlines.map { $0.provenance?.ruleID },
                       ["KOAP-APPEAL-INITIAL-ELECTION"])
        XCTAssertEqual(initial.assessments.first(where: {
            $0.ruleID == "KOAP-APPEAL-INITIAL-GENERAL"
        })?.status, .notApplicable)

        let subsequent = try evaluate(movement(
            number: "12-40/2026", category: category, sessions: [
                CaseSession(date: "01.09.2026", event: "Рассмотрение жалобы",
                            result: "Решение по жалобе: постановление оставлено без изменения"),
                CaseSession(date: "03.09.2026", event: "Вручена копия решения"),
            ]), context: context(
                cartoteka: "admj", number: "12-40/2026",
                judicialUID: "11RS0001-01-2026-000100-11"))
        XCTAssertEqual(subsequent.deadlines.map { $0.provenance?.ruleID },
                       ["KOAP-APPEAL-SUBSEQUENT-ELECTION"])
        XCTAssertEqual(subsequent.assessments.first(where: {
            $0.ruleID == "KOAP-APPEAL-SUBSEQUENT-GENERAL"
        })?.status, .notApplicable)
    }

    func testKoAPMagistrateAppealDoesNotCreateAnotherOrdinaryAppealDeadline() throws {
        let number = "12-149/2021"
        let uid = "11MS0062-01-2021-000100-10"
        let result = try evaluate(movement(number: number, level: .appeal, sessions: [
            CaseSession(date: "07.04.2021", event: "Рассмотрение жалобы",
                        result: "Изменено"),
            CaseSession(date: "08.04.2021", event: "Вручена копия решения"),
        ]), context: context(cartoteka: "admj", number: number, judicialUID: uid))

        XCTAssertTrue(result.deadlines.isEmpty)
        XCTAssertTrue(result.assessments.allSatisfy { $0.status == .notApplicable })
    }

    func testKoAPReturnNeedsExactReceiptMomentAndDoesNotMoveWeekendEndpoint() throws {
        for (number, exactTime) in [
            ("5-32/2026", "15:30"), ("5-957/2023", nil), ("5-311/2021", "09:05"),
        ] {
            let base = [
                CaseSession(date: "25.09.2026", event: "Рассмотрение материала",
                            result: "Протокол об административном правонарушении и материалы ВОЗВРАЩЕНЫ должностному лицу"),
            ]
            let ctx = context(cartoteka: "adm", number: number)
            let evaluated = try evaluate(movement(number: number, sessions: base + [
                CaseSession(date: "25.09.2026", time: exactTime,
                            event: "Получено определение о возвращении"),
            ]), context: ctx)
            if let exactTime {
                let deadline = try XCTUnwrap(evaluated.deadlines.first, number)
                XCTAssertEqual(deadline.provenance?.ruleID,
                               "KOAP-APPEAL-RETURN-DETERMINATION-ONE-SUTKI", number)
                XCTAssertEqual(DateUtil.cal.component(.weekday, from: deadline.date), 7, number)
                let parts = exactTime.split(separator: ":").compactMap { Int($0) }
                XCTAssertEqual(DateUtil.cal.component(.hour, from: deadline.date), parts[0], number)
                XCTAssertEqual(DateUtil.cal.component(.minute, from: deadline.date), parts[1], number)
                XCTAssertTrue(deadline.provenance?.policyIDs.contains(
                    "KOAP-NO-NONWORKING-ROLL-FOR-SUTKI") ?? false, number)
            } else {
                XCTAssertTrue(evaluated.deadlines.isEmpty, number)
                XCTAssertEqual(evaluated.assessments.first(where: {
                    $0.ruleID == "KOAP-APPEAL-RETURN-DETERMINATION-ONE-SUTKI"
                })?.status, .insufficientEvidence, number)
            }
        }
    }

    func testKoAPReturnWithoutCategoryDoesNotActivateInitialRules() throws {
        let number = "5-32/2026"
        let evaluated = try evaluate(movement(number: number, category: nil, sessions: [
            CaseSession(date: "25.09.2026", event: "Рассмотрение материала",
                        result: "Протокол об административном правонарушении и материалы ВОЗВРАЩЕНЫ должностному лицу"),
            CaseSession(date: "25.09.2026", time: "15:30",
                        event: "Получено определение о возвращении"),
        ]), context: context(cartoteka: "adm", number: number))

        XCTAssertEqual(evaluated.deadlines.map { $0.provenance?.ruleID },
                       ["KOAP-APPEAL-RETURN-DETERMINATION-ONE-SUTKI"])
        XCTAssertFalse(evaluated.assessments.contains { $0.isIndeterminate })
    }

    func testKoAPCopyDirectionIsNotReceipt() throws {
        let number = "5-100/2026"
        let result = try evaluate(movement(number: number, sessions: [
            CaseSession(date: "01.09.2026", event: "Судебное заседание",
                        result: "Постановление по делу об административном правонарушении"),
            CaseSession(date: "02.09.2026", event: "Направлена копия постановления"),
        ]), context: context(cartoteka: "adm", number: number))

        XCTAssertTrue(result.deadlines.isEmpty)
        XCTAssertEqual(result.assessments.first(where: {
            $0.ruleID == "KOAP-APPEAL-INITIAL-GENERAL"
        })?.status, .insufficientEvidence)
    }

    func testKoAPNegatedReceiptIsNotReceipt() throws {
        for event in [
            "Копия постановления не получена",
            "Копия постановления не была вручена",
            "Копия постановления не поступила адресату",
            "Копия постановления получена не была",
        ] {
            let number = "5-101/2026"
            let evaluated = try evaluate(movement(number: number, sessions: [
                CaseSession(date: "01.09.2026", event: "Судебное заседание",
                            result: "Постановление по делу об административном правонарушении"),
                CaseSession(date: "02.09.2026", event: event),
            ]), context: context(cartoteka: "adm", number: number))

            XCTAssertTrue(evaluated.deadlines.isEmpty, event)
            XCTAssertEqual(evaluated.assessments.first(where: {
                $0.ruleID == "KOAP-APPEAL-INITIAL-GENERAL"
            })?.status, .insufficientEvidence, event)
        }
    }

    func testKoAPMultipleReceiptDatesRemainInsufficient() throws {
        let number = "12-447/2026"
        let evaluated = try evaluate(movement(number: number, sessions: [
            CaseSession(date: "01.09.2026", event: "Рассмотрение жалобы",
                        result: "Решение по жалобе: постановление оставлено без изменения"),
            CaseSession(date: "03.09.2026", event: "Вручена копия решения"),
            CaseSession(date: "04.09.2026", event: "Повторно вручена копия решения"),
        ]), context: context(
            cartoteka: "admj", number: number,
            judicialUID: "11RS0001-01-2026-000100-11"))

        XCTAssertTrue(evaluated.deadlines.isEmpty)
        XCTAssertEqual(evaluated.assessments.first(where: {
            $0.ruleID == "KOAP-APPEAL-SUBSEQUENT-GENERAL"
        })?.status, .insufficientEvidence)
    }

    func testMovementUIDDefinesKoAPRoleAheadOfStaleContextUID() throws {
        let number = "12-461/2026"
        let evaluated = try evaluate(movement(number: number, sessions: [
            CaseSession(date: "01.09.2026", event: "Рассмотрение жалобы",
                        result: "Решение по жалобе: постановление изменено"),
            CaseSession(date: "03.09.2026", event: "Вручена копия решения"),
        ]), context: context(
            cartoteka: "admj", number: number,
            judicialUID: "11MS0001-01-2026-000100-11"))

        XCTAssertEqual(evaluated.deadlines.first?.provenance?.ruleID,
                       "KOAP-APPEAL-SUBSEQUENT-GENERAL")
    }
}
