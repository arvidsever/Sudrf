import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class CaseEventBaselineTests: XCTestCase {
    private let card = "sudrf|example.sudrf.ru|g1|1"
    private let scope = "sudrf|example.sudrf.ru"
    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testPendingActHearingAndNewCardAreHandledOnlyOnce() throws {
        var journal = CaseEventJournal()
        let baseline = snapshot()
        var state = transition(journal, baseline)
        journal.semanticBaselines = state.baselines
        var fresh = baseline
        fresh.sessions = [.init(dateRaw: "10.03.2027", time: "10:00", room: nil,
                               event: "Судебное заседание", result: nil, court: "Суд",
                               levelRaw: "first", sourceCardID: card)]
        fresh.actObservations = [.init(sourceCardID: card, sourceActID: "act-1", title: "Решение",
                                      dateRaw: "10.02.2027", court: "Суд", levelRaw: "first")]
        let second = "sudrf|example.sudrf.ru|g1|2"
        fresh.instanceObservations?.append(.init(sourceCardID: second, levelRaw: "first",
                                                 court: "Суд", caseNumber: "2-2/2027", judge: nil, result: nil))
        state = transition(journal, fresh, admitted: [:], complete: false)
        XCTAssertTrue(state.derivation.events.isEmpty)
        XCTAssertEqual(state.baselines, journal.semanticBaselines)
        state = transition(journal, fresh, admitted: [scope: [card: card, second: second]])
        XCTAssertEqual(Set(state.derivation.events.map(\.kind)),
                       [.judicialActPublished, .hearingScheduled, .instanceDiscovered])
        journal.semanticBaselines = state.baselines
        try journal.append(state.derivation.events)
        XCTAssertTrue(transition(journal, fresh, admitted: [scope: [card: card, second: second]])
            .derivation.events.isEmpty)
    }

    func testGlobalFactsWaitForCompleteChainAndManualDeadlineIsPointwise() throws {
        var old = snapshot()
        old.deadlines = [deadline("1", date: "01.03.2027"), deadline("2", date: "02.03.2027")]
        var journal = CaseEventJournal()
        journal.semanticBaselines = transition(journal, old).baselines
        var fresh = old
        fresh.inForce = true
        fresh.deadlines[1].dateRef = DateUtil.parse("05.03.2027")!.timeIntervalSinceReferenceDate
        fresh.instanceObservations?[0].judge = "B"
        let partial = transition(journal, fresh, complete: false)
        XCTAssertEqual(partial.derivation.events.map(\.kind), [.judgeChanged])
        XCTAssertEqual(partial.baselines?.global, journal.semanticBaselines?.global)
        journal.semanticBaselines = partial.baselines
        var edited = fresh
        edited.deadlines[0].statusRaw = DeadlineStatus.confirmed.rawValue
        let manual = CaseEventBaselineTransition.manualDeadline(
            journal: journal, before: fresh, after: edited, index: 0, observedAt: observedAt)
        XCTAssertEqual(manual.derivation.events.map(\.kind), [.deadlineConfirmed])
        XCTAssertEqual(manual.baselines?.global?.deadlines[1], old.deadlines[1])
        journal.semanticBaselines = manual.baselines
        let complete = transition(journal, edited)
        XCTAssertEqual(Set(complete.derivation.events.map(\.kind)), [.deadlineChanged, .entryIntoForceRecorded])
        journal.semanticBaselines = complete.baselines
        XCTAssertTrue(transition(journal, edited).derivation.events.isEmpty)
    }

    func testMergePreservesHandledBaselineInsteadOfPendingDisplayFacts() throws {
        var left = CaseEventJournal()
        left.semanticBaselines = transition(left, snapshot()).baselines
        var right = CaseEventJournal()
        let otherCard = "sudrf|other.sudrf.ru|g1|9"
        let otherScope = "sudrf|other.sudrf.ru"
        var other = snapshot()
        other.instanceObservations?[0].sourceCardID = otherCard
        right.semanticBaselines = transition(right, other, admitted: [otherScope: [otherCard: otherCard]]).baselines
        let merged = try CaseEventJournal.merged([left, right])
        var changed = snapshot()
        changed.instanceObservations?[0].judge = "B"
        let result = transition(merged, changed, complete: false)
        XCTAssertEqual(result.derivation.events.map(\.kind), [.judgeChanged])
        XCTAssertNotNil(result.baselines?.courts[otherScope])
        XCTAssertEqual(try CaseEventJournal.merged([right, left]).semanticBaselines, merged.semanticBaselines)
    }

    func testConflictingCourtBaselinesSeedSilentlyWithoutLosingOtherCourts() throws {
        var left = CaseEventJournal()
        left.semanticBaselines = transition(left, snapshot()).baselines
        var changed = snapshot()
        changed.instanceObservations?[0].judge = "B"
        var right = CaseEventJournal()
        right.semanticBaselines = transition(right, changed).baselines
        var merged = try CaseEventJournal.merged([left, right])
        XCTAssertNil(merged.semanticBaselines?.courts[scope])
        XCTAssertEqual(merged.semanticBaselines?.conflictingCourts, [scope])
        changed.instanceObservations?[0].judge = "C"
        let seeded = transition(merged, changed)
        XCTAssertTrue(seeded.derivation.events.isEmpty)
        merged.semanticBaselines = seeded.baselines
        changed.instanceObservations?[0].judge = "D"
        XCTAssertEqual(transition(merged, changed).derivation.events.map(\.kind), [.judgeChanged])
    }

    func testNativeContinuityRemapsOnlyHandledValues() {
        let old = snapshot()
        var journal = CaseEventJournal()
        journal.semanticBaselines = transition(journal, old).baselines
        let corrected = "sudrf|11rs0001|g1|1"
        var new = old
        new.instanceObservations?[0].sourceCardID = corrected
        new.instanceObservations?[0].judge = "B"
        let result = transition(journal, new, admitted: [scope: [card: corrected]])
        XCTAssertEqual(result.derivation.events.map(\.kind), [.judgeChanged])
        XCTAssertEqual(result.derivation.events.first?.evidence.previousValue, "A")
        XCTAssertEqual(result.derivation.events.first?.evidence.sourceCardID, corrected)
    }

    func testConfirmedEmptyCourtDoesNotDeleteKnownCardsAndDetectsFirstProduction() {
        var journal = CaseEventJournal()
        var empty = snapshot()
        empty.instanceObservations = []
        journal.semanticBaselines = transition(journal, empty, admitted: [scope: [:]]).baselines
        let found = transition(journal, snapshot())
        XCTAssertEqual(found.derivation.events.map(\.kind), [.instanceDiscovered])
        journal.semanticBaselines = found.baselines
        let missing = transition(journal, empty, admitted: [scope: [:]])
        XCTAssertTrue(missing.derivation.events.isEmpty)
        XCTAssertEqual(missing.baselines?.courts[scope], found.baselines?.courts[scope])
    }

    func testOldJournalAndDerivationVersionStartWithoutHistoricalStorm() throws {
        let seed = CaseEvent.make(kind: .complaintRegistered, occurrence: ["seed"],
                                  observedAt: observedAt, evidence: .init())
        var legacy = CaseEventJournal(events: [seed])
        let initial = transition(legacy, snapshot())
        XCTAssertTrue(initial.derivation.events.isEmpty)
        XCTAssertEqual(legacy.events, [seed])
        legacy.semanticBaselines = initial.baselines
        legacy.semanticBaselines?.derivationVersion = 0
        var changed = snapshot()
        changed.instanceObservations?[0].judge = "B"
        let versioned = transition(legacy, changed)
        XCTAssertTrue(versioned.derivation.events.isEmpty)
        XCTAssertTrue(versioned.derivation.diagnostics.contains(.derivationVersionChanged))
        var data = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        data.removeValue(forKey: "semanticBaselines")
        let decoded = try JSONDecoder().decode(CaseEventJournal.self, from: JSONSerialization.data(withJSONObject: data))
        XCTAssertNil(decoded.semanticBaselines)
        XCTAssertEqual(decoded.events, [seed])
    }

    private func transition(_ journal: CaseEventJournal, _ fresh: CaseSnapshot,
                            admitted: [String: [String: String]]? = nil, complete: Bool = true)
        -> (baselines: CaseEventBaselines?, derivation: CaseEventDerivationResult) {
        CaseEventBaselineTransition.refresh(
            journal: journal, freshSnapshot: fresh, globalSnapshot: fresh,
            admittedCourts: admitted ?? [scope: [card: card]],
            attempt: .init(kind: complete ? .usableSnapshot : .partial,
                           provenance: .init(operation: .movement, sourceFamily: "sudrf",
                                             host: "example.sudrf.ru", observedAt: observedAt)),
            isComplete: complete)
    }

    private func snapshot() -> CaseSnapshot {
        CaseSnapshot(uid: "", inForce: false, category: nil, partiesShort: "",
                     leadCharges: nil, secondPartyLine: nil, stageRaw: "first", stageTag: "",
                     statusText: "", statusChipRaw: "gray", lastEvent: "", nextEvent: "",
                     nextChipRaw: "gray", steps: [], sessions: [], deadlines: [], actsFingerprint: nil,
                     semanticProjectionVersion: CaseEventJournal.currentDerivationVersion,
                     instanceObservations: [.init(sourceCardID: card, levelRaw: "first", court: "Суд",
                                                 caseNumber: "2-1/2027", judge: "A", result: nil)],
                     actObservations: [], complaintObservations: [])
    }

    private func deadline(_ key: String, date: String) -> StoredDeadline {
        let dateRef = DateUtil.parse(date)!.timeIntervalSinceReferenceDate
        return StoredDeadline(kind: "appeal", what: "Апелляционная жалоба", basis: "",
                              calLabel: "апелл.", dateRef: dateRef, statusRaw: DeadlineStatus.proposed.rawValue,
                              occurrenceKey: key,
                              provenance: .init(ruleID: "GPK-APPEAL-GENERAL", registryRevision: 1,
                                                trigger: .init(event: "Решение", dateRaw: "01.02.2027", court: "Суд",
                                                               levelRaw: "first", caseNumber: "2-1/2027"),
                                                policyIDs: [], formula: "one month", source: "ГПК РФ", calculatedDateRef: dateRef))
    }
}
