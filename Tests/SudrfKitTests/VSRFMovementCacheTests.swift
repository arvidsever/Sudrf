import XCTest
@testable import SudrfKit

final class VSRFMovementCacheTests: XCTestCase {
    private let currentURL = URL(string: "https://www.vsrf.ru/lk/practice/claims/12-36321243")!
    private let oldAliasURL = URL(string: "https://vsrf.ru/lk/practice/claims/12-36321243")!

    private func instance(url: URL, result: String?, sessions: [CaseSession],
                          note: String? = nil) -> CaseInstance {
        CaseInstance(level: .vsCassation, court: "Верховный Суд РФ",
                     caseNumber: "3-ИКАД25-3-А2", judge: "А.А. Тестов",
                     domain: "vsrf.ru", foundByUID: true, result: result,
                     sessions: sessions, note: note, sourceURL: url)
    }

    private func movement(_ instances: [CaseInstance], incomplete: Bool = false) -> CaseMovement {
        CaseMovement(uid: "11OS0000-01-2025-000169-68", caseNumber: "3а-85/2025",
                     inForce: false, instances: instances, complaints: [:], acts: [],
                     incompleteHigherCourtDomains: incomplete ? ["www.vsrf.ru"] : nil)
    }

    func testPartialComplaintRefreshKeepsFreshCardAndRestoresOnlyMissingSessions() throws {
        let receipt = CaseSession(date: "16.09.2025", time: "16:24", room: "5038",
                                  event: "Истребовано дело", result: "Прежний текст")
        let cachedSameLine = CaseSession(date: "15.10.2025", event: "Результат рассмотрения",
                                         result: "Старое решение")
        let ownSession = CaseSession(date: "15.10.2025", event: "Результат рассмотрения",
                                     result: "Новое опубликованное решение")
        let ownEarlier = CaseSession(date: "20.09.2025", event: "Передано судье")
        let cached = movement([instance(url: oldAliasURL, result: "Старый итог",
                                        sessions: [receipt, cachedSameLine])])
        let fresh = movement([instance(url: currentURL, result: "Новый итог",
                                       sessions: [ownEarlier, ownSession],
                                       note: "Движение жалобы временно недоступно")], incomplete: true)

        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)
        let restored = try XCTUnwrap(merged.instances.first)
        XCTAssertEqual(merged.instances.count, 1)
        XCTAssertEqual(restored.sourceURL, currentURL)
        XCTAssertEqual(restored.result, "Новый итог")
        XCTAssertEqual(restored.note, "Движение жалобы временно недоступно")
        XCTAssertEqual(restored.sessions.count, 3)
        XCTAssertTrue(restored.sessions.contains(receipt))
        XCTAssertTrue(restored.sessions.contains(ownEarlier))
        XCTAssertTrue(restored.sessions.contains(ownSession))
        XCTAssertFalse(restored.sessions.contains(cachedSameLine), "свежий результат той же строки остаётся приоритетным")

        let encoded = try JSONEncoder().encode(merged)
        let decoded = try JSONDecoder().decode(CaseMovement.self, from: encoded)
        XCTAssertEqual(decoded.instances, merged.instances)
        let repeated = MovementCachePolicy.merge(fresh: fresh, cached: decoded)
        XCTAssertEqual(repeated.instances, merged.instances, "повторное слияние не дублирует движения")
    }

    func testFailedOwnCardRestoresCachedFieldsAndUnionsVerifiedComplaintIntakeIdempotently() throws {
        let sharedIntakeKeyCached = CaseSession(date: "16.09.2025", time: "16:24", room: "5038",
                                                 event: "Истребовано дело", result: "Старый текст")
        let cachedOwnEvent = CaseSession(date: "15.10.2025", event: "Результат рассмотрения",
                                         result: "Кэшированная подробность")
        let verifiedIntake = CaseSession(date: "16.09.2025", time: "16:24", room: "5038",
                                         event: "Истребовано дело", result: "Подтверждено свежей карточкой")
        let anotherVerifiedIntake = CaseSession(date: "20.09.2025", event: "Истребовано дело",
                                                result: "Второе проверенное событие")
        let cached = movement([instance(url: oldAliasURL, result: "Сохранённое опубликованное решение",
                                        sessions: [sharedIntakeKeyCached, cachedOwnEvent],
                                        note: "Отказ в передаче")])
        let fresh = movement([instance(
            url: currentURL, result: "Поисковый заголовок", sessions: [verifiedIntake, anotherVerifiedIntake],
            note: "Движение временно недоступно · жалоба проверена")], incomplete: true)

        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)
        let restored = try XCTUnwrap(merged.instances.first)

        XCTAssertEqual(merged.instances.count, 1)
        XCTAssertEqual(restored.sourceURL, oldAliasURL)
        XCTAssertEqual(restored.judge, "А.А. Тестов")
        XCTAssertEqual(restored.result, "Сохранённое опубликованное решение",
                       "restore the last verified case-card header")
        XCTAssertEqual(restored.note, "Движение временно недоступно · жалоба проверена")
        XCTAssertEqual(restored.sessions.count, 3)
        XCTAssertEqual(restored.sessions.first(where: { $0.event == "Истребовано дело" && $0.date == "16.09.2025" })?.result,
                       "Подтверждено свежей карточкой",
                       "a fresh verified intake row wins when its key matches an older cached row")
        XCTAssertTrue(restored.sessions.contains(cachedOwnEvent))
        XCTAssertTrue(restored.sessions.contains(anotherVerifiedIntake))

        let encoded = try JSONEncoder().encode(merged)
        let decoded = try JSONDecoder().decode(CaseMovement.self, from: encoded)
        XCTAssertEqual(decoded.instances, merged.instances)
        let repeated = MovementCachePolicy.merge(fresh: fresh, cached: decoded)
        XCTAssertEqual(repeated.instances, merged.instances, "repeated cache overlay stays idempotent")
    }

    func testSameNumberWithDifferentVSRFCardIDsKeepsBothRounds() {
        let cached = movement([instance(
            url: URL(string: "https://vsrf.ru/lk/practice/claims/12-36000001")!,
            result: "Старый результат", sessions: [CaseSession(date: "01.01.2025", event: "Старое дело")])])
        let fresh = movement([instance(
            url: currentURL, result: "Текущий результат",
            sessions: [CaseSession(date: "01.01.2026", event: "Новое дело")])], incomplete: true)

        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)

        XCTAssertEqual(merged.instances.count, 2)
        XCTAssertTrue(merged.instances.contains { $0.sourceURL == currentURL })
        XCTAssertTrue(merged.instances.contains {
            $0.sourceURL == URL(string: "https://vsrf.ru/lk/practice/claims/12-36000001")
        })
    }

    func testPartialRefreshPreservesPublishedActsBeforeAndAfterFileLoad() throws {
        let cardURL = currentURL
        let firstFile = URL(string: "https://www.vsrf.ru/lk/practice/stor_pdf/2496438")!
        let secondFile = URL(string: "https://www.vsrf.ru/lk/practice/stor_pdf/2496439")!
        let loadedID = "act_vsrf_12-36321243_/lk/practice/stor_pdf/2496438"
        let knownID = "act_vsrf_12-36321243_/lk/practice/stor_pdf/2496439"
        let provenance = PublishedActProvenance(
            sourceURL: firstFile, finalURL: firstFile, format: .pdf,
            contentType: "application/pdf", contentHash: "sha256",
            byteCount: 42, fetchedAt: Date(timeIntervalSince1970: 10), extractorVersion: 1)
        let cachedInstance = CaseInstance(
            level: .vsCassation, court: "Верховный Суд РФ", caseNumber: "3-ИКАД25-3-А2",
            judge: nil, domain: "vsrf.ru", foundByUID: true, result: "Результат",
            sessions: [CaseSession(date: "15.10.2025", event: "Заседание")],
            actID: loadedID, actIDs: [loadedID, knownID], actURL: firstFile,
            actURLs: [firstFile, secondFile], sourceURL: cardURL)
        let cachedActs = [
            CaseAct(id: loadedID, title: "Кассационное определение", date: "15.10.2025",
                    courtShort: "ВС РФ", instanceLevel: .vsCassation,
                    fileProvenance: provenance, sourceFileURL: firstFile,
                    productionNumber: "3-ИКАД25-3-А2"),
            CaseAct(id: knownID, title: "Кассационное определение", date: "15.10.2025",
                    courtShort: "ВС РФ", instanceLevel: .vsCassation,
                    sourceFileURL: secondFile, productionNumber: "3-ИКАД25-3-А2")
        ]
        let cached = CaseMovement(uid: "uid", caseNumber: "3а-85/2025", inForce: false,
                                  instances: [cachedInstance], complaints: [:], acts: cachedActs,
                                  actBodies: [loadedID: "Сохранённый полный текст"])
        let freshInstance = CaseInstance(
            level: .vsCassation, court: "Верховный Суд РФ", caseNumber: "3-ИКАД25-3-А2",
            judge: nil, domain: "www.vsrf.ru", foundByUID: true, result: nil,
            sessions: [], actID: loadedID, actIDs: [loadedID],
            note: "Движение временно недоступно",
            sourceURL: URL(string: "https://vsrf.ru/lk/practice/claims/12-36321243"))
        let freshLoadedMetadata = CaseAct(
            id: loadedID, title: "Кассационное определение", date: "15.10.2025",
            courtShort: "ВС РФ", instanceLevel: .vsCassation,
            sourceFileURL: firstFile, productionNumber: "3-ИКАД25-3-А2")
        let fresh = CaseMovement(uid: "uid", caseNumber: "3а-85/2025", inForce: false,
                                 instances: [freshInstance], complaints: [:],
                                 acts: [freshLoadedMetadata],
                                 incompleteHigherCourtDomains: ["www.vsrf.ru"])

        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)

        XCTAssertEqual(merged.acts.count, 2)
        XCTAssertEqual(merged.actBodies[loadedID], "Сохранённый полный текст")
        XCTAssertEqual(merged.acts.first { $0.id == loadedID }?.fileProvenance, provenance)
        XCTAssertEqual(merged.acts.first { $0.id == knownID }?.sourceFileURL, secondFile)
        XCTAssertEqual(merged.instances.first?.linkedActIDs, [loadedID, knownID])

        let restarted = try JSONDecoder().decode(CaseMovement.self,
                                                  from: JSONEncoder().encode(merged))
        let repeated = MovementCachePolicy.merge(fresh: fresh, cached: restarted)
        XCTAssertEqual(repeated.acts.count, 2)
        XCTAssertEqual(repeated.actBodies[loadedID], "Сохранённый полный текст")
    }

    func testCompleteRefreshRetainsPresentPublishedFileWithoutRestoringAbsentRound() throws {
        let url = URL(string: "https://www.vsrf.ru/lk/practice/stor_pdf/34000001")!
        let provenance = PublishedActProvenance(sourceURL: url, finalURL: url, format: .pdf,
            contentType: "application/pdf", contentHash: String(repeating: "a", count: 64),
            byteCount: 100, fetchedAt: .now, extractorVersion: 1)
        let known = CaseAct(id: "pdf", title: "Кассационное определение", date: "15.10.2025",
            courtShort: "ВС РФ", instanceLevel: .vsCassation, sourceFileURL: url,
            productionNumber: "3-ИКАД25-3-А2")
        var loaded = known
        loaded.fileProvenance = provenance
        var oldInstance = instance(url: currentURL, result: "Результат", sessions: [])
        oldInstance.actID = known.id
        var cached = movement([oldInstance])
        cached.acts = [loaded, CaseAct(id: "absent", title: "Старый акт", date: "01.01.2024",
            courtShort: "ВС РФ", instanceLevel: .vsCassation)]
        cached.actBodies = [known.id: "Сохранённый полный текст", "absent": "Другой круг"]
        var fresh = movement([oldInstance])
        fresh.acts = [known]
        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)
        XCTAssertEqual(merged.acts.count, 1)
        XCTAssertEqual(merged.acts.first?.fileProvenance, provenance)
        XCTAssertEqual(merged.actBodies[known.id], cached.actBodies[known.id])
        XCTAssertNil(merged.actBodies["absent"])
        let reopened = try JSONDecoder().decode(CaseMovement.self, from: JSONEncoder().encode(merged))
        XCTAssertEqual(MovementCachePolicy.merge(fresh: fresh, cached: reopened), merged)

        fresh.acts[0].sourceFileURL = URL(string: "https://www.vsrf.ru/lk/practice/stor_pdf/34000002")
        let changedFile = MovementCachePolicy.merge(fresh: fresh, cached: cached)
        XCTAssertNil(changedFile.acts.first?.fileProvenance)
        XCTAssertNil(changedFile.actBodies[known.id])
    }

    func testVSRFCardIdentityUsesSectionAndIDAcrossWwwAlias() {
        XCTAssertTrue(MovementService.sameVSRFCard(currentURL, oldAliasURL))
        XCTAssertFalse(MovementService.sameVSRFCard(
            currentURL, URL(string: "https://vsrf.ru/lk/practice/claims/12-36321244")))
        XCTAssertFalse(MovementService.sameVSRFCard(
            currentURL, URL(string: "https://vsrf.ru/lk/practice/cases/12-36321243")))
    }
}
