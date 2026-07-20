import Foundation
import Security
import SudrfKit
import SwiftData
import XCTest
@testable import SudrfApp

final class CorrectivePassTests: XCTestCase {
    private actor ChunkRetrySummarizer: ActSummarizing {
        private var calls: [String: Int] = [:]
        private var failingID: String?

        func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
            let paragraph = try XCTUnwrap(document.paragraphs.first)
            if failingID == nil, calls[paragraph.id] == nil, !calls.isEmpty {
                failingID = paragraph.id
            }
            calls[paragraph.id, default: 0] += 1
            if paragraph.id == failingID, calls[paragraph.id] == 1 {
                throw AISummarizerError.http(429, retryAfterSeconds: 0)
            }
            return ActSummary(reasoning: [SummaryClaim(
                text: "Обработан \(paragraph.id)",
                citations: [SummaryCitation(paragraphID: paragraph.id,
                                             evidenceQuote: paragraph.text)])])
        }

        func snapshot() -> [String: Int] { calls }
    }

    private struct ConditionalBenchmarkSummarizer: ActSummarizing {
        func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
            if document.sourceActID == "failed" { throw AISummarizerError.invalidResponse }
            let paragraph = document.paragraphs[0]
            return ActSummary(disposition: [SummaryClaim(
                text: "Взыскать 10 000 рублей.",
                citations: [SummaryCitation(paragraphID: paragraph.id,
                                             evidenceQuote: paragraph.text)])])
        }
    }

    private actor SharedBudgetSummarizer: ActSummarizing {
        private(set) var calls = 0

        func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
            calls += 1
            if calls == 1 {
                return ActSummary(reasoning: [SummaryClaim(text: "Без ссылки", citations: [])])
            }
            throw AISummarizerError.http(503)
        }
    }

    private actor TransientHTTPThenSuccessSummarizer: ActSummarizing {
        private(set) var calls = 0

        func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
            calls += 1
            if calls == 1 { throw AISummarizerError.http(500) }
            let paragraph = try XCTUnwrap(document.paragraphs.first)
            return ActSummary(reasoning: [SummaryClaim(
                text: "Проверенный вывод.",
                citations: [SummaryCitation(
                    paragraphID: paragraph.id, evidenceQuote: paragraph.text)])])
        }
    }

    private actor LongRateLimitSummarizer: ActSummarizing {
        private(set) var calls = 0

        func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
            calls += 1
            throw AISummarizerError.http(429, retryAfterSeconds: 16)
        }
    }

    private actor CancelledSummarizer: ActSummarizing {
        private(set) var calls = 0

        func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
            calls += 1
            throw CancellationError()
        }
    }

    func testOnlyFailingChunkUsesSharedRetryBudget() async throws {
        let paragraphs = (1...3).map {
            ActParagraph(ordinal: $0,
                         text: "Абзац \($0) " + String(repeating: "текст ", count: 200))
        }
        let source = paragraphs.map(\.text).joined(separator: "\n\n")
        let document = ActDocument(
            id: "case#act", caseKey: "case", sourceActID: "act", caseNumber: "2-1/2026",
            judicialUID: nil, court: "Суд", instanceLevel: .first,
            kind: "Решение", date: "", sourceText: source,
            sourceHash: ActParagraphizer.sourceHash(for: source),
            paragraphizerVersion: ActParagraphizer.currentVersion,
            paragraphs: paragraphs)
        let base = ChunkRetrySummarizer()
        let pipeline = FinalValidatedActSummarizer(base:
            ChunkingActSummarizer(base: ValidatedActSummarizer(base: base)))

        _ = try await pipeline.summarize(
            document: document, options: SummaryOptions(maxInputCharacters: 1_000))

        let calls = await base.snapshot()
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls.values.sorted(), [1, 1, 2])
    }

    func testRetryBudgetCoversValidationAndTransientHTTPTogether() async throws {
        let document = makeSummaryDocument()
        let shared = SharedBudgetSummarizer()
        do {
            _ = try await ValidatedActSummarizer(base: shared)
                .summarize(document: document, options: SummaryOptions())
            XCTFail("validation + HTTP failure не должны давать третий вызов")
        } catch {}
        let sharedCalls = await shared.calls
        XCTAssertEqual(sharedCalls, 2)

        let transient = TransientHTTPThenSuccessSummarizer()
        _ = try await ValidatedActSummarizer(base: transient)
            .summarize(document: document, options: SummaryOptions())
        let transientCalls = await transient.calls
        XCTAssertEqual(transientCalls, 2)

        let longLimit = LongRateLimitSummarizer()
        do {
            _ = try await ValidatedActSummarizer(base: longLimit)
                .summarize(document: document, options: SummaryOptions())
            XCTFail("Retry-After > 15 секунд нельзя ждать автоматически")
        } catch {}
        let longLimitCalls = await longLimit.calls
        XCTAssertEqual(longLimitCalls, 1)

        let cancelled = CancelledSummarizer()
        do {
            _ = try await ValidatedActSummarizer(base: cancelled)
                .summarize(document: document, options: SummaryOptions())
            XCTFail("Cancellation нельзя повторять")
        } catch is CancellationError {}
        let cancelledCalls = await cancelled.calls
        XCTAssertEqual(cancelledCalls, 1)
    }

    func testHTTPJSONDoesNotRetainErrorBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SecretHTTPErrorStub.self]
        let session = URLSession(configuration: configuration)
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.invalid")))
        do {
            _ = try await HTTPJSON.send(request, session: session)
            XCTFail("HTTP 500 должен завершаться ошибкой")
        } catch {
            XCTAssertEqual(error.localizedDescription, "AI API вернул HTTP 500.")
            XCTAssertFalse(String(describing: error).contains("secret response"))
        }
    }

    func testTranslationRejectsReservedPlaceholderCollision() throws {
        let document = ActDocument(
            caseKey: "case", sourceActID: "act", caseNumber: "2-1/2026",
            judicialUID: nil, court: "Суд", instanceLevel: .first,
            kind: "Решение", date: "", sourceText: "Внешний текст ⟦A001⟧.")
        XCTAssertThrowsError(try LegalLiteralProtector.protect(document))
    }

    func testBenchmarkErrorsAreReportedOutsideMetricDenominators() async {
        func fixture(_ id: String) -> SummaryBenchmarkFixture {
            SummaryBenchmarkFixture(
                id: id, caseNumber: "2-1/2026", court: "Суд", kind: "Решение",
                date: "", sourceText: "Исходный текст.",
                expectedCriticalValues: ["10 000 рублей"],
                requiredSections: [.disposition])
        }
        let configured = ConfiguredActSummarizer(
            provider: "test", model: "test", options: SummaryOptions(),
            pipelineVersion: "test",
            summarizer: AnyActSummarizer(ConditionalBenchmarkSummarizer()))

        let report = await SummaryBenchmarkRunner().run(
            fixtures: [fixture("success"), fixture("failed")], configured: configured)

        XCTAssertEqual(report.citationAccuracy, 1)
        XCTAssertEqual(report.criticalAccuracy, 1)
        XCTAssertEqual(report.sectionCompleteness, 1)
        XCTAssertEqual(report.failedFixtureIDs, ["failed"])
        XCTAssertEqual(report.successfulFixtureCount, 1)
        XCTAssertFalse(report.passed)

        let empty = await SummaryBenchmarkRunner().run(
            fixtures: [], configured: configured)
        XCTAssertEqual(empty.requestedFixtureCount, 0)
        XCTAssertFalse(empty.passed)
    }

    @MainActor
    func testCaseScopedProjectionDoesNotRebuildUnrelatedCase() async throws {
        let store = TrackedStore(inMemory: true)
        let first = makeContext(number: "2-1/2026", domain: "first.msk.sudrf.ru")
        let second = makeContext(number: "2-2/2026", domain: "second.msk.sudrf.ru")
        store.upsert(context: first, snapshot: nil,
                     movement: makeMovement(context: first, text: "Первый старый."),
                     collections: [])
        let secondRecord = store.upsert(
            context: second, snapshot: nil,
            movement: makeMovement(context: second, text: "Второй старый."), collections: [])
        let catalog = CaseCatalog(container: store.container)

        secondRecord.movement = makeMovement(context: second, text: "Второй новый.")
        store.upsert(context: first, snapshot: nil,
                     movement: makeMovement(context: first, text: "Первый новый."),
                     collections: [])

        var secondActs = try await catalog.acts(caseKey: second.key)
        var secondAct = try XCTUnwrap(secondActs.first)
        XCTAssertEqual(secondAct.document.sourceText, "Второй старый.")
        XCTAssertTrue(store.save(projection: .cases([second.key])))
        secondActs = try await catalog.acts(caseKey: second.key)
        secondAct = try XCTUnwrap(secondActs.first)
        XCTAssertEqual(secondAct.document.sourceText, "Второй новый.")
    }

    @MainActor
    func testReroutePreservesUniqueActDocumentID() async throws {
        let store = TrackedStore(inMemory: true)
        let old = makeContext(number: "2-1/2026", domain: "old.msk.sudrf.ru")
        var new = old
        new.displayDomain = "new.msk.sudrf.ru"
        new.searchDomain = "new--msk.sudrf.ru"
        let record = store.upsert(
            context: old, snapshot: nil,
            movement: makeMovement(context: old, text: "Исходный акт."), collections: [])
        let catalog = CaseCatalog(container: store.container)
        let oldActs = try await catalog.acts(caseKey: old.key)
        let document = try XCTUnwrap(oldActs.first?.document)
        let oldID = document.id
        let summary = ActSummary(disposition: [SummaryClaim(
            text: "Исходный акт.",
            citations: [SummaryCitation(paragraphID: "¶1",
                                         evidenceQuote: "Исходный акт.")])])
        try await catalog.saveSummary(
            document: document, summary: summary, provider: "test", model: "test-v1",
            promptVersion: "v1", pipelineVersion: "v1")

        record.key = new.key
        record.context = new
        record.displayDomain = new.displayDomain
        store.prepareCourtActsForReroute(from: [old.key], to: new.key)
        XCTAssertTrue(store.save(projection: .cases([old.key, new.key])))

        let remainingOldActs = try await catalog.acts(caseKey: old.key)
        XCTAssertTrue(remainingOldActs.isEmpty)
        let movedActs = try await catalog.acts(caseKey: new.key)
        let movedID = try XCTUnwrap(movedActs.first?.document.id)
        XCTAssertEqual(movedID, oldID)
        let movedSummary = try await catalog.summary(documentID: movedID)
        XCTAssertNotNil(movedSummary)
    }

    func testRendererKeepsParagraphIdentitySeparateFromBlockIdentity() {
        let paragraphs = [ActParagraph(ordinal: 1, text: "РЕШЕНИЕ")]
        let blocks = CourtActFormatter.parseIdentified("РЕШЕНИЕ", paragraphs: paragraphs)
        XCTAssertEqual(blocks.map(\.paragraphID), ["¶1"])
        XCTAssertEqual(blocks.map(\.blockID), ["¶1"])
    }

    func testSafePDFFilenameSanitizesHostileCharacters() {
        let filename = ActPDFExporter.filename(caseNumber: " ../2:1/2026?*|<>\n ")
        XCTAssertFalse(filename.contains("/"))
        XCTAssertFalse(filename.contains(":"))
        XCTAssertFalse(filename.contains("\n"))
        XCTAssertTrue(filename.hasSuffix(".pdf"))
    }

    func testKeychainUpdateIsAtomicAndFallsBackToAddOnlyWhenMissing() throws {
        let update = KeychainWriterStub(updateStatus: errSecSuccess)
        try AIKeychain.save("new-key", provider: .groq, writer: update)
        XCTAssertEqual(update.calls, ["update"])

        let missing = KeychainWriterStub(updateStatus: errSecItemNotFound)
        try AIKeychain.save("new-key", provider: .groq, writer: missing)
        XCTAssertEqual(missing.calls, ["update", "add"])

        let failed = KeychainWriterStub(updateStatus: errSecAuthFailed)
        XCTAssertThrowsError(try AIKeychain.save("new-key", provider: .groq, writer: failed))
        XCTAssertEqual(failed.calls, ["update"])
    }

    @MainActor
    func testBootstrapStartsLoadingAndFailsClosed() async {
        struct ExpectedFailure: LocalizedError {
            var errorDescription: String? { "bootstrap failed" }
        }
        let bootstrap = AppBootstrap(loader: { throw ExpectedFailure() })
        if case .loading = bootstrap.state {} else { XCTFail("первый state должен быть loading") }
        await bootstrap.start()
        guard case .failed(let message) = bootstrap.state else {
            return XCTFail("ошибка bootstrap не должна создавать рабочий router")
        }
        XCTAssertEqual(message, "bootstrap failed")
    }

    @MainActor
    func testBootstrapPublishesReadyOnlyAfterPreparedContainerArrives() async throws {
        let defaults = UserDefaults.standard
        let oldDisclosure = defaults.object(forKey: SpotlightPreferenceStore.onboardingKey)
        defaults.set(false, forKey: SpotlightPreferenceStore.onboardingKey)
        defer {
            if let oldDisclosure {
                defaults.set(oldDisclosure, forKey: SpotlightPreferenceStore.onboardingKey)
            } else {
                defaults.removeObject(forKey: SpotlightPreferenceStore.onboardingKey)
            }
        }
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let bootstrap = AppBootstrap(loader: { container })
        if case .loading = bootstrap.state {} else { XCTFail("первый state должен быть loading") }

        await bootstrap.start()

        guard case .ready(let router) = bootstrap.state else {
            return XCTFail("успешный bootstrap должен создать router")
        }
        XCTAssertTrue(router.cases.isEmpty)
        XCTAssertTrue(router.spotlightOnboardingRequired)
    }

    func testReopeningSummaryPreservesGenerationForSameTarget() {
        var state = SummaryOperationState()
        let generation = state.begin(
            kind: .generate, caseKey: "case", sourceActID: "act")
        XCTAssertTrue(state.preservesCurrentLoad(caseKey: "case", sourceActID: "act"))
        XCTAssertEqual(state.current, generation)
        XCTAssertFalse(state.preservesCurrentLoad(caseKey: "case", sourceActID: "other"))
        XCTAssertTrue(state.finish(generation))
        XCTAssertNil(state.current)
    }

    func testStaleSummaryCompletionCannotFinishNewTarget() {
        var state = SummaryOperationState()
        let old = state.begin(kind: .generate, caseKey: "case", sourceActID: "old")
        let new = state.begin(kind: .load, caseKey: "case", sourceActID: "new")

        XCTAssertFalse(state.finish(old))
        XCTAssertEqual(state.current, new)
        state.cancel()
        XCTAssertNil(state.current)
    }

    private func makeSummaryDocument() -> ActDocument {
        ActDocument(
            caseKey: "case", sourceActID: "act", caseNumber: "2-1/2026",
            judicialUID: nil, court: "Суд", instanceLevel: .first,
            kind: "Решение", date: "", sourceText: "Исходный абзац.")
    }

    private func makeContext(number: String, domain: String) -> MovementContext {
        MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: domain.replacingOccurrences(of: ".", with: "--"),
            displayDomain: domain, courtTitle: "Суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "77", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue, caseNumber: number)
    }

    private func makeMovement(context: MovementContext, text: String) -> CaseMovement {
        let act = CaseAct(id: "act-1", title: "Решение", date: "01.07.2026",
                          courtShort: "Суд", instanceLevel: .first)
        return CaseMovement(
            uid: "", caseNumber: context.caseNumber, inForce: false,
            instances: [], complaints: [:], acts: [act], actBodies: [act.id: text],
            category: nil, parties: CaseParties())
    }
}

private final class SecretHTTPErrorStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 500, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/plain"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("secret response".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class KeychainWriterStub: AIKeychain.Writing {
    let updateStatus: OSStatus
    var calls: [String] = []

    init(updateStatus: OSStatus) { self.updateStatus = updateStatus }

    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        calls.append("update")
        return updateStatus
    }

    func add(_ attributes: CFDictionary) -> OSStatus {
        calls.append("add")
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        calls.append("delete")
        return errSecSuccess
    }
}
