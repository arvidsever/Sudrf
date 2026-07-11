import XCTest
@testable import SudrfKit

/// Интеграция второй кассации (ВС РФ) в `MovementService` на РЕАЛЬНЫХ фикстурах
/// выдачи ВС (дело Воробьёва). Проверяется:
///  • истребованное дело (с УИД) даёт одну инстанцию `.vsCassation` (foundByUID);
///  • истребовавшая жалоба НЕ дублируется отдельной записью, её «Истребовано дело»
///    вливается в движение дела;
///  • «отказ в передаче» попадает в результат и в пометку `note`;
///  • посторонние регионы с тем же № дела 1-й инстанции отсеиваются тройкой;
///  • без внедрённого клиента `vsrf` вторая кассация не добавляется.
final class VSRFMovementTests: XCTestCase {

    private func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("Фикстура \(name).html не найдена")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private let uid = "11RS0001-01-2021-021221-14"

    private func district() -> Court {
        Court(domain: "syktsud--komi.sudrf.ru",
              title: "Сыктывкарский городской суд", level: .district)
    }
    private func base() -> CaseSearchResult {
        CaseSearchResult(caseNumber: "2-1649/2022", caseID: "900001", caseUID: "guid-000")
    }
    private func baseCard() throws -> CaseCard {
        // Датированная сессия обязательна: instanceOrderKey сортирует инстанции
        // по самому раннему событию движения, недатированные уходят в конец —
        // без неё 1-я инстанция «утонула» бы ниже второй кассации ВС.
        CaseCard(rawText: "", actText: nil,
                 sessions: [CaseSession(date: "02.03.2022", event: "Судебное заседание",
                                        result: "Иск удовлетворён полностью")],
                 judge: "О.А. Машкалева",
                 result: "Иск удовлетворён полностью", uid: uid,
                 caseNumber: "2-1649/2022",
                 parties: CaseParties(plaintiffs: ["Воробьёв Виктор Викторович"],
                                      defendants: ["Администрация муниципального округа Хамовники"]))
    }

    private func makeVSRF() throws -> MockVSRF {
        MockVSRF(uidResults: try VSRFSearchParser.parse(html: try fixture("vsrf_search_uid")),
                 numberResults: try VSRFSearchParser.parse(html: try fixture("vsrf_search_number")),
                 card: try VSRFCardParser.parse(html: try fixture("vsrf_card_vorobyev")))
    }

    func testSecondCassationWiredFromVSRF() async throws {
        let client = MockCase(firstCardID: "900001", firstCard: try baseCard())
        let service = MovementService(client: client, higherCourtDomains: [], vsrf: try makeVSRF())

        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        let mv = try await service.movement(for: base(), court: district(), cartoteka: cart)

        let vs = mv.instances.filter { $0.level == .vsCassation }
        XCTAssertEqual(vs.count, 1, "должна быть ровно одна инстанция второй кассации (дело)")
        let d = try XCTUnwrap(vs.first)
        XCTAssertEqual(d.court, "Верховный Суд РФ")
        XCTAssertEqual(d.caseNumber, "3-КГ23-1-К3")
        XCTAssertTrue(d.foundByUID)
        XCTAssertEqual(d.judge, "Жубрин М.А.")
        XCTAssertEqual(d.note, "отказ в передаче")
        XCTAssertEqual(d.result, "Отказ в передаче дела в суд кассационной инстанции")
        // «Истребовано дело» из жалобы влилось в движение дела.
        XCTAssertTrue(d.sessions.contains { $0.event.contains("Истребовано дело") && $0.date == "19.12.2022" })
        XCTAssertTrue(d.sessions.contains { $0.event.contains("Отказ в передаче") })
        // Отдельной «жалобной» инстанции быть не должно (жалоба истребована).
        XCTAssertFalse(vs.contains { $0.caseNumber == "3-КФ22-336-К3" })
    }

    func testSecondCassationAfterLowerInstancesInOrder() async throws {
        let client = MockCase(firstCardID: "900001", firstCard: try baseCard())
        let service = MovementService(client: client, higherCourtDomains: [], vsrf: try makeVSRF())
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        let mv = try await service.movement(for: base(), court: district(), cartoteka: cart)

        // 1-я инстанция должна идти раньше второй кассации ВС.
        let levels = mv.instances.map { $0.level }
        if let iFirst = levels.firstIndex(of: .first), let iVS = levels.firstIndex(of: .vsCassation) {
            XCTAssertLessThan(iFirst, iVS)
        } else {
            XCTFail("ожидались инстанции .first и .vsCassation")
        }
    }

    func testNoVSRFClientMeansNoSecondCassation() async throws {
        let client = MockCase(firstCardID: "900001", firstCard: try baseCard())
        let service = MovementService(client: client, higherCourtDomains: [])   // vsrf не внедрён
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        let mv = try await service.movement(for: base(), court: district(), cartoteka: cart)
        XCTAssertFalse(mv.instances.contains { $0.level == .vsCassation })
    }

    func testIntakeIsAssignedOnlyToNearestFollowingCaseRound() async {
        let first = VSRFFirstInstance(court: "Сыктывкарский городской суд", caseNumber: "2-1649/2022")
        let complaintOne = VSRFProduction(cardID: "c1", kind: .complaint, number: "3-КФ-1",
                                           incomingDate: "01.01.2025", firstInstance: first,
                                           events: [VSRFEvent(date: "10.01.2025", text: "Истребовано дело")])
        let complaintUnmatched = VSRFProduction(cardID: "c2", kind: .complaint, number: "3-КФ-2",
                                                 incomingDate: "01.04.2025", firstInstance: first,
                                                 events: [VSRFEvent(date: "20.04.2025", text: "Истребовано дело")])
        let caseOne = VSRFProduction(cardID: "d1", kind: .caseFile, number: "3-КГ-1",
                                     incomingDate: "12.01.2025", uid: uid, firstInstance: first,
                                     events: [VSRFEvent(date: "15.01.2025", text: "Передано судье")])
        let caseTwo = VSRFProduction(cardID: "d2", kind: .caseFile, number: "3-КГ-2",
                                     incomingDate: "15.03.2025", uid: uid, firstInstance: first,
                                     events: [VSRFEvent(date: "16.03.2025", text: "Принято к производству")])
        let results = VSRFSearchResults(total: 4, results: [caseOne, caseTwo, complaintOne, complaintUnmatched])
        let mock = MockVSRF(uidResults: results, numberResults: results, card: VSRFCard(productions: []))

        let instances = await MovementService.vsrfInstances(
            vsrf: mock, uid: uid, firstInstanceCourt: first.court!,
            firstInstanceCaseNumber: first.caseNumber!, partySurnames: [])
        let roundOne = instances.first { $0.caseNumber == "3-КГ-1" }
        let roundTwo = instances.first { $0.caseNumber == "3-КГ-2" }
        XCTAssertTrue(roundOne?.sessions.contains { $0.event.contains("Истребовано дело") } == true)
        XCTAssertFalse(roundTwo?.sessions.contains { $0.event.contains("Истребовано дело") } == true)
        XCTAssertNotNil(instances.first { $0.caseNumber == "3-КФ-2" },
                        "жалоба без датированного последующего дела остаётся отдельной")
    }
}

// MARK: - Моки

private actor MockCase: CaseProviding {
    let firstCardID: String
    let firstCard: CaseCard
    init(firstCardID: String, firstCard: CaseCard) {
        self.firstCardID = firstCardID; self.firstCard = firstCard
    }
    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] { [] }
    func fetchCard(url: URL) async throws -> CaseCard {
        throw SudrfError.http(status: 404)   // в этих сценариях путь по ссылке не используется
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard { firstCard }
}

private struct MockVSRF: VSRFProviding {
    let uidResults: VSRFSearchResults
    let numberResults: VSRFSearchResults
    let card: VSRFCard
    func search(uniqueNumber: String?, oldCaseNumber: String?,
                keywords: String?) async throws -> VSRFSearchResults {
        if uniqueNumber != nil { return uidResults }
        if oldCaseNumber != nil { return numberResults }
        return VSRFSearchResults(total: 0, results: [])
    }
    func fetchCard(productionID: String, section: VSRFCardSection) async throws -> VSRFCard { card }
}
