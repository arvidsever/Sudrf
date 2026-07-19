import Foundation

public struct SummaryCitation: Sendable, Codable, Hashable {
    public var paragraphID: String
    public var evidenceQuote: String

    public init(paragraphID: String, evidenceQuote: String) {
        self.paragraphID = paragraphID
        self.evidenceQuote = evidenceQuote
    }
}

public struct SummaryClaim: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var text: String
    public var citations: [SummaryCitation]

    public init(id: UUID = UUID(), text: String, citations: [SummaryCitation]) {
        self.id = id
        self.text = text
        self.citations = citations
    }

    private enum CodingKeys: String, CodingKey { case text, citations }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        text = try values.decode(String.self, forKey: .text)
        citations = try values.decode([SummaryCitation].self, forKey: .citations)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(text, forKey: .text)
        try values.encode(citations, forKey: .citations)
    }
}

/// Structured output shared by every provider. Arrays deliberately allow a
/// section to contain several independently cited legal conclusions.
public struct ActSummary: Sendable, Codable, Hashable {
    public var claims: [SummaryClaim]
    public var partyPositions: [SummaryClaim]
    public var circumstances: [SummaryClaim]
    public var reasoning: [SummaryClaim]
    public var disposition: [SummaryClaim]
    public var amounts: [SummaryClaim]
    public var dates: [SummaryClaim]
    public var deadlines: [SummaryClaim]
    public var appeal: [SummaryClaim]
    /// Предупреждения, сформированные моделью. Это такие же проверяемые claims:
    /// они обязаны иметь citations и проходят literal validation.
    public var warnings: [SummaryClaim]
    /// Диагностика, добавленная самим приложением (mock/experimental status).
    /// Провайдер не может записать сюда данные через structured-output schema.
    public var localWarnings: [String]
    public var intermediateEnglishSummary: String?
    public var usedDoubleTranslation: Bool

    public init(claims: [SummaryClaim] = [], partyPositions: [SummaryClaim] = [],
                circumstances: [SummaryClaim] = [], reasoning: [SummaryClaim] = [],
                disposition: [SummaryClaim] = [], amounts: [SummaryClaim] = [],
                dates: [SummaryClaim] = [], deadlines: [SummaryClaim] = [],
                appeal: [SummaryClaim] = [], warnings: [SummaryClaim] = [],
                localWarnings: [String] = [],
                intermediateEnglishSummary: String? = nil,
                usedDoubleTranslation: Bool = false) {
        self.claims = claims
        self.partyPositions = partyPositions
        self.circumstances = circumstances
        self.reasoning = reasoning
        self.disposition = disposition
        self.amounts = amounts
        self.dates = dates
        self.deadlines = deadlines
        self.appeal = appeal
        self.warnings = warnings
        self.localWarnings = localWarnings
        self.intermediateEnglishSummary = intermediateEnglishSummary
        self.usedDoubleTranslation = usedDoubleTranslation
    }

    public var allClaims: [SummaryClaim] {
        claims + partyPositions + circumstances + reasoning + disposition
            + amounts + dates + deadlines + appeal + warnings
    }

    public static func merging(_ values: [ActSummary]) -> ActSummary {
        let diagnostics = values.compactMap(\.intermediateEnglishSummary)
        return ActSummary(
            claims: values.flatMap(\.claims),
            partyPositions: values.flatMap(\.partyPositions),
            circumstances: values.flatMap(\.circumstances),
            reasoning: values.flatMap(\.reasoning),
            disposition: values.flatMap(\.disposition),
            amounts: values.flatMap(\.amounts),
            dates: values.flatMap(\.dates),
            deadlines: values.flatMap(\.deadlines),
            appeal: values.flatMap(\.appeal),
            warnings: uniqueClaims(values.flatMap(\.warnings)),
            localWarnings: Array(Set(values.flatMap(\.localWarnings))).sorted(),
            intermediateEnglishSummary: diagnostics.isEmpty
                ? nil : diagnostics.joined(separator: "\n\n--- chunk ---\n\n"),
            usedDoubleTranslation: values.contains(where: \.usedDoubleTranslation))
    }

    private static func uniqueClaims(_ claims: [SummaryClaim]) -> [SummaryClaim] {
        claims.reduce(into: []) { result, claim in
            guard !result.contains(where: {
                $0.text == claim.text && $0.citations == claim.citations
            }) else { return }
            result.append(claim)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case claims, partyPositions, circumstances, reasoning, disposition
        case amounts, dates, deadlines, appeal, warnings, localWarnings
        case intermediateEnglishSummary, usedDoubleTranslation
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        claims = try values.decodeIfPresent([SummaryClaim].self, forKey: .claims) ?? []
        partyPositions = try values.decodeIfPresent([SummaryClaim].self, forKey: .partyPositions) ?? []
        circumstances = try values.decodeIfPresent([SummaryClaim].self, forKey: .circumstances) ?? []
        reasoning = try values.decodeIfPresent([SummaryClaim].self, forKey: .reasoning) ?? []
        disposition = try values.decodeIfPresent([SummaryClaim].self, forKey: .disposition) ?? []
        amounts = try values.decodeIfPresent([SummaryClaim].self, forKey: .amounts) ?? []
        dates = try values.decodeIfPresent([SummaryClaim].self, forKey: .dates) ?? []
        deadlines = try values.decodeIfPresent([SummaryClaim].self, forKey: .deadlines) ?? []
        appeal = try values.decodeIfPresent([SummaryClaim].self, forKey: .appeal) ?? []
        if let cited = try? values.decode([SummaryClaim].self, forKey: .warnings) {
            warnings = cited
            localWarnings = try values.decodeIfPresent([String].self, forKey: .localWarnings) ?? []
        } else {
            // Совместимость с сохранёнными до перехода на cited warnings
            // сводками: прежний свободный текст становится только локальной
            // непроверенной диагностикой и больше не считается выводом модели.
            warnings = []
            let legacy = (try? values.decode([String].self, forKey: .warnings)) ?? []
            localWarnings = legacy
                + (try values.decodeIfPresent([String].self, forKey: .localWarnings) ?? [])
        }
        intermediateEnglishSummary = try values.decodeIfPresent(
            String.self, forKey: .intermediateEnglishSummary)
        usedDoubleTranslation = try values.decodeIfPresent(
            Bool.self, forKey: .usedDoubleTranslation) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(claims, forKey: .claims)
        try values.encode(partyPositions, forKey: .partyPositions)
        try values.encode(circumstances, forKey: .circumstances)
        try values.encode(reasoning, forKey: .reasoning)
        try values.encode(disposition, forKey: .disposition)
        try values.encode(amounts, forKey: .amounts)
        try values.encode(dates, forKey: .dates)
        try values.encode(deadlines, forKey: .deadlines)
        try values.encode(appeal, forKey: .appeal)
        try values.encode(warnings, forKey: .warnings)
        try values.encode(localWarnings, forKey: .localWarnings)
        try values.encodeIfPresent(intermediateEnglishSummary, forKey: .intermediateEnglishSummary)
        try values.encode(usedDoubleTranslation, forKey: .usedDoubleTranslation)
    }
}

public struct SummaryOptions: Sendable, Codable, Hashable {
    public var maxInputCharacters: Int
    public var languageCode: String
    public var promptVersion: String

    public init(maxInputCharacters: Int = 18_000, languageCode: String = "ru",
                promptVersion: String = "act-summary-v1") {
        self.maxInputCharacters = max(1_000, maxInputCharacters)
        self.languageCode = languageCode
        self.promptVersion = promptVersion
    }
}

public protocol ActSummarizing: Sendable {
    func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary
}

public enum ActSummaryValidationError: LocalizedError, Sendable, Equatable {
    case missingCitation(String)
    case unknownParagraph(String)
    case evidenceNotVerbatim(String)
    case unsupportedLiteral(String)

    public var errorDescription: String? {
        switch self {
        case .missingCitation(let text): "Вывод не содержит ссылку на оригинал: \(text)"
        case .unknownParagraph(let id): "Сводка ссылается на отсутствующий абзац \(id)."
        case .evidenceNotVerbatim(let id): "Цитата для \(id) отсутствует в оригинале."
        case .unsupportedLiteral(let value): "Критический реквизит не найден в оригинале: \(value)"
        }
    }
}

public enum ActSummaryValidator {
    public static func validate(_ summary: ActSummary, against document: ActDocument) throws {
        let paragraphs = Dictionary(uniqueKeysWithValues: document.paragraphs.map { ($0.id, $0.text) })
        for claim in summary.allClaims where !claim.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard !claim.citations.isEmpty else {
                throw ActSummaryValidationError.missingCitation(claim.text)
            }
            for citation in claim.citations {
                guard let original = paragraphs[citation.paragraphID] else {
                    throw ActSummaryValidationError.unknownParagraph(citation.paragraphID)
                }
                let quote = canonicalEvidenceText(citation.evidenceQuote)
                guard !quote.isEmpty,
                      canonicalEvidenceText(original).contains(quote) else {
                    throw ActSummaryValidationError.evidenceNotVerbatim(citation.paragraphID)
                }
            }

            // Реквизит должен находиться именно в процитированных абзацах, а
            // не где-нибудь в другом месте документа. Boundary-aware поиск не
            // принимает 100 внутри 1100 или 3 дня внутри 23 дней.
            let citedSource = claim.citations.compactMap { paragraphs[$0.paragraphID] }
                .joined(separator: "\n")
            for literal in protectedLiterals(in: claim.text) {
                guard containsLiteral(literal, in: citedSource) else {
                    throw ActSummaryValidationError.unsupportedLiteral(literal)
                }
            }
        }
    }

    public static func protectedLiterals(in text: String) -> [String] {
        let patterns = [
            #"\b\d{1,2}[./]\d{1,2}[./]\d{2,4}\b"#,
            #"(?i)\b\d{1,2}\s+(?:января|февраля|марта|апреля|мая|июня|июля|августа|сентября|октября|ноября|декабря)\s+\d{4}\s*(?:года|г\.)?"#,
            #"(?i)[0-9][0-9 \x{00A0}.,]*(?:руб(?:лей|ля|ль|\.)?|₽|USD|EUR)"#,
            #"(?i)\b(?:(?:ноль|один|одна|одно|два|две|три|четыре|пять|шесть|семь|восемь|девять|десять|одиннадцать|двенадцать|тринадцать|четырнадцать|пятнадцать|шестнадцать|семнадцать|восемнадцать|девятнадцать|двадцать|тридцать|сорок|пятьдесят|шестьдесят|семьдесят|восемьдесят|девяносто|сто|двести|триста|четыреста|пятьсот|шестьсот|семьсот|восемьсот|девятьсот|тысяч(?:а|и)?|миллион(?:а|ов)?|миллиард(?:а|ов)?)[\s-]+)+(?:руб(?:ль|ля|лей)|₽)\b"#,
            #"(?i)\b\d+\s+(?:календарных\s+|рабочих\s+)?(?:дн(?:ей|я|ь)|месяц(?:а|ев)?|лет|года?|час(?:а|ов)?)\b"#,
            #"(?i)\b(?:в\s+)?(?:январе|феврале|марте|апреле|мае|июне|июле|августе|сентябре|октябре|ноябре|декабре|января|февраля|марта|апреля|мая|июня|июля|августа|сентября|октября|ноября|декабря)(?:\s+\d{4}\s*(?:года|г\.)?)?\b"#,
            #"(?i)\b\d{2}[A-ZА-Я]{2}\d{4}-\d{2}-\d{4}-\d{6}-\d{2}\b"#,
            #"\b\d{1,3}[-–]\d+[A-Za-zА-Яа-я0-9/.-]*\b"#,
            #"(?i)\b(?:стать(?:я|е|и|ю)|ст\.|част(?:ь|и|ью)|ч\.|пункт(?:а|е|ом|у)?|п\.|подпункт(?:а|е|ом|у)?|абзац(?:а|е|ем|у)?)\s*\d+(?:\.\d+)*\b"#,
        ]
        var values: [String] = []
        let ns = text as NSString
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                values.append(ns.substring(with: match.range))
            }
        }
        return Array(Set(values)).sorted()
    }

    private static func canonicalLiteralText(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private static func canonicalEvidenceText(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsLiteral(_ literal: String, in source: String) -> Bool {
        let value = canonicalLiteralText(literal)
        let haystack = canonicalLiteralText(source)
        guard !value.isEmpty else { return true }
        let escaped = NSRegularExpression.escapedPattern(for: value)
        let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(
            in: haystack,
            range: NSRange(haystack.startIndex..<haystack.endIndex, in: haystack)) != nil
    }
}
