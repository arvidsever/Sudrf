import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class HearingJournalFeedProjectionTests: XCTestCase {
    private let today = DateUtil.parse("10.09.2026")!
    private let baseRecordKey = "syktsud.komi.sudrf.ru/2-9143/2025"
    private let baseCaseNumber = "2-9143/2025"

    func testPersistedScheduleStillProjectsAfterItsHearingDate() throws {
        let fixture = try fixture(recordKey: "scheduled/2-1/2026",
                                  date: DateUtil.parse("08.09.2026")!,
                                  time: "11:23", event: "Судебное заседание")
        let journal = try journal(for: fixture, before: [], observedAt: DateUtil.parse("07.09.2026")!)
        let (legacy, shadow) = project(fixture.record, journal: journal)

        XCTAssertEqual(legacy.entries.map(\.kind), [.hearing])
        XCTAssertEqual(shadow.entries.map(\.id), journal.events.map(\.id))
        XCTAssertEqual(shadow.aliases.map(\.legacyID), legacy.entries.map(\.id))
        XCTAssertEqual(shadow.unmappedLegacyHearings, [])
        XCTAssertEqual(shadow.unmappedEvents, [])
        XCTAssertEqual(shadow.fieldMismatches, [])
        assertEntry(shadow.entries[0], matches: legacy.entries[0], id: journal.events[0].id)
    }

    func testPostponedEventUsesCurrentExactSessionAndResult() throws {
        let before = try session(date: DateUtil.parse("09.09.2026")!,
                                 time: "10:15", event: "Судебное заседание")
        let fixture = try fixture(recordKey: "postponed/2-2/2026",
                                  date: DateUtil.parse("09.09.2026")!, time: "10:15",
                                  event: "Судебное заседание", result: "Заседание отложено")
        var old = before
        old.sourceCardID = fixture.sourceCardID
        old.caseNumber = fixture.session.caseNumber
        old.levelRaw = fixture.session.levelRaw
        let journal = try journal(for: fixture, before: [old],
                                  observedAt: DateUtil.parse("08.09.2026")!)
        XCTAssertEqual(journal.events.map(\.kind), [.hearingPostponed])

        let (legacy, shadow) = project(fixture.record, journal: journal)
        XCTAssertEqual(shadow.aliases.map(\.eventID), journal.events.map(\.id))
        XCTAssertEqual(shadow.fieldMismatches, [])
        assertEntry(try XCTUnwrap(shadow.entries.first),
                    matches: try XCTUnwrap(legacy.entries.first), id: journal.events[0].id)
    }

    func testScheduledAndPostponedEventsForOneOccurrenceAreBothUnmapped() throws {
        let scheduled = try fixture(recordKey: "conflict/2-3/2026",
                                    date: DateUtil.parse("09.09.2026")!,
                                    time: "09:30", event: "Судебное заседание")
        var journal = try journal(for: scheduled, before: [],
                                  observedAt: DateUtil.parse("07.09.2026")!)
        let postponed = try withCurrentSession(
            scheduled, result: "Заседание отложено")
        let transition = refresh(
            journal, snapshot: try snapshot(for: postponed, sessions: [postponed.session]),
            admittedCourts: admitted(postponed), observedAt: DateUtil.parse("10.09.2026")!,
            complete: true)
        XCTAssertEqual(transition.derivation.events.map(\.kind), [.hearingPostponed])
        journal.semanticBaselines = transition.baselines
        try journal.append(journal.identifyingOccurrences(
            transition.derivation.events, originKey: postponed.record.recordKey))
        XCTAssertEqual(Set(journal.events.map(\.kind)), [.hearingScheduled, .hearingPostponed])

        let (legacy, shadow) = project(postponed.record, journal: journal)
        XCTAssertEqual(legacy.entries.count, 1)
        XCTAssertTrue(shadow.entries.isEmpty)
        XCTAssertTrue(shadow.aliases.isEmpty)
        XCTAssertTrue(shadow.shadowReadIDs.isEmpty)
        XCTAssertEqual(shadow.unmappedEvents.map(\.reason), [
            .ambiguousEventForCurrentSession, .ambiguousEventForCurrentSession
        ])
        XCTAssertEqual(shadow.unmappedLegacyHearings.map(\.reason), [
            .ambiguousEventForCurrentSession
        ])
    }

    func testOutOfWindowEvidenceDateCannotHideAnInWindowCurrentOccurrence() throws {
        let fixture = try fixture(recordKey: "bad-window/2-3a/2026",
                                  date: DateUtil.addDays(today, -1),
                                  time: "09:30", event: "Судебное заседание")
        let journal = try journal(for: fixture, before: [],
                                  observedAt: DateUtil.addDays(today, -2))
        let scheduled = try XCTUnwrap(journal.events.first)

        for date in [DateUtil.addDays(today, 1), DateUtil.addDays(today, -46)] {
            var evidence = scheduled.evidence
            evidence.dateRaw = rawDate(date)
            let altered = replacing(scheduled, evidence: evidence)
            let result = project(fixture.record, journal: makeJournal([altered])).1

            XCTAssertTrue(result.aliases.isEmpty)
            XCTAssertEqual(result.unmappedEvents.map(\.reason), [.dateConflict])
            XCTAssertEqual(result.unmappedLegacyHearings.map(\.reason), [.dateConflict])
        }
    }

    func testOutOfWindowCompetingEventStillBlocksReadAndKnownAlias() throws {
        let scheduled = try fixture(recordKey: "conflict-window/2-3b/2026",
                                    date: DateUtil.addDays(today, -1),
                                    time: "09:31", event: "Судебное заседание")
        var journal = try journal(for: scheduled, before: [],
                                  observedAt: DateUtil.addDays(today, -2))
        let postponed = try withCurrentSession(scheduled, result: "Заседание отложено")
        let transition = refresh(
            journal, snapshot: try snapshot(for: postponed, sessions: [postponed.session]),
            admittedCourts: admitted(postponed), observedAt: today, complete: true)
        journal.semanticBaselines = transition.baselines
        try journal.append(journal.identifyingOccurrences(
            transition.derivation.events, originKey: postponed.record.recordKey))
        XCTAssertEqual(Set(journal.events.map(\.kind)), [.hearingScheduled, .hearingPostponed])

        let scheduledEvent = try XCTUnwrap(journal.events.first { $0.kind == .hearingScheduled })
        var wrongDate = scheduledEvent.evidence
        wrongDate.dateRaw = rawDate(DateUtil.addDays(today, 1))
        journal.events = [replacing(scheduledEvent, evidence: wrongDate)]
            + journal.events.filter { $0.id != scheduledEvent.id }

        let legacy = legacyProjection([postponed.record])
        let legacyID = try XCTUnwrap(legacy.entries.first?.id)
        let result = project(postponed.record, journal: journal,
                             readIDs: [legacyID], knownIDs: [legacyID]).1
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertTrue(result.aliases.isEmpty)
        XCTAssertTrue(result.shadowReadIDs.isEmpty)
        XCTAssertTrue(result.shadowKnownIDs.isEmpty)
        XCTAssertEqual(Set(result.unmappedEvents.map(\.reason)),
                       [.ambiguousEventForCurrentSession])
        XCTAssertEqual(result.unmappedLegacyHearings.map(\.reason), [
            .ambiguousEventForCurrentSession
        ])
    }

    func testRescheduledEvidenceIsReportedWithoutGuessingEitherOccurrence() throws {
        let before = try session(date: DateUtil.parse("09.09.2026")!,
                                 time: "10:00", event: "Судебное заседание")
        let initial = try fixture(recordKey: "rescheduled/2-4/2026",
                                  date: DateUtil.parse("09.09.2026")!, time: "10:00",
                                  event: "Судебное заседание")
        let postponed = try withCurrentSession(initial, result: "Заседание отложено")
        let next = try session(date: DateUtil.parse("14.09.2026")!,
                               time: "12:00", event: "Судебное заседание",
                               sourceCardID: initial.sourceCardID,
                               caseNumber: initial.session.caseNumber)
        let rescheduled = try withCurrentSessions(postponed, [postponed.session, next])
        var old = before
        old.sourceCardID = initial.sourceCardID
        old.caseNumber = initial.session.caseNumber
        let journal = try journal(for: rescheduled, before: [old],
                                  observedAt: DateUtil.parse("08.09.2026")!)
        XCTAssertEqual(journal.events.map(\.kind), [.hearingRescheduled])

        let (legacy, shadow) = project(rescheduled.record, journal: journal)
        XCTAssertEqual(legacy.entries.map(\.text), ["Заседание отложено"])
        XCTAssertTrue(shadow.entries.isEmpty)
        XCTAssertTrue(shadow.aliases.isEmpty)
        XCTAssertEqual(shadow.unmappedEvents.map(\.reason), [.rescheduledOccurrenceUnproven])
        XCTAssertEqual(shadow.unmappedLegacyHearings.map(\.reason), [
            .rescheduledOccurrenceUnproven
        ])

        var outOfWindowEvidence = journal.events[0].evidence
        outOfWindowEvidence.previousDateRaw = rawDate(DateUtil.addDays(today, 1))
        outOfWindowEvidence.dateRaw = rawDate(DateUtil.addDays(today, -46))
        let staleEvidence = replacing(journal.events[0], evidence: outOfWindowEvidence)
        let staleResult = project(rescheduled.record, journal: makeJournal([staleEvidence])).1
        XCTAssertEqual(staleResult.unmappedEvents.map(\.reason), [
            .rescheduledOccurrenceUnproven
        ])
        XCTAssertEqual(staleResult.unmappedLegacyHearings.map(\.reason), [
            .rescheduledOccurrenceUnproven
        ])
    }

    func testCurrentSnapshotAndQuietBaselineNeverCreateJournalPresence() throws {
        let fixture = try fixture(recordKey: "quiet/2-5/2026",
                                  date: DateUtil.parse("09.09.2026")!,
                                  time: "10:45", event: "Судебное заседание")
        let seeded = try quietJournal(for: fixture, observedAt: DateUtil.parse("08.09.2026")!)
        XCTAssertTrue(seeded.events.isEmpty)

        let (legacy, shadow) = project(fixture.record, journal: seeded)
        XCTAssertEqual(legacy.entries.count, 1)
        XCTAssertTrue(shadow.entries.isEmpty)
        XCTAssertTrue(shadow.aliases.isEmpty)
        XCTAssertEqual(shadow.unmappedLegacyHearings.map(\.reason), [.noJournalHearingEvent])
        XCTAssertTrue(shadow.unmappedEvents.isEmpty)
    }

    func testInclusiveProcessDateWindowIgnoresObservedAtAndKeepsOutsideRowsQuiet() throws {
        let offsets = [0, 45, -1, 46]
        let fixtures = try offsets.enumerated().map { index, offset in
            let date = DateUtil.addDays(today, -offset)
            let value = try fixture(recordKey: "window-\(index)/2-\(index)/2026",
                                    date: date, time: "10:0\(index)",
                                    event: "Заседание \(index)")
            let eventObservedAt = DateUtil.addDays(date, -1)
            return (value, try journal(for: value, before: [], observedAt: eventObservedAt))
        }
        let records = fixtures.map(\.0.record)
        let journals = Dictionary(uniqueKeysWithValues: fixtures.map {
            ($0.0.record.recordKey, $0.1)
        })
        let legacy = legacyProjection(records)
        let shadow = HearingJournalFeedProjection.project(
            records: records, journalsByRecordKey: journals, today: today,
            readIDs: legacy.migratedReadIDs, knownIDs: legacy.migratedKnownIDs,
            legacyEntries: legacy.entries)

        XCTAssertEqual(Set(legacy.entries.map(\.recordKey)),
                       Set([fixtures[0].0.record.recordKey, fixtures[1].0.record.recordKey]))
        XCTAssertEqual(Set(shadow.entries.map(\.recordKey)), Set(legacy.entries.map(\.recordKey)))
        XCTAssertEqual(shadow.unmappedEvents, [])
        XCTAssertEqual(shadow.unmappedLegacyHearings, [])
        XCTAssertTrue(shadow.fieldMismatches.isEmpty)
    }

    func testOwnCourtPartialEventSurvivesFullRefreshCodableRestartAndReplay() throws {
        let fixture = try fixture(recordKey: "partial/2-6/2026",
                                  date: DateUtil.parse("09.09.2026")!,
                                  time: "14:00", event: "Судебное заседание")
        let baseline = try snapshot(for: fixture, sessions: [])
        var journal = CaseEventJournal()
        let seed = refresh(journal, snapshot: baseline, admittedCourts: admitted(fixture),
                           observedAt: DateUtil.parse("07.09.2026")!, complete: true)
        journal.semanticBaselines = seed.baselines

        let partial = refresh(
            journal, snapshot: try snapshot(for: fixture, sessions: [fixture.session]),
            admittedCourts: admitted(fixture), observedAt: DateUtil.parse("08.09.2026")!,
            complete: false)
        XCTAssertEqual(partial.derivation.events.map(\.kind), [.hearingScheduled])
        journal.semanticBaselines = partial.baselines
        try journal.append(journal.identifyingOccurrences(
            partial.derivation.events, originKey: fixture.record.recordKey))
        let persistedID = try XCTUnwrap(journal.events.first?.id)

        let full = refresh(
            journal, snapshot: try snapshot(for: fixture, sessions: [fixture.session]),
            admittedCourts: admitted(fixture), observedAt: DateUtil.parse("11.09.2026")!,
            complete: true)
        XCTAssertTrue(full.derivation.events.isEmpty)
        journal.semanticBaselines = full.baselines
        try journal.append(journal.identifyingOccurrences(
            full.derivation.events, originKey: fixture.record.recordKey))
        XCTAssertEqual(journal.events.map(\.id), [persistedID])

        let reopenedData = try JSONEncoder().encode(journal)
        var reopened = try JSONDecoder().decode(CaseEventJournal.self, from: reopenedData)
        XCTAssertEqual(reopened, journal)
        let (legacy, beforeRestart) = project(fixture.record, journal: journal)
        let (_, afterRestart) = project(fixture.record, journal: reopened)
        XCTAssertEqual(beforeRestart.aliases, afterRestart.aliases)
        XCTAssertEqual(beforeRestart.entries.map(\.id), afterRestart.entries.map(\.id))
        XCTAssertEqual(beforeRestart.shadowReadIDs, afterRestart.shadowReadIDs)
        XCTAssertEqual(beforeRestart.unmappedEvents, afterRestart.unmappedEvents)
        XCTAssertEqual(beforeRestart.fieldMismatches, afterRestart.fieldMismatches)
        XCTAssertEqual(legacy.entries.count, 1)

        let replay = refresh(
            reopened, snapshot: try snapshot(for: fixture, sessions: [fixture.session]),
            admittedCourts: admitted(fixture), observedAt: DateUtil.parse("12.09.2026")!,
            complete: true)
        XCTAssertTrue(replay.derivation.events.isEmpty)
        try reopened.append(reopened.identifyingOccurrences(
            replay.derivation.events, originKey: fixture.record.recordKey))
        XCTAssertEqual(reopened.events.map(\.id), [persistedID])
    }

    func testMissingWrongAndChangedEvidenceAndUnconfirmedOwnerFailClosed() throws {
        let fixture = try fixture(recordKey: "evidence/2-7/2026",
                                  date: DateUtil.parse("09.09.2026")!,
                                  time: "10:15", event: "Судебное заседание")
        let journal = try journal(for: fixture, before: [], observedAt: DateUtil.parse("08.09.2026")!)
        let event = try XCTUnwrap(journal.events.first)

        var wrongSource = event.evidence
        wrongSource.sourceCardID = "sudrf|other-host|g1|foreign"
        assertUnmapped(replacing(event, evidence: wrongSource), record: fixture.record,
                       reason: .sourceConflict)

        var wrongDate = event.evidence
        wrongDate.dateRaw = rawDate(DateUtil.addDays(today, -2))
        assertUnmapped(replacing(event, evidence: wrongDate), record: fixture.record,
                       reason: .dateConflict)

        var wrongTime = event.evidence
        wrongTime.time = "11:00"
        assertUnmapped(replacing(event, evidence: wrongTime), record: fixture.record,
                       reason: .timeConflict)

        var wrongLevel = event.evidence
        wrongLevel.instanceLevelRaw = CaseInstance.Level.appeal.rawValue
        assertUnmapped(replacing(event, evidence: wrongLevel), record: fixture.record,
                       reason: .levelConflict)

        var wrongResult = event.evidence
        wrongResult.value = "Иной результат"
        assertUnmapped(replacing(event, evidence: wrongResult), record: fixture.record,
                       reason: .resultConflict)

        var missingOccurrence = event.evidence
        missingOccurrence.occurrenceKey = nil
        assertUnmapped(replacing(event, evidence: missingOccurrence), record: fixture.record,
                       reason: .missingOccurrenceKey)

        var missingSource = event.evidence
        missingSource.sourceCardID = nil
        assertUnmapped(replacing(event, evidence: missingSource), record: fixture.record,
                       reason: .missingSourceCardID)

        var withoutOwnObservation = try snapshot(for: fixture, sessions: [fixture.session])
        withoutOwnObservation.instanceObservations = []
        let recordWithoutObservation = record(fixture, snapshot: withoutOwnObservation)
        assertUnmapped(event, record: recordWithoutObservation,
                       reason: .missingCurrentObservation)

        let recordWithoutOwner = record(fixture, instances: [])
        assertUnmapped(event, record: recordWithoutOwner, reason: .missingCurrentOwner)
    }

    func testDuplicateCurrentOccurrenceAndRawCrossFamilyIDCollisionBlockAliases() throws {
        let duplicated = try fixture(recordKey: "duplicate-key/2-8/2026",
                                     date: DateUtil.parse("09.09.2026")!,
                                     time: "10:00", event: "Судебное заседание",
                                     duplicateSession: true)
        let duplicateJournal = try journal(
            for: duplicated, before: [], observedAt: DateUtil.parse("08.09.2026")!)
        let duplicateResult = project(duplicated.record, journal: duplicateJournal).1
        XCTAssertTrue(duplicateResult.entries.isEmpty)
        XCTAssertEqual(duplicateResult.unmappedEvents.map(\.reason), [.duplicateCurrentSession])
        XCTAssertEqual(duplicateResult.unmappedLegacyHearings.map(\.reason), [
            .ambiguousAlias, .ambiguousAlias
        ])

        let collision = try fixture(
            recordKey: "cross-kind/2-9/2026", date: DateUtil.parse("09.09.2026")!,
            time: "10:30", event: "Судебное заседание", result: "Общее событие",
            additionalSessions: [StoredSession(
                dateRaw: "09.09.2026", time: "10:30", room: nil,
                event: "Дело передано", result: "Общее событие", court: "Тестовый суд",
                judge: nil, levelRaw: CaseInstance.Level.first.rawValue,
                caseNumber: "2-9143/2025")])
        let collisionJournal = try journal(
            for: collision, before: [], observedAt: DateUtil.parse("08.09.2026")!)
        let legacy = legacyProjection([collision.record],
                                      readIDs: [AppRouter.feedID(
                                        recordKey: collision.record.recordKey,
                                        date: collision.session.date!, time: "10:30",
                                        text: "Общее событие")],
                                      knownIDs: [AppRouter.feedID(
                                        recordKey: collision.record.recordKey,
                                        date: collision.session.date!, time: "10:30",
                                        text: "Общее событие")])
        XCTAssertEqual(legacy.entries.map(\.kind), [.hearing, .movement])
        XCTAssertEqual(legacy.entries.map(\.id).uniqued().count, 1)
        let shadow = HearingJournalFeedProjection.project(
            records: [collision.record],
            journalsByRecordKey: [collision.record.recordKey: collisionJournal],
            today: today, readIDs: legacy.migratedReadIDs,
            knownIDs: legacy.migratedKnownIDs, legacyEntries: legacy.entries)
        XCTAssertTrue(shadow.aliases.isEmpty)
        XCTAssertTrue(shadow.shadowReadIDs.isEmpty)
        XCTAssertTrue(shadow.shadowKnownIDs.isEmpty)
        XCTAssertEqual(shadow.unmappedEvents.map(\.reason), [.ambiguousAlias])
        XCTAssertEqual(shadow.unmappedLegacyHearings.map(\.reason), [.ambiguousAlias])
    }

    func testReadKnownAreSeparateAndMaterialAndPreviousRegistrationNavigationSurvive() throws {
        let material = try fixture(recordKey: "material/2-10/2026",
                                   date: DateUtil.parse("09.09.2026")!, time: "13:00",
                                   event: "Заседание", level: .material,
                                   caseNumber: "13-2471/2026")
        let materialJournal = try journal(
            for: material, before: [], observedAt: DateUtil.parse("08.09.2026")!)
        let materialLegacyID = try XCTUnwrap(legacyProjection([material.record]).entries.first?.id)
        let (materialLegacy, materialShadow) = project(
            material.record, journal: materialJournal,
            readIDs: [materialLegacyID], knownIDs: [])
        let materialEntry = try XCTUnwrap(materialShadow.entries.first)
        XCTAssertEqual(materialShadow.aliases.map(\.legacyID), [materialLegacyID])
        XCTAssertTrue(materialShadow.shadowReadIDs.contains(materialJournal.events[0].id))
        XCTAssertTrue(materialShadow.shadowKnownIDs.isEmpty)
        XCTAssertFalse(materialEntry.isUnread)
        XCTAssertEqual(materialEntry.instanceLevel, .material)
        XCTAssertEqual(materialEntry.sourceCardID, material.sourceCardID)
        XCTAssertEqual(materialEntry.sourceInstanceID, material.owner.id)
        XCTAssertEqual(materialEntry.instanceCaseNumber, "13-2471/2026")
        XCTAssertEqual(materialEntry.secondaryLabel, "Материал № 13-2471/2026")
        XCTAssertEqual(materialEntry.notificationSubtitle,
                       "\(material.record.caseNumber) · Материал № 13-2471/2026")
        XCTAssertEqual(materialLegacy.entries.first?.id, materialLegacyID)
        XCTAssertTrue(materialShadow.fieldMismatches.isEmpty)

        let knownOnly = project(material.record, journal: materialJournal,
                                readIDs: [], knownIDs: [materialLegacyID]).1
        XCTAssertTrue(knownOnly.shadowReadIDs.isEmpty)
        XCTAssertEqual(knownOnly.shadowKnownIDs, [materialJournal.events[0].id])
        XCTAssertTrue(try XCTUnwrap(knownOnly.entries.first).isUnread)

        let caseAlreadyRead = try fixture(
            recordKey: "case-read/2-10a/2026", date: DateUtil.parse("09.09.2026")!,
            time: "13:05", event: "Заседание", unreadByCase: false)
        let caseAlreadyReadJournal = try journal(
            for: caseAlreadyRead, before: [], observedAt: DateUtil.parse("08.09.2026")!)
        let caseAlreadyReadLegacyID = try XCTUnwrap(
            legacyProjection([caseAlreadyRead.record]).entries.first?.id)
        let caseAlreadyReadShadow = project(
            caseAlreadyRead.record, journal: caseAlreadyReadJournal,
            readIDs: [], knownIDs: [caseAlreadyReadLegacyID]).1
        XCTAssertTrue(caseAlreadyReadShadow.shadowReadIDs.isEmpty)
        XCTAssertEqual(caseAlreadyReadShadow.shadowKnownIDs,
                       [caseAlreadyReadJournal.events[0].id])
        XCTAssertFalse(try XCTUnwrap(caseAlreadyReadShadow.entries.first).isUnread)
        XCTAssertTrue(caseAlreadyReadShadow.fieldMismatches.isEmpty)

        let previous = try fixture(recordKey: "previous/2-11/2026",
                                   date: DateUtil.parse("09.09.2026")!, time: "13:15",
                                   event: "Заседание", level: .first,
                                   caseNumber: "9а-104/2026",
                                   note: "Предыдущая регистрация")
        let previousJournal = try journal(
            for: previous, before: [], observedAt: DateUtil.parse("08.09.2026")!)
        let (previousLegacy, previousShadow) = project(previous.record, journal: previousJournal)
        let previousEntry = try XCTUnwrap(previousShadow.entries.first)
        XCTAssertEqual(previousShadow.aliases.map(\.legacyID), previousLegacy.entries.map(\.id))
        XCTAssertEqual(previousEntry.instanceCaseNumber, "9а-104/2026")
        XCTAssertEqual(previousEntry.previousRegistrationNumber, "9а-104/2026")
        XCTAssertEqual(previousEntry.sourceCardID, previous.sourceCardID)
        XCTAssertEqual(previousEntry.sourceInstanceID, previous.owner.id)
        XCTAssertEqual(previousEntry.secondaryLabel,
                       "Предыдущая регистрация № 9а-104/2026")
        XCTAssertEqual(previousShadow.fieldMismatches, [])
    }

    func testMaterialHearingMigrationUsesFullLegacyProjectionExactlyOnce() throws {
        let material = try fixture(recordKey: "migration/2-10b/2026",
                                   date: DateUtil.addDays(today, -1), time: "13:00",
                                   event: "Судебное заседание", level: .material,
                                   caseNumber: "13-2471/2026")
        let movementSession = StoredSession(
            dateRaw: rawDate(DateUtil.addDays(today, -2)), time: "13:05", room: nil,
            event: "Дело передано", result: nil, court: "Сыктывкарский городской суд",
            judge: nil, levelRaw: CaseInstance.Level.first.rawValue,
            caseNumber: baseCaseNumber, sourceCardID: nil)
        let mixedSnapshot = try snapshot(for: material,
                                         sessions: [material.session, movementSession])
        let act = CaseAct(id: "migration-act", title: "Определение",
                          date: rawDate(today), courtShort: "Первая инстанция",
                          instanceLevel: .first)
        let movement = CaseMovement(uid: "", caseNumber: baseCaseNumber, inForce: false,
                                    instances: [material.owner], complaints: [:], acts: [act])
        let materialRecord = LegacyFeedRecordInput(
            recordKey: material.record.recordKey, caseNumber: baseCaseNumber,
            client: material.record.client, unreadByCase: true, snapshot: mixedSnapshot,
            movement: movement, context: material.context, enforcementRecords: [])
        let materialJournal = try journal(for: material, before: [],
                                          observedAt: DateUtil.addDays(today, -2))
        let legacyID = AppRouter.feedID(
            recordKey: material.record.recordKey, date: material.session.date!,
            time: material.session.time!, text: material.session.event)
        let materialID = AppRouter.materialFeedID(
            legacyID: legacyID, sourceCardID: material.sourceCardID)

        let fullLegacy = legacyProjection([materialRecord],
                                          readIDs: [legacyID], knownIDs: [legacyID])
        XCTAssertTrue(fullLegacy.entries.contains { $0.kind == .hearing })
        XCTAssertTrue(fullLegacy.entries.contains { $0.kind == .movement })
        XCTAssertTrue(fullLegacy.entries.contains { $0.kind == .act })
        XCTAssertFalse(fullLegacy.migratedReadIDs.contains(legacyID))
        XCTAssertFalse(fullLegacy.migratedKnownIDs.contains(legacyID))
        XCTAssertTrue(fullLegacy.migratedReadIDs.contains(materialID))
        XCTAssertTrue(fullLegacy.migratedKnownIDs.contains(materialID))
        XCTAssertTrue(fullLegacy.migrationState.consumedLegacyIDs.contains(legacyID))

        let shadow = HearingJournalFeedProjection.project(
            records: [materialRecord], journalsByRecordKey: [material.record.recordKey: materialJournal],
            today: today, readIDs: fullLegacy.migratedReadIDs,
            knownIDs: fullLegacy.migratedKnownIDs, legacyEntries: fullLegacy.entries)
        let eventID = try XCTUnwrap(materialJournal.events.first?.id)
        XCTAssertEqual(shadow.aliases, [HearingJournalFeedAlias(
            legacyID: materialID, eventID: eventID)])
        XCTAssertEqual(shadow.shadowReadIDs, [eventID])
        XCTAssertEqual(shadow.shadowKnownIDs, [eventID])
        XCTAssertFalse(try XCTUnwrap(shadow.entries.first).isUnread)
        XCTAssertTrue(shadow.fieldMismatches.isEmpty)

        let later = try fixture(recordKey: material.record.recordKey,
                                date: material.session.date!, time: material.session.time,
                                event: material.session.event, level: .material,
                                caseNumber: "13-9999/2026",
                                knownCardID: "native-unrelated-card")
        let laterJournal = try journal(for: later, before: [],
                                      observedAt: DateUtil.addDays(today, -2))
        let oldMarksAfterLaterCard = LegacyFeedProjection.project(
            records: [later.record], today: today, readIDs: [legacyID],
            knownIDs: [legacyID], migrationState: fullLegacy.migrationState)
        let laterID = AppRouter.materialFeedID(
            legacyID: legacyID, sourceCardID: later.sourceCardID)
        XCTAssertNotEqual(material.sourceCardID, later.sourceCardID)
        XCTAssertNotEqual(materialID, laterID)
        XCTAssertFalse(oldMarksAfterLaterCard.migratedReadIDs.contains(laterID))
        XCTAssertFalse(oldMarksAfterLaterCard.migratedKnownIDs.contains(laterID))
        XCTAssertTrue(try XCTUnwrap(oldMarksAfterLaterCard.entries.first).isUnread)

        let laterShadow = HearingJournalFeedProjection.project(
            records: [later.record], journalsByRecordKey: [later.record.recordKey: laterJournal],
            today: today, readIDs: oldMarksAfterLaterCard.migratedReadIDs,
            knownIDs: oldMarksAfterLaterCard.migratedKnownIDs,
            legacyEntries: oldMarksAfterLaterCard.entries)
        XCTAssertTrue(laterShadow.shadowReadIDs.isEmpty)
        XCTAssertTrue(laterShadow.shadowKnownIDs.isEmpty)
        let laterEntry = try XCTUnwrap(laterShadow.entries.first)
        XCTAssertTrue(laterEntry.isUnread)
    }

    func testComparatorReportsActualLegacyPresentationDrift() throws {
        let fixture = try fixture(recordKey: "compare/2-12/2026",
                                  date: DateUtil.parse("09.09.2026")!,
                                  time: "12:00", event: "Судебное заседание")
        let journal = try journal(for: fixture, before: [], observedAt: DateUtil.parse("08.09.2026")!)
        let legacy = legacyProjection([fixture.record])
        var altered = legacy.entries
        altered[0].client = "Изменённый клиент"
        let shadow = HearingJournalFeedProjection.project(
            records: [fixture.record],
            journalsByRecordKey: [fixture.record.recordKey: journal], today: today,
            readIDs: legacy.migratedReadIDs, knownIDs: legacy.migratedKnownIDs,
            legacyEntries: altered)
        XCTAssertEqual(shadow.fieldMismatches.map(\.field), ["client"])
        XCTAssertEqual(shadow.fieldMismatches.map(\.legacyValue), ["Изменённый клиент"])
        XCTAssertEqual(shadow.fieldMismatches.map(\.shadowValue), [fixture.record.client])
    }

    private struct Fixture {
        let record: LegacyFeedRecordInput
        let sourceCardID: String
        let session: StoredSession
        let owner: CaseInstance
        let context: MovementContext
    }

    private func fixture(
        recordKey: String = "fixture/2-1/2026",
        date: Date,
        time: String? = nil,
        event: String,
        result: String? = nil,
        level: CaseInstance.Level = .first,
        caseNumber: String? = nil,
        note: String? = nil,
        client: String = "Синтетическая сторона",
        unreadByCase: Bool = true,
        includeObservation: Bool = true,
        duplicateSession: Bool = false,
        knownCardID: String? = nil,
        additionalSessions: [StoredSession] = []
    ) throws -> Fixture {
        let ownerNumber = caseNumber ?? baseCaseNumber
        let owner = instance(level: level, caseNumber: ownerNumber, note: note)
        let known = knownCard(level: level, number: ownerNumber,
                              caseID: knownCardID ?? "native-\(recordKey)")
        let context = context(caseNumber: baseCaseNumber,
                              nativeCardID: "root-\(recordKey)", knownCards: [known])
        let sourceCardID = try XCTUnwrap(CaseSnapshotSourceIdentity.sourceCardID(
            for: owner, context: context))
        let session = StoredSession(
            dateRaw: rawDate(date), time: time, room: "зал 2", event: event,
            result: result, court: "Сыктывкарский городской суд", judge: "Судья А",
            levelRaw: level.rawValue, caseNumber: ownerNumber,
            sourceCardID: sourceCardID)
        var sessions = [session]
        if duplicateSession { sessions.append(session) }
        sessions += additionalSessions.map { value in
            var value = value
            if value.sourceCardID == nil { value.sourceCardID = sourceCardID }
            if value.caseNumber == nil { value.caseNumber = ownerNumber }
            return value
        }
        let snapshot = snapshot(
            sessions: sessions, owner: owner, sourceCardID: sourceCardID,
            includeObservation: includeObservation)
        let record = record(recordKey: recordKey, client: client,
                            unreadByCase: unreadByCase, snapshot: snapshot,
                            instances: [owner], context: context)
        return Fixture(record: record, sourceCardID: sourceCardID,
                       session: session, owner: owner, context: context)
    }

    private func withCurrentSession(_ fixture: Fixture, result: String?) throws -> Fixture {
        var session = fixture.session
        session.result = result
        let snapshot = try snapshot(for: fixture, sessions: [session])
        let record = record(fixture, snapshot: snapshot)
        return Fixture(record: record, sourceCardID: fixture.sourceCardID,
                       session: session, owner: fixture.owner, context: fixture.context)
    }

    private func withCurrentSessions(_ fixture: Fixture,
                                     _ sessions: [StoredSession]) throws -> Fixture {
        let snapshot = try snapshot(for: fixture, sessions: sessions)
        let record = record(fixture, snapshot: snapshot)
        return Fixture(record: record, sourceCardID: fixture.sourceCardID,
                       session: sessions[0], owner: fixture.owner, context: fixture.context)
    }

    private func snapshot(for fixture: Fixture,
                          sessions: [StoredSession]) throws -> CaseSnapshot {
        let original = try XCTUnwrap(fixture.record.snapshot)
        var copy = original
        copy.sessions = sessions
        return copy
    }

    private func snapshot(sessions: [StoredSession], owner: CaseInstance,
                          sourceCardID: String, includeObservation: Bool = true) -> CaseSnapshot {
        CaseSnapshot(
            uid: "", inForce: false, category: nil, partiesShort: "",
            leadCharges: nil, secondPartyLine: nil, stageRaw: "first", stageTag: "",
            statusText: "", statusChipRaw: "gray", lastEvent: "", nextEvent: "",
            nextChipRaw: "gray", steps: [], sessions: sessions, deadlines: [],
            actsFingerprint: nil,
            semanticProjectionVersion: CaseEventJournal.currentDerivationVersion,
            instanceObservations: includeObservation ? [StoredInstanceObservation(
                sourceCardID: sourceCardID, levelRaw: owner.level.rawValue,
                court: owner.court, caseNumber: owner.caseNumber,
                judge: owner.judge, result: owner.result)] : [],
            actObservations: [], complaintObservations: [])
    }

    private func record(recordKey: String, client: String, unreadByCase: Bool,
                        snapshot: CaseSnapshot, instances: [CaseInstance],
                        context: MovementContext) -> LegacyFeedRecordInput {
        let movement = CaseMovement(uid: "", caseNumber: baseCaseNumber, inForce: false,
                                    instances: instances, complaints: [:], acts: [])
        return LegacyFeedRecordInput(
            recordKey: recordKey, caseNumber: baseCaseNumber, client: client,
            unreadByCase: unreadByCase, snapshot: snapshot, movement: movement,
            context: context, enforcementRecords: [])
    }

    private func record(_ fixture: Fixture, snapshot: CaseSnapshot? = nil,
                        instances: [CaseInstance]? = nil) -> LegacyFeedRecordInput {
        record(recordKey: fixture.record.recordKey,
               client: fixture.record.client,
               unreadByCase: fixture.record.unreadByCase,
               snapshot: snapshot ?? fixture.record.snapshot!,
               instances: instances ?? [fixture.owner], context: fixture.context)
    }

    private func session(date: Date, time: String?, event: String, result: String? = nil,
                         sourceCardID: String? = nil, caseNumber: String? = nil) throws -> StoredSession {
        StoredSession(dateRaw: rawDate(date), time: time, room: "зал 2",
                      event: event, result: result, court: "Сыктывкарский городской суд",
                      judge: "Судья А", levelRaw: CaseInstance.Level.first.rawValue,
                      caseNumber: caseNumber, sourceCardID: sourceCardID)
    }

    private func journal(for fixture: Fixture, before: [StoredSession],
                         observedAt: Date) throws -> CaseEventJournal {
        var journal = CaseEventJournal()
        let baseline = try snapshot(for: fixture, sessions: before)
        let seeded = refresh(journal, snapshot: baseline,
                             admittedCourts: admitted(fixture), observedAt: observedAt,
                             complete: true)
        journal.semanticBaselines = seeded.baselines
        let current = try XCTUnwrap(fixture.record.snapshot)
        let update = refresh(journal, snapshot: current,
                             admittedCourts: admitted(fixture), observedAt: observedAt,
                             complete: true)
        journal.semanticBaselines = update.baselines
        try journal.append(journal.identifyingOccurrences(
            update.derivation.events, originKey: fixture.record.recordKey))
        return journal
    }

    private func quietJournal(for fixture: Fixture, observedAt: Date) throws -> CaseEventJournal {
        var journal = CaseEventJournal()
        let current = try XCTUnwrap(fixture.record.snapshot)
        let seed = refresh(journal, snapshot: current,
                           admittedCourts: admitted(fixture), observedAt: observedAt,
                           complete: true)
        journal.semanticBaselines = seed.baselines
        return journal
    }

    private func refresh(_ journal: CaseEventJournal, snapshot: CaseSnapshot,
                         admittedCourts: [String: [String: String]], observedAt: Date,
                         complete: Bool, kind: SourceOutcomeKind = .usableSnapshot)
        -> (baselines: CaseEventBaselines?, derivation: CaseEventDerivationResult) {
        CaseEventBaselineTransition.refresh(
            journal: journal, freshSnapshot: snapshot, globalSnapshot: snapshot,
            admittedCourts: admittedCourts,
            attempt: SourceAttempt(
                kind: kind,
                provenance: .init(operation: .movement, sourceFamily: "sudrf",
                                  host: "syktsud--komi.sudrf.ru", observedAt: observedAt)),
            isComplete: complete)
    }

    private func admitted(_ fixture: Fixture) -> [String: [String: String]] {
        ["district": [fixture.sourceCardID: fixture.sourceCardID]]
    }

    private func project(_ record: LegacyFeedRecordInput, journal: CaseEventJournal,
                         readIDs: Set<String> = [], knownIDs: Set<String> = [],
                         legacyEntries: [FeedEntry]? = nil)
        -> (LegacyFeedProjectionResult, HearingJournalFeedProjectionResult) {
        let legacy = LegacyFeedProjection.project(
            records: [record], today: today, readIDs: readIDs, knownIDs: knownIDs,
            migrationState: .init())
        let shadow = HearingJournalFeedProjection.project(
            records: [record], journalsByRecordKey: [record.recordKey: journal], today: today,
            readIDs: legacy.migratedReadIDs, knownIDs: legacy.migratedKnownIDs,
            legacyEntries: legacyEntries ?? legacy.entries)
        return (legacy, shadow)
    }

    private func legacyProjection(_ records: [LegacyFeedRecordInput],
                                  readIDs: Set<String> = [], knownIDs: Set<String> = [])
        -> LegacyFeedProjectionResult {
        LegacyFeedProjection.project(records: records, today: today,
                                     readIDs: readIDs, knownIDs: knownIDs,
                                     migrationState: .init())
    }

    private func instance(level: CaseInstance.Level, caseNumber: String,
                          note: String?) -> CaseInstance {
        CaseInstance(level: level, court: "Сыктывкарский городской суд",
                     caseNumber: caseNumber, judge: "Судья А",
                     domain: "syktsud.komi.sudrf.ru", foundByUID: false,
                     result: nil, sessions: [], actIDs: [], note: note)
    }

    private func knownCard(level: CaseInstance.Level, number: String,
                           caseID: String) -> KnownCard {
        KnownCard(domain: "syktsud--komi.sudrf.ru",
                  courtTitle: "Сыктывкарский городской суд", caseID: caseID,
                  caseUID: "guid-\(caseID)", deloID: level == .material ? "m" : "g1",
                  new: "0", caseNumber: number, levelRaw: level.rawValue,
                  cartotekaID: level == .material ? "m" : "g1")
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

    private func replacing(_ event: CaseEvent, evidence: CaseEventEvidence) -> CaseEvent {
        CaseEvent(id: event.id, kind: event.kind, observedAtRef: event.observedAtRef,
                  evidence: evidence, occurrence: event.occurrence)
    }

    private func makeJournal(_ events: [CaseEvent]) -> CaseEventJournal {
        var journal = CaseEventJournal()
        journal.events = events
        return journal
    }

    private func assertUnmapped(_ event: CaseEvent, record: LegacyFeedRecordInput,
                                reason: HearingJournalFeedUnmappedReason,
                                file: StaticString = #filePath, line: UInt = #line) {
        var journal = CaseEventJournal()
        journal.events = [event]
        let result = project(record, journal: journal).1
        XCTAssertTrue(result.aliases.isEmpty, file: file, line: line)
        XCTAssertTrue(result.shadowReadIDs.isEmpty, file: file, line: line)
        XCTAssertEqual(result.unmappedEvents.map(\.reason), [reason], file: file, line: line)
    }

    private func assertEntry(_ actual: FeedEntry, matches legacy: FeedEntry, id: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.id, id, file: file, line: line)
        XCTAssertEqual(actual.dayHead, legacy.dayHead, file: file, line: line)
        XCTAssertEqual(actual.date, legacy.date, file: file, line: line)
        XCTAssertEqual(actual.time, legacy.time, file: file, line: line)
        XCTAssertEqual(actual.recordKey, legacy.recordKey, file: file, line: line)
        XCTAssertEqual(actual.caseNumber, legacy.caseNumber, file: file, line: line)
        XCTAssertEqual(actual.client, legacy.client, file: file, line: line)
        XCTAssertEqual(actual.kind, legacy.kind, file: file, line: line)
        XCTAssertEqual(actual.text, legacy.text, file: file, line: line)
        XCTAssertEqual(actual.actID, legacy.actID, file: file, line: line)
        XCTAssertEqual(actual.isUnread, legacy.isUnread, file: file, line: line)
        XCTAssertEqual(actual.instanceCaseNumber, legacy.instanceCaseNumber, file: file, line: line)
        XCTAssertEqual(actual.instanceLevel, legacy.instanceLevel, file: file, line: line)
        XCTAssertEqual(actual.sourceCardID, legacy.sourceCardID, file: file, line: line)
        XCTAssertEqual(actual.sourceInstanceID, legacy.sourceInstanceID, file: file, line: line)
        XCTAssertEqual(actual.previousRegistrationNumber, legacy.previousRegistrationNumber,
                       file: file, line: line)
        XCTAssertEqual(actual.secondaryLabel, legacy.secondaryLabel, file: file, line: line)
        XCTAssertEqual(actual.notificationSubtitle, legacy.notificationSubtitle,
                       file: file, line: line)
    }

    private func rawDate(_ date: Date) -> String {
        let parts = DateUtil.cal.dateComponents([.day, .month, .year], from: date)
        return String(format: "%02d.%02d.%04d", parts.day ?? 0,
                      parts.month ?? 0, parts.year ?? 0)
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
