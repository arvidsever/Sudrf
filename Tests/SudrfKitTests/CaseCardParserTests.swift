import XCTest
@testable import SudrfKit

/// Тесты разбора карточки на РЕАЛЬНЫХ страницах `name_op=case`, снятых с
/// Сыктывкарского городского суда (1-я инстанция), Верховного Суда Республики
/// Коми (апелляция) и Третьего КСОЮ (кассация) — одно гражданское дело по всем
/// трём инстанциям. Фикстуры лежат в Tests/SudrfKitTests/Fixtures.
final class CaseCardParserTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "html",
                                          subdirectory: "Fixtures") else {
            throw XCTSkip("Фикстура \(name).html не найдена в бандле теста")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Винтажная карточка (VNKOD-суды)

    /// Живая карточка Заволжского районного суда г. Ульяновска (винтажный
    /// интерфейс: вкладки tab_content_* вместо cont{N}).
    func testVintageCard() throws {
        let card = try CaseCardParser.parse(html: try loadFixture("zavolgskiy_card"))

        XCTAssertEqual(card.uid, "73RS0004-01-2024-005087-98")
        XCTAssertEqual(card.caseNumber, "2-5/2026 (2-13/2025; 2-2935/2024;) ~ М-2773/2024")
        XCTAssertEqual(card.judge, "Савелова А. Л.")
        XCTAssertEqual(card.category, "2.213 - Иски о взыскании сумм по договору займа")
        XCTAssertEqual(card.receiptDate, "22.07.2024")
        XCTAssertNil(card.actText, "акт по делу не опубликован")

        // Движение: первая запись — регистрация иска; мобильные дубли таблиц
        // не должны задваивать сессии (в фикстуре они есть).
        let first = try XCTUnwrap(card.sessions.first)
        XCTAssertTrue(first.event.contains("Регистрация иска"))
        XCTAssertEqual(first.date, "22.07.2024")
        XCTAssertEqual(first.time, "14:35")
        let registrations = card.sessions.filter { $0.event.contains("Регистрация иска") }
        XCTAssertEqual(registrations.count, 1, "мобильный дубль таблицы задвоил сессии")

        // Стороны: ИСТЕЦ / ОТВЕТЧИК / ПРЕДСТАВИТЕЛЬ, без задвоения.
        XCTAssertEqual(card.parties.plaintiffs, ["Головинская И.Ю."])
        XCTAssertEqual(card.parties.defendants.filter { $0.contains("Глухов") }.count, 1)
    }

    /// Живая карточка Благовещенского городского суда Амурской области —
    /// второй живой образец винтажной разметки: ключ судьи — «Судья» (не
    /// «Председательствующий»), категория с переносами <br> и стрелками,
    /// в «Движении дела» дополнительная колонка «Примечание», стороны скрыты
    /// (семейный спор). Карточка открывалась по ссылке ТОЛЬКО с `_uid` —
    /// сценарий cardURL-first.
    func testVintageCardBlagoveshchensk() throws {
        let card = try CaseCardParser.parse(html: try loadFixture("blag_card"))

        XCTAssertEqual(card.uid, "28RS0004-01-2025-018120-67")
        XCTAssertEqual(card.caseNumber, "2-5/2026 ~ М-7523/2025")
        XCTAssertEqual(card.judge, "Приходько А.В.")
        XCTAssertEqual(card.receiptDate, "15.12.2025")
        XCTAssertTrue(card.category?.contains("семейных правоотношений") == true)
        XCTAssertTrue(card.category?.contains("алиментов") == true)
        XCTAssertNil(card.actText, "акт по делу не опубликован")

        let first = try XCTUnwrap(card.sessions.first)
        XCTAssertTrue(first.event.contains("Регистрация иска"))
        XCTAssertFalse(first.date.isEmpty)

        // Стороны семейного спора скрыты — но роли распознаны без задвоения.
        XCTAssertEqual(card.parties.plaintiffs, ["Информация скрыта"])
        XCTAssertEqual(card.parties.defendants, ["Информация скрыта"])
    }

    /// Самарский областной суд: КАС-апелляция на старом VNKOD-интерфейсе живёт в
    /// общей гражданско-административной картотеке, а карточка публикует
    /// докладчика/решение и акт в `tab_content_DocumentN`.
    func testVintageSamaraKASAppealCard() throws {
        let card = try CaseCardParser.parse(html: try loadFixture("samara_kas_appeal_card"))

        XCTAssertEqual(card.uid, "63RS0042-01-2025-002452-47")
        XCTAssertEqual(card.caseNumber, "33а-647/2026 (33а-11786/2025;)")
        XCTAssertEqual(card.judge, "Пудовкина Е. С.")
        XCTAssertEqual(card.result, "РЕШЕНИЕ оставлено БЕЗ ИЗМЕНЕНИЯ")
        XCTAssertEqual(card.receiptDate, "10.11.2025")
        XCTAssertEqual(card.decisionDate, "13.01.2026")
        XCTAssertTrue(card.category?.contains("Гл. 22 КАС РФ") == true)

        XCTAssertEqual(card.sessions.count, 6)
        let first = try XCTUnwrap(card.sessions.first)
        XCTAssertEqual(first.date, "10.11.2025")
        XCTAssertEqual(first.time, "18:24")
        XCTAssertEqual(first.event, "Передача дела судье")

        let act = try XCTUnwrap(card.acts.first)
        XCTAssertEqual(act.kind, "Определение")
        XCTAssertTrue(act.body.contains("АПЕЛЛЯЦИОННОЕ ОПРЕДЕЛЕНИЕ"))
        XCTAssertEqual(card.actText, act.body)
    }

    // MARK: - 1-я инстанция (СГС)

    func testFirstInstanceCard() throws {
        let card = try CaseCardParser.parse(html: try loadFixture("sgs_1inst"))

        XCTAssertEqual(card.uid, "11RS0001-01-2025-011255-03")
        XCTAssertEqual(card.caseNumber, "2-7212/2025 ~ М-5922/2025")
        XCTAssertEqual(card.judge, "Машкалева Ольга Александровна")
        XCTAssertEqual(card.result, "Иск (заявление, жалоба) УДОВЛЕТВОРЕН")
        XCTAssertEqual(card.receiptDate, "22.07.2025")

        // Движение: «событие первое». Раньше парсер возвращал пусто.
        XCTAssertEqual(card.sessions.count, 8)
        let first = try XCTUnwrap(card.sessions.first)
        XCTAssertEqual(first.event, "Регистрация иска (заявления, жалобы) в суде")
        XCTAssertEqual(first.date, "22.07.2025")
        XCTAssertEqual(first.time, "13:00")

        // Текст акта — это РЕШЕНИЕ, а не «простыня» из метаданных.
        let act = try XCTUnwrap(card.acts.first)
        XCTAssertEqual(act.kind, "Решения")
        XCTAssertTrue(act.body.contains("ЗАОЧНОЕ РЕШЕНИЕ"))
        XCTAssertTrue(act.body.contains("Именем Российской Федерации"))
        XCTAssertFalse(act.body.contains("Категория дела"))      // метаданных тут быть не должно
        XCTAssertEqual(card.actText, act.body)                   // обратная совместимость
    }

    // MARK: - Апелляция (ВС РК)

    func testAppealCard() throws {
        let card = try CaseCardParser.parse(html: try loadFixture("vsrk_appeal"))

        XCTAssertEqual(card.uid, "11RS0001-01-2025-011255-03")
        XCTAssertEqual(card.caseNumber, "33-4818/2025")
        XCTAssertEqual(card.result, "РЕШЕНИЕ оставлено БЕЗ ИЗМЕНЕНИЯ")
        XCTAssertEqual(card.sessions.count, 5)                   // вкладка движения здесь cont3
        let act = try XCTUnwrap(card.acts.first)
        XCTAssertEqual(act.kind, "Определение")
        XCTAssertTrue(act.body.contains("АПЕЛЛЯЦИОННОЕ ОПРЕДЕЛЕНИЕ"))
    }

    // MARK: - Уголовное дело (вкладки «ЛИЦА» + «СТОРОНЫ»)

    /// Живая карточка Ленинского р/с г. Уфы: уголовное дело публикует участников
    /// в ДВУХ таблицах — «ЛИЦА» (подсудимый + перечень статей, колонка 0 это имя)
    /// и «СТОРОНЫ» (защитник, прокурор — роль | имя). Раньше не совпадал ни один
    /// заголовок `<th>` → «стороны не опубликованы».
    func testCriminalCardParties() throws {
        let card = try CaseCardParser.parse(html: try loadFixture("leninsky_ufa_criminal"))

        XCTAssertEqual(card.parties.kind, .upk)
        XCTAssertFalse(card.parties.isEmpty)

        let cols = card.parties.displayColumns
        let defense = try XCTUnwrap(cols.first { $0.icon == .shield }, "нет стороны защиты")
        let prosecution = try XCTUnwrap(cols.first { $0.icon == .scales }, "нет стороны обвинения")

        // Защита: подсудимая — слово-роль в `sub`, статьи отдельным полем
        // (для карточки «Подсудимый · ст…», для «Списком» — щит+статьи).
        let defendant = try XCTUnwrap(defense.members.first { $0.name.contains("Юсупова") })
        XCTAssertEqual(defendant.sub, "Подсудимый")
        XCTAssertTrue(defendant.articles?.contains("173.1") == true, "статья не попала в articles")
        XCTAssertTrue(defense.members.contains { $0.name.contains("Низамова") }, "нет защитника")

        // Обвинение: прокурор.
        XCTAssertTrue(prosecution.members.contains { $0.name.contains("Сагадиев") }, "нет прокурора")

        // «Списком»: статьи ведущего лица отдаются отдельно (для щита).
        XCTAssertTrue(card.parties.leadCharges?.contains("173.1") == true)
    }

    // MARK: - Дело об АП (КоАП: «СТОРОНЫ ПО ДЕЛУ» с «ПРИВЛЕКАЕМОЕ ЛИЦО»)

    /// Живая карточка Ленинского р/с г. Кирова (5-174/2026): у КоАП отдельной
    /// вкладки «ЛИЦА» нет — привлекаемое лицо и представители лежат в одной
    /// таблице «СТОРОНЫ ПО ДЕЛУ» (роль | имя + перечень статей). Привлекаемое —
    /// на защите (со статьёй), представители — на стороне обвинения.
    func testKoapCardParties() throws {
        let card = try CaseCardParser.parse(html: try loadFixture("kirov_koap"))

        XCTAssertEqual(card.parties.kind, .koap)
        XCTAssertFalse(card.parties.isEmpty)

        let defense = try XCTUnwrap(card.parties.displayColumns.first { $0.icon == .shield })
        let person = try XCTUnwrap(defense.members.first { $0.name.contains("Ананьева") })
        XCTAssertEqual(person.sub?.uppercased(), "ПРИВЛЕКАЕМОЕ ЛИЦО")
        XCTAssertNotNil(person.articles, "статья привлекаемого не попала в articles")
        XCTAssertNotNil(card.parties.leadCharges, "нет статей для щита в «Списком»")

        // Представители КоАП — на стороне обвинения (обычно представитель потерпевшего).
        let prosecution = try XCTUnwrap(card.parties.displayColumns.first { $0.icon == .scales },
                                        "нет стороны обвинения с представителями")
        XCTAssertTrue(prosecution.members.contains { $0.name.contains("Баева") })
        XCTAssertTrue(prosecution.members.contains { $0.name.contains("Перова") })
    }

    /// Роль «Представитель учреждения (компетентного органа)» в УПК — отдельная
    /// третья колонка «Иные лица» со значком лица (как у третьих лиц ГПК/КАС).
    func testUpkInstitutionRepGoesToOther() {
        var p = CaseParties()
        p.add(role: "Подсудимый", name: "Иванов Иван Иванович", articles: "ст.158 ч.3 УК РФ")
        p.add(role: "Представитель учреждения (компетентного органа)", name: "Петров Пётр")
        XCTAssertEqual(p.kind, .upk)

        let other = p.displayColumns.first { $0.id == "inye" }
        XCTAssertNotNil(other, "нет колонки «Иные лица»")
        XCTAssertEqual(other?.icon, .person)
        XCTAssertEqual(other?.titleMany, "Иные лица")
        XCTAssertTrue(other?.members.contains { $0.name.contains("Петров") } == true)
        // Представитель учреждения не должен утечь в защиту/обвинение.
        XCTAssertFalse(p.displayColumns.first { $0.icon == .shield }?.members
            .contains { $0.name.contains("Петров") } ?? false)
    }

    /// `leadCharges` — статьи ведущего лица для строки «Списком» (только УПК/КоАП).
    func testLeadCharges() {
        var upk = CaseParties()
        upk.add(role: "Подсудимый", name: "Иванов Иван Иванович", articles: "ст.158 ч.3 УК РФ")
        upk.add(role: "Защитник (адвокат)", name: "Сидоров С. С.")
        XCTAssertEqual(upk.leadCharges, "ст.158 ч.3 УК РФ")

        // Гражданское дело — статей нет.
        let civil = CaseParties(plaintiffs: ["Новожилова Е. В."], defendants: ["ООО «Северлес»"])
        XCTAssertNil(civil.leadCharges)
    }

    // MARK: - Кассация (3 КСОЮ)

    func testCassationCard() throws {
        let card = try CaseCardParser.parse(html: try loadFixture("ksoy_cassation"))

        XCTAssertEqual(card.uid, "11RS0001-01-2025-011255-03")
        // У КСОЮ заголовок: «ДЕЛО № 8Г-2430/2026 [88-4097/2026]».
        XCTAssertEqual(card.caseNumber, "8Г-2430/2026 [88-4097/2026]")
        XCTAssertTrue((card.result ?? "").contains("АПЕЛЛЯЦИОННОЕ ОПРЕДЕЛЕНИЕ ОТМЕНЕНО"))
        XCTAssertEqual(card.sessions.count, 1)                   // вкладка «СЛУШАНИЯ»
        let act = try XCTUnwrap(card.acts.first)
        XCTAssertEqual(act.kind, "Постановления")
        XCTAssertTrue(act.body.contains("ТРЕТИЙ КАССАЦИОННЫЙ СУД ОБЩЕЙ ЮРИСДИКЦИИ"))
    }
}
