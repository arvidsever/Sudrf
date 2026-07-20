import Foundation
import SudrfKit

enum AISummarizerError: LocalizedError, Sendable {
    case cloudConsentRequired
    case missingCredential
    case concreteModelRequired
    case translationLanguagesNotInstalled
    case providerUnavailable(String)
    case invalidResponse
    case invalidResponseField(String)
    case http(Int, retryAfterSeconds: Int? = nil)

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
        case .http(let status, let retryAfterSeconds):
            if status == 429 {
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
                guard attempt == 0 else { throw error }
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
              case .http(let status, let retryAfter) = summarizerError else { return nil }
        if status == 429 {
            let seconds = retryAfter ?? 1
            return seconds <= 15 ? .seconds(seconds) : nil
        }
        return (500...599).contains(status) ? .seconds(1) : nil
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

actor GroqActSummarizer: ActSummarizing {
    let key: String
    let model: String
    private let session: URLSession

    init(key: String, model: String, session: URLSession = .shared) {
        self.key = key; self.model = model; self.session = session
    }

    func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.000001,
            "messages": SummaryPrompt.messages(document: document),
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": "act_summary", "strict": true,
                                "schema": SummaryPrompt.jsonSchema],
            ],
        ]
        guard let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            throw AISummarizerError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await HTTPJSON.send(request, session: session)
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw AISummarizerError.invalidResponse }
        return try SummaryPrompt.decode(content)
    }
}

enum HTTPJSON {
    static func send(_ request: URLRequest, session: URLSession) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AISummarizerError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            // Тело ошибки может содержать отражённый prompt или провайдерские
            // диагностические данные. Не удерживаем его даже внутри Error.
            let retryAfter = retryAfterSeconds(
                http.value(forHTTPHeaderField: "Retry-After"))
            throw AISummarizerError.http(http.statusCode, retryAfterSeconds: retryAfter)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AISummarizerError.invalidResponse
        }
        return json
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
    /// Единственная форма JSON, которую разрешено заполнять внешней модели.
    /// Локальная диагностика и признаки translation pipeline намеренно здесь
    /// отсутствуют: schema-less provider не может подложить их как доверенные.
    private struct ProviderActSummaryPayload: Decodable {
        let claims: [SummaryClaim]
        let partyPositions: [SummaryClaim]
        let circumstances: [SummaryClaim]
        let reasoning: [SummaryClaim]
        let disposition: [SummaryClaim]
        let amounts: [SummaryClaim]
        let dates: [SummaryClaim]
        let deadlines: [SummaryClaim]
        let appeal: [SummaryClaim]
        let warnings: [SummaryClaim]

        private enum CodingKeys: String, CodingKey {
            case claims, partyPositions, circumstances, reasoning, disposition
            case amounts, dates, deadlines, appeal, warnings
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            claims = try values.decodeIfPresent([SummaryClaim].self, forKey: .claims) ?? []
            partyPositions = try values.decodeIfPresent(
                [SummaryClaim].self, forKey: .partyPositions) ?? []
            circumstances = try values.decodeIfPresent(
                [SummaryClaim].self, forKey: .circumstances) ?? []
            reasoning = try values.decodeIfPresent([SummaryClaim].self, forKey: .reasoning) ?? []
            disposition = try values.decodeIfPresent(
                [SummaryClaim].self, forKey: .disposition) ?? []
            amounts = try values.decodeIfPresent([SummaryClaim].self, forKey: .amounts) ?? []
            dates = try values.decodeIfPresent([SummaryClaim].self, forKey: .dates) ?? []
            deadlines = try values.decodeIfPresent([SummaryClaim].self, forKey: .deadlines) ?? []
            appeal = try values.decodeIfPresent([SummaryClaim].self, forKey: .appeal) ?? []
            warnings = try values.decodeIfPresent([SummaryClaim].self, forKey: .warnings) ?? []
        }

        var summary: ActSummary {
            ActSummary(
                claims: claims, partyPositions: partyPositions,
                circumstances: circumstances, reasoning: reasoning,
                disposition: disposition, amounts: amounts, dates: dates,
                deadlines: deadlines, appeal: appeal, warnings: warnings)
        }
    }

    static func messages(document: ActDocument) -> [[String: String]] {
        let paragraphs = document.paragraphs.map { "[\($0.id)] \($0.text)" }.joined(separator: "\n\n")
        return [
            ["role": "system", "content": """
            Ты анализируешь судебный акт. Верни только JSON по заданной схеме. Не додумывай факты.
            Каждый непустой вывод обязан иметь citations; evidenceQuote — дословная подстрока указанного абзаца.
            Предупреждения модели в warnings подчиняются тем же правилам: каждое содержит text и citations.
            Числа, даты, суммы, номера дел и нормы права копируй только из оригинала.
            """],
            ["role": "user", "content": """
            Дело № \(document.caseNumber). Суд: \(document.court). Вид: \(document.kind).

            \(paragraphs)
            """],
        ]
    }

    static var claimSchema: [String: Any] {
        [
            "type": "object", "additionalProperties": false,
            "properties": [
                "text": ["type": "string"],
                "citations": ["type": "array", "items": [
                    "type": "object", "additionalProperties": false,
                    "properties": ["paragraphID": ["type": "string"],
                                   "evidenceQuote": ["type": "string"]],
                    "required": ["paragraphID", "evidenceQuote"],
                ]],
            ],
            "required": ["text", "citations"],
        ]
    }

    static var jsonSchema: [String: Any] {
        let sectionNames = ["claims", "partyPositions", "circumstances", "reasoning",
                            "disposition", "amounts", "dates", "deadlines", "appeal"]
        var properties: [String: Any] = Dictionary(uniqueKeysWithValues: sectionNames.map {
            ($0, ["type": "array", "items": claimSchema] as [String: Any])
        })
        properties["warnings"] = ["type": "array", "items": claimSchema]
        return ["type": "object", "additionalProperties": false,
                "properties": properties,
                "required": sectionNames + ["warnings"]]
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
