import Foundation
import XCTest
@testable import SudrfKit
@testable import SudrfApp

@MainActor
final class MilitaryCourtPickerTests: XCTestCase {

    func testMilitaryTiersUseExactGVOVAVKVLists() async throws {
        MilitaryPickerURLProtocol.reset()
        let model = await makeModel()

        model.branch = .military
        model.tier = .district
        await model.resolveCourts()
        XCTAssertEqual(model.courts.map(\.code), ["11GV0001"])

        model.tier = .subject
        await model.resolveCourts()
        XCTAssertEqual(Set(model.courts.map(\.domain)),
                       Set(CourtDirectory.okrugMilitaryCourts.map(\.domain)))
        XCTAssertTrue(model.courts.allSatisfy { $0.level == .subject })

        model.tier = .appeal
        await model.resolveCourts()
        XCTAssertEqual(model.courts.map(\.domain), [CourtDirectory.appellateMilitaryCourt.domain])
        XCTAssertEqual(model.courts.first?.level, .appeal)

        model.tier = .cassation
        await model.resolveCourts()
        XCTAssertEqual(model.courts.map(\.domain), [CourtDirectory.cassationMilitaryCourt.domain])
        XCTAssertEqual(model.courts.first?.level, .cassation)
    }

    func testGeneralDistrictPickerStillExcludesMilitaryRows() async {
        MilitaryPickerURLProtocol.reset()
        let model = await makeModel()

        model.branch = .general
        model.tier = .district
        model.region = "11"
        await model.resolveCourts()

        XCTAssertEqual(model.courts.map(\.code), ["11RS0001"])
        XCTAssertTrue(model.courts.allSatisfy { $0.level == .district })
    }

    func testMilitaryRegionChangeDoesNotResolveCourtsAndRestoringGeneralResetsFilters() async throws {
        MilitaryPickerURLProtocol.reset()
        let model = await makeModel()
        model.branch = .military
        model.tier = .district
        model.cartotekaId = "u2" // допустима только как апелляция на мирового в общих судах
        let retained = CaseSearchResult(caseNumber: "1-1/2026")
        model.results = [retained]
        model.hasSearched = true
        model.status = "Предыдущая выдача"
        model.region = "77"

        model.regionChanged()
        XCTAssertEqual(MilitaryPickerURLProtocol.garrisonRequestCount(), 0)
        XCTAssertFalse(model.usesRegion)
        XCTAssertEqual(model.results, [retained])
        XCTAssertTrue(model.hasSearched)
        XCTAssertEqual(model.status, "Предыдущая выдача")

        model.region = "11"
        model.courtScopeChanged()
        try await waitUntil { model.courts.map(\.code) == ["11GV0001"] }
        XCTAssertEqual(model.cartotekaId, "u1")
        XCTAssertEqual(model.cartoteki.map(\.id), ["u1", "g1", "p1", "adm", "admj", "m"])
        XCTAssertNotEqual(model.cartotekaId, "u2")

        model.branch = .general
        model.courtScopeChanged()
        try await waitUntil { model.courts.map(\.code) == ["11RS0001"] }
        XCTAssertTrue(model.usesRegion)
        XCTAssertTrue(["u2", "g2", "p2"].allSatisfy { id in
            model.cartoteki.contains { $0.id == id }
        })
        XCTAssertNotNil(model.cartoteka)
    }

    func testTierChangeClearsSelectionBeforeReplacementResolutionRuns() async {
        let model = await makeModel()
        let garrison = SearchModel.CourtOption(
            domain: "gvs.sudrf.ru", title: "Гарнизонный суд", level: .district,
            code: "11GV0001")
        model.branch = .military
        model.tier = .district
        model.courts = [garrison]
        model.selectedCourtID = garrison.id

        model.tier = .subject
        model.courtScopeChanged()

        XCTAssertTrue(model.courts.isEmpty)
        XCTAssertEqual(model.selectedCourtID, "")
        await Task.yield()
    }

    func testMilitaryBranchNormalizationStartsOneGarrisonResolution() async throws {
        MilitaryPickerURLProtocol.reset()
        let model = await makeModel()
        model.branch = .general
        model.tier = .magistrate

        model.branch = .military
        model.courtScopeChanged()
        XCTAssertEqual(model.tier, .district)
        XCTAssertEqual(MilitaryPickerURLProtocol.garrisonRequestCount(), 0)

        // Имитирует onChange звена, вызванный нормализацией magistrate → district.
        model.courtScopeChanged()
        try await waitUntil { model.courts.map(\.code) == ["11GV0001"] }
        XCTAssertEqual(MilitaryPickerURLProtocol.garrisonRequestCount(), 1)
    }

    func testQueuedScopeChangesStartOnlyLatestResolution() async throws {
        MilitaryPickerURLProtocol.reset(garrisonIsDelayed: true)
        let model = await makeModel()

        model.branch = .military
        model.tier = .subject
        model.courtScopeChanged()
        model.tier = .district
        model.courtScopeChanged()

        try await MilitaryPickerURLProtocol.waitForGarrisonRequest()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(MilitaryPickerURLProtocol.garrisonRequestCount(), 1)
        MilitaryPickerURLProtocol.releaseGarrison()
        try await waitUntil { model.courts.map(\.code) == ["11GV0001"] }
    }

    func testDelayedGarrisonSuccessCannotOverwriteMilitarySubjectList() async throws {
        MilitaryPickerURLProtocol.reset(garrisonIsDelayed: true)
        let model = await makeModel()
        model.branch = .military
        model.tier = .district

        let oldResolution = Task { await model.resolveCourts() }
        try await MilitaryPickerURLProtocol.waitForGarrisonRequest()

        model.tier = .subject
        model.courtScopeChanged()
        try await waitUntil { model.courts.count == CourtDirectory.okrugMilitaryCourts.count }
        let subjectDomains = Set(model.courts.map(\.domain))
        XCTAssertEqual(subjectDomains, Set(CourtDirectory.okrugMilitaryCourts.map(\.domain)))

        MilitaryPickerURLProtocol.releaseGarrison()
        await oldResolution.value
        XCTAssertEqual(Set(model.courts.map(\.domain)), subjectDomains)
        XCTAssertEqual(model.status, "Судов в списке: \(subjectDomains.count)")
    }

    func testDelayedGarrisonErrorCannotOverwriteLatestSubjectSuccess() async throws {
        MilitaryPickerURLProtocol.reset(garrisonIsDelayed: true, garrisonFails: true)
        let model = await makeModel()
        model.branch = .military
        model.tier = .district

        let oldResolution = Task { await model.resolveCourts() }
        try await MilitaryPickerURLProtocol.waitForGarrisonRequest()

        model.tier = .subject
        model.courtScopeChanged()
        try await waitUntil { model.courts.count == CourtDirectory.okrugMilitaryCourts.count }
        let latestStatus = model.status

        MilitaryPickerURLProtocol.releaseGarrison()
        await oldResolution.value
        XCTAssertEqual(model.courts.count, CourtDirectory.okrugMilitaryCourts.count)
        XCTAssertEqual(model.status, latestStatus)
        XCTAssertFalse(model.status.contains("Ошибка загрузки судов"))
    }

    func testStaleDeferDoesNotClearLatestPendingResolution() async throws {
        MilitaryPickerURLProtocol.reset(garrisonIsDelayed: true, regionalIsDelayed: true)
        let model = await makeModel()
        model.branch = .military
        model.tier = .district

        let oldResolution = Task { await model.resolveCourts() }
        try await MilitaryPickerURLProtocol.waitForGarrisonRequest()

        model.branch = .general
        model.region = "11"
        model.courtScopeChanged()

        // Новый regional request стоит за уже активным garrison request в
        // общей FIFO-очереди SudrfClient и стартует после освобождения слота.
        MilitaryPickerURLProtocol.releaseGarrison()
        await oldResolution.value
        try await MilitaryPickerURLProtocol.waitForRegionalRequest()
        XCTAssertTrue(model.resolving)
        XCTAssertTrue(model.courts.isEmpty)
        XCTAssertEqual(model.status, "Загружаю суды…")

        MilitaryPickerURLProtocol.releaseRegional()
        try await waitUntil { model.courts.map(\.code) == ["11RS0001"] }
        XCTAssertFalse(model.resolving)
    }

    private func makeModel() async -> SearchModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MilitaryPickerURLProtocol.self]
        let client = SudrfClient(
            session: URLSession(configuration: configuration), minInterval: 0)
        await client.setMaxAttemptsForTesting(1)
        let resolver = DistrictCourtResolver(client: client, cacheURL: nil)
        return SearchModel(client: client, resolver: resolver)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("condition timed out")
        throw URLError(.timedOut)
    }
}

private final class MilitaryPickerURLProtocol: URLProtocol {
    nonisolated(unsafe) private static var garrisonStarted = false
    nonisolated(unsafe) private static var garrisonRequests = 0
    nonisolated(unsafe) private static var garrisonIsDelayed = false
    nonisolated(unsafe) private static var garrisonFails = false
    nonisolated(unsafe) private static var regionalStarted = false
    nonisolated(unsafe) private static var regionalIsDelayed = false
    nonisolated(unsafe) private static var pendingGarrisons: [MilitaryPickerURLProtocol] = []
    nonisolated(unsafe) private static var pendingRegionals: [MilitaryPickerURLProtocol] = []
    private static let condition = NSCondition()

    static func reset(garrisonIsDelayed: Bool = false, garrisonFails: Bool = false,
                      regionalIsDelayed: Bool = false) {
        condition.lock()
        Self.garrisonStarted = false
        Self.garrisonRequests = 0
        Self.garrisonIsDelayed = garrisonIsDelayed
        Self.garrisonFails = garrisonFails
        Self.regionalStarted = false
        Self.regionalIsDelayed = regionalIsDelayed
        Self.pendingGarrisons = []
        Self.pendingRegionals = []
        condition.broadcast()
        condition.unlock()
    }

    static func releaseGarrison() {
        condition.lock()
        let pending = pendingGarrisons
        pendingGarrisons = []
        garrisonIsDelayed = false
        let fails = garrisonFails
        condition.broadcast()
        condition.unlock()
        for request in pending {
            if fails {
                request.client?.urlProtocol(
                    request, didFailWithError: URLError(.notConnectedToInternet))
            } else {
                request.respond(with: Self.garrisonBody)
            }
        }
    }

    static func releaseRegional() {
        condition.lock()
        let pending = pendingRegionals
        pendingRegionals = []
        regionalIsDelayed = false
        condition.broadcast()
        condition.unlock()
        for request in pending { request.respond(with: Self.regionalBody) }
    }

    static func waitForGarrisonRequest() async throws {
        for _ in 0..<500 {
            if hasGarrisonStarted() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("garrison request did not start")
        throw URLError(.timedOut)
    }

    static func garrisonRequestCount() -> Int {
        condition.lock()
        let count = garrisonRequests
        condition.unlock()
        return count
    }

    static func waitForRegionalRequest() async throws {
        for _ in 0..<500 {
            if hasRegionalStarted() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("regional request did not start")
        throw URLError(.timedOut)
    }

    private static func hasGarrisonStarted() -> Bool {
        condition.lock()
        let started = garrisonStarted
        condition.unlock()
        return started
    }

    private static func hasRegionalStarted() -> Bool {
        condition.lock()
        let started = regionalStarted
        condition.unlock()
        return started
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let type = URLComponents(url: request.url ?? URL(string: "https://sudrf.ru")!,
                                 resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "court_type" }?.value
        if type == "GV" {
            Self.condition.lock()
            Self.garrisonStarted = true
            Self.garrisonRequests += 1
            let delayed = Self.garrisonIsDelayed
            if delayed { Self.pendingGarrisons.append(self) }
            Self.condition.broadcast()
            Self.condition.unlock()
            if delayed {
                return
            } else {
                respond(with: Self.garrisonBody)
            }
            return
        }

        Self.condition.lock()
        Self.regionalStarted = true
        let delayed = Self.regionalIsDelayed
        if delayed { Self.pendingRegionals.append(self) }
        Self.condition.broadcast()
        Self.condition.unlock()
        if delayed {
            return
        }
        respond(with: Self.regionalBody)
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

    override func stopLoading() {}

    private static let garrisonBody = """
    <ul>
      <li><a class='court-result' onclick="listcontrol('g1','11GV0001')">Гарнизонный суд</a>
        <a href='https://gvs.sudrf.ru/'>сайт</a></li>
      <li><a class='court-result' onclick="listcontrol('o1','11OV0001')">Окружной суд</a>
        <a href='https://ovs.sudrf.ru/'>сайт</a></li>
      <li><a class='court-result' onclick="listcontrol('a1','11AV0001')">Апелляционный суд</a>
        <a href='https://avs.sudrf.ru/'>сайт</a></li>
      <li><a class='court-result' onclick="listcontrol('k1','11KV0001')">Кассационный суд</a>
        <a href='https://kvs.sudrf.ru/'>сайт</a></li>
    </ul>
    """

    private static let regionalBody = """
    <ul>
      <li><a class='court-result' onclick="listcontrol('r1','11RS0001')">Районный суд</a>
        <a href='https://rs.sudrf.ru/'>сайт</a></li>
      <li><a class='court-result' onclick="listcontrol('g1','11GV0001')">Гарнизонный суд</a>
        <a href='https://gvs.sudrf.ru/'>сайт</a></li>
    </ul>
    """
}
