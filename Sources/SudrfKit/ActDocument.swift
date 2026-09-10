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
    public static let currentVersion = 2
    private static let structuralVerbs = [
        "установил", "решил", "постановил", "определил", "приговорил",
    ]
    private static let inlineWhitespacePattern = "[\\p{Zs}\\t]*"

    public static func paragraphs(in sourceText: String) -> [ActParagraph] {
        let normalized = normalizedText(sourceText)
        guard !normalized.isEmpty else { return [] }

        let sourceLines = normalized
            .components(separatedBy: "\n")
            .map(normalizeInlineWhitespace)
            .filter { !$0.isEmpty }

        // Некоторые суды публикуют весь акт одной строкой. Структурные глаголы
        // с двоеточием и реквизиты начала документа дают надёжные границы даже
        // у короткого акта; оставшиеся большие блоки режутся только по
        // завершённым предложениям, без потери или перестановки текста.
        let chunks: [String]
        if sourceLines.count == 1, let only = sourceLines.first {
            chunks = structuralChunks(only).flatMap(sentenceChunks)
        } else {
            chunks = sourceLines.flatMap { $0.count > 2_400 ? sentenceChunks($0) : [$0] }
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
        text.replacingOccurrences(of: "[\\p{Zs}\\t]+", with: " ", options: .regularExpression)
    }

    private static func structuralChunks(_ text: String) -> [String] {
        let nsText = text as NSString
        let spacedVerbs = structuralVerbs.map { verb in
            verb.map(String.init)
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: inlineWhitespacePattern)
        }.joined(separator: "|")
        let verbPattern = "(?i)(?<![\\p{L}\\p{N}])(?:\(spacedVerbs))\(inlineWhitespacePattern):"
        let verbMatches = matches(pattern: verbPattern, in: text)
        let firstVerb = verbMatches.first?.location ?? nsText.length

        // Заголовки и реквизиты являются структурными маркерами только в
        // преамбуле. Так слово «РЕШЕНИЕ» внутри мотивировки не становится
        // заголовком из-за одного лишь регистра.
        let preambleLength = min(firstVerb, min(nsText.length, 1_200))
        let preambleRange = NSRange(location: 0, length: preambleLength)
        let titlePatterns = [
            "(?<![\\p{L}])З\\s*А\\s*О\\s*Ч\\s*Н\\s*О\\s*Е\\s+Р\\s*Е\\s*Ш\\s*Е\\s*Н\\s*И\\s*Е(?![\\p{L}])",
            "(?<![\\p{L}])Р\\s*Е\\s*Ш\\s*Е\\s*Н\\s*И\\s*Е(?![\\p{L}])",
            "(?<![\\p{L}])П\\s*О\\s*С\\s*Т\\s*А\\s*Н\\s*О\\s*В\\s*Л\\s*Е\\s*Н\\s*И\\s*Е(?![\\p{L}])",
            "(?<![\\p{L}])О\\s*П\\s*Р\\s*Е\\s*Д\\s*Е\\s*Л\\s*Е\\s*Н\\s*И\\s*Е(?![\\p{L}])",
            "(?<![\\p{L}])П\\s*Р\\s*И\\s*Г\\s*О\\s*В\\s*О\\s*Р(?![\\p{L}])",
        ]
        let metadataPatterns = [
            "(?i)(?<![\\p{L}])Дело[\\p{Zs}\\t]*№[\\p{Zs}\\t]*[^\\s]+",
            "(?i)(?<![\\p{L}])УИД[\\p{Zs}\\t]*(?:[:№][\\p{Zs}\\t]*)?[0-9][A-ZА-ЯЁ0-9-]{7,}",
        ]
        let subtitlePattern = "(?i)(?<![\\p{L}])Именем[\\p{Zs}\\t]+Российской[\\p{Zs}\\t]+Федерации(?![\\p{L}])"
        let subtitleMatches = matches(pattern: subtitlePattern, in: text,
                                      range: preambleRange)

        var boundaries = verbMatches
        for pattern in metadataPatterns {
            boundaries.append(contentsOf: matches(pattern: pattern, in: text, range: preambleRange)
                .filter { markerHasOnlyKnownPreambleBeforeIt(
                    $0, in: text,
                    allowedPatterns: metadataPatterns + titlePatterns + [subtitlePattern]) })
        }
        var acceptedTitleRanges: [NSRange] = []
        for pattern in titlePatterns {
            acceptedTitleRanges.append(contentsOf:
                matches(pattern: pattern, in: text, range: preambleRange)
                    .filter {
                        markerHasOnlyKnownPreambleBeforeIt(
                            $0, in: text, allowedPatterns: metadataPatterns)
                        || isImmediatelyFollowed($0, byAny: subtitleMatches, in: text)
                    })
        }
        boundaries.append(contentsOf: acceptedTitleRanges)
        boundaries.append(contentsOf: subtitleMatches
            .filter { markerHasOnlyKnownPreambleBeforeIt(
                $0, in: text, allowedPatterns: metadataPatterns + titlePatterns)
                || isImmediatelyPreceded($0, byAny: acceptedTitleRanges, in: text) })
        boundaries.sort {
            $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location
        }

        var nonOverlapping: [NSRange] = []
        for range in boundaries where range.length > 0 {
            guard nonOverlapping.last.map({ NSMaxRange($0) <= range.location }) ?? true else { continue }
            nonOverlapping.append(range)
        }
        guard !nonOverlapping.isEmpty else { return [text] }

        var result: [String] = []
        var cursor = 0
        for range in nonOverlapping {
            appendChunk(nsText.substring(with: NSRange(location: cursor,
                                                        length: range.location - cursor)),
                        to: &result)
            appendChunk(nsText.substring(with: range), to: &result)
            cursor = NSMaxRange(range)
        }
        appendChunk(nsText.substring(from: cursor), to: &result)
        return result
    }

    private static func matches(pattern: String, in text: String,
                                range: NSRange? = nil) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, range: range ?? fullRange).map(\.range)
    }

    private static func markerHasOnlyKnownPreambleBeforeIt(
        _ markerRange: NSRange, in text: String, allowedPatterns: [String]
    ) -> Bool {
        guard markerRange.location > 0 else { return true }
        let nsText = text as NSString
        let prefix = nsText.substring(to: markerRange.location)
        var uncovered = prefix
        for pattern in allowedPatterns {
            uncovered = uncovered.replacingOccurrences(
                of: pattern, with: "", options: .regularExpression)
        }
        return uncovered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isImmediatelyFollowed(
        _ range: NSRange, byAny candidates: [NSRange], in text: String
    ) -> Bool {
        candidates.contains { candidate in
            guard candidate.location >= NSMaxRange(range) else { return false }
            return containsOnlyWhitespace(from: NSMaxRange(range), to: candidate.location,
                                          in: text)
        }
    }

    private static func isImmediatelyPreceded(
        _ range: NSRange, byAny candidates: [NSRange], in text: String
    ) -> Bool {
        candidates.contains { candidate in
            guard NSMaxRange(candidate) <= range.location else { return false }
            return containsOnlyWhitespace(from: NSMaxRange(candidate), to: range.location,
                                          in: text)
        }
    }

    private static func containsOnlyWhitespace(from start: Int, to end: Int,
                                               in text: String) -> Bool {
        let gap = (text as NSString).substring(
            with: NSRange(location: start, length: end - start))
        return gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func appendChunk(_ text: String, to chunks: inout [String]) {
        let normalized = normalizeInlineWhitespace(text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.isEmpty { chunks.append(normalized) }
    }

    private static func sentenceChunks(_ text: String) -> [String] {
        guard text.count > 1_200 else { return [text] }
        let sentencePattern = "(?<=[.!?])\\s+(?=[А-ЯЁA-Z0-9«])"
        // `components(separatedBy:)` не принимает regex. Ниже — стабильный
        // проход по найденным границам без Foundation NLP.
        guard let regex = try? NSRegularExpression(pattern: sentencePattern) else {
            return hardChunks(text)
        }
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
