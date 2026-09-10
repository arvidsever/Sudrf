import XCTest
import Foundation
import Combine
import SudrfKit
@testable import SudrfApp

final class CaseLifecyclePresentationCacheTests: XCTestCase {

    private struct PublishedProjection: Equatable {
        var cases: [String]
        var hearings: [String]
        var calendarHearings: [String]
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

    private func record(number: String, marker: String,
                        sessions suppliedSessions: [CaseSession]? = nil) throws -> TrackedCaseRecord {
        let context = MovementContext(
            branchRaw: "general", region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: "district", courtCode: "11RS0001",
            cartotekaId: "g1", cartotekaLevelRaw: "district",
            caseNumber: number)
        let sessions = suppliedSessions ?? [
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

    private func completedCaseWithMaterials(today: Date,
                                            sameSchedule: Bool = false,
                                            duplicateFirstMaterialSession: Bool = false,
                                            firstMaterialResult: String? = nil) throws
        -> TrackedCaseRecord {
        let baseNumber = "2-9143/2025"
        var context = MovementContext(
            branchRaw: "general", region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: "district", courtCode: "11RS0001",
            cartotekaId: "g1", cartotekaLevelRaw: "district",
            caseNumber: baseNumber, caseID: "base-card")
        context.sourceKnownCard = KnownCard(
            domain: context.searchDomain, courtTitle: context.courtTitle,
            caseID: "base-card", caseUID: "base-guid", deloID: "1540005", new: "5",
            caseNumber: baseNumber, levelRaw: CaseInstance.Level.first.rawValue,
            cartotekaID: "g1")
        context.knownCards = [
            KnownCard(domain: context.searchDomain, courtTitle: context.courtTitle,
                      caseID: "37314485", caseUID: "material-guid-1",
                      deloID: "1610001", new: "0", caseNumber: "13-2471/2026",
                      levelRaw: CaseInstance.Level.material.rawValue, cartotekaID: "m"),
            KnownCard(domain: context.searchDomain, courtTitle: context.courtTitle,
                      caseID: "39809037", caseUID: "material-guid-2",
                      deloID: "1610001", new: "0", caseNumber: "13-3241/2026",
                      levelRaw: CaseInstance.Level.material.rawValue, cartotekaID: "m"),
        ]

        let first = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: baseNumber,
            judge: "Судья основного дела", domain: context.displayDomain,
            foundByUID: false, result: "Решение вступило в законную силу",
            sessions: [CaseSession(date: "01.09.2026", time: "10:00",
                                   event: "Судебное заседание",
                                   result: "Решение вступило в законную силу")])
        let firstMaterialSession = CaseSession(
            date: "07.09.2026", time: "14:00", room: "215",
            event: "Судебное заседание")
        let firstMaterialSessions = duplicateFirstMaterialSession
            ? [firstMaterialSession, firstMaterialSession] : [firstMaterialSession]
        let firstMaterial = CaseInstance(
            level: .material, court: context.courtTitle, caseNumber: "13-2471/2026",
            judge: "Судья первого материала", domain: context.displayDomain,
            foundByUID: true, result: firstMaterialResult, sessions: firstMaterialSessions)
        let secondMaterial = CaseInstance(
            level: .material, court: context.courtTitle, caseNumber: "13-3241/2026",
            judge: "Судья второго материала", domain: context.displayDomain,
            foundByUID: true, result: nil,
            sessions: [CaseSession(date: sameSchedule ? "07.09.2026" : "09.09.2026",
                                   time: sameSchedule ? "14:00" : "16:30", room: "304",
                                   event: "Судебное заседание")])
        let movement = CaseMovement(
            uid: "11RS0001-01-2025-000001-00", caseNumber: baseNumber, inForce: true,
            instances: [first, firstMaterial, secondMaterial], complaints: [:], acts: [])
        var snapshot = MovementDerivation.snapshot(from: movement, context: context, today: today)
        for index in snapshot.sessions.indices
            where snapshot.sessions[index].level == .material {
            snapshot.sessions[index].caseNumber = nil
        }
        let record = TrackedCaseRecord(
            key: context.key, collections: ["Импорт"], caseNumber: baseNumber,
            courtTitle: context.courtTitle, displayDomain: context.displayDomain,
            contextData: try JSONEncoder().encode(context),
            snapshotData: try JSONEncoder().encode(snapshot))
        record.movement = movement
        record.movementFetchedAt = Date(timeIntervalSince1970: 1_777_777_777)
        return record
    }

    @MainActor
    private func projection(_ router: AppRouter) -> PublishedProjection {
        PublishedProjection(
            cases: router.cases.map {
                "\($0.recordKey)|\($0.stage.rawValue)|\($0.statusText)|\($0.last)|\($0.next)"
            },
            hearings: router.hearings.map(\.id),
            calendarHearings: router.calendarHearings.map(\.id),
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
    func testCalendarReloadKeepsCompletedHistoryAndDeduplicatesExistingIDs() throws {
        let defaults = UserDefaults.standard
        let onboardingKey = SpotlightPreferenceStore.onboardingKey
        let savedOnboarding = defaults.object(forKey: onboardingKey)
        defaults.set(false, forKey: onboardingKey)
        defer {
            if let savedOnboarding { defaults.set(savedOnboarding, forKey: onboardingKey) }
            else { defaults.removeObject(forKey: onboardingKey) }
        }

        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let past = sourceDate(DateUtil.addDays(DateUtil.today, -2))
        let rec = try record(
            number: "2-199/2026", marker: "completed",
            sessions: [
                CaseSession(date: past, time: "10:00", event: "Судебное заседание",
                            result: "Решение вступило в законную силу"),
                CaseSession(date: past, time: "10:00", event: "Судебное заседание",
                            result: "Решение вступило в законную силу"),
                CaseSession(date: past, time: "10:00", event: "Судебное слушание",
                            result: "Решение вступило в законную силу"),
                CaseSession(date: sourceDate(DateUtil.addDays(DateUtil.today, 1)),
                            time: "12:00",
                            event: "Рассмотрение исправленных материалов, поступивших в суд"),
            ])
        container.mainContext.insert(rec)
        try container.mainContext.save()

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)

        XCTAssertEqual(router.cases.first?.stage, .done)
        XCTAssertEqual(router.calendarHearings.count, 2)
        XCTAssertEqual(Set(router.calendarHearings.map(\.id)).count,
                       router.calendarHearings.count)
        XCTAssertTrue(router.calendarHearings.contains {
            DateUtil.sameDay($0.date, DateUtil.addDays(DateUtil.today, -2))
        })
        XCTAssertTrue(router.hearings.isEmpty,
                      "future-only projection must keep completed production empty")
        XCTAssertEqual(router.intentUpcomingHearings(), "Ближайших заседаний нет.")

        let firstReloadIDs = router.calendarHearings.map(\.id)
        router.reload()
        XCTAssertEqual(router.calendarHearings.map(\.id), firstReloadIDs)
    }

    @MainActor
    func testCompletedCasePublishesFutureMaterialHearingsFromCachedMovement() throws {
        let fixedToday = try XCTUnwrap(DateUtil.parse("03.09.2026"))
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let rec = try completedCaseWithMaterials(today: fixedToday)
        container.mainContext.insert(rec)
        try container.mainContext.save()
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let storedSnapshot = rec.snapshot
        let storedMovement = rec.movement
        let fetchedAt = rec.movementFetchedAt
        router.reload(today: fixedToday)

        XCTAssertEqual(router.cases.first?.stage, .done)
        XCTAssertTrue(rec.snapshot?.sessions.filter { $0.level == .material }
            .allSatisfy { $0.caseNumber == nil } == true,
            "legacy-compatible snapshot deliberately lacks material numbers")
        XCTAssertEqual(router.hearings.map(\.materialNumber),
                       ["13-2471/2026", "13-3241/2026"])
        XCTAssertEqual(router.hearings.map(\.judge),
                       ["Судья первого материала", "Судья второго материала"])
        XCTAssertEqual(router.hearings.map(\.room), ["215", "304"])
        XCTAssertEqual(router.calendarHearings.compactMap(\.materialNumber),
                       ["13-2471/2026", "13-3241/2026"])
        let intent = router.intentUpcomingHearings(today: fixedToday)
        XCTAssertTrue(intent.contains("дело № 2-9143/2025, материал № 13-2471/2026"))
        XCTAssertTrue(intent.contains("дело № 2-9143/2025, материал № 13-3241/2026"))

        let firstIDs = router.hearings.map(\.id)
        router.reload(today: fixedToday)
        XCTAssertEqual(router.hearings.map(\.id), firstIDs)
        XCTAssertEqual(rec.snapshot, storedSnapshot)
        XCTAssertEqual(rec.movement, storedMovement)
        XCTAssertEqual(rec.movementFetchedAt, fetchedAt)
        XCTAssertEqual(rec.collectionNames, ["Импорт"])
    }

    @MainActor
    func testMaterialSourceIdentityDeduplicatesRowsWithoutMergingDifferentMaterials() throws {
        let fixedToday = try XCTUnwrap(DateUtil.parse("03.09.2026"))
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let rec = try completedCaseWithMaterials(
            today: fixedToday, sameSchedule: true, duplicateFirstMaterialSession: true)
        container.mainContext.insert(rec)
        try container.mainContext.save()

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        router.reload(today: fixedToday)

        XCTAssertEqual(router.hearings.count, 2)
        XCTAssertEqual(router.calendarHearings.filter { $0.instanceLevel == .material }.count, 2)
        XCTAssertEqual(Set(router.hearings.map(\.id)).count, 2)
        XCTAssertEqual(Set(router.calendarHearings.map(\.id)).count,
                       router.calendarHearings.count)
    }

    @MainActor
    func testOldMaterialFeedRowsEnrichFromExactCachedSourcesAndKeepDistinctIDs() throws {
        let fixedToday = try XCTUnwrap(DateUtil.parse("10.09.2026"))
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let rec = try completedCaseWithMaterials(
            today: fixedToday, sameSchedule: true, duplicateFirstMaterialSession: true)
        container.mainContext.insert(rec)
        try container.mainContext.save()

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        router.reload(today: fixedToday)
        let materials = router.feed.filter { $0.instanceLevel == .material }

        XCTAssertEqual(materials.count, 2, "точный дубль одной строки должен схлопнуться")
        XCTAssertEqual(Set(materials.map(\.id)).count, 2)
        XCTAssertEqual(Set(materials.compactMap(\.secondaryLabel)),
                       ["Материал № 13-2471/2026", "Материал № 13-3241/2026"])
        XCTAssertTrue(materials.allSatisfy {
            $0.id.contains("#material#") && $0.sourceCardID != nil
                && $0.sourceInstanceID != nil
        })
    }

    @MainActor
    func testIssue273RealCardEnrichesExactMaterialWithoutChoosingNeighbour() throws {
        // Provenance: read-only extraction from
        // .reference/issue-261/post-acceptance-backup/default.store.
        // The 08.09.2026 14:00 row belongs to source card 39270473.
        let fixedToday = try XCTUnwrap(DateUtil.parse("10.09.2026"))
        let baseNumber = "2а-1610/2026"
        var context = MovementContext(
            branchRaw: "general", region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: "district", courtCode: "11RS0001",
            cartotekaId: "p1", cartotekaLevelRaw: "district",
            caseNumber: baseNumber, caseID: "base-card")
        context.knownCards = [
            KnownCard(domain: context.searchDomain, courtTitle: context.courtTitle,
                      caseID: "39270473", caseUID: "", deloID: "1610001", new: "0",
                      caseNumber: "13а-3091/2026",
                      levelRaw: CaseInstance.Level.material.rawValue, cartotekaID: "m"),
            KnownCard(domain: context.searchDomain, courtTitle: context.courtTitle,
                      caseID: "neighbour-material", caseUID: "",
                      deloID: "1610001", new: "0", caseNumber: "13а-3000/2026",
                      levelRaw: CaseInstance.Level.material.rawValue, cartotekaID: "m"),
        ]
        let event = CaseSession(
            date: "08.09.2026", time: "14:00",
            event: "Решение вопроса о принятии к производству",
            result: "Принято к производству")
        let movement = CaseMovement(
            uid: "", caseNumber: baseNumber, inForce: true,
            instances: [
                CaseInstance(level: .material, court: context.courtTitle,
                             caseNumber: "13а-3091/2026", judge: nil,
                             domain: context.displayDomain, foundByUID: true,
                             result: nil, sessions: [event]),
                CaseInstance(level: .material, court: context.courtTitle,
                             caseNumber: "13а-3000/2026", judge: nil,
                             domain: context.displayDomain, foundByUID: true,
                             result: nil, sessions: [event]),
            ], complaints: [:], acts: [])
        var snapshot = MovementDerivation.snapshot(
            from: movement, context: context, today: fixedToday)
        for index in snapshot.sessions.indices { snapshot.sessions[index].caseNumber = nil }
        let record = TrackedCaseRecord(
            key: context.key, collections: [], caseNumber: baseNumber,
            courtTitle: context.courtTitle, displayDomain: context.displayDomain,
            contextData: try JSONEncoder().encode(context),
            snapshotData: try JSONEncoder().encode(snapshot))
        record.movement = movement
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        container.mainContext.insert(record)
        try container.mainContext.save()

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        router.reload(today: fixedToday)
        let materials = router.feed.filter { $0.instanceLevel == .material }
        let target = try XCTUnwrap(materials.first {
            $0.sourceCardID?.hasSuffix("|39270473") == true
        })

        XCTAssertEqual(materials.count, 2)
        XCTAssertEqual(target.caseNumber, baseNumber)
        XCTAssertEqual(target.secondaryLabel, "Материал № 13а-3091/2026")
        XCTAssertEqual(target.text, "Принято к производству")
        XCTAssertNotEqual(target.sourceCardID,
                          materials.first { $0.id != target.id }?.sourceCardID)
    }

    @MainActor
    func testBadOrConflictingMaterialSourceDoesNotGuessFeedNumberOrFocus() throws {
        let fixedToday = try XCTUnwrap(DateUtil.parse("10.09.2026"))
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let rec = try completedCaseWithMaterials(today: fixedToday)
        var snapshot = try XCTUnwrap(rec.snapshot)
        let indexes = snapshot.sessions.indices.filter {
            snapshot.sessions[$0].level == .material
        }
        snapshot.sessions[indexes[0]].sourceCardID = "missing-source"
        snapshot.sessions[indexes[1]].caseNumber = "13-9999/2026"
        snapshot.sessions[indexes[0]].judge = nil
        snapshot.sessions[indexes[1]].judge = nil
        rec.snapshot = snapshot
        container.mainContext.insert(rec)
        try container.mainContext.save()

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        router.reload(today: fixedToday)
        let materials = router.feed.filter { $0.instanceLevel == .material }

        XCTAssertEqual(materials.count, 2)
        XCTAssertTrue(materials.allSatisfy {
            $0.secondaryLabel == "Материал · номер не опубликован"
                && $0.sourceInstanceID == nil
        })
        let materialHearings = router.calendarHearings.filter {
            $0.instanceLevel == .material
        }
        XCTAssertEqual(materialHearings.count, 2)
        XCTAssertTrue(materialHearings.allSatisfy {
            $0.secondaryLabel == "Материал · номер не опубликован"
                && $0.judge.isEmpty
        })
        for entry in materials {
            XCTAssertNil(AppRouter.materialInstance(
                for: entry, movement: try XCTUnwrap(rec.movement),
                context: try XCTUnwrap(rec.context)))
        }
    }

    @MainActor
    func testMaterialActUsesOnlyUniqueExactLinkEvenWithStaleActLevel() throws {
        let fixedToday = try XCTUnwrap(DateUtil.parse("10.09.2026"))
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let rec = try completedCaseWithMaterials(today: fixedToday)
        var movement = try XCTUnwrap(rec.movement)
        movement.instances[1].actIDs = ["linked-material-act"]
        movement.acts = [
            CaseAct(id: "linked-material-act", title: "Определение", date: "08.09.2026",
                    courtShort: "СГС", instanceLevel: .first),
            CaseAct(id: "unlinked-material-act", title: "Определение", date: "08.09.2026",
                    courtShort: "СГС", instanceLevel: .material),
        ]
        rec.movement = movement
        container.mainContext.insert(rec)
        try container.mainContext.save()

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        router.reload(today: fixedToday)
        let linked = try XCTUnwrap(router.feed.first { $0.actID == "linked-material-act" })
        let unlinked = try XCTUnwrap(router.feed.first { $0.actID == "unlinked-material-act" })

        XCTAssertEqual(linked.instanceLevel, .material)
        XCTAssertEqual(linked.secondaryLabel, "Материал № 13-2471/2026")
        XCTAssertNotNil(linked.sourceCardID)
        XCTAssertEqual(unlinked.secondaryLabel, "Материал · номер не опубликован")
        XCTAssertNil(unlinked.sourceCardID)
    }

    @MainActor
    func testCompletedMaterialResultIsNotUpcomingButRemainsInCalendar() throws {
        let fixedToday = try XCTUnwrap(DateUtil.parse("03.09.2026"))
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let rec = try completedCaseWithMaterials(
            today: fixedToday, firstMaterialResult: "Жалоба удовлетворена")
        container.mainContext.insert(rec)
        try container.mainContext.save()

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        router.reload(today: fixedToday)

        XCTAssertEqual(router.hearings.compactMap(\.materialNumber), ["13-3241/2026"])
        XCTAssertEqual(router.calendarHearings.compactMap(\.materialNumber),
                       ["13-2471/2026", "13-3241/2026"])
        XCTAssertFalse(router.hearings.contains { $0.instanceLevel != .material },
                       "ordinary completed instances must stay out of Overview")
    }

    @MainActor
    func testAmbiguousCachedMaterialSourceDoesNotGuessItsNumber() throws {
        let fixedToday = try XCTUnwrap(DateUtil.parse("03.09.2026"))
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let rec = try completedCaseWithMaterials(today: fixedToday)
        var movement = try XCTUnwrap(rec.movement)
        movement.instances.append(movement.instances[1])
        rec.movement = movement
        container.mainContext.insert(rec)
        try container.mainContext.save()

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        router.reload(today: fixedToday)

        let first = try XCTUnwrap(router.hearings.first {
            DateUtil.sameDay($0.date, DateUtil.parse("07.09.2026")!)
        })
        XCTAssertNil(first.materialNumber)
        XCTAssertEqual(router.hearings.last?.materialNumber, "13-3241/2026")
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
