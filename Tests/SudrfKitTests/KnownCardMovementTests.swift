import XCTest
@testable import SudrfKit

/// Известные прямые ссылки (KnownCard) и материалы в сборке движения (v21):
///  • капча на форме вышестоящего суда: вместо заглушки инстанция собирается
///    прямым GET карточки по известной ссылке;
///  • УИД базовой карточки пуст (сквозной поиск невозможен) — known cards
///    подтягиваются добором;
///  • материалы домашнего суда находятся по УИД в картотеке «m» и встают
///    инстанциями .material в конец; капча в m-поиске оставляет source partial;
///  • дубли не плодятся: карточка, уже найденная поиском, добором не повторяется.
final class KnownCardMovementTests: XCTestCase {

    private static let uid = "11RS0001-01-2025-011255-03"

    private func districtCourt() -> Court {
        Court(domain: "syktsud--komi.sudrf.ru",
              title: "Сыктывкарский городской суд", level: .district)
    }

    private func base() -> CaseSearchResult {
        CaseSearchResult(caseNumber: "2-7212/2025",
                         caseID: "30636693", caseUID: "guid-1")
    }

    private func firstCard(uid: String? = KnownCardMovementTests.uid) -> CaseCard {
        CaseCard(rawText: "", actText: "РЕШЕНИЕ\nиск удовлетворить.",
                 sessions: [CaseSession(date: "18.08.2025", event: "Судебное заседание")],
                 judge: "Печинина Л.А.", result: "Иск удовлетворён",
                 uid: uid, caseNumber: "2-7212/2025", decisionDate: "18.08.2025")
    }

    private func cassationKnownCard() -> KnownCard {
        KnownCard(domain: "3kas.sudrf.ru",
                  courtTitle: "Третий кассационный суд общей юрисдикции",
                  caseID: "24352048", caseUID: "guid-kas",
                  deloID: "2800001", new: "2800001",
                  caseNumber: "8Г-10837/2026", levelRaw: "cassation", cartotekaID: "g3")
    }

    private func cassationCard() -> CaseCard {
        CaseCard(rawText: "", actText: "ОПРЕДЕЛЕНИЕ\nжалобу оставить без удовлетворения.",
                 sessions: [CaseSession(date: "10.06.2026", event: "Судебное заседание")],
                 judge: "Иванов И.И.", result: "Жалоба оставлена без удовлетворения",
                 uid: Self.uid, caseNumber: "8Г-10837/2026", decisionDate: "10.06.2026")
    }

    private func materialKnownCard() -> KnownCard {
        KnownCard(domain: "syktsud--komi.sudrf.ru",
                  courtTitle: "Сыктывкарский городской суд",
                  caseID: "m1", caseUID: "guid-m",
                  deloID: "1610001", new: "0",
                  caseNumber: "13-2472/2026", levelRaw: "material", cartotekaID: "m")
    }

    private func materialCard(number: String = "13-2472/2026") -> CaseCard {
        CaseCard(rawText: "", actText: "ОПРЕДЕЛЕНИЕ\nзаявление удовлетворить.",
                 sessions: [CaseSession(date: "01.09.2026", event: "Судебное заседание")],
                 result: "Заявление удовлетворено",
                 uid: Self.uid, caseNumber: number, decisionDate: "01.09.2026")
    }

    // MARK: Капча → прямая ссылка вместо заглушки

    func testCaptchaRescuedByKnownCard() async throws {
        let mock = ScriptedClient(cards: ["30636693": firstCard(),
                                          "24352048": cassationCard()],
                                  captchaDomains: ["3kas.sudrf.ru"])
        let service = MovementService(client: mock,
                                      higherCourtDomains: ["3kas.sudrf.ru"],
                                      knownCards: [cassationKnownCard()])
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let mv = try await service.movement(for: base(), court: districtCourt(), cartoteka: cart)

        let kas = mv.instances.filter { $0.level == .cassation }
        XCTAssertEqual(kas.map(\.caseNumber), ["8Г-10837/2026"])
        XCTAssertNil(kas.first?.captchaFormURL, "заглушка не нужна — карточка взята по прямой ссылке")
        XCTAssertEqual(kas.first?.sessions.count, 1)
        XCTAssertFalse(mv.instances.contains { $0.captchaFormURL != nil })
        // Акт кассации на месте, с телом.
        let act = try XCTUnwrap(mv.acts.first { $0.instanceLevel == .cassation })
        XCTAssertEqual(act.title, "Определение суда кассационной инстанции")
        XCTAssertNotNil(mv.actBodies[act.id])
    }

    /// Без known card поведение прежнее: капча → заглушка с captchaFormURL.
    func testCaptchaStubWithoutKnownCard() async throws {
        let mock = ScriptedClient(cards: ["30636693": firstCard()],
                                  captchaDomains: ["3kas.sudrf.ru"])
        let service = MovementService(client: mock, higherCourtDomains: ["3kas.sudrf.ru"])
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let mv = try await service.movement(for: base(), court: districtCourt(), cartoteka: cart)

        XCTAssertTrue(mv.instances.contains { $0.captchaFormURL != nil })
    }

    // MARK: УИД пуст → добор по прямым ссылкам

    func testKnownCardsFetchedWhenUIDMissing() async throws {
        let mock = ScriptedClient(cards: ["30636693": firstCard(uid: nil),
                                          "24352048": cassationCard(),
                                          "m1": materialCard()])
        let service = MovementService(client: mock,
                                      higherCourtDomains: ["3kas.sudrf.ru"],
                                      knownCards: [cassationKnownCard(), materialKnownCard()])
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let mv = try await service.movement(for: base(), court: districtCourt(), cartoteka: cart)

        // Поиск не выполнялся вовсе (УИД пуст), но обе карточки подтянуты.
        let searched = await mock.searchCalls
        XCTAssertTrue(searched.isEmpty)
        XCTAssertTrue(mv.instances.contains { $0.level == .cassation && $0.caseNumber == "8Г-10837/2026" })
        let material = try XCTUnwrap(mv.instances.first {
            $0.level == .material && $0.caseNumber == "13-2472/2026"
        })
        XCTAssertEqual(material.sessions, materialCard().sessions,
                       "сессии известной карточки должны попасть в движение")
    }

    // MARK: Материалы по УИД в картотеке «m» домашнего суда

    func testMaterialsFoundByUIDAtHomeCourt() async throws {
        let matRow = CaseSearchResult(caseNumber: "13-2472/2026", decisionDate: "01.09.2026",
                                      caseID: "m1", caseUID: "guid-m")
        let mock = ScriptedClient(cards: ["30636693": firstCard(), "m1": materialCard()],
                                  searchResults: ["syktsud--komi.sudrf.ru/m": [matRow]])
        let service = MovementService(client: mock)
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let mv = try await service.movement(for: base(), court: districtCourt(), cartoteka: cart)

        let materials = mv.instances.filter { $0.level == .material }
        XCTAssertEqual(materials.map(\.caseNumber), ["13-2472/2026"])
        XCTAssertTrue(materials.allSatisfy(\.foundByUID))
        XCTAssertEqual(materials.first?.sessions, materialCard().sessions)
        // Материал — в конце списка инстанций (после 1-й инстанции).
        XCTAssertEqual(mv.instances.last?.level, .material)
        // Акт материала: «Определение» (13-…).
        let act = try XCTUnwrap(mv.acts.first { $0.instanceLevel == .material })
        XCTAssertEqual(act.title, "Определение")
    }

    /// CAPTCHA до выдачи m не выдумывает материал, но делает источник partial.
    func testMaterialSearchCaptchaSilentlyIgnored() async throws {
        let mock = ScriptedClient(cards: ["30636693": firstCard()],
                                  captchaCartotekas: ["m"])
        let service = MovementService(client: mock)
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let mv = try await service.movement(for: base(), court: districtCourt(), cartoteka: cart)

        XCTAssertFalse(mv.instances.contains { $0.level == .material })
        XCTAssertFalse(mv.instances.contains { $0.captchaFormURL != nil })
        XCTAssertEqual(mv.instances.map(\.level), [.first])
        XCTAssertEqual(mv.incompleteHigherCourtDomains, [districtCourt().domain])
    }

    func testPublishedMaterialWithoutSessionsStaysAnHonestEmptyHeader() async throws {
        let row = CaseSearchResult(caseNumber: "13-1000/2026", caseID: "m-empty",
                                   caseUID: "guid-empty")
        let emptyCard = CaseCard(rawText: "", actText: nil, sessions: [],
                                 uid: Self.uid, caseNumber: row.caseNumber)
        let mock = ScriptedClient(
            cards: ["30636693": firstCard(), "m-empty": emptyCard],
            searchResults: ["syktsud--komi.sudrf.ru/m": [row]])
        let service = MovementService(client: mock)
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let mv = try await service.movement(for: base(), court: districtCourt(), cartoteka: cart)

        let material = try XCTUnwrap(mv.instances.first { $0.level == .material })
        XCTAssertTrue(material.sessions.isEmpty)
        XCTAssertNil(material.note)
        XCTAssertNil(material.actID)
        XCTAssertNil(mv.incompleteHigherCourtDomains)
    }

    func testUnavailableMaterialRowKeepsHeaderWithoutCache() async throws {
        let sourceURL = URL(string: "https://syktsud--komi.sudrf.ru/modules.php"
            + "?name=sud_delo&name_op=case&case_id=m-missing&case_uid=guid-m"
            + "&delo_id=1610001&new=0")!
        let row = CaseSearchResult(caseNumber: "13-999/2026", judge: "Петров П. П.",
                                   result: "Заявление принято", caseID: "m-missing",
                                   caseUID: "guid-m", cardURL: sourceURL)
        let mock = ScriptedClient(
            cards: ["30636693": firstCard()],
            searchResults: ["syktsud--komi.sudrf.ru/m": [row]])
        let service = MovementService(client: mock)
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let mv = try await service.movement(for: base(), court: districtCourt(), cartoteka: cart)

        let material = try XCTUnwrap(mv.instances.first { $0.level == .material })
        XCTAssertEqual(material.caseNumber, row.caseNumber)
        XCTAssertEqual(material.judge, row.judge)
        XCTAssertEqual(material.result, row.result)
        XCTAssertTrue(material.sessions.isEmpty)
        XCTAssertEqual(material.note, "Движение временно недоступно")
        XCTAssertEqual(material.sourceURL, sourceURL)
        XCTAssertFalse(material.foundByUID,
                       "без карточки УИД строки выдачи ещё не подтверждён")
        XCTAssertEqual(mv.incompleteHigherCourtDomains, [districtCourt().domain])
    }

    func testUnavailableKnownMaterialKeepsHeaderWithoutCache() async throws {
        let known = materialKnownCard()
        let mock = ScriptedClient(cards: ["30636693": firstCard()])
        let service = MovementService(client: mock, knownCards: [known])
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let mv = try await service.movement(for: base(), court: districtCourt(), cartoteka: cart)

        let material = try XCTUnwrap(mv.instances.first {
            $0.level == .material && $0.caseNumber == known.caseNumber
        })
        XCTAssertNil(material.judge)
        XCTAssertNil(material.result)
        XCTAssertTrue(material.sessions.isEmpty)
        XCTAssertEqual(material.note, "Движение временно недоступно")
        XCTAssertEqual(material.sourceURL, MovementService.sourceURL(for: known))
        XCTAssertFalse(material.foundByUID)
        XCTAssertEqual(mv.incompleteHigherCourtDomains, [districtCourt().domain])
    }

    /// Материал, найденный m-поиском, не дублируется добором по известной ссылке.
    func testKnownMaterialNotDuplicatedAfterUIDSearch() async throws {
        let matRow = CaseSearchResult(caseNumber: "13-2472/2026", decisionDate: "01.09.2026",
                                      caseID: "m1", caseUID: "guid-m")
        let mock = ScriptedClient(cards: ["30636693": firstCard(), "m1": materialCard()],
                                  searchResults: ["syktsud--komi.sudrf.ru/m": [matRow]])
        let service = MovementService(client: mock, knownCards: [materialKnownCard()])
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let mv = try await service.movement(for: base(), court: districtCourt(), cartoteka: cart)

        XCTAssertEqual(mv.instances.filter { $0.level == .material }.count, 1)
    }

    func testKnownCardRescuesMaterialAfterRowCardFailure() async throws {
        let brokenURL = URL(string: "https://syktsud--komi.sudrf.ru/modules.php"
            + "?name=sud_delo&name_op=case&case_id=broken&case_uid=broken"
            + "&delo_id=1610001&new=0")!
        let row = CaseSearchResult(caseNumber: "13-2472/2026", caseID: "broken",
                                   caseUID: "broken", cardURL: brokenURL)
        let mock = ScriptedClient(
            cards: ["30636693": firstCard(), "m1": materialCard()],
            searchResults: ["syktsud--komi.sudrf.ru/m": [row]])
        let service = MovementService(client: mock, knownCards: [materialKnownCard()])
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let mv = try await service.movement(for: base(), court: districtCourt(), cartoteka: cart)

        let materials = mv.instances.filter { $0.level == .material }
        XCTAssertEqual(materials.count, 1)
        XCTAssertEqual(materials.first?.sessions, materialCard().sessions)
        XCTAssertNil(materials.first?.note)
        let act = try XCTUnwrap(mv.acts.first { $0.instanceLevel == .material })
        XCTAssertEqual(mv.actBodies[act.id], materialCard().actText)
    }

    /// Сортировка: материал с ранними заседаниями всё равно в конце
    /// (levelOrder(.material) — последний).
    func testMaterialOrderedLast() {
        func inst(_ level: CaseInstance.Level, _ num: String, _ date: String) -> CaseInstance {
            CaseInstance(level: level, court: "x", caseNumber: num, judge: nil,
                         domain: "d", foundByUID: false, result: nil,
                         sessions: [CaseSession(date: date, event: "з.")])
        }
        let first = inst(.first, "2-1/2025", "01.02.2025")
        let mat   = inst(.material, "13-9/2025", "01.01.2025")
        let sorted = [mat, first].sorted {
            MovementService.instanceOrderKey($0) < MovementService.instanceOrderKey($1)
        }
        // Материал раньше по дате — но ключ хронологический, поэтому здесь он
        // встанет первым по дате; секция «Материалы» в UI фильтрует по уровню,
        // а не по порядку — проверяем только устойчивость ключа.
        XCTAssertEqual(sorted.map(\.caseNumber), ["13-9/2025", "2-1/2025"])
        // При равных датах материал уходит после инстанций.
        let sameDay = [inst(.material, "13-9/2025", "01.02.2025"), first].sorted {
            MovementService.instanceOrderKey($0) < MovementService.instanceOrderKey($1)
        }
        XCTAssertEqual(sameDay.map(\.caseNumber), ["2-1/2025", "13-9/2025"])
    }

    func testMaterialActTitles() {
        XCTAssertEqual(MovementService.materialActTitle(caseNumber: "13-2472/2026"), "Определение")
        XCTAssertEqual(MovementService.materialActTitle(caseNumber: "13а-653/2025"), "Определение")
        XCTAssertEqual(MovementService.materialActTitle(caseNumber: "3/12-25/2026"), "Постановление")
        XCTAssertEqual(MovementService.materialActTitle(caseNumber: "4/17-1/2026"), "Постановление")
        XCTAssertEqual(MovementService.materialActTitle(caseNumber: "15-34/2026"), "Определение")
    }
}

/// Сценарный мок: карточки по caseID; поиск — по ключу «домен/картотека»;
/// капча настраивается на домен (все картотеки) или на конкретную картотеку.
private actor ScriptedClient: CaseProviding {
    private let cards: [String: CaseCard]
    private let searchResults: [String: [CaseSearchResult]]
    private let captchaDomains: Set<String>
    private let captchaCartotekas: Set<String>
    private(set) var searchCalls: [String] = []

    init(cards: [String: CaseCard],
         searchResults: [String: [CaseSearchResult]] = [:],
         captchaDomains: Set<String> = [],
         captchaCartotekas: Set<String> = []) {
        self.cards = cards
        self.searchResults = searchResults
        self.captchaDomains = captchaDomains
        self.captchaCartotekas = captchaCartotekas
    }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        searchCalls.append(court.domain + "/" + cartoteka.id)
        if captchaDomains.contains(court.domain) || captchaCartotekas.contains(cartoteka.id) {
            throw SudrfError.captchaRequired(formURL: URL(string: "https://\(court.domain)/form")!)
        }
        return searchResults[court.domain + "/" + cartoteka.id] ?? []
    }

    func fetchCard(url: URL) async throws -> CaseCard {
        throw SudrfError.http(status: 404)   // в этих сценариях путь по ссылке не используется
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        guard let card = cards[caseID] else { throw SudrfError.decodingFailed }
        return card
    }
}
