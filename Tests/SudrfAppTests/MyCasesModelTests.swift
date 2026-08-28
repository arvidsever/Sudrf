import XCTest
import Foundation
import SudrfKit
import SwiftData
@testable import SudrfApp

/// Модель редизайна «Моих дел» (v20): вид производства по номеру дела,
/// разделитель сторон «⚔», сортировка и живой фильтр таблицы «Списком».
final class MyCasesModelTests: XCTestCase {

    // MARK: Вид производства по префиксу номера

    func testProductionTypeByPrefix() {
        XCTAssertEqual(ProductionType.of("1-45/2026"), .crim)
        XCTAssertEqual(ProductionType.of("5-120/2026"), .koap)
        XCTAssertEqual(ProductionType.of("2а-77/2026"), .kas)
        XCTAssertEqual(ProductionType.of("3а-5/2026"), .kas)
        XCTAssertEqual(ProductionType.of("8а-1/2026"), .kas)
        XCTAssertEqual(ProductionType.of("33а-9/2026"), .kas)
        XCTAssertEqual(ProductionType.of("2-115/2026"), .civil)
        XCTAssertEqual(ProductionType.of("33-4/2026"), .civil)
        // Жалобы/кассация по КоАП и уголовная апелляция — раньше падали в civil.
        XCTAssertEqual(ProductionType.of("12-466/2026"), .koap)  // жалоба по делу об АП
        XCTAssertEqual(ProductionType.of("4а-321/2025"), .koap)  // кассация КоАП
        XCTAssertEqual(ProductionType.of("22-77/2026"), .crim)   // уголовная апелляция
        XCTAssertEqual(ProductionType.of("7у-15/2026"), .crim)   // кассация КСОЮ, не КоАП
    }

    func testProductionTypeUppercaseLetter() {
        // На портале встречается заглавная «А» в индексе.
        XCTAssertEqual(ProductionType.of("2А-77/2026"), .kas)
    }

    // MARK: Вид производства с учётом звена суда

    func testProductionTypeByCourtLevel() {
        // «2-…» неоднозначен без звена: район — гражданское, субъект — уголовное.
        XCTAssertEqual(ProductionType.of("2-1/2026", level: .district), .civil)
        XCTAssertEqual(ProductionType.of("2-1/2026", level: .subject), .crim)
        // «12-…» на районном звене — жалоба по делу об АП.
        XCTAssertEqual(ProductionType.of("12-5/2026", level: .district), .koap)
        // «33-…» суда субъекта — гражданская апелляция.
        XCTAssertEqual(ProductionType.of("33-9/2026", level: .subject), .civil)
    }

    func testProductionTypeFromCartotekaId() {
        XCTAssertEqual(ProductionType(cartotekaId: "u1"), .crim)
        XCTAssertEqual(ProductionType(cartotekaId: "u33"), .crim)
        XCTAssertEqual(ProductionType(cartotekaId: "g33"), .civil)
        XCTAssertEqual(ProductionType(cartotekaId: "m"), .civil)
        XCTAssertEqual(ProductionType(cartotekaId: "p2"), .kas)
        XCTAssertEqual(ProductionType(cartotekaId: "adm1"), .koap)
        XCTAssertEqual(ProductionType(cartotekaId: "admj"), .koap)
    }

    func testMaterialProductionUsesIndexClassifier() {
        XCTAssertEqual(ProductionType.classified(
            caseNumber: "3/12-31/2026", level: .district,
            branch: .general, cartotekaID: "m"), .crim)
        XCTAssertEqual(ProductionType.classified(
            caseNumber: "13-128/2025", level: .district,
            branch: .general, cartotekaID: "m"), .civil)
        XCTAssertEqual(ProductionType.classified(
            caseNumber: "13а-8/2025", level: .district,
            branch: .general, cartotekaID: "m"), .kas)
        XCTAssertEqual(ProductionType.classified(
            caseNumber: "ДА-4/2026", level: .district,
            branch: .military, cartotekaID: "m"), .koap)
    }

    func testUnknownMaterialsHaveNoProductionGroup() {
        XCTAssertNil(ProductionType.classified(
            caseNumber: "М-12/2026", level: .district,
            branch: .general, cartotekaID: "m"))
        XCTAssertNil(ProductionType.classified(
            caseNumber: "15-12/2026", level: .district,
            branch: .general, cartotekaID: "m"))
        XCTAssertNil(ProductionType.classified(
            caseNumber: "XYZ-12/2026", level: .district,
            branch: .general, cartotekaID: "m"))
    }

    // MARK: Стороны через «⚔»

    func testPartiesShortUsesCrossedSwords() {
        let p = CaseParties(plaintiffs: ["Новожилова Е. В."], defendants: ["ООО «Северлес»"])
        XCTAssertEqual(MovementDerivation.partiesShort(p), "Новожилова Е. В. ⚔ ООО «Северлес»")
    }

    func testPartiesShortListsTwoWithI() {
        let p = CaseParties(plaintiffs: ["Иванов А.", "Петров Б."], defendants: ["Сидоров В."])
        XCTAssertEqual(MovementDerivation.partiesShort(p), "Иванов А. и Петров Б. ⚔ Сидоров В.")
    }

    func testPartiesShortCountsThreeOrMore() {
        let p = CaseParties(plaintiffs: ["Иванов А.", "Петров Б.", "Сидоров В."],
                            defendants: ["ООО «Ромашка»"])
        XCTAssertEqual(MovementDerivation.partiesShort(p),
                       "Иванов А. и 2 других ⚔ ООО «Ромашка»")
    }

    func testPartiesShortForKoapOrganisation() {
        var p = CaseParties()
        p.add(role: "Привлекаемое лицо", name: "ООО «Севертранс»", articles: "ст.12.21.2 ч.1 КоАП РФ")
        XCTAssertEqual(MovementDerivation.partiesShort(p), "ООО «Севертранс»")
        XCTAssertEqual(p.leadCharges, "ст.12.21.2 ч.1 КоАП РФ")
        XCTAssertNil(MovementDerivation.partiesSecondLine(p))
    }

    // MARK: Категория на карточке — хвост рубрикатора
    //
    // Строки взяты из живых фикстур: sgs_card, ksoyu_case_card,
    // samara_kas_appeal_card. Разделителя два — «→» и «->».

    func testShortCategoryStaysWhole() {
        XCTAssertEqual(MovementDerivation.categoryTail("Иные жилищные споры"),
                       "Иные жилищные споры")
    }

    func testLongCategoryCollapsesToLastSection() {
        let cat = "Споры, связанные с имущественными правами → "
            + "Иски о взыскании сумм по договору займа, кредитному договору"
        XCTAssertEqual(MovementDerivation.categoryTail(cat),
                       "Иски о взыскании сумм по договору займа, кредитному договору")
    }

    func testStubSectionIsSkipped() {
        let cat = "Споры, возникающие из трудовых отношений → "
            + "Трудовые споры (независимо от форм собственности работодателя): → "
            + "Дела о восстановлении на работе, государственной (муниципальной) службе → "
            + "иные споры по делам о восстановлении на работе, государственной (муниципальной) службе"
        XCTAssertEqual(MovementDerivation.categoryTail(cat),
                       "Дела о восстановлении на работе, государственной (муниципальной) службе")
    }

    func testAsciiArrowAndRubricatorPrefix() {
        let cat = "3.025 - Гл. 22 КАС РФ -> об оспаривании решений, действий (бездействия) "
            + "должностных лиц -> прочие (об оспаривании решений, действий (бездействия) "
            + "должностных лиц (не явл. госслужащими) органов, организаций)"
        XCTAssertEqual(MovementDerivation.categoryTail(cat),
                       "об оспаривании решений, действий (бездействия) должностных лиц")
    }

    /// Длинная категория без разделов сворачивать некуда — отдаём как есть,
    /// обрезкой занимается сама карточка.
    func testLongCategoryWithoutSectionsIsKept() {
        let cat = "Дела о взыскании страхового возмещения по договору обязательного страхования"
        XCTAssertEqual(MovementDerivation.categoryTail(cat), cat)
    }

    /// Единственный раздел-заглушка не должен схлопнуться в пустоту.
    func testLoneStubSectionIsKept() {
        let cat = "иные споры по делам о восстановлении на работе, государственной службе"
        XCTAssertEqual(MovementDerivation.categoryTail(cat), cat)
    }

    // MARK: Подсудимые — многострочная раскладка «Списком»

    private func upkParties(_ defendants: [(String, String)]) -> CaseParties {
        var p = CaseParties()
        for (name, arts) in defendants { p.add(role: "Подсудимый", name: name, articles: arts) }
        return p
    }

    func testTwoDefendantsSecondLineHasName() {
        let p = upkParties([("Иванов И.", "ст.158 УК РФ"), ("Петров П.", "ст.159 УК РФ")])
        XCTAssertEqual(p.chargedMembers.count, 2)
        // Первая строка — ФИО первого, статьи — отдельно (щит).
        XCTAssertEqual(MovementDerivation.partiesShort(p), "Иванов И.")
        XCTAssertEqual(p.leadCharges, "ст.158 УК РФ")
        // Вторая строка — ФИО второго со своими статьями.
        let second = MovementDerivation.partiesSecondLine(p)
        XCTAssertEqual(second?.name, "Петров П.")
        XCTAssertEqual(second?.articles, "ст.159 УК РФ")
        XCTAssertNil(second?.more)
    }

    func testThreeDefendantsSecondLineCounts() {
        let p = upkParties([("Иванов И.", "ст.158 УК РФ"),
                            ("Петров П.", "ст.159 УК РФ"),
                            ("Сидоров С.", "ст.160 УК РФ")])
        let second = MovementDerivation.partiesSecondLine(p)
        XCTAssertEqual(second?.more, "и 2 других")
        XCTAssertNil(second?.name)
    }

    func testCivilHasNoSecondLine() {
        let p = CaseParties(plaintiffs: ["Иванов А.", "Петров Б."], defendants: ["Сидоров В."])
        XCTAssertNil(MovementDerivation.partiesSecondLine(p))
    }

    // MARK: Сортировка таблицы

    private func tracked(_ number: String, last: Date? = nil, next: Date? = nil) -> TrackedCase {
        TrackedCase(recordKey: "court/" + number, caseNumber: number, collections: [],
                    stage: .first, stageTag: "1-я инст.", subject: "—", court: "Сыктывкарский городской суд",
                    recordCourt: "Сыктывкарский городской суд",
                    courtTier: .district,
                    production: ProductionType.of(number),
                    partiesShort: "Иванов А. А. ⚔ ООО «Ромашка»", statusText: "В производстве",
                    statusChip: .blue, last: "—", next: "—", nextChip: .gray,
                    isNew: false, steps: [], newDot: false,
                    lastEventDate: last, nextEventDate: next)
    }

    func testSortByActivityFreshFirst() {
        let d1 = DateUtil.parse("01.04.2026")!, d2 = DateUtil.parse("20.04.2026")!
        let rows = [tracked("2-1/2026", last: d1), tracked("2-2/2026", last: d2),
                    tracked("2-3/2026", last: nil)]
        let sorted = AppRouter.sorted(rows, by: .activity).map(\.caseNumber)
        XCTAssertEqual(sorted, ["2-2/2026", "2-1/2026", "2-3/2026"])   // nil — в конец
    }

    func testSortByNextEventNearestFirst() {
        let d1 = DateUtil.parse("10.05.2026")!, d2 = DateUtil.parse("03.05.2026")!
        let rows = [tracked("2-1/2026", next: d1), tracked("2-2/2026", next: d2),
                    tracked("2-3/2026", next: nil)]
        let sorted = AppRouter.sorted(rows, by: .nextEvent).map(\.caseNumber)
        XCTAssertEqual(sorted, ["2-2/2026", "2-1/2026", "2-3/2026"])   // без события — в конец
    }

    @MainActor
    func testTierCountsPartitionCasesIncludingInactiveOnly() {
        var magistrate = tracked("1-1/2026")
        magistrate.courtTier = .magistrate
        var completed = tracked("2-2/2026")
        completed.stage = .done
        completed.courtTier = nil
        let counts = AppRouter.buildTierCounts([magistrate, tracked("2-3/2026"), completed])
        XCTAssertEqual(counts.reduce(0) { $0 + $1.1 }, 3)
        XCTAssertEqual(counts.first(where: { $0.0 == .magistrate })?.1, 1)
        XCTAssertEqual(counts.first(where: { $0.0 == .district })?.1, 1)
        XCTAssertEqual(counts.first(where: { $0.0 == nil })?.1, 1)
    }

    // MARK: Живой фильтр

    func testQueryMatchesNumberPartiesCollectionsCourt() {
        var c = tracked("2-115/2026")
        c.collections = ["Новожилова"]
        XCTAssertTrue(AppRouter.matches(c, query: "2-115"))
        XCTAssertTrue(AppRouter.matches(c, query: "ромашка"))       // стороны, регистр
        XCTAssertTrue(AppRouter.matches(c, query: "новожилова"))    // подборка
        XCTAssertTrue(AppRouter.matches(c, query: "сыктывкарский"))  // суд
        XCTAssertFalse(AppRouter.matches(c, query: "петров"))
    }

    /// #100 сменил показываемый суд на инстанцию ближайшего события. Дело,
    /// ушедшее в апелляцию, обязано находиться и по новому суду, и по суду
    /// первой инстанции: номер дела у него по-прежнему её, и в голове
    /// пользователя оно остаётся делом своего районного суда.
    func testQueryMatchesBothDisplayedAndRecordCourt() {
        var c = tracked("2-8236/2025")
        c.court = "Верховный суд Республики Коми"

        XCTAssertTrue(AppRouter.matches(c, query: "верховный"))
        XCTAssertTrue(AppRouter.matches(c, query: "сыктывкарский"))
        XCTAssertFalse(AppRouter.matches(c, query: "выборгский"))
    }

    @MainActor
    func testDeleteCollectionKeepsCasesAndRefreshesCounters() throws {
        let defaults = UserDefaults.standard
        let collectionsKey = "myCollections"
        let oldCollections = defaults.object(forKey: collectionsKey)
        let oldSpotlightOnboarding = defaults.object(forKey: SpotlightPreferenceStore.onboardingKey)
        let deleted = "Удалить-\(UUID().uuidString)"
        let kept = "Оставить-\(UUID().uuidString)"
        let empty = "Пустая-\(UUID().uuidString)"
        defaults.set([deleted, kept, empty], forKey: collectionsKey)
        defaults.set(false, forKey: SpotlightPreferenceStore.onboardingKey)
        defer {
            if let oldCollections { defaults.set(oldCollections, forKey: collectionsKey) }
            else { defaults.removeObject(forKey: collectionsKey) }
            if let oldSpotlightOnboarding {
                defaults.set(oldSpotlightOnboarding, forKey: SpotlightPreferenceStore.onboardingKey)
            } else {
                defaults.removeObject(forKey: SpotlightPreferenceStore.onboardingKey)
            }
        }

        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let context = container.mainContext
        let first = TrackedCaseRecord(
            key: "court/1-1/2026", collections: [deleted, kept],
            caseNumber: "1-1/2026", courtTitle: "Суд", displayDomain: "court",
            contextData: Data(), snapshotData: nil)
        let second = TrackedCaseRecord(
            key: "court/1-2/2026", collections: [deleted],
            caseNumber: "1-2/2026", courtTitle: "Суд", displayDomain: "court",
            contextData: Data(), snapshotData: nil)
        context.insert(first)
        context.insert(second)
        try context.save()

        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        XCTAssertEqual(router.collections.map(\.0), ["Все дела", deleted, kept, empty])
        XCTAssertEqual(router.collections.map(\.1), [2, 2, 1, 0])

        router.folder = deleted
        XCTAssertTrue(router.deleteCollection(named: deleted))
        XCTAssertEqual(router.folder, "Все дела")
        XCTAssertEqual(router.cases.count, 2)
        XCTAssertEqual(router.collections.map(\.0), ["Все дела", kept, empty])
        XCTAssertEqual(router.collections.map(\.1), [2, 1, 0])
        XCTAssertEqual(Set(first.collectionNames), [kept])
        XCTAssertTrue(second.collectionNames.isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: collectionsKey), [kept, empty])

        XCTAssertTrue(router.deleteCollection(named: empty))
        XCTAssertFalse(router.deleteCollection(named: "Все дела"))
        XCTAssertFalse(router.deleteCollection(named: "Неизвестная подборка"))
        XCTAssertEqual(router.collections.map(\.0), ["Все дела", kept])

        // Не оставляем уникальное тестовое имя для позднего reload из init Task.
        XCTAssertTrue(router.deleteCollection(named: kept))
    }
}
