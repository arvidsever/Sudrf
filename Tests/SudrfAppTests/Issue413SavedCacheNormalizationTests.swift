import Foundation
import SwiftData
import XCTest
@testable import SudrfKit
@testable import SudrfApp

private actor Issue413MovementSequence: MovementProviding {
    private let movement: CaseMovement

    init(_ movement: CaseMovement) { self.movement = movement }

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        movement
    }
}

private struct Issue413UnusedVSRFProvider: VSRFProviding {
    func search(uniqueNumber: String?, oldCaseNumber: String?,
                keywords: String?) async throws -> VSRFSearchResults {
        throw CancellationError()
    }

    func fetchCard(productionID: String, section: VSRFCardSection) async throws -> VSRFCard {
        throw CancellationError()
    }
}

@MainActor
final class Issue413SavedCacheNormalizationTests: XCTestCase {
    private let ownURL = URL(string:
        "https://mos-gorsud.ru/mgs/services/cases/appeal-civil/details/issue413-appeal")!
    private let baseURL = URL(string:
        "https://mos-gorsud.ru/mgs/services/cases/first-civil/details/issue413-base")!
    private let districtURL = URL(string:
        "https://mos-gorsud.ru/rs/cheremushkinskij/services/cases/civil/details/issue413-district")!
    private let composite = "Черёмушкинский районный суд (Синтетический судья А.А.)"
    private let ownCourt = "Московский городской суд"
    private let seenAt = Date(timeIntervalSince1970: 1_800_000_100)
    private let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testOnlyVerifiedMoscowAppealCardGetsOwnCourtCorrection() throws {
        let context = context()
        let old = try movement(ownCourt: composite, ownJudge: composite)
        let normalized = MovementDerivation.normalizedMovement(old, context: context)

        let appeal = try XCTUnwrap(normalized.instances.first { $0.sourceURL == ownURL })
        XCTAssertEqual(appeal.court, ownCourt)
        XCTAssertNil(appeal.judge)

        let district = try XCTUnwrap(normalized.instances.first { $0.sourceURL == districtURL })
        XCTAssertEqual(district.court, "Черёмушкинский районный суд")
        XCTAssertEqual(district.judge, "Синтетический мировой судья")

        let cassation = try XCTUnwrap(normalized.instances.first { $0.domain == "3kas.sudrf.ru" })
        XCTAssertEqual(cassation.court, "Третий кассационный суд общей юрисдикции")
        XCTAssertEqual(cassation.judge, "Синтетический судья кассации")

        var standaloneJudge = old
        let ownIndex = try XCTUnwrap(standaloneJudge.instances.firstIndex { $0.sourceURL == ownURL })
        standaloneJudge.instances[ownIndex].judge = "Синтетический судья А.А."
        let withFIO = MovementDerivation.normalizedMovement(standaloneJudge, context: context)
        let retained = try XCTUnwrap(withFIO.instances.first { $0.sourceURL == ownURL })
        XCTAssertEqual(retained.court, ownCourt)
        XCTAssertEqual(retained.judge, "Синтетический судья А.А.")

        let variant = "ЧЕРЕМУШКИНСКИЙ   РАЙОННЫЙ СУД (Синтетический судья А.А.)"
        let normalizedVariant = try MovementDerivation.normalizedMovement(
            movement(ownCourt: variant, ownJudge: variant), context: context)
        let variantAppeal = try XCTUnwrap(normalizedVariant.instances.first {
            $0.sourceURL == ownURL
        })
        XCTAssertEqual(variantAppeal.court, ownCourt,
                       "официальное районное название нормализуется по ё, регистру и пробелам")
        XCTAssertNil(variantAppeal.judge)

        let unknownComposite = "Синтетический районный суд (Синтетический судья А.А.)"
        let normalizedUnknown = try MovementDerivation.normalizedMovement(
            movement(ownCourt: unknownComposite, ownJudge: unknownComposite), context: context)
        let unknownAppeal = try XCTUnwrap(normalizedUnknown.instances.first {
            $0.sourceURL == ownURL
        })
        XCTAssertEqual(unknownAppeal.court, ownCourt)
        XCTAssertEqual(unknownAppeal.judge, unknownComposite,
                       "неизвестное название не доказывает ошибочность судьи")

        var foreignSection = old
        let foreignURL = URL(string:
            "https://mos-gorsud.ru/rs/cheremushkinskij/services/cases/appeal-civil/details/foreign")!
        let foreign = CaseInstance(
            level: .appeal, court: composite, caseNumber: "33-0002/2020",
            judge: composite, domain: "mos-gorsud.ru", foundByUID: false,
            result: nil, sessions: [], sourceURL: foreignURL)
        foreignSection.instances.append(foreign)
        let noForeignChange = MovementDerivation.normalizedMovement(foreignSection, context: context)
        let retainedForeign = try XCTUnwrap(noForeignChange.instances.first { $0.sourceURL == foreignURL })
        XCTAssertEqual(retainedForeign.court, composite)
        XCTAssertEqual(retainedForeign.judge, composite)

        var wrongHost = old
        let untrustedURL = URL(string:
            "https://example.invalid/mgs/services/cases/appeal-civil/details/issue413-appeal")!
        wrongHost.instances.append(CaseInstance(
            level: .appeal, court: composite, caseNumber: "33-0002/2020",
            judge: composite, domain: "mos-gorsud.ru", foundByUID: false,
            result: nil, sessions: [], sourceURL: untrustedURL))
        let noWrongHostChange = MovementDerivation.normalizedMovement(wrongHost, context: context)
        let retainedWrongHost = try XCTUnwrap(noWrongHostChange.instances.first {
            $0.sourceURL == untrustedURL
        })
        XCTAssertEqual(retainedWrongHost.court, composite)
        XCTAssertEqual(retainedWrongHost.judge, composite)
    }

    func testUnlinkedAppealActDoesNotInheritVerifiedCardOwner() throws {
        let context = context()
        var unlinked = try movement(ownCourt: composite, ownJudge: composite)
        let actID = "issue413-unlinked-appeal-act"
        unlinked.acts = [CaseAct(id: actID, title: "Апелляционное определение",
                                 date: "01.02.2020", courtShort: composite,
                                 instanceLevel: .appeal)]
        XCTAssertFalse(unlinked.instances.contains { $0.linkedActIDs.contains(actID) })

        let originalFingerprint = MovementDerivation.sourceActsFingerprint(from: unlinked)
        let corrections = MovementDerivation.moscowOwnCourtCorrections(
            in: unlinked, context: context)
        let normalized = MovementDerivation.normalizedMoscowOwnCourtFacts(
            in: unlinked, context: context)
        XCTAssertEqual(normalized.acts.first?.courtShort, composite,
                       "уровня дела недостаточно для привязки акта к карточке")

        var savedSnapshot = MovementDerivation.snapshot(from: unlinked, context: context)
        savedSnapshot.actsFingerprint = originalFingerprint
        let correctedSnapshot = MovementDerivation.normalizedMoscowSnapshotFacts(
            savedSnapshot, corrections: corrections,
            sourceMovement: unlinked, context: context)
        XCTAssertEqual(correctedSnapshot.actsFingerprint, originalFingerprint,
                       "fingerprint не должен меняться без доказанной связи акта")
        XCTAssertEqual(correctedSnapshot.actObservations, savedSnapshot.actObservations,
                       "нельзя приписывать старое наблюдение акта по одному уровню")
    }

    func testAmbiguouslyLinkedAppealActDoesNotInheritVerifiedCardOwner() throws {
        let context = context()
        let actID = "issue413-ambiguous-appeal-act"
        var ambiguous = try movement(ownCourt: composite, ownJudge: composite,
                                     actID: actID)
        ambiguous.acts[0].courtShort = composite
        ambiguous.instances.append(CaseInstance(
            level: .appeal, court: "Синтетический другой суд",
            caseNumber: "33-0002/2020", judge: nil,
            domain: "other-court.example", foundByUID: false,
            result: nil, sessions: [], actIDs: [actID]))
        XCTAssertEqual(ambiguous.instances.filter { $0.linkedActIDs.contains(actID) }.count, 2)

        let originalFingerprint = MovementDerivation.sourceActsFingerprint(from: ambiguous)
        let corrections = MovementDerivation.moscowOwnCourtCorrections(
            in: ambiguous, context: context)
        let normalized = MovementDerivation.normalizedMoscowOwnCourtFacts(
            in: ambiguous, context: context)
        XCTAssertEqual(normalized.acts.first?.courtShort, composite,
                       "две связи не дают единственного владельца акта")

        var savedSnapshot = MovementDerivation.snapshot(from: ambiguous, context: context)
        savedSnapshot.actsFingerprint = originalFingerprint
        let correctedSnapshot = MovementDerivation.normalizedMoscowSnapshotFacts(
            savedSnapshot, corrections: corrections,
            sourceMovement: ambiguous, context: context)
        XCTAssertEqual(correctedSnapshot.actsFingerprint, originalFingerprint)
    }

    func testMissingObservationIdentityFailsClosedAcrossSameNumberAppeals() throws {
        let context = context()
        var source = try movement(ownCourt: composite, ownJudge: composite)
        source.instances.append(CaseInstance(
            level: .appeal, court: composite, caseNumber: "33-0001/2020",
            judge: composite, domain: "foreign.example", foundByUID: false,
            result: nil, sessions: []))
        let correction = try XCTUnwrap(MovementDerivation.moscowOwnCourtCorrections(
            in: source, context: context).first)
        let legacy = StoredInstanceObservation(
            sourceCardID: nil, levelRaw: CaseInstance.Level.appeal.rawValue,
            court: composite, caseNumber: "33-0001/2020", judge: composite, result: nil)

        let normalized = MovementDerivation.normalizedMoscowInstances(
            [legacy], corrections: [correction], sourceMovement: source,
            context: context)
        XCTAssertEqual(normalized, [legacy],
                       "nil source ID не связывается, если есть другая апелляция с тем же номером")
    }

    func testSemanticBaselineUsesItsOwnCourtAndJudgeFacts() throws {
        let context = context()
        let currentDisplay = try movement(ownCourt: ownCourt,
                                          ownJudge: "Синтетический судья Б.Б.")
        let corrections = MovementDerivation.moscowOwnCourtCorrections(
            in: currentDisplay, context: context)
        let ownCardID = try cardIdentity(for: ownURL, cartotekaID: "g2")
        let baselineJudge = "Синтетический судья А.А."
        let invalidBaseline = StoredInstanceObservation(
            sourceCardID: ownCardID, levelRaw: CaseInstance.Level.appeal.rawValue,
            court: composite, caseNumber: "33-0001/2020", judge: composite, result: nil)
        let validBaseline = StoredInstanceObservation(
            sourceCardID: ownCardID, levelRaw: CaseInstance.Level.appeal.rawValue,
            court: composite, caseNumber: "33-0001/2020", judge: baselineJudge, result: nil)
        var template = MovementDerivation.snapshot(from: currentDisplay, context: context)
        template.instanceObservations = [invalidBaseline, validBaseline]
        let baseline = CaseEventCourtBaseline(snapshot: template, cards: [ownCardID: ownCardID])

        var normalized = baseline
        normalized.normalizeMoscowOwnCourtFacts(corrections, linkedActCorrections: [:])
        XCTAssertEqual(normalized.instances.first { $0.judge == nil }?.court, ownCourt,
                       "собственная устаревшая составная строка исправляется по ее снимку")
        XCTAssertEqual(normalized.instances.first { $0.judge == baselineJudge }?.court, ownCourt)
        XCTAssertEqual(normalized.instances.first { $0.judge == baselineJudge }?.judge,
                       baselineJudge,
                       "отдельное ФИО из базовой версии сохраняется, даже когда дисплей уже обновлён")
    }

    func testPreparationCorrectsDiskCacheAndItsExistingBaselineQuietlyAndIdempotently()
        throws {
        let directory = try makeTemporaryDirectory("issue-413-prepare")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("tracked.store")
        let seed = try seedLegacyStore(at: storeURL)

        XCTAssertTrue(try prepareStore(at: storeURL))
        let afterFirst = try persistedFacts(at: storeURL, key: seed.key)
        XCTAssertFalse(try prepareStore(at: storeURL))
        let afterSecond = try persistedFacts(at: storeURL, key: seed.key)

        XCTAssertEqual(afterFirst.key, seed.key)
        XCTAssertEqual(afterFirst.logicalCaseID, seed.logicalCaseID)
        XCTAssertEqual(afterFirst.collections, ["Регрессия #413"])
        XCTAssertEqual(afterFirst.legacyKeyAliases, ["legacy-issue-413"])
        XCTAssertEqual(afterFirst.seenAt, seenAt)
        XCTAssertEqual(afterFirst.movementFetchedAt, fetchedAt)
        XCTAssertEqual(afterFirst.contextData, seed.contextData)
        XCTAssertEqual(afterFirst.movement?.instances.first { $0.sourceURL == ownURL }?.court,
                       ownCourt)
        XCTAssertNil(afterFirst.movement?.instances.first { $0.sourceURL == ownURL }?.judge)
        XCTAssertEqual(afterFirst.movement?.instances.first { $0.sourceURL == districtURL }?.court,
                       "Черёмушкинский районный суд")
        XCTAssertEqual(afterFirst.movement?.instances.first { $0.domain == "3kas.sudrf.ru" }?.judge,
                       "Синтетический судья кассации")
        XCTAssertEqual(afterFirst.movement?.acts.first?.id, "issue413-existing-act")
        XCTAssertEqual(afterFirst.movement?.acts.first?.courtShort, ownCourt)
        XCTAssertEqual(afterFirst.snapshot?.actsFingerprint,
                       afterFirst.movement.map(MovementDerivation.sourceActsFingerprint(from:)))

        let ownCardID = try cardIdentity(for: ownURL, cartotekaID: "g2")
        let districtID = try cardIdentity(for: districtURL, cartotekaID: "g1")
        XCTAssertEqual(afterFirst.snapshot?.sessions.first { $0.sourceCardID == ownCardID }?.court,
                       ownCourt)
        XCTAssertNil(afterFirst.snapshot?.sessions.first { $0.sourceCardID == ownCardID }?.judge)
        XCTAssertEqual(afterFirst.snapshot?.sessions.first { $0.sourceCardID == districtID }?.court,
                       "Черёмушкинский районный суд")
        XCTAssertEqual(afterFirst.snapshot?.instanceObservations?.first {
            $0.sourceCardID == ownCardID
        }?.court, ownCourt)
        XCTAssertNil(afterFirst.snapshot?.instanceObservations?.first {
            $0.sourceCardID == ownCardID
        }?.judge)
        XCTAssertEqual(afterFirst.snapshot?.actObservations?.first {
            $0.sourceCardID == ownCardID
        }?.court, ownCourt)

        let firstJournal = try XCTUnwrap(afterFirst.journal)
        XCTAssertEqual(firstJournal.events, seed.journal.events)
        let moscowBaseline = try XCTUnwrap(
            firstJournal.semanticBaselines?.courts["mosgorsud|mgs"])
        XCTAssertEqual(moscowBaseline.instances.first { $0.sourceCardID == ownCardID }?.court,
                       ownCourt)
        XCTAssertNil(moscowBaseline.instances.first { $0.sourceCardID == ownCardID }?.judge)
        XCTAssertEqual(moscowBaseline.sessions.first { $0.sourceCardID == ownCardID }?.court,
                       ownCourt)
        XCTAssertNil(moscowBaseline.sessions.first { $0.sourceCardID == ownCardID }?.judge)
        XCTAssertEqual(moscowBaseline.acts.first {
            $0.sourceActID == "issue413-existing-act"
        }?.court, ownCourt)
        XCTAssertEqual(moscowBaseline.cards,
                       seed.journal.semanticBaselines?.courts["mosgorsud|mgs"]?.cards,
                       "связь native locator с baseline сохраняется")
        XCTAssertEqual(firstJournal.semanticBaselines?.courts["mosgorsud|cheremushkinskij"],
                       seed.journal.semanticBaselines?.courts["mosgorsud|cheremushkinskij"])
        XCTAssertEqual(afterSecond, afterFirst, "повторная подготовка не должна создавать новый переход")
    }

    func testCorrectionOnlyRefreshWithoutPreparationPreservesReadStateAndJournal()
        async throws {
        let directory = try makeTemporaryDirectory("issue-413-correction-only")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("tracked.store")
        let seed = try seedLegacyStore(at: storeURL)
        let correctionOnly = try movement(ownCourt: ownCourt, ownJudge: nil,
                                          actID: "issue413-existing-act", partial: true)

        let after = try await refreshOnce(at: storeURL, key: seed.key,
                                          movement: correctionOnly)

        XCTAssertEqual(after.movement?.instances.first { $0.sourceURL == ownURL }?.court,
                       ownCourt)
        XCTAssertNil(after.movement?.instances.first { $0.sourceURL == ownURL }?.judge)
        XCTAssertEqual(after.seenAt, seenAt,
                       "техническая коррекция без новых фактов не сбрасывает прочитанность")
        XCTAssertEqual(after.journal?.events, seed.journal.events)
        XCTAssertEqual(after.journal?.events.filter { $0.kind == .judgeChanged }.count, 0)
        XCTAssertEqual(after.journal?.events.filter { $0.kind == .judicialActPublished }.count, 0)
    }

    func testUnconfirmedDisplayChangeWaitsForOwnCardConfirmationAcrossReopen() async throws {
        let directory = try makeTemporaryDirectory("issue-413-delayed-confirmation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("tracked.store")
        let seed = try seedKnownJudgeBaselineStore(
            at: storeURL, baselineCourt: composite,
            baselineJudge: "Синтетический судья А.А.")
        var unconfirmedB = try movement(ownCourt: ownCourt,
                                        ownJudge: "Синтетический судья Б.Б.",
                                        actID: "issue413-existing-act", partial: true)
        unconfirmedB.sourceRefreshCoverage = nil

        let displayOnly = try await refreshOnce(at: storeURL, key: seed.key,
                                                movement: unconfirmedB)
        XCTAssertEqual(displayOnly.movement?.instances.first { $0.sourceURL == ownURL }?.judge,
                       "Синтетический судья Б.Б.")
        XCTAssertEqual(displayOnly.journal?.events, seed.journal.events,
                       "неподтверждённый display update не потребляет semantic transition")
        let retainedBaseline = try XCTUnwrap(displayOnly.journal?.semanticBaselines?
            .courts["mosgorsud|mgs"]?.instances.first { $0.sourceCardID == seed.ownCardID })
        XCTAssertEqual(retainedBaseline.court, ownCourt)
        XCTAssertEqual(retainedBaseline.judge, "Синтетический судья А.А.",
                       "исторический judge A берётся из baseline, а не из display B")

        let seenAfterRead = Date(timeIntervalSince1970: 1_800_000_300)
        let confirmedBMovement = try movement(ownCourt: ownCourt,
                                             ownJudge: "Синтетический судья Б.Б.",
                                             actID: "issue413-existing-act", partial: true)
        let confirmedB = try await repeatAfterReopen(
            at: storeURL, key: seed.key, movement: confirmedBMovement,
            seenAt: seenAfterRead)
        let confirmedJournal = try XCTUnwrap(confirmedB.journal)
        XCTAssertEqual(confirmedJournal.events.filter { $0.kind == .judgeChanged }.count, 1,
                       "события: \(confirmedJournal.events.map { $0.kind.rawValue })")
        XCTAssertEqual(confirmedJournal.events.filter { $0.kind == .judicialActPublished }.count, 0)
        XCTAssertEqual(confirmedJournal.events.filter { $0.kind == .complaintRegistered }.map(\.id),
                       seed.journal.events.map(\.id))
        XCTAssertEqual(confirmedB.seenAt, seenAfterRead)
        let eventIDs = confirmedJournal.events.map(\.id)

        let repeated = try await repeatAfterReopen(
            at: storeURL, key: seed.key, movement: confirmedBMovement,
            seenAt: Date(timeIntervalSince1970: 1_800_000_400))
        XCTAssertEqual(repeated.journal?.events.map(\.id), eventIDs)
        XCTAssertEqual(repeated.journal?.events.filter { $0.kind == .judgeChanged }.count, 1)
    }

    func testPartialRefreshAfterReopenPublishesRealJudgeAndActOnce() async throws {
        let directory = try makeTemporaryDirectory("issue-413-refresh")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("tracked.store")
        let seed = try seedLegacyStore(at: storeURL)
        XCTAssertTrue(try prepareStore(at: storeURL))

        let fresh = try movement(ownCourt: ownCourt, ownJudge: "Синтетический судья Б.Б.",
                                 actID: "issue413-new-act", partial: true)
        let first = try await refreshOnce(at: storeURL, key: seed.key, movement: fresh)
        XCTAssertEqual(first.movement?.instances.first { $0.sourceURL == ownURL }?.court, ownCourt)
        XCTAssertEqual(first.movement?.instances.first { $0.sourceURL == ownURL }?.judge,
                       "Синтетический судья Б.Б.")
        XCTAssertNil(first.seenAt, "свежая подтверждённая смена судьи должна вернуть бейдж обновления")
        XCTAssertEqual(first.movementFetchedAt, fetchedAt, "частичная попытка не продлевает TTL")
        let firstJournal = try XCTUnwrap(first.journal)
        XCTAssertEqual(firstJournal.events.filter { $0.kind == .complaintRegistered }.map(\.id),
                       seed.journal.events.map(\.id))
        XCTAssertEqual(firstJournal.events.filter { $0.kind == .judgeChanged }.count, 1)
        XCTAssertEqual(firstJournal.events.filter { $0.kind == .judicialActPublished }.count, 1)
        let eventIDs = firstJournal.events.map(\.id)

        let afterUserRead = try await repeatAfterReopen(
            at: storeURL, key: seed.key, movement: fresh,
            seenAt: Date(timeIntervalSince1970: 1_800_000_200))
        XCTAssertEqual(afterUserRead.journal?.events.map(\.id), eventIDs)
        XCTAssertEqual(afterUserRead.seenAt, Date(timeIntervalSince1970: 1_800_000_200),
                       "повторный ответ без новых фактов не сбрасывает прочитанность")
        XCTAssertEqual(afterUserRead.movement?.instances.first { $0.domain == "3kas.sudrf.ru" }?.judge,
                       "Синтетический судья кассации")
        XCTAssertEqual(afterUserRead.movement?.instances.first { $0.sourceURL == districtURL }?.court,
                       "Черёмушкинский районный суд")
    }

    func testFailedPreparationRestoresAllThreeCacheBlobs() throws {
        let directory = try makeTemporaryDirectory("issue-413-rollback")
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("tracked.store")
        let seed = try seedLegacyStore(at: storeURL)
        try withStore(at: storeURL) { container, context in
            let record = try XCTUnwrap(context.fetch(FetchDescriptor<TrackedCaseRecord>()).first {
                $0.key == seed.key
            })
            let snapshotBefore = record.snapshotData
            let movementBefore = record.movementData
            let journalBefore = record.eventJournalData
            XCTAssertThrowsError(try TrackedStorePreparation.prepare(
                context: context, today: Date(timeIntervalSince1970: 1_800_000_000),
                save: { _ in throw Issue413InjectedSaveFailure.expected }))
            XCTAssertEqual(record.snapshotData, snapshotBefore)
            XCTAssertEqual(record.movementData, movementBefore)
            XCTAssertEqual(record.eventJournalData, journalBefore)
            _ = container
        }
        let after = try persistedFacts(at: storeURL, key: seed.key)
        XCTAssertEqual(after.snapshotData, seed.snapshotData)
        XCTAssertEqual(after.movementData, seed.movementData)
        XCTAssertEqual(after.journalData, seed.journalData)
    }

    private struct Seed: Equatable {
        let key: String
        let logicalCaseID: UUID
        let ownCardID: String
        let contextData: Data
        let snapshotData: Data?
        let movementData: Data?
        let journalData: Data?
        let journal: CaseEventJournal
    }

    private struct PersistedFacts: Equatable {
        let key: String
        let logicalCaseID: UUID?
        let collections: [String]
        let legacyKeyAliases: [String]
        let seenAt: Date?
        let movementFetchedAt: Date?
        let contextData: Data
        let snapshotData: Data?
        let movementData: Data?
        let journalData: Data?
        let snapshot: CaseSnapshot?
        let movement: CaseMovement?
        let journal: CaseEventJournal?

        init(_ record: TrackedCaseRecord) {
            key = record.key
            logicalCaseID = record.logicalCaseID
            collections = record.collectionNames
            legacyKeyAliases = record.legacyKeyAliases
            seenAt = record.seenAt
            movementFetchedAt = record.movementFetchedAt
            contextData = record.contextData
            snapshotData = record.snapshotData
            movementData = record.movementData
            journalData = record.eventJournalData
            snapshot = record.snapshot
            movement = record.movement
            journal = record.eventJournal
        }
    }

    private func seedLegacyStore(at storeURL: URL) throws -> Seed {
        let context = context()
        let oldMovement = try movement(ownCourt: composite, ownJudge: composite,
                                       actID: "issue413-existing-act")
        var oldSnapshot = MovementDerivation.snapshot(from: oldMovement, context: context)
        let ownCardID = try cardIdentity(for: ownURL, cartotekaID: "g2")
        for index in oldSnapshot.sessions.indices where oldSnapshot.sessions[index].sourceCardID == ownCardID {
            oldSnapshot.sessions[index].court = composite
            oldSnapshot.sessions[index].judge = composite
        }
        for index in oldSnapshot.instanceObservations?.indices ?? 0..<0
        where oldSnapshot.instanceObservations?[index].sourceCardID == ownCardID {
            oldSnapshot.instanceObservations?[index].court = composite
            oldSnapshot.instanceObservations?[index].judge = composite
        }
        for index in oldSnapshot.actObservations?.indices ?? 0..<0
        where oldSnapshot.actObservations?[index].sourceCardID == ownCardID {
            oldSnapshot.actObservations?[index].court = composite
        }
        oldSnapshot.actsFingerprint = MovementDerivation.sourceActsFingerprint(from: oldMovement)

        let contextData = try JSONEncoder().encode(context)
        let snapshotData = try JSONEncoder().encode(oldSnapshot)
        let movementData = try JSONEncoder().encode(oldMovement)
        let baseID = try cardIdentity(for: baseURL, cartotekaID: "g1")
        let districtID = try cardIdentity(for: districtURL, cartotekaID: "g1")
        let otherSnapshot = CaseSnapshot(
            uid: "", inForce: false, category: nil, partiesShort: "", leadCharges: nil,
            secondPartyLine: nil, stageRaw: "first", stageTag: "", statusText: "",
            statusChipRaw: "gray", lastEvent: "", nextEvent: "", nextChipRaw: "gray",
            steps: [], sessions: [], deadlines: [], actsFingerprint: nil,
            semanticProjectionVersion: CaseEventJournal.currentDerivationVersion,
            instanceObservations: [.init(sourceCardID: districtID, levelRaw: "first",
                                         court: "Черёмушкинский районный суд",
                                         caseNumber: "2-0001/2020", judge: "Синтетический мировой судья")],
            actObservations: [], complaintObservations: [])
        let moscowBaseline = CaseEventCourtBaseline(
            snapshot: oldSnapshot, cards: [baseID: baseID, ownCardID: ownCardID])
        let districtBaseline = CaseEventCourtBaseline(snapshot: otherSnapshot,
                                                       cards: [districtID: districtID])
        var baselines = CaseEventBaselines()
        baselines.courts["mosgorsud|mgs"] = moscowBaseline
        baselines.courts["mosgorsud|cheremushkinskij"] = districtBaseline
        baselines.global = CaseEventGlobalBaseline(inForce: false, deadlines: [])
        let sentinel = CaseEvent.make(
            kind: .complaintRegistered, occurrence: ["issue413-existing-history"],
            observedAt: Date(timeIntervalSince1970: 1_700_000_000), evidence: .init())
        var journal = CaseEventJournal(events: [sentinel])
        journal.semanticBaselines = baselines
        let journalData = try JSONEncoder().encode(journal)
        let logicalID = UUID()
        try withStore(at: storeURL) { _, modelContext in
            let record = TrackedCaseRecord(
                key: "mosgorsud|issue-413|2-0001/2020",
                collections: ["Регрессия #413"], caseNumber: context.caseNumber,
                courtTitle: context.courtTitle, displayDomain: context.displayDomain,
                contextData: contextData, snapshotData: snapshotData)
            record.logicalCaseID = logicalID
            record.legacyKeyAliases = ["legacy-issue-413"]
            record.seenAt = seenAt
            record.movementFetchedAt = fetchedAt
            record.movementData = movementData
            record.eventJournalData = journalData
            modelContext.insert(record)
            try modelContext.save()
        }
        return Seed(key: "mosgorsud|issue-413|2-0001/2020",
                    logicalCaseID: logicalID, ownCardID: ownCardID,
                    contextData: contextData,
                    snapshotData: snapshotData, movementData: movementData,
                    journalData: journalData, journal: journal)
    }

    private func seedKnownJudgeBaselineStore(at storeURL: URL,
                                             baselineCourt: String,
                                             baselineJudge: String) throws -> Seed {
        let seed = try seedLegacyStore(at: storeURL)
        let initialMovement = try movement(
            ownCourt: baselineCourt, ownJudge: baselineJudge,
            actID: "issue413-existing-act")
        var initialSnapshot = MovementDerivation.snapshot(
            from: initialMovement, context: context())
        let ownCardID = try cardIdentity(for: ownURL, cartotekaID: "g2")
        for index in initialSnapshot.sessions.indices
        where initialSnapshot.sessions[index].sourceCardID == ownCardID {
            initialSnapshot.sessions[index].court = baselineCourt
            initialSnapshot.sessions[index].judge = baselineJudge
        }
        for index in initialSnapshot.instanceObservations?.indices ?? 0..<0
        where initialSnapshot.instanceObservations?[index].sourceCardID == ownCardID {
            initialSnapshot.instanceObservations?[index].court = baselineCourt
            initialSnapshot.instanceObservations?[index].judge = baselineJudge
        }
        for index in initialSnapshot.actObservations?.indices ?? 0..<0
        where initialSnapshot.actObservations?[index].sourceCardID == ownCardID {
            initialSnapshot.actObservations?[index].court = baselineCourt
        }
        initialSnapshot.actsFingerprint = MovementDerivation.sourceActsFingerprint(
            from: initialMovement)

        let baseCardID = try cardIdentity(for: baseURL, cartotekaID: "g1")
        var baselines = seed.journal.semanticBaselines ?? CaseEventBaselines()
        baselines.courts["mosgorsud|mgs"] = CaseEventCourtBaseline(
            snapshot: initialSnapshot, cards: [baseCardID: baseCardID,
                                               ownCardID: ownCardID])
        var journal = seed.journal
        journal.semanticBaselines = baselines
        let encoder = JSONEncoder()
        let snapshotData = try encoder.encode(initialSnapshot)
        let movementData = try encoder.encode(initialMovement)
        let journalData = try encoder.encode(journal)
        try withStore(at: storeURL) { _, modelContext in
            let record = try XCTUnwrap(modelContext.fetch(FetchDescriptor<TrackedCaseRecord>()).first {
                $0.key == seed.key
            })
            record.snapshotData = snapshotData
            record.movementData = movementData
            record.eventJournalData = journalData
            try modelContext.save()
        }
        return Seed(key: seed.key, logicalCaseID: seed.logicalCaseID,
                    ownCardID: ownCardID,
                    contextData: seed.contextData, snapshotData: snapshotData,
                    movementData: movementData, journalData: journalData,
                    journal: journal)
    }

    private func prepareStore(at storeURL: URL) throws -> Bool {
        try withStore(at: storeURL) { _, context in
            try TrackedStorePreparation.prepare(
                context: context, today: Date(timeIntervalSince1970: 1_800_000_000))
        }
    }

    private func persistedFacts(at storeURL: URL, key: String) throws -> PersistedFacts {
        try withStore(at: storeURL) { _, context in
            let record = try XCTUnwrap(context.fetch(FetchDescriptor<TrackedCaseRecord>()).first {
                $0.key == key
            })
            return PersistedFacts(record)
        }
    }

    private func refreshOnce(at storeURL: URL, key: String,
                             movement: CaseMovement) async throws -> PersistedFacts {
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true,
                                     projectionSynchronizer: { _, _ in })
        let center = makeRefreshCenter(store: store, movement: movement)
        let execution = await center.refresh(key: key)?.value
        guard case .partial? = execution?.outcome else {
            XCTFail("ожидался частичный исход синтетического источника")
            return PersistedFacts(try XCTUnwrap(store.record(forKey: key)))
        }
        let record = try XCTUnwrap(store.record(forKey: key))
        return PersistedFacts(record)
    }

    private func repeatAfterReopen(at storeURL: URL, key: String,
                                   movement: CaseMovement, seenAt: Date) async throws -> PersistedFacts {
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true,
                                     projectionSynchronizer: { _, _ in })
        let record = try XCTUnwrap(store.record(forKey: key))
        record.seenAt = seenAt
        try store.save()
        let center = makeRefreshCenter(store: store, movement: movement)
        let execution = await center.refresh(key: key)?.value
        guard case .partial? = execution?.outcome else {
            XCTFail("ожидался повторный частичный исход синтетического источника")
            return PersistedFacts(try XCTUnwrap(store.record(forKey: key)))
        }
        return PersistedFacts(try XCTUnwrap(store.record(forKey: key)))
    }

    private func makeRefreshCenter(store: TrackedStore,
                                   movement: CaseMovement) -> RefreshCenter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let client = SudrfClient(
            session: session, minInterval: 0, userAgent: "Issue413SavedCacheTests",
            variantStore: WorkingVariantStore(cacheURL: nil),
            captchaStore: CaptchaTokenStore())
        let fssp = FSSPClient(session: session, minInterval: 0, maxAttempts: 1)
        XCTAssertTrue(movement.instances.allSatisfy { $0.captchaFormURL == nil })
        return RefreshCenter(
            store: store, client: client,
            autoSolve: { _, _, _, _ in
                XCTFail("синтетический fixture не должен запускать CAPTCHA solver")
                return AutoCaptchaSolver.SolveResult(token: nil, png: nil)
            },
            serviceBuilder: { _ in Issue413MovementSequence(movement) },
            treasuryDiscover: { _, _, _ in throw CancellationError() },
            fsspClient: fssp, vsrfProvider: Issue413UnusedVSRFProvider(),
            fsspAutoModelEnabled: false,
            fsspDiscover: { _ in .error("unused in isolated test") },
            initialTimerDelay: .seconds(600), timerInterval: .seconds(600))
    }

    private func context() -> MovementContext {
        var value = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: "mos-gorsud.ru", displayDomain: "mos-gorsud.ru",
            courtTitle: ownCourt, courtLevelRaw: CourtLevel.subject.rawValue,
            cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.subject.rawValue,
            caseNumber: "2-0001/2020", caseID: "issue413-base",
            caseUID: "issue413-base-guid")
        value.baseInstanceLevelRaw = CaseInstance.Level.first.rawValue
        value.cardURLString = baseURL.absoluteString
        return value
    }

    private func movement(ownCourt: String, ownJudge: String?, actID: String? = nil,
                          partial: Bool = false) throws -> CaseMovement {
        var own = CaseInstance(
            level: .appeal, court: ownCourt, caseNumber: "33-0001/2020",
            judge: ownJudge, domain: "mos-gorsud.ru", foundByUID: false,
            result: "Оставлено без изменения",
            sessions: [CaseSession(date: "01.01.2099", time: "10:00",
                                   event: "Судебное заседание")],
            actID: actID, actIDs: actID.map { [$0] }, sourceURL: ownURL)
        if actID == nil { own.actIDs = nil }
        let instances = [
            CaseInstance(
                level: .first, court: self.ownCourt, caseNumber: "2-0001/2020",
                judge: "Синтетический судья первой инстанции", domain: "mos-gorsud.ru",
                foundByUID: false, result: "Решение", sessions: [], sourceURL: baseURL),
            own,
            CaseInstance(
                level: .first, court: "Черёмушкинский районный суд",
                caseNumber: "2-0001/2020", judge: "Синтетический мировой судья",
                domain: "mos-gorsud.ru", foundByUID: false, result: nil,
                sessions: [CaseSession(date: "02.02.2099", time: "11:00",
                                       event: "Судебное заседание")], sourceURL: districtURL),
            CaseInstance(
                level: .cassation,
                court: "Третий кассационный суд общей юрисдикции",
                caseNumber: "33-0001/2020", judge: "Синтетический судья кассации",
                domain: "3kas.sudrf.ru", foundByUID: false, result: nil,
                sessions: [], sourceURL: URL(string:
                    "https://3kas.sudrf.ru/modules.php?name=sud_delo&name_op=case"
                    + "&case_id=issue413-cassation&delo_id=2800001&new=2800001"))
        ]
        let acts = actID.map {
            [CaseAct(id: $0, title: "Апелляционное определение", date: "01.02.2020",
                     courtShort: ownCourt, instanceLevel: .appeal)]
        } ?? []
        let identities = [
            try nativeCardIdentity(for: baseURL, cartotekaID: "g1"),
            try nativeCardIdentity(for: ownURL, cartotekaID: "g2")
        ]
        return CaseMovement(
            uid: "", caseNumber: "2-0001/2020", inForce: false,
            instances: instances, complaints: [:], acts: acts,
            incompleteHigherCourtDomains: partial ? ["unavailable.example.sudrf.ru"] : nil,
            sourceRefreshCoverage: partial
                ? [MovementCourtCoverage(sourceFamily: "mosgorsud", courtKey: "mgs",
                                         kind: .usableSnapshot,
                                         loadedCardIdentities: identities)] : nil)
    }

    private func cardIdentity(for url: URL, cartotekaID: String) throws -> String {
        try nativeCardIdentity(for: url, cartotekaID: cartotekaID).id
    }

    private func nativeCardIdentity(for url: URL,
                                    cartotekaID: String) throws -> SourceNativeCardIdentity {
        let carts = CourtLevel.allCases.flatMap { CartotekaRegistry.sets(for: $0) }
        let identities = Set(carts.compactMap { cart -> SourceNativeCardIdentity? in
            guard cart.id == cartotekaID else { return nil }
            return SourceNativeCardLocator.mosgorsud(url: url, cartoteka: cart)?.identity
        })
        XCTAssertEqual(identities.count, 1, "тестовый URL должен иметь ровно один native locator")
        return try XCTUnwrap(identities.first)
    }

    private func makeTemporaryDirectory(_ prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func withStore<T>(at storeURL: URL,
                              _ body: (ModelContainer, ModelContext) throws -> T) throws -> T {
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        return try body(container, container.mainContext)
    }
}

private enum Issue413InjectedSaveFailure: Error {
    case expected
}
