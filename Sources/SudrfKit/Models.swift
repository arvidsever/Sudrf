import Foundation

/// Одна строка таблицы результатов поиска.
public struct CaseSearchResult: Sendable, Equatable, Identifiable {
    public var caseNumber: String          // № дела (текст ссылки)
    public var receiptDate: String?        // дата поступления
    public var essence: String?            // существо / стороны
    public var judge: String?              // судья
    public var decisionDate: String?       // дата решения
    public var result: String?             // результат
    public var legalForceDate: String?     // дата вступления в силу
    public var caseID: String?             // case_id из ссылки на карточку
    public var caseUID: String?            // case_uid (GUID) из ссылки
    public var cardURL: URL?               // абсолютная ссылка на карточку

    public var id: String { stableID }

    public var stableID: String {
        if let value = cardURL?.absoluteString, !value.isEmpty {
            return "url:\(value)"
        }
        if caseID?.isEmpty == false || caseUID?.isEmpty == false {
            return "case:\(caseID ?? "")|\(caseUID ?? "")"
        }
        return [
            caseNumber,
            receiptDate ?? "",
            decisionDate ?? "",
            judge ?? "",
            result ?? ""
        ].joined(separator: "|")
    }

    public init(caseNumber: String,
                receiptDate: String? = nil,
                essence: String? = nil,
                judge: String? = nil,
                decisionDate: String? = nil,
                result: String? = nil,
                legalForceDate: String? = nil,
                caseID: String? = nil,
                caseUID: String? = nil,
                cardURL: URL? = nil) {
        self.caseNumber = caseNumber
        self.receiptDate = receiptDate
        self.essence = essence
        self.judge = judge
        self.decisionDate = decisionDate
        self.result = result
        self.legalForceDate = legalForceDate
        self.caseID = caseID
        self.caseUID = caseUID
        self.cardURL = cardURL
    }
}

/// Текст одного судебного акта из вкладки «СУДЕБНЫЕ АКТЫ» карточки.
public struct CaseActText: Sendable, Equatable, Identifiable {
    public let id: String       // «doc1», «doc2», …
    public var kind: String     // тип из ярлыка: «Решения» / «Определение» / «Постановления»
    public var label: String    // полный ярлык: «Судебный акт #1 (Решения)»
    public var body: String     // текст акта (с сохранёнными абзацами)

    public init(id: String, kind: String, label: String, body: String) {
        self.id = id; self.kind = kind; self.label = label; self.body = body
    }
}

/// Карточка дела с метаданными, разобранным движением и текстами актов.
/// Вид жалобы из вкладки «Обжалование» карточки 1-й инстанции.
public enum AppealKind: Sendable, Equatable {
    case appeal            // апелляционная жалоба / представление
    case cassation         // кассационная жалоба / представление
    case privateComplaint  // частная жалоба
    case other             // замечания на протокол, надзор и прочее — не круг
}

/// Одна запись вкладки «Обжалование» (ЖАЛОБА № N): вид, вышестоящий суд и даты
/// движения. Источник истины для различения круг апелляции/кассации vs частная
/// жалоба — поле «Вид жалобы (представления)».
public struct AppealRecord: Sendable, Equatable {
    public let kind: AppealKind
    public let rawKind: String        // исходный «Вид жалобы (представления)»
    public let higherCourt: String?   // «Вышестоящий суд»
    public let sentUpDate: String?    // «Направлено в вышестоящую инстанцию»
    public let returnedDate: String?  // «Возвращено из вышестоящей инстанции»
    public let hearingDate: String?   // «Дата рассмотрения жалобы»
    public let result: String?        // «Результат обжалования»

    public init(kind: AppealKind, rawKind: String, higherCourt: String? = nil,
                sentUpDate: String? = nil, returnedDate: String? = nil,
                hearingDate: String? = nil, result: String? = nil) {
        self.kind = kind; self.rawKind = rawKind; self.higherCourt = higherCourt
        self.sentUpDate = sentUpDate; self.returnedDate = returnedDate
        self.hearingDate = hearingDate; self.result = result
    }
}

/// Ссылка из карточки апелляционной/кассационной инстанции на рассмотрение
/// в нижестоящем суде. Эти поля позволяют восстановить каноническую карточку
/// первой инстанции даже тогда, когда УИД в вышестоящей карточке не опубликован.
public struct LowerCourtReference: Sendable, Equatable, Codable {
    public var region: String?
    public var courtTitle: String?
    public var caseNumber: String?
    public var decisionDate: String?
    public var judge: String?

    public init(region: String? = nil, courtTitle: String? = nil,
                caseNumber: String? = nil, decisionDate: String? = nil,
                judge: String? = nil) {
        self.region = region; self.courtTitle = courtTitle
        self.caseNumber = caseNumber; self.decisionDate = decisionDate
        self.judge = judge
    }

    public var isEmpty: Bool {
        [region, courtTitle, caseNumber, decisionDate, judge]
            .allSatisfy { ($0 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

public struct CaseCard: Sendable {
    public var rawText: String          // весь текст карточки (для отладки/фолбэка)
    public var actText: String?         // текст первого судебного акта (для обратной совместимости)
    public var sessions: [CaseSession]  // движение дела из вкладки «ДВИЖЕНИЕ ДЕЛА»/«СЛУШАНИЯ»
    public var judge: String?           // судья из вкладки «ДЕЛО»/«ПРОИЗВОДСТВО»
    public var result: String?          // результат рассмотрения из той же вкладки
    public var uid: String?             // уникальный идентификатор дела (УИД)
    public var caseNumber: String?      // номер дела из заголовка карточки
    public var category: String?        // категория дела
    public var receiptDate: String?     // дата поступления
    public var decisionDate: String?    // дата рассмотрения
    public var legalForceDate: String?  // дата вступления в законную силу
    public var acts: [CaseActText]      // все судебные акты карточки (инлайн-тексты)
    public var appeals: [AppealRecord]  // вкладка «Обжалование» (в карточке 1-й инстанции)
    public var parties: CaseParties     // вкладка «СТОРОНЫ ПО ДЕЛУ» (истцы/ответчики/третьи)
    public var lowerCourt: LowerCourtReference? // «РАССМОТРЕНИЕ В НИЖЕСТОЯЩЕМ СУДЕ»

    public init(rawText: String, actText: String?,
                sessions: [CaseSession] = [], judge: String? = nil, result: String? = nil,
                uid: String? = nil, caseNumber: String? = nil, category: String? = nil,
                receiptDate: String? = nil, decisionDate: String? = nil,
                legalForceDate: String? = nil,
                acts: [CaseActText] = [], appeals: [AppealRecord] = [],
                parties: CaseParties = CaseParties(),
                lowerCourt: LowerCourtReference? = nil) {
        self.rawText = rawText
        self.actText = actText
        self.sessions = sessions
        self.judge = judge
        self.result = result
        self.uid = uid
        self.caseNumber = caseNumber
        self.category = category
        self.receiptDate = receiptDate
        self.decisionDate = decisionDate
        self.legalForceDate = legalForceDate
        self.acts = acts
        self.appeals = appeals
        self.parties = parties
        self.lowerCourt = lowerCourt
    }
}

public enum SudrfError: Error, CustomStringConvertible {
    /// На форме/выдаче обнаружена капча. Решать её программно нельзя —
    /// нужно открыть `formURL` в браузере и ввести код вручную.
    case captchaRequired(formURL: URL)
    case decodingFailed
    case http(status: Int)
    case parsing(String)
    case invalidValue(String)
    case unknownCartoteka(String)
    /// Ни один известный вариант поискового URL не дал ни выдачи, ни валидной
    /// пустой страницы — суд отвечает в неизвестном формате (другая версия
    /// интерфейса, JS-защита, заглушка). Пустоту в этом случае показывать нельзя.
    case searchModuleUnavailable(domain: String)
    /// Сетевая ошибка после исчерпания ретраев вышестоящего суда (timeout /
    /// нет сети / DNS). Это НЕ «модуль недоступен» (суд отдаёт неизвестный
    /// HTML) и НЕ капча — суд вообще не ответил. `MovementCachePolicy.merge`
    /// защищает кэш по `transientError` от затирания частично-успешным
    /// fetch'ем. Преобразование `URLError → SudrfError.transientNetworkError`
    /// делает `SudrfClient.fetchHTMLData` ТОЛЬКО после исчерпания 3 попыток
    /// (= 2 повтора после первой), и только если ФИНАЛЬНАЯ ошибка — transient.
    case transientNetworkError(domain: String, code: URLError.Code, attempt: Int)

    public var description: String {
        switch self {
        case .captchaRequired(let url):
            return "На форме этого суда стоит капча. Решать её автоматически нельзя — "
                 + "откройте в браузере и введите код вручную: \(url.absoluteString)"
        case .decodingFailed:
            return "Не удалось декодировать ответ как windows-1251."
        case .http(let status):
            return "HTTP-ошибка: статус \(status)."
        case .parsing(let what):
            return "Ошибка разбора HTML: \(what)"
        case .invalidValue(let v):
            return "Значение нельзя представить в cp1251: «\(v)»."
        case .unknownCartoteka(let id):
            return "Неизвестная картотека: «\(id)»."
        case .searchModuleUnavailable(let domain):
            return "Поисковый модуль суда \(domain) не отвечает в известных форматах "
                 + "(возможно, JS-защита или нестандартный интерфейс). "
                 + "Попробуйте открыть сайт суда в браузере."
        case .transientNetworkError(let domain, let code, let attempt):
            return "Суд \(domain) не отвечает по сети (\(code.rawValue)) после \(attempt) попыток."
        }
    }
}
