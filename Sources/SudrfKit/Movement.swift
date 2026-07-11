//  Movement.swift — Sudrf · v3
//  Модели движения дела по инстанциям + MovementService (реальные сетевые вызовы).
//
//  Алгоритм сборки:
//    1. fetchCard(1-я инстанция) → сессии из таблицы карточки + текст акта.
//    2. Для каждого higherCourtDomain: поиск по УИД → fetchCard → инстанция.
//    3. Частные жалобы на определения не разбираются автоматически (complaints = [:]).

import Foundation

// MARK: - Модель

public struct CaseSession: Sendable, Equatable, Identifiable, Codable {
    // id — только для Identifiable в UI; при декодировании создаётся заново,
    // поэтому в == не участвует (иначе кэшированное движение никогда не было
    // бы равно свежему с тем же содержимым).
    enum CodingKeys: String, CodingKey { case date, time, room, event, result, complaintID }
    public let id = UUID()
    public var date: String          // «23.04.2026»
    public var time: String?         // «14:00»
    public var room: String?         // зал, «215»
    public var event: String         // «Судебное заседание»
    public var result: String?       // «иск удовлетворён частично»
    /// Идентификатор частной жалобы, поданной на определение этого события.
    public var complaintID: String?

    public init(date: String, time: String? = nil, room: String? = nil,
                event: String, result: String? = nil, complaintID: String? = nil) {
        self.date = date; self.time = time; self.room = room
        self.event = event; self.result = result; self.complaintID = complaintID
    }

    public static func == (lhs: CaseSession, rhs: CaseSession) -> Bool {
        lhs.date == rhs.date && lhs.time == rhs.time && lhs.room == rhs.room
            && lhs.event == rhs.event && lhs.result == rhs.result
            && lhs.complaintID == rhs.complaintID
    }
}

public struct PrivateComplaint: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var label: String         // «Частная жалоба на отказ в обеспечительных мерах»
    public var court: String         // суд апелляционной инстанции
    public var caseNumber: String    // № дела жалобы, «33-1102/2026»
    public var foundByUID: Bool
    public var rows: [CaseSession]

    public init(id: String, label: String, court: String, caseNumber: String,
                foundByUID: Bool, rows: [CaseSession]) {
        self.id = id; self.label = label; self.court = court
        self.caseNumber = caseNumber; self.foundByUID = foundByUID; self.rows = rows
    }
}

public struct CaseInstance: Sendable, Equatable, Identifiable, Codable {
    public enum Level: String, Sendable, Codable {
        case first, appeal, cassation, vsCassation, supervisory
        /// Производство по материалу (13-…, 3/12-…, 15-…) в рамках дела —
        /// не инстанция пересмотра; в карточке показывается отдельной секцией
        /// «Материалы» в конце, в стадию/шаги дела не входит.
        case material
    }
    public var id: String { domain + "/" + caseNumber }
    public var level: Level
    public var court: String
    public var caseNumber: String
    public var judge: String?
    public var domain: String
    /// true, если карточка найдена по УИД в вышестоящем суде.
    public var foundByUID: Bool
    public var result: String?
    public var sessions: [CaseSession]
    /// id опубликованного судебного акта этой инстанции (для переключателя), если есть.
    public var actID: String?
    /// Если задан — инстанция не загружена автоматически (форма суда под капчей).
    /// URL формы поиска, которую нужно открыть, чтобы пользователь ввёл код вручную.
    public var captchaFormURL: URL?
    /// true — инстанция не загружена по сети (timeout / no-net / DNS после
    /// исчерпания ретраев). `MovementCachePolicy.merge` восстановит
    /// кэшированные реальные инстанции того же канонического хоста
    /// (с их актами и телами). В UI показывается как «нет связи с X»
    /// только в pure-transient сценарии (кэша нет). При наличии кэша
    /// merge бесшовно подменяет stub — UI показывает кэшированные данные
    /// без уведомления. Опциональное поле: старые кэши декодируются как
    /// `nil` без миграции. Устанавливается `Movement.movement(for:...)` при
    /// catch `SudrfError.transientNetworkError`.
    public var transientError: Bool?
    /// Пометка к инстанции (напр. «отказ в передаче», «возврат без рассмотрения»
    /// для «отказных» производств ВС РФ). Отображается отдельным чипом.
    public var note: String?
    /// Ссылка на текст акта-вложения (PDF/DOC) — mos-gorsud публикует акты
    /// файлами, а не инлайном (в отличие от sud_delo, где текст идёт в actID).
    /// Опционал: старые кэши декодируются без миграции.
    public var actURL: URL?

    public init(level: Level, court: String, caseNumber: String, judge: String?,
                domain: String, foundByUID: Bool, result: String?,
                sessions: [CaseSession], actID: String? = nil,
                captchaFormURL: URL? = nil, note: String? = nil, actURL: URL? = nil,
                transientError: Bool? = nil) {
        self.level = level; self.court = court; self.caseNumber = caseNumber
        self.judge = judge; self.domain = domain; self.foundByUID = foundByUID
        self.result = result; self.sessions = sessions; self.actID = actID
        self.captchaFormURL = captchaFormURL; self.note = note; self.actURL = actURL
        self.transientError = transientError
    }
}

public struct CaseAct: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var title: String         // «Решение», «Апелляционное определение»
    public var date: String
    public var courtShort: String    // «1-я инстанция», «ВС Коми», «3-й КСОЮ»
    public var instanceLevel: CaseInstance.Level

    public init(id: String, title: String, date: String, courtShort: String,
                instanceLevel: CaseInstance.Level) {
        self.id = id; self.title = title; self.date = date
        self.courtShort = courtShort; self.instanceLevel = instanceLevel
    }
}

public struct CaseMovement: Sendable, Equatable, Codable {
    public var uid: String
    public var caseNumber: String
    public var inForce: Bool
    public var instances: [CaseInstance]
    public var complaints: [String: PrivateComplaint]   // id → жалоба
    public var acts: [CaseAct]
    public var actBodies: [String: String]              // act.id → текст акта
    public var category: String?                        // категория дела (карточка 1-й инстанции)
    public var parties: CaseParties                     // стороны (карточка; фолбэк — выдача)

    public init(uid: String, caseNumber: String, inForce: Bool,
                instances: [CaseInstance], complaints: [String: PrivateComplaint],
                acts: [CaseAct], actBodies: [String: String] = [:],
                category: String? = nil, parties: CaseParties = CaseParties()) {
        self.uid = uid; self.caseNumber = caseNumber; self.inForce = inForce
        self.instances = instances; self.complaints = complaints
        self.acts = acts; self.actBodies = actBodies
        self.category = category; self.parties = parties
    }
}

// MARK: - Сервис

public protocol MovementProviding: Sendable {
    func movement(for base: CaseSearchResult,
                  court: Court,
                  cartoteka: Cartoteka) async throws -> CaseMovement
}

/// Часть интерфейса `SudrfClient`, нужная сервису движения (подменяется в тестах).
public protocol CaseProviding: Sendable {
    func search(court: Court, cartoteka: Cartoteka,
                field: SearchField, value: String) async throws -> [CaseSearchResult]
    func fetchCard(court: Court, caseID: String, caseUID: String,
                   deloID: String, new: String) async throws -> CaseCard
    /// Карточка по готовой ссылке из выдачи — для строк без case_id/case_uid
    /// (винтажные суды дают только `_uid`, ссылка самодостаточна).
    func fetchCard(url: URL) async throws -> CaseCard
}

extension SudrfClient: CaseProviding {}

/// Часть интерфейса `VSRFClient`, нужная сервису движения для второй кассации
/// (Верховный Суд РФ, vsrf.ru). Подменяется в тестах.
public protocol VSRFProviding: Sendable {
    func search(uniqueNumber: String?, oldCaseNumber: String?,
                keywords: String?) async throws -> VSRFSearchResults
    func fetchCard(productionID: String, section: VSRFCardSection) async throws -> VSRFCard
}

extension VSRFClient: VSRFProviding {}

/// Прямая ссылка на известную карточку дела/материала (например, из импорта
/// выгрузки стороннего сервиса). Карточки открываются прямым GET без капчи,
/// поэтому known card — гарантия данных там, где сквозной поиск по УИД
/// упирается в капчу или невозможен (УИД в базовой карточке пуст).
public struct KnownCard: Sendable, Equatable, Codable {
    public var domain: String        // модульный («--») домен суда
    public var courtTitle: String    // название суда для отображения
    public var caseID: String
    public var caseUID: String       // GUID ссылки (case_uid), не путать с УИД дела
    public var deloID: String
    public var new: String
    public var caseNumber: String?   // № дела/материала, если известен
    public var levelRaw: String      // CaseInstance.Level.rawValue
    public var cartotekaID: String?  // id картотеки (для названия акта), напр. "g3"

    public var level: CaseInstance.Level { CaseInstance.Level(rawValue: levelRaw) ?? .material }

    public init(domain: String, courtTitle: String, caseID: String, caseUID: String,
                deloID: String, new: String, caseNumber: String? = nil,
                levelRaw: String, cartotekaID: String? = nil) {
        self.domain = domain; self.courtTitle = courtTitle
        self.caseID = caseID; self.caseUID = caseUID
        self.deloID = deloID; self.new = new; self.caseNumber = caseNumber
        self.levelRaw = levelRaw; self.cartotekaID = cartotekaID
    }
}

public enum MovementDateRule: String, Sendable, Equatable, Codable {
    case always
    case before2026
    case from2026

    func matches(legalForceDate: String?) -> Bool {
        switch self {
        case .always:
            return true
        case .before2026, .from2026:
            let key = MovementService.dateSortKey(legalForceDate)
            if key == Int.max { return true }
            return self == .before2026 ? key < 2026_01_01 : key >= 2026_01_01
        }
    }
}

/// Точная цель поиска вышестоящего/связанного производства. Старый режим
/// `higherCourtDomains` разворачивается в такие цели автоматически; мировые
/// судьи передают их явно, потому что районная апелляция и президиум суда
/// субъекта не выводятся из одного только уровня суда.
public struct MovementSearchTarget: Sendable, Equatable, Codable {
    public var domain: String
    public var courtTitle: String?
    public var courtLevel: CourtLevel?
    public var instanceLevel: CaseInstance.Level?
    public var cartotekaIDs: [String]?
    public var dateRule: MovementDateRule

    public init(domain: String,
                courtTitle: String? = nil,
                courtLevel: CourtLevel? = nil,
                instanceLevel: CaseInstance.Level? = nil,
                cartotekaIDs: [String]? = nil,
                dateRule: MovementDateRule = .always) {
        self.domain = domain
        self.courtTitle = courtTitle
        self.courtLevel = courtLevel
        self.instanceLevel = instanceLevel
        self.cartotekaIDs = cartotekaIDs
        self.dateRule = dateRule
    }
}

public actor MovementService: MovementProviding {

    // internal (не private): московская ветка движения живёт в расширении
    // в MosGorSudMovement.swift и пользуется теми же зависимостями.
    let client: any CaseProviding
    /// Домены вышестоящих судов, на которых ищем дело по УИД.
    let higherCourtDomains: [String]
    let higherCourtTargets: [MovementSearchTarget]
    /// Известные прямые ссылки на карточки этого дела (вышестоящие инстанции,
    /// материалы) — фолбэк при капче и добор того, что поиск не нашёл.
    let knownCards: [KnownCard]
    /// Клиент второй кассации (ВС РФ). nil — вторая кассация не запрашивается.
    let vsrf: (any VSRFProviding)?
    /// Клиент портала судов Москвы (mos-gorsud.ru). nil — московская ветка
    /// не обслуживается (движение по делу Москвы не собрать).
    let mosgorsud: (any MosGorSudProviding)?

    public init(client: any CaseProviding = SudrfClient(), higherCourtDomains: [String] = [],
                higherCourtTargets: [MovementSearchTarget]? = nil,
                knownCards: [KnownCard] = [], vsrf: (any VSRFProviding)? = nil,
                mosgorsud: (any MosGorSudProviding)? = nil) {
        self.client = client
        self.higherCourtDomains = higherCourtDomains
        self.higherCourtTargets = higherCourtTargets
            ?? higherCourtDomains.map { MovementSearchTarget(domain: $0) }
        self.knownCards = knownCards
        self.vsrf = vsrf
        self.mosgorsud = mosgorsud
    }

    public func movement(for base: CaseSearchResult,
                         court: Court,
                         cartoteka: Cartoteka) async throws -> CaseMovement {
        // Суды Москвы — отдельный портал mos-gorsud.ru (см. MosGorSudMovement).
        // Ветка нужна и живому поиску, и перезапросу отслеживаемого дела
        // (RefreshCenter идёт через этот же метод по MovementProviding).
        if MosGorSudRouting.isMosGorSud(domain: court.domain) {
            return try await moscowMovement(
                for: MosGorSudResult(caseNumber: base.caseNumber,
                                     court: court.title,
                                     judge: base.judge,
                                     receiptDate: base.receiptDate,
                                     participants: base.essence,
                                     result: base.result,
                                     cardURL: base.cardURL),
                cartoteka: cartoteka)
        }

        guard Self.hasCardAccess(base) else {
            return Self.minimalMovement(base: base, court: court)
        }

        // 1. Карточка 1-й инстанции: сессии + текст акта
        let baseCard = try await fetchCard(row: base, court: court, cartoteka: cartoteka)

        // УИД дела (вида 11RS0001-01-2025-011255-03) — из метаданных карточки.
        // НЕ путать с base.caseUID: это внутренний GUID ссылки на карточку
        // (параметр case_uid=…), у каждого суда он свой — для сквозного поиска
        // по инстанциям не годится.
        let uid = baseCard.uid
        // Вкладка «Обжалование» 1-й инстанции — авторитетный классификатор жалоб
        // (вид + даты). Парсится из уже загруженной карточки, без доп. запросов.
        let appeals = baseCard.appeals
        var acts: [CaseAct] = []
        var actBodies: [String: String] = [:]
        var baseActID: String? = nil

        if let actText = baseCard.actText {
            let actID = "act_\(court.domain)"
            let date = base.decisionDate ?? base.receiptDate ?? "—"
            acts.append(CaseAct(id: actID,
                                title: Self.actTitle(cartotekaID: cartoteka.id, level: .first),
                                date: date, courtShort: "1-я инстанция", instanceLevel: .first))
            actBodies[actID] = actText
            baseActID = actID
        }

        var instances: [CaseInstance] = [CaseInstance(
            level: .first,
            court: court.title,
            caseNumber: base.caseNumber,
            judge: base.judge ?? baseCard.judge,
            domain: court.domain,
            foundByUID: false,
            result: base.result ?? baseCard.result,
            sessions: baseCard.sessions,
            actID: baseActID)]

        // 1b. Тот же суд: другие круги под этим же УИД. После отмены вышестоящим
        //     судом и возврата на новое рассмотрение в том же суде заводится НОВАЯ
        //     карточка (новый № дела) под тем же УИД. Прежде искались только
        //     вышестоящие суды, поэтому второй (и последующие) круги домашнего суда
        //     терялись. Ищем по УИД в той же картотеке, базовый круг исключаем.
        if let uid, court.level != .magistrate {
            let sameCourtRows = (try? await client.search(court: court, cartoteka: cartoteka,
                                                          field: .uid, value: uid)) ?? []
            for r in sameCourtRows {
                guard Self.hasCardAccess(r) else { continue }
                // Базовый круг и уже добавленные — пропускаем (№ может идти с
                // дописками «… ~ М-…», поэтому сравнение префиксом).
                if Self.sameCaseNumber(r.caseNumber, base.caseNumber) { continue }
                if instances.contains(where: { $0.domain == court.domain
                                            && Self.sameCaseNumber($0.caseNumber, r.caseNumber) }) { continue }
                guard let card = try? await fetchCard(row: r, court: court,
                                                      cartoteka: cartoteka) else { continue }
                var roundActID: String? = nil
                if let actText = card.actText {
                    let actID = "act_\(court.domain)#\(r.caseNumber)"
                    let date = r.decisionDate ?? r.receiptDate ?? card.decisionDate ?? "—"
                    acts.append(CaseAct(id: actID,
                                        title: Self.actTitle(cartotekaID: cartoteka.id, level: .first),
                                        date: date, courtShort: "1-я инстанция", instanceLevel: .first))
                    actBodies[actID] = actText
                    roundActID = actID
                }
                instances.append(CaseInstance(
                    level: .first,
                    court: court.title,
                    caseNumber: r.caseNumber,
                    judge: r.judge ?? card.judge,
                    domain: court.domain,
                    foundByUID: true,
                    result: r.result ?? card.result,
                    sessions: card.sessions,
                    actID: roundActID))
            }
        }

        // 1c. Материалы домашнего суда (13-…, 3/…, 15-…) под тем же УИД —
        //     секция «Материалы» в конце карточки. Ошибки и капча глушатся
        //     молча: материалы — дополнение, заглушку из-за них не ставим.
        if let uid, court.level == .district, cartoteka.id != "m",
           let mCart = CartotekaRegistry.find(level: .district, id: "m") {
            let rows = (try? await client.search(court: court, cartoteka: mCart,
                                                 field: .uid, value: uid)) ?? []
            for r in rows {
                guard Self.hasCardAccess(r) else { continue }
                if instances.contains(where: { $0.domain == court.domain
                                            && Self.sameCaseNumber($0.caseNumber, r.caseNumber) }) { continue }
                guard let card = try? await fetchCard(row: r, court: court,
                                                      cartoteka: mCart) else { continue }
                var matActID: String? = nil
                if let actText = card.actText {
                    let actID = "act_\(court.domain)#\(r.caseNumber)"
                    let date = r.decisionDate ?? r.receiptDate ?? card.decisionDate ?? "—"
                    acts.append(CaseAct(id: actID,
                                        title: Self.materialActTitle(caseNumber: r.caseNumber),
                                        date: date, courtShort: "Материал", instanceLevel: .material))
                    actBodies[actID] = actText
                    matActID = actID
                }
                instances.append(CaseInstance(
                    level: .material, court: court.title, caseNumber: r.caseNumber,
                    judge: r.judge ?? card.judge, domain: court.domain, foundByUID: true,
                    result: r.result ?? card.result, sessions: card.sessions, actID: matActID))
            }
        }

        // 2. Вышестоящие суды: поиск по УИД → карточка → инстанция.
        //    Если в карточке УИД не указан, сквозной поиск невозможен — пропускаем.
        //    A16 follow-up: при transientError-стабе (см. FIXPLAN.md, A16) использовать
        //    тот же moduleHost-ключ для дедупа, не сырой domain — иначе dash+dot формы
        //    одного вышестоящего суда породят лишнюю заглушку. Шаблон проверки —
        //    см. captcha-stub-path ниже.
        let legalForceDate = baseCard.legalForceDate ?? base.legalForceDate
        for target in higherCourtTargets where target.dateRule.matches(legalForceDate: legalForceDate) {
            guard let uid else { break }
            let domain = target.domain
            let level = target.courtLevel ?? Self.courtLevel(forDomain: domain)
            let higherCourt = Court(domain: domain,
                                    title: target.courtTitle ?? Self.shortCourtName(forDomain: domain),
                                    level: level)
            let cartotekaIDs = target.cartotekaIDs ?? Self.higherCartotekaIDs(baseID: cartoteka.id, level: level)
            let toTry = CartotekaRegistry.sets(for: level).filter { cartotekaIDs.contains($0.id) }
            guard !toTry.isEmpty else { continue }

            for higherCart in toTry {
                do {
                    let results = try await client.search(court: higherCourt,
                                                          cartoteka: higherCart,
                                                          field: .uid, value: uid)
                    // Строки, по которым не открыть карточку (ни ID, ни ссылки), бесполезны.
                    let usable = results.filter { Self.hasCardAccess($0) }
                    guard !usable.isEmpty else { continue }   // картотека пуста — пробуем следующую

                    let instLevel = target.instanceLevel ?? Self.instanceLevel(forCourtLevel: level)

                    // По одному УИД суд может вернуть НЕСКОЛЬКО записей: например, два
                    // круга апелляции — исходный и новый, после возврата из кассации на
                    // новое рассмотрение. Перебираем все и каждый круг кладём отдельной
                    // инстанцией (а не только первый, как было раньше).
                    var rounds: [(inst: CaseInstance, act: CaseAct?, body: String?, sortKey: Int)] = []
                    for r in usable {
                        let higherCard = try await fetchCard(row: r, court: higherCourt,
                                                             cartoteka: higherCart)
                        // Круг или нет — решает вкладка «Обжалование» (вид жалобы),
                        // с откатом к различителю по результату. Частные жалобы и
                        // прочее (замечания на протокол) кругом не считаем.
                        if !Self.isRoundOfAppeal(row: r, card: higherCard, appeals: appeals) { continue }

                        // actID уникален по № дела: при двух кругах из одного суда
                        // прежний "act_<домен>" схлопывал оба акта в один.
                        let actID = "act_\(domain)#\(r.caseNumber)"
                        var act: CaseAct? = nil
                        var body: String? = nil
                        if let actText = higherCard.actText {
                            let date = r.decisionDate ?? r.receiptDate ?? "—"
                            act = CaseAct(
                                id: actID,
                                title: Self.actTitle(cartotekaID: higherCart.id, level: instLevel),
                                date: date,
                                courtShort: Self.shortCourtName(forDomain: domain),
                                instanceLevel: instLevel)
                            body = actText
                        }
                        let inst = CaseInstance(
                            level: instLevel,
                            court: higherCourt.title,
                            caseNumber: r.caseNumber,
                            judge: r.judge ?? higherCard.judge,
                            domain: domain,
                            foundByUID: true,
                            result: r.result ?? higherCard.result,
                            sessions: higherCard.sessions,
                            actID: higherCard.actText != nil ? actID : nil)
                        rounds.append((inst, act, body,
                                       Self.dateSortKey(r.decisionDate ?? r.receiptDate)))
                    }

                    // Круги — по хронологии (старый → новый). Сортировка инстанций
                    // ниже устойчива по уровню, поэтому порядок кругов сохранится.
                    rounds.sort { $0.sortKey < $1.sortKey }
                    for entry in rounds {
                        // A14: `expandedHigherDomains` разворачивает один домен в
                        // dash+dot (`vs.komi.sudrf.ru` → [`vs--komi.sudrf.ru`,
                        // `vs.komi.sudrf.ru`]), оба попадают в `higherCourtTargets`
                        // и оба успешно отдают один и тот же круг — без dedup
                        // инстанция и акт дублируются. Сравниваем по каноническому
                        // `moduleHost` (одинаков для обеих форм) + номеру дела.
                        if instances.contains(where: {
                            SudrfHost.moduleHost($0.domain) == SudrfHost.moduleHost(entry.inst.domain)
                            && Self.sameCaseNumber($0.caseNumber, entry.inst.caseNumber)
                        }) { continue }
                        if let a = entry.act, let b = entry.body {
                            acts.append(a); actBodies[a.id] = b
                        }
                        instances.append(entry.inst)
                    }
                    break   // записи апелляции найдены в этой картотеке — к следующему суду
                } catch SudrfError.captchaRequired(let formURL) {
                    // Форма этого суда под капчей — автопоиск невозможен. Если из
                    // импорта известны прямые ссылки на карточки этого суда — берём
                    // их (карточки капчой не закрыты); иначе заглушка: пользователь
                    // введёт код во всплывающем окне (см. UI).
                    let instLevel = target.instanceLevel ?? Self.instanceLevel(forCourtLevel: level)
                    var rescued = false
                    for kc in knownCards
                        where SudrfHost.moduleHost(kc.domain) == SudrfHost.moduleHost(domain)
                        && kc.level != .material {
                        // A14: дедуп по (moduleHost, caseNumber) — `KnownCard` могут
                        // содержать несколько кругов одного вышестоящего суда; пропускаем
                        // только реальный дубль. `MovementService` — actor, fetch-цикл
                        // последовательный, гонок нет.
                        if let n = kc.caseNumber, instances.contains(where: {
                            SudrfHost.moduleHost($0.domain) == SudrfHost.moduleHost(kc.domain)
                            && Self.sameCaseNumber($0.caseNumber, n)
                        }) { rescued = true; continue }
                        guard let entry = await instanceFromKnownCard(kc) else { continue }
                        // A14: после fetch — финальная проверка против параллельных
                        // rescue (на случай, если fetched-круг совпадает с уже
                        // добавленным от предыдущего `kc`/`target`).
                        if instances.contains(where: {
                            SudrfHost.moduleHost($0.domain) == SudrfHost.moduleHost(kc.domain)
                            && Self.sameCaseNumber($0.caseNumber, entry.inst.caseNumber)
                        }) { rescued = true; continue }
                        if let a = entry.act, let b = entry.body {
                            acts.append(a); actBodies[a.id] = b
                        }
                        instances.append(entry.inst)
                        rescued = true
                    }
                    if !rescued, !instances.contains(where: {
                        // A14: captcha-stub проверяется по каноническому moduleHost,
                        // не по сырому домену — иначе dash+dot формы вышестоящего суда
                        // (развёрнутые `expandedHigherDomains`) дали бы две заглушки.
                        SudrfHost.moduleHost($0.domain) == SudrfHost.moduleHost(domain)
                    }) {
                        instances.append(CaseInstance(
                            level: instLevel,
                            court: higherCourt.title,
                            caseNumber: "—",
                            judge: nil,
                            domain: domain,
                            foundByUID: false,
                            result: nil,
                            sessions: [],
                            actID: nil,
                            captchaFormURL: formURL))
                    }
                    break
                }
                catch SudrfError.transientNetworkError {
                    // Сетевой сбой вышестоящего суда (timeout / DNS / нет сети
                    // после 3 попыток). Ставим transientError-стаб, чтобы
                    // merge восстановил кэшированные реальные инстанции того
                    // же канонического хоста (A14 — moduleHost dedup, иначе
                    // dash+dot формы дали бы две заглушки). A14 inline-комментарий
                    // L395-398 уже отсылает сюда. Если кэша нет — stub остаётся
                    // в instances, идёт в персист, UI показывает плашку «нет
                    // связи» + retry (если onRefresh != nil).
                    let instLevel = target.instanceLevel ?? Self.instanceLevel(forCourtLevel: level)
                    if !instances.contains(where: {
                        SudrfHost.moduleHost($0.domain) == SudrfHost.moduleHost(domain)
                    }) {
                        instances.append(CaseInstance(
                            level: instLevel,
                            court: higherCourt.title,
                            caseNumber: "—",
                            judge: nil,
                            domain: domain,
                            foundByUID: false,
                            result: nil,
                            sessions: [],
                            actID: nil,
                            captchaFormURL: nil,
                            transientError: true))
                    }
                    break
                }
                catch { continue }
            }
        }

        // 2b. Добор по известным прямым ссылкам: карточки, которые сквозной поиск
        //     не нашёл (УИД базовой карточки пуст, домен вне подсудности, материалы
        //     любого звена), подтягиваются прямым GET. Поиск первичен — он находит
        //     все круги; уже собранные инстанции не дублируем.
        for kc in knownCards {
            // A14: дедуп по каноническому moduleHost — иначе `expandedHigherDomains`
            // (dash+dot) приведёт к дублю инстанции при доборе.
            if let n = kc.caseNumber, instances.contains(where: {
                SudrfHost.moduleHost($0.domain) == SudrfHost.moduleHost(kc.domain)
                && Self.sameCaseNumber($0.caseNumber, n)
            }) { continue }
            guard let entry = await instanceFromKnownCard(kc) else { continue }
            if instances.contains(where: {
                SudrfHost.moduleHost($0.domain) == SudrfHost.moduleHost(kc.domain)
                && Self.sameCaseNumber($0.caseNumber, entry.inst.caseNumber)
            }) { continue }
            if let a = entry.act, let b = entry.body {
                acts.append(a); actBodies[a.id] = b
            }
            instances.append(entry.inst)
        }

        // 3. Вторая кассация — Верховный Суд РФ (vsrf.ru, отдельная платформа).
        //    Опрашивается, только если внедрён клиент `vsrf`. Дело (истребованное,
        //    с УИД) и «отказные» жалобы (без истребования) отбираются по УИД и по
        //    тройке (суд 1-й инст. + № дела 1-й инст. + фамилия любой из сторон).
        if let vsrf {
            let surnames = Set((baseCard.parties.plaintiffs
                                + baseCard.parties.defendants
                                + baseCard.parties.thirdParties)
                               .compactMap { VSRFLinkKey.surname($0) })
            if uid != nil || !surnames.isEmpty {
                let vs = await Self.vsrfInstances(vsrf: vsrf, uid: uid,
                                                  firstInstanceCourt: court.title,
                                                  firstInstanceCaseNumber: base.caseNumber,
                                                  partySurnames: surnames)
                instances.append(contentsOf: vs)
            }
        }

        let sortedInst = instances.sorted { Self.instanceOrderKey($0) < Self.instanceOrderKey($1) }
        let sortedActs = acts.sorted { Self.actOrderKey($0) < Self.actOrderKey($1) }

        // Стороны: вкладка «СТОРОНЫ ПО ДЕЛУ» карточки — авторитетный источник;
        // если её нет/пуста — фолбэк к разбору колонки выдачи («ИСТЕЦ: …»).
        var parties = baseCard.parties
        if parties.isEmpty, let p = CaseParties.split(essence: base.essence).parties {
            parties = p
        }
        parties.inferKindIfNeeded(caseNumber: base.caseNumber)

        return CaseMovement(uid: uid ?? "", caseNumber: base.caseNumber,
                            inForce: base.legalForceDate != nil || baseCard.legalForceDate != nil,
                            instances: sortedInst, complaints: [:],
                            acts: sortedActs, actBodies: actBodies,
                            category: baseCard.category, parties: parties)
    }

    /// Карточка по прямой ссылке → инстанция (+акт, если опубликован).
    /// nil — карточка недоступна (ошибки не пробрасываются: known card — добор,
    /// его отсутствие не должно ронять сборку движения).
    private func instanceFromKnownCard(_ kc: KnownCard)
        async -> (inst: CaseInstance, act: CaseAct?, body: String?)? {
        // Звено суда для fetchCard не участвует в построении URL — достаточно домена.
        let fetchCourt = Court(domain: kc.domain, title: kc.courtTitle, level: .district)
        guard let card = try? await client.fetchCard(court: fetchCourt, caseID: kc.caseID,
                                                     caseUID: kc.caseUID, deloID: kc.deloID,
                                                     new: kc.new) else { return nil }
        let number = card.caseNumber ?? kc.caseNumber ?? "—"
        var act: CaseAct? = nil
        var body: String? = nil
        if let actText = card.actText {
            let actID = "act_\(kc.domain)#\(number)"
            let title = kc.level == .material
                ? Self.materialActTitle(caseNumber: number)
                : Self.actTitle(cartotekaID: kc.cartotekaID ?? "", level: kc.level)
            act = CaseAct(id: actID, title: title,
                          date: card.decisionDate ?? card.receiptDate ?? "—",
                          courtShort: kc.level == .material ? "Материал"
                                                            : Self.shortCourtName(forDomain: kc.domain),
                          instanceLevel: kc.level)
            body = actText
        }
        let inst = CaseInstance(level: kc.level, court: kc.courtTitle, caseNumber: number,
                                judge: card.judge, domain: kc.domain, foundByUID: false,
                                result: card.result, sessions: card.sessions,
                                actID: act?.id)
        return (inst, act, body)
    }
}

// MARK: - Вспомогательные методы

extension MovementService {

    /// Можно ли открыть карточку по этой строке выдачи: либо пара
    /// case_id/case_uid (канонический путь через билдер), либо готовая ссылка
    /// (винтажные суды вроде Благовещенского дают в выдаче только `_uid` —
    /// тогда самодостаточна сама ссылка).
    static func hasCardAccess(_ row: CaseSearchResult) -> Bool {
        (row.caseID != nil && row.caseUID != nil) || row.cardURL != nil
    }

    /// Карточка по строке выдачи: пара ID → канонический URL через билдер
    /// (переживает смену формы хоста); иначе — готовая ссылка выдачи.
    func fetchCard(row: CaseSearchResult, court: Court, cartoteka: Cartoteka) async throws -> CaseCard {
        if let id = row.caseID, let uid = row.caseUID {
            return try await client.fetchCard(court: court, caseID: id, caseUID: uid,
                                              deloID: cartoteka.deloID, new: cartoteka.new)
        }
        guard let url = row.cardURL else {
            throw SudrfError.parsing("у записи нет ни идентификаторов, ни ссылки на карточку")
        }
        return try await client.fetchCard(url: url)
    }

    /// Определяет звено суда по домену (эвристика по структуре имени).
    static func courtLevel(forDomain domain: String) -> CourtLevel {
        if domain == "vkas.sudrf.ru" { return .cassation }   // Кассационный военный суд
        if domain == "vap.sudrf.ru"  { return .appeal }      // Апелляционный военный суд
        if domain.range(of: #"^vs(?:--|\.)"#, options: .regularExpression) != nil { return .subject }
        if domain.range(of: #"\dkas\.sudrf\.ru"#, options: .regularExpression) != nil { return .cassation }
        if domain.range(of: #"\dap\.sudrf\.ru"#, options: .regularExpression) != nil { return .appeal }
        if domain.contains("asoy") { return .appeal }
        return .subject
    }

    /// Уровень инстанции относительно базового дела (районный суд).
    static func instanceLevel(forCourtLevel level: CourtLevel) -> CaseInstance.Level {
        switch level {
        case .magistrate: return .first
        case .district:   return .first
        case .subject:    return .appeal
        case .appeal:     return .appeal
        case .cassation:  return .cassation
        }
    }

    /// Главный классификатор: показывать ли запись вышестоящего суда как круг
    /// (полноценную апелляцию/кассацию). Авторитетный источник — вкладка
    /// «Обжалование» карточки 1-й инстанции: запись наверху сшивается с жалобой по
    /// датам (дата рассмотрения наверху = «Дата рассмотрения жалобы»; дата
    /// поступления наверх = «Направлено в вышестоящую инстанцию») и решает её «Вид»:
    ///   • апелляционная / кассационная → круг (показываем);
    ///   • частная жалоба / прочее (замечания на протокол и т. п.) → не круг.
    /// Если по датам жалоба не нашлась (нет вкладки/расхождение дат) — откат к
    /// различителю по «Результату рассмотрения» самой карточки.
    static func isRoundOfAppeal(row: CaseSearchResult, card: CaseCard,
                                appeals: [AppealRecord]) -> Bool {
        if let match = matchAppeal(receipt: card.receiptDate ?? row.receiptDate,
                                   decision: card.decisionDate ?? row.decisionDate,
                                   in: appeals) {
            switch match.kind {
            case .appeal, .cassation:        return true
            case .privateComplaint, .other:  return false
            }
        }
        return !isPrivateComplaintByResult(row: row, card: card)
    }

    /// Сшивка записи вышестоящего суда с жалобой из вкладки «Обжалование» по датам.
    /// Приоритет — дата рассмотрения (точная), затем дата направления/поступления.
    static func matchAppeal(receipt: String?, decision: String?,
                            in appeals: [AppealRecord]) -> AppealRecord? {
        func norm(_ s: String?) -> String? {
            guard let s else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let d = norm(decision),
           let m = appeals.first(where: { norm($0.hearingDate) == d }) { return m }
        if let r = norm(receipt),
           let m = appeals.first(where: { norm($0.sentUpDate) == r }) { return m }
        return nil
    }

    /// Фолбэк-различитель по полю «Результат рассмотрения» апелляционной карточки:
    /// круг пересматривает РЕШЕНИЕ/ПРИГОВОР, частная жалоба — ОПРЕДЕЛЕНИЕ. Категория
    /// и ярлык акта не годятся (категория — существо спора; акт и там, и там —
    /// «Апелляционное определение»). Консервативно: при пустом результате не
    /// считаем частной жалобой.
    static func isPrivateComplaintByResult(row: CaseSearchResult, card: CaseCard) -> Bool {
        let result = (card.result ?? row.result ?? "").lowercased()
        guard !result.isEmpty else { return false }
        let reviewsRuling   = result.contains("определени")             // ОПРЕДЕЛЕНИЕ
        let reviewsJudgment = result.contains("решени")                 // РЕШЕНИЕ
                           || result.contains("приговор")               // ПРИГОВОР
        return reviewsRuling && !reviewsJudgment
    }

    /// Хронологический ключ инстанции для сортировки движения: строго по дате
    /// начала производства (самое раннее событие движения), при равенстве — по
    /// уровню. Жёсткого закрепления 1-й инстанции сверху НЕТ: при возврате на
    /// новое рассмотрение (горсуд → ВС → горсуд) второй круг 1-й инстанции
    /// корректно встаёт ПОСЛЕ вышестоящего суда. Недатированные инстанции уходят
    /// в конец (тай-брейк по уровню сохраняет 1-ю инстанцию выше пустых вышестоящих).
    public static func instanceOrderKey(_ inst: CaseInstance) -> (Int, Int) {
        let earliest = inst.sessions.compactMap { dateSortKey($0.date) }
            .filter { $0 != Int.max }.min() ?? Int.max
        return (earliest, levelOrder(inst.level))
    }

    /// Хронологический ключ судебного акта (панель «Судебные акты»): строго по
    /// дате акта, при равенстве — по уровню. 1-я инстанция не закрепляется сверху
    /// принудительно (см. `instanceOrderKey`).
    public static func actOrderKey(_ act: CaseAct) -> (Int, Int) {
        return (dateSortKey(act.date), levelOrder(act.instanceLevel))
    }

    /// Сравнение № дел с учётом «дописок» в выдаче («2-7212/2025 ~ М-5922/2025»):
    /// номера считаются одним делом, если один — префикс другого (по «голому»
    /// номеру до разделителей). Нужно, чтобы при переопросе домашнего суда не
    /// продублировать базовый круг.
    static func sameCaseNumber(_ a: String, _ b: String) -> Bool {
        func bare(_ s: String) -> String {
            let cut = s.components(separatedBy: CharacterSet(charactersIn: "~("))
                .first ?? s
            return cut.trimmingCharacters(in: .whitespaces)
        }
        let x = bare(a), y = bare(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || x.hasPrefix(y) || y.hasPrefix(x)
    }

    /// Ключ сортировки из даты «дд.мм.гггг» → гггг*10000 + мм*100 + дд.
    /// Непарсируемые/пустые даты уходят в конец (Int.max), чтобы недатированный
    /// круг не вклинивался между датированными.
    static func dateSortKey(_ date: String?) -> Int {
        guard let date else { return Int.max }
        let parts = date.split(separator: ".")
        guard parts.count == 3,
              let d = Int(parts[0]), let m = Int(parts[1]), let y = Int(parts[2]) else {
            return Int.max
        }
        return y * 10_000 + m * 100 + d
    }

    /// Идентификаторы картотек вышестоящего суда, соответствующих базовой картотеке.
    /// Возвращает пустой массив, если соответствие неизвестно ИЛИ суд этого звена
    /// в инстанционную цепочку данного дела не входит — тогда суд пропускается.
    ///
    /// Инстанционные цепочки (надзор ВС РФ — вне проекта, у него свой портал):
    ///   мировой судья → район (апелляция, база u2/g2/p2) → КСОЮ → [ВС РФ]
    ///   район (1 инст) → суд субъекта (апелляция) → КСОЮ → [ВС РФ]
    ///   суд субъекта (1 инст) → АСОЮ (апелляция) → КСОЮ → [ВС РФ]
    ///   КоАП: район (adm) → субъект (adm1) → КСОЮ (adm3, вступившие);
    ///         район (admj — жалоба на несудебное/мировое постановление)
    ///         → субъект (adm2) → КСОЮ (adm3). АСОЮ в КоАП не участвует.
    static func higherCartotekaIDs(baseID: String, level: CourtLevel) -> [String] {
        let prefix = String(baseID.prefix(while: { $0.isLetter })).lowercased()
        // База u2/g2/p2 районного звена — апелляция на мировых судей: её акты
        // минуют суд субъекта и АСОЮ, кассация — сразу в КСОЮ.
        let isAppellateBase = baseID.hasSuffix("2")
        switch level {
        case .magistrate:
            return []
        case .district:
            return []
        case .subject:
            if isAppellateBase { return [] }
            switch prefix {
            case "g":   return ["g2"]
            case "u":   return ["u2"]
            case "p":   return ["p2"]
            case "adm":  return ["adm1"]
                // Постановление судьи 1-й инстанции по делу об АП (adm_case)
                // обжалуется в суд субъекта по картотеке «жалобы на постановления»
                // (adm1_case, 1502001).
            case "admj": return ["adm2"]
                // Решение райсуда по жалобе на несудебное постановление (adm1_case)
                // → суд субъекта по картотеке «жалобы на решения по жалобам»
                // (adm2_case, 1513001). КСОЮ (.cassation) ниже — adm3 (вступившие).
            default:    return []
            }
        case .appeal:
            // АСОЮ — апелляция только на акты судов субъектов, принятые ими по
            // 1-й инстанции. Для дел районного звена (а это сегодня единственная
            // стартовая точка поиска) АСОЮ инстанцией не является. Ветка
            // заработает, когда появится поиск от суда субъекта как 1-й инстанции.
            return []
        case .cassation:
            switch prefix {
            case "g":   return ["g3"]
            case "u":   return ["u3"]
            case "p":   return ["p3"]
            case "adm", "admj": return ["adm3"]
            default:    return []
            }
        }
    }

    /// Название акта по картотеке и уровню инстанции.
    static func actTitle(cartotekaID: String, level: CaseInstance.Level) -> String {
        let prefix = String(cartotekaID.prefix(while: { $0.isLetter })).lowercased()
        switch level {
        case .first:
            switch prefix {
            case "u":    return "Приговор"
            case "admj": return "Решение"        // решение по жалобе на постановление по делу об АП
            case "adm":  return "Постановление"  // постановление по делу об АП (рассмотрение по существу)
            default:     return "Решение"
            }
        case .appeal:
            if prefix == "u" { return "Апелляционное постановление" }
            // АП во второй инстанции (суд субъекта по протесту/жалобе на не
            // вступившее решение) оформляется «Решением», а не апелляционным
            // определением.
            if prefix == "adm" || prefix == "admj" { return "Решение" }
            return "Апелляционное определение"
        case .cassation:
            // По делам об АП КСОЮ выносит постановление (ст. 30.17 КоАП),
            // по ГПК/УПК/КАС — кассационное определение.
            if prefix == "adm" || prefix == "admj" { return "Постановление" }
            return "Определение суда кассационной инстанции"
        case .vsCassation:
            return "Определение Верховного Суда РФ"
        case .supervisory:
            return "Постановление Президиума"
        case .material:
            return "Судебный акт по материалу"
        }
    }

    /// Название акта по материалу — по индексу номера: уголовно-процессуальные
    /// материалы («3/…», «4/…») разрешаются постановлением, гражданские/КАС
    /// («13-…», «13а-…») и КоАП-исполнение («15-…») — определением.
    static func materialActTitle(caseNumber: String) -> String {
        let n = CartotekaRegistry.normalizedNumber(caseNumber)
        return (n.hasPrefix("3/") || n.hasPrefix("4/")) ? "Постановление" : "Определение"
    }

    /// Краткое/полное название суда из домена для отображения в интерфейсе.
    static func shortCourtName(forDomain domain: String) -> String {
        // Если домен есть в справочнике — берём официальное название.
        if let c = CourtDirectory.court(forDomain: domain) { return c.title }
        // vs--komi.sudrf.ru / vs.komi.sudrf.ru → «ВС Komi»
        if let m = domain.range(of: #"^vs(?:--|\.)"#, options: .regularExpression) {
            let rest = domain[m.upperBound...].components(separatedBy: ".").first ?? ""
            return "ВС \(rest.capitalized)"
        }
        // 3kas.sudrf.ru → «3-й КСОЮ»
        if let m = domain.range(of: #"\dkas"#, options: .regularExpression) {
            let num = String(domain[m.lowerBound])
            return "\(num)-й КСОЮ"
        }
        return domain.components(separatedBy: ".").first.map { $0.uppercased() } ?? domain
    }

    static func levelOrder(_ level: CaseInstance.Level) -> Int {
        switch level {
        case .first:        return 0
        case .appeal:       return 1
        case .cassation:    return 2   // первая кассация (КСОЮ)
        case .vsCassation:  return 3   // вторая кассация (Судебные коллегии ВС РФ)
        case .supervisory:  return 4   // надзор (Президиум ВС РФ)
        case .material:     return 5   // материалы — всегда в конце карточки
        }
    }

    // MARK: Вторая кассация (ВС РФ)

    /// Строит инстанции второй кассации (ВС РФ) для базового дела.
    ///
    /// Логика слияния «жалоба → дело»:
    ///   • есть истребованное ДЕЛО (с УИД) → одна инстанция-дело; события
    ///     истребовавшей жалобы («Истребовано дело») вливаются в её движение,
    ///     сама жалоба отдельной записью НЕ дублируется;
    ///   • «отказные»/«возвратные» жалобы, не приведшие к истребованию, — каждая
    ///     отдельной инстанцией с пометкой «отказ/возврат» (решение пользователя);
    ///   • дел нет вовсе → все жалобы идут отдельными инстанциями.
    static func vsrfInstances(vsrf: any VSRFProviding, uid: String?,
                              firstInstanceCourt: String, firstInstanceCaseNumber: String,
                              partySurnames: Set<String>) async -> [CaseInstance] {
        var prods: [VSRFProduction] = []

        // 1) По УИД — истребованное дело (точный матч).
        if let uid, !uid.isEmpty,
           let r = try? await vsrf.search(uniqueNumber: uid, oldCaseNumber: nil, keywords: nil) {
            prods += r.results.filter {
                VSRFLinkKey.normUID($0.uid) != nil
                    && VSRFLinkKey.normUID($0.uid) == VSRFLinkKey.normUID(uid)
            }
        }
        // 2) По № дела 1-й инстанции — жалобы (в т. ч. отказные) любой из сторон.
        //    Выдача мешает регионы, поэтому строго отбираем по тройке.
        if let r = try? await vsrf.search(uniqueNumber: nil,
                                          oldCaseNumber: firstInstanceCaseNumber, keywords: nil) {
            let court = VSRFLinkKey.normCourt(firstInstanceCourt)
            let caseNo = VSRFLinkKey.normCaseNo(firstInstanceCaseNumber)
            for p in r.results {
                guard VSRFLinkKey.normCourt(p.firstInstance.court) == court, court != nil,
                      VSRFLinkKey.normCaseNo(p.firstInstance.caseNumber) == caseNo, caseNo != nil
                else { continue }
                if !partySurnames.isEmpty {
                    guard let s = VSRFLinkKey.surname(p.applicant), partySurnames.contains(s)
                    else { continue }
                }
                prods.append(p)
            }
        }

        // Дедупликация по cardID (или номеру).
        var seen = Set<String>()
        let unique = prods.filter { seen.insert($0.cardID ?? ($0.number ?? UUID().uuidString)).inserted }

        let cases = unique.filter { $0.kind == .caseFile }
        let complaints = unique.filter { $0.kind == .complaint }

        var out: [CaseInstance] = []
        if !cases.isEmpty {
            // Жалоба, по которой истребовано дело, относится только к ближайшему
            // следующему производству дела. Раньше все такие события приклеивались
            // ко всем раундам ВС РФ и смешивали их хронологию.
            var intakeByCase = Array(repeating: [VSRFEvent](), count: cases.count)
            var attachedComplaints = Set<Int>()
            for (complaintIndex, complaint) in complaints.enumerated() where complaint.caseRequested {
                let requestDate = complaint.events.first(where: {
                    $0.text.localizedCaseInsensitiveContains("Истребовано дело")
                        && dateSortKey($0.date) != Int.max
                })?.date ?? complaint.incomingDate
                let requestKey = dateSortKey(requestDate)
                guard requestKey != Int.max,
                      let caseIndex = cases.indices
                        .filter({
                            let key = dateSortKey(cases[$0].incomingDate)
                            return key != Int.max && key >= requestKey
                        })
                        .min(by: { dateSortKey(cases[$0].incomingDate) < dateSortKey(cases[$1].incomingDate) })
                else { continue }
                intakeByCase[caseIndex].append(contentsOf: complaint.events)
                attachedComplaints.insert(complaintIndex)
            }
            for (index, d) in cases.enumerated() {
                out.append(mapProduction(d, extraEvents: intakeByCase[index]))
            }
            // Не связанные с конкретным последующим делом жалобы остаются видны
            // отдельными инстанциями, а не теряются и не приписываются эвристикой.
            for (index, complaint) in complaints.enumerated() where !attachedComplaints.contains(index) {
                out.append(mapProduction(complaint))
            }
        } else {
            for c in complaints { out.append(mapProduction(c)) }
        }
        return out
    }

    /// Отображает производство ВС РФ в инстанцию второй кассации.
    static func mapProduction(_ p: VSRFProduction, extraEvents: [VSRFEvent] = []) -> CaseInstance {
        // Движение: события производства + (для дела) события истребовавшей жалобы,
        // в хронологическом порядке.
        let merged = (p.events + extraEvents)
            .sorted { dateSortKey($0.date) < dateSortKey($1.date) }
        var sessions = merged.map { CaseSession(date: $0.date ?? "—", event: $0.text) }
        if sessions.isEmpty, let inc = p.incomingDate {
            sessions = [CaseSession(date: inc, event: "Поступило в ВС РФ")]
        }
        let disposition = merged.last?.text ?? p.events.last?.text

        // Пометка «отказ/возврат».
        let joined = merged.map { $0.text.lowercased() }.joined(separator: " ")
        let note: String?
        if joined.contains("возврат") { note = "возврат без рассмотрения" }
        else if joined.contains("отказ в передаче") { note = "отказ в передаче" }
        else if p.kind == .complaint && p.uid == nil && !p.caseRequested { note = "жалоба отклонена" }
        else { note = nil }

        return CaseInstance(
            level: .vsCassation,
            court: "Верховный Суд РФ",
            caseNumber: p.number ?? "—",
            judge: p.rapporteur,
            domain: VSRFEndpoint.host,
            foundByUID: p.uid != nil,
            result: disposition,
            sessions: sessions,
            actID: nil,
            note: note)
    }

    /// Минимальное движение без сетевых запросов — когда у записи нет ID карточки.
    /// УИД здесь неизвестен: карточка не загружалась, а `base.caseUID` — это
    /// GUID ссылки на карточку, а не УИД.
    static func minimalMovement(base: CaseSearchResult, court: Court) -> CaseMovement {
        let inst = CaseInstance(
            level: .first, court: court.title, caseNumber: base.caseNumber,
            judge: base.judge, domain: court.domain, foundByUID: false,
            result: base.result, sessions: [], actID: nil)
        return CaseMovement(uid: "", caseNumber: base.caseNumber,
                            inForce: base.legalForceDate != nil,
                            instances: [inst], complaints: [:], acts: [], actBodies: [:],
                            parties: {
                                var p = CaseParties.split(essence: base.essence).parties
                                    ?? CaseParties()
                                p.inferKindIfNeeded(caseNumber: base.caseNumber)
                                return p
                            }())
    }
}

//  Демо-набор (demoMovement) переехал в тестовый таргет:
//  Tests/SudrfKitTests/DemoMovement.swift — в собранное приложение не попадает.
