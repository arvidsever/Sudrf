import Foundation
import SwiftSoup

/// Опубликованная запись участка мирового судьи Москвы.
///
/// `alias`, классификационный `code` и `unitPathID` — разные значения.
public struct MoscowMagistrateUnit: Sendable, Equatable, Codable {
    public let url: String
    public let name: String
    public let alias: String
    public let courtFullNameWithMunicipal: String
    public let id: String
    public let code: String
    public let rsCourtId: String
    public let canceledAt: String

    public var isActive: Bool {
        canceledAt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Идентификатор участка из опубликованного canonical URL `/rs/<id>`.
    public var unitPathID: String? {
        guard let components = URLComponents(string: url),
              components.scheme == "https",
              components.host == MoscowMagistrateDirectoryParser.host,
              components.user == nil, components.password == nil,
              components.port == nil, components.query == nil, components.fragment == nil,
              components.percentEncodedPath.hasPrefix("/rs/") else { return nil }
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0] == "rs",
              !parts[1].isEmpty,
              parts[1].unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else { return nil }
        return String(parts[1])
    }

    public var magistrateCourt: MagistrateCourt {
        MagistrateCourt(title: courtFullNameWithMunicipal,
                        domain: MoscowMagistrateDirectoryParser.host,
                        code: code,
                        portalSubject: MoscowMagistrateDirectoryParser.subjectCode)
    }
}

/// Парсер списка участков, опубликованного в JS-состоянии главной страницы mos-sud.ru.
public enum MoscowMagistrateDirectoryParser {
    public static let subjectCode = MosGorSudCourtDirectory.moscowSubjectCode
    public static let host = MoscowMagistrateKoAPSource.host

    public static func parse(html: String) throws -> [MoscowMagistrateUnit] {
        guard let document = try? SwiftSoup.parse(html) else {
            throw SudrfError.parsing("Не удалось разобрать справочник мировых судей Москвы")
        }
        let scripts = (try? document.select("script").array()) ?? []
        var arrays: [String] = []
        for script in scripts {
            guard let contents = try? script.html(),
                  let parsed = courtArrays(in: contents) else {
                throw SudrfError.parsing("Не удалось прочитать опубликованный список участков")
            }
            arrays.append(contentsOf: parsed)
        }
        guard arrays.count == 1, let json = jsonArray(from: arrays[0]),
              let data = json.data(using: .utf8) else {
            throw SudrfError.parsing("В источнике нет единственного опубликованного списка участков")
        }

        let units: [MoscowMagistrateUnit]
        do {
            units = try JSONDecoder().decode([MoscowMagistrateUnit].self, from: data)
        } catch {
            throw SudrfError.parsing("Не удалось прочитать список участков мировых судей Москвы")
        }
        guard !units.isEmpty,
              units.allSatisfy({
                  !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.courtFullNameWithMunicipal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && !$0.rsCourtId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.unitPathID != nil
              }),
              unique(units.map(\.url)), unique(units.map(\.id)),
              unique(units.map(\.alias)), unique(units.map(\.code)),
              unique(units.compactMap(\.unitPathID)) else {
            throw SudrfError.parsing("Список участков содержит пустые, повторные или некорректные записи")
        }
        return units
    }

    private static func unique(_ values: [String]) -> Bool {
        Set(values).count == values.count
    }

    private static func courtArrays(in source: String) -> [String]? {
        var markers: [Range<String.Index>] = []
        var index = source.startIndex
        var quoted: Character?
        var escaped = false
        while index < source.endIndex {
            let character = source[index]
            if let quote = quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == quote { quoted = nil }
            } else if character == "\"" || character == "'" {
                quoted = character
            } else if source[index...].hasPrefix("courts:") {
                let end = source.index(index, offsetBy: "courts:".count)
                markers.append(index..<end)
                index = end
                continue
            }
            index = source.index(after: index)
        }

        var arrays: [String] = []
        for marker in markers {
            var opening = marker.upperBound
            while opening < source.endIndex && source[opening].isWhitespace {
                opening = source.index(after: opening)
            }
            guard opening < source.endIndex, source[opening] == "[",
                  let array = arrayStarting(at: opening, in: source) else { return nil }
            arrays.append(array)
        }
        return arrays
    }

    private static func arrayStarting(at opening: String.Index, in source: String) -> String? {
        var depth = 0
        var quote: Character?
        var escaped = false
        var index = opening
        while index < source.endIndex {
            let character = source[index]
            if let quoteCharacter = quote {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == quoteCharacter { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                if depth == 0 { return String(source[opening...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    // shortcut: accepts the page's quoted-string object literals only; recheck the source before extending if its JS data shape changes.
    /// Converts the page's data-only JS object literal to JSON; it does not execute JavaScript.
    private static func jsonArray(from literal: String) -> String? {
        let characters = Array(literal)
        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var index = 0
        var quoted = false
        var escaped = false

        while index < characters.count {
            let character = characters[index]
            if quoted {
                output.append(character)
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
                index += 1
                continue
            }
            if character == "\"" {
                quoted = true
                output.append(character)
                index += 1
                continue
            }
            if character == "," {
                var next = index + 1
                while next < characters.count && characters[next].isWhitespace { next += 1 }
                if next < characters.count, characters[next] == "}" || characters[next] == "]" {
                    index += 1
                    continue
                }
                output.append(character)
                index += 1
                continue
            }
            if isIdentifierStart(character) {
                let start = index
                index += 1
                while index < characters.count && isIdentifierContinuation(characters[index]) { index += 1 }
                let identifier = String(characters[start..<index])
                var next = index
                while next < characters.count && characters[next].isWhitespace { next += 1 }
                if next < characters.count, characters[next] == ":" {
                    output.append("\"")
                    output.append(contentsOf: identifier)
                    output.append("\"")
                } else {
                    output.append(contentsOf: identifier)
                }
                continue
            }
            output.append(character)
            index += 1
        }
        return quoted ? nil : String(output)
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let value = character.unicodeScalars.first?.value else {
            return false
        }
        return (65...90).contains(value) || (97...122).contains(value) || value == 36 || value == 95
    }

    private static func isIdentifierContinuation(_ character: Character) -> Bool {
        isIdentifierStart(character)
            || (character.unicodeScalars.count == 1
                && character.unicodeScalars.first.map { (48...57).contains($0.value) } == true)
    }
}
