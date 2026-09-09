import XCTest
import SudrfKit
import SwiftData
@testable import SudrfApp

@MainActor
final class TrackedStoreIdentityTests: XCTestCase {
    private let oldUID = "11RS0001-01-2025-011255-03"
    private let newUID = "11RS0001-01-2026-011256-04"
    private let calendarTestToday = DateUtil.parse("01.09.2026")!

    private enum ForcedPreparationSaveError: Error { case forced }

    private func context(number: String, cardID: String, caseUID: String = "link-1",
                         judicialUID: String? = nil, domain: String = "court--komi.sudrf.ru",
                         courtCode: String = "11RS0001", cartoteka: String = "g1",
                         courtLevel: CourtLevel = .district,
                         baseInstanceLevel: CaseInstance.Level? = nil)
        -> MovementContext {
        var value = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: domain, displayDomain: SudrfHost.alternate(domain) ?? domain,
            courtTitle: "Тестовый суд", courtLevelRaw: courtLevel.rawValue,
            courtCode: courtCode, cartotekaId: cartoteka,
            cartotekaLevelRaw: courtLevel.rawValue,
            caseNumber: number, caseID: cardID, caseUID: caseUID)
        value.judicialUID = judicialUID
        value.baseInstanceLevelRaw = baseInstanceLevel?.rawValue
        return value
    }

    private func movement(for context: MovementContext, actID: String = "act-1",
                          sourceURL: URL? = nil,
                          previousRegistration: PreviousRegistrationReference? = nil)
        -> CaseMovement {
        let instance = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: nil, domain: context.searchDomain, foundByUID: false,
            result: "Решение", sessions: [], actID: actID,
            sourceURL: sourceURL, previousRegistration: previousRegistration)
        let act = CaseAct(id: actID, title: "Решение", date: "01.08.2026",
                          courtShort: context.courtTitle, instanceLevel: .first)
        return CaseMovement(uid: context.judicialUID ?? "", caseNumber: context.caseNumber,
                            inForce: false, instances: [instance], complaints: [:], acts: [act],
                            actBodies: [actID: "Текст акта"])
    }

    private func sourceURL(for context: MovementContext) -> URL {
        let cartoteka = CartotekaRegistry.find(
            level: context.cartotekaLevel, id: context.cartotekaId)!
        var components = URLComponents()
        components.scheme = "https"
        components.host = context.searchDomain
        components.path = "/modules.php"
        components.queryItems = [
            URLQueryItem(name: "name", value: "sud_delo"),
            URLQueryItem(name: "name_op", value: "case"),
            URLQueryItem(name: "vnkod", value: context.courtCode),
            URLQueryItem(name: "srv_num", value: "2"),
            URLQueryItem(name: "delo_id", value: cartoteka.deloID),
            URLQueryItem(name: "new", value: cartoteka.new),
            URLQueryItem(name: "case_id", value: context.caseID),
            URLQueryItem(name: "case_uid", value: context.caseUID)
        ]
        return components.url!
    }

    private func reviewInstance(for context: MovementContext,
                                foundByUID: Bool = true,
                                sourceURL: URL? = nil) -> CaseInstance {
        CaseInstance(
            level: context.baseInstanceLevel, court: context.courtTitle,
            caseNumber: context.caseNumber, judge: nil,
            domain: context.searchDomain, foundByUID: foundByUID,
            result: "Поступление жалобы в суд", sessions: [],
            sourceURL: sourceURL ?? self.sourceURL(for: context))
    }

    private func movementWithAutomaticCivilDeadline(for context: MovementContext) -> CaseMovement {
        let first = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: nil, domain: context.searchDomain, foundByUID: false,
            result: "Решение принято в окончательной форме",
            sessions: [CaseSession(
                date: "03.09.2026", event: "Судебное заседание",
                result: "Иск удовлетворён; решение принято в окончательной форме")])
        return CaseMovement(uid: context.judicialUID ?? "", caseNumber: context.caseNumber,
                            inForce: false, instances: [first], complaints: [:], acts: [],
                            category: "Споры из договоров")
    }

    private func automaticAppealIndex(in snapshot: CaseSnapshot) throws -> Int {
        try XCTUnwrap(snapshot.deadlines.firstIndex(where: { $0.kind == "appeal" }),
                      "Нужна исходная автоматическая апелляция для проверки пересчёта")
    }

    func testStoredKoapReviewLinksMergeBothDuplicatePairsOfflineAndRemainIdempotent() throws {
        let pairs = [
            ("5-469/2026", "35768698", "16-5132/2026", "25004446"),
            ("5-470/2026", "35768700", "16-4990/2026", "24914918"),
        ]
        for latestKind in [SourceOutcomeKind.partial, .transportFailure, nil] {
            let store = TrackedStore(inMemory: true)
            var expectedTTLByKey = [String: Date]()
            var expectedAttemptByKey = [String: SourceAttempt]()

            for (index, pair) in pairs.enumerated() {
                let base = context(
                    number: pair.0, cardID: pair.1, caseUID: "base-\(index)",
                    cartoteka: "adm", baseInstanceLevel: .first)
                let review = context(
                    number: pair.2, cardID: pair.3, caseUID: "review-\(index)",
                    domain: "3kas.sudrf.ru", courtCode: "", cartoteka: "adm3",
                    courtLevel: .cassation, baseInstanceLevel: .cassation)
                let baseRecord = try store.reconcileAndUpsert(
                    context: base, snapshot: nil, movement: movement(for: base),
                    collections: ["Основные"])
                _ = try store.reconcileAndUpsert(
                    context: review, snapshot: nil,
                    movement: CaseMovement(
                        uid: "", caseNumber: review.caseNumber, inForce: false,
                        instances: [reviewInstance(for: review)], complaints: [:], acts: []),
                    collections: ["Надзор"])

                var cached = try XCTUnwrap(baseRecord.movement)
                cached.instances.append(reviewInstance(for: review))
                baseRecord.movement = cached
                let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
                baseRecord.movementFetchedAt = fetchedAt
                let latestAttempt = latestKind.map { kind in
                    SourceAttempt(
                        kind: kind,
                        provenance: SourceProvenance(
                            operation: .movement, sourceFamily: "sudrf",
                            host: base.searchDomain,
                            observedAt: fetchedAt.addingTimeInterval(86_400),
                            affectedSources: kind == .partial ? ["3kas.sudrf.ru"] : []))
                }
                baseRecord.sourceRefreshAttempt = latestAttempt
                expectedTTLByKey[base.key] = fetchedAt
                if let latestAttempt { expectedAttemptByKey[base.key] = latestAttempt }
            }
            try store.save()
            XCTAssertEqual(store.all().count, 4)

            let summary = try store.reconcileStoredIdentity()

            XCTAssertEqual(summary.merged, 2)
            XCTAssertEqual(store.all().count, 2)
            for pair in pairs {
                let baseKey = "court.komi.sudrf.ru/\(pair.0)"
                let record = try XCTUnwrap(store.record(forKey: baseKey))
                XCTAssertEqual(record.context?.caseNumber, pair.0)
                XCTAssertEqual(record.movementFetchedAt, expectedTTLByKey[baseKey])
                XCTAssertEqual(record.sourceRefreshAttempt, expectedAttemptByKey[baseKey])
                XCTAssertEqual(Set(record.collectionNames), ["Основные", "Надзор"])
                let state = TrackedCaseIdentity.state(for: record)
                XCTAssertTrue(state.cards.contains { $0.identity.sourceNativeID == pair.3 })
                let relation = try XCTUnwrap(state.officialRelations.first {
                    $0.kind == .sourceNative && $0.relatedCard?.sourceNativeID == pair.3
                })
                XCTAssertEqual(relation.provenance.observedAt, expectedTTLByKey[baseKey])
            }

            store.failNextSaveForTesting = true
            XCTAssertEqual(try store.reconcileStoredIdentity(), IdentityReconciliationSummary())
            XCTAssertTrue(store.failNextSaveForTesting)
        }
    }

    func testReviewRelationRejectsMaterialUnverifiedFailedAndMalformedCards() throws {
        let base = context(number: "5-100/2026", cardID: "base", cartoteka: "adm")
        let review = context(
            number: "16-100/2026", cardID: "review", domain: "3kas.sudrf.ru",
            courtCode: "", cartoteka: "adm3", courtLevel: .cassation,
            baseInstanceLevel: .cassation)
        let linkedMaterial = context(
            number: "15-108/2026", cardID: "material", caseUID: "material-link",
            cartoteka: "m", baseInstanceLevel: .material)
        let malformed = URL(string:
            "https://3kas.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=review&delo_id=2550001&new=0&new=1")!
        var cached = movement(for: base)
        cached.instances.append(reviewInstance(for: linkedMaterial))
        cached.instances.append(reviewInstance(for: review, foundByUID: false))
        cached.instances.append(reviewInstance(for: review, sourceURL: malformed))
        var failed = reviewInstance(for: review)
        failed.transientError = true
        cached.instances.append(failed)
        var crossHost = reviewInstance(for: review)
        crossHost.domain = "2kas.sudrf.ru"
        cached.instances.append(crossHost)

        let observation = try XCTUnwrap(TrackedCaseIdentity.observation(
            context: base, movement: cached))
        XCTAssertFalse(observation.officialRelations.contains { $0.kind == .sourceNative })

        let affectedAttempt = SourceAttempt(
            kind: .partial,
            provenance: SourceProvenance(
                operation: .movement, sourceFamily: "sudrf", host: base.searchDomain,
                affectedSources: ["3kas.sudrf.ru"]))
        XCTAssertNil(TrackedCaseIdentity.partialRefreshObservation(
            context: base,
            movement: CaseMovement(
                uid: oldUID, caseNumber: base.caseNumber, inForce: false,
                instances: [reviewInstance(for: review)], complaints: [:], acts: []),
            attempt: affectedAttempt))

        var material = base
        material.cartotekaId = "m"
        material.baseInstanceLevelRaw = CaseInstance.Level.material.rawValue
        XCTAssertFalse(try XCTUnwrap(TrackedCaseIdentity.observation(
            context: material,
            movement: CaseMovement(
                uid: "", caseNumber: material.caseNumber, inForce: false,
                instances: [reviewInstance(for: review)], complaints: [:], acts: [])))
            .officialRelations.contains { $0.kind == .sourceNative })
    }

    func testRetrackingMergedReviewCardKeepsFirstInstancePresentation() throws {
        let store = TrackedStore(inMemory: true)
        let base = context(number: "5-469/2026", cardID: "35768698",
                           cartoteka: "adm", baseInstanceLevel: .first)
        let review = context(
            number: "16-5132/2026", cardID: "25004446",
            domain: "3kas.sudrf.ru", courtCode: "", cartoteka: "adm3",
            courtLevel: .cassation, baseInstanceLevel: .cassation)
        var baseMovement = movement(for: base)
        baseMovement.instances.append(reviewInstance(for: review))
        _ = try store.reconcileAndUpsert(
            context: review, snapshot: nil,
            movement: CaseMovement(
                uid: "", caseNumber: review.caseNumber, inForce: false,
                instances: [reviewInstance(for: review)], complaints: [:], acts: []),
            collections: ["Надзор"])
        let survivor = try store.reconcileAndUpsert(
            context: base, snapshot: nil, movement: baseMovement,
            collections: ["Основные"])
        let key = survivor.key

        let retracked = try store.reconcileAndUpsert(
            context: review, snapshot: nil,
            movement: CaseMovement(
                uid: "", caseNumber: review.caseNumber, inForce: false,
                instances: [reviewInstance(for: review)], complaints: [:], acts: []),
            collections: ["Повторный импорт"])

        XCTAssertTrue(retracked === survivor)
        XCTAssertEqual(retracked.key, key)
        XCTAssertEqual(retracked.context?.caseNumber, base.caseNumber)
        XCTAssertEqual(retracked.context?.baseInstanceLevel, .first)
        XCTAssertEqual(Set(retracked.movement?.instances.map(\.caseNumber) ?? []),
                       [base.caseNumber, review.caseNumber])
        XCTAssertEqual(Set(retracked.collectionNames),
                       ["Основные", "Надзор", "Повторный импорт"])
    }

    func testSameSourceCardRenumberingKeepsPersistentKeyActsCollectionsAndDeepLinks() async throws {
        let store = TrackedStore(inMemory: true)
        let original = context(number: "8Г-123/2026", cardID: "native-card", judicialUID: oldUID)
        let first = try store.reconcileAndUpsert(
            context: original, snapshot: nil, movement: movement(for: original),
            collections: ["Подборка"])
        let persistentKey = first.key
        let logicalCaseID = try XCTUnwrap(first.logicalCaseID)
        let oldActID = try XCTUnwrap(store.courtActID(caseKey: persistentKey, sourceActID: "act-1"))

        var renumbered = original
        renumbered.caseNumber = "88-123/2026"
        let refreshed = try store.reconcileAndUpsert(
            context: renumbered, snapshot: nil, movement: movement(for: renumbered),
            collections: ["Подборка"])

        XCTAssertTrue(refreshed === first)
        XCTAssertEqual(refreshed.key, persistentKey)
        XCTAssertEqual(refreshed.logicalCaseID, logicalCaseID)
        XCTAssertEqual(refreshed.caseNumber, renumbered.caseNumber)
        XCTAssertEqual(refreshed.collectionNames, ["Подборка"])
        XCTAssertTrue(refreshed.legacyKeyAliases.contains(renumbered.key))
        XCTAssertTrue(store.record(forLocator: original.key) === refreshed)
        XCTAssertTrue(store.record(forLocator: renumbered.key) === refreshed)
        XCTAssertEqual(store.courtActID(caseKey: persistentKey, sourceActID: "act-1"), oldActID)
        XCTAssertEqual(store.route(for: .caseRecord(key: original.key)),
                       .caseRecord(key: persistentKey, staleAct: false))
        XCTAssertEqual(store.route(for: .courtAct(caseKey: original.key, sourceActID: "act-1")),
                       .courtAct(caseKey: persistentKey, sourceActID: "act-1"))

        let state = TrackedCaseIdentity.state(for: refreshed)
        XCTAssertEqual(state.cards.count, 1)
        XCTAssertEqual(Set(state.numberHistory.map(\.rawValue)),
                       Set([original.caseNumber, renumbered.caseNumber]))
        let catalog = CaseCatalog(container: store.container)
        let catalogCase = try await catalog.caseSnapshot(id: persistentKey)
        XCTAssertEqual(catalogCase?.id, persistentKey,
                       "Spotlight continues to index the immutable persistent locator")
    }

    func testMatchingValidUIDAcrossDifferentCardsCreatesOneLogicalDossierAndUsesUIDHistory() throws {
        let store = TrackedStore(inMemory: true)
        let first = context(number: "2-100/2026", cardID: "first-card", judicialUID: oldUID)
        let appeal = context(number: "33-200/2026", cardID: "appeal-card", judicialUID: oldUID,
                             domain: "vs--komi.sudrf.ru", courtCode: "11VS0001", cartoteka: "g2")

        let trackedFirst = try store.reconcileAndUpsert(context: first, snapshot: nil, collections: ["A"])
        let trackedAppeal = try store.reconcileAndUpsert(context: appeal, snapshot: nil, collections: ["B"])

        XCTAssertTrue(trackedFirst === trackedAppeal)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.records(forJudicialUID: "11 rs 0001-01-2025-011255-03").count, 1)
        XCTAssertEqual(TrackedCaseIdentity.state(for: trackedFirst).cards.count, 2)
        XCTAssertEqual(trackedFirst.collectionNames, ["A", "B"])
        XCTAssertTrue(store.record(forLocator: appeal.key) === trackedFirst)
    }

    func testOfficialPredecessorCanAddSequentialUIDWithoutChangingDossier() throws {
        let store = TrackedStore(inMemory: true)
        let previous = context(number: "2-100/2025", cardID: "previous-card", judicialUID: oldUID)
        let existing = try store.reconcileAndUpsert(context: previous, snapshot: nil, collections: [])
        let previousObservation = try XCTUnwrap(TrackedCaseIdentity.observation(context: previous))

        let replacement = context(number: "2-101/2026", cardID: "replacement-card", judicialUID: newUID)
        let base = try XCTUnwrap(TrackedCaseIdentity.observation(context: replacement))
        let relation = OfficialCardRelation(
            kind: .predecessor, relatedCard: previousObservation.cardIdentity,
            provenance: base.provenance)
        let replacementObservation = SourceCardObservation(
            cardIdentity: base.cardIdentity, caseUID: base.caseUID,
            caseNumber: base.caseNumber, judicialUID: base.judicialUID,
            officialRelations: [relation], outcome: .usableSnapshot,
            provenance: base.provenance)

        let linked = try store.reconcileAndUpsert(
            context: replacement, snapshot: nil, collections: [],
            identityObservation: replacementObservation)

        XCTAssertTrue(linked === existing)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(Set(TrackedCaseIdentity.state(for: linked).judicialUIDs),
                       Set([TrackedStore.normalizedUID(oldUID), TrackedStore.normalizedUID(newUID)]))
    }

    func testMovementPredecessorLinksSequentialUIDsRegardlessOfTrackingOrder() throws {
        let previous = context(number: "2-100/2025", cardID: "previous-card",
                               caseUID: "previous-link", judicialUID: oldUID)
        let replacement = context(number: "2-101/2026", cardID: "replacement-card",
                                  caseUID: "replacement-link", judicialUID: newUID)
        let previousURL = sourceURL(for: previous)
        let replacementURL = sourceURL(for: replacement)
        let replacementMovement = movement(
            for: replacement, sourceURL: replacementURL,
            previousRegistration: PreviousRegistrationReference(
                caseNumber: previous.caseNumber, url: previousURL))
        var validatedReplacementMovement = replacementMovement
        validatedReplacementMovement.instances.append(CaseInstance(
            level: .first, court: previous.courtTitle, caseNumber: previous.caseNumber,
            judge: nil, domain: previous.searchDomain, foundByUID: true,
            result: "Решение", sessions: [], sourceURL: previousURL))
        let attempt = SourceAttempt(
            kind: .usableSnapshot,
            provenance: SourceProvenance(
                operation: .movement, sourceFamily: "sudrf",
                host: replacement.searchDomain,
                observedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        let replacementObservation = try XCTUnwrap(TrackedCaseIdentity.observation(
            context: replacement, movement: validatedReplacementMovement, attempt: attempt))
        let previousObservation = try XCTUnwrap(TrackedCaseIdentity.observation(context: previous))
        let relation = try XCTUnwrap(replacementObservation.officialRelations.first)

        XCTAssertEqual(relation.kind, .predecessor)
        XCTAssertEqual(relation.relatedCard, previousObservation.cardIdentity)
        XCTAssertEqual(relation.provenance, attempt.provenance)

        for previousFirst in [true, false] {
            let store = TrackedStore(inMemory: true)
            if previousFirst {
                _ = try store.reconcileAndUpsert(
                    context: previous, snapshot: nil,
                    movement: movement(for: previous, sourceURL: previousURL), collections: [])
                _ = try store.reconcileAndUpsert(
                    context: replacement, snapshot: nil, movement: replacementMovement,
                    collections: [], identityObservation: replacementObservation)
            } else {
                _ = try store.reconcileAndUpsert(
                    context: replacement, snapshot: nil, movement: replacementMovement,
                    collections: [], identityObservation: replacementObservation)
                _ = try store.reconcileAndUpsert(
                    context: previous, snapshot: nil,
                    movement: movement(for: previous, sourceURL: previousURL), collections: [])
            }

            let oldRecord = try XCTUnwrap(store.record(forLocator: previous.key))
            let newRecord = try XCTUnwrap(store.record(forLocator: replacement.key))
            XCTAssertTrue(oldRecord === newRecord, "tracking order: \(previousFirst)")
            XCTAssertEqual(store.all().count, 1, "tracking order: \(previousFirst)")
            XCTAssertEqual(TrackedCaseIdentity.state(for: oldRecord).cards.count, 2)
            XCTAssertEqual(Set(TrackedCaseIdentity.state(for: oldRecord).judicialUIDs),
                           Set([TrackedStore.normalizedUID(oldUID),
                                TrackedStore.normalizedUID(newUID)]))
        }
    }

    func testMovementPredecessorMustBelongToRefreshedSourceCard() throws {
        let previous = context(number: "2-100/2025", cardID: "previous-card",
                               caseUID: "previous-link", judicialUID: oldUID)
        let replacement = context(number: "2-101/2026", cardID: "replacement-card",
                                  caseUID: "replacement-link", judicialUID: newUID)
        let unrelated = context(number: "2-102/2026", cardID: "unrelated-card",
                                caseUID: "unrelated-link", judicialUID: newUID)
        var currentMovement = movement(for: replacement, sourceURL: sourceURL(for: replacement))
        currentMovement.instances.append(CaseInstance(
            level: .first, court: unrelated.courtTitle, caseNumber: unrelated.caseNumber,
            judge: nil, domain: unrelated.searchDomain, foundByUID: true,
            result: nil, sessions: [], sourceURL: sourceURL(for: unrelated),
            previousRegistration: PreviousRegistrationReference(
                caseNumber: previous.caseNumber, url: sourceURL(for: previous))))

        let observation = try XCTUnwrap(TrackedCaseIdentity.observation(
            context: replacement, movement: currentMovement))

        XCTAssertTrue(observation.officialRelations.isEmpty)
    }

    func testUnloadedOrMismatchedPredecessorNeverCreatesIdentityRelation() throws {
        let previous = context(number: "2-100/2025", cardID: "previous-card",
                               caseUID: "previous-link", judicialUID: oldUID)
        let replacement = context(number: "2-101/2026", cardID: "replacement-card",
                                  caseUID: "replacement-link", judicialUID: newUID)
        let reference = PreviousRegistrationReference(
            caseNumber: previous.caseNumber, url: sourceURL(for: previous))
        let unvalidated = movement(
            for: replacement, sourceURL: sourceURL(for: replacement),
            previousRegistration: reference)
        XCTAssertTrue(try XCTUnwrap(TrackedCaseIdentity.observation(
            context: replacement, movement: unvalidated)).officialRelations.isEmpty)

        var mismatched = unvalidated
        mismatched.instances.append(CaseInstance(
            level: .first, court: previous.courtTitle, caseNumber: "2-999/2025",
            judge: nil, domain: previous.searchDomain, foundByUID: true,
            result: nil, sessions: [], sourceURL: sourceURL(for: previous)))
        XCTAssertTrue(try XCTUnwrap(TrackedCaseIdentity.observation(
            context: replacement, movement: mismatched)).officialRelations.isEmpty)
    }

    func testStartupReconciliationUsesValidatedPredecessorFromStoredMovement() throws {
        let store = TrackedStore(inMemory: true)
        let previous = context(number: "2-100/2025", cardID: "previous-card",
                               caseUID: "previous-link", judicialUID: oldUID)
        let replacement = context(number: "2-101/2026", cardID: "replacement-card",
                                  caseUID: "replacement-link", judicialUID: newUID)
        let previousURL = sourceURL(for: previous)
        let replacementURL = sourceURL(for: replacement)
        _ = try store.reconcileAndUpsert(
            context: previous, snapshot: nil,
            movement: movement(for: previous, sourceURL: previousURL), collections: [])
        let replacementRecord = try store.reconcileAndUpsert(
            context: replacement, snapshot: nil,
            movement: movement(for: replacement, sourceURL: replacementURL), collections: [])
        XCTAssertEqual(store.all().count, 2)

        var linkedMovement = movement(
            for: replacement, sourceURL: replacementURL,
            previousRegistration: PreviousRegistrationReference(
                caseNumber: previous.caseNumber, url: previousURL))
        linkedMovement.instances.append(CaseInstance(
            level: .first, court: previous.courtTitle, caseNumber: previous.caseNumber,
            judge: nil, domain: previous.searchDomain, foundByUID: true,
            result: "Решение", sessions: [], sourceURL: previousURL))
        replacementRecord.movement = linkedMovement

        let summary = try store.reconcileStoredIdentity()

        XCTAssertEqual(summary.merged, 1)
        XCTAssertEqual(store.all().count, 1)
    }

    func testPartialUIDAndCaseUIDNeverLinkDistinctCards() throws {
        let store = TrackedStore(inMemory: true)
        let first = context(number: "2-100/2026", cardID: "first-card", caseUID: "same-link",
                            judicialUID: "11RS0001-01")
        let second = context(number: "2-101/2026", cardID: "second-card", caseUID: "same-link",
                             judicialUID: "11RS0001-01")

        _ = try store.reconcileAndUpsert(context: first, snapshot: nil, collections: [])
        _ = try store.reconcileAndUpsert(context: second, snapshot: nil, collections: [])

        XCTAssertEqual(store.all().count, 2)
        XCTAssertTrue(store.records(forJudicialUID: "11RS0001-01").isEmpty)
    }

    func testRepeatedReconciliationIsIdempotentAndDoesNotAdvanceRefreshTime() throws {
        let store = TrackedStore(inMemory: true)
        let value = context(number: "2-100/2026", cardID: "same-card", judicialUID: oldUID)
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let attempt = SourceAttempt(
            kind: .usableSnapshot,
            provenance: SourceProvenance(operation: .movement, sourceFamily: "sudrf",
                                         host: value.searchDomain, observedAt: observedAt))
        let observation = try XCTUnwrap(TrackedCaseIdentity.observation(
            context: value, attempt: attempt, outcome: .usableSnapshot))

        let first = try store.reconcileAndUpsert(
            context: value, snapshot: nil, movement: movement(for: value), collections: [],
            identityObservation: observation, movementFetchedAt: observedAt)
        let initialState = try JSONDecoder().decode(
            LogicalCaseState.self, from: XCTUnwrap(first.identityStateData))
        let initialRefresh = first.movementFetchedAt
        store.failNextSaveForTesting = true
        XCTAssertEqual(try store.reconcileStoredIdentity(), IdentityReconciliationSummary())
        XCTAssertTrue(store.failNextSaveForTesting,
                      "an already canonical graph must not invoke saveContext")
        XCTAssertEqual(try store.reconcileStoredIdentity(), IdentityReconciliationSummary())
        XCTAssertTrue(store.failNextSaveForTesting,
                      "reconciliation must remain idempotent on the next launch")

        let persisted = try XCTUnwrap(store.record(forKey: first.key))
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(persisted.movementFetchedAt, initialRefresh)
        XCTAssertEqual(try JSONDecoder().decode(
            LogicalCaseState.self, from: XCTUnwrap(persisted.identityStateData)), initialState)
    }

    func testCanonicalReconciliationSkipsAllRecordsWithoutSaving() throws {
        let store = TrackedStore(inMemory: true)
        for index in 0..<215 {
            let uid = "11RS0001-01-2026-\(String(format: "%06d", index + 1))-10"
            let value = context(number: "2-\(index + 1)/2026", cardID: "card-\(index)",
                                judicialUID: uid)
            _ = try store.reconcileAndUpsert(context: value, snapshot: nil, collections: [])
        }

        store.failNextSaveForTesting = true
        let summary = try store.reconcileStoredIdentity()

        XCTAssertEqual(summary, IdentityReconciliationSummary())
        XCTAssertTrue(store.failNextSaveForTesting,
                      "a canonical 215-record store must not start a save transaction")
        XCTAssertEqual(store.all().count, 215)
    }

    func testRepeatedPreparationAndProjectionAreNoOps() throws {
        let store = TrackedStore(inMemory: true)
        let value = context(number: "2-100/2026", cardID: "same-card", judicialUID: oldUID)
        let record = try store.reconcileAndUpsert(
            context: value, snapshot: nil, movement: movement(for: value), collections: [])

        XCTAssertFalse(store.container.mainContext.hasChanges)
        XCTAssertFalse(try TrackedStorePreparation.prepare(
            context: store.container.mainContext))
        XCTAssertFalse(store.container.mainContext.hasChanges)

        store.failNextSaveForTesting = true
        try store.save(projection: .cases([record.key]))
        XCTAssertTrue(store.failNextSaveForTesting,
                      "an unchanged court-act projection must not invoke saveContext")
    }

    func testPreparationRepairsOnlyStoredKoapPartyProjection() throws {
        let store = TrackedStore(inMemory: true)
        let value = context(number: "5-100/2026", cardID: "koap-card", judicialUID: oldUID)
        var parties = CaseParties(kind: .koap)
        parties.add(role: "Защитник (адвокат)", name: "Петров Пётр Петрович")
        parties.add(role: "Привлекаемое лицо", name: "Иванов Иван Иванович",
                    articles: "ч. 1 ст. 12.8 КоАП РФ")
        var cachedMovement = movement(for: value)
        cachedMovement.parties = parties

        var staleSnapshot = MovementDerivation.snapshot(from: cachedMovement, context: value)
        staleSnapshot.partiesShort = "Петров Пётр Петрович · Защитник (адвокат)"
        staleSnapshot.leadCharges = "устаревшие статьи"
        staleSnapshot.secondPartyLine = PartiesSecondLine(
            name: "Иванов Иван Иванович", articles: "ч. 1 ст. 12.8 КоАП РФ", more: nil)
        let record = try store.reconcileAndUpsert(
            context: value, snapshot: staleSnapshot, movement: cachedMovement,
            collections: ["КоАП"], movementFetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let movementData = try XCTUnwrap(record.movementData)
        let movementFetchedAt = try XCTUnwrap(record.movementFetchedAt)
        let eventJournalData = try XCTUnwrap(record.eventJournalData)
        let identityStateData = try XCTUnwrap(record.identityStateData)
        let logicalCaseID = try XCTUnwrap(record.logicalCaseID)

        XCTAssertTrue(try TrackedStorePreparation.prepare(context: store.container.mainContext))

        var expected = staleSnapshot
        expected.partiesShort = MovementDerivation.partiesShort(parties)
        expected.leadCharges = parties.leadCharges
        expected.secondPartyLine = MovementDerivation.partiesSecondLine(parties)
        let repaired = try XCTUnwrap(record.snapshot)
        XCTAssertEqual(repaired, expected)
        XCTAssertEqual(repaired.partiesShort, "Иванов Иван Иванович")
        XCTAssertEqual(repaired.leadCharges, "ч. 1 ст. 12.8 КоАП РФ")
        XCTAssertNil(repaired.secondPartyLine)
        XCTAssertEqual(record.movementData, movementData)
        XCTAssertEqual(record.movementFetchedAt, movementFetchedAt)
        XCTAssertEqual(record.eventJournalData, eventJournalData)
        XCTAssertEqual(record.identityStateData, identityStateData)
        XCTAssertEqual(record.logicalCaseID, logicalCaseID)

        XCTAssertFalse(try TrackedStorePreparation.prepare(
            context: store.container.mainContext, today: calendarTestToday))
    }

    func testPreparationRecalculatesAutomaticDeadlineFromCachedMovementOnly() throws {
        let store = TrackedStore(inMemory: true)
        let value = context(number: "2-224/2026", cardID: "calendar-deadline",
                            cartoteka: "g")
        let cachedMovement = movementWithAutomaticCivilDeadline(for: value)
        var stale = MovementDerivation.snapshot(from: cachedMovement, context: value,
                                                today: calendarTestToday)
        XCTAssertNotNil(stale.deadlines.first(where: { $0.kind == "appeal" })?.provenance?.calendarTrace)
        stale.deadlines[try automaticAppealIndex(in: stale)].provenance?.calendarTrace = nil
        let record = try store.reconcileAndUpsert(
            context: value, snapshot: stale, movement: cachedMovement,
            collections: ["Календарь"], movementFetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        record.sourceRefreshAttempt = SourceAttempt(
            kind: .partial,
            provenance: SourceProvenance(operation: .movement, sourceFamily: "sudrf",
                                         host: value.searchDomain,
                                         affectedSources: ["3kas.sudrf.ru"]))
        let fetchedAt = record.movementFetchedAt
        let attempt = record.sourceRefreshAttempt
        let journal = record.eventJournalData
        let identity = record.identityStateData
        try store.container.mainContext.save()

        XCTAssertTrue(try TrackedStorePreparation.prepare(
            context: store.container.mainContext, today: calendarTestToday))
        let repaired = try XCTUnwrap(record.snapshot)
        XCTAssertNotNil(repaired.deadlines.first(where: {
            $0.kind == "appeal"
        })?.provenance?.calendarTrace)
        XCTAssertEqual(record.movementFetchedAt, fetchedAt)
        XCTAssertEqual(record.sourceRefreshAttempt, attempt)
        XCTAssertEqual(record.eventJournalData, journal)
        XCTAssertEqual(record.identityStateData, identity)
        XCTAssertEqual(record.collectionNames, ["Календарь"])
        XCTAssertFalse(try TrackedStorePreparation.prepare(
            context: store.container.mainContext, today: calendarTestToday))
    }

    func testPreparationPreservesManualDeadlineDateWhileRefreshingCalendarProvenance() throws {
        let store = TrackedStore(inMemory: true)
        let value = context(number: "2-225/2026", cardID: "manual-calendar-deadline",
                            cartoteka: "g")
        let cachedMovement = movementWithAutomaticCivilDeadline(for: value)
        var stale = MovementDerivation.snapshot(from: cachedMovement, context: value,
                                                today: calendarTestToday)
        let appeal = try automaticAppealIndex(in: stale)
        stale.deadlines[appeal].statusRaw = DeadlineStatus.overridden.rawValue
        stale.deadlines[appeal].dateRef = DateUtil.parse("20.10.2026")!.timeIntervalSinceReferenceDate
        stale.deadlines[appeal].provenance?.calendarTrace = nil
        let record = try store.reconcileAndUpsert(
            context: value, snapshot: stale, movement: cachedMovement, collections: [],
            movementFetchedAt: Date(timeIntervalSince1970: 1_700_000_001))
        try store.container.mainContext.save()

        XCTAssertTrue(try TrackedStorePreparation.prepare(
            context: store.container.mainContext, today: calendarTestToday))
        let repaired = try XCTUnwrap(record.snapshot?.deadlines.first(where: {
            $0.kind == "appeal"
        }))
        XCTAssertEqual(repaired.status, .overridden)
        XCTAssertEqual(repaired.date, DateUtil.parse("20.10.2026"))
        XCTAssertNotNil(repaired.provenance?.calendarTrace)
        XCTAssertNotEqual(repaired.dateRef, repaired.provenance?.calculatedDateRef)
    }

    func testPreparationRechecksExistingProposalWithoutFullCacheTimestamp() throws {
        let store = TrackedStore(inMemory: true)
        let value = context(number: "2-229/2026", cardID: "calendar-partial-cache", cartoteka: "g")
        let cachedMovement = movementWithAutomaticCivilDeadline(for: value)
        var stale = MovementDerivation.snapshot(from: cachedMovement, context: value,
                                                today: calendarTestToday)
        stale.deadlines[try automaticAppealIndex(in: stale)].provenance?.calendarTrace = nil
        let preservedStage = stale.stageRaw
        let record = try store.reconcileAndUpsert(
            context: value, snapshot: stale, movement: cachedMovement, collections: [])
        // Модель при первичном upsert ставит время успешной загрузки. Здесь
        // воспроизводим старый/частичный кэш, для которого его нет.
        record.movementFetchedAt = nil
        try store.container.mainContext.save()

        XCTAssertTrue(try TrackedStorePreparation.prepare(
            context: store.container.mainContext, today: calendarTestToday))
        let repaired = try XCTUnwrap(record.snapshot)
        XCTAssertNotNil(repaired.deadlines.first(where: {
            $0.kind == "appeal"
        })?.provenance?.calendarTrace)
        XCTAssertNil(record.movementFetchedAt)
        XCTAssertEqual(repaired.stageRaw, preservedStage)
    }

    func testPreparationPreservesUnverifiedProposedDeadlineWithoutCachedMovement() throws {
        let store = TrackedStore(inMemory: true)
        let value = context(number: "2-230/2026", cardID: "calendar-missing-movement", cartoteka: "g")
        let cachedMovement = movementWithAutomaticCivilDeadline(for: value)
        var stale = MovementDerivation.snapshot(from: cachedMovement, context: value,
                                                today: calendarTestToday)
        stale.deadlines[try automaticAppealIndex(in: stale)].provenance?.calendarTrace = nil
        let record = try store.reconcileAndUpsert(
            context: value, snapshot: stale, movement: cachedMovement, collections: [])
        record.movementData = nil
        try store.container.mainContext.save()
        let before = record.snapshotData

        XCTAssertFalse(try TrackedStorePreparation.prepare(
            context: store.container.mainContext, today: calendarTestToday))
        XCTAssertEqual(record.snapshotData, before)
        let preserved = try XCTUnwrap(record.snapshot?.deadlines.first(where: { $0.kind == "appeal" }))
        XCTAssertEqual(preserved.status, .proposed)
        XCTAssertNil(preserved.provenance?.calendarTrace)
    }

    func testPreparationRollsBackCalendarRecalculationWhenSaveFails() throws {
        let store = TrackedStore(inMemory: true)
        let value = context(number: "2-227/2026", cardID: "calendar-rollback", cartoteka: "g")
        let cachedMovement = movementWithAutomaticCivilDeadline(for: value)
        var stale = MovementDerivation.snapshot(from: cachedMovement, context: value,
                                                today: calendarTestToday)
        stale.deadlines[try automaticAppealIndex(in: stale)].provenance?.calendarTrace = nil
        let record = try store.reconcileAndUpsert(
            context: value, snapshot: stale, movement: cachedMovement, collections: ["Rollback"],
            movementFetchedAt: Date(timeIntervalSince1970: 1_700_000_003))
        try store.container.mainContext.save()
        let snapshotData = record.snapshotData
        let movementFetchedAt = record.movementFetchedAt
        let journalData = record.eventJournalData
        let identityData = record.identityStateData

        XCTAssertThrowsError(try TrackedStorePreparation.prepare(
            context: store.container.mainContext, today: calendarTestToday,
            save: { _ in throw ForcedPreparationSaveError.forced }))
        let restored = try XCTUnwrap(store.record(forKey: record.key))
        XCTAssertEqual(restored.snapshotData, snapshotData)
        XCTAssertEqual(restored.movementFetchedAt, movementFetchedAt)
        XCTAssertEqual(restored.eventJournalData, journalData)
        XCTAssertEqual(restored.identityStateData, identityData)
        XCTAssertFalse(store.container.mainContext.hasChanges)
    }

    func testPreparationLeavesOnlyHistoricalDeadlineSnapshotByteEquivalent() throws {
        let store = TrackedStore(inMemory: true)
        let value = context(number: "2-228/2026", cardID: "calendar-historical", cartoteka: "g")
        let cachedMovement = movementWithAutomaticCivilDeadline(for: value)
        var snapshot = MovementDerivation.snapshot(from: cachedMovement, context: value,
                                                   today: calendarTestToday)
        snapshot.deadlines = [StoredDeadline(
            kind: "appeal", what: "Апелляция", basis: "история", calLabel: "апелляция",
            dateRef: DateUtil.parse("03.10.2026")!.timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.proposed.rawValue, occurrenceKey: "historical-only",
            lifecycleRaw: DeadlineLifecycle.superseded.rawValue)]
        let record = try store.reconcileAndUpsert(
            context: value, snapshot: snapshot, movement: cachedMovement, collections: [],
            movementFetchedAt: Date(timeIntervalSince1970: 1_700_000_004))
        try store.container.mainContext.save()
        let before = record.snapshotData

        XCTAssertFalse(try TrackedStorePreparation.prepare(
            context: store.container.mainContext, today: calendarTestToday))
        XCTAssertEqual(record.snapshotData, before)
        XCTAssertFalse(store.container.mainContext.hasChanges)
    }

    func testPreparationFailsClosedForUncoveredAutomaticDeadlineAndPreservesOtherHistory() throws {
        let store = TrackedStore(inMemory: true)
        let value = context(number: "2-226/2012", cardID: "uncovered-calendar-deadline",
                            cartoteka: "g")
        let first = CaseInstance(
            level: .first, court: value.courtTitle, caseNumber: value.caseNumber,
            judge: nil, domain: value.searchDomain, foundByUID: false,
            result: "Решение принято в окончательной форме",
            sessions: [CaseSession(date: "01.01.2012", event: "Судебное заседание",
                                  result: "Иск удовлетворён; решение принято в окончательной форме")])
        let cachedMovement = CaseMovement(uid: "", caseNumber: value.caseNumber,
                                          inForce: false, instances: [first], complaints: [:], acts: [],
                                          category: "Споры из договоров")
        var stale = MovementDerivation.snapshot(from: cachedMovement, context: value,
                                                today: calendarTestToday)
        let automatic = StoredDeadline(
            kind: "appeal", what: "Апелляция", basis: "старый расчёт", calLabel: "апелляция",
            dateRef: DateUtil.parse("01.02.2012")!.timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.proposed.rawValue, occurrenceKey: "old-auto",
            lifecycleRaw: DeadlineLifecycle.active.rawValue)
        let confirmed = StoredDeadline(
            kind: "cassation", what: "Кассация", basis: "ручная дата", calLabel: "кассация",
            dateRef: DateUtil.parse("10.02.2012")!.timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.confirmed.rawValue, occurrenceKey: "confirmed-history",
            lifecycleRaw: DeadlineLifecycle.active.rawValue)
        let historical = StoredDeadline(
            kind: "appeal", what: "Апелляция", basis: "история", calLabel: "апелляция",
            dateRef: DateUtil.parse("11.02.2012")!.timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.proposed.rawValue, occurrenceKey: "historical",
            lifecycleRaw: DeadlineLifecycle.superseded.rawValue)
        stale.deadlines = [automatic, confirmed, historical]
        let record = try store.reconcileAndUpsert(
            context: value, snapshot: stale, movement: cachedMovement, collections: [],
            movementFetchedAt: Date(timeIntervalSince1970: 1_700_000_002))
        try store.container.mainContext.save()

        XCTAssertTrue(try TrackedStorePreparation.prepare(
            context: store.container.mainContext, today: calendarTestToday))
        let repaired = try XCTUnwrap(record.snapshot)
        XCTAssertEqual(repaired.deadlines.first(where: { $0.occurrenceKey == "old-auto" })?.lifecycle,
                       .superseded)
        XCTAssertEqual(repaired.deadlines.first(where: {
            $0.occurrenceKey == "confirmed-history"
        })?.status, .confirmed)
        XCTAssertEqual(repaired.deadlines.first(where: {
            $0.occurrenceKey == "confirmed-history"
        })?.lifecycle, .active)
        XCTAssertEqual(repaired.deadlines.first(where: {
            $0.occurrenceKey == "historical"
        })?.lifecycle, .superseded)
        XCTAssertEqual(repaired.deadlineAssessments?.first(where: {
            $0.ruleID == "GPK-APPEAL-GENERAL"
        })?.status, .unsupportedCalculation)
    }

    func testPreparationPreservesSnapshotsWithoutUsableKoapMovement() throws {
        let store = TrackedStore(inMemory: true)

        func insert(_ number: String, cardID: String, kind: ProcessKind) throws
            -> TrackedCaseRecord {
            let value = context(number: number, cardID: cardID)
            var parties = CaseParties(kind: kind)
            parties.add(role: "Защитник (адвокат)", name: "Петров Пётр Петрович")
            parties.add(role: "Привлекаемое лицо", name: "Иванов Иван Иванович",
                        articles: "ч. 1 ст. 12.8 КоАП РФ")
            var cachedMovement = movement(for: value)
            cachedMovement.parties = parties
            cachedMovement.acts = []
            cachedMovement.actBodies = [:]
            var snapshot = MovementDerivation.snapshot(from: cachedMovement, context: value)
            snapshot.partiesShort = "сохранённая строка"
            snapshot.leadCharges = "сохранённые статьи"
            snapshot.secondPartyLine = PartiesSecondLine(
                name: "сохранённая вторая строка", articles: nil, more: nil)
            return try store.reconcileAndUpsert(
                context: value, snapshot: snapshot, movement: cachedMovement, collections: [])
        }

        let missing = try insert("5-101/2026", cardID: "missing-movement", kind: .koap)
        missing.movementData = nil
        let corrupt = try insert("5-102/2026", cardID: "corrupt-movement", kind: .koap)
        corrupt.movementData = Data("not-json".utf8)
        let otherKind = try insert("1-103/2026", cardID: "upk-movement", kind: .upk)
        try store.container.mainContext.save()
        let snapshots = [missing, corrupt, otherKind].map(\.snapshotData)
        let movements = [missing, corrupt, otherKind].map(\.movementData)

        XCTAssertFalse(try TrackedStorePreparation.prepare(context: store.container.mainContext))
        XCTAssertEqual([missing, corrupt, otherKind].map(\.snapshotData), snapshots)
        XCTAssertEqual([missing, corrupt, otherKind].map(\.movementData), movements)
    }

    func testNewTrackingStartsWithEmptySemanticBaseline() throws {
        let store = TrackedStore(inMemory: true)
        let value = context(number: "2-100/2026", cardID: "same-card", judicialUID: oldUID)
        let record = try store.reconcileAndUpsert(
            context: value, snapshot: nil, movement: movement(for: value), collections: [])

        XCTAssertEqual(record.eventJournal, CaseEventJournal())
    }

    func testVerifiedRecoveredAppealKeepsExistingFirstInstancePresentation() throws {
        let store = TrackedStore(inMemory: true)
        let first = context(number: "2-100/2026", cardID: "first-card", judicialUID: oldUID)
        let tracked = try store.reconcileAndUpsert(
            context: first, snapshot: nil, movement: movement(for: first), collections: ["Existing"])
        let logicalCaseID = try XCTUnwrap(tracked.logicalCaseID)

        var staleAppeal = context(
            number: "33-200/2026", cardID: "appeal-old", judicialUID: oldUID,
            domain: "vs--komi.sudrf.ru", courtCode: "11VS0001", cartoteka: "g2")
        staleAppeal.courtLevelRaw = CourtLevel.subject.rawValue
        staleAppeal.cartotekaLevelRaw = CourtLevel.subject.rawValue
        staleAppeal.cardURLString = sourceURL(for: staleAppeal).absoluteString
        let survivor = try store.reconcileAndUpsert(
            context: staleAppeal, snapshot: nil, collections: ["Imported"])
        XCTAssertTrue(survivor === tracked)
        XCTAssertEqual(survivor.context?.caseNumber, first.caseNumber)
        let staleKnown = try XCTUnwrap(TrackedCaseRepairCoordinator.knownCard(from: staleAppeal))
        var active = try XCTUnwrap(survivor.context)
        active.knownCards = [staleKnown]
        survivor.context = active
        try store.save()

        var healedAppeal = staleAppeal
        healedAppeal.caseID = "appeal-verified"
        healedAppeal.caseUID = "appeal-link-verified"
        healedAppeal.cardURLString = sourceURL(for: healedAppeal).absoluteString
        let attempt = SourceAttempt(
            kind: .usableSnapshot,
            provenance: SourceProvenance(operation: .discovery, sourceFamily: "sudrf",
                                         host: healedAppeal.searchDomain))
        let saved = try XCTUnwrap(store.applyVerifiedCardContext(
            forLocator: survivor.key, context: healedAppeal, attempt: attempt,
            replacesActiveContext: false,
            replacingKnownCardFrom: staleAppeal))

        XCTAssertEqual(saved.key, tracked.key)
        XCTAssertEqual(saved.logicalCaseID, logicalCaseID)
        XCTAssertEqual(saved.context?.caseNumber, first.caseNumber)
        XCTAssertEqual(saved.context?.cardURLString, first.cardURLString)
        XCTAssertEqual(saved.context?.knownCards?.map(\.caseID), ["appeal-verified"])
        let state = TrackedCaseIdentity.state(for: saved)
        XCTAssertTrue(state.cards.contains { $0.identity.sourceNativeID == "appeal-verified" })
    }

    func testAtomicMergeUnionsEventJournalsWithoutCreatingRepairEvent() throws {
        let store = TrackedStore(inMemory: true)
        let first = context(number: "2-100/2026", cardID: "first-card", judicialUID: oldUID)
        let appeal = context(number: "33-200/2026", cardID: "appeal-card", judicialUID: oldUID,
                             domain: "vs--komi.sudrf.ru", courtCode: "11VS0001", cartoteka: "g2")
        let one = try store.reconcileAndUpsert(context: first, snapshot: nil, collections: [])
        let two = try store.reconcileAndUpsert(context: appeal, snapshot: nil, collections: [])
        let firstEvent = CaseEvent.make(
            kind: .instanceDiscovered, occurrence: ["first"], observedAt: .distantPast,
            evidence: CaseEventEvidence(sourceCardID: "first", occurrenceKey: "first"))
        let secondEvent = CaseEvent.make(
            kind: .judicialActPublished, occurrence: ["second"], observedAt: .distantPast,
            evidence: CaseEventEvidence(sourceCardID: "second", occurrenceKey: "second"))
        try store.appendCaseEvents([firstEvent], to: one)
        try store.appendCaseEvents([secondEvent], to: two)
        try store.save()

        _ = try TrackedCaseRepairCoordinator.atomicMerge(
            store: store, survivor: one, duplicates: [two], canonicalContext: first,
            canonicalCard: nil)

        XCTAssertEqual(Set(one.eventJournal?.events.map(\.id) ?? []),
                       Set([firstEvent.id, secondEvent.id]))
        XCTAssertEqual(one.eventJournal?.events.count, 2)
    }

    func testCorruptedJournalFailsClosed() throws {
        let store = TrackedStore(inMemory: true)
        let value = context(number: "2-100/2026", cardID: "same-card", judicialUID: oldUID)
        let record = try store.reconcileAndUpsert(context: value, snapshot: nil, collections: [])
        record.eventJournalData = Data("not-json".utf8)
        let event = CaseEvent.make(
            kind: .instanceDiscovered, occurrence: ["new"], observedAt: .now,
            evidence: CaseEventEvidence(sourceCardID: "new", occurrenceKey: "new"))

        XCTAssertThrowsError(try store.appendCaseEvents([event], to: record)) { error in
            guard case .corruptedEventJournal = error as? TrackedStoreCommitError else {
                return XCTFail("Expected corrupted journal, got \(error)")
            }
        }
    }

    func testAtomicMergeSaveFailureRollsBackWithoutSecondUpsertSave() throws {
        let store = TrackedStore(inMemory: true)
        let first = context(number: "2-100/2026", cardID: "first-card", judicialUID: oldUID)
        let appeal = context(number: "33-200/2026", cardID: "appeal-card", judicialUID: oldUID,
                             domain: "vs--komi.sudrf.ru", courtCode: "11VS0001", cartoteka: "g2")
        let firstObservation = try XCTUnwrap(TrackedCaseIdentity.observation(context: first))
        let appealObservation = try XCTUnwrap(TrackedCaseIdentity.observation(context: appeal))
        let firstState = LogicalCaseState(observation: firstObservation)
        let appealState = LogicalCaseState(observation: appealObservation)
        let firstRecord = TrackedCaseRecord(
            key: first.key, collections: ["Existing"], caseNumber: first.caseNumber,
            courtTitle: first.courtTitle, displayDomain: first.displayDomain,
            contextData: try JSONEncoder().encode(first), snapshotData: nil)
        firstRecord.logicalCaseID = firstState.logicalCaseID
        firstRecord.identityStateData = try JSONEncoder().encode(firstState)
        firstRecord.judicialUID = TrackedStore.normalizedUID(oldUID)
        let appealRecord = TrackedCaseRecord(
            key: appeal.key, collections: ["Appeal"], caseNumber: appeal.caseNumber,
            courtTitle: appeal.courtTitle, displayDomain: appeal.displayDomain,
            contextData: try JSONEncoder().encode(appeal), snapshotData: nil)
        appealRecord.logicalCaseID = appealState.logicalCaseID
        appealRecord.identityStateData = try JSONEncoder().encode(appealState)
        appealRecord.judicialUID = TrackedStore.normalizedUID(oldUID)
        store.container.mainContext.insert(firstRecord)
        store.container.mainContext.insert(appealRecord)
        try store.container.mainContext.save()

        store.failNextSaveForTesting = true
        XCTAssertThrowsError(try store.reconcileAndUpsert(
            context: appeal, snapshot: nil, collections: ["Must not persist"],
            identityObservation: appealObservation
        )) { error in
            guard case .contextSave = error as? TrackedStoreCommitError else {
                return XCTFail("Expected context-save failure, got \(error)")
            }
        }

        XCTAssertEqual(store.all().count, 2)
        XCTAssertEqual(store.record(forKey: first.key)?.collectionNames, ["Existing"])
        XCTAssertEqual(store.record(forKey: appeal.key)?.collectionNames, ["Appeal"])
        XCTAssertEqual(TrackedCaseIdentity.state(for: try XCTUnwrap(store.record(forKey: first.key))).cards.count,
                       1)
    }

    func testProjectionSynchronizationFailureRollsBackTrackedChanges() throws {
        struct ProjectionFailure: LocalizedError {
            var errorDescription: String? { "forced projection failure" }
        }

        var failNextProjection = false
        let store = TrackedStore(inMemory: true) { context, scope in
            if failNextProjection { throw ProjectionFailure() }
            try CourtActProjectionSynchronizer.synchronize(context: context, scope: scope)
        }
        let original = context(number: "2-100/2026", cardID: "source-card", judicialUID: oldUID)
        let tracked = try store.reconcileAndUpsert(
            context: original, snapshot: nil, movement: movement(for: original),
            collections: ["Existing"])
        let originalActs = tracked.movement?.acts

        var updated = original
        updated.caseNumber = "2-101/2026"
        failNextProjection = true
        XCTAssertThrowsError(try store.reconcileAndUpsert(
            context: updated, snapshot: nil, movement: movement(for: updated, actID: "act-2"),
            collections: ["Must not persist"]
        )) { error in
            guard case .projectionSynchronization = error as? TrackedStoreCommitError else {
                return XCTFail("Expected projection failure, got \(error)")
            }
        }

        let persisted = try XCTUnwrap(store.record(forKey: tracked.key))
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(persisted.caseNumber, original.caseNumber)
        XCTAssertEqual(persisted.collectionNames, ["Existing"])
        XCTAssertEqual(persisted.movement?.acts, originalActs)
    }

    func testStartupIdentityReconciliationPropagatesCommitFailureWithoutMerging() throws {
        struct ProjectionFailure: LocalizedError {
            var errorDescription: String? { "forced startup projection failure" }
        }

        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let first = context(number: "2-100/2026", cardID: "first-card", judicialUID: oldUID)
        let appeal = context(
            number: "33-200/2026", cardID: "appeal-card", judicialUID: oldUID,
            domain: "vs--komi.sudrf.ru", courtCode: "11VS0001", cartoteka: "g2")
        func legacyRecord(_ value: MovementContext, collections: [String]) throws -> TrackedCaseRecord {
            TrackedCaseRecord(
                key: value.key, collections: collections, caseNumber: value.caseNumber,
                courtTitle: value.courtTitle, displayDomain: value.displayDomain,
                contextData: try JSONEncoder().encode(value), snapshotData: nil)
        }
        let firstRecord = try legacyRecord(first, collections: ["First"])
        let appealRecord = try legacyRecord(appeal, collections: ["Appeal"])
        container.mainContext.insert(firstRecord)
        container.mainContext.insert(appealRecord)
        try container.mainContext.save()

        XCTAssertThrowsError(try TrackedStore(
            container: container, prepared: true,
            projectionSynchronizer: { _, _ in throw ProjectionFailure() }
        )) { error in
            guard case .projectionSynchronization = error as? TrackedStoreCommitError else {
                return XCTFail("Expected projection failure, got \(error)")
            }
        }

        let records = try container.mainContext.fetch(FetchDescriptor<TrackedCaseRecord>())
        XCTAssertEqual(Set(records.map(\.key)), Set([first.key, appeal.key]))
        XCTAssertEqual(records.first { $0.key == first.key }?.collectionNames, ["First"])
        XCTAssertEqual(records.first { $0.key == appeal.key }?.collectionNames, ["Appeal"])
    }
}
