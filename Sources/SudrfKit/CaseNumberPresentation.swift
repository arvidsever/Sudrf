import Foundation

/// Presentation-only formatting for case numbers. Raw numbers remain the
/// source of truth for persistence, searching and navigation.
public enum CaseNumberPresentation {
    /// Removes a leading `№` and returns the first number from a composite
    /// portal label (previous numbers, material numbers, etc. are omitted).
    public static func primary(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "№" {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty else { return "" }
        if let end = value.firstIndex(where: {
            $0.isWhitespace || $0 == "(" || $0 == "~" || $0 == "∼" || $0 == "["
        }) {
            return String(value[..<end])
        }
        return value
    }
}
