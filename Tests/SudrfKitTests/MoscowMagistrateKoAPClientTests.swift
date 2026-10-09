import XCTest
import Foundation
@testable import SudrfKit

final class MoscowMagistrateKoAPClientTests: XCTestCase {
    private var session: URLSession!

    override func setUpWithError() throws {
        try super.setUpWithError()
        MoscowMagistrateKoAPStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MoscowMagistrateKoAPStub.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        session = nil
        MoscowMagistrateKoAPStub.reset()
        try super.tearDownWithError()
    }

    func testNativeLocatorRequiresExactHostUnitAdminSectionAndUUID() throws {
        let adm = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm"))
        let url = URL(string:
            "https://mos-sud.ru/424/cases/admin/details/11111111-1111-4111-8111-111111111111?caseNumber=fixture")!
        let locator = try XCTUnwrap(SourceNativeCardLocator.moscowMagistrateKoAP(
            url: url, cartoteka: adm))
        XCTAssertEqual(locator.identity,
                       SourceNativeCardIdentity(sourceFamily: "moscow-magistrate-koap",
                                                courtKey: "424", cartotekaKey: "adm",
                                                sourceNativeID: "11111111-1111-4111-8111-111111111111"))

        let invalidURLs = [
            "http://mos-sud.ru/424/cases/admin/details/11111111-1111-4111-8111-111111111111",
            "https://www.mos-sud.ru/424/cases/admin/details/11111111-1111-4111-8111-111111111111",
            "https://mos-sud.ru.example/424/cases/admin/details/11111111-1111-4111-8111-111111111111",
            "https://mos-sud.ru:8443/424/cases/admin/details/11111111-1111-4111-8111-111111111111",
            "https://user@mos-sud.ru/424/cases/admin/details/11111111-1111-4111-8111-111111111111",
            "https://mos-sud.ru/unit/cases/admin/details/11111111-1111-4111-8111-111111111111",
            "https://mos-sud.ru/424/cases/appeal-admin/details/11111111-1111-4111-8111-111111111111",
            "https://mos-sud.ru/424/cases/admin/details/11111111-1111-4111-8111-notuuid"
        ]
        for raw in invalidURLs {
            XCTAssertNil(SourceNativeCardLocator.moscowMagistrateKoAP(
                url: try XCTUnwrap(URL(string: raw)), cartoteka: adm), raw)
        }
        let civil = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "g1"))
        XCTAssertNil(SourceNativeCardLocator.moscowMagistrateKoAP(url: url, cartoteka: civil))
    }

    func testSearchDeduplicatesByNativeIdentityButKeepsSameUUIDAtAnotherUnit() throws {
        let html = """
        <table><tbody>
          <tr><td><a href="/424/cases/admin/details/AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA?copy=one">05-0042/424/2026</a></td><td>Синтетическая запись</td></tr>
          <tr><td><a href="/424/cases/admin/details/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa?copy=two">05-0042/424/2026</a></td><td>Повторная синтетическая запись</td></tr>
          <tr><td><a href="/425/cases/admin/details/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa?copy=three">05-0042/425/2026</a></td><td>Другой синтетический участок</td></tr>
        </tbody></table>
        """
        let rows = try MoscowMagistrateKoAPResultsParser.parse(
            html: html, field: .name, requestedValue: "Синтетический участник")

        XCTAssertEqual(rows.count, 2)
        let units = Set(rows.compactMap { row -> String? in
            guard let components = row.cardURL?.pathComponents, components.count > 1 else { return nil }
            return components[1]
        })
        XCTAssertEqual(units, Set(["424", "425"]))
    }

    func testCaseNumberPaddingMatchesOnlyTheSameUnitAndYear() throws {
        XCTAssertTrue(MoscowMagistrateKoAPNumber.matchesPublishedNumber(
            "05-0042/424/2026", "5-42/424/2026"))
        XCTAssertFalse(MoscowMagistrateKoAPNumber.matchesPublishedNumber(
            "05-0042/424/2026", "5-42/425/2026"))
        XCTAssertFalse(MoscowMagistrateKoAPNumber.matchesPublishedNumber(
            "05-0042/424/2026", "5-42/424/2025"))

        let html = """
        <table><tbody>
          <tr><td><a href="/424/cases/admin/details/11111111-1111-4111-8111-111111111111">05-0042/424/2026</a></td><td>Подтверждённый тот же участок</td></tr>
          <tr><td><a href="/425/cases/admin/details/22222222-2222-4222-8222-222222222222">05-0042/425/2026</a></td><td>Другой участок</td></tr>
          <tr><td><a href="/424/cases/admin/details/33333333-3333-4333-8333-333333333333">05-0042/424/2025</a></td><td>Другой год</td></tr>
        </tbody></table>
        """
        let rows = try MoscowMagistrateKoAPResultsParser.parse(
            html: html, field: .caseNumber, requestedValue: "5-42/424/2026")
        XCTAssertEqual(rows.map(\.caseNumber), ["05-0042/424/2026"])
    }

    func testRedirectTaskDelegateRejectsUnsafeTargetsBeforeFollowing() throws {
        let taskDelegate: URLSessionTaskDelegate = MoscowMagistrateKoAPSessionDelegate()
        let sourceURL = URL(string: "https://mos-sud.ru/search")!
        let response = try XCTUnwrap(HTTPURLResponse(
            url: sourceURL, statusCode: 302, httpVersion: "HTTP/1.1",
            headerFields: ["Location": "/search"]))
        let task = session.dataTask(with: sourceURL)
        let targets = [
            URL(string: "https://mos-sud.ru/search")!,
            URL(string: "http://mos-sud.ru/search")!,
            URL(string: "https://www.mos-sud.ru/search")!,
            URL(string: "https://user:password@mos-sud.ru/search")!,
            URL(string: "https://mos-sud.ru:443/search")!
        ]

        for target in targets {
            let forwarded = RedirectRequestBox()
            taskDelegate.urlSession?(session, task: task,
                                     willPerformHTTPRedirection: response,
                                     newRequest: URLRequest(url: target)) {
                forwarded.set($0)
            }
            if MoscowMagistrateKoAPURLPolicy.allows(target) {
                XCTAssertEqual(forwarded.request?.url, target)
            } else {
                XCTAssertNil(forwarded.request, "Unsafe redirect target must be rejected: \(target)")
            }
        }
    }

    func testSearchURLAndParserAcceptOnlyExactNumberInAdminUUIDRows() throws {
        let adm = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm"))
        let url = try MoscowMagistrateKoAPSearchURL.make(
            court: moscowMagistrateCourt, cartoteka: adm,
            field: .caseNumber, value: "05-0042/424/2026")
        XCTAssertEqual(url.host, "mos-sud.ru")
        XCTAssertEqual(url.path, "/search")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "caseNumber", value: "05-0042/424/2026")])
        let uidURL = try MoscowMagistrateKoAPSearchURL.make(
            court: moscowMagistrateCourt, cartoteka: adm,
            field: .uid, value: "77MS0424-01-2026-000042-10")
        XCTAssertEqual(URLComponents(url: uidURL, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "uid", value: "77MS0424-01-2026-000042-10")])
        let participantURL = try MoscowMagistrateKoAPSearchURL.make(
            court: moscowMagistrateCourt, cartoteka: adm,
            field: .name, value: "Синтетический участник")
        XCTAssertEqual(URLComponents(url: participantURL,
                                     resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "participant", value: "Синтетический участник")])
        XCTAssertThrowsError(try MoscowMagistrateKoAPSearchURL.make(
            court: Court(domain: "mos-gorsud.ru", title: "Мосгорсуд", level: .magistrate),
            cartoteka: adm, field: .caseNumber, value: "05-0042/424/2026"))
        XCTAssertThrowsError(try MoscowMagistrateKoAPSearchURL.make(
            court: Court(domain: "mos-sud.ru", title: "Не мировой суд", level: .district),
            cartoteka: adm, field: .caseNumber, value: "05-0042/424/2026"))

        let rows = try MoscowMagistrateKoAPResultsParser.parse(
            html: fixture("mos_sud_koap_search_synthetic"),
            field: .caseNumber, requestedValue: "05-0042/424/2026")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].caseNumber, "05-0042/424/2026")
        XCTAssertEqual(rows[0].caseID, "11111111-1111-4111-8111-111111111111")
        XCTAssertNil(rows[0].caseUID)
        XCTAssertEqual(rows[0].essence, "Синтетический участник")
        XCTAssertEqual(rows[0].result, "Назначено к рассмотрению")
        XCTAssertEqual(rows[0].cardURL?.absoluteString,
                       "https://mos-sud.ru/424/cases/admin/details/11111111-1111-4111-8111-111111111111")
        XCTAssertThrowsError(try MoscowMagistrateKoAPResultsParser.parse(
            html: "<html><body>unknown output</body></html>",
            field: .caseNumber, requestedValue: "05-0042/424/2026"))
        let contradictoryUID = try fixture("mos_sud_koap_search_synthetic")
            .replacingOccurrences(of: "Синтетический участник",
                                  with: "77MS9999-01-2026-000042-10")
        XCTAssertThrowsError(try MoscowMagistrateKoAPResultsParser.parse(
            html: contradictoryUID, field: .uid,
            requestedValue: "77MS0424-01-2026-000042-10"))
    }

    func testUIDAndParticipantSearchReturnCandidatesWithoutInventingUIDProof() async throws {
        MoscowMagistrateKoAPStub.enqueue(body: try fixture("mos_sud_koap_search_synthetic"))
        MoscowMagistrateKoAPStub.enqueue(body: try fixture("mos_sud_koap_search_synthetic"))
        let client = MoscowMagistrateKoAPClient(session: session)
        let adm = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm"))

        let uidOutcome = try await client.searchForUnit(
            court: moscowMagistrateCourt, cartoteka: adm, unitPathID: "424",
            field: .uid, value: "77MS0424-01-2026-000042-10")
        guard case .partial(let uidRows?, _) = uidOutcome else {
            return XCTFail("Scoped UID search remains partial")
        }
        XCTAssertEqual(uidRows.count, 1)
        XCTAssertNil(uidRows[0].caseUID,
                     "A query value is not copied into a source-published UID field")
        let participantOutcome = try await client.searchForUnit(
            court: moscowMagistrateCourt, cartoteka: adm, unitPathID: "424",
            field: .name, value: "Синтетический участник")
        guard case .partial(let participantRows?, _) = participantOutcome else {
            return XCTFail("Scoped participant search remains partial")
        }
        XCTAssertEqual(participantRows.count, 1)

        let requests = MoscowMagistrateKoAPStub.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(requests[0].url),
                                     resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "uid", value: "77MS0424-01-2026-000042-10")])
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(requests[1].url),
                                     resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "participant", value: "Синтетический участник")])
    }

    func testScopedSearchFiltersByNativeUnitAndWrongUnitStaysPartial() async throws {
        let html = """
        <table><tbody>
          <tr><td><a href="/424/cases/admin/details/11111111-1111-4111-8111-111111111111">05-0042/424/2026</a></td><td>Синтетический участник</td><td>Рассмотрено</td></tr>
          <tr><td><a href="/425/cases/admin/details/22222222-2222-4222-8222-222222222222">05-0042/425/2026</a></td><td>Синтетический участник</td><td>Рассмотрено</td></tr>
        </tbody></table>
        """
        MoscowMagistrateKoAPStub.enqueue(body: html)
        MoscowMagistrateKoAPStub.enqueue(body: html)
        let client = MoscowMagistrateKoAPClient(session: session)
        let adm = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm"))

        let selected = try await client.searchForUnit(
            court: moscowMagistrateCourt, cartoteka: adm, unitPathID: "425",
            field: .name, value: "Синтетический участник")
        guard case .partial(let rows?, let attempt) = selected else {
            return XCTFail("Search completeness is not established by the portal response")
        }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(SourceNativeCardLocator.moscowMagistrateKoAP(
            url: try XCTUnwrap(rows.first?.cardURL), cartoteka: adm)?.courtKey, "425")
        XCTAssertEqual(attempt.kind, .partial)

        let wrongUnit = try await client.searchForUnit(
            court: moscowMagistrateCourt, cartoteka: adm, unitPathID: "426",
            field: .name, value: "Синтетический участник")
        guard case .partial(let wrongRows?, let wrongAttempt) = wrongUnit else {
            return XCTFail("No matching native unit is unknown, not a confirmed zero")
        }
        XCTAssertTrue(wrongRows.isEmpty)
        XCTAssertEqual(wrongAttempt.kind, .partial)
        XCTAssertFalse(wrongUnit.isConfirmedEmpty)
    }

    func testSearchUsesFixedRefererAndReturnsTypedPartialRows() async throws {
        MoscowMagistrateKoAPStub.enqueue(body: try fixture("mos_sud_koap_search_synthetic"))
        let client = MoscowMagistrateKoAPClient(session: session)
        let adm = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm"))

        let outcome = try await client.searchForUnit(
            court: moscowMagistrateCourt, cartoteka: adm, unitPathID: "424",
            field: .caseNumber, value: "05-0042/424/2026", operation: .search)
        guard case .partial(let rows, let attempt) = outcome else {
            return XCTFail("Search output without completeness proof must be partial")
        }
        XCTAssertEqual(rows?.count, 1)
        XCTAssertEqual(attempt.kind, .partial)
        XCTAssertEqual(attempt.provenance.sourceFamily, "moscow-magistrate-koap")
        XCTAssertEqual(attempt.provenance.host, "mos-sud.ru")
        let requests = MoscowMagistrateKoAPStub.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/search")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url),
                                     resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "caseNumber", value: "05-0042/424/2026")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"),
                       "https://mos-sud.ru/search")
    }

    func testMetaRefreshUsesSameHostAndFixedRefererAndExternalTargetFailsClosed() async throws {
        MoscowMagistrateKoAPStub.enqueue(body: try fixture("mos_sud_meta_refresh_synthetic"))
        MoscowMagistrateKoAPStub.enqueue(body: try fixture("mos_sud_koap_search_synthetic"))
        let client = MoscowMagistrateKoAPClient(session: session)
        let adm = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm"))

        let outcome = try await client.searchForUnit(
            court: moscowMagistrateCourt, cartoteka: adm, unitPathID: "424",
            field: .caseNumber, value: "05-0042/424/2026")
        guard case .partial(let rows?, _) = outcome else {
            return XCTFail("Scoped search remains partial")
        }
        XCTAssertEqual(rows.count, 1)
        let requests = MoscowMagistrateKoAPStub.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Referer") == "https://mos-sud.ru/search"
        })
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(requests.last?.url),
                                     resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "caseNumber", value: "05-0042/424/2026"),
                        URLQueryItem(name: "_cb", value: "fixture")])
    }

    func testExternalMetaRefreshIsRejectedBeforeFollowingAndNeverHonestZero() async throws {
        MoscowMagistrateKoAPStub.enqueue(body: """
        <html><head><meta http-equiv="refresh" content="0;url=https://elsewhere.example/result"></head></html>
        """)
        let client = MoscowMagistrateKoAPClient(session: session)
        let adm = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm"))
        let outcome = try await client.searchForUnit(
            court: moscowMagistrateCourt, cartoteka: adm, unitPathID: "424",
            field: .caseNumber, value: "05-0042/424/2026", operation: .search)
        guard case .parserFailure(let message, let attempt) = outcome else {
            return XCTFail("An external meta-refresh target must fail closed")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertEqual(attempt.kind, .parserFailure)
        XCTAssertEqual(MoscowMagistrateKoAPStub.requests.count, 1)
        XCTAssertFalse(outcome.isConfirmedEmpty)
    }

    func testHTTPRedirectFinalHostOutsideAllowlistFailsBeforeParsing() async throws {
        MoscowMagistrateKoAPStub.enqueue(
            body: try fixture("mos_sud_koap_search_synthetic"),
            finalURL: URL(string: "https://elsewhere.example/search")!)
        let client = MoscowMagistrateKoAPClient(session: session)
        let adm = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm"))
        let outcome = try await client.searchForUnit(
            court: moscowMagistrateCourt, cartoteka: adm, unitPathID: "424",
            field: .caseNumber, value: "05-0042/424/2026", operation: .search)
        guard case .parserFailure = outcome else {
            return XCTFail("A response outside the source host must fail closed")
        }
        XCTAssertEqual(MoscowMagistrateKoAPStub.requests.count, 1)
    }

    func testMetaRefreshChainStopsAtSafetyBound() async throws {
        let redirect = "<html><head><meta http-equiv=\"refresh\" content=\"0;url=/search?caseNumber=05-0042%2F424%2F2026\"></head></html>"
        for _ in 0..<4 { MoscowMagistrateKoAPStub.enqueue(body: redirect) }
        let client = MoscowMagistrateKoAPClient(session: session)
        let adm = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm"))

        let outcome = try await client.searchForUnit(
            court: moscowMagistrateCourt, cartoteka: adm, unitPathID: "424",
            field: .caseNumber, value: "05-0042/424/2026", operation: .search)
        guard case .parserFailure = outcome else {
            return XCTFail("Exceeding the configured meta-refresh safety bound must fail closed")
        }
        XCTAssertEqual(MoscowMagistrateKoAPStub.requests.count, 4)
    }

    func testCardFetchReusesMosGorSudOwnFieldsParserAndChecksEffectiveIdentity() async throws {
        MoscowMagistrateKoAPStub.enqueue(body: try fixture("mos_sud_koap_card_synthetic"))
        let client = MoscowMagistrateKoAPClient(session: session)
        let url = URL(string:
            "https://mos-sud.ru/424/cases/admin/details/11111111-1111-4111-8111-111111111111")!
        let fetched = try await client.fetchCardWithResponseURL(url: url)
        XCTAssertEqual(fetched.responseURL, url)
        XCTAssertEqual(fetched.card.caseNumber, "05-0042/424/2026")
        XCTAssertEqual(fetched.card.uid, "77MS0424-01-2026-000042-10")
        XCTAssertEqual(fetched.card.judge, "Судья Тестова И. И.")
        XCTAssertEqual(fetched.card.result, "Назначено к рассмотрению")
        XCTAssertEqual(fetched.card.category, "Административное правонарушение")
        XCTAssertEqual(fetched.card.receiptDate, "01.02.2026")
        XCTAssertEqual(fetched.card.legalForceDate, "15.03.2026")
        XCTAssertEqual(fetched.card.sessions.count, 1)
        XCTAssertEqual(fetched.card.sessions[0].date, "10.03.2026")
        XCTAssertEqual(fetched.card.processKind, .koap)
        XCTAssertEqual(fetched.card.parties.kind, .koap)
        XCTAssertEqual(fetched.card.parties.roleItems,
                       [RoleItem(role: "Привлекаемое лицо", name: "Синтетический участник")])
        XCTAssertTrue(MoscowMagistrateKoAPStub.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Referer") == "https://mos-sud.ru/search"
        })
    }

    func testMGSCardParserDoesNotUseLowerCourtJudgeCompositeAsOwnJudge() throws {
        let cardHTML = try fixture("mos_sud_koap_card_synthetic")
        let ownJudgeRow = #"<div class="left">Cудья</div><div class="right">Судья Тестова И. И.</div>"#
        let lowerCourtJudgeRow = #"<div class="left">Судья нижестоящего суда</div><div class="right">Синтетический районный суд — судья Петрова П. П.</div>"#
        let parts = cardHTML.components(separatedBy: ownJudgeRow)
        XCTAssertEqual(parts.count, 2, "The synthetic fixture must contain its own judge field once")

        let compositeOnly = parts[0] + lowerCourtJudgeRow + parts[1]
        let compositeAndOwn = parts[0] + lowerCourtJudgeRow + ownJudgeRow + parts[1]

        XCTAssertNil(try MosGorSudCardParser.parse(html: compositeOnly).judge)
        XCTAssertEqual(try MosGorSudCardParser.parse(html: compositeAndOwn).judge,
                       "Судья Тестова И. И.")
    }

    func testCardFetchRejectsOtherSectionBeforeStartingRequest() async throws {
        let client = MoscowMagistrateKoAPClient(session: session)
        let url = URL(string:
            "https://mos-sud.ru/424/cases/appeal-admin/details/11111111-1111-4111-8111-111111111111")!
        do {
            _ = try await client.fetchCard(url: url)
            XCTFail("Appeal section is outside this first-stage client")
        } catch let error as SudrfError {
            guard case .parsing = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertTrue(MoscowMagistrateKoAPStub.requests.isEmpty)
    }

    func testCardMetaRefreshCannotChangeNativeUUID() async throws {
        MoscowMagistrateKoAPStub.enqueue(body: """
        <html><head><meta http-equiv="refresh" content="0;url=/424/cases/admin/details/22222222-2222-4222-8222-222222222222"></head></html>
        """)
        MoscowMagistrateKoAPStub.enqueue(body: try fixture("mos_sud_koap_card_synthetic"))
        let client = MoscowMagistrateKoAPClient(session: session)
        let url = URL(string:
            "https://mos-sud.ru/424/cases/admin/details/11111111-1111-4111-8111-111111111111")!
        do {
            _ = try await client.fetchCard(url: url)
            XCTFail("The final card locator must match the requested UUID")
        } catch let error as SudrfError {
            guard case .caseCardTemporarilyUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(MoscowMagistrateKoAPStub.requests.count, 2)
    }

    func testHTTPFailureIsTypedTransportFailure() async throws {
        MoscowMagistrateKoAPStub.enqueue(status: 403, body: "blocked")
        let client = MoscowMagistrateKoAPClient(session: session)
        let adm = try XCTUnwrap(CartotekaRegistry.find(level: .magistrate, id: "adm"))
        let outcome = try await client.searchForUnit(
            court: moscowMagistrateCourt, cartoteka: adm, unitPathID: "424",
            field: .caseNumber, value: "05-0042/424/2026", operation: .search)
        guard case .transportFailure(_, let attempt) = outcome else {
            return XCTFail("HTTP status must remain a typed transport failure")
        }
        XCTAssertEqual(attempt.kind, .transportFailure)
        XCTAssertEqual(attempt.provenance.httpStatus, 403)
    }

    private var moscowMagistrateCourt: Court {
        Court(domain: "mos-sud.ru", title: "Мировые судьи Москвы", level: .magistrate)
    }

    private func fixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "html",
                                                  subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8)
    }
}

private extension SourceOutcome where Value == [CaseSearchResult] {
    var isConfirmedEmpty: Bool {
        if case .honestZero = self { return true }
        return false
    }
}

private final class RedirectRequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: URLRequest?

    var request: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return storedRequest
    }

    func set(_ request: URLRequest?) {
        lock.lock(); defer { lock.unlock() }
        storedRequest = request
    }
}

private final class MoscowMagistrateKoAPStub: URLProtocol {
    private struct Reply {
        var status: Int
        var body: Data
        var finalURL: URL?
    }

    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var capturedRequests: [URLRequest] = []
    private static let lock = NSLock()

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return capturedRequests
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        replies = []
        capturedRequests = []
    }

    static func enqueue(status: Int = 200, body: String, finalURL: URL? = nil) {
        lock.lock(); defer { lock.unlock() }
        replies.append(Reply(status: status, body: Data(body.utf8), finalURL: finalURL))
    }

    private static func take(for request: URLRequest) -> Reply? {
        lock.lock(); defer { lock.unlock() }
        capturedRequests.append(request)
        guard !replies.isEmpty else { return nil }
        return replies.removeFirst()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let reply = Self.take(for: request), let requestURL = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let response = HTTPURLResponse(
            url: reply.finalURL ?? requestURL,
            statusCode: reply.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
