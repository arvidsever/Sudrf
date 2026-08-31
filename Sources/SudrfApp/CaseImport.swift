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
        if SudrfHost.isMSudrfHost(host) { return .skipped(reason: reasonMagistrate) }
        // У петербургских мировых судей собственный портал (не msudrf.ru).
        if host.hasSuffix("mirsud.spb.ru") { return .skipped(reason: reasonMagistrateSpb) }
        if host.contains("mos-gorsud") { return .skipped(reason: reasonMosgorsud) }
        guard host.hasSuffix("sudrf.ru") else { return .skipped(reason: reasonPlatform) }

        var params: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            params[item.name] = item.value
        }
        guard let caseID = params["case_id"], !caseID.isEmpty,
              let caseUID = params["case_uid"], !caseUID.isEmpty,
              let deloID = params["delo_id"], !deloID.isEmpty else {
            return .skipped(reason: reasonBadURL)
        }
        let newParam = params["new"]

        let searchDomain = SudrfHost.moduleHost(host)
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

        let isMaterial = deloID == "1610001" || deloID == "1610002"
        let cartoteka = CartotekaRegistry.resolve(
            level: level, deloID: deloID, new: newParam, caseNumber: row.number)

        return .seed(ImportSeed(
            row: row, searchDomain: searchDomain, displayDomain: displayDomain,
            branch: branch, level: level, courtTitle: courtTitle, region: region,
            courtCode: courtCode, caseID: caseID, caseUID: caseUID,
            deloID: deloID, new: newParam ?? "0",
            isMaterial: isMaterial, cartoteka: cartoteka))
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
        var higherCourtTargets: [MovementSearchTarget]? = nil
        /// Usually one row; grouped imports may carry more than one.
        var sourceRows: [ImportedRow]

        init(seed: ImportSeed, card: CaseCard?,
             higherCourtTargets: [MovementSearchTarget]? = nil,
             sourceRows: [ImportedRow]? = nil) {
            self.seed = seed
            self.card = card
            self.higherCourtTargets = higherCourtTargets
            self.sourceRows = sourceRows ?? [seed.row]
        }

        var sourceRow: ImportedRow? { sourceRows.first }
        var provenance: [ImportedRow] { sourceRows }

        var instanceLevel: CaseInstance.Level {
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
        var context: MovementContext
        var isMaterial: Bool
        /// Original CSV rows represented by this logical record. This is
        /// transient provenance and is not persisted in MovementContext.
        var sourceRows: [ImportedRow]

        init(context: MovementContext, isMaterial: Bool,
             sourceRows: [ImportedRow] = []) {
            self.context = context
            self.isMaterial = isMaterial
            self.sourceRows = sourceRows
        }

        var sourceRow: ImportedRow? { sourceRows.first }
        var provenance: [ImportedRow] { sourceRows }
    }

    struct Plan {
        var records: [PlannedRecord] = []
        var stitched = 0
        var cold = 0
    }

    /// Сшивание: группировка по УИД, выбор якоря, knownCards для остальных.
    static func plan(_ fetched: [Fetched]) -> Plan {
        var plan = Plan()
        var groups: [String: [Fetched]] = [:]
        var loners: [Fetched] = []
        for f in fetched {
            if let uid = f.card?.uid, !uid.isEmpty {
                groups[TrackedStore.normalizedUID(uid), default: []].append(f)
            } else {
                loners.append(f)
                if f.card == nil { plan.cold += 1 }
            }
        }
        for f in loners {
            plan.records.append(PlannedRecord(context: makeContext(f, known: []),
                                              isMaterial: f.seed.isMaterial,
                                              sourceRows: f.sourceRows))
        }
        for (_, members) in groups.sorted(by: { $0.key < $1.key }) {
            let sorted = members.sorted { $0.anchorRank < $1.anchorRank }
            guard let anchor = sorted.first else { continue }
            if anchor.seed.isMaterial {
                // Группа из одних материалов — дела в выгрузке нет; каждый
                // материал остаётся самостоятельной записью.
                for f in sorted {
                    plan.records.append(PlannedRecord(context: makeContext(f, known: []),
                                                      isMaterial: true,
                                                      sourceRows: f.sourceRows))
                }
                continue
            }
            let known = sorted.dropFirst().map(knownCard)
            plan.stitched += known.count
            plan.records.append(PlannedRecord(context: makeContext(anchor, known: known),
                                              isMaterial: false,
                                              sourceRows: uniqueSourceRows(sorted.flatMap(\.sourceRows))))
        }
        return plan
    }

    private static func uniqueSourceRows(_ rows: [ImportedRow]) -> [ImportedRow] {
        var seen = Set<String>()
        return rows.filter { seen.insert($0.sourceIdentity).inserted }
    }

    /// Контекст записи «Моих дел» из карточки-якоря.
    static func makeContext(_ f: Fetched, known: [KnownCard]) -> MovementContext {
        let seed = f.seed
        let number = f.card?.caseNumber ?? seed.row.number
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
        ctx.judicialUID = f.card?.uid
        ctx.baseInstanceLevelRaw = f.instanceLevel.rawValue
        if !seed.caseID.isEmpty, !seed.caseUID.isEmpty { ctx.sourceKnownCard = knownCard(f) }
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
        let seed = f.seed
        return KnownCard(domain: seed.searchDomain,
                         courtTitle: seed.courtTitle,
                         caseID: seed.caseID,
                         caseUID: seed.caseUID,
                         deloID: seed.deloID,
                         new: seed.new,
                         caseNumber: f.card?.caseNumber ?? (seed.row.number.isEmpty ? nil : seed.row.number),
                         levelRaw: f.instanceLevel.rawValue,
                         cartotekaID: seed.cartoteka?.id)
    }

}
