import Foundation
import SwiftData
import XCTest
import SudrfKit
@testable import SudrfApp

private actor Issue262MovementSequence: MovementProviding {
    private let values: [CaseMovement]
    private var index = 0

    init(_ values: [CaseMovement]) {
        precondition(!values.isEmpty)
        self.values = values
    }

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        defer { index += 1 }
        return values[min(index, values.count - 1)]
    }
}

private actor Issue262CaseClient: CaseProviding {
    private let cards: [CaseCard]
    private var index = 0

    init(_ cards: [CaseCard]) {
        precondition(!cards.isEmpty)
        self.cards = cards
    }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        []
    }

    func searchOutcome(court: Court, cartoteka: Cartoteka,
                       field: SearchField, value: String,
                       operation: SourceOperation) async throws
        -> SourceOutcome<[CaseSearchResult]> {
        .honestZero(SourceAttempt(
            kind: .honestZero,
            provenance: SourceProvenance(
                operation: operation, sourceFamily: "sudrf", host: court.domain)))
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        nextCard()
    }

    func fetchCard(url: URL) async throws -> CaseCard {
        nextCard()
    }

    private func nextCard() -> CaseCard {
        defer { index += 1 }
        return cards[min(index, cards.count - 1)]
    }
}

@MainActor
final class Issue262SemanticBaselineTests: XCTestCase {
    private let uid = "11RS0001-01-2026-000262-11"
    private var retainedCenters: [RefreshCenter] = []

    func testPartialOwnCourtChangeSurvivesDiskReopenAndEmitsOnceOnCompleteRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-262-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let context = makeContext()
        let record = try store.upsert(context: context, snapshot: nil, collections: ["Регрессия #262"])
        let key = record.key
        let completeA = try movement(rootJudge: "Судья A")
        let initial = await center(store: store, movements: [completeA]).refresh(key: key)?.value
        XCTAssertEqual(initial?.outcome, .refreshed)
        XCTAssertTrue(store.record(forKey: key)?.eventJournal?.events.isEmpty == true)

        var partialB = try movement(rootJudge: "Судья B", rootCoverageKind: .partial,
                                    incompleteDomains: [context.searchDomain])
        partialB.honestZeroDomains = nil
        let partial = await center(store: store, movements: [partialB]).refresh(key: key)?.value
        guard let partial, case .partial = partial.outcome else {
            return XCTFail("неполная карточка домашнего суда должна остаться partial")
        }
        XCTAssertEqual(store.record(forKey: key)?.movement?.instances.first?.judge, "Судья B")
        XCTAssertTrue(store.record(forKey: key)?.eventJournal?.events.isEmpty == true)
        XCTAssertEqual(
            store.record(forKey: key)?.eventJournal?.semanticBaselines?.courts.values.first?
                .instances.first?.judge,
            "Судья A",
            "partial coverage не должна потреблять смену судьи")

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        let completeB = try movement(rootJudge: "Судья B")
        let completeCenter = center(store: reopened, movements: [completeB, completeB])

        let firstComplete = await completeCenter.refresh(key: key)?.value
        XCTAssertEqual(firstComplete?.outcome, .refreshed)
        let once = try XCTUnwrap(reopened.record(forKey: key)?.eventJournal?.events)
        XCTAssertEqual(once.map(\.kind), [.judgeChanged])
        XCTAssertEqual(once.first?.evidence.previousValue, "Судья A")
        XCTAssertEqual(once.first?.evidence.value, "Судья B")

        let repeatedComplete = await completeCenter.refresh(key: key)?.value
        XCTAssertEqual(repeatedComplete?.outcome, .refreshed)
        let repeated = try XCTUnwrap(reopened.record(forKey: key)?.eventJournal?.events)
        XCTAssertEqual(repeated.map(\.kind), [.judgeChanged])
        XCTAssertEqual(Set(repeated.map(\.id)).count, 1)
        XCTAssertEqual(reopened.record(forKey: key)?.collectionNames, ["Регрессия #262"])
    }

    func testPartialSameCourtCoverageDoesNotAdvanceAnyLoadedCardAcrossDiskReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-262-multicard-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let context = makeContext()
        let record = try seed(store: store, context: context,
                              movement: try sameCourtMultiCardMovement(
                                rootJudge: "Судья A", siblingJudge: "Судья X"))
        let key = record.key
        let initial = try sameCourtMultiCardMovement(rootJudge: "Судья A", siblingJudge: "Судья X")
        let initialResult = await center(store: store, movements: [initial])
            .refresh(key: key)?.value
        XCTAssertEqual(initialResult?.outcome, .refreshed)

        let partialMovement = try sameCourtMultiCardMovement(
            rootJudge: "Судья B", siblingJudge: nil, coverageKind: .partial,
            incompleteDomains: [context.searchDomain])
        let partial = await center(store: store, movements: [partialMovement])
            .refresh(key: key)?.value
        guard let partial, case .partial = partial.outcome else {
            return XCTFail("ошибка одной карточки суда должна сохранить partial outcome")
        }
        let pending = try XCTUnwrap(store.record(forKey: key)?.eventJournal?.semanticBaselines)
        let native = try rootIdentity(context)
        let rootScope = native.sourceFamily + "|" + native.courtKey
        XCTAssertEqual(pending.courts[rootScope]?.cards.count, 2)
        XCTAssertEqual(Set(pending.courts[rootScope]?.instances.compactMap(\.judge) ?? []),
                       ["Судья A", "Судья X"],
                       "ни одна карточка общего судебного scope не должна продвинуться по partial coverage")
        XCTAssertTrue(store.record(forKey: key)?.eventJournal?.events.isEmpty == true)

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        let complete = try sameCourtMultiCardMovement(rootJudge: "Судья B", siblingJudge: "Судья Y")
        let completeCenter = center(store: reopened, movements: [complete, complete])

        let firstComplete = await completeCenter.refresh(key: key)?.value
        XCTAssertEqual(firstComplete?.outcome, .refreshed)
        var events = try XCTUnwrap(reopened.record(forKey: key)?.eventJournal?.events)
        let changes = events.filter { $0.kind == .judgeChanged }
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(Set(changes.compactMap(\.evidence.previousValue)), ["Судья A", "Судья X"])
        XCTAssertEqual(Set(changes.compactMap(\.evidence.value)), ["Судья B", "Судья Y"])

        let repeatedComplete = await completeCenter.refresh(key: key)?.value
        XCTAssertEqual(repeatedComplete?.outcome, .refreshed)
        events = try XCTUnwrap(reopened.record(forKey: key)?.eventJournal?.events)
        XCTAssertEqual(events.filter { $0.kind == .judgeChanged }.count, 2)
    }

    func testOwnCourtChangeEmitsDuringOtherCourtFailureAndUnobservedCourtBaselineSurvivesRetries() async throws {
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        let completeA = try movement(rootJudge: "Судья A", higherJudge: "Судья X")
        let record = try seed(store: store, context: context, movement: completeA)
        let initial = await center(store: store, movements: [completeA]).refresh(key: record.key)?.value
        XCTAssertEqual(initial?.outcome, .refreshed)

        let firstPartial = try movement(
            rootJudge: "Судья B", higherCoverageKind: .partial, coverHigherScope: true,
            incompleteDomains: ["2kas.sudrf.ru"])
        let partialCenter = center(store: store, movements: [firstPartial])
        let first = await partialCenter.refresh(key: record.key)?.value
        guard let first, case .partial = first.outcome else {
            return XCTFail("ошибка вышестоящего суда должна сохранить partial outcome")
        }
        var events = try XCTUnwrap(semanticJournalEvents(store.record(forKey: record.key)?.eventJournal))
        XCTAssertEqual(events.map(\.kind), [.judgeChanged])
        XCTAssertEqual(events.first?.evidence.previousValue, "Судья A")
        XCTAssertEqual(events.first?.evidence.value, "Судья B")

        let secondPartial = try movement(
            rootJudge: "Судья B", higherJudge: "Судья Y", higherCoverageKind: .partial,
            incompleteDomains: ["2kas.sudrf.ru"])
        let second = await center(store: store, movements: [secondPartial]).refresh(key: record.key)?.value
        guard let second, case .partial = second.outcome else {
            return XCTFail("повторная неполная загрузка вышестоящего суда должна остаться partial")
        }
        events = try XCTUnwrap(semanticJournalEvents(store.record(forKey: record.key)?.eventJournal))
        XCTAssertEqual(events.map(\.kind), [.judgeChanged])
        XCTAssertEqual(
            store.record(forKey: record.key)?.eventJournal?.semanticBaselines?.courts.values
                .flatMap(\.instances).first(where: { $0.levelRaw == CaseInstance.Level.cassation.rawValue })?
                .judge,
            "Судья X",
            "failed higher-court scope keeps its last complete baseline")

        let completeFinal = try movement(rootJudge: "Судья B", higherJudge: "Судья Y")
        let completed = await center(store: store, movements: [completeFinal, completeFinal])
            .refresh(key: record.key)?.value
        XCTAssertEqual(completed?.outcome, .refreshed)
        events = try XCTUnwrap(semanticJournalEvents(store.record(forKey: record.key)?.eventJournal))
        let judgeChanges = events.filter { $0.kind == .judgeChanged }
        XCTAssertEqual(judgeChanges.count, 2)
        XCTAssertEqual(Set(judgeChanges.compactMap(\.evidence.previousValue)), ["Судья A", "Судья X"])
        XCTAssertEqual(Set(judgeChanges.compactMap(\.evidence.value)), ["Судья B", "Судья Y"])

        _ = await center(store: store, movements: [completeFinal]).refresh(key: record.key)?.value
        XCTAssertEqual(store.record(forKey: record.key)?.eventJournal?.events.filter {
            $0.kind == .judgeChanged
        }.count, 2)
    }

    func testMissingCoverageDoesNotConsumeChangeBeforeLaterCompleteFetch() async throws {
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        let initial = try movement(rootJudge: "Судья A")
        let record = try seed(store: store, context: context, movement: initial)
        _ = await center(store: store, movements: [initial]).refresh(key: record.key)?.value
        let baseline = store.record(forKey: record.key)?.eventJournal?.semanticBaselines

        let unproven = try movement(rootJudge: "Судья B", includeCoverage: false)
        let unprovenExecution = await center(store: store, movements: [unproven])
            .refresh(key: record.key)?.value
        XCTAssertEqual(unprovenExecution?.outcome, .refreshed)
        XCTAssertTrue(semanticJournalEvents(store.record(forKey: record.key)?.eventJournal)?.isEmpty == true)
        XCTAssertEqual(store.record(forKey: record.key)?.eventJournal?.semanticBaselines, baseline)

        let complete = try movement(rootJudge: "Судья B")
        _ = await center(store: store, movements: [complete]).refresh(key: record.key)?.value
        let events = try XCTUnwrap(semanticJournalEvents(store.record(forKey: record.key)?.eventJournal))
        XCTAssertEqual(events.map(\.kind), [.judgeChanged])
        XCTAssertEqual(events.first?.evidence.previousValue, "Судья A")
        XCTAssertEqual(events.first?.evidence.value, "Судья B")
    }

    func testJournalAppendAndSaveFailuresDoNotConsumeSemanticTransition() async throws {
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        let initial = try movement(rootJudge: "Судья A")
        let record = try seed(store: store, context: context, movement: initial)
        _ = await center(store: store, movements: [initial]).refresh(key: record.key)?.value
        let changed = try movement(rootJudge: "Судья B")
        let changedCenter = center(store: store, movements: [changed, changed, changed, changed])

        store.failNextJournalAppendForTesting = true
        let appendFailure = await changedCenter.refresh(key: record.key)?.value
        guard let appendFailure, case .failed = appendFailure.outcome else {
            return XCTFail("ошибка append должна откатить semantic transition")
        }
        assertUnconsumedJudgeChange(store: store, key: record.key, expectedJudge: "Судья A")

        store.failNextJournalEncodingForTesting = true
        let encodingFailure = await changedCenter.refresh(key: record.key)?.value
        guard let encodingFailure, case .failed = encodingFailure.outcome else {
            return XCTFail("ошибка encoding должна откатить semantic transition")
        }
        XCTAssertFalse(store.failNextJournalEncodingForTesting)
        assertUnconsumedJudgeChange(store: store, key: record.key, expectedJudge: "Судья A")

        store.failNextSaveForTesting = true
        let saveFailure = await changedCenter.refresh(key: record.key)?.value
        guard let saveFailure, case .failed = saveFailure.outcome else {
            return XCTFail("ошибка save должна откатить semantic transition")
        }
        XCTAssertFalse(store.failNextSaveForTesting)
        assertUnconsumedJudgeChange(store: store, key: record.key, expectedJudge: "Судья A")

        let success = await changedCenter.refresh(key: record.key)?.value
        XCTAssertEqual(success?.outcome, .refreshed)
        let events = try XCTUnwrap(semanticJournalEvents(store.record(forKey: record.key)?.eventJournal))
        XCTAssertEqual(events.map(\.kind), [.judgeChanged])
        XCTAssertEqual(events.first?.evidence.previousValue, "Судья A")
        XCTAssertEqual(events.first?.evidence.value, "Судья B")
    }

    func testLegacyFirstCompleteRefreshEstablishesBaselineSilently() async throws {
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        let initial = try movement(rootJudge: "Судья A")
        let record = try seed(store: store, context: context, movement: initial)
        record.eventJournal = nil
        try store.save()

        let first = await center(store: store, movements: [initial]).refresh(key: record.key)?.value
        XCTAssertEqual(first?.outcome, .refreshed)
        let journal = try XCTUnwrap(store.record(forKey: record.key)?.eventJournal)
        XCTAssertTrue(semanticJournalEvents(journal)?.isEmpty == true)
        XCTAssertNotNil(journal.semanticBaselines)

        let changed = try movement(rootJudge: "Судья B")
        _ = await center(store: store, movements: [changed]).refresh(key: record.key)?.value
        let events = try XCTUnwrap(semanticJournalEvents(store.record(forKey: record.key)?.eventJournal))
        XCTAssertEqual(events.map(\.kind), [.judgeChanged])
        XCTAssertEqual(events.first?.evidence.previousValue, "Судья A")
        XCTAssertEqual(events.first?.evidence.value, "Судья B")
    }

    func testMoscowAliasesKeepIndependentSemanticBaselinesOnSameHost() async throws {
        let store = TrackedStore(inMemory: true)
        let context = makeMoscowContext()
        let initial = try moscowMovement(tverskoyJudge: "Судья T1", hamovnikiJudge: "Судья H1")
        let record = try seed(store: store, context: context, movement: initial)
        let initialResult = await center(store: store, movements: [initial])
            .refresh(key: record.key)?.value
        XCTAssertEqual(initialResult?.outcome, .refreshed)

        let partial = try moscowMovement(
            tverskoyJudge: "Судья T2", hamovnikiJudge: "Судья H1",
            hamovnikiCoverageKind: .partial, incompleteDomains: ["mos-gorsud.ru"])
        let partialResult = await center(store: store, movements: [partial])
            .refresh(key: record.key)?.value
        guard let partialResult, case .partial = partialResult.outcome else {
            return XCTFail("ошибка одного алиаса должна оставить обновление partial")
        }
        var events = try XCTUnwrap(semanticJournalEvents(store.record(forKey: record.key)?.eventJournal))
        XCTAssertEqual(events.map(\.kind), [.judgeChanged])
        XCTAssertEqual(events.first?.evidence.previousValue, "Судья T1")
        XCTAssertEqual(events.first?.evidence.value, "Судья T2")

        let final = try moscowMovement(tverskoyJudge: "Судья T2", hamovnikiJudge: "Судья H2")
        let finalResult = await center(store: store, movements: [final])
            .refresh(key: record.key)?.value
        XCTAssertEqual(finalResult?.outcome, .refreshed)
        events = try XCTUnwrap(semanticJournalEvents(store.record(forKey: record.key)?.eventJournal))
        let changes = events.filter { $0.kind == .judgeChanged }
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(Set(changes.compactMap(\.evidence.previousValue)), ["Судья H1", "Судья T1"])
        XCTAssertEqual(Set(changes.compactMap(\.evidence.value)), ["Судья H2", "Судья T2"])
    }

    func testUnknownSharedMoscowFailureWithholdsCourtAndGlobalChangesUntilComplete() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-262-moscow-unknown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let context = makeMoscowContext()
        let initial = try moscowMovement(
            tverskoyJudge: "Судья T1", hamovnikiJudge: "Судья H1")
        let initialSnapshot = MovementDerivation.snapshot(from: initial, context: context)
        XCTAssertTrue(initialSnapshot.deadlines.isEmpty,
                      "without a dated final-form session there is no global deadline baseline")
        let record = try seed(store: store, context: context, movement: initial)
        let key = record.key
        let initialResult = await center(store: store, movements: [initial])
            .refresh(key: key)?.value
        XCTAssertEqual(initialResult?.outcome, .refreshed)
        let oldGlobal = try XCTUnwrap(store.record(forKey: key)?.eventJournal?.semanticBaselines?.global)

        let unknownSharedFailure = try moscowMovement(
            tverskoyJudge: "Судья T2", hamovnikiJudge: "Судья H2", inForce: true,
            decisionDate: "01.10.2026", includeUnscopedFailure: true,
            incompleteDomains: ["mos-gorsud.ru"])
        let pendingDeadlineSnapshot = MovementDerivation.snapshot(
            from: unknownSharedFailure, context: context)
        XCTAssertFalse(pendingDeadlineSnapshot.deadlines.isEmpty,
                       "a dated decision and its final form should produce a pending global deadline; assessments: \(String(describing: pendingDeadlineSnapshot.deadlineAssessments))")
        let partial = await center(store: store, movements: [unknownSharedFailure])
            .refresh(key: key)?.value
        guard let partial, case .partial = partial.outcome else {
            return XCTFail("неизвестная ошибка общего хоста Москвы должна сохранить partial outcome")
        }
        XCTAssertTrue(store.record(forKey: key)?.eventJournal?.events.isEmpty == true)
        XCTAssertEqual(store.record(forKey: key)?.eventJournal?.semanticBaselines?.global, oldGlobal,
                       "unscoped shared-host failure must not consume entry-into-force or deadline transitions")
        XCTAssertTrue(oldGlobal.deadlines.isEmpty)

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        XCTAssertEqual(reopened.record(forKey: key)?.eventJournal?.semanticBaselines?.global, oldGlobal)
        let complete = try moscowMovement(
            tverskoyJudge: "Судья T2", hamovnikiJudge: "Судья H2", inForce: true,
            decisionDate: "01.10.2026")
        let completeCenter = center(store: reopened, movements: [complete, complete])

        let firstComplete = await completeCenter.refresh(key: key)?.value
        XCTAssertEqual(firstComplete?.outcome, .refreshed)
        var events = try XCTUnwrap(reopened.record(forKey: key)?.eventJournal?.events)
        XCTAssertEqual(events.filter { $0.kind == .judgeChanged }.count, 2)
        XCTAssertEqual(Set(events.map(\.kind)),
                       [.judgeChanged, .deadlineProposed, .entryIntoForceRecorded])
        let completeGlobal = try XCTUnwrap(
            reopened.record(forKey: key)?.eventJournal?.semanticBaselines?.global)
        XCTAssertTrue(completeGlobal.inForce)
        XCTAssertEqual(completeGlobal.deadlines, pendingDeadlineSnapshot.deadlines)

        let repeatedComplete = await completeCenter.refresh(key: key)?.value
        XCTAssertEqual(repeatedComplete?.outcome, .refreshed)
        events = try XCTUnwrap(reopened.record(forKey: key)?.eventJournal?.events)
        XCTAssertEqual(events.filter { $0.kind == .entryIntoForceRecorded }.count, 1)
        XCTAssertEqual(events.filter { $0.kind == .deadlineProposed }.count, 1)
    }

    func testConfirmedEmptyHigherCourtAllowsGlobalChangesAcrossDiskReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-262-empty-higher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let context = makeMoscowContext()
        func withEmptyHigherCourt(_ movement: CaseMovement) -> CaseMovement {
            var result = movement
            result.honestZeroDomains = ["vs.komi.sudrf.ru"]
            result.sourceRefreshCoverage?.append(MovementCourtCoverage(
                sourceFamily: "sudrf", courtKey: "vs.komi.sudrf.ru", kind: .honestZero))
            return result
        }
        let initial = withEmptyHigherCourt(try moscowMovement(
            tverskoyJudge: "Судья T1", hamovnikiJudge: "Судья H1"))
        let record = try seed(store: store, context: context, movement: initial)
        let key = record.key
        let successTime = try XCTUnwrap(DateUtil.parse("01.09.2026"))
        record.movementFetchedAt = successTime
        try store.save()
        let initialResult = await center(store: store, movements: [initial]).refresh(key: key)?.value
        guard let initialResult, case .partial = initialResult.outcome else {
            return XCTFail("legacy empty-listing outcome remains partial")
        }
        XCTAssertNotNil(store.record(forKey: key)?.eventJournal?.semanticBaselines?.global)
        XCTAssertEqual(store.record(forKey: key)?.movementFetchedAt, successTime)

        let reopenedContainer = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        let complete = withEmptyHigherCourt(try moscowMovement(
            tverskoyJudge: "Судья T1", hamovnikiJudge: "Судья H1", inForce: true,
            decisionDate: "01.10.2026"))
        let refreshCenter = center(store: reopened, movements: [complete, complete])
        _ = await refreshCenter.refresh(key: key)?.value
        let once = try XCTUnwrap(reopened.record(forKey: key)?.eventJournal?.events)
        XCTAssertEqual(Set(once.map(\.kind)), [.entryIntoForceRecorded, .deadlineProposed])
        XCTAssertEqual(once.count, 2)
        XCTAssertEqual(reopened.record(forKey: key)?.movementFetchedAt, successTime)
        _ = await refreshCenter.refresh(key: key)?.value
        XCTAssertEqual(reopened.record(forKey: key)?.eventJournal?.events, once)
    }

    func testEmptySearchConflictingWithUnloadedSavedCardWithholdsGlobalFacts() async throws {
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        let initial = try movement(rootJudge: "Судья A", higherJudge: "Судья X")
        let record = try seed(store: store, context: context, movement: initial)
        _ = await center(store: store, movements: [initial]).refresh(key: record.key)?.value
        let oldGlobal = store.record(forKey: record.key)?.eventJournal?.semanticBaselines?.global
        var empty = try movement(rootJudge: "Судья B")
        empty.inForce = true
        empty.honestZeroDomains = ["2kas.sudrf.ru"]
        empty.sourceRefreshCoverage?.append(MovementCourtCoverage(
            sourceFamily: "sudrf", courtKey: "2kas.sudrf.ru", kind: .honestZero))
        _ = await center(store: store, movements: [empty]).refresh(key: record.key)?.value
        XCTAssertEqual(semanticJournalEvents(store.record(forKey: record.key)?.eventJournal)?.map(\.kind), [.judgeChanged])
        XCTAssertEqual(store.record(forKey: record.key)?.eventJournal?.semanticBaselines?.global, oldGlobal)
        XCTAssertTrue(store.record(forKey: record.key)?.movement?.instances.contains {
            $0.caseNumber == "88-262/2026" && $0.judge == "Судья X"
        } == true)
        var complete = try movement(rootJudge: "Судья B", higherJudge: "Судья X")
        complete.inForce = true
        _ = await center(store: store, movements: [complete]).refresh(key: record.key)?.value
        XCTAssertEqual(Set(semanticJournalEvents(store.record(forKey: record.key)?.eventJournal)?.map(\.kind) ?? []),
                       [.judgeChanged, .entryIntoForceRecorded])
    }

    func testAtomicMergePreservesPendingCourtBaselinesAcrossDiskReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-262-merge-pending-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let rootContext = makeContext()
        let higherContext = makeHigherContext()
        let rootRecord = try store.upsert(context: rootContext, snapshot: nil, collections: ["Регрессия #262"])
        let higherRecord = try store.upsert(context: higherContext, snapshot: nil, collections: ["Регрессия #262"])
        XCTAssertEqual(store.all().count, 2)

        let rootBaselineMovement = try movement(rootJudge: "Судья A")
        var rootJournal = try XCTUnwrap(rootRecord.eventJournal)
        rootJournal.semanticBaselines = semanticTransition(
            journal: rootJournal, movement: rootBaselineMovement, context: rootContext,
            isComplete: true).baselines
        let rootPendingMovement = try movement(
            rootJudge: "Судья B", rootCoverageKind: .partial,
            incompleteDomains: [rootContext.searchDomain])
        rootJournal.semanticBaselines = semanticTransition(
            journal: rootJournal, movement: rootPendingMovement, context: rootContext,
            isComplete: false).baselines
        rootRecord.eventJournal = rootJournal
        rootRecord.movement = MovementCachePolicy.stripped(forPersist: rootPendingMovement)
        rootRecord.snapshot = MovementDerivation.snapshot(from: rootPendingMovement, context: rootContext)

        let higherBaselineMovement = try movement(
            rootJudge: "Судья B", rootCoverageKind: nil, higherJudge: "Судья X")
        var higherJournal = try XCTUnwrap(higherRecord.eventJournal)
        higherJournal.semanticBaselines = semanticTransition(
            journal: higherJournal, movement: higherBaselineMovement, context: higherContext,
            isComplete: false).baselines
        let higherPendingMovement = try movement(
            rootJudge: "Судья B", rootCoverageKind: nil, higherJudge: "Судья Y",
            higherCoverageKind: .partial, incompleteDomains: ["2kas.sudrf.ru"])
        higherJournal.semanticBaselines = semanticTransition(
            journal: higherJournal, movement: higherPendingMovement, context: higherContext,
            isComplete: false).baselines
        higherRecord.eventJournal = higherJournal
        higherRecord.movement = MovementCachePolicy.stripped(forPersist: higherPendingMovement)
        higherRecord.snapshot = MovementDerivation.snapshot(from: higherPendingMovement, context: higherContext)
        try store.save()

        _ = try TrackedCaseRepairCoordinator.atomicMerge(
            store: store, survivor: rootRecord, duplicates: [higherRecord],
            canonicalContext: rootContext, canonicalCard: nil)
        XCTAssertEqual(store.all().count, 1)
        let merged = try XCTUnwrap(rootRecord.eventJournal?.semanticBaselines)
        let rootNative = try rootIdentity(rootContext)
        let rootScope = rootNative.sourceFamily + "|" + rootNative.courtKey
        let higherNative = try higherIdentity()
        let higherScope = higherNative.sourceFamily + "|" + higherNative.courtKey
        XCTAssertEqual(merged.courts[rootScope]?.instances.first?.judge, "Судья A")
        XCTAssertEqual(merged.courts[higherScope]?.instances.first?.judge, "Судья X")
        XCTAssertFalse(merged.conflictingCourts.contains(rootScope))
        XCTAssertFalse(merged.conflictingCourts.contains(higherScope))

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        let reopenedRecord = try XCTUnwrap(reopened.record(forKey: rootRecord.key))
        let persisted = try XCTUnwrap(reopenedRecord.eventJournal?.semanticBaselines)
        XCTAssertEqual(persisted.courts[rootScope]?.instances.first?.judge, "Судья A")
        XCTAssertEqual(persisted.courts[higherScope]?.instances.first?.judge, "Судья X")

        let complete = try movement(rootJudge: "Судья B", higherJudge: "Судья Y")
        let completeCenter = center(store: reopened, movements: [complete, complete])
        let completed = await completeCenter.refresh(key: rootRecord.key)?.value
        XCTAssertEqual(completed?.outcome, .refreshed)
        let events = try XCTUnwrap(reopened.record(forKey: rootRecord.key)?.eventJournal?.events)
        let changes = events.filter { $0.kind == .judgeChanged }
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(Set(changes.compactMap(\.evidence.previousValue)), ["Судья A", "Судья X"])
        XCTAssertEqual(Set(changes.compactMap(\.evidence.value)), ["Судья B", "Судья Y"])
    }

    func testAtomicMergeConflictSurvivesDiskReopenAndReseedsSilently() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-262-merge-conflict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let context = makeContext()
        let duplicateContext = makeConflictContext()
        let first = try store.upsert(context: context, snapshot: nil, collections: [])
        let duplicate = try store.upsert(context: duplicateContext, snapshot: nil, collections: [])
        XCTAssertEqual(store.all().count, 2)

        let baselineA = try movement(rootJudge: "Судья A")
        let baselineC = try movement(rootJudge: "Судья C")
        var firstJournal = try XCTUnwrap(first.eventJournal)
        firstJournal.semanticBaselines = semanticTransition(
            journal: firstJournal, movement: baselineA, context: context,
            isComplete: true).baselines
        first.eventJournal = firstJournal
        var duplicateJournal = try XCTUnwrap(duplicate.eventJournal)
        duplicateJournal.semanticBaselines = semanticTransition(
            journal: duplicateJournal, movement: baselineC, context: context,
            isComplete: true).baselines
        duplicate.eventJournal = duplicateJournal
        try store.save()

        _ = try TrackedCaseRepairCoordinator.atomicMerge(
            store: store, survivor: first, duplicates: [duplicate],
            canonicalContext: context, canonicalCard: nil)
        XCTAssertEqual(store.all().count, 1)
        let native = try rootIdentity(context)
        let scope = native.sourceFamily + "|" + native.courtKey
        XCTAssertNil(first.eventJournal?.semanticBaselines?.courts[scope])
        XCTAssertEqual(first.eventJournal?.semanticBaselines?.conflictingCourts, [scope])

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        let reopenedRecord = try XCTUnwrap(reopened.record(forKey: first.key))
        XCTAssertNil(reopenedRecord.eventJournal?.semanticBaselines?.courts[scope])
        XCTAssertEqual(reopenedRecord.eventJournal?.semanticBaselines?.conflictingCourts, [scope])

        let seed = try movement(rootJudge: "Судья B")
        let seeded = await center(store: reopened, movements: [seed])
            .refresh(key: first.key)?.value
        XCTAssertEqual(seeded?.outcome, .refreshed)
        XCTAssertTrue(reopenedRecord.eventJournal?.events.isEmpty == true,
                      "one full refresh after conflicting history seeds a fresh baseline silently")
        XCTAssertEqual(reopenedRecord.eventJournal?.semanticBaselines?.courts[scope]?.instances.first?.judge,
                       "Судья B")
        XCTAssertFalse(reopenedRecord.eventJournal?.semanticBaselines?.conflictingCourts.contains(scope) ?? true)

        let changed = try movement(rootJudge: "Судья D")
        let refreshed = await center(store: reopened, movements: [changed])
            .refresh(key: first.key)?.value
        XCTAssertEqual(refreshed?.outcome, .refreshed)
        let events = try XCTUnwrap(reopenedRecord.eventJournal?.events)
        XCTAssertEqual(events.map(\.kind), [.judgeChanged])
        XCTAssertEqual(events.first?.evidence.previousValue, "Судья B")
        XCTAssertEqual(events.first?.evidence.value, "Судья D")
    }

    func testMovementServiceCoverageFeedsRefreshCenterSemanticJournal() async throws {
        let store = TrackedStore(inMemory: true)
        let context = makeContext()
        let record = try store.upsert(context: context, snapshot: nil, collections: [])
        let firstCard = CaseCard(rawText: "card A", actText: nil, judge: "Судья A",
                                 result: "Иск удовлетворён", caseNumber: context.caseNumber)
        let directService = MovementService(client: Issue262CaseClient([firstCard]))
        let directMovement = try await directService.movement(
            for: context.baseResult, court: context.searchCourt,
            cartoteka: try XCTUnwrap(context.cartoteka))
        let coverage = try XCTUnwrap(directMovement.sourceRefreshCoverage)
        XCTAssertEqual(coverage.map(\.kind), [.usableSnapshot])
        XCTAssertEqual(coverage.first?.loadedCardIdentities.count, 1)
        XCTAssertEqual(coverage.first?.loadedCardIdentities.first?.sourceNativeID, context.caseID)

        let cards = Issue262CaseClient([
            firstCard,
            CaseCard(rawText: "card B", actText: nil, judge: "Судья B",
                     result: "Иск удовлетворён", caseNumber: context.caseNumber)
        ])
        let movementService = MovementService(client: cards)
        let refreshCenter = RefreshCenter(
            store: store, client: SudrfClient(),
            serviceBuilder: { _ in movementService })

        let first = await refreshCenter.refresh(key: record.key)?.value
        XCTAssertEqual(first?.outcome, .refreshed)
        XCTAssertTrue(semanticJournalEvents(store.record(forKey: record.key)?.eventJournal)?.isEmpty == true)

        let second = await refreshCenter.refresh(key: record.key)?.value
        XCTAssertEqual(second?.outcome, .refreshed)
        let events = try XCTUnwrap(semanticJournalEvents(store.record(forKey: record.key)?.eventJournal))
        XCTAssertEqual(events.map(\.kind), [.judgeChanged])
        XCTAssertEqual(events.first?.evidence.previousValue, "Судья A")
        XCTAssertEqual(events.first?.evidence.value, "Судья B")
    }

    private func assertUnconsumedJudgeChange(store: TrackedStore, key: String,
                                             expectedJudge: String) {
        let saved = store.record(forKey: key)
        XCTAssertEqual(saved?.movement?.instances.first?.judge, expectedJudge)
        XCTAssertTrue(semanticJournalEvents(saved?.eventJournal)?.isEmpty == true)
        XCTAssertEqual(
            saved?.eventJournal?.semanticBaselines?.courts.values.first?.instances.first?.judge,
            expectedJudge)
    }

    private func seed(store: TrackedStore, context: MovementContext,
                      movement: CaseMovement) throws -> TrackedCaseRecord {
        try store.upsert(context: context,
                         snapshot: MovementDerivation.snapshot(from: movement, context: context),
                         movement: movement, collections: ["Регрессия #262"])
    }

    private func center(store: TrackedStore, movements: [CaseMovement]) -> RefreshCenter {
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in Issue262MovementSequence(movements) })
        retainedCenters.append(center)
        return center
    }

    private func makeContext() -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue,
            region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS0001",
            cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-262/2026",
            caseID: "issue-262-root-card",
            caseUID: "card-link-guid",
            judicialUID: uid)
    }

    private func makeMoscowContext() -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue,
            region: "Москва",
            searchDomain: "mos-gorsud.ru",
            displayDomain: "mos-gorsud.ru",
            courtTitle: "Тверской районный суд",
            courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "77RS0027",
            cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-262/2026",
            caseID: "moscow-root-card",
            caseUID: "moscow-case-guid",
            judicialUID: uid)
    }

    private func makeHigherContext() -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue,
            region: "Республика Коми",
            searchDomain: "2kas.sudrf.ru",
            displayDomain: "2kas.sudrf.ru",
            courtTitle: "Второй кассационный суд общей юрисдикции",
            courtLevelRaw: CourtLevel.cassation.rawValue,
            courtCode: "11KS0001",
            cartotekaId: "g3",
            cartotekaLevelRaw: CourtLevel.cassation.rawValue,
            caseNumber: "88-262/2026",
            caseID: "issue-262-higher-card",
            caseUID: "higher-guid",
            judicialUID: "11RS0001-01-2026-000263-11")
    }

    private func makeConflictContext() -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue,
            region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS0001",
            cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-263/2026",
            caseID: "issue-262-conflicting-card",
            caseUID: "conflicting-guid",
            judicialUID: "11RS0001-01-2026-000263-11")
    }

    private func rootIdentity(_ context: MovementContext) throws -> SourceNativeCardIdentity {
        let cart = try XCTUnwrap(context.cartoteka)
        return try XCTUnwrap(SourceNativeCardLocator.sudrf(
            court: context.searchCourt, cartoteka: cart,
            caseID: try XCTUnwrap(context.caseID))).identity
    }

    private func higherIdentity() throws -> SourceNativeCardIdentity {
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .cassation, id: "g3"))
        return try XCTUnwrap(SourceNativeCardLocator.sudrf(
            url: higherCardURL(), cartoteka: cart)).identity
    }

    private func higherCardURL() -> URL {
        URL(string: "https://2kas.sudrf.ru/modules.php?name=sud_delo&name_op=case"
            + "&case_id=issue-262-higher-card&case_uid=higher-guid"
            + "&delo_id=2800001&new=2800001&srv_num=1")!
    }

    private func siblingCardURL() -> URL {
        URL(string: "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case"
            + "&case_id=issue-262-sibling-card&case_uid=sibling-guid"
            + "&delo_id=1540005&new=0&srv_num=1")!
    }

    private func siblingIdentity() throws -> SourceNativeCardIdentity {
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        return try XCTUnwrap(SourceNativeCardLocator.sudrf(
            url: siblingCardURL(), cartoteka: cart)).identity
    }

    private func sameCourtMultiCardMovement(
        rootJudge: String, siblingJudge: String?,
        coverageKind: SourceOutcomeKind = .usableSnapshot,
        incompleteDomains: [String]? = nil
    ) throws -> CaseMovement {
        let context = makeContext()
        var instances = [CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: rootJudge, domain: context.searchDomain, foundByUID: false,
            result: "Иск удовлетворён", sessions: [])]
        if let siblingJudge {
            instances.append(CaseInstance(
                level: .first, court: context.courtTitle, caseNumber: "2-263/2026",
                judge: siblingJudge, domain: context.searchDomain, foundByUID: true,
                result: "Иск удовлетворён", sessions: [], sourceURL: siblingCardURL()))
        }
        let root = try rootIdentity(context)
        let loaded = siblingJudge == nil ? [root] : [root, try siblingIdentity()]
        let coverage = MovementCourtCoverage(
            sourceFamily: root.sourceFamily, courtKey: root.courtKey,
            kind: coverageKind, loadedCardIdentities: loaded)
        return CaseMovement(
            uid: uid, caseNumber: context.caseNumber, inForce: false,
            instances: instances, complaints: [:], acts: [],
            incompleteHigherCourtDomains: incompleteDomains,
            sourceRefreshCoverage: [coverage])
    }

    private func movement(rootJudge: String,
                          rootCoverageKind: SourceOutcomeKind? = .usableSnapshot,
                          higherJudge: String? = nil,
                          higherCoverageKind: SourceOutcomeKind = .usableSnapshot,
                          coverHigherScope: Bool = false,
                          includeCoverage: Bool = true,
                          incompleteDomains: [String]? = nil) throws -> CaseMovement {
        let context = makeContext()
        var instances = [CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: rootJudge, domain: context.searchDomain, foundByUID: false,
            result: "Иск удовлетворён",
            sessions: [CaseSession(date: "01.08.2026", event: "Судебное заседание",
                                   result: "Иск удовлетворён")])]
        if let higherJudge {
            instances.append(CaseInstance(
                level: .cassation, court: "Второй кассационный суд общей юрисдикции",
                caseNumber: "88-262/2026", judge: higherJudge, domain: "2kas.sudrf.ru",
                foundByUID: true, result: "Оставлено без изменения", sessions: [],
                sourceURL: higherCardURL()))
        }
        var coverage: [MovementCourtCoverage] = []
        if includeCoverage, let rootCoverageKind {
            coverage.append(makeCoverage(try rootIdentity(context), kind: rootCoverageKind))
        }
        if includeCoverage, higherJudge != nil || coverHigherScope {
            coverage.append(makeCoverage(try higherIdentity(), kind: higherCoverageKind))
        }
        return CaseMovement(
            uid: uid, caseNumber: context.caseNumber, inForce: false,
            instances: instances, complaints: [:], acts: [],
            incompleteHigherCourtDomains: incompleteDomains,
            sourceRefreshCoverage: includeCoverage ? coverage : nil)
    }

    private func makeCoverage(_ identity: SourceNativeCardIdentity,
                             kind: SourceOutcomeKind) -> MovementCourtCoverage {
        MovementCourtCoverage(sourceFamily: identity.sourceFamily,
                              courtKey: identity.courtKey, kind: kind,
                              loadedCardIdentities: [identity])
    }

    private func moscowMovement(tverskoyJudge: String, hamovnikiJudge: String,
                                tverskoyCoverageKind: SourceOutcomeKind = .usableSnapshot,
                                hamovnikiCoverageKind: SourceOutcomeKind = .usableSnapshot,
                                inForce: Bool = false,
                                decisionDate: String? = nil,
                                includeUnscopedFailure: Bool = false,
                                incompleteDomains: [String]? = nil) throws -> CaseMovement {
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        let tverskoyURL = URL(string:
            "https://mos-gorsud.ru/rs/tverskoj/services/cases/first-civil/details/"
                + "49e1e932-ca18-4a54-9797-987d15209322")!
        let hamovnikiURL = URL(string:
            "https://mos-gorsud.ru/rs/hamovnicheskij/services/cases/first-civil/details/"
                + "11111111-1111-4111-8111-111111111111")!
        let tverskoyID = try XCTUnwrap(SourceNativeCardLocator.mosgorsud(
            url: tverskoyURL, cartoteka: cart)).identity
        let hamovnikiID = try XCTUnwrap(SourceNativeCardLocator.mosgorsud(
            url: hamovnikiURL, cartoteka: cart)).identity
        let rootSessions = decisionDate.map { date in
            [CaseSession(date: "30.09.2026", event: "Судебное заседание",
                         result: "Вынесено решение по делу"),
             CaseSession(date: date,
                         event: "Изготовлено мотивированное решение в окончательной форме")]
        } ?? []
        var tverskoy = CaseInstance(level: .first, court: "Тверской районный суд",
                                    caseNumber: "2-262/2026", judge: tverskoyJudge,
                                    domain: "mos-gorsud.ru", foundByUID: false,
                                    result: "Иск удовлетворён; решение принято в окончательной форме",
                                    sessions: rootSessions, sourceURL: tverskoyURL)
        tverskoy.sourceEvidence = .init(
            decisionDate: decisionDate, cartotekaID: "g1", sourceCourtLevel: .district,
            sourceBranch: .general, category: "Споры из договоров", ownProcessKind: .civil)
        let hamovniki = CaseInstance(level: .first, court: "Хамовнический районный суд",
                                     caseNumber: "2-263/2026", judge: hamovnikiJudge,
                                     domain: "mos-gorsud.ru", foundByUID: true,
                                     result: "Иск удовлетворён", sessions: [],
                                     sourceURL: hamovnikiURL)
        let instances = [tverskoy, hamovniki]
        return CaseMovement(
            uid: uid, caseNumber: "2-262/2026", inForce: inForce,
            instances: instances, complaints: [:], acts: [],
            category: "Споры из договоров",
            incompleteHigherCourtDomains: incompleteDomains,
            sourceRefreshCoverage: [
                makeCoverage(tverskoyID, kind: tverskoyCoverageKind),
                makeCoverage(hamovnikiID, kind: hamovnikiCoverageKind)
            ] + (includeUnscopedFailure ? [MovementCourtCoverage(
                sourceFamily: "mosgorsud", courtKey: "mos-gorsud.ru", kind: .partial)] : []))
    }

    private func semanticTransition(journal: CaseEventJournal, movement: CaseMovement,
                                    context: MovementContext, isComplete: Bool)
        -> (baselines: CaseEventBaselines?, derivation: CaseEventDerivationResult) {
        let admitted = CaseEventSourceAdmission.courts(in: movement, context: context)
        let chainConfirmed = CaseEventSourceAdmission.chainIsConfirmed(
            in: movement, context: context, admitted: admitted)
        let complete = isComplete && chainConfirmed
        let provenance = SourceProvenance(
            operation: .movement,
            sourceFamily: movement.sourceRefreshCoverage?.first?.sourceFamily ?? "sudrf",
            host: context.searchDomain)
        let snapshot = MovementDerivation.snapshot(from: movement, context: context)
        return CaseEventBaselineTransition.refresh(
            journal: journal, freshSnapshot: snapshot, globalSnapshot: snapshot,
            admittedCourts: admitted,
            attempt: SourceAttempt(kind: complete ? .usableSnapshot : .partial,
                                   provenance: provenance),
            isComplete: complete)
    }
}
