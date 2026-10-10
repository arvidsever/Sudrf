// © 2026 Воробьёв Виктор Викторович
// SPDX-License-Identifier: CC-BY-NC-ND-4.0
import XCTest
import SwiftData
@testable import SudrfKit
@testable import SudrfApp

@MainActor
final class JournalFeedStateTests: XCTestCase {
    private func binding(_ id: String = "semantic", histories: [String] = ["old-1", "old-2"]) -> JournalFeedBinding {
        JournalFeedBinding(eventID: id, historyEventIDs: histories,
            legacyIDs: histories.map { "legacy:" + $0 }, originRecordKeys: ["origin"],
            presentation: JournalFeedPresentation(FeedEntry(id: id, dayHead: nil,
                date: Date(timeIntervalSince1970: 1_800_000_000), time: "—", recordKey: "origin",
                caseNumber: "2-179/2026", client: "Тестовый суд", kind: .hearing,
                text: "Заседание перенесено", actID: nil, isUnread: true)))
    }
    func testCompleteRescheduleReadANDKnownORAndDirectReadIndependent() throws {
        for read in [Set<String>(), ["old-1"], ["old-2"], ["old-1", "old-2"], ["semantic"]] {
            for known in [Set<String>(), ["old-1"], ["old-2"]] {
                var state = JournalFeedState()
                state.readEventIDs = read
                state.knownEventIDs = known
                try state.bind(binding(), rescheduled: true)
                XCTAssertEqual(state.readEventIDs.contains("semantic"),
                    read.contains("semantic") || read.isSuperset(of: ["old-1", "old-2"]))
                XCTAssertEqual(state.knownEventIDs.contains("semantic"), !known.isEmpty)
            }
        }
        var incomplete = JournalFeedState()
        XCTAssertThrowsError(try incomplete.bind(binding(histories: ["old-1"]), rescheduled: true))
        XCTAssertTrue(incomplete.bindings.isEmpty)
    }
    func testOneTimeInputReceiptCannotReplayAfterUnreadAndKnownClearAcrossDiskReopen() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("feed-state-179-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
        let store = try TrackedStore(container: container, prepared: true)
        let ctx = MovementContext(branchRaw: CourtBranch.general.rawValue, region: "Тест",
            searchDomain: "test--region.sudrf.ru", displayDomain: "test--region.sudrf.ru",
            courtTitle: "Тестовый суд", courtLevelRaw: CourtLevel.district.rawValue,
            cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-179/2026", caseID: "feed-state-179")
        let record = try store.upsert(context: ctx, snapshot: nil, collections: [])
        var state = JournalFeedState.initial(recordKey: record.key,
            journal: try store.requiredEventJournal(for: record),
            legacyReadIDs: ["old-1", "old-2", "semantic"], legacyKnownIDs: ["old-1"])
        state.readEventIDs = ["old-1", "old-2", "semantic"]
        state.knownEventIDs = ["old-1"]
        try state.bind(binding(), rescheduled: true)
        try store.commit {
            try store.ensureLegacyFeedHistory(for: record)
            try store.appendCaseEvents([], to: record, feedState: state)
        }
        let receipt = state.receipts
        state.readEventIDs.remove("semantic")
        state.knownEventIDs.removeAll()
        try store.commit {
            try store.ensureLegacyFeedHistory(for: record)
            try store.appendCaseEvents([], to: record, feedState: state)
        }
        let reopenedContainer = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        var saved = try XCTUnwrap(reopened.record(forKey: record.key)?.eventJournal?.feedState)
        XCTAssertEqual(saved.receipts, receipt)
        try saved.bind(binding(), rescheduled: true)
        XCTAssertFalse(saved.readEventIDs.contains("semantic"))
        XCTAssertTrue(saved.knownEventIDs.isEmpty)
        XCTAssertEqual(saved.bindings.count, 1)
    }
    func testMergePreservesMarksAndExactBindingsAndRejectsPayloadCollision() throws {
        var first = JournalFeedState()
        first.readEventIDs = ["left"]
        first.knownEventIDs = ["outside-window"]
        try first.bind(binding("left", histories: ["own-left"]), rescheduled: false)
        var second = JournalFeedState()
        second.readEventIDs = ["right"]
        try second.bind(binding("right", histories: ["own-right"]), rescheduled: false)
        let merged = try XCTUnwrap(JournalFeedState.merged([first, second], events: []))
        XCTAssertEqual(merged.readEventIDs, ["left", "right"])
        XCTAssertEqual(merged.knownEventIDs, ["outside-window"])
        XCTAssertEqual(merged.bindings.count, 2)
        var conflicting = JournalFeedState()
        try conflicting.bind(binding("left", histories: ["different-source"]), rescheduled: false)
        XCTAssertThrowsError(try JournalFeedState.merged([first, conflicting], events: []))
    }
    func testPendingMaterialFamilyKeepsBlockedCourtAndIndependentMarksAcrossDiskRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("material-state-179-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
        let store = try TrackedStore(container: container, prepared: true)
        let ctx = MovementContext(branchRaw: CourtBranch.general.rawValue, region: "Тест",
            searchDomain: "test--region.sudrf.ru", displayDomain: "test--region.sudrf.ru",
            courtTitle: "Тестовый суд", courtLevelRaw: CourtLevel.district.rawValue,
            cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-179/2026", caseID: "material-state-179")
        let record = try store.upsert(context: ctx, snapshot: nil, collections: [])
        let date = try XCTUnwrap(DateUtil.parse("01.10.2026"))
        let base = AppRouter.feedID(recordKey: record.key, date: date, time: "—", text: "Принято")
        func event(_ court: String, published: Bool) -> CaseEvent {
            let sourceID = "material-source-" + court
            let entry = FeedEntry(id: published ? AppRouter.materialFeedID(legacyID: base, sourceCardID: sourceID) : base,
                dayHead: nil, date: date, time: "—", recordKey: record.key, caseNumber: record.caseNumber,
                client: "Тест", kind: .movement, text: "Принято", actID: nil, isUnread: true,
                instanceCaseNumber: "13-" + court + "/2026", instanceLevel: .material,
                sourceCardID: published ? sourceID : nil)
            let source = StoredSession(dateRaw: "01.10.2026", time: nil, room: nil, event: "Принято",
                result: nil, court: court, levelRaw: CaseInstance.Level.material.rawValue,
                caseNumber: "13-" + court + "/2026", sourceCardID: published ? sourceID : nil)
            var evidence = CaseEventEvidence()
            evidence.legacyFeedHistory = LegacyFeedHistoryEvidence(entry, source: .session(source))
            if published {
                evidence.sourceCardID = sourceID
                evidence.sourceRowBinding = SourceRowBinding(courtScope: court, nativeCardID: court,
                    sourceCardID: sourceID, fingerprint: "row", ordinal: 0, notificationEligible: true)
            }
            return CaseEvent.make(kind: published ? .sourceRowPublished : .legacyFeedImported,
                occurrence: [court, published ? "new" : "old"], observedAt: date, evidence: evidence)
        }
        let oldA = event("A", published: false), oldB = event("B", published: false)
        var journal = try store.requiredEventJournal(for: record)
        try journal.append([oldA, oldB])
        var state = JournalFeedState.initial(recordKey: record.key, journal: journal,
            legacyReadIDs: [base], legacyKnownIDs: [base])
        _ = AppRouter.materialFeedTransitionsToMigrate(transitions: [:], unresolvedCounts: [base: 2],
            readIDs: [base], knownIDs: [base], state: &state.materialMigrationState)
        state.readEventIDs.remove(oldB.id) // Independent post-cutover user mutation.
        let newA = event("A", published: true), newB = event("B", published: true)
        state.admitMaterialEnrichment(events: [newA], journal: journal)
        XCTAssertTrue(state.readEventIDs.contains(newA.id))
        XCTAssertEqual(state.materialMigrationState.pendingUnresolvedCounts[base], 1)
        XCTAssertFalse(state.materialMigrationState.consumedLegacyIDs.contains(base))
        try store.commit { try store.appendCaseEvents([oldA, oldB, newA], to: record, feedState: state) }
        XCTAssertEqual(state.materialHistoryReplacements, [oldA.id: newA.id])
        XCTAssertEqual(JournalFeedProjection.historyDisplayGroups(journal: try store.requiredEventJournal(for: record))
            .flatMap { $0 }.map(\.id), [oldB.id, newA.id], "Blocked B stays visible; only admitted A replaces its original")
        let reopenedContainer = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        let saved = try XCTUnwrap(reopened.record(forKey: record.key))
        let savedJournal = try reopened.requiredEventJournal(for: saved)
        var resumed = try XCTUnwrap(savedJournal.feedState)
        resumed.admitMaterialEnrichment(events: [newB], journal: savedJournal)
        XCTAssertFalse(resumed.readEventIDs.contains(newB.id), "Read A cannot resurrect unread B")
        XCTAssertTrue(resumed.knownEventIDs.contains(newB.id))
        XCTAssertTrue(resumed.materialMigrationState.consumedLegacyIDs.contains(base))
        XCTAssertNil(resumed.materialMigrationState.pendingUnresolvedCounts[base])
        XCTAssertEqual(resumed.materialResolvedHistoryIDs, [oldA.id, oldB.id])
        resumed.readEventIDs.remove(newA.id)
        resumed.admitMaterialEnrichment(events: [newA, newB], journal: savedJournal)
        XCTAssertFalse(resumed.readEventIDs.contains(newA.id), "Consumed family never reapplies read")
    }

    func testPendingMaterialActRequiresExactImmutableOwnerProof() throws {
        let date = try XCTUnwrap(DateUtil.parse("01.10.2026"))
        let act = CaseAct(id: "native-act-179", title: "Определение", date: "01.10.2026",
            courtShort: "Материал", instanceLevel: .material)
        let base = AppRouter.feedID(recordKey: "origin", date: date, time: "—", text: act.id)
        func evidence(published: Bool, proved: Bool) -> CaseEventEvidence {
            let entry = FeedEntry(id: published ? AppRouter.materialFeedID(legacyID: base, sourceCardID: "owner") : base,
                dayHead: nil, date: date, time: "—", recordKey: "origin", caseNumber: "2-179/2026",
                client: "Тест", kind: .act, text: "Опубликован судебный акт: Определение", actID: act.id,
                isUnread: true, instanceLevel: .material, sourceCardID: published ? "owner" : nil)
            var value = CaseEventEvidence()
            value.legacyFeedHistory = LegacyFeedHistoryEvidence(entry, source: .act(act))
            value.sourceCardID = proved ? "owner" : nil
            if published { value.sourceRowBinding = SourceRowBinding(courtScope: "court", nativeCardID: "native",
                sourceCardID: "owner", fingerprint: "act", ordinal: 0, notificationEligible: true) }
            return value
        }
        let fresh = CaseEvent.make(kind: .sourceRowPublished, occurrence: ["fresh-act"],
            observedAt: date, evidence: evidence(published: true, proved: true))
        for proved in [true, false] {
            let old = CaseEvent.make(kind: .legacyFeedImported, occurrence: ["old-act"],
                observedAt: date, evidence: evidence(published: false, proved: proved))
            var journal = CaseEventJournal()
            try journal.append([old])
            var state = JournalFeedState.initial(recordKey: "origin", journal: journal,
                legacyReadIDs: [base], legacyKnownIDs: [base])
            state.materialMigrationState.pendingUnresolvedCounts[base] = 1
            state.admitMaterialEnrichment(events: [fresh], journal: journal)
            XCTAssertEqual(state.readEventIDs.contains(fresh.id), proved)
            XCTAssertEqual(state.knownEventIDs.contains(fresh.id), proved)
            XCTAssertEqual(state.materialMigrationState.consumedLegacyIDs.contains(base), proved)
            XCTAssertTrue(state.readEventIDs.contains(old.id), "Unknown history and mark survive")
            try journal.append([fresh])
            journal.feedState = state
            XCTAssertEqual(JournalFeedProjection.replacedHistoryIDs(journal: journal).contains(old.id), proved)
        }
    }

    func testMaterialOccurrenceOrdinalUsesPublicationKindBeforeFlatID() throws {
        let date = try XCTUnwrap(DateUtil.parse("01.10.2026"))
        let base = AppRouter.feedID(recordKey: "origin", date: date, time: "—", text: "Принято")
        func event(hearing: Bool, published: Bool) -> CaseEvent {
            let session = StoredSession(dateRaw: "01.10.2026", time: nil, room: nil,
                event: hearing ? "Судебное заседание" : "Поступило дело", result: "Принято", court: "Суд A",
                levelRaw: CaseInstance.Level.material.rawValue, caseNumber: "13-179/2026",
                sourceCardID: published ? "owner" : nil)
            let entry = FeedEntry(id: published ? AppRouter.materialFeedID(legacyID: base, sourceCardID: "owner") : base,
                dayHead: nil, date: date, time: "—", recordKey: "origin", caseNumber: "2-179/2026",
                client: "Тест", kind: AppRouter.feedKind(for: session), text: "Принято", actID: nil,
                isUnread: true, instanceLevel: .material, sourceCardID: published ? "owner" : nil)
            var evidence = CaseEventEvidence()
            evidence.legacyFeedHistory = LegacyFeedHistoryEvidence(entry, source: .session(session))
            if published { evidence.sourceCardID = "owner"; evidence.sourceRowBinding = SourceRowBinding(courtScope: "A", nativeCardID: "A",
                sourceCardID: "owner", fingerprint: hearing ? "hearing" : "movement", ordinal: 0,
                notificationEligible: true) }
            return CaseEvent.make(kind: published ? .sourceRowPublished : .legacyFeedImported,
                occurrence: [hearing ? "hearing" : "movement", published ? "new" : "old"],
                observedAt: date, evidence: evidence)
        }
        let oldH = event(hearing: true, published: false), oldM = event(hearing: false, published: false)
        let newH = event(hearing: true, published: true), newM = event(hearing: false, published: true)
        var journal = CaseEventJournal()
        try journal.append([oldH, oldM])
        var state = JournalFeedState.initial(recordKey: "origin", journal: journal,
            legacyReadIDs: [], legacyKnownIDs: [])
        state.readEventIDs = [oldH.id]
        state.materialMigrationState.pendingUnresolvedCounts[base] = 2
        state.admitMaterialEnrichment(events: [newH, newM], journal: journal)
        XCTAssertTrue(state.readEventIDs.contains(newH.id))
        XCTAssertFalse(state.readEventIDs.contains(newM.id))
        XCTAssertEqual(state.materialResolvedHistoryIDs, [oldH.id, oldM.id])
        XCTAssertTrue(state.materialMigrationState.consumedLegacyIDs.contains(base))

        // Ordinals cover the whole native publication, including an occurrence
        // which was already qualified before the remaining row was enriched.
        let qualified = CaseEvent.make(kind: .legacyFeedImported, occurrence: ["already-qualified"],
            observedAt: date, evidence: newH.evidence)
        var offsetJournal = CaseEventJournal()
        try offsetJournal.append([qualified, oldH])
        var offsetState = JournalFeedState.initial(recordKey: "origin", journal: offsetJournal,
            legacyReadIDs: [base], legacyKnownIDs: [base])
        offsetState.materialMigrationState.pendingUnresolvedCounts[base] = 1
        var lateEvidence = newH.evidence
        lateEvidence.sourceRowBinding = SourceRowBinding(courtScope: "A", nativeCardID: "A",
            sourceCardID: "owner", fingerprint: "hearing", ordinal: 1, notificationEligible: true)
        let late = CaseEvent.make(kind: .sourceRowPublished, occurrence: ["qualified-offset"],
            observedAt: date, evidence: lateEvidence)
        offsetState.admitMaterialEnrichment(events: [late], journal: offsetJournal)
        XCTAssertTrue(offsetState.readEventIDs.contains(late.id))
        XCTAssertEqual(offsetState.materialResolvedHistoryIDs, [oldH.id])
        XCTAssertTrue(offsetState.materialMigrationState.consumedLegacyIDs.contains(base))
        var reversedJournal = CaseEventJournal()
        try reversedJournal.append([oldH, qualified])
        var reversedState = JournalFeedState.initial(recordKey: "origin", journal: reversedJournal,
            legacyReadIDs: [base], legacyKnownIDs: [base])
        reversedState.materialMigrationState.pendingUnresolvedCounts[base] = 1
        reversedState.admitMaterialEnrichment(events: [late], journal: reversedJournal)
        XCTAssertTrue(reversedState.readEventIDs.contains(late.id))
        XCTAssertEqual(reversedState.materialResolvedHistoryIDs, [oldH.id])
        XCTAssertTrue(reversedState.materialMigrationState.consumedLegacyIDs.contains(base))
    }

    func testMaterialReplacementMergeCanonicalizesIDsAndRejectsConflicts() throws {
        var evidence = CaseEventEvidence()
        evidence.eventIDAliases = ["previous-publication"]
        let publication = CaseEvent.make(kind: .sourceRowPublished, occurrence: ["canonical-publication"],
            observedAt: Date(timeIntervalSince1970: 1_800_000_000), evidence: evidence)
        var first = JournalFeedState()
        first.materialHistoryReplacements = ["original": "previous-publication"]
        var second = JournalFeedState()
        second.materialHistoryReplacements = ["original": publication.id]
        let merged = try XCTUnwrap(JournalFeedState.merged([first, second], events: [publication]))
        XCTAssertEqual(merged.materialHistoryReplacements, ["original": publication.id])
        second.materialHistoryReplacements = ["original": "conflicting-publication"]
        XCTAssertThrowsError(try JournalFeedState.merged([first, second], events: [publication]))
        second.materialHistoryReplacements = ["another-original": publication.id]
        XCTAssertThrowsError(try JournalFeedState.merged([first, second], events: [publication]))
        second.materialHistoryReplacements = ["same": "same"]
        XCTAssertThrowsError(try JournalFeedState.merged([second], events: []))
        let encoded = try JSONEncoder().encode(JournalFeedState())
        let decoded = try JSONDecoder().decode(JournalFeedState.self, from: encoded)
        XCTAssertNil(decoded.materialHistoryReplacements, "Old state without the optional pair remains readable")
    }

    func testMaterialReplacementRejectsOrphanWrongOwnerAndAmbiguousSuccessors() throws {
        let date = try XCTUnwrap(DateUtil.parse("01.10.2026"))
        let base = AppRouter.feedID(recordKey: "origin", date: date, time: "—", text: "Принято")
        func event(published: Bool, owner: String = "owner", occurrence: String = "one",
                   court: String = "Суд A", kind: CaseEventKind? = nil) -> CaseEvent {
            let source = StoredSession(dateRaw: "01.10.2026", time: nil, room: nil,
                event: "Принято", result: nil, court: court,
                levelRaw: CaseInstance.Level.material.rawValue, caseNumber: "13-179/2026",
                sourceCardID: published ? owner : nil)
            let entry = FeedEntry(id: published ? AppRouter.materialFeedID(legacyID: base, sourceCardID: owner) : base,
                dayHead: nil, date: date, time: "—", recordKey: "origin", caseNumber: "2-179/2026",
                client: "Тест", kind: .movement, text: "Принято", actID: nil, isUnread: true,
                instanceLevel: .material, sourceCardID: published ? owner : nil)
            var evidence = CaseEventEvidence()
            evidence.legacyFeedHistory = LegacyFeedHistoryEvidence(entry, source: .session(source))
            if published {
                evidence.sourceCardID = owner
                evidence.sourceRowBinding = SourceRowBinding(courtScope: "A", nativeCardID: owner,
                    sourceCardID: owner, fingerprint: "movement", ordinal: 0, notificationEligible: true)
            }
            return CaseEvent.make(kind: kind ?? (published ? .sourceRowPublished : .legacyFeedImported),
                occurrence: [occurrence, published ? owner : "original"], observedAt: date, evidence: evidence)
        }
        let old = event(published: false), fresh = event(published: true)
        var journal = CaseEventJournal()
        try journal.append([old, fresh])
        var state = JournalFeedState()
        state.materialResolvedHistoryIDs = [old.id]
        journal.feedState = state
        XCTAssertFalse(JournalFeedProjection.replacedHistoryIDs(journal: journal).contains(old.id),
            "A resolved receipt alone cannot suppress history")
        for candidate in [event(published: true, court: "Чужой суд"),
                          event(published: true, kind: .legacyFeedImported)] {
            var invalid = CaseEventJournal()
            try invalid.append([old, candidate])
            state.materialHistoryReplacements = [old.id: candidate.id]
            invalid.feedState = state
            XCTAssertFalse(JournalFeedProjection.replacedHistoryIDs(journal: invalid).contains(old.id))
        }
        state.materialHistoryReplacements = [old.id: "missing"]
        journal.feedState = state
        XCTAssertFalse(JournalFeedProjection.replacedHistoryIDs(journal: journal).contains(old.id))
        var pending = JournalFeedState()
        pending.readEventIDs = [old.id]
        pending.knownEventIDs = [old.id]
        pending.materialMigrationState.pendingUnresolvedCounts[base] = 1
        let second = event(published: true, owner: "other-owner", occurrence: "two")
        pending.admitMaterialEnrichment(events: [fresh, second], journal: journal)
        XCTAssertNil(pending.materialHistoryReplacements)
        XCTAssertEqual(pending.readEventIDs, [old.id])
        XCTAssertEqual(pending.knownEventIDs, [old.id])
        XCTAssertTrue(pending.materialResolvedHistoryIDs.isEmpty)
        XCTAssertEqual(pending.materialMigrationState.pendingUnresolvedCounts[base], 1)
        XCTAssertFalse(pending.materialMigrationState.consumedLegacyIDs.contains(base))
    }

}
