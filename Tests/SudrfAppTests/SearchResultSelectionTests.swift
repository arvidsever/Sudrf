import XCTest
@testable import SudrfKit
@testable import SudrfApp
@testable import CaptchaSolver

final class SearchResultSelectionTests: XCTestCase {
    func testStableIDPrefersCardURLAndFallbackIsNonEmpty() throws {
        let url = try XCTUnwrap(URL(string: "https://example.test/modules.php?case_id=1"))
        let withURL = CaseSearchResult(caseNumber: "2-1/2026", cardURL: url)
        XCTAssertEqual(withURL.stableID, "url:\(url.absoluteString)")

        let fallback = CaseSearchResult(caseNumber: "2-2/2026",
                                        receiptDate: "01.02.2026",
                                        judge: "Иванов И. И.",
                                        result: "Решение")
        XCTAssertFalse(fallback.stableID.isEmpty)
    }

    @MainActor
    func testSelectedResultUsesStableIDAndClearsWhenRowsDisappear() throws {
        let model = SearchModel()
        let url = try XCTUnwrap(URL(string: "https://example.test/card?id=1"))
        let row = CaseSearchResult(caseNumber: "2-1/2026", cardURL: url)

        model.results = [row]
        model.selectedResultIndex = 0

        XCTAssertEqual(model.selectedResultID, row.stableID)
        XCTAssertEqual(model.selectedResult?.caseNumber, "2-1/2026")

        model.results = []

        XCTAssertNil(model.selectedResult)
        XCTAssertNil(model.selectedResultIndex)
    }

    @MainActor
    func testSharedSearchFilteringAndStatusPreservePrimaryFieldBehavior() {
        let matching = CaseSearchResult(caseNumber: "2-1/2026", essence: "Иванов Иван")
        let wrongNumber = CaseSearchResult(caseNumber: "2-2/2026", essence: "Иванов Иван")
        let wrongName = CaseSearchResult(caseNumber: "2-1/2026", essence: "Петров Пётр")
        let rows = [matching, wrongNumber, wrongName]

        let uidSearch = SearchModel.filteredSearchResults(
            rows, primary: .uid, caseNumber: "2-1", name: "иванов"
        )
        XCTAssertEqual(uidSearch.map(\.caseNumber), ["2-1/2026"],
                       "оба вторичных фильтра применяются к выдаче поиска по УИД")

        let magistrateNameSearch = SearchModel.filteredSearchResults(
            rows, primary: .name, caseNumber: "2-1", name: "иванов"
        )
        XCTAssertEqual(magistrateNameSearch.map { $0.essence ?? "" },
                       ["Иванов Иван", "Петров Пётр"],
                       "для мирового участка номер остаётся вторичным фильтром, а ФИО — первичным")

        let caseNumberSearch = SearchModel.filteredSearchResults(
            rows, primary: .caseNumber, caseNumber: "2-1", name: "иванов"
        )
        XCTAssertEqual(caseNumberSearch.map(\.caseNumber), ["2-1/2026", "2-2/2026"],
                       "первичное поле не фильтруется повторно локально")
        XCTAssertEqual(SearchModel.searchStatus(for: uidSearch, used: ["№ дела", "ФИО", "УИД"]),
                       "Найдено: 1 (№ дела + ФИО + УИД)")
        XCTAssertEqual(SearchModel.searchStatus(for: [], used: ["ФИО"]),
                       "Ничего не найдено (учтите ограничения публикации по 262-ФЗ).")
    }

    @MainActor
    func testMissingPublishedActNeverUsesCardRawText() {
        let ordinaryCard = CaseCard(rawText: "Метаданные обычной карточки", actText: nil)
        let magistrateCard = CaseCard(rawText: "Метаданные мирового участка", actText: "  \n")
        let publishedCard = CaseCard(rawText: "Метаданные карточки", actText: "Текст решения")

        XCTAssertNil(SearchModel.publishedActText(from: ordinaryCard))
        XCTAssertNil(SearchModel.publishedActText(from: magistrateCard))
        XCTAssertEqual(SearchModel.publishedActText(from: publishedCard), "Текст решения")
    }

    @MainActor
    func testMosGorSudPreviewUsesOnlyPublishedActLinks() async throws {
        let cardURL = try XCTUnwrap(URL(string: "https://mos-gorsud.ru/rs/tverskoj/details/1"))
        let actURL = try XCTUnwrap(URL(string: "https://mos-gorsud.ru/rs/tverskoj/cases/docs/content/1"))
        let row = CaseSearchResult(caseNumber: "02-1/2026", cardURL: cardURL)
        let court = SearchModel.CourtOption(domain: MosGorSudEndpoint.host,
                                             title: "Тверской районный суд",
                                             level: .district,
                                             code: "77RS0001")

        let withAct = SearchModel(
            mosGorSudClient: SearchMosGorSudStub(
                card: MosGorSudCard(caseNumber: row.caseNumber,
                                    actLinks: [actURL],
                                    rawText: "Сводка карточки, не акт")))
        withAct.tier = .district
        withAct.courts = [court]
        withAct.selectedCourtID = court.id
        withAct.cartotekaId = "g1"
        withAct.results = [row]

        await withAct.openCard(row)

        XCTAssertEqual(withAct.actLinks, [actURL])
        XCTAssertTrue(withAct.actText.isEmpty)
        XCTAssertFalse(withAct.actMissing)

        let withoutAct = SearchModel(
            mosGorSudClient: SearchMosGorSudStub(
                card: MosGorSudCard(caseNumber: row.caseNumber,
                                    rawText: "Сводка карточки, не акт")))
        withoutAct.tier = .district
        withoutAct.courts = [court]
        withoutAct.selectedCourtID = court.id
        withoutAct.cartotekaId = "g1"
        withoutAct.results = [row]

        await withoutAct.openCard(row)

        XCTAssertTrue(withoutAct.actLinks.isEmpty)
        XCTAssertTrue(withoutAct.actText.isEmpty)
        XCTAssertTrue(withoutAct.actMissing)
    }

    @MainActor
    func testFailedOrClosedCardClearsStaleActPreview() async throws {
        let cardURL = try XCTUnwrap(URL(string: "https://mos-gorsud.ru/rs/tverskoj/details/1"))
        let actURL = try XCTUnwrap(URL(string: "https://mos-gorsud.ru/rs/tverskoj/cases/docs/content/1"))
        let row = CaseSearchResult(caseNumber: "02-1/2026", cardURL: cardURL)
        let court = SearchModel.CourtOption(domain: MosGorSudEndpoint.host,
                                             title: "Тверской районный суд",
                                             level: .district,
                                             code: "77RS0001")
        let model = SearchModel(mosGorSudClient: SearchMosGorSudStub(card: nil))
        model.tier = .district
        model.courts = [court]
        model.selectedCourtID = court.id
        model.cartotekaId = "g1"
        model.results = [row]
        model.actText = "Текст из прежней карточки"
        model.actLinks = [actURL]
        model.actMissing = true

        await model.openCard(row)

        XCTAssertTrue(model.actText.isEmpty)
        XCTAssertTrue(model.actLinks.isEmpty)
        XCTAssertFalse(model.actMissing)

        model.actLinks = [actURL]
        model.actMissing = true
        model.closeInspector()

        XCTAssertTrue(model.actLinks.isEmpty)
        XCTAssertFalse(model.actMissing)
    }

    @MainActor
    func testDelayedCardLoadCannotOverwriteNewerSelectionOrClosedInspector() async throws {
        let firstCardURL = try XCTUnwrap(URL(string: "https://mos-gorsud.ru/rs/tverskoj/details/1"))
        let secondCardURL = try XCTUnwrap(URL(string: "https://mos-gorsud.ru/rs/tverskoj/details/2"))
        let firstActURL = try XCTUnwrap(URL(string: "https://mos-gorsud.ru/rs/tverskoj/cases/docs/content/1"))
        let secondActURL = try XCTUnwrap(URL(string: "https://mos-gorsud.ru/rs/tverskoj/cases/docs/content/2"))
        let first = CaseSearchResult(caseNumber: "02-1/2026", cardURL: firstCardURL)
        let second = CaseSearchResult(caseNumber: "02-2/2026", cardURL: secondCardURL)
        let court = SearchModel.CourtOption(domain: MosGorSudEndpoint.host,
                                             title: "Тверской районный суд",
                                             level: .district,
                                             code: "77RS0001")
        let client = DelayedSearchMosGorSudStub()
        let model = SearchModel(mosGorSudClient: client)
        model.tier = .district
        model.courts = [court]
        model.selectedCourtID = court.id
        model.cartotekaId = "g1"
        model.results = [first, second]

        let firstLoad = Task { @MainActor in await model.openCard(first) }
        await client.waitUntilFetchStarts(for: firstCardURL)
        let secondLoad = Task { @MainActor in await model.openCard(second) }
        await client.waitUntilFetchStarts(for: secondCardURL)

        await client.resume(firstCardURL,
                            with: MosGorSudCard(caseNumber: first.caseNumber,
                                                actLinks: [firstActURL]))
        await firstLoad.value

        XCTAssertEqual(model.selectedResultID, second.stableID)
        XCTAssertTrue(model.loadingCard)
        XCTAssertTrue(model.actLinks.isEmpty)
        XCTAssertFalse(model.actMissing)

        model.closeInspector()
        await client.resume(secondCardURL,
                            with: MosGorSudCard(caseNumber: second.caseNumber,
                                                actLinks: [secondActURL]))
        await secondLoad.value

        XCTAssertNil(model.selectedResultID)
        XCTAssertFalse(model.loadingCard)
        XCTAssertTrue(model.actLinks.isEmpty)
        XCTAssertFalse(model.actMissing)
    }

    @MainActor
    func testOpeningMovementClearsCardPreviewAndInvalidatesPendingCardLoad() async throws {
        let firstCardURL = try XCTUnwrap(URL(string: "https://mos-gorsud.ru/rs/tverskoj/details/1"))
        let firstActURL = try XCTUnwrap(URL(string: "https://mos-gorsud.ru/rs/tverskoj/cases/docs/content/1"))
        let first = CaseSearchResult(caseNumber: "02-1/2026", cardURL: firstCardURL)
        let second = CaseSearchResult(caseNumber: "02-2/2026",
                                      cardURL: URL(string: "https://mos-gorsud.ru/rs/tverskoj/details/2"))
        let court = SearchModel.CourtOption(domain: MosGorSudEndpoint.host,
                                             title: "Тверской районный суд",
                                             level: .district,
                                             code: "77RS0001")
        let client = DelayedSearchMosGorSudStub()
        let model = SearchModel(mosGorSudClient: client)
        model.tier = .district
        model.courts = [court]
        model.selectedCourtID = court.id
        model.cartotekaId = "g1"
        model.results = [first, second]

        let cacheKey = MovementContext.identityKey(displayDomain: court.domain,
                                                   courtCode: court.code,
                                                   caseNumber: second.caseNumber)
        MovementMemoryCache.shared.put(
            cacheKey,
            CaseMovement(uid: "", caseNumber: second.caseNumber, inForce: false,
                         instances: [], complaints: [:], acts: [])
        )
        defer { MovementMemoryCache.shared.remove(cacheKey) }

        model.selectedResultID = first.stableID
        model.actText = "Текст прежней карточки"
        model.actLinks = [firstActURL]
        model.actMissing = true

        await model.openMovement(second)

        XCTAssertEqual(model.selectedResultID, second.stableID)
        XCTAssertEqual(model.movement?.caseNumber, second.caseNumber)
        XCTAssertFalse(model.loadingCard)
        XCTAssertTrue(model.actText.isEmpty)
        XCTAssertTrue(model.actLinks.isEmpty)
        XCTAssertFalse(model.actMissing)

        model.exitMovement()
        XCTAssertNil(model.movement)
        XCTAssertTrue(model.actLinks.isEmpty)

        let pendingLoad = Task { @MainActor in await model.openCard(first) }
        await client.waitUntilFetchStarts(for: firstCardURL)
        XCTAssertTrue(model.loadingCard)

        await model.openMovement(second)
        model.exitMovement()
        await client.resume(firstCardURL,
                            with: MosGorSudCard(caseNumber: first.caseNumber,
                                                actLinks: [firstActURL]))
        await pendingLoad.value

        XCTAssertEqual(model.selectedResultID, second.stableID)
        XCTAssertFalse(model.loadingCard)
        XCTAssertTrue(model.actText.isEmpty)
        XCTAssertTrue(model.actLinks.isEmpty)
        XCTAssertFalse(model.actMissing)
    }

    @MainActor
    func testActionsIgnoreStaleRows() async throws {
        let model = SearchModel()
        let url = try XCTUnwrap(URL(string: "https://example.test/card?id=stale"))
        let stale = CaseSearchResult(caseNumber: "2-1/2026", cardURL: url)

        model.results = []

        await model.openCard(stale)
        await model.openMovement(stale)

        XCTAssertNil(model.selectedResultID)
        XCTAssertNil(model.selectedResult)
    }

    @MainActor
    func testMagistrateCardFailureKeepsSuccessfulListing() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MagistrateListingAndCardStub.self]
        let client = SudrfClient(session: URLSession(configuration: configuration), minInterval: 0)
        let model = SearchModel(client: client)
        let court = SearchModel.CourtOption(
            domain: "example.msudrf.ru", title: "Судебный участок № 2", level: .magistrate
        )
        model.tier = .magistrate
        model.courts = [court]
        model.selectedCourtID = court.id
        model.cartotekaId = "adm"
        model.queryName = "Новикова"

        await model.runSearch()

        let listed = try XCTUnwrap(model.results.first)
        XCTAssertEqual(listed.caseNumber, "5-10/2026")
        XCTAssertEqual(model.status, "Найдено: 1 (ФИО)")

        await model.openCard(listed)

        XCTAssertEqual(model.results.map(\.caseNumber), ["5-10/2026"])
        XCTAssertEqual(model.selectedResult?.caseNumber, "5-10/2026")
        XCTAssertTrue(model.status.contains("Карточка дела временно недоступна"))
        XCTAssertTrue(model.actText.isEmpty)
    }

    @MainActor
    func testManualCaptchaContinuationResumesOriginalSearch() async throws {
        ManualCaptchaContinuationStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManualCaptchaContinuationStub.self]
        let client = SudrfClient(session: URLSession(configuration: configuration), minInterval: 0)
        let settings = CaptchaSettings.shared
        let wasForceDisabled = settings.forceDisabled
        settings.forceDisabled = true
        defer { settings.forceDisabled = wasForceDisabled }

        let displayHost = "leninsky.orb.sudrf.ru"
        let moduleHost = "leninsky--orb.sudrf.ru"
        await CaptchaTokenStore.shared.invalidate(domain: displayHost)
        defer { Task { await CaptchaTokenStore.shared.invalidate(domain: displayHost) } }

        let model = SearchModel(captchaSettings: settings, client: client)
        let court = SearchModel.CourtOption(
            domain: displayHost,
            title: "Ленинский районный суд г. Оренбурга",
            level: .district
        )
        model.tier = .district
        model.courts = [court]
        model.selectedCourtID = court.id
        model.cartotekaId = "g1"
        model.queryCaseNumber = "2-42/2026"
        model.queryName = "Иванов"

        await model.runSearch()

        let challenge = try XCTUnwrap(model.captcha)
        XCTAssertTrue(challenge.rerunSearch)
        XCTAssertEqual(challenge.formURL.host, moduleHost)
        XCTAssertEqual(model.queryCaseNumber, "2-42/2026")
        XCTAssertEqual(model.queryName, "Иванов")

        let token = CaptchaToken(value: "12345", id: "captcha-id")
        await model.storeCaptchaPair(host: challenge.formURL.host ?? "", token: token).value

        XCTAssertNil(model.captcha)
        XCTAssertEqual(model.selectedCourtID, court.id)
        XCTAssertEqual(model.cartotekaId, "g1")
        XCTAssertEqual(model.queryCaseNumber, "2-42/2026")
        XCTAssertEqual(model.queryName, "Иванов")
        XCTAssertEqual(model.results.map(\.caseNumber), ["2-42/2026"])
        XCTAssertEqual(model.status, "Найдено: 1 (№ дела + ФИО)")
        let storedToken = await CaptchaTokenStore.shared.token(forDomain: displayHost)
        XCTAssertEqual(storedToken, token)

        let resumedRequest = try XCTUnwrap(ManualCaptchaContinuationStub.requests.last)
        XCTAssertEqual(resumedRequest.host, moduleHost)
        let query = try XCTUnwrap(
            URLComponents(url: resumedRequest, resolvingAgainstBaseURL: false)?.queryItems
        )
        XCTAssertEqual(query.first { $0.name == "captcha" }?.value, token.value)
        XCTAssertEqual(query.first { $0.name == "captchaid" }?.value, token.id)
    }

    @MainActor
    func testCaptchaCorpusBootstrapUsesSubmittedTokenAfterStoreOverwrite() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SearchModelCorpusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let corpus = CorpusStore(baseDir: dir)
        let model = SearchModel(corpusStore: corpus)
        let host = "court.sudrf.ru"
        model.lastSubmittedCaptcha = (
            png: Data([0x01]),
            token: CaptchaToken(value: "sent-token", id: "sent-id")
        )
        await CaptchaTokenStore.shared.store(
            CaptchaToken(value: "overwritten-token", id: "new-id"), domain: host
        )
        defer { Task { await CaptchaTokenStore.shared.invalidate(domain: host) } }

        await model.bootstrapCaptchaToCorpus(
            host: host,
            results: [CaseSearchResult(caseNumber: "2-1/2026")]
        )

        let files = try FileManager.default.contentsOfDirectory(
            at: dir.appendingPathComponent("solved-numeric"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].lastPathComponent.hasPrefix("sent-token_"))
        XCTAssertNil(model.lastSubmittedCaptcha)
    }

    @MainActor
    func testCaptchaCorpusBootstrapDoesNotSaveWithoutServerResults() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SearchModelCorpusTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let corpus = CorpusStore(baseDir: dir)
        let model = SearchModel(corpusStore: corpus)
        model.lastSubmittedCaptcha = (
            png: Data([0x01]),
            token: CaptchaToken(value: "12345", id: "sent-id")
        )

        await model.bootstrapCaptchaToCorpus(host: "court.sudrf.ru", results: [])

        let count = await corpus.currentCount(kind: .sudrfToken)
        XCTAssertEqual(count, 0)
        XCTAssertNotNil(model.lastSubmittedCaptcha)
    }
}

private struct SearchMosGorSudStub: MosGorSudProviding {
    let card: MosGorSudCard?

    func search(courtAlias: String?, uid: String?, caseNumber: String?,
                participant: String?, instance: Int,
                processType: MosGorSudProcessType) async throws -> [MosGorSudResult] {
        []
    }

    func fetchCard(url: URL) async throws -> MosGorSudCard {
        guard let card else { throw SearchMosGorSudStubError.unavailable }
        return card
    }
}

private enum SearchMosGorSudStubError: Error, Sendable {
    case unavailable
}

private actor DelayedSearchMosGorSudStub: MosGorSudProviding {
    private var fetchContinuations: [URL: CheckedContinuation<MosGorSudCard, Never>] = [:]
    private var startWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    func search(courtAlias: String?, uid: String?, caseNumber: String?,
                participant: String?, instance: Int,
                processType: MosGorSudProcessType) async -> [MosGorSudResult] {
        []
    }

    func fetchCard(url: URL) async -> MosGorSudCard {
        await withCheckedContinuation { continuation in
            fetchContinuations[url] = continuation
            startWaiters.removeValue(forKey: url)?.forEach { $0.resume() }
        }
    }

    func waitUntilFetchStarts(for url: URL) async {
        guard fetchContinuations[url] == nil else { return }
        await withCheckedContinuation { startWaiters[url, default: []].append($0) }
    }

    func resume(_ url: URL, with card: MosGorSudCard) {
        fetchContinuations.removeValue(forKey: url)?.resume(returning: card)
    }
}

private final class MagistrateListingAndCardStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let operation = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "op" }?.value
        let body: String
        if operation == "cs" {
            body = "<main>Информация временно недоступна. Попробуйте обратиться позже.</main>"
        } else {
            body = """
            <div id="search_results"><div class="case-count">Найдено дел: <b>1</b></div>
              <table><tr><td><a href="/modules.php?name=sud_delo&amp;op=cs&amp;case_id=10&amp;delo_id=1500001">5-10/2026</a></td></tr></table>
            </div>
            """
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ManualCaptchaContinuationStub: URLProtocol {
    nonisolated(unsafe) static var requests: [URL] = []

    static func reset() {
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.requests.append(url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let hasToken = query.contains { $0.name == "captcha" && $0.value == "12345" }
            && query.contains { $0.name == "captchaid" && $0.value == "captcha-id" }
        let body = hasToken
            ? """
              <div id="search_results"><table><tr>
                <td><a href="/modules.php?name=sud_delo&amp;name_op=case&amp;case_id=42&amp;case_uid=uid-42">2-42/2026</a></td>
                <td>01.08.2026</td><td>Иванов</td>
              </tr></table></div>
              """
            : """
              <form><label>Проверочный код</label>
                <input name="captcha"><input type="hidden" name="captchaid" value="captcha-id">
              </form>
              """
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
