import Foundation
import XCTest
@testable import SudrfKit
@testable import SudrfApp

private struct ProviderImportFailure: Error, LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}

private struct PersistedProviderState: Equatable {
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

private actor CSVCaseProvider: CaseProviding {
    private let card: CaseCard
    private(set) var cardURLs: [URL] = []
    private var failNextFetch = false
    private var captchaNextFetch: URL?

    init(card: CaseCard) { self.card = card }

    func search(court: Court, cartoteka: Cartoteka, field: SearchField,
                value: String) async throws -> [CaseSearchResult] { [] }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard { card }

    func fetchCard(url: URL) async throws -> CaseCard {
        cardURLs.append(url)
        if let formURL = captchaNextFetch {
            captchaNextFetch = nil
            throw SudrfError.captchaRequired(formURL: formURL)
        }
        if failNextFetch {
            failNextFetch = false
            throw URLError(.timedOut)
        }
        return card
    }

    func failNext() { failNextFetch = true }
    func requireCaptchaNext(_ formURL: URL) { captchaNextFetch = formURL }
    func fetchCount() -> Int { cardURLs.count }
}

private actor CSVMosGorSudProvider: MosGorSudProviding {
    private let card: MosGorSudCard
    private(set) var cardURLs: [URL] = []
    private var failNextFetch = false

    init(card: MosGorSudCard) { self.card = card }

    func search(courtAlias: String?, uid: String?, caseNumber: String?,
                participant: String?, instance: Int,
                processType: MosGorSudProcessType) async throws -> [MosGorSudResult] { [] }

    func fetchCard(url: URL) async throws -> MosGorSudCard {
        cardURLs.append(url)
        if failNextFetch {
            failNextFetch = false
            throw URLError(.timedOut)
        }
        return card
    }

    func failNext() { failNextFetch = true }
    func fetchCount() -> Int { cardURLs.count }
}

@MainActor
final class ProviderImportRefreshTests: XCTestCase {
    func testFederalModernAndVintageCSVLinksPersistReopenAndRefreshDirectly() async throws {
        let rows = [
            ("2-100/2026", "https://nvs--spb.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=modern-100&case_uid=modern-guid&delo_id=1540005&new=0"),
            ("2-101/2026", "http://nvs--spb.sudrf.ru/modules.php?name=sud_delo&name_op=case&_uid=vintage-guid&_deloId=1540005&_new=0&srv_num=2")
        ]

        for (index, (number, rawURL)) in rows.enumerated() {
            let source = try XCTUnwrap(URL(string: rawURL))
            let row = ImportedRow(number: number,
                                  court: "Невский районный суд (Город Санкт-Петербург)",
                                  parties: "Истец ⚔ Ответчик", urlString: rawURL)
            let seed = try unwrapSeed(CaseImporter.classify(row))
            XCTAssertEqual(seed.provider, .sudrf)
            let provider = CSVCaseProvider(card: CaseCard(
                rawText: "федеральная карточка", actText: nil,
                uid: "11RS0001-01-2026-00010\(index)-45", caseNumber: number))
            let importedCard = try await provider.fetchCard(url: source)
            let plan = CaseImporter.plan([CaseImporter.Fetched(seed: seed, card: importedCard)])
            let planned = try XCTUnwrap(plan.records.first)
            XCTAssertEqual(planned.context.cardURLString, rawURL,
                           "точная федеральная ссылка, включая vintage srv_num, должна сохраниться")

            let (directory, storeURL) = try makeStoreURL("csv-federal-\(index)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let key = planned.context.key
            let afterFirst: PersistedProviderState
            do {
                let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
                let store = try TrackedStore(container: container, prepared: true)
                let record = try store.upsert(context: planned.context, snapshot: nil,
                                              movement: nil,
                                              collections: ["CSV", "Пользовательская"])
                let center = RefreshCenter(
                    store: store, client: TestNetworkGuard.sudrfClient(),
                    serviceBuilder: { context in context.makeService(client: provider) })
                let first = await center.refresh(key: key, manually: true)?.value
                switch first?.outcome {
                case .refreshed?, .partial?: break
                default: return XCTFail("прямая федеральная карточка должна обновляться")
                }
                XCTAssertEqual(record.movement?.instances.first?.sourceURL, source)
                XCTAssertEqual(try XCTUnwrap(record.eventJournal).events, [])
                afterFirst = try PersistedProviderState(record: record)
            }

            do {
                // The first phase has released its center, record, store, and container.
                let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
                let reopened = try TrackedStore(container: container, prepared: true)
                XCTAssertEqual(reopened.all().count, 1)
                let loaded = try XCTUnwrap(reopened.record(forKey: key))
                XCTAssertEqual(try PersistedProviderState(record: loaded), afterFirst)

                let center = RefreshCenter(
                    store: reopened, client: TestNetworkGuard.sudrfClient(),
                    serviceBuilder: { context in context.makeService(client: provider) })
                let repeated = await center.refresh(key: key, manually: true)?.value
                switch repeated?.outcome {
                case .refreshed?, .partial?: break
                default: return XCTFail("сохранённая федеральная карточка должна обновляться повторно")
                }
                let afterRepeat = try XCTUnwrap(reopened.record(forKey: key))
                XCTAssertEqual(afterRepeat.logicalCaseID, afterFirst.logicalCaseID)
                XCTAssertEqual(afterRepeat.collectionNames.sorted(), ["CSV", "Пользовательская"])
                XCTAssertEqual(afterRepeat.context?.cardURLString, rawURL)
                XCTAssertEqual(afterRepeat.movement?.instances.count, 1)
                XCTAssertEqual(try XCTUnwrap(afterRepeat.eventJournal).events.map(\.id), [])
                let fetchCount = await provider.fetchCount()
                XCTAssertEqual(fetchCount, 3, "import fetch плюс два refresh используют карточный URL")
            }
        }
    }

    func testMagistrateCardLocatorPersistsReopensRefreshesAndKeepsCacheOnFailure() async throws {
        let number = "2-15/2026"
        let source = URL(string: "https://zheshartsky.komi.msudrf.ru/modules.php?name=sud_delo&op=cs&case_id=141614450&delo_id=1540005")!
        let row = ImportedRow(number: number, court: "Судебный участок № 1",
                              parties: "Истец ⚔ Ответчик",
                              urlString: source.absoluteString)
        let seed = try unwrapSeed(CaseImporter.classify(row))
        XCTAssertEqual(seed.provider, .msudrf)
        let provider = CSVCaseProvider(card: CaseCard(rawText: "карточка мирового судьи",
                                                      actText: nil, caseNumber: number))

        let importedCard = try await provider.fetchCard(url: source)
        XCTAssertEqual(importedCard.caseNumber, number)
        let plan = CaseImporter.plan([CaseImporter.Fetched(seed: seed, card: importedCard)])
        let planned = try XCTUnwrap(plan.records.first)
        XCTAssertEqual(planned.context.cardURLString, source.absoluteString)
        XCTAssertEqual(planned.context.cartoteka?.id, "g1")

        let (directory, storeURL) = try makeStoreURL("csv-msudrf")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = planned.context.key
        let afterFirst: PersistedProviderState
        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let store = try TrackedStore(container: container, prepared: true)
            let record = try store.upsert(context: planned.context, snapshot: nil, movement: nil,
                                          collections: ["CSV", "Пользовательская"])
            let center = RefreshCenter(
                store: store, client: TestNetworkGuard.sudrfClient(),
                serviceBuilder: { context in
                    context.makeService(client: provider, magistrate: provider)
                })
            let first = await center.refresh(key: key, manually: true)?.value
            XCTAssertEqual(first?.outcome, .refreshed)
            XCTAssertEqual(record.movement?.instances.first?.sourceURL, source)
            XCTAssertEqual(try XCTUnwrap(record.eventJournal).events, [])
            afterFirst = try PersistedProviderState(record: record)
            XCTAssertNotNil(afterFirst.movementFetchedAt)
            let firstCount = await provider.fetchCount()
            XCTAssertEqual(firstCount, 2, "CSV fetch и первый refresh используют ссылку карточки")
        }

        do {
            // Reopen the fixture through a new container only after the first store graph is released.
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let reopened = try TrackedStore(container: container, prepared: true)
            XCTAssertEqual(reopened.all().count, 1)
            let loaded = try XCTUnwrap(reopened.record(forKey: key))
            XCTAssertEqual(try PersistedProviderState(record: loaded), afterFirst)

            let center = RefreshCenter(
                store: reopened, client: TestNetworkGuard.sudrfClient(),
                serviceBuilder: { context in
                    context.makeService(client: provider, magistrate: provider)
                })
            let repeated = await center.refresh(key: key, manually: true)?.value
            XCTAssertEqual(repeated?.outcome, .refreshed)
            let afterRepeat = try XCTUnwrap(reopened.record(forKey: key))
            XCTAssertEqual(afterRepeat.logicalCaseID, afterFirst.logicalCaseID)
            XCTAssertEqual(afterRepeat.collectionNames.sorted(), ["CSV", "Пользовательская"])
            XCTAssertEqual(afterRepeat.context?.cardURLString, source.absoluteString)
            XCTAssertEqual(afterRepeat.movement?.instances.count, 1)
            XCTAssertEqual(try XCTUnwrap(afterRepeat.eventJournal).events.map(\.id), [])
            XCTAssertNotNil(afterRepeat.movementFetchedAt)
            let secondCount = await provider.fetchCount()
            XCTAssertEqual(secondCount, 3)

            let cachedMovement = try XCTUnwrap(afterRepeat.movement)
            let successfulFetchedAt = try XCTUnwrap(afterRepeat.movementFetchedAt)
            await provider.failNext()
            guard case .failed = (await center.refresh(key: key, manually: true)?.value)?.outcome else {
                return XCTFail("временная ошибка карточки мирового судьи должна остаться видимой")
            }
            let afterFailure = try XCTUnwrap(reopened.record(forKey: key))
            XCTAssertEqual(afterFailure.movement, cachedMovement)
            XCTAssertEqual(afterFailure.movementFetchedAt, successfulFetchedAt,
                           "ошибка не продлевает срок свежести кэша")
            XCTAssertEqual(afterFailure.sourceRefreshAttempt?.kind, .transportFailure)
            XCTAssertEqual(try XCTUnwrap(afterFailure.eventJournal).events.map(\.id), [],
                           "ошибка не добавляет события в журнал")
            XCTAssertNil(afterFailure.seenAt)

            let formURL = URL(string: "https://zheshartsky.komi.msudrf.ru/modules.php?name=sud_delo&op=cap")!
            await provider.requireCaptchaNext(formURL)
            let captchaOutcome = await center.refreshForIntent(key: key)
            XCTAssertEqual(captchaOutcome, .captchaRequired)
            let afterCaptcha = try XCTUnwrap(reopened.record(forKey: key))
            XCTAssertEqual(afterCaptcha.movement, cachedMovement,
                           "капча не заменяет последний подтверждённый снимок")
            XCTAssertEqual(afterCaptcha.movementFetchedAt, successfulFetchedAt)
            XCTAssertEqual(try XCTUnwrap(afterCaptcha.eventJournal).events.map(\.id), [])
            XCTAssertEqual(center.captchaPendingRequest(forKey: key)?.formURL, formURL)
        }
    }

    func testMoscowCardLocatorPersistsReopensRefreshesAndRejectsWrongCourtPath() async throws {
        let number = "3а-2719/2023"
        let source = URL(string: "https://mos-gorsud.ru/mgs/services/cases/first-admin/details/df043061-4638-11ed-8d08-f17fce8d2817")!
        let row = ImportedRow(number: number, court: "Московский городской суд",
                              parties: "Истец ⚔ Ответчик",
                              urlString: source.absoluteString)
        let seed = try unwrapSeed(CaseImporter.classify(row))
        XCTAssertEqual(seed.provider, .mosgorsud)
        let provider = CSVMosGorSudProvider(card: MosGorSudCard(
            caseNumber: number, court: "Московский городской суд"))
        let importedCard = try await provider.fetchCard(url: source)
        XCTAssertEqual(importedCard.caseNumber, number)
        let plan = CaseImporter.plan([CaseImporter.Fetched(
            seed: seed,
            card: CaseCard(rawText: importedCard.rawText, actText: nil,
                           caseNumber: importedCard.caseNumber))])
        let planned = try XCTUnwrap(plan.records.first)
        XCTAssertEqual(planned.context.cardURLString, source.absoluteString)
        XCTAssertEqual(planned.context.cartoteka?.id, "p1")

        let (directory, storeURL) = try makeStoreURL("csv-mgs")
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = planned.context.key
        let afterFirst: PersistedProviderState
        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let store = try TrackedStore(container: container, prepared: true)
            let record = try store.upsert(context: planned.context, snapshot: nil, movement: nil,
                                          collections: ["CSV", "Пользовательская"])
            let center = RefreshCenter(
                store: store, client: TestNetworkGuard.sudrfClient(),
                serviceBuilder: { context in
                    context.makeService(client: TestNetworkGuard.sudrfClient(), mosgorsud: provider)
                })
            let first = await center.refresh(key: key, manually: true)?.value
            XCTAssertEqual(first?.outcome, .refreshed)
            XCTAssertEqual(record.movement?.instances.first?.sourceURL, source)
            XCTAssertEqual(try XCTUnwrap(record.eventJournal).events, [])
            afterFirst = try PersistedProviderState(record: record)
            XCTAssertNotNil(afterFirst.movementFetchedAt)
            let firstCount = await provider.fetchCount()
            XCTAssertEqual(firstCount, 2)
        }

        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let reopened = try TrackedStore(container: container, prepared: true)
            XCTAssertEqual(reopened.all().count, 1)
            let loaded = try XCTUnwrap(reopened.record(forKey: key))
            XCTAssertEqual(try PersistedProviderState(record: loaded), afterFirst)

            let center = RefreshCenter(
                store: reopened, client: TestNetworkGuard.sudrfClient(),
                serviceBuilder: { context in
                    context.makeService(client: TestNetworkGuard.sudrfClient(), mosgorsud: provider)
                })
            let repeated = await center.refresh(key: key, manually: true)?.value
            XCTAssertEqual(repeated?.outcome, .refreshed)
            let afterRepeat = try XCTUnwrap(reopened.record(forKey: key))
            XCTAssertEqual(afterRepeat.logicalCaseID, afterFirst.logicalCaseID)
            XCTAssertEqual(afterRepeat.collectionNames.sorted(), ["CSV", "Пользовательская"])
            XCTAssertEqual(afterRepeat.context?.cardURLString, source.absoluteString)
            XCTAssertEqual(afterRepeat.movement?.instances.count, 1)
            XCTAssertEqual(try XCTUnwrap(afterRepeat.eventJournal).events.map(\.id), [])
            let repeatCount = await provider.fetchCount()
            XCTAssertEqual(repeatCount, 3)

            var wrongCourt = planned.context
            wrongCourt.courtTitle = "Тверской районный суд"
            let wrongStore = TrackedStore(inMemory: true)
            let wrongRecord = try wrongStore.upsert(context: wrongCourt, snapshot: nil,
                                                    movement: nil, collections: [])
            let wrongCenter = RefreshCenter(
                store: wrongStore, client: TestNetworkGuard.sudrfClient(),
                serviceBuilder: { context in
                    context.makeService(client: TestNetworkGuard.sudrfClient(), mosgorsud: provider)
                })
            guard case .failed = (await wrongCenter.refresh(
                key: wrongRecord.key, manually: true)?.value)?.outcome else {
                return XCTFail("ссылка Мосгорсуда на /mgs не должна подтверждать карточку райсуда")
            }
            let finalFetchCount = await provider.fetchCount()
            XCTAssertEqual(finalFetchCount, 3,
                           "неверный court/path отбрасывается до сетевого запроса")
        }
    }

    private func makeStoreURL(_ prefix: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("fixture.store"))
    }

    private func unwrapSeed(_ outcome: ImportRowOutcome) throws -> ImportSeed {
        switch outcome {
        case .seed(let seed): return seed
        case .skipped(let reason):
            throw ProviderImportFailure(reason: "CSV source row was skipped: \(reason)")
        }
    }
}
