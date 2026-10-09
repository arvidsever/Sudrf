import Foundation
import XCTest
@testable import SudrfKit

final class MoscowMagistrateKoAPMovementTests: XCTestCase {
    private let unit = "424"
    private let caseNumber = "05-0042/424/2026"
    private let uid = "77MS0424-01-2026-000042-01"
    private let cardID = "11111111-1111-4111-8111-111111111111"

    private func baseURL(unit: String? = nil) throws -> URL {
        try XCTUnwrap(URL(string:
            "https://mos-sud.ru/\(unit ?? self.unit)/cases/admin/details/\(cardID)"))
    }

    private func cartoteka() throws -> Cartoteka {
        try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm"))
    }

    private func candidateURL() throws -> URL {
        let district = try XCTUnwrap(MosGorSudCourtDirectory.districtCourts.first)
        return try XCTUnwrap(URL(string:
            "https://mos-gorsud.ru/rs/\(district.alias)/services/cases/appeal-admin/details/\(cardID)"))
    }

    private func reviewURL() throws -> URL {
        try XCTUnwrap(URL(string:
            "https://mos-gorsud.ru/mgs/services/cases/review-supervision/details/\(cardID)"))
    }

    private func anchorCard(person: String = "Синтетический участник",
                            category: String? = "Часть 1 статьи 12.8 КоАП РФ",
                            number: String = "05-0042/424/2026",
                            cardUID: String? = nil,
                            omitUID: Bool = false) -> CaseCard {
        CaseCard(rawText: "Synthetic Moscow magistrate card", actText: nil,
                 uid: omitUID ? nil : (cardUID ?? uid), caseNumber: number, category: category,
                 parties: CaseParties(kind: .koap, roleItems: [
                    RoleItem(role: "Привлекаемое лицо", name: person)
                 ]), processKind: .koap)
    }

    private func appealCard(url: URL, person: String = "Синтетический участник",
                            category: String? = "Ст. 12.8 ч. 1 КоАП РФ",
                            cardUID: String? = nil) throws -> MosGorSudCard {
        let locator = try XCTUnwrap(SourceNativeCardLocator.moscowMagistrateKoAPAppeal(url: url))
        return MosGorSudCard(
            uid: cardUID ?? uid,
            caseNumber: "12-0001/2026",
            court: try XCTUnwrap(MosGorSudCourtDirectory.title(forAlias: locator.courtKey)),
            judge: "Судья Тестова И. И.", category: category,
            result: "Постановление оставлено без изменения",
            participants: ["Привлекаемое лицо: \(person)"],
            rawText: "Synthetic district appeal card")
    }

    private func reviewCard(lowerNumber: String?) throws -> MosGorSudCard {
        MosGorSudCard(
            uid: uid, caseNumber: "4а-35/2026",
            court: "Московский городской суд", judge: "Судья Тестова И. И.",
            category: "Часть 1 статьи 12.8 КоАП РФ",
            result: "Постановление оставлено без изменения",
            lowerNumber: lowerNumber,
            participants: ["Привлекаемое лицо: Синтетический участник"],
            rawText: "Synthetic Moscow City Court review card")
    }

    func testUIDCandidateRemainsUnlinkedAndBothSourceCoverageStatesStayExplicit() async throws {
        let baseURL = try baseURL()
        let district = try XCTUnwrap(MosGorSudCourtDirectory.districtCourts.first)
        let candidateURL = try candidateURL()
        let candidate = MosGorSudResult(
            caseNumber: "12-0001/2026", uid: uid, court: district.title,
            section: "appeal-admin", cardURL: candidateURL)
        let client = KoAPMovementClientStub(card: anchorCard(category: nil), responseURL: baseURL)
        let mgs = KoAPMovementMosGorSudStub(
            rows: [candidate], cardsByURL: [candidateURL: try appealCard(url: candidateURL, category: nil)])
        let service = MovementService(client: client, mosgorsud: mgs)

        let movement = try await service.movement(
            for: CaseSearchResult(caseNumber: caseNumber, caseUID: uid, cardURL: baseURL),
            court: Court(domain: MoscowMagistrateKoAPSource.host,
                         title: "Мировой судья участка \(unit)", level: .magistrate),
            cartoteka: cartoteka())

        XCTAssertEqual(movement.instances.count, 1)
        XCTAssertEqual(movement.instances[0].caseNumber, caseNumber)
        XCTAssertEqual(movement.instances[0].domain, MoscowMagistrateKoAPSource.host)
        XCTAssertEqual(movement.instances[0].sourceURL, baseURL)
        XCTAssertEqual(movement.uid, uid)
        XCTAssertTrue(movement.complaints.isEmpty)
        XCTAssertTrue(movement.acts.isEmpty)
        XCTAssertEqual(Set(movement.incompleteHigherCourtDomains ?? []),
                       Set([MoscowMagistrateKoAPSource.host, MosGorSudEndpoint.host]))
        XCTAssertTrue(movement.honestZeroDomains?.isEmpty == true)

        let baseIdentity = try XCTUnwrap(SourceNativeCardLocator.moscowMagistrateKoAP(
            url: baseURL, cartoteka: cartoteka())).identity
        let baseCoverage = try XCTUnwrap(movement.sourceRefreshCoverage?.first {
            $0.sourceFamily == MoscowMagistrateKoAPSource.family
        })
        XCTAssertEqual(baseCoverage.kind, .partial)
        XCTAssertTrue(baseCoverage.contains(card: baseIdentity))
        XCTAssertEqual(SourceOutcomeClassifier.attempt(
            for: movement, sourceFamily: MoscowMagistrateKoAPSource.family,
            host: MoscowMagistrateKoAPSource.host).kind, .partial)
        let mgsCoverage = try XCTUnwrap(movement.sourceRefreshCoverage?.first {
            $0.sourceFamily == "mosgorsud" && $0.courtKey == MosGorSudEndpoint.host
        })
        XCTAssertEqual(mgsCoverage.kind, .partial)

        let requests = await mgs.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.map(\.instance), [MosGorSudInstance.appeal,
                                                  MosGorSudInstance.review])
        XCTAssertTrue(requests.allSatisfy { $0.uid == uid && $0.processType == .admin })
        let fetchedCandidateURLs = await mgs.fetchedURLs
        XCTAssertEqual(fetchedCandidateURLs, [candidateURL])
        XCTAssertEqual(movement.instances.count, 1,
                       "UID and exact locator do not replace party/article proof")
    }

    func testUniqueCandidateLinksOnlyWhenUIDPersonArticleAndRSLocatorAllMatch() async throws {
        let baseURL = try baseURL()
        let candidateURL = try candidateURL()
        let district = try XCTUnwrap(MosGorSudCourtDirectory.districtCourts.first)
        let row = MosGorSudResult(caseNumber: "12-0001/2026", uid: uid,
                                  court: district.title, section: "appeal-admin",
                                  cardURL: candidateURL)
        let client = KoAPMovementClientStub(card: anchorCard(), responseURL: baseURL)
        let mgs = KoAPMovementMosGorSudStub(
            rows: [row], cardsByURL: [candidateURL: try appealCard(url: candidateURL)])
        let service = MovementService(client: client, mosgorsud: mgs)

        let movement = try await service.movement(
            for: CaseSearchResult(caseNumber: caseNumber, caseID: cardID.uppercased(),
                                  caseUID: uid, cardURL: baseURL),
            court: Court(domain: MoscowMagistrateKoAPSource.host,
                         title: "Мировой судья участка \(unit)", level: .magistrate),
            cartoteka: cartoteka())

        XCTAssertEqual(movement.instances.map(\.level), [.first, .appeal])
        let appeal = try XCTUnwrap(movement.instances.first { $0.level == .appeal })
        XCTAssertEqual(appeal.caseNumber, row.caseNumber)
        XCTAssertEqual(appeal.court, district.title)
        XCTAssertEqual(appeal.sourceURL, candidateURL)
        XCTAssertTrue(appeal.foundByUID)
        XCTAssertEqual(appeal.sourceEvidence?.cartotekaID, "admj")
        XCTAssertEqual(appeal.sourceEvidence?.judicialUID, uid)
        XCTAssertEqual(Set(movement.incompleteHigherCourtDomains ?? []),
                       Set([MoscowMagistrateKoAPSource.host, MosGorSudEndpoint.host]),
                       "The selected-unit listing and next section-filtered search are not proven complete")
        let mgsCoverage = try XCTUnwrap(movement.sourceRefreshCoverage?.first {
            $0.sourceFamily == "mosgorsud" && $0.courtKey == district.alias
        })
        XCTAssertEqual(mgsCoverage.kind, .usableSnapshot)
        XCTAssertTrue(mgsCoverage.loadedCardIdentities.contains {
            $0.cartotekaKey == "admj" && $0.sourceNativeID == cardID.lowercased()
        })
    }

    func testStoredAnchorCaseIDMustMatchNativeUUIDBeforeFetch() async throws {
        let baseURL = try baseURL()
        let client = KoAPMovementClientStub(card: anchorCard(), responseURL: baseURL)
        let mgs = KoAPMovementMosGorSudStub(rows: [])
        let service = MovementService(client: client, mosgorsud: mgs)

        do {
            _ = try await service.movement(
                for: CaseSearchResult(
                    caseNumber: caseNumber,
                    caseID: "22222222-2222-4222-8222-222222222222",
                    cardURL: baseURL),
                court: Court(domain: MoscowMagistrateKoAPSource.host,
                             title: "Мировой судья участка \(unit)", level: .magistrate),
                cartoteka: cartoteka())
            XCTFail("A saved row's explicit UUID must agree with its native card URL")
        } catch { }

        let fetchedURLs = await client.fetchedURLs
        let mgsRequests = await mgs.requests
        XCTAssertTrue(fetchedURLs.isEmpty)
        XCTAssertTrue(mgsRequests.isEmpty)
    }

    func testStoredAnchorUIDMustMatchFetchedCardBeforeStartingChain() async throws {
        let baseURL = try baseURL()
        let client = KoAPMovementClientStub(card: anchorCard(), responseURL: baseURL)
        let mgs = KoAPMovementMosGorSudStub(rows: [])
        let service = MovementService(client: client, mosgorsud: mgs)

        do {
            _ = try await service.movement(
                for: CaseSearchResult(
                    caseNumber: caseNumber,
                    caseUID: "77MS0424-01-2026-000099-01",
                    cardURL: baseURL),
                court: Court(domain: MoscowMagistrateKoAPSource.host,
                             title: "Мировой судья участка \(unit)", level: .magistrate),
                cartoteka: cartoteka())
            XCTFail("A stale published UID must not refresh a different card's chain")
        } catch { }

        let fetchedURLs = await client.fetchedURLs
        let mgsRequests = await mgs.requests
        XCTAssertEqual(fetchedURLs, [baseURL])
        XCTAssertTrue(mgsRequests.isEmpty)
    }

    func testUIDSearchExpectationIsCheckedAgainstOwnCardBeforeHigherRequests() async throws {
        let baseURL = try baseURL()
        let court = Court(domain: MoscowMagistrateKoAPSource.host,
                          title: "Мировой судья участка \(unit)", level: .magistrate)
        let cart = try cartoteka()

        let matchingMGS = KoAPMovementMosGorSudStub(rows: [])
        let matching = try await MovementService(
            client: KoAPMovementClientStub(card: anchorCard(), responseURL: baseURL),
            mosgorsud: matchingMGS,
            judicialUID: uid).movement(
                for: CaseSearchResult(caseNumber: caseNumber, cardURL: baseURL),
                court: court, cartoteka: cart)
        XCTAssertEqual(matching.uid, uid)
        let matchingRequests = await matchingMGS.requests
        XCTAssertEqual(matchingRequests.count, 2,
                       "Only the matching fetched own UID may start the higher-stage searches")

        let wrongUID = "77MS0424-01-2026-000043-01"
        for card in [anchorCard(cardUID: wrongUID), anchorCard(omitUID: true)] {
            let client = KoAPMovementClientStub(card: card, responseURL: baseURL)
            let mgs = KoAPMovementMosGorSudStub(rows: [])
            do {
                _ = try await MovementService(
                    client: client, mosgorsud: mgs, judicialUID: uid).movement(
                        for: CaseSearchResult(caseNumber: caseNumber, cardURL: baseURL),
                        court: court, cartoteka: cart)
                XCTFail("A UID search candidate must match the fetched card's own UID")
            } catch { }
            let fetchedURLs = await client.fetchedURLs
            let mgsRequests = await mgs.requests
            XCTAssertEqual(fetchedURLs, [baseURL])
            XCTAssertTrue(mgsRequests.isEmpty,
                          "A wrong or missing own UID must stop before every higher-source request")
        }
    }

    func testPersonArticleSectionAndMultiplicityContradictionsStayPartial() async throws {
        let baseURL = try baseURL()
        let candidateURL = try candidateURL()
        let district = try XCTUnwrap(MosGorSudCourtDirectory.districtCourts.first)
        let matchingRow = MosGorSudResult(caseNumber: "12-0001/2026", uid: uid,
                                          court: district.title, section: "appeal-admin",
                                          cardURL: candidateURL)
        let court = Court(domain: MoscowMagistrateKoAPSource.host,
                          title: "Мировой судья участка \(unit)", level: .magistrate)
        let cart = try cartoteka()

        let mismatchedPeople = KoAPMovementMosGorSudStub(
            rows: [matchingRow],
            cardsByURL: [candidateURL: try appealCard(url: candidateURL,
                                                       person: "Другой синтетический участник")])
        let peopleMovement = try await MovementService(
            client: KoAPMovementClientStub(card: anchorCard(), responseURL: baseURL),
            mosgorsud: mismatchedPeople).movement(
                for: CaseSearchResult(caseNumber: caseNumber, cardURL: baseURL),
                court: court, cartoteka: cart)
        XCTAssertEqual(peopleMovement.instances.count, 1)
        XCTAssertEqual(Set(peopleMovement.incompleteHigherCourtDomains ?? []),
                       Set([MoscowMagistrateKoAPSource.host, MosGorSudEndpoint.host]))

        let mismatchedArticle = KoAPMovementMosGorSudStub(
            rows: [matchingRow],
            cardsByURL: [candidateURL: try appealCard(url: candidateURL,
                                                       category: "Статья 12.9 ч. 1 КоАП РФ")])
        let articleMovement = try await MovementService(
            client: KoAPMovementClientStub(card: anchorCard(), responseURL: baseURL),
            mosgorsud: mismatchedArticle).movement(
                for: CaseSearchResult(caseNumber: caseNumber, cardURL: baseURL),
                court: court, cartoteka: cart)
        XCTAssertEqual(articleMovement.instances.count, 1)
        XCTAssertEqual(Set(articleMovement.incompleteHigherCourtDomains ?? []),
                       Set([MoscowMagistrateKoAPSource.host, MosGorSudEndpoint.host]))

        let contradictorySection = MosGorSudResult(
            caseNumber: matchingRow.caseNumber, uid: uid, court: district.title,
            section: "appeal-civil", cardURL: candidateURL)
        let sectionStub = KoAPMovementMosGorSudStub(
            rows: [contradictorySection],
            cardsByURL: [candidateURL: try appealCard(url: candidateURL)])
        let sectionMovement = try await MovementService(
            client: KoAPMovementClientStub(card: anchorCard(), responseURL: baseURL),
            mosgorsud: sectionStub).movement(
                for: CaseSearchResult(caseNumber: caseNumber, cardURL: baseURL),
                court: court, cartoteka: cart)
        XCTAssertEqual(sectionMovement.instances.count, 1)
        let sectionFetchedURLs = await sectionStub.fetchedURLs
        XCTAssertTrue(sectionFetchedURLs.isEmpty)

        let ambiguous = KoAPMovementMosGorSudStub(rows: [matchingRow, matchingRow],
                                                   cardsByURL: [candidateURL: try appealCard(url: candidateURL)])
        let ambiguousMovement = try await MovementService(
            client: KoAPMovementClientStub(card: anchorCard(), responseURL: baseURL),
            mosgorsud: ambiguous).movement(
                for: CaseSearchResult(caseNumber: caseNumber, cardURL: baseURL),
                court: court, cartoteka: cart)
        XCTAssertEqual(ambiguousMovement.instances.count, 1)
        XCTAssertEqual(Set(ambiguousMovement.incompleteHigherCourtDomains ?? []),
                       Set([MoscowMagistrateKoAPSource.host, MosGorSudEndpoint.host]))
        let ambiguousFetchedURLs = await ambiguous.fetchedURLs
        XCTAssertTrue(ambiguousFetchedURLs.isEmpty)
    }

    func testEmptyUIDListingRemainsPartialUntilMGSCompletenessIsKnown() async throws {
        let url = try baseURL()
        let client = KoAPMovementClientStub(card: CaseCard(
            rawText: "Synthetic Moscow magistrate card", actText: nil,
            uid: uid, caseNumber: caseNumber), responseURL: url)
        let mgs = KoAPMovementMosGorSudStub(rows: [])
        let service = MovementService(client: client, mosgorsud: mgs)

        let movement = try await service.movement(
            for: CaseSearchResult(caseNumber: caseNumber, cardURL: url),
            court: Court(domain: MoscowMagistrateKoAPSource.host,
                         title: "Мировой судья участка \(unit)", level: .magistrate),
            cartoteka: cartoteka())

        XCTAssertEqual(movement.instances.count, 1)
        XCTAssertEqual(movement.instances[0].sourceURL, url)
        XCTAssertEqual(Set(movement.incompleteHigherCourtDomains ?? []),
                       Set([MoscowMagistrateKoAPSource.host, MosGorSudEndpoint.host]))
        XCTAssertTrue(movement.honestZeroDomains?.isEmpty == true)
        let coverage = try XCTUnwrap(movement.sourceRefreshCoverage?.first {
            $0.sourceFamily == "mosgorsud"
        })
        XCTAssertEqual(coverage.kind, .partial)
    }

    func testSectionFilteredMGSRowsDoNotBecomeHonestZero() async throws {
        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: "search-mgs-participant", withExtension: "html",
            subdirectory: "Fixtures/mosgorsud"))
        let html = try Data(contentsOf: fixtureURL)
        KoAPStaticMosGorSudURLProtocol.install(body: html)
        defer { KoAPStaticMosGorSudURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.protocolClasses = [KoAPStaticMosGorSudURLProtocol.self]
        let mgs = MosGorSudClient(session: URLSession(configuration: configuration), minInterval: 0)
        let baseURL = try baseURL()
        let service = MovementService(
            client: KoAPMovementClientStub(card: anchorCard(), responseURL: baseURL),
            mosgorsud: mgs)

        let movement = try await service.movement(
            for: CaseSearchResult(caseNumber: caseNumber, cardURL: baseURL),
            court: Court(domain: MoscowMagistrateKoAPSource.host,
                         title: "Мировой судья участка \(unit)", level: .magistrate),
            cartoteka: cartoteka())

        XCTAssertEqual(movement.instances.count, 1,
                       "Fixture contains another MGS section, not an own appeal")
        XCTAssertEqual(Set(movement.incompleteHigherCourtDomains ?? []),
                       Set([MoscowMagistrateKoAPSource.host, MosGorSudEndpoint.host]))
        XCTAssertTrue(movement.honestZeroDomains?.isEmpty == true)
        XCTAssertTrue(movement.sourceRefreshCoverage?.filter {
            $0.sourceFamily == "mosgorsud"
        }.allSatisfy { $0.kind == .partial } == true)
    }

    func testMGSRedirectToDifferentNativeCardIsNotLinked() async throws {
        let baseURL = try baseURL()
        let rsURL = try candidateURL()
        let otherUUID = "22222222-2222-4222-8222-222222222222"
        let redirectedURL = try XCTUnwrap(URL(string:
            "https://mos-gorsud.ru/rs/\(rsURL.pathComponents[2])/services/cases/appeal-admin/details/\(otherUUID)"))
        let district = try XCTUnwrap(MosGorSudCourtDirectory.districtCourts.first)
        let row = MosGorSudResult(caseNumber: "12-0001/2026", uid: uid,
                                  court: district.title, section: "appeal-admin", cardURL: rsURL)
        let mgs = KoAPMovementMosGorSudStub(
            rows: [row],
            cardsByURL: [rsURL: try appealCard(url: rsURL)],
            responseURLsByURL: [rsURL: redirectedURL])
        let movement = try await MovementService(
            client: KoAPMovementClientStub(card: anchorCard(), responseURL: baseURL),
            mosgorsud: mgs).movement(
                for: CaseSearchResult(caseNumber: caseNumber, cardURL: baseURL),
                court: Court(domain: MoscowMagistrateKoAPSource.host,
                             title: "Мировой судья участка \(unit)", level: .magistrate),
                cartoteka: cartoteka())

        XCTAssertFalse(movement.instances.contains { $0.level == .appeal })
        XCTAssertTrue(movement.incompleteHigherCourtDomains?.contains(MosGorSudEndpoint.host) == true)
        let fetchedURLs = await mgs.fetchedURLs
        XCTAssertEqual(fetchedURLs, [rsURL])
    }

    func testDirectoryLoaderRejectsExternalRedirect() async throws {
        let destination = try XCTUnwrap(URL(string: "https://example.test/away"))
        KoAPRedirectingMosGorSudURLProtocol.install(
            from: MoscowMagistrateKoAPSource.homeURL, to: destination,
            body: Data("<html></html>".utf8))
        defer { KoAPRedirectingMosGorSudURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.protocolClasses = [KoAPRedirectingMosGorSudURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = MoscowMagistrateKoAPClient(session: session, minInterval: 0, maxAttempts: 1)
        do {
            _ = try await client.fetchDirectory()
            XCTFail("A directory response redirected off the source host")
        } catch { }
        XCTAssertTrue(KoAPRedirectingMosGorSudURLProtocol.requestedURLs.contains(destination))
    }

    func testMosGorSudClientReturnsEffectiveCardURLAfterRedirect() async throws {
        let requestedURL = try candidateURL()
        let targetUUID = "22222222-2222-4222-8222-222222222222"
        let finalURL = try XCTUnwrap(URL(string:
            "https://mos-gorsud.ru/rs/\(requestedURL.pathComponents[2])/services/cases/appeal-admin/details/\(targetUUID)"))
        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: "issue413-appeal-2021", withExtension: "html",
            subdirectory: "Fixtures/mosgorsud"))
        let html = try Data(contentsOf: fixtureURL)
        KoAPRedirectingMosGorSudURLProtocol.install(from: requestedURL, to: finalURL, body: html)
        defer { KoAPRedirectingMosGorSudURLProtocol.reset() }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.protocolClasses = [KoAPRedirectingMosGorSudURLProtocol.self]
        let client = MosGorSudClient(session: URLSession(configuration: configuration), minInterval: 0)
        let fetched = try await client.fetchCardWithResponseURL(url: requestedURL)
        XCTAssertEqual(fetched.responseURL, finalURL)
        XCTAssertNotNil(fetched.card.caseNumber)
    }

    func testRejectsWrongSourceURLAndMismatchedFetchedIdentity() async throws {
        let validURL = try baseURL()
        let court = Court(domain: MoscowMagistrateKoAPSource.host,
                          title: "Мировой судья участка \(unit)", level: .magistrate)
        let cart = try cartoteka()

        let wrongHost = try XCTUnwrap(URL(string:
            "https://example.test/\(unit)/cases/admin/details/\(cardID)"))
        let untouchedClient = KoAPMovementClientStub(card: CaseCard(
            rawText: "Synthetic card", actText: nil, uid: uid,
            caseNumber: caseNumber), responseURL: wrongHost)
        let untouchedService = MovementService(client: untouchedClient)
        do {
            _ = try await untouchedService.movement(
                for: CaseSearchResult(caseNumber: caseNumber, cardURL: wrongHost),
                court: court, cartoteka: cart)
            XCTFail("A non-source URL must be rejected")
        } catch { }
        let wrongHostFetches = await untouchedClient.fetchedURLs
        XCTAssertTrue(wrongHostFetches.isEmpty)

        let redirectedURL = try XCTUnwrap(URL(string:
            "https://mos-sud.ru/425/cases/admin/details/\(cardID)"))
        let redirectedClient = KoAPMovementClientStub(card: CaseCard(
            rawText: "Synthetic card", actText: nil, uid: uid,
            caseNumber: caseNumber), responseURL: redirectedURL)
        let redirectedService = MovementService(client: redirectedClient)
        do {
            _ = try await redirectedService.movement(
                for: CaseSearchResult(caseNumber: caseNumber, cardURL: validURL),
                court: court, cartoteka: cart)
            XCTFail("A card response from another unit must not establish identity")
        } catch { }

        let wrongNumberClient = KoAPMovementClientStub(card: CaseCard(
            rawText: "Synthetic card", actText: nil, uid: uid,
            caseNumber: "05-9999/424/2026"), responseURL: validURL)
        let wrongNumberService = MovementService(client: wrongNumberClient)
        do {
            _ = try await wrongNumberService.movement(
                for: CaseSearchResult(caseNumber: caseNumber, cardURL: validURL),
                court: court, cartoteka: cart)
            XCTFail("A fetched card with a different own case number must not establish identity")
        } catch { }
    }

    func testDistrictAppealLocatorAcceptsOnlyPublishedRSAdminSection() throws {
        let district = try XCTUnwrap(MosGorSudCourtDirectory.districtCourts.first)
        let uuid = "11111111-1111-4111-8111-111111111111"
        let accepted = try XCTUnwrap(URL(string:
            "https://mos-gorsud.ru/rs/\(district.alias)/services/cases/appeal-admin/details/\(uuid)"))
        let locator = try XCTUnwrap(SourceNativeCardLocator.moscowMagistrateKoAPAppeal(url: accepted))
        XCTAssertEqual(locator.identity.sourceFamily, "mosgorsud")
        XCTAssertEqual(locator.identity.courtKey, district.alias)
        XCTAssertEqual(locator.identity.cartotekaKey, "admj")
        XCTAssertEqual(locator.identity.sourceNativeID, uuid)

        for raw in [
            "https://mos-gorsud.ru/mgs/services/cases/appeal-admin/details/\(uuid)",
            "https://mos-gorsud.ru/rs/\(district.alias)/services/cases/appeal-civil/details/\(uuid)",
            "https://mos-gorsud.ru/rs/unknown/services/cases/appeal-admin/details/\(uuid)",
            "http://mos-gorsud.ru/rs/\(district.alias)/services/cases/appeal-admin/details/\(uuid)",
            "https://user@mos-gorsud.ru/rs/\(district.alias)/services/cases/appeal-admin/details/\(uuid)"
        ] {
            XCTAssertNil(SourceNativeCardLocator.moscowMagistrateKoAPAppeal(
                url: try XCTUnwrap(URL(string: raw))), raw)
        }
    }

    func testMGSReviewLinksOnlyThroughItsPublishedLowerNumber() async throws {
        let baseURL = try baseURL()
        let rsURL = try candidateURL()
        let mgsURL = try reviewURL()
        let district = try XCTUnwrap(MosGorSudCourtDirectory.districtCourts.first)
        let rsRow = MosGorSudResult(caseNumber: "12-0001/2026", uid: uid,
                                    court: district.title, section: "appeal-admin",
                                    cardURL: rsURL)
        let mgsRow = MosGorSudResult(caseNumber: "4а-35/2026", uid: uid,
                                     court: "Московский городской суд",
                                     section: "review-supervision", cardURL: mgsURL)
        let mgs = KoAPMovementMosGorSudStub(
            rowsByInstance: [MosGorSudInstance.appeal: [rsRow],
                             MosGorSudInstance.review: [mgsRow]],
            cardsByURL: [rsURL: try appealCard(url: rsURL),
                         mgsURL: try reviewCard(lowerNumber: rsRow.caseNumber)])
        let service = MovementService(
            client: KoAPMovementClientStub(card: anchorCard(), responseURL: baseURL),
            mosgorsud: mgs)

        let movement = try await service.movement(
            for: CaseSearchResult(caseNumber: caseNumber, cardURL: baseURL),
            court: Court(domain: MoscowMagistrateKoAPSource.host,
                         title: "Мировой судья участка \(unit)", level: .magistrate),
            cartoteka: cartoteka())

        XCTAssertEqual(movement.instances.map(\.level), [.first, .appeal, .supervisory])
        let review = try XCTUnwrap(movement.instances.last)
        XCTAssertEqual(review.caseNumber, mgsRow.caseNumber)
        XCTAssertEqual(review.sourceURL, mgsURL)
        XCTAssertEqual(review.sourceEvidence?.cartotekaID, "adm33")
        XCTAssertEqual(review.sourceEvidence?.lowerCourt?.caseNumber, rsRow.caseNumber)
        XCTAssertEqual(movement.incompleteHigherCourtDomains, [MoscowMagistrateKoAPSource.host])
        let magistrateCoverage = try XCTUnwrap(movement.sourceRefreshCoverage?.first {
            $0.sourceFamily == MoscowMagistrateKoAPSource.family
                && $0.courtKey == unit
        })
        XCTAssertEqual(magistrateCoverage.kind, .partial)
        XCTAssertEqual(SourceOutcomeClassifier.attempt(
            for: movement, sourceFamily: MoscowMagistrateKoAPSource.family,
            host: MoscowMagistrateKoAPSource.host).kind, .partial)
        let coverage = try XCTUnwrap(movement.sourceRefreshCoverage?.first {
            $0.sourceFamily == "mosgorsud" && $0.courtKey == MosGorSudCourtDirectory.mgsAlias
        })
        XCTAssertEqual(coverage.kind, .usableSnapshot)
        XCTAssertTrue(coverage.loadedCardIdentities.contains {
            $0.cartotekaKey == "adm33" && $0.sourceNativeID == cardID.lowercased()
        })
        let requests = await mgs.requests
        XCTAssertEqual(requests.map(\.instance), [MosGorSudInstance.appeal,
                                                  MosGorSudInstance.review])
    }

    func testMGSReviewNeedsExactLowerNumberAndExactReviewSection() async throws {
        let baseURL = try baseURL()
        let rsURL = try candidateURL()
        let mgsURL = try reviewURL()
        let district = try XCTUnwrap(MosGorSudCourtDirectory.districtCourts.first)
        let rsRow = MosGorSudResult(caseNumber: "12-0001/2026", uid: uid,
                                    court: district.title, section: "appeal-admin",
                                    cardURL: rsURL)
        let reviewRow = MosGorSudResult(caseNumber: "4а-35/2026", uid: uid,
                                        court: "Московский городской суд",
                                        section: "review-supervision", cardURL: mgsURL)
        let court = Court(domain: MoscowMagistrateKoAPSource.host,
                          title: "Мировой судья участка \(unit)", level: .magistrate)
        let cart = try cartoteka()

        for lowerNumber in ["4а-999/2026", nil] {
            let stub = KoAPMovementMosGorSudStub(
                rowsByInstance: [MosGorSudInstance.appeal: [rsRow],
                                 MosGorSudInstance.review: [reviewRow]],
                cardsByURL: [rsURL: try appealCard(url: rsURL),
                             mgsURL: try reviewCard(lowerNumber: lowerNumber)])
            let movement = try await MovementService(
                client: KoAPMovementClientStub(card: anchorCard(), responseURL: baseURL),
                mosgorsud: stub).movement(
                    for: CaseSearchResult(caseNumber: caseNumber, cardURL: baseURL),
                    court: court, cartoteka: cart)
            XCTAssertEqual(movement.instances.map(\.level), [.first, .appeal])
            XCTAssertTrue(movement.incompleteHigherCourtDomains?.contains(MosGorSudEndpoint.host) == true)
        }

        let wrongSection = MosGorSudResult(caseNumber: reviewRow.caseNumber, uid: uid,
                                           section: "appeal-admin", cardURL: mgsURL)
        let stub = KoAPMovementMosGorSudStub(
            rowsByInstance: [MosGorSudInstance.appeal: [rsRow],
                             MosGorSudInstance.review: [wrongSection]],
            cardsByURL: [rsURL: try appealCard(url: rsURL),
                         mgsURL: try reviewCard(lowerNumber: rsRow.caseNumber)])
        let movement = try await MovementService(
            client: KoAPMovementClientStub(card: anchorCard(), responseURL: baseURL),
            mosgorsud: stub).movement(
                for: CaseSearchResult(caseNumber: caseNumber, cardURL: baseURL),
                court: court, cartoteka: cart)
        XCTAssertEqual(movement.instances.map(\.level), [.first, .appeal])
        let fetchedURLs = await stub.fetchedURLs
        XCTAssertEqual(fetchedURLs, [rsURL])
    }

    func testMGSReviewMayPointDirectlyToTheVerifiedMagistrateNumber() async throws {
        let baseURL = try baseURL()
        let mgsURL = try reviewURL()
        let mgsRow = MosGorSudResult(caseNumber: "4а-35/2026", uid: uid,
                                     court: "Московский городской суд",
                                     section: "review-supervision", cardURL: mgsURL)
        let stub = KoAPMovementMosGorSudStub(
            rowsByInstance: [MosGorSudInstance.review: [mgsRow]],
            cardsByURL: [mgsURL: try reviewCard(lowerNumber: "5-42/424/2026")])
        let movement = try await MovementService(
            client: KoAPMovementClientStub(card: anchorCard(), responseURL: baseURL),
            mosgorsud: stub).movement(
                for: CaseSearchResult(caseNumber: "5-42/424/2026", cardURL: baseURL),
                court: Court(domain: MoscowMagistrateKoAPSource.host,
                             title: "Мировой судья участка \(unit)", level: .magistrate),
                cartoteka: cartoteka())

        XCTAssertEqual(movement.instances.map(\.level), [.first, .supervisory])
        XCTAssertEqual(movement.instances.last?.sourceEvidence?.lowerCourt?.caseNumber,
                       "5-42/424/2026")
    }

    func testMagistratePaddingNormalizationRetainsUnitAndYear() async throws {
        let baseURL = try baseURL()
        let reviewURL = try reviewURL()
        let row = MosGorSudResult(caseNumber: "4а-35/2026", uid: uid,
                                  court: "Московский городской суд",
                                  section: "review-supervision", cardURL: reviewURL)
        let court = Court(domain: MoscowMagistrateKoAPSource.host,
                          title: "Мировой судья участка \(unit)", level: .magistrate)
        let cart = try cartoteka()

        for lowerNumber in ["5-42/425/2026", "5-42/424/2025"] {
            let stub = KoAPMovementMosGorSudStub(
                rowsByInstance: [MosGorSudInstance.review: [row]],
                cardsByURL: [reviewURL: try reviewCard(lowerNumber: lowerNumber)])
            let movement = try await MovementService(
                client: KoAPMovementClientStub(card: anchorCard(), responseURL: baseURL),
                mosgorsud: stub).movement(
                    for: CaseSearchResult(caseNumber: caseNumber, cardURL: baseURL),
                    court: court, cartoteka: cart)
            XCTAssertFalse(movement.instances.contains { $0.level == .supervisory }, lowerNumber)
            XCTAssertTrue(movement.incompleteHigherCourtDomains?.contains(MosGorSudEndpoint.host) == true)
        }

        let wrongUnitCard = anchorCard(number: "05-0042/425/2026")
        do {
            _ = try await MovementService(
                client: KoAPMovementClientStub(card: wrongUnitCard, responseURL: baseURL),
                mosgorsud: KoAPMovementMosGorSudStub(rows: [])).movement(
                    for: CaseSearchResult(caseNumber: "5-42/424/2026", cardURL: baseURL),
                    court: court, cartoteka: cart)
            XCTFail("A different published magistrate unit must not match")
        } catch { }
    }

    func testMoscowMagistrateKoAPReviewLocatorAcceptsOnlyMGSReviewSupervision() throws {
        let uuid = "11111111-1111-4111-8111-111111111111"
        let accepted = try reviewURL()
        let locator = try XCTUnwrap(SourceNativeCardLocator.moscowMagistrateKoAPReview(url: accepted))
        XCTAssertEqual(locator.identity.sourceFamily, "mosgorsud")
        XCTAssertEqual(locator.identity.courtKey, MosGorSudCourtDirectory.mgsAlias)
        XCTAssertEqual(locator.identity.cartotekaKey, "adm33")
        XCTAssertEqual(locator.identity.sourceNativeID, uuid)

        for raw in [
            "https://mos-gorsud.ru/rs/cheremushkinskij/services/cases/review-supervision/details/\(uuid)",
            "https://mos-gorsud.ru/mgs/services/cases/appeal-admin/details/\(uuid)",
            "https://mos-gorsud.ru/mgs/services/cases/review-supervision/details/not-a-uuid",
            "http://mos-gorsud.ru/mgs/services/cases/review-supervision/details/\(uuid)",
            "https://user@mos-gorsud.ru/mgs/services/cases/review-supervision/details/\(uuid)"
        ] {
            XCTAssertNil(SourceNativeCardLocator.moscowMagistrateKoAPReview(
                url: try XCTUnwrap(URL(string: raw))), raw)
        }
    }

    func testMoscowMagistrateUsesFederalProviderForKSOYUAndSupremeSearches() async throws {
        let baseURL = try baseURL()
        let federal = KoAPFederalProviderSpy()
        let vsrf = KoAPVSRFProviderSpy()
        let local = KoAPMovementClientStub(card: anchorCard(), responseURL: baseURL)
        let target = MovementSearchTarget(
            domain: "3kas.sudrf.ru", courtTitle: "Третий кассационный суд общей юрисдикции",
            courtLevel: .cassation, instanceLevel: .cassation, cartotekaIDs: ["adm3"])
        let service = MovementService(
            client: local, higherCourtTargets: [target], vsrf: vsrf,
            mosgorsud: KoAPMovementMosGorSudStub(rows: []), magistrate: federal)

        let movement = try await service.movement(
            for: CaseSearchResult(caseNumber: caseNumber, cardURL: baseURL),
            court: Court(domain: MoscowMagistrateKoAPSource.host,
                         title: "Мировой судья участка \(unit)", level: .magistrate),
            cartoteka: cartoteka())

        let federalRequests = await federal.requests
        XCTAssertEqual(federalRequests.map(\.domain), ["3kas.sudrf.ru"])
        XCTAssertEqual(federalRequests.map(\.cartotekaID), ["adm3"])
        XCTAssertTrue(federalRequests.allSatisfy {
            $0.field == .uid && $0.value == uid
        })
        let localSearches = await local.searchDomains
        XCTAssertTrue(localSearches.isEmpty,
                      "The Moscow-only provider must not receive federal domains")
        let supremeRequests = await vsrf.requests
        XCTAssertEqual(supremeRequests.count, 2)
        XCTAssertEqual(supremeRequests.first?.uniqueNumber, uid)
        XCTAssertNil(supremeRequests.first?.oldCaseNumber)
        XCTAssertNil(supremeRequests.last?.uniqueNumber)
        XCTAssertEqual(supremeRequests.last?.oldCaseNumber, caseNumber)
        XCTAssertTrue(movement.honestZeroDomains?.contains("3kas.sudrf.ru") == true)
    }
}

private actor KoAPMovementClientStub: CaseProviding {
    private let card: CaseCard
    private let responseURL: URL
    private(set) var fetchedURLs: [URL] = []
    private(set) var searchDomains: [String] = []

    init(card: CaseCard, responseURL: URL) {
        self.card = card
        self.responseURL = responseURL
    }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        searchDomains.append(court.domain)
        guard court.domain == MoscowMagistrateKoAPSource.host else {
            throw SudrfError.searchModuleUnavailable(domain: court.domain)
        }
        return []
    }

    func searchOutcome(court: Court, cartoteka: Cartoteka,
                      field: SearchField, value: String,
                      operation: SourceOperation) async throws
        -> SourceOutcome<[CaseSearchResult]> {
        searchDomains.append(court.domain)
        guard court.domain == MoscowMagistrateKoAPSource.host else {
            throw SudrfError.searchModuleUnavailable(domain: court.domain)
        }
        return .honestZero(SourceAttempt(kind: .honestZero,
                                         provenance: SourceProvenance(
                                            operation: operation,
                                            sourceFamily: MoscowMagistrateKoAPSource.family,
                                            host: MoscowMagistrateKoAPSource.host)))
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard { card }

    func fetchCard(url: URL) async throws -> CaseCard {
        fetchedURLs.append(url)
        return card
    }

    func fetchCardWithResponseURL(url: URL) async throws -> SudrfCaseCardFetchResult {
        fetchedURLs.append(url)
        return SudrfCaseCardFetchResult(card: card, responseURL: responseURL)
    }
}

private actor KoAPMovementMosGorSudStub: MosGorSudProviding, MosGorSudCardResponseProviding {
    struct Request: Sendable {
        var uid: String?
        var caseNumber: String?
        var instance: Int
        var processType: MosGorSudProcessType
    }

    private let rowsByInstance: [Int: [MosGorSudResult]]
    private let cardsByURL: [URL: MosGorSudCard]
    private let responseURLsByURL: [URL: URL]
    private(set) var requests: [Request] = []
    private(set) var fetchedURLs: [URL] = []

    init(rows: [MosGorSudResult], cardsByURL: [URL: MosGorSudCard] = [:],
         responseURLsByURL: [URL: URL] = [:]) {
        self.rowsByInstance = [MosGorSudInstance.appeal: rows]
        self.cardsByURL = cardsByURL
        self.responseURLsByURL = responseURLsByURL
    }

    init(rowsByInstance: [Int: [MosGorSudResult]],
         cardsByURL: [URL: MosGorSudCard] = [:],
         responseURLsByURL: [URL: URL] = [:]) {
        self.rowsByInstance = rowsByInstance
        self.cardsByURL = cardsByURL
        self.responseURLsByURL = responseURLsByURL
    }

    func search(courtAlias: String?, uid: String?, caseNumber: String?,
                participant: String?, instance: Int,
                processType: MosGorSudProcessType) async throws -> [MosGorSudResult] {
        requests.append(Request(uid: uid, caseNumber: caseNumber,
                                instance: instance, processType: processType))
        return rowsByInstance[instance] ?? []
    }

    func fetchCard(url: URL) async throws -> MosGorSudCard {
        fetchedURLs.append(url)
        return cardsByURL[url] ?? MosGorSudCard(caseNumber: "12-0001/2026",
                                                rawText: "Synthetic candidate")
    }

    func fetchCardWithResponseURL(url: URL) async throws -> MosGorSudCardFetchResult {
        fetchedURLs.append(url)
        let card = cardsByURL[url] ?? MosGorSudCard(caseNumber: "12-0001/2026",
                                                    rawText: "Synthetic candidate")
        return MosGorSudCardFetchResult(card: card, responseURL: responseURLsByURL[url] ?? url)
    }

    func fetchPublishedAct(url: URL) async throws -> PublishedActFile {
        throw PublishedActFileError.extractionFailed
    }
}

private actor KoAPFederalProviderSpy: CaseProviding {
    struct Request: Sendable {
        var domain: String
        var cartotekaID: String
        var field: SearchField
        var value: String
    }

    private(set) var requests: [Request] = []

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        requests.append(Request(domain: court.domain, cartotekaID: cartoteka.id,
                                field: field, value: value))
        return []
    }

    func searchOutcome(court: Court, cartoteka: Cartoteka,
                       field: SearchField, value: String,
                       operation: SourceOperation) async throws
        -> SourceOutcome<[CaseSearchResult]> {
        requests.append(Request(domain: court.domain, cartotekaID: cartoteka.id,
                                field: field, value: value))
        return .honestZero(SourceAttempt(
            kind: .honestZero,
            provenance: SourceProvenance(operation: operation,
                                         sourceFamily: "sudrf", host: court.domain)))
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        throw SudrfError.caseCardTemporarilyUnavailable
    }

    func fetchCard(url: URL) async throws -> CaseCard {
        throw SudrfError.caseCardTemporarilyUnavailable
    }
}

private actor KoAPVSRFProviderSpy: VSRFProviding {
    struct Request: Sendable {
        var uniqueNumber: String?
        var oldCaseNumber: String?
        var keywords: String?
    }

    private(set) var requests: [Request] = []

    func search(uniqueNumber: String?, oldCaseNumber: String?,
                keywords: String?) async throws -> VSRFSearchResults {
        requests.append(Request(uniqueNumber: uniqueNumber,
                                oldCaseNumber: oldCaseNumber,
                                keywords: keywords))
        return VSRFSearchResults(total: 0, results: [])
    }

    func fetchCard(productionID: String, section: VSRFCardSection) async throws -> VSRFCard {
        throw SudrfError.caseCardTemporarilyUnavailable
    }
}

private final class KoAPStaticMosGorSudURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var body: Data?

    static func install(body: Data) {
        lock.lock()
        self.body = body
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        body = nil
        lock.unlock()
    }

    private static func responseBody() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return body
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let body = Self.responseBody(),
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class KoAPRedirectingMosGorSudURLProtocol: URLProtocol {
    private struct Fixture {
        let from: URL
        let to: URL
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixture: Fixture?
    nonisolated(unsafe) private static var urls: [URL] = []

    static var requestedURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    static func install(from: URL, to: URL, body: Data) {
        lock.lock()
        fixture = Fixture(from: from, to: to, body: body)
        urls = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        fixture = nil
        urls = []
        lock.unlock()
    }

    private static func currentFixture() -> Fixture? {
        lock.lock()
        defer { lock.unlock() }
        return fixture
    }

    private static func record(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let fixture = Self.currentFixture() else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        Self.record(url)
        if url == fixture.from {
            guard let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                headerFields: ["Location": fixture.to.absoluteString]) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: fixture.to),
                                redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        guard url == fixture.to,
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/html; charset=utf-8"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
