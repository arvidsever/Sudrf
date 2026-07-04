import Foundation

/// Поле поиска в выдаче.
public enum SearchField: Sendable {
    case caseNumber   // № дела
    case uid          // УИД
    case name         // ФИО стороны
}

/// Один из вариантов поискового URL. Суды понимают разные версии интерфейса
/// sud_delo (SearchPattern) и разные наборы параметров внутри версии — варианты
/// перебираются клиентом по порядку, рабочий запоминается (WorkingVariantStore).
public struct SearchURLVariant: Sendable, Equatable {
    /// Стабильный ключ варианта для кэша, напр. "primary" или "vnkod:41:0:pt".
    public let id: String
    public let url: URL
}

/// Сборка прямых URL к sud_delo. Кириллица кодируется в cp1251 вручную,
/// поэтому query собирается строкой, а не через URLComponents (тот навязал бы UTF-8).
public struct SudrfURLBuilder {
    public let court: Court
    public init(court: Court) { self.court = court }

    private var base: String { "https://\(court.domain)/modules.php?name=sud_delo" }

    /// Версия поискового интерфейса этого суда.
    public var pattern: SearchPattern { SearchPatternDirectory.pattern(forDomain: court.domain) }

    /// URL формы картотеки (`name_op=sf`) — используется для проверки капчи
    /// и открывается пользователю для ручного ввода кода.
    public func formURL(_ c: Cartoteka) throws -> URL {
        let q: String
        switch pattern {
        case .primary:
            var s = "\(base)&srv_num=1&name_op=sf&delo_id=\(Self.escape(c.deloID))"
            if c.new != "0" { s += "&new=\(Self.escape(c.new))" }
            q = s
        case .vnkod:
            // Винтажная форма; пары _deloId/_new — как у выдачи (vnkodDeloParams).
            let (deloID, new) = Self.vnkodDeloParams(c)?.first ?? (c.deloID, c.new)
            q = "\(base)&srv_num=1&name_op=sf&_deloId=\(Self.escape(deloID))&_caseType=0&_new=\(Self.escape(new))"
        }
        guard let url = URL(string: q) else { throw SudrfError.parsing("не удалось собрать URL формы") }
        return url
    }

    /// URL выдачи (`name_op=r`) — прямой GET в обход JS-формы.
    public func searchURL(cartoteka c: Cartoteka, field: SearchField, value: String) throws -> URL {
        let fieldName: String
        switch field {
        case .caseNumber: fieldName = c.caseNumberField
        case .uid:        fieldName = c.uidField
        case .name:       fieldName = c.nameField
        }
        guard let encoded = Cyrillic1251.percentEncodeQueryValue(value) else {
            throw SudrfError.invalidValue(value)
        }
        var q = "\(base)&srv_num=1&name_op=r&delo_id=\(Self.escape(c.deloID))&case_type=0&new=\(Self.escape(c.new))"
        q += "&delo_table=\(Self.escape(c.deloTable))"
        q += "&\(fieldName)=\(encoded)"
        q += "&Submit=%CD%E0%E9%F2%E8"   // «Найти» в cp1251
        guard let url = URL(string: q) else { throw SudrfError.parsing("не удалось собрать URL выдачи") }
        return url
    }

    /// Варианты URL выдачи для перебора. У primary-судов вариант один (searchURL);
    /// у винтажных — набор из известных форм записи запроса (с process-type и без,
    /// для ФИО дополнительно поле part__namess вместо parts__namess). Если
    /// винтажная форма для картотеки неизвестна (кассация/президиум) — возвращается
    /// primary-вариант: пусть суд ответит, а классификатор оценит ответ.
    ///
    /// `captcha` — решённая пользователем пара: форма отправляется GET-ом, поэтому
    /// суд принимает её параметрами `&captcha=…&captchaid=…` в каждом варианте.
    public func searchURLVariants(cartoteka c: Cartoteka,
                                  field: SearchField,
                                  value: String,
                                  captcha: CaptchaToken? = nil) throws -> [SearchURLVariant] {
        let variants = try rawSearchURLVariants(cartoteka: c, field: field, value: value)
        guard let captcha else { return variants }
        return try variants.map { v in
            let q = v.url.absoluteString
                  + "&captcha=\(Self.escape(captcha.value))&captchaid=\(Self.escape(captcha.id))"
            guard let url = URL(string: q) else {
                throw SudrfError.parsing("не удалось собрать URL выдачи")
            }
            return SearchURLVariant(id: v.id, url: url)
        }
    }

    private func rawSearchURLVariants(cartoteka c: Cartoteka,
                                      field: SearchField,
                                      value: String) throws -> [SearchURLVariant] {
        guard pattern == .vnkod,
              let vnkod = SearchPatternDirectory.vnkod(forDomain: court.domain),
              let pairs = Self.vnkodDeloParams(c) else {
            return [SearchURLVariant(id: "primary",
                                     url: try searchURL(cartoteka: c, field: field, value: value))]
        }
        guard let encoded = Cyrillic1251.percentEncodeQueryValue(value) else {
            throw SudrfError.invalidValue(value)
        }
        var variants: [SearchURLVariant] = []
        for (deloID, new) in pairs {
            let head = "\(base)&name_op=r&_page=1&vnkod=\(Self.escape(vnkod))&srv_num=1"
                     + "&_deloId=\(Self.escape(deloID))&case__case_type=0&_new=\(Self.escape(new))"
                     + "&case__vnkod=\(Self.escape(vnkod))&case__num_build=1"
            // process-type встречается только у форм первой инстанции; для
            // апелляции у части судов он текстовый в cp1251 — надёжнее без него.
            // Для ФИО часть судов ждёт поле part__namess вместо parts__namess —
            // один запасной вариант без process-type, чтобы не раздувать перебор.
            var combos: [(fieldName: String, processType: String?)]
            let pts: [String?] = (new == "0") ? ["\(deloID)_0_0", nil] : [nil]
            switch field {
            case .caseNumber: combos = pts.map { ("case__case_numberss", $0) }
            case .uid:        combos = pts.map { ("case__judicial_uidss", $0) }
            case .name:
                combos = pts.map { ("parts__namess", $0) }
                combos.append(("part__namess", nil))
            }
            for (fieldName, pt) in combos {
                var q = head
                if let pt { q += "&process-type=\(Self.escape(pt))" }
                q += "&\(fieldName)=\(encoded)"
                guard let url = URL(string: q) else {
                    throw SudrfError.parsing("не удалось собрать URL выдачи")
                }
                let ptSuffix = pt == nil ? "" : ":pt"
                let fSuffix = fieldName == "part__namess" ? ":part" : ""
                variants.append(SearchURLVariant(id: "vnkod:\(deloID):\(new)\(ptSuffix)\(fSuffix)",
                                                 url: url))
            }
        }
        // Классификация среза VNKOD-судов может устаревать (Воронеж по живой
        // проверке уже на современном модуле) — primary-вариант замыкает
        // перебор, а WorkingVariantStore запомнит его как рабочий.
        variants.append(SearchURLVariant(id: "primary",
                                         url: try searchURL(cartoteka: c, field: field, value: value)))
        return variants
    }

    /// Пары `_deloId`/`_new` винтажного интерфейса для картотеки. Выверены по
    /// боевым паттернам sudrfscraper (searchpatterns/*.properties, VNKOD_PATTERN):
    /// первая инстанция и апелляция известны; кассация/президиум — нет (nil →
    /// перебор откатывается на primary-вариант).
    static func vnkodDeloParams(_ c: Cartoteka) -> [(deloID: String, new: String)]? {
        switch (c.deloID, c.new) {
        case ("1540006", "0"): return [("1540006", "0")]   // уголовные, 1-я инстанция
        case ("4", "4"):       return [("1540006", "4")]   // уголовные, апелляция
        case ("1540005", "0"): return [("1540005", "0")]   // гражданские, 1-я инстанция
        case ("5", "5"):       return [("1540005", "5")]   // гражданские, апелляция
        case ("41", "0"):      return [("41", "0"), ("1540005", "0")]
            // КАС, 1-я инстанция: на части винтажных судов КАС-дела живут
            // в гражданской таблице (_deloId=1540005) — пробуются обе.
        case ("42", "0"):      return [("42", "0")]        // КАС, апелляция
        case ("1500001", "0"): return [("1500001", "0")]   // дела об АП
        case ("1502001", "0"): return [("1502001", "0")]   // жалобы по делам об АП
        case ("1610001", "0"): return [("1610001", "0")]   // материалы
        default:               return nil
        }
    }

    /// URL карточки дела (`name_op=case`). Капчей не защищена ни на одном суде —
    /// имея case_id и case_uid, можно тянуть карточку и тексты актов свободно.
    /// Для апелляции/кассации карточка требует `new` (как и выдача), поэтому он
    /// добавляется, если задан и не равен «0».
    ///
    /// case_id и case_uid приходят из выдачи УЖЕ percent-декодированными
    /// (URLComponents в ResultsParser.queryValue), поэтому здесь кодируются заново.
    ///
    /// Винтажный интерфейс (VNKOD-суды) открывает карточку другими параметрами:
    /// `_id`/`_uid`/`_deloId`/`_caseType`/`_new` (порядок — как в живом URL
    /// Заволжского районного суда г. Ульяновска); пары `_deloId`/`_new` — через
    /// тот же маппинг, что у выдачи (vnkodDeloParams).
    public func cardURL(caseID: String, caseUID: String, deloID: String, new: String = "0") throws -> URL {
        let q: String
        switch pattern {
        case .primary:
            var s = "\(base)&srv_num=1&name_op=case&case_id=\(Self.escape(caseID))"
            s += "&case_uid=\(Self.escape(caseUID))&delo_id=\(Self.escape(deloID))"
            if new != "0" && !new.isEmpty { s += "&new=\(Self.escape(new))" }
            q = s
        case .vnkod:
            let mapped = Self.vnkodDeloParams(Cartoteka(
                id: "", title: "", deloID: deloID, new: new.isEmpty ? "0" : new,
                deloTable: "", caseNumberField: "", uidField: "", nameField: ""
            ))?.first ?? (deloID, new.isEmpty ? "0" : new)
            q = "\(base)&name_op=case&_id=\(Self.escape(caseID))"
              + "&_uid=\(Self.escape(caseUID))&_deloId=\(Self.escape(mapped.deloID))"
              + "&_caseType=0&_new=\(Self.escape(mapped.new))&srv_num=1"
        }
        guard let url = URL(string: q) else { throw SudrfError.parsing("не удалось собрать URL карточки") }
        return url
    }

    /// Percent-кодирование значения query-параметра: остаются только
    /// незарезервированные символы RFC 3986 (как в Cyrillic1251.isUnreserved).
    private static func escape(_ s: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
