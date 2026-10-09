import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class CaseEventFeedCompatibilityTests: XCTestCase {
    private let sourceCardID = "sudrf|compatibility.test.sudrf.ru|g1|fixture-card"
    private let courtScope = "sudrf|compatibility.test.sudrf.ru"
    private let recordKey = "compatibility.test.sudrf.ru/2-1/2026"
    private let observedAt = DateUtil.parse("01.09.2026")!

    func testLegacyFeedIdentityKeepsIssue99AndTreasuryGUIDFilterContract() {
        let date = DateUtil.parse("20.08.2026")!
        let session = StoredSession(
            dateRaw: "20.08.2026", time: "11:00", room: nil,
            event: "Дело сдано в отдел судебного делопроизводства", result: nil,
            court: "Тестовый суд", judge: nil, levelRaw: "first",
            caseNumber: "2-1/2026", sourceCardID: sourceCardID)

        XCTAssertFalse(CaseLifecycleResolver.isHearingEvent(event: session.event))
        XCTAssertTrue(MovementDerivation.futureHearings([session], today: date).isEmpty)
        XCTAssertTrue(CaseLifecycleResolver.isHearingEvent(event: "Судебное заседание"),
                      "the negative case must not disable real hearings")

        let currentID = AppRouter.feedID(recordKey: recordKey, date: date,
                                         time: session.time ?? "—", text: session.event)
        let preIssue99ID = "\(recordKey)#feed#hearing#\(Int(date.timeIntervalSinceReferenceDate))#11:00#\(session.event)"
        XCTAssertEqual(AppRouter.feedIDDroppingKind(preIssue99ID), currentID)

        let guid = "fixture-rss-guid-42"
        let treasuryID = AppRouter.enforcementFeedID(recordKey: recordKey, guid: guid)
        let unread = feedEntry(id: treasuryID, date: observedAt, kind: .enforcement,
                               text: "Синтетическая запись", isUnread: true)
        let read = feedEntry(id: treasuryID, date: observedAt, kind: .enforcement,
                             text: "Синтетическая запись", isUnread: false)
        XCTAssertEqual(unread.id, read.id)
        XCTAssertEqual(AppRouter.filteredFeedEntries(
            [unread], filter: .enforcement, unreadOnly: true, query: "").map(\.id), [treasuryID])
        XCTAssertTrue(AppRouter.filteredFeedEntries(
            [read], filter: .enforcement, unreadOnly: true, query: "").isEmpty)
    }

    func testFutureHearingAndSevenDayRecentHelperHaveSeparateContracts() {
        let futureDate = DateUtil.parse("15.09.2026")!
        let session = StoredSession(
            dateRaw: "15.09.2026", time: "10:30", room: nil,
            event: "Судебное заседание", result: nil,
            court: "Тестовый суд", judge: nil, levelRaw: "first",
            caseNumber: "2-1/2026", sourceCardID: sourceCardID)
        let old = snapshot()
        let new = snapshot(sessions: [session])
        let derivation = CaseEventDeriver.derive(
            old: old, new: new, attempt: attempt(kind: .usableSnapshot),
            observedAt: observedAt)
        XCTAssertEqual(derivation.events.map(\.kind), [.hearingScheduled])
        XCTAssertEqual(MovementDerivation.futureHearings([session], today: observedAt).count, 1)

        let futureCandidate = feedEntry(
            id: AppRouter.feedID(recordKey: recordKey, date: futureDate,
                                 time: session.time ?? "—", text: session.event),
            date: futureDate, kind: .hearing, text: session.event)
        let recentDate = observedAt.addingTimeInterval(-6 * 24 * 60 * 60)
        let recentCandidate = feedEntry(
            id: AppRouter.feedID(recordKey: recordKey, date: recentDate,
                                 time: "—", text: "Вынесено решение"),
            date: recentDate, kind: .hearing, text: "Вынесено решение")
        let outsideWindowCandidate = feedEntry(
            id: AppRouter.feedID(recordKey: recordKey,
                                 date: observedAt.addingTimeInterval(-7 * 24 * 60 * 60),
                                 time: "—", text: "Старое решение"),
            date: observedAt.addingTimeInterval(-7 * 24 * 60 * 60),
            kind: .hearing, text: "Старое решение")
        XCTAssertEqual(AppRouter.recentFeedEntries(
            [futureCandidate, recentCandidate, outsideWindowCandidate], today: observedAt, days: 7)
            .map(\.id), [recentCandidate.id])
    }

    func testVersionSixSeedIsQuietThenCompleteChangeIsRecordedOnce() throws {
        XCTAssertEqual(CaseEventJournal.currentDerivationVersion, 6)
        let existingSession = StoredSession(
            dateRaw: "20.08.2026", time: "10:00", room: nil,
            event: "Судебное заседание", result: nil,
            court: "Тестовый суд", judge: nil, levelRaw: "first",
            caseNumber: "2-1/2026", sourceCardID: sourceCardID)
        let baselineSnapshot = snapshot(sessions: [existingSession], judge: "Судья A")
        var journal = CaseEventJournal()

        let seed = transition(journal, baselineSnapshot,
                              admitted: [courtScope: [sourceCardID: sourceCardID]])
        XCTAssertTrue(seed.derivation.events.isEmpty,
                      "a first confirmed snapshot is a baseline, not imported history")
        let savedBaseline = try XCTUnwrap(seed.baselines?.courts[courtScope])
        XCTAssertEqual(savedBaseline.sessions, [existingSession])
        journal.semanticBaselines = seed.baselines
        try journal.append(seed.derivation.events)
        XCTAssertTrue(journal.events.isEmpty)

        let changed = snapshot(sessions: [existingSession], judge: "Судья B")
        let partial = transition(journal, changed, admitted: [:], kind: .partial,
                                 isComplete: false)
        XCTAssertTrue(partial.derivation.events.isEmpty)
        XCTAssertEqual(partial.baselines, journal.semanticBaselines)

        let complete = transition(journal, changed,
                                  admitted: [courtScope: [sourceCardID: sourceCardID]])
        XCTAssertEqual(complete.derivation.events.map(\.kind), [.judgeChanged])
        XCTAssertEqual(complete.derivation.events.first?.evidence.previousValue, "Судья A")
        XCTAssertEqual(complete.derivation.events.first?.evidence.value, "Судья B")
        journal.semanticBaselines = complete.baselines
        try journal.append(complete.derivation.events)

        let repeated = transition(journal, changed,
                                  admitted: [courtScope: [sourceCardID: sourceCardID]])
        XCTAssertTrue(repeated.derivation.events.isEmpty)
        XCTAssertEqual(journal.events.map(\.kind), [.judgeChanged])

        let numberEnrichment = CaseEventDeriver.derive(
            old: snapshot(instanceCaseNumber: "2-1/2026"),
            new: snapshot(instanceCaseNumber: "2-1/2026 · материал 13-2/2026"),
            attempt: attempt(kind: .usableSnapshot), observedAt: observedAt)
        XCTAssertTrue(numberEnrichment.events.isEmpty,
                      "published-number enrichment is not a new semantic case event")
    }

    func testActHasSemanticIdentitySeparateFromLegacyIDAndPresentationEvidence() throws {
        let actID = "fixture-act-42"
        let original = StoredActObservation(
            sourceCardID: sourceCardID, sourceActID: actID, title: "Определение",
            dateRaw: "31.08.2026", court: "Тестовый суд", levelRaw: "first")
        let reformatted = StoredActObservation(
            sourceCardID: sourceCardID, sourceActID: actID, title: "Судебное определение",
            dateRaw: "31.08.2026", court: "Другой формат названия суда", levelRaw: "first")
        let originalResult = CaseEventDeriver.derive(
            old: snapshot(), new: snapshot(acts: [original]),
            attempt: attempt(kind: .usableSnapshot), observedAt: observedAt)
        let reformattedResult = CaseEventDeriver.derive(
            old: snapshot(), new: snapshot(acts: [reformatted]),
            attempt: attempt(kind: .usableSnapshot), observedAt: observedAt)
        let originalEvent = try XCTUnwrap(originalResult.events.first)
        let reformattedEvent = try XCTUnwrap(reformattedResult.events.first)
        XCTAssertEqual(originalEvent.kind, .judicialActPublished)

        let legacyID = AppRouter.feedID(
            recordKey: recordKey, date: DateUtil.parse("31.08.2026")!,
            time: "—", text: actID)
        XCTAssertNotEqual(originalEvent.id, legacyID)
        XCTAssertEqual(originalEvent.id, reformattedEvent.id,
                       "the source act ID, not its display labels, determines the event identity")
        XCTAssertNotEqual(originalEvent.evidence, reformattedEvent.evidence)

        let enrichment = CaseEventDeriver.derive(
            old: snapshot(acts: [original]), new: snapshot(acts: [reformatted]),
            attempt: attempt(kind: .usableSnapshot), observedAt: observedAt)
        XCTAssertTrue(enrichment.events.isEmpty,
                      "reformatting a known act is not a newly published act")
    }

    func testMaterialReadAndKnownMigrationDoesNotWildcardLaterCardEnrichment() {
        let legacy = "fixture/2-1/2026#feed#1#14:00#Принято к производству"
        let first = AppRouter.materialFeedID(legacyID: legacy, sourceCardID: "material-card-1")
        let laterUnrelated = AppRouter.materialFeedID(
            legacyID: legacy, sourceCardID: "material-card-2")
        var state = MaterialFeedMigrationState()

        let initialTransitions = AppRouter.materialFeedTransitionsToMigrate(
            transitions: [legacy: [first]], unresolvedCounts: [:],
            readIDs: [legacy], knownIDs: [legacy], state: &state)
        XCTAssertEqual(initialTransitions, [legacy: [first]])
        let migratedRead = AppRouter.migratedFeedIDs(
            [legacy], transitions: initialTransitions, currentIDs: [first])
        let migratedKnown = AppRouter.migratedFeedIDs(
            [legacy], transitions: initialTransitions, currentIDs: [first])
        XCTAssertEqual(migratedRead, [first])
        XCTAssertEqual(migratedKnown, [first])
        XCTAssertTrue(state.consumedLegacyIDs.contains(legacy))

        let repeatedEnrichment = AppRouter.materialFeedTransitionsToMigrate(
            transitions: [legacy: [first, laterUnrelated]], unresolvedCounts: [:],
            readIDs: [legacy, first], knownIDs: [legacy, first], state: &state)
        XCTAssertTrue(repeatedEnrichment.isEmpty)
        let readAfterRepeat = AppRouter.migratedFeedIDs(
            [legacy, first], transitions: repeatedEnrichment,
            currentIDs: [first, laterUnrelated])
        let knownAfterRepeat = AppRouter.migratedFeedIDs(
            [legacy, first], transitions: repeatedEnrichment,
            currentIDs: [first, laterUnrelated])
        XCTAssertEqual(readAfterRepeat, [legacy, first])
        XCTAssertEqual(knownAfterRepeat, [legacy, first])
        XCTAssertFalse(readAfterRepeat.contains(laterUnrelated))
        XCTAssertFalse(knownAfterRepeat.contains(laterUnrelated))

        let knownOnlyLegacy = "fixture/2-2/2026#feed#1#15:00#Принято к производству"
        let knownOnlyCard = AppRouter.materialFeedID(
            legacyID: knownOnlyLegacy, sourceCardID: "material-card-known-only")
        var knownOnlyState = MaterialFeedMigrationState()
        let knownOnlyTransitions = AppRouter.materialFeedTransitionsToMigrate(
            transitions: [knownOnlyLegacy: [knownOnlyCard]], unresolvedCounts: [:],
            readIDs: [], knownIDs: [knownOnlyLegacy], state: &knownOnlyState)
        XCTAssertEqual(knownOnlyTransitions, [knownOnlyLegacy: [knownOnlyCard]])
        let knownOnlyReadAfter = AppRouter.migratedFeedIDs(
            [], transitions: knownOnlyTransitions, currentIDs: [knownOnlyCard])
        let knownOnlyKnownAfter = AppRouter.migratedFeedIDs(
            [knownOnlyLegacy], transitions: knownOnlyTransitions,
            currentIDs: [knownOnlyCard])
        XCTAssertTrue(knownOnlyReadAfter.isEmpty,
                      "known-only history must not fabricate a read mark")
        XCTAssertEqual(knownOnlyKnownAfter, [knownOnlyCard])
    }

    private func transition(_ journal: CaseEventJournal, _ fresh: CaseSnapshot,
                            admitted: [String: [String: String]],
                            kind: SourceOutcomeKind = .usableSnapshot,
                            isComplete: Bool = true)
        -> (baselines: CaseEventBaselines?, derivation: CaseEventDerivationResult) {
        CaseEventBaselineTransition.refresh(
            journal: journal, freshSnapshot: fresh, globalSnapshot: fresh,
            admittedCourts: admitted, attempt: attempt(kind: kind),
            isComplete: isComplete)
    }

    private func attempt(kind: SourceOutcomeKind) -> SourceAttempt {
        SourceAttempt(kind: kind,
                      provenance: .init(operation: .movement, sourceFamily: "sudrf",
                                        host: "compatibility.test.sudrf.ru",
                                        observedAt: observedAt))
    }

    private func snapshot(sessions: [StoredSession] = [], judge: String? = "Судья A",
                          instanceCaseNumber: String = "2-1/2026",
                          acts: [StoredActObservation] = []) -> CaseSnapshot {
        CaseSnapshot(uid: "", inForce: false, category: nil, partiesShort: "",
                     leadCharges: nil, secondPartyLine: nil, stageRaw: "first", stageTag: "",
                     statusText: "", statusChipRaw: "gray", lastEvent: "", nextEvent: "",
                     nextChipRaw: "gray", steps: [], sessions: sessions, deadlines: [],
                     actsFingerprint: nil,
                     semanticProjectionVersion: CaseEventJournal.currentDerivationVersion,
                     instanceObservations: [.init(
                        sourceCardID: sourceCardID, levelRaw: "first", court: "Тестовый суд",
                        caseNumber: instanceCaseNumber, judge: judge, result: nil)],
                     actObservations: acts, complaintObservations: [])
    }

    private func feedEntry(id: String, date: Date, kind: FeedEntryKind, text: String,
                           isUnread: Bool = true) -> FeedEntry {
        FeedEntry(id: id, dayHead: nil, date: date, time: "—", recordKey: recordKey,
                  caseNumber: "2-1/2026", client: "fixture", kind: kind, text: text,
                  actID: kind == .act ? text : nil, isUnread: isUnread)
    }
}
