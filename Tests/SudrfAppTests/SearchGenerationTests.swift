import Foundation
import XCTest
@testable import SudrfKit
@testable import SudrfApp
@testable import CaptchaSolver

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

    func testDelayedSearchDoesNotPublishAfterPickerChoice() async throws {
        try await assertDelayedSearchIsIgnored(deferred: true) { model, _ in
            model.selectFromPicker(.tier(.supreme))
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

    func testMovementAutoSolvesEachCanonicalCaptchaHostAndRetries() async throws {
        let settings = CaptchaSettings.shared
        let previousEnabled = settings.autoSolveEnabled
        let previousForceDisabled = settings.forceDisabled
        defer {
            settings.autoSolveEnabled = previousEnabled
            settings.forceDisabled = previousForceDisabled
        }
        settings.autoSolveEnabled = true
        settings.forceDisabled = false

        let firstHost = "appeal.region.sudrf.ru"
        let secondHost = "cassation--region.sudrf.ru"
        await CaptchaTokenStore.shared.invalidate(domain: firstHost)
        await CaptchaTokenStore.shared.invalidate(domain: secondHost)
        defer {
            Task {
                await CaptchaTokenStore.shared.invalidate(domain: firstHost)
                await CaptchaTokenStore.shared.invalidate(domain: secondHost)
            }
        }
        let service = SearchMovementCaptchaMovementProvider(
            firstHost: firstHost, secondHost: secondHost)
        let solves = SearchMovementCaptchaSolveCounter()
        let (model, result, cacheKey) = makeMovementModel(
            caseNumber: "2-339/2026", service: service, settings: settings,
            autoSolve: { url, _, _, _ in await solves.solve(url) })
        defer { MovementMemoryCache.shared.remove(cacheKey) }

        await model.openMovement(result)

        let solveCalls = await solves.callsByCanonicalHost()
        XCTAssertEqual(solveCalls, [
            SudrfHost.moduleHost(firstHost): 1,
            secondHost: 1
        ])
        let movementCalls = await service.callCount
        XCTAssertEqual(movementCalls, 3, "initial movement plus one retry per solved court")
        XCTAssertTrue(model.movement?.instances.contains { $0.captchaFormURL != nil } == false)
        XCTAssertTrue(model.movement?.instances.contains { $0.domain == firstHost } == true)
        XCTAssertTrue(model.movement?.instances.contains { $0.domain == secondHost } == true)
    }

    func testClosingMovementDuringCaptchaSolvePreventsStalePublish() async throws {
        let settings = CaptchaSettings.shared
        let previousEnabled = settings.autoSolveEnabled
        let previousForceDisabled = settings.forceDisabled
        defer {
            settings.autoSolveEnabled = previousEnabled
            settings.forceDisabled = previousForceDisabled
        }
        settings.autoSolveEnabled = true
        settings.forceDisabled = false

        let formURL = URL(string: "https://appeal.region.sudrf.ru/modules.php?name=sud_delo")!
        await CaptchaTokenStore.shared.invalidate(domain: formURL.host!)
        defer { Task { await CaptchaTokenStore.shared.invalidate(domain: formURL.host!) } }
        let gate = SearchMovementCaptchaSolveGate()
        let service = SearchMovementCaptchaMovementProvider(
            firstHost: formURL.host!, secondHost: "cassation--region.sudrf.ru")
        let (model, result, cacheKey) = makeMovementModel(
            caseNumber: "2-340/2026", service: service, settings: settings,
            autoSolve: { _, _, _, _ in
                await gate.waitForRelease()
                return AutoCaptchaSolver.SolveResult(
                    token: CaptchaToken(value: "12345", id: "stale"), png: Data([1]))
            })
        let cached = movementWithCaptcha(caseNumber: result.caseNumber, formURL: formURL)
        MovementMemoryCache.shared.put(cacheKey, cached)
        defer { MovementMemoryCache.shared.remove(cacheKey) }

        let load = Task { await model.openMovement(result) }
        await gate.waitUntilStarted()
        XCTAssertTrue(model.loadingMovement)

        model.exitMovement()
        await gate.release()
        await load.value

        XCTAssertFalse(model.loadingMovement)
        XCTAssertNil(model.movement)
        XCTAssertEqual(MovementMemoryCache.shared.get(cacheKey)?.movement, cached)
        let staleToken = await CaptchaTokenStore.shared.token(forDomain: formURL.host!)
        XCTAssertNil(staleToken)
    }

    private func assertDelayedSearchIsIgnored(
        deferred: Bool = false,
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
        if deferred {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        XCTAssertFalse(model.searching)
        XCTAssertTrue(model.results.isEmpty)

        DelayedSearchURLProtocol.release()
        await search.value

        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.hasSearched)
    }

    private func makeMovementModel(
        caseNumber: String,
        service: SearchMovementCaptchaMovementProvider,
        settings: CaptchaSettings,
        autoSolve: @escaping (URL, SudrfClient, CaptchaSolver,
                               AutoCaptchaSolver.Settings) async -> AutoCaptchaSolver.SolveResult
    ) -> (SearchModel, CaseSearchResult, String) {
        let court = SearchModel.CourtOption(
            domain: "lower.region.sudrf.ru", title: "Районный суд",
            level: .district, code: "11RS0001")
        let result = CaseSearchResult(caseNumber: caseNumber)
        let model = SearchModel(
            captchaSettings: settings,
            movementServiceFactory: { _, _ in service },
            autoSolve: autoSolve)
        model.courts = [court]
        model.selectedCourtID = court.id
        model.cartotekaId = "g1"
        model.results = [result]
        model.selectedResultIndex = 0
        let key = MovementContext.identityKey(
            displayDomain: court.domain, courtCode: court.code, caseNumber: caseNumber)
        MovementMemoryCache.shared.remove(key)
        return (model, result, key)
    }

    private func movementWithCaptcha(caseNumber: String, formURL: URL) -> CaseMovement {
        CaseMovement(uid: "uid-\(caseNumber)", caseNumber: caseNumber, inForce: false,
                     instances: [CaseInstance(
                        level: .first, court: "Районный суд", caseNumber: caseNumber,
                        judge: nil, domain: "lower.region.sudrf.ru", foundByUID: false,
                        result: nil, sessions: []),
                        SearchMovementCaptchaMovementProvider.captchaStub(
                            domain: formURL.host!, level: .appeal)],
                     complaints: [:], acts: [])
    }
}

private actor SearchMovementCaptchaSolveCounter {
    private var calls: [String: Int] = [:]

    func solve(_ url: URL) -> AutoCaptchaSolver.SolveResult {
        let canonical = SudrfHost.moduleHost((url.host ?? "").lowercased())
        calls[canonical, default: 0] += 1
        return AutoCaptchaSolver.SolveResult(
            token: CaptchaToken(value: "12345", id: canonical), png: Data([1]))
    }

    func callsByCanonicalHost() -> [String: Int] { calls }
}

private actor SearchMovementCaptchaSolveGate {
    private var started = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitForRelease() async {
        started = true
        startWaiter?.resume()
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func release() { releaseWaiter?.resume() }
}

private actor SearchMovementCaptchaMovementProvider: MovementProviding {
    private let firstHost: String
    private let secondHost: String
    private(set) var callCount = 0

    init(firstHost: String, secondHost: String) {
        self.firstHost = firstHost
        self.secondHost = secondHost
    }

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        callCount += 1
        let firstSolved = await CaptchaTokenStore.shared.token(forDomain: firstHost) != nil
        let secondSolved = await CaptchaTokenStore.shared.token(forDomain: secondHost) != nil
        var instances = [CaseInstance(
            level: .first, court: "Районный суд", caseNumber: base.caseNumber,
            judge: nil, domain: court.domain, foundByUID: false, result: nil, sessions: [])]
        if firstSolved {
            // The retry confirms all dot/dash variants for this host.
            instances.append(Self.confirmedCard(domain: firstHost, level: .appeal))
        } else {
            for domain in [firstHost, SudrfHost.moduleHost(firstHost)] {
                instances.append(Self.captchaStub(domain: domain, level: .appeal))
            }
        }
        if secondSolved { instances.append(Self.confirmedCard(domain: secondHost, level: .cassation)) }
        else { instances.append(Self.captchaStub(domain: secondHost, level: .cassation)) }
        return CaseMovement(uid: "uid-\(base.caseNumber)", caseNumber: base.caseNumber,
                            inForce: false, instances: instances, complaints: [:], acts: [])
    }

    static func captchaStub(domain: String, level: CaseInstance.Level) -> CaseInstance {
        let formURL = URL(string: "https://\(domain)/modules.php?name=sud_delo")!
        return CaseInstance(level: level, court: domain, caseNumber: "—", judge: nil,
                            domain: domain, foundByUID: false, result: nil, sessions: [],
                            captchaFormURL: formURL)
    }

    private static func confirmedCard(domain: String,
                                      level: CaseInstance.Level) -> CaseInstance {
        CaseInstance(level: level, court: domain, caseNumber: "8-1/2026", judge: nil,
                     domain: domain, foundByUID: true, result: "Найдено", sessions: [])
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
        // Scope changes now resolve court lists through the same production
        // SudrfClient. Those portal-directory requests are not the delayed
        // case search this test controls and must finish immediately.
        if request.url?.host == "sudrf.ru" {
            respond(with: "<html><body></body></html>")
            return
        }
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
