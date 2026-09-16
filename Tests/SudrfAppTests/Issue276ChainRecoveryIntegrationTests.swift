import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

private actor Issue276Provider: CaseProviding {
    let uid = "78RS0023-01-2018-009010-02"
    let lowerNumber = "2-1975/2019"
    let appealNumber = "33-7564/2019"
    let returnedNumber = "8Г-162/2019"
    let laterNumber = "88-3384/2020"
    let materialNumber = "13-100/2019"
    private let returnedCard: CaseCard
    private var captchaOnKSOYUSearch = false

    init(returnedCard: CaseCard) {
        self.returnedCard = returnedCard
    }

    func setCaptchaOnKSOYUSearch(_ value: Bool) {
        captchaOnKSOYUSearch = value
    }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        let host = SudrfHost.moduleHost(court.domain)
        if host == "frn--spb.sudrf.ru", cartoteka.id == "g1",
           field == .caseNumber, value == lowerNumber {
            return [lowerRow]
        }
        if host == "frn--spb.sudrf.ru", cartoteka.id == "g1",
           field == .uid, value == uid { return [lowerRow] }
        if host == "frn--spb.sudrf.ru", cartoteka.id == "m",
           field == .uid, value == uid { return [materialRow] }
        if host == "sankt-peterburgsky--spb.sudrf.ru", cartoteka.id == "g2",
           field == .uid, value == uid {
            return [appealRow]
        }
        if host == "3kas.sudrf.ru", cartoteka.id == "g3", field == .uid, value == uid {
            if captchaOnKSOYUSearch {
                throw SudrfError.captchaRequired(formURL: URL(string:
                    "https://3kas.sudrf.ru/modules.php?name=sud_delo")!)
            }
            return [returnedRow, laterRow]
        }
        return []
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        switch caseID {
        case "224918231": return lowerCard
        case "material-id": return materialCard
        case "appeal-id": return appealCard
        case "11929251": return returnedCard
        case "later-id": return laterCard
        default: throw SudrfError.http(status: 404)
        }
    }

    func fetchCard(url: URL) async throws -> CaseCard {
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "case_id" }?.value
        switch id {
        case "224918231": return lowerCard
        case "material-id": return materialCard
        case "appeal-id": return appealCard
        case "11929251": return returnedCard
        case "later-id": return laterCard
        default: throw SudrfError.http(status: 404)
        }
    }

    private var lowerRow: CaseSearchResult {
        CaseSearchResult(
            caseNumber: "2-1975/2019 (2-7895/2018;) ~ М-6968/2018",
            caseID: "224918231", caseUID: "5A1CB189-E350-4548-8DC1-7BC38E72D3FF",
            cardURL: URL(string: "https://frn--spb.sudrf.ru/modules.php?case_id=224918231"
                + "&case_uid=5A1CB189-E350-4548-8DC1-7BC38E72D3FF&delo_id=1540005"
                + "&name=sud_delo&name_op=case&srv_num=1"))
    }

    private var lowerCard: CaseCard {
        CaseCard(
            rawText: "", actText: nil,
            sessions: [CaseSession(date: "05.02.2019", event: "Судебное заседание",
                                   result: "Иск удовлетворен частично")],
            judge: "Подольская Наталья Валентиновна", result: "Иск удовлетворен частично",
            uid: uid, caseNumber: lowerNumber, category: "Гражданский спор",
            decisionDate: "05.02.2019", processKind: .civil)
    }

    private var appealRow: CaseSearchResult {
        CaseSearchResult(caseNumber: appealNumber, decisionDate: "20.06.2019",
                         result: "Решение изменено", caseID: "appeal-id",
                         caseUID: "appeal-guid", cardURL: cardURL(
                            host: "sankt-peterburgsky--spb.sudrf.ru",
                            caseID: "appeal-id", caseUID: "appeal-guid",
                            deloID: "5", new: "5"))
    }

    private var materialRow: CaseSearchResult {
        CaseSearchResult(caseNumber: materialNumber, decisionDate: "01.03.2019",
                         result: "Заявление разрешено", caseID: "material-id",
                         caseUID: "material-guid", cardURL: cardURL(
                            host: "frn--spb.sudrf.ru", caseID: "material-id",
                            caseUID: "material-guid", deloID: "1500001", new: "0"))
    }

    private var materialCard: CaseCard {
        CaseCard(rawText: "", actText: nil, result: "Заявление разрешено",
                 uid: uid, caseNumber: materialNumber, decisionDate: "01.03.2019",
                 processKind: .civil)
    }

    private var appealCard: CaseCard {
        CaseCard(
            rawText: "", actText: nil,
            sessions: [CaseSession(date: "20.06.2019", event: "Судебное заседание",
                                   result: "Решение изменено")],
            result: "Решение изменено", uid: uid, caseNumber: appealNumber,
            decisionDate: "20.06.2019", processKind: .civil)
    }

    private var returnedRow: CaseSearchResult {
        CaseSearchResult(caseNumber: returnedNumber, decisionDate: "15.10.2019",
                         caseID: "11929251",
                         caseUID: "3ec699b1-bad6-4927-b00a-b18f140ccb0c",
                         cardURL: cardURL(host: "3kas.sudrf.ru", caseID: "11929251",
                                          caseUID: "3ec699b1-bad6-4927-b00a-b18f140ccb0c",
                                          deloID: "2800001", new: "2800001"))
    }

    private var laterRow: CaseSearchResult {
        CaseSearchResult(caseNumber: laterNumber, decisionDate: "26.02.2020",
                         result: "Оставлено без изменения", caseID: "later-id",
                         caseUID: "later-guid", cardURL: cardURL(
                            host: "3kas.sudrf.ru", caseID: "later-id",
                            caseUID: "later-guid", deloID: "2800001", new: "2800001"))
    }

    private var laterCard: CaseCard {
        CaseCard(
            rawText: "", actText: nil,
            sessions: [CaseSession(date: "26.02.2020", event: "Судебное заседание",
                                   result: "Оставлено без изменения")],
            result: "Оставлено без изменения", uid: uid, caseNumber: laterNumber,
            decisionDate: "26.02.2020", processKind: .civil)
    }

    private func cardURL(host: String, caseID: String, caseUID: String,
                         deloID: String, new: String) -> URL {
        URL(string: "https://\(host)/modules.php?name=sud_delo&srv_num=1&name_op=case"
            + "&case_id=\(caseID)&case_uid=\(caseUID)&delo_id=\(deloID)&new=\(new)")!
    }
}

private actor Issue276MovementSequence {
    let provider: Issue276Provider
    private var calls = 0

    init(provider: Issue276Provider) { self.provider = provider }

    func movement(using parsed: MovementService, for base: CaseSearchResult,
                  court: Court, cartoteka: Cartoteka) async throws -> CaseMovement {
        calls += 1
        if calls == 3 { throw SudrfError.caseCardTemporarilyUnavailable }
        if calls == 2 { await provider.setCaptchaOnKSOYUSearch(true) }
        do {
            let movement = try await parsed.movement(for: base, court: court,
                                                     cartoteka: cartoteka)
            if calls == 2 { await provider.setCaptchaOnKSOYUSearch(false) }
            return movement
        } catch {
            if calls == 2 { await provider.setCaptchaOnKSOYUSearch(false) }
            throw error
        }
    }
}

private struct Issue276Movements: MovementProviding {
    let parsed: MovementService
    let sequence: Issue276MovementSequence

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        try await sequence.movement(using: parsed, for: base, court: court,
                                    cartoteka: cartoteka)
    }
}

@MainActor
final class Issue276ChainRecoveryIntegrationTests: XCTestCase {
    private let uid = "78RS0023-01-2018-009010-02"
    private let lowerNumber = "2-1975/2019"
    private let returnedNumber = "8Г-162/2019"
    private let laterNumber = "88-3384/2020"
    private let returnedResult = "возвращено - кассационные жалоба, представление поданы с нарушением "
        + "правил подсудности, установленных ст.377 настоящего Кодекса"

    func testKSOYUCardWithoutJudicialUIDRepairsAndRefreshesOnePersistentChain() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-276-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let returnedCard = try fixtureCard()
        XCTAssertNil(returnedCard.uid)
        XCTAssertEqual(returnedCard.lowerCourt?.caseNumber, lowerNumber)
        let provider = Issue276Provider(returnedCard: returnedCard)
        let context = try ksoyuContext()
        var initialMovement = try await context.makeService(client: provider).movement(
            for: context.baseResult, court: context.searchCourt,
            cartoteka: try XCTUnwrap(context.cartoteka))
        initialMovement.acts = [CaseAct(
            id: "preserved-act", title: "Определение", date: "15.10.2019",
            courtShort: "3 КСОЮ", instanceLevel: .cassation)]
        initialMovement.actBodies = ["preserved-act": "Сохраненный текст акта"]
        var initialSnapshot = MovementDerivation.snapshot(from: initialMovement, context: context)
        initialSnapshot.deadlines = [StoredDeadline(
            kind: "custom", what: "Пользовательский срок", basis: "fixture",
            calLabel: "ручной", dateRef: Date(timeIntervalSince1970: 1_600_000_000)
                .timeIntervalSinceReferenceDate,
            statusRaw: DeadlineStatus.confirmed.rawValue,
            occurrenceKey: "issue-276-user-deadline")]

        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let record = try store.upsert(context: context, snapshot: initialSnapshot,
                                      movement: initialMovement, collections: ["Гражданские"])
        let stableKey = record.key
        let seenAt = Date(timeIntervalSinceReferenceDate: 42)
        record.seenAt = seenAt
        let seed = CaseEvent.make(
            kind: .judicialActPublished, occurrence: ["issue-276-seed"],
            observedAt: Date(timeIntervalSinceReferenceDate: 1), evidence: .init())
        record.eventJournal = CaseEventJournal(events: [seed])
        try store.save()

        let cacheURL = directory.appendingPathComponent("districts.json")
        let directoryCourt = DistrictCourt(
            title: "Фрунзенский районный суд города Санкт-Петербурга",
            domain: "frn.spb.sudrf.ru", code: "78RS0023", regionCode: "spb",
            kind: .district, portalSubject: "78")
        try JSONEncoder().encode([directoryCourt]).write(to: cacheURL)
        let resolver = CaseOriginResolver(
            client: SudrfClient(), districtResolver: DistrictCourtResolver(
                client: SudrfClient(), cacheURL: cacheURL), regularProvider: provider)
        let suiteName = "Issue276ChainRecoveryIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: resolver,
            defaults: defaults, anchorCardFetcher: { _ in returnedCard })

        let repair = try await coordinator.repairIfNeeded(key: stableKey)
        XCTAssertEqual(repair.effectiveKey, stableKey)
        let afterRepair = try XCTUnwrap(store.record(forKey: stableKey))
        XCTAssertEqual(afterRepair.seenAt, seenAt)
        XCTAssertEqual(afterRepair.eventJournal?.events, [seed])
        XCTAssertTrue(afterRepair.movement?.acts.contains { $0.id == "preserved-act" } == true)
        XCTAssertEqual(afterRepair.movement?.actBodies["preserved-act"],
                       "Сохраненный текст акта")
        XCTAssertEqual(afterRepair.snapshot?.deadlines.first {
            $0.occurrenceKey == "issue-276-user-deadline"
        }?.status, .confirmed)

        let sequence = Issue276MovementSequence(provider: provider)
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { context in
            let parsed = MovementService(
                client: provider,
                higherCourtDomains: [
                    "sankt-peterburgsky--spb.sudrf.ru", "3kas.sudrf.ru",
                ],
                knownCards: context.knownCards ?? [],
                baseInstanceLevel: context.baseInstanceLevel,
                judicialUID: context.judicialUID, branch: context.branch)
            return Issue276Movements(parsed: parsed, sequence: sequence)
        })
        center.repairBeforeRefresh = { key in
            try await coordinator.repairIfNeeded(key: key).effectiveKey
        }

        let first = await center.refresh(key: stableKey)?.value
        XCTAssertEqual(first?.outcome, .refreshed)
        let repaired = try XCTUnwrap(store.record(forKey: stableKey))
        let fullMovement = try XCTUnwrap(repaired.movement)
        let fullSnapshot = repaired.snapshot
        let fullFetchedAt = repaired.movementFetchedAt
        let fullJournal = repaired.eventJournal

        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(repaired.key, stableKey)
        XCTAssertEqual(repaired.caseNumber, lowerNumber)
        XCTAssertEqual(repaired.context?.caseNumber, lowerNumber)
        XCTAssertEqual(repaired.context?.judicialUID, uid)
        XCTAssertEqual(repaired.movement?.caseNumber, lowerNumber)
        XCTAssertEqual(repaired.collectionNames, ["Гражданские"])
        XCTAssertEqual(MaterialProductionContext.resolve(
            context: repaired.context, movement: repaired.movement).production, .civil)
        XCTAssertTrue(repaired.context?.knownCards?.contains {
            $0.caseNumber == returnedNumber && $0.caseUID == context.caseUID
        } == true)
        XCTAssertTrue(AppRouter.caseNumberAliases(for: repaired)
            .searchable.contains(returnedNumber))
        XCTAssertTrue(store.record(forLocator: context.key) === repaired)
        XCTAssertTrue(store.record(forLocator: try XCTUnwrap(repaired.context).key) === repaired)
        XCTAssertTrue(repaired.eventJournal?.events.contains(seed) == true)
        XCTAssertEqual(fullSnapshot?.deadlines.first {
            $0.occurrenceKey == "issue-276-user-deadline"
        }?.status, .confirmed)

        let returned = try XCTUnwrap(fullMovement.instances.first {
            $0.caseNumber == returnedNumber
        })
        XCTAssertEqual(returned.sessions.last?.result, returnedResult)
        XCTAssertEqual(fullMovement.instances.filter { $0.caseNumber == returnedNumber }.count, 1)
        XCTAssertNotNil(fullMovement.instances.first { $0.level == .appeal })
        XCTAssertNotNil(fullMovement.instances.first { $0.caseNumber == laterNumber })
        XCTAssertEqual(fullSnapshot?.stageRaw, CaseStageKind.done.rawValue)

        let captcha = await center.refresh(key: stableKey)?.value
        guard case .partial = captcha?.outcome else {
            return XCTFail("CAPTCHA вышестоящего суда должна дать partial refresh")
        }
        let afterCaptcha = try XCTUnwrap(store.record(forKey: stableKey))
        XCTAssertEqual(afterCaptcha.movementFetchedAt, fullFetchedAt)
        XCTAssertEqual(afterCaptcha.eventJournal, fullJournal)
        XCTAssertEqual(afterCaptcha.snapshot?.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(afterCaptcha.movement?.instances.filter {
            $0.caseNumber == returnedNumber
        }.count, 1)
        XCTAssertEqual(afterCaptcha.movement?.instances.first {
            $0.caseNumber == returnedNumber
        }?.sessions.last?.result, returnedResult)
        XCTAssertNotNil(afterCaptcha.movement?.instances.first { $0.caseNumber == laterNumber })
        XCTAssertEqual(afterCaptcha.snapshot?.deadlines.first {
            $0.occurrenceKey == "issue-276-user-deadline"
        }?.status, .confirmed)

        let unavailable = await center.refresh(key: stableKey)?.value
        guard case .failed = unavailable?.outcome else {
            return XCTFail("Временная ошибка не должна менять подтвержденную цепочку")
        }
        XCTAssertEqual(store.record(forKey: stableKey)?.movement, afterCaptcha.movement)
        XCTAssertEqual(store.record(forKey: stableKey)?.snapshot, afterCaptcha.snapshot)

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        let persisted = try XCTUnwrap(reopened.record(forKey: stableKey))
        XCTAssertEqual(reopened.all().count, 1)
        XCTAssertEqual(persisted.caseNumber, lowerNumber)
        XCTAssertEqual(persisted.context?.judicialUID, uid)
        XCTAssertTrue(AppRouter.caseNumberAliases(for: persisted)
            .searchable.contains(returnedNumber))
        XCTAssertTrue(persisted.eventJournal?.events.contains(seed) == true)
        XCTAssertEqual(persisted.movement?.instances.filter {
            $0.caseNumber == returnedNumber
        }.count, 1)
        XCTAssertNotNil(persisted.movement?.instances.first { $0.caseNumber == laterNumber })

        let reopenedSequence = Issue276MovementSequence(provider: provider)
        let reopenedCenter = RefreshCenter(
            store: reopened, client: SudrfClient(), serviceBuilder: { context in
                Issue276Movements(
                    parsed: MovementService(
                        client: provider,
                        higherCourtDomains: [
                            "sankt-peterburgsky--spb.sudrf.ru", "3kas.sudrf.ru",
                        ],
                        knownCards: context.knownCards ?? [],
                        baseInstanceLevel: context.baseInstanceLevel,
                        judicialUID: context.judicialUID, branch: context.branch),
                    sequence: reopenedSequence)
            })
        let repeated = await reopenedCenter.refresh(key: stableKey)?.value
        XCTAssertEqual(repeated?.outcome, .refreshed)
        let afterRepeated = try XCTUnwrap(reopened.record(forKey: stableKey))
        XCTAssertEqual(reopened.all().count, 1)
        XCTAssertEqual(afterRepeated.caseNumber, lowerNumber)
        XCTAssertEqual(afterRepeated.movement?.instances.filter {
            $0.caseNumber == returnedNumber
        }.count, 1)
        XCTAssertNotNil(afterRepeated.movement?.instances.first {
            $0.caseNumber == laterNumber
        })
    }

    private func ksoyuContext() throws -> MovementContext {
        let url = try XCTUnwrap(URL(string:
            "https://3kas.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case"
                + "&case_id=11929251&case_uid=3ec699b1-bad6-4927-b00a-b18f140ccb0c"
                + "&new=2800001&delo_id=2800001"))
        return MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Санкт-Петербург",
            searchDomain: "3kas.sudrf.ru", displayDomain: "3kas.sudrf.ru",
            courtTitle: "Третий кассационный суд общей юрисдикции",
            courtLevelRaw: CourtLevel.cassation.rawValue, courtCode: nil,
            cartotekaId: "g3", cartotekaLevelRaw: CourtLevel.cassation.rawValue,
            caseNumber: returnedNumber, caseID: "11929251",
            caseUID: "3ec699b1-bad6-4927-b00a-b18f140ccb0c",
            cardURLString: url.absoluteString, judicialUID: nil,
            baseInstanceLevelRaw: CaseInstance.Level.cassation.rawValue)
    }

    private func fixtureCard() throws -> CaseCard {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = tests.appendingPathComponent(
            "SudrfKitTests/Fixtures/ksoyu_civil_returned_wrong_jurisdiction.html")
        return try CaseCardParser.parse(
            html: String(contentsOf: fixture, encoding: .utf8),
            cardURL: try XCTUnwrap(URL(string:
                "https://3kas.sudrf.ru/modules.php?name=sud_delo&srv_num=1"
                    + "&name_op=case&case_id=11929251"
                    + "&case_uid=3ec699b1-bad6-4927-b00a-b18f140ccb0c"
                    + "&new=2800001&delo_id=2800001")))
    }
}
