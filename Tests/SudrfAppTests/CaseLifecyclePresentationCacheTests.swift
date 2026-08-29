import XCTest
@testable import SudrfApp

final class CaseLifecyclePresentationCacheTests: XCTestCase {

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

        XCTAssertEqual(scopedProjection, fullProjection)
    }
}
