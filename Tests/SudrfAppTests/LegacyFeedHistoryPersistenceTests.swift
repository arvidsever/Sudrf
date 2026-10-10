// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0
import XCTest
import SwiftData
import CaptchaSolver
@testable import SudrfKit
@testable import SudrfApp

@MainActor
final class LegacyFeedHistoryPersistenceTests: XCTestCase {
    private let observed = Date(timeIntervalSince1970: 1_800_000_000)
    private func context(_ id: String = "179") -> MovementContext {
        MovementContext(branchRaw: CourtBranch.general.rawValue, region: "Тест",
            searchDomain: "test--region.sudrf.ru", displayDomain: "test--region.sudrf.ru",
            courtTitle: "Тестовый суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "00RS0001", cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-\(id)/2026", caseID: id)
    }
    private func snapshot(_ text: String) -> CaseSnapshot {
        CaseSnapshot(uid: "", inForce: false, category: nil, partiesShort: "",
            leadCharges: nil, secondPartyLine: nil, stageRaw: "first", stageTag: "",
            statusText: "", statusChipRaw: "gray", lastEvent: "", nextEvent: "", nextChipRaw: "gray",
            steps: [], sessions: [StoredSession(dateRaw: "01.01.2020", time: "10:00", room: "101",
                event: text, court: "Тестовый суд", judge: "Тестовый судья", levelRaw: "first")],
            deadlines: [], actsFingerprint: nil)
    }
    private func seed(_ container: ModelContainer, id: String = "179") throws -> TrackedCaseRecord {
        let ctx = context(id)
        let record = TrackedCaseRecord(key: ctx.key, collections: [], caseNumber: ctx.caseNumber,
            courtTitle: ctx.courtTitle, displayDomain: ctx.displayDomain,
            contextData: try JSONEncoder().encode(ctx), snapshotData: try JSONEncoder().encode(snapshot("Исходная история")))
        record.logicalCaseID = UUID()
        record.eventJournalData = nil
        record.seenAt = observed
        record.movementFetchedAt = observed
        container.mainContext.insert(record)
        try container.mainContext.save()
        return record
    }
    private func disk(_ test: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sudrf-179-import-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try test(directory.appendingPathComponent("fixture.store"))
    }
    func testPreparationImportsAllPublishedHistoryAndReopensWithoutAdvancingState() throws {
        try disk { url in
            var key = ""
            var journal: CaseEventJournal?
            do {
                let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
                let record = try seed(container)
                key = record.key
                XCTAssertTrue(try TrackedStorePreparation.prepare(context: container.mainContext))
                journal = record.eventJournal
                XCTAssertEqual(journal?.events.compactMap(\.evidence.legacyFeedHistory).map(\.text), ["Исходная история"])
                XCTAssertEqual(journal?.legacyFeedImportVersion, 1)
                XCTAssertNil(journal?.semanticBaselines)
                XCTAssertEqual(record.seenAt, observed)
                XCTAssertEqual(record.movementFetchedAt, observed)
                XCTAssertFalse(try TrackedStorePreparation.prepare(context: container.mainContext))
            }
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let record = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<TrackedCaseRecord>()).first)
            XCTAssertEqual(record.key, key)
            XCTAssertEqual(record.eventJournal, journal)
        }
    }
    func testPreparationImportsRawSessionProvenanceBeforeMoscowNormalization() throws {
        try disk { url in
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            var ctx = context()
            ctx.searchDomain = "mos-gorsud.ru"
            ctx.displayDomain = "mos-gorsud.ru"
            ctx.courtTitle = "Московский городской суд"
            ctx.cardURLString = "https://mos-gorsud.ru/mgs/services/cases/appeal-civil/details/synthetic-179"
            let movement = CaseMovement(uid: "", caseNumber: ctx.caseNumber, inForce: false,
                instances: [CaseInstance(level: .appeal, court: "Хамовнический районный суд",
                    caseNumber: "33-179/2026", judge: nil, domain: "mos-gorsud.ru", foundByUID: false,
                    result: nil, sessions: [CaseSession(date: "01.01.2020", time: "10:00",
                        event: "Исходная публикация", result: nil)], sourceURL: URL(string: ctx.cardURLString!))],
                complaints: [:], acts: [])
            var original = MovementDerivation.snapshot(from: movement, context: ctx)
            original.sessions[0].court = "Хамовнический районный суд"
            let record = TrackedCaseRecord(key: ctx.key, collections: [], caseNumber: ctx.caseNumber,
                courtTitle: ctx.courtTitle, displayDomain: ctx.displayDomain,
                contextData: try JSONEncoder().encode(ctx), snapshotData: try JSONEncoder().encode(original))
            record.movementData = try JSONEncoder().encode(movement)
            record.eventJournalData = nil
            container.mainContext.insert(record)
            try container.mainContext.save()
            XCTAssertTrue(try TrackedStorePreparation.prepare(context: container.mainContext))
            let imported = try XCTUnwrap(record.eventJournal?.events.first?.evidence.legacyFeedHistory)
            XCTAssertEqual(imported.source, .session(try XCTUnwrap(original.sessions.first)))
            XCTAssertEqual(original.sessions.first?.court, "Хамовнический районный суд")
            XCTAssertEqual(record.snapshot?.sessions.first?.court, "Московский городской суд")
            XCTAssertNotEqual(record.snapshot?.sessions.first, original.sessions.first)
        }
    }

    func testMalformedSourceCannotConsumeImportReceiptAndRepairedBytesRemainImportable() throws {
        for payload in 0..<3 {
            try disk { url in
                var key = ""
                do {
                    let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
                    let record = try seed(container)
                    key = record.key
                    let corrupt = Data("malformed-synthetic-179".utf8)
                    if payload == 0 { record.snapshotData = corrupt }
                    if payload == 1 { record.movementData = corrupt }
                    if payload == 2 { record.contextData = corrupt }
                    try container.mainContext.save()
                    let snapshotBytes = record.snapshotData
                    let movementBytes = record.movementData
                    let contextBytes = record.contextData
                    XCTAssertThrowsError(try TrackedStorePreparation.prepare(context: container.mainContext))
                    XCTAssertNil(record.eventJournalData)
                    XCTAssertEqual(record.snapshotData, snapshotBytes)
                    XCTAssertEqual(record.movementData, movementBytes)
                    XCTAssertEqual(record.contextData, contextBytes)
                    XCTAssertEqual(record.seenAt, observed)
                    XCTAssertEqual(record.movementFetchedAt, observed)
                    XCTAssertFalse(container.mainContext.hasChanges)
                }
                let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
                let record = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<TrackedCaseRecord>()).first)
                XCTAssertEqual(record.key, key)
                XCTAssertNil(record.eventJournalData)
                let corrupt = Data("malformed-synthetic-179".utf8)
                if payload == 0 { XCTAssertEqual(record.snapshotData, corrupt) }
                if payload == 1 { XCTAssertEqual(record.movementData, corrupt) }
                if payload == 2 { XCTAssertEqual(record.contextData, corrupt) }
                record.snapshotData = try JSONEncoder().encode(snapshot("Исходная история"))
                record.movementData = nil
                record.contextData = try JSONEncoder().encode(context())
                try container.mainContext.save()
                XCTAssertTrue(try TrackedStorePreparation.prepare(context: container.mainContext))
                XCTAssertEqual(record.eventJournal?.legacyFeedImportVersion, 1)
                XCTAssertEqual(record.eventJournal?.events.compactMap(\.evidence.legacyFeedHistory).map(\.text), ["Исходная история"])
            }
        }
    }

    func testPreparationSaveFailureRestoresOriginalNilJournalInRetainedObjectAndDisk() throws {
        try disk { url in
            do {
                let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
                let record = try seed(container)
                XCTAssertThrowsError(try TrackedStorePreparation.prepare(context: container.mainContext,
                    save: { _ in throw CocoaError(.fileWriteUnknown) }))
                XCTAssertNil(record.eventJournalData)
                XCTAssertEqual(record.snapshot?.sessions.first?.event, "Исходная история")
                XCTAssertEqual(record.seenAt, observed)
                XCTAssertEqual(record.movementFetchedAt, observed)
                XCTAssertFalse(container.mainContext.hasChanges)
            }
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            XCTAssertNil(try container.mainContext.fetch(FetchDescriptor<TrackedCaseRecord>()).first?.eventJournalData)
        }
    }
    func testFailedUpdateRestoresOriginalJournalAndOldHistoryOnDisk() throws {
        try disk { url in
            do {
                let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
                let store = try TrackedStore(container: container, prepared: true)
                let record = try seed(container)
                let bytes = record.eventJournalData
                store.failNextSaveForTesting = true
                XCTAssertThrowsError(try store.upsert(context: context(), snapshot: snapshot("Новый ответ"), collections: []))
                XCTAssertEqual(record.eventJournalData, bytes)
                XCTAssertEqual(record.snapshot?.sessions.first?.event, "Исходная история")
                XCTAssertEqual(record.seenAt, observed)
                XCTAssertEqual(record.movementFetchedAt, observed)
                XCTAssertFalse(container.mainContext.hasChanges)
            }
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let record = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<TrackedCaseRecord>()).first)
            XCTAssertNil(record.eventJournalData)
            XCTAssertEqual(record.snapshot?.sessions.first?.event, "Исходная история")
        }
    }

    func testAtomicMergeImportsEachOriginalAndRollsBackRetainedBytesOnSaveFailure() throws {
        for fails in [true, false] {
            try disk { url in
                let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
                let store = try TrackedStore(container: container, prepared: true)
                let left = try seed(container, id: "181")
                let right = try seed(container, id: "182")
                let origins = Set([left.key, right.key])
                XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<TrackedCaseRecord>()), 2)
                store.failNextSaveForTesting = fails
                let merge = { try TrackedCaseRepairCoordinator.atomicMerge(store: store, survivor: left,
                    duplicates: [right], canonicalContext: self.context("181"), canonicalCard: nil) }
                if fails {
                    XCTAssertThrowsError(try merge())
                    XCTAssertNil(left.eventJournalData)
                    XCTAssertNil(right.eventJournalData)
                    XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<TrackedCaseRecord>()), 2)
                    XCTAssertFalse(container.mainContext.hasChanges)
                } else {
                    _ = try merge()
                    XCTAssertEqual(Set(left.eventJournal?.events.compactMap(\.evidence.legacyFeedHistory).map(\.originRecordKey) ?? []), origins)
                    XCTAssertEqual(left.eventJournal?.legacyFeedImportVersion, 1)
                    XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<TrackedCaseRecord>()), 1)
                }
                let reopened = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
                let persisted = try reopened.mainContext.fetch(FetchDescriptor<TrackedCaseRecord>())
                XCTAssertEqual(persisted.count, fails ? 2 : 1)
                if fails {
                    XCTAssertTrue(persisted.allSatisfy { $0.eventJournalData == nil })
                } else {
                    XCTAssertEqual(Set(persisted[0].eventJournal?.events.compactMap(\.evidence.legacyFeedHistory).map(\.originRecordKey) ?? []), origins)
                }
            }
        }
    }

    func testRealRefreshCommitImportsOldHistoryBeforeNewMovementAndSurvivesReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sudrf-179-refresh-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.store")
        let suite = "sudrf-179-refresh-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var key = ""
        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let store = try TrackedStore(container: container, prepared: true)
            let record = try seed(container)
            key = record.key
            let fresh = CaseMovement(uid: "", caseNumber: context().caseNumber, inForce: false,
                instances: [CaseInstance(level: .first, court: "Тестовый суд", caseNumber: context().caseNumber,
                    judge: nil, domain: context().displayDomain, foundByUID: false, result: nil,
                    sessions: [CaseSession(date: "10.10.2026", time: "10:00", event: "Новый ответ", result: nil)])],
                complaints: [:], acts: [])
            let center = RefreshCenter(store: store, client: TestNetworkGuard.sudrfClient(),
                captchaSettings: CaptchaSettings(defaults: defaults),
                captchaTokenStore: CaptchaTokenStore(),
                serviceBuilder: { _ in LegacyHistory179Movement(value: fresh) },
                treasuryDiscover: { _, _, _ in throw CancellationError() },
                vsrfProvider: LegacyHistory179UnusedVSRF(), fsspAutoModelEnabled: false,
                fsspDiscover: { _ in .notFound(.init(state: .notFound, record: nil)) })
            let execution = await center.refreshForIntent(key: key)
            if case .notFound = execution { XCTFail("Refresh unexpectedly found no record") }
            XCTAssertEqual(record.eventJournal?.events.compactMap(\.evidence.legacyFeedHistory).map(\.text), ["Исходная история"])
            XCTAssertEqual(record.eventJournal?.legacyFeedImportVersion, 1)
            XCTAssertEqual(record.snapshot?.sessions.first?.event, "Новый ответ")
        }
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
        let record = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<TrackedCaseRecord>()).first)
        XCTAssertEqual(record.key, key)
        XCTAssertEqual(record.eventJournal?.events.compactMap(\.evidence.legacyFeedHistory).map(\.text), ["Исходная история"])
    }

    func testAppendEncodingAndSaveFailuresRestorePreimportJournalAndSourceHistory() throws {
        for failure in 0..<3 {
            try disk { url in
                do {
                    let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
                    let store = try TrackedStore(container: container, prepared: true)
                    let record = try seed(container)
                    if failure == 0 { store.failNextJournalAppendForTesting = true }
                    if failure == 1 { store.failNextJournalEncodingForTesting = true }
                    if failure == 2 { store.failNextSaveForTesting = true }
                    let update = EnforcementRecord(courtDocumentID: "synthetic-179", source: .treasury,
                        status: "Тест", events: [EnforcementEvent(guid: "synthetic-guid-179", date: observed,
                            text: "Тестовый документ", sourceOrder: 0)])
                    XCTAssertThrowsError(try store.applyEnforcementUpdates(forLocator: record.key,
                        updates: [update], openedKey: nil))
                    XCTAssertNil(record.eventJournalData)
                    XCTAssertTrue(record.enforcementRecords.isEmpty)
                    XCTAssertEqual(record.snapshot?.sessions.first?.event, "Исходная история")
                    XCTAssertEqual(record.seenAt, observed)
                    XCTAssertEqual(record.movementFetchedAt, observed)
                    XCTAssertFalse(container.mainContext.hasChanges)
                }
                let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
                let record = try XCTUnwrap(try container.mainContext.fetch(FetchDescriptor<TrackedCaseRecord>()).first)
                XCTAssertNil(record.eventJournalData)
                XCTAssertTrue(record.enforcementRecords.isEmpty)
                XCTAssertEqual(record.snapshot?.sessions.first?.event, "Исходная история")
            }
        }
    }

    func testUnpreparedUpdateImportsOriginalBeforeOverwriteAndIncomingInsertSeedsHistory() throws {
        try disk { url in
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let store = try TrackedStore(container: container, prepared: true)
            let record = try seed(container)
            try store.upsert(context: context(), snapshot: snapshot("Новый ответ"), collections: [])
            XCTAssertEqual(record.eventJournal?.events.compactMap(\.evidence.legacyFeedHistory).map(\.text), ["Исходная история"])
            let incoming = try store.upsert(context: context("180"), snapshot: snapshot("Входящая история"), collections: [])
            XCTAssertEqual(incoming.eventJournal?.legacyFeedImportVersion, 1)
            XCTAssertEqual(incoming.eventJournal?.events.compactMap(\.evidence.legacyFeedHistory).map(\.text), ["Входящая история"])
        }
    }
}

private struct LegacyHistory179Movement: MovementProviding {
    let value: CaseMovement
    func movement(for base: CaseSearchResult, court: Court, cartoteka: Cartoteka) async throws -> CaseMovement { value }
}
private struct LegacyHistory179UnusedVSRF: VSRFProviding {
    func search(uniqueNumber: String?, oldCaseNumber: String?, keywords: String?) async throws -> VSRFSearchResults {
        XCTFail("Unexpected VS RF request"); throw CancellationError()
    }
    func fetchCard(productionID: String, section: VSRFCardSection) async throws -> VSRFCard {
        XCTFail("Unexpected VS RF card request"); throw CancellationError()
    }
}
