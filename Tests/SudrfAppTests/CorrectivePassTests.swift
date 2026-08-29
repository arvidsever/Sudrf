import Foundation
import Security
import SudrfKit
import SwiftData
import XCTest
@testable import SudrfApp

final class CorrectivePassTests: XCTestCase {
    private struct BootstrapFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private actor BootstrapCallCounter {
        private(set) var calls = 0

        func increment() -> Int {
            calls += 1
            return calls
        }
    }

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

    private actor JSONValidationFailureSummarizer: ActSummarizing {
        private(set) var calls = 0

        func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
            calls += 1
            throw AISummarizerError.http(
                400, providerCode: .jsonValidateFailed)
        }
    }

    private actor GenericBadRequestSummarizer: ActSummarizing {
        private(set) var calls = 0

        func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
            calls += 1
            throw AISummarizerError.http(400)
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

    func testJSONValidateFailedRetriesOnceButGeneric400DoesNotRetry() async {
        let document = makeSummaryDocument()
        XCTAssertTrue(GroqTokenBudget.allowsImmediateRetry(
            forCharacters: document.sourceText.count))
        let validationFailure = JSONValidationFailureSummarizer()
        do {
            _ = try await ValidatedActSummarizer(base: validationFailure)
                .summarize(document: document, options: SummaryOptions())
            XCTFail("json_validate_failed должен завершиться после одного повтора")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Провайдер принял API-ключ, но после повторной попытки не смог сформировать структурированную сводку.")
        }
        let validationCalls = await validationFailure.calls
        XCTAssertEqual(validationCalls, 2)

        let genericFailure = GenericBadRequestSummarizer()
        do {
            _ = try await ValidatedActSummarizer(base: genericFailure)
                .summarize(document: document, options: SummaryOptions())
            XCTFail("Обычный HTTP 400 нельзя повторять")
        } catch {}
        let genericCalls = await genericFailure.calls
        XCTAssertEqual(genericCalls, 1)
    }

    /// Для крупного chunk два запроса подряд не укладываются в минутный token
    /// budget, поэтому повтор заведомо получил бы отказ по лимиту и лишь отнял
    /// бы бюджет у остальных chunks.
    func testJSONValidateFailedIsNotRetriedWhenTwoRequestsExceedMinuteBudget() async {
        let source = String(repeating: "А", count: 12_000)
        let document = ActDocument(
            caseKey: "case", sourceActID: "large", caseNumber: "2-1/2026",
            judicialUID: nil, court: "Суд", instanceLevel: .first,
            kind: "Решение", date: "", sourceText: source)
        XCTAssertFalse(GroqTokenBudget.allowsImmediateRetry(forCharacters: source.count))

        let failure = JSONValidationFailureSummarizer()
        do {
            _ = try await ValidatedActSummarizer(base: failure)
                .summarize(document: document, options: SummaryOptions())
            XCTFail("json_validate_failed на крупном chunk нельзя повторять")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Провайдер принял API-ключ, но не смог сформировать сводку по заданной JSON-схеме.")
        }
        let calls = await failure.calls
        XCTAssertEqual(calls, 1)
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

    func testHTTPJSONRetainsOnlyAllowlistedProviderFailureCode() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JSONValidationHTTPErrorStub.self]
        let session = URLSession(configuration: configuration)
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.invalid")))
        do {
            _ = try await HTTPJSON.send(request, session: session)
            XCTFail("HTTP 400 должен завершаться ошибкой")
        } catch let error as AISummarizerError {
            guard case .http(400, _, .jsonValidateFailed) = error else {
                return XCTFail("Ожидался безопасный json_validate_failed, получено \(error)")
            }
            XCTAssertFalse(String(describing: error).contains("secret response"))
            XCTAssertFalse(error.localizedDescription.contains("secret response"))
        } catch {
            XCTFail("Неожиданный тип ошибки: \(error)")
        }
    }

    func testConnectionProbeRejectsEmptyAndAcceptsCitedSummary() throws {
        XCTAssertThrowsError(try AIConnectionProbe.validate(ActSummary()))

        let paragraph = try XCTUnwrap(AIConnectionProbe.document.paragraphs.first)
        let summary = ActSummary(claims: [SummaryClaim(
            text: "Истец просил взыскать 10 000 рублей.",
            citations: [SummaryCitation(
                paragraphID: paragraph.id, evidenceQuote: "10 000 рублей")])])
        XCTAssertNoThrow(try AIConnectionProbe.validate(summary))
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
        _ = try store.upsert(context: first, snapshot: nil,
                     movement: makeMovement(context: first, text: "Первый старый."),
                     collections: [])
        let secondRecord = try store.upsert(
            context: second, snapshot: nil,
            movement: makeMovement(context: second, text: "Второй старый."), collections: [])
        let catalog = CaseCatalog(container: store.container)

        secondRecord.movement = makeMovement(context: second, text: "Второй новый.")
        _ = try store.upsert(context: first, snapshot: nil,
                     movement: makeMovement(context: first, text: "Первый новый."),
                     collections: [])

        var secondActs = try await catalog.acts(caseKey: second.key)
        var secondAct = try XCTUnwrap(secondActs.first)
        XCTAssertEqual(secondAct.document.sourceText, "Второй старый.")
        try store.save(projection: .cases([second.key]))
        secondActs = try await catalog.acts(caseKey: second.key)
        secondAct = try XCTUnwrap(secondActs.first)
        XCTAssertEqual(secondAct.document.sourceText, "Второй новый.")
    }

    @MainActor
    func testReroutePreservesUniqueActDocumentIDWithoutRotatingRecordKey() async throws {
        let store = TrackedStore(inMemory: true)
        let old = makeContext(number: "2-1/2026", domain: "old.msk.sudrf.ru")
        var new = old
        new.displayDomain = "new.msk.sudrf.ru"
        new.searchDomain = "new--msk.sudrf.ru"
        let record = try store.upsert(
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

        record.context = new
        record.displayDomain = new.displayDomain
        record.addLegacyKeyAlias(new.key)
        try store.save(projection: .cases([record.key]))

        XCTAssertEqual(record.key, old.key)
        XCTAssertTrue(store.record(forLocator: new.key) === record)
        let preservedActs = try await catalog.acts(caseKey: old.key)
        let preservedID = try XCTUnwrap(preservedActs.first?.document.id)
        XCTAssertEqual(preservedID, oldID)
        let preservedSummary = try await catalog.summary(documentID: preservedID)
        XCTAssertNotNil(preservedSummary)
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
        let bootstrap = AppBootstrap(loader: {
            throw BootstrapFailure(message: "bootstrap failed")
        })
        if case .loading = bootstrap.state {} else { XCTFail("первый state должен быть loading") }
        await bootstrap.start()
        guard case .failed(let failure) = bootstrap.state else {
            return XCTFail("ошибка bootstrap не должна создавать рабочий router")
        }
        XCTAssertEqual(failure.message, "bootstrap failed")
        XCTAssertNil(failure.storeURL)
        XCTAssertFalse(failure.canQuarantine)
    }

    @MainActor
    func testBootstrapTreatsStartupReconciliationCommitFailureAsRetryOnly() async {
        let bootstrap = AppBootstrap(loader: {
            throw TrackedStoreCommitError.contextSave(details: "startup reconciliation failed")
        })

        await bootstrap.start()

        guard case .failed(let failure) = bootstrap.state else {
            return XCTFail("startup reconciliation failure must keep the app blocked")
        }
        XCTAssertTrue(failure.message.contains("startup reconciliation failed"))
        XCTAssertNil(failure.storeURL)
        XCTAssertFalse(failure.canQuarantine)
        XCTAssertNil(failure.recoveryDirectory)
    }

    @MainActor
    func testBootstrapRetryCallsLoaderAgainAndConcurrentRetriesOnlyOnce() async throws {
        let counter = BootstrapCallCounter()
        let quarantineCalls = BootstrapCallCounter()
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let bootstrap = AppBootstrap(loader: {
            let call = await counter.increment()
            if call == 1 { throw BootstrapFailure(message: "bootstrap failed") }
            try await Task.sleep(nanoseconds: 25_000_000)
            return container
        }, quarantine: { _, _ in
            _ = await quarantineCalls.increment()
            return URL(fileURLWithPath: "/tmp/unused-recovery")
        })

        await bootstrap.start()
        guard case .failed(let failure) = bootstrap.state else {
            return XCTFail("первая попытка должна завершиться ошибкой")
        }
        XCTAssertEqual(failure.message, "bootstrap failed")

        let firstRetry = Task { await bootstrap.retry() }
        let secondRetry = Task { await bootstrap.retry() }
        await firstRetry.value
        await secondRetry.value

        guard case .ready = bootstrap.state else {
            return XCTFail("повторная попытка должна открыть контейнер")
        }
        let calls = await counter.calls
        XCTAssertEqual(calls, 2,
                       "двойное действие не должно запускать второй loader")
        let performedQuarantines = await quarantineCalls.calls
        XCTAssertEqual(performedQuarantines, 0,
                       "retry не должен самовольно запускать quarantine")
    }

    @MainActor
    func testBootstrapFirstLaunchFailureCannotQuarantine() async {
        let quarantineCalls = BootstrapCallCounter()
        let storeURL = URL(fileURLWithPath: "/tmp/sudrf-fresh/default.store")
        let bootstrap = AppBootstrap(loader: {
            throw SudrfStoreBootstrapError(
                underlying: BootstrapFailure(message: "fresh store failed"),
                backupDirectory: nil, storeURL: storeURL, hadExistingStore: false)
        }, quarantine: { _, _ in
            _ = await quarantineCalls.increment()
            return URL(fileURLWithPath: "/tmp/should-not-exist")
        })

        await bootstrap.start()
        guard case .failed(let failure) = bootstrap.state else {
            return XCTFail("ошибка первого запуска должна быть failed")
        }
        XCTAssertEqual(failure.storeURL, storeURL.standardizedFileURL)
        XCTAssertFalse(failure.canQuarantine)

        await bootstrap.quarantineStore()
        guard case .failed = bootstrap.state else {
            return XCTFail("первый запуск не должен переходить в quarantine")
        }
        let performedQuarantines = await quarantineCalls.calls
        XCTAssertEqual(performedQuarantines, 0)
    }

    @MainActor
    func testBootstrapRelaunchWithIncompleteRecoveryStaysBlocked() async {
        let loaderCalls = BootstrapCallCounter()
        let quarantineCalls = BootstrapCallCounter()
        let storeURL = URL(fileURLWithPath: "/tmp/sudrf-partial/default.store")
        let recoveryDirectory = URL(fileURLWithPath: "/tmp/sudrf-partial/recovery")
        let bootstrap = AppBootstrap(loader: {
            _ = await loaderCalls.increment()
            throw SudrfStoreBootstrapError(
                underlying: BootstrapFailure(message: "incomplete recovery"),
                backupDirectory: nil, storeURL: storeURL, hadExistingStore: true,
                canQuarantine: false, recoveryDirectory: recoveryDirectory)
        }, quarantine: { _, _ in
            _ = await quarantineCalls.increment()
            return URL(fileURLWithPath: "/tmp/should-not-exist")
        })

        await bootstrap.start()
        guard case .failed(let failure) = bootstrap.state else {
            return XCTFail("relaunch с incomplete marker должен быть blocked")
        }
        XCTAssertEqual(failure.recoveryDirectory, recoveryDirectory.standardizedFileURL)
        XCTAssertFalse(failure.canQuarantine)

        await bootstrap.retry()
        await bootstrap.quarantineStore()
        let finalLoaderCalls = await loaderCalls.calls
        let finalQuarantineCalls = await quarantineCalls.calls
        XCTAssertEqual(finalLoaderCalls, 1)
        XCTAssertEqual(finalQuarantineCalls, 0)
        guard case .failed(let stillBlocked) = bootstrap.state else {
            return XCTFail("recovery actions не должны обходить incomplete marker")
        }
        XCTAssertEqual(stillBlocked.recoveryDirectory,
                       recoveryDirectory.standardizedFileURL)
    }

    @MainActor
    func testBootstrapQuarantineFailureKeepsRetryCapabilityOnlyAfterCompleteRollback() async {
        let loaderCalls = BootstrapCallCounter()
        let quarantineCalls = BootstrapCallCounter()
        let storeURL = URL(fileURLWithPath: "/tmp/sudrf-unopenable/default.store")
        let partialDirectory = URL(fileURLWithPath: "/tmp/sudrf-partial-recovery")
        let bootstrap = AppBootstrap(loader: {
            _ = await loaderCalls.increment()
            throw SudrfStoreBootstrapError(
                underlying: BootstrapFailure(message: "store unreadable"),
                backupDirectory: nil, storeURL: storeURL, hadExistingStore: true)
        }, quarantine: { url, _ in
            let call = await quarantineCalls.increment()
            if call == 1 {
                throw SudrfStoreQuarantineError(
                    underlying: BootstrapFailure(message: "move failed"),
                    storeURL: url, recoveryDirectory: nil, rollbackError: nil)
            }
            throw SudrfStoreQuarantineError(
                underlying: BootstrapFailure(message: "rollback failed"),
                storeURL: url, recoveryDirectory: partialDirectory,
                rollbackError: BootstrapFailure(message: "rollback failed"))
        })

        await bootstrap.start()
        await bootstrap.quarantineStore()
        guard case .failed(let retryable) = bootstrap.state else {
            return XCTFail("ошибка полного rollback должна остаться failed")
        }
        XCTAssertTrue(retryable.canQuarantine)
        XCTAssertNil(retryable.recoveryDirectory)

        await bootstrap.quarantineStore()
        guard case .failed(let partial) = bootstrap.state else {
            return XCTFail("ошибка неполного rollback должна остаться failed")
        }
        XCTAssertFalse(partial.canQuarantine)
        XCTAssertEqual(partial.recoveryDirectory, partialDirectory)

        let callsBeforeRetry = await loaderCalls.calls
        await bootstrap.retry()
        let callsAfterRetry = await loaderCalls.calls
        XCTAssertEqual(callsAfterRetry, callsBeforeRetry,
                       "при неполном rollback loader должен оставаться заблокирован")
        guard case .failed(let stillBlocked) = bootstrap.state else {
            return XCTFail("неполный rollback должен оставлять failed state")
        }
        XCTAssertEqual(stillBlocked.recoveryDirectory, partialDirectory)
    }

    @MainActor
    func testBootstrapQuarantineAndFreshStartFailureStayInRecoveryState() async throws {
        let counter = BootstrapCallCounter()
        let quarantineCalls = BootstrapCallCounter()
        let container = try SudrfModelContainerFactory.make(inMemory: true)
        let storeURL = URL(fileURLWithPath: "/tmp/sudrf-unopenable/default.store")
        let quarantineDirectory = URL(fileURLWithPath: "/tmp/sudrf-unopenable-recovery")
        let bootstrap = AppBootstrap(loader: {
            switch await counter.increment() {
            case 1:
                throw SudrfStoreBootstrapError(
                    underlying: BootstrapFailure(message: "store unreadable"),
                    backupDirectory: nil, storeURL: storeURL, hadExistingStore: true)
            case 2:
                throw BootstrapFailure(message: "fresh start failed")
            default:
                return container
            }
        }, quarantine: { _, _ in
            _ = await quarantineCalls.increment()
            try await Task.sleep(nanoseconds: 25_000_000)
            return quarantineDirectory
        })

        await bootstrap.start()
        guard case .failed(let failure) = bootstrap.state else {
            return XCTFail("существующая неоткрываемая база должна быть в failed")
        }
        XCTAssertEqual(failure.storeURL, storeURL.standardizedFileURL)
        XCTAssertTrue(failure.canQuarantine)

        let firstQuarantine = Task { await bootstrap.quarantineStore() }
        let secondQuarantine = Task { await bootstrap.quarantineStore() }
        await firstQuarantine.value
        await secondQuarantine.value
        guard case .quarantined(let quarantined) = bootstrap.state else {
            return XCTFail("после quarantine должен быть промежуточный recovery state")
        }
        XCTAssertEqual(quarantined.directory, quarantineDirectory)
        XCTAssertNil(quarantined.freshStartError)
        let performedQuarantines = await quarantineCalls.calls
        XCTAssertEqual(performedQuarantines, 1)

        await bootstrap.continueWithCleanDatabase()
        guard case .quarantined(let failedFreshStart) = bootstrap.state else {
            return XCTFail("ошибка fresh start должна оставить recovery screen")
        }
        XCTAssertEqual(failedFreshStart.directory, quarantineDirectory)
        XCTAssertEqual(failedFreshStart.freshStartError, "fresh start failed")

        await bootstrap.continueWithCleanDatabase()
        guard case .ready = bootstrap.state else {
            return XCTFail("повторная команда fresh start должна открыть контейнер")
        }
        let totalCalls = await counter.calls
        XCTAssertEqual(totalCalls, 3)
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

private final class JSONValidationHTTPErrorStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 400, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        let body: [String: Any] = ["error": [
            "code": "json_validate_failed",
            "type": "invalid_request_error",
            "message": "secret response with reflected prompt",
            "failed_generation": ["private": "secret response"],
        ]]
        let data = try! JSONSerialization.data(withJSONObject: body)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
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
