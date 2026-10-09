import Foundation
import XCTest
import SudrfKit
@testable import sudrf_cli

final class PortalCanaryTests: XCTestCase {
    func testRecognizedCaptchaIsExpectedButOtherOutcomesStillFailWorkflow() {
        func report(_ outcomes: [PortalCanaryOutcome]) -> PortalCanaryReport {
            let requests = zip(PortalCanaryFamily.allCases, outcomes).map { family, outcome in
                PortalCanaryReportRow(family: family, host: "example.invalid", outcome: outcome,
                                      stage: "test", httpStatus: nil, bytes: nil, sha256: nil,
                                      declaredCharset: "unspecified", decodedCharset: nil,
                                      safeDOM: nil)
            }
            return PortalCanaryReport(generatedAt: .distantPast, requests: requests)
        }

        let expected = [PortalCanaryOutcome.captcha, .parsedListing] +
            Array(repeating: .searchForm, count: PortalCanaryFamily.allCases.count - 2)
        XCTAssertTrue(report(expected).satisfiesWorkflowOutcomePolicy)

        var mixedFailure = expected
        mixedFailure[1] = .networkFailure
        XCTAssertFalse(report(mixedFailure).satisfiesWorkflowOutcomePolicy)

        let stillUnexpected: [PortalCanaryOutcome] = [
            .emptyListing, .maintenance, .parserContractFailure, .unknownPage,
            .redirectBlocked, .httpFailure, .bodyTooLarge, .nonHTMLResponse,
            .decodeFailure, .networkFailure
        ]
        for outcome in stillUnexpected {
            var results = Array(repeating: PortalCanaryOutcome.searchForm,
                                count: PortalCanaryFamily.allCases.count)
            results[0] = outcome
            XCTAssertFalse(report(results).satisfiesWorkflowOutcomePolicy, "\(outcome)")
        }

        XCTAssertFalse(report(Array(expected.dropLast())).satisfiesWorkflowOutcomePolicy)
    }

    func testLiveSessionDoesNotPersistOrReuseCookiesCredentialsOrCache() {
        let session = PortalCanaryRunner.makeLiveSession()
        defer { session.invalidateAndCancel() }

        let configuration = session.configuration
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 45)
    }

    func testTargetsAreSevenHTTPSPublicFormsWithoutCaseCriteria() throws {
        let targets = try PortalCanaryTargets.make()
        XCTAssertEqual(targets.count, 7)
        XCTAssertEqual(Set(targets.map(\.family)), Set(PortalCanaryFamily.allCases))

        let forbiddenNames: Set<String> = [
            "uid", "participant", "casenumber", "uniquenumber", "oldcasenumber1",
            "keywords", "captcha", "captchaid", "captcha-response", "token"
        ]
        for target in targets {
            XCTAssertEqual(target.url.scheme, "https", target.family.rawValue)
            XCTAssertEqual(target.url.host?.lowercased(), target.host, target.family.rawValue)
            let names = Set((URLComponents(url: target.url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .map { $0.name.lowercased() })
            XCTAssertTrue(names.isDisjoint(with: forbiddenNames), target.family.rawValue)
            XCTAssertFalse(target.host.isEmpty, target.family.rawValue)
        }

        XCTAssertNil(URLComponents(url: try XCTUnwrap(targets.first { $0.family == .supremeCourt }?.url),
                                   resolvingAgainstBaseURL: false)?.query)
        XCTAssertNil(URLComponents(url: try XCTUnwrap(targets.first { $0.family == .moscow }?.url),
                                   resolvingAgainstBaseURL: false)?.query)
    }

    func testLegacyTargetUsesTheExistingVNKODDirectoryEntry() throws {
        let target = try XCTUnwrap(PortalCanaryTargets.make().first { $0.family == .vnkodLegacy })
        XCTAssertEqual(SearchPatternDirectory.pattern(forDomain: target.host), .vnkod)
        XCTAssertEqual(SearchPatternDirectory.vnkod(forDomain: target.host), "73RS0004")
        XCTAssertEqual(target.url.path, "/modules.php")

        let query = URLComponents(url: target.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let values = Dictionary(query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(values["name"], "sud_delo")
        XCTAssertEqual(values["name_op"], "sf")
        XCTAssertEqual(values["_deloId"], "1540005")
        XCTAssertEqual(values["_caseType"], "0")
        XCTAssertEqual(values["_new"], "0")
        XCTAssertNil(values["delo_id"])
    }

    func testUnknownResponseArtifactContainsOnlySafeStructure() async throws {
        let target = try XCTUnwrap(PortalCanaryTargets.make().first)
        let secretName = "CANARY_PRIVATE_PERSON_4f7e"
        let secretCase = "CANARY_CASE_8d1a"
        let secretToken = "CANARY_SERVICE_TOKEN_c02d"
        let body = """
        <html><body><form action="/private?token=\(secretToken)">
          <input name="\(secretCase)" value="\(secretName)">
          <div data-session="\(secretToken)">\(secretName)</div>
        </form></body></html>
        """.data(using: .utf8)!
        PortalCanaryStub.reset(status: 200, contentType: "text/html; charset=utf-8", body: body)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let report = await PortalCanaryRunner(session: session).run([target], now: Date(timeIntervalSince1970: 0))
        let row = try XCTUnwrap(report.requests.first)
        XCTAssertEqual(row.outcome, .unknownPage)
        XCTAssertEqual(row.host, target.host)
        XCTAssertNotNil(row.safeDOM)

        let encoded = try JSONEncoder().encode(report)
        let serialized = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(serialized.contains(secretName))
        XCTAssertFalse(serialized.contains(secretCase))
        XCTAssertFalse(serialized.contains(secretToken))
        XCTAssertTrue(serialized.contains("\"div\""))

        let requests = PortalCanaryStub.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertFalse(requests[0].httpShouldHandleCookies)
        XCTAssertEqual(requests[0].cachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testLegacyBlankFormMatchesTheExistingVNKODFormContract() async throws {
        let target = try XCTUnwrap(PortalCanaryTargets.make().first { $0.family == .vnkodLegacy })
        let body = """
        <html><body><form action="/modules.php?name=sud_delo&name_op=r">
          <input name="name_op" value="r">
          <input name="_deloId" value="1540005">
          <input name="_new" value="0">
          <input name="case__case_numberss" value="">
        </form></body></html>
        """.data(using: .utf8)!
        PortalCanaryStub.reset(status: 200, contentType: "text/html; charset=utf-8", body: body)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let report = await PortalCanaryRunner(session: session).run([target])
        XCTAssertEqual(report.requests.first?.outcome, .searchForm)
    }

    func testPositiveSudrfResultCountCannotFallBackToSearchForm() async throws {
        let target = try XCTUnwrap(PortalCanaryTargets.make().first { $0.family == .sudrfDistrict })
        let field = try XCTUnwrap(target.expectedFieldNames.first)
        let body = """
        <form action="/modules.php?name=sud_delo&name_op=r">
          <input name="\(field)" value="">
        </form>
        <div>Всего по запросу найдено: 2</div>
        """.data(using: .utf8)!
        PortalCanaryStub.reset(status: 200, contentType: "text/html; charset=utf-8", body: body)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let report = await PortalCanaryRunner(session: session).run([target])
        XCTAssertEqual(SearchPageClassifier.classify(html: String(decoding: body, as: UTF8.self)), .unrecognized)
        XCTAssertEqual(report.requests.first?.outcome, .parserContractFailure)
        XCTAssertEqual(report.requests.first?.safeDOM?.hasExpectedSearchControl, true)
        XCTAssertEqual(report.requests.first?.safeDOM?.hasKnownListingStructure, true)
    }

    func testPositiveMagistrateResultCountCannotFallBackToSearchForm() async throws {
        let target = try XCTUnwrap(PortalCanaryTargets.make().first { $0.family == .magistrate })
        let field = try XCTUnwrap(target.expectedFieldNames.first)
        let body = """
        <form action="/modules.php?name=sud_delo&op=sf">
          <input name="\(field)" value="">
        </form>
        <div class="case-count">Найдено дел: 2</div>
        """.data(using: .utf8)!
        PortalCanaryStub.reset(status: 200, contentType: "text/html; charset=utf-8", body: body)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let report = await PortalCanaryRunner(session: session).run([target])
        XCTAssertEqual(MagistratePageClassifier.classify(html: String(decoding: body, as: UTF8.self)), .unrecognized)
        XCTAssertEqual(report.requests.first?.outcome, .parserContractFailure)
        XCTAssertEqual(report.requests.first?.safeDOM?.hasExpectedSearchControl, true)
        XCTAssertEqual(report.requests.first?.safeDOM?.hasKnownListingStructure, true)
    }

    func testParsedListingDoesNotRetainParserRowsOrIdentifiers() async throws {
        let target = try XCTUnwrap(PortalCanaryTargets.make().first { $0.family == .sudrfDistrict })
        let privateNumber = "CANARY_CASE_NUMBER_ef31"
        let privateID = "CANARY_CARD_ID_5ac2"
        let privateUID = "CANARY_UID_8b20"
        let body = """
        <html><body><table><tbody><tr><td>
          <a href="/modules.php?name=sud_delo&name_op=case&case_id=\(privateID)&case_uid=\(privateUID)">\(privateNumber)</a>
        </td></tr></tbody></table></body></html>
        """.data(using: .utf8)!
        PortalCanaryStub.reset(status: 200, contentType: "text/html; charset=utf-8", body: body)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let report = await PortalCanaryRunner(session: session).run([target])
        XCTAssertEqual(report.requests.first?.outcome, .parsedListing)
        let encoded = try JSONEncoder().encode(report)
        let serialized = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(serialized.contains(privateNumber))
        XCTAssertFalse(serialized.contains(privateID))
        XCTAssertFalse(serialized.contains(privateUID))
    }

    func testValidEmptySupremeAndMoscowResultsAreNotReportedAsSuccess() async throws {
        let targets = try PortalCanaryTargets.make()
        let vsrf = try XCTUnwrap(targets.first { $0.family == .supremeCourt })
        let moscow = try XCTUnwrap(targets.first { $0.family == .moscow })
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        PortalCanaryStub.reset(
            status: 200,
            contentType: "text/html; charset=utf-8",
            body: #"<div class="SearchPage_resultsBlock__test"><span>Найдено: 0</span></div>"#.data(using: .utf8)!)
        let vsrfReport = await PortalCanaryRunner(session: session).run([vsrf])
        XCTAssertEqual(vsrfReport.requests.first?.outcome, .emptyListing)

        PortalCanaryStub.reset(
            status: 200,
            contentType: "text/html; charset=utf-8",
            body: "<table><thead><tr><th>№ дела</th><th>Стороны</th></tr></thead><tbody></tbody></table>".data(using: .utf8)!)
        let moscowReport = await PortalCanaryRunner(session: session).run([moscow])
        XCTAssertEqual(moscowReport.requests.first?.outcome, .emptyListing)
    }

    func testSupremeCourtExplicitZeroWithActualSearchFormIsRecognized() async throws {
        let target = try XCTUnwrap(PortalCanaryTargets.make().first { $0.family == .supremeCourt })
        let body = #"""
        <form id="filter-form"><input name="uniqueNumber" value=""></form>
        <div class="SearchPage_resultsBlock__test"><span>Найдено: 0</span></div>
        """#.data(using: .utf8)!
        PortalCanaryStub.reset(status: 200, contentType: "text/html; charset=utf-8", body: body)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let report = await PortalCanaryRunner(session: session).run([target])
        XCTAssertEqual(report.requests.first?.outcome, .searchForm)
    }

    func testBrokenSupremeListingDoesNotFallBackToItsSearchForm() async throws {
        let target = try XCTUnwrap(PortalCanaryTargets.make().first { $0.family == .supremeCourt })
        let body = #"""
        <form id="filter-form"><input name="uniqueNumber" value=""></form>
        <div class="SearchPage_resultsBlock__test">
          <span>Найдено: 2</span>
          <div class="CaseStyle_case_item__test"><p>row without a linkable production</p></div>
        </div>
        """#.data(using: .utf8)!
        PortalCanaryStub.reset(status: 200, contentType: "text/html; charset=utf-8", body: body)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let report = await PortalCanaryRunner(session: session).run([target])
        XCTAssertEqual(report.requests.first?.outcome, .parserContractFailure)
        XCTAssertEqual(report.requests.first?.safeDOM?.hasExpectedSearchControl, true)
        XCTAssertEqual(report.requests.first?.safeDOM?.hasKnownListingStructure, true)
    }

    func testBrokenMoscowListingTableIsNotMistakenForSearchForm() async throws {
        let target = try XCTUnwrap(PortalCanaryTargets.make().first { $0.family == .moscow })
        let body = """
        <form><input name="caseNumber" value=""></form>
        <table class="search-form__table"><thead><tr><th>Дата</th><th>Стороны</th></tr></thead>
          <tbody><tr><td>публичная строка</td><td>данные</td></tr></tbody>
        </table>
        """.data(using: .utf8)!
        PortalCanaryStub.reset(status: 200, contentType: "text/html; charset=utf-8", body: body)
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let report = await PortalCanaryRunner(session: session).run([target])
        XCTAssertEqual(report.requests.first?.outcome, .parserContractFailure)
        XCTAssertEqual(report.requests.first?.safeDOM?.hasExpectedSearchControl, true)
        XCTAssertEqual(report.requests.first?.safeDOM?.hasKnownListingStructure, true)
    }

    func testHttpFailureIsReportedAfterExactlyOneRequest() async throws {
        let target = try XCTUnwrap(PortalCanaryTargets.make().first)
        PortalCanaryStub.reset(status: 503, contentType: "text/html", body: Data())
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let report = await PortalCanaryRunner(session: session).run([target])
        XCTAssertEqual(report.requests.first?.outcome, .httpFailure)
        XCTAssertEqual(report.requests.first?.httpStatus, 503)
        XCTAssertEqual(PortalCanaryStub.requests.count, 1)
    }

    func testResponseBodyLimitStopsLargePageAndDoesNotHashItAsComplete() async throws {
        let target = try XCTUnwrap(PortalCanaryTargets.make().first)
        PortalCanaryStub.reset(status: 200, contentType: "text/html",
                               body: Data(repeating: 0x61, count: 1_000_100))
        let session = makeSession()
        defer { session.invalidateAndCancel() }

        let report = await PortalCanaryRunner(session: session).run([target])
        XCTAssertEqual(report.requests.first?.outcome, .bodyTooLarge)
        XCTAssertEqual(report.requests.first?.bytes, 1_000_000)
        XCTAssertNil(report.requests.first?.sha256)
        XCTAssertEqual(PortalCanaryStub.requests.count, 1)
    }

    func testRedirectDelegateRejectsRedirectRequest() throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let blocker = try XCTUnwrap(session.delegate as? PortalCanaryRedirectBlocker)
        let source = try XCTUnwrap(URL(string: "https://source.invalid/form"))
        let destination = try XCTUnwrap(URL(string: "https://destination.invalid/"))
        let task = session.dataTask(with: source)
        let response = try XCTUnwrap(HTTPURLResponse(url: source, statusCode: 302,
                                                      httpVersion: "HTTP/1.1",
                                                      headerFields: ["Location": destination.absoluteString]))
        var forwarded: URLRequest? = URLRequest(url: destination)

        blocker.urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: destination), completionHandler: { forwarded = $0 })

        XCTAssertNil(forwarded)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PortalCanaryStub.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return PortalCanaryRunner.makeSession(configuration: configuration)
    }
}

private struct PortalCanaryStubResponse {
    let status: Int
    let contentType: String
    let body: Data
}

private final class PortalCanaryStubState: @unchecked Sendable {
    private let lock = NSLock()
    private var response = PortalCanaryStubResponse(status: 200, contentType: "text/html", body: Data())
    private var recorded: [URLRequest] = []

    func reset(status: Int, contentType: String, body: Data) {
        lock.lock(); defer { lock.unlock() }
        response = PortalCanaryStubResponse(status: status, contentType: contentType,
                                            body: body)
        recorded = []
    }

    func start(_ request: URLRequest) -> PortalCanaryStubResponse {
        lock.lock(); defer { lock.unlock() }
        recorded.append(request)
        return response
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }
}

private final class PortalCanaryStub: URLProtocol, @unchecked Sendable {
    private static let state = PortalCanaryStubState()

    static func reset(status: Int, contentType: String, body: Data) {
        state.reset(status: status, contentType: contentType, body: body)
    }

    static var requests: [URLRequest] { state.requests }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let stub = Self.state.start(request)
        let headers = ["Content-Type": stub.contentType]
        guard let response = HTTPURLResponse(url: request.url!, statusCode: stub.status,
                                             httpVersion: "HTTP/1.1", headerFields: headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !stub.body.isEmpty { client?.urlProtocol(self, didLoad: stub.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
