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
    public var warnings: [String]
    public var intermediateEnglishSummary: String?
    public var usedDoubleTranslation: Bool

    public init(claims: [SummaryClaim] = [], partyPositions: [SummaryClaim] = [],
                circumstances: [SummaryClaim] = [], reasoning: [SummaryClaim] = [],
                disposition: [SummaryClaim] = [], amounts: [SummaryClaim] = [],
                dates: [SummaryClaim] = [], deadlines: [SummaryClaim] = [],
                appeal: [SummaryClaim] = [], warnings: [String] = [],
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
        self.intermediateEnglishSummary = intermediateEnglishSummary
        self.usedDoubleTranslation = usedDoubleTranslation
    }

    public var allClaims: [SummaryClaim] {
        claims + partyPositions + circumstances + reasoning + disposition
            + amounts + dates + deadlines + appeal
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
            warnings: Array(Set(values.flatMap(\.warnings))).sorted(),
            intermediateEnglishSummary: diagnostics.isEmpty
                ? nil : diagnostics.joined(separator: "\n\n--- chunk ---\n\n"),
            usedDoubleTranslation: values.contains(where: \.usedDoubleTranslation))
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
                let quote = citation.evidenceQuote.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !quote.isEmpty, original.localizedCaseInsensitiveContains(quote) else {
                    throw ActSummaryValidationError.evidenceNotVerbatim(citation.paragraphID)
                }
            }
        }

        // Числа, даты, номера дел и ссылки на нормы нельзя принимать, если их
        // нет в русском оригинале. Проверяется именно текст claims, не warnings.
        let source = canonicalLiteralText(ActParagraphizer.normalizedText(document.sourceText))
        for literal in protectedLiterals(in: summary.allClaims.map(\.text).joined(separator: "\n")) {
            guard source.contains(canonicalLiteralText(literal)) else {
                throw ActSummaryValidationError.unsupportedLiteral(literal)
            }
        }
    }

    public static func protectedLiterals(in text: String) -> [String] {
        let patterns = [
            #"\b\d{1,2}[./]\d{1,2}[./]\d{2,4}\b"#,
            #"(?i)\b\d{1,2}\s+(?:января|февраля|марта|апреля|мая|июня|июля|августа|сентября|октября|ноября|декабря)\s+\d{4}\s*(?:года|г\.)?"#,
            #"(?i)[0-9][0-9 \x{00A0}.,]*(?:руб(?:лей|ля|ль)?\.?|₽|USD|EUR)"#,
            #"(?i)\b\d+\s+(?:календарных\s+|рабочих\s+)?(?:дн(?:ей|я|ь)|месяц(?:а|ев)?|лет|года?|час(?:а|ов)?)\b"#,
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
}
