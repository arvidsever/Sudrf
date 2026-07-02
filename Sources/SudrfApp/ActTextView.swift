//  ActTextView.swift — Sudrf · новый файл
//  Типографика судебного акта (как в HTML-прототипе): центрированный заголовок
//  «РЕШЕНИЕ / ПОСТАНОВЛЕНИЕ…», «Именем Российской Федерации», центрированные
//  курсивные глаголы «установил: / решил: / постановил:», абзацы с красной
//  строкой, ширина колонки ≤ 640 pt.
//
//  Работает и со «простынёй» (одна строка без \n): есть эвристический
//  fallback-разбор. Но основной фикс — CaseCardParser, сохраняющий абзацы.

import SwiftUI

// MARK: - Структурный разбор акта

enum CourtActFormatter {

    enum Block: Equatable {
        case meta(String)       // «УИД …», «Дело № …»
        case title(String)      // РЕШЕНИЕ / ПОСТАНОВЛЕНИЕ / ОПРЕДЕЛЕНИЕ / ПРИГОВОР
        case subtitle(String)   // «Именем Российской Федерации»
        case verb(String)       // «установил:», «решил:», «постановил:»…
        case paragraph(String)
    }

    static func parse(_ text: String) -> [Block] {
        var source = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // «Простыня» без переводов строк → синтезируем границы.
        if !source.contains("\n") {
            source = synthesizeBreaks(in: source)
        }
        var blocks: [Block] = []
        for rawLine in source.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            blocks.append(contentsOf: classify(line))
        }
        return blocks
    }

    // MARK: классификация строки

    private static let titleWords: Set<String> = [
        "РЕШЕНИЕ", "ЗАОЧНОЕРЕШЕНИЕ", "ПОСТАНОВЛЕНИЕ", "ОПРЕДЕЛЕНИЕ", "ПРИГОВОР",
    ]

    private static func classify(_ line: String) -> [Block] {
        let compact = line.replacingOccurrences(of: " ", with: "")
        if line.hasPrefix("УИД") || line.hasPrefix("Дело №") {
            return [.meta(line)]
        }
        if titleWords.contains(compact.uppercased()), compact == compact.uppercased() {
            return [.title(spacedCaps(compact))]
        }
        if compact.lowercased() == "именемроссийскойфедерации" {
            return [.subtitle("Именем Российской Федерации")]
        }
        if let verb = verbMatch(line) {
            return [.verb(verb)]
        }
        // Длинный абзац без структуры → режем по предложениям.
        if line.count > 600 {
            return splitSentences(line).map { .paragraph($0) }
        }
        return [.paragraph(line)]
    }

    private static func verbMatch(_ line: String) -> String? {
        let pattern = "^(установил|решил|постановил|определил|приговорил)\\s*:?$"
        let lower = line.lowercased()
        guard lower.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return lower.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ":", with: "") + ":"
    }

    /// «ПОСТАНОВЛЕНИЕ» → «П О С Т А Н О В Л Е Н И Е» — традиционная разрядка.
    private static func spacedCaps(_ word: String) -> String {
        word.map(String.init).joined(separator: " ")
    }

    // MARK: fallback для текста одной строкой

    private static func synthesizeBreaks(in text: String) -> String {
        var s = text
        // Заголовок с разрядкой: «Р Е Ш Е Н И Е» и т. п.
        s = s.replacingOccurrences(
            of: "(([А-ЯЁ]\\s){3,}[А-ЯЁ])",
            with: "\n$1\n", options: .regularExpression)
        s = s.replacingOccurrences(
            of: "(Именем Российской Федерации)",
            with: "\n$1\n", options: .regularExpression)
        // Глаголы-секции, в т. ч. «УСТАНОВИЛ :» с пробелом перед двоеточием.
        s = s.replacingOccurrences(
            of: "\\s*,?\\s*(УСТАНОВИЛ|РЕШИЛ|ПОСТАНОВИЛ|ОПРЕДЕЛИЛ|ПРИГОВОРИЛ)\\s*:",
            with: "\n$1:\n", options: [.regularExpression])
        // «Дело № …» отдельной строкой после УИД.
        s = s.replacingOccurrences(
            of: "(УИД [0-9A-ZА-Я-]+)\\s+(Дело №)",
            with: "$1\n$2", options: .regularExpression)
        return s
    }

    /// Деление на предложения с защитой сокращений («ст.», «ч.», «г.», инициалы).
    private static func splitSentences(_ text: String) -> [String] {
        let abbrev: Set<String> = [
            "г", "гг", "ст", "ч", "п", "пп", "руб", "коп", "т", "д", "др",
            "им", "ул", "корп", "кв", "обл", "респ", "тыс", "млн", "проц",
        ]
        var sentences: [String] = []
        var current = ""
        let words = text.components(separatedBy: " ")
        for word in words {
            current += current.isEmpty ? word : " " + word
            guard word.hasSuffix(".") else { continue }
            let stem = String(word.dropLast())
                .components(separatedBy: CharacterSet(charactersIn: ".(«„")).last ?? ""
            // не рвём после сокращений и одиночных инициалов «В.»
            if abbrev.contains(stem.lowercased()) { continue }
            if stem.count == 1, stem == stem.uppercased(), stem.rangeOfCharacter(from: .decimalDigits) == nil { continue }
            sentences.append(current)
            current = ""
        }
        if !current.isEmpty { sentences.append(current) }
        // Склеиваем совсем короткие хвосты с предыдущим предложением.
        var merged: [String] = []
        for s in sentences {
            if s.count < 40, var last = merged.popLast() {
                last += " " + s
                merged.append(last)
            } else {
                merged.append(s)
            }
        }
        return merged
    }
}

// MARK: - View

struct ActTextView: View {
    let text: String
    var serif = false

    var body: some View {
        let blocks = CourtActFormatter.parse(text)
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: CourtActFormatter.Block) -> some View {
        switch block {
        case .meta(let s):
            Text(s)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .title(let s):
            Text(s)
                .font(bodyFont(size: 14).weight(.bold))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 6)
        case .subtitle(let s):
            Text(s)
                .font(bodyFont(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .verb(let s):
            Text(s)
                .font(bodyFont(size: 13).weight(.semibold).italic())
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 2)
        case .paragraph(let s):
            // \u{2003} — em-пробел вместо красной строки (text-indent в SwiftUI нет)
            Text("\u{2003}" + s)
                .font(bodyFont(size: 13))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bodyFont(size: CGFloat) -> Font {
        serif ? .system(size: size, design: .serif) : .system(size: size)
    }
}
