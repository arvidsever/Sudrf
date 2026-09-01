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
                          acts: [CaseAct] = [], bodies: [String: String] = [:],
                          executionDocuments: [CourtEnforcementDocument]? = nil,
                          uid: String = "11RS0001-01-2026-000001-11",
                          inForce: Bool = false,
                          category: String? = nil,
                          parties: CaseParties = CaseParties()) -> CaseMovement {
        CaseMovement(uid: uid, caseNumber: "2-1/2026", inForce: inForce,
                     instances: instances, complaints: [:], acts: acts,
                     actBodies: bodies, category: category, parties: parties,
                     executionDocuments: executionDocuments)
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

    func testHonestZeroDoesNotDeleteKnownCourtRound() {
        let actID = "act_vs"
        let cached = movement(
            [instance(domain: "vs.komi.sudrf.ru", act: actID)],
            acts: [CaseAct(id: actID, title: "Апелляционное определение",
                           date: "30.06.2026", courtShort: "ВС Коми",
                           instanceLevel: .appeal)],
            bodies: [actID: "Текст определения"])
        var fresh = movement([])
        fresh.honestZeroDomains = ["vs--komi.sudrf.ru"]

        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)

        XCTAssertEqual(merged.instances.map(\.caseNumber), ["33-1/2026"])
        XCTAssertEqual(merged.acts.map(\.id), [actID])
        XCTAssertEqual(merged.actBodies[actID], "Текст определения")
        XCTAssertNil(merged.honestZeroDomains)
    }

    func testPartialHomeMergePreservesPredecessorAndRegistrationLabels() {
        let domain = "home--komi.sudrf.ru"
        let predecessorURL = URL(string: "https://home--komi.sudrf.ru/modules.php"
            + "?name=sud_delo&name_op=case&case_id=old&delo_id=1540005&new=0")!
        let previous = CaseInstance(
            level: .first, court: "Домашний суд", caseNumber: "9-1/2025",
            judge: nil, domain: domain, foundByUID: true, result: "Решение",
            sessions: [CaseSession(date: "01.01.2025", event: "Решение")],
            note: "Предыдущая регистрация")
        let cachedCurrent = CaseInstance(
            level: .first, court: "Домашний суд", caseNumber: "2-1/2026",
            judge: nil, domain: domain, foundByUID: false, result: nil,
            sessions: [CaseSession(date: "01.01.2026", event: "Регистрация")],
            previousRegistration: PreviousRegistrationReference(
                caseNumber: previous.caseNumber, url: predecessorURL))
        let freshCurrent = CaseInstance(
            level: .first, court: "Домашний суд", caseNumber: "2-1/2026",
            judge: nil, domain: domain, foundByUID: false, result: nil,
            sessions: [])
        var fresh = movement([freshCurrent])
        fresh.incompleteHigherCourtDomains = [domain]

        let merged = MovementCachePolicy.merge(
            fresh: fresh, cached: movement([previous, cachedCurrent]))

        let rounds = merged.instances.filter { $0.domain == domain && $0.level == .first }
        XCTAssertEqual(rounds.map(\.caseNumber), ["9-1/2025", "2-1/2026"])
        XCTAssertEqual(rounds.first?.note, "Предыдущая регистрация")
        XCTAssertNil(rounds.last?.note)
        XCTAssertEqual(rounds.last?.previousRegistration, cachedCurrent.previousRegistration)
    }

    func testMergeWithoutCacheReturnsFresh() {
        let fresh = movement([instance(domain: "vs.komi.sudrf.ru", captcha: true)])
        let merged = MovementCachePolicy.merge(fresh: fresh, cached: nil)
        XCTAssertNotNil(merged.instances[0].captchaFormURL)
    }

    func testPartialFreshMovementPreservesCachedExecutionDocuments() {
        let documents = [CourtEnforcementDocument(date: "21.08.2025",
                                                   blankNumber: "ФС № 049373812",
                                                   courtStatus: "Выдан")]
        let cached = movement([instance(domain: "syktsud.komi.sudrf.ru")],
                              executionDocuments: documents)
        let fresh = movement([instance(domain: "syktsud.komi.sudrf.ru")])

        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)

        XCTAssertEqual(merged.executionDocuments, documents)
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
        let inst = instance(domain: domain, level: level, act: act)
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

    func testPartialFileRefreshKeepsEveryPreviouslyVerifiedAttachment() {
        let firstID = "act_mos-gorsud.ru#3а-1/2026#file-one"
        let secondID = "act_mos-gorsud.ru#3а-1/2026#file-two"
        let cachedInstance = CaseInstance(
            level: .first, court: "Московский городской суд", caseNumber: "3а-1/2026",
            judge: nil, domain: MosGorSudEndpoint.host, foundByUID: false, result: nil,
            sessions: [], actID: firstID, actIDs: [firstID, secondID])
        let cached = movement(
            [cachedInstance],
            acts: [
                CaseAct(id: firstID, title: "Определение", date: "01.06.2026",
                        courtShort: "МГС", instanceLevel: .first),
                CaseAct(id: secondID, title: "Решение", date: "02.06.2026",
                        courtShort: "МГС", instanceLevel: .first),
            ],
            bodies: [firstID: "Старый текст определения", secondID: "Старый текст решения"])
        let freshInstance = CaseInstance(
            level: .first, court: "Московский городской суд", caseNumber: "3а-1/2026",
            judge: nil, domain: MosGorSudEndpoint.host, foundByUID: false, result: nil,
            sessions: [], actID: firstID, actIDs: [firstID],
            actFileError: "Не удалось прочитать один опубликованный файл.")
        var fresh = movement(
            [freshInstance],
            acts: [CaseAct(id: firstID, title: "Определение", date: "01.06.2026",
                           courtShort: "МГС", instanceLevel: .first)],
            bodies: [firstID: "Новый текст определения"])
        fresh.incompleteHigherCourtDomains = [MosGorSudEndpoint.host]

        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)

        XCTAssertEqual(Set(merged.instances[0].linkedActIDs), [firstID, secondID])
        XCTAssertEqual(merged.actBodies[firstID], "Новый текст определения")
        XCTAssertEqual(merged.actBodies[secondID], "Старый текст решения")
        XCTAssertEqual(Set(merged.acts.map(\.id)), [firstID, secondID])
    }

    func testSparseBaseFallbackPreservesCachedBaseDataAndFreshHigherRounds() {
        let baseActID = "act_home#2-1/2026"
        let cachedBase = CaseInstance(
            level: .first, court: "Домашний суд", caseNumber: "2-1/2026",
            judge: "Судья Иванов", domain: "home--komi.sudrf.ru", foundByUID: false,
            result: "Решение принято", sessions: [
                CaseSession(date: "01.02.2026", event: "Заседание")
            ], actID: baseActID)
        let cachedHigher = instance(domain: "vs.komi.sudrf.ru", act: "act_vs")
        let cachedDocuments = [CourtEnforcementDocument(date: "21.08.2025",
                                                         blankNumber: "ФС № 049373812",
                                                         courtStatus: "Выдан")]
        let cachedParties = CaseParties(plaintiffs: ["Истец"], defendants: ["Ответчик"])
        let cached = movement(
            [cachedBase, cachedHigher],
            acts: [CaseAct(id: baseActID, title: "Решение", date: "02.02.2026",
                           courtShort: "1-я инстанция", instanceLevel: .first)],
            bodies: [baseActID: "Текст решения"],
            executionDocuments: cachedDocuments, inForce: true,
            category: "Гражданское дело", parties: cachedParties)

        let sparseBase = CaseInstance(
            level: .first, court: "Домашний суд", caseNumber: "2-1/2026",
            judge: nil, domain: "home--komi.sudrf.ru", foundByUID: false,
            result: nil, sessions: [])
        let freshHigher = instance(domain: "vs--komi.sudrf.ru", act: nil)
        var fresh = movement([sparseBase, freshHigher], uid: cached.uid)
        fresh.incompleteHigherCourtDomains = ["home--komi.sudrf.ru"]

        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)
        let mergedBase = merged.instances.first { $0.domain == "home--komi.sudrf.ru" }

        XCTAssertEqual(mergedBase?.sessions.count, 1)
        XCTAssertEqual(mergedBase?.judge, "Судья Иванов")
        XCTAssertEqual(mergedBase?.result, "Решение принято")
        XCTAssertEqual(mergedBase?.actID, baseActID)
        XCTAssertEqual(merged.acts.map(\.id), [baseActID])
        XCTAssertEqual(merged.actBodies[baseActID], "Текст решения")
        XCTAssertEqual(merged.category, "Гражданское дело")
        XCTAssertEqual(merged.parties, cachedParties)
        XCTAssertEqual(merged.executionDocuments, cachedDocuments)
        XCTAssertTrue(merged.instances.contains { $0.domain == "vs--komi.sudrf.ru" },
                      "свежая вышестоящая инстанция должна сохраниться")
    }

    func testPartialUnavailableMaterialPreservesCachedSessionsAndActs() {
        let domain = "home--komi.sudrf.ru"
        let number = "13-2472/2026"
        let sourceURL = URL(string: "https://home--komi.sudrf.ru/material")!
        let actID = "act_\(domain)#\(number)"
        let cachedMaterial = CaseInstance(
            level: .material, court: "Домашний суд", caseNumber: number,
            judge: "Судья Иванова", domain: domain, foundByUID: true,
            result: "Заявление удовлетворено",
            sessions: [CaseSession(date: "01.09.2026", event: "Рассмотрение")],
            actID: actID, sourceURL: sourceURL)
        let cachedAct = CaseAct(id: actID, title: "Определение", date: "01.09.2026",
                                courtShort: "Материал", instanceLevel: .material)
        let cached = movement([cachedMaterial], acts: [cachedAct],
                              bodies: [actID: "Сохранённый текст материала"])

        let fallbackMaterial = CaseInstance(
            level: .material, court: "Домашний суд", caseNumber: number,
            judge: "Судья из строки", domain: domain, foundByUID: true,
            result: "Заявление принято", sessions: [],
            note: "Движение временно недоступно", sourceURL: sourceURL)
        var fresh = movement([fallbackMaterial])
        fresh.incompleteHigherCourtDomains = [domain]

        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)
        let material = try! XCTUnwrap(merged.instances.first {
            $0.level == .material && $0.caseNumber == number
        })

        XCTAssertEqual(material.sessions, cachedMaterial.sessions)
        XCTAssertEqual(material.actID, actID)
        XCTAssertEqual(merged.acts.map(\.id), [actID])
        XCTAssertEqual(merged.actBodies[actID], "Сохранённый текст материала")
        XCTAssertNil(merged.incompleteHigherCourtDomains)
    }

    func testSuccessfulMaterialRefreshReplacesCachedHistoryAndAct() {
        let domain = "home--komi.sudrf.ru"
        let number = "13-2472/2026"
        let oldActID = "old-material-act"
        let cachedMaterial = CaseInstance(
            level: .material, court: "Домашний суд", caseNumber: number,
            judge: nil, domain: domain, foundByUID: true, result: "Старый результат",
            sessions: [CaseSession(date: "01.08.2026", event: "Старое событие")],
            actID: oldActID)
        let cached = movement(
            [cachedMaterial],
            acts: [CaseAct(id: oldActID, title: "Старый акт", date: "01.08.2026",
                           courtShort: "Материал", instanceLevel: .material)],
            bodies: [oldActID: "Старый текст"])
        let freshMaterial = CaseInstance(
            level: .material, court: "Домашний суд", caseNumber: number,
            judge: nil, domain: domain, foundByUID: true, result: "Новый результат",
            sessions: [CaseSession(date: "02.09.2026", event: "Новое событие")])

        let merged = MovementCachePolicy.merge(
            fresh: movement([freshMaterial]), cached: cached)

        XCTAssertEqual(merged.instances, [freshMaterial])
        XCTAssertTrue(merged.acts.isEmpty)
        XCTAssertTrue(merged.actBodies.isEmpty)
    }

    func testCompleteFreshBaseDoesNotInheritCachedMetadata() {
        let cachedParties = CaseParties(plaintiffs: ["Старый истец"])
        let cached = movement([instance(domain: "home--komi.sudrf.ru")],
                              uid: "11RS0001-01-2026-000001-11", inForce: true,
                              category: "Старая категория", parties: cachedParties)
        let fresh = movement([
            CaseInstance(level: .first, court: "Домашний суд", caseNumber: "2-1/2026",
                         judge: nil, domain: "home--komi.sudrf.ru", foundByUID: false,
                         result: nil, sessions: [])
        ], uid: "", inForce: false)

        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)

        XCTAssertNil(merged.category)
        XCTAssertTrue(merged.parties.isEmpty)
        XCTAssertFalse(merged.inForce)
        XCTAssertEqual(merged.uid, "")
    }

    func testIncompleteHigherCourtDoesNotOverlayStaleFieldsOnFreshRound() {
        let base = CaseInstance(
            level: .first, court: "Домашний суд", caseNumber: "2-1/2026",
            judge: "Свежий судья", domain: "home--komi.sudrf.ru", foundByUID: false,
            result: "Свежий результат", sessions: [])
        let cachedHigher = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "33-1/2026",
            judge: "Устаревший судья", domain: "vs.komi.sudrf.ru", foundByUID: true,
            result: "Устаревший результат",
            sessions: [CaseSession(date: "01.01.2025", event: "Старое заседание")],
            sourceURL: URL(string: "https://vs.komi.sudrf.ru/stale"))
        let freshHigher = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "33-1/2026",
            judge: nil, domain: "vs--komi.sudrf.ru", foundByUID: true,
            result: nil, sessions: [])
        let cached = movement([base, cachedHigher])
        var fresh = movement([base, freshHigher])
        fresh.incompleteHigherCourtDomains = ["vs--komi.sudrf.ru"]

        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)
        let higher = merged.instances.first { $0.caseNumber == "33-1/2026" }

        XCTAssertTrue(higher?.sessions.isEmpty == true)
        XCTAssertNil(higher?.judge)
        XCTAssertNil(higher?.result)
        XCTAssertNil(higher?.sourceURL)
    }
}
