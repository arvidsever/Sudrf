import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class LegacyFeedProjectionTests: XCTestCase {
    private let today = DateUtil.parse("10.09.2026")!
    private let recordKey = "syktsud.komi.sudrf.ru/2-9143/2025"
    private let caseNumber = "2-9143/2025"
    private let client = "Иванов А. А."

    func testProjectsTreasuryWithoutSnapshotSessionsAndActsWithLegacyFields() {
        let treasuryDate = today
        let treasury = EnforcementRecord(
            courtDocumentID: "exec-42", source: .treasury, status: "Окончено",
            events: [EnforcementEvent(guid: " treasury-guid-42 ", date: treasuryDate,
                                      text: "Стадия исполнительного документа", sourceOrder: 0)])
        let treasuryRecord = input(
            recordKey: "treasury.sudrf.ru/2-20/2026", caseNumber: "2-20/2026",
            client: "Клиент Казначейства", unreadByCase: false,
            enforcementRecords: [treasury])

        let session = StoredSession(
            dateRaw: "09.09.2026", time: "11:23", room: "301",
            event: "Судебное заседание", result: "Отложено",
            court: "Сыктывкарский городской суд", judge: "Судья А",
            levelRaw: CaseInstance.Level.first.rawValue, caseNumber: nil)
        let act = CaseAct(id: "published-act-42", title: "Определение",
                          date: "08.09.2026", courtShort: "1-я инстанция",
                          instanceLevel: .first)
        let movement = CaseMovement(uid: "", caseNumber: caseNumber, inForce: false,
                                    instances: [], complaints: [:], acts: [act])
        let caseRecord = input(snapshot: snapshot([session]), movement: movement)

        let result = project([treasuryRecord, caseRecord])
        let expectedTreasuryID = AppRouter.enforcementFeedID(
            recordKey: treasuryRecord.recordKey, guid: "treasury-guid-42")
        let expectedSessionDate = DateUtil.parse("09.09.2026")!
        let expectedSessionID = AppRouter.feedID(
            recordKey: recordKey, date: expectedSessionDate, time: "11:23", text: "Отложено")
        let expectedActDate = DateUtil.parse("08.09.2026")!
        let expectedActID = AppRouter.feedID(
            recordKey: recordKey, date: expectedActDate, time: "—", text: act.id)

        assertEntries(result.entries, equalTo: [
            entry(id: expectedTreasuryID, date: treasuryDate, time: "—",
                  recordKey: treasuryRecord.recordKey, caseNumber: "2-20/2026",
                  client: "Клиент Казначейства", kind: .enforcement,
                  text: "Стадия исполнительного документа", isUnread: true),
            entry(id: expectedSessionID, date: expectedSessionDate, time: "11:23",
                  recordKey: recordKey, caseNumber: caseNumber, client: client,
                  kind: .hearing, text: "Отложено", isUnread: true),
            entry(id: expectedActID, date: expectedActDate, time: "—",
                  recordKey: recordKey, caseNumber: caseNumber, client: client,
                  kind: .act, text: "Опубликован судебный акт: Определение",
                  actID: act.id, isUnread: true)
        ])
    }

    func testInclusiveFortyFiveDayBoundaryForAllThreeSources() {
        let dates = [-1, 0, 45, 46].map { DateUtil.addDays(today, -$0) }
        let treasury = EnforcementRecord(
            courtDocumentID: "exec-boundary", source: .treasury, status: "Открыто",
            events: dates.enumerated().map { index, date in
            EnforcementEvent(guid: "treasury-\(index)", date: date,
                                 text: "Событие Казначейства \(index)", sourceOrder: index)
            })
        let sessions = dates.enumerated().map { index, date in
            session(date: date, time: "10:0\(index)", event: "Движение \(index)")
        }
        let acts = dates.enumerated().map { index, date in
            CaseAct(id: "boundary-act-\(index)", title: "Акт \(index)",
                    date: rawDate(date), courtShort: "Суд", instanceLevel: .first)
        }
        let movement = CaseMovement(uid: "", caseNumber: caseNumber, inForce: false,
                                    instances: [], complaints: [:], acts: acts)
        let result = project([input(snapshot: snapshot(sessions), movement: movement,
                                    enforcementRecords: [treasury])])

        XCTAssertEqual(dates.map { DateUtil.daysBetween($0, today) }, [-1, 0, 45, 46])
        let expectedIDs = Set([1, 2].flatMap { index in
            let date = dates[index]
            return [
                AppRouter.enforcementFeedID(recordKey: recordKey, guid: "treasury-\(index)"),
                AppRouter.feedID(recordKey: recordKey, date: DateUtil.parse(rawDate(date))!,
                                 time: "10:0\(index)", text: "Движение \(index)"),
                AppRouter.feedID(recordKey: recordKey,
                                 date: DateUtil.parse(rawDate(date))!, time: "—",
                                 text: "boundary-act-\(index)")
            ]
        })
        XCTAssertEqual(Set(result.entries.map(\.id)), expectedIDs)
        XCTAssertEqual(result.entries.count, 6)
    }

    func testIssue99ClericalTimeAndHistoricalHearingKeepLegacyKinds() {
        let date = DateUtil.parse("08.09.2026")!
        let clerical = session(date: date, time: "15:00",
                               event: "Дело сдано в отдел судебного делопроизводства")
        let hearing = session(date: date, time: "15:05", event: "Судебное заседание",
                              result: "Рассмотрение отложено")
        let result = project([input(snapshot: snapshot([clerical, hearing]))])
        let clericalID = AppRouter.feedID(
            recordKey: recordKey, date: date, time: "15:00",
            text: "Дело сдано в отдел судебного делопроизводства")
        let hearingID = AppRouter.feedID(
            recordKey: recordKey, date: date, time: "15:05", text: "Рассмотрение отложено")

        assertEntries(result.entries, equalTo: [
            entry(id: clericalID, date: date, time: "15:00", recordKey: recordKey,
                  caseNumber: caseNumber, client: client, kind: .movement,
                  text: "Дело сдано в отдел судебного делопроизводства", isUnread: true),
            entry(id: hearingID, date: date, time: "15:05", recordKey: recordKey,
                  caseNumber: caseNumber, client: client, kind: .hearing,
                  text: "Рассмотрение отложено", isUnread: true)
        ])
    }

    func testAllEntriesRetainsFutureAndOlderDatedHistoryBeforeWindowFiltering() {
        let dates = [DateUtil.addDays(today, -46), DateUtil.addDays(today, 1)]
        let sessions = dates.map {
            session(date: $0, time: "15:00",
                    event: "Дело сдано в отдел судебного делопроизводства")
        }
        let acts = dates.enumerated().map { index, date in
            CaseAct(id: "history-act-\(index)", title: "Решение", date: rawDate(date),
                    courtShort: "Суд", instanceLevel: .first)
        }
        let treasury = EnforcementRecord(
            courtDocumentID: "history-exec", source: .treasury, status: "Открыто",
            events: dates.enumerated().map { index, date in
                EnforcementEvent(guid: "history-guid-\(index)", date: date,
                                 text: "Событие Казначейства", sourceOrder: index)
            })
        let movement = CaseMovement(uid: "", caseNumber: caseNumber, inForce: false,
                                    instances: [], complaints: [:], acts: acts)
        let records = [input(snapshot: snapshot(sessions), movement: movement,
                             enforcementRecords: [treasury])]
        let history = LegacyFeedProjection.allEntries(records: records)

        XCTAssertEqual(history.count, 6)
        XCTAssertEqual(history.filter { $0.kind == .movement }.count, 2)
        XCTAssertEqual(history.filter { $0.kind == .act }.count, 2)
        XCTAssertEqual(history.filter { $0.kind == .enforcement }.count, 2)
        XCTAssertTrue(history.allSatisfy { $0.dayHead == nil })
        XCTAssertTrue(project(records).entries.isEmpty)
    }

    func testAllEntriesPreservesCollidingMaterialRowsForImportValidation() {
        let date = DateUtil.parse("09.09.2026")!
        let first = session(date: date, time: "14:00", event: "Принято к производству",
                            level: .material, number: "13-1/2026", sourceCardID: "card-1")
        let conflicting = session(date: date, time: "14:00", event: "Принято к производству",
                                  level: .material, number: "13-2/2026", sourceCardID: "card-1")
        let records = [input(snapshot: snapshot([first, conflicting]))]
        let history = LegacyFeedProjection.allEntries(records: records)

        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].id, history[1].id)
        XCTAssertEqual(history.map(\.instanceCaseNumber), ["13-1/2026", "13-2/2026"])
        XCTAssertEqual(project(records).entries.count, 1,
                       "The existing display keeps its material-ID collapse.")
    }

    func testMaterialDedupPreviousRegistrationAndScopedNavigationFields() throws {
        var context = fixtureContext()
        context.knownCards = [
            knownCard(id: "material-card-1", number: "13-2471/2026", level: .material),
            knownCard(id: "material-card-2", number: "13-3241/2026", level: .material),
            knownCard(id: "previous-card", number: "9а-104/2026", level: .first)
        ]
        let material1 = instance(level: .material, number: "13-2471/2026")
        let material2 = instance(level: .material, number: "13-3241/2026")
        let previous = instance(level: .first, number: "9а-104/2026",
                                 note: "Предыдущая регистрация")
        let source1 = try XCTUnwrap(CaseSnapshotSourceIdentity.sourceCardID(
            for: material1, context: context))
        let source2 = try XCTUnwrap(CaseSnapshotSourceIdentity.sourceCardID(
            for: material2, context: context))
        let previousSource = try XCTUnwrap(AppRouter.previousRegistrationSourceCardID(
            for: previous, context: context))
        let date = DateUtil.parse("09.09.2026")!
        let materialSession1 = session(date: date, time: "14:00",
                                       event: "Принято к производству", level: .material,
                                       sourceCardID: source1)
        let materialSession2 = session(date: date, time: "14:00",
                                       event: "Принято к производству", level: .material,
                                       sourceCardID: source2)
        let conflictingMaterialSession = session(
            date: date, time: "14:01", event: "Принято к производству",
            level: .material, number: "13-9999/2026", sourceCardID: source1)
        let previousSession = session(date: date, time: "14:05", event: "Передано",
                                      number: "9а-104/2026", sourceCardID: previousSource)
        let ambiguousAct = CaseAct(id: "ambiguous-material-act", title: "Определение",
                                   date: "09.09.2026", courtShort: "Суд",
                                   instanceLevel: .material)
        let fallbackAct = CaseAct(id: "unlinked-appeal-act", title: "Постановление",
                                  date: "09.09.2026", courtShort: "АСОЮ",
                                  instanceLevel: .appeal)
        var linkedMaterial1 = material1
        linkedMaterial1.actIDs = [ambiguousAct.id]
        var linkedMaterial2 = material2
        linkedMaterial2.actIDs = [ambiguousAct.id]
        let appeal = instance(level: .appeal, number: "66а-10/2026")
        let movement = CaseMovement(
            uid: "", caseNumber: caseNumber, inForce: false,
            instances: [linkedMaterial1, linkedMaterial2, previous, appeal],
            complaints: [:], acts: [ambiguousAct, fallbackAct])
        let records = [input(snapshot: snapshot([
            materialSession1, materialSession1, materialSession2,
            conflictingMaterialSession, previousSession
        ]), movement: movement, context: context)]

        let result = project(records)
        let materialLegacy = AppRouter.feedID(
            recordKey: recordKey, date: date, time: "14:00", text: "Принято к производству")
        let conflictingLegacy = AppRouter.feedID(
            recordKey: recordKey, date: date, time: "14:01", text: "Принято к производству")
        let previousID = AppRouter.feedID(
            recordKey: recordKey, date: date, time: "14:05", text: "Передано")
        let ambiguousActLegacy = AppRouter.feedID(
            recordKey: recordKey, date: date, time: "—", text: ambiguousAct.id)
        let fallbackActID = AppRouter.feedID(
            recordKey: recordKey, date: date, time: "—", text: fallbackAct.id)

        assertEntries(result.entries, equalTo: [
            entry(id: AppRouter.materialFeedID(legacyID: materialLegacy, sourceCardID: source1),
                  date: date, time: "14:00", recordKey: recordKey, caseNumber: caseNumber,
                  client: client, kind: .movement, text: "Принято к производству",
                  isUnread: true, instanceCaseNumber: "13-2471/2026", instanceLevel: .material,
                  sourceCardID: source1, sourceInstanceID: material1.id),
            entry(id: AppRouter.materialFeedID(legacyID: materialLegacy, sourceCardID: source2),
                  date: date, time: "14:00", recordKey: recordKey, caseNumber: caseNumber,
                  client: client, kind: .movement, text: "Принято к производству",
                  isUnread: true, instanceCaseNumber: "13-3241/2026", instanceLevel: .material,
                  sourceCardID: source2, sourceInstanceID: material2.id),
            entry(id: AppRouter.materialFeedID(legacyID: conflictingLegacy, sourceCardID: source1),
                  date: date, time: "14:01", recordKey: recordKey, caseNumber: caseNumber,
                  client: client, kind: .movement, text: "Принято к производству",
                  isUnread: true, instanceLevel: .material, sourceCardID: source1),
            entry(id: previousID, date: date, time: "14:05", recordKey: recordKey,
                  caseNumber: caseNumber, client: client, kind: .movement, text: "Передано",
                  isUnread: true, instanceCaseNumber: "9а-104/2026", instanceLevel: .first,
                  sourceCardID: previousSource, sourceInstanceID: previous.id,
                  previousRegistrationNumber: "9а-104/2026"),
            entry(id: ambiguousActLegacy, date: date, time: "—", recordKey: recordKey,
                  caseNumber: caseNumber, client: client, kind: .act,
                  text: "Опубликован судебный акт: Определение", actID: ambiguousAct.id,
                  isUnread: true, instanceLevel: .material),
            entry(id: fallbackActID, date: date, time: "—", recordKey: recordKey,
                  caseNumber: caseNumber, client: client, kind: .act,
                  text: "Опубликован судебный акт: Постановление", actID: fallbackAct.id,
                  isUnread: true, instanceCaseNumber: "66а-10/2026", instanceLevel: .appeal)
        ])
        XCTAssertEqual(result.entries.count, 6, "same material source row is rendered once")
        XCTAssertEqual(result.entries[0].materialNumber, "13-2471/2026")
        XCTAssertEqual(result.entries[3].secondaryLabel,
                       "Предыдущая регистрация № 9а-104/2026")
    }

    func testReadKnownAndUnresolvedMaterialMigrationReturnsReusableState() throws {
        var context = fixtureContext()
        context.knownCards = [knownCard(id: "material-card-1", number: "13-2471/2026",
                                        level: .material)]
        let material = instance(level: .material, number: "13-2471/2026")
        let sourceID = CaseSnapshotSourceIdentity.sourceCardID(for: material, context: context)!
        let date = DateUtil.parse("09.09.2026")!
        let unresolvedSession = session(date: date, time: "14:00",
                                       event: "Принято к производству", level: .material)
        let resolvedSession = session(date: date, time: "14:00",
                                      event: "Принято к производству", level: .material,
                                      sourceCardID: sourceID)
        let movement = CaseMovement(uid: "", caseNumber: caseNumber, inForce: false,
                                    instances: [material], complaints: [:], acts: [])
        let unresolved = input(snapshot: snapshot([unresolvedSession]), movement: movement,
                               context: context)
        let resolved = input(snapshot: snapshot([resolvedSession]), movement: movement,
                             context: context)
        let legacyID = AppRouter.feedID(
            recordKey: recordKey, date: date, time: "14:00", text: "Принято к производству")
        let materialID = AppRouter.materialFeedID(legacyID: legacyID, sourceCardID: sourceID)

        let first = LegacyFeedProjection.project(
            records: [unresolved], today: today, readIDs: [legacyID],
            knownIDs: [legacyID], migrationState: MaterialFeedMigrationState())
        XCTAssertEqual(first.migratedReadIDs, [legacyID])
        XCTAssertEqual(first.migratedKnownIDs, [legacyID])
        XCTAssertEqual(first.entries.map(\.id), [legacyID])
        XCTAssertFalse(first.entries[0].isUnread)
        XCTAssertEqual(first.migrationState.pendingUnresolvedCounts[legacyID], 1)
        XCTAssertFalse(first.migrationState.consumedLegacyIDs.contains(legacyID))

        let initialJournal = try LegacyFeedHistoryImport.journal(record: unresolved,
            logicalCaseID: UUID(), existing: CaseEventJournal(), importedAt: today)
        let authority = try JournalFeedProjection.synchronize(record: unresolved,
            journal: initialJournal, legacyReadIDs: [legacyID], legacyKnownIDs: [legacyID],
            migrationDay: today)
        XCTAssertEqual(authority.materialMigrationState, first.migrationState)
        XCTAssertEqual(authority.readEventIDs, Set(initialJournal.events.map(\.id)))
        XCTAssertEqual(authority.receipts.first?.originalReadIDs, [legacyID])

        let enriched = LegacyFeedProjection.project(
            records: [resolved], today: today, readIDs: [legacyID],
            knownIDs: [legacyID], migrationState: first.migrationState)
        XCTAssertEqual(enriched.migratedReadIDs, [materialID])
        XCTAssertEqual(enriched.migratedKnownIDs, [materialID])
        XCTAssertEqual(enriched.entries.map(\.id), [materialID])
        XCTAssertFalse(enriched.entries[0].isUnread)
        XCTAssertTrue(enriched.migrationState.consumedLegacyIDs.contains(legacyID))
        XCTAssertNil(enriched.migrationState.pendingUnresolvedCounts[legacyID])

        let resolvedJournal = try LegacyFeedHistoryImport.journal(record: resolved,
            logicalCaseID: UUID(), existing: CaseEventJournal(), importedAt: today)
        var publishedEvidence = resolvedJournal.events[0].evidence
        publishedEvidence.sourceRowBinding = SourceRowBinding(courtScope: "proved-scope",
            nativeCardID: "proved-native", sourceCardID: sourceID, fingerprint: "proved-row",
            ordinal: 0, notificationEligible: true)
        let publication = CaseEvent.make(kind: .sourceRowPublished,
            occurrence: ["proved-row"], observedAt: today, evidence: publishedEvidence)
        var lateAuthority = authority
        lateAuthority.admitMaterialEnrichment(events: [publication], journal: initialJournal)
        XCTAssertTrue(lateAuthority.readEventIDs.contains(publication.id))
        XCTAssertTrue(lateAuthority.knownEventIDs.contains(publication.id))
        XCTAssertEqual(lateAuthority.materialMigrationState, enriched.migrationState)
        XCTAssertEqual(initialJournal.events.count, 1, "Unknown history remains intact")
        var clearedAuthority = authority
        clearedAuthority.readEventIDs.removeAll()
        clearedAuthority.admitMaterialEnrichment(events: [publication], journal: initialJournal)
        XCTAssertFalse(clearedAuthority.readEventIDs.contains(publication.id),
            "Late enrichment reads current DB marks, not original preference receipt")
        let consumed = lateAuthority
        lateAuthority.readEventIDs.remove(publication.id)
        lateAuthority.admitMaterialEnrichment(events: [publication], journal: initialJournal)
        XCTAssertFalse(lateAuthority.readEventIDs.contains(publication.id))
        XCTAssertEqual(lateAuthority.materialMigrationState, consumed.materialMigrationState)

        let resolvedAuthority = try JournalFeedProjection.synchronize(record: resolved,
            journal: resolvedJournal, legacyReadIDs: [legacyID], legacyKnownIDs: [legacyID],
            materialMigrationState: first.migrationState, migrationDay: today)
        XCTAssertEqual(resolvedAuthority.materialMigrationState, enriched.migrationState)
        XCTAssertEqual(resolvedAuthority.readEventIDs, Set(resolvedJournal.events.map(\.id)))
        var resetJournal = resolvedJournal
        resetJournal.feedState = resolvedAuthority
        resetJournal.feedState?.readEventIDs.removeAll()
        let restarted = try JournalFeedProjection.synchronize(record: resolved,
            journal: resetJournal, legacyReadIDs: [legacyID], legacyKnownIDs: [legacyID],
            materialMigrationState: first.migrationState, migrationDay: today)
        XCTAssertTrue(restarted.readEventIDs.isEmpty, "Original preference input is never replayed")
        XCTAssertEqual(restarted.materialMigrationState, resolvedAuthority.materialMigrationState)

        let repeated = LegacyFeedProjection.project(
            records: [resolved], today: today,
            readIDs: enriched.migratedReadIDs, knownIDs: enriched.migratedKnownIDs,
            migrationState: enriched.migrationState)
        assertEntries(repeated.entries, equalTo: enriched.entries)
        XCTAssertEqual(repeated.migratedReadIDs, enriched.migratedReadIDs)
        XCTAssertEqual(repeated.migratedKnownIDs, enriched.migratedKnownIDs)
        XCTAssertEqual(repeated.migrationState, enriched.migrationState)

        let knownOnly = LegacyFeedProjection.project(
            records: [resolved], today: today, readIDs: [], knownIDs: [legacyID],
            migrationState: MaterialFeedMigrationState())
        XCTAssertTrue(knownOnly.migratedReadIDs.isEmpty)
        XCTAssertEqual(knownOnly.migratedKnownIDs, [materialID])
        XCTAssertTrue(knownOnly.entries[0].isUnread,
                      "known-only migration must not create a read mark")
    }

    private func project(_ records: [LegacyFeedRecordInput]) -> LegacyFeedProjectionResult {
        LegacyFeedProjection.project(records: records, today: today, readIDs: [],
                                     knownIDs: [], migrationState: .init())
    }

    private func input(recordKey: String? = nil, caseNumber: String? = nil,
                       client: String? = nil, unreadByCase: Bool = true,
                       snapshot: CaseSnapshot? = nil, movement: CaseMovement? = nil,
                       context: MovementContext? = nil,
                       enforcementRecords: [EnforcementRecord] = []) -> LegacyFeedRecordInput {
        LegacyFeedRecordInput(
            recordKey: recordKey ?? self.recordKey,
            caseNumber: caseNumber ?? self.caseNumber,
            client: client ?? self.client, unreadByCase: unreadByCase,
            snapshot: snapshot, movement: movement, context: context,
            enforcementRecords: enforcementRecords)
    }

    private func snapshot(_ sessions: [StoredSession]) -> CaseSnapshot {
        CaseSnapshot(uid: "", inForce: false, category: nil, partiesShort: "",
                     leadCharges: nil, secondPartyLine: nil, stageRaw: "first", stageTag: "",
                     statusText: "", statusChipRaw: "gray", lastEvent: "", nextEvent: "",
                     nextChipRaw: "gray", steps: [], sessions: sessions, deadlines: [],
                     actsFingerprint: nil)
    }

    private func session(date: Date, time: String? = nil, event: String,
                         result: String? = nil, level: CaseInstance.Level = .first,
                         number: String? = nil, sourceCardID: String? = nil) -> StoredSession {
        StoredSession(dateRaw: rawDate(date), time: time, room: nil,
                      event: event, result: result, court: "Тестовый суд", judge: nil,
                      levelRaw: level.rawValue, caseNumber: number, sourceCardID: sourceCardID)
    }

    private func rawDate(_ date: Date) -> String {
        let components = DateUtil.cal.dateComponents([.day, .month, .year], from: date)
        return String(format: "%02d.%02d.%04d", components.day ?? 0,
                      components.month ?? 0, components.year ?? 0)
    }

    private func entry(id: String, date: Date, time: String, recordKey: String,
                       caseNumber: String, client: String, kind: FeedEntryKind,
                       text: String, actID: String? = nil, isUnread: Bool,
                       instanceCaseNumber: String? = nil,
                       instanceLevel: CaseInstance.Level = .first,
                       sourceCardID: String? = nil, sourceInstanceID: String? = nil,
                       previousRegistrationNumber: String? = nil) -> FeedEntry {
        FeedEntry(id: id, dayHead: nil, date: date, time: time, recordKey: recordKey,
                  caseNumber: caseNumber, client: client, kind: kind, text: text,
                  actID: actID, isUnread: isUnread,
                  instanceCaseNumber: instanceCaseNumber, instanceLevel: instanceLevel,
                  sourceCardID: sourceCardID, sourceInstanceID: sourceInstanceID,
                  previousRegistrationNumber: previousRegistrationNumber)
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
            XCTAssertEqual(actual.secondaryLabel, expected.secondaryLabel,
                           file: file, line: line)
            XCTAssertEqual(actual.notificationSubtitle, expected.notificationSubtitle,
                           file: file, line: line)
        }
    }

    private func fixtureContext() -> MovementContext {
        MovementContext(
            branchRaw: "general", region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд",
            courtLevelRaw: "district", courtCode: "11RS0001",
            cartotekaId: "g1", cartotekaLevelRaw: "district",
            caseNumber: caseNumber, caseID: "base-card")
    }

    private func knownCard(id: String, number: String,
                           level: CaseInstance.Level) -> KnownCard {
        KnownCard(domain: "syktsud--komi.sudrf.ru",
                  courtTitle: "Сыктывкарский городской суд",
                  caseID: id, caseUID: "guid-\(id)", deloID: "1610001", new: "0",
                  caseNumber: number, levelRaw: level.rawValue,
                  cartotekaID: level == .material ? "m" : "g1")
    }

    private func instance(level: CaseInstance.Level, number: String,
                          note: String? = nil) -> CaseInstance {
        CaseInstance(level: level, court: "Сыктывкарский городской суд",
                     caseNumber: number, judge: "Судья Б",
                     domain: "syktsud.komi.sudrf.ru", foundByUID: false,
                     result: nil, sessions: [], note: note)
    }
}
