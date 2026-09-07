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
                         host: String? = nil, level: CourtLevel = .subject) -> MovementContext {
        let domain = host ?? komiHost
        var value = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: domain, displayDomain: SudrfHost.alternate(domain) ?? domain,
            courtTitle: "Верховный Суд Республики Коми", courtLevelRaw: level.rawValue,
            courtCode: "11", cartotekaId: "p2", cartotekaLevelRaw: level.rawValue,
            caseNumber: number, caseID: "old", caseUID: "old-guid",
            cardURLString: url.absoluteString)
        value.judicialUID = uid
        value.baseInstanceLevelRaw = CaseInstance.Level.appeal.rawValue
        return value
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
