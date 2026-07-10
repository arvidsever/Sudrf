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

    // MARK: - A16 transient-stub tests

    private func instanceWithTransient(domain: String, level: CaseInstance.Level = .appeal,
                                      act: String? = nil) -> CaseInstance {
        var inst = instance(domain: domain, level: level, act: act)
        // captchaFormURL == nil, transientError == true. Не мутируем captcha-ветку.
        return CaseInstance(
            level: inst.level, court: inst.court, caseNumber: inst.caseNumber,
            judge: inst.judge, domain: inst.domain, foundByUID: inst.foundByUID,
            result: inst.result, sessions: inst.sessions, actID: inst.actID,
            captchaFormURL: nil, note: inst.note, actURL: inst.actURL,
            transientError: true)
    }

    /// Fresh: 1 transient-stub. Cached: 1 real (без captcha, без transient).
    /// Merge: stub удалён, real восстановлен, акт перенесён, transientError
    /// == nil, captchaFormURL == nil. **Главный сценарий A16** для
    /// merge-политики (single round).
    func testTransientStubPreservesCachedRealInstance() {
        let actID = "act_vs"
        let cached = movement(
            [instance(domain: "vs.komi.sudrf.ru", act: actID)],
            acts: [CaseAct(id: actID, title: "Апелляционное определение",
                           date: "30.06.2026", courtShort: "ВС Коми", instanceLevel: .appeal)],
            bodies: [actID: "Текст определения"])
        let fresh = movement([instanceWithTransient(domain: "vs.komi.sudrf.ru")])

        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)

        XCTAssertEqual(merged.instances.count, 1)
        XCTAssertNil(merged.instances[0].captchaFormURL, "transient-stub не заменяется на captcha-stub")
        XCTAssertNil(merged.instances[0].transientError, "stub заменён на cached real — transientError == nil")
        XCTAssertEqual(merged.instances[0].actID, actID)
        XCTAssertTrue(merged.acts.contains { $0.id == actID }, "акт кэша перенесён в merged")
        XCTAssertEqual(merged.actBodies[actID], "Текст определения")
    }

    /// Fresh: 1 transient-stub. Cached: 1 transient-stub того же домена.
    /// Merge: свежий transient-stub остаётся (не откатываемся к прошлой
    /// ошибке), ничего не подменяется. `changed == false` → fresh
    /// возвращается как есть. Логика: «свежий transient авторитетнее
    /// кэшированного, retry-цикл отработал только что».
    func testTransientStubDoesNotOverwriteAnotherTransient() {
        let fresh = movement([instanceWithTransient(domain: "vs.komi.sudrf.ru")])
        let cached = movement([instanceWithTransient(domain: "vs.komi.sudrf.ru")])

        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)

        XCTAssertEqual(merged.instances.count, 1, "только один stub (fresh) — cached НЕ подменяется")
        XCTAssertEqual(merged.instances[0].transientError, true, "свежий transient stub")
        // merged должен быть == fresh (без изменений)
        XCTAssertEqual(merged.instances[0].domain, fresh.instances[0].domain)
    }

    /// `stripped(forPersist:)` НЕ вырезает transient-stub. Captcha-stub'ы
    /// вырезаются (transient URL формы), а transient-stub'ы сохраняются
    /// — иначе merge на следующий fetch не увидит, что у домена был
    /// сетевой сбой, и UI увидит «дело исчезло», а не «нет связи».
    /// Captcha-stub (captchaFormURL != nil) всё ещё вырезается.
    func testStrippedKeepsTransientStub() {
        let mv = movement([
            instance(domain: "syktsud.komi.sudrf.ru", level: .first),
            instanceWithTransient(domain: "vs.komi.sudrf.ru"),
            instance(domain: "vs.komi.sudrf.ru", captcha: true),  // для контроля: captcha-stub всё ещё вырезается
        ])
        let stripped = MovementCachePolicy.stripped(forPersist: mv)
        XCTAssertEqual(stripped.instances.count, 2,
                       "captcha-stub вырезан, transient-stub и 1-я инстанция сохранены")
        XCTAssertEqual(stripped.instances.map(\.domain),
                       ["syktsud.komi.sudrf.ru", "vs.komi.sudrf.ru"])
        XCTAssertNotNil(stripped.instances.first { $0.transientError == true },
                        "transient-stub сохранён в персисте")
    }

    /// **Закрепление BM7 (captcha-часть)**: 2 cached rounds одного
    /// канонического хоста с разными `actID` и телами → captcha-stub
    /// (1 штука) подменяется ОБОИМИ round'ами, оба акта + оба тела
    /// переносятся, captchaFormURL == nil. A14 moduleHost dedup: `vs--komi`
    /// и `vs.komi` — один и тот же канонический хост. Это отдельный тест
    /// от A16-transient-аналога в `MovementServiceTransientStubTests`.
    func testCaptchaMultiRoundRestoredFromCache() {
        let actID1 = "act_vs--komi.sudrf.ru#33-1/2025"
        let actID2 = "act_vs--komi.sudrf.ru#33-2/2026"
        let round1 = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "33-1/2025",
            judge: nil, domain: "vs.komi.sudrf.ru", foundByUID: true,
            result: "решение отменено",
            sessions: [CaseSession(date: "01.06.2025", event: "Заседание")],
            actID: actID1)
        let round2 = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "33-2/2026",
            judge: nil, domain: "vs.komi.sudrf.ru", foundByUID: true,
            result: "оставлено без изменения",
            sessions: [CaseSession(date: "01.06.2026", event: "Заседание")],
            actID: actID2)
        let cached = movement(
            [round1, round2],
            acts: [
                CaseAct(id: actID1, title: "Апелляционное определение",
                        date: "15.09.2025", courtShort: "ВС Коми", instanceLevel: .appeal),
                CaseAct(id: actID2, title: "Апелляционное определение",
                        date: "15.09.2026", courtShort: "ВС Коми", instanceLevel: .appeal)
            ],
            bodies: [actID1: "Тело акта 1", actID2: "Тело акта 2"])
        // Fresh: 1 captcha-stub для dash-формы того же канонического хоста
        let fresh = movement([instance(domain: "vs--komi.sudrf.ru", captcha: true)])

        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)

        // Captcha-stub удалён, ОБА cached round'а восстановлены (BM7)
        XCTAssertFalse(merged.instances.contains { $0.captchaFormURL != nil },
                       "captcha-stub удалён после merge")
        XCTAssertEqual(merged.instances.count, 2, "оба cached round'а восстановлены (BM7)")
        XCTAssertEqual(Set(merged.instances.map(\.caseNumber)),
                       Set(["33-1/2025", "33-2/2026"]))
        XCTAssertEqual(Set(merged.instances.map(\.actID)),
                       Set([actID1, actID2]))
        // ОБА акта + ОБА тела перенесены
        XCTAssertTrue(merged.acts.contains { $0.id == actID1 })
        XCTAssertTrue(merged.acts.contains { $0.id == actID2 })
        XCTAssertEqual(merged.actBodies[actID1], "Тело акта 1")
        XCTAssertEqual(merged.actBodies[actID2], "Тело акта 2")
    }
}
