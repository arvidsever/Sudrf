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
    /// Разбор CSV: кавычки, экранированные кавычки («""»), запятые и переводы
    /// строк внутри полей. BOM отбрасывается.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var i = text.startIndex
        if text.hasPrefix("\u{FEFF}") { i = text.index(after: i) }
        func endField() { row.append(field); field = "" }
        func endRow() {
            endField()
            // Полностью пустые строки (артефакт трейлинг-переводов) не включаем.
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }
        while i < text.endIndex {
            let c = text[i]
            if inQuotes {
                if c == "\"" {
                    let next = text.index(after: i)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\""); i = next
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"" where field.isEmpty: inQuotes = true
                case ",":  endField()
                // ВАЖНО: «\r\n» в Swift — ОДИН Character (грефемный кластер CRLF),
                // поэтому перечисляется отдельным кейсом наравне с одиночными.
                case "\r\n", "\r", "\n": endRow()
                default:   field.append(c)
                }
            }
            i = text.index(after: i)
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}

// MARK: - Модель импорта

/// Строка выгрузки (значимые для импорта поля).
struct ImportedRow: Equatable {
    var number: String
    var court: String
    var parties: String
    var urlString: String
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
        // Картотеки 1-й инстанции (u1/g1/p1/adm/admj) — .first независимо от
        // звена: дело субъекта по 1-й инстанции — не «апелляция».
        if let id = cartoteka?.id {
            if id.hasSuffix("1") || id == "adm" || id == "admj" { return .first }
            if id.hasSuffix("3") || id.hasSuffix("33") { return .cassation }
            if id.hasSuffix("2") { return .appeal }
        }
        switch level {
        case .magistrate:return .first
        case .district:  return .first
        case .subject:   return .appeal
        case .appeal:    return .appeal
        case .cassation: return .cassation
        }
    }

    /// Ранг якоря: чем меньше, тем «базовее» карточка. Материалы якорем не
    /// становятся (кроме групп, где дел нет вовсе).
    var anchorRank: Int {
        if isMaterial { return 100 }
        let levelRank: Int
        switch level {
        case .magistrate:levelRank = -1
        case .district:  levelRank = 0
        case .subject:   levelRank = 1
        case .appeal:    levelRank = 2
        case .cassation: levelRank = 3
        }
        let firstInstance = (cartoteka?.new ?? new) == "0" ? 0 : 1
        return levelRank * 10 + firstInstance
    }
}

enum ImportRowOutcome {
    case seed(ImportSeed)
    case skipped(reason: String)
}

/// Итог импорта для сводки пользователю.
struct ImportSummary {
    var cases = 0                      // записей-дел (якорей)
    var materials = 0                  // записей-материалов (отдельных)
    var stitched = 0                   // карточек сшито в knownCards
    var cold = 0                       // карточка не загрузилась — импорт без сшивания
    var skipped: [(reason: String, count: Int)] = []
    var total = 0                      // строк в CSV

    var text: String {
        var lines = ["Дел: \(cases), отдельных материалов: \(materials) (строк в файле: \(total))."]
        if stitched > 0 { lines.append("Сшито карточек вышестоящих инстанций и материалов: \(stitched).") }
        if cold > 0 { lines.append("Без сшивания (карточка не загрузилась): \(cold).") }
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

    /// CSV → строки импорта. Порядок колонок фиксирован заголовком.
    static func rows(fromCSV text: String) -> [ImportedRow] {
        let table = CSVParser.parse(text)
        guard let header = table.first else { return [] }
        func idx(_ name: String) -> Int? { header.firstIndex(of: name) }
        guard let iURL = idx("url") else { return [] }
        let iNum = idx("number"), iCourt = idx("court"), iParties = idx("parties")
        return table.dropFirst().map { r in
            func at(_ i: Int?) -> String { i.flatMap { r.indices.contains($0) ? r[$0] : nil } ?? "" }
            return ImportedRow(number: at(iNum), court: at(iCourt),
                               parties: at(iParties), urlString: at(iURL))
        }
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
        let cartoteka = resolveCartoteka(level: level, deloID: deloID, new: newParam,
                                         caseNumber: row.number)

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

    /// Каноническая картотека по параметрам ссылки. Ссылки выгрузки не всегда
    /// несут канонический delo_id (у КСОЮ карточка открыта как delo_id=2450001,
    /// хотя каноническая пара картотеки — 4&new=2450001), поэтому порядок:
    /// точная пара → по new (некороткому) → по delo_id → по индексу № дела.
    static func resolveCartoteka(level: CourtLevel, deloID: String, new: String?,
                                 caseNumber: String) -> Cartoteka? {
        let sets = CartotekaRegistry.sets(for: level)
        if let c = sets.first(where: { $0.deloID == deloID && $0.new == (new ?? "0") }) { return c }
        if let new, new != "0", let c = sets.first(where: { $0.new == new }) { return c }
        if let c = sets.first(where: { $0.deloID == deloID }) { return c }
        // Материал/дело по некороткому new не нашлись — карточка могла быть
        // открыта нестандартной парой; индекс номера — последний шанс.
        return CartotekaRegistry.matches(caseNumber: caseNumber, level: level).first
    }

    // MARK: Группировка по УИД

    /// Карточка после сетевого этапа: seed + карточка (nil — не загрузилась).
    struct Fetched {
        var seed: ImportSeed
        var card: CaseCard?
    }

    /// Готовая к записи единица импорта.
    struct PlannedRecord {
        var context: MovementContext
        var isMaterial: Bool
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
                groups[uid, default: []].append(f)
            } else {
                loners.append(f)
                if f.card == nil { plan.cold += 1 }
            }
        }
        for f in loners {
            plan.records.append(PlannedRecord(context: makeContext(f, known: []),
                                              isMaterial: f.seed.isMaterial))
        }
        for (_, members) in groups.sorted(by: { $0.key < $1.key }) {
            let sorted = members.sorted { $0.seed.anchorRank < $1.seed.anchorRank }
            guard let anchor = sorted.first else { continue }
            if anchor.seed.isMaterial {
                // Группа из одних материалов — дела в выгрузке нет; каждый
                // материал остаётся самостоятельной записью.
                for f in sorted {
                    plan.records.append(PlannedRecord(context: makeContext(f, known: []),
                                                      isMaterial: true))
                }
                continue
            }
            let known = sorted.dropFirst().map(knownCard)
            plan.stitched += known.count
            plan.records.append(PlannedRecord(context: makeContext(anchor, known: known),
                                              isMaterial: false))
        }
        return plan
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
        if !known.isEmpty { ctx.knownCards = known }
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
                         levelRaw: seed.instanceLevel.rawValue,
                         cartotekaID: seed.cartoteka?.id)
    }
}
