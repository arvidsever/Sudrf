import XCTest
import SudrfKit
@testable import SudrfApp

/// Проверяет именно ограничение обхода по группам домашних судов. Один
/// источник может обслуживать несколько карточек, поэтому в тесте есть по два
/// дела в каждой группе и четыре разные группы.
@MainActor
final class RefreshCenterConcurrencyTests: XCTestCase {

    private actor Probe: MovementProviding {
        struct Stats: Sendable {
            let started: Int
            let completed: Int
            let peak: Int
        }

        private var started = 0
        private var completed = 0
        private var active = 0
        private var peak = 0

        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            started += 1
            active += 1
            peak = max(peak, active)
            defer {
                active -= 1
                completed += 1
            }

            try await Task.sleep(for: .milliseconds(25))
            let instance = CaseInstance(
                level: .first, court: court.title, caseNumber: base.caseNumber,
                judge: nil, domain: court.domain, foundByUID: false,
                result: "Решение", sessions: [])
            return CaseMovement(
                uid: "uid-\(base.caseNumber)", caseNumber: base.caseNumber,
                inForce: false, instances: [instance], complaints: [:], acts: [])
        }

        func stats() -> Stats {
            Stats(started: started, completed: completed, peak: peak)
        }
    }

    func testFullWalkLimitsCourtGroupsAndCompletesEveryCase() async throws {
        XCTAssertEqual(RefreshSettings.maxConcurrentCourts, 1)

        let store = TrackedStore(inMemory: true)
        let casesPerCourt = 2
        let courtCount = 4
        let expectedCases = casesPerCourt * courtCount

        for courtIndex in 0..<courtCount {
            for caseIndex in 0..<casesPerCourt {
                let domain = "court\(courtIndex).komi.sudrf.ru"
                let searchDomain = "court\(courtIndex)--komi.sudrf.ru"
                let number = "2-\(100 + courtIndex * 10 + caseIndex)/2026"
                let context = MovementContext(
                    branchRaw: "general", region: "Республика Коми",
                    searchDomain: searchDomain, displayDomain: domain,
                    courtTitle: "Тестовый суд \(courtIndex)",
                    courtLevelRaw: CourtLevel.district.rawValue,
                    courtCode: "11RS00\(courtIndex)", cartotekaId: "g1",
                    cartotekaLevelRaw: CourtLevel.district.rawValue,
                    caseNumber: number, caseID: "case-\(courtIndex)-\(caseIndex)",
                    caseUID: "guid-\(courtIndex)-\(caseIndex)")
                _ = try store.upsert(context: context, snapshot: nil,
                                     movement: nil, collections: [])
            }
        }

        let probe = Probe()
        let center = RefreshCenter(
            store: store, client: SudrfClient(minInterval: 0),
            serviceBuilder: { _ in probe })
        center.refreshAll(force: true)

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let stats = await probe.stats()
            if stats.completed == expectedCases { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let stats = await probe.stats()
        XCTAssertEqual(stats.started, expectedCases,
                       "обход должен запустить каждое дело ровно один раз")
        XCTAssertEqual(stats.completed, expectedCases,
                       "обход должен завершить все группы судов")
        XCTAssertLessThanOrEqual(stats.peak, RefreshSettings.maxConcurrentCourts,
                                 "полный обход должен использовать один судебный воркер")

        while center.walkProgress != nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(center.walkProgress, "после завершения полного обхода прогресс очищается")
    }
}
