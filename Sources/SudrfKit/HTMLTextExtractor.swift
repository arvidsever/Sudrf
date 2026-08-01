import Foundation
import SwiftSoup

/// Общее извлечение читаемого текста из HTML-фрагментов судебных карточек.
/// Стили сохраняют различия платформ: основной sudrf считает ячейки таблиц
/// блочными элементами, magistrate — нет.
enum HTMLTextExtractor {
    enum Style {
        case sudrf
        case magistrate

        fileprivate var blockTags: Set<String> {
            var tags: Set<String> = [
                "p", "div", "tr", "li", "table", "section", "article",
                "blockquote", "h1", "h2", "h3", "h4", "h5", "h6",
            ]
            if self == .sudrf {
                tags.formUnion(["td", "th"])
            }
            return tags
        }
    }

    static func normalizedBlockText(_ element: Element, style: Style) -> String {
        var output = ""
        appendText(of: element, blockTags: style.blockTags, to: &output)
        return normalizeParagraphs(output)
    }

    private static func appendText(of node: Node, blockTags: Set<String>,
                                   to output: inout String) {
        for child in node.getChildNodes() {
            if let text = child as? TextNode {
                output += text.getWholeText()
            } else if let element = child as? Element {
                let tag = element.tagName().lowercased()
                if tag == "br" {
                    output += "\n"
                    continue
                }
                if tag == "script" || tag == "style" { continue }
                let isBlock = blockTags.contains(tag)
                if isBlock && !output.hasSuffix("\n") { output += "\n" }
                appendText(of: element, blockTags: blockTags, to: &output)
                if isBlock && !output.hasSuffix("\n") { output += "\n" }
            }
        }
    }

    private static func normalizeParagraphs(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        var output: [String] = []
        for line in lines {
            if line.isEmpty {
                if let last = output.last, !last.isEmpty { output.append("") }
            } else {
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
