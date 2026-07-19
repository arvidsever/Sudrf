//  ActTextView.swift — Sudrf · новый файл
//  Типографика судебного акта (как в HTML-прототипе): центрированный заголовок
//  «РЕШЕНИЕ / ПОСТАНОВЛЕНИЕ…», «Именем Российской Федерации», центрированные
//  курсивные глаголы «установил: / решил: / постановил:», абзацы с красной
//  строкой, ширина колонки ≤ 640 pt.
//
//  Границы берутся из единого сохранённого ActParagraph snapshot. Formatter
//  только классифицирует готовые абзацы для визуального рендера и не создаёт
//  параллельную сегментацию для PDF или AI-citations.

import SwiftUI
import SudrfKit

// MARK: - Структурный разбор акта

enum CourtActFormatter {

    struct IdentifiedBlock: Identifiable, Equatable {
        let id: String
        let block: Block
    }

    enum Block: Equatable {
        case meta(String)       // «УИД …», «Дело № …»
        case title(String)      // РЕШЕНИЕ / ПОСТАНОВЛЕНИЕ / ОПРЕДЕЛЕНИЕ / ПРИГОВОР
        case subtitle(String)   // «Именем Российской Федерации»
        case verb(String)       // «установил:», «решил:», «постановил:»…
        case paragraph(String)
    }

    static func parse(_ text: String, paragraphs: [ActParagraph]? = nil) -> [Block] {
        (paragraphs ?? ActParagraphizer.paragraphs(in: text)).flatMap { classify($0.text) }
    }

    static func parseIdentified(_ text: String,
                                paragraphs: [ActParagraph]? = nil) -> [IdentifiedBlock] {
        (paragraphs ?? ActParagraphizer.paragraphs(in: text)).flatMap { paragraph in
            classify(paragraph.text).enumerated().map { index, block in
                IdentifiedBlock(id: index == 0 ? paragraph.id : "\(paragraph.id).\(index)",
                                block: block)
            }
        }
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

}

// MARK: - View

struct ActTextView: View {
    let text: String
    var serif = false
    var highlightedParagraphID: String? = nil
    var paragraphs: [ActParagraph]? = nil

    var body: some View {
        let blocks = CourtActFormatter.parseIdentified(text, paragraphs: paragraphs)
        VStack(alignment: .leading, spacing: 11) {
            ForEach(blocks) { item in
                blockView(item.block)
                    .id(item.id)
                    .padding(.horizontal, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(item.id == highlightedParagraphID
                                  ? Color.yellow.opacity(0.28) : .clear))
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
