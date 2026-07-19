import CryptoKit
import Foundation

/// Стабильный адрес абзаца судебного акта. Значение хранится отдельно от
/// переводимого текста и используется в Spotlight, AI-ответах и deep links.
public struct ActParagraph: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let ordinal: Int
    public let text: String

    public init(ordinal: Int, text: String) {
        self.id = "¶\(ordinal)"
        self.ordinal = ordinal
        self.text = text
    }
}

/// Провайдер-независимое представление опубликованного судебного акта.
public struct ActDocument: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let caseKey: String
    public let sourceActID: String
    public let caseNumber: String
    public let judicialUID: String?
    public let court: String
    public let instanceLevel: CaseInstance.Level
    public let kind: String
    public let date: String
    public let sourceText: String
    public let sourceHash: String
    public let paragraphizerVersion: Int
    public let paragraphs: [ActParagraph]

    public init(caseKey: String, sourceActID: String, caseNumber: String,
                judicialUID: String?, court: String,
                instanceLevel: CaseInstance.Level, kind: String, date: String,
                sourceText: String, documentID: String? = nil) {
        self.id = documentID ?? Self.stableID(caseKey: caseKey, sourceActID: sourceActID)
        self.caseKey = caseKey
        self.sourceActID = sourceActID
        self.caseNumber = caseNumber
        self.judicialUID = judicialUID
        self.court = court
        self.instanceLevel = instanceLevel
        self.kind = kind
        self.date = date
        self.sourceText = sourceText
        self.sourceHash = ActParagraphizer.sourceHash(for: sourceText)
        self.paragraphizerVersion = ActParagraphizer.currentVersion
        self.paragraphs = ActParagraphizer.paragraphs(in: sourceText)
    }

    /// Восстанавливает сохранённый snapshot границ. Это защищает старые ¶ID от
    /// перенумерации после улучшения алгоритма paragraphizer.
    public init(id: String, caseKey: String, sourceActID: String,
                caseNumber: String, judicialUID: String?, court: String,
                instanceLevel: CaseInstance.Level, kind: String, date: String,
                sourceText: String, sourceHash: String,
                paragraphizerVersion: Int, paragraphs: [ActParagraph]) {
        self.id = id
        self.caseKey = caseKey
        self.sourceActID = sourceActID
        self.caseNumber = caseNumber
        self.judicialUID = judicialUID
        self.court = court
        self.instanceLevel = instanceLevel
        self.kind = kind
        self.date = date
        self.sourceText = sourceText
        self.sourceHash = sourceHash
        self.paragraphizerVersion = paragraphizerVersion
        self.paragraphs = paragraphs
    }

    public static func stableID(caseKey: String, sourceActID: String) -> String {
        "\(caseKey)#\(sourceActID)"
    }
}

/// Детерминированная нормализация текста. Алгоритм намеренно не зависит от
/// locale и системных NLP-моделей: одинаковый текст получает те же ¶ID и hash
/// на любом поддерживаемом Mac.
public enum ActParagraphizer {
    public static let currentVersion = 1

    public static func paragraphs(in sourceText: String) -> [ActParagraph] {
        let normalized = normalizedText(sourceText)
        guard !normalized.isEmpty else { return [] }

        var chunks = normalized
            .components(separatedBy: "\n")
            .map(normalizeInlineWhitespace)
            .filter { !$0.isEmpty }

        // Некоторые суды публикуют весь акт одной строкой. Структурные глаголы
        // дают надёжные границы; оставшиеся большие блоки режутся только по
        // завершённым предложениям, без потери или перестановки текста.
        if chunks.count == 1, let only = chunks.first, only.count > 1_200 {
            chunks = structuralChunks(only).flatMap(sentenceChunks)
        } else {
            chunks = chunks.flatMap { $0.count > 2_400 ? sentenceChunks($0) : [$0] }
        }

        return chunks.enumerated().map { ActParagraph(ordinal: $0.offset + 1, text: $0.element) }
    }

    public static func sourceHash(for sourceText: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedText(sourceText).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func normalizedText(_ sourceText: String) -> String {
        sourceText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeInlineWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "[\\t ]+", with: " ", options: .regularExpression)
    }

    private static func structuralChunks(_ text: String) -> [String] {
        let pattern = "(?i)\\s+(?=(установил|решил|постановил|определил|приговорил)\\s*:?)"
        return text
            .replacingOccurrences(of: pattern, with: "\n", options: .regularExpression)
            .components(separatedBy: "\n")
            .map(normalizeInlineWhitespace)
            .filter { !$0.isEmpty }
    }

    private static func sentenceChunks(_ text: String) -> [String] {
        guard text.count > 1_200 else { return [text] }
        let sentencePattern = "(?<=[.!?])\\s+(?=[А-ЯЁA-Z0-9«])"
        // `components(separatedBy:)` не принимает regex. Ниже — стабильный
        // проход по найденным границам без Foundation NLP.
        let regex = try! NSRegularExpression(pattern: sentencePattern)
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return hardChunks(text) }

        var pieces: [String] = []
        var start = 0
        for match in matches {
            let end = match.range.location
            pieces.append(nsText.substring(with: NSRange(location: start, length: end - start)))
            start = match.range.location + match.range.length
        }
        pieces.append(nsText.substring(from: start))

        var result: [String] = []
        var current = ""
        for piece in pieces.map(normalizeInlineWhitespace).filter({ !$0.isEmpty }) {
            if current.isEmpty || current.count + piece.count + 1 <= 1_200 {
                current += current.isEmpty ? piece : " " + piece
            } else {
                result.append(current)
                current = piece
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.flatMap { $0.count > 2_400 ? hardChunks($0) : [$0] }
    }

    private static func hardChunks(_ text: String) -> [String] {
        var result: [String] = []
        var remaining = text[...]
        while remaining.count > 1_200 {
            let limit = remaining.index(remaining.startIndex, offsetBy: 1_200)
            let prefix = remaining[..<limit]
            let cut = prefix.lastIndex(of: " ") ?? limit
            result.append(String(remaining[..<cut]).trimmingCharacters(in: .whitespaces))
            remaining = remaining[cut...].drop(while: { $0 == " " })
        }
        let tail = String(remaining).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }
}
