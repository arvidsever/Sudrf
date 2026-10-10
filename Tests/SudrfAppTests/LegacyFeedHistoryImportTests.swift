// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0
import Foundation
import SudrfKit
import XCTest
@testable import SudrfApp

final class LegacyFeedHistoryImportTests: XCTestCase {
    private let logicalID = UUID(uuidString: "00000000-0000-0000-0000-000000000179")!
    private let importedAt = DateUtil.parse("10.10.2026")!

    func testImportsAllCourtDatesAndOriginalSourceButNotTreasury() throws {
        let past = session("01.01.2020", result: "Рассмотрение отложено")
        let future = session("01.01.2027", event: "Дело оформлено")
        let act = CaseAct(id: "test-act", title: "Решение", date: "02.01.2020",
                          courtShort: "Тестовый суд", instanceLevel: .first)
        let input = record([past, future], acts: [act], treasury: true)
        let journal = try imported(input)
        let history = journal.events.compactMap(\.evidence.legacyFeedHistory)

        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.map(\.kindRaw), ["hearing", "movement", "act"])
        XCTAssertEqual(history[0].source, .session(past))
        XCTAssertEqual(history[1].source, .session(future))
        XCTAssertEqual(history[2].source, .act(act))
        XCTAssertEqual(history[0].text, past.result)
        XCTAssertEqual(history[0].publishedAtRef, past.date!.timeIntervalSinceReferenceDate)
        XCTAssertEqual(Set(history.map(\.legacyID)),
                       Set(LegacyFeedProjection.allEntries(records: [input])
                        .filter { $0.kind != .enforcement }.map(\.id)))
        XCTAssertTrue(journal.events.allSatisfy { $0.kind == .legacyFeedImported && $0.occurrence == nil })
    }

    func testEmptyHistoryAndPersistedReceiptPreventLaterReimport() throws {
        let empty = try imported(record([]))
        XCTAssertEqual(empty.legacyFeedImportVersion, 1)
        XCTAssertTrue(empty.events.isEmpty)
        let reopened = try JSONDecoder().decode(CaseEventJournal.self,
                                                from: JSONEncoder().encode(empty))
        XCTAssertEqual(try imported(record([session("10.10.2026")]), existing: reopened), reopened)
    }

    func testPublishedFileProvenanceAndProductionRemainInReopenedHistory() throws {
        let url = URL(string: "https://example.invalid/act.docx")!
        let provenance = PublishedActProvenance(sourceURL: url, finalURL: url, format: .docx,
            contentType: "application/octet-stream", contentHash: "synthetic-hash",
            byteCount: 42, fetchedAt: importedAt, extractorVersion: 1)
        let act = CaseAct(id: "file-act", title: "Определение", date: "01.01.2020",
            courtShort: "Тестовый суд", instanceLevel: .appeal, fileProvenance: provenance,
            sourceFileURL: url, productionNumber: "33-1/2020")
        let journal = try imported(record([], acts: [act]))
        let reopened = try JSONDecoder().decode(CaseEventJournal.self,
                                                from: JSONEncoder().encode(journal))
        XCTAssertEqual(reopened.events.first?.evidence.legacyFeedHistory?.source, .act(act))
    }

    func testImportPreservesSemanticEventsAndBaselines() throws {
        let event = CaseEvent.make(kind: .judgeChanged, occurrence: ["test-judge"],
                                   observedAt: importedAt, evidence: .init())
        var existing = CaseEventJournal(derivationVersion: 5, events: [event])
        existing.semanticBaselines = CaseEventBaselines()
        let journal = try imported(record([session("10.10.2026")]), existing: existing)
        XCTAssertEqual(journal.events.first, event)
        XCTAssertEqual(journal.derivationVersion, existing.derivationVersion)
        XCTAssertEqual(journal.schemaVersion, existing.schemaVersion)
        XCTAssertEqual(journal.semanticBaselines, existing.semanticBaselines)
        let repeated = try imported(record([session("10.10.2026", event: "Другой текст")]),
                                    existing: journal)
        XCTAssertEqual(repeated, journal)
    }

    func testCollisionAndExactDuplicateMultiplicitySurviveReorderingAndJSON() throws {
        let first = session("10.10.2026", materialNumber: "13-1/2026")
        let other = session("10.10.2026", materialNumber: "13-2/2026")
        let journal = try imported(record([first, other, first]))
        let reordered = try imported(record([first, first, other]))
        XCTAssertEqual(journal.events.count, 3)
        XCTAssertEqual(Set(journal.events.map(\.id)).count, 3)
        XCTAssertEqual(Set(journal.events.map(\.id)), Set(reordered.events.map(\.id)))
        XCTAssertEqual(Set(journal.events.compactMap(\.evidence.legacyFeedHistory).map(\.legacyID)).count, 1)
        let reopened = try JSONDecoder().decode(CaseEventJournal.self,
                                                from: JSONEncoder().encode(journal))
        XCTAssertEqual(reopened, journal)
        XCTAssertEqual(try imported(record([]), existing: reopened), journal)
    }

    func testOriginsStaySeparateAndMixedImportCannotFabricateCompletion() throws {
        let left = try imported(record([session("10.10.2026")], key: "original-left"))
        let right = try imported(record([session("10.10.2026")], key: "original-right"))
        let merged = try CaseEventJournal.merged([left, right])
        XCTAssertEqual(merged.legacyFeedImportVersion, 1)
        XCTAssertEqual(merged.events.count, 2)
        XCTAssertEqual(Set(merged.events.compactMap(\.evidence.legacyFeedHistory).map(\.originRecordKey)),
                       ["original-left", "original-right"])
        XCTAssertThrowsError(try CaseEventJournal.merged([left, CaseEventJournal()]))
        let mixed = CaseEventJournal(events: left.events)
        XCTAssertThrowsError(try imported(record([]), existing: mixed)) {
            XCTAssertTrue($0 is LegacyFeedHistoryImportError)
        }
        XCTAssertNil(try CaseEventJournal.merged([]).legacyFeedImportVersion)
    }

    func testEmptyImportedOriginCannotDisappearInMixedMerge() throws {
        let complete = try imported(record([]))
        let incomplete = CaseEventJournal()
        XCTAssertThrowsError(try CaseEventJournal.merged([complete, incomplete]))
        XCTAssertThrowsError(try CaseEventJournal.merged([incomplete, complete]))
        XCTAssertEqual(try CaseEventJournal.merged([complete, complete]).legacyFeedImportVersion, 1)
    }

    func testOldJournalJSONStillReadsWithoutImportReceipt() throws {
        let old = Data(#"{"schemaVersion":1,"derivationVersion":6,"events":[]}"#.utf8)
        let journal = try JSONDecoder().decode(CaseEventJournal.self, from: old)
        XCTAssertNil(journal.legacyFeedImportVersion)
        XCTAssertEqual(try imported(record([]), existing: journal).legacyFeedImportVersion, 1)
    }

    private func imported(_ input: LegacyFeedRecordInput,
                          existing: CaseEventJournal = .init()) throws -> CaseEventJournal {
        try LegacyFeedHistoryImport.journal(record: input, logicalCaseID: logicalID,
                                           existing: existing, importedAt: importedAt)
    }

    private func record(_ sessions: [StoredSession], key: String = "test-court/test-case",
                        acts: [CaseAct] = [], treasury: Bool = false) -> LegacyFeedRecordInput {
        let snapshot = CaseSnapshot(uid: "", inForce: false, category: nil, partiesShort: "",
            leadCharges: nil, secondPartyLine: nil, stageRaw: "first", stageTag: "",
            statusText: "", statusChipRaw: "gray", lastEvent: "", nextEvent: "",
            nextChipRaw: "gray", steps: [], sessions: sessions, deadlines: [], actsFingerprint: nil)
        let movement = CaseMovement(uid: "", caseNumber: "2-1/2026", inForce: false,
                                    instances: [], complaints: [:], acts: acts)
        let enforcement = EnforcementRecord(courtDocumentID: "test-exec", source: .treasury,
            status: "Открыто", events: [EnforcementEvent(guid: "test-guid", date: importedAt,
                                                        text: "Тест RSS", sourceOrder: 0)])
        return LegacyFeedRecordInput(recordKey: key, caseNumber: "2-1/2026", client: "Тест",
            unreadByCase: true, snapshot: snapshot, movement: movement, context: nil,
            enforcementRecords: treasury ? [enforcement] : [])
    }

    private func session(_ date: String, event: String = "Судебное заседание",
                         result: String? = nil, materialNumber: String? = nil) -> StoredSession {
        StoredSession(dateRaw: date, time: "10:00", room: "101", event: event,
            result: result, court: "Тестовый суд", judge: "Тестовый судья",
            levelRaw: materialNumber == nil ? CaseInstance.Level.first.rawValue
                : CaseInstance.Level.material.rawValue,
            caseNumber: materialNumber, sourceCardID: materialNumber == nil ? nil : "test-source")
    }
}
