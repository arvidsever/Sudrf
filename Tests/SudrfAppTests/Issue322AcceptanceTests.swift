import XCTest
@testable import SudrfKit
@testable import SudrfApp

private struct Issue322FixtureSet {
    let appeal2013: CaseCard
    let appeal4311: CaseCard
    let cassation: CaseCard
    let moscowFirstRow: MosGorSudResult
    let moscowFirst: MosGorSudCard
    let moscowHamovRow: MosGorSudResult
    let moscowAppealRow: MosGorSudResult
    let moscowHamov: MosGorSudCard
    let moscowAppeal: MosGorSudCard
    let appeal2013URL: URL
    let appeal4311URL: URL
    let cassationURL: URL
    let moscowFirstURL: URL
    let moscowHamovURL: URL
    let moscowAppealURL: URL

    static func load() throws -> Issue322FixtureSet {
        func html(_ name: String) throws -> String {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../SudrfKitTests/Fixtures/\(name).html")
                .standardizedFileURL
            return try String(contentsOf: url, encoding: .utf8)
        }
        func url(_ value: String) throws -> URL {
            try XCTUnwrap(URL(string: value))
        }

        let firstRows = try MosGorSudResultsParser.parse(
            html: html("issue322_mgs_search_first"))
        let uidRows = try MosGorSudResultsParser.parse(
            html: html("issue322_mgs_search_uid"))
        let hamovRow = try XCTUnwrap(uidRows.first { $0.caseNumber == "02а-0419/2021" })
        let moscowAppealRow = try XCTUnwrap(uidRows.first { $0.caseNumber == "33а-6088/2021" })
        return Issue322FixtureSet(
            appeal2013: try CaseCardParser.parse(html: html("issue322_asoy_2013")),
            appeal4311: try CaseCardParser.parse(html: html("issue322_asoy_4311")),
            cassation: try CaseCardParser.parse(html: html("issue322_ksoyu_8501")),
            moscowFirstRow: try XCTUnwrap(firstRows.first),
            moscowFirst: try MosGorSudCardParser.parse(html: html("issue322_mgs_first")),
            moscowHamovRow: hamovRow,
            moscowAppealRow: moscowAppealRow,
            moscowHamov: try MosGorSudCardParser.parse(html: html("issue322_mgs_hamov")),
            moscowAppeal: try MosGorSudCardParser.parse(html: html("issue322_mgs_appeal")),
            appeal2013URL: try url("https://1ap.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case&case_id=6724440&case_uid=0cd448a3-5cf2-49bc-99c1-35bf0706c2d5&delo_id=42"),
            appeal4311URL: try url("https://1ap.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case&case_id=6749107&case_uid=6dc098e7-acb0-4b6b-b250-fcbb25479004&delo_id=42"),
            cassationURL: try url("https://2kas.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case&case_id=2723657&case_uid=576e5fae-ee46-434a-99eb-5956562963b0&new=0&delo_id=43"),
            moscowFirstURL: try XCTUnwrap(firstRows.first?.cardURL),
            moscowHamovURL: try XCTUnwrap(hamovRow.cardURL),
            moscowAppealURL: try XCTUnwrap(moscowAppealRow.cardURL))
    }
}

private actor Issue322SudrfStub: CaseProviding {
    private let cassationUID: String
    private let cassationRow: CaseSearchResult
    private var cardsByURL: [URL: CaseCard]
    private var failedURLs = Set<URL>()
    private var failedReads = Set<URL>()
    private(set) var requestedURLs: [URL] = []
    private(set) var searches: [String] = []

    init(fixtures: Issue322FixtureSet) throws {
        cassationUID = try XCTUnwrap(fixtures.cassation.uid)
        cassationRow = CaseSearchResult(
            caseNumber: try XCTUnwrap(fixtures.cassation.caseNumber),
            judge: fixtures.cassation.judge,
            decisionDate: fixtures.cassation.decisionDate,
            result: fixtures.cassation.result,
            caseID: "2723657", caseUID: "576e5fae-ee46-434a-99eb-5956562963b0",
            cardURL: fixtures.cassationURL)
        cardsByURL = [fixtures.appeal2013URL: fixtures.appeal2013,
                      fixtures.appeal4311URL: fixtures.appeal4311,
                      fixtures.cassationURL: fixtures.cassation]
    }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        searches.append("\(court.domain)|\(field)|\(value)")
        guard court.domain == "2kas.sudrf.ru", field == .uid,
              value == cassationUID else { return [] }
        return [cassationRow]
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        guard let card = cardsByURL.first(where: {
            URLComponents(url: $0.key, resolvingAgainstBaseURL: false)?.queryItems?
                .contains { $0.name == "case_id" && $0.value == caseID } == true
        })?.value else { throw SudrfError.http(status: 404) }
        return card
    }

    func fetchCard(url: URL) async throws -> CaseCard {
        requestedURLs.append(url)
        if failedURLs.contains(url) {
            failedReads.insert(url)
            throw SudrfError.http(status: 503)
        }
        guard let card = cardsByURL[url] else { throw SudrfError.http(status: 404) }
        return card
    }

    func cardForRepair(url: URL) async throws -> CaseCard {
        guard let card = cardsByURL[url] else { throw SudrfError.http(status: 404) }
        return card
    }

    func fail(_ urls: Set<URL>) { failedURLs = urls }
    func requestedCardURLs() -> [URL] { requestedURLs }
    func failedCardURLs() -> Set<URL> { failedReads }
    func searchRequests() -> [String] { searches }
}

private actor Issue322MoscowStub: MoscowOriginProviding, MosGorSudProviding {
    private let fixtures: Issue322FixtureSet
    private var failedURLs = Set<URL>()
    private var failedReads = Set<URL>()
    private(set) var requestedURLs: [URL] = []
    private(set) var searches: [String] = []

    init(fixtures: Issue322FixtureSet) { self.fixtures = fixtures }

    func search(courtAlias: String?, uid: String?, caseNumber: String?,
                participant: String?, instance: Int,
                processType: MosGorSudProcessType) async throws -> [MosGorSudResult] {
        searches.append("alias=\(courtAlias ?? "*")|uid=\(uid ?? "")|number=\(caseNumber ?? "")|instance=\(instance)")
        if courtAlias == "mgs", caseNumber == "3а-3696/2020" {
            return [fixtures.moscowFirstRow]
        }
        if courtAlias == "hamovnicheskij", uid == fixtures.moscowHamov.uid {
            return [fixtures.moscowHamovRow]
        }
        if courtAlias == nil, uid == fixtures.moscowHamov.uid,
           instance == MosGorSudInstance.appeal {
            return [fixtures.moscowAppealRow]
        }
        return []
    }

    func fetchCard(url: URL) async throws -> MosGorSudCard {
        requestedURLs.append(url)
        if failedURLs.contains(url) {
            failedReads.insert(url)
            throw SudrfError.http(status: 503)
        }
        if url == fixtures.moscowFirstURL { return fixtures.moscowFirst }
        if url == fixtures.moscowHamovURL { return fixtures.moscowHamov }
        if url == fixtures.moscowAppealURL { return fixtures.moscowAppeal }
        throw SudrfError.http(status: 404)
    }

    func fail(_ urls: Set<URL>) { failedURLs = urls }
    func requestedCardURLs() -> [URL] { requestedURLs }
    func failedCardURLs() -> Set<URL> { failedReads }
    func searchRequests() -> [String] { searches }
}

private actor Issue322MovementProbe {
    private var cached: CaseMovement?
    private var fresh: CaseMovement?

    func recordCached(_ movement: CaseMovement?) { cached = movement }
    func recordFresh(_ movement: CaseMovement) { fresh = movement }
    func snapshot() -> (CaseMovement?, CaseMovement?) { (cached, fresh) }
}

private struct Issue322RecordingMovementProvider: MovementProviding {
    let base: any MovementProviding
    let probe: Issue322MovementProbe

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        let movement = try await self.base.movement(for: base, court: court,
                                                    cartoteka: cartoteka)
        await probe.recordFresh(movement)
        return movement
    }
}

private final class Issue322OfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTFail("Unexpected network request in offline #322 acceptance test: \(request.url?.absoluteString ?? "<missing URL>")")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }

    override func stopLoading() {}
}

@MainActor
final class Issue322AcceptanceTests: XCTestCase {
    private func offlineClient() -> SudrfClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Issue322OfflineURLProtocol.self]
        return SudrfClient(session: URLSession(configuration: configuration), minInterval: 0,
                           variantStore: WorkingVariantStore(cacheURL: nil),
                           captchaStore: CaptchaTokenStore())
    }

    private func appealContext(number: String, id: String, guid: String,
                               url: URL) -> MovementContext {
        var context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "город Москва",
            searchDomain: "1ap.sudrf.ru", displayDomain: "1ap.sudrf.ru",
            courtTitle: "Первый апелляционный суд общей юрисдикции",
            courtLevelRaw: CourtLevel.appeal.rawValue, courtCode: nil,
            cartotekaId: "p2", cartotekaLevelRaw: CourtLevel.appeal.rawValue,
            caseNumber: number, caseID: id, caseUID: guid,
            cardURLString: url.absoluteString)
        context.baseInstanceLevelRaw = CaseInstance.Level.appeal.rawValue
        context.essence = "Воробьёв Виктор Викторович × Совет депутатов муниципального округа Тверской"
        return context
    }

    private func seedMovement(card: CaseCard, context: MovementContext,
                              sourceURL: URL) -> CaseMovement {
        let number = context.caseNumber
        // The excerpted issue fixtures omit act text. Model a previously cached
        // body, but use the same source ID and metadata as the production card
        // builder so refresh tests the real cache-merge contract.
        let actID = "act_\(context.searchDomain)#\(number)"
        let date = card.decisionDate ?? card.receiptDate ?? "—"
        let instance = CaseInstance(
            level: context.baseInstanceLevel, court: context.courtTitle,
            caseNumber: number, judge: card.judge, domain: context.searchDomain,
            foundByUID: false, result: card.result,
            sessions: [CaseSession(date: date, event: "Рассмотрение",
                                   result: card.result)],
            actID: actID, sourceURL: sourceURL)
        let act = CaseAct(id: actID,
                          title: card.acts.first?.label ?? "Судебный акт",
                          date: date, courtShort: context.courtTitle,
                          instanceLevel: context.baseInstanceLevel)
        return CaseMovement(uid: card.uid ?? "", caseNumber: number,
                            inForce: false, instances: [instance], complaints: [:],
                            acts: [act], actBodies: [actID: "Исторический текст \(number)"])
    }

    private func seed(_ context: MovementContext, card: CaseCard, url: URL,
                      collection: String, addedAt: Date,
                      store: TrackedStore) throws -> TrackedCaseRecord {
        let movement = seedMovement(card: card, context: context, sourceURL: url)
        let record = try store.upsert(
            context: context,
            snapshot: MovementDerivation.snapshot(from: movement, context: context),
            movement: movement, collections: ["Москва", collection])
        record.addedAt = addedAt
        record.seenAt = nil
        record.movementFetchedAt = Date(timeIntervalSince1970: 50)
        let event = CaseEvent.make(
            kind: .instanceDiscovered, occurrence: ["issue322", context.caseNumber],
            observedAt: addedAt,
            evidence: CaseEventEvidence(instanceLevelRaw: CaseInstance.Level.appeal.rawValue,
                                        caseNumber: context.caseNumber))
        try store.appendCaseEvents([event], to: record)
        try store.save()
        return record
    }

    private func makeRepair(store: TrackedStore,
                            sudrf: Issue322SudrfStub, moscow: Issue322MoscowStub,
                            defaults: UserDefaults, client: SudrfClient) -> TrackedCaseRepairCoordinator {
        let resolver = CaseOriginResolver(
            client: client,
            districtResolver: DistrictCourtResolver(client: client, cacheURL: nil),
            magistrateResolver: MagistrateCourtResolver(client: client, cacheURL: nil),
            moscowProvider: moscow)
        return TrackedCaseRepairCoordinator(
            store: store, client: client, originResolver: resolver,
            defaults: defaults,
            anchorCardFetcher: { context in
                guard let value = context.cardURLString, let url = URL(string: value) else {
                    throw SudrfError.parsing("missing issue322 fixture URL")
                }
                return try await sudrf.cardForRepair(url: url)
            })
    }

    private func makeCenter(store: TrackedStore, sudrf: Issue322SudrfStub,
                            moscow: Issue322MoscowStub,
                            repair: TrackedCaseRepairCoordinator,
                            client: SudrfClient,
                            probe: Issue322MovementProbe? = nil,
                            afterRepair: ((String, String) -> Void)? = nil) -> RefreshCenter {
        let center = RefreshCenter(
            store: store, client: client,
            serviceBuilder: { context in
                let service = context.makeService(client: sudrf, mosgorsud: moscow)
                guard let probe else { return service }
                return Issue322RecordingMovementProvider(base: service, probe: probe)
            })
        center.repairBeforeRefresh = { key, force in
            let outcome = try await repair.repairIfNeeded(key: key, forceAttempt: force)
            await probe?.recordCached(
                store.record(forLocator: outcome.effectiveKey)?.movement)
            afterRepair?(key, outcome.effectiveKey)
            return outcome.effectiveKey
        }
        return center
    }

    private func persistentStore() throws -> (URL, TrackedStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-322-acceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
        return (url, try TrackedStore(container: container, prepared: true))
    }

    private func isolatedDefaults() throws -> (String, UserDefaults) {
        let name = "issue322-\(UUID().uuidString)"
        return (name, try XCTUnwrap(UserDefaults(suiteName: name)))
    }

    private func assertRetainedActText(_ expectedText: String,
                                       linkedToCaseNumber caseNumber: String,
                                       sourceURL: URL,
                                       in record: TrackedCaseRecord,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        guard let movement = record.movement else {
            return XCTFail("missing movement for retained act", file: file, line: line)
        }
        assertRetainedActText(expectedText, linkedToCaseNumber: caseNumber,
                              sourceURL: sourceURL, in: movement,
                              file: file, line: line)
    }

    private func assertRetainedActText(_ expectedText: String,
                                       linkedToCaseNumber caseNumber: String,
                                       sourceURL: URL,
                                       in movement: CaseMovement,
                                       file: StaticString = #filePath,
                                       line: UInt = #line) {
        let retainedIDs = Set(movement.acts.filter {
            movement.actBodies[$0.id] == expectedText
        }.map(\.id))
        XCTAssertFalse(retainedIDs.isEmpty,
                       "historical act text was lost; acts=\(movement.acts.map(\.id)); bodyIDs=\(movement.actBodies.keys.sorted())",
                       file: file, line: line)
        let source = movement.instances.first {
            $0.caseNumber.contains(caseNumber) && $0.sourceURL == sourceURL
        }
        XCTAssertNotNil(source, "missing source instance for retained act",
                        file: file, line: line)
        XCTAssertTrue(source?.linkedActIDs.contains(where: retainedIDs.contains) == true,
                      "historical text is no longer linked to its source instance",
                      file: file, line: line)
    }

    func testTwoAppealsRepairThroughRefreshAndRetainHistoryAcrossPartialFailureAndReopen() async throws {
        let fixtures = try Issue322FixtureSet.load()
        let (storeURL, store) = try persistentStore()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let (suiteName, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = offlineClient()

        let first = try seed(
            appealContext(number: "66а-2013/2020", id: "6724440",
                          guid: "0cd448a3-5cf2-49bc-99c1-35bf0706c2d5",
                          url: fixtures.appeal2013URL),
            card: fixtures.appeal2013, url: fixtures.appeal2013URL,
            collection: "Частная жалоба", addedAt: Date(timeIntervalSince1970: 100),
            store: store)
        let second = try seed(
            appealContext(number: "66а-4311/2020", id: "6749107",
                          guid: "6dc098e7-acb0-4b6b-b250-fcbb25479004",
                          url: fixtures.appeal4311URL),
            card: fixtures.appeal4311, url: fixtures.appeal4311URL,
            collection: "Апелляция", addedAt: Date(timeIntervalSince1970: 200),
            store: store)
        XCTAssertEqual(store.all().count, 2)
        XCTAssertTrue(store.all().allSatisfy { $0.context?.searchDomain == "1ap.sudrf.ru" },
                       "the Moscow first-instance record must not be pre-added")

        let sudrf = try Issue322SudrfStub(fixtures: fixtures)
        let moscow = Issue322MoscowStub(fixtures: fixtures)
        let probe = Issue322MovementProbe()
        let repair = makeRepair(store: store, sudrf: sudrf,
                                moscow: moscow, defaults: defaults, client: client)
        let center = makeCenter(store: store, sudrf: sudrf, moscow: moscow,
                                repair: repair, client: client, probe: probe,
                                afterRepair: { requestedKey, effectiveKey in
            guard let record = store.record(forLocator: effectiveKey) else {
                return XCTFail("repair did not leave a readable tracked record")
            }
            self.assertRetainedActText("Исторический текст 66а-2013/2020",
                                  linkedToCaseNumber: "66а-2013/2020",
                                  sourceURL: fixtures.appeal2013URL, in: record)
            if requestedKey == second.key || store.all().count == 1 {
                self.assertRetainedActText("Исторический текст 66а-4311/2020",
                                      linkedToCaseNumber: "66а-4311/2020",
                                      sourceURL: fixtures.appeal4311URL, in: record)
            }
        })

        for key in [first.key, second.key] {
            let task = try XCTUnwrap(center.refresh(key: key))
            let execution = await task.value
            guard case .partial = execution.outcome else {
                return XCTFail("ordinary refresh must keep the chain while reporting verified empty listings")
            }
            let (cached, fresh) = await probe.snapshot()
            if let cached, let fresh {
                let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)
                let numbers = key == first.key
                    ? ["66а-2013/2020"]
                    : ["66а-2013/2020", "66а-4311/2020"]
                for number in numbers {
                    let sourceURL = number == "66а-2013/2020"
                        ? fixtures.appeal2013URL : fixtures.appeal4311URL
                    self.assertRetainedActText("Исторический текст \(number)",
                                                linkedToCaseNumber: number,
                                                sourceURL: sourceURL, in: merged)
                }
            } else {
                XCTFail("refresh probe did not capture both cache and fresh movement")
            }
            let refreshed = try XCTUnwrap(store.record(forKey: execution.effectiveKey))
            let numbers = key == first.key
                ? ["66а-2013/2020"]
                : ["66а-2013/2020", "66а-4311/2020"]
            for number in numbers {
                let sourceURL = number == "66а-2013/2020"
                    ? fixtures.appeal2013URL : fixtures.appeal4311URL
                assertRetainedActText("Исторический текст \(number)",
                                      linkedToCaseNumber: number,
                                      sourceURL: sourceURL, in: refreshed)
            }
        }

        XCTAssertEqual(store.all().count, 1)
        let saved = try XCTUnwrap(store.all().first)
        XCTAssertEqual(saved.caseNumber, "3а-3696/2020")
        XCTAssertEqual(saved.context?.cardURLString, fixtures.moscowFirstURL.absoluteString)
        XCTAssertEqual(Set(saved.collectionNames), ["Москва", "Частная жалоба", "Апелляция"])
        XCTAssertEqual(saved.addedAt, Date(timeIntervalSince1970: 100))
        XCTAssertNil(saved.seenAt)
        let appealCards = saved.context?.knownCards ?? []
        XCTAssertEqual(Set(appealCards.compactMap(\.sourceURL)),
                       [fixtures.appeal2013URL, fixtures.appeal4311URL])
        let originalEventIDs = Set([
            CaseEvent.make(kind: .instanceDiscovered,
                           occurrence: ["issue322", "66а-2013/2020"],
                           observedAt: Date(timeIntervalSince1970: 100),
                           evidence: CaseEventEvidence(
                            instanceLevelRaw: CaseInstance.Level.appeal.rawValue,
                            caseNumber: "66а-2013/2020")).id,
            CaseEvent.make(kind: .instanceDiscovered,
                           occurrence: ["issue322", "66а-4311/2020"],
                           observedAt: Date(timeIntervalSince1970: 200),
                           evidence: CaseEventEvidence(
                            instanceLevelRaw: CaseInstance.Level.appeal.rawValue,
                            caseNumber: "66а-4311/2020")).id
        ])
        let seededJournalIDs = try XCTUnwrap(saved.eventJournal?.events.map(\.id))
        XCTAssertEqual(Set(seededJournalIDs), originalEventIDs)
        XCTAssertEqual(seededJournalIDs.count, Set(seededJournalIDs).count)

        func assertThreeCards(_ record: TrackedCaseRecord, file: StaticString = #filePath,
                              line: UInt = #line) {
            let instances = record.movement?.instances ?? []
            let expected: [(String, URL)] = [
                ("3а-3696/2020", fixtures.moscowFirstURL),
                ("66а-2013/2020", fixtures.appeal2013URL),
                ("66а-4311/2020", fixtures.appeal4311URL)
            ]
            for (number, url) in expected {
                XCTAssertTrue(instances.contains {
                    $0.caseNumber == number && $0.sourceURL == url
                }, "missing \(number) at \(url)", file: file, line: line)
            }
            let matching = instances.filter { instance in
                expected.contains { $0.0 == instance.caseNumber && $0.1 == instance.sourceURL }
            }
            XCTAssertEqual(matching.count, 3, file: file, line: line)
            let expectedURLs = Set(expected.map(\.1))
            XCTAssertEqual(Set(matching.compactMap(\.sourceURL)).intersection(expectedURLs).count,
                           3, file: file, line: line)
            for number in ["66а-2013/2020", "66а-4311/2020"] {
                let sourceURL = number == "66а-2013/2020"
                    ? fixtures.appeal2013URL : fixtures.appeal4311URL
                assertRetainedActText("Исторический текст \(number)",
                                      linkedToCaseNumber: number,
                                      sourceURL: sourceURL, in: record,
                                      file: file, line: line)
            }
        }
        assertThreeCards(saved)
        let firstJournal = try XCTUnwrap(saved.eventJournal?.events.map(\.id))
        XCTAssertEqual(firstJournal.count, Set(firstJournal).count)
        let successfulRefresh = Date(timeIntervalSince1970: 400)
        saved.movementFetchedAt = successfulRefresh
        try store.save()

        await sudrf.fail([fixtures.appeal4311URL])
        let partialTask = try XCTUnwrap(center.refresh(key: saved.key))
        guard case .partial = await partialTask.value.outcome else {
            return XCTFail("one unreadable known appeal must produce a partial refresh")
        }
        let partial = try XCTUnwrap(store.record(forKey: saved.key))
        assertThreeCards(partial)
        XCTAssertEqual(partial.movementFetchedAt, successfulRefresh)
        XCTAssertEqual(partial.sourceRefreshAttempt?.kind, .partial)
        XCTAssertEqual(partial.eventJournal?.events.map(\.id), firstJournal)
        let failedAppealReads = await sudrf.failedCardURLs()
        XCTAssertTrue(failedAppealReads.contains(fixtures.appeal4311URL))
        await sudrf.fail([])

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        let reopenedRepair = makeRepair(store: reopened,
                                        sudrf: sudrf, moscow: moscow, defaults: defaults,
                                        client: client)
        let reopenedCenter = makeCenter(store: reopened, sudrf: sudrf,
                                        moscow: moscow, repair: reopenedRepair, client: client)
        let reopenedRecord = try XCTUnwrap(reopened.all().first)
        let repeatTask = try XCTUnwrap(
            reopenedCenter.refresh(key: reopenedRecord.key))
        let repeatExecution = await repeatTask.value
        guard case .partial = repeatExecution.outcome else {
            return XCTFail("repeat refresh should preserve the known historical-chain state")
        }
        XCTAssertEqual(reopened.record(forKey: reopenedRecord.key)?.movementFetchedAt,
                       successfulRefresh)
        XCTAssertEqual(reopened.all().count, 1)
        let repeated = try XCTUnwrap(reopened.all().first)
        assertThreeCards(repeated)
        XCTAssertEqual(Set(repeated.collectionNames), ["Москва", "Частная жалоба", "Апелляция"])
        XCTAssertEqual(repeated.eventJournal?.events.map(\.id), firstJournal)

        let moscowRequests = await moscow.searchRequests()
        XCTAssertTrue(moscowRequests.contains { $0.contains("alias=mgs") && $0.contains("3а-3696/2020") })
        let sudrfRequests = await sudrf.requestedCardURLs()
        XCTAssertTrue(sudrfRequests.contains(fixtures.appeal2013URL))
        XCTAssertTrue(sudrfRequests.contains(fixtures.appeal4311URL))
    }

    func testKSOYURefreshRestoresBothMoscowCardsWithoutJoiningPositiveControl() async throws {
        let fixtures = try Issue322FixtureSet.load()
        let (storeURL, store) = try persistentStore()
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let (suiteName, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = offlineClient()

        var cassationContext = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "город Москва",
            searchDomain: "2kas.sudrf.ru", displayDomain: "2kas.sudrf.ru",
            courtTitle: "Второй кассационный суд общей юрисдикции",
            courtLevelRaw: CourtLevel.cassation.rawValue, courtCode: nil,
            cartotekaId: "g3", cartotekaLevelRaw: CourtLevel.cassation.rawValue,
            caseNumber: try XCTUnwrap(fixtures.cassation.caseNumber),
            caseID: "2723657", caseUID: "576e5fae-ee46-434a-99eb-5956562963b0",
            cardURLString: fixtures.cassationURL.absoluteString)
        cassationContext.judicialUID = fixtures.cassation.uid
        cassationContext.baseInstanceLevelRaw = CaseInstance.Level.cassation.rawValue
        cassationContext.essence = "Лукьянова Анна Константиновна × Совет депутатов муниципального округа Хамовники"
        let cassationMovement = seedMovement(card: fixtures.cassation,
                                             context: cassationContext,
                                             sourceURL: fixtures.cassationURL)
        let cassationRecord = try store.upsert(
            context: cassationContext,
            snapshot: MovementDerivation.snapshot(from: cassationMovement,
                                                  context: cassationContext),
            movement: cassationMovement, collections: ["Лукьянова"])
        cassationRecord.addedAt = Date(timeIntervalSince1970: 300)
        let seedEvent = CaseEvent.make(
            kind: .instanceDiscovered, occurrence: ["issue322", "8а-7078/2022"],
            observedAt: cassationRecord.addedAt,
            evidence: CaseEventEvidence(instanceLevelRaw: CaseInstance.Level.cassation.rawValue,
                                        caseNumber: "8а-7078/2022"))
        try store.appendCaseEvents([seedEvent], to: cassationRecord)
        cassationRecord.movementFetchedAt = Date(timeIntervalSince1970: 300)

        var controlContext = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "город Москва",
            searchDomain: MosGorSudEndpoint.host, displayDomain: MosGorSudEndpoint.host,
            courtTitle: "Московский городской суд",
            courtLevelRaw: CourtLevel.subject.rawValue, courtCode: "77OS0000",
            cartotekaId: "p1", cartotekaLevelRaw: CourtLevel.subject.rawValue,
            caseNumber: "3а-1318/2021")
        controlContext.baseInstanceLevelRaw = CaseInstance.Level.first.rawValue
        controlContext.essence = "Заместитель прокурора города Москвы × Совет депутатов муниципального округа Хамовники"
        let controlMovement = CaseMovement(
            uid: "", caseNumber: controlContext.caseNumber, inForce: false,
            instances: [CaseInstance(
                level: .first, court: controlContext.courtTitle,
                caseNumber: controlContext.caseNumber, judge: nil,
                domain: MosGorSudEndpoint.host, foundByUID: false,
                result: nil, sessions: [])], complaints: [:], acts: [])
        let control = try store.upsert(context: controlContext, snapshot: nil,
                                       movement: controlMovement,
                                       collections: ["Положительный контроль"])
        try store.save()
        XCTAssertEqual(store.all().count, 2)

        let sudrf = try Issue322SudrfStub(fixtures: fixtures)
        let moscow = Issue322MoscowStub(fixtures: fixtures)
        let probe = Issue322MovementProbe()
        let repair = makeRepair(store: store, sudrf: sudrf,
                                moscow: moscow, defaults: defaults, client: client)
        let center = makeCenter(store: store, sudrf: sudrf, moscow: moscow,
                                repair: repair, client: client, probe: probe,
                                afterRepair: { _, effectiveKey in
            guard let record = store.record(forLocator: effectiveKey),
                  let act = cassationMovement.acts.first,
                  let text = cassationMovement.actBodies[act.id] else {
                return XCTFail("repair did not leave the seeded cassation act available")
            }
            self.assertRetainedActText(text, linkedToCaseNumber: "8а-7078/2022",
                                  sourceURL: fixtures.cassationURL, in: record)
        })
        let task = try XCTUnwrap(center.refresh(key: cassationRecord.key))
        let execution = await task.value
        guard case .partial = execution.outcome else {
            return XCTFail("ordinary refresh should retain the chain with verified empty listings")
        }
        let (cached, fresh) = await probe.snapshot()
        if let cached, let fresh, let act = cassationMovement.acts.first,
           let text = cassationMovement.actBodies[act.id] {
            let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)
            self.assertRetainedActText(text, linkedToCaseNumber: "8а-7078/2022",
                                       sourceURL: fixtures.cassationURL, in: merged)
        } else {
            XCTFail("refresh probe did not capture the cassation cache and fresh movement")
        }

        XCTAssertEqual(store.all().count, 2)
        let repaired = try XCTUnwrap(store.record(forLocator: cassationRecord.key))
        XCTAssertEqual(repaired.context?.caseNumber, "02а-0419/2021")
        XCTAssertEqual(repaired.context?.cardURLString, fixtures.moscowHamovURL.absoluteString)
        XCTAssertTrue((repaired.context?.knownCards ?? []).contains {
            $0.sourceURL == fixtures.cassationURL
                && $0.caseNumber?.contains("8а-7078/2022") == true
                && $0.caseNumber?.contains("88а-8501/2022") == true
        })
        XCTAssertEqual(repaired.eventJournal?.events.map(\.id), [seedEvent.id])
        XCTAssertTrue(store.record(forLocator: control.key) === control)
        XCTAssertEqual(control.caseNumber, "3а-1318/2021")

        func assertFullChain(_ record: TrackedCaseRecord,
                             file: StaticString = #filePath, line: UInt = #line) {
            let instances = record.movement?.instances ?? []
            let first = instances.first { $0.caseNumber == "02а-0419/2021" }
            let appeal = instances.first { $0.caseNumber == "33а-6088/2021" }
            let cassation = instances.first { $0.caseNumber.contains("8а-7078/2022") }
            XCTAssertEqual([first, appeal, cassation].compactMap { $0 }.count, 3,
                           file: file, line: line)
            XCTAssertEqual(first?.sourceURL, fixtures.moscowHamovURL, file: file, line: line)
            XCTAssertEqual(appeal?.sourceURL, fixtures.moscowAppealURL, file: file, line: line)
            XCTAssertEqual(cassation?.sourceURL, fixtures.cassationURL, file: file, line: line)
            XCTAssertTrue(cassation?.caseNumber.contains("88а-8501/2022") == true,
                          file: file, line: line)
            XCTAssertFalse(instances.contains { $0.caseNumber == "3а-1318/2021" },
                           file: file, line: line)
            for act in cassationMovement.acts {
                guard let text = cassationMovement.actBodies[act.id] else {
                    XCTFail("seed act must have cached text", file: file, line: line)
                    continue
                }
                assertRetainedActText(text, linkedToCaseNumber: "8а-7078/2022",
                                      sourceURL: fixtures.cassationURL, in: record,
                                      file: file, line: line)
            }
        }
        assertFullChain(repaired)
        let journalAfterFull = try XCTUnwrap(repaired.eventJournal?.events.map(\.id))
        XCTAssertEqual(journalAfterFull.count, Set(journalAfterFull).count)
        let successfulRefresh = Date(timeIntervalSince1970: 500)
        repaired.movementFetchedAt = successfulRefresh
        try store.save()

        await moscow.fail([fixtures.moscowAppealURL])
        let partialTask = try XCTUnwrap(center.refresh(key: repaired.key))
        guard case .partial = await partialTask.value.outcome else {
            return XCTFail("an unavailable Moscow appellate card must leave a partial snapshot")
        }
        let partial = try XCTUnwrap(store.record(forKey: repaired.key))
        assertFullChain(partial)
        XCTAssertEqual(partial.movementFetchedAt, successfulRefresh)
        XCTAssertEqual(partial.eventJournal?.events.map(\.id), journalAfterFull)
        let failedMoscowReads = await moscow.failedCardURLs()
        XCTAssertTrue(failedMoscowReads.contains(fixtures.moscowAppealURL))
        await moscow.fail([])

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        let reopenedRepair = makeRepair(store: reopened,
                                        sudrf: sudrf, moscow: moscow, defaults: defaults,
                                        client: client)
        let reopenedCenter = makeCenter(store: reopened, sudrf: sudrf,
                                        moscow: moscow, repair: reopenedRepair, client: client)
        let target = try XCTUnwrap(reopened.record(forLocator: cassationRecord.key))
        let repeatTask = try XCTUnwrap(
            reopenedCenter.refresh(key: target.key))
        let repeatExecution = await repeatTask.value
        guard case .partial = repeatExecution.outcome else {
            return XCTFail("repeat refresh should continue preserving the Moscow chain")
        }
        XCTAssertEqual(reopened.record(forKey: target.key)?.movementFetchedAt,
                       successfulRefresh)
        XCTAssertEqual(reopened.all().count, 2)
        let repeated = try XCTUnwrap(reopened.record(forLocator: cassationRecord.key))
        assertFullChain(repeated)
        XCTAssertEqual(repeated.eventJournal?.events.map(\.id), journalAfterFull)
        XCTAssertEqual(Set(repeated.collectionNames), ["Лукьянова"])
        let reopenedControl = try XCTUnwrap(reopened.record(forLocator: control.key))
        XCTAssertEqual(reopenedControl.caseNumber, "3а-1318/2021")

        let moscowRequests = await moscow.searchRequests()
        XCTAssertTrue(moscowRequests.contains { $0.contains("alias=hamovnicheskij") })
        XCTAssertTrue(moscowRequests.contains { $0.contains("instance=2") })
        let sudrfSearches = await sudrf.searchRequests()
        XCTAssertTrue(sudrfSearches.contains { $0.contains("2kas.sudrf.ru") })
    }
}
