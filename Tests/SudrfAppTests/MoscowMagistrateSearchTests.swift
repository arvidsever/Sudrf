import Foundation
import XCTest
import SudrfKit
import CaptchaSolver
import SwiftData
@testable import SudrfApp
@testable import SudrfKit
@testable import CaptchaSolver

@MainActor
final class MoscowMagistrateSearchTests: XCTestCase {
    func testPickerSelectionScopesGlobalSearchAndOpensExactNativeCard() async throws {
        MoscowUnitSearchURLProtocol.configure(
            directory: Self.directoryHTML,
            results: Self.resultsHTML,
            card: Self.cardHTML)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MoscowUnitSearchURLProtocol.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            MoscowUnitSearchURLProtocol.reset()
        }

        let ordinaryClient = SudrfClient(session: session, minInterval: 0)
        let moscowClient = MoscowMagistrateKoAPClient(session: session, minInterval: 0,
                                                     maxAttempts: 1)
        let corpusURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moscow-search-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: corpusURL) }
        let settings = CaptchaSettings.shared
        let solver = CaptchaSolver(
            provider: VisionOCRStrategy(), enabledKinds: [],
            log: CaptchaSolverLog(fileURL: nil, failuresDir: nil))
        let model = SearchModel(
            captchaSolver: solver,
            captchaSettings: settings,
            corpusStore: CorpusStore(baseDir: corpusURL),
            client: ordinaryClient,
            resolver: DistrictCourtResolver(client: ordinaryClient, cacheURL: nil),
            magistrateResolver: MagistrateCourtResolver(
                client: ordinaryClient, cacheURL: nil, moscowDirectoryClient: moscowClient),
            mosGorSudClient: MosGorSudClient(session: session, minInterval: 0),
            moscowMagistrateClient: moscowClient)

        model.tier = .magistrate
        model.region = "77"
        await model.resolveCourts()

        XCTAssertEqual(model.courts.count, 3)
        let selected = try XCTUnwrap(model.courts.first {
            $0.moscowMagistrateUnitPathID == "425"
        })
        XCTAssertEqual(selected.id, "mos-sud.ru#77MS0425")
        XCTAssertEqual(selected.title, "Участок мирового судьи № 425 (Синтетический район 425)")
        model.selectedCourtID = selected.id
        XCTAssertTrue(model.uidSearchEnabled)
        model.queryCaseNumber = "5-42/425/2026"
        model.queryName = "Синтетический участник"

        await model.runSearch()

        XCTAssertEqual(model.results.count, 1)
        let result = try XCTUnwrap(model.results.first)
        XCTAssertEqual(result.cardURL?.absoluteString,
                       "https://mos-sud.ru/425/cases/admin/details/22222222-2222-4222-8222-222222222222")
        XCTAssertTrue(model.status.contains("выдача неполная"))
        XCTAssertFalse(model.status.contains("mos-sud.ru"))

        await model.openCard(result)
        XCTAssertEqual(MoscowUnitSearchURLProtocol.cardRequests(), [result.cardURL])
        XCTAssertEqual(model.cardPDFMetadata?.courtName, selected.title)
        let context = try XCTUnwrap(model.currentContext())
        XCTAssertEqual(context.courtTitle, selected.title)
        XCTAssertEqual(context.courtCode, "77MS0425")
        XCTAssertEqual(context.cardURLString, result.cardURL?.absoluteString)
        let reopenedContext = try JSONDecoder().decode(
            MovementContext.self, from: JSONEncoder().encode(context))
        XCTAssertEqual(reopenedContext, context)
        let reopenedLocator = try XCTUnwrap(SourceNativeCardLocator.moscowMagistrateKoAP(
            url: try XCTUnwrap(reopenedContext.cardURLString.flatMap(URL.init(string:))),
            cartoteka: try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm"))))
        XCTAssertEqual(reopenedLocator.courtKey, selected.moscowMagistrateUnitPathID)
        XCTAssertEqual(reopenedContext.courtCode, selected.code)
        XCTAssertEqual(reopenedContext.courtTitle, selected.title)

        let wrongUnit = try XCTUnwrap(model.courts.first {
            $0.moscowMagistrateUnitPathID == "426"
        })
        model.selectedCourtID = wrongUnit.id
        await model.runSearch()
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.status, "Нельзя подтвердить отсутствие дел по выбранному участку.")
        XCTAssertFalse(model.status.contains("Ничего не найдено"))

        let searchRequests = MoscowUnitSearchURLProtocol.searchRequests()
        XCTAssertEqual(searchRequests.count, 2)
        XCTAssertTrue(searchRequests.allSatisfy {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems
                == [URLQueryItem(name: "caseNumber", value: "5-42/425/2026")]
        })
    }

    func testMoscowNativeIdentityAdmissionRequiresExactLoadedLocator() throws {
        let baseURL = try XCTUnwrap(URL(string:
            "https://mos-sud.ru/425/cases/admin/details/22222222-2222-4222-8222-222222222222"))
        let cartoteka = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm"))
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: MoscowMagistrateKoAPSource.host,
            displayDomain: MoscowMagistrateKoAPSource.host,
            courtTitle: "Участок мирового судьи № 425 (Синтетический район 425)",
            courtLevelRaw: CourtLevel.magistrate.rawValue, courtCode: "77MS0425",
            cartotekaId: "adm", cartotekaLevelRaw: CourtLevel.magistrate.rawValue,
            caseNumber: "05-0042/425/2026", cardURLString: baseURL.absoluteString)
        let identity = try XCTUnwrap(SourceNativeCardLocator.moscowMagistrateKoAP(
            url: baseURL, cartoteka: cartoteka)?.identity)
        let instance = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: "5-42/425/2026",
            judge: nil, domain: MoscowMagistrateKoAPSource.host, foundByUID: false,
            result: nil, sessions: [], sourceURL: baseURL)
        let movement = CaseMovement(
            uid: "synthetic-uid", caseNumber: instance.caseNumber, inForce: false,
            instances: [instance], complaints: [:], acts: [],
            sourceRefreshCoverage: [MovementCourtCoverage(
                sourceFamily: MoscowMagistrateKoAPSource.family,
                courtKey: "425", kind: .usableSnapshot, loadedCardIdentities: [identity])])

        XCTAssertEqual(CaseEventSourceAdmission.nativeCardIdentity(
            for: instance, context: context), identity)
        XCTAssertEqual(CaseSnapshotSourceIdentity.sourceCardID(
            for: instance, context: context), identity.id)
        XCTAssertEqual(CaseEventSourceAdmission.courts(in: movement, context: context), [
            "moscow-magistrate-koap|425": [identity.id: identity.id]
        ])

        let wrongUnitURL = try XCTUnwrap(URL(string:
            "https://mos-sud.ru/426/cases/admin/details/33333333-3333-4333-8333-333333333333"))
        var wrongUnit = instance
        wrongUnit.sourceURL = wrongUnitURL
        let wrongUnitMovement = CaseMovement(
            uid: movement.uid, caseNumber: movement.caseNumber, inForce: false,
            instances: [wrongUnit], complaints: [:], acts: [],
            sourceRefreshCoverage: movement.sourceRefreshCoverage)
        XCTAssertEqual(CaseSnapshotSourceIdentity.sourceCardID(
            for: wrongUnit, context: context),
                       "moscow-magistrate-koap|426|adm|33333333-3333-4333-8333-333333333333")
        XCTAssertTrue(CaseEventSourceAdmission.courts(
            in: wrongUnitMovement, context: context).isEmpty,
                      "A valid card from another unit cannot satisfy unit 425's loaded proof")

        let wrongSectionURL = try XCTUnwrap(URL(string:
            "https://mos-sud.ru/425/cases/civil/details/22222222-2222-4222-8222-222222222222"))
        var wrongSection = instance
        wrongSection.sourceURL = wrongSectionURL
        XCTAssertNil(CaseEventSourceAdmission.nativeCardIdentity(
            for: wrongSection, context: context))
        XCTAssertNil(CaseSnapshotSourceIdentity.sourceCardID(
            for: wrongSection, context: context))
    }

    func testSyntheticCompleteMoscowAnchorTransitionPersistsOnceAcrossDiskReopen() async throws {
        let cardURL = try XCTUnwrap(URL(string:
            "https://mos-sud.ru/425/cases/admin/details/22222222-2222-4222-8222-222222222222"))
        let cartoteka = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm"))
        let identity = try XCTUnwrap(SourceNativeCardLocator.moscowMagistrateKoAP(
            url: cardURL, cartoteka: cartoteka)?.identity)
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: MoscowMagistrateKoAPSource.host,
            displayDomain: MoscowMagistrateKoAPSource.host,
            courtTitle: "Участок мирового судьи № 425 (Синтетический район 425)",
            courtLevelRaw: CourtLevel.magistrate.rawValue, courtCode: "77MS0425",
            cartotekaId: "adm", cartotekaLevelRaw: CourtLevel.magistrate.rawValue,
            caseNumber: "05-0042/425/2026",
            caseID: identity.sourceNativeID, caseUID: "77MS0425-01-2026-000042-10",
            cardURLString: cardURL.absoluteString)

        func movement(sessions: [CaseSession]) -> CaseMovement {
            let instance = CaseInstance(
                level: .first, court: context.courtTitle, caseNumber: "5-42/425/2026",
                judge: "Судья Тестова И. И.", domain: MoscowMagistrateKoAPSource.host,
                foundByUID: false, result: "Постановление вынесено", sessions: sessions,
                sourceURL: cardURL)
            return CaseMovement(
                uid: "77MS0425-01-2026-000042-10", caseNumber: instance.caseNumber,
                inForce: false, instances: [instance], complaints: [:], acts: [],
                sourceRefreshCoverage: [MovementCourtCoverage(
                    sourceFamily: MoscowMagistrateKoAPSource.family,
                    courtKey: "425", kind: .usableSnapshot,
                    loadedCardIdentities: [identity])])
        }

        let firstSession = CaseSession(
            date: "31.12.2099", time: "10:30", room: "1",
            event: "Судебное заседание", result: "Назначено")
        let postponedSession = CaseSession(
            date: "31.12.2099", time: "10:30", room: "1",
            event: "Судебное заседание", result: "Отложено")
        let rescheduledSession = CaseSession(
            date: "21.01.2100", time: "10:30", room: "1",
            event: "Судебное заседание", result: "Назначено")
        let sequence = MoscowSyntheticMovementSequence([
            movement(sessions: [firstSession]),
            movement(sessions: [postponedSession, rescheduledSession]),
            movement(sessions: [postponedSession, rescheduledSession])
        ])

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("moscow-semantic-journal-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            MoscowFederalBlockerURLProtocol.reset()
        }
        let storeURL = directory.appendingPathComponent("fixture.store")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MoscowFederalBlockerURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = SudrfClient(
            session: session, minInterval: 0,
            variantStore: WorkingVariantStore(cacheURL: nil),
            captchaStore: CaptchaTokenStore())

        var baselineIDs: [String] = []
        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false,
                                                                storeURL: storeURL)
            let store = try TrackedStore(container: container, prepared: true)
            let record = try store.upsert(context: context, snapshot: nil, movement: nil,
                                          collections: ["Синтетическая полная выдача"])
            let center = RefreshCenter(
                store: store, client: client,
                serviceBuilder: { _ in sequence }, fsspAutoModelEnabled: false,
                initialTimerDelay: .seconds(3600), timerInterval: .seconds(3600))
            let first = await center.refresh(key: record.key, manually: true)?.value
            XCTAssertEqual(first?.outcome, .refreshed)
            let saved = try XCTUnwrap(store.record(forKey: record.key))
            let events = try XCTUnwrap(saved.eventJournal).events
            XCTAssertEqual(events.map(\.kind), [.hearingScheduled])
            XCTAssertEqual(events.first?.evidence.sourceCardID, identity.id)
            XCTAssertEqual(saved.movement?.sourceRefreshCoverage?.first?.kind, .usableSnapshot)
            baselineIDs = events.map(\.id)
        }

        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false,
                                                                storeURL: storeURL)
            let store = try TrackedStore(container: container, prepared: true)
            let loaded = try XCTUnwrap(store.all().first)
            XCTAssertEqual(try XCTUnwrap(loaded.eventJournal).events.map(\.id), baselineIDs)
            let center = RefreshCenter(
                store: store, client: client,
                serviceBuilder: { _ in sequence }, fsspAutoModelEnabled: false,
                initialTimerDelay: .seconds(3600), timerInterval: .seconds(3600))
            let changed = await center.refresh(key: loaded.key, manually: true)?.value
            XCTAssertEqual(changed?.outcome, .refreshed)
            let saved = try XCTUnwrap(store.record(forKey: loaded.key))
            let events = try XCTUnwrap(saved.eventJournal).events
            XCTAssertEqual(events.count, 2)
            XCTAssertEqual(events.map(\.kind), [.hearingScheduled, .hearingRescheduled])
            XCTAssertEqual(events.filter { $0.kind == .hearingRescheduled }
                .compactMap(\.evidence.sourceCardID), [identity.id])
            XCTAssertEqual(Set(events.map(\.id)).count, 2)
            baselineIDs = events.map(\.id)
        }

        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false,
                                                                storeURL: storeURL)
            let store = try TrackedStore(container: container, prepared: true)
            let loaded = try XCTUnwrap(store.all().first)
            let priorJournal = try XCTUnwrap(loaded.eventJournal)
            XCTAssertEqual(priorJournal.events.map(\.id), baselineIDs)
            let center = RefreshCenter(
                store: store, client: client,
                serviceBuilder: { _ in sequence }, fsspAutoModelEnabled: false,
                initialTimerDelay: .seconds(3600), timerInterval: .seconds(3600))
            let repeated = await center.refresh(key: loaded.key, manually: true)?.value
            XCTAssertEqual(repeated?.outcome, .refreshed)
            let reopened = try XCTUnwrap(store.record(forKey: loaded.key)?.eventJournal)
            XCTAssertEqual(reopened, priorJournal,
                           "The same verified card refresh must not append a duplicate transition")
        }

        XCTAssertTrue(MoscowFederalBlockerURLProtocol.requests().isEmpty,
                      "The synthetic complete-coverage sequence must make no network request")
    }

    func testValidatedUnitContextPersistsAndRefreshesAfterDiskReopen() async throws {
        let context = try await validatedPickerContext()
        let sourceURL = try XCTUnwrap(context.cardURLString.flatMap(URL.init(string:)))
        XCTAssertEqual(context.courtCode, "77MS0425")
        XCTAssertEqual(context.courtTitle,
                       "Участок мирового судьи № 425 (Синтетический район 425)")
        XCTAssertEqual(SourceNativeCardLocator.moscowMagistrateKoAP(
            url: sourceURL,
            cartoteka: try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm")))?
                .courtKey, "425")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("moscow-magistrate-refresh-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
            MoscowUnitRefreshURLProtocol.reset()
            MoscowFederalBlockerURLProtocol.reset()
        }
        let storeURL = directory.appendingPathComponent("fixture.store")
        MoscowUnitRefreshURLProtocol.configure(card: Self.cardHTML)
        let mosgorsud = MoscowRefreshMosGorSudStub()
        let vsrf = MoscowRefreshVSRFStub()
        var journalIDs: [String] = []

        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false,
                                                                storeURL: storeURL)
            let store = try TrackedStore(container: container, prepared: true)
            let record = try store.upsert(context: context, snapshot: nil, movement: nil,
                                          collections: ["Проверка участка Москвы"])
            let center = refreshCenter(store: store, mosgorsud: mosgorsud, vsrf: vsrf)
            let first = await center.refresh(key: record.key, manually: true)?.value
            guard case .partial = first?.outcome else {
                return XCTFail("источники с неполной выдачей должны сохранить частичный результат")
            }

            let saved = try XCTUnwrap(store.record(forKey: record.key))
            XCTAssertEqual(saved.context, context)
            XCTAssertEqual(saved.context?.courtCode, "77MS0425")
            XCTAssertEqual(saved.context?.courtTitle, context.courtTitle)
            XCTAssertEqual(saved.context?.cardURLString, sourceURL.absoluteString)
            XCTAssertEqual(saved.collectionNames, ["Проверка участка Москвы"])
            let base = try XCTUnwrap(saved.movement?.instances.first)
            XCTAssertEqual(base.sourceURL, sourceURL)
            XCTAssertEqual(base.domain, "mos-sud.ru")
            XCTAssertEqual(base.court, context.courtTitle)
            let coverage = try XCTUnwrap(saved.movement?.sourceRefreshCoverage?.first {
                $0.sourceFamily == "moscow-magistrate-koap"
            })
            XCTAssertTrue(coverage.loadedCardIdentities.contains {
                $0.courtKey == "425" && $0.sourceNativeID
                    == "22222222-2222-4222-8222-222222222222"
            })
            journalIDs = try XCTUnwrap(saved.eventJournal).events.map(\.id)
            XCTAssertEqual(saved.sourceRefreshAttempt?.kind, .partial)
        }

        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false,
                                                                storeURL: storeURL)
            let store = try TrackedStore(container: container, prepared: true)
            let loaded = try XCTUnwrap(store.all().first)
            XCTAssertEqual(loaded.context, context)
            XCTAssertEqual(loaded.context?.cardURLString, sourceURL.absoluteString)
            XCTAssertEqual(loaded.context?.courtCode, "77MS0425")
            XCTAssertEqual(loaded.context?.courtTitle, context.courtTitle)

            let center = refreshCenter(store: store, mosgorsud: mosgorsud, vsrf: vsrf)
            let repeated = await center.refresh(key: loaded.key, manually: true)?.value
            guard case .partial = repeated?.outcome else {
                return XCTFail("повторное обновление должно сохранить частичный исход")
            }
            let refreshed = try XCTUnwrap(store.record(forKey: loaded.key))
            XCTAssertEqual(refreshed.context, context)
            XCTAssertEqual(refreshed.movement?.instances.first?.sourceURL, sourceURL)
            XCTAssertEqual(refreshed.movement?.instances.first?.court, context.courtTitle)
            XCTAssertEqual(try XCTUnwrap(refreshed.eventJournal).events.map(\.id), journalIDs)
            XCTAssertEqual(refreshed.collectionNames, ["Проверка участка Москвы"])
        }

        XCTAssertEqual(MoscowUnitRefreshURLProtocol.cardRequests(), [sourceURL, sourceURL])
        let mosgorsudSearchCount = await mosgorsud.searchCount()
        let vsrfSearchCount = await vsrf.searchCount()
        XCTAssertGreaterThanOrEqual(mosgorsudSearchCount, 4)
        XCTAssertGreaterThan(vsrfSearchCount, 0)
        XCTAssertFalse(MoscowFederalBlockerURLProtocol.requests().isEmpty,
                       "The normal federal stages must use the injected offline Sudrf transport")
        XCTAssertTrue(MoscowFederalBlockerURLProtocol.requests().allSatisfy {
            $0.host?.hasSuffix(".sudrf.ru") == true
        })
    }

    private func validatedPickerContext() async throws -> MovementContext {
        MoscowUnitSearchURLProtocol.configure(
            directory: Self.directoryHTML,
            results: Self.resultsHTML,
            card: Self.cardHTML)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MoscowUnitSearchURLProtocol.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer {
            session.invalidateAndCancel()
            MoscowUnitSearchURLProtocol.reset()
        }

        let ordinaryClient = SudrfClient(
            session: session, minInterval: 0,
            variantStore: WorkingVariantStore(cacheURL: nil),
            captchaStore: CaptchaTokenStore())
        let moscowClient = MoscowMagistrateKoAPClient(session: session, minInterval: 0,
                                                     maxAttempts: 1)
        let corpusURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("moscow-search-context-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: corpusURL) }
        let solver = CaptchaSolver(
            provider: VisionOCRStrategy(), enabledKinds: [],
            log: CaptchaSolverLog(fileURL: nil, failuresDir: nil))
        let model = SearchModel(
            captchaSolver: solver,
            captchaSettings: CaptchaSettings.shared,
            corpusStore: CorpusStore(baseDir: corpusURL),
            client: ordinaryClient,
            resolver: DistrictCourtResolver(client: ordinaryClient, cacheURL: nil),
            magistrateResolver: MagistrateCourtResolver(
                client: ordinaryClient, cacheURL: nil, moscowDirectoryClient: moscowClient),
            mosGorSudClient: MosGorSudClient(session: session, minInterval: 0),
            moscowMagistrateClient: moscowClient)
        model.tier = .magistrate
        model.region = "77"
        await model.resolveCourts()
        let selected = try XCTUnwrap(model.courts.first {
            $0.moscowMagistrateUnitPathID == "425"
        })
        model.selectedCourtID = selected.id
        model.queryCaseNumber = "5-42/425/2026"
        model.queryName = "Синтетический участник"
        await model.runSearch()
        let result = try XCTUnwrap(model.results.first)
        await model.openCard(result)
        return try XCTUnwrap(model.currentContext())
    }

    private func refreshCenter(store: TrackedStore,
                               mosgorsud: MoscowRefreshMosGorSudStub,
                               vsrf: MoscowRefreshVSRFStub) -> RefreshCenter {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MoscowFederalBlockerURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let federalSession = URLSession(configuration: configuration)
        let federalClient = SudrfClient(
            session: federalSession, minInterval: 0,
            variantStore: WorkingVariantStore(cacheURL: nil),
            captchaStore: CaptchaTokenStore())

        let moscowConfiguration = URLSessionConfiguration.ephemeral
        moscowConfiguration.protocolClasses = [MoscowUnitRefreshURLProtocol.self]
        moscowConfiguration.httpCookieStorage = nil
        moscowConfiguration.urlCache = nil
        moscowConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let moscowClient = MoscowMagistrateKoAPClient(
            session: URLSession(configuration: moscowConfiguration), minInterval: 0,
            maxAttempts: 1)
        return RefreshCenter(
            store: store, client: federalClient,
            vsrfProvider: vsrf, mosGorSudProvider: mosgorsud,
            moscowMagistrateProvider: moscowClient,
            fsspAutoModelEnabled: false,
            initialTimerDelay: .seconds(3600), timerInterval: .seconds(3600))
    }

    private static var directoryHTML: String {
        """
        <html><script>window.state={courts:[
          {url:"https://mos-sud.ru/rs/424",name:"Участок 424",alias:"424",courtFullNameWithMunicipal:"Участок мирового судьи № 424 (Синтетический район 424)",id:"11111111-1111-4111-8111-111111111111",code:"77MS0424",rsCourtId:"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",canceledAt:""},
          {url:"https://mos-sud.ru/rs/425",name:"Участок 425",alias:"425",courtFullNameWithMunicipal:"Участок мирового судьи № 425 (Синтетический район 425)",id:"22222222-2222-4222-8222-222222222222",code:"77MS0425",rsCourtId:"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",canceledAt:""},
          {url:"https://mos-sud.ru/rs/426",name:"Участок 426",alias:"426",courtFullNameWithMunicipal:"Участок мирового судьи № 426 (Синтетический район 426)",id:"33333333-3333-4333-8333-333333333333",code:"77MS0426",rsCourtId:"cccccccc-cccc-4ccc-8ccc-cccccccccccc",canceledAt:""}
        ]};</script></html>
        """
    }

    private static let resultsHTML = """
    <table><tbody>
      <tr><td><a href="/424/cases/admin/details/11111111-1111-4111-8111-111111111111">05-0042/424/2026</a></td><td>Синтетический участник</td><td>Рассмотрено</td></tr>
      <tr><td><a href="/425/cases/admin/details/22222222-2222-4222-8222-222222222222">05-0042/425/2026</a></td><td>Синтетический участник</td><td>Рассмотрено</td></tr>
    </tbody></table>
    """

    private static let cardHTML = """
    <!doctype html><html lang="ru"><head><meta charset="utf-8"></head><body>
      <div class="row"><div class="left">Наименование суда</div><div class="right">Синтетический мировой участок</div></div>
      <div class="row"><div class="left">Номер дела</div><div class="right">5-42/425/2026</div></div>
      <div class="row"><div class="left">Уникальный идентификатор</div><div class="right">77MS0425-01-2026-000042-10</div></div>
      <div class="row"><div class="left">Судья</div><div class="right">Судья Тестова И. И.</div></div>
      <div class="row"><div class="left">Категория дела</div><div class="right">Административное правонарушение</div></div>
      <div class="row"><div class="left">Текущее состояние</div><div class="right">Назначено к рассмотрению</div></div>
      <div class="row"><div class="left">Стороны</div><div class="right"><p class="table-bold-text">Привлекаемое лицо</p>Синтетический участник</div></div>
      <table><thead><tr><th>Дата и время</th><th>Зал</th><th>Стадия</th><th>Результат</th></tr></thead>
        <tbody><tr><td>10.03.2026 10:30</td><td>1</td><td>Рассмотрение</td><td>Отложено</td></tr></tbody></table>
    </body></html>
    """
}

private actor MoscowSyntheticMovementSequence: MovementProviding {
    private let values: [CaseMovement]
    private var index = 0

    init(_ values: [CaseMovement]) {
        self.values = values
    }

    func movement(for base: CaseSearchResult,
                  court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        guard !values.isEmpty else { throw URLError(.badServerResponse) }
        defer { index += 1 }
        return values[min(index, values.count - 1)]
    }
}

private final class MoscowUnitSearchURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var directory = ""
    nonisolated(unsafe) private static var results = ""
    nonisolated(unsafe) private static var card = ""
    nonisolated(unsafe) private static var requests: [URL] = []

    static func configure(directory: String, results: String, card: String) {
        lock.lock()
        self.directory = directory
        self.results = results
        self.card = card
        requests = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        directory = ""
        results = ""
        card = ""
        requests = []
        lock.unlock()
    }

    static func searchRequests() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.host == "mos-sud.ru" && $0.path == "/search" }
    }

    static func cardRequests() -> [URL?] {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter {
            $0.host == "mos-sud.ru" && $0.path.contains("/cases/admin/details/")
        }.map(Optional.some)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme?.lowercased() == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body: String? = Self.body(for: url)
        guard let body, let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(for url: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        requests.append(url)
        guard url.host == "mos-sud.ru" else {
            return url.host == "sudrf.ru" ? "<html></html>" : nil
        }
        if url.path == "/" { return directory }
        if url.path == "/search" { return results }
        if url.path.contains("/cases/admin/details/") { return card }
        return nil
    }
}

private actor MoscowRefreshMosGorSudStub: MosGorSudProviding {
    private(set) var searchRequests = 0

    func search(courtAlias: String?, uid: String?, caseNumber: String?,
                participant: String?, instance: Int,
                processType: MosGorSudProcessType) async throws -> [MosGorSudResult] {
        searchRequests += 1
        return []
    }

    func fetchCard(url: URL) async throws -> MosGorSudCard {
        throw URLError(.unsupportedURL)
    }

    func searchCount() -> Int { searchRequests }
}

private actor MoscowRefreshVSRFStub: VSRFProviding {
    private(set) var searchRequests = 0

    func search(uniqueNumber: String?, oldCaseNumber: String?,
                keywords: String?) async throws -> VSRFSearchResults {
        searchRequests += 1
        return VSRFSearchResults(total: 0, results: [])
    }

    func fetchCard(productionID: String, section: VSRFCardSection) async throws -> VSRFCard {
        throw URLError(.unsupportedURL)
    }

    func searchCount() -> Int { searchRequests }
}

private final class MoscowUnitRefreshURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var html = ""
    nonisolated(unsafe) private static var requests: [URL] = []

    static func configure(card: String) {
        lock.lock()
        html = card
        requests = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        html = ""
        requests = []
        lock.unlock()
    }

    static func cardRequests() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter {
            $0.host == "mos-sud.ru" && $0.path.contains("/cases/admin/details/")
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.lowercased() == "mos-sud.ru"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.lock()
        Self.requests.append(url)
        let body = Self.html
        Self.lock.unlock()
        guard url.path.contains("/cases/admin/details/"), !body.isEmpty,
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class MoscowFederalBlockerURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [URL] = []

    static func reset() {
        lock.lock()
        captured = []
        lock.unlock()
    }

    static func requests() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            Self.lock.lock()
            Self.captured.append(url)
            Self.lock.unlock()
        }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}
