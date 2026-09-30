import XCTest
import Combine
import SwiftData
import SudrfKit
@testable import SudrfApp

@MainActor
final class CaseOpeningSeenStateTests: XCTestCase {
    private static let readIDsKey = "overviewReadFeedIDs.v1"
    private static let knownIDsKey = "notifiedFeedIDs.v1"
    private static let consumedMaterialIDsKey = "materialFeedConsumedLegacyIDs.v1"
    private static let pendingMaterialCountsKey = "materialFeedPendingCounts.v1"
    private static let collectionsKey = "myCollections"

    private actor FixedMovement: MovementProviding {
        let value: CaseMovement
        init(_ value: CaseMovement) { self.value = value }

        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            value
        }
    }

    private func isolateFeedDefaults() -> () -> Void {
        let defaults = UserDefaults.standard
        let keys = [Self.readIDsKey, Self.knownIDsKey,
                    Self.consumedMaterialIDsKey, Self.pendingMaterialCountsKey,
                    Self.collectionsKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        for key in keys { defaults.removeObject(forKey: key) }
        return {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
    }

    private func context(_ number: String) -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: "11RS0001",
            cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: number)
    }

    private func date(_ offset: Int) -> Date {
        DateUtil.addDays(DateUtil.today, offset)
    }

    private func dateText(_ offset: Int) -> String {
        let parts = DateUtil.cal.dateComponents([.day, .month, .year], from: date(offset))
        return String(format: "%02d.%02d.%04d", parts.day!, parts.month!, parts.year!)
    }

    private func movement(for context: MovementContext,
                          withMaterial: Bool = false,
                          actID: String? = nil) -> CaseMovement {
        var instances = [CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: nil, domain: context.displayDomain, foundByUID: false, result: nil,
            sessions: [
                CaseSession(date: dateText(-1), time: "10:00",
                            event: "Судебное заседание"),
                CaseSession(date: dateText(2), time: "12:00",
                            event: "Судебное заседание"),
            ])]
        if withMaterial {
            instances.append(CaseInstance(
                level: .material, court: context.courtTitle,
                caseNumber: "13-1/2026", judge: nil, domain: context.displayDomain,
                foundByUID: true, result: nil,
                sessions: [CaseSession(date: dateText(-1), time: "11:00",
                                       event: "Поступление материала")]))
        }
        let acts = actID.map {
            [CaseAct(id: $0, title: "Определение", date: dateText(-1),
                     courtShort: "СГС", instanceLevel: .first)]
        } ?? []
        return CaseMovement(uid: "uid-\(context.caseNumber)",
                            caseNumber: context.caseNumber, inForce: false,
                            instances: instances, complaints: [:], acts: acts)
    }

    private func record(_ context: MovementContext,
                        withMaterial: Bool = false,
                        actID: String? = nil) throws -> TrackedCaseRecord {
        let movement = movement(for: context, withMaterial: withMaterial, actID: actID)
        var snapshot = MovementDerivation.snapshot(from: movement, context: context)
        snapshot.deadlines.append(StoredDeadline(
            kind: "opening-test", what: "Контрольный срок", basis: "тест",
            calLabel: "контроль", dateRef: date(3).timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.confirmed.rawValue,
            occurrenceKey: "opening-\(context.caseNumber)"))
        let record = TrackedCaseRecord(
            key: context.key, collections: ["Тест"], caseNumber: context.caseNumber,
            courtTitle: context.courtTitle, displayDomain: context.displayDomain,
            contextData: try JSONEncoder().encode(context),
            snapshotData: try JSONEncoder().encode(snapshot))
        record.movement = movement
        record.movementFetchedAt = Date()
        return record
    }

    private func container(with records: [TrackedCaseRecord]) throws -> ModelContainer {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        for record in records { container.mainContext.insert(record) }
        try container.mainContext.save()
        return container
    }

    func testOpeningUsesCurrentDayCacheAndOnlyMarksCanonicalCaseAndNormalFeedRead() throws {
        let restoreDefaults = isolateFeedDefaults()
        defer { restoreDefaults() }

        let first = try record(context("2-385/2026"))
        first.legacyKeyAliases = ["old-display-key"]
        let other = try record(context("2-386/2026"))
        let container = try container(with: [first, other])
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)

        var hearingPublications = 0
        var calendarPublications = 0
        var deadlinePublications = 0
        var inactiveDeadlinePublications = 0
        let hearingSubscription = router.$hearings.sink { _ in hearingPublications += 1 }
        let calendarSubscription = router.$calendarHearings.sink { _ in calendarPublications += 1 }
        let deadlineSubscription = router.$deadlines.sink { _ in deadlinePublications += 1 }
        let inactiveDeadlineSubscription = router.$inactiveDeadlines.sink {
            _ in inactiveDeadlinePublications += 1
        }
        hearingPublications = 0
        calendarPublications = 0
        deadlinePublications = 0
        inactiveDeadlinePublications = 0

        let firstNormalIDs = Set(router.feed.filter {
            $0.recordKey == first.key && $0.kind != .enforcement
        }.map(\.id))
        XCTAssertFalse(firstNormalIDs.isEmpty)
        XCTAssertTrue(router.feed.filter { firstNormalIDs.contains($0.id) }.allSatisfy(\.isUnread))

        router.openCase(key: "old-display-key")

        XCTAssertEqual(router.openedCase, first.caseNumber)
        XCTAssertEqual(try TrackedStore(container: container, prepared: true)
            .record(forKey: first.key)?.seenAt, first.seenAt)
        XCTAssertNotNil(first.seenAt)
        XCTAssertFalse(router.cases.first { $0.recordKey == first.key }?.isNew ?? true)
        XCTAssertFalse(router.cases.first { $0.recordKey == first.key }?.newDot ?? true)
        XCTAssertTrue(router.cases.first { $0.recordKey == other.key }?.isNew ?? false)
        XCTAssertTrue(router.feed.filter { firstNormalIDs.contains($0.id) }.allSatisfy { !$0.isUnread })
        XCTAssertTrue(router.feed.filter { $0.recordKey == other.key && $0.kind != .enforcement }
            .allSatisfy(\.isUnread))
        XCTAssertNil(UserDefaults.standard.object(forKey: Self.readIDsKey),
                     "opening a case must not persist every feed ID as read")
        XCTAssertEqual(hearingPublications, 0)
        XCTAssertEqual(calendarPublications, 0)
        XCTAssertEqual(deadlinePublications, 0)
        XCTAssertEqual(inactiveDeadlinePublications, 0)

        let seenAt = try XCTUnwrap(first.seenAt)
        router.openCase(key: first.key)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(first.seenAt), seenAt)
        XCTAssertEqual(hearingPublications, 0)
        XCTAssertEqual(calendarPublications, 0)
        XCTAssertEqual(deadlinePublications, 0)

        func projection(_ router: AppRouter) -> [String] {
            [
                "\(router.newBadge)|\(router.unreadFeedCount)",
                router.cases.map { "\($0.recordKey)|\($0.isNew)|\($0.newDot)" }.joined(separator: ";"),
                router.feed.map { "\($0.id)|\($0.kind.rawValue)|\($0.isUnread)" }.joined(separator: ";"),
                router.hearings.map(\.id).joined(separator: ";"),
                router.calendarHearings.map(\.id).joined(separator: ";"),
                router.deadlines.map(\.id).joined(separator: ";"),
                router.stageCounts.map { "\($0.0.rawValue)|\($0.1)" }.joined(separator: ";"),
                router.tierCounts.map { "\(String(describing: $0.0))|\($0.1)" }.joined(separator: ";"),
            ]
        }
        let fastPathProjection = projection(router)
        router.reload()
        XCTAssertEqual(projection(router), fastPathProjection,
                       "same-day seen updates must match the full reload projection")
        _ = hearingSubscription
        _ = calendarSubscription
        _ = deadlineSubscription
        _ = inactiveDeadlineSubscription
    }

    func testOpeningMaterialAndActFeedEntriesKeepsExplicitActSelection() throws {
        let restoreDefaults = isolateFeedDefaults()
        defer { restoreDefaults() }

        let context = context("2-387/2026")
        let record = try record(context, withMaterial: true, actID: "opening-act")
        let container = try container(with: [record])
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let material = try XCTUnwrap(router.feed.first {
            $0.recordKey == record.key && $0.instanceLevel == .material
        })
        XCTAssertTrue(material.isUnread)

        router.openFeedEntry(material)

        XCTAssertEqual(router.openedCase, record.caseNumber)
        XCTAssertFalse(try XCTUnwrap(router.feed.first { $0.id == material.id }).isUnread)
        XCTAssertTrue(router.feed.filter { $0.recordKey == record.key && $0.kind != .enforcement }
            .allSatisfy { !$0.isUnread })

        let act = try XCTUnwrap(router.feed.first { $0.actID == "opening-act" })
        router.closeCase()
        router.openFeedEntry(act, preferAct: true)

        XCTAssertEqual(router.selectedActID, "opening-act")
        XCTAssertFalse(try XCTUnwrap(router.feed.first { $0.id == act.id }).isUnread)
        XCTAssertTrue(UserDefaults.standard.stringArray(forKey: Self.readIDsKey)?.contains(act.id) == true)
    }

    func testOpeningCaseLeavesEnforcementUnreadUntilItsEntryIsOpened() throws {
        let restoreDefaults = isolateFeedDefaults()
        defer { restoreDefaults() }

        let record = try record(context("2-388/2026"))
        record.enforcementRecords = [EnforcementRecord(
            courtDocumentID: "writ-388", source: .treasury, status: "Исполняется",
            events: [
                EnforcementEvent(guid: "rss-388-a", date: date(-1), text: "Первое событие", sourceOrder: 0),
                EnforcementEvent(guid: "rss-388-b", date: date(-2), text: "Второе событие", sourceOrder: 1),
            ])]
        let container = try container(with: [record])
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let enforcement = router.feed.filter {
            $0.recordKey == record.key && $0.kind == .enforcement
        }
        XCTAssertEqual(enforcement.count, 2)

        router.openCase(key: record.key)

        XCTAssertTrue(router.feed.filter { $0.kind == .enforcement }.allSatisfy(\.isUnread))
        XCTAssertNil(UserDefaults.standard.object(forKey: Self.readIDsKey))

        let chosen = try XCTUnwrap(enforcement.first)
        router.openFeedEntry(chosen)
        XCTAssertFalse(try XCTUnwrap(router.feed.first { $0.id == chosen.id }).isUnread)
        XCTAssertEqual(router.feed.filter {
            $0.recordKey == record.key && $0.kind == .enforcement && $0.id != chosen.id
        }.count, 1)
        XCTAssertTrue(router.feed.first {
            $0.recordKey == record.key && $0.kind == .enforcement && $0.id != chosen.id
        }?.isUnread ?? false)
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: Self.readIDsKey), [chosen.id])
    }

    func testFailedSeenSaveRollsBackRecordAndPublishedUnreadState() throws {
        let restoreDefaults = isolateFeedDefaults()
        defer { restoreDefaults() }

        let record = try record(context("2-389/2026"))
        let priorSeenAt: Date? = nil
        record.seenAt = priorSeenAt
        let container = try container(with: [record])
        var capturedStore: TrackedStore?
        let router = try AppRouter(
            modelContainer: container, modelContainerIsPrepared: true,
            refreshCenterFactory: { store, client in
                capturedStore = store
                return RefreshCenter(store: store, client: client)
            })
        capturedStore?.failNextSaveForTesting = true

        router.openCase(key: record.key)

        XCTAssertEqual(capturedStore?.record(forKey: record.key)?.seenAt, priorSeenAt)
        XCTAssertEqual(router.persistenceError, "Изменения не сохранены. Повторите попытку.")
        XCTAssertTrue(router.cases.first?.isNew == true)
        XCTAssertTrue(router.cases.first?.newDot == true)
        XCTAssertTrue(router.feed.filter { $0.recordKey == record.key && $0.kind != .enforcement }
            .allSatisfy(\.isUnread))
        XCTAssertFalse(capturedStore?.failNextSaveForTesting ?? true)
    }

    func testSeenAtSurvivesReopeningPersistentStoreAndRouter() throws {
        let restoreDefaults = isolateFeedDefaults()
        defer { restoreDefaults() }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("case-opening-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("test.store")
        let context = context("2-390/2026")
        let record = try record(context)
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        container.mainContext.insert(record)
        try container.mainContext.save()
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)

        router.openCase(key: record.key)
        let savedSeenAt = try XCTUnwrap(record.seenAt)

        let reopenedContainer = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let reopenedStore = try TrackedStore(container: reopenedContainer, prepared: true)
        XCTAssertEqual(reopenedStore.record(forKey: record.key)?.seenAt, savedSeenAt)
        let reopenedRouter = try AppRouter(
            modelContainer: reopenedContainer, modelContainerIsPrepared: true)
        XCTAssertFalse(reopenedRouter.cases.first?.isNew ?? true)
    }

    func testOpeningAfterPreviousDayCacheFallsBackToFullReload() throws {
        let restoreDefaults = isolateFeedDefaults()
        defer { restoreDefaults() }

        let record = try record(context("2-391/2026"))
        let container = try container(with: [record])
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        router.reload(today: DateUtil.addDays(DateUtil.today, -1))
        var calendarPublications = 0
        let subscription = router.$calendarHearings.sink { _ in calendarPublications += 1 }
        let beforeOpen = calendarPublications

        router.openCase(key: record.key)

        XCTAssertGreaterThan(calendarPublications, beforeOpen,
                             "previous-day cache must trigger the ordinary full reload")
        XCTAssertNotNil(record.seenAt)
        let afterFallback = calendarPublications
        router.openCase(key: record.key)
        XCTAssertEqual(calendarPublications, afterFallback,
                       "a second open on the current day must use the warm cache")
        _ = subscription
    }

    func testRefreshWithNewEventClearsSeenAndReturnsFeedEntryToUnread() async throws {
        let restoreDefaults = isolateFeedDefaults()
        defer { restoreDefaults() }

        let context = context("2-392/2026")
        let record = try record(context)
        record.seenAt = Date(timeIntervalSince1970: 1_700_000_100)
        var updated = try XCTUnwrap(record.movement)
        updated.instances[0].sessions.append(CaseSession(
            date: dateText(0), time: "14:30", event: "Поступление нового документа"))
        let container = try container(with: [record])
        let provider = FixedMovement(updated)
        let router = try AppRouter(
            modelContainer: container, modelContainerIsPrepared: true,
            refreshCenterFactory: { store, client in
                RefreshCenter(store: store, client: client, serviceBuilder: { _ in provider })
            })
        router.refreshCenter.repairBeforeRefresh = { key, _ in key }
        // Avoid UNUserNotificationCenter in xctest; project persisted state explicitly below.
        router.refreshCenter.onRefreshed = nil
        router.openCase(key: record.key)
        router.closeCase()

        let execution = await router.refreshCenter.refresh(key: record.key, manually: true)?.value

        XCTAssertEqual(execution?.outcome, .refreshed)
        XCTAssertNil(record.seenAt)
        router.reload(notifyNew: false, changedCaseKeys: [record.key])
        XCTAssertTrue(router.feed.contains {
            $0.recordKey == record.key && $0.text == "Поступление нового документа" && $0.isUnread
        })
    }

    func testLifecycleCacheIsCurrentOnlyForPreparedDay() {
        let today = DateUtil.today
        var cache = CaseLifecyclePresentationCache()

        XCTAssertFalse(cache.isCurrent(for: today))
        cache.prepare(for: today, changedCaseKeys: nil)
        XCTAssertTrue(cache.isCurrent(for: today))
        XCTAssertFalse(cache.isCurrent(for: DateUtil.addDays(today, 1)))
    }
}
