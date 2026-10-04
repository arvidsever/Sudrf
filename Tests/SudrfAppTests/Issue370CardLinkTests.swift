import Foundation
import SwiftData
import XCTest
import SudrfKit
@testable import SudrfApp

private actor Issue370MovementSequence: MovementProviding {
    private let values: [CaseMovement]
    private var index = 0

    init(_ values: [CaseMovement]) { self.values = values }

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        defer { index += 1 }
        return values[min(index, values.count - 1)]
    }
}

@MainActor
final class Issue370CardLinkTests: XCTestCase {
    private let manualDeadlineKey = "issue-370-manual"
    private let manualDeadlineDate = DateUtil.parse("01.01.2030")!
    private let syntheticActText = """
        ОПРЕДЕЛИЛ:
        Определение Сыктывкарского городского суда от 16 февраля 2026 года.
        Апелляционное определение от 23 апреля 2026 года оставить без изменения.
        """

    func testExactCassationCardLinkSurvivesDiskRefreshRepeatAndPartialRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-370-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixtureURL = try XCTUnwrap(Bundle.module.url(
            forResource: "issue370_exact_card_link", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode(CaseMovement.self, from: Data(contentsOf: fixtureURL))
        XCTAssertEqual(fixture.instances.count, 4)
        XCTAssertEqual(fixture.acts.count, 2)
        XCTAssertTrue(fixture.actBodies.isEmpty)

        let cassationNumber = "8Г-13509/2026 [88-13567/2026]"
        let exactURL = "https://3kas.sudrf.ru/modules.php?name=sud_delo&srv_num=1&name_op=case"
            + "&case_id=24704983&case_uid=2b58299d-bb41-4c0a-8b69-ba7977ee335d"
            + "&new=2800001&delo_id=2800001"
        let cassation = try XCTUnwrap(fixture.instances.first { $0.caseNumber == cassationNumber })
        XCTAssertEqual(cassation.sourceURL?.absoluteString, exactURL)
        let cassationActID = try XCTUnwrap(cassation.actID)

        // Synthetic QA text exercises the material-aware timeline resolver; it is not source act text.
        var cachedMovement = fixture
        cachedMovement.actBodies[cassationActID] = syntheticActText
        let initialMainTimeline = CaseLifecycleResolver.timeline(
            in: cachedMovement, production: .civil)
        XCTAssertEqual(initialMainTimeline.lifecycleOrdered.map(\.instance.caseNumber),
                       [fixture.caseNumber])

        let root = try XCTUnwrap(fixture.instances.first { $0.level == .first })
        let rootURL = try XCTUnwrap(root.sourceURL)
        let rootQuery = URLComponents(url: rootURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: root.domain, displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: root.court, courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS0001", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: fixture.caseNumber,
            caseID: rootQuery.first { $0.name == "case_id" }?.value,
            caseUID: rootQuery.first { $0.name == "case_uid" }?.value,
            judicialUID: fixture.uid,
            baseInstanceLevelRaw: CaseInstance.Level.first.rawValue)
        context.cardURLString = rootURL.absoluteString

        var partialMovement = cachedMovement
        partialMovement.instances.removeAll { $0.domain == "3kas.sudrf.ru" }
        partialMovement.acts.removeAll { $0.id == cassationActID }
        partialMovement.actBodies = [:]
        partialMovement.incompleteHigherCourtDomains = ["3kas.sudrf.ru"]

        let storeURL = directory.appendingPathComponent("tracked.store")
        let key: String
        let seenAt = Date(timeIntervalSince1970: 1_700_000_000)
        let seedEvent = CaseEvent.make(
            kind: .complaintRegistered, occurrence: ["issue-370-seed"],
            observedAt: Date(timeIntervalSinceReferenceDate: 1), evidence: .init())

        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let store = try TrackedStore(container: container, prepared: true)
            var snapshot = MovementDerivation.snapshot(
                from: cachedMovement, context: context, today: DateUtil.parse("26.09.2026")!)
            snapshot.deadlines.append(StoredDeadline(
                kind: "custom", what: "Пользовательский срок", basis: "Тест #370",
                calLabel: "ручной", dateRef: manualDeadlineDate.timeIntervalSinceReferenceDate,
                statusRaw: DeadlineStatus.confirmed.rawValue,
                occurrenceKey: manualDeadlineKey,
                lifecycleRaw: DeadlineLifecycle.active.rawValue))
            let record = try store.upsert(
                context: context, snapshot: snapshot, movement: cachedMovement,
                collections: ["Проверка #370"])
            key = record.key
            record.seenAt = seenAt
            record.eventJournal = CaseEventJournal(events: [seedEvent])
            try store.save()
        }

        do {
            let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
            let store = try TrackedStore(container: container, prepared: true)
            try assertPersistedState(store: store, key: key, seenAt: seenAt,
                                     seedEvent: seedEvent, expectedActs: fixture.acts,
                                     exactURL: exactURL, cassationNumber: cassationNumber,
                                     cassationActID: cassationActID)

            let provider = Issue370MovementSequence([cachedMovement, cachedMovement, partialMovement])
            var suppliedContexts: [MovementContext] = []
            let center = RefreshCenter(store: store, client: SudrfClient(), serviceBuilder: { ctx in
                suppliedContexts.append(ctx)
                return provider
            })

            let firstRefresh = await center.refresh(key: key)?.value
            XCTAssertEqual(firstRefresh?.outcome, .refreshed)
            try assertPersistedState(store: store, key: key, seenAt: seenAt,
                                     seedEvent: seedEvent, expectedActs: fixture.acts,
                                     exactURL: exactURL, cassationNumber: cassationNumber,
                                     cassationActID: cassationActID)

            let repeatedRefresh = await center.refresh(key: key)?.value
            XCTAssertEqual(repeatedRefresh?.outcome, .refreshed)
            try assertPersistedState(store: store, key: key, seenAt: seenAt,
                                     seedEvent: seedEvent, expectedActs: fixture.acts,
                                     exactURL: exactURL, cassationNumber: cassationNumber,
                                     cassationActID: cassationActID)

            guard case .partial = await center.refresh(key: key)?.value.outcome else {
                return XCTFail("Частичный ответ без 3 КСОЮ должен сохранить проверенную карточку")
            }
            try assertPersistedState(store: store, key: key, seenAt: seenAt,
                                     seedEvent: seedEvent, expectedActs: fixture.acts,
                                     exactURL: exactURL, cassationNumber: cassationNumber,
                                     cassationActID: cassationActID)

            XCTAssertEqual(suppliedContexts.count, 3)
            for supplied in suppliedContexts {
                let cards = supplied.knownCards ?? []
                let exactCards = cards.filter { $0.caseNumber == cassationNumber }
                XCTAssertEqual(exactCards.count, 1)
                let card = try XCTUnwrap(exactCards.first)
                XCTAssertEqual(card.sourceURL?.absoluteString, exactURL)
                XCTAssertEqual(card.caseID, "24704983")
                XCTAssertEqual(card.caseUID, "2b58299d-bb41-4c0a-8b69-ba7977ee335d")
                XCTAssertEqual(card.deloID, "2800001")
                XCTAssertEqual(card.new, "2800001")
                let query = URLComponents(url: try XCTUnwrap(card.sourceURL),
                                          resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertEqual(query.first { $0.name == "srv_num" }?.value, "1")
            }
        }

        let reopenedContainer = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        try assertPersistedState(store: reopened, key: key, seenAt: seenAt,
                                 seedEvent: seedEvent, expectedActs: fixture.acts,
                                 exactURL: exactURL, cassationNumber: cassationNumber,
                                 cassationActID: cassationActID)
    }

    private func assertPersistedState(
        store: TrackedStore, key: String, seenAt: Date, seedEvent: CaseEvent,
        expectedActs: [CaseAct], exactURL: String, cassationNumber: String,
        cassationActID: String
    ) throws {
        XCTAssertEqual(store.all().count, 1, "refresh не должен создавать вторую запись")
        let record = try XCTUnwrap(store.record(forKey: key))
        XCTAssertEqual(record.collectionNames, ["Проверка #370"])
        XCTAssertEqual(record.seenAt, seenAt)
        XCTAssertEqual(record.eventJournal, CaseEventJournal(events: [seedEvent]),
                       "refresh не должен добавлять повторные/старые события")

        let manual = try XCTUnwrap(record.snapshot?.deadlines.first {
            $0.occurrenceKey == manualDeadlineKey
        })
        XCTAssertEqual(manual.date, manualDeadlineDate)
        XCTAssertEqual(manual.status, .confirmed)
        XCTAssertEqual(manual.lifecycle, .active)

        let movement = try XCTUnwrap(record.movement)
        XCTAssertEqual(movement.instances.count, 4)
        XCTAssertEqual(movement.acts, expectedActs)
        XCTAssertEqual(Set(movement.acts.map(\.id)).count, 2)
        XCTAssertEqual(movement.actBodies[cassationActID], syntheticActText)
        let matchingCards = movement.instances.filter { $0.caseNumber == cassationNumber }
        XCTAssertEqual(matchingCards.count, 1, "карточка КСОЮ не должна дублироваться")
        let cassation = try XCTUnwrap(matchingCards.first)
        XCTAssertEqual(cassation.sourceURL?.absoluteString, exactURL)
        XCTAssertEqual(cassation.actID, cassationActID)

        let timeline = CaseLifecycleResolver.timeline(in: movement, production: .civil)
        XCTAssertEqual(timeline.lifecycleOrdered.map(\.instance.caseNumber), [movement.caseNumber],
                       "материальный акт и его review не должны попасть в main timeline")
    }
}
