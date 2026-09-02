import Foundation

/// A validated direct link to a federal SUDRF case card.
///
/// SUDRF publishes two spellings of the card parameters.  Modern cards use
/// `case_id`, `case_uid`, `delo_id`, and `new`; the older VNKOD interface uses
/// `_id`, `_uid`, `_deloId`, and `_new`.  A card may omit either source-native
/// identifier (some vintage result links contain only `_uid`), but it must
/// contain at least one identifier and a register (`deloID`).
public struct SudrfCaseCardLink: Sendable, Equatable {
    /// The input URL without its fragment, CAPTCHA values, or known tracking
    /// parameters.  Unknown query parameters are retained because some courts
    /// use them to select a source register or database instance.
    public let url: URL
    /// The host that published the link, lowercased.  Dot and double-dash host
    /// forms are both accepted; `moduleHost` provides their common spelling.
    public let host: String
    public let caseID: String?
    public let caseUID: String?
    public let deloID: String
    /// `nil` means the source's default register value (`0`).
    public let new: String?
    /// The database instance selector when it was published by the source.
    public let srvNum: String?

    public var domain: String { host }
    public var moduleHost: String { SudrfHost.moduleHost(host) }
    public var resolvedNew: String { new ?? "0" }
    public var sanitizedURL: URL { url }

    public init(url: URL) throws {
        self = try Self.parse(url)
    }

    public init(_ url: URL) throws {
        self = try Self.parse(url)
    }

    public static func parse(_ url: URL) throws -> Self {
        guard isSupportedHTTPURL(url) else {
            throw invalidURL("ожидался HTTP(S)-адрес без учётных данных")
        }
        guard let host = url.host?.lowercased(), isSupportedHost(host) else {
            throw invalidURL("поддерживаются только поддомены *.sudrf.ru")
        }
        guard url.path.caseInsensitiveCompare("/modules.php") == .orderedSame else {
            throw invalidURL("путь должен быть /modules.php")
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            throw invalidURL("в URL отсутствует query")
        }

        guard let name = try value(for: ["name"], in: items, label: "name", required: true) else {
            throw invalidURL("отсутствует параметр name")
        }
        guard name.caseInsensitiveCompare("sud_delo") == .orderedSame else {
            throw invalidURL("параметр name должен быть sud_delo")
        }
        guard let operation = try value(for: ["name_op"], in: items,
                                        label: "name_op", required: true) else {
            throw invalidURL("отсутствует параметр name_op")
        }
        guard operation.caseInsensitiveCompare("case") == .orderedSame else {
            throw invalidURL("поддерживается только name_op=case")
        }

        let caseID = try value(for: ["case_id", "_id"], in: items,
                               label: "case_id/_id", required: false)
        let caseUID = try value(for: ["case_uid", "_uid"], in: items,
                                label: "case_uid/_uid", required: false)
        guard caseID != nil || caseUID != nil else {
            throw invalidURL("нужен case_id/_id или case_uid/_uid")
        }
        guard let deloID = try value(for: ["delo_id", "_deloid"], in: items,
                                     label: "delo_id/_deloId", required: true) else {
            throw invalidURL("отсутствует delo_id/_deloId")
        }
        let new = try value(for: ["new", "_new"], in: items,
                            label: "new/_new", required: false,
                            emptyValue: "0")
        let srvNum = try value(for: ["srv_num"], in: items,
                               label: "srv_num", required: false)

        var sanitized = components
        sanitized.scheme = components.scheme?.lowercased()
        sanitized.host = host
        sanitized.fragment = nil
        sanitized.queryItems = items.filter { !isRemovableQueryItem($0) }
        guard let sanitizedURL = sanitized.url else {
            throw invalidURL("не удалось нормализовать URL")
        }

        return Self(url: sanitizedURL, host: host, caseID: caseID,
                    caseUID: caseUID, deloID: deloID, new: new, srvNum: srvNum)
    }

    public static func parse(_ string: String) throws -> Self {
        guard let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw invalidURL("некорректный URL")
        }
        return try parse(url)
    }

    private init(url: URL, host: String, caseID: String?, caseUID: String?,
                 deloID: String, new: String?, srvNum: String?) {
        self.url = url
        self.host = host
        self.caseID = caseID
        self.caseUID = caseUID
        self.deloID = deloID
        self.new = new
        self.srvNum = srvNum
    }

    private static func value(for names: [String], in items: [URLQueryItem],
                              label: String, required: Bool,
                              emptyValue: String? = nil) throws -> String? {
        let aliases = Set(names.map { $0.lowercased() })
        var values: [String] = []
        var found = false
        for item in items where aliases.contains(item.name.lowercased()) {
            found = true
            if item.value?.isEmpty != false, let emptyValue {
                values.append(emptyValue)
                continue
            }
            guard let value = item.value, !value.isEmpty,
                  value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw invalidURL("параметр \(label) пуст или содержит пробелы по краям")
            }
            values.append(value)
        }
        guard found else {
            if required { throw invalidURL("отсутствует параметр \(label)") }
            return nil
        }
        guard let first = values.first,
              values.dropFirst().allSatisfy({ $0 == first }) else {
            throw invalidURL("конфликтующие дубликаты параметра \(label)")
        }
        return first
    }

    private static func isSupportedHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return false }
        return true
    }

    private static func isSupportedHost(_ host: String) -> Bool {
        host.hasSuffix(".sudrf.ru") && host.dropLast(".sudrf.ru".count).isEmpty == false
    }

    private static let trackingParameterNames: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "utm_id", "gclid", "dclid", "gbraid", "wbraid", "fbclid", "msclkid",
        "yclid", "mc_cid", "mc_eid", "_ga", "_gl", "referrer", "referral"
    ]

    private static func isRemovableQueryItem(_ item: URLQueryItem) -> Bool {
        let name = item.name.lowercased()
        return name == "captcha" || name == "captchaid"
            || name.hasPrefix("utm_") || trackingParameterNames.contains(name)
    }

    private static func invalidURL(_ reason: String) -> SudrfError {
        SudrfError.parsing("ссылка на карточку SUDRF: \(reason)")
    }
}

/// Parsed card data together with the URL at which the source actually
/// answered.  `responseURL` is sanitized using the same contract as the
/// requested URL, so it is safe to persist as the card's source URL.
public struct SudrfCaseCardFetchResult: Sendable {
    public let card: CaseCard
    public let responseURL: URL

    public var effectiveURL: URL { responseURL }

    public init(card: CaseCard, responseURL: URL) {
        self.card = card
        self.responseURL = responseURL
    }
}
