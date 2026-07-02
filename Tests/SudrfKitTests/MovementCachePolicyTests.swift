import XCTest
import Foundation
@testable import SudrfKit

/// Политика слияния кэша карточек (MovementCachePolicy):
/// 1) заглушка капчи не затирает ранее загруженную реальную инстанцию;
/// 2) акт кэшированной инстанции переносится в свежие данные;
/// 3) перед персистом заглушки вырезаются.
final class MovementCachePolicyTests: XCTestCase {

    private func instance(domain: String, level: CaseInstance.Level = .appeal,
                          act: String? = nil, captcha: Bool = false) -> CaseInstance {
        CaseInstance(level: level, court: "ВС Коми", caseNumber: "33-1/2026",
                     judge: nil, domain: domain, foundByUID: true, result: nil,
                     sessions: [CaseSession(date: "01.06.2026", event: "Заседание")],
                     actID: act,
                     captchaFormURL: captcha ? URL(string: "https://\(domain)/form") : nil)
    }

    private func movement(_ instances: [CaseInstance],
                          acts: [CaseAct] = [], bodies: [String: String] = [:]) -> CaseMovement {
        CaseMovement(uid: "11RS0001-01-2026-000001-11", caseNumber: "2-1/2026",
                     inForce: false, instances: instances, complaints: [:],
                     acts: acts, actBodies: bodies)
    }

    func testPlaceholderDoesNotOverwriteRealInstance() {
        let actID = "act_vs"
        let cached = movement(
            [instance(domain: "vs.komi.sudrf.ru", act: actID)],
            acts: [CaseAct(id: actID, title: "Апелляционное определение",
                           date: "30.06.2026", courtShort: "ВС Коми", instanceLevel: .appeal)],
            bodies: [actID: "Текст определения"])
        let fresh = movement([instance(domain: "vs.komi.sudrf.ru", captcha: true)])

        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)

        XCTAssertEqual(merged.instances.count, 1)
        XCTAssertNil(merged.instances[0].captchaFormURL, "заглушка должна замениться кэшем")
        XCTAssertEqual(merged.instances[0].actID, actID)
        XCTAssertEqual(merged.acts.map(\.id), [actID], "акт кэша должен переехать в свежие данные")
        XCTAssertEqual(merged.actBodies[actID], "Текст определения")
    }

    func testFreshRealInstanceWinsOverCache() {
        var newer = instance(domain: "vs.komi.sudrf.ru")
        newer.result = "Решение отменено"
        let merged = MovementCachePolicy.merge(
            fresh: movement([newer]),
            cached: movement([instance(domain: "vs.komi.sudrf.ru")]))
        XCTAssertEqual(merged.instances[0].result, "Решение отменено",
                       "живая инстанция не должна подменяться кэшем")
    }

    func testMergeWithoutCacheReturnsFresh() {
        let fresh = movement([instance(domain: "vs.komi.sudrf.ru", captcha: true)])
        let merged = MovementCachePolicy.merge(fresh: fresh, cached: nil)
        XCTAssertNotNil(merged.instances[0].captchaFormURL)
    }

    func testStripRemovesPlaceholdersOnly() {
        let mv = movement([
            instance(domain: "syktsud.komi.sudrf.ru", level: .first),
            instance(domain: "vs.komi.sudrf.ru", captcha: true),
        ])
        let stripped = MovementCachePolicy.stripped(forPersist: mv)
        XCTAssertEqual(stripped.instances.map(\.domain), ["syktsud.komi.sudrf.ru"])
    }
}
