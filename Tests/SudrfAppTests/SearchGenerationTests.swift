import Foundation
import XCTest
@testable import SudrfKit
@testable import SudrfApp

@MainActor
final class SearchGenerationTests: XCTestCase {

    func testDelayedSearchDoesNotPublishAfterScopeOrQueryChange() async throws {
        try await assertDelayedSearchIsIgnored { model, _ in model.branch = .military }
        try await assertDelayedSearchIsIgnored { model, _ in model.tier = .subject }
        try await assertDelayedSearchIsIgnored { model, otherCourt in
            model.selectedCourtID = otherCourt.id
        }
        try await assertDelayedSearchIsIgnored { model, _ in model.cartotekaId = "adm" }
        try await assertDelayedSearchIsIgnored { model, _ in
            model.queryCaseNumber = "2-2/2026"
        }
    }

    func testCourtScopeChangeClearsSearchCardAndMovementState() async {
        let model = SearchModel()
        let court = SearchModel.CourtOption(
            domain: "syktsud--komi.sudrf.ru", title: "Сыктывкарский городской суд",
            level: .district, code: "11RS0001")
        let result = CaseSearchResult(caseNumber: "2-1/2026")
        let act = CaseAct(id: "act", title: "Решение", date: "01.01.2026",
                          courtShort: "Суд", instanceLevel: .first)

        model.tier = .supreme // обходится без сетевого резолвера в этом тесте
        model.courts = [court]
        model.selectedCourtID = court.id
        model.results = [result]
        model.selectedResultIndex = 0
        model.actText = "Текст акта"
        model.actLinks = [URL(string: "https://example.test/act")!]
        model.cardActs = [act]
        model.cardActBodies = [act.id: "Текст акта"]
        model.selectedCardActID = act.id
        model.actMissing = true
        model.hasSearched = true
        model.loadingCard = true
        model.movement = CaseMovement(uid: "uid", caseNumber: result.caseNumber, inForce: false,
                                      instances: [], complaints: [:], acts: [act],
                                      actBodies: [act.id: "Текст акта"])
        model.loadingMovement = true
        model.selectedActID = act.id
        model.expandedComplaints = ["complaint"]

        model.courtScopeChanged()

        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selectedResultID)
        XCTAssertTrue(model.actText.isEmpty)
        XCTAssertTrue(model.actLinks.isEmpty)
        XCTAssertTrue(model.cardActs.isEmpty)
        XCTAssertTrue(model.cardActBodies.isEmpty)
        XCTAssertNil(model.selectedCardActID)
        XCTAssertFalse(model.actMissing)
        XCTAssertFalse(model.hasSearched)
        XCTAssertFalse(model.loadingCard)
        XCTAssertNil(model.movement)
        XCTAssertFalse(model.loadingMovement)
        XCTAssertNil(model.selectedActID)
        XCTAssertTrue(model.expandedComplaints.isEmpty)
    }

    func testDelayedMovementDoesNotPublishAfterScopeChange() async throws {
        DelayedMovementURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedMovementURLProtocol.self]
        let client = SudrfClient(session: URLSession(configuration: configuration), minInterval: 0)
        await client.setMaxAttemptsForTesting(1)

        let model = SearchModel(client: client)
        let court = SearchModel.CourtOption(
            domain: "syktsud--komi.sudrf.ru", title: "Сыктывкарский городской суд",
            level: .district, code: "11RS0001")
        let result = CaseSearchResult(caseNumber: "2-1/2026", caseID: "42", caseUID: "uid-42")
        model.courts = [court]
        model.selectedCourtID = court.id
        model.cartotekaId = "g1"
        model.results = [result]

        let load = Task { await model.openMovement(result) }
        try await DelayedMovementURLProtocol.waitForRequest()
        XCTAssertTrue(model.loadingMovement)

        model.branch = .military
        XCTAssertFalse(model.loadingMovement)
        XCTAssertNil(model.movement)
        XCTAssertNil(model.selectedResultID)

        DelayedMovementURLProtocol.release()
        await load.value

        XCTAssertFalse(model.loadingMovement)
        XCTAssertNil(model.movement)
        XCTAssertNil(model.selectedActID)
        XCTAssertNil(model.selectedResultID)
    }

    private func assertDelayedSearchIsIgnored(
        after change: @escaping @MainActor (SearchModel, SearchModel.CourtOption) -> Void
    ) async throws {
        DelayedSearchURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DelayedSearchURLProtocol.self]
        let client = SudrfClient(session: URLSession(configuration: configuration), minInterval: 0)
        await client.setMaxAttemptsForTesting(1)

        let model = SearchModel(client: client)
        let court = SearchModel.CourtOption(
            domain: "syktsud--komi.sudrf.ru", title: "Сыктывкарский городской суд",
            level: .district, code: "11RS0001")
        let otherCourt = SearchModel.CourtOption(
            domain: "ukhtasud--komi.sudrf.ru", title: "Ухтинский городской суд",
            level: .district, code: "11RS0002")
        model.courts = [court, otherCourt]
        model.selectedCourtID = court.id
        model.cartotekaId = "g1"
        model.queryCaseNumber = "2-1/2026"

        let search = Task { await model.runSearch() }
        try await DelayedSearchURLProtocol.waitForRequest()

        change(model, otherCourt)
        XCTAssertFalse(model.searching)
        XCTAssertTrue(model.results.isEmpty)

        DelayedSearchURLProtocol.release()
        await search.value

        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.hasSearched)
    }
}

private final class DelayedMovementURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var pending: [DelayedMovementURLProtocol] = []
    private static let condition = NSCondition()

    static func reset() {
        condition.lock()
        started = false
        pending = []
        condition.broadcast()
        condition.unlock()
    }

    static func waitForRequest() async throws {
        for _ in 0..<500 {
            if hasStarted() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("movement request did not start")
        throw URLError(.timedOut)
    }

    static func release() {
        condition.lock()
        let requests = pending
        pending = []
        condition.broadcast()
        condition.unlock()
        for request in requests { request.respond() }
    }

    private static func hasStarted() -> Bool {
        condition.lock()
        let value = started
        condition.unlock()
        return value
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.condition.lock()
        Self.started = true
        Self.pending.append(self)
        Self.condition.broadcast()
        Self.condition.unlock()
    }

    override func stopLoading() {}

    private func respond() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"])
        else { return }
        let body = "<html><body><div class='casenumber'>ДЕЛО № 2-1/2026</div></body></html>"
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class DelayedSearchURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var started = false
    nonisolated(unsafe) private static var pending: [DelayedSearchURLProtocol] = []
    private static let condition = NSCondition()

    static func reset() {
        condition.lock()
        started = false
        pending = []
        condition.broadcast()
        condition.unlock()
    }

    static func waitForRequest() async throws {
        for _ in 0..<500 {
            if hasStarted() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("search request did not start")
        throw URLError(.timedOut)
    }

    static func release() {
        condition.lock()
        let requests = pending
        pending = []
        condition.broadcast()
        condition.unlock()
        for request in requests { request.respond() }
    }

    private static func hasStarted() -> Bool {
        condition.lock()
        let value = started
        condition.unlock()
        return value
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let operation = URLComponents(url: request.url ?? URL(string: "https://sudrf.ru")!,
                                      resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "name_op" }?.value
        if operation == "sf" {
            respond(with: "<html><body>Форма поиска</body></html>")
            return
        }
        Self.condition.lock()
        Self.started = true
        Self.pending.append(self)
        Self.condition.broadcast()
        Self.condition.unlock()
    }

    override func stopLoading() {}

    private func respond() {
        respond(with: """
        <html><body><table id="tablcont">
          <tr><th>№</th><th>Дата</th><th>Стороны</th><th>Судья</th><th>Результат</th></tr>
          <tr>
            <td><a href="modules.php?name=sud_delo&amp;name_op=case&amp;case_id=42&amp;case_uid=uid-42">2-1/2026</a></td>
            <td>01.01.2026</td><td>Иванов И.И.</td><td>Петров П.П.</td><td>Решение</td>
          </tr>
        </table></body></html>
        """)
    }

    private func respond(with body: String) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"])
        else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
