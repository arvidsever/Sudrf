import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

private actor Issue288Provider: CaseProviding {
    var rows: [CaseSearchResult]
    var cards: [String: CaseCard]
    var unreadable: Set<String> = []
    private(set) var fields: [SearchField] = []
    private(set) var fetchedIDs: [String] = []

    init(rows: [CaseSearchResult], cards: [String: CaseCard]) {
        self.rows = rows
        self.cards = cards
    }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        fields.append(field)
        if field == .uid { return [] }
        return cartoteka.id == "g1" ? rows : []
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        fetchedIDs.append(caseID)
        if unreadable.contains(caseID) {
            throw SudrfError.caseCardTemporarilyUnavailable
        }
        guard let card = cards[caseID] else { throw SudrfError.http(status: 404) }
        return card
    }

    func makeUnreadable(_ caseID: String) { unreadable.insert(caseID) }

    func fetchCard(url: URL) async throws -> CaseCard {
        throw SudrfError.http(status: 404)
    }
}

private actor Issue288Movements: MovementProviding {
    private var values: [CaseMovement]
    private(set) var requestedNumbers: [String] = []

    init(_ values: [CaseMovement]) { self.values = values }

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        requestedNumbers.append(base.caseNumber)
        return values.removeFirst()
    }
}

final class Issue288RegistrationDiscoveryTests: XCTestCase {
    private let oldUID = "11RS0001-01-2020-002565-94"
    private let newUID = "11RS0001-01-2020-016791-96"
    private let oldNumber = "9-727/2020 ~ М-1512/2020"
    private let newNumber = "2-1725/2021 (2-9326/2020;) ~ М-9968/2020"

    func testOfficialCompositeEvidenceFindsAcceptedRegistrationWithNewUID() async throws {
        let oldCard = try fixture("issue288_old_registration.html", caseID: "old")
        let newCard = try fixture("issue288_new_registration.html", caseID: "new")
        let rows = [oldRow, newRow, unrelatedRow]
        let provider = Issue288Provider(rows: rows, cards: ["new": newCard])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)

        let result = try await resolver.resolveMainCase(
            anchorContext: oldContext, anchorCard: oldCard,
            evidenceMovement: remandedMovement)

        XCTAssertEqual(result.result.caseNumber, newNumber)
        XCTAssertEqual(result.card.uid, newUID)
        XCTAssertEqual(result.card.previousRegistration?.caseNumber, "М-9968/2020")
        XCTAssertEqual(result.cartoteka.id, "g1")
        let fields = await provider.fields
        XCTAssertEqual(fields, [.uid, .uid, .name, .name])
        let fetchedIDs = await provider.fetchedIDs
        XCTAssertEqual(fetchedIDs, ["new"])
    }

    func testOperativeReturnToAcceptanceOverridesWrongShortAppealLabel() throws {
        let date = try XCTUnwrap(
            CaseLifecycleResolver.confirmedFirstInstanceRemandDate(in: remandedMovement))
        XCTAssertEqual(DateUtil.startOfDay(date),
                       DateUtil.startOfDay(try XCTUnwrap(DateUtil.parse("08.12.2020"))))
        let resolution = CaseLifecycleResolver.resolve(
            movement: remandedMovement, production: .civil, deadlines: [],
            today: try XCTUnwrap(DateUtil.parse("09.12.2020")))
        XCTAssertEqual(resolution.stage, .first)
    }

    func testPartiesAloneDoNotLinkWithoutConfirmedRemandAct() async throws {
        let oldCard = try fixture("issue288_old_registration.html", caseID: "old")
        let newCard = try fixture("issue288_new_registration.html", caseID: "new")
        let provider = Issue288Provider(rows: [newRow], cards: ["new": newCard])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)
        var movement = remandedMovement
        movement.acts = []
        movement.actBodies = [:]

        await XCTAssertThrowsErrorAsync {
            _ = try await resolver.resolveMainCase(
                anchorContext: self.oldContext, anchorCard: oldCard,
                evidenceMovement: movement)
        } verify: { error in
            XCTAssertEqual(error as? CaseOriginResolutionError, .notFound)
        }
    }

    func testDifferentOriginalFilingDateDoesNotLink() async throws {
        var oldCard = try fixture("issue288_old_registration.html", caseID: "old")
        let newCard = try fixture("issue288_new_registration.html", caseID: "new")
        oldCard.receiptDate = "27.02.2020"
        let provider = Issue288Provider(rows: [newRow], cards: ["new": newCard])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)

        await XCTAssertThrowsErrorAsync {
            _ = try await resolver.resolveMainCase(
                anchorContext: self.oldContext, anchorCard: oldCard,
                evidenceMovement: self.remandedMovement)
        } verify: { error in
            XCTAssertEqual(error as? CaseOriginResolutionError, .notFound)
        }
    }

    func testTwoFullyVerifiedCandidatesAreAmbiguous() async throws {
        let oldCard = try fixture("issue288_old_registration.html", caseID: "old")
        let newCard = try fixture("issue288_new_registration.html", caseID: "new")
        var duplicate = newRow
        duplicate.caseID = "duplicate"
        duplicate.caseUID = "duplicate-guid"
        duplicate.cardURL = cardURL(caseID: "duplicate", caseUID: "duplicate-guid")
        let provider = Issue288Provider(
            rows: [newRow, duplicate], cards: ["new": newCard, "duplicate": newCard])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)

        await XCTAssertThrowsErrorAsync {
            _ = try await resolver.resolveMainCase(
                anchorContext: self.oldContext, anchorCard: oldCard,
                evidenceMovement: self.remandedMovement)
        } verify: { error in
            XCTAssertEqual(error as? CaseOriginResolutionError, .ambiguous)
        }
    }

    func testUnreadableEligibleCandidateIsTransient() async throws {
        let oldCard = try fixture("issue288_old_registration.html", caseID: "old")
        let newCard = try fixture("issue288_new_registration.html", caseID: "new")
        let provider = Issue288Provider(rows: [newRow], cards: ["new": newCard])
        await provider.makeUnreadable("new")
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)

        await XCTAssertThrowsErrorAsync {
            _ = try await resolver.resolveMainCase(
                anchorContext: self.oldContext, anchorCard: oldCard,
                evidenceMovement: self.remandedMovement)
        } verify: { error in
            guard case SudrfError.caseCardTemporarilyUnavailable = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testRepairRefreshAndReopenKeepOneChainAndStableKey() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-288-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let oldCard = try fixture("issue288_old_registration.html", caseID: "old")
        let newCard = try fixture("issue288_new_registration.html", caseID: "new")

        var snapshot = MovementDerivation.snapshot(from: remandedMovement, context: oldContext)
        snapshot.deadlines = [StoredDeadline(
            kind: "custom", what: "Пользовательский срок", basis: "fixture",
            calLabel: "ручной", dateRef: try XCTUnwrap(DateUtil.parse("01.03.2021"))
                .timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.confirmed.rawValue,
            occurrenceKey: "issue-288-user-deadline")]
        let record = try store.upsert(context: oldContext, snapshot: snapshot,
                                      movement: remandedMovement, collections: ["Беляев"])
        let stableKey = record.key
        try store.appendCaseEvents([CaseEvent.make(
            kind: .judicialActPublished, occurrence: ["issue-288-seed"],
            observedAt: Date(timeIntervalSinceReferenceDate: 1),
            evidence: CaseEventEvidence(caseNumber: oldNumber,
                                        value: "issue288-remand"))], to: record)
        try store.save()

        let provider = Issue288Provider(rows: [oldRow, newRow, unrelatedRow],
                                        cards: ["new": newCard])
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)
        let suiteName = "Issue288RegistrationDiscoveryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: resolver,
            defaults: defaults, anchorCardFetcher: { _ in oldCard })

        let full = refreshedMovement
        var partial = full
        partial.incompleteHigherCourtDomains = ["vs--komi.sudrf.ru"]
        let movements = Issue288Movements([full, partial])
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in movements })
        center.repairBeforeRefresh = { key, _ in
            try await coordinator.repairIfNeeded(key: key).effectiveKey
        }

        let first = await center.refresh(key: stableKey)?.value
        XCTAssertEqual(first?.outcome, .refreshed)
        let promoted = try XCTUnwrap(store.record(forKey: stableKey))
        let firstFetchedAt = promoted.movementFetchedAt
        let firstJournal = promoted.eventJournal
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(promoted.key, stableKey)
        XCTAssertEqual(promoted.caseNumber, "2-1725/2021")
        XCTAssertEqual(promoted.context?.caseNumber, "2-1725/2021")
        XCTAssertEqual(promoted.context?.judicialUID, newUID)
        XCTAssertTrue(promoted.context?.knownCards?.contains {
            $0.caseNumber == oldNumber
        } == true)
        XCTAssertEqual(promoted.movement?.caseNumber, "2-1725/2021")
        XCTAssertEqual(promoted.collectionNames, ["Беляев"])
        XCTAssertEqual(promoted.snapshot?.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(promoted.snapshot?.deadlines.first {
            $0.occurrenceKey == "issue-288-user-deadline"
        }?.status, .confirmed)
        for number in [oldNumber, "33-2819/2020", "88-18789/2020",
                       "33-4790/2021", "33-906/2022", "33-3759/2022"] {
            XCTAssertNotNil(promoted.movement?.instances.first { $0.caseNumber == number }, number)
        }
        XCTAssertTrue(AppRouter.caseNumberAliases(for: promoted).searchable.contains(oldNumber))
        XCTAssertTrue(store.record(forLocator: oldContext.key) === promoted)

        let second = await center.refresh(key: stableKey)?.value
        XCTAssertEqual(second?.outcome,
                       .partial("Не обновился источник vs--komi.sudrf.ru; сохранены последние успешные данные."))
        let afterPartial = try XCTUnwrap(store.record(forKey: stableKey))
        XCTAssertEqual(afterPartial.movementFetchedAt, firstFetchedAt)
        XCTAssertEqual(afterPartial.eventJournal, firstJournal)
        XCTAssertEqual(afterPartial.context?.judicialUID, newUID)
        let requestedNumbers = await movements.requestedNumbers
        XCTAssertEqual(requestedNumbers, ["2-1725/2021", "2-1725/2021"])

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        let persisted = try XCTUnwrap(reopened.record(forKey: stableKey))
        XCTAssertEqual(reopened.all().count, 1)
        XCTAssertEqual(persisted.caseNumber, "2-1725/2021")
        XCTAssertEqual(persisted.context?.judicialUID, newUID)
        XCTAssertNotNil(persisted.movement?.instances.first { $0.caseNumber == oldNumber })
        XCTAssertEqual(persisted.collectionNames, ["Беляев"])
        XCTAssertEqual(persisted.eventJournal, firstJournal)
    }

    private var oldContext: MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru",
            displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд", courtLevelRaw: "district",
            courtCode: "11RS0001", cartotekaId: "g1",
            cartotekaLevelRaw: "district", caseNumber: oldNumber,
            caseID: "old", caseUID: "old-guid",
            cardURLString: cardURL(caseID: "old", caseUID: "old-guid").absoluteString,
            judicialUID: oldUID, baseInstanceLevelRaw: CaseInstance.Level.first.rawValue)
    }

    private var oldRow: CaseSearchResult {
        CaseSearchResult(caseNumber: oldNumber, receiptDate: "26.02.2020",
                         caseID: "old", caseUID: "old-guid",
                         cardURL: cardURL(caseID: "old", caseUID: "old-guid"))
    }

    private var newRow: CaseSearchResult {
        CaseSearchResult(caseNumber: newNumber, receiptDate: "22.12.2020",
                         result: "Иск удовлетворен частично", caseID: "new",
                         caseUID: "new-guid",
                         cardURL: cardURL(caseID: "new", caseUID: "new-guid"))
    }

    private var unrelatedRow: CaseSearchResult {
        CaseSearchResult(caseNumber: "2-152/2026 (2-6213/2025;)",
                         receiptDate: "16.06.2025", caseID: "unrelated",
                         caseUID: "unrelated-guid",
                         cardURL: cardURL(caseID: "unrelated", caseUID: "unrelated-guid"))
    }

    private var remandedMovement: CaseMovement {
        let first = CaseInstance(
            level: .first, court: "Сыктывкарский городской суд",
            caseNumber: oldNumber, judge: "Лушкова С.В.",
            domain: "syktsud--komi.sudrf.ru", foundByUID: false,
            result: "Заявление возвращено заявителю",
            sessions: [CaseSession(date: "06.05.2020", event: "Материалы возвращены")])
        let appeal = CaseInstance(
            level: .appeal, court: "Верховный Суд Республики Коми",
            caseNumber: "33-2819/2020", judge: nil,
            domain: "vs--komi.sudrf.ru", foundByUID: true,
            result: "ОПРЕДЕЛЕНИЕ оставлено БЕЗ ИЗМЕНЕНИЯ",
            sessions: [CaseSession(
                date: "18.06.2020", event: "Судебное заседание",
                result: "ОПРЕДЕЛЕНИЕ оставлено БЕЗ ИЗМЕНЕНИЯ")])
        let cassation = CaseInstance(
            level: .cassation, court: "Третий кассационный суд общей юрисдикции",
            caseNumber: "88-18789/2020", judge: "Рогачева В.В.",
            domain: "3kas.sudrf.ru", foundByUID: true,
            result: "ОТМЕНЕНО апелляционное определение с НАПРАВЛЕНИЕМ ДЕЛА НА НОВОЕ АПЕЛЛЯЦИОННОЕ РАССМОТРЕНИЕ",
            sessions: [CaseSession(
                date: "08.12.2020", event: "Судебное заседание",
                result: "ОТМЕНЕНО апелляционное определение с направлением дела на новое апелляционное рассмотрение")],
            actID: "issue288-remand")
        let body = """
        ОПРЕДЕЛЕНИЕ
        Суд установил обстоятельства кассационной жалобы.
        определила:
        Определение Сыктывкарского городского суда от 06 мая 2020 года и апелляционное определение от 18 июня 2020 года отменить.
        Материал по иску возвратить в Сыктывкарский городской суд Республики Коми для рассмотрения со стадии принятия искового заявления к производству суда.
        """
        return CaseMovement(
            uid: oldUID, caseNumber: oldNumber, inForce: false,
            instances: [first, appeal, cassation], complaints: [:],
            acts: [CaseAct(id: "issue288-remand", title: "Определение",
                           date: "08.12.2020", courtShort: "3 КСОЮ",
                           instanceLevel: .cassation)],
            actBodies: ["issue288-remand": body], category: nil)
    }

    private var refreshedMovement: CaseMovement {
        func instance(_ level: CaseInstance.Level, _ number: String, _ date: String,
                      _ result: String, _ domain: String) -> CaseInstance {
            CaseInstance(
                level: level, court: level == .first
                    ? "Сыктывкарский городской суд" : "Вышестоящий суд",
                caseNumber: number, judge: nil, domain: domain,
                foundByUID: level != .first, result: result,
                sessions: [CaseSession(date: date, event: "Судебное заседание",
                                       result: result)])
        }
        let historical = remandedMovement
        return CaseMovement(
            uid: newUID, caseNumber: "2-1725/2021", inForce: false,
            instances: historical.instances + [
                instance(.first, "2-1725/2021", "28.05.2021",
                         "Вынесено решение", "syktsud--komi.sudrf.ru"),
                instance(.appeal, "33-4790/2021", "18.10.2021",
                         "РЕШЕНИЕ оставлено БЕЗ ИЗМЕНЕНИЯ", "vs--komi.sudrf.ru"),
                instance(.appeal, "33-906/2022", "10.03.2022",
                         "определение отменено полностью с разрешением вопроса по существу",
                         "vs--komi.sudrf.ru"),
                instance(.appeal, "33-3759/2022", "11.07.2022",
                         "ОПРЕДЕЛЕНИЕ оставлено БЕЗ ИЗМЕНЕНИЯ", "vs--komi.sudrf.ru")
            ], complaints: [:], acts: historical.acts,
            actBodies: historical.actBodies,
            category: "Споры, возникающие из трудовых отношений",
            parties: CaseParties(
                plaintiffs: ["Беляев Дмитрий Анатольевич"],
                defendants: ["Министерство науки и высшего образования РФ",
                             "ФГБОУ ВО «Ухтинский государственный технический университет»"]))
    }

    private func fixture(_ name: String, caseID: String) throws -> CaseCard {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = tests.appendingPathComponent("SudrfKitTests/Fixtures/\(name)")
        return try CaseCardParser.parse(
            html: String(contentsOf: url, encoding: .utf8),
            cardURL: cardURL(caseID: caseID, caseUID: "\(caseID)-guid"))
    }

    private func cardURL(caseID: String, caseUID: String) -> URL {
        URL(string: "https://syktsud--komi.sudrf.ru/modules.php?name=sud_delo"
            + "&srv_num=1&name_op=case&case_id=\(caseID)&case_uid=\(caseUID)"
            + "&delo_id=1540005&new=0")!
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    verify: (Error) -> Void,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        verify(error)
    }
}
