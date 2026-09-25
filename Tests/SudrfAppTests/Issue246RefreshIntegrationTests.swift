import Foundation
import XCTest
import SudrfKit
@testable import SudrfApp

private actor Issue246OriginProvider: CaseProviding {
    let uid: String
    let row: CaseSearchResult
    let card: CaseCard

    init(uid: String, row: CaseSearchResult, card: CaseCard) {
        self.uid = uid
        self.row = row
        self.card = card
    }

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        field == .uid && value == uid && cartoteka.id == "g1" ? [row] : []
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        guard caseID == row.caseID, caseUID == row.caseUID else {
            throw SudrfError.http(status: 404)
        }
        return card
    }

    func fetchCard(url: URL) async throws -> CaseCard {
        throw SudrfError.http(status: 404)
    }
}

private actor Issue246Movements: MovementProviding {
    private var values: [CaseMovement]
    private(set) var requestedNumbers: [String] = []

    init(_ values: [CaseMovement]) { self.values = values }

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        requestedNumbers.append(base.caseNumber)
        return values.removeFirst()
    }

    func requests() -> [String] { requestedNumbers }
}

@MainActor
final class Issue246RefreshIntegrationTests: XCTestCase {
    private let uid = "11RS0020-01-2026-001096-98"
    private let oldNumber = "9-89/2026 ~ М-758/2026"
    private let appealNumber = "33-4096/2026"
    private let currentNumber = "2-1326/2026"

    func testAcceptedCivilRegistrationBecomesCurrentAndSurvivesRefreshAndReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-246-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)

        let old = try context(number: oldNumber, caseID: "old-9-89", caseUID: "old-guid")
        let current = try context(number: currentNumber, caseID: "current-2-1326",
                                  caseUID: "current-guid")
        var cached = try movement(current: false, oldContext: old, currentContext: current)
        cached.instances.removeAll { $0.caseNumber == currentNumber }
        cached.caseNumber = oldNumber
        var oldSnapshot = MovementDerivation.snapshot(from: cached, context: old)
        oldSnapshot.deadlines = [
            StoredDeadline(
                kind: "appeal", what: "Частная жалоба на возврат", basis: "fixture",
                calLabel: "старый срок", dateRef: DateUtil.parse("01.09.2026")!.timeIntervalSinceReferenceDate,
                statusRaw: DeadlineStatus.proposed.rawValue,
                occurrenceKey: "issue-246-return-deadline"),
            StoredDeadline(
                kind: "custom", what: "Пользовательский срок", basis: "fixture",
                calLabel: "ручной", dateRef: DateUtil.parse("20.10.2026")!.timeIntervalSinceReferenceDate,
                statusRaw: DeadlineStatus.confirmed.rawValue,
                occurrenceKey: "issue-246-user-deadline")
        ]
        let record = try store.upsert(context: old, snapshot: oldSnapshot,
                                      movement: cached, collections: ["Гражданские"])
        let stableKey = record.key
        try store.appendCaseEvents([
            CaseEvent.make(
                kind: .judicialActPublished, occurrence: ["issue-246-seed"],
                observedAt: Date(timeIntervalSinceReferenceDate: 1),
                evidence: CaseEventEvidence(caseNumber: oldNumber, value: "old-return-act"))
        ], to: record)
        try store.save()

        let currentCard = CaseCard(
            rawText: "", actText: nil,
            sessions: [CaseSession(date: "11.09.2026", event: "Исковое заявление принято к производству")],
            uid: uid, caseNumber: currentNumber, category: "Гражданский спор",
            previousRegistration: PreviousRegistrationReference(
                caseNumber: oldNumber, url: try XCTUnwrap(URL(string: old.cardURLString!))),
            processKind: .civil)
        let row = CaseSearchResult(
            caseNumber: currentNumber, caseID: current.caseID, caseUID: current.caseUID,
            cardURL: try XCTUnwrap(URL(string: current.cardURLString!)))
        let provider = Issue246OriginProvider(uid: uid, row: row, card: currentCard)
        let resolver = CaseOriginResolver(client: SudrfClient(), regularProvider: provider)
        let suiteName = "Issue246RefreshIntegrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = TrackedCaseRepairCoordinator(
            store: store, client: SudrfClient(), originResolver: resolver,
            defaults: defaults, anchorCardFetcher: { [uid, oldNumber] _ in
                CaseCard(rawText: "", actText: nil, uid: uid, caseNumber: oldNumber)
            })

        let refreshed = try movement(current: true, oldContext: old, currentContext: current)
        var partial = refreshed
        partial.incompleteHigherCourtDomains = ["vs--komi.sudrf.ru"]
        let service = Issue246Movements([refreshed, partial])
        let center = RefreshCenter(store: store, client: SudrfClient(),
                                   serviceBuilder: { _ in service })
        center.repairBeforeRefresh = { key, _ in
            try await coordinator.repairIfNeeded(key: key).effectiveKey
        }

        let firstExecution = await center.refresh(key: stableKey)?.value
        XCTAssertEqual(firstExecution?.outcome, .refreshed)
        let promoted = try XCTUnwrap(store.record(forKey: stableKey))
        let firstFetchedAt = promoted.movementFetchedAt
        let firstJournal = promoted.eventJournal

        XCTAssertEqual(store.all().count, 1)
        XCTAssertEqual(promoted.key, stableKey)
        XCTAssertEqual(promoted.caseNumber, currentNumber)
        XCTAssertEqual(promoted.context?.caseNumber, currentNumber)
        XCTAssertEqual(promoted.movement?.caseNumber, currentNumber)
        XCTAssertEqual(promoted.collectionNames, ["Гражданские"])
        XCTAssertEqual(MaterialProductionContext.resolve(
            context: promoted.context, movement: promoted.movement).production, .civil)
        XCTAssertFalse(MaterialProductionContext.resolve(
            context: promoted.context, movement: promoted.movement).isMaterial)
        XCTAssertEqual(promoted.snapshot?.stageRaw, CaseStageKind.first.rawValue)
        XCTAssertEqual(promoted.snapshot?.deadlines.first {
            $0.occurrenceKey == "issue-246-return-deadline"
        }?.lifecycle, .superseded)
        XCTAssertEqual(promoted.snapshot?.deadlines.first {
            $0.occurrenceKey == "issue-246-user-deadline"
        }?.status, .confirmed)
        XCTAssertEqual(promoted.movement?.instances.first {
            $0.caseNumber == oldNumber
        }?.note, "Предыдущая регистрация")
        XCTAssertNotNil(promoted.movement?.instances.first { $0.caseNumber == appealNumber })
        XCTAssertTrue(promoted.movement?.acts.contains { $0.id == "old-return-act" } == true)
        XCTAssertEqual(promoted.movement?.actBodies["old-return-act"], "Определение о возврате")
        XCTAssertTrue((firstJournal?.events.contains { $0.kind == .judicialActPublished }) == true)
        XCTAssertTrue(AppRouter.caseNumberAliases(for: promoted).searchable.contains(oldNumber))
        XCTAssertTrue(store.record(forLocator: current.key) === promoted)
        let firstRequests = await service.requests()
        XCTAssertEqual(firstRequests, [currentNumber])

        let secondExecution = await center.refresh(key: stableKey)?.value
        XCTAssertEqual(secondExecution?.outcome,
                       .partial("Не обновился источник vs--komi.sudrf.ru; сохранены последние успешные данные."))
        let afterPartial = try XCTUnwrap(store.record(forKey: stableKey))
        XCTAssertEqual(afterPartial.caseNumber, currentNumber)
        XCTAssertEqual(afterPartial.movementFetchedAt, firstFetchedAt)
        XCTAssertEqual(afterPartial.eventJournal, firstJournal)
        XCTAssertNotNil(afterPartial.movement?.instances.first { $0.caseNumber == appealNumber })
        let secondRequests = await service.requests()
        XCTAssertEqual(secondRequests, [currentNumber, currentNumber])

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: storeURL)
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        let persisted = try XCTUnwrap(reopened.record(forKey: stableKey))
        XCTAssertEqual(reopened.all().count, 1)
        XCTAssertEqual(persisted.caseNumber, currentNumber)
        XCTAssertEqual(persisted.context?.caseNumber, currentNumber)
        XCTAssertEqual(persisted.movement?.caseNumber, currentNumber)
        XCTAssertEqual(persisted.collectionNames, ["Гражданские"])
        XCTAssertNotNil(persisted.movement?.instances.first { $0.caseNumber == oldNumber })
        XCTAssertNotNil(persisted.movement?.instances.first { $0.caseNumber == appealNumber })
        XCTAssertEqual(persisted.eventJournal, firstJournal)
        XCTAssertTrue(AppRouter.caseNumberAliases(for: persisted).searchable.contains(oldNumber))
    }

    private func context(number: String, caseID: String,
                         caseUID: String) throws -> MovementContext {
        let cartoteka = try XCTUnwrap(CartotekaRegistry.find(level: .district, id: "g1"))
        let url = try cardURL(domain: "uwsud--komi.sudrf.ru", cartoteka: cartoteka,
                              caseID: caseID, caseUID: caseUID)
        var context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "uwsud--komi.sudrf.ru", displayDomain: "uwsud.komi.sudrf.ru",
            courtTitle: "Усть-Вымский районный суд Республики Коми",
            courtLevelRaw: CourtLevel.district.rawValue, courtCode: "11RS0020",
            cartotekaId: "g1", cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: number, caseID: caseID, caseUID: caseUID,
            cardURLString: url.absoluteString)
        context.judicialUID = uid
        context.baseInstanceLevelRaw = CaseInstance.Level.first.rawValue
        return context
    }

    private func movement(current hasCurrent: Bool, oldContext: MovementContext,
                          currentContext: MovementContext) throws -> CaseMovement {
        let oldURL = try XCTUnwrap(URL(string: oldContext.cardURLString!))
        let currentURL = try XCTUnwrap(URL(string: currentContext.cardURLString!))
        let appealCart = try XCTUnwrap(CartotekaRegistry.find(level: .subject, id: "g2"))
        let appealURL = try cardURL(domain: "vs--komi.sudrf.ru", cartoteka: appealCart,
                                    caseID: "appeal-33-4096", caseUID: "appeal-guid")
        var instances = [
            CaseInstance(
                level: .first, court: oldContext.courtTitle, caseNumber: oldNumber,
                judge: nil, domain: oldContext.searchDomain, foundByUID: false,
                result: "Заявление ВОЗВРАЩЕНО заявителю",
                sessions: [CaseSession(date: "10.08.2026", event: "Вынесено определение", result: "Заявление возвращено")],
                actID: "old-return-act", sourceURL: oldURL,
                sourceEvidence: .init(judicialUID: uid, cartotekaID: "g1",
                                      sourceCourtLevel: .district, sourceBranch: .general)),
            CaseInstance(
                level: .appeal, court: "Верховный Суд Республики Коми",
                caseNumber: appealNumber, judge: nil, domain: "vs--komi.sudrf.ru",
                foundByUID: true,
                result: "определение отменено полностью с разрешением вопроса по существу",
                sessions: [CaseSession(
                    date: "24.08.2026", event: "Рассмотрение частной жалобы",
                    result: "Определение о возврате отменено")],
                actID: "appeal-cancellation-act", sourceURL: appealURL,
                sourceEvidence: .init(
                    appealKinds: ["Частная жалоба"],
                    lowerCourt: LowerCourtReference(
                        region: "11 - Республика Коми", courtTitle: oldContext.courtTitle,
                        caseNumber: oldNumber), receiptDate: "17.08.2026",
                    decisionDate: "24.08.2026", judicialUID: uid,
                    cartotekaID: "g2", sourceCourtLevel: .subject,
                    sourceBranch: .general))
        ]
        if hasCurrent {
            instances[0].note = "Предыдущая регистрация"
            instances.insert(CaseInstance(
                level: .first, court: currentContext.courtTitle, caseNumber: currentNumber,
                judge: nil, domain: currentContext.searchDomain, foundByUID: false,
                result: nil,
                sessions: [CaseSession(date: "11.09.2026", event: "Исковое заявление принято к производству")],
                sourceURL: currentURL,
                previousRegistration: PreviousRegistrationReference(
                    caseNumber: oldNumber, url: oldURL),
                sourceEvidence: .init(
                    judicialUID: uid, cartotekaID: "g1", sourceCourtLevel: .district,
                    sourceBranch: .general, category: "Гражданский спор", ownProcessKind: .civil)), at: 0)
        }
        return CaseMovement(
            uid: uid, caseNumber: hasCurrent ? currentNumber : oldNumber, inForce: false,
            instances: instances, complaints: [:],
            acts: [
                CaseAct(id: "old-return-act", title: "Определение", date: "10.08.2026",
                        courtShort: oldContext.courtTitle, instanceLevel: .first),
                CaseAct(id: "appeal-cancellation-act", title: "Апелляционное определение",
                        date: "24.08.2026", courtShort: "ВС Республики Коми", instanceLevel: .appeal)
            ],
            actBodies: [
                "old-return-act": "Определение о возврате",
                "appeal-cancellation-act": "Определение о возврате отменено"
            ], category: hasCurrent ? "Гражданский спор" : nil)
    }

    private func cardURL(domain: String, cartoteka: Cartoteka,
                         caseID: String, caseUID: String) throws -> URL {
        try XCTUnwrap(URL(string:
            "https://\(domain)/modules.php?name=sud_delo&srv_num=1&name_op=case"
                + "&case_id=\(caseID)&case_uid=\(caseUID)"
                + "&delo_id=\(cartoteka.deloID)&new=\(cartoteka.new)"))
    }
}
