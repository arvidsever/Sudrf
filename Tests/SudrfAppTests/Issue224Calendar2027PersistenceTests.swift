import Foundation
import SwiftData
import XCTest
@testable import SudrfKit
@testable import SudrfApp

private actor Issue224CalendarMovementProvider: MovementProviding {
    private let value: CaseMovement

    init(_ value: CaseMovement) { self.value = value }

    func movement(for base: CaseSearchResult, court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement {
        value
    }
}

private final class Issue224NoNetworkURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

@MainActor
final class Issue224Calendar2027PersistenceTests: XCTestCase {
    private let ruleID = "GPK-APPEAL-GENERAL"
    private let actID = "issue224-synthetic-final-act"
    private let manualConfirmedKey = "issue224-user-confirmed-date"
    private let manualOverrideKey = "issue224-user-overridden-date"
    private let closedHistoryKey = "GPK-APPEAL-GENERAL|closed-2026-occurrence"
    private let fetchedAt = DateUtil.parse("01.10.2026")!
    private let seenAt = DateUtil.parse("02.10.2026")!
    private let calendarToday = DateUtil.parse("09.10.2026")!

    private struct SummaryFacts: Equatable {
        let id: String
        let documentID: String
        let summaryData: Data
        let provider: String
        let model: String
        let promptVersion: String
        let pipelineVersion: String
        let sourceHash: String
        let generatedAt: Date
    }

    private struct PersistedFacts {
        let key: String
        let logicalCaseID: UUID
        let folderName: String
        let collections: [String]
        let seenAt: Date?
        let movementFetchedAt: Date?
        let sourceRefreshAttempt: SourceAttempt?
        let movement: CaseMovement?
        let snapshot: CaseSnapshot?
        let journal: CaseEventJournal?
        let act: ActDocument?
        let summary: SummaryFacts?
    }

    func testPreparationAndRepeatedRefreshPreserveCalendarCaseStorage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("issue-224-2027-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("tracked.store")
        let context = makeContext()
        let movement = makeMovement(context: context)
        let projected = MovementDerivation.snapshot(
            from: movement, context: context, today: calendarToday)
        let projected2027 = try XCTUnwrap(projected.deadlines.first {
            $0.provenance?.ruleID == ruleID
        })
        XCTAssertEqual(projected2027.date, DateUtil.parse("01.02.2027"))
        XCTAssertEqual(projected2027.provenance?.calendarTrace?.revisions.map(\.year), [2027])

        let seeded = try seedOldCalendarSnapshot(
            at: storeURL, context: context, movement: movement, projected: projected)
        let seedJournalIDs = try XCTUnwrap(seeded.journal).events.map(\.id)
        let seedAct = try XCTUnwrap(seeded.act)
        let seedSummary = try XCTUnwrap(seeded.summary)
        XCTAssertEqual(seeded.movementFetchedAt, fetchedAt)
        XCTAssertEqual(seeded.seenAt, seenAt)
        XCTAssertEqual(seeded.snapshot?.deadlines.filter { $0.isActive && $0.provenance?.ruleID == ruleID }, [])
        XCTAssertEqual(seeded.snapshot?.deadlineAssessments?.first { $0.ruleID == ruleID }?.status,
                       .unsupportedCalculation)

        XCTAssertTrue(try prepareStore(at: storeURL))
        let afterPreparation = try persistedFacts(at: storeURL)
        assertPreservedFacts(afterPreparation, seed: seeded, act: seedAct, summary: seedSummary)
        XCTAssertEqual(afterPreparation.movementFetchedAt, fetchedAt,
                       "локальная подготовка не продлевает TTL успешной загрузки")
        XCTAssertEqual(afterPreparation.sourceRefreshAttempt, seeded.sourceRefreshAttempt)
        XCTAssertEqual(afterPreparation.seenAt, seenAt)
        XCTAssertEqual(afterPreparation.snapshot?.deadlineAssessments?.first {
            $0.ruleID == ruleID
        }?.status, .applicable)
        XCTAssertFalse(afterPreparation.snapshot?.deadlines.contains {
            $0.isActive && $0.status == .proposed && $0.provenance?.ruleID == ruleID
        } ?? true, "новый автоматический срок не должен появляться только при подготовке")

        XCTAssertFalse(try prepareStore(at: storeURL), "повторная подготовка должна быть идемпотентна")
        let afterColdReopen = try persistedFacts(at: storeURL)
        assertPreservedFacts(afterColdReopen, seed: seeded, act: seedAct, summary: seedSummary)
        XCTAssertEqual(afterColdReopen.movementFetchedAt, fetchedAt)
        XCTAssertEqual(afterColdReopen.sourceRefreshAttempt, seeded.sourceRefreshAttempt)
        XCTAssertEqual(afterColdReopen.seenAt, seenAt)
        XCTAssertFalse(afterColdReopen.snapshot?.deadlines.contains {
            $0.isActive && $0.status == .proposed && $0.provenance?.ruleID == ruleID
        } ?? true)

        let firstRefresh = try await refreshStore(at: storeURL, movement: movement)
        XCTAssertEqual(firstRefresh.outcome, .refreshed)
        let afterRefresh = try persistedFacts(at: storeURL)
        assertPreservedFacts(afterRefresh, seed: seeded, act: seedAct, summary: seedSummary)
        assert2027Deadline(in: afterRefresh.snapshot)
        XCTAssertGreaterThan(try XCTUnwrap(afterRefresh.movementFetchedAt), fetchedAt)
        XCTAssertEqual(semanticJournalEvents(afterRefresh.journal)?.map(\.id), seedJournalIDs,
                       "первое подтверждение календарного года не публикует старые судебные события")

        let secondRefresh = try await refreshStore(at: storeURL, movement: movement)
        XCTAssertEqual(secondRefresh.outcome, .refreshed)
        let afterRepeat = try persistedFacts(at: storeURL)
        assertPreservedFacts(afterRepeat, seed: seeded, act: seedAct, summary: seedSummary)
        assert2027Deadline(in: afterRepeat.snapshot)
        XCTAssertEqual(semanticJournalEvents(afterRepeat.journal)?.map(\.id), seedJournalIDs,
                       "повторный полный refresh не дублирует исторические события")
        XCTAssertEqual(afterRepeat.movement?.acts, movement.acts)
        XCTAssertEqual(afterRepeat.movement?.actBodies, movement.actBodies)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(afterRepeat.movementFetchedAt),
                                    try XCTUnwrap(afterRefresh.movementFetchedAt))
    }

    private func seedOldCalendarSnapshot(at storeURL: URL, context: MovementContext,
                                         movement: CaseMovement,
                                         projected: CaseSnapshot) throws -> PersistedFacts {
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        var old = projected
        old.deadlines = [
            deadline(kind: "manual-confirmed", key: manualConfirmedKey,
                     date: "12.03.2027", status: .confirmed),
            deadline(kind: "manual-overridden", key: manualOverrideKey,
                     date: "13.03.2027", status: .overridden),
            deadline(kind: "appeal", key: closedHistoryKey,
                     date: "01.02.2026", status: .proposed,
                     lifecycle: .superseded),
        ]
        if let index = old.deadlineAssessments?.firstIndex(where: { $0.ruleID == ruleID }) {
            old.deadlineAssessments?[index].statusRaw = DeadlineAssessmentStatus.unsupportedCalculation.rawValue
            old.deadlineAssessments?[index].missingPolicyIDs = [
                "GPK-END-NONWORKING-NEXT-WORKING",
            ]
        } else {
            XCTFail("synthetic old snapshot must contain the applicable GPK assessment")
        }

        let record = try store.reconcileAndUpsert(
            context: context, snapshot: old, movement: movement,
            collections: ["Календарь 2027", "Избранное"],
            movementFetchedAt: fetchedAt)
        record.seenAt = seenAt
        record.sourceRefreshAttempt = SourceAttempt(
            kind: .usableSnapshot,
            provenance: SourceProvenance(operation: .movement, sourceFamily: "sudrf",
                                         host: context.searchDomain, observedAt: fetchedAt))
        let sentinel = CaseEvent.make(
            kind: .hearingScheduled, occurrence: ["issue224-existing-event"],
            observedAt: seenAt,
            evidence: CaseEventEvidence(event: "synthetic existing event"))
        record.eventJournal = CaseEventJournal(events: [sentinel])
        try store.save(projection: .cases([record.key]))

        let document = try XCTUnwrap(store.courtActDocument(caseKey: record.key, sourceActID: actID))
        let summary = ActSummary(localWarnings: ["issue224-summary-sentinel"],
                                 intermediateEnglishSummary: "synthetic stored summary")
        container.mainContext.insert(try ActSummaryRecord(
            documentID: document.id, summary: summary, provider: "fixture", model: "fixture",
            promptVersion: "issue224", pipelineVersion: "synthetic",
            sourceHash: document.sourceHash,
            paragraphizerVersion: document.paragraphizerVersion,
            generatedAt: DateUtil.parse("03.10.2026")!))
        try store.save()
        return try facts(record: record, in: container.mainContext)
    }

    private func prepareStore(at storeURL: URL) throws -> Bool {
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        _ = try TrackedStore(container: container, prepared: true)
        return try TrackedStorePreparation.prepare(
            context: container.mainContext, today: calendarToday)
    }

    private func refreshStore(at storeURL: URL, movement: CaseMovement) async throws
        -> RefreshExecution {
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let store = try TrackedStore(container: container, prepared: true)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.urlCache = nil
        sessionConfiguration.protocolClasses = [Issue224NoNetworkURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let client = SudrfClient(
            session: session, minInterval: 0,
            variantStore: WorkingVariantStore(cacheURL: nil),
            captchaStore: CaptchaTokenStore())
        let provider = Issue224CalendarMovementProvider(movement)
        let center = RefreshCenter(
            store: store, client: client,
            autoSolve: { _, _, _, _ in
                XCTFail("synthetic refresh must not enter CAPTCHA recovery")
                return AutoCaptchaSolver.SolveResult(token: nil, png: nil)
            },
            serviceBuilder: { _ in provider },
            treasuryDiscover: { _, _, _ in throw CancellationError() },
            fsspClient: FSSPClient(session: session, minInterval: 0, maxAttempts: 1),
            vsrfProvider: Issue224UnusedVSRFProvider(),
            fsspAutoModelEnabled: false,
            fsspDiscover: { _ in throw CancellationError() },
            initialTimerDelay: .seconds(600), timerInterval: .seconds(600))
        XCTAssertEqual(store.all().count, 1)
        let key = try XCTUnwrap(store.all().first?.key)
        let task = try XCTUnwrap(center.refresh(key: key, manually: true))
        return await task.value
    }

    private func persistedFacts(at storeURL: URL) throws -> PersistedFacts {
        let container = try SudrfModelContainerFactory.make(inMemory: false, storeURL: storeURL)
        let records = try container.mainContext.fetch(FetchDescriptor<TrackedCaseRecord>())
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        return try facts(record: record, in: container.mainContext)
    }

    private func facts(record: TrackedCaseRecord, in context: ModelContext) throws -> PersistedFacts {
        let caseKey = record.key
        let acts = try context.fetch(FetchDescriptor<CourtActRecord>(
            predicate: #Predicate { $0.caseKey == caseKey }))
        XCTAssertEqual(acts.count, 1)
        let actRecord = try XCTUnwrap(acts.first)
        let documentID = actRecord.id
        let summaries = try context.fetch(FetchDescriptor<ActSummaryRecord>(
            predicate: #Predicate { $0.documentID == documentID }))
        XCTAssertEqual(summaries.count, 1)
        let summaryRecord = try XCTUnwrap(summaries.first)
        return PersistedFacts(
            key: record.key, logicalCaseID: try XCTUnwrap(record.logicalCaseID),
            folderName: record.folderName, collections: record.collectionNames,
            seenAt: record.seenAt, movementFetchedAt: record.movementFetchedAt,
            sourceRefreshAttempt: record.sourceRefreshAttempt, movement: record.movement,
            snapshot: record.snapshot, journal: record.eventJournal,
            act: actRecord.document,
            summary: SummaryFacts(
                id: summaryRecord.id, documentID: summaryRecord.documentID,
                summaryData: summaryRecord.summaryData, provider: summaryRecord.provider,
                model: summaryRecord.model, promptVersion: summaryRecord.promptVersion,
                pipelineVersion: summaryRecord.pipelineVersion,
                sourceHash: summaryRecord.sourceHash, generatedAt: summaryRecord.generatedAt))
    }

    private func assertPreservedFacts(_ actual: PersistedFacts, seed: PersistedFacts,
                                      act: ActDocument, summary: SummaryFacts,
                                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.key, seed.key, file: file, line: line)
        XCTAssertEqual(actual.logicalCaseID, seed.logicalCaseID, file: file, line: line)
        XCTAssertEqual(actual.folderName, seed.folderName, file: file, line: line)
        XCTAssertEqual(actual.collections, seed.collections, file: file, line: line)
        XCTAssertEqual(actual.act, act, file: file, line: line)
        XCTAssertEqual(actual.summary, summary, file: file, line: line)
        XCTAssertEqual(actual.snapshot?.sessions, seed.snapshot?.sessions, file: file, line: line)
        let deadlines = actual.snapshot?.deadlines ?? []
        for key in [manualConfirmedKey, manualOverrideKey, closedHistoryKey] {
            XCTAssertEqual(deadlines.first { $0.occurrenceKey == key },
                           seed.snapshot?.deadlines.first { $0.occurrenceKey == key },
                           "deadline \(key) must survive storage transitions", file: file, line: line)
        }
        XCTAssertEqual(semanticJournalEvents(actual.journal)?.map(\.id), seed.journal?.events.map(\.id),
                       file: file, line: line)
    }

    private func assert2027Deadline(in snapshot: CaseSnapshot?,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let matches = snapshot?.deadlines.filter {
            $0.isActive && $0.status == .proposed && $0.provenance?.ruleID == ruleID
        } ?? []
        XCTAssertEqual(matches.count, 1, file: file, line: line)
        guard let deadline = matches.first else { return }
        XCTAssertEqual(deadline.date, DateUtil.parse("01.02.2027"), file: file, line: line)
        XCTAssertEqual(deadline.provenance?.trigger.dateRaw, "31.12.2026", file: file, line: line)
        XCTAssertEqual(deadline.provenance?.calendarTrace?.start,
                       LegalCalendarDate(year: 2027, month: 1, day: 31), file: file, line: line)
        XCTAssertEqual(deadline.provenance?.calendarTrace?.result,
                       LegalCalendarDate(year: 2027, month: 2, day: 1), file: file, line: line)
        XCTAssertEqual(deadline.provenance?.calendarTrace?.revisions.map(\.year), [2027],
                       file: file, line: line)
    }

    private func deadline(kind: String, key: String, date: String,
                          status: DeadlineStatus,
                          lifecycle: DeadlineLifecycle = .active) -> StoredDeadline {
        StoredDeadline(kind: kind, what: "Срок", basis: "Синтетическая сохранённая дата",
                       calLabel: "Пользовательская дата",
                       dateRef: DateUtil.parse(date)!.timeIntervalSinceReferenceDate,
                       statusRaw: status.rawValue, occurrenceKey: key,
                       lifecycleRaw: lifecycle.rawValue)
    }

    private func makeContext() -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Республика Коми",
            searchDomain: "syktsud--komi.sudrf.ru", displayDomain: "syktsud.komi.sudrf.ru",
            courtTitle: "Сыктывкарский городской суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "11RS0001", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue,
            caseNumber: "2-123/2026", caseID: "issue224-calendar-2027-card",
            caseUID: "issue224-calendar-2027-case")
    }

    private func makeMovement(context: MovementContext) -> CaseMovement {
        let finalResult = "Иск удовлетворён; решение принято в окончательной форме"
        let session = CaseSession(date: "31.12.2026", time: "10:00",
                                  event: "Судебное заседание", result: finalResult)
        let first = CaseInstance(
            level: .first, court: context.courtTitle, caseNumber: context.caseNumber,
            judge: "Синтетический судья", domain: context.searchDomain,
            foundByUID: false, result: finalResult, sessions: [session],
            actID: actID, actIDs: [actID])
        let act = CaseAct(id: actID, title: "Решение", date: "31.12.2026",
                          courtShort: context.courtTitle, instanceLevel: .first)
        return CaseMovement(
            uid: "11RS0001-01-2026-000123-11", caseNumber: context.caseNumber,
            inForce: false, instances: [first], complaints: [:], acts: [act],
            actBodies: [actID: "Синтетический текст судебного акта для проверки сохранения."],
            category: "Споры из договоров")
    }
}

private struct Issue224UnusedVSRFProvider: VSRFProviding {
    func search(uniqueNumber: String?, oldCaseNumber: String?,
                keywords: String?) async throws -> VSRFSearchResults {
        throw CancellationError()
    }

    func fetchCard(productionID: String, section: VSRFCardSection) async throws -> VSRFCard {
        throw CancellationError()
    }
}
