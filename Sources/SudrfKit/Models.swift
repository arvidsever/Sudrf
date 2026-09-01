import Foundation

/// Ссылка на текст судебного акта из последней колонки строки выдачи
/// (`name_op=doc`). Для приложения избыточна — оно берёт тексты из карточки,
/// — но для сплошного сбора это половина запросов: текст по такой ссылке
/// совпадает с блоком `cont_doc{N}` карточки того же дела
/// (`Docs/architecture/ksoyu-listing-grammar.md`, §4).
public struct CaseActLink: Sendable, Equatable, Identifiable {
    /// `number=` — идентификатор документа в базе суда.
    public var number: String
    /// `text_number=` — порядковый номер акта внутри дела, с 1.
    /// Несколько актов на дело возможны, но редки.
    public var textNumber: Int
    /// Ярлык из `TITLE` ссылки: «Постановления», «Решения», «Определение».
    public var kind: String?
    public var url: URL

    public var id: String { url.absoluteString }

    public init(number: String, textNumber: Int, kind: String? = nil, url: URL) {
        self.number = number; self.textNumber = textNumber
        self.kind = kind; self.url = url
    }
}

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
    /// Ссылки на тексты опубликованных актов из последней колонки. Пусто, если
    /// акт не опубликован (262-ФЗ: публикуется не всё) или суд колонку не даёт.
    public var actTextLinks: [CaseActLink]

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
                cardURL: URL? = nil,
                actTextLinks: [CaseActLink] = []) {
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
        self.actTextLinks = actTextLinks
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

/// Опубликованная карточкой ссылка на номер предыдущей регистрации дела.
/// URL сохраняется именно в виде, разрешённом относительно фактического
/// адреса загруженной карточки, а не строится из предположений о картотеке.
public struct PreviousRegistrationReference: Sendable, Equatable, Codable {
    public var caseNumber: String
    public var url: URL

    public init(caseNumber: String, url: URL) {
        self.caseNumber = caseNumber
        self.url = url
    }
}

/// Реквизиты одного исполнительного листа из вкладки «Исполнительные листы».
///
/// Судебная карточка публикует бумажные и электронные документы в одной
/// таблице. `date` сохраняется в том виде, в котором его отдал суд (как и
/// остальные даты карточки), чтобы не потерять значение при смене формата.
public struct CourtEnforcementDocument: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var date: String?
    public var blankNumber: String?
    public var electronicID: String?
    public var courtStatus: String?
    public var recipient: String?

    public init(id: String? = nil,
                date: String? = nil,
                blankNumber: String? = nil,
                electronicID: String? = nil,
                courtStatus: String? = nil,
                recipient: String? = nil) {
        self.date = Self.clean(date)
        self.blankNumber = Self.clean(blankNumber)
        self.electronicID = Self.clean(electronicID)
        self.courtStatus = Self.clean(courtStatus)
        self.recipient = Self.clean(recipient)
        self.id = id ?? Self.makeID(date: self.date,
                                    blankNumber: self.blankNumber,
                                    electronicID: self.electronicID,
                                    courtStatus: self.courtStatus,
                                    recipient: self.recipient)
    }

    /// Stable identity used to reconcile a row after a refresh. It deliberately
    /// avoids Swift's process-randomised `hashValue`.
    public static func makeID(date: String?, blankNumber: String?, electronicID: String?,
                              courtStatus: String?, recipient: String?) -> String {
        let number = normalizedNumber(blankNumber ?? electronicID)
        let key = number.isEmpty
            ? [date, courtStatus, recipient].map { normalize($0) }.joined(separator: "|")
            : number
        return "court-enforcement:\(key.isEmpty ? "row" : key)"
    }

    /// Canonical number for exact source matching (spaces, punctuation and
    /// case markers such as «№» do not affect identity).
    public static func normalizedNumber(_ value: String?) -> String {
        normalize(value).uppercased().filter { $0.isNumber || $0.isLetter }
    }

    /// Canonical paper number used by source matching and reconciliation.
    public var normalizedBlankNumber: String {
        Self.normalizedNumber(blankNumber)
    }

    /// Казначейство ищем только для бумажного листа, который суд не направил
    /// приставам. Электронные ИД и явные получатели ФССП остаются в общем UI,
    /// но ждут отдельного источника.
    public var isTreasuryEligible: Bool {
        guard !normalizedBlankNumber.isEmpty else { return false }
        let recipient = Self.normalize(recipient).lowercased()
        return !recipient.contains("пристав") && !recipient.contains("фссп")
    }

    static func normalize(_ value: String?) -> String {
        guard let value else { return "" }
        return value
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "Ё", with: "Е")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clean(_ value: String?) -> String? {
        let value = normalize(value)
        return value.isEmpty ? nil : value
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
    /// Опубликованная ссылка на предыдущую регистрацию этого же дела.
    public var previousRegistration: PreviousRegistrationReference?
    /// Исполнительные листы из таблицы «ИСПОЛНИТЕЛЬНЫЕ ЛИСТЫ».
    public var executionDocuments: [CourtEnforcementDocument]

    public init(rawText: String, actText: String?,
                sessions: [CaseSession] = [], judge: String? = nil, result: String? = nil,
                uid: String? = nil, caseNumber: String? = nil, category: String? = nil,
                receiptDate: String? = nil, decisionDate: String? = nil,
                legalForceDate: String? = nil,
                acts: [CaseActText] = [], appeals: [AppealRecord] = [],
                parties: CaseParties = CaseParties(),
                lowerCourt: LowerCourtReference? = nil,
                previousRegistration: PreviousRegistrationReference? = nil,
                executionDocuments: [CourtEnforcementDocument] = []) {
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
        self.previousRegistration = previousRegistration
        self.executionDocuments = executionDocuments
    }
}

public enum SudrfError: Error, CustomStringConvertible, LocalizedError {
    /// На форме/выдаче обнаружена капча. Решать её программно нельзя —
    /// нужно открыть `formURL` в браузере и ввести код вручную.
    case captchaRequired(formURL: URL)
    case decodingFailed
    case http(status: Int)
    case parsing(String)
    case invalidValue(String)
    case unknownCartoteka(String)
    /// Сервер вернул штатную HTML-заглушку вместо карточки дела. HTTP-запрос
    /// формально успешен, но разбирать такую страницу как пустую карточку нельзя:
    /// фоновое обновление иначе затрёт уже сохранённые движение, УИД и акты.
    case caseCardTemporarilyUnavailable
    /// Источник вернул штатную страницу технических работ/недоступности
    /// вместо результата операции.
    case sourceMaintenance(domain: String)
    /// Ни один известный вариант поискового URL не дал ни выдачи, ни валидной
    /// пустой страницы — суд отвечает в неизвестном формате. Пустоту в этом
    /// случае показывать нельзя.
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
        case .caseCardTemporarilyUnavailable:
            return "Карточка дела временно недоступна на сайте суда. "
                 + "Сохранённые данные оставлены без изменений; попробуйте обновить позже."
        case .sourceMaintenance(let domain):
            return "Источник \(domain) временно недоступен. Сохранённые данные оставлены без изменений."
        case .searchModuleUnavailable(let domain):
            return "Поисковый модуль суда \(domain) вернул страницу, которую приложение "
                 + "не смогло распознать. Это не считается пустой выдачей; попробуйте "
                 + "позже или откройте сайт суда в браузере."
        case .transientNetworkError(let domain, let code, let attempt):
            return "Суд \(domain) не отвечает по сети (\(code.rawValue)) после \(attempt) попыток."
        }
    }

    public var errorDescription: String? { description }
}
