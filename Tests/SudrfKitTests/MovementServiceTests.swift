import XCTest
@testable import SudrfKit

/// Регрессии сервиса движения:
/// 1) вышестоящие инстанции ищутся по УИД из карточки 1-й инстанции
///    (вида 11RS0001-01-2025-011255-03), а НЕ по внутреннему GUID ссылки на
///    карточку (параметр `case_uid=…`) — он у каждого суда свой и УИДом не является;
/// 2) если по УИД апелляция вернула несколько записей — показываются ВСЕ круги;
/// 3) частные жалобы под тем же УИД кругом апелляции не считаются и отсеиваются.
final class MovementServiceTests: XCTestCase {

    /// GUID из href строки выдачи СГС — раньше ошибочно уходил в поиск как «УИД».
    private static let linkGUID = "0cec7ea2-1eae-47eb-988b-5df03f4f190c"
    private static let uid = "11RS0001-01-2025-011255-03"

    private func fixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("Фикстура \(name).html не найдена в бандле теста")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func districtCourt() -> Court {
        Court(domain: "syktsud--komi.sudrf.ru",
              title: "Сыктывкарский городской суд", level: .district)
    }

    private func base() -> CaseSearchResult {
        CaseSearchResult(caseNumber: "2-7212/2025 ~ М-5922/2025",
                         caseID: "30636693", caseUID: Self.linkGUID)
    }

    func testHigherInstancesSearchedByCardUIDNotLinkGUID() async throws {
        let firstCard = try CaseCardParser.parse(html: try fixture("sgs_1inst"))
        let appealCard = try CaseCardParser.parse(html: try fixture("vsrk_appeal"))
        let appealRow = CaseSearchResult(caseNumber: "33-4818/2025", caseID: "40133205",
                                         caseUID: "2aa596f3-44c4-4fab-adad-cd2ad3318db4")
        let mock = MockClient(firstCardID: "30636693", firstCard: firstCard,
                              higherResults: [appealRow],
                              higherCards: ["40133205": appealCard])
        let service = MovementService(client: mock,
                                      higherCourtDomains: ["vs--komi.sudrf.ru"])
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let movement = try await service.movement(for: base(), court: districtCourt(),
                                                  cartoteka: cart)

        let searched = await mock.searchedValues
        // Теперь по УИД опрашивается и домашний суд (другие круги), и вышестоящий —
        // важно лишь, что ВЕЗДЕ уходит УИД карточки, а GUID ссылки не уходит никогда.
        XCTAssertFalse(searched.isEmpty)
        XCTAssertTrue(searched.allSatisfy { $0 == Self.uid })
        XCTAssertFalse(searched.contains(Self.linkGUID))
        XCTAssertEqual(movement.uid, Self.uid)
        XCTAssertTrue(movement.instances.contains { $0.level == .appeal && $0.foundByUID })
    }

    /// Два круга апелляции (исходный + новый после возврата из кассации) — оба видны,
    /// в хронологическом порядке, с РАЗНЫМИ actID (акты не схлопываются в один).
    func testBothAppealRoundsShown() async throws {
        let firstCard = try CaseCardParser.parse(html: try fixture("sgs_1inst"))

        // Круг 1 (старше): решение отменено, дело — на новое рассмотрение.
        let round1Row = CaseSearchResult(
            caseNumber: "33-4818/2025", decisionDate: "15.09.2025",
            result: "решение отменено, направлено на новое рассмотрение",
            caseID: "40133205", caseUID: "2aa596f3-44c4-4fab-adad-cd2ad3318db4")
        let round1Card = CaseCard(
            rawText: "", actText: "АПЕЛЛЯЦИОННОЕ ОПРЕДЕЛЕНИЕ\nрешение отменено, дело направлено на новое рассмотрение.",
            result: "РЕШЕНИЕ отменено, направлено на новое рассмотрение", caseNumber: "33-4818/2025")

        // Круг 2 (новее, после нового рассмотрения и второй апелляции).
        let round2Row = CaseSearchResult(
            caseNumber: "33-2266/2026", decisionDate: "20.03.2026",
            result: "решение оставлено без изменения",
            caseID: "40299999", caseUID: "bb112233-0000-4444-8888-cccccccccccc")
        let round2Card = CaseCard(
            rawText: "", actText: "АПЕЛЛЯЦИОННОЕ ОПРЕДЕЛЕНИЕ\nрешение оставлено без изменения, жалоба — без удовлетворения.",
            result: "РЕШЕНИЕ оставлено без изменения", caseNumber: "33-2266/2026")

        let mock = MockClient(firstCardID: "30636693", firstCard: firstCard,
                              higherResults: [round2Row, round1Row],   // нарочно «новый раньше»
                              higherCards: ["40133205": round1Card, "40299999": round2Card])
        let service = MovementService(client: mock,
                                      higherCourtDomains: ["vs--komi.sudrf.ru"])
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let mv = try await service.movement(for: base(), court: districtCourt(), cartoteka: cart)

        let appeals = mv.instances.filter { $0.level == .appeal }
        XCTAssertEqual(appeals.count, 2, "должны показаться ОБА круга апелляции")
        // Хронология: старый круг (2025) раньше нового (2026), несмотря на порядок выдачи.
        XCTAssertEqual(appeals.map(\.caseNumber), ["33-4818/2025", "33-2266/2026"])

        // Акты обоих кругов — разные id, оба тела на месте (не схлопнулись).
        let appealActs = mv.acts.filter { $0.instanceLevel == .appeal }
        XCTAssertEqual(appealActs.count, 2)
        XCTAssertEqual(Set(appealActs.map(\.id)).count, 2, "actID кругов должны различаться")
        for a in appealActs {
            XCTAssertNotNil(mv.actBodies[a.id], "тело акта \(a.id) потеряно")
        }
    }

    /// Кассация должна стоять МЕЖДУ кругами апелляции по хронологии (дело
    /// 2-7212/2025): 1-я → круг1 (сент-окт 2025) → кассация (02.03.2026, отмена
    /// определения 1-го круга) → круг2 (апр-май 2026). Раньше сортировка по уровню
    /// гнала кассацию в конец.
    func testCassationOrderedBetweenAppealRoundsByDate() {
        func inst(_ level: CaseInstance.Level, _ num: String, _ dates: [String]) -> CaseInstance {
            CaseInstance(level: level, court: "x", caseNumber: num, judge: nil,
                         domain: "d", foundByUID: true, result: nil,
                         sessions: dates.map { CaseSession(date: $0, event: "Судебное заседание") })
        }
        let first  = inst(.first,     "2-7212/2025",  ["22.07.2025", "18.08.2025"])
        let round1 = inst(.appeal,    "33-4818/2025", ["25.09.2025", "07.10.2025"])
        let round2 = inst(.appeal,    "33-2266/2026", ["01.04.2026", "07.05.2026"])
        let cass   = inst(.cassation, "8Г-2430/2026", ["02.03.2026"])

        let sorted = [cass, round2, first, round1]
            .sorted { MovementService.instanceOrderKey($0) < MovementService.instanceOrderKey($1) }
        XCTAssertEqual(sorted.map(\.caseNumber),
                       ["2-7212/2025", "33-4818/2025", "8Г-2430/2026", "33-2266/2026"])
    }

    /// Частная жалоба под тем же УИД кругом апелляции не считается — в инстанциях
    /// остаётся только полноценный круг.
    func testPrivateComplaintNotShownAsRound() async throws {
        let firstCard = try CaseCardParser.parse(html: try fixture("sgs_1inst"))

        let appealRow = CaseSearchResult(
            caseNumber: "33-4818/2025", decisionDate: "15.09.2025",
            result: "РЕШЕНИЕ оставлено без изменения",
            caseID: "40133205", caseUID: "2aa596f3-44c4-4fab-adad-cd2ad3318db4")
        let appealCard = CaseCard(
            rawText: "", actText: "АПЕЛЛЯЦИОННОЕ ОПРЕДЕЛЕНИЕ\nрешение оставлено без изменения.",
            result: "РЕШЕНИЕ оставлено без изменения", caseNumber: "33-4818/2025")

        // Частная жалоба на определение — тот же УИД, но не круг апелляции.
        // Важно: «Категория дела» у неё — обычное существо спора (не «частная
        // жалоба»), различитель — «ОПРЕДЕЛЕНИЕ …» в результате рассмотрения.
        let chzhRow = CaseSearchResult(
            caseNumber: "33-1102/2025", decisionDate: "02.04.2025",
            result: "ОПРЕДЕЛЕНИЕ оставлено без изменения",
            caseID: "40100777", caseUID: "dd445566-0000-4444-8888-eeeeeeeeeeee")
        let chzhCard = CaseCard(
            rawText: "", actText: "АПЕЛЛЯЦИОННОЕ ОПРЕДЕЛЕНИЕ\nопределение оставлено без изменения.",
            result: "ОПРЕДЕЛЕНИЕ оставлено БЕЗ ИЗМЕНЕНИЯ", caseNumber: "33-1102/2025",
            category: "Споры, возникающие из трудовых отношений → Дела о восстановлении на работе")

        let mock = MockClient(firstCardID: "30636693", firstCard: firstCard,
                              higherResults: [appealRow, chzhRow],
                              higherCards: ["40133205": appealCard, "40100777": chzhCard])
        let service = MovementService(client: mock,
                                      higherCourtDomains: ["vs--komi.sudrf.ru"])
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let mv = try await service.movement(for: base(), court: districtCourt(), cartoteka: cart)

        let appeals = mv.instances.filter { $0.level == .appeal }
        XCTAssertEqual(appeals.map(\.caseNumber), ["33-4818/2025"],
                       "частная жалоба не должна показываться как круг апелляции")
    }

    /// Реальная карточка частной жалобы из ВС РК (33-4820/2025): «Категория дела» —
    /// трудовой спор, слова «частная жалоба» в карточке нет, но «Результат
    /// рассмотрения» = «ОПРЕДЕЛЕНИЕ оставлено без изменения» → распознаётся как ЧЖ.
    func testRealPrivateComplaintCardClassified() throws {
        let card = try CaseCardParser.parse(html: try fixture("vsrk_chzh"))
        XCTAssertEqual(card.uid, "11RS0001-01-2025-002795-66")
        XCTAssertEqual(card.decisionDate, "02.10.2025")
        XCTAssertEqual(card.receiptDate, "17.09.2025")
        // Фолбэк по результату: «ОПРЕДЕЛЕНИЕ …» → частная жалоба.
        XCTAssertTrue(MovementService.isPrivateComplaintByResult(
            row: CaseSearchResult(caseNumber: "33-4820/2025"), card: card))
    }

    /// Реальная карточка полного круга апелляции (33-4818/2025): «Результат
    /// рассмотрения» = «РЕШЕНИЕ оставлено без изменения» → кругом и остаётся,
    /// несмотря на то что сам акт называется «Апелляционным определением».
    func testRealAppealRoundNotClassifiedAsComplaint() throws {
        let card = try CaseCardParser.parse(html: try fixture("vsrk_appeal"))
        XCTAssertTrue((card.result ?? "").lowercased().contains("решени"))
        XCTAssertFalse(MovementService.isPrivateComplaintByResult(
            row: CaseSearchResult(caseNumber: "33-4818/2025"), card: card))
    }

    /// Реальная вкладка «Обжалование» (карточка горсуда, дело 2-3671/2025):
    /// 5 жалоб с видами и датами; парсер достаёт «Вид жалобы» и даты движения.
    func testObzhalovanieParsedFromRealCard() throws {
        let card = try CaseCardParser.parse(html: try fixture("sgs_card"))
        XCTAssertEqual(card.appeals.count, 5)
        XCTAssertEqual(card.appeals.map(\.kind),
                       [.appeal, .other, .appeal, .appeal, .privateComplaint])
        let chzh = try XCTUnwrap(card.appeals.first { $0.kind == .privateComplaint })
        XCTAssertEqual(chzh.hearingDate, "02.10.2025")
        XCTAssertEqual(chzh.sentUpDate, "17.09.2025")
        XCTAssertEqual(chzh.returnedDate, "08.10.2025")
    }

    /// Классификация по вкладке «Обжалование» (а не по результату): запись ВС
    /// сшивается с жалобой по дате и берёт её «Вид».
    func testClassificationViaObzhalovanie() throws {
        let appeals = try CaseCardParser.parse(html: try fixture("sgs_card")).appeals

        // Карточка ВС 33-4820/2025 — частная жалоба (дата рассмотрения 02.10.2025).
        let chzhCard = try CaseCardParser.parse(html: try fixture("vsrk_chzh"))
        XCTAssertFalse(MovementService.isRoundOfAppeal(
            row: CaseSearchResult(caseNumber: "33-4820/2025"), card: chzhCard, appeals: appeals),
            "частная жалоба сшивается по дате 02.10.2025 и кругом не считается")

        // Гипотетическая запись с датой апелляционного круга из той же вкладки →
        // классифицируется как круг даже при «определенческом» результате.
        let appealLike = CaseCard(rawText: "", actText: nil,
                                  result: "ОПРЕДЕЛЕНИЕ … (нерелевантно)", decisionDate: "31.10.2025")
        XCTAssertTrue(MovementService.isRoundOfAppeal(
            row: CaseSearchResult(caseNumber: "33-X/2025", receiptDate: "31.10.2025"),
            card: appealLike, appeals: appeals),
            "апелляционная жалоба из вкладки → круг, вид важнее результата")
    }

    func testMinimalMovementDoesNotShowLinkGUIDAsUID() {
        let mv = MovementService.minimalMovement(
            base: CaseSearchResult(caseNumber: "2-1/2025", caseUID: Self.linkGUID),
            court: districtCourt())
        XCTAssertEqual(mv.uid, "")   // карточка не загружалась — УИД неизвестен
    }

    // Юнит-проверки фолбэка по «Результату рассмотрения» (когда вкладка
    // «Обжалование» не сшилась): определение → ЧЖ, решение/приговор → круг.
    func testResultFallbackHeuristic() {
        let row = CaseSearchResult(caseNumber: "33-1/2025")
        func card(result: String?, category: String? = nil) -> CaseCard {
            CaseCard(rawText: "", actText: nil, result: result, category: category)
        }
        XCTAssertTrue(MovementService.isPrivateComplaintByResult(
            row: row, card: card(result: "ОПРЕДЕЛЕНИЕ оставлено БЕЗ ИЗМЕНЕНИЯ")))
        XCTAssertTrue(MovementService.isPrivateComplaintByResult(
            row: row, card: card(result: "определение отменено, вопрос направлен на новое рассмотрение")))
        XCTAssertFalse(MovementService.isPrivateComplaintByResult(
            row: row, card: card(result: "РЕШЕНИЕ оставлено БЕЗ ИЗМЕНЕНИЯ")))
        XCTAssertFalse(MovementService.isPrivateComplaintByResult(
            row: row, card: card(result: "приговор изменён")))
        XCTAssertFalse(MovementService.isPrivateComplaintByResult(row: row, card: card(result: nil)))
        XCTAssertTrue(MovementService.isPrivateComplaintByResult(
            row: CaseSearchResult(caseNumber: "33-9/2025", result: "ОПРЕДЕЛЕНИЕ оставлено без изменения"),
            card: card(result: nil)))
    }

    // «Вид жалобы (представления)» → тип.
    func testAppealKindMapping() {
        XCTAssertEqual(CaseCardParser.appealKind(from: "Частная жалоба"), .privateComplaint)
        XCTAssertEqual(CaseCardParser.appealKind(from: "Апелляционная жалоба (на не вступивший в силу судебный акт)"), .appeal)
        XCTAssertEqual(CaseCardParser.appealKind(from: "Кассационная жалоба (представление)"), .cassation)
        XCTAssertEqual(CaseCardParser.appealKind(from: "Замечание на протокол судебного заседания"), .other)
    }

    // MARK: - АП: возврат на новое рассмотрение (горсуд → ВС → горсуд)

    private static let koapUID = "11RS0001-01-2023-002356-90"

    private func koapSession(_ date: String) -> CaseSession {
        CaseSession(date: date, event: "Судебное заседание")
    }

    /// Полная КоАП-цепочка по реальному делу (УИД 11RS0001-01-2023-002356-90):
    ///   • горсуд 12-255/2023 (Печинина) — жалоба удовлетворена, возврат в прокуратуру;
    ///   • ВС 21-183/2023 (Пешкин) по протесту прокурора — решение судьи отменено;
    ///   • горсуд 12-544/2023 (Леконцев) — прокурорские акты засилены.
    /// Проверяем: подтянуты ОБА круга горсуда и ВС; порядок строго хронологический
    /// (горсуд1 → ВС → горсуд2); ВС найден по картотеке adm2 (1513001).
    func testKoAPRemandRoundsHomeCourtAndSubject() async throws {
        let firstCard = CaseCard(
            rawText: "", actText: "РЕШЕНИЕ\nжалобу удовлетворить, дело направить на новое рассмотрение.",
            sessions: [koapSession("22.02.2023"), koapSession("05.05.2023")],
            judge: "Печинина Л.А.", result: "Отменено с возвращением на новое рассмотрение",
            uid: Self.koapUID, caseNumber: "12-255/2023", decisionDate: "05.05.2023")

        let base = CaseSearchResult(caseNumber: "12-255/2023", decisionDate: "05.05.2023",
                                    caseID: "31500136", caseUID: "e212242b-0e65-41d3-8b07-e6e8c556a079")

        // Тот же горсуд: первый круг (дубль базового — должен отсеяться) и второй круг.
        let round1Row = CaseSearchResult(caseNumber: "12-255/2023", caseID: "31500136",
                                         caseUID: "e212242b-0e65-41d3-8b07-e6e8c556a079")
        let round2Row = CaseSearchResult(caseNumber: "12-544/2023", receiptDate: "14.06.2023",
                                         decisionDate: "29.06.2023", result: "Оставлено без изменения",
                                         caseID: "31501757", caseUID: "8418548b-c002-4563-a9c3-7fd17318d474")
        let round2Card = CaseCard(
            rawText: "", actText: "РЕШЕНИЕ\nпостановление и решение прокурора оставить без изменения.",
            sessions: [koapSession("14.06.2023"), koapSession("29.06.2023")],
            judge: "Леконцев А.П.", result: "Оставлено без изменения",
            uid: Self.koapUID, caseNumber: "12-544/2023", decisionDate: "29.06.2023")

        // ВС по протесту прокурора (картотека «жалобы на решения по жалобам», adm2).
        let vsRow = CaseSearchResult(caseNumber: "21-183/2023", receiptDate: "22.05.2023",
                                     decisionDate: "31.05.2023", result: "Вынесено решение по существу",
                                     caseID: "40655987", caseUID: "ca0790d0-2cbf-4491-858d-3e09466c1e3d")
        let vsCard = CaseCard(
            rawText: "", actText: "РЕШЕНИЕ\nрешение судьи горсуда отменить, дело направить на новое рассмотрение.",
            sessions: [koapSession("22.05.2023"), koapSession("31.05.2023")],
            judge: "Пешкин А.Г.", result: "Вынесено решение по существу",
            uid: Self.koapUID, caseNumber: "21-183/2023", decisionDate: "31.05.2023")

        let mock = MockClient(firstCardID: "31500136", firstCard: firstCard,
                              higherResults: [vsRow],
                              higherCards: ["40655987": vsCard, "31501757": round2Card],
                              sameCourtResults: [round1Row, round2Row],
                              expectedUID: Self.koapUID)
        let service = MovementService(client: mock,
                                      higherCourtDomains: ["vs--komi.sudrf.ru"])
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "admj"))

        let mv = try await service.movement(for: base, court: districtCourt(), cartoteka: cart)

        // Строго хронологический порядок: горсуд1 → ВС → горсуд2.
        XCTAssertEqual(mv.instances.map(\.caseNumber),
                       ["12-255/2023", "21-183/2023", "12-544/2023"])
        XCTAssertEqual(mv.instances.map(\.level), [.first, .appeal, .first])

        // Второй круг найден по УИД в том же суде (а базовый круг не продублирован).
        let firstRounds = mv.instances.filter { $0.level == .first }
        XCTAssertEqual(firstRounds.map(\.caseNumber), ["12-255/2023", "12-544/2023"])
        XCTAssertTrue(mv.instances.first { $0.caseNumber == "12-544/2023" }?.foundByUID == true)

        // ВС подтянут как круг (а не отсеян как «определенческий»).
        XCTAssertTrue(mv.instances.contains { $0.caseNumber == "21-183/2023" && $0.level == .appeal })

        // Акты — все три, в хронологии, с разными id и сохранёнными телами.
        XCTAssertEqual(mv.acts.map(\.date), ["05.05.2023", "31.05.2023", "29.06.2023"])
        XCTAssertEqual(Set(mv.acts.map(\.id)).count, mv.acts.count)
        for a in mv.acts { XCTAssertNotNil(mv.actBodies[a.id]) }
    }

    /// Картотека ВС для АП «жалобы на решения по жалобам» (adm2) зарегистрирована
    /// с верными платформенными значениями.
    func testKoAPSubjectCartotekaRegistered() throws {
        let c = try XCTUnwrap(CartotekaRegistry.find(level: .subject, id: "adm2"))
        XCTAssertEqual(c.deloID, "1513001")
        XCTAssertEqual(c.new, "0")
        XCTAssertEqual(c.deloTable, "adm2_case")
        XCTAssertEqual(c.uidField, "adm2_case__JUDICIAL_UIDSS")
    }

    /// Маппинг базовой АП-картотеки на вышестоящую картотеку суда субъекта.
    /// Различаются две ветки КоАП: постановление судьи 1-й инстанции (adm) →
    /// ВС «жалобы на постановления» (adm1); решение райсуда по жалобе на несудебное
    /// постановление (admj) → ВС «жалобы на решения по жалобам» (adm2).
    func testKoAPHigherCartotekaMapping() {
        XCTAssertEqual(MovementService.higherCartotekaIDs(baseID: "adm", level: .subject), ["adm1"])
        XCTAssertEqual(MovementService.higherCartotekaIDs(baseID: "admj", level: .subject), ["adm2"])
        // Регресс по гражданским — не сломан.
        XCTAssertEqual(MovementService.higherCartotekaIDs(baseID: "g1", level: .subject), ["g2"])
    }

    /// Картотека ВС для АП «жалобы на постановления» (adm1) зарегистрирована.
    func testKoAPSubjectAdm1Registered() throws {
        let c = try XCTUnwrap(CartotekaRegistry.find(level: .subject, id: "adm1"))
        XCTAssertEqual(c.deloID, "1502001")
        XCTAssertEqual(c.deloTable, "adm1_case")
        XCTAssertEqual(c.uidField, "adm1_case__JUDICIAL_UIDSS")
    }

    /// Ветка КоАП «1-я инстанция по существу» (база adm_case) с двойным возвратом
    /// (реальное дело, УИД 11RS0001-01-2020-015447-54):
    ///   5-45/2021 (Леконцев, привлёк) → ВС 12-127/2021 (отмена) →
    ///   5-1469/2021 (Новикова, оправдал) → ВС 12-283/2021 (отмена) →
    ///   5-2418/2021 (Дульцева, привлёк) → ВС 12-355/2021 (засилил).
    /// ВС-круги лежат в картотеке adm1 (1502001), а НЕ adm2. Проверяем: подтянуты
    /// все три круга горсуда И все три ВС, строго в хронологии.
    func testKoAPFirstInstanceRemandChainPullsSubjectAppeals() async throws {
        let uid = "11RS0001-01-2020-015447-54"
        func gs(_ date: String) -> CaseSession {
            CaseSession(date: date, event: "Рассмотрение дела по существу")
        }
        // Горсуд, 1-я инстанция (adm_case).
        let base = CaseSearchResult(caseNumber: "5-45/2021", decisionDate: "19.01.2021",
                                    result: "Вынесено постановление о назначении наказания",
                                    caseID: "g45", caseUID: "u45")
        let baseCard = CaseCard(rawText: "", actText: "ПОСТАНОВЛЕНИЕ\nназначить наказание.",
                                sessions: [gs("24.11.2020")],
                                judge: "Леконцев А.П.", result: "Вынесено постановление о назначении наказания",
                                uid: uid, caseNumber: "5-45/2021", decisionDate: "19.01.2021")
        let row1469 = CaseSearchResult(caseNumber: "5-1469/2021", decisionDate: "30.03.2021",
                                       result: "Производство прекращено", caseID: "g1469", caseUID: "u1469")
        let card1469 = CaseCard(rawText: "", actText: "ПОСТАНОВЛЕНИЕ\nпроизводство прекратить.",
                                sessions: [gs("15.03.2021")],
                                judge: "Новикова И.В.", result: "Производство прекращено",
                                uid: uid, caseNumber: "5-1469/2021", decisionDate: "30.03.2021")
        let row2418 = CaseSearchResult(caseNumber: "5-2418/2021", decisionDate: "12.05.2021",
                                       result: "Вынесено постановление о назначении наказания",
                                       caseID: "g2418", caseUID: "u2418")
        let card2418 = CaseCard(rawText: "", actText: "ПОСТАНОВЛЕНИЕ\nназначить наказание.",
                                sessions: [gs("23.04.2021")],
                                judge: "Дульцева Ю.А.", result: "Вынесено постановление о назначении наказания",
                                uid: uid, caseNumber: "5-2418/2021", decisionDate: "12.05.2021")
        // ВС, картотека adm1 (жалобы на постановления).
        func vs(_ num: String, _ rcpt: String, _ dec: String, _ res: String, _ id: String) -> CaseSearchResult {
            CaseSearchResult(caseNumber: num, receiptDate: rcpt, decisionDate: dec, result: res,
                             caseID: id, caseUID: "u" + id)
        }
        func vsCard(_ num: String, _ rcpt: String, _ res: String) -> CaseCard {
            CaseCard(rawText: "", actText: "РЕШЕНИЕ\n…", sessions: [CaseSession(date: rcpt, event: "Поступление")],
                     result: res, uid: uid, caseNumber: num)
        }
        let vs127 = vs("12-127/2021", "19.02.2021", "10.03.2021", "Отменено с возвращением на новое рассмотрение", "v127")
        let vs283 = vs("12-283/2021", "14.04.2021", "21.04.2021", "Отменено с возвращением на новое рассмотрение", "v283")
        let vs355 = vs("12-355/2021", "07.06.2021", "07.07.2021", "Оставлено без изменения", "v355")

        let mock = MockClient(
            firstCardID: "g45", firstCard: baseCard,
            higherResults: [vs355, vs127, vs283],   // нарочно вперемешку
            higherCards: ["v127": vsCard("12-127/2021", "19.02.2021", "Отменено с возвращением на новое рассмотрение"),
                          "v283": vsCard("12-283/2021", "14.04.2021", "Отменено с возвращением на новое рассмотрение"),
                          "v355": vsCard("12-355/2021", "07.06.2021", "Оставлено без изменения"),
                          "g1469": card1469, "g2418": card2418],
            sameCourtResults: [row1469, row2418],
            expectedUID: uid)
        let service = MovementService(client: mock, higherCourtDomains: ["vs--komi.sudrf.ru"])
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "adm"))

        let mv = try await service.movement(for: base, court: districtCourt(), cartoteka: cart)

        XCTAssertEqual(mv.instances.map(\.caseNumber),
                       ["5-45/2021", "12-127/2021", "5-1469/2021", "12-283/2021", "5-2418/2021", "12-355/2021"])
        XCTAssertEqual(mv.instances.map(\.level),
                       [.first, .appeal, .first, .appeal, .first, .appeal])
        XCTAssertEqual(mv.instances.filter { $0.level == .appeal }.count, 3, "все три круга ВС подтянуты")
        XCTAssertEqual(mv.instances.filter { $0.level == .first }.count, 3, "все три круга горсуда")
    }

    /// Заголовки актов для АП: жалоба на постановление (admj) — «Решение», а не
    /// «Постановление»; ВС во 2-й инстанции (adm2) — тоже «Решение».
    func testKoAPActTitles() {
        XCTAssertEqual(MovementService.actTitle(cartotekaID: "admj", level: .first), "Решение")
        XCTAssertEqual(MovementService.actTitle(cartotekaID: "adm", level: .first), "Постановление")
        XCTAssertEqual(MovementService.actTitle(cartotekaID: "adm2", level: .appeal), "Решение")
    }

    func testAppealAnchorKeepsAppealLevelForBaseInstanceAndAct() async throws {
        let card = CaseCard(rawText: "", actText: "Текст апелляционного акта",
                            uid: Self.uid, caseNumber: "33-4818/2025")
        let mock = MockClient(firstCardID: "appeal-id", firstCard: card,
                              higherResults: [], higherCards: [:],
                              homeDomain: "vs--komi.sudrf.ru")
        let service = MovementService(client: mock, baseInstanceLevel: .appeal)
        let court = Court(domain: "vs--komi.sudrf.ru",
                          title: "Верховный Суд Республики Коми", level: .subject)
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .subject, id: "g2"))
        let base = CaseSearchResult(caseNumber: "33-4818/2025",
                                    caseID: "appeal-id", caseUID: "link-guid")

        let movement = try await service.movement(for: base, court: court, cartoteka: cart)

        XCTAssertEqual(movement.instances.first?.level, .appeal)
        XCTAssertEqual(movement.acts.first?.instanceLevel, .appeal)
        XCTAssertEqual(movement.acts.first?.title, "Апелляционное определение")
    }
}

/// Мок клиента: отдаёт заранее заданные карточки и записывает значения поиска.
/// Различает домашний суд (по домену) и вышестоящие: по УИД домашний суд отдаёт
/// `sameCourtResults` (другие круги той же инстанции), вышестоящие — `higherResults`.
private actor MockClient: CaseProviding {
    private let firstCardID: String
    private let firstCard: CaseCard
    private let higherResults: [CaseSearchResult]
    private let higherCards: [String: CaseCard]
    private let sameCourtResults: [CaseSearchResult]
    private let homeDomain: String
    private let expectedUID: String
    private(set) var searchedValues: [String] = []

    init(firstCardID: String, firstCard: CaseCard,
         higherResults: [CaseSearchResult], higherCards: [String: CaseCard],
         sameCourtResults: [CaseSearchResult] = [],
         homeDomain: String = "syktsud--komi.sudrf.ru",
         expectedUID: String = "11RS0001-01-2025-011255-03") {
        self.firstCardID = firstCardID
        self.firstCard = firstCard
        self.higherResults = higherResults
        self.higherCards = higherCards
        self.sameCourtResults = sameCourtResults
        self.homeDomain = homeDomain
        self.expectedUID = expectedUID
    }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        searchedValues.append(value)
        guard field == .uid, value == expectedUID else { return [] }
        return court.domain == homeDomain ? sameCourtResults : higherResults
    }

    func fetchCard(url: URL) async throws -> CaseCard {
        throw SudrfError.http(status: 404)   // в этих сценариях путь по ссылке не используется
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        if caseID == firstCardID { return firstCard }
        return higherCards[caseID] ?? firstCard
    }
}

// MARK: - A16 transient-stub merge tests

/// Мок клиента, бросающий заранее заданную ошибку на запросах к вышестоящему
/// суду. Используется для тестов transient-ветки в `Movement.movement(...)`:
/// мок бросает `SudrfError.transientNetworkError` (тесты
/// `testTransientErrorRestoresCachedHigherInstance`,
/// `testModuleHostDashDotMatchInMerge`, `testMultiRoundRestoredFromCache`)
/// или `URLError(.cancelled)` (`testCancelledDoesNotCreateTransientStub`).
/// Преобразование `URLError → SudrfError.transientNetworkError` тестируется
/// отдельно в `SudrfClientTransientErrorTests`.
private actor FailingMockClient: CaseProviding {
    private let firstCardID: String
    private let firstCard: CaseCard
    private let homeDomain: String
    private let expectedUID: String
    /// Ошибка, бросаемая на ЛЮБОЙ запрос к вышестоящему суду (search + fetchCard).
    private let higherError: Error
    private let firstCardError: Error?
    private(set) var searchedValues: [String] = []

    init(firstCardID: String, firstCard: CaseCard,
         homeDomain: String = "syktsud--komi.sudrf.ru",
         expectedUID: String = "11RS0001-01-2025-011255-03",
         higherError: Error,
         firstCardError: Error? = nil) {
        self.firstCardID = firstCardID
        self.firstCard = firstCard
        self.homeDomain = homeDomain
        self.expectedUID = expectedUID
        self.higherError = higherError
        self.firstCardError = firstCardError
    }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        searchedValues.append(value)
        if let firstCardError, court.domain == homeDomain { throw firstCardError }
        throw higherError
    }

    func fetchCard(url: URL) async throws -> CaseCard {
        throw SudrfError.http(status: 404)
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        if caseID == firstCardID { return firstCard }
        throw higherError
    }
}

/// `testTransientErrorRestoresCachedHigherInstance` — single round. cached
/// содержит 1 real round этого домена с `actID`; fresh (через `FailingMockClient`,
/// бросающий `SudrfError.transientNetworkError`) ставит transient-stub.
/// После `MovementCachePolicy.merge` — stub удалён, real из кэша, акт перенесён,
/// `transientError == nil`, `captchaFormURL == nil`.
final class MovementServiceTransientStubTests: XCTestCase {

    private static let uid = "11RS0001-01-2026-000001-11"

    private func firstCardFixture() throws -> CaseCard {
        let url = Bundle.module.url(forResource: "sgs_1inst", withExtension: "html",
                                    subdirectory: "Fixtures")
        let html = try String(contentsOf: XCTUnwrap(url), encoding: .utf8)
        return try CaseCardParser.parse(html: html)
    }

    private func districtCourt() -> Court {
        Court(domain: "syktsud--komi.sudrf.ru",
              title: "Сыктывкарский городской суд", level: .district)
    }

    private func base() -> CaseSearchResult {
        CaseSearchResult(caseNumber: "2-1/2026", caseID: "30636693",
                         caseUID: "0cec7ea2-1eae-47eb-988b-5df03f4f190c")
    }

    /// Fresh: 1 transient-stub для `vs--komi.sudrf.ru`. Cached: 1 real round
    /// того же домена с `actID`. Merge подменяет stub на cached real, акт
    /// переезжает. `transientError == nil`, `captchaFormURL == nil`.
    func testTransientErrorRestoresCachedHigherInstance() async throws {
        let firstCard = try firstCardFixture()
        let actID = "act_vs--komi.sudrf.ru#33-4818/2026"
        let cachedReal = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "33-4818/2026",
            judge: nil, domain: "vs--komi.sudrf.ru", foundByUID: true,
            result: "решение отменено", sessions: [CaseSession(date: "01.06.2026", event: "Заседание")],
            actID: actID)
        let cachedAct = CaseAct(id: actID, title: "Апелляционное определение",
                                date: "15.09.2026", courtShort: "ВС Коми", instanceLevel: .appeal)
        let cached = CaseMovement(uid: Self.uid, caseNumber: "2-1/2026", inForce: true,
                                 instances: [
                                    CaseInstance(level: .first, court: "Сыктывкарский городской суд",
                                                 caseNumber: "2-1/2026", judge: nil,
                                                 domain: "syktsud--komi.sudrf.ru",
                                                 foundByUID: false, result: nil, sessions: []),
                                    cachedReal
                                 ],
                                 complaints: [:], acts: [cachedAct], actBodies: [actID: "Текст акта"])

        let mock = FailingMockClient(
            firstCardID: "30636693", firstCard: firstCard,
            higherError: SudrfError.transientNetworkError(
                domain: "vs--komi.sudrf.ru", code: .timedOut, attempt: 3))
        let service = MovementService(client: mock, higherCourtDomains: ["vs--komi.sudrf.ru"])
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let fresh = try await service.movement(for: base(), court: districtCourt(), cartoteka: cart)
        // Fresh: 1 transient-stub, captchaFormURL == nil, transientError == true.
        XCTAssertEqual(fresh.instances.filter { $0.transientError == true }.count, 1)
        let freshStub = fresh.instances.first { $0.transientError == true }!
        XCTAssertNil(freshStub.captchaFormURL)

        // Merge: stub удалён, cached real на месте, акт перенесён.
        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)
        let mergedInst = merged.instances.first { $0.domain == "vs--komi.sudrf.ru" }!
        XCTAssertNil(mergedInst.captchaFormURL, "transient-stub не заменяется captcha-stub")
        XCTAssertNil(mergedInst.transientError, "stub заменён на cached real — transientError == nil")
        XCTAssertEqual(mergedInst.caseNumber, "33-4818/2026", "cached real caseNumber")
        XCTAssertEqual(mergedInst.actID, actID, "cached real actID")
        XCTAssertTrue(merged.acts.contains { $0.id == actID }, "акт из кэша перенесён в merged")
        XCTAssertEqual(merged.actBodies[actID], "Текст акта", "тело акта из кэша перенесено")
    }

    /// Ошибка, которую клиент не классифицировал как transient (например,
    /// единичный timeout тестового провайдера), раньше попадала в `catch {
    /// continue }`: свежий результат терял вышестоящий суд и затирал кэш.
    func testGenericHigherCourtFailurePreservesCachedInstance() async throws {
        let firstCard = try firstCardFixture()
        let actID = "act_vs--komi.sudrf.ru#33-4818/2026"
        let cachedReal = CaseInstance(
            level: .appeal, court: "ВС Коми", caseNumber: "33-4818/2026",
            judge: nil, domain: "vs--komi.sudrf.ru", foundByUID: true,
            result: "решение отменено", sessions: [CaseSession(date: "01.06.2026", event: "Заседание")],
            actID: actID)
        let cached = CaseMovement(uid: Self.uid, caseNumber: "2-1/2026", inForce: true,
                                 instances: [
                                    CaseInstance(level: .first, court: "Сыктывкарский городской суд",
                                                 caseNumber: "2-1/2026", judge: nil,
                                                 domain: "syktsud--komi.sudrf.ru",
                                                 foundByUID: false, result: nil, sessions: []),
                                    cachedReal
                                 ],
                                 complaints: [:],
                                 acts: [CaseAct(id: actID, title: "Апелляционное определение",
                                                date: "15.09.2026", courtShort: "ВС Коми", instanceLevel: .appeal)],
                                 actBodies: [actID: "Текст акта"])
        let mock = FailingMockClient(firstCardID: "30636693", firstCard: firstCard,
                                     higherError: URLError(.timedOut))
        let service = MovementService(client: mock, higherCourtDomains: ["vs--komi.sudrf.ru"])
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let fresh = try await service.movement(for: base(), court: districtCourt(), cartoteka: cart)
        XCTAssertEqual(fresh.incompleteHigherCourtDomains, ["vs--komi.sudrf.ru"])

        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)
        let restored = try XCTUnwrap(merged.instances.first { $0.domain == "vs--komi.sudrf.ru" })
        XCTAssertEqual(restored.caseNumber, "33-4818/2026")
        XCTAssertEqual(restored.actID, actID)
        XCTAssertEqual(merged.actBodies[actID], "Текст акта")
        XCTAssertNil(merged.incompleteHigherCourtDomains)
    }

    /// Fresh: 1 transient-stub для `vs--komi.sudrf.ru` (dash-форма).
    /// Cached: 1 real round для `vs.komi.sudrf.ru` (dot-форма). После merge
    /// — stub удалён, real восстановлен по каноническому moduleHost.
    /// A14 dedup + A16 merge: dash и dot формы — один и тот же хост.
    func testModuleHostDashDotMatchInMerge() async throws {
        let firstCard = try firstCardFixture()
        let actID = "act_vs.komi.sudrf.ru#33-4818/2026"
        let cached = CaseMovement(uid: Self.uid, caseNumber: "2-1/2026", inForce: true,
                                 instances: [
                                    CaseInstance(level: .first, court: "Сыктывкарский городской суд",
                                                 caseNumber: "2-1/2026", judge: nil,
                                                 domain: "syktsud--komi.sudrf.ru",
                                                 foundByUID: false, result: nil, sessions: []),
                                    CaseInstance(level: .appeal, court: "ВС Коми", caseNumber: "33-4818/2026",
                                                 judge: nil, domain: "vs.komi.sudrf.ru",
                                                 foundByUID: true, result: "оставлено без изменения",
                                                 sessions: [CaseSession(date: "01.06.2026", event: "Заседание")],
                                                 actID: actID)
                                 ],
                                 complaints: [:],
                                 acts: [CaseAct(id: actID, title: "Апелляционное определение",
                                               date: "15.09.2026", courtShort: "ВС Коми", instanceLevel: .appeal)],
                                 actBodies: [actID: "Текст акта dot-формы"])

        let mock = FailingMockClient(
            firstCardID: "30636693", firstCard: firstCard,
            higherError: SudrfError.transientNetworkError(
                domain: "vs--komi.sudrf.ru", code: .timedOut, attempt: 3))
        let service = MovementService(client: mock, higherCourtDomains: ["vs--komi.sudrf.ru"])
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let fresh = try await service.movement(for: base(), court: districtCourt(), cartoteka: cart)
        XCTAssertEqual(fresh.instances.filter { $0.transientError == true }.count, 1)
        let freshStub = fresh.instances.first { $0.transientError == true }!
        XCTAssertEqual(freshStub.domain, "vs--komi.sudrf.ru", "fresh stub в dash-форме")

        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)
        // dot-форма из кэша восстановлена, dash-stub удалён.
        XCTAssertNil(merged.instances.first { $0.domain == "vs--komi.sudrf.ru" && $0.transientError == true },
                     "dash-stub удалён после merge")
        let realInst = merged.instances.first { $0.domain == "vs.komi.sudrf.ru" }!
        XCTAssertNil(realInst.transientError, "cached real — transientError == nil")
        XCTAssertEqual(realInst.caseNumber, "33-4818/2026")
        XCTAssertEqual(realInst.actID, actID)
        XCTAssertEqual(merged.actBodies[actID], "Текст акта dot-формы")
    }

    /// Fresh: 1 transient-stub для `vs--komi.sudrf.ru`. Cached: 2 real rounds
    /// того же канонического хоста с разными `actID`. Merge восстанавливает
    /// ОБА round'а + оба акта, stub удалён. **Закрывает BM7 (для
    /// transient-ветки)**: «восстанавливать все кэш-инстанции домена, не
    /// только первую». Captcha-аналог — `testCaptchaMultiRoundRestoredFromCache`
    /// в `MovementCachePolicyTests`.
    func testMultiRoundRestoredFromCache() async throws {
        let firstCard = try firstCardFixture()
        let actID1 = "act_vs--komi.sudrf.ru#33-1/2025"
        let actID2 = "act_vs--komi.sudrf.ru#33-2/2026"
        let round1 = CaseInstance(level: .appeal, court: "ВС Коми", caseNumber: "33-1/2025",
                                  judge: nil, domain: "vs.komi.sudrf.ru", foundByUID: true,
                                  result: "решение отменено",
                                  sessions: [CaseSession(date: "01.06.2025", event: "Заседание")],
                                  actID: actID1)
        let round2 = CaseInstance(level: .appeal, court: "ВС Коми", caseNumber: "33-2/2026",
                                  judge: nil, domain: "vs.komi.sudrf.ru", foundByUID: true,
                                  result: "оставлено без изменения",
                                  sessions: [CaseSession(date: "01.06.2026", event: "Заседание")],
                                  actID: actID2)
        let cached = CaseMovement(uid: Self.uid, caseNumber: "2-1/2026", inForce: true,
                                 instances: [
                                    CaseInstance(level: .first, court: "Сыктывкарский городской суд",
                                                 caseNumber: "2-1/2026", judge: nil,
                                                 domain: "syktsud--komi.sudrf.ru",
                                                 foundByUID: false, result: nil, sessions: []),
                                    round1, round2
                                 ],
                                 complaints: [:],
                                 acts: [
                                    CaseAct(id: actID1, title: "Апелляционное определение",
                                            date: "15.09.2025", courtShort: "ВС Коми", instanceLevel: .appeal),
                                    CaseAct(id: actID2, title: "Апелляционное определение",
                                            date: "15.09.2026", courtShort: "ВС Коми", instanceLevel: .appeal)
                                 ],
                                 actBodies: [actID1: "Тело акта 1", actID2: "Тело акта 2"])

        let mock = FailingMockClient(
            firstCardID: "30636693", firstCard: firstCard,
            higherError: SudrfError.transientNetworkError(
                domain: "vs--komi.sudrf.ru", code: .timedOut, attempt: 3))
        let service = MovementService(client: mock, higherCourtDomains: ["vs--komi.sudrf.ru"])
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let fresh = try await service.movement(for: base(), court: districtCourt(), cartoteka: cart)
        let merged = MovementCachePolicy.merge(fresh: fresh, cached: cached)

        // Нет transient-stub после merge
        XCTAssertFalse(merged.instances.contains { $0.transientError == true },
                       "transient-stub удалён после merge")
        // ОБА cached round'а восстановлены
        let realRounds = merged.instances.filter { $0.domain == "vs.komi.sudrf.ru" }
        XCTAssertEqual(realRounds.count, 2, "оба cached round'а восстановлены (BM7)")
        XCTAssertEqual(Set(realRounds.map(\.caseNumber)), ["33-1/2025", "33-2/2026"])
        // ОБА акта перенесены
        XCTAssertTrue(merged.acts.contains { $0.id == actID1 },
                      "акт кэша 1 перенесён в merged (BM7)")
        XCTAssertTrue(merged.acts.contains { $0.id == actID2 },
                      "акт кэша 2 перенесён в merged (BM7)")
        XCTAssertEqual(merged.actBodies[actID1], "Тело акта 1")
        XCTAssertEqual(merged.actBodies[actID2], "Тело акта 2")
    }

    /// `URLError(.cancelled)` НЕ входит в `isTransient` (SudrfClient не
    /// преобразует в `SudrfError.transientNetworkError`). Стало быть, в
    /// `Movement.movement(...)` catch `SudrfError.transientNetworkError` НЕ
    /// срабатывает, `transient-stub` НЕ ставится — `URLError(.cancelled)`
    /// летит в общий `catch { continue }` и весь вышестоящий суд
    /// пропускается без инстанции. SudrfClient-сторона для `.cancelled`
    /// покрыта в `SudrfClientTransientErrorTests.testFatalURLErrorNotMarkedTransient_Cancelled`.
    func testCancelledDoesNotCreateTransientStub() async throws {
        let firstCard = try firstCardFixture()
        // Бросаем именно URLError(.cancelled), НЕ SudrfError.transientNetworkError.
        // Если бы в Movement.catch был catch URLError + isTransient — была бы
        // регрессия (отмена Task оставляла бы stub). Логика НЕ должна
        // создавать stub на отмену.
        let mock = FailingMockClient(
            firstCardID: "30636693", firstCard: firstCard,
            higherError: URLError(.cancelled))
        let service = MovementService(client: mock, higherCourtDomains: ["vs--komi.sudrf.ru"])
        let cart = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))

        let fresh = try await service.movement(for: base(), court: districtCourt(), cartoteka: cart)
        XCTAssertFalse(fresh.instances.contains { $0.transientError == true },
                       "URLError(.cancelled) НЕ ставит transient-stub")
        XCTAssertFalse(fresh.instances.contains { $0.captchaFormURL != nil },
                       "URLError(.cancelled) НЕ ставит captcha-stub")
        // 1-я инстанция (district) на месте, вышестоящего — нет.
        XCTAssertEqual(fresh.instances.count, 1, "только 1-я инстанция, вышестоящий пропущен")
    }
}
