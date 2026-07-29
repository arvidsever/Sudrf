import Foundation
import SudrfKit

enum SafeProviderFailureCode: String, Sendable {
    case jsonValidateFailed = "json_validate_failed"
}

enum AISummarizerError: LocalizedError, Sendable {
    case cloudConsentRequired
    case missingCredential
    case concreteModelRequired
    case translationLanguagesNotInstalled
    case providerUnavailable(String)
    case invalidResponse
    case invalidResponseField(String)
    case structuredOutputFailedAfterRetry
    case http(Int, retryAfterSeconds: Int? = nil,
              providerCode: SafeProviderFailureCode? = nil)

    var errorDescription: String? {
        switch self {
        case .cloudConsentRequired:
            "Сначала разрешите облачную обработку выбранного акта в Настройки → AI."
        case .missingCredential: "API-ключ не найден в Keychain."
        case .concreteModelRequired: "Укажите конкретный model ID в Настройки → AI."
        case .translationLanguagesNotInstalled:
            "Языковая пара русский ↔ английский не установлена. Подготовьте её в Настройки → AI."
        case .providerUnavailable(let reason): reason
        case .invalidResponse: "Провайдер вернул ответ, не соответствующий ActSummary."
        case .invalidResponseField(let path):
            "Провайдер вернул неверный тип или значение в поле \(path)."
        case .structuredOutputFailedAfterRetry:
            "Groq принял API-ключ, но после повторной попытки не смог сформировать структурированную сводку."
        case .http(let status, let retryAfterSeconds, let providerCode):
            if status == 400, providerCode == .jsonValidateFailed {
                "Groq принял API-ключ, но не смог сформировать сводку по заданной JSON-схеме."
            } else if status == 429 {
                if let retryAfterSeconds {
                    "Лимит AI API исчерпан. Повторите через \(retryAfterSeconds) сек."
                } else {
                    "Лимит AI API исчерпан. Повторите запрос позднее."
                }
            } else {
                "AI API вернул HTTP \(status)."
            }
        }
    }
}

struct MockActSummarizer: ActSummarizing {
    func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
        guard let first = document.paragraphs.first else { return ActSummary() }
        let citation = SummaryCitation(paragraphID: first.id,
                                       evidenceQuote: String(first.text.prefix(160)))
        return ActSummary(
            circumstances: [SummaryClaim(
                text: "Тестовая локальная сводка по первому абзацу.", citations: [citation])],
            localWarnings: ["Mock-провайдер не выполняет юридический анализ."])
    }
}

/// Делит документ строго по сохранённым paragraph boundaries. Внешнему
/// провайдеру передаётся только выбранный акт; никакого доступа к каталогу у
/// wrapper нет. Частичные summaries объединяются детерминированно, сохраняя ¶ID.
struct ChunkingActSummarizer<Base: ActSummarizing>: ActSummarizing {
    let base: Base

    func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
        let groups = chunks(document.paragraphs, budget: options.maxInputCharacters)
        guard groups.count > 1 else { return try await base.summarize(document: document, options: options) }
        var partials: [ActSummary] = []
        for group in groups {
            try Task.checkCancellation()
            let fragment = ActDocument(
                id: document.id, caseKey: document.caseKey, sourceActID: document.sourceActID,
                caseNumber: document.caseNumber, judicialUID: document.judicialUID,
                court: document.court, instanceLevel: document.instanceLevel,
                kind: document.kind, date: document.date,
                sourceText: group.map(\.text).joined(separator: "\n\n"),
                sourceHash: document.sourceHash,
                paragraphizerVersion: document.paragraphizerVersion, paragraphs: group)
            partials.append(try await base.summarize(document: fragment, options: options))
        }
        return ActSummary.merging(partials)
    }

    private func chunks(_ paragraphs: [ActParagraph], budget: Int) -> [[ActParagraph]] {
        var result: [[ActParagraph]] = []
        var current: [ActParagraph] = []
        var count = 0
        for paragraph in paragraphs {
            if !current.isEmpty, count + paragraph.text.count > budget {
                result.append(current); current = []; count = 0
            }
            current.append(paragraph); count += paragraph.text.count
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// На один fragment разрешён ровно один общий retry: либо после invalid
/// structured output/локальной проверки, либо после кратковременного HTTP
/// сбоя. Таким образом один chunk никогда не создаёт больше двух запросов.
struct ValidatedActSummarizer<Base: ActSummarizing>: ActSummarizing {
    let base: Base

    func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                let value = try await base.summarize(document: document, options: options)
                try ActSummaryValidator.validate(value, against: document)
                return value
            } catch {
                if error is CancellationError { throw error }
                guard attempt == 0 else {
                    if isJSONValidationFailure(error) {
                        throw AISummarizerError.structuredOutputFailedAfterRetry
                    }
                    throw error
                }
                guard let delay = retryDelay(error) else { throw error }
                lastError = error
                if delay > .zero {
                    try await Task.sleep(for: delay)
                }
            }
        }
        throw lastError ?? AISummarizerError.invalidResponse
    }

    private func retryDelay(_ error: Error) -> Duration? {
        if error is ActSummaryValidationError { return .zero }
        if let summarizerError = error as? AISummarizerError,
           case .invalidResponse = summarizerError { return .zero }
        if let summarizerError = error as? AISummarizerError,
           case .invalidResponseField = summarizerError { return .zero }
        guard let summarizerError = error as? AISummarizerError,
              case .http(let status, let retryAfter, let providerCode) = summarizerError
        else { return nil }
        if status == 400, providerCode == .jsonValidateFailed { return .zero }
        if status == 429 {
            let seconds = retryAfter ?? 1
            return seconds <= 15 ? .seconds(seconds) : nil
        }
        return (500...599).contains(status) ? .seconds(1) : nil
    }

    private func isJSONValidationFailure(_ error: Error) -> Bool {
        guard let summarizerError = error as? AISummarizerError,
              case .http(400, _, .jsonValidateFailed) = summarizerError
        else { return false }
        return true
    }
}

/// После слияния чанков проверяем результат против полного документа, но не
/// повторяем уже успешно обработанные chunks.
struct FinalValidatedActSummarizer<Base: ActSummarizing>: ActSummarizing {
    let base: Base

    func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
        let value = try await base.summarize(document: document, options: options)
        try ActSummaryValidator.validate(value, against: document)
        return value
    }
}

struct GroqMessage: Codable, Sendable {
    let role: String
    let content: String
}

private struct GroqSummaryJSONSchema: Encodable, Sendable {
    let type = "object"
    let additionalProperties = false
    let properties = RootProperties()
    let required = ["items"]

    struct RootProperties: Encodable, Sendable {
        let items = ItemsSchema()
    }

    struct ItemsSchema: Encodable, Sendable {
        let type = "array"
        let items = ItemSchema()
    }

    struct ItemSchema: Encodable, Sendable {
        let type = "object"
        let additionalProperties = false
        let properties = ItemProperties()
        let required = ["section", "text", "citations"]
    }

    struct ItemProperties: Encodable, Sendable {
        let section = SectionSchema()
        let text = StringSchema()
        let citations = CitationsSchema()
    }

    struct SectionSchema: Encodable, Sendable {
        let type = "string"
        let allowedValues = SummaryPrompt.ProviderSection.allCases.map(\.rawValue)

        private enum CodingKeys: String, CodingKey {
            case type
            case allowedValues = "enum"
        }
    }

    struct StringSchema: Encodable, Sendable {
        let type = "string"
    }

    struct CitationsSchema: Encodable, Sendable {
        let type = "array"
        let items = CitationSchema()
    }

    struct CitationSchema: Encodable, Sendable {
        let type = "object"
        let additionalProperties = false
        let properties = CitationProperties()
        let required = ["paragraphID", "evidenceQuote"]
    }

    struct CitationProperties: Encodable, Sendable {
        let paragraphID = StringSchema()
        let evidenceQuote = StringSchema()
    }
}

private struct GroqChatCompletionRequest: Encodable, Sendable {
    let model: String
    let temperature = 0.2
    let reasoningEffort = "low"
    let maxCompletionTokens: Int?
    let messages: [GroqMessage]
    let responseFormat = ResponseFormat()

    private enum CodingKeys: String, CodingKey {
        case model, temperature, messages
        case reasoningEffort = "reasoning_effort"
        case maxCompletionTokens = "max_completion_tokens"
        case responseFormat = "response_format"
    }

    struct ResponseFormat: Encodable, Sendable {
        let type = "json_schema"
        let jsonSchema = NamedSchema()

        private enum CodingKeys: String, CodingKey {
            case type
            case jsonSchema = "json_schema"
        }
    }

    struct NamedSchema: Encodable, Sendable {
        let name = "act_summary_items"
        let strict = true
        let schema = GroqSummaryJSONSchema()
    }
}

private struct GroqChatCompletionResponse: Decodable, Sendable {
    let choices: [Choice]

    struct Choice: Decodable, Sendable {
        let message: Message
    }

    struct Message: Decodable, Sendable {
        let content: String
    }
}

actor GroqActSummarizer: ActSummarizing {
    let key: String
    let model: String
    private let session: URLSession

    init(key: String, model: String, session: URLSession = .shared) {
        self.key = key; self.model = model; self.session = session
    }

    func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
        // Free Groq projects currently have an 8K TPM ceiling. Reserving output
        // tokens together with a near-limit legal act is rejected before
        // inference (HTTP 413). For a large single chunk, omit the reservation
        // and let Groq apply its server-side completion cap; the compact schema
        // remains bounded by the prompt. Short requests keep an explicit cap.
        let maxCompletionTokens = document.sourceText.count > 12_000 ? nil : 4_096
        let body = GroqChatCompletionRequest(
            model: model, maxCompletionTokens: maxCompletionTokens,
            messages: SummaryPrompt.messages(document: document))
        guard let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            throw AISummarizerError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data = try await HTTPJSON.send(request, session: session)
        guard let response = try? JSONDecoder().decode(
            GroqChatCompletionResponse.self, from: data),
              let content = response.choices.first?.message.content
        else { throw AISummarizerError.invalidResponse }
        return try SummaryPrompt.decode(content)
    }
}

enum HTTPJSON {
    static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AISummarizerError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            // Тело ошибки может содержать отражённый prompt или провайдерские
            // диагностические данные. Читаем только allowlisted machine code;
            // сырые message/failed_generation не удерживаем внутри Error.
            let retryAfter = retryAfterSeconds(
                http.value(forHTTPHeaderField: "Retry-After"))
            let providerCode = safeProviderCode(in: data)
            throw AISummarizerError.http(
                http.statusCode, retryAfterSeconds: retryAfter, providerCode: providerCode)
        }
        return data
    }

    private static func safeProviderCode(in data: Data) -> SafeProviderFailureCode? {
        struct ProviderError: Decodable {
            let code: String?
            let type: String?
        }
        struct ErrorEnvelope: Decodable {
            let error: ProviderError?
        }
        guard let providerError = try? JSONDecoder().decode(ErrorEnvelope.self, from: data).error
        else { return nil }
        return [providerError.code, providerError.type]
            .compactMap { $0 }
            .compactMap { SafeProviderFailureCode(rawValue: $0) }
            .first
    }

    private static func retryAfterSeconds(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        if let seconds = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, Int(ceil(date.timeIntervalSinceNow)))
    }
}

enum SummaryPrompt {
    enum ProviderSection: String, CaseIterable, Decodable, Sendable {
        case claims
        case partyPositions = "party_positions"
        case circumstances
        case reasoning
        case disposition
        case amounts
        case dates
        case deadlines
        case appeal
        case warnings
    }

    /// Единственная форма JSON, которую разрешено заполнять внешней модели.
    /// Локальная диагностика и признаки translation pipeline намеренно здесь
    /// отсутствуют: schema-less provider не может подложить их как доверенные.
    private struct ProviderActSummaryPayload: Decodable {
        let items: [ProviderSummaryItem]

        struct ProviderSummaryItem: Decodable {
            let section: ProviderSection
            let text: String
            let citations: [SummaryCitation]

            var claim: SummaryClaim {
                SummaryClaim(text: text, citations: citations)
            }
        }

        var summary: ActSummary {
            func claims(for section: ProviderSection) -> [SummaryClaim] {
                items.lazy.filter { $0.section == section }.map(\.claim)
            }
            return ActSummary(
                claims: claims(for: .claims),
                partyPositions: claims(for: .partyPositions),
                circumstances: claims(for: .circumstances),
                reasoning: claims(for: .reasoning),
                disposition: claims(for: .disposition),
                amounts: claims(for: .amounts), dates: claims(for: .dates),
                deadlines: claims(for: .deadlines), appeal: claims(for: .appeal),
                warnings: claims(for: .warnings))
        }
    }

    static func messages(document: ActDocument) -> [GroqMessage] {
        let paragraphs = document.paragraphs.map { "[\($0.id)] \($0.text)" }.joined(separator: "\n\n")
        return [
            GroqMessage(role: "system", content: """
            Ты анализируешь судебный акт. Верни только JSON по заданной схеме. Не додумывай факты.
            Каждый непустой вывод обязан иметь citations; evidenceQuote — дословная подстрока указанного абзаца.
            section выбирай из enum схемы; отсутствующие разделы просто не добавляй в items.
            Дай не более трёх кратких выводов на раздел и не более тридцати items всего.
            Для evidenceQuote выбирай кратчайшую достаточную дословную цитату, обычно до 240 символов.
            Предупреждения используй как section=warnings; они тоже обязаны иметь text и citations.
            Числа, даты, суммы, номера дел и нормы права копируй только из оригинала.
            """),
            GroqMessage(role: "user", content: """
            Дело № \(document.caseNumber). Суд: \(document.court). Вид: \(document.kind).

            \(paragraphs)
            """),
        ]
    }

    static var jsonSchema: [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(
            with: JSONEncoder().encode(GroqSummaryJSONSchema())),
              let schema = object as? [String: Any]
        else { preconditionFailure("Groq summary schema must be JSON encodable") }
        return schema
    }

    static func decode(_ text: String) throws -> ActSummary {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("```") {
            candidate.removeFirst(3)
            candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.lowercased().hasPrefix("json") {
                candidate.removeFirst(4)
                candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if candidate.hasSuffix("```") {
                candidate.removeLast(3)
                candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let data = candidate.data(using: .utf8) else {
            throw AISummarizerError.invalidResponse
        }
        let payload: ProviderActSummaryPayload
        do {
            payload = try JSONDecoder().decode(ProviderActSummaryPayload.self, from: data)
        } catch let error as DecodingError {
            throw AISummarizerError.invalidResponseField(safeCodingPath(error))
        } catch {
            throw AISummarizerError.invalidResponse
        }
        return payload.summary
    }

    private static func safeCodingPath(_ error: DecodingError) -> String {
        var path: [any CodingKey]
        switch error {
        case .typeMismatch(_, let context), .valueNotFound(_, let context),
             .dataCorrupted(let context):
            path = context.codingPath
        case .keyNotFound(let key, let context):
            path = context.codingPath + [key]
        @unknown default:
            return "<root>"
        }
        let value = path.map(\.stringValue).joined(separator: ".")
        return value.isEmpty ? "<root>" : value
    }
}
