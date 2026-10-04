import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

final class CaseEventMirrorBaselineTests: XCTestCase {
    private let mirrorScope = "sudrf|mirror.sudrf.ru"
    private let canonicalScope = "sudrf|canonical.sudrf.ru"
    private let oldMirrorCard = "sudrf|mirror.sudrf.ru|g1|mirror-card"
    private let newMirrorCard = "sudrf|canonical.sudrf.ru|g1|mirror-card"
    private let otherCanonicalCard = "sudrf|canonical.sudrf.ru|g1|other-card"
    private let oldMirrorID = "mirror-source-old"
    private let newMirrorID = "mirror-source-new"
    private let otherCanonicalID = "canonical-source-other"
    private let oldActID = "act_mirror.sudrf.ru#2-100/2026"
    private let newActID = "act_canonical.sudrf.ru#2-100/2026"
    private let oldActBody = "ОПРЕДЕЛИЛ: карточка рассмотрена."
    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testMirrorMigrationPreservesPendingJudgeChangeAndRemapsHandledAct() throws {
        var journal = CaseEventJournal()
        let first = snapshot(mirrorSourceID: oldMirrorID, mirrorJudge: "Судья A",
                             mirrorActID: oldActID, otherSourceID: otherCanonicalID,
                             otherJudge: "Судья B")
        let seeded = transition(
            journal, first,
            admitted: [mirrorScope: [oldMirrorCard: oldMirrorID],
                       canonicalScope: [otherCanonicalCard: otherCanonicalID]],
            actBodies: [oldActID: oldActBody])
        XCTAssertTrue(seeded.derivation.events.isEmpty, "первый baseline должен быть тихим")
        journal.semanticBaselines = try XCTUnwrap(seeded.baselines)

        // The partial display snapshot changes, but no source scope is admitted.
        let partialDisplay = snapshot(mirrorSourceID: oldMirrorID, mirrorJudge: "Судья C",
                                      mirrorActID: oldActID, otherSourceID: otherCanonicalID,
                                      otherJudge: "Судья B")
        let partial = transition(journal, partialDisplay, admitted: [:], complete: false)
        XCTAssertTrue(partial.derivation.events.isEmpty)
        XCTAssertEqual(partial.baselines, journal.semanticBaselines)

        // The canonical host now publishes the same native card. Only the
        // handled A→current transition and an equal, already-handled act body
        // may cross the proven native-card continuity mapping.
        let current = snapshot(mirrorSourceID: newMirrorID, mirrorJudge: "Судья C",
                               mirrorActID: newActID, otherSourceID: otherCanonicalID,
                               otherJudge: "Судья B")
        let migrated = transition(
            journal, current,
            admitted: [canonicalScope: [newMirrorCard: newMirrorID,
                                        otherCanonicalCard: otherCanonicalID]],
            actBodies: [newActID: "  \(oldActBody)  "],
            nativeContinuities: [oldMirrorCard: newMirrorCard])

        XCTAssertEqual(migrated.derivation.events.map(\.kind), [.judgeChanged])
        XCTAssertEqual(migrated.derivation.events.first?.evidence.previousValue, "Судья A")
        XCTAssertEqual(migrated.derivation.events.first?.evidence.value, "Судья C")
        XCTAssertEqual(migrated.derivation.events.first?.evidence.sourceCardID, newMirrorID)

        let canonical = try XCTUnwrap(migrated.baselines?.courts[canonicalScope])
        XCTAssertEqual(canonical.cards[newMirrorCard], newMirrorID)
        XCTAssertEqual(canonical.cards[otherCanonicalCard], otherCanonicalID)
        XCTAssertEqual(canonical.instances.first(where: {
            $0.sourceCardID == newMirrorID
        })?.judge, "Судья C")
        XCTAssertEqual(canonical.acts.map(\.sourceActID), [newActID])

        journal.semanticBaselines = migrated.baselines
        let repeatRefresh = transition(
            journal, current,
            admitted: [canonicalScope: [newMirrorCard: newMirrorID,
                                        otherCanonicalCard: otherCanonicalID]],
            actBodies: [newActID: oldActBody],
            nativeContinuities: [oldMirrorCard: newMirrorCard])
        XCTAssertTrue(repeatRefresh.derivation.events.isEmpty)
    }

    func testChangedMirrorActBodyIsStillPublishedAfterNativeMigration() throws {
        var journal = CaseEventJournal()
        let first = snapshot(mirrorSourceID: oldMirrorID, mirrorJudge: "Судья A",
                             mirrorActID: oldActID, otherSourceID: otherCanonicalID,
                             otherJudge: "Судья B")
        let seeded = transition(
            journal, first,
            admitted: [mirrorScope: [oldMirrorCard: oldMirrorID],
                       canonicalScope: [otherCanonicalCard: otherCanonicalID]],
            actBodies: [oldActID: oldActBody])
        journal.semanticBaselines = try XCTUnwrap(seeded.baselines)

        let current = snapshot(mirrorSourceID: newMirrorID, mirrorJudge: "Судья A",
                               mirrorActID: newActID, otherSourceID: otherCanonicalID,
                               otherJudge: "Судья B")
        let migrated = transition(
            journal, current,
            admitted: [canonicalScope: [newMirrorCard: newMirrorID,
                                        otherCanonicalCard: otherCanonicalID]],
            actBodies: [newActID: "Новое содержание акта."],
            nativeContinuities: [oldMirrorCard: newMirrorCard])

        XCTAssertEqual(migrated.derivation.events.map(\.kind), [.judicialActPublished])
        XCTAssertEqual(migrated.derivation.events.first?.evidence.sourceCardID, newMirrorID)
        XCTAssertEqual(migrated.derivation.events.first?.evidence.occurrenceKey, newActID)
    }

    func testConflictingTargetBaselineSeedsQuietlyAndKeepsPriorJournalEvents() throws {
        var journal = CaseEventJournal()
        let mirror = snapshot(mirrorSourceID: oldMirrorID, mirrorJudge: "Судья A",
                              mirrorActID: oldActID, otherSourceID: otherCanonicalID,
                              otherJudge: "Судья B")
        var canonical = mirror
        canonical.instanceObservations?[0].sourceCardID = newMirrorID
        canonical.instanceObservations?[0].judge = "Судья X"
        canonical.actObservations?[0].sourceCardID = newMirrorID
        canonical.actObservations?[0].sourceActID = newActID

        let seeded = transition(
            journal, canonical,
            admitted: [mirrorScope: [oldMirrorCard: oldMirrorID],
                       canonicalScope: [newMirrorCard: newMirrorID,
                                        otherCanonicalCard: otherCanonicalID]],
            actBodies: [oldActID: oldActBody, newActID: "Другое ранее опубликованное содержание."])
        XCTAssertTrue(seeded.derivation.events.isEmpty)
        journal.semanticBaselines = try XCTUnwrap(seeded.baselines)
        let priorEvent = CaseEvent.make(
            kind: .complaintRegistered, occurrence: ["existing"], observedAt: observedAt,
            evidence: .init(sourceCardID: otherCanonicalID))
        try journal.append([priorEvent])

        let current = snapshot(mirrorSourceID: newMirrorID, mirrorJudge: "Судья C",
                               mirrorActID: newActID, otherSourceID: otherCanonicalID,
                               otherJudge: "Судья B")
        let migrated = transition(
            journal, current,
            admitted: [canonicalScope: [newMirrorCard: newMirrorID,
                                        otherCanonicalCard: otherCanonicalID]],
            actBodies: [newActID: "Новое текущее содержание."],
            nativeContinuities: [oldMirrorCard: newMirrorCard])

        XCTAssertTrue(migrated.derivation.events.isEmpty,
                      "конфликт двух обработанных baseline должен тихо установить текущую базу")
        var afterAppend = journal
        try afterAppend.append(migrated.derivation.events)
        XCTAssertEqual(afterAppend.events, [priorEvent])
        XCTAssertFalse(migrated.baselines?.conflictingCourts.contains(canonicalScope) ?? true)
        let currentBaseline = try XCTUnwrap(migrated.baselines?.courts[canonicalScope])
        XCTAssertEqual(currentBaseline.instances.first(where: {
            $0.sourceCardID == newMirrorID
        })?.judge, "Судья C")
        XCTAssertEqual(currentBaseline.cards[otherCanonicalCard], otherCanonicalID)

        var later = current
        later.instanceObservations?[0].judge = "Судья D"
        var laterJournal = afterAppend
        laterJournal.semanticBaselines = migrated.baselines
        let nextRefresh = transition(
            laterJournal,
            later,
            admitted: [canonicalScope: [newMirrorCard: newMirrorID,
                                        otherCanonicalCard: otherCanonicalID]],
            actBodies: [newActID: "Новое текущее содержание."])
        XCTAssertEqual(nextRefresh.derivation.events.map(\.kind), [.judgeChanged])
        XCTAssertEqual(nextRefresh.derivation.events.first?.evidence.previousValue, "Судья C")
    }

    private func transition(_ journal: CaseEventJournal, _ snapshot: CaseSnapshot,
                            admitted: [String: [String: String]],
                            complete: Bool = true,
                            actBodies: [String: String] = [:],
                            nativeContinuities: [String: String] = [:])
        -> (baselines: CaseEventBaselines?, derivation: CaseEventDerivationResult) {
        CaseEventBaselineTransition.refresh(
            journal: journal, freshSnapshot: snapshot, globalSnapshot: snapshot,
            admittedCourts: admitted,
            attempt: .init(kind: complete ? .usableSnapshot : .partial,
                           provenance: .init(operation: .movement, sourceFamily: "sudrf",
                                             host: "canonical.sudrf.ru", observedAt: observedAt)),
            isComplete: complete, actBodies: actBodies,
            nativeContinuities: nativeContinuities)
    }

    private func snapshot(mirrorSourceID: String, mirrorJudge: String,
                          mirrorActID: String, otherSourceID: String,
                          otherJudge: String) -> CaseSnapshot {
        CaseSnapshot(uid: "", inForce: false, category: nil, partiesShort: "",
                     leadCharges: nil, secondPartyLine: nil, stageRaw: "first", stageTag: "",
                     statusText: "", statusChipRaw: "gray", lastEvent: "", nextEvent: "",
                     nextChipRaw: "gray", steps: [], sessions: [], deadlines: [],
                     actsFingerprint: nil,
                     semanticProjectionVersion: CaseEventJournal.currentDerivationVersion,
                     instanceObservations: [
                        .init(sourceCardID: mirrorSourceID, levelRaw: "first", court: "Суд A",
                              caseNumber: "2-100/2026", judge: mirrorJudge, result: nil),
                        .init(sourceCardID: otherSourceID, levelRaw: "first", court: "Суд B",
                              caseNumber: "2-200/2026", judge: otherJudge, result: nil)
                     ],
                     actObservations: [
                        .init(sourceCardID: mirrorSourceID, sourceActID: mirrorActID,
                              title: "Определение", dateRaw: "10.02.2026", court: "Суд A",
                              levelRaw: "first")
                     ],
                     complaintObservations: [])
    }
}
