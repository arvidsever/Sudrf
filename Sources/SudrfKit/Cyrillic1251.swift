import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// Кодек windows-1251 и совместимое с формой суда percent-кодирование query-значений.
///
/// Сайты ГАС «Правосудие» отдают и принимают данные в кодировке windows-1251.
/// В `String.Encoding` именованной константы для неё нет — получаем через CoreFoundation.
public enum Cyrillic1251 {

    /// windows-1251 как `String.Encoding`.
    public static let encoding: String.Encoding = {
        let cf = CFStringEncoding(CFStringEncodings.windowsCyrillic.rawValue)
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }()

    /// Декодирует тело ответа суда (страница в cp1251) в строку.
    public static func decode(_ data: Data) -> String? {
        if let decoded = String(data: data, encoding: encoding) { return decoded }

        // 0x98 не определён в windows-1251, но иногда попадает в HTML как
        // мусорный управляющий байт. Foundation тогда отвергает весь ответ,
        // хотя остальные байты страницы корректны. Чиним только этот байт,
        // не включая lossy-декодирование для произвольных повреждений.
        guard data.contains(0x98) else { return nil }
        let repaired = Data(data.map { $0 == 0x98 ? 0x3F : $0 })
        return String(data: repaired, encoding: encoding)
    }

    /// Кодирует строку в байты cp1251 (без потерь — кириллица обязана уложиться в 1251).
    public static func encodeBytes(_ s: String) -> Data? {
        s.data(using: encoding, allowLossyConversion: false)
    }

    /// Percent-кодирование значения для query string поверх байтов cp1251.
    ///
    /// Кириллица уходит как cp1251-байты («а» → `%E0`), `/` → `%2F`, пробел → `+`
    /// — ровно так, как кодирует браузерная форма суда (проверено на «Найти» →
    /// `%CD%E0%E9%F2%E8`). Возвращает `nil`, если строка не представима в cp1251.
    public static func percentEncodeQueryValue(_ s: String) -> String? {
        guard let data = encodeBytes(s) else { return nil }
        var out = String()
        out.reserveCapacity(data.count * 3)
        for byte in data {
            if isUnreserved(byte) {
                out.unicodeScalars.append(UnicodeScalar(byte))
            } else if byte == 0x20 { // пробел → '+' (как в application/x-www-form-urlencoded)
                out.append("+")
            } else {
                out.append(String(format: "%%%02X", Int(byte)))
            }
        }
        return out
    }

    /// Незарезервированные символы RFC 3986: A–Z a–z 0–9 - _ . ~
    private static func isUnreserved(_ b: UInt8) -> Bool {
        switch b {
        case 0x41...0x5A, 0x61...0x7A, 0x30...0x39: return true
        case 0x2D, 0x5F, 0x2E, 0x7E: return true
        default: return false
        }
    }
}
