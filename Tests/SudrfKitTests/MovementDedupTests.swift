import XCTest
@testable import SudrfKit

/// Дедупликация инстанций/актов/captcha-stub по каноническому `SudrfHost.moduleHost`
/// (FIXPLAN A14). Покрывает 4 сценария H1 из ревью №2:
///
///   1) success-path: обе формы вышестоящего суда (dash+dot) возвращают один
///      и тот же круг апелляции — без dedup появляются две инстанции и два акта;
///   2) captcha-stub: обе формы под капчей — без dedup две заглушки на одном
///      moduleHost;
///   3) captcha + known card: `KnownCard` спасает оба target-а, и без dedup каждый
///      target добавит инстанцию по `instanceFromKnownCard`;
///   4) replacingCaptchaStub: ручное решение капчи снимает ВСЕ legacy-stub на
///      одном `moduleHost` (dash и dot), а не только совпавший по сырому домену.
///
/// Также покрывает защиту v2-регрессии: два `KnownCard` одного `moduleHost` с
/// разными номерами дел сохраняют оба круга (проверка №5).
final class MovementDedupTests: XCTestCase {

    // MARK: - Test fixtures

    private static let uid = "11RS0001-01-2025-011255-03"
    private static let homeDomain = "syktsud--komi.sudrf.ru"
    private static let appealDashDomain = "oblsud--mo.sudrf.ru"
    private static let appealDotDomain  = "oblsud.mo.sudrf.ru"
    private static let appealTitle = "Московский областной суд"

    private func districtCourt() -> Court {
        Court(domain: Self.homeDomain,
              title: "Сыктывкарский городской суд", level: .district)
    }

    /// `cart` — базовая картотека 1-й инстанции (district, g1), чтобы
    /// `higherCartotekaIDs(baseID: "g1", level: .subject) = ["g2"]` (L801
    /// Movement.swift) дала непустой `toTry` для subject-таргета.
    private func baseCart() throws -> Cartoteka {
        try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
    }

    private func appealDashTarget() -> MovementSearchTarget {
        MovementSearchTarget(domain: Self.appealDashDomain,
                            courtTitle: Self.appealTitle,
                            courtLevel: .subject,
                            instanceLevel: .appeal,
                            dateRule: .always)
    }

    private func appealDotTarget() -> MovementSearchTarget {
        MovementSearchTarget(domain: Self.appealDotDomain,
                            courtTitle: Self.appealTitle,
                            courtLevel: .subject,
                            instanceLevel: .appeal,
                            dateRule: .always)
    }

    private func base() -> CaseSearchResult {
        // caseID/caseUID — обязательны непустые, иначе `fetchCard(row:...)` бросит
        // `SudrfError.parsing` ещё до чтения `baseCard.uid` (L294 Movement.swift).
        CaseSearchResult(caseNumber: "2-7212/2025",
                         caseID: "base-1",
                         caseUID: "base-uid-1")
    }

    private func firstCard() -> CaseCard {
        // `uid` обязательно непустой: `guard let uid` (L397 Movement.swift) иначе
        // прерывает цикл `for target in higherCourtTargets` и вышестоящие не собираются.
        CaseCard(rawText: "", actText: "РЕШЕНИЕ\nиск удовлетворить.",
                 judge: "Судья А.", result: "Иск удовлетворён",
                 uid: Self.uid, caseNumber: "2-7212/2025", decisionDate: "18.08.2025")
    }

    private func appealRow(id: String, caseNumber: String) -> CaseSearchResult {
        // `result` с «оставлено без изменения» — НЕ частная жалоба, идёт как
        // круг апелляции по `isPrivateComplaintByResult` (L657 Movement.swift).
        CaseSearchResult(caseNumber: caseNumber, decisionDate: "15.09.2025",
                         result: "решение оставлено без изменения",
                         caseID: id, caseUID: "uid-\(id)")
    }

    private func appealCard(id: String, caseNumber: String) -> CaseCard {
        CaseCard(rawText: "",
                 actText: "АПЕЛЛЯЦИОННОЕ ОПРЕДЕЛЕНИЕ\nрешение оставлено без изменения.",
                 result: "РЕШЕНИЕ оставлено без изменения",
                 caseNumber: caseNumber)
    }

    private func knownCardDash(id: String, caseNumber: String) -> KnownCard {
        // `KnownCard.domain` — модульная (dash) форма (контракт L169 Movement.swift).
        KnownCard(domain: Self.appealDashDomain,
                  courtTitle: Self.appealTitle,
                  caseID: id, caseUID: "kc-uid-\(id)",
                  deloID: "4", new: "4",
                  caseNumber: caseNumber,
                  levelRaw: CaseInstance.Level.appeal.rawValue,
                  cartotekaID: "u2")
    }

    // MARK: - Mock

    /// Управляемый мок: на `search` возвращает `appealRows[domain]` или
    /// бросает `.captchaRequired`, если домен в `captchaDomains`. `fetchCard`
    /// по `caseID` ищет в `appealCards`, для `baseID` отдаёт `firstCard`.
    private actor MovementMock: CaseProviding {
        let baseID: String
        let firstCard: CaseCard
        let appealRows: [String: [CaseSearchResult]]
        let appealCards: [String: CaseCard]
        let captchaDomains: Set<String>

        init(baseID: String, firstCard: CaseCard,
             appealRows: [String: [CaseSearchResult]],
             appealCards: [String: CaseCard],
             captchaDomains: Set<String> = []) {
            self.baseID = baseID
            self.firstCard = firstCard
            self.appealRows = appealRows
            self.appealCards = appealCards
            self.captchaDomains = captchaDomains
        }

        func search(court: Court, cartoteka: Cartoteka,
                    field: SearchField, value: String) async throws -> [CaseSearchResult] {
            if captchaDomains.contains(court.domain) {
                throw SudrfError.captchaRequired(
                    formURL: URL(string: "https://\(court.domain)/form")!)
            }
            return appealRows[court.domain] ?? []
        }

        func fetchCard(url: URL) async throws -> CaseCard {
            throw SudrfError.http(status: 404)
        }

        func fetchCard(court: Court, caseID: String, caseUID: String,
                       deloID: String, new: String) async throws -> CaseCard {
            if caseID == baseID { return firstCard }
            guard let c = appealCards[caseID] else {
                throw SudrfError.decodingFailed
            }
            return c
        }
    }

    // MARK: - Tests

    /// (1) Success-path: оба target-а успешно возвращают один и тот же круг
    /// апелляции — после dedup ровно одна инстанция и один акт.
    func testMovementDedupesAppealsAndActsByModuleHost() async throws {
        let mock = MovementMock(
            baseID: "base-1", firstCard: firstCard(),
            appealRows: [
                Self.appealDashDomain: [appealRow(id: "a-dash", caseNumber: "2-9999/2024")],
                Self.appealDotDomain:  [appealRow(id: "a-dot",  caseNumber: "2-9999/2024")],
            ],
            appealCards: [
                "a-dash": appealCard(id: "a-dash", caseNumber: "2-9999/2024"),
                "a-dot":  appealCard(id: "a-dot",  caseNumber: "2-9999/2024"),
            ])
        let service = MovementService(
            client: mock,
            higherCourtTargets: [appealDashTarget(), appealDotTarget()])
        let cart = try baseCart()

        let movement = try await service.movement(for: base(), court: districtCourt(),
                                                  cartoteka: cart)

        let appeals = movement.instances.filter { $0.level == .appeal }
        XCTAssertEqual(appeals.count, 1,
                       "dash+dot формы одного суда должны схлопнуться в одну апелляцию")
        XCTAssertEqual(appeals[0].domain, Self.appealDashDomain,
                       "первый target из списка выигрывает (порядок stable)")
        XCTAssertEqual(appeals[0].caseNumber, "2-9999/2024")
        XCTAssertNotNil(appeals[0].actID)

        let appealActs = movement.acts.filter { $0.instanceLevel == .appeal }
        XCTAssertEqual(appealActs.count, 1, "акт не должен дублироваться от dot-формы")
        XCTAssertEqual(appealActs[0].id, appeals[0].actID)
        XCTAssertEqual(appealActs[0].id, "act_oblsud--mo.sudrf.ru#2-9999/2024")
    }

    /// (2) Captcha-stub-path: оба target-а под капчей, no knownCards — одна
    /// заглушка вместо двух.
    func testMovementCaptchaStubDedupesByModuleHost() async throws {
        let mock = MovementMock(
            baseID: "base-1", firstCard: firstCard(),
            appealRows: [:],
            appealCards: [:],
            captchaDomains: [Self.appealDashDomain, Self.appealDotDomain])
        let service = MovementService(
            client: mock,
            higherCourtTargets: [appealDashTarget(), appealDotTarget()])
        let cart = try baseCart()

        let movement = try await service.movement(for: base(), court: districtCourt(),
                                                  cartoteka: cart)

        let captchaStubs = movement.instances.filter { $0.captchaFormURL != nil }
        XCTAssertEqual(captchaStubs.count, 1,
                       "dash+dot формы одного суда под капчей → одна заглушка")
        XCTAssertEqual(captchaStubs[0].domain, Self.appealDashDomain)
        XCTAssertEqual(captchaStubs[0].caseNumber, "—")
        XCTAssertEqual(captchaStubs[0].level, .appeal)

        let appeals = movement.instances.filter { $0.level == .appeal }
        XCTAssertEqual(appeals.count, 1)
    }

    /// (3) Captcha + known card: один `KnownCard` в dash-форме спасает оба
    /// target-а — без dedup dot-target продублировал бы инстанцию.
    func testMovementCaptchaWithKnownCardRescuesOnce() async throws {
        let kc = knownCardDash(id: "kc-1", caseNumber: "2-9999/2024")
        let mock = MovementMock(
            baseID: "base-1", firstCard: firstCard(),
            appealRows: [:],
            appealCards: [
                "kc-1": appealCard(id: "kc-1", caseNumber: "2-9999/2024"),
            ],
            captchaDomains: [Self.appealDashDomain, Self.appealDotDomain])
        let service = MovementService(
            client: mock,
            higherCourtTargets: [appealDashTarget(), appealDotTarget()],
            knownCards: [kc])
        let cart = try baseCart()

        let movement = try await service.movement(for: base(), court: districtCourt(),
                                                  cartoteka: cart)

        let appeals = movement.instances.filter { $0.level == .appeal }
        XCTAssertEqual(appeals.count, 1, "известная карточка спасает ровно один раз")
        XCTAssertEqual(appeals[0].domain, Self.appealDashDomain,
                       "домен инстанции — от kc.domain (контракт KnownCard, dash)")
        XCTAssertEqual(appeals[0].caseNumber, "2-9999/2024")
        XCTAssertNotNil(appeals[0].actID)
        XCTAssertNil(appeals[0].captchaFormURL, "заглушки нет — спаслись по прямой ссылке")

        let captchaStubs = movement.instances.filter { $0.captchaFormURL != nil }
        XCTAssertTrue(captchaStubs.isEmpty)

        let appealActs = movement.acts.filter { $0.instanceLevel == .appeal }
        XCTAssertEqual(appealActs.count, 1, "один акт на одну спасенную инстанцию")
    }

    /// (4) `replacingCaptchaStub` снимает ОБА legacy-stub на одном `moduleHost`
    /// (dash и dot), а не только совпавший по сырому домену.
    func testReplacingCaptchaStubDropsBothLegacyStubsByModuleHost() {
        let legitimateActID = "act_oblsud--mo.sudrf.ru#1-1111/2023"
        let baseInst = CaseInstance(level: .first, court: "Сыктывкарский горсуд",
                                    caseNumber: "2-7212/2025", judge: nil,
                                    domain: Self.homeDomain, foundByUID: true,
                                    result: "Иск удовлетворён", sessions: [],
                                    actID: nil)
        let legitimateInst = CaseInstance(level: .appeal, court: Self.appealTitle,
                                          caseNumber: "1-1111/2023", judge: "Судья Б.",
                                          domain: Self.appealDashDomain,
                                          foundByUID: true,
                                          result: "решение оставлено без изменения",
                                          sessions: [], actID: legitimateActID)
        let stubDash = CaseInstance(level: .appeal, court: Self.appealTitle,
                                    caseNumber: "—", judge: nil,
                                    domain: Self.appealDashDomain,
                                    foundByUID: false, result: nil, sessions: [],
                                    actID: nil,
                                    captchaFormURL: URL(string: "https://\(Self.appealDashDomain)/form")!)
        let stubDot = CaseInstance(level: .appeal, court: Self.appealTitle,
                                   caseNumber: "—", judge: nil,
                                   domain: Self.appealDotDomain,
                                   foundByUID: false, result: nil, sessions: [],
                                   actID: nil,
                                   captchaFormURL: URL(string: "https://\(Self.appealDotDomain)/form")!)

        let legitimateAct = CaseAct(id: legitimateActID,
                                    title: "Постановление апелляции",
                                    date: "15.06.2023",
                                    courtShort: "Мособлсуд",
                                    instanceLevel: .appeal)
        let baseMovement = CaseMovement(
            uid: Self.uid, caseNumber: "2-7212/2025", inForce: false,
            instances: [baseInst, legitimateInst, stubDash, stubDot],
            complaints: [:],
            acts: [legitimateAct],
            actBodies: [legitimateActID: "Текст апелляции (legacy)."])

        let newCard = CaseCard(
            rawText: "", actText: nil,
            caseNumber: "2-2222/2024",
            receiptDate: "01.07.2024",
            acts: [CaseActText(id: "doc1", kind: "Постановление",
                               label: "Судебный акт #1 (Постановление)",
                               body: "Новое постановление после ручного решения капчи.")])
        let out = baseMovement.replacingCaptchaStub(
            domain: Self.appealDashDomain,
            courtTitle: Self.appealTitle,
            level: .appeal,
            card: newCard)

        let captchaStubs = out.instances.filter { $0.captchaFormURL != nil }
        XCTAssertTrue(captchaStubs.isEmpty,
                      "оба legacy-stub (dash и dot) должны быть сняты")

        let newInst = out.instances.first(where: {
            $0.domain == Self.appealDashDomain && $0.caseNumber == "2-2222/2024"
        })
        XCTAssertNotNil(newInst, "новая инстанция в dash-форме на месте")
        XCTAssertEqual(newInst?.level, .appeal)
        XCTAssertNotNil(newInst?.actID)

        XCTAssertNotNil(out.instances.first(where: { $0.caseNumber == "1-1111/2023" }),
                       "легитимная инстанция сохранена")

        let appealActs = out.acts.filter { $0.instanceLevel == CaseInstance.Level.appeal }
        XCTAssertEqual(appealActs.count, 2,
                       "1 легитимный акт + 1 новый акт от replacingCaptchaStub")
        XCTAssertNotNil(out.actBodies[legitimateActID],
                        "тело легитимного акта сохранено")
        let newActID = appealActs.first(where: { $0.id != legitimateActID })?.id
        XCTAssertNotNil(newActID)
        XCTAssertNotNil(out.actBodies[newActID!],
                        "тело нового акта добавлено")
    }

    /// (5) Защита v2-регрессии: два `KnownCard` одного `moduleHost` с разными
    /// номерами дел — оба спасаются, оба дают по инстанции и акту. v2-вариант
    /// с предварительной проверкой «`moduleHost` only» потерял бы второй круг.
    func testMovementKnownCardMultipleRoundsSameModuleHost() async throws {
        let kc1 = knownCardDash(id: "kc-1", caseNumber: "1-1111/2023")
        let kc2 = knownCardDash(id: "kc-2", caseNumber: "2-2222/2024")
        let mock = MovementMock(
            baseID: "base-1", firstCard: firstCard(),
            appealRows: [:],
            appealCards: [
                "kc-1": appealCard(id: "kc-1", caseNumber: "1-1111/2023"),
                "kc-2": appealCard(id: "kc-2", caseNumber: "2-2222/2024"),
            ],
            captchaDomains: [Self.appealDashDomain, Self.appealDotDomain])
        let service = MovementService(
            client: mock,
            higherCourtTargets: [appealDashTarget(), appealDotTarget()],
            knownCards: [kc1, kc2])
        let cart = try baseCart()

        let movement = try await service.movement(for: base(), court: districtCourt(),
                                                  cartoteka: cart)

        let appeals = movement.instances.filter { $0.level == .appeal }
        XCTAssertEqual(appeals.count, 2,
                       "два KnownCard одного moduleHost с разными caseNumber → два круга")
        XCTAssertEqual(Set(appeals.map(\.caseNumber)), ["1-1111/2023", "2-2222/2024"])
        XCTAssertTrue(appeals.allSatisfy { $0.domain == Self.appealDashDomain },
                      "домен инстанций — dash-форма из KnownCard")
        XCTAssertTrue(appeals.allSatisfy { $0.actID != nil })

        let captchaStubs = movement.instances.filter { $0.captchaFormURL != nil }
        XCTAssertTrue(captchaStubs.isEmpty, "оба спасены, заглушка не нужна")

        let appealActs = movement.acts.filter { $0.instanceLevel == .appeal }
        XCTAssertEqual(appealActs.count, 2, "по акту на каждый спасенный круг")
    }
}
