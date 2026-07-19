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
            throw AISummarizerError.http(401, "unauthorized")
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

    func testTranslationSpikeRejectsReorderedOrDuplicatedPlaceholders() async throws {
        let document = ActDocument(
            caseKey: "case", sourceActID: "act", caseNumber: "2-1/2026",
            judicialUID: nil, court: "Суд", instanceLevel: .first,
            kind: "Решение", date: "", sourceText: "Взыскать 10 рублей и 20 рублей.")
        let pipeline = AppleTranslatedActSummarizer(
            englishSummarizer: EnglishSpikeSummarizer(),
            russianToEnglish: {
                $0.replacingOccurrences(of: "⟦A001⟧ и ⟦A002⟧",
                                         with: "⟦A002⟧ и ⟦A001⟧")
            },
            englishToRussian: { $0 })
        do {
            _ = try await pipeline.summarize(document: document, options: SummaryOptions())
            XCTFail("reordered placeholder IDs must be rejected")
        } catch {
            // expected
        }
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


    func testSummaryPromptDecodesSingleLineMarkdownFence() throws {
        let summary = ActSummary(localWarnings: ["local"])
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(summary), encoding: .utf8))
        let decoded = try SummaryPrompt.decode("```json\(json)```")
        XCTAssertEqual(decoded.localWarnings, ["local"])
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
        let messages = try XCTUnwrap(json["messages"] as? [[String: String]])
        let prompt = messages.compactMap { $0["content"] }.joined(separator: "\n")
        XCTAssertTrue(prompt.contains("ТОЛЬКО ВЫБРАННЫЙ АКТ"))
        XCTAssertFalse(prompt.contains("РЕАЛЬНЫЙ ПОСТОРОННИЙ АКТ"))
        XCTAssertFalse(String(data: body, encoding: .utf8)?.contains("test-secret") == true)
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
        let summary = ActSummary(circumstances: [SummaryClaim(
            text: "Проверенный вывод.",
            citations: [SummaryCitation(paragraphID: "¶1",
                                         evidenceQuote: "ТОЛЬКО ВЫБРАННЫЙ АКТ")])])
        let content = String(data: try! JSONEncoder().encode(summary), encoding: .utf8)!
        let envelope: [String: Any] = ["choices": [["message": ["content": content]]]]
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
