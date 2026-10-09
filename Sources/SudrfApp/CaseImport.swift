//  CaseImport.swift — Sudrf · v21
//  Импорт дел из CSV-выгрузки стороннего сервиса (LegalHelp) в «Мои дела».
//
//  Формат CSV (см. Scripts/export_cases_csv.py): колонки number, court, kind,
//  level, parties, updated, url; обязательные — court и url (номер добывается
//  из самой карточки). url — прямая ссылка на карточку sud_delo с case_id,
//  case_uid и delo_id.
//
//  Конвейер:
//   1. classify: строка CSV → ImportSeed (домен, звено, картотека, параметры
//      карточки) либо причина пропуска (мировые судьи, Мосгорсуд и т. п.).
//   2. Сетевой этап (см. AppRouter.runImport): для каждого seed карточка
//      тянется прямым GET (капчи на карточках нет) — из неё берётся УИД.
//   3. plan: группировка карточек по УИД — в LegalHelp каждая инстанция и
//      каждый материал заведены отдельными карточками, здесь они сшиваются в
//      одно дело. Якорь группы — низшее звено вида «дело»; остальные карточки
//      уходят в knownCards контекста (MovementService заберёт их прямым GET
//      там, где сквозной поиск упрётся в капчу или в пустой УИД).

import Foundation
import SudrfKit

// MARK: - CSV (RFC 4180)

enum CSVParser {
    struct ParsedRow: Equatable {
        let fields: [String]
        /// Physical line numbers, including the header as line 1. A quoted
        /// newline therefore produces a range such as 7...9.
        let lineRange: ClosedRange<Int>

        var sourceLine: Int { lineRange.lowerBound }
        var sourceLines: String {
            lineRange.lowerBound == lineRange.upperBound
                ? "\(lineRange.lowerBound)"
                : "\(lineRange.lowerBound)–\(lineRange.upperBound)"
        }
    }

    enum DiagnosticKind: String, Equatable {
        case unterminatedQuote = "unterminated_quote"
        case unexpectedQuote = "unexpected_quote"
        case invalidUTF8 = "invalid_utf8"
    }

    struct Diagnostic: Equatable {
        let kind: DiagnosticKind
        let lineRange: ClosedRange<Int>
        let message: String

        var sourceLine: Int { lineRange.lowerBound }
        var sourceLines: String {
            lineRange.lowerBound == lineRange.upperBound
                ? "\(lineRange.lowerBound)"
                : "\(lineRange.lowerBound)–\(lineRange.upperBound)"
        }
    }

    struct ParseResult: Equatable {
        let rows: [ParsedRow]
        let diagnostics: [Diagnostic]
        let isValidUTF8: Bool

        var isValid: Bool { isValidUTF8 && diagnostics.isEmpty }
        var header: ParsedRow? { rows.first }
    }

    /// Backwards-compatible field-only API. Detailed callers should use
    /// `parseDetailed`, which retains physical line ranges and diagnostics.
    static func parse(_ text: String) -> [[String]] {
        parseDetailed(text).rows.map(\.fields)
    }

    /// Data entry point for callers that have not decoded the file yet. A
    /// String cannot represent invalid UTF-8, so this is the only path that
    /// can report that trust-boundary error without silently dropping data.
    static func parseDetailed(_ data: Data) -> ParseResult {
        guard let text = String(data: data, encoding: .utf8) else {
            return ParseResult(
                rows: [],
                diagnostics: [Diagnostic(
                    kind: .invalidUTF8,
                    lineRange: 1...1,
                    message: "Файл не является корректным UTF-8.")],
                isValidUTF8: false)
        }
        return parseDetailed(text)
    }

    /// Разбор RFC 4180 CSV с сохранением физических строк. BOM отбрасывается.
    static func parseDetailed(_ text: String) -> ParseResult {
        let characters = Array(text)
        var rows: [ParsedRow] = []
        var diagnostics: [Diagnostic] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var quoteClosed = false
        var fieldStarted = false
        var rowStarted = false
        var line = 1
        var rowStartLine = 1
        var index = 0

        // A UTF-8 BOM belongs to the encoding, not to the first header name.
        if characters.first == "\u{FEFF}" { index = 1 }

        func addDiagnostic(_ kind: DiagnosticKind, message: String) {
            diagnostics.append(Diagnostic(kind: kind,
                                           lineRange: rowStartLine...line,
                                           message: message))
        }

        func endField() {
            row.append(field)
            field = ""
            fieldStarted = false
            quoteClosed = false
        }

        func endRow() {
            endField()
            // Fully empty lines are an import artefact, not CSV records.
            if rowStarted || row.count > 1 || !(row.first?.isEmpty ?? true) {
                rows.append(ParsedRow(fields: row, lineRange: rowStartLine...line))
            }
            row = []
            field = ""
            fieldStarted = false
            rowStarted = false
            quoteClosed = false
        }

        func isNewline(_ character: Character) -> Bool {
            character == "\r\n" || character == "\r" || character == "\n"
        }

        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 2
                    } else {
                        inQuotes = false
                        quoteClosed = true
                        index += 1
                    }
                    continue
                }
                field.append(character)
                if isNewline(character) { line += 1 }
                index += 1
                continue
            }

            if quoteClosed {
                if character == "," {
                    endField()
                    rowStarted = true
                    index += 1
                    continue
                }
                if isNewline(character) {
                    endRow()
                    line += 1
                    rowStartLine = line
                    index += 1
                    continue
                }
                // RFC 4180 allows no content between a closing quote and the
                // next delimiter. Keep the value, but make the loss visible.
                addDiagnostic(.unexpectedQuote,
                              message: "После закрывающей кавычки ожидалась запятая или перевод строки.")
                field.append(character)
                fieldStarted = true
                quoteClosed = false
                index += 1
                continue
            }

            if character == "\"" {
                if fieldStarted {
                    addDiagnostic(.unexpectedQuote,
                                  message: "Кавычка внутри некавычного поля.")
                    field.append(character)
                } else {
                    inQuotes = true
                }
                fieldStarted = true
                rowStarted = true
                index += 1
                continue
            }
            if character == "," {
                endField()
                rowStarted = true
                index += 1
                continue
            }
            if isNewline(character) {
                if rowStarted || fieldStarted || !row.isEmpty { endRow() }
                line += 1
                rowStartLine = line
                index += 1
                continue
            }

            field.append(character)
            fieldStarted = true
            rowStarted = true
            index += 1
        }

        if inQuotes {
            addDiagnostic(.unterminatedQuote,
                          message: "Кавычка не закрыта до конца файла.")
        }
        if rowStarted || fieldStarted || !row.isEmpty { endRow() }
        return ParseResult(rows: rows, diagnostics: diagnostics, isValidUTF8: true)
    }
}

// MARK: - Модель импорта

/// Строка выгрузки. Besides the fields used by the importer, retain the
/// original row so a failed import can be exported without reconstructing it.
struct ImportedRow: Equatable, Hashable {
    var number: String
    var court: String
    var parties: String
    var urlString: String

    /// One-based physical line range in the source file. `nil` means the row
    /// was constructed by code rather than read from a CSV file.
    var sourceLineRange: ClosedRange<Int>?
    var originalHeader: [String]
    var originalFields: [String]

    init(number: String, court: String, parties: String, urlString: String,
         sourceLineRange: ClosedRange<Int>? = nil,
         originalHeader: [String] = [], originalFields: [String]? = nil) {
        self.number = number
        self.court = court
        self.parties = parties
        self.urlString = urlString
        self.sourceLineRange = sourceLineRange
        self.originalHeader = originalHeader.isEmpty
            ? ["number", "court", "parties", "url"] : originalHeader
        self.originalFields = originalFields ?? [number, court, parties, urlString]
    }

    var sourceLine: Int? { sourceLineRange?.lowerBound }
    var sourceLines: String {
        guard let sourceLineRange else { return "" }
        return sourceLineRange.lowerBound == sourceLineRange.upperBound
            ? "\(sourceLineRange.lowerBound)"
            : "\(sourceLineRange.lowerBound)–\(sourceLineRange.upperBound)"
    }

    /// Stable enough for one import batch; unlike `hashValue`, it is not
    /// randomized between processes and is therefore useful to group issues.
    var sourceIdentity: String {
        let range = sourceLineRange.map { "\($0.lowerBound):\($0.upperBound)" } ?? "-"
        return range + "\u{001F}" + originalFields.joined(separator: "\u{001E}")
    }
}

/// Разобранная строка: всё, что нужно, чтобы открыть карточку и собрать контекст.
struct ImportSeed {
    var row: ImportedRow
    var provider: ImportProvider
    var searchDomain: String    // модульная («--») форма хоста
    var displayDomain: String   // точечная форма (ключ записи)
    var branch: CourtBranch
    var level: CourtLevel
    var courtTitle: String      // без скобки региона
    var region: String          // регион из скобки («Республика Коми»)
    var courtCode: String?      // код субъекта (районные суды)
    var caseID: String
    var caseUID: String
    var deloID: String          // как в ссылке выгрузки (карточка по ней открывается)
    var new: String
    var isMaterial: Bool        // delo_id 1610001/1610002
    var cartoteka: Cartoteka?   // канонический вид производства (для якоря)

    /// Уровень «инстанции» карточки внутри чужого дела (для knownCards).
    var instanceLevel: CaseInstance.Level {
        if isMaterial { return .material }
        return MovementContext.instanceLevel(
            cartotekaID: cartoteka?.id ?? "", courtLevel: level)
    }
}

enum ImportProvider: Equatable {
    case sudrf
    case msudrf
    case mosgorsud
    case vsrf(VSRFCardSection)

    var sourceFamily: String {
        switch self {
        case .sudrf: return "sudrf"
        case .msudrf: return "msudrf"
        case .mosgorsud: return "mosgorsud"
        case .vsrf: return "vsrf"
        }
    }

    var isVSRF: Bool {
        if case .vsrf = self { return true }
        return false
    }
}

enum ImportRowOutcome {
    case seed(ImportSeed)
    case skipped(reason: String)
}

enum ImportIssueCategory: String, CaseIterable, Codable {
    case csvFormat = "csv_format"
    case unsupportedSource = "unsupported_source"
    case courtNotFound = "court_not_found"
    case firstInstanceNotFound = "first_instance_not_found"
    case missingUID = "missing_uid"
    case cardParsing = "card_parsing"
    case transientSource = "transient_source"
    case captcha = "captcha"
    case ambiguousFirstInstance = "ambiguous_first_instance"
    case cardLinkRecovered = "card_link_recovered"
    case ambiguousCardLink = "ambiguous_card_link"

    var displayName: String {
        switch self {
        case .csvFormat: return "формат CSV"
        case .unsupportedSource: return "неподдерживаемый источник"
        case .courtNotFound: return "суд не найден"
        case .firstInstanceNotFound: return "первая инстанция не найдена"
        case .missingUID: return "отсутствует УИД"
        case .cardParsing: return "разбор карточки"
        case .transientSource: return "временная ошибка источника"
        case .captcha: return "капча"
        case .ambiguousFirstInstance: return "неоднозначная первая инстанция"
        case .cardLinkRecovered: return "ссылка на карточку восстановлена"
        case .ambiguousCardLink: return "неоднозначная ссылка на карточку"
        }
    }
}

enum ImportIssueSeverity: String, Codable {
    case warning
    case error
}

/// One actionable detail in an import report. A detail can reference several
/// source rows when grouping by UID produced one logical case.
struct ImportIssue: Equatable, Identifiable {
    var category: ImportIssueCategory
    var reason: String
    var severity: ImportIssueSeverity
    var sourceRows: [ImportedRow]
    var caseNumber: String
    var court: String
    var key: String?
    private var explicitSourceLineRange: ClosedRange<Int>?

    init(category: ImportIssueCategory, reason: String,
         sourceRow: ImportedRow? = nil, sourceRows: [ImportedRow] = [],
         caseNumber: String? = nil, court: String? = nil,
         severity: ImportIssueSeverity = .error, key: String? = nil,
         sourceLineRange: ClosedRange<Int>? = nil) {
        self.category = category
        self.reason = reason
        self.severity = severity
        self.sourceRows = sourceRow.map { [$0] } ?? sourceRows
        let row = self.sourceRows.first
        self.caseNumber = caseNumber ?? row?.number ?? ""
        self.court = court ?? row?.court ?? ""
        self.key = key
        self.explicitSourceLineRange = sourceLineRange
    }

    init(sourceRow: ImportedRow, category: ImportIssueCategory, reason: String,
         severity: ImportIssueSeverity = .error, key: String? = nil) {
        self.init(category: category, reason: reason, sourceRow: sourceRow,
                  severity: severity, key: key)
    }

    var id: String {
        let rows = sourceRows.map(\.sourceIdentity).joined(separator: "|")
        return [category.rawValue, rows, caseNumber, court, reason].joined(separator: "\u{001F}")
    }

    var row: ImportedRow? { sourceRows.first }
    var sourceLineRange: ClosedRange<Int>? { row?.sourceLineRange ?? explicitSourceLineRange }
    var sourceLine: Int? { sourceLineRange?.lowerBound }
    var sourceLines: String {
        let rowLabels = sourceRows
            .compactMap { row -> (Int, String)? in
                guard let range = row.sourceLineRange else { return nil }
                let label = range.lowerBound == range.upperBound
                    ? "\(range.lowerBound)"
                    : "\(range.lowerBound)–\(range.upperBound)"
                return (range.lowerBound, label)
            }
            .sorted { $0.0 < $1.0 }
            .map(\.1)
        var seen = Set<String>()
        let uniqueLabels = rowLabels.filter { seen.insert($0).inserted }
        if !uniqueLabels.isEmpty { return uniqueLabels.joined(separator: ", ") }
        guard let explicitSourceLineRange else { return "" }
        return explicitSourceLineRange.lowerBound == explicitSourceLineRange.upperBound
            ? "\(explicitSourceLineRange.lowerBound)"
            : "\(explicitSourceLineRange.lowerBound)–\(explicitSourceLineRange.upperBound)"
    }
    var number: String { caseNumber }
    var type: ImportIssueCategory { category }
}

/// CSV input plus row-level diagnostics. `header` is always the original CSV
/// header (diagnostic columns produced by export are simply ignored by field
/// lookup), so exporting a report preserves the user's source schema.
struct ImportInput: Equatable {
    var header: [String]
    var rows: [ImportedRow]
    var issues: [ImportIssue]

    var totalRows: Int { rows.count }
    var report: ImportReport {
        ImportReport(header: header, totalRows: totalRows, issues: issues)
    }
}

/// User-facing details accumulated by AppModel while the batch progresses.
/// It intentionally has no persistence dependencies and can be unit-tested as
/// a pure value.
struct ImportReport: Equatable {
    var header: [String]
    var totalRows: Int
    var issues: [ImportIssue]
    var repairEvents: [CaseRepairEvent]

    init(header: [String] = [], totalRows: Int = 0,
         issues: [ImportIssue] = [], repairEvents: [CaseRepairEvent] = []) {
        self.header = header
        self.totalRows = totalRows
        self.issues = issues
        self.repairEvents = repairEvents
    }

    var hasIssues: Bool { !issues.isEmpty }
    var problemCount: Int { problematicRows.count }
    var problematicRows: [ImportedRow] {
        var seen = Set<String>()
        return issues.flatMap(\.sourceRows).filter { seen.insert($0.sourceIdentity).inserted }
    }
    var sourceRows: [ImportedRow] { problematicRows }

    mutating func append(_ issue: ImportIssue) { issues.append(issue) }
    mutating func append(_ event: CaseRepairEvent, sourceRows: [ImportedRow] = []) {
        repairEvents.append(event)
        if let issue = event.importIssue(sourceRows: sourceRows) { issues.append(issue) }
    }

    /// UTF-8 RFC 4180 report containing only rows referenced by issues.
    /// Multiple details for a row are folded into the two diagnostic columns.
    func exportCSV() -> String {
        let sourceHeader = (header.isEmpty ? problematicRows.first?.originalHeader : header)
            ?? ["number", "court", "parties", "url"]
        // The diagnostic names are not reserved in arbitrary source files.
        // Always retain the original schema verbatim; a re-export can prefix
        // another diagnostic triplet, but it must never discard user data.
        let outputHeader = ["source_lines", "error_category", "error_reason"] + sourceHeader
        var lines = [outputHeader.map(Self.escapeCSV).joined(separator: ",")]

        var grouped: [String: [ImportIssue]] = [:]
        for issue in issues {
            for row in issue.sourceRows { grouped[row.sourceIdentity, default: []].append(issue) }
        }
        let rows = problematicRows.sorted {
            ($0.sourceLineRange?.lowerBound ?? Int.max) < ($1.sourceLineRange?.lowerBound ?? Int.max)
        }
        for row in rows {
            let rowIssues = grouped[row.sourceIdentity] ?? []
            let categories = unique(rowIssues.map(\.category.rawValue)).joined(separator: ";")
            let reasons = unique(rowIssues.map(\.reason)).joined(separator: "; ")
            let fields: [String]
            if row.originalFields.isEmpty {
                fields = [row.number, row.court, row.parties, row.urlString]
            } else {
                fields = row.originalFields
            }
            lines.append(([row.sourceLines, categories, reasons] + fields).map(Self.escapeCSV).joined(separator: ","))
        }
        // CRLF is the interoperable line ending mandated by RFC 4180.
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    var csvData: Data { Data(exportCSV().utf8) }

    private static func escapeCSV(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

private extension CaseRepairEvent {
    func importIssue(sourceRows: [ImportedRow]) -> ImportIssue? {
        let category: ImportIssueCategory
        let severity: ImportIssueSeverity
        let reason: String
        switch kind {
        case .firstInstanceNotFound:
            category = .firstInstanceNotFound
            severity = .error
            reason = "Не удалось найти карточку первой инстанции."
        case .firstInstanceAmbiguous:
            category = .ambiguousFirstInstance
            severity = .error
            reason = "Найдено несколько возможных карточек первой инстанции."
        case .unsupportedCourt:
            category = .courtNotFound
            severity = .error
            reason = "Не удалось определить суд для ремонта цепочки."
        case .cardParsing:
            category = .cardParsing
            severity = .error
            reason = "Не удалось разобрать карточку суда."
        case .transient:
            category = .transientSource
            severity = .error
            reason = "Источник суда временно недоступен."
        case .captcha:
            category = .captcha
            severity = .warning
            reason = "Для продолжения ремонта требуется код с картинки."
        case .rerouted, .reanchored, .restoredMaterial, .merged:
            return nil
        }
        return ImportIssue(category: category, reason: reason, sourceRows: sourceRows,
                           caseNumber: newCaseNumber ?? oldCaseNumber,
                           court: newCourtTitle ?? oldCourtTitle,
                           severity: severity, key: caseKey)
    }
}

/// Итог импорта для сводки пользователю.
struct ImportSummary {
    var cases = 0                      // записей-дел (якорей)
    var materials = 0                  // записей-материалов (отдельных)
    var stitched = 0                   // карточек сшито в knownCards
    var cold = 0                       // карточка не загрузилась — импорт без сшивания
    var recoveredLinks = 0              // исправлен технический locator карточки
    var ambiguousLinks = 0              // несколько подтверждённых карточек
    var stitchedExisting = 0           // объединено с уже отслеживаемыми записями
    var recoveredDown = 0              // найдена и добавлена первая инстанция
    var rerouted = 0                   // исправлена процессуальная роль/маршрут КоАП
    var transient = 0                  // временные сетевые ошибки
    var parsing = 0                    // карточка ответила, но не разобрана
    var withoutUID = 0                 // в загруженной карточке нет настоящего УИД
    var ambiguous = 0                  // нижняя карточка не определена однозначно
    var unresolvedNumbers: [String] = []
    var skipped: [(reason: String, count: Int)] = []
    var total = 0                      // строк в CSV
    var report = ImportReport()

    var issues: [ImportIssue] { report.issues }
    var repairEvents: [CaseRepairEvent] { report.repairEvents }

    var text: String {
        var lines = ["Дел: \(cases), отдельных материалов: \(materials) (строк в файле: \(total))."]
        if stitched > 0 { lines.append("Сшито карточек вышестоящих инстанций и материалов: \(stitched).") }
        if stitchedExisting > 0 { lines.append("Объединено с уже сохранёнными делами: \(stitchedExisting).") }
        if recoveredDown > 0 { lines.append("Восстановлено карточек первой инстанции: \(recoveredDown).") }
        if rerouted > 0 { lines.append("Исправлено маршрутов КоАП: \(rerouted).") }
        if cold > 0 { lines.append("Без сшивания (карточка не загрузилась): \(cold).") }
        if recoveredLinks > 0 { lines.append("Восстановлено ссылок на карточки: \(recoveredLinks).") }
        if ambiguousLinks > 0 { lines.append("Неоднозначных ссылок на карточки: \(ambiguousLinks).") }
        if transient > 0 { lines.append("Временно недоступно, можно повторить импорт: \(transient).") }
        if parsing > 0 { lines.append("Не удалось разобрать ответ карточки: \(parsing).") }
        if withoutUID > 0 { lines.append("Карточек без опубликованного УИД: \(withoutUID).") }
        if ambiguous > 0 {
            lines.append("Не удалось однозначно связать с первой инстанцией: \(ambiguous).")
            lines.append(contentsOf: unresolvedNumbers.prefix(12).map { "• \($0)" })
        }
        for s in skipped { lines.append("Пропущено — \(s.reason): \(s.count).") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Импортёр

enum CaseImporter {

    // Причины пропуска (сгруппируются в сводке).
    static let reasonMagistrate    = "мировые судьи (msudrf.ru)"
    static let reasonMagistrateSpb = "мировые судьи СПб (mirsud.spb.ru)"
    static let reasonMosgorsud     = "Мосгорсуд (mos-gorsud.ru, другая платформа)"
    static let reasonPlatform      = "не платформа sudrf.ru"
    static let reasonBadURL        = "не разобрана ссылка на дело"

    /// Detailed CSV entry point used by the report-producing import flow.
    static func parseCSV(_ text: String) -> ImportInput {
        makeImportInput(CSVParser.parseDetailed(text))
    }

    /// Data entry point preserves invalid UTF-8 as a typed CSV issue.
    static func parseCSV(_ data: Data) -> ImportInput {
        makeImportInput(CSVParser.parseDetailed(data))
    }

    /// Converts legacy classify outcomes into typed report details.
    static func issue(for row: ImportedRow, skippedReason: String) -> ImportIssue {
        let category: ImportIssueCategory = skippedReason == reasonBadURL
            ? .csvFormat : .unsupportedSource
        return ImportIssue(sourceRow: row, category: category, reason: skippedReason)
    }

    /// Converts a fetch/parser failure without making the network layer know
    /// about report presentation.
    static func issue(for row: ImportedRow, error: Error) -> ImportIssue {
        let category: ImportIssueCategory
        switch error {
        case let error as SudrfError:
            switch error {
            case .captchaRequired:
                category = .captcha
            case .transientNetworkError, .sourceMaintenance, .searchModuleUnavailable,
                 .caseCardTemporarilyUnavailable:
                category = .transientSource
            case .http(let status) where status >= 500:
                category = .transientSource
            case .decodingFailed, .http, .parsing, .invalidValue, .unknownCartoteka:
                category = .cardParsing
            }
        default:
            category = .cardParsing
        }
        return ImportIssue(sourceRow: row, category: category,
                           reason: (error as? LocalizedError)?.errorDescription
                               ?? String(describing: error))
    }

    static func missingUIDIssue(for row: ImportedRow,
                                reason: String = "В карточке суда не опубликован УИД.") -> ImportIssue {
        ImportIssue(sourceRow: row, category: .missingUID, reason: reason,
                    severity: .warning)
    }

    private static func makeImportInput(_ parsed: CSVParser.ParseResult) -> ImportInput {
        guard let headerRow = parsed.rows.first else {
            let reason = parsed.isValidUTF8
                ? "CSV-файл пуст: отсутствует заголовок."
                : "CSV-файл не является корректным UTF-8."
            return ImportInput(header: [], rows: [], issues: [
                ImportIssue(category: .csvFormat, reason: reason)
            ])
        }

        let header = headerRow.fields
        let normalizedHeader = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func index(of name: String) -> Int? { normalizedHeader.firstIndex(of: name) }
        let iURL = index(of: "url")
        let iCourt = index(of: "court")
        let iNumber = index(of: "number")
        let iParties = index(of: "parties")
        var issues: [ImportIssue] = []

        if header.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            issues.append(ImportIssue(category: .csvFormat,
                                      reason: "CSV-файл содержит пустой заголовок.",
                                      sourceLineRange: headerRow.lineRange))
        }
        if iURL == nil {
            issues.append(ImportIssue(category: .csvFormat,
                                      reason: "В заголовке отсутствует обязательная колонка «url».",
                                      sourceLineRange: headerRow.lineRange))
        }
        if iCourt == nil {
            issues.append(ImportIssue(category: .csvFormat,
                                      reason: "В заголовке отсутствует обязательная колонка «court».",
                                      sourceLineRange: headerRow.lineRange))
        }

        var rows: [ImportedRow] = []
        for parsedRow in parsed.rows.dropFirst() {
            func at(_ index: Int?) -> String {
                guard let index, parsedRow.fields.indices.contains(index) else { return "" }
                return parsedRow.fields[index]
            }
            let row = ImportedRow(number: at(iNumber), court: at(iCourt),
                                  parties: at(iParties), urlString: at(iURL),
                                  sourceLineRange: parsedRow.lineRange,
                                  originalHeader: header,
                                  originalFields: parsedRow.fields)
            rows.append(row)

            if parsedRow.fields.count < header.count {
                issues.append(ImportIssue(sourceRow: row, category: .csvFormat,
                                          reason: "В строке меньше полей, чем в заголовке CSV."))
            }
            if let iURL, !parsedRow.fields.indices.contains(iURL) || at(iURL).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(ImportIssue(sourceRow: row, category: .csvFormat,
                                          reason: "В строке отсутствует обязательный URL."))
            }
        }

        for diagnostic in parsed.diagnostics {
            let sourceRow = rows.first { $0.sourceLineRange?.overlaps(diagnostic.lineRange) == true }
            issues.append(ImportIssue(category: .csvFormat, reason: diagnostic.message,
                                      sourceRow: sourceRow,
                                      sourceLineRange: sourceRow == nil ? diagnostic.lineRange : nil))
        }
        return ImportInput(header: header, rows: rows, issues: issues)
    }

    /// CSV → строки импорта. Порядок колонок фиксирован заголовком.
    static func rows(fromCSV text: String) -> [ImportedRow] {
        let input = parseCSV(text)
        let hasURL = input.header.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "url"
        }
        return hasURL ? input.rows : []
    }

    /// Строка выгрузки → seed либо причина пропуска.
    static func classify(_ row: ImportedRow) -> ImportRowOutcome {
        guard let url = URL(string: row.urlString), let host = url.host?.lowercased() else {
            return .skipped(reason: reasonBadURL)
        }
        if host.hasSuffix(".msudrf.ru") { return classifyMagistrate(row, url: url, host: host) }
        // У петербургских мировых судей собственный портал (не msudrf.ru).
        if host.hasSuffix("mirsud.spb.ru") { return .skipped(reason: reasonMagistrateSpb) }
        if ["mos-gorsud.ru", "www.mos-gorsud.ru"].contains(host) {
            return classifyMosGorSud(row, url: url)
        }
        if ["vsrf.ru", "www.vsrf.ru"].contains(host) {
            return classifyVSRF(row, url: url)
        }
        guard host.hasSuffix(".sudrf.ru") else {
            return .skipped(reason: host.contains("mos-gorsud") ? reasonMosgorsud : reasonPlatform)
        }
        guard let link = try? SudrfCaseCardLink(url: url) else {
            return .skipped(reason: reasonBadURL)
        }

        let searchDomain = link.moduleHost
        let displayDomain = SudrfHost.alternate(searchDomain) ?? searchDomain
        let (level, branch) = courtLevelAndBranch(forHost: searchDomain, courtTitle: row.court)

        // «Сыктывкарский городской суд (Республика Коми)» → название + регион.
        var courtTitle = row.court
        var region = ""
        if let open = row.court.range(of: " ("), row.court.hasSuffix(")") {
            courtTitle = String(row.court[..<open.lowerBound])
            region = String(row.court[open.upperBound...].dropLast())
        }

        var courtCode: String? = nil
        if level == .district, branch == .general,
           let suffix = CourtDirectory.regionSuffix(ofDomain: searchDomain) {
            courtCode = CourtDirectory.subjectCode(forRegionSuffix: suffix)
        }

        let isMaterial = link.deloID == "1610001" || link.deloID == "1610002"
        let cartoteka = CartotekaRegistry.resolve(
            level: level, deloID: link.deloID, new: link.new, caseNumber: row.number)

        return .seed(ImportSeed(
            row: row, provider: .sudrf,
            searchDomain: searchDomain, displayDomain: displayDomain,
            branch: branch, level: level, courtTitle: courtTitle, region: region,
            courtCode: courtCode, caseID: link.caseID ?? "", caseUID: link.caseUID ?? "",
            deloID: link.deloID, new: link.resolvedNew,
            isMaterial: isMaterial, cartoteka: cartoteka))
    }

    private static func classifyMagistrate(_ row: ImportedRow, url: URL,
                                            host: String) -> ImportRowOutcome {
        guard safeDirectURL(url, requireHTTPS: false),
              url.path.caseInsensitiveCompare("/modules.php") == .orderedSame,
              let name = uniqueParameter(["name"], in: url),
              name.caseInsensitiveCompare("sud_delo") == .orderedSame,
              let operation = uniqueParameter(["op"], in: url),
              operation.caseInsensitiveCompare("cs") == .orderedSame,
              let caseID = uniqueParameter(["case_id", "_id"], in: url),
              let deloID = uniqueParameter(["delo_id", "_deloid"], in: url) else {
            return .skipped(reason: reasonBadURL)
        }
        let new: String
        if hasParameter(["new", "_new"], in: url) {
            guard let value = uniqueParameter(["new", "_new"], in: url) else {
                return .skipped(reason: reasonBadURL)
            }
            new = value
        } else {
            new = "0"
        }
        let caseUID: String
        if hasParameter(["case_uid", "_uid"], in: url) {
            guard let value = uniqueParameter(["case_uid", "_uid"], in: url) else {
                return .skipped(reason: reasonBadURL)
            }
            caseUID = value
        } else {
            caseUID = ""
        }
        guard let cartoteka = CartotekaRegistry.resolve(
            level: .magistrate, deloID: deloID, new: new, caseNumber: row.number),
              let locator = SourceNativeCardLocator.msudrf(url: url, cartoteka: cartoteka),
              locator.sourceNativeID == caseID else {
            return .skipped(reason: reasonBadURL)
        }
        let (courtTitle, region) = splitCourtAndRegion(row.court)
        return .seed(ImportSeed(
            row: row, provider: .msudrf,
            searchDomain: host, displayDomain: host,
            branch: .general, level: .magistrate,
            courtTitle: courtTitle, region: region, courtCode: nil,
            caseID: caseID, caseUID: caseUID,
            deloID: deloID, new: new,
            isMaterial: deloID == "1610001" || deloID == "1610002",
            cartoteka: cartoteka))
    }

    private static func classifyMosGorSud(_ row: ImportedRow, url: URL) -> ImportRowOutcome {
        guard url.host?.lowercased() != nil, safeDirectURL(url, requireHTTPS: true) else {
            return .skipped(reason: reasonBadURL)
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        let alias: String
        let prefixCount: Int
        let level: CourtLevel
        let courtTitle: String
        let courtCode: String?
        if parts.first == "mgs" {
            alias = "mgs"; prefixCount = 1; level = .subject
            courtTitle = "Московский городской суд"; courtCode = nil
        } else if parts.count > 1, parts[0] == "rs",
                  let district = MosGorSudCourtDirectory.districtCourts.first(where: {
                      $0.alias == parts[1]
                  }) {
            alias = district.alias; prefixCount = 2; level = .district
            courtTitle = district.title; courtCode = district.code
        } else {
            return .skipped(reason: reasonBadURL)
        }
        guard parts.count == prefixCount + 5,
              parts[prefixCount] == "services", parts[prefixCount + 1] == "cases",
              parts[prefixCount + 3] == "details",
              parts.indices.contains(prefixCount + 2),
              !parts[prefixCount + 2].isEmpty,
              let cardID = parts.last, !cardID.isEmpty else {
            return .skipped(reason: reasonBadURL)
        }
        let section = parts[prefixCount + 2]

        let (providedTitle, _) = splitCourtAndRegion(row.court)
        if !providedTitle.isEmpty,
           !CaseOriginResolver.sameCourtTitle(providedTitle, courtTitle, region: "Город Москва") {
            return .skipped(reason: reasonBadURL)
        }
        let numberCartotekas = Set(CartotekaRegistry.matches(
            caseNumber: row.number, level: level).map(\.id))
        let candidates = CartotekaRegistry.sets(for: level).filter { cart in
            MosGorSudRouting.sectionSegments(cartoteka: cart).contains(section)
                && (row.number.isEmpty || numberCartotekas.contains(cart.id))
        }
        guard candidates.count == 1, let cartoteka = candidates.first,
              let locator = SourceNativeCardLocator.mosgorsud(url: url, cartoteka: cartoteka),
              locator.courtKey == alias else {
            return .skipped(reason: reasonBadURL)
        }
        return .seed(ImportSeed(
            row: row, provider: .mosgorsud,
            searchDomain: MosGorSudEndpoint.host, displayDomain: MosGorSudEndpoint.host,
            branch: .general, level: level, courtTitle: courtTitle,
            region: "Город Москва", courtCode: courtCode,
            caseID: cardID, caseUID: "", deloID: cartoteka.deloID,
            new: cartoteka.new, isMaterial: cartoteka.id == "m",
            cartoteka: cartoteka))
    }

    private static func classifyVSRF(_ row: ImportedRow, url: URL) -> ImportRowOutcome {
        guard let locator = SourceNativeCardLocator.vsrf(url: url),
              let section = VSRFCardSection(rawValue: url.pathComponents
                .filter { $0 != "/" }.dropFirst(2).first ?? "") else {
            return .skipped(reason: reasonBadURL)
        }
        let (providedTitle, _) = splitCourtAndRegion(row.court)
        if !providedTitle.isEmpty {
            let title = providedTitle.lowercased().replacingOccurrences(of: "ё", with: "е")
            guard title.contains("верховн"), title.contains("суд"),
                  title.contains("рф") || title.contains("российск") else {
                return .skipped(reason: reasonBadURL)
            }
        }
        return .seed(ImportSeed(
            row: row, provider: .vsrf(section),
            searchDomain: "vsrf.ru", displayDomain: "vsrf.ru",
            branch: .general, level: .cassation,
            courtTitle: "Верховный Суд РФ", region: "Российская Федерация",
            courtCode: nil, caseID: locator.sourceNativeID, caseUID: "",
            deloID: "", new: "0", isMaterial: false, cartoteka: nil))
    }

    private static func safeDirectURL(_ url: URL, requireHTTPS: Bool) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || (!requireHTTPS && scheme == "http"),
              url.user == nil, url.password == nil, url.port == nil else { return false }
        return true
    }

    private static func uniqueParameter(_ names: [String], in url: URL) -> String? {
        let aliases = Set(names.map { $0.lowercased() })
        let values = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .compactMap { item -> String? in
                guard aliases.contains(item.name.lowercased()) else { return nil }
                guard let value = item.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !value.isEmpty, value == item.value else { return nil }
                return value
            }
        guard let value = values.first, values.allSatisfy({ $0 == value }) else { return nil }
        return value
    }

    private static func hasParameter(_ names: [String], in url: URL) -> Bool {
        let aliases = Set(names.map { $0.lowercased() })
        return (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .contains { aliases.contains($0.name.lowercased()) }
    }

    private static func splitCourtAndRegion(_ value: String) -> (title: String, region: String) {
        guard let open = value.range(of: " ("), value.hasSuffix(")") else {
            return (value.trimmingCharacters(in: .whitespacesAndNewlines), "")
        }
        return (String(value[..<open.lowerBound]), String(value[open.upperBound...].dropLast()))
    }

    /// Звено и ветвь по домену (модульная форма) и названию суда. Гарнизонные
    /// военные суды живут на обычных sudrf-доменах, поэтому по одному хосту их
    /// не отличить от районных.
    static func courtLevelAndBranch(forHost host: String, courtTitle: String = "") -> (CourtLevel, CourtBranch) {
        let title = courtTitle.lowercased()
        if title.contains("гарнизон") && title.contains("воен") { return (.district, .military) }
        if host == "vkas.sudrf.ru" { return (.cassation, .military) }
        if host == "vap.sudrf.ru"  { return (.appeal, .military) }
        let dotForm = SudrfHost.alternate(host) ?? host
        if CourtDirectory.okrugMilitaryCourts.contains(where: { $0.domain == host || $0.domain == dotForm }) {
            return (.subject, .military)
        }
        if host.range(of: #"^\d+kas\.sudrf\.ru$"#, options: .regularExpression) != nil {
            return (.cassation, .general)
        }
        if host.range(of: #"^\d+ap\.sudrf\.ru$"#, options: .regularExpression) != nil {
            return (.appeal, .general)
        }
        if CourtDirectory.subjectCourts.contains(where: { $0.domain == host || $0.domain == dotForm }) {
            return (.subject, .general)
        }
        return (.district, .general)
    }

    // MARK: Группировка по УИД

    /// Карточка после сетевого этапа: seed + карточка (nil — не загрузилась).
    struct Fetched {
        var seed: ImportSeed
        var card: CaseCard?
        /// The original Supreme Court card response is transient import evidence.
        /// Its exact production IDs may prove a case/complaint relation; a UID
        /// alone never does.
        var vsrfCard: VSRFCard? = nil
        var higherCourtTargets: [MovementSearchTarget]? = nil
        /// A card resolver may correct only the published card locator.  The
        /// original context remains available until the batch commits so its
        /// source identity is retained in the logical dossier.
        var resolvedContext: MovementContext? = nil
        var originalContext: MovementContext? = nil
        var sourceAttempt: SourceAttempt? = nil
        var wasRecovered = false
        /// Usually one row; grouped imports may carry more than one.
        var sourceRows: [ImportedRow]

        init(seed: ImportSeed, card: CaseCard?,
             higherCourtTargets: [MovementSearchTarget]? = nil,
             sourceRows: [ImportedRow]? = nil,
             resolvedContext: MovementContext? = nil,
             originalContext: MovementContext? = nil,
             sourceAttempt: SourceAttempt? = nil,
             wasRecovered: Bool = false,
             vsrfCard: VSRFCard? = nil) {
            self.seed = seed
            self.card = card
            self.vsrfCard = vsrfCard
            self.higherCourtTargets = higherCourtTargets
            self.sourceRows = sourceRows ?? [seed.row]
            self.resolvedContext = resolvedContext
            self.originalContext = originalContext
            self.sourceAttempt = sourceAttempt
            self.wasRecovered = wasRecovered
        }

        var sourceRow: ImportedRow? { sourceRows.first }
        var provenance: [ImportedRow] { sourceRows }

        var instanceLevel: CaseInstance.Level {
            if seed.provider.isVSRF {
                return CaseImporter.verifiedVSRFProduction(for: self)?.resolvedInstanceLevel
                    ?? .vsCassation
            }
            if seed.isMaterial { return .material }
            return MovementContext.instanceLevel(
                cartotekaID: seed.cartoteka?.id ?? "", courtLevel: seed.level,
                judicialUID: card?.uid,
                lowerCourtTitle: card?.lowerCourt?.courtTitle)
        }

        /// Ранг вычисляется после загрузки карточки: только тогда районный
        /// admj можно надёжно разделить на MS-апелляцию и RS-якорь.
        var anchorRank: Int {
            if seed.isMaterial { return 100 }
            switch instanceLevel {
            case .first: return seed.level == .magistrate ? -10 : 0
            case .appeal: return 20
            case .cassation: return 30
            case .vsCassation, .supervisory: return 40
            case .material: return 100
            }
        }
    }

    /// Готовая к записи единица импорта.
    struct PlannedRecord {
        /// Transient proof from one fetched official VSRF card. The persisted
        /// graph receives this exact pair at commit; a URL retained in
        /// `knownCards` by itself never creates an identity relation.
        struct ProvenVSRFRelation {
            let sourceCard: SourceNativeCardIdentity
            let relatedCard: SourceNativeCardIdentity
        }

        struct RecoveredSource {
            var originalContext: MovementContext
            var verifiedContext: MovementContext
            var sourceAttempt: SourceAttempt
        }

        var context: MovementContext
        var isMaterial: Bool
        /// The pre-recovery locator is only used while committing this batch.
        /// It lets the identity graph remember a corrected historical card
        /// without leaving its stale URL among active known cards.
        var originalContext: MovementContext? = nil
        var sourceAttempt: SourceAttempt? = nil
        var provenVSRFRelation: ProvenVSRFRelation? = nil
        /// Recovered non-anchor cards of a UID group. Their active URLs live
        /// in `knownCards`; this transient list carries their old locators and
        /// source observations into the same atomic store commit.
        var recoveredSources: [RecoveredSource] = []
        /// Original CSV rows represented by this logical record. This is
        /// transient provenance and is not persisted in MovementContext.
        var sourceRows: [ImportedRow]

        init(context: MovementContext, isMaterial: Bool,
             sourceRows: [ImportedRow] = [],
             originalContext: MovementContext? = nil,
             sourceAttempt: SourceAttempt? = nil,
             provenVSRFRelation: ProvenVSRFRelation? = nil,
             recoveredSources: [RecoveredSource] = []) {
            self.context = context
            self.isMaterial = isMaterial
            self.sourceRows = sourceRows
            self.originalContext = originalContext
            self.sourceAttempt = sourceAttempt
            self.provenVSRFRelation = provenVSRFRelation
            self.recoveredSources = recoveredSources
        }

        var sourceRow: ImportedRow? { sourceRows.first }
        var provenance: [ImportedRow] { sourceRows }
    }

    struct Plan {
        var records: [PlannedRecord] = []
        var stitched = 0
        var cold = 0
        var recoveredLinks = 0
    }

    /// Сшивание: группировка по УИД, выбор якоря, knownCards для остальных.
    static func plan(_ fetched: [Fetched]) -> Plan {
        var plan = Plan()
        var groups: [String: [Fetched]] = [:]
        var loners: [Fetched] = []
        let sudrfFetched = fetched.filter { !$0.seed.provider.isVSRF }
        let vsrfFetched = fetched.filter { $0.seed.provider.isVSRF }
        for f in sudrfFetched {
            if let uid = f.card?.uid, !uid.isEmpty {
                groups[TrackedStore.normalizedUID(uid), default: []].append(f)
            } else {
                loners.append(f)
                if f.card == nil { plan.cold += 1 }
            }
        }
        let vsrf = planVSRF(vsrfFetched)
        plan.records.append(contentsOf: vsrf.records)
        plan.stitched += vsrf.stitched
        plan.cold += vsrf.cold
        for f in loners {
            plan.records.append(plannedRecord(f, known: []))
            if f.wasRecovered { plan.recoveredLinks += 1 }
        }
        for (_, members) in groups.sorted(by: { $0.key < $1.key }) {
            let sorted = members.sorted { $0.anchorRank < $1.anchorRank }
            guard let anchor = sorted.first else { continue }
            if anchor.seed.isMaterial {
                // Группа из одних материалов — дела в выгрузке нет; каждый
                // материал остаётся самостоятельной записью.
                for f in sorted {
                    plan.records.append(plannedRecord(f, known: []))
                    if f.wasRecovered { plan.recoveredLinks += 1 }
                }
                continue
            }
            let known = sorted.dropFirst().map(knownCard)
            plan.stitched += known.count
            var planned = plannedRecord(anchor, known: known)
            planned.sourceRows = uniqueSourceRows(sorted.flatMap(\.sourceRows))
            planned.recoveredSources = sorted.dropFirst().compactMap { member in
                guard member.wasRecovered,
                      let originalContext = member.originalContext,
                      let verifiedContext = member.resolvedContext,
                      let sourceAttempt = member.sourceAttempt else { return nil }
                return PlannedRecord.RecoveredSource(
                    originalContext: originalContext, verifiedContext: verifiedContext,
                    sourceAttempt: sourceAttempt)
            }
            plan.records.append(planned)
            plan.recoveredLinks += sorted.filter(\.wasRecovered).count
        }
        return plan
    }

    /// Supreme Court production UIDs are not case/complaint links. Keep each
    /// exact production standalone unless one fetched official card names the
    /// precise case ID and complaint ID together, with one unambiguous pair.
    private static func planVSRF(_ fetched: [Fetched]) -> (records: [PlannedRecord], stitched: Int, cold: Int) {
        var byID: [String: [Fetched]] = [:]
        var unlocated: [Fetched] = []
        for item in fetched {
            guard let url = URL(string: item.seed.row.urlString),
                  let locator = SourceNativeCardLocator.vsrf(url: url) else {
                unlocated.append(item)
                continue
            }
            byID[locator.id, default: []].append(item)
        }

        var uniqueByID: [String: Fetched] = [:]
        for (id, copies) in byID {
            let preferred = copies.first(where: { $0.card != nil }) ?? copies[0]
            var merged = preferred
            merged.sourceRows = uniqueSourceRows(copies.flatMap(\.sourceRows))
            if merged.vsrfCard == nil {
                merged.vsrfCard = copies.compactMap(\.vsrfCard).first
            }
            uniqueByID[id] = merged
        }

        struct Pair: Hashable {
            let caseID: String
            let complaintID: String
        }
        func locatorID(for production: VSRFProduction) -> String? {
            guard let url = production.cardURL,
                  let locator = SourceNativeCardLocator.vsrf(url: url) else { return nil }
            return locator.id
        }

        var proposedPairs = Set<Pair>()
        for item in uniqueByID.values {
            guard let card = item.vsrfCard else { continue }
            guard let pair = exactVSRFCaseComplaintPair(in: card),
                  uniqueByID[pair.caseLocator.id] != nil,
                  uniqueByID[pair.complaintLocator.id] != nil else { continue }
            proposedPairs.insert(Pair(caseID: pair.caseLocator.id,
                                      complaintID: pair.complaintLocator.id))
        }

        var degree: [String: Int] = [:]
        for pair in proposedPairs {
            degree[pair.caseID, default: 0] += 1
            degree[pair.complaintID, default: 0] += 1
        }

        var pairedIDs = Set<String>()
        var records: [PlannedRecord] = []
        var stitched = 0
        for pair in proposedPairs.sorted(by: {
            ($0.caseID, $0.complaintID) < ($1.caseID, $1.complaintID)
        }) {
            guard degree[pair.caseID] == 1, degree[pair.complaintID] == 1,
                  let first = uniqueByID[pair.caseID], let second = uniqueByID[pair.complaintID],
                  let caseFetched = [first, second].first(where: {
                      $0.vsrfCard?.productions.contains {
                          $0.kind == .caseFile && locatorID(for: $0) == pair.caseID
                      } == true
                  }), caseFetched.seed.provider.isVSRF else { continue }
            var anchor = caseFetched
            anchor.sourceRows = uniqueSourceRows(first.sourceRows + second.sourceRows)
            records.append(plannedRecord(anchor, known: []))
            pairedIDs.formUnion([pair.caseID, pair.complaintID])
            stitched += 1
        }

        for (id, item) in uniqueByID.sorted(by: { $0.key < $1.key })
            where !pairedIDs.contains(id) {
            records.append(plannedRecord(item, known: []))
        }
        for item in unlocated {
            records.append(plannedRecord(item, known: []))
        }
        let cold = fetched.filter { $0.card == nil }.count
        return (records, stitched, cold)
    }

    private static func uniqueSourceRows(_ rows: [ImportedRow]) -> [ImportedRow] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.sourceIdentity).inserted }
    }

    private static func plannedRecord(_ fetched: Fetched, known: [KnownCard]) -> PlannedRecord {
        PlannedRecord(context: makeContext(fetched, known: known),
                      isMaterial: fetched.seed.isMaterial,
                      sourceRows: fetched.sourceRows,
                      originalContext: fetched.wasRecovered ? fetched.originalContext : nil,
                      sourceAttempt: fetched.sourceAttempt,
                      provenVSRFRelation: fetched.sourceAttempt?.kind == .usableSnapshot
                        ? provenVSRFRelation(for: fetched) : nil)
    }

    /// Контекст записи «Моих дел» из карточки-якоря.
    static func makeContext(_ f: Fetched, known: [KnownCard]) -> MovementContext {
        if var resolved = f.resolvedContext {
            if !known.isEmpty { resolved.knownCards = known }
            resolved.baseInstanceLevelRaw = f.instanceLevel.rawValue
            resolved.higherCourtTargets = f.higherCourtTargets ?? resolved.cartoteka.flatMap {
                MovementTargetBuilder.targets(
                    branch: resolved.branch, courtLevel: resolved.courtLevel,
                    baseCartoteka: $0, caseNumber: resolved.caseNumber,
                    judicialUID: f.card?.uid ?? resolved.judicialUID,
                    courtTitle: resolved.courtTitle, courtCode: resolved.courtCode,
                    region: resolved.region, displayDomain: resolved.displayDomain)
            }
            return resolved
        }
        let seed = f.seed
        let number = f.card?.caseNumber ?? seed.row.number
        if seed.provider.isVSRF {
            let production = verifiedVSRFProduction(for: f)
            var pairedCards = known
            if let pair = provenVSRFPair(for: f),
               let counterpartCard = knownVSRFCard(pair.counterpartProduction) {
                pairedCards.append(counterpartCard)
            }
            var context = MovementContext(
                branchRaw: CourtBranch.general.rawValue,
                region: "Российская Федерация",
                searchDomain: "vsrf.ru",
                displayDomain: "vsrf.ru",
                courtTitle: "Верховный Суд РФ",
                courtLevelRaw: CourtLevel.cassation.rawValue,
                courtCode: nil,
                cartotekaId: "",
                cartotekaLevelRaw: CourtLevel.cassation.rawValue,
                caseNumber: number.isEmpty ? "—" : number,
                caseID: nil,
                caseUID: nil,
                essence: seed.row.parties.isEmpty ? nil : seed.row.parties,
                judge: f.card?.judge,
                receiptDate: f.card?.receiptDate,
                decisionDate: f.card?.decisionDate,
                resultText: f.card?.result,
                legalForceDate: nil,
                cardURLString: seed.row.urlString)
            // A Supreme Court UID is a search field, not sufficient proof that
            // two separately imported source productions are the same record.
            context.judicialUID = nil
            context.baseInstanceLevelRaw = production?.resolvedInstanceLevel.rawValue
                ?? CaseInstance.Level.vsCassation.rawValue
            if !pairedCards.isEmpty { context.knownCards = uniqueVSRFKnownCards(pairedCards) }
            return context
        }
        // Стороны из карточки авторитетнее выгрузки; формат выгрузки «X ⚔ Y»
        // остаётся читаемым в списке до загрузки движения (поле essence).
        let essence = seed.row.parties.isEmpty ? nil : seed.row.parties
        var ctx = MovementContext(
            branchRaw: seed.branch.rawValue,
            region: seed.region,
            searchDomain: seed.searchDomain,
            displayDomain: seed.displayDomain,
            courtTitle: seed.courtTitle,
            courtLevelRaw: seed.level.rawValue,
            courtCode: seed.courtCode,
            cartotekaId: seed.cartoteka?.id ?? "",
            cartotekaLevelRaw: seed.level.rawValue,
            caseNumber: number.isEmpty ? "—" : number,
            caseID: seed.caseID,
            caseUID: seed.caseUID,
            essence: essence,
            judge: f.card?.judge,
            receiptDate: f.card?.receiptDate,
            decisionDate: f.card?.decisionDate,
            resultText: f.card?.result,
            legalForceDate: nil,
            cardURLString: seed.row.urlString)
        ctx.judicialUID = seed.provider.isVSRF ? nil : f.card?.uid
        ctx.baseInstanceLevelRaw = f.instanceLevel.rawValue
        if seed.provider == .sudrf && (!seed.caseID.isEmpty || !seed.caseUID.isEmpty) {
            ctx.sourceKnownCard = knownCard(f)
        }
        if !known.isEmpty { ctx.knownCards = known }
        ctx.higherCourtTargets = f.higherCourtTargets ?? seed.cartoteka.flatMap {
            MovementTargetBuilder.targets(
                branch: seed.branch, courtLevel: seed.level, baseCartoteka: $0,
                caseNumber: number, judicialUID: f.card?.uid,
                courtTitle: seed.courtTitle, courtCode: seed.courtCode,
                region: seed.region, displayDomain: seed.displayDomain)
        }
        return ctx
    }

    /// Не-якорная карточка группы → прямая ссылка для MovementService.
    static func knownCard(_ f: Fetched) -> KnownCard {
        if let resolved = f.resolvedContext?.sourceKnownCard { return resolved }
        let seed = f.seed
        return KnownCard(domain: seed.searchDomain,
                         courtTitle: seed.courtTitle,
                         caseID: seed.caseID,
                         caseUID: seed.caseUID,
                         deloID: seed.deloID,
                         new: seed.new,
                         caseNumber: f.card?.caseNumber ?? (seed.row.number.isEmpty ? nil : seed.row.number),
                         levelRaw: f.instanceLevel.rawValue,
                         cartotekaID: seed.cartoteka?.id,
                         sourceURL: URL(string: seed.row.urlString))
    }

    private struct VSRFCaseComplaintPair {
        let caseProduction: VSRFProduction
        let caseLocator: SourceNativeCardLocator
        let complaintProduction: VSRFProduction
        let complaintLocator: SourceNativeCardLocator
    }

    private struct VerifiedVSRFPair {
        let sourceProduction: VSRFProduction
        let sourceLocator: SourceNativeCardLocator
        let counterpartProduction: VSRFProduction
        let counterpartLocator: SourceNativeCardLocator
    }

    /// Only a one-case/one-complaint pair with exact, host-validated native
    /// card locators can be carried into the persisted identity graph.
    private static func exactVSRFCaseComplaintPair(
        in card: VSRFCard
    ) -> VSRFCaseComplaintPair? {
        let cases = card.productions.filter { $0.kind == .caseFile }
        let complaints = card.productions.filter { $0.kind == .complaint }
        guard cases.count == 1, complaints.count == 1,
              let caseURL = cases[0].cardURL,
              let caseLocator = SourceNativeCardLocator.vsrf(url: caseURL),
              let complaintURL = complaints[0].cardURL,
              let complaintLocator = SourceNativeCardLocator.vsrf(url: complaintURL),
              caseLocator.identity != complaintLocator.identity else { return nil }
        return VSRFCaseComplaintPair(
            caseProduction: cases[0], caseLocator: caseLocator,
            complaintProduction: complaints[0], complaintLocator: complaintLocator)
    }

    private static func provenVSRFPair(for fetched: Fetched) -> VerifiedVSRFPair? {
        guard let source = verifiedVSRFProduction(for: fetched),
              let sourceURL = source.cardURL,
              let sourceLocator = SourceNativeCardLocator.vsrf(url: sourceURL),
              let pair = fetched.vsrfCard.flatMap(exactVSRFCaseComplaintPair(in:)) else {
            return nil
        }
        if sourceLocator.identity == pair.caseLocator.identity {
            return VerifiedVSRFPair(
                sourceProduction: source, sourceLocator: sourceLocator,
                counterpartProduction: pair.complaintProduction,
                counterpartLocator: pair.complaintLocator)
        }
        if sourceLocator.identity == pair.complaintLocator.identity {
            return VerifiedVSRFPair(
                sourceProduction: source, sourceLocator: sourceLocator,
                counterpartProduction: pair.caseProduction,
                counterpartLocator: pair.caseLocator)
        }
        return nil
    }

    private static func provenVSRFRelation(
        for fetched: Fetched
    ) -> PlannedRecord.ProvenVSRFRelation? {
        guard let pair = provenVSRFPair(for: fetched) else { return nil }
        return PlannedRecord.ProvenVSRFRelation(
            sourceCard: pair.sourceLocator.identity,
            relatedCard: pair.counterpartLocator.identity)
    }

    private static func verifiedVSRFProduction(for fetched: Fetched) -> VSRFProduction? {
        guard case .vsrf(let section) = fetched.seed.provider,
              let sourceURL = URL(string: fetched.seed.row.urlString),
              let expected = SourceNativeCardLocator.vsrf(url: sourceURL),
              expected.cartotekaKey == section.rawValue,
              let card = fetched.vsrfCard,
              let importedNumber = fetched.card?.caseNumber?.trimmingCharacters(
                in: .whitespacesAndNewlines), !importedNumber.isEmpty else { return nil }
        let matches = card.productions.filter { production in
            guard production.cardID == expected.sourceNativeID,
                  production.resolvedSection == section,
                  let cardURL = production.cardURL,
                  let locator = SourceNativeCardLocator.vsrf(url: cardURL),
                  let publishedNumber = production.number?.trimmingCharacters(
                    in: .whitespacesAndNewlines) else { return false }
            return locator.identity == expected.identity
                && normalizedVSRFNumber(importedNumber) == normalizedVSRFNumber(publishedNumber)
                && (fetched.seed.row.number.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || normalizedVSRFNumber(fetched.seed.row.number)
                        == normalizedVSRFNumber(publishedNumber))
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private static func normalizedVSRFNumber(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "Ё", with: "Е")
            .lowercased()
    }

    private static func knownVSRFCard(_ production: VSRFProduction) -> KnownCard? {
        guard let url = production.cardURL,
              let locator = SourceNativeCardLocator.vsrf(url: url),
              let number = production.number, !number.isEmpty else { return nil }
        return KnownCard(domain: "vsrf.ru", courtTitle: "Верховный Суд РФ",
                         caseID: locator.sourceNativeID, caseUID: "",
                         deloID: "", new: "0", caseNumber: number,
                         levelRaw: production.resolvedInstanceLevel.rawValue,
                         sourceURL: url)
    }

    private static func uniqueVSRFKnownCards(_ cards: [KnownCard]) -> [KnownCard] {
        var seen = Set<SourceNativeCardIdentity>()
        return cards.filter { card in
            guard let url = card.sourceURL,
                  let locator = SourceNativeCardLocator.vsrf(url: url) else { return true }
            return seen.insert(locator.identity).inserted
        }
    }

}
