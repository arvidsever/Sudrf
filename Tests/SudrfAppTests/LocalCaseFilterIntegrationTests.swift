import Foundation
import SwiftData
import XCTest
import SudrfKit
@testable import SudrfApp

@MainActor
enum LocalFilter403Fixture {
    static func context(_ index: Int = 1) -> MovementContext {
        MovementContext(branchRaw: "general", region: "Проверочный регион",
            searchDomain: "qa.sudrf.ru", displayDomain: "qa.sudrf.ru",
            courtTitle: "Проверочный районный суд", courtLevelRaw: "district",
            courtCode: "11RS0001", cartotekaId: "g1", cartotekaLevelRaw: "district",
            caseNumber: "2-\(index)/2026", caseID: "qa403-\(index)",
            caseUID: "technical-guid-\(index)", essence: "ИСТЕЦ: Примеров Пётр Павлович",
            judge: "Сохранённый С. С.", judicialUID: String(format: "11RS0001-01-2026-%06d-01", index))
    }

    static func movement(_ index: Int = 1, participants: Int = 3) -> CaseMovement {
        let ctx = context(index)
        let first = CaseInstance(level: .first, court: ctx.courtTitle,
            caseNumber: ctx.caseNumber, judge: "Первый Пётр Петрович", domain: ctx.displayDomain,
            foundByUID: false, result: nil,
            sessions: [CaseSession(date: "01.10.2026", event: "Подготовка дела")])
        let appeal = CaseInstance(level: .appeal, court: "Проверочный областной суд",
            caseNumber: "33-\(index + 40000)/2026", judge: "Ермаков Алексей Евгеньевич",
            domain: "qa-appeal.sudrf.ru", foundByUID: true, result: nil,
            sessions: [CaseSession(date: "20.10.2026", time: "10:00", event: "Судебное заседание")])
        var value = CaseMovement(uid: ctx.judicialUID!, caseNumber: ctx.caseNumber,
            inForce: false, instances: [first, appeal], complaints: [:], acts: [])
        value.category = "Защита прав потребителей — проверочный транспорт"
        value.parties = CaseParties(plaintiffs: ["Примеров Пётр Павлович"],
            defendants: ["ООО «Пример»"],
            thirdParties: (1...participants).map { "Скрытый участник \($0)" },
            roleItems: [RoleItem(role: "Представитель", name: "Защитников Зиновий Иванович", articles: "ст. 20.3 КоАП РФ")])
        return value
    }

    static func seed(_ container: ModelContainer, count: Int = 2, participants: Int = 3) throws -> [String] {
        let store = try TrackedStore(container: container, prepared: true)
        var keys: [String] = []
        for index in 1...count {
            let ctx = context(index)
            let move = movement(index, participants: participants)
            let snap = MovementDerivation.snapshot(from: move, context: ctx, today: DateUtil.parse("05.10.2026")!)
            let rec = try store.upsert(context: ctx, snapshot: snap, movement: move,
                collections: index == 1 ? ["Жешарт", "Проверка"] : [])
            rec.seenAt = Date(timeIntervalSince1970: 1_700_000_000)
            keys.append(rec.key)
        }
        try store.save()
        return keys
    }
}

@MainActor
final class LocalCaseFilterIntegrationTests: XCTestCase {
    func testDiskReopenPartialRefreshAndMembershipUseSavedFields() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("filter403-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("isolated.store")
        var keys: [String] = []
        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            keys = try LocalFilter403Fixture.seed(container)
        }
        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
            let store = try TrackedStore(container: container, prepared: true)
            let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
            router.query = "Жешарт Ермаков"
            XCTAssertEqual(router.filteredCases().map(\.recordKey), [keys[0]])
            router.query = "33-40001/2026"
            XCTAssertEqual(router.filteredCases().map(\.recordKey), [keys[0]])
            router.query = "Скрытый участник 3"
            XCTAssertEqual(Set(router.filteredCases().map(\.recordKey)), Set(keys))
            router.query = "technical-guid-1"
            XCTAssertTrue(router.filteredCases().isEmpty)
            let record = try XCTUnwrap(store.record(forKey: keys[0]))
            let journalBefore = record.eventJournal?.events
            let savedMovementData = record.movementData
            record.movementData = Data("not decoded while typing".utf8)
            router.query = "Ермаков 33-40001/2026"
            XCTAssertEqual(router.filteredCases().map(\.recordKey), [keys[0]])
            record.movementData = savedMovementData
            var partial = LocalFilter403Fixture.movement()
            partial.instances.removeAll { $0.level == .appeal }
            partial.incompleteHigherCourtDomains = ["qa-appeal.sudrf.ru"]
            let center = RefreshCenter(store: store, client: SudrfClient(), serviceBuilder: { _ in
                Filter403PartialProvider(value: partial)
            })
            _ = await center.refresh(key: keys[0])?.value
            router.reload()
            router.query = "Ермаков 33-40001/2026"
            XCTAssertEqual(router.filteredCases().map(\.recordKey), [keys[0]])
            XCTAssertEqual(record.eventJournal?.events, journalBefore)
            router.remove(caseKey: keys[0], from: "Жешарт")
            router.query = "Жешарт"
            XCTAssertTrue(router.filteredCases().isEmpty)
            router.query = "Ермаков"
            XCTAssertEqual(Set(router.filteredCases().map(\.recordKey)), Set(keys))
            router.untrack(recordKey: keys[0])
            router.query = "33-40001/2026"
            XCTAssertTrue(router.filteredCases().isEmpty)
        }
        let reopened = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
        let router = try AppRouter(modelContainer: reopened, modelContainerIsPrepared: true)
        router.query = "Ермаков"
        XCTAssertEqual(router.filteredCases().map(\.recordKey), [keys[1]])
    }

    func testLegacyContextAndExplicitMergeThenCorrectedSources() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let legacy = try store.upsert(context: LocalFilter403Fixture.context(3), snapshot: nil, collections: [])
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        router.query = "Сохранённый"
        XCTAssertEqual(router.filteredCases().map(\.recordKey), [legacy.key])
        router.query = "Примеров"
        XCTAssertEqual(router.filteredCases().map(\.recordKey), [legacy.key])
        _ = try LocalFilter403Fixture.seed(container)
        let one = try XCTUnwrap(store.record(forKey: LocalFilter403Fixture.context().key))
        let two = try XCTUnwrap(store.record(forKey: LocalFilter403Fixture.context(2).key))
        _ = try TrackedCaseRepairCoordinator.atomicMerge(store: store, survivor: one,
            duplicates: [two], canonicalContext: LocalFilter403Fixture.context(), canonicalCard: nil)
        router.reload()
        router.query = "33-40002/2026"
        XCTAssertEqual(router.filteredCases().map(\.recordKey), [one.key])
        // A confirmed correction upstream removes the unrelated card from
        // every persisted source. The transient search document must follow it.
        one.context = LocalFilter403Fixture.context()
        one.identityStateData = nil
        let corrected = LocalFilter403Fixture.movement()
        one.movement = corrected
        one.snapshot = MovementDerivation.snapshot(from: corrected,
            context: LocalFilter403Fixture.context(), today: DateUtil.parse("05.10.2026")!)
        try store.save()
        router.reload()
        router.query = "33-40002/2026"
        XCTAssertTrue(router.filteredCases().isEmpty)
        router.query = "33-40001/2026"
        XCTAssertEqual(router.filteredCases().map(\.recordKey), [one.key])
    }

    func testAllSavedRoundsMaterialsComplaintsAndHiddenRolesWithoutIdentityAliases() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let store = try TrackedStore(container: container, prepared: true)
        let context = LocalFilter403Fixture.context()
        var movement = LocalFilter403Fixture.movement()
        movement.instances[0].previousRegistration = .init(caseNumber: "2-900/2025",
            url: URL(string: "https://qa.sudrf.ru/previous")!)
        for (level, number, judge) in [(CaseInstance.Level.cassation, "8Г-550/2026 [88-551/2026]", "Старый Семён Сергеевич"),
                                       (.cassation, "88-552/2026", "Новый Николай Николаевич"),
                                       (.vsCassation, "3-КГ26-12", "Верховный Василий Васильевич"),
                                       (.material, "13-100/2026", "Материальный Михаил Михайлович")] {
            movement.instances.append(.init(level: level, court: "Проверочный суд \(number)",
                caseNumber: number, judge: judge, domain: "round-\(level.rawValue).sudrf.ru",
                foundByUID: true, result: "Исторический уникальный результат", sessions: []))
        }
        movement.complaints["private"] = .init(id: "private", label: "Частная жалоба",
            court: "Проверочный суд жалобы", caseNumber: "33-990/2026", foundByUID: true, rows: [])
        movement.parties.columns = [.init(id: "interested", title: "Заинтересованное лицо", titleMany: "Заинтересованные лица",
            icon: .person, members: [.init(name: "Дальний Дмитрий Дмитриевич", sub: nil, articles: nil)])]
        movement.actBodies["body"] = "ПолнотекстоваяУникальнаяФраза"
        let snapshot = MovementDerivation.snapshot(from: movement, context: context, today: DateUtil.parse("05.10.2026")!)
        let record = try store.upsert(context: context, snapshot: snapshot, movement: movement, collections: [])
        record.identityStateData = nil
        try store.save()
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        let originalParties = try XCTUnwrap(router.cases.first).partiesShort
        for query in ["2-900/2025", "8Г-550/2026", "88-551/2026", "88-552/2026", "3-КГ26-12",
                      "13-100/2026", "33-990/2026", "Старый", "Новый", "Верховный Василий Васильевич",
                      "Материальный", "Дальний", "Защитников", "ст. 20.3 КоАП РФ"] {
            router.query = query
            XCTAssertEqual(router.filteredCases().map(\.recordKey), [record.key], query)
        }
        for query in ["ПолнотекстоваяУникальнаяФраза", "Исторический уникальный результат"] {
            router.query = query
            XCTAssertTrue(router.filteredCases().isEmpty, query)
        }
        XCTAssertEqual(router.cases.first?.partiesShort, originalParties)
    }

    func testGroupingKeepsSameRecordsIncludingMissingGroups() throws {
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        _ = try LocalFilter403Fixture.seed(container)
        let router = try AppRouter(modelContainer: container, modelContainerIsPrepared: true)
        router.query = "Ермаков"
        var rows = router.filteredCases()
        rows[1].production = nil
        let expected = Set(rows.map(\.recordKey))
        for mode in [MyCasesMode.stages, .prods, .clients] {
            let groups = MyCasesView.caseGroups(rows: rows, mode: mode, collections: ["Жешарт", "Проверка"])
            XCTAssertEqual(Set(groups.flatMap { $0.rows.map(\.recordKey) }), expected)
            XCTAssertTrue(groups.allSatisfy { !$0.rows.isEmpty })
        }
        XCTAssertTrue(MyCasesView.caseGroups(rows: rows, mode: .prods, collections: []).contains { $0.title == "Вид производства не определён" })
        XCTAssertTrue(MyCasesView.caseGroups(rows: rows, mode: .clients, collections: ["Жешарт", "Проверка"]).contains { $0.title == "Без подборки" })
        rows[0].collections = ["Без подборки"]
        rows[1].collections = []
        let collision = MyCasesView.caseGroups(rows: rows, mode: .clients, collections: ["Без подборки"])
        XCTAssertEqual(collision.filter { $0.title == "Без подборки" }.count, 2)
        XCTAssertEqual(Set(collision.map(\.id)).count, collision.count)
    }
}

private struct Filter403PartialProvider: MovementProviding {
    let value: CaseMovement
    func movement(for base: CaseSearchResult, court: Court, cartoteka: Cartoteka) async throws -> CaseMovement { value }
}
