import Foundation

/// Поле поиска в выдаче.
public enum SearchField: Sendable {
    case caseNumber   // № дела
    case uid          // УИД
    case name         // ФИО стороны
}

/// Сборка прямых URL к sud_delo. Кириллица кодируется в cp1251 вручную,
/// поэтому query собирается строкой, а не через URLComponents (тот навязал бы UTF-8).
public struct SudrfURLBuilder {
    public let court: Court
    public init(court: Court) { self.court = court }

    private var base: String { "https://\(court.domain)/modules.php?name=sud_delo" }

    /// URL формы картотеки (`name_op=sf`) — используется для проверки капчи.
    public func formURL(_ c: Cartoteka) throws -> URL {
        var q = "\(base)&srv_num=1&name_op=sf&delo_id=\(Self.escape(c.deloID))"
        if c.new != "0" { q += "&new=\(Self.escape(c.new))" }
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

    /// URL карточки дела (`name_op=case`). Капчей не защищена ни на одном суде —
    /// имея case_id и case_uid, можно тянуть карточку и тексты актов свободно.
    /// Для апелляции/кассации карточка требует `new` (как и выдача), поэтому он
    /// добавляется, если задан и не равен «0».
    ///
    /// case_id и case_uid приходят из выдачи УЖЕ percent-декодированными
    /// (URLComponents в ResultsParser.queryValue), поэтому здесь кодируются заново.
    public func cardURL(caseID: String, caseUID: String, deloID: String, new: String = "0") throws -> URL {
        var q = "\(base)&srv_num=1&name_op=case&case_id=\(Self.escape(caseID))"
        q += "&case_uid=\(Self.escape(caseUID))&delo_id=\(Self.escape(deloID))"
        if new != "0" && !new.isEmpty { q += "&new=\(Self.escape(new))" }
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
