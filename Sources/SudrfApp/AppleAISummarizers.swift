import Foundation
import FoundationModels
import SudrfKit
@preconcurrency import Translation

enum AppleModelSupport {
    @MainActor
    static func isAvailable(localeIdentifier: String) -> Bool {
#if arch(x86_64)
        false
#else
        let model = SystemLanguageModel.default
        return model.availability == .available
            && model.supportsLocale(Locale(identifier: localeIdentifier))
#endif
    }
}

@Generable(description: "A verbatim citation from one numbered paragraph")
private struct AppleCitationOutput {
    @Guide(description: "Paragraph ID exactly as supplied, for example ¶12")
    var paragraphID: String
    @Guide(description: "Short verbatim quote from that paragraph")
    var evidenceQuote: String
}

@Generable(description: "One factual or legal conclusion with evidence")
private struct AppleClaimOutput {
    var text: String
    var citations: [AppleCitationOutput]
}

@Generable(description: "Structured summary of a court decision")
private struct AppleSummaryOutput {
    var claims: [AppleClaimOutput]
    var partyPositions: [AppleClaimOutput]
    var circumstances: [AppleClaimOutput]
    var reasoning: [AppleClaimOutput]
    var disposition: [AppleClaimOutput]
    var amounts: [AppleClaimOutput]
    var dates: [AppleClaimOutput]
    var deadlines: [AppleClaimOutput]
    var appeal: [AppleClaimOutput]
    var warnings: [AppleClaimOutput]
}

actor AppleDirectActSummarizer: ActSummarizing {
    private let requiredLocaleIdentifier: String

    init(requiredLocaleIdentifier: String = "ru_RU") {
        self.requiredLocaleIdentifier = requiredLocaleIdentifier
    }

    func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
        let model = SystemLanguageModel.default
        guard model.availability == .available else {
            throw AISummarizerError.providerUnavailable(
                "Apple Intelligence недоступен, выключен или модель ещё не загружена.")
        }
        let requiredLocale = Locale(identifier: requiredLocaleIdentifier)
        guard model.supportsLocale(requiredLocale) else {
            throw AISummarizerError.providerUnavailable(
                "Системная модель официально не поддерживает locale \(requiredLocaleIdentifier).")
        }
        let session = LanguageModelSession(
            model: model,
            instructions: "Не додумывай факты. Каждый вывод подтверждай дословной цитатой и ¶ID.")
        let paragraphs = document.paragraphs.map { "[\($0.id)] \($0.text)" }
            .joined(separator: "\n\n")
        let response = try await session.respond(
            to: "Составь структурированную сводку судебного акта:\n\n\(paragraphs)",
            generating: AppleSummaryOutput.self)
        return Self.convert(response.content)
    }

    private static func convert(_ value: AppleSummaryOutput) -> ActSummary {
        func claims(_ source: [AppleClaimOutput]) -> [SummaryClaim] {
            source.map { value in
                SummaryClaim(text: value.text, citations: value.citations.map {
                    SummaryCitation(paragraphID: $0.paragraphID,
                                    evidenceQuote: $0.evidenceQuote)
                })
            }
        }
        return ActSummary(
            claims: claims(value.claims), partyPositions: claims(value.partyPositions),
            circumstances: claims(value.circumstances), reasoning: claims(value.reasoning),
            disposition: claims(value.disposition), amounts: claims(value.amounts),
            dates: claims(value.dates), deadlines: claims(value.deadlines),
            appeal: claims(value.appeal), warnings: claims(value.warnings))
    }
}

/// TranslationSession не объявлен Sendable, поэтому обе сессии создаются и
/// используются только внутри actor; наружу выходят лишь строки.
actor InstalledTranslationPair {
    static let shared = InstalledTranslationPair()
    private let russian = Locale.Language(identifier: "ru")
    private let english = Locale.Language(identifier: "en")
    private var russianToEnglishSession: TranslationSession?
    private var englishToRussianSession: TranslationSession?

    /// Headless initializer умеет работать только с уже установленными
    /// языками. Разрешение на загрузку всегда запрашивает SwiftUI
    /// `.translationTask`; здесь мы лишь проверяем фактическую готовность.
    func refreshInstalledSessions() async throws {
        let forward = TranslationSession(installedSource: russian, target: english)
        let reverse = TranslationSession(installedSource: english, target: russian)
        guard await forward.isReady, await reverse.isReady else {
            russianToEnglishSession = nil
            englishToRussianSession = nil
            throw AISummarizerError.translationLanguagesNotInstalled
        }
        russianToEnglishSession = forward
        englishToRussianSession = reverse
    }

    func toEnglish(_ text: String) async throws -> String {
        try await ensureReady()
        guard let russianToEnglishSession else {
            throw AISummarizerError.providerUnavailable(
                "Языковая пара русский → английский недоступна.")
        }
        return try await russianToEnglishSession.translate(text).targetText
    }

    func toRussian(_ text: String) async throws -> String {
        try await ensureReady()
        guard let englishToRussianSession else {
            throw AISummarizerError.providerUnavailable(
                "Языковая пара английский → русский недоступна.")
        }
        return try await englishToRussianSession.translate(text).targetText
    }

    private func ensureReady() async throws {
        if let russianToEnglishSession, let englishToRussianSession,
           await russianToEnglishSession.isReady,
           await englishToRussianSession.isReady {
            return
        }
        try await refreshInstalledSessions()
    }
}

struct ProtectedLegalLiteral: Sendable, Codable, Hashable {
    let id: String
    let original: String
}

struct ProtectedTranslationDocument: Sendable, Hashable {
    let paragraphs: [ActParagraph]
    let literals: [ProtectedLegalLiteral]

    func restoring(_ text: String) -> String {
        literals.reduce(text) { value, literal in
            value.replacingOccurrences(of: "⟦\(literal.id)⟧", with: literal.original)
        }
    }
}

enum LegalLiteralProtector {
    static func protect(_ document: ActDocument) -> ProtectedTranslationDocument {
        let patterns: [(String, String)] = [
            ("D", #"\b\d{1,2}[./]\d{1,2}[./]\d{2,4}\b"#),
            ("D", #"(?i)\b\d{1,2}\s+(?:января|февраля|марта|апреля|мая|июня|июля|августа|сентября|октября|ноября|декабря)\s+\d{4}\s*(?:года|г\.)?"#),
            ("A", #"(?i)[0-9][0-9 \x{00A0}.,]*(?:руб(?:лей|ля|ль|\.)?|₽|USD|EUR)"#),
            ("A", #"(?i)\b(?:(?:ноль|один|одна|одно|два|две|три|четыре|пять|шесть|семь|восемь|девять|десять|сто|двести|триста|четыреста|пятьсот|тысяч(?:а|и)?|миллион(?:а|ов)?)[\s-]+)+(?:руб(?:ль|ля|лей)|₽)\b"#),
            ("D", #"(?i)\b(?:\d{1,4}\s+(?:календарных\s+|рабочих\s+)?дн(?:ей|я|ь)|\d{1,3}\s+(?:календарных\s+|рабочих\s+)?(?:месяц(?:а|ев)?|лет|года?|час(?:а|ов)?))\b"#),
            ("N", #"(?i)\b\d{2}[A-ZА-Я]{2}\d{4}-\d{2}-\d{4}-\d{6}-\d{2}\b"#),
            ("L", #"(?i)(?:стать(?:я|е|и|ю)|ст\.|част(?:ь|и|ью)|ч\.|пункт(?:а|е|ом|у)?|п\.|подпункт(?:а|е|ом|у)?|абзац(?:а|е|ем|у)?)\s*\d+(?:\.\d+)*"#),
            ("N", #"\b\d{1,3}[-–]\d+[A-Za-zА-Яа-я0-9/.-]*\b"#),
        ]
        var literals: [ProtectedLegalLiteral] = []
        var counters: [String: Int] = [:]
        let values = document.paragraphs.map { paragraph -> ActParagraph in
            var text = paragraph.text
            for (prefix, pattern) in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                while true {
                    let ns = text as NSString
                    guard let match = regex.firstMatch(
                        in: text, range: NSRange(location: 0, length: ns.length)) else { break }
                    let original = ns.substring(with: match.range)
                    let next = (counters[prefix] ?? 0) + 1
                    counters[prefix] = next
                    let id = String(format: "%@%03d", prefix, next)
                    literals.append(ProtectedLegalLiteral(id: id, original: original))
                    text = ns.replacingCharacters(in: match.range, with: "⟦\(id)⟧")
                }
            }
            return ActParagraph(ordinal: paragraph.ordinal, text: text)
        }
        return ProtectedTranslationDocument(paragraphs: values, literals: literals)
    }

    static func placeholderCounts(in text: String) -> [String: Int] {
        guard let regex = try? NSRegularExpression(pattern: #"⟦[A-Z]\d{3}⟧"#) else { return [:] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .reduce(into: [:]) { counts, match in
                counts[ns.substring(with: match.range), default: 0] += 1
            }
    }
}

/// Тестируемое ядро translation spike. Реальные TranslationSession передаются
/// с UI-границы Translation framework; IDs живут вне переводимого текста.
struct AppleTranslatedActSummarizer<English: ActSummarizing>: ActSummarizing {
    typealias Translator = @Sendable (String) async throws -> String

    let englishSummarizer: English
    let russianToEnglish: Translator
    let englishToRussian: Translator

    func summarize(document: ActDocument, options: SummaryOptions) async throws -> ActSummary {
        let protected = LegalLiteralProtector.protect(document)
        var englishParagraphs: [ActParagraph] = []
        for paragraph in protected.paragraphs {
            try Task.checkCancellation()
            let translated = try await russianToEnglish(paragraph.text)
            guard LegalLiteralProtector.placeholderCounts(in: translated)
                    == LegalLiteralProtector.placeholderCounts(in: paragraph.text) else {
                throw AISummarizerError.providerUnavailable(
                    "Перевод изменил защищённые юридические реквизиты; экспериментальный результат отклонён.")
            }
            englishParagraphs.append(ActParagraph(
                ordinal: paragraph.ordinal,
                text: translated))
        }
        let englishDocument = ActDocument(
            id: document.id, caseKey: document.caseKey, sourceActID: document.sourceActID,
            caseNumber: document.caseNumber, judicialUID: document.judicialUID,
            court: document.court, instanceLevel: document.instanceLevel,
            kind: document.kind, date: document.date,
            sourceText: englishParagraphs.map(\.text).joined(separator: "\n\n"),
            sourceHash: document.sourceHash,
            paragraphizerVersion: document.paragraphizerVersion,
            paragraphs: englishParagraphs)
        let english = try await englishSummarizer.summarize(
            document: englishDocument, options: options)
        // Сначала проверяем вывод модели против фактически переданного
        // английского документа. Русская remap-проверка не может заменить
        // эту границу, потому что evidence на spike затем становится целым
        // исходным абзацем.
        try ActSummaryValidator.validate(english, against: englishDocument)
        let originals = Dictionary(uniqueKeysWithValues: document.paragraphs.map { ($0.id, $0.text) })

        func translateClaims(_ claims: [SummaryClaim]) async throws -> [SummaryClaim] {
            var result: [SummaryClaim] = []
            for claim in claims {
                let translatedClaim = try await englishToRussian(claim.text)
                guard LegalLiteralProtector.placeholderCounts(in: translatedClaim)
                        == LegalLiteralProtector.placeholderCounts(in: claim.text) else {
                    throw AISummarizerError.providerUnavailable(
                        "Обратный перевод изменил защищённые юридические реквизиты; результат не показан.")
                }
                let translated = protected.restoring(translatedClaim)
                let citations = claim.citations.compactMap { citation -> SummaryCitation? in
                    guard let original = originals[citation.paragraphID] else { return nil }
                    // Цитата никогда не проходит round trip: русский оригинал
                    // целиком является проверяемым evidence для spike.
                    return SummaryCitation(paragraphID: citation.paragraphID,
                                           evidenceQuote: original)
                }
                result.append(SummaryClaim(text: translated, citations: citations))
            }
            return result
        }

        let diagnostic = try? JSONEncoder().encode(english)
        let claims = try await translateClaims(english.claims)
        let partyPositions = try await translateClaims(english.partyPositions)
        let circumstances = try await translateClaims(english.circumstances)
        let reasoning = try await translateClaims(english.reasoning)
        let disposition = try await translateClaims(english.disposition)
        let amounts = try await translateClaims(english.amounts)
        let dates = try await translateClaims(english.dates)
        let deadlines = try await translateClaims(english.deadlines)
        let appeal = try await translateClaims(english.appeal)
        let warnings = try await translateClaims(english.warnings)
        let result = ActSummary(
            claims: claims, partyPositions: partyPositions,
            circumstances: circumstances, reasoning: reasoning,
            disposition: disposition, amounts: amounts, dates: dates,
            deadlines: deadlines, appeal: appeal, warnings: warnings,
            localWarnings: ["Экспериментальная сводка через двойной перевод."],
            intermediateEnglishSummary: diagnostic.flatMap { String(data: $0, encoding: .utf8) },
            usedDoubleTranslation: true)
        try ActSummaryValidator.validate(result, against: document)
        return result
    }
}
