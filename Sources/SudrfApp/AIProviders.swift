import Foundation
import SudrfKit

enum AISummarizerError: LocalizedError, Sendable {
    case cloudConsentRequired
    case missingCredential
    case concreteModelRequired
    case providerUnavailable(String)
    case invalidResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .cloudConsentRequired:
            "Сначала разрешите облачную обработку выбранного акта в Настройки → AI."
        case .missingCredential: "API-ключ не найден в Keychain."
        case .concreteModelRequired: "Укажите конкретный model ID в Настройки → AI."
        case .providerUnavailable(let reason): reason
        case .invalidResponse: "Провайдер вернул ответ, не соответствующий ActSummary."
        case .http(let status, _): "AI API вернул HTTP \(status). Ответ провайдера скрыт из соображений безопасности."
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

/// Один автоматический retry разрешён только для invalid structured output или
/// локальной проверки. Второй сомнительный результат никогда не показывается.
struct ValidatedActSummarizer<Base: ActSummarizing>: ActSummarizing {
    let base: Base

    func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
        var lastError: Error?
        for _ in 0..<2 {
            do {
                let value = try await base.summarize(document: document, options: options)
                try ActSummaryValidator.validate(value, against: document)
                return value
            } catch {
                if error is CancellationError { throw error }
                guard isRetryable(error) else { throw error }
                lastError = error
            }
        }
        throw lastError ?? AISummarizerError.invalidResponse
    }

    private func isRetryable(_ error: Error) -> Bool {
        if error is ActSummaryValidationError { return true }
        if let summarizerError = error as? AISummarizerError,
           case .invalidResponse = summarizerError { return true }
        return false
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

actor GigaChatActSummarizer: ActSummarizing {
    let authorizationKey: String
    let scope: String
    let model: String
    private let session: URLSession
    private var cachedToken: (value: String, expiresAt: Date)?

    init(authorizationKey: String, scope: String, model: String,
         session: URLSession = .shared) {
        self.authorizationKey = authorizationKey; self.scope = scope
        self.model = model; self.session = session
    }

    func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
        let token = try await accessToken()
        let body: [String: Any] = [
            "model": model,
            "messages": SummaryPrompt.messages(document: document),
            "response_format": ["type": "json_schema", "schema": SummaryPrompt.jsonSchema,
                                "strict": true],
        ]
        guard let endpoint = URL(string: "https://api.giga.chat/v1/chat/completions") else {
            throw AISummarizerError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await HTTPJSON.send(request, session: session)
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw AISummarizerError.invalidResponse }
        return try SummaryPrompt.decode(content)
    }

    private func accessToken() async throws -> String {
        if let cachedToken, cachedToken.expiresAt > Date().addingTimeInterval(60) {
            return cachedToken.value
        }
        guard let endpoint = URL(string: "https://api.giga.chat/api/v2/oauth") else {
            throw AISummarizerError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Basic \(authorizationKey)", forHTTPHeaderField: "Authorization")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "RqUID")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("scope=\(scope)".utf8)
        let json = try await HTTPJSON.send(request, session: session)
        guard let token = json["access_token"] as? String else { throw AISummarizerError.invalidResponse }
        let milliseconds = json["expires_at"] as? Double ?? (Date().timeIntervalSince1970 + 1_800) * 1_000
        cachedToken = (token, Date(timeIntervalSince1970: milliseconds / 1_000))
        return token
    }
}

actor YandexGPTActSummarizer: ActSummarizing {
    let apiKey: String
    let folderID: String
    let model: String
    private let session: URLSession

    init(apiKey: String, folderID: String, model: String, session: URLSession = .shared) {
        self.apiKey = apiKey; self.folderID = folderID; self.model = model; self.session = session
    }

    func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
        let body: [String: Any] = [
            "modelUri": "gpt://\(folderID)/\(model)",
            "completionOptions": ["stream": false, "temperature": 0],
            "messages": SummaryPrompt.messages(document: document),
        ]
        guard let endpoint = URL(
            string: "https://llm.api.cloud.yandex.net/foundationModels/v1/completion") else {
            throw AISummarizerError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Api-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(folderID, forHTTPHeaderField: "x-folder-id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let json = try await HTTPJSON.send(request, session: session)
        guard let result = json["result"] as? [String: Any],
              let alternatives = result["alternatives"] as? [[String: Any]],
              let message = alternatives.first?["message"] as? [String: Any],
              let text = message["text"] as? String else { throw AISummarizerError.invalidResponse }
        return try SummaryPrompt.decode(text)
    }
}

enum HTTPJSON {
    static func send(_ request: URLRequest, session: URLSession) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AISummarizerError.invalidResponse }
        guard 200..<300 ~= http.statusCode else {
            throw AISummarizerError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AISummarizerError.invalidResponse
        }
        return json
    }
}

enum SummaryPrompt {
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
        properties["intermediateEnglishSummary"] = ["type": ["string", "null"]]
        properties["usedDoubleTranslation"] = ["type": "boolean"]
        return ["type": "object", "additionalProperties": false,
                "properties": properties,
                "required": sectionNames + ["warnings", "intermediateEnglishSummary",
                                               "usedDoubleTranslation"]]
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
        guard let data = candidate.data(using: .utf8),
              let result = try? JSONDecoder().decode(ActSummary.self, from: data) else {
            throw AISummarizerError.invalidResponse
        }
        return result
    }
}
