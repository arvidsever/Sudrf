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

    /// Показывает номер принятого производства КСОЮ, если портал поместил его
    /// в квадратные скобки рядом с номером жалобы. Сырой номер не меняется:
    /// это только выбор подписи для уже принятого производства.
    public static func displayedNumber(for instance: CaseInstance) -> String {
        let incoming = primary(instance.caseNumber)
        guard instance.level == .cassation,
              isKSOYU(instance.domain),
              let accepted = bracketedNumber(in: instance.caseNumber),
              let acceptedPrefixes = acceptedPrefixes(forIncoming: incoming),
              acceptedPrefixes.contains(numberPrefix(accepted)) else {
            return incoming
        }
        return accepted
    }

    /// Второй номер в интерфейсе — только если это реальный номер другого
    /// производства, а не повтор исходного номера дела.
    public static func secondary(_ raw: String?, distinctFrom base: String) -> String? {
        guard let raw else { return nil }
        let number = primary(raw)
        guard !number.isEmpty,
              !["—", "–", "-"].contains(number),
              number != primary(base) else { return nil }
        return number
    }

    private static func isKSOYU(_ domain: String) -> Bool {
        var host = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["https://", "http://"] where host.hasPrefix(scheme) {
            host.removeFirst(scheme.count)
        }
        host = host.split(separator: "/", maxSplits: 1).first.map(String.init) ?? host
        return CourtDirectory.cassationCourts.contains { $0.domain == host }
    }

    private static func bracketedNumber(in raw: String) -> String? {
        guard let open = raw.firstIndex(of: "["),
              let close = raw[raw.index(after: open)...].firstIndex(of: "]") else {
            return nil
        }
        let body = raw[raw.index(after: open)..<close]
        let number = primary(String(body))
        return number.isEmpty ? nil : number
    }

    private static func numberPrefix(_ number: String) -> String {
        String(primary(number).split(separator: "-", maxSplits: 1).first ?? "")
            .lowercased()
    }

    private static func acceptedPrefixes(forIncoming incoming: String) -> Set<String>? {
        switch numberPrefix(incoming) {
        case "8":   return ["88"]
        case "8г":  return ["88"]
        case "8а":  return ["88а"]
        case "7":   return ["77"]
        case "7у": return ["77", "77у"]
        default:    return nil
        }
    }
}
