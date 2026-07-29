import XCTest
import SudrfKit
@testable import SudrfApp

final class AISummaryPipelineTests: XCTestCase {
    private actor EnglishSpikeSummarizer: ActSummarizing {
        private(set) var receivedParagraphIDs: [String] = []
        private(set) var receivedText = ""

        func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
            receivedParagraphIDs = document.paragraphs.map(\.id)
            receivedText = document.sourceText
            return ActSummary(
                disposition: [SummaryClaim(
                    text: "Award ⟦A001⟧ under ⟦L001⟧ and ⟦L002⟧ on ⟦D001⟧.",
                    citations: [SummaryCitation(paragraphID: "¶1",
                                                evidenceQuote: document.paragraphs[0].text)])],
                warnings: [SummaryClaim(
                    text: "Check ⟦A001⟧.",
                    citations: [SummaryCitation(paragraphID: "¶1",
                                                evidenceQuote: document.paragraphs[0].text)])])
        }
    }

    private actor RecordingSummarizer: ActSummarizing {
        private(set) var documents: [ActDocument] = []

        func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
            documents.append(document)
            guard let paragraph = document.paragraphs.first else { return ActSummary() }
            return ActSummary(circumstances: [SummaryClaim(
                text: "Фрагмент обработан.",
                citations: [SummaryCitation(paragraphID: paragraph.id,
                                             evidenceQuote: paragraph.text)])])
        }
    }

    private actor RetrySummarizer: ActSummarizing {
        private(set) var calls = 0
        let validOnSecondAttempt: Bool

        init(validOnSecondAttempt: Bool) {
            self.validOnSecondAttempt = validOnSecondAttempt
        }

        func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
            calls += 1
            guard validOnSecondAttempt, calls == 2, let paragraph = document.paragraphs.first else {
                return ActSummary(reasoning: [SummaryClaim(text: "Без ссылки", citations: [])])
            }
            return ActSummary(reasoning: [SummaryClaim(
                text: "Проверенный вывод.",
                citations: [SummaryCitation(paragraphID: paragraph.id,
                                             evidenceQuote: paragraph.text)])])
        }
    }

    private actor HTTPFailureSummarizer: ActSummarizing {
        private(set) var calls = 0
        func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
            calls += 1
            throw AISummarizerError.http(401)
        }
    }

    private struct BenchmarkSummarizer: ActSummarizing {
        func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
            let citation = SummaryCitation(paragraphID: "¶1",
                                            evidenceQuote: document.paragraphs[0].text)
            return ActSummary(disposition: [SummaryClaim(
                text: "Взыскать 10 000 рублей по делу 2-1/2026 в течение месяца.",
                citations: [citation])])
        }
    }

    func testChunkingPreservesOriginalParagraphIDsAndOnlySelectedDocumentText() async throws {
        let paragraphs = (1...6).map { "Абзац \($0): " + String(repeating: "текст ", count: 190) }
        let document = ActDocument(
            caseKey: "case", sourceActID: "act", caseNumber: "2-1/2026",
            judicialUID: nil, court: "Суд", instanceLevel: .first,
            kind: "Решение", date: "", sourceText: paragraphs.joined(separator: "\n"))
        let recorder = RecordingSummarizer()
        let pipeline = ChunkingActSummarizer(base: recorder)

        let result = try await pipeline.summarize(
            document: document, options: SummaryOptions(maxInputCharacters: 1_500))
        let sent = await recorder.documents

        XCTAssertGreaterThan(sent.count, 1)
        XCTAssertEqual(Set(sent.flatMap { $0.paragraphs.map(\.id) }), Set(document.paragraphs.map(\.id)))
        XCTAssertEqual(result.allClaims.count, sent.count)
        XCTAssertTrue(sent.allSatisfy { fragment in
            fragment.paragraphs.allSatisfy { document.paragraphs.contains($0) }
        })
    }

    func testValidationAllowsExactlyOneAutomaticRetry() async throws {
        let document = ActDocument(
            caseKey: "case", sourceActID: "act", caseNumber: "2-1/2026",
            judicialUID: nil, court: "Суд", instanceLevel: .first,
            kind: "Решение", date: "", sourceText: "Исходный абзац.")
        let succeeds = RetrySummarizer(validOnSecondAttempt: true)
        _ = try await ValidatedActSummarizer(base: succeeds)
            .summarize(document: document, options: SummaryOptions())
        let successfulCalls = await succeeds.calls
        XCTAssertEqual(successfulCalls, 2)

        let fails = RetrySummarizer(validOnSecondAttempt: false)
        do {
            _ = try await ValidatedActSummarizer(base: fails)
                .summarize(document: document, options: SummaryOptions())
            XCTFail("второй сомнительный результат нельзя возвращать")
        } catch {}
        let failedCalls = await fails.calls
        XCTAssertEqual(failedCalls, 2)

        let httpFailure = HTTPFailureSummarizer()
        do {
            _ = try await ValidatedActSummarizer(base: httpFailure)
                .summarize(document: document, options: SummaryOptions())
            XCTFail("HTTP/auth errors must not be retried")
        } catch {}
        let httpCalls = await httpFailure.calls
        XCTAssertEqual(httpCalls, 1)
    }

    func testTranslationSpikeProtectsLiteralsAndMapsCitationsBackToRussianParagraphs() async throws {
        let source = "01.07.2026 суд решил взыскать 10 000 рублей в течение 30 дней, УИД 77RS0001-01-2026-000001-10, по пункту 2 статьи 15."
        let document = ActDocument(
            caseKey: "case", sourceActID: "act", caseNumber: "2-1/2026",
            judicialUID: nil, court: "Суд", instanceLevel: .first,
            kind: "Решение", date: "01.07.2026", sourceText: source)
        let english = EnglishSpikeSummarizer()
        let pipeline = AppleTranslatedActSummarizer(
            englishSummarizer: english,
            russianToEnglish: { $0 },
            englishToRussian: { $0 })

        let summary = try await pipeline.summarize(
            document: document, options: SummaryOptions(maxInputCharacters: 6_000))
        let sentText = await english.receivedText
        let sentIDs = await english.receivedParagraphIDs

        XCTAssertTrue(sentText.contains("⟦D001⟧"))
        XCTAssertTrue(sentText.contains("⟦A001⟧"))
        XCTAssertTrue(sentText.contains("⟦L001⟧"))
        XCTAssertTrue(sentText.contains("⟦L002⟧"))
        XCTAssertTrue(sentText.contains("⟦D002⟧"))
        XCTAssertTrue(sentText.contains("⟦N001⟧"))
        XCTAssertEqual(sentIDs, ["¶1"])
        XCTAssertEqual(summary.disposition.first?.citations.first?.evidenceQuote, source)
        XCTAssertTrue(summary.disposition.first?.text.contains("01.07.2026") == true)
        XCTAssertTrue(summary.disposition.first?.text.contains("10 000 рублей") == true)
        XCTAssertTrue(summary.disposition.first?.text.contains("пункту 2") == true)
        XCTAssertTrue(summary.disposition.first?.text.contains("статьи 15") == true)
        XCTAssertTrue(summary.usedDoubleTranslation)
        XCTAssertNotNil(summary.intermediateEnglishSummary)
        XCTAssertNoThrow(try ActSummaryValidator.validate(summary, against: document))
    }

    func testTranslationSpikeRejectsChangedLiteralPlaceholder() async throws {
        let document = ActDocument(
            caseKey: "case", sourceActID: "act", caseNumber: "2-1/2026",
            judicialUID: nil, court: "Суд", instanceLevel: .first,
            kind: "Решение", date: "", sourceText: "Взыскать 10 000 рублей.")
        let pipeline = AppleTranslatedActSummarizer(
            englishSummarizer: EnglishSpikeSummarizer(),
            russianToEnglish: { $0.replacingOccurrences(of: "⟦A001⟧", with: "A001") },
            englishToRussian: { $0 })

        do {
            _ = try await pipeline.summarize(document: document, options: SummaryOptions())
            XCTFail("изменённый literal ID нельзя принимать")
        } catch let error as AISummarizerError {
            guard case .providerUnavailable = error else {
                return XCTFail("ожидалась ошибка сохранности literal ID")
            }
        }
    }

    func testTranslationPlaceholderMultisetAllowsReorderButRejectsDuplication() {
        let original = LegalLiteralProtector.placeholderCounts(
            in: "⟦A001⟧ и ⟦A002⟧ по ⟦L001⟧")
        let reordered = LegalLiteralProtector.placeholderCounts(
            in: "under ⟦L001⟧: ⟦A002⟧ and ⟦A001⟧")
        let duplicated = LegalLiteralProtector.placeholderCounts(
            in: "⟦A001⟧, ⟦A001⟧, ⟦A002⟧, ⟦L001⟧")

        XCTAssertEqual(original, reordered)
        XCTAssertNotEqual(original, duplicated)
    }

    func testChunkMergeKeepsEnglishDiagnostics() {
        let first = ActSummary(localWarnings: ["one"], intermediateEnglishSummary: "chunk 1",
                               usedDoubleTranslation: true)
        let second = ActSummary(localWarnings: ["two"], intermediateEnglishSummary: "chunk 2",
                                usedDoubleTranslation: true)
        let merged = ActSummary.merging([first, second])
        XCTAssertTrue(merged.intermediateEnglishSummary?.contains("chunk 1") == true)
        XCTAssertTrue(merged.intermediateEnglishSummary?.contains("chunk 2") == true)
    }


    func testSummaryPromptDecodesFenceAndStripsProviderControlledMetadata() throws {
        let payload: [String: Any] = [
            "items": [[
                "section": "circumstances",
                "text": "Проверенный вывод.",
                "citations": [[
                    "paragraphID": "¶1",
                    "evidenceQuote": "Исходный текст",
                ]],
            ]],
            "localWarnings": ["Подложенное локальное предупреждение"],
            "intermediateEnglishSummary": "attacker diagnostic",
            "usedDoubleTranslation": true,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        let decoded = try SummaryPrompt.decode("```json\(json)```")
        XCTAssertEqual(decoded.circumstances.map(\.text), ["Проверенный вывод."])
        XCTAssertTrue(decoded.localWarnings.isEmpty)
        XCTAssertNil(decoded.intermediateEnglishSummary)
        XCTAssertFalse(decoded.usedDoubleTranslation)
        let schema = try XCTUnwrap(SummaryPrompt.jsonSchema["properties"] as? [String: Any])
        XCTAssertEqual(Set(schema.keys), ["items"])
        XCTAssertNil(schema["localWarnings"])
        XCTAssertNil(schema["intermediateEnglishSummary"])
        XCTAssertNil(schema["usedDoubleTranslation"])
    }

    func testSummaryPromptMapsEveryProviderSectionAndRejectsUnknownSection() throws {
        let sections = SummaryPrompt.ProviderSection.allCases.map(\.rawValue)
        let items = sections.enumerated().map { index, section in
            [
                "section": section,
                "text": "Вывод \(index)",
                "citations": [["paragraphID": "¶1", "evidenceQuote": "Фрагмент"]],
            ] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: ["items": items])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(try SummaryPrompt.decode(text).allClaims.count, sections.count)

        var invalidItems = items
        invalidItems[0]["section"] = "attacker_section"
        let invalidData = try JSONSerialization.data(withJSONObject: ["items": invalidItems])
        let invalidText = try XCTUnwrap(String(data: invalidData, encoding: .utf8))
        XCTAssertThrowsError(try SummaryPrompt.decode(invalidText))
    }

    func testHTTPErrorDoesNotRetainProviderBody() {
        let error = AISummarizerError.http(500)
        XCTAssertEqual(error.localizedDescription, "AI API вернул HTTP 500.")
        XCTAssertFalse(String(describing: error).contains("secret response"))
    }

    @MainActor
    func testGroqRequestContainsOnlySelectedActAndUsesPinnedModel() async throws {
        GroqRequestStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GroqRequestStub.self]
        let session = URLSession(configuration: configuration)
        let store = TrackedStore(inMemory: true)
        let context = MovementContext(
            branchRaw: CourtBranch.general.rawValue, region: "Москва",
            searchDomain: "court--msk.sudrf.ru", displayDomain: "court.msk.sudrf.ru",
            courtTitle: "Суд", courtLevelRaw: CourtLevel.district.rawValue,
            courtCode: "77", cartotekaId: "g1",
            cartotekaLevelRaw: CourtLevel.district.rawValue, caseNumber: "2-7/2026")
        let selected = CaseAct(id: "selected", title: "Решение", date: "",
                               courtShort: "Суд", instanceLevel: .first)
        let foreign = CaseAct(id: "foreign", title: "Определение", date: "",
                              courtShort: "Суд", instanceLevel: .appeal)
        let movement = CaseMovement(
            uid: "", caseNumber: context.caseNumber, inForce: false,
            instances: [], complaints: [:], acts: [selected, foreign],
            actBodies: [selected.id: "ТОЛЬКО ВЫБРАННЫЙ АКТ",
                        foreign.id: "РЕАЛЬНЫЙ ПОСТОРОННИЙ АКТ"],
            category: nil, parties: CaseParties())
        store.upsert(context: context, snapshot: nil, movement: movement, collections: [])
        let documents = try await CaseCatalog(container: store.container).acts()
        let document = try XCTUnwrap(
            documents.first(where: { $0.document.sourceActID == selected.id })?.document)

        _ = try await GroqActSummarizer(
            key: "test-secret", model: AISettings.personalModelID, session: session)
            .summarize(document: document, options: SummaryOptions())

        let body = try XCTUnwrap(GroqRequestStub.capturedBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "openai/gpt-oss-120b")
        XCTAssertEqual(json["temperature"] as? Double, 0.2)
        XCTAssertEqual(json["reasoning_effort"] as? String, "low")
        XCTAssertEqual(json["max_completion_tokens"] as? Int, 4_096)
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        let prompt = messages.compactMap { $0["content"] }.joined(separator: "\n")
        XCTAssertTrue(prompt.contains("ТОЛЬКО ВЫБРАННЫЙ АКТ"))
        XCTAssertFalse(prompt.contains("РЕАЛЬНЫЙ ПОСТОРОННИЙ АКТ"))
        XCTAssertFalse(String(data: body, encoding: .utf8)?.contains("test-secret") == true)

        let responseFormat = try XCTUnwrap(json["response_format"] as? [String: Any])
        XCTAssertEqual(responseFormat["type"] as? String, "json_schema")
        let namedSchema = try XCTUnwrap(responseFormat["json_schema"] as? [String: Any])
        XCTAssertEqual(namedSchema["strict"] as? Bool, true)
        let schema = try XCTUnwrap(namedSchema["schema"] as? [String: Any])
        assertStrictObjects(in: schema)
    }

    func testGroqLargeChunkOmitsCompletionReservationForFreeTier() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GroqRequestStub.self]
        let provider = GroqActSummarizer(
            key: "test-secret", model: "openai/gpt-oss-120b",
            session: URLSession(configuration: configuration))
        let document = ActDocument(
            caseKey: "selected", sourceActID: "large", caseNumber: "2-1/2026",
            judicialUID: nil, court: "Суд", instanceLevel: .first,
            kind: "Решение", date: "", sourceText: String(repeating: "А", count: 12_001))

        _ = try await provider.summarize(document: document, options: SummaryOptions())

        let body = try XCTUnwrap(GroqRequestStub.capturedBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["max_completion_tokens"])
    }

    /// Резерв вывода списывается из минутного бюджета до инференса, поэтому
    /// сумма «оценка входа + резерв» обязана укладываться в бюджет при любой
    /// длине запроса. Фиксированный резерв за порогом по символам этого не
    /// обеспечивал: 12 000 символов вместе с 4096 гарантированно выходили за
    /// лимит и получали HTTP 413, который не повторяется.
    func testCompletionReservationAlwaysFitsMinuteBudget() {
        for characters in stride(from: 0, through: 20_000, by: 250) {
            guard let reservation = GroqTokenBudget.completionReservation(
                forCharacters: characters) else { continue }
            XCTAssertGreaterThanOrEqual(reservation, GroqTokenBudget.minimumCompletionTokens)
            XCTAssertLessThanOrEqual(reservation, GroqTokenBudget.maximumCompletionTokens)
            XCTAssertLessThanOrEqual(
                GroqTokenBudget.estimatedInputTokens(forCharacters: characters) + reservation,
                GroqTokenBudget.usableTokens)
        }
        XCTAssertEqual(GroqTokenBudget.completionReservation(forCharacters: 400),
                       GroqTokenBudget.maximumCompletionTokens)
        XCTAssertNil(GroqTokenBudget.completionReservation(forCharacters: 11_000))
        XCTAssertNil(GroqTokenBudget.completionReservation(forCharacters: 12_000))
        XCTAssertNotEqual(GroqTokenBudget.completionReservation(forCharacters: 8_000),
                          GroqTokenBudget.maximumCompletionTokens)
    }

    func testGroqMidSizeChunkSendsReservationThatFitsBudget() async throws {
        GroqRequestStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GroqRequestStub.self]
        let provider = GroqActSummarizer(
            key: "test-secret", model: "openai/gpt-oss-120b",
            session: URLSession(configuration: configuration))
        let source = String(repeating: "А", count: 8_000)
        let document = ActDocument(
            caseKey: "selected", sourceActID: "mid", caseNumber: "2-1/2026",
            judicialUID: nil, court: "Суд", instanceLevel: .first,
            kind: "Решение", date: "", sourceText: source)

        _ = try await provider.summarize(document: document, options: SummaryOptions())

        let body = try XCTUnwrap(GroqRequestStub.capturedBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let reservation = try XCTUnwrap(json["max_completion_tokens"] as? Int)
        XCTAssertEqual(reservation,
                       GroqTokenBudget.completionReservation(forCharacters: source.count))
        XCTAssertLessThanOrEqual(
            GroqTokenBudget.estimatedInputTokens(forCharacters: source.count) + reservation,
            GroqTokenBudget.usableTokens)
    }

    func testTruncatedGroqResponseIsReportedAsOutputLimit() async throws {
        TruncatedGroqStub.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TruncatedGroqStub.self]
        let provider = GroqActSummarizer(
            key: "test-secret", model: "openai/gpt-oss-120b",
            session: URLSession(configuration: configuration))
        let document = ActDocument(
            caseKey: "selected", sourceActID: "truncated", caseNumber: "2-1/2026",
            judicialUID: nil, court: "Суд", instanceLevel: .first,
            kind: "Решение", date: "", sourceText: "Исходный абзац.")

        do {
            _ = try await ValidatedActSummarizer(base: provider)
                .summarize(document: document, options: SummaryOptions())
            XCTFail("Обрезанный ответ нельзя принимать за сводку")
        } catch let error as AISummarizerError {
            guard case .responseTruncatedByOutputLimit = error else {
                return XCTFail("Ожидался обрезанный ответ, получено \(error)")
            }
            XCTAssertEqual(
                error.localizedDescription,
                "Ответ провайдера обрезан лимитом вывода: полная сводка не получена.")
        }
        // Тот же запрос обрежется так же, поэтому повтор не тратится.
        XCTAssertEqual(TruncatedGroqStub.loads, 1)
    }

    func testBenchmarkRunnerCalculatesConfiguredThresholds() async throws {
        let fixture = SummaryBenchmarkFixture(
            id: "synthetic", caseNumber: "2-1/2026", court: "Суд",
            kind: "Решение", date: "01.07.2026",
            sourceText: "Суд исследовал материалы дела.",
            expectedCriticalValues: ["10 000 рублей", "2-1/2026", "месяца"],
            requiredSections: [.disposition])
        let configured = ConfiguredActSummarizer(
            provider: "test", model: "test-v1", options: SummaryOptions(),
            pipelineVersion: "test", summarizer: AnyActSummarizer(BenchmarkSummarizer()))

        let report = await SummaryBenchmarkRunner().run(
            fixtures: [fixture], configured: configured)

        XCTAssertEqual(report.citationAccuracy, 1)
        XCTAssertEqual(report.criticalAccuracy, 1)
        XCTAssertEqual(report.sectionCompleteness, 1)
        XCTAssertTrue(report.passed)
    }

    private func assertStrictObjects(
        in schema: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if schema["type"] as? String == "object" {
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false, file: file, line: line)
            let properties = schema["properties"] as? [String: Any] ?? [:]
            let required = schema["required"] as? [String] ?? []
            XCTAssertEqual(Set(properties.keys), Set(required), file: file, line: line)
        }
        for value in schema.values {
            if let nested = value as? [String: Any] {
                assertStrictObjects(in: nested, file: file, line: line)
            } else if let values = value as? [[String: Any]] {
                values.forEach { assertStrictObjects(in: $0, file: file, line: line) }
            }
        }
    }
}

private final class GroqRequestStub: URLProtocol {
    nonisolated(unsafe) static var capturedBody: Data?

    static func reset() { capturedBody = nil }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let body = request.httpBody {
            Self.capturedBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            Self.capturedBody = data
        }
        let payload: [String: Any] = ["items": [[
            "section": "circumstances",
            "text": "Проверенный вывод.",
            "citations": [[
                "paragraphID": "¶1",
                "evidenceQuote": "ТОЛЬКО ВЫБРАННЫЙ АКТ",
            ]],
        ]]]
        let content = String(
            data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        let envelope: [String: Any] = ["choices": [
            ["message": ["content": content], "finish_reason": "stop"],
        ]]
        let data = try! JSONSerialization.data(withJSONObject: envelope)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Ответ, оборванный лимитом вывода: JSON не закрыт, а `finish_reason` равен
/// `length`. Именно этот режим отказа стал вероятнее после отказа от резерва
/// вывода на крупных chunk.
private final class TruncatedGroqStub: URLProtocol {
    nonisolated(unsafe) static var loads = 0

    static func reset() { loads = 0 }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.loads += 1
        let envelope: [String: Any] = ["choices": [[
            "message": ["content": #"{"items": [{"section": "claims", "text": "Обрез"#],
            "finish_reason": "length",
        ]]]
        let data = try! JSONSerialization.data(withJSONObject: envelope)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
