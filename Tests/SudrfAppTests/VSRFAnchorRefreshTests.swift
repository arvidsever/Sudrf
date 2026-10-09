import Foundation
import XCTest
@testable import SudrfKit
@testable import SudrfApp

private struct VSRFPersistedState: Equatable {
    let logicalCaseID: UUID?
    let cardIDs: [String]
    let relatedCardIDs: [String]
    let collections: [String]
    let addedAt: Date
    let context: MovementContext?
    let movement: CaseMovement?
    let movementFetchedAt: Date?
    let sourceRefreshAttempt: SourceAttempt?
    let eventJournalIDs: [String]

    init(record: TrackedCaseRecord) throws {
        let identity = TrackedCaseIdentity.state(for: record)
        logicalCaseID = record.logicalCaseID
        cardIDs = identity.cards.map { $0.identity.sourceNativeID }.sorted()
        relatedCardIDs = identity.officialRelations.compactMap {
            $0.relatedCard?.sourceNativeID
        }.sorted()
        collections = record.collectionNames.sorted()
        addedAt = record.addedAt
        context = record.context
        movement = record.movement
        movementFetchedAt = record.movementFetchedAt
        sourceRefreshAttempt = record.sourceRefreshAttempt
        eventJournalIDs = try XCTUnwrap(record.eventJournal).events.map(\.id)
    }
}

@MainActor
final class VSRFAnchorRefreshTests: XCTestCase {
    private actor Provider: VSRFProviding {
        let card: VSRFCard
        private(set) var fetchCount = 0
        private var failNextFetch = false

        init(card: VSRFCard) { self.card = card }

        func search(uniqueNumber: String?, oldCaseNumber: String?,
                    keywords: String?) async throws -> VSRFSearchResults {
            VSRFSearchResults(total: 0, results: [])
        }

        func fetchCard(productionID: String,
                       section: VSRFCardSection) async throws -> VSRFCard {
            fetchCount += 1
            if failNextFetch {
                failNextFetch = false
                throw URLError(.timedOut)
            }
            return card
        }

        func failNext() { failNextFetch = true }
    }

    func testCSVVSRFAnchorRefreshReopensRepeatsAndKeepsCacheOnTransientFailure() async throws {
        let cardID = "12-36321243"
        let number = "3-ИКАД25-3-А2"
        let card = VSRFCard(productions: [VSRFProduction(
            cardID: cardID, cardSection: .claims, kind: .caseFile,
            number: number, uid: "11OS0000-01-2025-000169-68",
            events: [VSRFEvent(date: "15.10.2025", text: "Определение вынесено")])])
        let sourceURL = "https://www.vsrf.ru/lk/practice/claims/\(cardID)"
        let row = ImportedRow(number: number, court: "Верховный Суд РФ",
                              parties: "Заявитель ⚔ Ответчик", urlString: sourceURL)
        guard case .seed(let seed) = CaseImporter.classify(row) else {
            return XCTFail("строка VS РФ должна классифицироваться как поддерживаемый источник")
        }
        let fetched = CaseImporter.Fetched(
            seed: seed,
            card: CaseCard(rawText: "", actText: nil, uid: card.uid,
                           caseNumber: number),
            vsrfCard: card)
        let planned = try XCTUnwrap(CaseImporter.plan([fetched]).records.first)
        XCTAssertNil(planned.context.cartoteka)
        XCTAssertNil(planned.context.judicialUID,
                     "один УИД ВС РФ не связывает независимые production IDs")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("csv-vsrf-anchor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("fixture.store")
        let key = planned.context.key
        let provider = Provider(card: card)
        let afterFirstState: VSRFPersistedState
        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let store = try TrackedStore(container: container, prepared: true)
            _ = try store.upsert(context: planned.context, snapshot: nil,
                                 movement: nil, collections: ["CSV", "Пользовательская"])
            let center = RefreshCenter(store: store, client: TestNetworkGuard.sudrfClient(),
                                       vsrfProvider: provider)

            let first = await center.refresh(key: key, manually: true)?.value
            XCTAssertEqual(first?.outcome, .refreshed)
            let afterFirst = try XCTUnwrap(store.record(forKey: key))
            XCTAssertEqual(afterFirst.context?.cardURLString, sourceURL)
            XCTAssertEqual(afterFirst.movement?.instances.map(\.sourceURL), [card.productions[0].cardURL])
            XCTAssertEqual(afterFirst.collectionNames.sorted(), ["CSV", "Пользовательская"])
            XCTAssertEqual(try XCTUnwrap(afterFirst.eventJournal).events, [],
                           "первый refresh не создаёт исторические события")
            afterFirstState = try VSRFPersistedState(record: afterFirst)
            XCTAssertEqual(afterFirstState.eventJournalIDs, [])
            XCTAssertNotNil(afterFirstState.movementFetchedAt)
            let firstFetchCount = await provider.fetchCount
            XCTAssertEqual(firstFetchCount, 1)
        }

        do {
            // This container and store are newly created after the first lexical scope released theirs.
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let reopened = try TrackedStore(container: container, prepared: true)
            XCTAssertEqual(reopened.all().count, 1)
            let loaded = try XCTUnwrap(reopened.record(forKey: key))
            XCTAssertEqual(try VSRFPersistedState(record: loaded), afterFirstState)

            let center = RefreshCenter(store: reopened, client: TestNetworkGuard.sudrfClient(),
                                       vsrfProvider: provider)
            let repeated = await center.refresh(key: key, manually: true)?.value
            XCTAssertEqual(repeated?.outcome, .refreshed)
            let afterRepeat = try XCTUnwrap(reopened.record(forKey: key))
            let repeatedState = try VSRFPersistedState(record: afterRepeat)
            XCTAssertEqual(repeatedState.logicalCaseID, afterFirstState.logicalCaseID)
            XCTAssertEqual(repeatedState.cardIDs, afterFirstState.cardIDs)
            XCTAssertEqual(repeatedState.relatedCardIDs, afterFirstState.relatedCardIDs)
            XCTAssertEqual(repeatedState.collections, afterFirstState.collections)
            XCTAssertEqual(repeatedState.addedAt, afterFirstState.addedAt)
            XCTAssertEqual(repeatedState.context, afterFirstState.context)
            XCTAssertEqual(afterRepeat.movement?.instances.count, 1,
                           "повторный refresh не дублирует production")
            XCTAssertEqual(repeatedState.eventJournalIDs, afterFirstState.eventJournalIDs)
            XCTAssertEqual(repeatedState.eventJournalIDs, [])
            let repeatedFetchCount = await provider.fetchCount
            XCTAssertEqual(repeatedFetchCount, 2)

            let cachedMovement = try XCTUnwrap(afterRepeat.movement)
            let successfulFetchedAt = try XCTUnwrap(afterRepeat.movementFetchedAt)
            await provider.failNext()
            let failed = await center.refresh(key: key, manually: true)?.value
            guard case .failed = failed?.outcome else {
                return XCTFail("временный сбой прямой карточки должен быть виден как ошибка")
            }
            let afterFailure = try XCTUnwrap(reopened.record(forKey: key))
            XCTAssertEqual(afterFailure.movement, cachedMovement,
                           "сбой обновления оставляет последний подтверждённый снимок")
            XCTAssertEqual(afterFailure.movementFetchedAt, successfulFetchedAt,
                           "ошибка не продлевает срок свежести кэша")
            XCTAssertEqual(afterFailure.sourceRefreshAttempt?.kind, .transportFailure)
            XCTAssertEqual(try XCTUnwrap(afterFailure.eventJournal).events.map(\.id), [],
                           "временный сбой не добавляет события в журнал")
            XCTAssertNil(afterFailure.seenAt)
            let failureFetchCount = await provider.fetchCount
            XCTAssertEqual(failureFetchCount, 3)
        }
    }

    func testWrongVSRFPathNeverCallsProviderOrCreatesASnapshot() async throws {
        let context = MovementContext(
            branchRaw: "general", region: "Российская Федерация",
            searchDomain: "vsrf.ru", displayDomain: "vsrf.ru",
            courtTitle: "Верховный Суд РФ", courtLevelRaw: CourtLevel.cassation.rawValue,
            courtCode: nil, cartotekaId: "", cartotekaLevelRaw: CourtLevel.cassation.rawValue,
            caseNumber: "3-КГ26-1-К3", caseID: nil, caseUID: nil,
            essence: nil, judge: nil, receiptDate: nil, decisionDate: nil,
            resultText: nil, legalForceDate: nil,
            cardURLString: "https://vsrf.ru/lk/practice/claims/123/extra")
        var malformed = context
        malformed.baseInstanceLevelRaw = CaseInstance.Level.vsCassation.rawValue
        let store = TrackedStore(inMemory: true)
        let record = try store.upsert(context: malformed, snapshot: nil,
                                      movement: nil, collections: [])
        let provider = Provider(card: VSRFCard(productions: []))
        let center = RefreshCenter(store: store, client: TestNetworkGuard.sudrfClient(),
                                   vsrfProvider: provider)

        let result = await center.refresh(key: record.key, manually: true)?.value
        guard case .failed = result?.outcome else {
            return XCTFail("неверный VS URL не должен подтверждаться прямой загрузкой")
        }
        let fetchCount = await provider.fetchCount
        XCTAssertEqual(fetchCount, 0)
        XCTAssertNil(store.record(forKey: record.key)?.movement)
    }

    func testSameVSRFUIDDoesNotMergeDifferentProductionLocators() throws {
        let uid = "11OS0000-01-2025-000169-68"
        let rows = [
            ("https://vsrf.ru/lk/practice/claims/12-36321243", "3-ИКАД25-3-А2"),
            ("https://vsrf.ru/lk/practice/appeals/21-36321242", "3-КФ25-3-К3")
        ]
        let store = TrackedStore(inMemory: true)
        for (url, number) in rows {
            let row = ImportedRow(number: number, court: "Верховный Суд РФ",
                                  parties: "Заявитель ⚔ Ответчик", urlString: url)
            guard case .seed(let seed) = CaseImporter.classify(row) else {
                return XCTFail("опубликованный локатор ВС РФ должен поддерживаться")
            }
            let context = CaseImporter.makeContext(
                CaseImporter.Fetched(seed: seed,
                                     card: CaseCard(rawText: "", actText: nil,
                                                    uid: uid, caseNumber: number)),
                known: [])
            let locatorURL = try XCTUnwrap(URL(string: url))
            let movement = CaseMovement(
                uid: uid, caseNumber: number, inForce: false,
                instances: [CaseInstance(
                    level: .vsCassation, court: "Верховный Суд РФ", caseNumber: number,
                    judge: nil, domain: "vsrf.ru", foundByUID: false,
                    result: nil, sessions: [], sourceURL: locatorURL)],
                complaints: [:], acts: [])
            let record = try store.upsert(context: context, snapshot: nil, movement: movement,
                                          collections: ["CSV"])
            XCTAssertNil(context.judicialUID)
            XCTAssertNil(record.judicialUID,
                         "scalar УИД ВС не должен участвовать в последующем объединении")
        }

        XCTAssertEqual(store.all().count, 2)
        let reconciliation = try store.reconcileStoredIdentity()
        XCTAssertEqual(reconciliation.merged, 0,
                       "совпадающий УИД сам по себе не объединяет производства ВС РФ")
        XCTAssertEqual(store.all().count, 2)
        XCTAssertNotEqual(store.all()[0].logicalCaseID, store.all()[1].logicalCaseID)
    }

    func testExactPublishedVSRFPairSurvivesReopenAndReimport() throws {
        let caseURL = "https://www.vsrf.ru/lk/practice/claims/12-36321243"
        let complaintURL = "https://www.vsrf.ru/lk/practice/claims/21-36321242"
        let caseNumber = "3-КГ26-1-К3"
        let complaintNumber = "3-КФ26-1-К3"
        let uid = "11RS0001-01-2026-000001-01"
        let officialCard = VSRFCard(productions: [
            VSRFProduction(cardID: "12-36321243", cardSection: .claims,
                           kind: .caseFile, number: caseNumber, uid: uid),
            VSRFProduction(cardID: "21-36321242", cardSection: .claims,
                           kind: .complaint, number: complaintNumber)
        ])

        func planned(url: String, number: String, uid: String?) throws -> CaseImporter.PlannedRecord {
            let row = ImportedRow(number: number, court: "Верховный Суд РФ",
                                  parties: "Заявитель ⚔ Ответчик", urlString: url)
            guard case .seed(let seed) = CaseImporter.classify(row) else {
                throw NSError(domain: "VSRF import", code: 1)
            }
            let attempt = SourceAttempt(
                kind: .usableSnapshot,
                provenance: SourceProvenance(operation: .discovery,
                                             sourceFamily: "vsrf", host: "vsrf.ru"))
            return try XCTUnwrap(CaseImporter.plan([CaseImporter.Fetched(
                seed: seed,
                card: CaseCard(rawText: "", actText: nil, uid: uid,
                               caseNumber: number),
                sourceAttempt: attempt,
                vsrfCard: officialCard)]).records.first)
        }

        let casePlan = try planned(url: caseURL, number: caseNumber, uid: uid)
        XCTAssertNotNil(casePlan.provenVSRFRelation)
        XCTAssertEqual(casePlan.context.knownCards?.compactMap { $0.sourceURL?.absoluteString },
                       [complaintURL],
                       "одна точная опубликованная пара сохраняет вторую карточку в контексте")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("csv-vsrf-pair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("fixture.store")
        let firstState: VSRFPersistedState
        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true,
                                       importVSRFProvider: Provider(card: officialCard))
            _ = try router.commitImport(records: [casePlan], collection: "CSV")
            let store = try TrackedStore(container: container, prepared: true)
            let first = try XCTUnwrap(store.all().first)
            firstState = try VSRFPersistedState(record: first)
            XCTAssertEqual(firstState.relatedCardIDs, ["21-36321242"])
            XCTAssertEqual(firstState.cardIDs, ["12-36321243"])
            XCTAssertEqual(firstState.collections, ["CSV"])
            XCTAssertEqual(firstState.eventJournalIDs, [])
            XCTAssertNil(firstState.movementFetchedAt)
        }

        let complaintPlan = try planned(url: complaintURL, number: complaintNumber, uid: uid)
        XCTAssertEqual(complaintPlan.context.knownCards?.compactMap { $0.sourceURL?.absoluteString },
                       [caseURL])
        do {
            // Reopen from disk after the first router and all its SwiftData references have left scope.
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let reopenedRouter = try AppRouter(modelContainer: container,
                                               modelContainerIsPrepared: true,
                                               importVSRFProvider: Provider(card: officialCard))
            let reopened = try TrackedStore(container: container, prepared: true)
            XCTAssertEqual(reopened.all().count, 1)
            let loaded = try XCTUnwrap(reopened.all().first)
            XCTAssertEqual(try VSRFPersistedState(record: loaded), firstState)

            _ = try reopenedRouter.commitImport(records: [complaintPlan], collection: "CSV")
            let importedAgain = try XCTUnwrap(reopened.all().first)
            let finalState = try VSRFPersistedState(record: importedAgain)
            XCTAssertEqual(reopened.all().count, 1,
                           "точная пара после холодного открытия обновляет тот же трек")
            XCTAssertEqual(finalState.logicalCaseID, firstState.logicalCaseID)
            XCTAssertEqual(finalState.relatedCardIDs, ["12-36321243", "21-36321242"])
            XCTAssertEqual(finalState.cardIDs, ["12-36321243", "21-36321242"])
            XCTAssertEqual(finalState.collections, firstState.collections)
            XCTAssertEqual(finalState.addedAt, firstState.addedAt)
            XCTAssertEqual(finalState.eventJournalIDs, firstState.eventJournalIDs)
            XCTAssertEqual(finalState.eventJournalIDs, [],
                           "reimport does not create historical notifications")
            XCTAssertNil(finalState.movementFetchedAt)
            XCTAssertEqual(finalState.sourceRefreshAttempt?.kind, .usableSnapshot)
        }
    }

    func testVSRFKnownCardURLAloneDoesNotCreateSourceNativeRelation() throws {
        let rows = [
            ("https://vsrf.ru/lk/practice/claims/12-36321243", "3-КГ26-1-К3",
             "https://vsrf.ru/lk/practice/claims/21-36321242", "3-КФ26-1-К3"),
            ("https://vsrf.ru/lk/practice/claims/12-46321243", "3-КГ26-2-К3",
             "https://vsrf.ru/lk/practice/claims/21-46321242", "3-КФ26-2-К3")
        ]
        let store = TrackedStore(inMemory: true)
        for (url, number, arbitraryRelatedURL, relatedNumber) in rows {
            let row = ImportedRow(number: number, court: "Верховный Суд РФ",
                                  parties: "Заявитель ⚔ Ответчик", urlString: url)
            guard case .seed(let seed) = CaseImporter.classify(row) else {
                return XCTFail("опубликованный локатор ВС РФ должен поддерживаться")
            }
            var context = CaseImporter.makeContext(
                CaseImporter.Fetched(seed: seed,
                                     card: CaseCard(rawText: "", actText: nil,
                                                    uid: "11RS0001-01-2026-000001-01",
                                                    caseNumber: number)),
                known: [])
            context.knownCards = [KnownCard(
                domain: "vsrf.ru", courtTitle: "Верховный Суд РФ",
                caseID: "arbitrary", caseUID: "",
                deloID: "", new: "0", caseNumber: relatedNumber,
                levelRaw: CaseInstance.Level.vsCassation.rawValue,
                sourceURL: URL(string: arbitraryRelatedURL))]
            _ = try store.upsert(context: context, snapshot: nil,
                                 movement: nil, collections: ["CSV"])
        }

        XCTAssertEqual(store.all().count, 2)
        XCTAssertEqual(try store.reconcileStoredIdentity().merged, 0)
        XCTAssertEqual(store.all().count, 2,
                       "два arbitrary known URL и общий УИД не доказывают отношение между производствами")
        XCTAssertTrue(store.all().allSatisfy {
            TrackedCaseIdentity.state(for: $0).officialRelations.isEmpty
        })
    }
}
