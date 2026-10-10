import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

/// Pure lifecycle projection of synthetic own-complaint facts, not real root completion.
final class Issue104LifecycleTests: XCTestCase {
    private let refusal = "Отказано в передаче жалобы для рассмотрения"

    private func complaint() -> CaseInstance {
        CaseInstance(level: .vsCassation, court: "Верховный Суд РФ",
            caseNumber: "3-КФ26-1-К1", judge: nil, domain: "vsrf.ru", foundByUID: false,
            result: refusal, sessions: [
                CaseSession(date: "02.01.2026", event: "Поступило в ВС РФ"),
                CaseSession(date: "03.02.2026", event: refusal)
            ], sourceURL: VSRFEndpoint.cardURL(productionID: "21-00000001", section: .claims))
    }

    private func movement(_ instances: [CaseInstance]) -> CaseMovement {
        CaseMovement(uid: "", caseNumber: "2-1/2026", inForce: false,
            instances: instances, complaints: [:], acts: [])
    }

    func testOwnRefusedComplaintCompletesStandaloneProductionAsCassation() throws {
        let own = complaint()
        let source = movement([own])
        let resolution = CaseLifecycleResolver.resolve(movement: source, production: .civil,
            deadlines: [], today: try XCTUnwrap(DateUtil.parse("04.02.2026")))
        XCTAssertEqual(CaseLifecycleResolver.stage(for: own, production: .civil), .cassation)
        XCTAssertEqual(resolution.stage, .done)
        XCTAssertEqual(resolution.currentInstance?.caseNumber, own.caseNumber)
        XCTAssertEqual(resolution.completionReason, .terminalReview(refusal))
        XCTAssertTrue(source.acts.isEmpty)
        XCTAssertFalse(source.inForce)
    }

    func testLowerRoundStartingBetweenIntakeAndRefusalRemainsCurrentInEveryOrder() throws {
        let remand = CaseInstance(level: .appeal, court: "Тестовый областной суд",
            caseNumber: "33-1/2025", judge: nil, domain: "test--region.sudrf.ru", foundByUID: false,
            result: "Решение отменено с направлением дела на новое рассмотрение в суд первой инстанции",
            sessions: [CaseSession(date: "01.01.2026", event: "Судебное заседание",
                result: "Решение отменено с направлением дела на новое рассмотрение в суд первой инстанции")])
        let lower = CaseInstance(level: .first, court: "Тестовый городской суд",
            caseNumber: "2-2/2026", judge: nil, domain: "test--region.sudrf.ru", foundByUID: false,
            result: nil, sessions: [CaseSession(date: "15.01.2026", event: "Дело принято к производству")])
        let own = complaint()
        for instances in [[remand, own, lower], [remand, lower, own], [own, remand, lower],
                          [own, lower, remand], [lower, remand, own], [lower, own, remand]] {
            let source = movement(instances)
            let resolution = CaseLifecycleResolver.resolve(movement: source, production: .civil,
                deadlines: [], today: try XCTUnwrap(DateUtil.parse("04.02.2026")))
            XCTAssertEqual(resolution.stage, .first)
            XCTAssertEqual(resolution.currentInstance?.caseNumber, lower.caseNumber)
            XCTAssertNil(resolution.completionReason)
            XCTAssertTrue(source.acts.isEmpty)
            XCTAssertFalse(source.inForce)
        }
    }
}
