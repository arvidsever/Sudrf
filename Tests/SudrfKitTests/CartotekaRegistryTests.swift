import XCTest
@testable import SudrfKit

/// Маппинг картотек: наборы по звеньям, индексы номеров дел (номенклатура),
/// авто-подбор картотеки по номеру и согласованность с маршрутами обжалования.
final class CartotekaRegistryTests: XCTestCase {

    // MARK: Наборы по звеньям

    func testDistrictSetIncludesAppealOnMagistrates() {
        let ids = CartotekaRegistry.sets(for: .district).map(\.id)
        XCTAssertTrue(ids.contains("u2"), "апелляция на мировых: уголовные (10-)")
        XCTAssertTrue(ids.contains("g2"), "апелляция на мировых: гражданские (11-)")
        XCTAssertTrue(ids.contains("p2"), "апелляция на мировых: КАС (11а-)")
    }

    func testSubjectSetIncludesKASFirstInstance() {
        XCTAssertNotNil(CartotekaRegistry.find(level: .subject, id: "p1"),
                        "КАС 1-й инстанции в суде субъекта (3а-)")
    }

    func testAppealSOYuSetHasNoKoAP() {
        let ids = CartotekaRegistry.sets(for: .appeal).map(\.id)
        XCTAssertEqual(Set(ids), ["u2", "g2", "p2"],
                       "АСОЮ: только апелляция по УПК/ГПК/КАС, КоАП-производств нет")
    }

    func testCassationSOYuPlatformPairs() throws {
        // Канонические пары delo_id/new — из универсального JS-переключателя
        // видов производства (фикстура ksoy_cassation.html).
        let u3 = try XCTUnwrap(CartotekaRegistry.find(level: .cassation, id: "u3"))
        XCTAssertEqual([u3.deloID, u3.new, u3.deloTable], ["4", "2450001", "u33_case"])
        let g3 = try XCTUnwrap(CartotekaRegistry.find(level: .cassation, id: "g3"))
        XCTAssertEqual([g3.deloID, g3.new, g3.deloTable], ["5", "2800001", "g33_case"])
        let p3 = try XCTUnwrap(CartotekaRegistry.find(level: .cassation, id: "p3"))
        XCTAssertEqual([p3.deloID, p3.deloTable], ["43", "p33_case"])
        let adm3 = try XCTUnwrap(CartotekaRegistry.find(level: .cassation, id: "adm3"))
        XCTAssertEqual([adm3.deloID, adm3.deloTable], ["2550001", "adm33_case"])
    }

    func testIDsUniqueWithinEachLevel() {
        for level in CourtLevel.allCases {
            let ids = CartotekaRegistry.sets(for: level).map(\.id)
            XCTAssertEqual(ids.count, Set(ids).count, "дубль id в наборе \(level)")
        }
    }

    // MARK: Подбор картотеки по индексу номера дела

    private func single(_ number: String, _ level: CourtLevel) -> String? {
        let m = CartotekaRegistry.matches(caseNumber: number, level: level)
        return m.count == 1 ? m[0].id : nil
    }

    func testDistrictPrefixMatching() {
        XCTAssertEqual(single("1-15/2026", .district), "u1")
        XCTAssertEqual(single("10-3/2026", .district), "u2")     // не «1-»!
        XCTAssertEqual(single("2-7212/2025 ~ М-5922/2025", .district), "g1")
        XCTAssertEqual(single("М-5922/2025", .district), "g1")   // материал до принятия
        XCTAssertEqual(single("11-44/2026", .district), "g2")
        XCTAssertEqual(single("2а-3021/2023", .district), "p1")
        XCTAssertEqual(single("11а-12/2026", .district), "p2")   // не «11-» и не «1-»
        XCTAssertEqual(single("5-470/2026", .district), "adm")
        XCTAssertEqual(single("12-150/2025", .district), "admj")
        XCTAssertEqual(single("3/1-44/2026", .district), "m")
        XCTAssertEqual(single("4/17-9/2026", .district), "m")
        XCTAssertEqual(single("13-21/2026", .district), "m")
    }

    func testSubjectPrefixMatching() {
        XCTAssertEqual(single("2-5/2026", .subject), "u1")
        XCTAssertEqual(single("22-801/2026", .subject), "u2")
        XCTAssertEqual(single("22К-115/2026", .subject), "u2")
        XCTAssertEqual(single("3а-77/2026", .subject), "p1")
        XCTAssertEqual(single("33-4818/2025", .subject), "g2")
        XCTAssertEqual(single("33а-90/2026", .subject), "p2")
        XCTAssertEqual(single("44У-12/2019", .subject), "u33")
        XCTAssertEqual(single("4Га-8/2019", .subject), "p33")
        XCTAssertEqual(single("4а-321/2019", .subject), "adm33")
        // КоАП 2-я инстанция: «на постановления» — 12- (как в районе, но другой
        // суд); «на решения по жалобам» — региональная вариативность: 21-
        // (напр., Коми) либо 7- (напр., Санкт-Петербург).
        XCTAssertEqual(single("12-150/2025", .subject), "adm1")
        XCTAssertEqual(single("21-45/2026", .subject), "adm2")
        XCTAssertEqual(single("7-1042/2026", .subject), "adm2")
    }

    func testHigherLevelsPrefixMatching() {
        XCTAssertEqual(single("55-102/2026", .appeal), "u2")
        XCTAssertEqual(single("66-301/2026", .appeal), "g2")
        XCTAssertEqual(single("66а-14/2026", .appeal), "p2")
        XCTAssertEqual(single("77-1019/2026", .cassation), "u3")
        XCTAssertEqual(single("7У-1019/2026", .cassation), "u3")
        XCTAssertEqual(single("8Г-2430/2026", .cassation), "g3")
        XCTAssertEqual(single("88-21412/2026", .cassation), "g3")
        XCTAssertEqual(single("88а-330/2026", .cassation), "p3")
        XCTAssertEqual(single("16-2074/2026", .cassation), "adm3")
        XCTAssertEqual(single("П16-12/2026", .cassation), "adm3")
    }

    func testLatinLookalikesNormalized() {
        // Пользователи набирают латиницу: «2a-», «8g-», «7y-», «m-».
        XCTAssertEqual(single("2a-3021/2023", .district), "p1")
        XCTAssertEqual(single("8g-2430/2026", .cassation), "g3")
        XCTAssertEqual(single("7y-1019/2026", .cassation), "u3")
        XCTAssertEqual(single("m-5922/2025", .district), "g1")
    }

    func testPrefixMatchesGuard() throws {
        let p1 = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "p1"))
        XCTAssertTrue(CartotekaRegistry.prefixMatches(p1, caseNumber: "2а-1/2026"))
        XCTAssertFalse(CartotekaRegistry.prefixMatches(p1, caseNumber: "2-1/2026"))
        XCTAssertTrue(CartotekaRegistry.prefixMatches(p1, caseNumber: ""),
                      "пустой номер — судить не по чему, не переключаем")
    }

    // MARK: Маршруты обжалования согласованы с наборами

    func testHigherRouteIDsExistInTargetSets() {
        for base in CartotekaRegistry.sets(for: .district) {
            for level in [CourtLevel.subject, .appeal, .cassation] {
                let route = MovementService.higherCartotekaIDs(baseID: base.id, level: level)
                let available = Set(CartotekaRegistry.sets(for: level).map(\.id))
                for id in route {
                    XCTAssertTrue(available.contains(id),
                                  "маршрут \(base.id) → \(level): id «\(id)» нет в наборе")
                }
            }
        }
    }

    func testAppealOnMagistratesGoesStraightToKSOYu() {
        // Дела мировых судей: район (апелляция) → КСОЮ, минуя субъект и АСОЮ.
        for base in ["u2", "g2", "p2"] {
            XCTAssertEqual(MovementService.higherCartotekaIDs(baseID: base, level: .subject), [])
            XCTAssertEqual(MovementService.higherCartotekaIDs(baseID: base, level: .appeal), [])
        }
        XCTAssertEqual(MovementService.higherCartotekaIDs(baseID: "g2", level: .cassation), ["g3"])
        XCTAssertEqual(MovementService.higherCartotekaIDs(baseID: "u2", level: .cassation), ["u3"])
        XCTAssertEqual(MovementService.higherCartotekaIDs(baseID: "p2", level: .cassation), ["p3"])
    }

    func testKoAPRoutes() {
        XCTAssertEqual(MovementService.higherCartotekaIDs(baseID: "adm", level: .subject), ["adm1"])
        XCTAssertEqual(MovementService.higherCartotekaIDs(baseID: "admj", level: .subject), ["adm2"])
        XCTAssertEqual(MovementService.higherCartotekaIDs(baseID: "adm", level: .cassation), ["adm3"])
        XCTAssertEqual(MovementService.higherCartotekaIDs(baseID: "admj", level: .cassation), ["adm3"])
        // КоАП в АСОЮ не рассматривается.
        XCTAssertEqual(MovementService.higherCartotekaIDs(baseID: "adm", level: .appeal), [])
    }
}
