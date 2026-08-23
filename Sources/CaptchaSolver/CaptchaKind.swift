import Foundation

/// Разновидность капчи, распознаваемой солвером. Соответствует
/// `SearchModel.CaptchaContext.Kind` в SudrfApp — разные домены символов, но
/// один и тот же `(captcha, captchaid)` контракт ответа.
public enum CaptchaKind: Sendable, Hashable {
    /// Только цифры, 4–6 символов, на сайтах `*.sudrf.ru` (ГАС «Правосудие»).
    case sudrfToken
    /// Смешанные буквы и цифры, 4–6 символов, на сайтах `*.msudrf.ru`
    /// (портал мировых судей).
    case kcaptcha
    /// Ровно пять цифр в публичном поиске Банка данных ФССП.
    /// Обслуживается только отдельной прошедшей eligibility-gate CoreML-моделью.
    case fsspDigits

    /// Короткая метка для логов и UI. Стабильна между запусками.
    public var label: String {
        switch self {
        case .sudrfToken: return "sudrfToken"
        case .kcaptcha:   return "kcaptcha"
        case .fsspDigits: return "fsspDigits"
        }
    }
}
