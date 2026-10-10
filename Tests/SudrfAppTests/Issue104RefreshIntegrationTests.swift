import Foundation
import Synchronization
import XCTest
@testable import SudrfKit
@testable import SudrfApp

private final class Issue104VSRFURLProtocol: URLProtocol {
    private struct State {
        var search = Data()
        var card = Data()
        var urls: [URL] = []
    }
    private static let state = Mutex(State())

    static func install(search: Data, card: Data) {
        state.withLock { $0 = State(search: search, card: card) }
    }
    static func requests() -> [URL] { state.withLock { $0.urls } }
    static func reset() { state.withLock { $0 = State() } }
    static func partialSearch() {
        state.withLock {
            $0.search = Data("<div class=\"SearchPage_resultsBlock__qDIxx\"><span>Найдено: 1</span></div>".utf8)
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, request.httpMethod == "GET",
              url.scheme == "https" else {
            XCTFail("Unexpected request in #104 offline profile")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let searchURL = VSRFEndpoint.searchURL(oldCaseNumber: "2-1/2026")!
        let cardURL = VSRFEndpoint.cardURL(productionID: "21-00000001", section: .claims)!
        let data: Data? = Self.state.withLock {
            if url == searchURL { $0.urls.append(url); return $0.search }
            if url == cardURL, $0.urls.last == searchURL {
                $0.urls.append(url); return $0.card
            }
            return nil
        }
        guard let data else {
            XCTFail("Unexpected URL or request order in #104 offline profile")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct Issue104LowerCards: CaseProviding {
    static let rootURL = URL(string: "https://test--region.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=root&case_uid=root-guid&delo_id=1540005&new=0")!
    static let remandURL = URL(string: "https://test--region.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=appeal&case_uid=appeal-guid&delo_id=1540005&new=0")!
    static let activeURL = URL(string: "https://test--region.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=active&case_uid=active-guid&delo_id=1540005&new=0")!

    func search(court: Court, cartoteka: Cartoteka, field: SearchField,
                value: String) async throws -> [CaseSearchResult] {
        XCTFail("Unexpected lower-court search in #104 fixture profile")
        throw URLError(.unsupportedURL)
    }
    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        let url = [Self.rootURL, Self.remandURL, Self.activeURL].first {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.contains {
                $0.name == "case_id" && $0.value == caseID
            } == true
        }
        return try await fetchCard(url: XCTUnwrap(url))
    }
    func fetchCard(url: URL) async throws -> CaseCard {
        let number: String
        let date: String
        let event: String
        switch url {
        case Self.rootURL: (number, date, event) = ("2-1/2026", "01.01.2026", "Решение вынесено")
        case Self.remandURL:
            (number, date, event) = ("33-1/2026", "01.01.2026", "Решение отменено с направлением дела на новое рассмотрение в суд первой инстанции")
        case Self.activeURL: (number, date, event) = ("2-2/2026", "15.01.2026", "Дело принято к производству")
        default:
            XCTFail("Unexpected lower-court card in #104 fixture profile")
            throw URLError(.unsupportedURL)
        }
        let html = """
        <html><body><h2>ДЕЛО № \(number)</h2>
        <table><tr><td>Вид лица</td><td>Лицо, участвующее в деле</td></tr>
        <tr><td>ИСТЕЦ</td><td>Тестовый получатель</td></tr></table>
        <table><tr><th colspan="3">ДВИЖЕНИЕ ДЕЛА</th></tr><tr><td>Наименование события</td><td>Дата</td><td>Результат события</td></tr>
        <tr><td>\(event)</td><td>\(date)</td><td>\(url == Self.remandURL ? event : "")</td></tr></table>
        </body></html>
        """
        return try CaseCardParser.parse(html: html, cardURL: url)
    }
}

@MainActor
final class Issue104RefreshIntegrationTests: XCTestCase {
    private struct State: Equatable {
        let key: String
        let logicalID: UUID?
        let addedAt: Date
        let seenAt: Date?
        let collections: [String]
        let movement: CaseMovement?
        let journal: CaseEventJournal?
        init(_ record: TrackedCaseRecord) {
            key = record.key; logicalID = record.logicalCaseID
            addedAt = record.addedAt; seenAt = record.seenAt
            collections = record.collectionNames.sorted()
            movement = record.movement; journal = record.eventJournal
        }
    }

    func testDiscoveredComplaintRefreshPersistsRepeatsAndKeepsActiveRemandRound() async throws {
        func fixture(_ name: String) throws -> Data {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../SudrfKitTests/Fixtures/\(name).html")
            return try Data(contentsOf: url)
        }
        Issue104VSRFURLProtocol.install(search: try fixture("vsrf_current_search_row_parties"),
                                        card: try fixture("vsrf_current_complaint_disposition"))
        defer { Issue104VSRFURLProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Issue104VSRFURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let vsrf = VSRFClient(session: session, minInterval: 0)
        let lower = Issue104LowerCards()
        let evidenceRoot = ProcessInfo.processInfo.environment["SUDRF_104_EVIDENCE_DIRECTORY"]
            .map { URL(fileURLWithPath: $0) }
        let directory = (evidenceRoot ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("issue104-refresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            if evidenceRoot == nil { try? FileManager.default.removeItem(at: directory) }
        }
        let storeURL = directory.appendingPathComponent("fixture.store")
        let context = MovementContext(branchRaw: "general", region: "Тестовый регион",
            searchDomain: "test--region.sudrf.ru", displayDomain: "test--region.sudrf.ru",
            courtTitle: "Тестовый городской суд", courtLevelRaw: CourtLevel.district.rawValue,
            cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-1/2026", caseID: "root", caseUID: "root-guid",
            cardURLString: Issue104LowerCards.rootURL.absoluteString,
            higherCourtTargets: [])
        let seedInstances = [
            CaseInstance(level: .first, court: context.courtTitle, caseNumber: "2-1/2026",
                judge: nil, domain: context.searchDomain, foundByUID: false, result: nil,
                sessions: [], actID: "issue104-lower-act", sourceURL: Issue104LowerCards.rootURL),
            CaseInstance(level: .appeal, court: "Тестовый областной суд", caseNumber: "33-1/2026",
                judge: nil, domain: context.searchDomain, foundByUID: false,
                result: "Решение отменено с направлением дела на новое рассмотрение в суд первой инстанции",
                sessions: [CaseSession(date: "01.01.2026", event: "Судебное заседание",
                    result: "Решение отменено с направлением дела на новое рассмотрение в суд первой инстанции")],
                sourceURL: Issue104LowerCards.remandURL),
            CaseInstance(level: .first, court: context.courtTitle, caseNumber: "2-2/2026",
                judge: nil, domain: context.searchDomain, foundByUID: false, result: nil,
                sessions: [CaseSession(date: "15.01.2026", event: "Дело принято к производству")],
                sourceURL: Issue104LowerCards.activeURL)
        ]
        let seedEvent = CaseEvent.make(kind: .complaintRegistered, occurrence: ["issue104-user-event"],
                                      observedAt: Date(timeIntervalSince1970: 1), evidence: .init())
        let expected: State
        do {
            let store = try TrackedStore(container: SudrfModelContainerFactory.make(
                inMemory: false, storeURL: storeURL), prepared: true)
            let movement = CaseMovement(uid: "", caseNumber: context.caseNumber, inForce: false,
                                       instances: seedInstances, complaints: [:],
                                       acts: [CaseAct(id: "issue104-lower-act", title: "Решение",
                                           date: "01.01.2026", courtShort: "1-я инстанция",
                                           instanceLevel: .first)],
                                       actBodies: ["issue104-lower-act": "Синтетический сохранённый нижний акт."])
            let record = try store.upsert(context: context, snapshot: nil, movement: movement,
                                         collections: ["Пользовательская"])
            record.addedAt = Date(timeIntervalSince1970: 100)
            record.seenAt = Date(timeIntervalSince1970: 200)
            record.eventJournal = CaseEventJournal(events: [seedEvent])
            try store.save()
            XCTAssertFalse(record.movement!.instances.contains { $0.level == .vsCassation })
            let seededKey = record.key
            let seededLogicalID = record.logicalCaseID
            let seededSeenAt = record.seenAt
            let center = makeCenter(store: store, lower: lower, vsrf: vsrf)
            let outcome = await center.refresh(key: record.key, manually: true)?.value
            XCTAssertEqual(outcome?.outcome, .refreshed)
            XCTAssertEqual(record.key, seededKey)
            XCTAssertEqual(record.logicalCaseID, seededLogicalID)
            XCTAssertEqual(seededSeenAt, Date(timeIntervalSince1970: 200))
            // New official movement is correctly marked unseen on first refresh.
            XCTAssertNil(record.seenAt)
            XCTAssertEqual(store.all().count, 1)
            try assertDiscovered(record, seedEvent: seedEvent)
            expected = State(record)
        }
        do {
            let store = try TrackedStore(container: SudrfModelContainerFactory.make(
                inMemory: false, storeURL: storeURL), prepared: true)
            let record = try XCTUnwrap(store.record(forKey: context.key))
            XCTAssertEqual(State(record), expected)
            XCTAssertEqual(store.all().count, 1)
            let center = makeCenter(store: store, lower: lower, vsrf: vsrf)
            let repeated = await center.refresh(key: record.key, manually: true)?.value
            XCTAssertEqual(repeated?.outcome, .refreshed)
            XCTAssertEqual(State(record), expected)
            XCTAssertEqual(store.all().count, 1)
            try assertDiscovered(record, seedEvent: seedEvent)
            Issue104VSRFURLProtocol.partialSearch()
            let partial = await center.refresh(key: record.key, manually: true)?.value
            guard case .partial = partial?.outcome else {
                return XCTFail("Incomplete VSRF source must remain partial")
            }
            XCTAssertEqual(record.movement?.instances.filter { $0.level == .vsCassation },
                           expected.movement?.instances.filter { $0.level == .vsCassation })
            XCTAssertEqual(record.eventJournal, expected.journal)
            XCTAssertEqual(record.key, expected.key)
            XCTAssertEqual(record.logicalCaseID, expected.logicalID)
            XCTAssertEqual(record.addedAt, expected.addedAt)
            XCTAssertEqual(record.seenAt, expected.seenAt)
            XCTAssertEqual(record.collectionNames.sorted(), expected.collections)
            XCTAssertEqual(record.movement?.actBodies, expected.movement?.actBodies)
        }
        if let evidenceRoot {
            let evidence: [String: String] = ["storePath": storeURL.path, "recordKey": context.key,
                                            "state": "partial-source-preserved"]
            try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
                .write(to: evidenceRoot.appendingPathComponent("persisted-store.json"), options: .atomic)
        }
        let requests = Issue104VSRFURLProtocol.requests()
        XCTAssertEqual(requests, [VSRFEndpoint.searchURL(oldCaseNumber: "2-1/2026")!,
                                 VSRFEndpoint.cardURL(productionID: "21-00000001", section: .claims)!,
                                 VSRFEndpoint.searchURL(oldCaseNumber: "2-1/2026")!,
                                 VSRFEndpoint.cardURL(productionID: "21-00000001", section: .claims)!,
                                 VSRFEndpoint.searchURL(oldCaseNumber: "2-1/2026")!])
    }

    private func makeCenter(store: TrackedStore, lower: Issue104LowerCards,
                            vsrf: VSRFClient) -> RefreshCenter {
        RefreshCenter(store: store, client: TestNetworkGuard.sudrfClient(),
            captchaTokenStore: CaptchaTokenStore(), serviceBuilder: { context in
                MovementService(client: lower, higherCourtDomains: [],
                    higherCourtTargets: context.higherCourtTargets, knownCards: context.knownCards ?? [],
                    baseInstanceLevel: context.baseInstanceLevel, vsrf: vsrf,
                    judicialUID: context.judicialUID, branch: context.branch,
                    transferCourts: { _ in
                        XCTFail("Unexpected transfer directory request in #104 offline profile")
                        throw URLError(.unsupportedURL)
                    })
            }, treasuryDiscover: { _, _, _ in throw URLError(.unsupportedURL) },
            vsrfProvider: vsrf, fsspAutoModelEnabled: false,
            fsspDiscover: { _ in throw URLError(.unsupportedURL) })
    }

    private func assertDiscovered(_ record: TrackedCaseRecord, seedEvent: CaseEvent) throws {
        let movement = try XCTUnwrap(record.movement)
        let instances = movement.instances.filter { $0.level == .vsCassation }
        XCTAssertEqual(instances.count, 1)
        let instance = try XCTUnwrap(instances.first)
        XCTAssertEqual(instance.caseNumber, "3-КФ26-1-К1")
        let locator = try XCTUnwrap(SourceNativeCardLocator.vsrf(url: try XCTUnwrap(instance.sourceURL)))
        XCTAssertEqual(locator.sourceNativeID, "21-00000001")
        XCTAssertEqual(locator.identity.cartotekaKey, "claims")
        XCTAssertEqual(instance.sourceURL, VSRFEndpoint.cardURL(productionID: "21-00000001", section: .claims))
        XCTAssertEqual(instance.result, "Отказано в передаче жалобы для рассмотрения")
        XCTAssertTrue(instance.sessions.contains { $0.date == "02.01.2026" && $0.event == "Поступило в ВС РФ" })
        XCTAssertTrue(instance.sessions.contains { $0.date == "03.02.2026" })
        XCTAssertEqual(movement.acts.map(\.id), ["issue104-lower-act"])
        XCTAssertEqual(movement.actBodies["issue104-lower-act"], "Синтетический сохранённый нижний акт.")
        XCTAssertTrue(movement.acts.filter { $0.instanceLevel == .vsCassation }.isEmpty)
        XCTAssertTrue(record.eventJournal?.events.contains(seedEvent) == true)
        XCTAssertEqual(record.collectionNames, ["Пользовательская"])
        XCTAssertEqual(record.addedAt, Date(timeIntervalSince1970: 100))
        let lifecycle = CaseLifecycleResolver.resolve(movement: movement, production: .civil,
            deadlines: [], today: try XCTUnwrap(DateUtil.parse("04.02.2026")))
        XCTAssertEqual(lifecycle.stage, .first)
        XCTAssertEqual(lifecycle.currentInstance?.caseNumber, "2-2/2026")
        XCTAssertNil(lifecycle.completionReason)
    }
}
