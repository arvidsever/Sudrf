import XCTest
import SwiftData
@testable import SudrfKit
@testable import SudrfApp

private final class Issue350CardProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              parts.first(where: { $0.name == "name_op" })?.value == "case",
              let id = parts.first(where: { $0.name == "case_id" })?.value,
              let expectedDelo = ["3501": "4", "3502": "2450001", "3503": "5",
                                  "3504": "2800001", "3599": "4"][id],
              parts.first(where: { $0.name == "delo_id" })?.value == expectedDelo,
              parts.first(where: { $0.name == "new" })?.value == "0",
              SudrfHost.moduleHost(url.host ?? "") == (id == "3599" ? "vs--komi.sudrf.ru" : "1zovs--spb.sudrf.ru") else {
            XCTFail("Unexpected request outside the four synthetic source cards")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        // Synthetic source-shaped card. Its number is not evidence for historical auto-selection.
        let html = """
        <html><head><meta charset="utf-8"></head><body>
        <div class="casenumber">ДЕЛО № 22-350/2011</div>
        <table id="tablcont"><tr><td>Дата поступления</td><td>01.02.2011</td></tr>
        <tr><td>Результат рассмотрения</td><td>Рассмотрено</td></tr></table>
        </body></html>
        """
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor Issue350CachedOriginResolver: CaseOriginResolving {
    private var cards: [CaseCard] = []
    func resolve(anchorContext: MovementContext, anchorCard: CaseCard) async throws -> ResolvedCaseOrigin {
        cards.append(anchorCard)
        throw CaseOriginResolutionError.noReference
    }
    func captured() -> [CaseCard] { cards }
}

@MainActor
final class MilitaryHistoricalIdentityTests: XCTestCase {
    func testTransientHistoricalAnchorUsesExactCachedEvidence() async throws {
        let suite = "issue350.cached.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TrackedStore(inMemory: true, projectionSynchronizer: { _, _ in })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Issue350CardProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let client = SudrfClient(session: URLSession(configuration: configuration), minInterval: 0,
            variantStore: WorkingVariantStore(cacheURL: nil), captchaStore: CaptchaTokenStore())
        let direct = DirectCaseLinkResolver(fetchCard: { try await client.fetchCardWithResponseURL(url: $0) },
            districtCourts: { _ in XCTFail("Directory unused"); return [] })
        // Existing repair admission covers appeal/cassation, not supervisory anchors.
        for (index, delo) in [(0, "4"), (2, "5")] {
            let url = try XCTUnwrap(URL(string: "https://1zovs.spb.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=\(3501 + index)&case_uid=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa\(index)&delo_id=\(delo)&new=0&srv_num=1"))
            let context = try await direct.resolve(url.absoluteString).context
            let lower = LowerCourtReference(courtTitle: "Тестовый гарнизонный военный суд", caseNumber: "2-350/2011")
            var instance = CaseInstance(level: context.baseInstanceLevel, court: context.courtTitle,
                caseNumber: context.caseNumber, judge: nil, domain: context.searchDomain,
                foundByUID: false, result: nil, sessions: [], sourceURL: url)
            instance.sourceEvidence = CaseInstance.SourceEvidence(lowerCourt: lower,
                cartotekaID: context.cartotekaId, sourceCourtLevel: .subject, sourceBranch: .military)
            let movement = CaseMovement(uid: "", caseNumber: context.caseNumber, inForce: false,
                instances: [instance], complaints: [:], acts: [])
            let record = try store.upsert(context: context, snapshot: nil, movement: movement, collections: [])
            let origin = Issue350CachedOriginResolver()
            var fetches = 0
            let coordinator = TrackedCaseRepairCoordinator(store: store, client: client,
                originResolver: origin, defaults: defaults, anchorCardFetcher: { _ in
                    fetches += 1
                    throw SudrfError.http(status: 503)
                })
            _ = try await coordinator.run(keys: [record.key])
            let cards = await origin.captured()
            XCTAssertEqual(fetches, 1)
            XCTAssertEqual(cards.count, 1, "Exact historical cached anchor must reach origin validation")
            XCTAssertEqual(cards.first?.lowerCourt, lower)
            XCTAssertEqual(store.record(forKey: record.key)?.context?.cartotekaId, context.cartotekaId)
        }
    }

    func testMixedKnownCardsUseTheirOwnProvenCourtBranch() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Issue350CardProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let client = SudrfClient(session: URLSession(configuration: configuration), minInterval: 0,
                                 variantStore: WorkingVariantStore(cacheURL: nil), captchaStore: CaptchaTokenStore())
        let service = MovementService(client: client, branch: .military,
            transferCourts: { _ in XCTFail("Transfer directory unused"); return [] })
        for (host, id, title, expected, level) in [
            ("1zovs.spb.sudrf.ru", "3501", "1-й Западный окружной военный суд", "u3_old", CaseInstance.Level.cassation),
            ("vs.komi.sudrf.ru", "3599", "Верховный Суд Республики Коми", "u2", .appeal)] {
            let source = try XCTUnwrap(URL(string: "https://\(host)/modules.php?name=sud_delo&name_op=case"
                + "&case_id=\(id)&case_uid=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb&delo_id=4&new=0&srv_num=1"))
            let card = KnownCard(domain: host, courtTitle: title, caseID: id,
                caseUID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", deloID: "4", new: "0",
                caseNumber: "22-350/2011", levelRaw: level.rawValue, sourceURL: source)
            let loaded = try await service.instanceFromKnownCard(card)
            XCTAssertEqual(loaded.inst.sourceEvidence?.cartotekaID, expected)
            XCTAssertEqual(loaded.inst.sourceURL, try SudrfCaseCardLink(url: source).sanitizedURL)
            XCTAssertEqual(loaded.inst.level, level)
        }
    }

    func testFourHistoricalSourceCardsRetainNativeIdentityThroughDiskReopenAndRepeat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("issue350-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "issue350.\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let storeURL = directory.appendingPathComponent("fixture.store")
        let loader = PersistentStoreBootstrapper(recoveryRoot: directory.appendingPathComponent("backups"))
        let container = try await loader.prepareProduction(storeURL: storeURL, defaultsSuiteName: suite)
        let store = try TrackedStore(container: container, prepared: true, projectionSynchronizer: { _, _ in })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Issue350CardProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let client = SudrfClient(session: URLSession(configuration: configuration), minInterval: 0,
                                 variantStore: WorkingVariantStore(cacheURL: nil), captchaStore: CaptchaTokenStore())
        let resolver = DirectCaseLinkResolver(fetchCard: { try await client.fetchCardWithResponseURL(url: $0) },
            districtCourts: { _ in XCTFail("Directory fetch not needed for known OVS host"); return [] })
        let sources: [(String, String, CaseInstance.Level)] = [
            ("4", "u3_old", .cassation), ("2450001", "u_supervisory_old", .supervisory),
            ("5", "g3_old", .cassation), ("2800001", "g_supervisory_old", .supervisory)]
        var expectedKeys: [String] = []
        for (index, source) in sources.enumerated() {
            let input = try XCTUnwrap(URL(string: "https://1zovs.spb.sudrf.ru/modules.php?name=sud_delo"
                + "&name_op=case&case_id=\(3501 + index)&case_uid=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa\(index)"
                + "&delo_id=\(source.0)&new=0&srv_num=1"))
            let result = try await resolver.resolve(input.absoluteString)
            let context = result.context
            XCTAssertEqual(context.branch, .military)
            XCTAssertEqual(context.courtLevel, .subject)
            XCTAssertEqual(context.cartotekaId, source.1)
            XCTAssertEqual(context.baseInstanceLevel, source.2)
            XCTAssertEqual(context.cardURLString, try SudrfCaseCardLink(url: input).url.absoluteString)
            let encoded = try JSONEncoder().encode(context)
            XCTAssertEqual(try JSONDecoder().decode(MovementContext.self, from: encoded), context)
            let catalog = try XCTUnwrap(context.cartoteka)
            let domains = context.expandedHigherDomains()
            XCTAssertTrue(domains.isEmpty, "Historical source must not invent a modern AV/KV route")
            let movement = try await MovementService(client: client, higherCourtDomains: domains,
                knownCards: context.knownCards ?? [], baseInstanceLevel: context.baseInstanceLevel,
                branch: context.branch, transferCourts: { _ in XCTFail("Transfer directory unused"); return [] })
                .movement(for: context.baseResult, court: context.searchCourt, cartoteka: catalog)
            let own = try XCTUnwrap(movement.instances.first)
            XCTAssertEqual(own.level, source.2)
            XCTAssertEqual(own.sourceURL?.absoluteString, context.cardURLString)
            XCTAssertEqual(own.sourceEvidence?.cartotekaID, source.1)
            XCTAssertEqual(MovementDerivation.courtTier(for: own, context: context), .subject)
            let key = "issue350-\(index)"
            expectedKeys.append(key)
            let record = TrackedCaseRecord(key: key, collections: ["QA350"],
                caseNumber: context.caseNumber, courtTitle: context.courtTitle,
                displayDomain: context.displayDomain, contextData: encoded, snapshotData: nil)
            record.movement = movement
            record.movementFetchedAt = Date()
            store.container.mainContext.insert(record)
        }
        try store.save()
        let reopenedContainer = try await loader.prepareProduction(storeURL: storeURL, defaultsSuiteName: suite)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true,
                                       projectionSynchronizer: { _, _ in })
        XCTAssertEqual(Set(reopened.all().map(\.key)), Set(expectedKeys))
        for record in reopened.all() {
            let context = try XCTUnwrap(record.context)
            let old = try XCTUnwrap(record.movement)
            let catalog = try XCTUnwrap(context.cartoteka)
            let native = try XCTUnwrap(TrackedCaseIdentity.state(for: record).cards.first?.identity)
            XCTAssertEqual(native.cartotekaKey, context.cartotekaId)
            XCTAssertEqual(native.sourceNativeID, context.caseID)
            let repeated = try await MovementService(client: client, higherCourtDomains: [],
                knownCards: context.knownCards ?? [], baseInstanceLevel: context.baseInstanceLevel,
                branch: context.branch, transferCourts: { _ in XCTFail("Transfer directory unused"); return [] })
                .movement(for: context.baseResult, court: context.searchCourt, cartoteka: catalog)
            XCTAssertEqual(repeated.instances.map(\.id), old.instances.map(\.id))
            XCTAssertEqual(repeated.instances.map(\.sourceURL), old.instances.map(\.sourceURL))
            XCTAssertEqual(repeated.instances.map(\.level), old.instances.map(\.level))
            record.movement = repeated
        }
        try reopened.save()
        XCTAssertEqual(reopened.all().count, 4)
    }
}
