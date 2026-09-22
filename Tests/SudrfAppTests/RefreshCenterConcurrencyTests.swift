import XCTest
import SudrfKit
@testable import SudrfApp

/// Проверяет последовательность и справедливость общего фонового обхода.
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
        private var requestedNumbers: [String] = []
        private let delay: Duration

        init(delay: Duration = .milliseconds(25)) {
            self.delay = delay
        }

        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            started += 1
            active += 1
            peak = max(peak, active)
            requestedNumbers.append(base.caseNumber)
            defer {
                active -= 1
                completed += 1
            }

            try await Task.sleep(for: delay)
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

        func requests() -> [String] { requestedNumbers }
    }

    private actor BlockingProbe: MovementProviding {
        private var started = false
        private var released = false

        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            started = true
            while !released {
                try await Task.sleep(for: .milliseconds(2))
            }
            let instance = CaseInstance(
                level: .first, court: court.title, caseNumber: base.caseNumber,
                judge: nil, domain: court.domain, foundByUID: false,
                result: "Решение", sessions: [])
            return CaseMovement(
                uid: "uid-\(base.caseNumber)", caseNumber: base.caseNumber,
                inForce: false, instances: [instance], complaints: [:], acts: [])
        }

        func hasStarted() -> Bool { started }
        func release() { released = true }
    }

    private actor RepairProbe {
        private var started = false
        func run() { started = true }
        func hasStarted() -> Bool { started }
    }

    func testStartupWaitsForInitialDueWalkBeforeStartingGeneralRepair() async throws {
        let store = TrackedStore(inMemory: true)
        let context = MovementContext(
            branchRaw: "general", region: "Республика Коми",
            searchDomain: "startup--komi.sudrf.ru",
            displayDomain: "startup.komi.sudrf.ru",
            courtTitle: "Тестовый суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS0001", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-87/2026", caseID: "case-87", caseUID: "guid-87")
        _ = try store.upsert(context: context, snapshot: nil,
                             movement: nil, collections: [])
        let movement = BlockingProbe()
        let repair = RepairProbe()
        let center = RefreshCenter(
            store: store, client: SudrfClient(minInterval: 0),
            serviceBuilder: { _ in movement },
            initialTimerDelay: .seconds(60), timerInterval: .seconds(60))

        let startup = Task { @MainActor in
            let initialWalk = center.start()
            await initialWalk?.value
            await repair.run()
        }

        let deadline = Date().addingTimeInterval(2)
        while !(await movement.hasStarted()) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        let movementStarted = await movement.hasStarted()
        let repairStartedEarly = await repair.hasStarted()
        XCTAssertTrue(movementStarted)
        XCTAssertFalse(repairStartedEarly,
                       "общий repair не должен опережать первый due-обход")

        await movement.release()
        await startup.value
        let repairStarted = await repair.hasStarted()
        XCTAssertTrue(repairStarted)
        XCTAssertNil(center.walkProgress)
    }

    func testFullWalkIsSequentialAndCompletesEveryCase() async throws {
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
        XCTAssertLessThanOrEqual(stats.peak, 1,
                                 "полный обход должен использовать один судебный воркер")

        while center.walkProgress != nil && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(center.walkProgress, "после завершения полного обхода прогресс очищается")
    }

    func testRestartedWalkTriesAll215CasesBeforeRepeatingRecentAttempts() async throws {
        let store = TrackedStore(inMemory: true)
        let count = 215
        for index in 0..<count {
            let number = "2-\(String(format: "%03d", index + 1))/2026"
            let context = MovementContext(
                branchRaw: "general", region: "Республика Коми",
                searchDomain: "court\(index % 5)--komi.sudrf.ru",
                displayDomain: "court\(index % 5).komi.sudrf.ru",
                courtTitle: "Тестовый суд \(index % 5)",
                courtLevelRaw: CourtLevel.district.rawValue,
                courtCode: "11RS\(String(format: "%04d", index % 5))",
                cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
                caseNumber: number, caseID: "case-\(index)", caseUID: "guid-\(index)")
            _ = try store.upsert(context: context, snapshot: nil,
                                 movement: nil, collections: [])
        }

        let probe = Probe(delay: .milliseconds(2))
        let center = RefreshCenter(
            store: store, client: SudrfClient(minInterval: 0),
            serviceBuilder: { _ in probe })
        center.refreshAll(force: true)

        let deadline = Date().addingTimeInterval(10)
        while (await probe.requests()).count < 8 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        center.refreshAll(force: true)

        while Set(await probe.requests()).count < count && Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        await center.waitUntilWalkIdle()

        let requests = await probe.requests()
        XCTAssertEqual(Set(requests).count, count)
        var seen = Set<String>()
        let firstDuplicate = requests.firstIndex { !seen.insert($0).inserted }
        XCTAssertTrue(firstDuplicate == nil || firstDuplicate! >= count,
                      "после перезапуска непроверенные дела должны идти раньше недавних; "
                        + "firstDuplicate=\(String(describing: firstDuplicate)), "
                        + "uniqueBefore=\(seen.count), total=\(requests.count)")
        XCTAssertNil(center.walkProgress)
    }
}
