import XCTest
import SudrfKit
@testable import SudrfApp

private enum RecoveryStubFailure: Sendable {
    case noCard
    case parser
    case notFound
    case transient
    case captcha
    case maintenance
    case cancelled

    func makeError() -> Error {
        switch self {
        case .noCard:
            return SudrfError.parsing("страница не содержит признаков карточки дела")
        case .parser:
            return SudrfError.parsing("SwiftSoup не смог разобрать карточку")
        case .notFound:
            return SudrfError.http(status: 404)
        case .transient:
            return SudrfError.transientNetworkError(domain: "court.sudrf.ru",
                                                     code: .timedOut, attempt: 3)
        case .captcha:
            return SudrfError.captchaRequired(
                formURL: URL(string: "https://court.sudrf.ru/modules.php?name=sud_delo")!)
        case .maintenance:
            return SudrfError.sourceMaintenance(domain: "court.sudrf.ru")
        case .cancelled:
            return CancellationError()
        }
    }
}

private actor RecoveryProviderStub: CaseProviding {
    var cards: [String: CaseCard]
    var htmlByRegister: [String: String]
    var failures: [String: RecoveryStubFailure]
    var defaultFailure: RecoveryStubFailure?
    var uidRows: [CaseSearchResult]
    var numberRows: [CaseSearchResult]
    var searchFailure: RecoveryStubFailure?
    var responseURLs: [String: URL]
    private(set) var fetchedURLs: [String] = []
    private(set) var completeSearches: [(field: String, srvNum: Int)] = []
    private(set) var legacySearchCount = 0

    init(cards: [String: CaseCard] = [:], htmlByRegister: [String: String] = [:],
         failures: [String: RecoveryStubFailure] = [:],
         defaultFailure: RecoveryStubFailure? = nil,
         uidRows: [CaseSearchResult] = [], numberRows: [CaseSearchResult] = [],
         searchFailure: RecoveryStubFailure? = nil,
         responseURLs: [String: URL] = [:]) {
        self.cards = cards
        self.htmlByRegister = htmlByRegister
        self.failures = failures
        self.defaultFailure = defaultFailure
        self.uidRows = uidRows
        self.numberRows = numberRows
        self.searchFailure = searchFailure
        self.responseURLs = responseURLs
    }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        legacySearchCount += 1
        return []
    }

    func searchComplete(court: Court, cartoteka: Cartoteka,
                        field: SearchField, value: String,
                        srvNum: Int) async throws -> [CaseSearchResult] {
        let name = fieldName(field)
        completeSearches.append((name, srvNum))
        if let searchFailure { throw searchFailure.makeError() }
        return fieldName(field) == "uid" ? uidRows : numberRows
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        throw SudrfError.http(status: 404)
    }

    func fetchCard(url: URL) async throws -> CaseCard {
        fetchedURLs.append(url.absoluteString)
        if let failure = failures[url.absoluteString] { throw failure.makeError() }
        if let card = cards[url.absoluteString] { return card }
        let register = query("delo_id", url) + "/" + (query("new", url).isEmpty ? "0" : query("new", url))
        if let html = htmlByRegister[register] {
            return try CaseCardParser.parse(html: html, cardURL: url)
        }
        if let defaultFailure { throw defaultFailure.makeError() }
        throw SudrfError.http(status: 404)
    }

    func fetchCardWithResponseURL(url: URL) async throws -> SudrfCaseCardFetchResult {
        let card = try await fetchCard(url: url)
        return SudrfCaseCardFetchResult(
            card: card, responseURL: responseURLs[url.absoluteString] ?? url)
    }

    func snapshot() -> (urls: [String], searches: [(String, Int)], legacy: Int) {
        (fetchedURLs, completeSearches.map { ($0.field, $0.srvNum) }, legacySearchCount)
    }

    private func fieldName(_ field: SearchField) -> String {
        switch field {
        case .uid: return "uid"
        case .caseNumber: return "number"
        case .name: return "name"
        }
    }

    private func query(_ name: String, _ url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
    }
}

final class CaseCardRecoveryTests: XCTestCase {
    private let komiHost = "vs--komi.sudrf.ru"

    func testWorkingOriginalURLIsReturnedUnchangedWithoutSearch() async throws {
        let url = cardURL(host: komiHost, number: "1", uid: "guid", delo: "42", new: "0")
        let card = CaseCard(rawText: "card", actText: nil,
                            uid: "11RS0001-01-2022-009001-50",
                            caseNumber: "33а-9001/2022")
        let provider = RecoveryProviderStub(cards: [url.absoluteString: card])

        let result = try await CaseCardRecovery(provider: provider).resolve(
            context: context(number: "33а-9001/2022", uid: card.uid, url: url))

        XCTAssertEqual(result.reason, .originalURL)
        XCTAssertEqual(result.verifiedURL, url)
        XCTAssertFalse(result.wasRecovered)
        let snapshot = await provider.snapshot()
        XCTAssertEqual(snapshot.urls, [url.absoluteString])
        XCTAssertTrue(snapshot.searches.isEmpty)
        XCTAssertEqual(snapshot.legacy, 0)
    }

    func testChangedSameCourtRedirectMustMatchExpectedCardBeforePersistence() async throws {
        let original = cardURL(host: komiHost, number: "old", uid: "old-guid",
                               delo: "42", new: "0")
        let redirected = cardURL(host: komiHost, number: "foreign", uid: "foreign-guid",
                                 delo: "42", new: "0")
        let foreign = CaseCard(rawText: "", actText: nil,
                               uid: "11RS0001-01-2022-999999-50",
                               caseNumber: "33а-9999/2022")
        let provider = RecoveryProviderStub(
            cards: [original.absoluteString: foreign],
            responseURLs: [original.absoluteString: redirected])

        await XCTAssertThrowsErrorAsync(
            try await CaseCardRecovery(provider: provider).resolve(
                context: context(number: "33а-9001/2022",
                                 uid: "11RS0001-01-2022-009001-50", url: original))
        ) { error in
            XCTAssertEqual(error as? CaseCardRecoveryError, .incompleteCandidates)
        }
    }

    func testKomiFixtureRepairsOnlyCartotekaParametersAndPreservesRawQuery() async throws {
        let original = URL(string: "https://\(komiHost)/modules.php?name=sud_delo&srv_num=2&name_op=case&case_id=101&case_uid=guid&delo_id=5&new=5&legacy=%CF%F0&note=a%20b")!
        let provider = RecoveryProviderStub(htmlByRegister: [
            "5/5": try fixture("komi-original"),
            "42/0": try fixture("komi-recovered")
        ])

        let result = try await CaseCardRecovery(provider: provider).resolve(
            context: context(number: "33а-9001/2022",
                             uid: "11RS0001-01-2022-009001-50", url: original))

        XCTAssertEqual(result.reason, .cartotekaParameters)
        XCTAssertEqual(result.card.caseNumber, "33а-9001/2022")
        XCTAssertEqual(result.card.sessions.count, 3)
        XCTAssertTrue(result.verifiedURL.absoluteString.contains("delo_id=42&new=0"))
        XCTAssertTrue(result.verifiedURL.absoluteString.contains("srv_num=2"))
        XCTAssertTrue(result.verifiedURL.absoluteString.contains("legacy=%CF%F0"))
        XCTAssertTrue(result.verifiedURL.absoluteString.contains("note=a%20b"))
        XCTAssertEqual(result.context.cartotekaId, "p2")
        XCTAssertEqual(result.context.sourceKnownCard?.deloID, "42")
        XCTAssertEqual(result.context.sourceKnownCard?.new, "0")
    }

    func testAppealFixtureRepairsLegacyParametersWithoutJudicialUID() async throws {
        let host = "1ap.sudrf.ru"
        let original = cardURL(host: host, number: "202", uid: "appeal-guid",
                               delo: "5", new: "5", srvNum: 1)
        let provider = RecoveryProviderStub(htmlByRegister: [
            "5/5": try fixture("appeal-original"),
            "42/0": try fixture("appeal-recovered")
        ])
        var value = context(number: "66а-9002/2020", uid: nil, url: original,
                            host: host, level: .appeal)
        value.courtTitle = "Первый апелляционный суд общей юрисдикции"

        let result = try await CaseCardRecovery(provider: provider).resolve(context: value)

        XCTAssertEqual(result.reason, .cartotekaParameters)
        XCTAssertNil(result.card.uid)
        XCTAssertEqual(result.card.caseNumber, "66а-9002/2020")
        XCTAssertEqual(result.context.cartotekaId, "p2")
    }

    func testKSOYUCompositeFixturesRecoverDirectlyWithoutSearch() async throws {
        let examples: [(fixture: String, host: String, caseID: String, caseUID: String,
                        expected: String, published: String, judicialUID: String?)] = [
            ("kas-4018", "3kas.sudrf.ru", "3304334",
             "856b772d-bb2d-4960-bd53-fc536bb33450",
             "88а-4018/2021", "8а-2564/2021 [88а-4018/2021]",
             "11OS0000-01-2020-000019-50"),
            ("kas-1001", "3kas.sudrf.ru", "73968",
             "cc38a8b0-e5fc-4b6e-9996-d143a38d861a",
             "88а-1001/2019", "8а-1231/2019 [88а-1001/2019]",
             "78RS0017-01-2019-005288-56"),
            ("kas-4154", "3kas.sudrf.ru", "110339",
             "18d78c0e-7435-4eca-82c3-cc5b570bd0db",
             "88а-4154/2020", "8а-1494/2020 [88а-4154/2020]", nil),
            ("kas-8501", "2kas.sudrf.ru", "2723657",
             "576e5fae-ee46-434a-99eb-5956562963b0",
             "88а-8501/2022", "8а-7078/2022 [88а-8501/2022]",
             "77RS0030-02-2021-008181-07")
        ]

        for example in examples {
            let original = cardURL(
                host: example.host, number: example.caseID, uid: example.caseUID,
                delo: "2800001", new: "2800001")
            let provider = RecoveryProviderStub(htmlByRegister: [
                "2800001/2800001": try compositeFixture("invalid-format"),
                "43/0": try compositeFixture(example.fixture)
            ])
            let value = context(
                number: example.expected, uid: example.judicialUID, url: original,
                host: example.host, level: .cassation, cartotekaID: "p3")

            let result = try await CaseCardRecovery(provider: provider).resolve(context: value)

            XCTAssertEqual(result.reason, .cartotekaParameters, example.fixture)
            XCTAssertEqual(result.card.caseNumber, example.published, example.fixture)
            XCTAssertFalse(result.card.sessions.isEmpty, example.fixture)
            XCTAssertTrue(result.verifiedURL.absoluteString.contains("delo_id=43"))
            XCTAssertTrue(result.verifiedURL.absoluteString.contains("new=0"))
            XCTAssertEqual(result.context.cartotekaId, "p3")
            let calls = await provider.snapshot()
            XCTAssertEqual(calls.urls.count, 2, example.fixture)
            XCTAssertTrue(calls.searches.isEmpty, example.fixture)

            let replayProvider = RecoveryProviderStub(cards: [
                result.verifiedURL.absoluteString: result.card
            ])
            let replay = try await CaseCardRecovery(provider: replayProvider).resolve(
                context: result.context)
            XCTAssertEqual(replay.reason, .originalURL, example.fixture)
            let replayCalls = await replayProvider.snapshot()
            XCTAssertTrue(replayCalls.searches.isEmpty, example.fixture)
        }
    }

    func testKSOYUCompositeMatcherCoversAllPublishedNumberFamilies() throws {
        let cases = [
            ("8-1/2026 [88-2/2026]", "88-2/2026", "g3"),
            ("8Г-1/2026 [88-2/2026]", "88-2/2026", "g3"),
            ("8A-1/2026 [88А-2/2026]", "88а-2/2026", "p3"),
            ("7-1/2026 [77-2/2026]", "77-2/2026", "u3"),
            ("7-1/2026 [77У-2/2026]", "77у-2/2026", "u3"),
            ("7У-1/2026 [77-2/2026]", "77-2/2026", "u3"),
            ("7У-1/2026 [77У-2/2026]", "77у-2/2026", "u3")
        ]

        for (published, expected, cartotekaID) in cases {
            let cartoteka = try XCTUnwrap(
                CartotekaRegistry.find(level: .cassation, id: cartotekaID))
            let value = ksoyuContext(number: expected, cartotekaID: cartotekaID)
            XCTAssertTrue(CaseCardRecovery.matchesRecoveryCaseNumber(
                published, expected: "№ \(expected.uppercased())",
                context: value, cartoteka: cartoteka), published)
            XCTAssertTrue(CaseCardRecovery.matchesRecoveryCaseNumber(
                published, expected: published,
                context: value, cartoteka: cartoteka), published)
        }
    }

    func testKSOYUCompositeMatcherRejectsMalformedOrContradictoryEvidence() throws {
        let p3 = try XCTUnwrap(CartotekaRegistry.find(level: .cassation, id: "p3"))
        let expected = "88а-2/2026"
        let value = ksoyuContext(number: expected, cartotekaID: "p3")
        let rejected = [
            "8а-1/2026[88а-2/2026]",
            "8а-1/2026 [88а-2/2026",
            "8а-1/2026 [88а-2/2026] [88а-2/2026]",
            "8а-1/2026 [88а-2/2026] продолжение",
            "8а-1/2026 [88а-3/2026]",
            "8а-1/2026 [88-2/2026]",
            "8а-1/2026 [88а-2/26]",
            "текст 8а-1/2026 [88а-2/2026]"
        ]
        for published in rejected {
            XCTAssertFalse(CaseCardRecovery.matchesRecoveryCaseNumber(
                published, expected: expected, context: value, cartoteka: p3), published)
        }

        let g3 = try XCTUnwrap(CartotekaRegistry.find(level: .cassation, id: "g3"))
        XCTAssertFalse(CaseCardRecovery.matchesRecoveryCaseNumber(
            "8а-1/2026 [88а-2/2026]", expected: expected,
            context: value, cartoteka: g3))
        let unknownCourt = context(
            number: expected, uid: nil,
            url: cardURL(host: "unknown.sudrf.ru", number: "1", uid: "g",
                         delo: "43", new: "0"),
            host: "unknown.sudrf.ru", level: .cassation, cartotekaID: "p3")
        XCTAssertFalse(CaseCardRecovery.matchesRecoveryCaseNumber(
            "8а-1/2026 [88а-2/2026]", expected: expected,
            context: unknownCourt, cartoteka: p3))
    }

    func testKSOYUCompositeNumberSearchUsesSameStrictMatcher() async throws {
        let host = "3kas.sudrf.ru"
        let expected = "88а-4018/2021"
        let original = cardURL(host: host, number: "old", uid: "old-guid",
                               delo: "43", new: "0")
        let first = cardURL(host: host, number: "3304334", uid: "candidate-1",
                            delo: "43", new: "0")
        let second = cardURL(host: host, number: "3304335", uid: "candidate-2",
                             delo: "43", new: "0")
        let published = "8а-2564/2021 [88а-4018/2021]"
        let row = CaseSearchResult(caseNumber: published, cardURL: first)
        let card = CaseCard(rawText: "", actText: nil, caseNumber: published)
        let context = context(number: expected, uid: nil, url: original,
                              host: host, level: .cassation, cartotekaID: "p3")
        let provider = RecoveryProviderStub(
            cards: [first.absoluteString: card], defaultFailure: .noCard,
            numberRows: [row])

        let result = try await CaseCardRecovery(provider: provider).resolve(context: context)

        XCTAssertEqual(result.reason, .caseNumber)
        XCTAssertEqual(result.verifiedURL, first)
        let searches = await provider.snapshot().searches
        XCTAssertEqual(searches.map(\.0), ["number"])

        let ambiguous = RecoveryProviderStub(
            cards: [first.absoluteString: card, second.absoluteString: card],
            defaultFailure: .noCard,
            numberRows: [row, CaseSearchResult(caseNumber: published, cardURL: second)])
        await XCTAssertThrowsErrorAsync(
            try await CaseCardRecovery(provider: ambiguous).resolve(context: context)
        ) { error in
            XCTAssertEqual(error as? CaseCardRecoveryError, .ambiguous)
        }
    }

    func testUIDSearchUsesSameSrvNumAndRequiresMatchingCardUID() async throws {
        let original = cardURL(host: komiHost, number: "old", uid: "old-guid",
                               delo: "42", new: "0", srvNum: 3)
        let candidate = cardURL(host: komiHost, number: "new", uid: "new-guid",
                                delo: "42", new: "0", srvNum: 3)
        let uid = "11RS0001-01-2022-009001-50"
        let row = CaseSearchResult(caseNumber: "33а-9001/2022", cardURL: candidate)
        let card = CaseCard(rawText: "", actText: nil, uid: uid,
                            caseNumber: "33а-9001/2022")
        let provider = RecoveryProviderStub(cards: [candidate.absoluteString: card],
                                            defaultFailure: .noCard, uidRows: [row])

        let result = try await CaseCardRecovery(provider: provider).resolve(
            context: context(number: "33а-9001/2022", uid: uid, url: original))

        XCTAssertEqual(result.reason, .judicialUID)
        XCTAssertEqual(result.verifiedURL, candidate)
        let searches = await provider.snapshot().searches
        XCTAssertEqual(searches.map(\.0), ["uid"])
        XCTAssertEqual(searches.map(\.1), [3])
    }

    func testSavedUIDRejectsForeignAndMissingCandidateUID() async throws {
        let expectedUID = "11RS0001-01-2022-009001-50"
        for foundUID in ["11RS0001-01-2022-999999-50", nil] as [String?] {
            let original = cardURL(host: komiHost, number: UUID().uuidString,
                                   uid: "old-guid", delo: "42", new: "0")
            let candidate = cardURL(host: komiHost, number: UUID().uuidString,
                                    uid: "new-guid", delo: "42", new: "0")
            let row = CaseSearchResult(caseNumber: "33а-9001/2022", cardURL: candidate)
            let card = CaseCard(rawText: "", actText: nil, uid: foundUID,
                                caseNumber: "33а-9001/2022")
            let provider = RecoveryProviderStub(
                cards: [candidate.absoluteString: card], defaultFailure: .noCard,
                uidRows: [row], numberRows: [])

            do {
                _ = try await CaseCardRecovery(provider: provider).resolve(
                    context: context(number: "33а-9001/2022",
                                     uid: expectedUID, url: original))
                XCTFail("candidate with UID \(foundUID ?? "nil") must be rejected")
            } catch let error as SudrfError {
                guard case .parsing = error else {
                    return XCTFail("expected original no-card error, got \(error)")
                }
            }
            let searches = await provider.snapshot().searches
            XCTAssertEqual(searches.map(\.0), ["uid", "number"])
        }
    }

    func testCompleteUIDZeroFallsBackToExactNumberSearch() async throws {
        let original = cardURL(host: komiHost, number: "old", uid: "old-guid",
                               delo: "42", new: "0")
        let candidate = cardURL(host: komiHost, number: "new", uid: "new-guid",
                                delo: "42", new: "0")
        let uid = "11RS0001-01-2022-009001-50"
        let row = CaseSearchResult(caseNumber: "33а-9001/2022", cardURL: candidate)
        let card = CaseCard(rawText: "", actText: nil, uid: uid,
                            caseNumber: "33а-9001/2022")
        let provider = RecoveryProviderStub(
            cards: [candidate.absoluteString: card], defaultFailure: .noCard,
            uidRows: [], numberRows: [row])

        let result = try await CaseCardRecovery(provider: provider).resolve(
            context: context(number: "33а-9001/2022", uid: uid, url: original))

        XCTAssertEqual(result.reason, .caseNumber)
        let searches = await provider.snapshot().searches
        XCTAssertEqual(searches.map(\.0), ["uid", "number"])
    }

    func testCompleteUIDAndNumberZeroPreserveOriginalFailure() async throws {
        let original = cardURL(host: komiHost, number: "old", uid: "old-guid",
                               delo: "42", new: "0")
        let provider = RecoveryProviderStub(defaultFailure: .noCard,
                                            uidRows: [], numberRows: [])

        do {
            _ = try await CaseCardRecovery(provider: provider).resolve(
                context: context(number: "33а-9001/2022",
                                 uid: "11RS0001-01-2022-009001-50", url: original))
            XCTFail("expected original no-card error")
        } catch let error as SudrfError {
            guard case .parsing = error else {
                return XCTFail("expected original no-card error, got \(error)")
            }
        }
        let searches = await provider.snapshot().searches
        XCTAssertEqual(searches.map(\.0), ["uid", "number"])
    }

    func testExactNumberSearchAllowsOneConfirmedCardWithoutUID() async throws {
        let original = cardURL(host: komiHost, number: "old", uid: "old-guid",
                               delo: "42", new: "0")
        let candidate = cardURL(host: komiHost, number: "new", uid: "new-guid",
                                delo: "42", new: "0")
        let row = CaseSearchResult(caseNumber: "33а-9001/2022", cardURL: candidate)
        let card = CaseCard(rawText: "", actText: nil, uid: nil,
                            caseNumber: "33а-9001/2022")
        let provider = RecoveryProviderStub(cards: [candidate.absoluteString: card],
                                            defaultFailure: .noCard, numberRows: [row])

        let result = try await CaseCardRecovery(provider: provider).resolve(
            context: context(number: "33а-9001/2022", uid: nil, url: original))

        XCTAssertEqual(result.reason, .caseNumber)
        XCTAssertEqual(result.verifiedURL, candidate)
        let searches = await provider.snapshot().searches
        XCTAssertEqual(searches.map(\.0), ["number"])
    }

    func testNumberSearchRejectsTwoConfirmedCardsAsAmbiguous() async throws {
        let original = cardURL(host: komiHost, number: "old", uid: "old-guid",
                               delo: "42", new: "0")
        let first = cardURL(host: komiHost, number: "1", uid: "g1", delo: "42", new: "0")
        let second = cardURL(host: komiHost, number: "2", uid: "g2", delo: "42", new: "0")
        let rows = [first, second].map {
            CaseSearchResult(caseNumber: "33а-9001/2022", cardURL: $0)
        }
        let card = CaseCard(rawText: "", actText: nil, caseNumber: "33а-9001/2022")
        let provider = RecoveryProviderStub(cards: [first.absoluteString: card,
                                                    second.absoluteString: card],
                                            defaultFailure: .noCard, numberRows: rows)

        await XCTAssertThrowsErrorAsync(
            try await CaseCardRecovery(provider: provider).resolve(
                context: context(number: "33а-9001/2022", uid: nil, url: original))
        ) { error in
            XCTAssertEqual(error as? CaseCardRecoveryError, .ambiguous)
        }
    }

    func testOneFailedCandidateMakesSearchIncomplete() async throws {
        let original = cardURL(host: komiHost, number: "old", uid: "old-guid",
                               delo: "42", new: "0")
        let good = cardURL(host: komiHost, number: "1", uid: "g1", delo: "42", new: "0")
        let failed = cardURL(host: komiHost, number: "2", uid: "g2", delo: "42", new: "0")
        let rows = [good, failed].map {
            CaseSearchResult(caseNumber: "33а-9001/2022", cardURL: $0)
        }
        let card = CaseCard(rawText: "", actText: nil, caseNumber: "33а-9001/2022")
        let provider = RecoveryProviderStub(cards: [good.absoluteString: card],
                                            failures: [failed.absoluteString: .notFound],
                                            defaultFailure: .noCard, numberRows: rows)

        await XCTAssertThrowsErrorAsync(
            try await CaseCardRecovery(provider: provider).resolve(
                context: context(number: "33а-9001/2022", uid: nil, url: original))
        ) { error in
            XCTAssertEqual(error as? CaseCardRecoveryError, .incompleteCandidates)
        }
    }

    func testTransientCaptchaMaintenanceAndCancellationNeverStartRecovery() async throws {
        for failure in [RecoveryStubFailure.transient, .captcha, .maintenance, .cancelled] {
            let original = cardURL(host: komiHost, number: UUID().uuidString,
                                   uid: "guid", delo: "42", new: "0")
            let provider = RecoveryProviderStub(failures: [original.absoluteString: failure])
            do {
                _ = try await CaseCardRecovery(provider: provider).resolve(
                    context: context(number: "33а-9001/2022", uid: nil, url: original))
                XCTFail("expected \(failure)")
            } catch {
                let snapshot = await provider.snapshot()
                XCTAssertTrue(snapshot.searches.isEmpty)
                XCTAssertEqual(snapshot.urls, [original.absoluteString])
            }
        }
    }

    func testOnlyNoCardParserAndGoneHTTPStatusesAreRecoveryEligible() {
        XCTAssertTrue(CaseCardRecovery.isRecoveryEligible(
            SudrfError.parsing("страница не содержит признаков карточки дела")))
        XCTAssertTrue(CaseCardRecovery.isRecoveryEligible(
            SudrfError.parsing("страница не содержит признаков винтажной карточки дела")))
        XCTAssertTrue(CaseCardRecovery.isRecoveryEligible(SudrfError.http(status: 404)))
        XCTAssertTrue(CaseCardRecovery.isRecoveryEligible(SudrfError.http(status: 410)))
        XCTAssertFalse(CaseCardRecovery.isRecoveryEligible(
            SudrfError.parsing("SwiftSoup не смог разобрать карточку")))
        XCTAssertFalse(CaseCardRecovery.isRecoveryEligible(SudrfError.http(status: 500)))
    }

    private func context(number: String, uid: String?, url: URL,
                         host: String? = nil, level: CourtLevel = .subject,
                         cartotekaID: String = "p2") -> MovementContext {
        let domain = host ?? komiHost
        var value = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: domain, displayDomain: SudrfHost.alternate(domain) ?? domain,
            courtTitle: "Верховный Суд Республики Коми", courtLevelRaw: level.rawValue,
            courtCode: "11", cartotekaId: cartotekaID, cartotekaLevelRaw: level.rawValue,
            caseNumber: number, caseID: "old", caseUID: "old-guid",
            cardURLString: url.absoluteString)
        value.judicialUID = uid
        value.baseInstanceLevelRaw = CaseInstance.Level.appeal.rawValue
        return value
    }

    private func ksoyuContext(number: String, cartotekaID: String) -> MovementContext {
        context(number: number, uid: nil,
                url: cardURL(host: "3kas.sudrf.ru", number: "1", uid: "guid",
                             delo: "43", new: "0"),
                host: "3kas.sudrf.ru", level: .cassation,
                cartotekaID: cartotekaID)
    }

    private func cardURL(host: String, number: String, uid: String,
                         delo: String, new: String, srvNum: Int = 1) -> URL {
        URL(string: "https://\(host)/modules.php?name=sud_delo&srv_num=\(srvNum)&name_op=case&case_id=\(number)&case_uid=\(uid)&delo_id=\(delo)&new=\(new)")!
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "html",
            subdirectory: "Fixtures/card-recovery"))
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func compositeFixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name, withExtension: "html",
            subdirectory: "Fixtures/composite-recovery"))
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
