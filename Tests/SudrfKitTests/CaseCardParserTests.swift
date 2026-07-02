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
