import Foundation

/// Normalizes the small set of standalone headings used by the act viewer and Spotlight.
public enum CourtActHeadingNormalizer {
    public enum Heading: Sendable, Equatable {
        case title(String)
        case subtitle(String)

        public var text: String {
            switch self {
            case .title(let text), .subtitle(let text): text
            }
        }
    }

    private static let titles = [
        (letters: "РЕШЕНИЕ", text: "РЕШЕНИЕ"),
        (letters: "ЗАОЧНОЕРЕШЕНИЕ", text: "ЗАОЧНОЕ РЕШЕНИЕ"),
        (letters: "ОПРЕДЕЛЕНИЕ", text: "ОПРЕДЕЛЕНИЕ"),
        (letters: "ПОСТАНОВЛЕНИЕ", text: "ПОСТАНОВЛЕНИЕ"),
        (letters: "ПРИГОВОР", text: "ПРИГОВОР"),
    ]
    private static let subtitleLetters = "ИМЕНЕМРОССИЙСКОЙФЕДЕРАЦИИ"
    private static let subtitle = "Именем Российской Федерации"

    /// Returns canonical components only when the whole line is a known heading.
    /// Titles retain the existing all-uppercase guard; whitespace may separate letters.
    public static func normalize(_ line: String) -> [Heading]? {
        let scalars = Array(line.unicodeScalars)
        let letters = scalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty,
              scalars.allSatisfy({ CharacterSet.letters.contains($0)
                  || CharacterSet.whitespacesAndNewlines.contains($0) }) else { return nil }

        let sourceLetters = String(String.UnicodeScalarView(letters))
        let compact = sourceLetters.uppercased()
        if let title = titles.first(where: { $0.letters == compact }) {
            guard sourceLetters == compact else { return nil }
            return [.title(title.text)]
        }
        if compact == subtitleLetters { return [.subtitle(subtitle)] }

        for title in titles where compact.hasPrefix(title.letters)
            && compact.dropFirst(title.letters.count) == subtitleLetters {
            let titleLetters = String(String.UnicodeScalarView(
                letters.prefix(title.letters.unicodeScalars.count)))
            guard titleLetters == titleLetters.uppercased() else { return nil }
            return [.title(title.text), .subtitle(subtitle)]
        }
        return nil
    }
}
