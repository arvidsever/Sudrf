import XCTest
@testable import SudrfKit

final class CourtNamePresentationTests: XCTestCase {

    // MARK: - VNKODCourts.json: все 101 суда должны распознаваться

    func testAllVNKODCourtsAreRecognisedAndIdempotent() throws {
        let url = try XCTUnwrap(PackagedResource.url("VNKODCourts", withExtension: "json"))
        let data = try Data(contentsOf: url)
        struct Entry: Decodable { let title: String }
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        XCTAssertEqual(entries.count, 101)
        for e in entries {
            let d = CourtNamePresentation.display(e.title)
            XCTAssertNotNil(d.tier, "не распознан: \(e.title)")
            XCTAssertFalse(d.short.isEmpty, "пустой short: \(e.title)")
            XCTAssertLessThan(d.short.count, e.title.count, "short не короче: \(e.title)")
            let again = CourtNamePresentation.display(d.short)
            XCTAssertEqual(again.short, d.short, "неидемпотентно: \(e.title)")
            XCTAssertEqual(again.tier, d.tier, "неидемпотентно (tier): \(e.title)")
        }
    }

    // MARK: - АСОЮ / КСОЮ (1..9) из CourtDirectory

    func testAppealAndCassationCourtsFromDirectory() {
        for court in CourtDirectory.appealCourts {
            let d = CourtNamePresentation.display(court.title)
            XCTAssertEqual(d.short, "\(court.number) АСОЮ", court.title)
            XCTAssertEqual(d.tier, .appeal, court.title)
        }
        for court in CourtDirectory.cassationCourts {
            let d = CourtNamePresentation.display(court.title)
            XCTAssertEqual(d.short, "\(court.number) КСОЮ", court.title)
            XCTAssertEqual(d.tier, .cassation, court.title)
        }
    }

    func testCassationShortAliasSpellingsConverge() {
        let spellings = [
            "Третий кассационный суд общей юрисдикции",
            "Третий кассационный суд",
            "Третий КСОЮ",
            "3 КСОЮ"
        ]
        let displays = spellings.map(CourtNamePresentation.display)
        for d in displays {
            XCTAssertEqual(d.short, "3 КСОЮ")
            XCTAssertEqual(d.tier, .cassation)
            XCTAssertEqual(d.key, displays[0].key)
        }
    }

    func testAppealShortAliasSpellingsConverge() {
        let d1 = CourtNamePresentation.display("Первый апелляционный суд")
        let d2 = CourtNamePresentation.display("1 АСОЮ")
        XCTAssertEqual(d1.short, "1 АСОЮ")
        XCTAssertEqual(d1.tier, .appeal)
        XCTAssertEqual(d1.key, d2.key)
    }

    // MARK: - Военные суды

    func testMilitaryAppealAndCassation() {
        let ap = CourtNamePresentation.display("Апелляционный военный суд")
        XCTAssertEqual(ap.short, "АВС")
        XCTAssertEqual(ap.tier, .appeal)
        XCTAssertEqual(CourtNamePresentation.display("АВС").tier, .appeal)

        let kas = CourtNamePresentation.display("Кассационный военный суд")
        XCTAssertEqual(kas.short, "КВС")
        XCTAssertEqual(kas.tier, .cassation)
        XCTAssertEqual(CourtNamePresentation.display("КВС").tier, .cassation)
    }

    func testOkrugAndFleetMilitaryCourts() {
        let d = CourtNamePresentation.display("Балтийский флотский военный суд")
        XCTAssertEqual(d.short, "Балтийский ОВС")
        XCTAssertEqual(d.tier, .subject)
        // идемпотентность
        let again = CourtNamePresentation.display(d.short)
        XCTAssertEqual(again.short, d.short)
        XCTAssertEqual(again.tier, .subject)

        let d2 = CourtNamePresentation.display("Южный окружной военный суд")
        XCTAssertEqual(d2.short, "Южный ОВС")
        XCTAssertEqual(d2.tier, .subject)
    }

    func testGarrisonMilitaryCourt() {
        let d = CourtNamePresentation.display("Сыктывкарский гарнизонный военный суд")
        XCTAssertEqual(d.short, "Сыктывкарский ГВС")
        XCTAssertEqual(d.tier, .district)
        let again = CourtNamePresentation.display(d.short)
        XCTAssertEqual(again.short, d.short)
        XCTAssertEqual(again.tier, .district)
    }

    // MARK: - ВС РФ

    func testSupremeCourt() {
        for s in ["Верховный Суд Российской Федерации", "Верховный суд РФ", "ВС РФ"] {
            let d = CourtNamePresentation.display(s)
            XCTAssertEqual(d.short, "ВС РФ", s)
            XCTAssertEqual(d.tier, .supreme, s)
        }
    }

    // MARK: - Верховные суды республик

    func testSupremeRepublicCourtsConverge() {
        let spellings = [
            "Верховный Суд Республики Коми",
            "Верховный суд Республики Коми",
            "ВС Коми"
        ]
        let displays = spellings.map(CourtNamePresentation.display)
        for d in displays {
            XCTAssertEqual(d.short, "ВС Коми")
            XCTAssertEqual(d.tier, .subject)
            XCTAssertEqual(d.key, displays[0].key)
        }
    }

    func testSupremeRepublicOddGenitiveForms() {
        let chuvash = CourtNamePresentation.display("Верховный Суд Чувашской Республики")
        XCTAssertEqual(chuvash.short, "ВС Чувашской Республики")
        XCTAssertEqual(chuvash.tier, .subject)

        let kbr = CourtNamePresentation.display("Верховный Суд Кабардино-Балкарской Республики")
        XCTAssertEqual(kbr.short, "ВС Кабардино-Балкарской Республики")
        XCTAssertEqual(kbr.tier, .subject)

        let saha = CourtNamePresentation.display("Верховный Суд Республики Саха (Якутия)")
        XCTAssertEqual(saha.short, "ВС Саха (Якутия)")
        XCTAssertEqual(saha.tier, .subject)
    }

    // MARK: - Мировые судьи

    func testMagistrateCourt() {
        for s in ["Судебный участок № 3", "Мировой судья судебного участка № 3", "Мировой, уч. 3"] {
            let d = CourtNamePresentation.display(s)
            XCTAssertEqual(d.short, "Мировой, уч. 3", s)
            XCTAssertEqual(d.tier, .magistrate, s)
        }
    }

    // MARK: - Города федерального значения

    func testFederalCityCourtsAreSubjectTier() {
        let moscow = CourtNamePresentation.display("Московский городской суд")
        XCTAssertEqual(moscow.short, "Московский горсуд")
        XCTAssertEqual(moscow.tier, .subject)

        let alias = CourtNamePresentation.display("Мосгорсуд")
        XCTAssertEqual(alias.short, "Московский горсуд")
        XCTAssertEqual(alias.tier, .subject)
        XCTAssertEqual(alias.key, moscow.key)

        let spb = CourtNamePresentation.display("Санкт-Петербургский городской суд")
        XCTAssertEqual(spb.short, "Санкт-Петербургский горсуд")
        XCTAssertEqual(spb.tier, .subject)

        let sev = CourtNamePresentation.display("Севастопольский городской суд")
        XCTAssertEqual(sev.short, "Севастопольский горсуд")
        XCTAssertEqual(sev.tier, .subject)
    }

    // MARK: - Областные / краевые / АО

    func testRegionalCourts() {
        let obl = CourtNamePresentation.display("Амурский областной суд")
        XCTAssertEqual(obl.short, "Амурский облсуд")
        XCTAssertEqual(obl.tier, .subject)
        XCTAssertEqual(CourtNamePresentation.display(obl.short).short, obl.short)

        let kray = CourtNamePresentation.display("Алтайский краевой суд")
        XCTAssertEqual(kray.short, "Алтайский крайсуд")
        XCTAssertEqual(kray.tier, .subject)
        XCTAssertEqual(CourtNamePresentation.display(kray.short).short, kray.short)

        let ao = CourtNamePresentation.display("Суд Ханты-Мансийского автономного округа - Югры")
        XCTAssertEqual(ao.short, "Суд Ханты-Мансийского АО")
        XCTAssertEqual(ao.tier, .subject)
        XCTAssertEqual(CourtNamePresentation.display(ao.short).short, ao.short)

        let eao = CourtNamePresentation.display("Суд Еврейской автономной области")
        XCTAssertEqual(eao.short, "Суд Еврейской АО")
        XCTAssertEqual(eao.tier, .subject)
    }

    // MARK: - Районные / городские суды: сходимость написаний одного суда

    func testSyktyvkarskiySpellingsConverge() {
        let spellings = [
            "Сыктывкарский городской суд",
            "Сыктывкарский городской суд Республики Коми",
            "Сыктывкарский городской суд (Республика Коми)",
            "Сыктывкарский горсуд"
        ]
        let displays = spellings.map(CourtNamePresentation.display)
        for d in displays {
            XCTAssertEqual(d.short, "Сыктывкарский")
            XCTAssertEqual(d.tier, .district)
            XCTAssertEqual(d.key, displays[0].key)
        }
    }

    func testBareAdjectiveIsTreatedAsDistrict() {
        // Требование идемпотентности (все 101 суда VNKODCourts.json дают
        // короткое имя ровно такого вида) перевесило риск ложных срабатываний.
        let d = CourtNamePresentation.display("Сыктывкарский")
        XCTAssertEqual(d.tier, .district)
        XCTAssertEqual(d.short, "Сыктывкарский")
    }

    func testBareAdjectiveExcludesMirovoy() {
        // «Мировой» само по себе не суд — это только определение к «судье»/
        // «участку», распознаваемое отдельным правилом с номером участка.
        let d = CourtNamePresentation.display("Мировой")
        XCTAssertNil(d.tier)
    }

    func testDistrictCourtWithCityInsideRegionTail() {
        let d = CourtNamePresentation.display("Эжвинский районный суд г. Сыктывкара Республики Коми")
        XCTAssertEqual(d.short, "Эжвинский")
        XCTAssertEqual(d.tier, .district)
        XCTAssertEqual(d.locality, "г. Сыктывкара")
    }

    func testUnknownNameStaysAsIsWithNilTier() {
        let d = CourtNamePresentation.display("Какой-то неизвестный орган")
        XCTAssertEqual(d.short, "Какой-то неизвестный орган")
        XCTAssertNil(d.tier)
    }

    // MARK: - Коллизии одинаковых коротких имён

    func testCollisionsAreDisambiguatedWithLocality() {
        let raws = [
            "Центральный районный суд города Твери",
            "Центральный районный суд г. Барнаула"
        ]
        let map = CourtNamePresentation.disambiguatedShortNames(raws)
        XCTAssertEqual(map[raws[0]], "Центральный р/с г. Твери")
        XCTAssertEqual(map[raws[1]], "Центральный р/с г. Барнаула")
    }

    func testSameCourtTwoSpellingsIsNotTreatedAsCollision() {
        let raws = [
            "Сыктывкарский городской суд",
            "Сыктывкарский городской суд Республики Коми"
        ]
        let map = CourtNamePresentation.disambiguatedShortNames(raws)
        XCTAssertEqual(map[raws[0]], "Сыктывкарский")
        XCTAssertEqual(map[raws[1]], "Сыктывкарский")
    }

    // MARK: - canonicalKeys: бесхвостая запись того же суда не «коллизия»

    func testCanonicalKeysMergeCitylessVariantWithSingleCityInGroup() {
        let raws = [
            "Эжвинский районный суд г. Сыктывкара Республики Коми",
            "Эжвинский районный суд"
        ]
        let keys = CourtNamePresentation.canonicalKeys(raws)
        XCTAssertEqual(keys[raws[0]], keys[raws[1]])

        let map = CourtNamePresentation.disambiguatedShortNames(raws)
        XCTAssertEqual(map[raws[0]], "Эжвинский")
        XCTAssertEqual(map[raws[1]], "Эжвинский")
    }

    func testCanonicalKeysKeepCitylessVariantSeparateWhenTwoCitiesCollide() {
        let raws = [
            "Центральный районный суд города Твери",
            "Центральный районный суд г. Барнаула",
            "Центральный районный суд"
        ]
        let keys = CourtNamePresentation.canonicalKeys(raws)
        // Двух городов достаточно, чтобы не гадать, к какому из них
        // относится безхвостая запись — она остаётся при своём ключе.
        XCTAssertNotEqual(keys[raws[0]], keys[raws[2]])
        XCTAssertNotEqual(keys[raws[1]], keys[raws[2]])
        XCTAssertNotEqual(keys[raws[0]], keys[raws[1]])

        let map = CourtNamePresentation.disambiguatedShortNames(raws)
        XCTAssertEqual(map[raws[0]], "Центральный р/с г. Твери")
        XCTAssertEqual(map[raws[1]], "Центральный р/с г. Барнаула")
        // Вид известен («районный» есть и здесь) и показывается всегда —
        // не хватает только города, поэтому «р/с» без локальности.
        XCTAssertEqual(map[raws[2]], "Центральный р/с")
    }

    func testCanonicalKeysStillMergeIdempotentSpellings() {
        let raws = [
            "Сыктывкарский городской суд",
            "Сыктывкарский городской суд Республики Коми",
            "Сыктывкарский горсуд"
        ]
        let keys = CourtNamePresentation.canonicalKeys(raws)
        XCTAssertEqual(Set(keys.values).count, 1)
    }

    // MARK: - Вид суда (р/с/г/с/м/с) — часть идентичности (defect #1)

    func testDistrictAndCityCourtsWithSameNameAreDifferentCourts() {
        let city = CourtNamePresentation.display("Благовещенский городской суд Амурской области")
        let district = CourtNamePresentation.display("Благовещенский районный суд Амурской области")
        XCTAssertNotEqual(city.key, district.key)

        let map = CourtNamePresentation.disambiguatedShortNames([city.full, district.full])
        XCTAssertEqual(map[city.full], "Благовещенский г/с")
        XCTAssertEqual(map[district.full], "Благовещенский р/с")
    }

    func testHorsudIdempotentWithGorodskoySud() {
        let a = CourtNamePresentation.display("Сыктывкарский горсуд")
        let b = CourtNamePresentation.display("Сыктывкарский городской суд")
        XCTAssertEqual(a.key, b.key)
    }

    func testBareShortMergesIntoTheSingleKindInTheGroup() {
        let raws = [
            "Благовещенский",
            "Благовещенский городской суд Амурской области"
        ]
        let keys = CourtNamePresentation.canonicalKeys(raws)
        XCTAssertEqual(keys[raws[0]], keys[raws[1]])
        let map = CourtNamePresentation.disambiguatedShortNames(raws)
        XCTAssertEqual(map[raws[0]], "Благовещенский")
        XCTAssertEqual(map[raws[1]], "Благовещенский")
    }

    func testCanonicalKeysDoNotMergeRegionTailedVariantIntoCityOne() {
        // Defect #4: региональный хвост — не «недосказанность», подменять
        // его городом другого суда нельзя.
        let raws = [
            "Центральный районный суд г. Барнаула",
            "Центральный районный суд Тверской области"
        ]
        let keys = CourtNamePresentation.canonicalKeys(raws)
        XCTAssertNotEqual(keys[raws[0]], keys[raws[1]])
    }

    // MARK: - Мировые участки: хвост входит в идентичность (defect #2)

    func testMagistrateSectionsInDifferentDistrictsHaveDifferentKeys() {
        let a = CourtNamePresentation.display(
            "Судебный участок № 1 Эжвинского судебного района г. Сыктывкара")
        let b = CourtNamePresentation.display(
            "Мировой судья судебного участка № 1 Сыктывкарского судебного района")
        XCTAssertEqual(a.tier, .magistrate)
        XCTAssertEqual(b.tier, .magistrate)
        XCTAssertNotEqual(a.key, b.key)

        let map = CourtNamePresentation.disambiguatedShortNames([a.full, b.full])
        XCTAssertEqual(map[a.full], "Мировой, уч. 1 Эжвинского судебного района г. Сыктывкара")
        XCTAssertEqual(map[b.full], "Мировой, уч. 1 Сыктывкарского судебного района")
    }

    // MARK: - ё/е свёрнуты и в ключе (defect #3)

    func testYoYeFoldedInKey() {
        let a = CourtNamePresentation.display("Семёновский районный суд")
        let b = CourtNamePresentation.display("Семеновский районный суд")
        XCTAssertEqual(a.key, b.key)
    }

    // MARK: - Хвост в скобках не должен ломать распознавание (defect #6)

    func testParenthesisedTailsDoNotBreakRecognition() {
        let garrison = CourtNamePresentation.display("224 гарнизонный военный суд (Город Санкт-Петербург)")
        XCTAssertEqual(garrison.tier, .district)
        XCTAssertEqual(garrison.short, "224 ГВС")

        let spbCity = CourtNamePresentation.display("Санкт-Петербургский городской суд (г. Санкт-Петербург)")
        XCTAssertEqual(spbCity.tier, .subject)
        XCTAssertEqual(spbCity.short, "Санкт-Петербургский горсуд")

        let kas = CourtNamePresentation.display("Третий кассационный суд общей юрисдикции (г. Санкт-Петербург)")
        XCTAssertEqual(kas.tier, .cassation)
        XCTAssertEqual(kas.short, "3 КСОЮ")

        // «Республика Саха (Якутия)» — скобки часть самого названия региона,
        // а не постороннего хвоста, и должны сохраняться (не регрессия).
        let saha = CourtNamePresentation.display("Верховный Суд Республики Саха (Якутия)")
        XCTAssertEqual(saha.short, "ВС Саха (Якутия)")
    }

    func testAllCourtDirectoryTitlesAreRecognised() {
        var titles: [String] = []
        titles += CourtDirectory.subjectCourts.map(\.title)
        titles += CourtDirectory.cassationCourts.map(\.title)
        titles += CourtDirectory.appealCourts.map(\.title)
        titles += CourtDirectory.okrugMilitaryCourts.map(\.title)
        titles += [CourtDirectory.appellateMilitaryCourt.title, CourtDirectory.cassationMilitaryCourt.title]

        for title in titles {
            let d = CourtNamePresentation.display(title)
            XCTAssertNotNil(d.tier, "не распознан: \(title)")
        }
    }

    // MARK: - Латинские двойники (defect #7)

    func testLatinLookalikeLettersAreFolded() {
        // Реальная опечатка с портала: латинская C вместо кириллической С.
        let latin = CourtNamePresentation.display("Верховный Cуд Республики Коми")
        let cyrillic = CourtNamePresentation.display("Верховный Суд Республики Коми")
        XCTAssertEqual(latin.tier, .subject)
        XCTAssertEqual(latin.short, cyrillic.short)
        XCTAssertEqual(latin.key, cyrillic.key)
    }

    // MARK: - «Верховный суд Коми» без слова «Республики» (defect #8)

    func testSupremeCourtWithoutRespubliki() {
        let d = CourtNamePresentation.display("Верховный суд Коми")
        XCTAssertEqual(d.short, "ВС Коми")
        XCTAssertEqual(d.tier, .subject)
    }

    // MARK: - Многословный город после «г.» (defect #9)

    func testMultiWordCityAfterGDot() {
        let d = CourtNamePresentation.display("Нижегородский районный суд г. Нижнего Новгорода")
        XCTAssertEqual(d.locality, "г. Нижнего Новгорода")
    }
}
