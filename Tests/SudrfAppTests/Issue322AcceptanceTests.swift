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

private final class Issue322OfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTFail("Unexpected network request in offline #322 acceptance test: \(request.url?.absoluteString ?? "<missing URL>")")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }

    override func stopLoading() {}
}

private struct Issue322InstanceSnapshot: Equatable, Sendable {
    let level: String
    let caseNumber: String
    let domain: String
    let sourceURL: String?

    var sortKey: String {
        [level, caseNumber, domain, sourceURL ?? ""].joined(separator: "\u{0}")
    }
}

private struct Issue322ActLinkSnapshot: Equatable, Sendable {
    let level: String
    let caseNumber: String
    let sourceURL: String?
    let actID: String
    let body: String
}

/// Plain values only. A phase returns this instead of retaining SwiftData
/// models/contexts, so reopening below really starts after the first store and
/// its managed objects have left scope.
private struct Issue322RecordSnapshot: Equatable, Sendable {
    let key: String
    let caseNumber: String
    let courtTitle: String
    let displayDomain: String
    let addedAt: Date
    let seenAt: Date?
    let folderName: String
    let collections: [String]
    let movementFetchedAt: Date?
    let refreshAttemptKind: String?
    let eventJournal: CaseEventJournal?
    let totalInstanceCount: Int
    let instances: [Issue322InstanceSnapshot]
    let linkedActTexts: [Issue322ActLinkSnapshot]
    let knownCards: [String]
}

private struct Issue322PersistenceCheckpoint: Sendable {
    let storePath: String
    let defaultsSuiteName: String
    let targetLocator: String
    let controlLocator: String?
    let records: [Issue322RecordSnapshot]
}

private enum Issue322TestFailure: Error {
    case unexpectedRefreshOutcome
}

/// Test-only transfer directory. The normal MovementContext factory creates a
/// production directory resolver by default, so the RefreshCenter profile
/// reconstructs MovementService with this injected, fixture-backed boundary.
private actor Issue322TransferCourtDirectory {
    private var requestedSubjects: [String] = []

    func courts(for subjectCode: String) -> [DistrictCourt] {
        requestedSubjects.append(subjectCode)
        return []
    }

    func requests() -> [String] { requestedSubjects }
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
                      collection: String, addedAt: Date, seenAt: Date,
                      store: TrackedStore) throws -> TrackedCaseRecord {
        let movement = seedMovement(card: card, context: context, sourceURL: url)
        let record = try store.upsert(
            context: context,
            snapshot: MovementDerivation.snapshot(from: movement, context: context),
            movement: movement, collections: ["Москва", collection])
        record.addedAt = addedAt
        record.seenAt = seenAt
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
                            transferDirectory: Issue322TransferCourtDirectory,
                            afterRepair: ((String, String) -> Void)? = nil) -> RefreshCenter {
        let center = RefreshCenter(
            store: store, client: client,
            serviceBuilder: { context in
                self.makeOfflineService(context: context, client: sudrf,
                                        moscow: moscow,
                                        transferDirectory: transferDirectory)
            })
        center.repairBeforeRefresh = { key, force in
            let outcome = try await repair.repairIfNeeded(key: key, forceAttempt: force)
            afterRepair?(key, outcome.effectiveKey)
            return outcome.effectiveKey
        }
        return center
    }

    private func makeOfflineService(context: MovementContext,
                                    client: any CaseProviding,
                                    moscow: any MosGorSudProviding,
                                    transferDirectory: Issue322TransferCourtDirectory)
        -> MovementService {
        let targets = context.higherCourtTargets ?? context.cartoteka.flatMap {
            MovementTargetBuilder.targets(
                branch: context.branch, courtLevel: context.courtLevel,
                baseCartoteka: $0, caseNumber: context.caseNumber,
                judicialUID: context.judicialUID, courtTitle: context.courtTitle,
                courtCode: context.courtCode, region: context.region,
                displayDomain: context.displayDomain)
        }
        return MovementService(
            client: client,
            higherCourtDomains: context.expandedHigherDomains(),
            higherCourtTargets: targets,
            knownCards: context.knownCards ?? [],
            baseInstanceLevel: context.baseInstanceLevel,
            mosgorsud: moscow,
            judicialUID: context.judicialUID,
            branch: context.branch,
            transferCourts: { subjectCode in
                await transferDirectory.courts(for: subjectCode)
            })
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

    private func instanceSnapshot(_ instance: CaseInstance) -> Issue322InstanceSnapshot {
        Issue322InstanceSnapshot(level: instance.level.rawValue,
                                 caseNumber: instance.caseNumber,
                                 domain: instance.domain,
                                 sourceURL: instance.sourceURL?.absoluteString)
    }

    private func recordSnapshot(_ record: TrackedCaseRecord) -> Issue322RecordSnapshot {
        let movement = record.movement
        let instances = (movement?.instances ?? []).map(instanceSnapshot)
            .sorted { $0.sortKey < $1.sortKey }
        let linkedActTexts = (movement?.instances ?? []).flatMap { instance in
            instance.linkedActIDs.compactMap { actID -> Issue322ActLinkSnapshot? in
                guard let body = movement?.actBodies[actID] else { return nil }
                return Issue322ActLinkSnapshot(
                    level: instance.level.rawValue, caseNumber: instance.caseNumber,
                    sourceURL: instance.sourceURL?.absoluteString,
                    actID: actID, body: body)
            }
        }.sorted {
            [$0.level, $0.caseNumber, $0.sourceURL ?? "", $0.actID, $0.body]
                .lexicographicallyPrecedes(
                    [$1.level, $1.caseNumber, $1.sourceURL ?? "", $1.actID, $1.body])
        }
        let knownCards = (record.context?.knownCards ?? []).map {
            [$0.levelRaw, $0.caseNumber ?? "", $0.domain,
             $0.sourceURL?.absoluteString ?? ""].joined(separator: "\u{0}")
        }.sorted()
        return Issue322RecordSnapshot(
            key: record.key, caseNumber: record.caseNumber,
            courtTitle: record.courtTitle, displayDomain: record.displayDomain,
            addedAt: record.addedAt, seenAt: record.seenAt,
            folderName: record.folderName, collections: record.collectionNames,
            movementFetchedAt: record.movementFetchedAt,
            refreshAttemptKind: record.sourceRefreshAttempt?.kind.rawValue,
            eventJournal: record.eventJournal,
            totalInstanceCount: movement?.instances.count ?? 0,
            instances: instances, linkedActTexts: linkedActTexts,
            knownCards: knownCards)
    }

    private func recordSnapshots(_ records: [TrackedCaseRecord]) -> [Issue322RecordSnapshot] {
        records.map(recordSnapshot).sorted { $0.key < $1.key }
    }

    private func expectedInstances(_ values: [Issue322InstanceSnapshot])
        -> [Issue322InstanceSnapshot] {
        values.sorted { $0.sortKey < $1.sortKey }
    }

    private func assertExactInstances(_ record: TrackedCaseRecord,
                                      expected: [Issue322InstanceSnapshot],
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        let actual = (record.movement?.instances ?? []).map(instanceSnapshot)
        XCTAssertEqual(record.movement?.instances.count, expected.count,
                       "unexpected or duplicate movement instances", file: file, line: line)
        XCTAssertEqual(expectedInstances(actual), expectedInstances(expected),
                       "movement instances must match exact level, number, domain, and URL tuples",
                       file: file, line: line)
    }

    private func assertUserData(_ snapshot: Issue322RecordSnapshot,
                                addedAt: Date, seenAt: Date,
                                collections: [String],
                                file: StaticString = #filePath,
                                line: UInt = #line) {
        XCTAssertEqual(snapshot.addedAt, addedAt, file: file, line: line)
        XCTAssertEqual(snapshot.seenAt, seenAt, file: file, line: line)
        XCTAssertFalse(snapshot.seenAt == nil, "seenAt must be meaningful and nonnil",
                       file: file, line: line)
        XCTAssertEqual(snapshot.collections, collections, file: file, line: line)
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

    private func runTwoAppealsThroughPartialRefresh()
        async throws -> Issue322PersistenceCheckpoint {
        let fixtures = try Issue322FixtureSet.load()
        let (storeURL, store) = try persistentStore()
        let (suiteName, defaults) = try isolatedDefaults()
        let client = offlineClient()
        let firstAddedAt = Date(timeIntervalSince1970: 100)
        let firstSeenAt = Date(timeIntervalSince1970: 1_100)
        let secondAddedAt = Date(timeIntervalSince1970: 200)
        let secondSeenAt = Date(timeIntervalSince1970: 1_200)

        let first = try seed(
            appealContext(number: "66а-2013/2020", id: "6724440",
                          guid: "0cd448a3-5cf2-49bc-99c1-35bf0706c2d5",
                          url: fixtures.appeal2013URL),
            card: fixtures.appeal2013, url: fixtures.appeal2013URL,
            collection: "Частная жалоба", addedAt: firstAddedAt, seenAt: firstSeenAt,
            store: store)
        let second = try seed(
            appealContext(number: "66а-4311/2020", id: "6749107",
                          guid: "6dc098e7-acb0-4b6b-b250-fcbb25479004",
                          url: fixtures.appeal4311URL),
            card: fixtures.appeal4311, url: fixtures.appeal4311URL,
            collection: "Апелляция", addedAt: secondAddedAt, seenAt: secondSeenAt,
            store: store)
        XCTAssertEqual(store.all().count, 2)
        XCTAssertTrue(store.all().allSatisfy { $0.context?.searchDomain == "1ap.sudrf.ru" },
                       "the Moscow first-instance record must not be pre-added")
        XCTAssertEqual(first.seenAt, firstSeenAt)
        XCTAssertEqual(second.seenAt, secondSeenAt)

        let sudrf = try Issue322SudrfStub(fixtures: fixtures)
        let moscow = Issue322MoscowStub(fixtures: fixtures)
        let transferDirectory = Issue322TransferCourtDirectory()
        let repair = makeRepair(store: store, sudrf: sudrf,
                                moscow: moscow, defaults: defaults, client: client)
        let center = makeCenter(store: store, sudrf: sudrf, moscow: moscow,
                                repair: repair, client: client,
                                transferDirectory: transferDirectory,
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
                XCTFail("ordinary refresh must keep the chain while reporting verified empty listings")
                throw Issue322TestFailure.unexpectedRefreshOutcome
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
        XCTAssertEqual(saved.addedAt, firstAddedAt)
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

        let expectedInstances = expectedInstances([
            Issue322InstanceSnapshot(level: CaseInstance.Level.first.rawValue,
                                     caseNumber: "3а-3696/2020",
                                     domain: MosGorSudEndpoint.host,
                                     sourceURL: fixtures.moscowFirstURL.absoluteString),
            Issue322InstanceSnapshot(level: CaseInstance.Level.appeal.rawValue,
                                     caseNumber: "66а-2013/2020",
                                     domain: "1ap.sudrf.ru",
                                     sourceURL: fixtures.appeal2013URL.absoluteString),
            Issue322InstanceSnapshot(level: CaseInstance.Level.appeal.rawValue,
                                     caseNumber: "66а-4311/2020",
                                     domain: "1ap.sudrf.ru",
                                     sourceURL: fixtures.appeal4311URL.absoluteString)
        ])
        assertExactInstances(saved, expected: expectedInstances)
        for number in ["66а-2013/2020", "66а-4311/2020"] {
            let sourceURL = number == "66а-2013/2020"
                ? fixtures.appeal2013URL : fixtures.appeal4311URL
            assertRetainedActText("Исторический текст \(number)",
                                  linkedToCaseNumber: number,
                                  sourceURL: sourceURL, in: saved)
        }
        let firstJournal = try XCTUnwrap(saved.eventJournal?.events.map(\.id))
        XCTAssertEqual(firstJournal.count, Set(firstJournal).count)
        let successfulRefresh = Date(timeIntervalSince1970: 400)
        let seenAfterRepair = Date(timeIntervalSince1970: 1_400)
        saved.movementFetchedAt = successfulRefresh
        // A newly discovered first-instance card may legitimately mark the
        // repaired chain unread. Model the user reviewing it now so the
        // partial/reopen persistence checks start from a meaningful read date.
        saved.seenAt = seenAfterRepair
        try store.save()

        await sudrf.fail([fixtures.appeal4311URL])
        let partialTask = try XCTUnwrap(center.refresh(key: saved.key))
        guard case .partial = await partialTask.value.outcome else {
            XCTFail("one unreadable known appeal must produce a partial refresh")
            throw Issue322TestFailure.unexpectedRefreshOutcome
        }
        let partial = try XCTUnwrap(store.record(forKey: saved.key))
        assertExactInstances(partial, expected: expectedInstances)
        for number in ["66а-2013/2020", "66а-4311/2020"] {
            let sourceURL = number == "66а-2013/2020"
                ? fixtures.appeal2013URL : fixtures.appeal4311URL
            assertRetainedActText("Исторический текст \(number)",
                                  linkedToCaseNumber: number,
                                  sourceURL: sourceURL, in: partial)
        }
        XCTAssertEqual(partial.movementFetchedAt, successfulRefresh)
        XCTAssertEqual(partial.sourceRefreshAttempt?.kind, .partial)
        XCTAssertEqual(partial.eventJournal?.events.map(\.id), firstJournal)
        let failedAppealReads = await sudrf.failedCardURLs()
        XCTAssertTrue(failedAppealReads.contains(fixtures.appeal4311URL))
        let transferRequests = await transferDirectory.requests()
        XCTAssertTrue(transferRequests.isEmpty,
                      "offline MovementService must never consult a live transfer directory")

        let partialSnapshot = recordSnapshot(partial)
        assertUserData(partialSnapshot, addedAt: firstAddedAt, seenAt: seenAfterRepair,
                       collections: ["Москва", "Частная жалоба", "Апелляция"])
        return Issue322PersistenceCheckpoint(
            storePath: storeURL.path, defaultsSuiteName: suiteName,
            targetLocator: saved.key, controlLocator: nil,
            records: recordSnapshots(store.all()))
    }

    private func verifyTwoAppealsAfterColdReopen(
        _ checkpoint: Issue322PersistenceCheckpoint) async throws {
        let fixtures = try Issue322FixtureSet.load()
        let container = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: URL(fileURLWithPath: checkpoint.storePath))
        let reopened = try TrackedStore(container: container, prepared: true)
        XCTAssertEqual(recordSnapshots(reopened.all()), checkpoint.records,
                       "cold reopen must restore the saved state before another refresh")
        XCTAssertEqual(reopened.all().count, 1)
        let reopenedRecord = try XCTUnwrap(reopened.record(forLocator: checkpoint.targetLocator))
        let expectedInstances = expectedInstances([
            Issue322InstanceSnapshot(level: CaseInstance.Level.first.rawValue,
                                     caseNumber: "3а-3696/2020",
                                     domain: MosGorSudEndpoint.host,
                                     sourceURL: fixtures.moscowFirstURL.absoluteString),
            Issue322InstanceSnapshot(level: CaseInstance.Level.appeal.rawValue,
                                     caseNumber: "66а-2013/2020",
                                     domain: "1ap.sudrf.ru",
                                     sourceURL: fixtures.appeal2013URL.absoluteString),
            Issue322InstanceSnapshot(level: CaseInstance.Level.appeal.rawValue,
                                     caseNumber: "66а-4311/2020",
                                     domain: "1ap.sudrf.ru",
                                     sourceURL: fixtures.appeal4311URL.absoluteString)
        ])
        assertExactInstances(reopenedRecord, expected: expectedInstances)
        for number in ["66а-2013/2020", "66а-4311/2020"] {
            let sourceURL = number == "66а-2013/2020"
                ? fixtures.appeal2013URL : fixtures.appeal4311URL
            assertRetainedActText("Исторический текст \(number)",
                                  linkedToCaseNumber: number,
                                  sourceURL: sourceURL, in: reopenedRecord)
        }
        let beforeRepeat = recordSnapshot(reopenedRecord)
        let persistedTarget = try XCTUnwrap(checkpoint.records.first {
            $0.key == checkpoint.targetLocator
        })
        XCTAssertEqual(beforeRepeat, persistedTarget)
        assertUserData(beforeRepeat, addedAt: Date(timeIntervalSince1970: 100),
                       seenAt: Date(timeIntervalSince1970: 1_400),
                       collections: ["Москва", "Частная жалоба", "Апелляция"])

        let defaults = try XCTUnwrap(UserDefaults(suiteName: checkpoint.defaultsSuiteName))
        let client = offlineClient()
        let sudrf = try Issue322SudrfStub(fixtures: fixtures)
        let moscow = Issue322MoscowStub(fixtures: fixtures)
        let transferDirectory = Issue322TransferCourtDirectory()
        let repair = makeRepair(store: reopened, sudrf: sudrf,
                                moscow: moscow, defaults: defaults, client: client)
        let center = makeCenter(store: reopened, sudrf: sudrf, moscow: moscow,
                                repair: repair, client: client,
                                transferDirectory: transferDirectory)
        let repeatTask = try XCTUnwrap(center.refresh(key: reopenedRecord.key))
        let repeatExecution = await repeatTask.value
        guard case .partial = repeatExecution.outcome else {
            return XCTFail("repeat refresh should preserve the persisted historical-chain state")
        }
        let afterRepeat = try XCTUnwrap(reopened.record(forLocator: checkpoint.targetLocator))
        assertExactInstances(afterRepeat, expected: expectedInstances)
        XCTAssertEqual(recordSnapshots(reopened.all()), checkpoint.records,
                       "repeat refresh must preserve every persisted record value")
        XCTAssertEqual(recordSnapshot(afterRepeat), beforeRepeat)
        let transferRequests = await transferDirectory.requests()
        XCTAssertTrue(transferRequests.isEmpty,
                      "offline MovementService must never consult a live transfer directory")

        let requestedURLs = await sudrf.requestedCardURLs()
        XCTAssertTrue(requestedURLs.contains(fixtures.appeal2013URL))
        XCTAssertTrue(requestedURLs.contains(fixtures.appeal4311URL))
    }

    func testTwoAppealsRepairThroughRefreshAndRetainHistoryAcrossPartialFailureAndReopen() async throws {
        let checkpoint = try await runTwoAppealsThroughPartialRefresh()
        defer {
            try? FileManager.default.removeItem(atPath:
                URL(fileURLWithPath: checkpoint.storePath).deletingLastPathComponent().path)
            UserDefaults(suiteName: checkpoint.defaultsSuiteName)?
                .removePersistentDomain(forName: checkpoint.defaultsSuiteName)
        }
        try await verifyTwoAppealsAfterColdReopen(checkpoint)

    }

    private func runKSOYUThroughPartialRefresh()
        async throws -> Issue322PersistenceCheckpoint {
        let fixtures = try Issue322FixtureSet.load()
        let cassationCaseNumber = try XCTUnwrap(fixtures.cassation.caseNumber)
        let cassationActText = "Исторический текст \(cassationCaseNumber)"
        let (storeURL, store) = try persistentStore()
        let (suiteName, defaults) = try isolatedDefaults()
        let client = offlineClient()
        let targetAddedAt = Date(timeIntervalSince1970: 300)
        let targetSeenAt = Date(timeIntervalSince1970: 1_300)
        let controlAddedAt = Date(timeIntervalSince1970: 200)
        let controlSeenAt = Date(timeIntervalSince1970: 1_200)

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
            movement: cassationMovement, collections: ["Лукьянова", "Мои дела"])
        cassationRecord.addedAt = targetAddedAt
        cassationRecord.seenAt = targetSeenAt
        let seedEvent = CaseEvent.make(
            kind: .instanceDiscovered, occurrence: ["issue322", "8а-7078/2022"],
            observedAt: targetAddedAt,
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
                                       collections: ["Положительный контроль", "Мои дела"])
        control.addedAt = controlAddedAt
        control.seenAt = controlSeenAt
        let controlEvent = CaseEvent.make(
            kind: .instanceDiscovered,
            occurrence: ["issue322-control", "3а-1318/2021"],
            observedAt: controlAddedAt,
            evidence: CaseEventEvidence(instanceLevelRaw: CaseInstance.Level.first.rawValue,
                                        caseNumber: "3а-1318/2021"))
        try store.appendCaseEvents([controlEvent], to: control)
        try store.save()
        XCTAssertEqual(store.all().count, 2)
        XCTAssertEqual(cassationRecord.seenAt, targetSeenAt)
        XCTAssertEqual(control.seenAt, controlSeenAt)
        let controlSeedSnapshot = recordSnapshot(control)
        assertUserData(controlSeedSnapshot, addedAt: controlAddedAt,
                       seenAt: controlSeenAt,
                       collections: ["Положительный контроль", "Мои дела"])

        let sudrf = try Issue322SudrfStub(fixtures: fixtures)
        let moscow = Issue322MoscowStub(fixtures: fixtures)
        let transferDirectory = Issue322TransferCourtDirectory()
        let repair = makeRepair(store: store, sudrf: sudrf,
                                moscow: moscow, defaults: defaults, client: client)
        let center = makeCenter(store: store, sudrf: sudrf, moscow: moscow,
                                repair: repair, client: client,
                                transferDirectory: transferDirectory,
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
            XCTFail("ordinary refresh should retain the chain with verified empty listings")
            throw Issue322TestFailure.unexpectedRefreshOutcome
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
        XCTAssertEqual(recordSnapshot(control), controlSeedSnapshot,
                       "repairing the target must not change the separate control record")

        let expectedTargetInstances = expectedInstances([
            Issue322InstanceSnapshot(level: CaseInstance.Level.first.rawValue,
                                     caseNumber: "02а-0419/2021",
                                     domain: MosGorSudEndpoint.host,
                                     sourceURL: fixtures.moscowHamovURL.absoluteString),
            Issue322InstanceSnapshot(level: CaseInstance.Level.appeal.rawValue,
                                     caseNumber: "33а-6088/2021",
                                     domain: MosGorSudEndpoint.host,
                                     sourceURL: fixtures.moscowAppealURL.absoluteString),
            Issue322InstanceSnapshot(level: CaseInstance.Level.cassation.rawValue,
                                     caseNumber: try XCTUnwrap(fixtures.cassation.caseNumber),
                                     domain: "2kas.sudrf.ru",
                                     sourceURL: fixtures.cassationURL.absoluteString)
        ])
        let expectedControlInstances = expectedInstances([
            Issue322InstanceSnapshot(level: CaseInstance.Level.first.rawValue,
                                     caseNumber: "3а-1318/2021",
                                     domain: MosGorSudEndpoint.host,
                                     sourceURL: nil)
        ])
        assertExactInstances(repaired, expected: expectedTargetInstances)
        assertExactInstances(control, expected: expectedControlInstances)
        assertRetainedActText(cassationActText,
                              linkedToCaseNumber: "8а-7078/2022",
                              sourceURL: fixtures.cassationURL, in: repaired)
        let journalAfterFull = try XCTUnwrap(repaired.eventJournal?.events.map(\.id))
        XCTAssertEqual(journalAfterFull.count, Set(journalAfterFull).count)
        let successfulRefresh = Date(timeIntervalSince1970: 500)
        let seenAfterRepair = Date(timeIntervalSince1970: 1_500)
        repaired.movementFetchedAt = successfulRefresh
        // The first repaired chain may be unread because its native cards are
        // newly discovered. Persist a read marker before testing stable refresh.
        repaired.seenAt = seenAfterRepair
        try store.save()
        assertUserData(recordSnapshot(repaired), addedAt: targetAddedAt,
                       seenAt: seenAfterRepair,
                       collections: ["Лукьянова", "Мои дела"])

        await moscow.fail([fixtures.moscowAppealURL])
        let partialTask = try XCTUnwrap(center.refresh(key: repaired.key))
        guard case .partial = await partialTask.value.outcome else {
            XCTFail("an unavailable Moscow appellate card must leave a partial snapshot")
            throw Issue322TestFailure.unexpectedRefreshOutcome
        }
        let partial = try XCTUnwrap(store.record(forKey: repaired.key))
        assertExactInstances(partial, expected: expectedTargetInstances)
        assertExactInstances(control, expected: expectedControlInstances)
        XCTAssertEqual(partial.movementFetchedAt, successfulRefresh)
        XCTAssertEqual(partial.eventJournal?.events.map(\.id), journalAfterFull)
        let failedMoscowReads = await moscow.failedCardURLs()
        XCTAssertTrue(failedMoscowReads.contains(fixtures.moscowAppealURL))
        let targetSnapshot = recordSnapshot(partial)
        assertUserData(targetSnapshot, addedAt: targetAddedAt, seenAt: seenAfterRepair,
                       collections: ["Лукьянова", "Мои дела"])
        XCTAssertEqual(recordSnapshot(control), controlSeedSnapshot)
        let partialRecords = recordSnapshots(store.all())
        XCTAssertEqual(partialRecords.count, 2)
        let transferRequests = await transferDirectory.requests()
        XCTAssertTrue(transferRequests.isEmpty,
                      "offline MovementService must never consult a live transfer directory")

        let moscowRequests = await moscow.searchRequests()
        XCTAssertTrue(moscowRequests.contains { $0.contains("alias=hamovnicheskij") })
        XCTAssertTrue(moscowRequests.contains { $0.contains("instance=2") })
        let sudrfSearches = await sudrf.searchRequests()
        XCTAssertTrue(sudrfSearches.contains { $0.contains("2kas.sudrf.ru") })
        return Issue322PersistenceCheckpoint(
            storePath: storeURL.path, defaultsSuiteName: suiteName,
            targetLocator: cassationRecord.key, controlLocator: control.key,
            records: partialRecords)
    }

    private func verifyKSOYUAfterColdReopen(
        _ checkpoint: Issue322PersistenceCheckpoint) async throws {
        let fixtures = try Issue322FixtureSet.load()
        let cassationActText = "Исторический текст \(try XCTUnwrap(fixtures.cassation.caseNumber))"
        let container = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: URL(fileURLWithPath: checkpoint.storePath))
        let reopened = try TrackedStore(container: container, prepared: true)
        XCTAssertEqual(recordSnapshots(reopened.all()), checkpoint.records,
                       "cold reopen must restore target and control before another refresh")
        XCTAssertEqual(reopened.all().count, 2)
        let target = try XCTUnwrap(reopened.record(forLocator: checkpoint.targetLocator))
        let controlLocator = try XCTUnwrap(checkpoint.controlLocator)
        let control = try XCTUnwrap(reopened.record(forLocator: controlLocator))
        let expectedTargetInstances = expectedInstances([
            Issue322InstanceSnapshot(level: CaseInstance.Level.first.rawValue,
                                     caseNumber: "02а-0419/2021",
                                     domain: MosGorSudEndpoint.host,
                                     sourceURL: fixtures.moscowHamovURL.absoluteString),
            Issue322InstanceSnapshot(level: CaseInstance.Level.appeal.rawValue,
                                     caseNumber: "33а-6088/2021",
                                     domain: MosGorSudEndpoint.host,
                                     sourceURL: fixtures.moscowAppealURL.absoluteString),
            Issue322InstanceSnapshot(level: CaseInstance.Level.cassation.rawValue,
                                     caseNumber: try XCTUnwrap(fixtures.cassation.caseNumber),
                                     domain: "2kas.sudrf.ru",
                                     sourceURL: fixtures.cassationURL.absoluteString)
        ])
        let expectedControlInstances = expectedInstances([
            Issue322InstanceSnapshot(level: CaseInstance.Level.first.rawValue,
                                     caseNumber: "3а-1318/2021",
                                     domain: MosGorSudEndpoint.host,
                                     sourceURL: nil)
        ])
        assertExactInstances(target, expected: expectedTargetInstances)
        assertExactInstances(control, expected: expectedControlInstances)
        assertRetainedActText(cassationActText,
                              linkedToCaseNumber: "8а-7078/2022",
                              sourceURL: fixtures.cassationURL, in: target)
        let targetBeforeRepeat = recordSnapshot(target)
        let controlBeforeRepeat = recordSnapshot(control)
        XCTAssertEqual(targetBeforeRepeat, try XCTUnwrap(checkpoint.records.first {
            $0.key == targetBeforeRepeat.key
        }))
        XCTAssertEqual(controlBeforeRepeat, try XCTUnwrap(checkpoint.records.first {
            $0.key == controlBeforeRepeat.key
        }))
        assertUserData(targetBeforeRepeat, addedAt: Date(timeIntervalSince1970: 300),
                       seenAt: Date(timeIntervalSince1970: 1_500),
                       collections: ["Лукьянова", "Мои дела"])
        assertUserData(controlBeforeRepeat, addedAt: Date(timeIntervalSince1970: 200),
                       seenAt: Date(timeIntervalSince1970: 1_200),
                       collections: ["Положительный контроль", "Мои дела"])

        let defaults = try XCTUnwrap(UserDefaults(suiteName: checkpoint.defaultsSuiteName))
        let client = offlineClient()
        let sudrf = try Issue322SudrfStub(fixtures: fixtures)
        let moscow = Issue322MoscowStub(fixtures: fixtures)
        let transferDirectory = Issue322TransferCourtDirectory()
        let repair = makeRepair(store: reopened, sudrf: sudrf,
                                moscow: moscow, defaults: defaults, client: client)
        let center = makeCenter(store: reopened, sudrf: sudrf, moscow: moscow,
                                repair: repair, client: client,
                                transferDirectory: transferDirectory)
        let repeatTask = try XCTUnwrap(center.refresh(key: target.key))
        let repeatExecution = await repeatTask.value
        guard case .partial = repeatExecution.outcome else {
            return XCTFail("repeat refresh should continue preserving the Moscow chain")
        }
        let targetAfterRepeat = try XCTUnwrap(reopened.record(forLocator: checkpoint.targetLocator))
        let controlAfterRepeat = try XCTUnwrap(reopened.record(forLocator: controlLocator))
        assertExactInstances(targetAfterRepeat, expected: expectedTargetInstances)
        assertExactInstances(controlAfterRepeat, expected: expectedControlInstances)
        XCTAssertEqual(recordSnapshots(reopened.all()), checkpoint.records,
                       "repeat refresh must preserve both target and control records")
        XCTAssertEqual(recordSnapshot(targetAfterRepeat), targetBeforeRepeat)
        XCTAssertEqual(recordSnapshot(controlAfterRepeat), controlBeforeRepeat)
        let transferRequests = await transferDirectory.requests()
        XCTAssertTrue(transferRequests.isEmpty,
                      "offline MovementService must never consult a live transfer directory")

    }

    func testKSOYURefreshRestoresBothMoscowCardsWithoutJoiningPositiveControl() async throws {
        let checkpoint = try await runKSOYUThroughPartialRefresh()
        defer {
            try? FileManager.default.removeItem(atPath:
                URL(fileURLWithPath: checkpoint.storePath).deletingLastPathComponent().path)
            UserDefaults(suiteName: checkpoint.defaultsSuiteName)?
                .removePersistentDomain(forName: checkpoint.defaultsSuiteName)
        }
        try await verifyKSOYUAfterColdReopen(checkpoint)
    }
}
