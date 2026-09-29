import XCTest
@testable import SudrfKit
@testable import SudrfApp

final class SearchMovementStageTests: XCTestCase {
    @MainActor
    func testIssue356PublishedAppealCardsKeepTheirStageAndActTitle() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Issue356CardStub.self]
        let client = SudrfClient(session: URLSession(configuration: configuration), minInterval: 0)

        for (number, id, guid, region, date, lowerNumber) in [
            ("66а-757/2026", "6251713", "24eccea2-0839-415f-b4d6-0dac1da1b95f",
             "11", "18.09.2026", "3а-681/2026"),
            ("66а-758/2026", "6251720", "62abc79c-442b-4353-9a8d-de5682cfe9d5",
             "74", "17.09.2026", "3а-3040/2026")
        ] {
            let model = SearchModel(client: client)
            model.tier = .appeal
            model.region = region
            await model.resolveCourts()
            let court = SearchModel.CourtOption(
                domain: "2ap.sudrf.ru", title: "Второй апелляционный суд", level: .appeal)
            model.courts = [court]
            model.selectedCourtID = court.id
            model.cartotekaId = "p2"
            let url = try XCTUnwrap(URL(string: "https://2ap.sudrf.ru/modules.php?name=sud_delo"
                + "&srv_num=1&name_op=case&case_id=\(id)&case_uid=\(guid)&delo_id=42"))
            let row = CaseSearchResult(caseNumber: number, caseID: id,
                                       caseUID: guid, cardURL: url)
            model.results = [row]
            let cacheKey = MovementContext.identityKey(
                displayDomain: court.domain, courtCode: court.code, caseNumber: number)
            MovementMemoryCache.shared.remove(cacheKey)
            defer { MovementMemoryCache.shared.remove(cacheKey) }

            await model.openMovement(row)

            let movement = try XCTUnwrap(model.movement, model.status)
            let base = try XCTUnwrap(movement.instances.first {
                $0.caseNumber == number && $0.domain == court.domain
            })
            XCTAssertEqual(base.level, .appeal)
            let act = try XCTUnwrap(movement.acts.first { $0.id == base.actID })
            XCTAssertEqual(act.title, "Апелляционное определение")
            XCTAssertEqual(act.instanceLevel, .appeal)
            XCTAssertEqual(act.date, date)
            XCTAssertTrue(movement.actBodies[act.id]?.contains("АПЕЛЛЯЦИОННОЕ ОПРЕДЕЛЕНИЕ") == true)
            XCTAssertEqual(base.sourceEvidence?.lowerCourt?.caseNumber, lowerNumber)
            XCTAssertFalse(movement.instances.contains {
                $0.caseNumber == number && $0.level == .first
            })
        }
    }

    @MainActor
    func testIssue356OtherSearchCartotekasUseTheirOwnStage() async throws {
        for (tier, cartoteka, number, expected) in [
            (CourtTier.appeal, "g2", "66-1/2026", CaseInstance.Level.appeal),
            (.appeal, "u2", "55-1/2026", .appeal),
            (.cassation, "g3", "88-1/2026", .cassation),
            (.cassation, "u3", "77-1/2026", .cassation),
            (.cassation, "p3", "88а-1/2026", .cassation),
            (.district, "g1", "2-1/2026", .first)
        ] {
            let model = SearchModel()
            model.tier = tier
            if tier != .district { await model.resolveCourts() }
            let court = SearchModel.CourtOption(
                domain: tier == .appeal ? "2ap.sudrf.ru"
                    : tier == .cassation ? "3kas.sudrf.ru" : "syktsud.komi.sudrf.ru",
                title: "Тестовый суд", level: tier.level ?? .district)
            model.courts = [court]
            model.selectedCourtID = court.id
            model.cartotekaId = cartoteka
            let row = CaseSearchResult(caseNumber: number)
            model.results = [row]

            await model.openMovement(row)

            XCTAssertEqual(model.movement?.instances.first?.level, expected,
                           "\(tier) / \(cartoteka)")
        }
    }

    @MainActor
    func testIssue356WrongStageCacheWithoutDirectURLIsReloaded() async throws {
        let (model, row, court, cacheKey) = try await appealModelWithoutCardURL()
        defer { MovementMemoryCache.shared.remove(cacheKey) }
        let wrong = CaseMovement(uid: "", caseNumber: row.caseNumber, inForce: false,
                                 instances: [instance(.first, court: court,
                                                      number: row.caseNumber)],
                                 complaints: [:], acts: [])
        MovementMemoryCache.shared.put(cacheKey, wrong)

        await model.openMovement(row)

        XCTAssertEqual(model.movement?.instances.first?.level, .appeal)
        XCTAssertNotEqual(model.movement, wrong)
    }

    @MainActor
    func testIssue356CorrectStageCacheKeepsSeparateLowerInstance() async throws {
        let (model, row, court, cacheKey) = try await appealModelWithoutCardURL()
        defer { MovementMemoryCache.shared.remove(cacheKey) }
        let cached = CaseMovement(uid: "", caseNumber: row.caseNumber, inForce: false,
            instances: [
                instance(.first, court: Court(domain: "vs--komi.sudrf.ru",
                    title: "Верховный Суд Республики Коми", level: .subject),
                    number: "3а-681/2026"),
                instance(.appeal, court: court, number: row.caseNumber)
            ], complaints: [:], acts: [])
        MovementMemoryCache.shared.put(cacheKey, cached)

        await model.openMovement(row)

        XCTAssertEqual(model.movement, cached)
        XCTAssertEqual(model.movement?.instances.map(\.level), [.first, .appeal])
    }

    @MainActor
    private func appealModelWithoutCardURL() async throws
        -> (SearchModel, CaseSearchResult, Court, String) {
        let model = SearchModel()
        model.tier = .appeal
        await model.resolveCourts()
        let court = SearchModel.CourtOption(
            domain: "2ap.sudrf.ru", title: "Второй апелляционный суд", level: .appeal)
        model.courts = [court]
        model.selectedCourtID = court.id
        model.cartotekaId = "p2"
        let row = CaseSearchResult(caseNumber: "66а-757/2026")
        model.results = [row]
        let key = MovementContext.identityKey(
            displayDomain: court.domain, courtCode: court.code, caseNumber: row.caseNumber)
        MovementMemoryCache.shared.remove(key)
        return (model, row, court.court, key)
    }

    private func instance(_ level: CaseInstance.Level, court: Court,
                          number: String) -> CaseInstance {
        CaseInstance(level: level, court: court.title, caseNumber: number,
                     judge: nil, domain: court.domain, foundByUID: false,
                     result: nil, sessions: [])
    }
}

private final class Issue356CardStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "case_id" }?.value
        let fixture = id == "6251713" ? "issue356_757"
            : id == "6251720" ? "issue356_758" : nil
        let file = fixture.flatMap {
            Bundle.module.url(forResource: $0, withExtension: "html", subdirectory: "Fixtures")
        }
        let body = file.flatMap { try? Data(contentsOf: $0) }
            ?? Data("Данных по запросу не найдено".utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
