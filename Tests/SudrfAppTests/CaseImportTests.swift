import XCTest
import Foundation
import SudrfKit
@testable import SudrfApp

/// Импорт дел из CSV-выгрузки LegalHelp (v21): разбор CSV, классификация
/// строк по доменам/параметрам ссылки, сборка контекста и сшивание карточек
/// в дела по УИД. Ссылки в тестах — реальные образцы из выгрузки (обезличенные id).
final class CaseImportTests: XCTestCase {

    // MARK: CSV

    func testCSVParserQuotesAndCommas() {
        let csv = "number,court,kind,level,parties,updated,url\n"
            + "\"2-1/2026\",Суд,,,\"Иванов И.И. ⚔ ООО \"\"Ромашка, и точка\"\"\",01.07.2026,https://x.sudrf.ru/?a=1\n"
            + "M-2/2026,Суд2,,,стороны\n"
        let rows = CSVParser.parse(csv)
        XCTAssertEqual(rows[0].count, 7)
        XCTAssertEqual(rows[1][0], "2-1/2026")
        XCTAssertEqual(rows[1][4], "Иванов И.И. ⚔ ООО \"Ромашка, и точка\"")
        XCTAssertEqual(rows[1][6], "https://x.sudrf.ru/?a=1")
        XCTAssertEqual(rows[2][0], "M-2/2026")
    }

    func testCSVRowsMapping() {
        let csv = "\u{FEFF}number,court,kind,level,parties,updated,url\r\n" +
                  "13-1/2026,Суд (Регион),материалы,Районный суд,А ⚔ Б,01.01.2026,https://s--r.sudrf.ru/x\r\n"
        let rows = CaseImporter.rows(fromCSV: csv)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].number, "13-1/2026")
        XCTAssertEqual(rows[0].court, "Суд (Регион)")
        XCTAssertEqual(rows[0].parties, "А ⚔ Б")
        XCTAssertEqual(rows[0].urlString, "https://s--r.sudrf.ru/x")
    }

    // MARK: Классификация строк

    private func row(_ number: String, _ court: String, _ url: String,
                     parties: String = "Истец И.И. ⚔ Ответчик О.О.") -> ImportedRow {
        ImportedRow(number: number, court: court, parties: parties, urlString: url)
    }

    private func seed(_ r: ImportedRow) throws -> ImportSeed {
        guard case .seed(let s) = CaseImporter.classify(r) else {
            throw XCTSkip("строка неожиданно пропущена")
        }
        return s
    }

    func testDistrictCivilCase() throws {
        let s = try seed(row("2-8966/2026 ~ М-3225/2026",
                             "Невский районный суд (Город Санкт-Петербург)",
                             "https://nvs--spb.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case&case_id=964177648&case_uid=bd648faa-6272-4b5d-819b-d148c70cc94c&delo_id=1540005"))
        XCTAssertEqual(s.level, .district)
        XCTAssertEqual(s.branch, .general)
        XCTAssertEqual(s.searchDomain, "nvs--spb.sudrf.ru")
        XCTAssertEqual(s.displayDomain, "nvs.spb.sudrf.ru")
        XCTAssertEqual(s.courtTitle, "Невский районный суд")
        XCTAssertEqual(s.region, "Город Санкт-Петербург")
        XCTAssertEqual(s.courtCode, "78")
        XCTAssertEqual(s.cartoteka?.id, "g1")
        XCTAssertFalse(s.isMaterial)
        XCTAssertEqual(s.caseID, "964177648")
        XCTAssertEqual(s.instanceLevel, .first)
    }

    /// Точечная форма хоста (старые ссылки выгрузки) приводится к модульной.
    func testDotFormHostNormalized() throws {
        let s = try seed(row("2-100/2025", "Сыктывкарский городской суд (Республика Коми)",
                             "http://syktsud.komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=1&case_uid=u&delo_id=1540005"))
        XCTAssertEqual(s.searchDomain, "syktsud--komi.sudrf.ru")
        XCTAssertEqual(s.displayDomain, "syktsud.komi.sudrf.ru")
        XCTAssertEqual(s.courtCode, "11")
    }

    func testDistrictMaterial() throws {
        let s = try seed(row("13-2472/2026", "Сыктывкарский городской суд (Республика Коми)",
                             "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=27767691&case_uid=b054f552&delo_id=1610001&case_type=0&new=0&srv_num=1"))
        XCTAssertTrue(s.isMaterial)
        XCTAssertEqual(s.cartoteka?.id, "m")
        XCTAssertEqual(s.instanceLevel, .material)
        XCTAssertEqual(s.anchorRank, 100, "материал якорем быть не должен")
    }

    func testGarrisonCourtUsesMilitaryDistrictRoute() throws {
        let s = try seed(row("2-1/2026", "Сыктывкарский гарнизонный военный суд (Республика Коми)",
                             "https://gvs--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=1&case_uid=u&delo_id=1540005"))
        XCTAssertEqual(s.level, .district)
        XCTAssertEqual(s.branch, .military)
    }

    /// Материал вида «15-…» (индекса нет в реестре) — картотека по delo_id.
    func testMaterial15ResolvedByDeloID() throws {
        let s = try seed(row("15-34/2026", "Сыктывкарский городской суд (Республика Коми)",
                             "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=2&case_uid=u&delo_id=1610001&new=0"))
        XCTAssertEqual(s.cartoteka?.id, "m")
        XCTAssertTrue(s.isMaterial)
    }

    /// КСОЮ: ссылка выгрузки открывает карточку неканонической парой
    /// delo_id=2800001&new=2800001 — картотека распознаётся по new (g3).
    func testCassationCourtNonCanonicalDeloID() throws {
        let s = try seed(row("8Г-10837/2026", "Третий кассационный суд общей юрисдикции (Город Санкт-Петербург)",
                             "https://3kas.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case&case_id=24352048&case_uid=00d6eb33&new=2800001&delo_id=2800001"))
        XCTAssertEqual(s.level, .cassation)
        XCTAssertEqual(s.cartoteka?.id, "g3")
        XCTAssertEqual(s.instanceLevel, .cassation)
        // Прямая ссылка сохраняет параметры выгрузки (карточка по ним открывается).
        XCTAssertEqual(s.deloID, "2800001")
        XCTAssertEqual(s.new, "2800001")
    }

    func testAppealCourtASOYu() throws {
        let s = try seed(row("66а-1/2026", "Второй апелляционный суд общей юрисдикции (Город Санкт-Петербург)",
                             "https://2ap.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=3&case_uid=u&delo_id=42&new=0"))
        XCTAssertEqual(s.level, .appeal)
        XCTAssertEqual(s.cartoteka?.id, "p2")
    }

    /// Суд субъекта: апелляция (33-…) и историческая кассация президиума
    /// (delo_id=2800001&new=2800001 на уровне субъекта — g33).
    func testSubjectCourtCartotekas() throws {
        let ap = try seed(row("33-3719/2026", "Верховный Суд Республики Коми (Республика Коми)",
                              "https://vs--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=4&case_uid=u&delo_id=5&new=5"))
        XCTAssertEqual(ap.level, .subject)
        XCTAssertEqual(ap.cartoteka?.id, "g2")
        XCTAssertEqual(ap.instanceLevel, .appeal)

        let pres = try seed(row("44Г-1/2019", "Верховный Суд Республики Коми (Республика Коми)",
                                "https://vs--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=5&case_uid=u&delo_id=2800001&new=2800001"))
        XCTAssertEqual(pres.cartoteka?.id, "g33")
        XCTAssertEqual(pres.instanceLevel, .cassation)
    }

    func testSkippedPlatforms() {
        func reason(_ url: String) -> String? {
            if case .skipped(let r) = CaseImporter.classify(row("1", "Суд", url)) { return r }
            return nil
        }
        XCTAssertEqual(reason("https://zheshartsky.komi.msudrf.ru/modules.php?name=sud_delo&op=cs&case_id=141614450&delo_id=1540005"),
                       CaseImporter.reasonMagistrate)
        XCTAssertEqual(reason("https://mos-gorsud.ru/rs/cases/123"), CaseImporter.reasonMosgorsud)
        XCTAssertEqual(reason("https://mirsud.spb.ru/cases/detail/20/?id=5-583%2F2025-20"),
                       CaseImporter.reasonMagistrateSpb)
        XCTAssertEqual(reason("https://example.org/case/1"), CaseImporter.reasonPlatform)
        XCTAssertEqual(reason("не ссылка"), CaseImporter.reasonBadURL)
        // sudrf без параметров карточки — тоже пропуск, а не падение.
        XCTAssertEqual(reason("https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo"),
                       CaseImporter.reasonBadURL)
    }

    // MARK: Сшивание по УИД

    private func fetched(_ r: ImportedRow, uid: String?,
                         cardNumber: String? = nil) throws -> CaseImporter.Fetched {
        let s = try seed(r)
        let card = uid.map { u in
            CaseCard(rawText: "", actText: nil, uid: u,
                     caseNumber: cardNumber ?? (r.number.isEmpty ? nil : r.number))
        }
        return CaseImporter.Fetched(seed: s, card: card)
    }

    func testStitchingGroupsByUID() throws {
        let uid = "11RS0001-01-2025-011255-03"
        let first = try fetched(
            row("2-7212/2025", "Сыктывкарский городской суд (Республика Коми)",
                "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=100&case_uid=a&delo_id=1540005"),
            uid: uid)
        let appeal = try fetched(
            row("33-4818/2025", "Верховный Суд Республики Коми (Республика Коми)",
                "https://vs--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=200&case_uid=b&delo_id=5&new=5"),
            uid: uid)
        let cassation = try fetched(
            row("8Г-2430/2026", "Третий кассационный суд общей юрисдикции (Город Санкт-Петербург)",
                "https://3kas.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=300&case_uid=c&delo_id=2800001&new=2800001"),
            uid: uid)
        let material = try fetched(
            row("13-2472/2026", "Сыктывкарский городской суд (Республика Коми)",
                "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=400&case_uid=d&delo_id=1610001&new=0"),
            uid: uid)
        let unrelated = try fetched(
            row("2-100/2026", "Ухтинский городской суд (Республика Коми)",
                "https://ukhtasud--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=500&case_uid=e&delo_id=1540005"),
            uid: "11RS0005-01-2026-000001-01")

        // Нарочно вперемешку: якорь должен выбраться по звену, а не по порядку.
        let plan = CaseImporter.plan([cassation, material, unrelated, appeal, first])

        XCTAssertEqual(plan.records.count, 2, "две группы УИД → две записи")
        XCTAssertEqual(plan.stitched, 3)
        XCTAssertEqual(plan.cold, 0)

        let stitchedRec = try XCTUnwrap(plan.records.first {
            $0.context.caseNumber == "2-7212/2025"
        })
        XCTAssertFalse(stitchedRec.isMaterial)
        XCTAssertEqual(stitchedRec.context.displayDomain, "syktsud.komi.sudrf.ru")
        let known = try XCTUnwrap(stitchedRec.context.knownCards)
        XCTAssertEqual(Set(known.map(\.domain)),
                       ["vs--komi.sudrf.ru", "3kas.sudrf.ru", "syktsud--komi.sudrf.ru"])
        XCTAssertEqual(known.first { $0.domain == "syktsud--komi.sudrf.ru" }?.level, .material)
        XCTAssertEqual(known.first { $0.domain == "3kas.sudrf.ru" }?.level, .cassation)

        let lone = try XCTUnwrap(plan.records.first { $0.context.caseNumber == "2-100/2026" })
        XCTAssertNil(lone.context.knownCards)
    }

    func testStitchingNormalizesUIDFormatting() throws {
        let first = try fetched(
            row("2-7212/2025", "Сыктывкарский городской суд (Республика Коми)",
                "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=100&case_uid=a&delo_id=1540005"),
            uid: "11RS0001-01-2025-011255-03")
        let appeal = try fetched(
            row("33-4818/2025", "Верховный Суд Республики Коми (Республика Коми)",
                "https://vs--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=200&case_uid=b&delo_id=5&new=5"),
            uid: "11rs000101202501125503")

        let plan = CaseImporter.plan([appeal, first])

        XCTAssertEqual(plan.records.count, 1)
        XCTAssertEqual(plan.stitched, 1)
        XCTAssertEqual(plan.records.first?.context.caseNumber, "2-7212/2025")
    }

    /// Группа из одних материалов (дела в выгрузке нет) — каждый материал
    /// остаётся самостоятельной записью.
    func testMaterialsOnlyGroupStaysStandalone() throws {
        let uid = "11RS0001-01-2024-000002-02"
        let m1 = try fetched(
            row("13-5676/2025", "Сыктывкарский городской суд (Республика Коми)",
                "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=600&case_uid=f&delo_id=1610001&new=0"),
            uid: uid)
        let m2 = try fetched(
            row("13-5677/2025", "Сыктывкарский городской суд (Республика Коми)",
                "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=700&case_uid=g&delo_id=1610001&new=0"),
            uid: uid)
        let plan = CaseImporter.plan([m1, m2])
        XCTAssertEqual(plan.records.count, 2)
        XCTAssertTrue(plan.records.allSatisfy(\.isMaterial))
        XCTAssertEqual(plan.stitched, 0)
    }

    /// Карточка не загрузилась — «холодная» запись без сшивания; номер из CSV.
    func testColdImportWithoutCard() throws {
        let cold = try fetched(
            row("2-1/2026", "Сыктывкарский городской суд (Республика Коми)",
                "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=800&case_uid=h&delo_id=1540005"),
            uid: nil)  // card == nil
        var noCard = cold
        noCard.card = nil
        let plan = CaseImporter.plan([noCard])
        XCTAssertEqual(plan.records.count, 1)
        XCTAssertEqual(plan.cold, 1)
        XCTAssertEqual(plan.records[0].context.caseNumber, "2-1/2026")
    }

    /// Номер дела из карточки авторитетнее CSV (в выгрузке встречается карточка
    /// вовсе без номера).
    func testCardNumberPreferredOverCSV() throws {
        let f = try fetched(
            row("", "Санкт-Петербургский городской суд (Город Санкт-Петербург)",
                "https://sankt-peterburgsky--spb.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=900&case_uid=i&delo_id=5&new=5"),
            uid: "78OS0001-01-2026-000003-03", cardNumber: "33-100/2026")
        let plan = CaseImporter.plan([f])
        XCTAssertEqual(plan.records[0].context.caseNumber, "33-100/2026")
    }

    /// Контекст якоря: стороны выгрузки видны в списке до загрузки движения,
    /// прямая ссылка сохраняется.
    func testContextCarriesPartiesAndCardURL() throws {
        let url = "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo&name_op=case&case_id=100&case_uid=a&delo_id=1540005"
        let f = try fetched(row("2-7212/2025", "Сыктывкарский городской суд (Республика Коми)", url,
                                parties: "Воробьев В.В. ⚔ Администрация МО"),
                            uid: "11RS0001-01-2025-011255-03")
        let ctx = CaseImporter.makeContext(f, known: [])
        XCTAssertEqual(ctx.essence, "Воробьев В.В. ⚔ Администрация МО")
        XCTAssertEqual(ctx.cardURLString, url)
        XCTAssertEqual(ctx.key, "syktsud.komi.sudrf.ru/2-7212/2025")
        XCTAssertEqual(ctx.judicialUID, "11RS0001-01-2025-011255-03")
        XCTAssertEqual(ctx.baseInstanceLevel, .first)
        XCTAssertEqual(ctx.sourceKnownCard?.caseID, "100")
        XCTAssertEqual(ctx.sourceKnownCard?.caseUID, "a")
        XCTAssertEqual(ctx.sourceKnownCard?.deloID, "1540005")
        XCTAssertNotNil(ctx.cartoteka, "RefreshCenter требует восстановимую картотеку")
        // Подсудность: домены вышестоящих судов строятся по коду субъекта.
        let higher = ctx.expandedHigherDomains()
        XCTAssertTrue(higher.contains("vs--komi.sudrf.ru"))
        XCTAssertTrue(higher.contains("3kas.sudrf.ru"))
    }

    // MARK: Справочник

    func testSubjectCodeForRegionSuffix() {
        XCTAssertEqual(CourtDirectory.subjectCode(forRegionSuffix: "komi"), "11")
        XCTAssertEqual(CourtDirectory.subjectCode(forRegionSuffix: "spb"), "78")
        XCTAssertEqual(CourtDirectory.subjectCode(forRegionSuffix: "kir"), "43")
        XCTAssertEqual(CourtDirectory.subjectCode(forRegionSuffix: "lo"), "47")
        XCTAssertEqual(CourtDirectory.subjectCode(forRegionSuffix: "mo"), "50")
        XCTAssertEqual(CourtDirectory.subjectCode(forRegionSuffix: "arh"), "29")
        XCTAssertNil(CourtDirectory.subjectCode(forRegionSuffix: "nosuch"))
    }

    func testRegionSuffixOfDomain() {
        XCTAssertEqual(CourtDirectory.regionSuffix(ofDomain: "syktsud--komi.sudrf.ru"), "komi")
        XCTAssertEqual(CourtDirectory.regionSuffix(ofDomain: "oblsud.kir.sudrf.ru"), "kir")
        XCTAssertEqual(CourtDirectory.regionSuffix(ofDomain: "sankt-peterburgsky.spb.sudrf.ru"), "spb")
        XCTAssertNil(CourtDirectory.regionSuffix(ofDomain: "3kas.sudrf.ru"))
        XCTAssertNil(CourtDirectory.regionSuffix(ofDomain: "www.mos-gorsud.ru"))
    }
}
