import Foundation
import XCTest
@testable import SudrfKit

final class CaseIdentityTests: XCTestCase {
    private let firstDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func provenance(_ date: Date? = nil,
                            operation: SourceOperation = .discovery) -> SourceProvenance {
        SourceProvenance(operation: operation, sourceFamily: "sudrf",
                         host: "court.test", observedAt: date ?? firstDate)
    }

    private func identity(_ id: String,
                          source: String = "sudrf",
                          court: String = "court-1",
                          cartoteka: String = "g1") -> SourceNativeCardIdentity {
        SourceNativeCardIdentity(sourceFamily: source, courtKey: court,
                                 cartotekaKey: cartoteka, sourceNativeID: id)
    }

    private func judicialUID(_ value: String,
                             date: Date? = nil) -> JudicialUIDObservation {
        JudicialUIDObservation(rawValue: value, provenance: provenance(date))
    }

    private func observation(_ id: String,
                             number: String? = "2-1/2026",
                             uid: String? = nil,
                             caseUID: String? = nil,
                             relations: [OfficialCardRelation] = [],
                             outcome: SourceOutcomeKind = .usableSnapshot,
                             date: Date? = nil) -> SourceCardObservation {
        SourceCardObservation(
            cardIdentity: identity(id), caseUID: caseUID, caseNumber: number,
            judicialUID: uid.map { judicialUID($0, date: date) },
            officialRelations: relations, outcome: outcome,
            provenance: provenance(date))
    }

    func testJudicialUIDNormalizationAndStructuralValidity() {
        let valid = judicialUID(" 11rs0001 - 01 - 2025 - 000001 - 10 ")
        XCTAssertEqual(valid.normalizedValue, "11RS000101202500000110")
        XCTAssertEqual(valid.validity, .valid)
        XCTAssertTrue(valid.isStructurallyValid)

        XCTAssertEqual(judicialUID("11RS0001-01-2025").validity, .partial)
        XCTAssertEqual(judicialUID("11RS0001-XX-2025-000001-10").validity, .invalid)
        XCTAssertEqual(judicialUID("—").validity, .empty)
    }

    func testCaseUIDIsNotJudicialUID() {
        let first = observation("a", caseUID: "bd648faa-6272-4b5d-819b-d148c70cc94c")
        var states: [LogicalCaseState] = []
        _ = LogicalCaseReconciler.reconcileAndUpsert(first, in: &states)

        let second = observation("b", caseUID: "bd648faa-6272-4b5d-819b-d148c70cc94c")
        let result = LogicalCaseReconciler.reconcileAndUpsert(second, in: &states)

        XCTAssertEqual(result.decision.kind, .newCase)
        XCTAssertEqual(states.count, 2)
        XCTAssertTrue(states.allSatisfy { $0.uidBindings.isEmpty })
    }

    func testExactCardIdentityIsScopedBySourceCourtAndCartoteka() {
        let first = observation("same", uid: "11RS0001-01-2025-000001-10")
        var states: [LogicalCaseState] = []
        _ = LogicalCaseReconciler.reconcileAndUpsert(first, in: &states)

        let otherCourt = SourceCardObservation(
            cardIdentity: identity("same", court: "court-2"),
            caseNumber: "2-1/2026",
            judicialUID: judicialUID("11RS0001-01-2025-000002-11"),
            provenance: provenance())
        let result = LogicalCaseReconciler.reconcileAndUpsert(otherCourt, in: &states)

        XCTAssertEqual(result.decision.kind, .newCase)
        XCTAssertEqual(states.count, 2)
    }

    func testSameValidUIDLinksDifferentSourceCardsIntoOneLogicalCase() {
        let uid = "11RS0001-01-2025-000001-10"
        var states: [LogicalCaseState] = []
        let first = LogicalCaseReconciler.reconcileAndUpsert(
            observation("first", uid: uid), in: &states)
        let second = LogicalCaseReconciler.reconcileAndUpsert(
            observation("appeal", number: "33-2/2026", uid: uid), in: &states)

        XCTAssertEqual(first.decision.kind, .newCase)
        XCTAssertEqual(second.decision.kind, .linkedExistingCase)
        XCTAssertEqual(second.decision.evidence, .matchingJudicialUID)
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states[0].cards.count, 2)
        XCTAssertEqual(states[0].judicialUIDs, ["11RS000101202500000110"])
        XCTAssertEqual(states[0].uidBindings.count, 2,
                       "один УИД может быть привязан к нескольким source-карточкам")
    }

    func testSourceNativeCardWithRenumberingKeepsCaseAndNumberHistory() {
        var states: [LogicalCaseState] = []
        _ = LogicalCaseReconciler.reconcileAndUpsert(
            observation("card", number: "8Г-1/2026"), in: &states)
        let result = LogicalCaseReconciler.reconcileAndUpsert(
            observation("card", number: "88Г-1/2026", date: firstDate.addingTimeInterval(10)),
            in: &states)

        XCTAssertEqual(result.decision.kind, .sameCard)
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states[0].cards.first?.currentCaseNumber, "88Г-1/2026")
        XCTAssertEqual(states[0].numberHistory.map(\.rawValue), ["8Г-1/2026", "88Г-1/2026"])
    }

    func testNewUIDNeedsOfficialRelationToJoinExistingCase() {
        let oldIdentity = identity("old")
        let old = SourceCardObservation(
            cardIdentity: oldIdentity, caseNumber: "8-1/2026",
            judicialUID: judicialUID("11RS0001-01-2025-000001-10"),
            provenance: provenance())
        var states: [LogicalCaseState] = []
        _ = LogicalCaseReconciler.reconcileAndUpsert(old, in: &states)

        let unrelated = observation("new", number: "88-1/2026",
                                     uid: "11RS0001-01-2026-000002-11",
                                     date: firstDate.addingTimeInterval(10))
        let newResult = LogicalCaseReconciler.reconcileAndUpsert(unrelated, in: &states)
        XCTAssertEqual(newResult.decision.kind, .newCase)
        XCTAssertEqual(states.count, 2)

        let relation = OfficialCardRelation(
            kind: .predecessor, relatedCard: oldIdentity,
            provenance: provenance(firstDate.addingTimeInterval(20)))
        let linked = observation("registered-again", number: "88-2/2026",
                                 uid: "11RS0001-01-2026-000003-12",
                                 relations: [relation],
                                 date: firstDate.addingTimeInterval(20))
        let linkedResult = LogicalCaseReconciler.reconcileAndUpsert(linked, in: &states)

        XCTAssertEqual(linkedResult.decision.kind, .linkedExistingCase)
        XCTAssertEqual(linkedResult.decision.evidence, .officialRelation)
        XCTAssertEqual(states.count, 2,
                       "связь должна выбрать старое досье, но не объединять прежний unrelated UID")
        XCTAssertEqual(states.first { $0.contains(card: oldIdentity) }?.cards.count, 2)
        XCTAssertEqual(states.first { $0.contains(card: oldIdentity) }?.uidBindings.count, 2)
    }

    func testRegistryRelationCanUseKnownUIDAndInvalidUIDCannotMatch() {
        var states: [LogicalCaseState] = []
        _ = LogicalCaseReconciler.reconcileAndUpsert(
            observation("old", uid: "11RS0001-01-2025-000001-10"), in: &states)

        let knownUIDRelation = OfficialCardRelation(
            kind: .registry,
            relatedUID: judicialUID("11RS0001-01-2025-000001-10"),
            provenance: provenance())
        let linked = observation("new", uid: "11RS0001-01-2026-000002-11",
                                 relations: [knownUIDRelation])
        let linkedResult = LogicalCaseReconciler.reconcileAndUpsert(linked, in: &states)
        XCTAssertEqual(linkedResult.decision.kind, .linkedExistingCase)
        XCTAssertEqual(states.count, 1)

        let invalidRelation = OfficialCardRelation(
            kind: .registry,
            relatedUID: judicialUID("11RS0001-01-2025"),
            provenance: provenance())
        let unrelated = observation("not-linked", uid: "11RS0001-01-2026-000003-12",
                                     relations: [invalidRelation])
        let unrelatedResult = LogicalCaseReconciler.reconcileAndUpsert(unrelated, in: &states)
        XCTAssertEqual(unrelatedResult.decision.kind, .newCase)
        XCTAssertEqual(states.count, 2)
    }

    func testUnusableRegistryOutcomeDoesNotMutateState() {
        var states: [LogicalCaseState] = []
        _ = LogicalCaseReconciler.reconcileAndUpsert(
            observation("known", uid: "11RS0001-01-2025-000001-10"), in: &states)
        let before = states

        for outcome in [SourceOutcomeKind.honestZero, .partial, .transportFailure, .parserFailure] {
            let attempt = observation("new", uid: "11RS0001-01-2026-000002-11",
                                      outcome: outcome)
            let result = LogicalCaseReconciler.reconcileAndUpsert(attempt, in: &states)
            XCTAssertEqual(result.decision.kind, .candidate)
            XCTAssertFalse(result.decision.mutated)
            XCTAssertEqual(states, before)
        }
    }

    func testDuplicateObservationIsIdempotent() {
        let value = observation("same", uid: "11RS0001-01-2025-000001-10")
        var states: [LogicalCaseState] = []
        _ = LogicalCaseReconciler.reconcileAndUpsert(value, in: &states)
        let before = states

        let result = LogicalCaseReconciler.reconcileAndUpsert(value, in: &states)
        XCTAssertEqual(result.decision.kind, .sameCard)
        XCTAssertEqual(states, before)
    }

    func testLegacyDuplicateUIDGraphsAreMergedIntoDeterministicSurvivor() {
        let uid = judicialUID("11RS0001-01-2025-000001-10")
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let firstObservation = observation("first", uid: uid.rawValue)
        let secondObservation = observation("second", uid: uid.rawValue)
        var states = [
            LogicalCaseState(logicalCaseID: secondID, observation: secondObservation),
            LogicalCaseState(logicalCaseID: firstID, observation: firstObservation)
        ]

        let result = LogicalCaseReconciler.reconcileAndUpsert(
            observation("third", uid: uid.rawValue), in: &states)

        XCTAssertEqual(result.decision.kind, .linkedExistingCase)
        XCTAssertEqual(states.count, 1)
        XCTAssertEqual(states[0].logicalCaseID, firstID)
        XCTAssertEqual(states[0].cards.count, 3)
    }

    func testStateRoundTripsThroughCodable() throws {
        var states: [LogicalCaseState] = []
        _ = LogicalCaseReconciler.reconcileAndUpsert(
            observation("card", number: "8-1/2026",
                        uid: "11RS0001-01-2025-000001-10"), in: &states)
        let relation = OfficialCardRelation(
            kind: .sourceNative, relatedCard: identity("card"), provenance: provenance())
        let enriched = observation("other", number: "88-1/2026",
                                   uid: "11RS0001-01-2026-000002-11",
                                   relations: [relation])
        _ = LogicalCaseReconciler.reconcileAndUpsert(enriched, in: &states)

        let data = try JSONEncoder().encode(states[0])
        let decoded = try JSONDecoder().decode(LogicalCaseState.self, from: data)
        XCTAssertEqual(decoded, states[0])
    }
}
