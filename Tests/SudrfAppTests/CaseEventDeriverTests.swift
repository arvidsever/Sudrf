import Foundation
import Testing
@testable import SudrfApp
import SudrfKit

struct CaseEventDeriverTests {
    private let card = "sudrf|11rs0001|g1|12345"
    private let observedAt = DateUtil.parse("01.03.2027")!

    @Test func identicalReorderWhitespaceAndRenumberingAreSilent() {
        let first = session("10.03.2027", event: "Судебное заседание")
        let second = session("12.03.2027", event: "Слушание")
        var old = snapshot(sessions: [first, second])
        var new = snapshot(sessions: [second, first])
        old.instanceObservations?[0].caseNumber = "2-1/2027"
        old.instanceObservations?[0].judge = "Иванов И. И."
        new.instanceObservations?[0].caseNumber = "2-999/2027"
        new.instanceObservations?[0].judge = "  ИВАНОВ   И. И. "

        let result = derive(old, new)
        #expect(result.events.isEmpty)
    }

    @Test func addingOnlyAnExactDuplicateRowIsSilent() {
        let value = session("10.03.2027")
        let result = derive(snapshot(sessions: [value]),
                            snapshot(sessions: [value, value]))
        #expect(result.events.isEmpty)
    }

    @Test func newStableInstanceHearingAndActProduceOneEventEach() {
        let secondCard = "sudrf|11rs0002|g2|67890"
        var new = snapshot(sessions: [session("10.03.2027", source: secondCard)])
        new.instanceObservations?.append(.init(
            sourceCardID: secondCard, levelRaw: CaseInstance.Level.appeal.rawValue,
            court: "Суд апелляции", caseNumber: "33-1/2027", judge: nil, result: nil))
        new.actObservations = [.init(
            sourceCardID: secondCard, sourceActID: "act-1", title: "Определение",
            dateRaw: "02.03.2027", court: "Суд апелляции", levelRaw: "appeal")]

        let kinds = derive(snapshot(), new).events.map(\.kind)
        #expect(kinds.filter { $0 == .instanceDiscovered }.count == 1)
        #expect(kinds.filter { $0 == .hearingScheduled }.count == 1)
        #expect(kinds.filter { $0 == .judicialActPublished }.count == 1)
    }

    @Test func mergeBaselineTreatsFactsFromEveryRecordAsAlreadyKnown() throws {
        var recordWithoutAct = snapshot()
        recordWithoutAct.instanceObservations?[0].caseNumber = "2-999/2027"
        var recordWithAct = snapshot()
        recordWithAct.actObservations = [.init(
            sourceCardID: card, sourceActID: "act-1", title: "Решение",
            dateRaw: "01.03.2027", court: "Суд", levelRaw: "first")]
        let baseline = try #require(CaseEventDeriver.conservativeBaseline(
            [recordWithoutAct, recordWithAct], comparedTo: recordWithAct))

        #expect(derive(baseline, recordWithAct).events.isEmpty)
    }

    @Test func explicitPostponementWithoutNewDateProducesPostponed() {
        let old = snapshot(sessions: [session("31.03.2027")])
        let new = snapshot(sessions: [session(
            "31.03.2027", result: "Заседание отложено")])
        #expect(derive(old, new).events.map(\.kind) == [.hearingPostponed])
    }

    @Test func explicitPostponementAndSingleNewDateProduceOnlyRescheduled() {
        let old = snapshot(sessions: [session("31.03.2027")])
        let new = snapshot(sessions: [
            session("31.03.2027", result: "Заседание отложено"),
            session("11.04.2027")
        ])
        #expect(derive(old, new).events.map(\.kind) == [.hearingRescheduled])
    }

    @Test func disappearanceAndDateOnlyRewriteAreAmbiguousAndSilent() {
        let old = snapshot(sessions: [session("31.03.2027")])
        let removed = derive(old, snapshot())
        #expect(removed.events.isEmpty)
        #expect(removed.diagnostics.contains(.ambiguousHearingRewrite))

        let rewritten = derive(old, snapshot(sessions: [session("11.04.2027")]))
        #expect(rewritten.events.isEmpty)
        #expect(rewritten.diagnostics.contains(.ambiguousHearingRewrite))
    }

    @Test func multipleRescheduleCandidatesAreAmbiguousAndSilent() {
        let old = snapshot(sessions: [session("31.03.2027")])
        let new = snapshot(sessions: [
            session("31.03.2027", result: "Заседание отложено"),
            session("11.04.2027"), session("12.04.2027")
        ])
        let result = derive(old, new)
        #expect(result.events.isEmpty)
        #expect(result.diagnostics.contains(.ambiguousHearingRewrite))
    }

    @Test func partialSourceAndLegacySnapshotAreBaselines() {
        let partial = SourceAttempt(
            kind: .partial,
            provenance: .init(operation: .movement, sourceFamily: "sudrf",
                              host: "example.sudrf.ru", observedAt: observedAt))
        let result = CaseEventDeriver.derive(
            old: snapshot(), new: snapshot(sessions: [session("10.03.2027")]),
            attempt: partial, observedAt: observedAt)
        #expect(result.events.isEmpty)
        #expect(result.diagnostics == [.unusableSnapshot])

        var legacy = snapshot()
        legacy.semanticProjectionVersion = nil
        let baseline = derive(legacy, snapshot(sessions: [session("10.03.2027")]))
        #expect(baseline.events.isEmpty)
        #expect(baseline.diagnostics == [.derivationVersionChanged])
    }

    @Test func recognizedDispositionOnlyProducesResultChange() {
        var old = snapshot()
        var new = snapshot()
        old.instanceObservations?[0].result = "Оставлено без изменения"
        new.instanceObservations?[0].result = "Решение изменено"
        #expect(derive(old, new).events.map(\.kind) == [.resultChanged])

        old.instanceObservations?[0].result = "Текст редакции один"
        new.instanceObservations?[0].result = "Текст редакции два"
        #expect(derive(old, new).events.isEmpty)
    }

    @Test func explicitSnapshotLegalForceProducesOneEvent() {
        let old = snapshot()
        var new = snapshot()
        new.inForce = true

        #expect(derive(old, new).events.map(\.kind) == [.entryIntoForceRecorded])
    }

    @Test func deadlineConfirmationAndOverrideUseExistingOccurrence() throws {
        let proposed = deadline(status: .proposed, date: "10.03.2027")
        var confirmed = proposed
        confirmed.statusRaw = DeadlineStatus.confirmed.rawValue
        #expect(derive(snapshot(deadlines: [proposed]),
                       snapshot(deadlines: [confirmed])).events.map(\.kind)
                == [.deadlineConfirmed])

        var overridden = confirmed
        overridden.statusRaw = DeadlineStatus.overridden.rawValue
        overridden.dateRef = DateUtil.parse("12.03.2027")!.timeIntervalSinceReferenceDate
        #expect(derive(snapshot(deadlines: [confirmed]),
                       snapshot(deadlines: [overridden])).events.map(\.kind)
                == [.deadlineChanged])
    }

    @Test func manualDeadlineMutationSurvivesLegacyProjectionBaseline() {
        let proposed = deadline(status: .proposed, date: "10.03.2027")
        var confirmed = proposed
        confirmed.statusRaw = DeadlineStatus.confirmed.rawValue
        var old = snapshot(deadlines: [proposed])
        var new = snapshot(deadlines: [confirmed])
        old.semanticProjectionVersion = nil
        new.semanticProjectionVersion = nil

        let result = CaseEventDeriver.derive(old: old, new: new, attempt: nil,
                                             observedAt: observedAt)
        #expect(result.events.map(\.kind) == [.deadlineConfirmed])
        #expect(result.diagnostics == [.derivationVersionChanged])
    }

    @Test func journalDeduplicatesAndRejectsConflictingPayload() throws {
        let event = derive(snapshot(), snapshot(sessions: [session("10.03.2027")]))
            .events.first!
        var journal = CaseEventJournal()
        try journal.append([event, event])
        #expect(journal.events.count == 1)
        let conflict = CaseEvent(id: event.id, kind: event.kind,
                                 observedAtRef: event.observedAtRef + 1,
                                 evidence: event.evidence)
        #expect(throws: CaseEventJournalError.conflictingEventID(event.id)) {
            try journal.append([conflict])
        }
    }

    private func derive(_ old: CaseSnapshot, _ new: CaseSnapshot) -> CaseEventDerivationResult {
        CaseEventDeriver.derive(old: old, new: new, attempt: usableAttempt(),
                                observedAt: observedAt)
    }

    private func usableAttempt() -> SourceAttempt {
        SourceAttempt(kind: .usableSnapshot,
                      provenance: .init(operation: .movement, sourceFamily: "sudrf",
                                        host: "example.sudrf.ru", observedAt: observedAt))
    }

    private func session(_ date: String, source: String? = nil,
                         event: String = "Судебное заседание",
                         result: String? = nil) -> StoredSession {
        StoredSession(dateRaw: date, time: "10:00", room: "1", event: event,
                      result: result, court: "Суд", judge: "Иванов И. И.",
                      levelRaw: "first", caseNumber: "2-1/2027",
                      sourceCardID: source ?? card)
    }

    private func deadline(status: DeadlineStatus, date: String) -> StoredDeadline {
        let dateRef = DateUtil.parse(date)!.timeIntervalSinceReferenceDate
        return StoredDeadline(kind: "appeal", what: "Апелляционная жалоба", basis: "",
                       calLabel: "апелл.",
                       dateRef: dateRef,
                       statusRaw: status.rawValue, occurrenceKey: "rule|round|trigger",
                       provenance: DeadlineProvenance(
                        ruleID: "GPK-APPEAL-GENERAL", registryRevision: 1,
                        trigger: DeadlineTriggerProvenance(
                            event: "Решение", result: nil, dateRaw: "10.02.2027",
                            court: "Суд", levelRaw: "first", caseNumber: "2-1/2027"),
                        policyIDs: [], formula: "one month", source: "ГПК РФ",
                        calculatedDateRef: dateRef),
                       lifecycleRaw: DeadlineLifecycle.active.rawValue)
    }

    private func snapshot(sessions: [StoredSession] = [],
                          deadlines: [StoredDeadline] = []) -> CaseSnapshot {
        CaseSnapshot(uid: "", inForce: false, category: nil, partiesShort: "",
                     leadCharges: nil, secondPartyLine: nil, stageRaw: "first",
                     stageTag: "", statusText: "", statusChipRaw: "gray",
                     lastEvent: "", nextEvent: "", nextChipRaw: "gray", steps: [],
                     sessions: sessions, deadlines: deadlines,
                     deadlineAssessments: nil, actsFingerprint: nil,
                     semanticProjectionVersion: CaseEventJournal.currentDerivationVersion,
                     instanceObservations: [.init(
                        sourceCardID: card, levelRaw: "first", court: "Суд",
                        caseNumber: "2-1/2027", judge: nil, result: nil)],
                     actObservations: [], complaintObservations: [])
    }
}
