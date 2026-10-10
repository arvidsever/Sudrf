// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0
import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class KoAPJournalFeedProjectionTests: XCTestCase {
    private let today = DateUtil.parse("10.06.2027")!
    private let source = "sudrf|3kas.sudrf.ru|adm3|123456"
    private let number = "16-123/2027"

    func testThreePersistedMilestonesMatchRealLegacyFeedAndReadAlias() throws {
        let f = fixture()
        let legacy = legacyProjection([input(f)])
        XCTAssertEqual(legacy.entries.count, 3)
        let read = Set(legacy.entries.map(\.id))
        let marked = legacyProjection([input(f)], read: read)
        let result = project(f, read: read, legacy: marked.entries)
        XCTAssertEqual(result.entries.count, 3)
        XCTAssertEqual(Set(result.entries.map(\.id)), Set(f.journal.events.map(\.id)))
        XCTAssertEqual(Set(f.journal.events.map(\.kind)), [.caseFileRequested, .requestedCaseReceived, .complaintReviewResult])
        XCTAssertEqual(Set(result.aliases.map(\.legacyID)), read)
        XCTAssertTrue(result.entries.allSatisfy { !$0.isUnread && $0.sourceCardID == source })
        XCTAssertTrue(result.fieldMismatches.isEmpty)
        XCTAssertTrue(result.unmappedEvents.isEmpty)
        XCTAssertTrue(result.unmappedLegacyIDs.isEmpty)
    }

    func testQuietBaselineDoesNotInventEvents() {
        var f = fixture()
        f.journal = CaseEventJournal()
        let result = project(f)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(result.aliases.isEmpty)
        XCTAssertEqual(result.unmappedLegacyIDs.count, 3)
        XCTAssertTrue(result.unmappedEvents.isEmpty)
    }

    func testForeignOwnerAndConflictingEvidenceFailClosed() {
        for mutation in 0..<7 {
            var f = fixture()
            if mutation == 0 { f.movement.instances[0].sourceURL = URL(string: "https://3kas.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case&case_id=999999&delo_id=2550001") }
            if mutation == 1 { f.movement.instances.append(f.movement.instances[0]) }
            if mutation == 2 { let duplicate = f.snapshot.instanceObservations![0]; f.snapshot.instanceObservations?.append(duplicate) }
            if mutation == 3 { f.snapshot.sessions[0].dateRaw = "02.06.2027" }
            if mutation == 4 { f.snapshot.sessions[0].caseNumber = "16-999/2027" }
            if mutation == 5 { f.snapshot.sessions[0].event = "Поступление истребованного дела (материала)" }
            if mutation == 6 { f.movement.instances[0].domain = "foreign.sudrf.ru" }
            let result = project(f)
            XCTAssertFalse(result.unmappedEvents.isEmpty, "mutation \(mutation)")
            XCTAssertLessThan(result.entries.count, 3, "mutation \(mutation)")
        }
        var f = fixture()
        var conflicting = f.snapshot.sessions[2]
        conflicting.result = "Жалоба удовлетворена"
        f.snapshot.sessions.append(conflicting)
        let result = project(f)
        XCTAssertFalse(result.entries.contains { $0.id == f.journal.events.first(where: { $0.kind == .complaintReviewResult })?.id })
    }

    func testRawCrossFamilyCollisionAndMultipleEventsCannotAlias() {
        let f = fixture()
        var raw = legacyProjection([input(f)]).entries
        let row = raw[0]
        raw.append(FeedEntry(id: row.id, dayHead: nil, date: DateUtil.parse("01.01.2020")!,
            time: "—", recordKey: "foreign", caseNumber: "foreign", client: "",
            kind: .act, text: "foreign", actID: "foreign", isUnread: false))
        let collision = project(f, legacy: raw)
        XCTAssertFalse(collision.aliases.contains { $0.legacyID == row.id })
        XCTAssertFalse(collision.unmappedEvents.isEmpty)
        var duplicate = f
        duplicate.journal.events.append(f.journal.events[0])
        let result = project(duplicate)
        XCTAssertFalse(result.entries.contains { $0.id == f.journal.events[0].id })
    }

    func testInvalidPersistedCompetitorBlocksOccurrenceBeforeWindowFiltering() {
        for dateRaw in ["01.01.2020", "invalid", ""] {
            var f = fixture()
            let original = f.journal.events[0]
            var evidence = original.evidence
            evidence.dateRaw = dateRaw
            evidence.event = "Несовпадающая публикация"
            let competitor = CaseEvent(id: "invalid-competitor", kind: .complaintReviewResult,
                observedAtRef: original.observedAtRef, evidence: evidence)
            f.journal.events.append(competitor)
            let result = project(f)
            XCTAssertFalse(result.entries.contains { $0.id == original.id }, dateRaw)
            XCTAssertFalse(result.aliases.contains { $0.eventID == original.id }, dateRaw)
            XCTAssertFalse(result.aliases.contains { $0.eventID == competitor.id }, dateRaw)
            XCTAssertEqual(result.entries.count, 2, dateRaw)
        }
    }

    func testLegacyWindowBoundariesAndQuietOutsideDuplicates() {
        for (date, expected) in [("11.06.2027", 0), ("10.06.2027", 1),
                                 ("26.04.2027", 1), ("25.04.2027", 0)] {
            var f = fixture()
            var session = f.snapshot.sessions[0]
            session.dateRaw = date
            f.snapshot.sessions = [session]
            var before = f.snapshot
            before.sessions = []
            f.journal.events = CaseEventDeriver.derive(old: before, new: f.snapshot,
                attempt: nil, observedAt: today).events
            if expected == 0, let event = f.journal.events.first {
                f.journal.events.append(CaseEvent(id: "outside-duplicate", kind: event.kind,
                    observedAtRef: event.observedAtRef, evidence: event.evidence))
            }
            let legacy = legacyProjection([input(f)])
            XCTAssertEqual(legacy.entries.count, expected, date)
            let result = project(f, legacy: legacy.entries)
            XCTAssertEqual(result.aliases.count, expected, date)
            XCTAssertTrue(result.unmappedEvents.isEmpty, date)
            XCTAssertTrue(result.unmappedLegacyIDs.isEmpty, date)
        }
    }

    func testKnownCardCannotMaskDifferentCurrentNativeURL() {
        for query in ["case_id=999999&delo_id=2550001", "case_id=123456&delo_id=2800001"] {
            var f = fixture()
            f.context.knownCards = [KnownCard(domain: "3kas.sudrf.ru", courtTitle: "Третий кассационный суд общей юрисдикции",
                caseID: "123456", caseUID: "", deloID: "2550001", new: "0", caseNumber: number,
                levelRaw: "cassation", cartotekaID: "adm3")]
            f.movement.instances[0].sourceURL = URL(string: "https://3kas.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case&" + query)
            let result = project(f)
            XCTAssertTrue(result.entries.isEmpty)
            XCTAssertEqual(result.unmappedEvents.count, 3)
        }
    }

    func testComparatorReportsActualPresentationDifference() {
        let f = fixture()
        var raw = legacyProjection([input(f)]).entries
        raw[0].isUnread = false
        let result = project(f, legacy: raw)
        XCTAssertEqual(result.fieldMismatches.map(\.field), ["isUnread"])
        XCTAssertEqual(result.fieldMismatches.first?.legacyValue, "false")
        XCTAssertEqual(result.fieldMismatches.first?.shadowValue, "true")
    }

    @MainActor
    func testDiskReopenAndRepeatedProjectionPreserveJournalAndStoredBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koap-shadow-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("test.store")
        let f = fixture()
        var persistedIDs = [String]()
        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let store = try TrackedStore(container: container, prepared: true)
            let rec = try store.commit {
                let rec = try store.reconcileAndUpsert(context: f.context, snapshot: f.snapshot,
                    movement: f.movement, collections: [], saveChanges: false)
                try store.appendCaseEvents(f.journal.events, to: rec,
                    derivationVersion: CaseEventJournal.currentDerivationVersion)
                // Replay already identified persisted occurrences, not a new raw transition.
                let savedEvents = try XCTUnwrap(rec.eventJournal).events
                try store.appendCaseEvents(savedEvents, to: rec,
                    derivationVersion: CaseEventJournal.currentDerivationVersion)
                XCTAssertTrue(CaseEventDeriver.derive(old: f.snapshot, new: f.snapshot,
                    attempt: nil, observedAt: today).events.isEmpty)
                return rec
            }
            persistedIDs = try XCTUnwrap(rec.eventJournal).events.map(\.id)
            XCTAssertEqual(persistedIDs.count, 3)
        }
        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let store = try TrackedStore(container: container, prepared: true)
            let rec = try XCTUnwrap(store.record(forKey: f.context.key))
            let journal = try XCTUnwrap(rec.eventJournal)
            let input = LegacyFeedRecordInput(recordKey: rec.key, caseNumber: rec.caseNumber,
                client: "Учебное дело", unreadByCase: true, snapshot: rec.snapshot,
                movement: rec.movement, context: rec.context, enforcementRecords: [])
            let legacy = legacyProjection([input])
            let bytes = [rec.contextData, rec.snapshotData, rec.movementData, rec.eventJournalData]
            for _ in 0..<2 {
                let result = KoAPJournalFeedProjection.project(records: [input],
                    journalsByRecordKey: [rec.key: journal], today: today,
                    readIDs: [], legacyEntries: legacy.entries)
                XCTAssertEqual(Set(result.entries.map(\.id)), Set(persistedIDs))
                XCTAssertEqual(result.aliases.count, 3)
                XCTAssertTrue(result.fieldMismatches.isEmpty)
                XCTAssertTrue(result.unmappedEvents.isEmpty)
                XCTAssertTrue(result.unmappedLegacyIDs.isEmpty)
            }
            XCTAssertEqual(bytes, [rec.contextData, rec.snapshotData, rec.movementData, rec.eventJournalData])
            XCTAssertFalse(container.mainContext.hasChanges)
            XCTAssertEqual(journal.events.map(\.id), persistedIDs)
        }
    }

    private struct Fixture {
        var context: MovementContext
        var movement: CaseMovement
        var snapshot: CaseSnapshot
        var journal: CaseEventJournal
    }
    private func fixture() -> Fixture {
        let context = MovementContext(branchRaw: "general", region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru", displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Учебный городской суд", courtLevelRaw: "district", courtCode: "11RS0001",
            cartotekaId: "adm", cartotekaLevelRaw: "district", caseNumber: "12-123/2027", caseID: "100")
        let rows = [("01.06.2027", "Истребование дела (материала)", nil),
                    ("03.06.2027", "Поступление истребованного дела (материала)", nil),
                    ("05.06.2027", "Результат рассмотрения жалобы", "Жалоба оставлена без удовлетворения")]
        let sessions = rows.map { StoredSession(dateRaw: $0.0, time: nil, room: nil,
            event: $0.1, result: $0.2, court: "Третий кассационный суд общей юрисдикции",
            levelRaw: "cassation", caseNumber: number, sourceCardID: source) }
        let owner = CaseInstance(level: .cassation, court: "Третий кассационный суд общей юрисдикции",
            caseNumber: number, judge: "", domain: "3kas.sudrf.ru", foundByUID: false,
            result: rows[2].2, sessions: rows.map { CaseSession(date: $0.0, event: $0.1, result: $0.2) },
            sourceURL: URL(string: "https://3kas.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case&case_id=123456&delo_id=2550001"))
        let movement = CaseMovement(uid: "", caseNumber: context.caseNumber, inForce: false,
            instances: [owner], complaints: [:], acts: [])
        let snapshot = CaseSnapshot(uid: "", inForce: false, category: nil, partiesShort: "",
            leadCharges: nil, secondPartyLine: nil, stageRaw: "cassation", stageTag: "кассация",
            statusText: "", statusChipRaw: "gray", lastEvent: "", nextEvent: "", nextChipRaw: "gray",
            steps: [], sessions: sessions, deadlines: [], semanticProjectionVersion: CaseEventJournal.currentDerivationVersion,
            instanceObservations: [.init(sourceCardID: source, levelRaw: "cassation", court: owner.court,
                                        caseNumber: number, judge: nil, result: owner.result)])
        var before = snapshot
        before.sessions = []
        let events = CaseEventDeriver.derive(old: before, new: snapshot, attempt: nil, observedAt: today).events
        return Fixture(context: context, movement: movement, snapshot: snapshot, journal: .init(events: events))
    }
    private func input(_ f: Fixture) -> LegacyFeedRecordInput {
        .init(recordKey: f.context.key, caseNumber: f.context.caseNumber, client: "Учебное дело",
              unreadByCase: true, snapshot: f.snapshot, movement: f.movement,
              context: f.context, enforcementRecords: [])
    }
    private func legacyProjection(_ inputs: [LegacyFeedRecordInput], read: Set<String> = []) -> LegacyFeedProjectionResult {
        LegacyFeedProjection.project(records: inputs, today: today, readIDs: read,
                                     knownIDs: [], migrationState: .init())
    }
    private func project(_ f: Fixture, read: Set<String> = [], legacy: [FeedEntry]? = nil) -> KoAPJournalFeedProjection.Result {
        let record = input(f)
        return KoAPJournalFeedProjection.project(records: [record], journalsByRecordKey: [record.recordKey: f.journal],
            today: today, readIDs: read, legacyEntries: legacy ?? legacyProjection([record], read: read).entries)
    }
}
