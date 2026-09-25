import XCTest
@_spi(Diagnostics) import SudrfKit
@testable import SudrfApp

@MainActor
final class RefreshCenterSchedulingTests: XCTestCase {

    private actor Probe: MovementProviding {
        private let failure: Bool
        private var requestedNumbers: [String] = []
        private var scopedCalls = 0

        init(failure: Bool = false) { self.failure = failure }

        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            requestedNumbers.append(base.caseNumber)
            if TransportTiming.collector != nil { scopedCalls += 1 }
            if failure { throw SudrfError.caseCardTemporarilyUnavailable }
            return CaseMovement(
                uid: "uid-\(base.caseNumber)", caseNumber: base.caseNumber,
                inForce: false,
                instances: [CaseInstance(level: .first, court: court.title,
                                         caseNumber: base.caseNumber, judge: nil,
                                         domain: court.domain, foundByUID: false,
                                         result: "Решение", sessions: [])],
                complaints: [:], acts: [])
        }

        func requests() -> [String] { requestedNumbers }
        func scopedRequestCount() -> Int { scopedCalls }
    }

    private actor FirstCallGate: MovementProviding {
        private var requests: [String] = []
        private var firstCallContinuation: CheckedContinuation<Void, Never>?

        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            requests.append(base.caseNumber)
            if requests.count == 1 {
                await withCheckedContinuation { firstCallContinuation = $0 }
            }
            return CaseMovement(
                uid: "uid-\(base.caseNumber)", caseNumber: base.caseNumber,
                inForce: false,
                instances: [CaseInstance(level: .first, court: court.title,
                                         caseNumber: base.caseNumber, judge: nil,
                                         domain: court.domain, foundByUID: false,
                                         result: "Решение", sessions: [])],
                complaints: [:], acts: [])
        }

        func hasFirstCall() -> Bool { firstCallContinuation != nil }
        func releaseFirstCall() {
            firstCallContinuation?.resume()
            firstCallContinuation = nil
        }
        func allRequests() -> [String] { requests }
    }

    private func context(_ index: Int) -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "scheduler\(index)--komi.sudrf.ru",
            displayDomain: "scheduler\(index).komi.sudrf.ru",
            courtTitle: "Тестовый суд \(index)",
            courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS\(String(format: "%04d", index))", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-\(index)/2026", caseID: "case-\(index)",
            caseUID: "guid-\(index)")
    }

    private func snapshot(withUpcomingSession: Bool, sessionDate: Date? = nil) -> CaseSnapshot {
        let scheduledDate = sessionDate
            ?? Calendar.current.date(byAdding: .day, value: 1, to: .now)!
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "dd.MM.yyyy"
        let sessions = withUpcomingSession ? [StoredSession(
            dateRaw: formatter.string(from: scheduledDate), time: "10:00", room: nil,
            event: "Заседание", result: nil, court: "Тестовый суд",
            levelRaw: CaseInstance.Level.first.rawValue)] : []
        return CaseSnapshot(
            uid: "", inForce: false, category: nil, partiesShort: "",
            leadCharges: nil, secondPartyLine: nil, stageRaw: "first", stageTag: "",
            statusText: "", statusChipRaw: "gray", lastEvent: "", nextEvent: "",
            nextChipRaw: "gray", steps: [], sessions: sessions, deadlines: [])
    }

    func testRetryDelayIsDeterministicExponentialAndCapped() {
        let key = "scheduler-delay"
        XCTAssertEqual(RefreshCenter.retryDelay(forFailureCount: 3, key: key),
                       RefreshCenter.retryDelay(forFailureCount: 3, key: key))
        XCTAssertGreaterThanOrEqual(RefreshCenter.retryDelay(forFailureCount: 1, key: key), 480)
        XCTAssertLessThanOrEqual(RefreshCenter.retryDelay(forFailureCount: 1, key: key), 720)
        XCTAssertGreaterThanOrEqual(RefreshCenter.retryDelay(forFailureCount: 3, key: key), 1_920)
        XCTAssertLessThanOrEqual(RefreshCenter.retryDelay(forFailureCount: 3, key: key), 2_880)
        XCTAssertLessThanOrEqual(RefreshCenter.retryDelay(forFailureCount: 99, key: key), 21_600)
        XCTAssertEqual(RefreshCenter.retryDelay(forFailureCount: 7, key: key),
                       RefreshCenter.retryDelay(forFailureCount: 99, key: key))
    }

    func testUpcomingSessionRunsBeforeOlderOrdinaryCase() async throws {
        let store = TrackedStore(inMemory: true)
        let ordinary = try store.upsert(context: context(1), snapshot: snapshot(withUpcomingSession: false),
                                        movement: nil, collections: [])
        let urgent = try store.upsert(context: context(2), snapshot: snapshot(withUpcomingSession: true),
                                      movement: nil, collections: [])
        let now = Date()
        ordinary.movementFetchedAt = now.addingTimeInterval(-RefreshSettings.ttl - 60)
        urgent.movementFetchedAt = now.addingTimeInterval(-RefreshSettings.ttl - 60)
        try store.save()
        let probe = Probe()
        let center = RefreshCenter(store: store, client: SudrfClient(minInterval: 0),
                                   serviceBuilder: { _ in probe },
                                   walkDiagnostics: RefreshWalkDiagnostics(
                                       enabled: false, directory: FileManager.default.temporaryDirectory,
                                       now: { now }, appVersion: "test", appBuild: "1"))

        await center.refreshAll(force: false)?.value

        let requests = await probe.requests()
        XCTAssertEqual(Array(requests.prefix(2)), [urgent.caseNumber, ordinary.caseNumber])
        let scopedCalls = await probe.scopedRequestCount()
        XCTAssertEqual(scopedCalls, 2, "court walk must scope all refresh requests")
    }

    func testSameDaySessionHasUrgentPriorityAfterMidnight() async throws {
        let store = TrackedStore(inMemory: true)
        let startOfToday = Calendar.current.startOfDay(for: .now)
        let now = Calendar.current.date(byAdding: .hour, value: 12, to: startOfToday)!
        let ordinary = try store.upsert(context: context(11), snapshot: snapshot(withUpcomingSession: false),
                                        movement: nil, collections: [])
        let today = try store.upsert(context: context(12),
                                    snapshot: snapshot(withUpcomingSession: true, sessionDate: now),
                                    movement: nil, collections: [])
        ordinary.movementFetchedAt = now.addingTimeInterval(-RefreshSettings.ttl - 60)
        today.movementFetchedAt = now.addingTimeInterval(-RefreshSettings.ttl - 60)
        try store.save()
        let probe = Probe()
        let center = RefreshCenter(
            store: store, client: SudrfClient(minInterval: 0), serviceBuilder: { _ in probe },
            walkDiagnostics: RefreshWalkDiagnostics(
                enabled: false, directory: FileManager.default.temporaryDirectory,
                now: { now }, appVersion: "test", appBuild: "1"))

        await center.refreshAll(force: false)?.value

        let requests = await probe.requests()
        XCTAssertEqual(requests.first, today.caseNumber)
    }

    func testRecentAndUpcomingHearingsBypassBackoffButOlderHearingDoesNot() async throws {
        let store = TrackedStore(inMemory: true)
        let now = Date()
        let recent = try store.upsert(
            context: context(21),
            snapshot: snapshot(withUpcomingSession: true,
                               sessionDate: now.addingTimeInterval(-5 * 24 * 60 * 60)),
            movement: nil, collections: [])
        let upcoming = try store.upsert(
            context: context(22),
            snapshot: snapshot(withUpcomingSession: true,
                               sessionDate: now.addingTimeInterval(2 * 24 * 60 * 60)),
            movement: nil, collections: [])
        let old = try store.upsert(
            context: context(23),
            snapshot: snapshot(withUpcomingSession: true,
                               sessionDate: now.addingTimeInterval(-8 * 24 * 60 * 60)),
            movement: nil, collections: [])
        var deadlineSnapshot = snapshot(withUpcomingSession: false)
        deadlineSnapshot.deadlines = [StoredDeadline(
            kind: "appeal", what: "Жалоба", basis: "test", calLabel: "Срок",
            dateRef: now.addingTimeInterval(2 * 24 * 60 * 60)
                .timeIntervalSinceReferenceDate, statusRaw: "confirmed")]
        let deadline = try store.upsert(
            context: context(24), snapshot: deadlineSnapshot,
            movement: nil, collections: [])
        for record in [recent, upcoming, old, deadline] {
            record.movementFetchedAt = now.addingTimeInterval(-RefreshSettings.ttl - 60)
            record.sourceRefreshAttempt = SourceAttempt(
                kind: .transportFailure,
                provenance: SourceProvenance(operation: .movement,
                                             sourceFamily: "sudrf",
                                             host: record.context!.searchDomain,
                                             observedAt: now),
                consecutiveRefreshFailures: 3,
                retryNotBefore: now.addingTimeInterval(60 * 60))
        }
        try store.save()
        let probe = Probe()
        let center = RefreshCenter(
            store: store, client: SudrfClient(minInterval: 0), serviceBuilder: { _ in probe },
            walkDiagnostics: RefreshWalkDiagnostics(
                enabled: false, directory: FileManager.default.temporaryDirectory,
                now: { now }, appVersion: "test", appBuild: "1"))

        await center.refreshAll(force: false)?.value

        let requests = await probe.requests()
        XCTAssertEqual(Set(requests),
                       [recent.caseNumber, upcoming.caseNumber, deadline.caseNumber])
        XCTAssertFalse(requests.contains(old.caseNumber))
    }

    func testSuccessfulRefreshClearsPersistedFailureState() async throws {
        let store = TrackedStore(inMemory: true)
        let record = try store.upsert(context: context(3), snapshot: nil, movement: nil, collections: [])
        record.sourceRefreshAttempt = SourceAttempt(
            kind: .transportFailure,
            provenance: SourceProvenance(operation: .movement, sourceFamily: "sudrf",
                                         host: "scheduler3--komi.sudrf.ru", observedAt: .now),
            consecutiveRefreshFailures: 4,
            retryNotBefore: .now.addingTimeInterval(24 * 60 * 60))
        try store.save()
        let center = RefreshCenter(store: store, client: SudrfClient(minInterval: 0),
                                   serviceBuilder: { _ in Probe() })

        _ = await center.refresh(key: record.key)?.value

        let attempt = try XCTUnwrap(store.record(forKey: record.key)?.sourceRefreshAttempt)
        XCTAssertEqual(attempt.kind, .usableSnapshot)
        XCTAssertNil(attempt.consecutiveRefreshFailures)
        XCTAssertNil(attempt.retryNotBefore)
    }

    func testForcedRestartLetsUnscheduledCasesOvertakeRecentAttempts() async throws {
        let store = TrackedStore(inMemory: true)
        let count = 40
        let sameAddedAt = Date(timeIntervalSince1970: 1_000_000)
        for index in 0..<count {
            let record = try store.upsert(context: context(index + 100), snapshot: nil,
                                          movement: nil, collections: [])
            record.addedAt = sameAddedAt
        }
        try store.save()
        let probe = FirstCallGate()
        let center = RefreshCenter(store: store, client: SudrfClient(minInterval: 0),
                                   serviceBuilder: { _ in probe })
        center.refreshAll(force: true)
        for _ in 0..<1_000 where !(await probe.hasFirstCall()) {
            await Task.yield()
        }
        let firstCallStarted = await probe.hasFirstCall()
        guard firstCallStarted else { return XCTFail("первый refresh не дошёл до gate") }
        center.refreshAll(force: true)
        await probe.releaseFirstCall()
        var uniqueRequests = Set<String>()
        for _ in 0..<10_000 {
            uniqueRequests = Set(await probe.allRequests())
            if uniqueRequests.count == count { break }
            await Task.yield()
        }
        await center.waitUntilWalkIdle()

        let requests = await probe.allRequests()
        XCTAssertEqual(Set(requests).count, count)
        var seen = Set<String>()
        let firstDuplicate = requests.firstIndex { !seen.insert($0).inserted }
        XCTAssertTrue(firstDuplicate == nil || firstDuplicate! >= count,
                      "после force-restart недавние попытки не должны вытеснять хвост")
    }
}
