import XCTest
import SudrfKit
@testable import SudrfApp

@MainActor
final class CaseCardRecoveryIntegrationTests: XCTestCase {
    private actor ParserFailure: MovementProviding {
        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            throw SudrfError.parsing("stale card")
        }
    }

    private actor ParserThenSuccess: MovementProviding {
        let value: CaseMovement
        private(set) var calls = 0

        init(_ value: CaseMovement) { self.value = value }

        func movement(for base: CaseSearchResult, court: Court,
                      cartoteka: Cartoteka) async throws -> CaseMovement {
            calls += 1
            if calls == 1 { throw SudrfError.parsing("stale card") }
            return value
        }
    }

    private actor SuspendedResolution {
        private var started: CheckedContinuation<Void, Never>?
        private var pending: CheckedContinuation<CaseCardRecoveryResolution, Never>?

        func resolve() async -> CaseCardRecoveryResolution {
            await withCheckedContinuation {
                pending = $0
                started?.resume()
                started = nil
            }
        }

        func waitUntilStarted() async {
            guard pending == nil else { return }
            await withCheckedContinuation { started = $0 }
        }

        func release(_ resolution: CaseCardRecoveryResolution) {
            pending?.resume(returning: resolution); pending = nil
        }
    }

    private func context(url: String? = nil) -> MovementContext {
        var value = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru", displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS0001", cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-100/2026", caseID: "old", caseUID: "old-link", cardURLString: url)
        value.sourceKnownCard = KnownCard(domain: value.searchDomain, courtTitle: value.courtTitle,
                                           caseID: "old", caseUID: "old-link", deloID: "5", new: "5",
                                           caseNumber: value.caseNumber, levelRaw: CaseInstance.Level.first.rawValue,
                                           cartotekaID: value.cartotekaId)
        return value
    }

    private func resolution(from original: MovementContext) throws -> CaseCardRecoveryResolution {
        var verified = original
        verified.cardURLString = "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&case_id=old&case_uid=old-link&delo_id=1540005&new=0"
        verified.sourceKnownCard = KnownCard(domain: verified.searchDomain, courtTitle: verified.courtTitle,
                                              caseID: "old", caseUID: "old-link", deloID: "1540005", new: "0",
                                              caseNumber: verified.caseNumber,
                                              levelRaw: CaseInstance.Level.first.rawValue,
                                              cartotekaID: verified.cartotekaId)
        return CaseCardRecoveryResolution(
            card: CaseCard(rawText: "", actText: nil, caseNumber: verified.caseNumber),
            verifiedURL: try XCTUnwrap(URL(string: verified.cardURLString!)),
            reason: .cartotekaParameters, context: verified)
    }

    private func movement(for value: MovementContext) -> CaseMovement {
        let instance = CaseInstance(level: .first, court: value.courtTitle,
                                    caseNumber: value.caseNumber, judge: nil,
                                    domain: value.searchDomain, foundByUID: false,
                                    result: "Решение", sessions: [])
        return CaseMovement(uid: "", caseNumber: value.caseNumber, inForce: false,
                            instances: [instance], complaints: [:], acts: [])
    }

    func testRecoveredLocatorRollbackRestoresContextAndIdentity() throws {
        struct ProjectionFailure: Error {}
        var fail = false
        let store = TrackedStore(inMemory: true) { context, scope in
            if fail { throw ProjectionFailure() }
            try CourtActProjectionSynchronizer.synchronize(context: context, scope: scope)
        }
        let original = context(url: "https://syktsud--komi.sudrf.ru/modules.php?case_id=old&case_uid=old-link&delo_id=5&new=5")
        let record = try store.upsert(context: original, snapshot: nil, movement: nil, collections: ["Import"])
        let previousIdentity = TrackedCaseIdentity.state(for: record)
        let repaired = try resolution(from: original)
        fail = true

        XCTAssertThrowsError(try store.applyVerifiedCardContext(
            forLocator: record.key, context: repaired.context,
            attempt: SourceAttempt(kind: .usableSnapshot,
                                   provenance: SourceProvenance(operation: .discovery,
                                                                sourceFamily: "sudrf", host: original.searchDomain))))
        XCTAssertEqual(store.record(forKey: record.key)?.context, original)
        XCTAssertEqual(TrackedCaseIdentity.state(for: try XCTUnwrap(store.record(forKey: record.key))),
                       previousIdentity)
        XCTAssertEqual(store.record(forKey: record.key)?.collectionNames, ["Import"])
    }

    func testRecoveredActiveLocatorRemovesStaleKnownCard() throws {
        let store = TrackedStore(inMemory: true)
        var original = context(url: "https://syktsud--komi.sudrf.ru/modules.php?case_id=old&case_uid=old-link&delo_id=5&new=5")
        original.knownCards = [try XCTUnwrap(original.sourceKnownCard)]
        let record = try store.upsert(context: original, snapshot: nil, movement: nil, collections: [])
        let repaired = try resolution(from: original)

        let saved = try XCTUnwrap(store.applyVerifiedCardContext(
            forLocator: record.key, context: repaired.context,
            attempt: SourceAttempt(kind: .usableSnapshot,
                                   provenance: SourceProvenance(operation: .discovery,
                                                                sourceFamily: "sudrf", host: original.searchDomain))))

        XCTAssertEqual(saved.context?.sourceKnownCard, repaired.context.sourceKnownCard)
        XCTAssertEqual(saved.context?.knownCards, [])
    }

    func testDeletedRecordDuringResolverIsNotRecreated() async throws {
        let store = TrackedStore(inMemory: true)
        let original = context(url: "https://syktsud--komi.sudrf.ru/modules.php?case_id=old&case_uid=old-link&delo_id=5&new=5")
        let record = try store.upsert(context: original, snapshot: nil, movement: nil, collections: [])
        let suspended = SuspendedResolution()
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in ParserFailure() })
        center.recoverCard = { _ in await suspended.resolve() }

        let task = center.refresh(key: record.key)!
        await suspended.waitUntilStarted()
        try store.remove(key: record.key)
        await suspended.release(try resolution(from: original))
        let execution = await task.value

        XCTAssertNil(store.record(forKey: record.key))
        XCTAssertEqual(execution.outcome, .notFound)
    }

    func testOriginalURLResolverRetriesMovementOnceWithoutReplacingLocator() async throws {
        let store = TrackedStore(inMemory: true)
        let original = context(url: "https://syktsud--komi.sudrf.ru/modules.php?case_id=old&case_uid=old-link&delo_id=1540005&new=0")
        let record = try store.upsert(context: original, snapshot: nil, movement: nil, collections: [])
        let service = ParserThenSuccess(movement(for: original))
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in service })
        center.recoverCard = { context in
            var enriched = context
            enriched.judge = "Из карточки"
            return CaseCardRecoveryResolution(
                card: CaseCard(rawText: "", actText: nil, judge: enriched.judge,
                               caseNumber: enriched.caseNumber),
                verifiedURL: try XCTUnwrap(URL(string: enriched.cardURLString!)),
                reason: .originalURL, context: enriched)
        }

        let execution = await center.refresh(key: record.key)?.value
        let calls = await service.calls

        XCTAssertEqual(execution?.outcome, .refreshed)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.record(forKey: record.key)?.context?.cardURLString, original.cardURLString)
        XCTAssertEqual(store.record(forKey: record.key)?.context?.caseID, original.caseID)
    }

    func testReimportAfterFailureDoesNotDowngradeRecoveredLocator() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let stale = context(url: "https://syktsud--komi.sudrf.ru/modules.php?case_id=old&case_uid=old-link&delo_id=5&new=5")
        let healed = try resolution(from: stale).context
        let success = SourceAttempt(kind: .usableSnapshot,
                                    provenance: SourceProvenance(operation: .discovery,
                                                                 sourceFamily: "sudrf",
                                                                 host: stale.searchDomain))
        _ = try router.commitImport(records: [CaseImporter.PlannedRecord(
            context: healed, isMaterial: false, sourceRows: [],
            originalContext: stale, sourceAttempt: success)], collection: "First")

        let failed = SourceAttempt(kind: .maintenance,
                                   provenance: SourceProvenance(operation: .discovery,
                                                                sourceFamily: "sudrf",
                                                                host: stale.searchDomain))
        _ = try router.commitImport(records: [CaseImporter.PlannedRecord(
            context: stale, isMaterial: false, sourceRows: [], sourceAttempt: failed)],
                                    collection: "Repeated")
        router.reload()
        router.openCase(key: stale.key)

        XCTAssertEqual(router.openCaseSourceURL?.absoluteString, healed.cardURLString)
    }

    func testSameDisplayLocatorKeepsDistinctSourceCardsSeparate() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let stale = context(url: "https://syktsud--komi.sudrf.ru/modules.php?case_id=old&case_uid=old-link&delo_id=5&new=5")
        let healed = try resolution(from: stale).context
        let success = SourceAttempt(
            kind: .usableSnapshot,
            provenance: SourceProvenance(operation: .discovery, sourceFamily: "sudrf",
                                         host: stale.searchDomain))
        _ = try router.commitImport(records: [CaseImporter.PlannedRecord(
            context: healed, isMaterial: false, sourceRows: [],
            originalContext: stale, sourceAttempt: success)], collection: "Existing")

        var distinct = stale
        distinct.caseID = "distinct"
        distinct.caseUID = "distinct-link"
        distinct.cardURLString = "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&case_id=distinct&case_uid=distinct-link&delo_id=1540005&new=0"
        distinct.sourceKnownCard = KnownCard(
            domain: distinct.searchDomain, courtTitle: distinct.courtTitle,
            caseID: "distinct", caseUID: "distinct-link", deloID: "1540005", new: "0",
            caseNumber: distinct.caseNumber, levelRaw: CaseInstance.Level.first.rawValue,
            cartotekaID: distinct.cartotekaId)
        _ = try router.commitImport(records: [CaseImporter.PlannedRecord(
            context: distinct, isMaterial: false, sourceRows: [], sourceAttempt: success)],
                                    collection: "Incoming")

        let store = try TrackedStore(container: container, prepared: true)
        XCTAssertEqual(store.all().count, 2)
        XCTAssertEqual(Set(store.all().flatMap {
            TrackedCaseIdentity.state(for: $0).cards.map(\.identity.sourceNativeID)
        }), ["old", "distinct"])
        XCTAssertEqual(Set(store.all().map { Set($0.collectionNames) }),
                       Set([Set(["Existing"]), Set(["Incoming"])]))
    }

    func testRecoveredNonAnchorKeepsOldLocatorThroughColdReimport() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        var anchor = context(url: "https://syktsud--komi.sudrf.ru/modules.php?case_id=first&case_uid=first-link&delo_id=1540005&new=0")
        anchor.caseID = "first"
        anchor.caseUID = "first-link"

        var staleAppeal = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "vs--komi.sudrf.ru", displayDomain: "vs.komi.sudrf.ru",
            courtTitle: "Верховный Суд Республики Коми", courtLevelRaw: CourtLevel.subject.rawValue,
            courtCode: "11VS0001", cartotekaId: "g2", cartotekaLevelRaw: CourtLevel.subject.rawValue,
            caseNumber: "33-200/2026", caseID: "appeal-old", caseUID: "appeal-old-link",
            cardURLString: "https://vs--komi.sudrf.ru/modules.php?case_id=appeal-old&case_uid=appeal-old-link&delo_id=5&new=5")
        staleAppeal.sourceKnownCard = KnownCard(
            domain: staleAppeal.searchDomain, courtTitle: staleAppeal.courtTitle,
            caseID: "appeal-old", caseUID: "appeal-old-link", deloID: "5", new: "5",
            caseNumber: staleAppeal.caseNumber, levelRaw: CaseInstance.Level.appeal.rawValue,
            cartotekaID: "g2")
        var healedAppeal = staleAppeal
        healedAppeal.caseID = "appeal-verified"
        healedAppeal.caseUID = "appeal-verified-link"
        healedAppeal.cardURLString = "https://vs--komi.sudrf.ru/modules.php?case_id=appeal-verified&case_uid=appeal-verified-link&delo_id=1540005&new=0"
        healedAppeal.sourceKnownCard = KnownCard(
            domain: healedAppeal.searchDomain, courtTitle: healedAppeal.courtTitle,
            caseID: "appeal-verified", caseUID: "appeal-verified-link", deloID: "1540005", new: "0",
            caseNumber: healedAppeal.caseNumber, levelRaw: CaseInstance.Level.appeal.rawValue,
            cartotekaID: "g2")
        anchor.knownCards = [try XCTUnwrap(healedAppeal.sourceKnownCard)]
        let recoveredAttempt = SourceAttempt(
            kind: .usableSnapshot,
            provenance: SourceProvenance(operation: .discovery, sourceFamily: "sudrf",
                                         host: healedAppeal.searchDomain))

        _ = try router.commitImport(records: [CaseImporter.PlannedRecord(
            context: anchor, isMaterial: false,
            recoveredSources: [.init(originalContext: staleAppeal, verifiedContext: healedAppeal,
                                     sourceAttempt: recoveredAttempt)])], collection: "First")
        let store = try TrackedStore(container: container, prepared: true)
        let before = try XCTUnwrap(store.record(forLocator: staleAppeal.key))
        XCTAssertEqual(before.key, anchor.key)
        let beforeIdentity = TrackedCaseIdentity.state(for: before)
        XCTAssertTrue(beforeIdentity.cards.contains { $0.identity.sourceNativeID == "appeal-old" })
        XCTAssertTrue(beforeIdentity.cards.contains { $0.identity.sourceNativeID == "appeal-verified" })

        let unavailable = SourceAttempt(
            kind: .maintenance,
            provenance: SourceProvenance(operation: .discovery, sourceFamily: "sudrf",
                                         host: staleAppeal.searchDomain))
        _ = try router.commitImport(records: [CaseImporter.PlannedRecord(
            context: staleAppeal, isMaterial: false, sourceAttempt: unavailable)],
                                    collection: "Repeated")

        XCTAssertEqual(store.all().count, 1)
        let saved = try XCTUnwrap(store.record(forLocator: staleAppeal.key))
        XCTAssertEqual(saved.key, anchor.key)
        XCTAssertEqual(saved.context?.cardURLString, anchor.cardURLString)
        XCTAssertEqual(Set(saved.collectionNames), Set(["First", "Repeated"]))
    }

    func testColdRecordShowsPersistedSourceFailure() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let record = try store.upsert(context: context(), snapshot: nil, movement: nil, collections: [])
        record.sourceRefreshAttempt = SourceAttempt(
            kind: .maintenance,
            provenance: SourceProvenance(operation: .discovery, sourceFamily: "sudrf",
                                         host: "syktsud--komi.sudrf.ru"))
        try store.save()

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        XCTAssertEqual(router.cases.first?.statusText, "Источник временно недоступен")
    }

    func testColdRecordShowsLoadedCardBeforeMovementIsCollected() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let record = try store.upsert(context: context(), snapshot: nil, movement: nil, collections: [])
        record.sourceRefreshAttempt = SourceAttempt(
            kind: .usableSnapshot,
            provenance: SourceProvenance(operation: .discovery, sourceFamily: "sudrf",
                                         host: "syktsud--komi.sudrf.ru"))
        try store.save()

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        XCTAssertEqual(router.cases.first?.statusText, "Карточка загружена")
        XCTAssertEqual(router.cases.first?.last, "движение ещё не собрано")
    }

    func testColdRecordShowsAmbiguousRecoveryReason() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let record = try store.upsert(context: context(), snapshot: nil, movement: nil, collections: [])
        record.sourceRefreshAttempt = CaseCardRecoveryError.ambiguous
            .sourceAttempt(host: "syktsud--komi.sudrf.ru")
        try store.save()

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        XCTAssertEqual(router.cases.first?.statusText, "Не удалось однозначно восстановить ссылку")
    }
}
