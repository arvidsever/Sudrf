import XCTest
import Foundation
import Combine
import SudrfKit
@testable import SudrfApp

final class CaseLifecyclePresentationCacheTests: XCTestCase {

    private struct PublishedProjection: Equatable {
        var cases: [String]
        var hearings: [String]
        var deadlines: [String]
        var feed: [String]
        var collections: [String]
        var stageCounts: [String]
        var tierCounts: [String]
        var lastOverviewRefreshAt: Date?
    }

    private let day = DateUtil.parse("29.08.2026")!

    private func presentation(_ tag: String) -> CaseLifecyclePresentation {
        CaseLifecyclePresentation(
            stage: .first,
            stageTag: tag,
            statusText: tag,
            statusChip: .blue,
            nextEvent: tag,
            nextChip: .blue,
            nextEventDate: day,
            steps: [tag],
            currentTier: nil,
            currentReviewNumber: nil,
            nextEventCourt: nil)
    }

    private func sourceDate(_ date: Date) -> String {
        let parts = DateUtil.cal.dateComponents([.day, .month, .year], from: date)
        return String(format: "%02d.%02d.%04d", parts.day!, parts.month!, parts.year!)
    }

    private func record(number: String, marker: String) throws -> TrackedCaseRecord {
        let context = MovementContext(
            branchRaw: "general", region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: "district", courtCode: "11RS0001",
            cartotekaId: "g1", cartotekaLevelRaw: "district",
            caseNumber: number)
        let sessions = [
            CaseSession(date: sourceDate(DateUtil.addDays(DateUtil.today, -1)),
                        event: "Судебное заседание", result: "Результат-\(marker)"),
            CaseSession(date: sourceDate(DateUtil.addDays(DateUtil.today, 1)),
                        time: "10:00", event: "Судебное заседание"),
        ]
        let instance = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: number,
            judge: nil, domain: context.displayDomain, foundByUID: false,
            result: nil, sessions: sessions)
        let movement = CaseMovement(
            uid: "uid-\(number)", caseNumber: number, inForce: false,
            instances: [instance], complaints: [:], acts: [])
        let snapshot = MovementDerivation.snapshot(from: movement, context: context)
        let record = TrackedCaseRecord(
            key: context.key, collections: ["Тест"], caseNumber: number,
            courtTitle: context.courtTitle, displayDomain: context.displayDomain,
            contextData: try JSONEncoder().encode(context),
            snapshotData: try JSONEncoder().encode(snapshot))
        record.movement = movement
        record.movementFetchedAt = Date()
        return record
    }

    @MainActor
    private func projection(_ router: AppRouter) -> PublishedProjection {
        PublishedProjection(
            cases: router.cases.map {
                "\($0.recordKey)|\($0.stage.rawValue)|\($0.statusText)|\($0.last)|\($0.next)"
            },
            hearings: router.hearings.map(\.id),
            deadlines: router.deadlines.map {
                "\($0.id)|\($0.status.rawValue)|\($0.date.timeIntervalSinceReferenceDate)"
            },
            feed: router.feed.map {
                "\($0.id)|\($0.kind.rawValue)|\($0.text)|\($0.isUnread)"
            },
            collections: router.collections.map { "\($0.0)|\($0.1)" },
            stageCounts: router.stageCounts.map { "\($0.0.rawValue)|\($0.1)" },
            tierCounts: router.tierCounts.map { "\(String(describing: $0.0))|\($0.1)" },
            lastOverviewRefreshAt: router.lastOverviewRefreshAt)
    }

    func testFirstReloadComputesEveryRecord() {
        var cache = CaseLifecyclePresentationCache()
        var computations = 0
        cache.prepare(for: day, changedCaseKeys: nil)

        for key in ["a", "b", "c"] {
            _ = cache.presentation(for: key) {
                computations += 1
                return self.presentation(key)
            }
        }

        XCTAssertEqual(computations, 3)
        XCTAssertEqual(cache.count, 3)
    }

    func testSameDayScopedReloadRecomputesOnlyChangedRecord() {
        var cache = CaseLifecyclePresentationCache()
        var computations = 0
        cache.prepare(for: day, changedCaseKeys: nil)
        for key in ["a", "b"] {
            _ = cache.presentation(for: key) {
                computations += 1
                return self.presentation("initial-" + key)
            }
        }

        cache.prepare(for: day, changedCaseKeys: ["a"])
        let refreshed = cache.presentation(for: "a") {
            computations += 1
            return self.presentation("updated-a")
        }
        let untouched = cache.presentation(for: "b") {
            computations += 1
            return self.presentation("incorrect-recompute")
        }

        XCTAssertEqual(computations, 3)
        XCTAssertEqual(refreshed?.stageTag, "updated-a")
        XCTAssertEqual(untouched?.stageTag, "initial-b")
        XCTAssertEqual(cache.count, 2)
    }

    func testDeletedAndRemappedKeysAreEvictedBeforeScopedReload() {
        var cache = CaseLifecyclePresentationCache()
        var computations = 0
        cache.prepare(for: day, changedCaseKeys: nil)
        for key in ["old", "survivor", "deleted"] {
            _ = cache.presentation(for: key) {
                computations += 1
                return self.presentation(key)
            }
        }

        cache.prepare(for: day, changedCaseKeys: ["old", "survivor", "deleted"])
        XCTAssertEqual(cache.count, 0)
        _ = cache.presentation(for: "survivor") {
            computations += 1
            return self.presentation("survivor-after-remap")
        }

        XCTAssertEqual(computations, 4)
        XCTAssertEqual(cache.count, 1)
    }

    func testNextDayInvalidatesAllEvenForScopedReload() {
        var cache = CaseLifecyclePresentationCache()
        var computations = 0
        cache.prepare(for: day, changedCaseKeys: nil)
        for key in ["a", "b"] {
            _ = cache.presentation(for: key) {
                computations += 1
                return self.presentation(key)
            }
        }

        cache.prepare(for: DateUtil.addDays(day, 1), changedCaseKeys: ["a"])
        _ = cache.presentation(for: "a") {
            computations += 1
            return self.presentation("next-day-a")
        }
        _ = cache.presentation(for: "b") {
            computations += 1
            return self.presentation("next-day-b")
        }

        XCTAssertEqual(computations, 4)
        XCTAssertEqual(cache.count, 2)
    }

    func testScopedAndFullReloadProduceTheSameProjection() {
        let keys = ["a", "b", "c"]
        let initial = Dictionary(uniqueKeysWithValues: keys.map { ($0, "initial-" + $0) })
        let updated = ["a": "initial-a", "b": "updated-b", "c": "initial-c"]

        var full = CaseLifecyclePresentationCache()
        full.prepare(for: day, changedCaseKeys: nil)
        let fullProjection = keys.compactMap { key in
            full.presentation(for: key) { self.presentation(updated[key]!) }
        }

        var scoped = CaseLifecyclePresentationCache()
        scoped.prepare(for: day, changedCaseKeys: nil)
        for key in keys {
            _ = scoped.presentation(for: key) { self.presentation(initial[key]!) }
        }
        scoped.prepare(for: day, changedCaseKeys: ["b"])
        let scopedProjection = keys.compactMap { key in
            scoped.presentation(for: key) { self.presentation(updated[key]!) }
        }

        XCTAssertEqual(scopedProjection.map(\.stageTag), fullProjection.map(\.stageTag))
        XCTAssertEqual(scopedProjection.map(\.statusText), fullProjection.map(\.statusText))
        XCTAssertEqual(scopedProjection.map(\.nextEvent), fullProjection.map(\.nextEvent))
    }

    @MainActor
    func testScopedAndFullRouterReloadPublishEquivalentDerivedCollections() throws {
        let defaults = UserDefaults.standard
        let onboardingKey = SpotlightPreferenceStore.onboardingKey
        let savedOnboarding = defaults.object(forKey: onboardingKey)
        defaults.set(false, forKey: onboardingKey)
        defer {
            if let savedOnboarding { defaults.set(savedOnboarding, forKey: onboardingKey) }
            else { defaults.removeObject(forKey: onboardingKey) }
        }

        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let first = try record(number: "2-195/2026", marker: "first")
        let second = try record(number: "2-196/2026", marker: "initial")
        container.mainContext.insert(first)
        container.mainContext.insert(second)
        try container.mainContext.save()

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let updated = try record(number: second.caseNumber, marker: "updated")
        second.snapshotData = updated.snapshotData
        second.movementData = updated.movementData
        second.movementFetchedAt = updated.movementFetchedAt
        try container.mainContext.save()

        router.reload(changedCaseKeys: [second.key])
        let scoped = projection(router)
        router.reload()
        let full = projection(router)

        XCTAssertEqual(scoped, full)
    }

    @MainActor
    func testEmptyRepairPreflightDoesNotPublishProjectionReload() async throws {
        let defaults = UserDefaults.standard
        let onboardingKey = SpotlightPreferenceStore.onboardingKey
        let savedOnboarding = defaults.object(forKey: onboardingKey)
        defaults.set(false, forKey: onboardingKey)
        defer {
            if let savedOnboarding { defaults.set(savedOnboarding, forKey: onboardingKey) }
            else { defaults.removeObject(forKey: onboardingKey) }
        }

        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let rec = try record(number: "2-197/2026", marker: "repair-empty")
        container.mainContext.insert(rec)
        try container.mainContext.save()

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        for _ in 0..<100 { await Task.yield() }

        var notifications = 0
        let subscription = router.objectWillChange.sink { _ in notifications += 1 }
        let before = projection(router)
        let effectiveKey = try await router.refreshCenter.repairBeforeRefresh?(rec.key)

        XCTAssertEqual(effectiveKey, rec.key)
        XCTAssertEqual(notifications, 0,
                       "пустой repair-preflight не должен запускать projection reload")
        XCTAssertEqual(projection(router), before)
        _ = subscription
    }

    func testRepairReportWithoutCaseChangesDoesNotRequireProjectionReload() {
        var summary = CaseRepairSummary()
        summary.transient = 1
        summary.notFound = ["2-199/2026"]
        summary.ambiguous = ["2-200/2026"]

        XCTAssertTrue(summary.hasReport)
        XCTAssertFalse(summary.hasProjectionChanges)

        summary.affectedCaseKeys.insert("changed")
        XCTAssertTrue(summary.hasProjectionChanges)
    }

    @MainActor
    func testReportedRepairPreflightStillPublishesProjection() async throws {
        let defaults = UserDefaults.standard
        let onboardingKey = SpotlightPreferenceStore.onboardingKey
        let completedKey = "importChainRepair.v6.completed"
        let savedOnboarding = defaults.object(forKey: onboardingKey)
        let savedCompleted = defaults.object(forKey: completedKey)
        defaults.set(false, forKey: onboardingKey)
        defer {
            if let savedOnboarding { defaults.set(savedOnboarding, forKey: onboardingKey) }
            else { defaults.removeObject(forKey: onboardingKey) }
            if let savedCompleted { defaults.set(savedCompleted, forKey: completedKey) }
            else { defaults.removeObject(forKey: completedKey) }
        }

        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        for _ in 0..<100 { await Task.yield() }

        let rec = try record(number: "2-198/2026", marker: "repair-report")
        var context = try XCTUnwrap(rec.context)
        context.cartotekaId = "admj"
        context.judicialUID = "11MS0001"
        context.baseInstanceLevelRaw = CaseInstance.Level.first.rawValue
        rec.context = context
        container.mainContext.insert(rec)
        try container.mainContext.save()
        defaults.set([rec.key], forKey: completedKey)

        var notifications = 0
        let subscription = router.objectWillChange.sink { _ in notifications += 1 }
        let effectiveKey = try await router.refreshCenter.repairBeforeRefresh?(rec.key)

        XCTAssertEqual(effectiveKey, rec.key)
        XCTAssertEqual(rec.context?.baseInstanceLevel, .appeal)
        XCTAssertEqual(router.cases.map(\.recordKey), [rec.key],
                       "отчётный repair-preflight должен применить projection reload")
        XCTAssertGreaterThan(notifications, 0)
        _ = subscription
    }
}
