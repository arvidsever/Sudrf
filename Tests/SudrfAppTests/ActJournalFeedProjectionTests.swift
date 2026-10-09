import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class ActJournalFeedProjectionTests: XCTestCase {
    private let today = DateUtil.parse("10.09.2026")!

    func testDerivedEventsProjectExactLegacyActsWithMaterialAndPreviousRegistration() throws {
        let ordinary = try fixture(actID: "ordinary-act", level: .first,
                                   instanceNumber: "3-18/2026")
        let material = try fixture(recordKey: "material-case", actID: "material-act",
                                   level: .material, instanceNumber: "13-2471/2026")
        let previous = try fixture(recordKey: "previous-case", actID: "previous-act",
                                   level: .first, instanceNumber: "9а-104/2026",
                                   note: "Предыдущая регистрация")
        let records = [ordinary.record, material.record, previous.record]
        let journals = Dictionary(uniqueKeysWithValues: [ordinary, material, previous].map {
            ($0.record.recordKey, $0.journal)
        })
        let (legacy, result) = project(records, journals: journals)

        XCTAssertEqual(result.entries.count, 3)
        XCTAssertEqual(result.aliases.count, 3)
        XCTAssertTrue(result.unmappedLegacyActs.isEmpty)
        XCTAssertTrue(result.unmappedEvents.isEmpty)
        XCTAssertTrue(result.shadowReadIDs.isEmpty)
        XCTAssertTrue(result.shadowKnownIDs.isEmpty)

        for fixture in [ordinary, material, previous] {
            let entry = try XCTUnwrap(result.entries.first {
                $0.recordKey == fixture.record.recordKey
            })
            XCTAssertEqual(entry.id, fixture.event.id)
            XCTAssertEqual(entry.dayHead, nil)
            XCTAssertEqual(entry.date, today)
            XCTAssertEqual(entry.time, "—")
            XCTAssertEqual(entry.recordKey, fixture.record.recordKey)
            XCTAssertEqual(entry.caseNumber, fixture.record.caseNumber)
            XCTAssertEqual(entry.client, fixture.record.client)
            XCTAssertEqual(entry.kind, .act)
            XCTAssertEqual(entry.text, "Опубликован судебный акт: \(fixture.currentAct.title)")
            XCTAssertEqual(entry.actID, fixture.currentAct.id)
            XCTAssertTrue(entry.isUnread)
            XCTAssertEqual(entry.instanceLevel, fixture.owner.level)
            XCTAssertEqual(entry.sourceCardID,
                           fixture.owner.level == .material ? fixture.sourceCardID : nil)
            XCTAssertEqual(entry.sourceInstanceID, fixture.owner.id)
        }

        XCTAssertEqual(try XCTUnwrap(result.entries.first { $0.recordKey == material.record.recordKey })
            .instanceCaseNumber, "13-2471/2026")
        let previousEntry = try XCTUnwrap(result.entries.first {
            $0.recordKey == previous.record.recordKey
        })
        XCTAssertEqual(previousEntry.instanceCaseNumber, "9а-104/2026")
        XCTAssertEqual(previousEntry.previousRegistrationNumber, "9а-104/2026")

        let expectedAliases = Dictionary(uniqueKeysWithValues: zip(legacy.entries, result.entries).map {
            ($0.id, $1.id)
        })
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: result.aliases.map {
            ($0.legacyID, $0.eventID)
        }), expectedAliases)
        XCTAssertTrue(result.fieldMismatches.isEmpty)

        // Prove the real legacy comparator notices presentation drift instead
        // of merely agreeing with the event-derived oracle by construction.
        var alteredLegacyEntries = legacy.entries
        let materialIndex = try XCTUnwrap(alteredLegacyEntries.firstIndex {
            $0.recordKey == material.record.recordKey && $0.kind == .act
        })
        alteredLegacyEntries[materialIndex].time = "09:41"
        alteredLegacyEntries[materialIndex].text += " (изменено для проверки)"
        let alteredComparison = ActJournalFeedProjection.project(
            records: records,
            journalsByRecordKey: journals,
            today: today,
            readIDs: legacy.migratedReadIDs,
            knownIDs: legacy.migratedKnownIDs,
            legacyEntries: alteredLegacyEntries)
        let alteredMismatches = alteredComparison.fieldMismatches.filter {
            $0.eventID == material.event.id
        }
        XCTAssertEqual(alteredMismatches.map(\.field), ["time", "text"])
        XCTAssertEqual(alteredMismatches.map(\.legacyValue), [
            "09:41", "\(legacy.entries[materialIndex].text) (изменено для проверки)"
        ])
        XCTAssertEqual(alteredMismatches.map(\.shadowValue), [
            "—", "Опубликован судебный акт: \(material.currentAct.title)"
        ])
    }

    func testQuietLegacyBaselineActRemainsVisibleAsUnmapped() throws {
        let fixture = try fixture(actID: "quiet-act")
        let observation = try XCTUnwrap(fixture.record.snapshot?.actObservations?.first)
        let quiet = quietJournal(observations: [observation])
        XCTAssertTrue(quiet.events.isEmpty)
        let (legacy, result) = project([fixture.record],
                                       journals: [fixture.record.recordKey: quiet])

        XCTAssertEqual(legacy.entries.count, 1)
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(result.aliases.isEmpty)
        XCTAssertEqual(result.unmappedLegacyActs.map(\.reason), [.noPublishedEvent])
        XCTAssertTrue(result.unmappedEvents.isEmpty)
    }

    func testPartialRefreshDoesNotConsumeActAndCompleteRefreshProjectsIt() throws {
        let fixture = try fixture(actID: "existing-act")
        let oldObservation = try XCTUnwrap(fixture.record.snapshot?.actObservations?.first)
        let newAct = CaseAct(id: "newly-published-act", title: "Постановление",
                             date: rawDate(today), courtShort: "1-я инстанция",
                             instanceLevel: .first)
        let acts = [fixture.currentAct, newAct]
        let owner = instance(level: .first, caseNumber: "3-18/2026",
                             actIDs: acts.map(\.id), note: nil)
        let observations = acts.map { observation($0, owner: owner, context: fixture.context) }
        let currentSnapshot = snapshot(observations)
        let currentRecord = input(recordKey: fixture.record.recordKey,
                                  caseNumber: fixture.record.caseNumber,
                                  client: fixture.record.client, acts: acts,
                                  instances: [owner], context: fixture.context,
                                  snapshot: currentSnapshot)
        let initialJournal = quietJournal(observations: [oldObservation])
        let partial = transition(
            journal: initialJournal, snapshot: currentSnapshot, admittedCourts: [:],
            complete: false, observedAt: DateUtil.addDays(today, 100))
        XCTAssertFalse(partial.derivation.events.contains { $0.kind == .judicialActPublished })
        XCTAssertEqual(partial.baselines, initialJournal.semanticBaselines)

        var afterPartial = initialJournal
        afterPartial.semanticBaselines = partial.baselines
        let complete = transition(
            journal: afterPartial, snapshot: currentSnapshot,
            admittedCourts: admittedCourts(observations), complete: true,
            observedAt: DateUtil.addDays(today, 100))
        let actEvents = complete.derivation.events.filter { $0.kind == .judicialActPublished }
        XCTAssertEqual(actEvents.map(\.evidence.occurrenceKey), [newAct.id])

        var journal = afterPartial
        journal.events = complete.derivation.events
        journal.semanticBaselines = complete.baselines
        let (legacy, result) = project([currentRecord],
                                       journals: [currentRecord.recordKey: journal])
        XCTAssertEqual(legacy.entries.count, 2)
        XCTAssertEqual(result.entries.map(\.id), actEvents.map(\.id))
        XCTAssertEqual(result.aliases.map(\.eventID), actEvents.map(\.id))
        XCTAssertEqual(result.unmappedLegacyActs.map(\.actID), [fixture.currentAct.id])
        XCTAssertEqual(result.unmappedLegacyActs.map(\.reason), [.noPublishedEvent])
    }

    func testReadKnownKnownOnlyAndRepeatedProjectionUseOnlyExactAliases() throws {
        let fixture = try fixture(actID: "read-known-act")
        let legacy = legacyProjection([fixture.record])
        let legacyID = try XCTUnwrap(legacy.entries.first?.id)
        let result = ActJournalFeedProjection.project(
            records: [fixture.record],
            journalsByRecordKey: [fixture.record.recordKey: fixture.journal], today: today,
            readIDs: legacy.migratedReadIDs.union([legacyID]),
            knownIDs: legacy.migratedKnownIDs.union([legacyID]),
            legacyEntries: legacy.entries)
        XCTAssertEqual(result.shadowReadIDs, [fixture.event.id])
        XCTAssertEqual(result.shadowKnownIDs, [fixture.event.id])
        XCTAssertFalse(try XCTUnwrap(result.entries.first).isUnread)

        let repeated = ActJournalFeedProjection.project(
            records: [fixture.record],
            journalsByRecordKey: [fixture.record.recordKey: fixture.journal], today: today,
            readIDs: legacy.migratedReadIDs.union([legacyID]),
            knownIDs: legacy.migratedKnownIDs.union([legacyID]),
            legacyEntries: legacy.entries)
        XCTAssertEqual(repeated.aliases, result.aliases)
        XCTAssertEqual(repeated.shadowReadIDs, result.shadowReadIDs)
        XCTAssertEqual(repeated.shadowKnownIDs, result.shadowKnownIDs)
        assertEntries(repeated.entries, equalTo: result.entries)

        let knownOnlyLegacy = legacyProjection([fixture.record], knownIDs: [legacyID])
        let knownOnly = ActJournalFeedProjection.project(
            records: [fixture.record],
            journalsByRecordKey: [fixture.record.recordKey: fixture.journal], today: today,
            readIDs: knownOnlyLegacy.migratedReadIDs,
            knownIDs: knownOnlyLegacy.migratedKnownIDs,
            legacyEntries: knownOnlyLegacy.entries)
        XCTAssertTrue(knownOnly.shadowReadIDs.isEmpty)
        XCTAssertEqual(knownOnly.shadowKnownIDs, [fixture.event.id])
        XCTAssertTrue(try XCTUnwrap(knownOnly.entries.first).isUnread)
    }

    func testCurrentTitleAndLateNumberEnrichPresentationWithoutChangingEventID() throws {
        let published = CaseAct(id: "stable-published-act", title: "Определение",
                                date: rawDate(today), courtShort: "Апелляционный суд",
                                instanceLevel: .appeal)
        let current = CaseAct(id: published.id, title: "Определение от 9 сентября 2026 года",
                              date: published.date, courtShort: published.courtShort,
                              instanceLevel: .appeal)
        let fixture = try fixture(actID: published.id, level: .appeal,
                                  instanceNumber: "66а-10/2026",
                                  currentActs: [current], publishedActs: [published])
        XCTAssertNotEqual(fixture.event.evidence.event, current.title)
        let (_, result) = project([fixture.record],
                                  journals: [fixture.record.recordKey: fixture.journal])
        let entry = try XCTUnwrap(result.entries.first)
        XCTAssertEqual(entry.id, fixture.event.id)
        XCTAssertEqual(entry.actID, published.id)
        XCTAssertEqual(entry.text, "Опубликован судебный акт: \(current.title)")
        XCTAssertEqual(entry.instanceCaseNumber, "66а-10/2026")
        XCTAssertEqual(result.aliases.first?.eventID, fixture.event.id)
    }

    func testProcessDateWindowUsesEvidenceDateAndKeepsInclusive45DayBoundary() throws {
        let dates = [-1, 0, 45, 46].map { DateUtil.addDays(today, -$0) }
        let acts = dates.enumerated().map { index, date in
            CaseAct(id: "window-act-\(index)", title: "Акт \(index)",
                    date: rawDate(date), courtShort: "1-я инстанция", instanceLevel: .first)
        }
        let fixture = try fixture(actID: acts[0].id, level: .first,
                                  instanceNumber: "3-18/2026", currentActs: acts,
                                  publishedActs: acts, observedAt: DateUtil.addDays(today, 100))
        let (legacy, result) = project([fixture.record],
                                       journals: [fixture.record.recordKey: fixture.journal])
        XCTAssertEqual(legacy.entries.count, 2)
        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(Set(result.entries.map(\.actID)), [acts[1].id, acts[2].id])
        XCTAssertEqual(Set(result.aliases.map(\.eventID)),
                       Set(result.entries.map(\.id)))
        XCTAssertTrue(result.unmappedLegacyActs.isEmpty)
        XCTAssertTrue(result.unmappedEvents.isEmpty,
                      "valid acts outside the feed window are quietly excluded")
    }

    func testDuplicateEventsOwnersAndCurrentActIDsFailClosed() throws {
        let first = try fixture(recordKey: "duplicate-one", actID: "duplicate-act",
                                nativeCardID: "shared-native-card")
        let second = try fixture(recordKey: "duplicate-two", actID: "duplicate-act",
                                 nativeCardID: "shared-native-card")
        XCTAssertEqual(first.event.id, second.event.id)
        let duplicateRecords = [first.record, second.record]
        let duplicateLegacy = legacyProjection(duplicateRecords)
        let duplicateResult = ActJournalFeedProjection.project(
            records: duplicateRecords,
            journalsByRecordKey: [first.record.recordKey: first.journal,
                                  second.record.recordKey: second.journal], today: today,
            readIDs: Set(duplicateLegacy.entries.map(\.id)),
            knownIDs: Set(duplicateLegacy.entries.map(\.id)),
            legacyEntries: duplicateLegacy.entries)
        XCTAssertTrue(duplicateResult.entries.isEmpty)
        XCTAssertTrue(duplicateResult.aliases.isEmpty)
        XCTAssertTrue(duplicateResult.shadowReadIDs.isEmpty)
        XCTAssertTrue(duplicateResult.shadowKnownIDs.isEmpty)
        XCTAssertEqual(duplicateResult.unmappedEvents.map(\.reason),
                       [.duplicateEventID, .duplicateEventID])
        XCTAssertEqual(duplicateResult.unmappedLegacyActs.map(\.reason),
                       [.duplicateEventID, .duplicateEventID])

        let ambiguousContext = first.context
        let originalOwner = first.record.instances[0]
        let duplicateOwner = originalOwner
        let firstSnapshot = try XCTUnwrap(first.record.snapshot)
        let ambiguousInput = input(
            recordKey: first.record.recordKey, caseNumber: first.record.caseNumber,
            client: first.record.client, acts: [first.currentAct],
            instances: [originalOwner, duplicateOwner], context: ambiguousContext,
            snapshot: firstSnapshot)
        let ambiguousLegacy = legacyProjection([ambiguousInput])
        let ambiguous = ActJournalFeedProjection.project(
            records: [ambiguousInput],
            journalsByRecordKey: [ambiguousInput.recordKey: first.journal], today: today,
            readIDs: Set(ambiguousLegacy.entries.map(\.id)), knownIDs: [],
            legacyEntries: ambiguousLegacy.entries)
        XCTAssertTrue(ambiguous.entries.isEmpty)
        XCTAssertTrue(ambiguous.aliases.isEmpty)
        XCTAssertEqual(ambiguous.unmappedEvents.map(\.reason), [.ambiguousCurrentOwner])
        XCTAssertEqual(ambiguous.unmappedLegacyActs.map(\.reason), [.ambiguousCurrentOwner])

        let duplicateActInput = input(
            recordKey: first.record.recordKey, caseNumber: first.record.caseNumber,
            client: first.record.client, acts: [first.currentAct, first.currentAct],
            instances: [originalOwner], context: ambiguousContext,
            snapshot: firstSnapshot)
        let duplicateActLegacy = legacyProjection([duplicateActInput])
        let duplicateActResult = ActJournalFeedProjection.project(
            records: [duplicateActInput],
            journalsByRecordKey: [duplicateActInput.recordKey: first.journal], today: today,
            readIDs: Set(duplicateActLegacy.entries.map(\.id)), knownIDs: [],
            legacyEntries: duplicateActLegacy.entries)
        XCTAssertTrue(duplicateActResult.entries.isEmpty)
        XCTAssertTrue(duplicateActResult.aliases.isEmpty)
        XCTAssertEqual(duplicateActResult.unmappedEvents.map(\.reason), [.duplicateCurrentAct])
        XCTAssertEqual(duplicateActResult.unmappedLegacyActs.map(\.reason),
                       [.duplicateCurrentAct, .duplicateCurrentAct])
    }

    func testSourceConflictDoesNotTransferLegacyMarks() throws {
        let fixture = try fixture(actID: "source-conflict-act")
        var evidence = fixture.event.evidence
        evidence.sourceCardID = "stale-source-card"
        let altered = replace(fixture.event, evidence: evidence)
        var journal = fixture.journal
        journal.events = [altered]
        let legacy = legacyProjection([fixture.record], readIDs: [])
        let legacyID = try XCTUnwrap(legacy.entries.first?.id)
        let result = ActJournalFeedProjection.project(
            records: [fixture.record], journalsByRecordKey: [fixture.record.recordKey: journal],
            today: today, readIDs: [legacyID], knownIDs: [legacyID],
            legacyEntries: legacy.entries)

        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(result.aliases.isEmpty)
        XCTAssertTrue(result.shadowReadIDs.isEmpty)
        XCTAssertTrue(result.shadowKnownIDs.isEmpty)
        XCTAssertEqual(result.unmappedEvents.map(\.reason), [.sourceConflict])
        XCTAssertEqual(result.unmappedLegacyActs.map(\.reason), [.sourceConflict])
    }

    func testAliasRequiresExactExpectedLegacyIDAndUniqueRawLegacyIDs() throws {
        let fixture = try fixture(actID: "exact-legacy-id-act")
        let legacy = legacyProjection([fixture.record])
        let legacyID = try XCTUnwrap(legacy.entries.first?.id)

        var changedIDEntries = legacy.entries
        changedIDEntries[0].id += "-changed"
        let changedID = ActJournalFeedProjection.project(
            records: [fixture.record],
            journalsByRecordKey: [fixture.record.recordKey: fixture.journal], today: today,
            readIDs: [legacyID], knownIDs: [legacyID], legacyEntries: changedIDEntries)
        XCTAssertTrue(changedID.aliases.isEmpty)
        XCTAssertTrue(changedID.shadowReadIDs.isEmpty)
        XCTAssertTrue(changedID.shadowKnownIDs.isEmpty)
        XCTAssertEqual(changedID.unmappedEvents.map(\.reason), [.legacyIDMismatch])
        XCTAssertEqual(changedID.unmappedLegacyActs.map(\.reason), [.legacyIDMismatch])

        var unmatchedDuplicate = legacy.entries[0]
        unmatchedDuplicate.actID = "unmatched-act-row"
        let duplicateID = ActJournalFeedProjection.project(
            records: [fixture.record],
            journalsByRecordKey: [fixture.record.recordKey: fixture.journal], today: today,
            readIDs: [legacyID], knownIDs: [legacyID],
            legacyEntries: legacy.entries + [unmatchedDuplicate])
        XCTAssertTrue(duplicateID.aliases.isEmpty)
        XCTAssertTrue(duplicateID.shadowReadIDs.isEmpty)
        XCTAssertTrue(duplicateID.shadowKnownIDs.isEmpty)
        XCTAssertEqual(duplicateID.unmappedEvents.map(\.reason), [.ambiguousAlias])
        XCTAssertEqual(duplicateID.unmappedLegacyActs.count, 2)
        XCTAssertEqual(duplicateID.unmappedLegacyActs.map(\.legacyID), [legacyID, legacyID])
        XCTAssertEqual(duplicateID.unmappedLegacyActs.map(\.reason),
                       [.ambiguousAlias, .ambiguousAlias])
    }

    func testCrossFamilyLegacyIDCollisionDoesNotTransferMarks() throws {
        let fixture = try fixture(actID: "cross-family-act")
        var snapshot = try XCTUnwrap(fixture.record.snapshot)
        snapshot.sessions = [StoredSession(
            dateRaw: fixture.currentAct.date, time: nil, room: nil,
            event: fixture.currentAct.id, result: nil, court: fixture.owner.court,
            levelRaw: fixture.owner.level.rawValue,
            sourceCardID: fixture.sourceCardID)]
        let record = input(
            recordKey: fixture.record.recordKey, caseNumber: fixture.record.caseNumber,
            client: fixture.record.client, acts: [fixture.currentAct],
            instances: [fixture.owner], context: fixture.context, snapshot: snapshot)
        let legacy = legacyProjection([record])
        XCTAssertEqual(legacy.entries.map(\.kind), [.movement, .act])
        let legacyID = try XCTUnwrap(legacy.entries.first?.id)
        XCTAssertEqual(legacy.entries.map(\.id), [legacyID, legacyID])

        let result = ActJournalFeedProjection.project(
            records: [record], journalsByRecordKey: [record.recordKey: fixture.journal],
            today: today, readIDs: [legacyID], knownIDs: [legacyID],
            legacyEntries: legacy.entries)

        XCTAssertTrue(result.aliases.isEmpty)
        XCTAssertTrue(result.shadowReadIDs.isEmpty)
        XCTAssertTrue(result.shadowKnownIDs.isEmpty)
        XCTAssertEqual(result.unmappedEvents.map(\.reason), [.ambiguousAlias])
        XCTAssertEqual(result.unmappedLegacyActs.map(\.reason), [.ambiguousAlias])
    }

    func testDateConflictAndUnprovedActMirrorChangeStayUnmapped() throws {
        let oldDate = DateUtil.addDays(today, -1)
        let dateConflict = try fixture(actID: "date-conflict-act", currentDate: today,
                                       publishedDate: oldDate)
        let (conflictLegacy, conflict) = project(
            [dateConflict.record], journals: [dateConflict.record.recordKey: dateConflict.journal],
            readIDs: [], knownIDs: [])
        let oldLegacyID = try XCTUnwrap(conflictLegacy.entries.first?.id)
        let conflictWithMarks = ActJournalFeedProjection.project(
            records: [dateConflict.record],
            journalsByRecordKey: [dateConflict.record.recordKey: dateConflict.journal], today: today,
            readIDs: [oldLegacyID], knownIDs: [oldLegacyID],
            legacyEntries: conflictLegacy.entries)
        XCTAssertTrue(conflict.entries.isEmpty)
        XCTAssertTrue(conflictWithMarks.shadowReadIDs.isEmpty)
        XCTAssertTrue(conflictWithMarks.shadowKnownIDs.isEmpty)
        XCTAssertEqual(conflictWithMarks.unmappedEvents.map(\.reason), [.dateConflict])
        XCTAssertEqual(conflictWithMarks.unmappedLegacyActs.map(\.reason), [.dateConflict])

        let oldAct = CaseAct(id: "old-mirror-act", title: "Определение",
                             date: rawDate(today), courtShort: "1-я инстанция",
                             instanceLevel: .first)
        let newAct = CaseAct(id: "new-mirror-act", title: "Определение",
                             date: oldAct.date, courtShort: oldAct.courtShort,
                             instanceLevel: .first)
        let mirror = try fixture(actID: newAct.id, level: .first,
                                 instanceNumber: "3-18/2026",
                                 currentActs: [newAct], publishedActs: [oldAct])
        let mirrorLegacy = legacyProjection([mirror.record])
        let mirrorID = try XCTUnwrap(mirrorLegacy.entries.first?.id)
        let mirrorResult = ActJournalFeedProjection.project(
            records: [mirror.record],
            journalsByRecordKey: [mirror.record.recordKey: mirror.journal], today: today,
            readIDs: [mirrorID], knownIDs: [mirrorID], legacyEntries: mirrorLegacy.entries)
        XCTAssertTrue(mirrorResult.entries.isEmpty)
        XCTAssertTrue(mirrorResult.aliases.isEmpty)
        XCTAssertTrue(mirrorResult.shadowReadIDs.isEmpty)
        XCTAssertTrue(mirrorResult.shadowKnownIDs.isEmpty)
        XCTAssertEqual(mirrorResult.unmappedEvents.map(\.reason), [.missingCurrentAct])
        XCTAssertEqual(mirrorResult.unmappedLegacyActs.map(\.reason), [.noPublishedEvent])
    }

    private struct Fixture {
        let record: LegacyFeedRecordInput
        let journal: CaseEventJournal
        let event: CaseEvent
        let currentAct: CaseAct
        let owner: CaseInstance
        let context: MovementContext
        let sourceCardID: String
    }

    private func fixture(
        recordKey: String = "syktsud.komi.sudrf.ru/2-9143/2025",
        caseNumber: String = "2-9143/2025",
        client: String = "Иванов А. А.",
        actID: String,
        level: CaseInstance.Level = .first,
        instanceNumber: String? = nil,
        knownCardNumber: String? = nil,
        note: String? = nil,
        currentDate: Date? = nil,
        publishedDate: Date? = nil,
        currentActs: [CaseAct]? = nil,
        publishedActs: [CaseAct]? = nil,
        nativeCardID: String? = nil,
        observedAt: Date? = nil
    ) throws -> Fixture {
        let date = currentDate ?? today
        let currentAct = currentActs?.first ?? CaseAct(
            id: actID, title: "Определение", date: rawDate(date),
            courtShort: "1-я инстанция", instanceLevel: level)
        let currentActs = currentActs ?? [currentAct]
        let owner = instance(level: level,
                             caseNumber: instanceNumber ?? caseNumber,
                             actIDs: currentActs.map(\.id), note: note)
        let card = knownCard(level: level, number: knownCardNumber,
                             caseID: nativeCardID ?? "native-\(recordKey)")
        let context = context(caseNumber: caseNumber, nativeCardID: "base-\(recordKey)",
                              knownCards: [card])
        let observations = currentActs.map { observation($0, owner: owner, context: context) }
        let currentSnapshot = snapshot(observations)
        let record = input(recordKey: recordKey, caseNumber: caseNumber, client: client,
                           acts: currentActs, instances: [owner], context: context,
                           snapshot: currentSnapshot)
        let originalActs = publishedActs ?? currentActs.map { act in
            CaseAct(id: act.id, title: act.title,
                    date: rawDate(publishedDate ?? date), courtShort: act.courtShort,
                    instanceLevel: act.instanceLevel)
        }
        let originalObservations = originalActs.map {
            observation($0, owner: owner, context: context)
        }
        let journal = journalAfterPublishing(
            originalObservations, observedAt: observedAt ?? DateUtil.addDays(today, 100))
        let event = try XCTUnwrap(journal.events.first { $0.kind == .judicialActPublished })
        let sourceCardID = try XCTUnwrap(observations.first?.sourceCardID)
        return Fixture(record: record, journal: journal, event: event,
                       currentAct: currentAct, owner: owner, context: context,
                       sourceCardID: sourceCardID)
    }

    private func project(
        _ records: [LegacyFeedRecordInput],
        journals: [String: CaseEventJournal],
        readIDs: Set<String> = [],
        knownIDs: Set<String> = []
    ) -> (LegacyFeedProjectionResult, ActJournalFeedProjectionResult) {
        let legacy = legacyProjection(records, readIDs: readIDs, knownIDs: knownIDs)
        let shadow = ActJournalFeedProjection.project(
            records: records, journalsByRecordKey: journals, today: today,
            readIDs: legacy.migratedReadIDs, knownIDs: legacy.migratedKnownIDs,
            legacyEntries: legacy.entries)
        return (legacy, shadow)
    }

    private func legacyProjection(_ records: [LegacyFeedRecordInput],
                                  readIDs: Set<String> = [], knownIDs: Set<String> = [])
        -> LegacyFeedProjectionResult {
        LegacyFeedProjection.project(records: records, today: today, readIDs: readIDs,
                                     knownIDs: knownIDs, migrationState: .init())
    }

    private func journalAfterPublishing(_ observations: [StoredActObservation],
                                        observedAt: Date) -> CaseEventJournal {
        let admitted = admittedCourts(observations)
        let seeded = transition(journal: CaseEventJournal(), snapshot: snapshot([]),
                                admittedCourts: admitted, complete: true,
                                observedAt: observedAt)
        var journal = CaseEventJournal()
        journal.semanticBaselines = seeded.baselines
        let published = transition(journal: journal, snapshot: snapshot(observations),
                                   admittedCourts: admitted, complete: true,
                                   observedAt: observedAt)
        journal.events = published.derivation.events
        journal.semanticBaselines = published.baselines
        return journal
    }

    private func quietJournal(observations: [StoredActObservation]) -> CaseEventJournal {
        let seeded = transition(journal: CaseEventJournal(), snapshot: snapshot(observations),
                                admittedCourts: admittedCourts(observations), complete: true,
                                observedAt: DateUtil.addDays(today, 100))
        var journal = CaseEventJournal()
        journal.semanticBaselines = seeded.baselines
        return journal
    }

    private func transition(journal: CaseEventJournal, snapshot: CaseSnapshot,
                            admittedCourts: [String: [String: String]], complete: Bool,
                            observedAt: Date)
        -> (baselines: CaseEventBaselines?, derivation: CaseEventDerivationResult) {
        CaseEventBaselineTransition.refresh(
            journal: journal, freshSnapshot: snapshot, globalSnapshot: snapshot,
            admittedCourts: admittedCourts,
            attempt: SourceAttempt(
                kind: complete ? .usableSnapshot : .partial,
                provenance: .init(operation: .movement, sourceFamily: "sudrf",
                                  host: "syktsud--komi.sudrf.ru", observedAt: observedAt)),
            isComplete: complete)
    }

    private func admittedCourts(_ observations: [StoredActObservation])
        -> [String: [String: String]] {
        var cards = [String: String]()
        for observation in observations {
            if let sourceCardID = observation.sourceCardID {
                cards[sourceCardID] = sourceCardID
            }
        }
        return ["scope": cards]
    }

    private func input(recordKey: String, caseNumber: String, client: String,
                       acts: [CaseAct], instances: [CaseInstance], context: MovementContext,
                       snapshot: CaseSnapshot, unreadByCase: Bool = true)
        -> LegacyFeedRecordInput {
        let movement = CaseMovement(uid: "", caseNumber: caseNumber, inForce: false,
                                    instances: instances, complaints: [:], acts: acts)
        return LegacyFeedRecordInput(
            recordKey: recordKey, caseNumber: caseNumber, client: client,
            unreadByCase: unreadByCase, snapshot: snapshot, movement: movement,
            context: context, enforcementRecords: [])
    }

    private func snapshot(_ observations: [StoredActObservation]) -> CaseSnapshot {
        CaseSnapshot(uid: "", inForce: false, category: nil, partiesShort: "",
                     leadCharges: nil, secondPartyLine: nil, stageRaw: "first", stageTag: "",
                     statusText: "", statusChipRaw: "gray", lastEvent: "", nextEvent: "",
                     nextChipRaw: "gray", steps: [], sessions: [], deadlines: [],
                     actsFingerprint: nil,
                     semanticProjectionVersion: CaseEventJournal.currentDerivationVersion,
                     instanceObservations: [], actObservations: observations,
                     complaintObservations: [])
    }

    private func observation(_ act: CaseAct, owner: CaseInstance,
                             context: MovementContext) -> StoredActObservation {
        StoredActObservation(
            sourceCardID: CaseSnapshotSourceIdentity.sourceCardID(for: owner, context: context),
            sourceActID: act.id, title: act.title, dateRaw: act.date,
            court: act.courtShort, levelRaw: owner.level.rawValue)
    }

    private func context(caseNumber: String, nativeCardID: String,
                         knownCards: [KnownCard]) -> MovementContext {
        var value = MovementContext(
            branchRaw: "general", region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru", displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд", courtLevelRaw: "district",
            courtCode: "11RS0001", cartotekaId: "g1", cartotekaLevelRaw: "district",
            caseNumber: caseNumber, caseID: nativeCardID)
        value.baseInstanceLevelRaw = CaseInstance.Level.first.rawValue
        value.knownCards = knownCards
        return value
    }

    private func knownCard(level: CaseInstance.Level, number: String?, caseID: String) -> KnownCard {
        KnownCard(domain: "syktsud--komi.sudrf.ru",
                  courtTitle: "Сыктывкарский городской суд", caseID: caseID,
                  caseUID: "guid-\(caseID)", deloID: level == .material ? "m" : "g1",
                  new: "0", caseNumber: number, levelRaw: level.rawValue,
                  cartotekaID: level == .material ? "m" : "g1")
    }

    private func instance(level: CaseInstance.Level, caseNumber: String,
                          actIDs: [String], note: String?) -> CaseInstance {
        CaseInstance(level: level, court: "Сыктывкарский городской суд",
                     caseNumber: caseNumber, judge: "Судья А",
                     domain: "syktsud.komi.sudrf.ru", foundByUID: false,
                     result: nil, sessions: [], actIDs: actIDs, note: note)
    }

    private func replace(_ event: CaseEvent, evidence: CaseEventEvidence) -> CaseEvent {
        CaseEvent(id: event.id, kind: event.kind, observedAtRef: event.observedAtRef,
                  evidence: evidence, occurrence: event.occurrence)
    }

    private func rawDate(_ date: Date) -> String {
        let components = DateUtil.cal.dateComponents([.day, .month, .year], from: date)
        return String(format: "%02d.%02d.%04d", components.day ?? 0,
                      components.month ?? 0, components.year ?? 0)
    }

    private func assertEntries(_ actual: [FeedEntry], equalTo expected: [FeedEntry],
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(actual, expected) {
            XCTAssertEqual(actual.id, expected.id, file: file, line: line)
            XCTAssertEqual(actual.dayHead, expected.dayHead, file: file, line: line)
            XCTAssertEqual(actual.date, expected.date, file: file, line: line)
            XCTAssertEqual(actual.time, expected.time, file: file, line: line)
            XCTAssertEqual(actual.recordKey, expected.recordKey, file: file, line: line)
            XCTAssertEqual(actual.caseNumber, expected.caseNumber, file: file, line: line)
            XCTAssertEqual(actual.client, expected.client, file: file, line: line)
            XCTAssertEqual(actual.kind, expected.kind, file: file, line: line)
            XCTAssertEqual(actual.text, expected.text, file: file, line: line)
            XCTAssertEqual(actual.actID, expected.actID, file: file, line: line)
            XCTAssertEqual(actual.isUnread, expected.isUnread, file: file, line: line)
            XCTAssertEqual(actual.instanceCaseNumber, expected.instanceCaseNumber,
                           file: file, line: line)
            XCTAssertEqual(actual.instanceLevel, expected.instanceLevel, file: file, line: line)
            XCTAssertEqual(actual.sourceCardID, expected.sourceCardID, file: file, line: line)
            XCTAssertEqual(actual.sourceInstanceID, expected.sourceInstanceID,
                           file: file, line: line)
            XCTAssertEqual(actual.previousRegistrationNumber, expected.previousRegistrationNumber,
                           file: file, line: line)
        }
    }
}
