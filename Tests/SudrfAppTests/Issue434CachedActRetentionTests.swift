import XCTest
import Foundation
@testable import SudrfKit
@testable import SudrfApp

private struct Issue434FixtureCaseProvider: CaseProviding {
    let card: CaseCard
    let cardURL: URL
    let caseNumber: String
    let judicialUID: String

    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult] {
        guard field == .uid, value == judicialUID, cartoteka.id == "g3" else { return [] }
        return [CaseSearchResult(caseNumber: caseNumber, caseID: "2723657",
                                 caseUID: "576e5fae-ee46-434a-99eb-5956562963b0",
                                 cardURL: cardURL)]
    }

    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard {
        guard caseID == "2723657", caseUID == "576e5fae-ee46-434a-99eb-5956562963b0",
              deloID == "43", new == "0" else { throw SudrfError.http(status: 404) }
        return card
    }

    func fetchCard(url: URL) async throws -> CaseCard {
        guard url == cardURL else { throw SudrfError.http(status: 404) }
        return card
    }
}

private struct Issue434FixtureMovementProvider: MovementProviding {
    let source: Issue434FixtureCaseProvider
    let partial: Bool

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        let service = MovementService(
            client: source, higherCourtDomains: [], higherCourtTargets: [],
            baseInstanceLevel: .cassation, judicialUID: source.judicialUID,
            branch: .general)
        var movement = try await service.movement(for: base, court: court,
                                                  cartoteka: cartoteka)
        movement.incompleteHigherCourtDomains = partial ? [court.domain] : nil
        movement.honestZeroDomains = nil
        return movement
    }
}

private final class Issue434OfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTFail("Unexpected network request in offline #434 test: \(request.url?.absoluteString ?? "<missing URL>")")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }

    override func stopLoading() {}
}

@MainActor
final class Issue434CachedActRetentionTests: XCTestCase {
    private let cardURL = URL(string: "https://2kas.sudrf.ru/modules.php"
        + "?name=sud_delo&srv_num=1&name_op=case&case_id=2723657"
        + "&case_uid=576e5fae-ee46-434a-99eb-5956562963b0&new=0&delo_id=43")!
    private let body = "Синтетический текст, сохранённый до обновления карточки"

    private func fixtures() throws -> (CaseCard, Issue434FixtureCaseProvider) {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../SudrfKitTests/Fixtures/issue322_ksoyu_8501.html")
            .standardizedFileURL
        let html = try String(contentsOf: path, encoding: .utf8)
        let card = try CaseCardParser.parse(html: html)
        let number = try XCTUnwrap(card.caseNumber)
        let uid = try XCTUnwrap(card.uid)
        return (card, Issue434FixtureCaseProvider(card: card, cardURL: cardURL,
                                                  caseNumber: number, judicialUID: uid))
    }

    private func context(card: CaseCard) throws -> MovementContext {
        var context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "город Москва",
            searchDomain: "2kas.sudrf.ru", displayDomain: "2kas.sudrf.ru",
            courtTitle: "Второй кассационный суд общей юрисдикции",
            courtLevelRaw: CourtLevel.cassation.rawValue, courtCode: nil,
            cartotekaId: "g3", cartotekaLevelRaw: CourtLevel.cassation.rawValue,
            caseNumber: try XCTUnwrap(card.caseNumber), caseID: "2723657",
            caseUID: "576e5fae-ee46-434a-99eb-5956562963b0",
            cardURLString: cardURL.absoluteString)
        context.judicialUID = card.uid
        context.baseInstanceLevelRaw = CaseInstance.Level.cassation.rawValue
        context.higherCourtTargets = []
        return context
    }

    private func offlineClient() -> SudrfClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Issue434OfflineURLProtocol.self]
        return SudrfClient(session: URLSession(configuration: configuration), minInterval: 0,
                           variantStore: WorkingVariantStore(cacheURL: nil),
                           captchaStore: CaptchaTokenStore())
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-434-acceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func center(store: TrackedStore, source: Issue434FixtureCaseProvider,
                        partial: Bool) -> RefreshCenter {
        RefreshCenter(store: store, client: offlineClient(), serviceBuilder: { _ in
            Issue434FixtureMovementProvider(source: source, partial: partial)
        })
    }

    private func assertRetainedAct(_ record: TrackedCaseRecord,
                                   number: String, file: StaticString = #filePath,
                                   line: UInt = #line) {
        guard let movement = record.movement else {
            return XCTFail("movement disappeared", file: file, line: line)
        }
        let actID = "act_2kas.sudrf.ru#\(number)"
        XCTAssertEqual(movement.acts.filter { $0.id == actID }.count, 1,
                       "one cached act must remain", file: file, line: line)
        XCTAssertEqual(movement.actBodies[actID], body, file: file, line: line)
        let source = movement.instances.first { $0.sourceURL == cardURL }
        XCTAssertTrue(source?.linkedActIDs.contains(actID) == true,
                      "retained text must still be linked to the exact source card",
                      file: file, line: line)
    }

    private func seedAndRefreshCompleteThenPartial(
        directory: URL
    ) async throws -> (key: String, fullSuccess: Date, journalIDs: [String]) {
        let (card, source) = try fixtures()
        XCTAssertNil(card.actText, "fixture intentionally has no inline act text")
        let context = try context(card: card)
        let cartoteka = try XCTUnwrap(context.cartoteka)
        let freshTemplate = try await Issue434FixtureMovementProvider(
            source: source, partial: false).movement(
                for: context.baseResult, court: context.searchCourt, cartoteka: cartoteka)
        let number = try XCTUnwrap(card.caseNumber)
        let actID = "act_2kas.sudrf.ru#\(number)"
        XCTAssertFalse(freshTemplate.acts.contains { $0.id == actID })
        XCTAssertNil(freshTemplate.actBodies[actID])

        var cached = MovementCachePolicy.stripped(forPersist: freshTemplate)
        let sourceIndex = try XCTUnwrap(cached.instances.firstIndex { $0.sourceURL == cardURL })
        cached.instances[sourceIndex].actID = actID
        cached.instances[sourceIndex].actIDs = [actID]
        let cachedAct = CaseAct(
            id: actID, title: "Определение из кэша",
            date: card.decisionDate ?? card.receiptDate ?? "—",
            courtShort: "2-й КСОЮ", instanceLevel: .cassation)
        cached.acts.append(cachedAct)
        cached.actBodies[actID] = body

        let mergedTemplate = MovementCachePolicy.merge(fresh: freshTemplate, cached: cached)
        let persistedTemplate = MovementCachePolicy.stripped(forPersist: mergedTemplate)
        XCTAssertEqual(cached.acts, persistedTemplate.acts)
        XCTAssertEqual(cached.complaints, persistedTemplate.complaints)
        XCTAssertEqual(cached.executionDocuments, persistedTemplate.executionDocuments)
        XCTAssertTrue(MovementDerivation.hasSameRefreshSource(cached, persistedTemplate),
                      "restoring an omitted act must reconstruct the previous movement facts")
        XCTAssertTrue(
            MovementDerivation.snapshot(from: cached, context: context).hasSameRefreshSource(
                as: MovementDerivation.snapshot(from: persistedTemplate, context: context)),
            "restoring the omitted act must preserve the previous semantic snapshot")

        let url = directory.appendingPathComponent("test.store")
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: url)
        let store = try TrackedStore(container: container, prepared: true)
        let addedAt = Date(timeIntervalSince1970: 100)
        let seenAt = Date(timeIntervalSince1970: 200)
        let previousSuccess = Date(timeIntervalSince1970: 300)
        let record = try store.upsert(
            context: context, snapshot: MovementDerivation.snapshot(from: cached, context: context),
            movement: cached, collections: ["Москва", "Лукьянова"])
        record.addedAt = addedAt
        record.seenAt = seenAt
        record.movementFetchedAt = previousSuccess
        let priorEvent = CaseEvent.make(
            kind: .instanceDiscovered, occurrence: ["issue434", number], observedAt: addedAt,
            evidence: CaseEventEvidence(instanceLevelRaw: CaseInstance.Level.cassation.rawValue,
                                        caseNumber: number))
        try store.appendCaseEvents([priorEvent], to: record)
        try store.save()

        let fullCenter = center(store: store, source: source, partial: false)
        let full = try XCTUnwrap(fullCenter.refresh(key: record.key))
        let fullExecution = await full.value
        XCTAssertEqual(fullExecution.outcome, .refreshed)
        let afterFull = try XCTUnwrap(store.record(forKey: record.key))
        assertRetainedAct(afterFull, number: number)
        XCTAssertEqual(afterFull.seenAt, seenAt,
                       "restoring an already-present cached act must not mark the case unread")
        let fullSuccess = try XCTUnwrap(afterFull.movementFetchedAt)
        XCTAssertGreaterThan(fullSuccess, previousSuccess)
        let fullJournalIDs = try XCTUnwrap(afterFull.eventJournal?.events.map(\.id))
        XCTAssertEqual(try XCTUnwrap(semanticJournalEvents(afterFull.eventJournal)).map(\.id), [priorEvent.id],
                       "refresh must not invent journal history for an unchanged fixture")

        let partialCenter = center(store: store, source: source, partial: true)
        let partial = try XCTUnwrap(partialCenter.refresh(key: afterFull.key))
        guard case .partial = await partial.value.outcome else {
            XCTFail("partial fixture refresh must remain partial")
            throw URLError(.cannotParseResponse)
        }
        let afterPartial = try XCTUnwrap(store.record(forKey: afterFull.key))
        assertRetainedAct(afterPartial, number: number)
        XCTAssertEqual(afterPartial.movementFetchedAt, fullSuccess)
        let journalIDs = try XCTUnwrap(afterPartial.eventJournal?.events.map(\.id))
        XCTAssertEqual(journalIDs, fullJournalIDs,
                       "partial refresh must keep the exact prior journal history")
        XCTAssertEqual(afterPartial.addedAt, addedAt)
        XCTAssertEqual(afterPartial.seenAt, seenAt)
        XCTAssertEqual(Set(afterPartial.collectionNames), ["Москва", "Лукьянова"])

        return (afterPartial.key, fullSuccess, journalIDs)
    }

    func testRefreshPersistsCachedActAcrossCompletePartialAndReopenedRefreshes() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // This function returns only stable scalar state. Its store, model
        // container, records, and refresh centers are released before reopening.
        let checkpoint = try await seedAndRefreshCompleteThenPartial(directory: directory)

        let reopenedContainer = try SudrfModelContainerFactory.make(
            inMemory: false, storeURL: directory.appendingPathComponent("test.store"))
        let reopened = try TrackedStore(container: reopenedContainer, prepared: true)
        let reopenedRecord = try XCTUnwrap(reopened.record(forKey: checkpoint.key))
        let (card, source) = try fixtures()
        let number = try XCTUnwrap(card.caseNumber)
        assertRetainedAct(reopenedRecord, number: number)
        XCTAssertEqual(reopenedRecord.movementFetchedAt, checkpoint.fullSuccess)
        XCTAssertEqual(reopenedRecord.eventJournal?.events.map(\.id), checkpoint.journalIDs)
        XCTAssertEqual(reopenedRecord.addedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(reopenedRecord.seenAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(Set(reopenedRecord.collectionNames), ["Москва", "Лукьянова"])

        let repeatedCenter = center(store: reopened, source: source, partial: true)
        let repeated = try XCTUnwrap(repeatedCenter.refresh(key: reopenedRecord.key))
        guard case .partial = await repeated.value.outcome else {
            return XCTFail("repeated refresh must remain partial")
        }
        let reopenedAfterRepeat = try XCTUnwrap(reopened.record(forKey: reopenedRecord.key))
        assertRetainedAct(reopenedAfterRepeat, number: number)
        XCTAssertEqual(reopenedAfterRepeat.movementFetchedAt, checkpoint.fullSuccess)
        XCTAssertEqual(reopenedAfterRepeat.eventJournal?.events.map(\.id), checkpoint.journalIDs)
        XCTAssertEqual(reopenedAfterRepeat.addedAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(reopenedAfterRepeat.seenAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(Set(reopenedAfterRepeat.collectionNames), ["Москва", "Лукьянова"])
    }
}
