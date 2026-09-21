import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

private actor Issue290Provider: CaseProviding {
    let lowerRow: CaseSearchResult
    let lowerCard: CaseCard
    private var captchaRequired = true
    private(set) var searches = 0

    init(lowerCard: CaseCard) {
        self.lowerCard = lowerCard
        lowerRow = CaseSearchResult(
            caseNumber: "4-111/2019", caseID: "892526215",
            caseUID: "7c9bc768-720c-4537-a3b3-6ab56e36fc5f",
            cardURL: URL(string: "https://oktibrsky--spb.sudrf.ru/modules.php"
                + "?name=sud_delo&srv_num=1&name_op=case&case_id=892526215"
                + "&case_uid=7c9bc768-720c-4537-a3b3-6ab56e36fc5f&delo_id=1610001"))
    }

    func allowSearch() { captchaRequired = false }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        searches += 1
        guard SudrfHost.moduleHost(court.domain) == "oktibrsky--spb.sudrf.ru",
              cartoteka.id == "m", field == .caseNumber, value == lowerRow.caseNumber
        else { return [] }
        if captchaRequired {
            throw SudrfError.captchaRequired(formURL: URL(string:
                "https://oktibrsky--spb.sudrf.ru/modules.php?name=sud_delo"
                    + "&name_op=sf&srv_num=1&delo_id=1610001")!)
        }
        return [lowerRow]
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        guard caseID == lowerRow.caseID, caseUID == lowerRow.caseUID,
              deloID == "1610001" else { throw SudrfError.http(status: 404) }
        return lowerCard
    }

    func fetchCard(url: URL) async throws -> CaseCard { lowerCard }
}

@MainActor
final class Issue290ChainRecoveryIntegrationTests: XCTestCase {
    private let appealNumber = "22-227/2020"
    private let appealPublishedNumber = "22-227/2020 (22-8976/2019;)"
    private let lowerNumber = "4-111/2019"
    private let removedResult = "СНЯТО ПО ДРУГИМ ОСНОВАНИЯМ"

    func testNoUIDAppealRepairsPersistentMaterialChainAfterCaptchaAndRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-290-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let appealCard = try fixtureCard(
            "issue289_subject_appeal_removed", url: appealURL())
        let lowerCard = try fixtureCard("issue290_lower_material", url: lowerURL())
        XCTAssertNil(appealCard.uid)
        XCTAssertNil(lowerCard.uid)

        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let context = appealContext()
        var snapshot = MovementDerivation.snapshot(from: appealMovement(), context: context)
        snapshot.deadlines = [StoredDeadline(
            kind: "custom", what: "Пользовательский срок", basis: "fixture",
            calLabel: "ручной", dateRef: 123,
            statusRaw: DeadlineStatus.confirmed.rawValue,
            occurrenceKey: "issue-290-user-deadline")]
        let record = try store.upsert(context: context, snapshot: snapshot,
                                      movement: appealMovement(), collections: ["Уголовные"])
        let stableKey = record.key
        let seenAt = Date(timeIntervalSinceReferenceDate: 290)
        record.seenAt = seenAt
        let event = CaseEvent.make(
            kind: .judicialActPublished, occurrence: ["issue-290-seed"],
            observedAt: Date(timeIntervalSinceReferenceDate: 1), evidence: .init())
        record.eventJournal = CaseEventJournal(events: [event])
        try store.save()

        let provider = Issue290Provider(lowerCard: lowerCard)
        let resolver = try originResolver(provider: provider, directory: directory)
        let suiteName = "Issue290ChainRecoveryIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([stableKey], forKey: "importChainRepair.v6.completed")
        defaults.set([stableKey], forKey: "importChainRepair.v6.unsupported")
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: resolver,
            defaults: defaults, anchorCardFetcher: { _ in appealCard })

        let captcha = try await coordinator.repairIfNeeded(key: stableKey)
        XCTAssertEqual(captcha.summary.captchaRequests.count, 1)
        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(store.record(forKey: stableKey)?.context?.caseNumber,
                       appealPublishedNumber)

        await provider.allowSearch()
        let repair = try await coordinator.repairIfNeeded(key: stableKey)
        XCTAssertEqual(repair.effectiveKey, stableKey)
        XCTAssertEqual(repair.summary.restoredMaterials, 1)
        let repaired = try XCTUnwrap(store.record(forKey: stableKey))
        let repairedMovement = try XCTUnwrap(repaired.movement)
        let repairedSnapshot = try XCTUnwrap(repaired.snapshot)

        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(repaired.key, stableKey)
        XCTAssertEqual(repaired.caseNumber, lowerNumber)
        XCTAssertEqual(repaired.context?.caseNumber, lowerNumber)
        XCTAssertEqual(repaired.context?.baseInstanceLevel, .material)
        XCTAssertEqual(repaired.context?.cartotekaId, "m")
        XCTAssertNil(repaired.context?.judicialUID)
        XCTAssertEqual(repaired.collectionNames, ["Уголовные"])
        XCTAssertEqual(repaired.seenAt, seenAt)
        XCTAssertTrue(repaired.eventJournal?.events.contains(event) == true)
        XCTAssertTrue(repairedMovement.acts.contains { $0.id == "issue-290-appeal-act" })
        XCTAssertEqual(repairedMovement.actBodies["issue-290-appeal-act"],
                       "Сохранённый текст апелляционного акта")
        XCTAssertEqual(repairedSnapshot.deadlines.first {
            $0.occurrenceKey == "issue-290-user-deadline"
        }?.status, .confirmed)
        XCTAssertEqual(repairedSnapshot.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(repairedSnapshot.statusText, removedResult)
        XCTAssertFalse(repairedSnapshot.inForce)
        XCTAssertEqual(MaterialProductionContext.resolve(
            context: repaired.context, movement: repaired.movement).production, .crim)
        XCTAssertTrue(repaired.context?.knownCards?.contains {
            $0.caseNumber == appealPublishedNumber
        } == true)
        let aliases = AppRouter.caseNumberAliases(for: repaired).searchable
        XCTAssertTrue(aliases.contains { $0.contains(appealNumber) })
        XCTAssertTrue(aliases.contains { $0.contains("22-8976/2019") })
        XCTAssertEqual(repaired.caseNumber, lowerNumber)

        _ = try await coordinator.runAll()
        let searches = await provider.searches
        XCTAssertEqual(searches, 2,
                       "после переякоривания самостоятельный материал не ищется повторно")

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        let persisted = try XCTUnwrap(reopened.record(forKey: stableKey))
        XCTAssertEqual(reopened.all().count, 1)
        XCTAssertEqual(persisted.caseNumber, lowerNumber)
        XCTAssertEqual(persisted.snapshot?.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(persisted.snapshot?.statusText, removedResult)
        XCTAssertFalse(persisted.snapshot?.inForce ?? true)
        XCTAssertTrue(AppRouter.caseNumberAliases(for: persisted)
            .searchable.contains { $0.contains("22-8976/2019") })
        XCTAssertTrue(persisted.eventJournal?.events.contains(event) == true)
    }

    func testSeparatelyTrackedLowerMaterialMergesIntoOneDossier() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-290-merge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let appealCard = try fixtureCard(
            "issue289_subject_appeal_removed", url: appealURL())
        let lowerCard = try fixtureCard("issue290_lower_material", url: lowerURL())
        let store = TrackedStore(inMemory: true)
        let lower = try store.upsert(
            context: lowerContext(), snapshot: nil, movement: lowerMovement(lowerCard),
            collections: ["Материал"])
        let appeal = try store.upsert(
            context: appealContext(), snapshot: nil, movement: appealMovement(),
            collections: ["Апелляция"])
        XCTAssertEqual(store.all().count, 2)

        let provider = Issue290Provider(lowerCard: lowerCard)
        await provider.allowSearch()
        let resolver = try originResolver(provider: provider, directory: directory)
        let suiteName = "Issue290ChainRecoveryMergeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: resolver,
            defaults: defaults, anchorCardFetcher: { _ in appealCard })

        let repair = try await coordinator.repairIfNeeded(key: appeal.key)
        let survivor = try XCTUnwrap(store.record(forKey: repair.effectiveKey))

        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(Set(survivor.collectionNames), Set(["Материал", "Апелляция"]))
        XCTAssertTrue(store.record(forLocator: appeal.key) === survivor)
        XCTAssertTrue(store.record(forLocator: lower.key) === survivor)
        XCTAssertEqual(survivor.context?.caseNumber, lowerNumber)
        XCTAssertEqual(survivor.snapshot?.stageRaw, CaseStageKind.done.rawValue)
        XCTAssertEqual(survivor.snapshot?.statusText, removedResult)
        XCTAssertEqual(survivor.movement?.instances.filter {
            $0.caseNumber == appealNumber
        }.count, 1)
        XCTAssertEqual(survivor.movement?.instances.filter {
            $0.caseNumber == lowerNumber
        }.count, 1)
    }

    private func appealContext() -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Город Санкт-Петербург",
            searchDomain: "sankt-peterburgsky--spb.sudrf.ru",
            displayDomain: "sankt-peterburgsky.spb.sudrf.ru",
            courtTitle: "Санкт-Петербургский городской суд",
            courtLevelRaw: CourtLevel.subject.rawValue, courtCode: "78OS0000",
            cartotekaId: "u2", cartotekaLevelRaw: CourtLevel.subject.rawValue,
            caseNumber: appealPublishedNumber, caseID: "107129947",
            caseUID: "1e76ee9f-cdd4-496e-9162-558c3888f91e",
            cardURLString: appealURL().absoluteString, judicialUID: nil,
            baseInstanceLevelRaw: CaseInstance.Level.appeal.rawValue)
    }

    private func appealMovement() -> CaseMovement {
        let act = CaseAct(id: "issue-290-appeal-act", title: "Апелляционное определение",
                          date: "23.01.2020", courtShort: "Санкт-Петербургский городской суд",
                          instanceLevel: .appeal)
        let instance = CaseInstance(
            level: .appeal, court: "Санкт-Петербургский городской суд",
            caseNumber: appealNumber, judge: "Афанасьева Людмила Сергеевна",
            domain: "sankt-peterburgsky.spb.sudrf.ru", foundByUID: false,
            result: removedResult,
            sessions: [CaseSession(date: "23.01.2020", time: "16:00",
                                   event: "Судебное заседание", result: removedResult)],
            actID: act.id)
        return CaseMovement(
            uid: "", caseNumber: appealNumber, inForce: false,
            instances: [instance], complaints: [:], acts: [act],
            actBodies: [act.id: "Сохранённый текст апелляционного акта"])
    }

    private func lowerContext() -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Город Санкт-Петербург",
            searchDomain: "oktibrsky--spb.sudrf.ru",
            displayDomain: "oktibrsky.spb.sudrf.ru",
            courtTitle: "Октябрьский районный суд города Санкт-Петербурга",
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: "78RS0016",
            cartotekaId: "m", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: lowerNumber, caseID: "892526215",
            caseUID: "7c9bc768-720c-4537-a3b3-6ab56e36fc5f",
            cardURLString: lowerURL().absoluteString, judicialUID: nil,
            baseInstanceLevelRaw: CaseInstance.Level.material.rawValue)
    }

    private func lowerMovement(_ card: CaseCard) -> CaseMovement {
        let instance = CaseInstance(
            level: .material, court: "Октябрьский районный суд города Санкт-Петербурга",
            caseNumber: lowerNumber, judge: card.judge,
            domain: "oktibrsky.spb.sudrf.ru", foundByUID: false,
            result: card.result, sessions: card.sessions)
        return CaseMovement(uid: "", caseNumber: lowerNumber, inForce: false,
                            instances: [instance], complaints: [:], acts: [])
    }

    private func originResolver(provider: Issue290Provider, directory: URL) throws
        -> CaseOriginResolver {
        let cacheURL = directory.appendingPathComponent("districts.json")
        let court = DistrictCourt(
            title: "Октябрьский районный суд города Санкт-Петербурга",
            domain: "oktibrsky.spb.sudrf.ru", code: "78RS0016", regionCode: "spb",
            kind: .district, portalSubject: "78")
        try JSONEncoder().encode([court]).write(to: cacheURL)
        return CaseOriginResolver(
            client: SudrfClient(),
            districtResolver: DistrictCourtResolver(client: SudrfClient(), cacheURL: cacheURL),
            regularProvider: provider)
    }

    private func fixtureCard(_ name: String, url: URL) throws -> CaseCard {
        let tests = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = tests.appendingPathComponent("SudrfKitTests/Fixtures/\(name).html")
        return try CaseCardParser.parse(
            html: String(contentsOf: fixture, encoding: .utf8), cardURL: url)
    }

    private func appealURL() -> URL {
        URL(string: "https://sankt-peterburgsky--spb.sudrf.ru/modules.php"
            + "?name=sud_delo&srv_num=1&name_op=case&case_id=107129947"
            + "&case_uid=1e76ee9f-cdd4-496e-9162-558c3888f91e&delo_id=4&new=4")!
    }

    private func lowerURL() -> URL {
        URL(string: "https://oktibrsky--spb.sudrf.ru/modules.php"
            + "?name=sud_delo&srv_num=1&name_op=case&case_id=892526215"
            + "&case_uid=7c9bc768-720c-4537-a3b3-6ab56e36fc5f&delo_id=1610001")!
    }
}
