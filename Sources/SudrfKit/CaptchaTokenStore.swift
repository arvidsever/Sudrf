import Foundation

/// Решённая пользователем капча sud_delo. Форма поиска отправляется GET-ом,
/// поэтому пара уходит параметрами `&captcha=<код>&captchaid=<id>` — и суд
/// принимает её повторно в последующих запросах, пока не отклонит.
public struct CaptchaToken: Sendable, Equatable {
    public let value: String    // captcha=
    public let id: String       // captchaid=
    public let obtainedAt: Date

    public init(value: String, id: String, obtainedAt: Date = Date()) {
        self.value = value
        self.id = id
        self.obtainedAt = obtainedAt
    }
}

/// Хранилище решённых капч по судам. Пользователь решает код один раз (в окне
/// капчи), пара сохраняется сюда, и дальше клиент подставляет её в поисковые
/// URL этого суда — без повторных окон. Отклонённая судом пара инвалидируется,
/// и поток возвращается к обычному сценарию с окном.
///
/// Только в памяти: валидность пары привязана к серверной сессии, переживать
/// перезапуск приложения ей незачем. Синглтон — клиентов SudrfClient два
/// (поиск и фоновое обновление), решённая капча общая.
public actor CaptchaTokenStore {

    public static let shared = CaptchaTokenStore()

    private let ttl: TimeInterval
    private var tokens: [String: CaptchaToken] = [:]   // ключ — модульный хост

    public init(ttl: TimeInterval = 30 * 60) {
        self.ttl = ttl
    }

    /// Ключ — дефисная (модульная) форма хоста: обе формы одного суда и оба
    /// клиента попадают в одну запись.
    private func key(_ domain: String) -> String {
        SudrfHost.moduleHost(domain.lowercased())
    }

    public func token(forDomain domain: String) -> CaptchaToken? {
        let k = key(domain)
        guard let t = tokens[k] else { return nil }
        guard Date().timeIntervalSince(t.obtainedAt) < ttl else {
            tokens.removeValue(forKey: k)
            return nil
        }
        return t
    }

    public func store(_ token: CaptchaToken, domain: String) {
        tokens[key(domain)] = token
    }

    public func invalidate(domain: String) {
        tokens.removeValue(forKey: key(domain))
    }
}
