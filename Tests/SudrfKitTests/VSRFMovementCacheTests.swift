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

    func testVSRFCardIdentityUsesSectionAndIDAcrossWwwAlias() {
        XCTAssertTrue(MovementService.sameVSRFCard(currentURL, oldAliasURL))
        XCTAssertFalse(MovementService.sameVSRFCard(
            currentURL, URL(string: "https://vsrf.ru/lk/practice/claims/12-36321244")))
        XCTAssertFalse(MovementService.sameVSRFCard(
            currentURL, URL(string: "https://vsrf.ru/lk/practice/cases/12-36321243")))
    }
}
