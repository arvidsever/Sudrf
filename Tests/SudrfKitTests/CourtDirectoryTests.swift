import XCTest
@testable import SudrfKit

final class CourtDirectoryTests: XCTestCase {

    func testCountsParsed() {
        XCTAssertEqual(CourtDirectory.cassationCourts.count, 9)
        XCTAssertEqual(CourtDirectory.appealCourts.count, 5)
        XCTAssertGreaterThan(CourtDirectory.subjectCourts.count, 80)
    }

    func testKomiRouting() {
        XCTAssertEqual(CourtDirectory.cassationCourt(forRegion: "Коми")?.domain, "3kas.sudrf.ru")
        XCTAssertEqual(CourtDirectory.appealCourt(forRegion: "Коми")?.domain, "2ap.sudrf.ru")
    }

    func testSpbRouting() {
        XCTAssertEqual(CourtDirectory.cassationCourt(forRegion: "Санкт-Петербург")?.number, 3)
        XCTAssertEqual(CourtDirectory.appealCourt(forRegion: "Санкт-Петербург")?.number, 2)
    }

    func testMoscowCassation() {
        XCTAssertEqual(CourtDirectory.cassationCourt(forRegion: "город Москва")?.number, 2)
    }

    func testCassationRoutingDistinguishesNenetsAutonomousOkrugs() {
        XCTAssertEqual(CourtDirectory.cassationCourt(
            forRegion: "Ямало-Ненецкий автономный округ")?.number, 7)
        XCTAssertEqual(CourtDirectory.cassationCourt(
            forRegion: "Ненецкий автономный округ")?.number, 3)
        XCTAssertEqual(CourtDirectory.cassationCourt(
            forRegion: "Сахалинская область")?.number, 9)
        XCTAssertEqual(CourtDirectory.cassationCourt(
            forRegion: "Республика Саха (Якутия)")?.number, 9)
    }

    func testSubjectLookup() {
        // v5: модульные страницы судов субъектов живут на хосте с двойным тире.
        XCTAssertEqual(CourtDirectory.subjectCourt(matching: "Коми")?.domain, "vs--komi.sudrf.ru")
    }

    func testCourtForDomain() {
        let c = CourtDirectory.court(forDomain: "https://3kas.sudrf.ru/")
        XCTAssertEqual(c?.level, .cassation)
        XCTAssertEqual(c?.domain, "3kas.sudrf.ru")
    }

    func testMSudrfHostPredicateRequiresExactOrDottedHost() {
        XCTAssertTrue(SudrfHost.isMSudrfHost("msudrf.ru"))
        XCTAssertTrue(SudrfHost.isMSudrfHost("pervomaysky.komi.msudrf.ru"))
        XCTAssertFalse(SudrfHost.isMSudrfHost("xmsudrf.ru"))
    }

    func testTerritorialCourtToCourt() {
        let k = CourtDirectory.cassationCourts.first { $0.number == 3 }!
        XCTAssertEqual(k.court.level, .cassation)
    }
}

// MARK: - Ветви и звенья (v12)

extension CourtDirectoryTests {

    func testSubjectCourtForRegion() {
        XCTAssertEqual(CourtDirectory.subjectCourt(forRegion: "Республика Коми")?.domain,
                       "vs--komi.sudrf.ru")
        // Алиасы городов федерального значения работают и тут.
        XCTAssertEqual(CourtDirectory.subjectCourt(forRegion: "город Москва")?.domain,
                       "www.mos-gorsud.ru")
        XCTAssertEqual(CourtDirectory.subjectCourt(forRegion: "город Москва")?.isSudrfPlatform,
                       false, "Мосгорсуд — вне платформы sudrf")
    }

    func testCourtTierLevels() {
        XCTAssertNil(CourtTier.supreme.level, "ВС РФ — вне платформы sud_delo")
        XCTAssertEqual(CourtTier.cassation.level, .cassation)
        XCTAssertEqual(CourtTier.appeal.level, .appeal)
        XCTAssertEqual(CourtTier.subject.level, .subject)
        XCTAssertEqual(CourtTier.district.level, .district)
        XCTAssertEqual(CourtTier.magistrate.level, .magistrate)
        // Порядок в пикере — сверху вниз, от ВС РФ к мировым.
        XCTAssertEqual(CourtTier.allCases.first, .supreme)
        XCTAssertEqual(CourtTier.allCases.last, .magistrate)
        XCTAssertFalse(CourtTier.cases(for: .military).contains(.magistrate))
    }

    func testDistrictCourtCodeLetters() {
        func court(_ code: String?) -> DistrictCourt {
            DistrictCourt(title: "т", domain: "d", code: code, regionCode: nil,
                          kind: code.map { CourtKind(classificationCode: $0) } ?? .district)
        }
        XCTAssertEqual(court("11RS0001").codeLetters, "RS")
        XCTAssertEqual(court("54GV0011").codeLetters, "GV")
        XCTAssertEqual(court("50AV0001").codeLetters, "AV")
        XCTAssertNil(court(nil).codeLetters)
    }
}

// MARK: - Подсудность по региональным кодам (v12.4)

extension CourtDirectoryTests {
    func testJurisdictionBySubjectCode() {
        XCTAssertEqual(CourtDirectory.cassationCourt(forSubjectCode: "11")?.number, 3)
        XCTAssertEqual(CourtDirectory.appealCourt(forSubjectCode: "11")?.number, 2)
        XCTAssertEqual(CourtDirectory.cassationCourt(forSubjectCode: "66")?.number, 7)
        XCTAssertEqual(CourtDirectory.cassationCourt(forSubjectCode: "77")?.number, 2)   // Москва
        XCTAssertEqual(CourtDirectory.cassationCourt(forSubjectCode: "50")?.number, 1)   // Московская обл.
        XCTAssertEqual(CourtDirectory.cassationCourt(forSubjectCode: "78")?.number, 3)   // СПб
        // Код принимается и в виде полного классификационного кода суда.
        XCTAssertEqual(CourtDirectory.cassationCourt(forSubjectCode: "78RS0015")?.number, 3)
        XCTAssertEqual(CourtDirectory.appealCourt(forSubjectCode: "02")?.number, 5)      // Республика Алтай
        XCTAssertEqual(CourtDirectory.cassationCourt(forSubjectCode: "22")?.number, 8)   // Алтайский край
    }

    func testSubjectCourtBySubjectCode() {
        XCTAssertEqual(CourtDirectory.subjectCourt(forSubjectCode: "11")?.domain, "vs--komi.sudrf.ru")
        XCTAssertEqual(CourtDirectory.subjectCourt(forSubjectCode: "02")?.domain, "vs.ralt.sudrf.ru")
        XCTAssertEqual(CourtDirectory.subjectCourt(forSubjectCode: "22")?.domain, "kraevoy.alt.sudrf.ru")
        XCTAssertEqual(CourtDirectory.subjectCourt(forSubjectCode: "50")?.domain, "oblsud.mo.sudrf.ru")
        XCTAssertEqual(CourtDirectory.subjectCourt(forSubjectCode: "77")?.domain, "www.mos-gorsud.ru")
        // Обратная таблица: домен → код.
        XCTAssertEqual(CourtDirectory.subjectCode(forDomain: "oblsud.svd.sudrf.ru"), "66")
        XCTAssertEqual(CourtDirectory.subjectCode(forDomain: "https://vs--komi.sudrf.ru/"), "11")
    }

    func testNormalizedSubjectCode() {
        XCTAssertEqual(CourtDirectory.normalizedSubjectCode("11RS0001"), "11")
        XCTAssertEqual(CourtDirectory.normalizedSubjectCode("7"), "07")
        XCTAssertEqual(CourtDirectory.normalizedSubjectCode("78"), "78")
    }

    func testMilitaryUpperTiersHardcoded() {
        // Ст. 1 466-ФЗ: 9 окружных (флотских) военных судов — 1-й/2-й Западные,
        // 1-й/2-й Восточные, Центральный, Южный + Балтийский, Северный,
        // Тихоокеанский флотские.
        XCTAssertEqual(CourtDirectory.okrugMilitaryCourts.count, 9)
        XCTAssertEqual(Set(CourtDirectory.okrugMilitaryCourts.map(\.domain)).count, 9)
        XCTAssertTrue(CourtDirectory.okrugMilitaryCourts
            .contains { $0.domain == "1zovs.spb.sudrf.ru" }, "живьём подтверждённый домен")
        XCTAssertEqual(CourtDirectory.appellateMilitaryCourt.level, .appeal)
        XCTAssertEqual(CourtDirectory.cassationMilitaryCourt.level, .cassation)
    }

    func testEveryRegionCodeHasCassationAndAppeal() {
        // Каждый код, у которого есть суд субъекта, обязан иметь КСОЮ и АСОЮ.
        for code in CourtDirectory.subjectCourtDomainByCode.keys {
            XCTAssertNotNil(CourtDirectory.cassationCourt(forSubjectCode: code), "нет КСОЮ для \(code)")
            XCTAssertNotNil(CourtDirectory.appealCourt(forSubjectCode: code), "нет АСОЮ для \(code)")
        }
    }
}

// MARK: - Военная вертикаль и новые регионы (v12.5, из первоисточников)

extension CourtDirectoryTests {
    func testOkrugMilitaryCourtsAreNineAndLive() {
        XCTAssertEqual(CourtDirectory.okrugMilitaryCourts.count, 9,
                       "6 окружных + 3 флотских (живая выдача портала)")
        XCTAssertEqual(Set(CourtDirectory.okrugMilitaryCourts.map(\.domain)).count, 9)
        XCTAssertEqual(CourtDirectory.appellateMilitaryCourt.domain, "vap.sudrf.ru")
        XCTAssertEqual(CourtDirectory.cassationMilitaryCourt.domain, "vkas.sudrf.ru")
    }

    func testOkrugMilitaryJurisdictionBy345FZ() {
        // ст. 1 ФЗ от 27.12.2009 № 345-ФЗ (ред. 27.11.2023)
        XCTAssertEqual(CourtDirectory.okrugMilitaryCourt(forSubjectCode: "11")?.domain,
                       "1zovs.spb.sudrf.ru")                       // Коми → 1-й Западный
        XCTAssertEqual(CourtDirectory.okrugMilitaryCourt(forSubjectCode: "39")?.domain,
                       "baltovs.kln.sudrf.ru")                     // Калининград → Балтийский флотский
        // Внимание: по ГОЛОМУ коду 39 даётся Балтийский флотский — это фолбэк
        // для нераспознанных имён; для 224 ГВС правильный маршрут — по имени
        // (см. testGarrisonJurisdictionBy466FZ): его код врёт о юрисдикции.
        XCTAssertEqual(CourtDirectory.okrugMilitaryCourt(forSubjectCode: "77")?.domain,
                       "2zovs.msk.sudrf.ru")                       // Москва → 2-й Западный
        XCTAssertEqual(CourtDirectory.okrugMilitaryCourt(forSubjectCode: "93")?.domain,
                       "yovs.ros.sudrf.ru")                        // ДНР → Южный
        XCTAssertEqual(CourtDirectory.okrugMilitaryCourt(forSubjectCode: "87")?.domain,
                       "tihookeanskyfvs.prm.sudrf.ru")             // Чукотка → Тихоокеанский флотский
    }

    func testNewRegionsJurisdiction() {
        // 7-ФКЗ от 31.07.2023: новые субъекты — Второй КСОЮ и Первый АСОЮ.
        for code in ["90", "93", "94", "96"] {
            XCTAssertEqual(CourtDirectory.cassationCourt(forSubjectCode: code)?.number, 2)
            XCTAssertEqual(CourtDirectory.appealCourt(forSubjectCode: code)?.number, 1)
        }
    }

    func testEveryRegionCodeHasOkrugMilitary() {
        // Каждый код портальной таблицы (кроме служебных 95/97) накрыт ОВС.
        for (_, code) in CourtDirectory.subjectCodeTable where !["95", "97"].contains(code) {
            XCTAssertNotNil(CourtDirectory.okrugMilitaryCourt(forSubjectCode: code),
                            "код \(code) не накрыт юрисдикцией ОВС")
        }
    }
}


// MARK: - Подсудность гарнизонных судов (v12.6, ст. 1 466-ФЗ)

extension CourtDirectoryTests {
    func testGarrisonJurisdictionBy466FZ() {
        func okrug(_ title: String, code: String? = nil) -> String? {
            CourtDirectory.okrugMilitaryCourt(forGarrisonTitle: title, code: code)?.domain
        }
        // 224 ГВС: юрисдикция — часть СПб и Ленобласти → 1-й Западный,
        // несмотря на «калининградский» классификационный код.
        XCTAssertEqual(okrug("224 гарнизонный военный суд (Город Санкт-Петербург)",
                             code: "39GV0005"), "1zovs.spb.sudrf.ru")
        // Падежная устойчивость: формулировка из закона даёт тот же ключ.
        XCTAssertEqual(CourtDirectory.garrisonKey("224-го гарнизонного военного суда"),
                       CourtDirectory.garrisonKey("224 гарнизонный военный суд"))
        XCTAssertEqual(okrug("Санкт-Петербургский гарнизонный военный суд"), "1zovs.spb.sudrf.ru")
        XCTAssertEqual(okrug("Балтийский гарнизонный военный суд"), "baltovs.kln.sudrf.ru")
        XCTAssertEqual(okrug("Калининградский гарнизонный военный суд"), "baltovs.kln.sudrf.ru")
        XCTAssertEqual(okrug("Спасск-Дальнего гарнизонный военный суд"),
                       "tihookeanskyfvs.prm.sudrf.ru")
        XCTAssertEqual(okrug("Курильский гарнизонный военный суд"), "1vovs.hbr.sudrf.ru",
                       "Курилы — 1-й Восточный, не Тихоокеанский флотский (345-ФЗ)")
        XCTAssertEqual(okrug("Воркутинский гарнизонный военный суд"), "1zovs.spb.sudrf.ru")
        XCTAssertEqual(okrug("Донецкий гарнизонный военный суд"), "yovs.ros.sudrf.ru")
        XCTAssertEqual(okrug("235 гарнизонный военный суд (Город Москва)"), "2zovs.msk.sudrf.ru")
        // Фолбэк по коду — для имени вне карты.
        XCTAssertEqual(okrug("Новый гарнизонный военный суд", code: "54GV0099"),
                       "2vovs.cht.sudrf.ru")
    }

    func testGarrisonMapIsComplete() {
        // Не меньше статутных 98 (ст. 1 466-ФЗ); карта шире — в ней ещё
        // зарубежные ГВС, подведомственность которых закон не перечисляет.
        XCTAssertGreaterThanOrEqual(CourtDirectory.garrisonOkrugDomainByKey.count, 98,
                       "ст. 1 466-ФЗ: минимум 98 гарнизонных военных судов")
        let okrugDomains = Set(CourtDirectory.okrugMilitaryCourts.map(\.domain))
        for (key, domain) in CourtDirectory.garrisonOkrugDomainByKey {
            XCTAssertTrue(okrugDomains.contains(domain), "ключ \(key): домен \(domain) не из списка ОВС")
        }
    }

    func testSubjectCourtsPortalSync() {
        // Живая выгрузка портала: новые суды и переехавшие на платформу домены.
        XCTAssertEqual(CourtDirectory.subjectCourt(forSubjectCode: "92")?.domain, "gs.sev.sudrf.ru")
        XCTAssertEqual(CourtDirectory.subjectCourt(forSubjectCode: "93")?.domain, "vs.dnr.sudrf.ru")
        XCTAssertEqual(CourtDirectory.subjectCourt(forSubjectCode: "94")?.domain, "vs.lnr.sudrf.ru")
        XCTAssertEqual(CourtDirectory.subjectCourt(forSubjectCode: "90")?.domain, "oblsud.zpr.sudrf.ru")
        XCTAssertEqual(CourtDirectory.subjectCourt(forSubjectCode: "96")?.domain, "oblsud.hrs.sudrf.ru")
        XCTAssertEqual(CourtDirectory.subjectCourt(forSubjectCode: "58")?.domain, "oblsud.pnz.sudrf.ru")
        XCTAssertEqual(CourtDirectory.subjectCourt(forSubjectCode: "73")?.domain, "oblsud.uln.sudrf.ru")
        XCTAssertEqual(CourtDirectory.subjectCourt(forSubjectCode: "58")?.isSudrfPlatform, true,
                       "Пензенский областной переехал на платформу sudrf")
    }
}

// MARK: - Кодовая карта гарнизонных и дефисные домены (v12.7)

extension CourtDirectoryTests {
    func testGarrisonByFullCode() {
        // Полный классификационный код — первичный ключ: региональный
        // префикс врёт (живая выгрузка court_type=GV).
        XCTAssertEqual(CourtDirectory.okrugMilitaryCourt(
            forGarrisonTitle: "что угодно", code: "39GV0005")?.domain,
            "1zovs.spb.sudrf.ru", "224 ГВС: код «калининградский», округ — 1-й Западный")
        XCTAssertEqual(CourtDirectory.okrugMilitaryCourt(
            forGarrisonTitle: "что угодно", code: "77GV0013")?.domain,
            "2zovs.msk.sudrf.ru", "Ярославский ГВС: код «московский»")
        XCTAssertEqual(CourtDirectory.garrisonOkrugDomainByCode.count, 104,
                       "99 по РФ + 5 зарубежных")
    }

    func testForeignGarrisonsJurisdiction() {
        // Зарубежные ГВС (вне 466-ФЗ) — подведомственность от эксперта,
        // в кодовой и именной картах (фолбэк больше не нужен).
        func okrug(code: String?, title: String) -> String? {
            CourtDirectory.okrugMilitaryCourt(forGarrisonTitle: title, code: code)?.domain
        }
        XCTAssertEqual(okrug(code: "61GV0015", title: "5 гарнизонный военный суд"),
                       "yovs.ros.sudrf.ru", "Ереван → Южный")
        XCTAssertEqual(okrug(code: "31GV0014", title: "26 гарнизонный военный суд"),
                       "2zovs.msk.sudrf.ru", "Байконур → 2-й Западный")
        XCTAssertEqual(okrug(code: "31GV0015", title: "40 гарнизонный военный суд"),
                       "2zovs.msk.sudrf.ru", "Приозерск → 2-й Западный")
        XCTAssertEqual(okrug(code: "77GV0022", title: "80 гарнизонный военный суд"),
                       "2zovs.msk.sudrf.ru", "Тирасполь → 2-й Западный")
        XCTAssertEqual(okrug(code: "66GV0008", title: "109 гарнизонный военный суд"),
                       "covs.svd.sudrf.ru", "Душанбе → Центральный")
        // Лookup по одному имени (без кода) тоже работает.
        XCTAssertEqual(okrug(code: nil,
                             title: "26 гарнизонный военный суд (Территории за пределами РФ)"),
                       "2zovs.msk.sudrf.ru")
    }

    func testYaroslavlGarrisonRestored() {
        XCTAssertEqual(CourtDirectory.okrugMilitaryCourt(
            forGarrisonTitle: "Ярославский гарнизонный военный суд")?.domain,
            "2zovs.msk.sudrf.ru")
    }

    func testDashVariant() {
        XCTAssertEqual(CourtDirectory.dashVariant(of: "vs.komi.sudrf.ru"), "vs--komi.sudrf.ru")
        XCTAssertEqual(CourtDirectory.dashVariant(of: "sankt-peterburgsky.spb.sudrf.ru"),
                       "sankt-peterburgsky--spb.sudrf.ru")
        XCTAssertEqual(CourtDirectory.dashVariant(of: "nvs.spb.sudrf.ru"), "nvs--spb.sudrf.ru")
        XCTAssertNil(CourtDirectory.dashVariant(of: "3kas.sudrf.ru"), "односегментный — без варианта")
        XCTAssertNil(CourtDirectory.dashVariant(of: "vkas.sudrf.ru"))
        XCTAssertNil(CourtDirectory.dashVariant(of: "vs--komi.sudrf.ru"), "уже дефисный")
        XCTAssertNil(CourtDirectory.dashVariant(of: "nnoblsud.ru"), "вне платформы")
    }
}
