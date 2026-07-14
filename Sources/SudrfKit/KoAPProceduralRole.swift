import Foundation

/// Процессуальная роль карточки КоАП. Одинаковая картотека `admj` районного
/// суда означает разные звенья: апелляцию на мирового судью при MS-УИД и
/// первый судебный пересмотр несудебного постановления при RS-УИД.
public enum KoAPProceduralRole: String, Sendable, Codable, Equatable {
    case firstInstance
    case magistrateAppeal
    case authorityJudicialReview
    case subjectReview
    case finalActReview
    case unknown

    public var instanceLevel: CaseInstance.Level? {
        switch self {
        case .firstInstance, .authorityJudicialReview: return .first
        case .magistrateAppeal, .subjectReview: return .appeal
        case .finalActReview: return .cassation
        case .unknown: return nil
        }
    }

    public static func resolve(courtLevel: CourtLevel, cartotekaID: String,
                               judicialUID: String?, lowerCourtTitle: String? = nil)
        -> KoAPProceduralRole {
        let id = cartotekaID.lowercased()
        guard id.hasPrefix("adm") else { return .unknown }

        switch (courtLevel, id) {
        case (.magistrate, "adm"), (.district, "adm"):
            return .firstInstance
        case (.district, "admj"):
            switch uidCourtKind(judicialUID) {
            case .magistrate:
                return .magistrateAppeal
            case .district:
                return .authorityJudicialReview
            default:
                let title = lowerCourtTitle?.lowercased() ?? ""
                if title.contains("миров") || title.contains("судебн") && title.contains("участ") {
                    return .magistrateAppeal
                }
                return .unknown
            }
        case (.subject, "adm1"), (.subject, "adm2"):
            return .subjectReview
        case (.subject, "adm33"), (.cassation, "adm3"):
            return .finalActReview
        default:
            return .unknown
        }
    }

    public static func classificationCode(from uid: String?) -> String? {
        guard let uid else { return nil }
        let upper = uid.uppercased()
        guard let range = upper.range(of: #"^\d{2}[A-ZА-Я]{2}\d{4}"#,
                                      options: .regularExpression) else { return nil }
        return String(upper[range])
    }

    public static func uidCourtKind(_ uid: String?) -> CourtKind? {
        classificationCode(from: uid).map(CourtKind.init(classificationCode:))
    }
}
