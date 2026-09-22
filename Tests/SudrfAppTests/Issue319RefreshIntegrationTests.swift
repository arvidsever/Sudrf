import Foundation
import SwiftData
import XCTest
import SudrfKit
@testable import SudrfApp

private actor Issue319Movements: MovementProviding {
    let full: CaseMovement
    let partial: CaseMovement
    private var calls = 0

    init(full: CaseMovement, partial: CaseMovement) {
        self.full = full
        self.partial = partial
    }

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        calls += 1
        return calls == 2 ? partial : full
    }
}

@MainActor
final class Issue319RefreshIntegrationTests: XCTestCase {
    private let number = "2-431/2026"
    private let today = DateUtil.parse("22.09.2026")!

    func testTerminalFirstRefreshBaselinesVersionSixAndSurvivesPartialAndReopen()
        async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-319-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let context = makeContext()
        let full = makeMovement()
        var partial = full
        partial.instances.removeAll()
        partial.incompleteHigherCourtDomains = [context.searchDomain]

        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        var stale = MovementDerivation.snapshot(from: full, context: context, today: today)
        stale.stageRaw = CaseStageKind.first.rawValue
        stale.stageTag = "Первая инстанция"
        stale.semanticProjectionVersion = 5
        stale.deadlines.append(StoredDeadline(
            kind: "custom", what: "Пользовательский срок", basis: "fixture",
            calLabel: "ручной",
            dateRef: DateUtil.parse("01.01.2030")!.timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.confirmed.rawValue,
            occurrenceKey: "issue-319-manual"))
        let record = try store.upsert(
            context: context, snapshot: stale, movement: full,
            collections: ["Регрессия #319"])
        let key = record.key
        let seed = CaseEvent.make(
            kind: .complaintRegistered, occurrence: ["issue-319-seed"],
            observedAt: Date(timeIntervalSinceReferenceDate: 1), evidence: .init())
        record.eventJournal = CaseEventJournal(derivationVersion: 5, events: [seed])
        try store.save()

        let source = Issue319Movements(full: full, partial: partial)
        let center = RefreshCenter(
            store: store, client: SudrfClient(), serviceBuilder: { _ in source })

        let refreshed = await center.refresh(key: key)?.value
        XCTAssertEqual(refreshed?.outcome, .refreshed)
        try assertCompleted(in: store, container: container, key: key, seed: seed)
        let fetchedAt = try XCTUnwrap(store.record(forKey: key)?.movementFetchedAt)

        guard case .partial = await center.refresh(key: key)?.value.outcome else {
            return XCTFail("partial refresh должен сохранить подтверждённый terminal outcome")
        }
        XCTAssertEqual(store.record(forKey: key)?.movementFetchedAt, fetchedAt)
        try assertCompleted(in: store, container: container, key: key, seed: seed)

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        try assertCompleted(
            in: reopened, container: reopenedContainer, key: key, seed: seed)

        let reopenedCenter = RefreshCenter(
            store: reopened, client: SudrfClient(),
            serviceBuilder: { _ in Issue319Movements(full: full, partial: partial) })
        let reopenedRefresh = await reopenedCenter.refresh(key: key)?.value
        XCTAssertEqual(reopenedRefresh?.outcome, .refreshed)
        try assertCompleted(
            in: reopened, container: reopenedContainer, key: key, seed: seed)
    }

    private func assertCompleted(in store: TrackedStore, container: ModelContainer,
                                 key: String, seed: CaseEvent) throws {
        XCTAssertEqual(store.all().count, 1)
        let record = try XCTUnwrap(store.record(forKey: key))
        XCTAssertEqual(record.snapshot?.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(record.snapshot?.semanticProjectionVersion, 6)
        XCTAssertEqual(record.eventJournal?.derivationVersion, 6)
        XCTAssertEqual(record.eventJournal?.events, [seed])
        XCTAssertEqual(record.collectionNames, ["Регрессия #319"])
        XCTAssertEqual(record.snapshot?.deadlines.first {
            $0.provenance?.ruleID == "GPK-PRIVATE-COMPLAINT-GENERAL"
        }?.date, DateUtil.parse("30.01.2026"))
        XCTAssertEqual(record.snapshot?.deadlines.first {
            $0.occurrenceKey == "issue-319-manual"
        }?.status, .confirmed)

        let router = try AppRouter(
            modelContainer: container, modelContainerIsPrepared: true)
        router.reload(today: today)
        XCTAssertEqual(router.cases.count, 1)
        XCTAssertNil(router.stageCounts.first { $0.0 == .first })
        XCTAssertEqual(router.stageCounts.first { $0.0 == .done }?.1, 1)
        XCTAssertEqual(router.tierCounts.first { $0.0 == nil }?.1, 1)
        router.stageFilter = .first
        XCTAssertTrue(router.filteredCases().isEmpty)
        router.stageFilter = .done
        XCTAssertEqual(router.filteredCases().map(\.caseNumber), [number])
    }

    private func makeContext() -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: "11RS0001",
            cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: number, caseID: "319", caseUID: "issue-319-card",
            judicialUID: "11RS0001-01-2026-000319-11")
    }

    private func makeMovement() -> CaseMovement {
        let result = "Производство по делу ПРЕКРАЩЕНО"
        let instance = CaseInstance(
            level: .first, court: "Сыктывкарский городской суд",
            caseNumber: number, judge: nil,
            domain: "syktsud--komi.sudrf.ru", foundByUID: false,
            result: result, sessions: [
                CaseSession(date: "01.01.2026", event: "Судебное заседание",
                            result: result),
            ])
        return CaseMovement(
            uid: "11RS0001-01-2026-000319-11", caseNumber: number,
            inForce: false, instances: [instance], complaints: [:], acts: [],
            category: "Общая категория")
    }
}
