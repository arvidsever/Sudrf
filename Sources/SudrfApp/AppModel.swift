//  AppModel.swift — Sudrf · v15 · разделы мониторинга НА ЖИВЫХ ДАННЫХ
//
//  Прежде разделы (Обзор / Мои дела / Календарь) работали на демо-наборе, а
//  поиск был отдельным «островом». Теперь всё сопряжено:
//   • дело берётся «в отслеживание» из поиска (кнопка в карточке движения) и
//     сохраняется в SwiftData (см. TrackedStore);
//   • разделы мониторинга показывают только реально отслеживаемые дела;
//   • тап по делу показывает КЭШ мгновенно и перезапрашивает движение в фоне
//     (stale-while-revalidate); периодический и принудительный перезапрос —
//     RefreshCenter, правила слияния с кэшем — MovementCachePolicy (SudrfKit);
//   • заседания, сроки и лента ВЫЧИСЛЯЮТСЯ из движения (см. MovementDerivation).
//
//  Единый источник правды о наборе дел — TrackedStore; AppRouter держит из него
//  производные опубликованные массивы и навигацию.

import SwiftUI
import AppKit
import Combine
import SudrfKit

// MARK: - Палитра разделов

enum Palette {
    static let blue      = Color.accentColor
    static let confirmed = Color(red: 0.788, green: 0.184, blue: 0.149)   // #c92f26 — срок подтверждён
    static let proposed  = Color(red: 0.627, green: 0.388, blue: 0.0)     // #a06400 — срок расчётный
    static let green     = Color(red: 0.114, green: 0.478, blue: 0.239)   // #1d7a3d — завершено / в силе

    // RawRepresentable — чтобы цвет чипа сериализовался в снимок дела.
    enum Chip: String { case blue, gray, green, proposed, confirmed }

    static func chipFg(_ c: Chip) -> Color {
        switch c {
        case .blue:      return .accentColor
        case .gray:      return .secondary
        case .green:     return green
        case .proposed:  return proposed
        case .confirmed: return confirmed
        }
    }
    static func chipBg(_ c: Chip) -> Color {
        switch c {
        case .blue:      return Color.accentColor.opacity(0.13)
        case .gray:      return Color.primary.opacity(0.06)
        case .green:     return green.opacity(0.16)
        case .proposed:  return Color.orange.opacity(0.16)
        case .confirmed: return confirmed.opacity(0.13)
        }
    }
}

// MARK: - Модели раздела мониторинга

enum AppSection: String, CaseIterable, Hashable { case overview, cases, search, calendar
    var title: String {
        switch self {
        case .overview: return "Обзор"
        case .cases:    return "Мои дела"
        case .search:   return "Поиск"
        case .calendar: return "Календарь"
        }
    }
}

enum MyCasesMode: String, CaseIterable { case list, stages, prods, clients
    var title: String {
        switch self {
        case .list:    return "Списком"
        case .stages:  return "По стадиям"
        case .prods:   return "По производствам"
        case .clients: return "По подборкам"
        }
    }
}

// MARK: - Вид производства

/// Вид производства дела. Если известно звено суда — определяется ТОЧНО по
/// картотеке (`CartotekaRegistry.matches`): один и тот же префикс на разных
/// звеньях значит разное («2-…»: район — гражданское, суд субъекта — уголовное).
/// Без звена — эвристика по номеру через канонический `ProcessKind.detect`.
enum ProductionType: String, CaseIterable {
    case civil, kas, crim, koap

    /// Категория по ключу картотеки (`Cartoteka.id`): `u*` — уголовное,
    /// `p*` — КАС, `adm*` — КоАП, `g*`/`m`/прочее — гражданское/материалы.
    init(cartotekaId id: String) {
        if id.hasPrefix("adm")     { self = .koap }
        else if id.hasPrefix("u")  { self = .crim }
        else if id.hasPrefix("p")  { self = .kas }
        else                       { self = .civil }
    }

    /// Вид производства по номеру и (если известно) звену суда. При заданном
    /// `level` номер разбирается по картотекам этого звена — тогда «12-…» →
    /// КоАП, а «2-…» суда субъекта → уголовное. Иначе — фолбэк по номеру.
    static func of(_ caseNumber: String, level: CourtLevel? = nil) -> ProductionType {
        if let level,
           let cart = CartotekaRegistry.matches(caseNumber: caseNumber, level: level).first {
            return ProductionType(cartotekaId: cart.id)
        }
        switch ProcessKind.detect(caseNumber: caseNumber) {
        case .upk:             return .crim
        case .koap:            return .koap
        case .administrative:  return .kas
        case .civil, .special: return .civil
        }
    }

    /// Название группы/фильтра (сайдбар, группировка «По производствам»).
    var side: String {
        switch self {
        case .civil: return "Гражданские"
        case .kas:   return "Административные (КАС)"
        case .crim:  return "Уголовные"
        case .koap:  return "Адм. правонарушения"
        }
    }
    /// Подпись под номером дела в строке таблицы.
    var row: String {
        switch self {
        case .civil: return "гражданское"
        case .kas:   return "административное (КАС)"
        case .crim:  return "уголовное"
        case .koap:  return "адм. правонарушение"
        }
    }
    /// Буква-бейдж в сайдбаре.
    var abbr: String {
        switch self {
        case .civil: return "Г"; case .kas: return "А"
        case .crim:  return "У"; case .koap: return "АП"
        }
    }
    /// Палитра «шкала тяжести»: один тёплый градиент от нейтрального к
    /// тёмно-красному — цвет кодирует серьёзность производства, а не «тип».
    var color: Color {
        switch self {
        case .civil: return Color(red: 0.38, green: 0.47, blue: 0.56)  // #607890 — нейтральный
        case .kas:   return Color(red: 0.64, green: 0.47, blue: 0.16)  // #a3782a — охра
        case .crim:  return Color(red: 0.62, green: 0.17, blue: 0.17)  // #9e2b2b — тёмно-красный
        case .koap:  return Color(red: 0.75, green: 0.36, blue: 0.16)  // #c05c2a — оранжевый
        }
    }
}

// MARK: - Сортировка таблицы «Списком»

enum CaseSort: CaseIterable {
    case activity, nextEvent, number
    var label: String {
        switch self {
        case .activity:  return "по активности"
        case .nextEvent: return "по ближайшему событию"
        case .number:    return "по номеру дела"
        }
    }
    var hint: String {
        switch self {
        case .activity:  return "свежие изменения в деле — сверху"
        case .nextEvent: return "ближайшее заседание или срок — сверху"
        case .number:    return "по возрастанию номера"
        }
    }
}

enum CalMode { case month, agenda }

enum OverviewRoute { case dashboard, fullFeed }

enum FeedEntryKind: String, CaseIterable, Hashable {
    case hearing, act, movement

    var title: String {
        switch self {
        case .hearing:  return "Заседания"
        case .act:      return "Судебные акты"
        case .movement: return "Движение дела"
        }
    }

    var tag: String {
        switch self {
        case .hearing:  return "заседание"
        case .act:      return "акт"
        case .movement: return "движение"
        }
    }
}

enum FeedTypeFilter: CaseIterable, Hashable {
    case all, hearing, act, movement

    var title: String {
        switch self {
        case .all:      return "Все"
        case .hearing:  return FeedEntryKind.hearing.title
        case .act:      return FeedEntryKind.act.title
        case .movement: return FeedEntryKind.movement.title
        }
    }

    var kind: FeedEntryKind? {
        switch self {
        case .all:      return nil
        case .hearing:  return .hearing
        case .act:      return .act
        case .movement: return .movement
        }
    }
}

enum CaseStageKind: String { case first, appeal, cassation, done
    var label: String {
        switch self {
        case .first:     return "Первая инстанция"
        case .appeal:    return "Апелляция"
        case .cassation: return "Кассация"
        case .done:      return "Завершённые"
        }
    }
    var dot: Color {
        switch self {
        case .first:     return Color(red: 0.04, green: 0.48, blue: 1.0)
        case .appeal:    return Color(red: 0.37, green: 0.36, blue: 0.90)
        case .cassation: return Color(red: 0.69, green: 0.32, blue: 0.87)
        case .done:      return Color.primary.opacity(0.25)
        }
    }
}

enum DeadlineStatus: String { case proposed, confirmed }

struct TrackedDeadline: Identifiable {
    let id: String            // «<ключ записи>#<kind>»
    var recordKey: String
    var what: String
    var caseNumber: String
    var basis: String
    var calLabel: String
    var date: Date
    var status: DeadlineStatus
}

struct TrackedHearing: Identifiable {
    var id: String { "\(recordKey)#hearing#\(Int(date.timeIntervalSinceReferenceDate))#\(time)#\(court)" }
    var recordKey: String
    var date: Date
    var time: String
    var caseNumber: String
    var parties: String
    var court: String
    var room: String
    var dateLabel: String
}

struct FeedEntry: Identifiable {
    var id: String
    var dayHead: String?
    var date: Date
    var time: String
    var recordKey: String
    var caseNumber: String
    var client: String
    var kind: FeedEntryKind
    var text: String
    var actID: String?
    var isUnread: Bool

    var hasAct: Bool { actID != nil }
}

struct OverviewHearingBuckets {
    var next7Days: [TrackedHearing]
    var later: [TrackedHearing]
    var firstLaterDays: Int?
}

struct StepState { let label: String; let kind: Kind; enum Kind { case done, active, todo } }

struct TrackedCase: Identifiable {
    var id: String { recordKey }
    var recordKey: String
    var caseNumber: String
    /// Подборки, в которых состоит дело (доверитель, тема — что угодно).
    var collections: [String]
    var stage: CaseStageKind
    var stageTag: String
    var subject: String
    var court: String
    /// Вид производства, вычисленный при сборке строки с учётом звена суда
    /// (см. `productionType(for:)`). Читатели фильтров/счётчиков берут готовое.
    var production: ProductionType
    var partiesShort: String
    /// Статьи подсудимого/привлекаемого — для строки «Списком» (ФИО ⟨щит⟩ статьи).
    var leadCharges: String?
    /// Вторая строка ячейки «Списком» (второй подсудимый / «и N других»).
    var secondPartyLine: PartiesSecondLine?
    var statusText: String
    var statusChip: Palette.Chip
    var last: String
    var next: String
    var nextChip: Palette.Chip
    var isNew: Bool
    var steps: [StepState]
    var newDot: Bool
    /// Дата последнего состоявшегося события (для сортировки «по активности»).
    var lastEventDate: Date?
    /// Дата ближайшего будущего заседания/срока (для «по ближайшему событию»).
    var nextEventDate: Date?
}

// MARK: - Роутер приложения (навигация + единое состояние мониторинга)

@MainActor
final class AppRouter: ObservableObject {

    // Навигация
    @Published var section: AppSection = .overview
    @Published var overviewRoute: OverviewRoute = .dashboard
    @Published var openedCase: String? = nil
    @Published var expandedComplaints: Set<String> = []

    // Мои дела
    @Published var myView: MyCasesMode = .list
    /// Выбранная подборка («Все дела» — без фильтра).
    @Published var folder: String = "Все дела"
    @Published var stageFilter: CaseStageKind? = nil
    @Published var prodFilter: ProductionType? = nil
    /// Живой фильтр таблицы: номер + стороны + подборки + суд.
    @Published var query: String = ""
    @Published var sortBy: CaseSort = .activity

    // Вся лента внутри «Обзора»
    @Published var feedFilter: FeedTypeFilter = .all
    @Published var feedUnreadOnly = false
    @Published var feedQuery: String = ""

    // Календарь (на реальных датах)
    @Published var calMode: CalMode = .month
    @Published var calMonth: Date = DateUtil.startOfMonth(DateUtil.today)
    @Published var calSelectedDate: Date? = nil

    // Производные наборы (перестраиваются из хранилища в reload())
    @Published var cases: [TrackedCase] = []
    @Published var hearings: [TrackedHearing] = []
    @Published var feed: [FeedEntry] = []
    @Published var deadlines: [TrackedDeadline] = []
    @Published var collections: [(String, Int)] = []   // «Все дела» + подборки со счётчиками
    @Published var stageCounts: [(CaseStageKind, Int)] = []
    @Published var lastOverviewRefreshAt: Date? = nil

    // Правка срока
    @Published var editingDeadline: String? = nil
    @Published var draftDate: Date? = nil

    // Живая карточка дела (кэш + фоновый перезапрос, см. RefreshCenter)
    @Published var liveMovement: CaseMovement? = nil
    @Published var loadingMovement = false
    @Published var movementError: String? = nil
    @Published var selectedActID: String? = nil
    @Published var captcha: SearchModel.CaptchaContext? = nil
    /// Когда открытая карточка в последний раз получена с портала.
    @Published var movementFetchedAt: Date? = nil
    /// Тихая ошибка фонового обновления (кэш при этом остаётся на экране).
    @Published var refreshNote: String? = nil
    /// Ключ записи открытой карточки — фоновые результаты применяются к UI
    /// только при совпадении ключа (карточку могли закрыть/сменить).
    private var openedKey: String? = nil

    private let store = TrackedStore()
    private let client = SudrfClient()
    let refreshCenter: RefreshCenter
    private var refreshCenterSink: AnyCancellable? = nil
    private static let readFeedIDsKey = "overviewReadFeedIDs.v1"
    private var readFeedIDs = Set(UserDefaults.standard.stringArray(forKey: readFeedIDsKey) ?? [])
    /// Уже виденные id ленты — чтобы уведомлять только о реально новых записях.
    /// Отдельно от readFeedIDs: то — «пользователь прочёл», это — «система знала».
    private static let knownFeedIDsKey = "notifiedFeedIDs.v1"
    private var knownFeedIDs = Set(UserDefaults.standard.stringArray(forKey: knownFeedIDsKey) ?? [])

    var isRefreshingOpenCase: Bool {
        openedKey.map { refreshCenter.isRefreshing($0) } ?? false
    }

    init() {
        refreshCenter = RefreshCenter(store: store, client: client)
        refreshCenter.openedKey = { [weak self] in self?.openedKey }
        refreshCenter.onRefreshed = { [weak self] key, mv in
            self?.applyRefreshed(key: key, movement: mv)
        }
        refreshCenter.onRefreshFailed = { [weak self] key, text in
            self?.applyRefreshFailed(key: key, error: text)
        }
        // Вложенный ObservableObject сам по себе не перерисовывает вьюхи,
        // наблюдающие router, — пробрасываем его objectWillChange.
        refreshCenterSink = refreshCenter.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        // Клик по системному уведомлению — поднять окно и открыть дело.
        FeedNotifier.shared.onOpen = { [weak self] key in
            NSApp.activate(ignoringOtherApps: true)
            self?.openCase(key: key)
        }
        refreshCenter.start()
        reload()
    }

    // MARK: Навигация

    func go(_ s: AppSection) {
        section = s
        if s == .overview { overviewRoute = .dashboard }
        else { overviewRoute = .dashboard }
        openedCase = nil
        closeLiveCard()
    }

    func openFullFeed() { overviewRoute = .fullFeed }
    func closeFullFeed() { overviewRoute = .dashboard }

    /// Открытие по ключу записи — предпочтительный путь (номер дела без суда
    /// неоднозначен: «2-115/2026» может отслеживаться в двух судах сразу).
    func openCase(key: String) {
        guard let rec = store.record(forKey: key) else { return }
        open(rec)
    }

    /// Открытие по номеру дела — для мест, где ключа нет (лента, календарь).
    func openCase(_ number: String) {
        guard let rec = recordFor(number: number) else { return }
        open(rec)
    }

    private func open(_ rec: TrackedCaseRecord) {
        openedCase = rec.caseNumber
        openedKey = rec.key
        expandedComplaints = []
        markSeen(rec)
        movementError = nil; refreshNote = nil
        if let cached = rec.movement {
            // Кэш есть — показываем мгновенно, свежие данные подъедут тихо.
            liveMovement = cached
            movementFetchedAt = rec.movementFetchedAt
            selectedActID = cached.acts.first(where: { $0.instanceLevel == .first })?.id
                         ?? cached.acts.first?.id
            loadingMovement = false
        } else {
            liveMovement = nil
            loadingMovement = true
        }
        refreshCenter.refresh(key: rec.key)   // SWR: перезапрос всегда
    }

    func openFeedEntry(_ entry: FeedEntry, preferAct: Bool = false) {
        markFeedEntryRead(entry.id)
        guard let rec = store.record(forKey: entry.recordKey) else { return }
        open(rec)
        if preferAct, let actID = entry.actID {
            selectedActID = actID
        }
    }

    func closeCase() { openedCase = nil; closeLiveCard() }

    /// Принудительное обновление открытой карточки (кнопка «Обновить»).
    func refreshOpenCase() {
        refreshNote = nil
        if let key = openedKey { refreshCenter.refresh(key: key) }
    }

    private func closeLiveCard() {
        liveMovement = nil; loadingMovement = false; movementError = nil
        selectedActID = nil; captcha = nil
        openedKey = nil; movementFetchedAt = nil; refreshNote = nil
        // Задачу обновления в полёте не отменяем: её результат всё равно
        // нужен спискам/календарю; к UI он не применится (проверка ключа).
    }

    func openCalendar(date: Date?) {
        section = .calendar; calMode = .month
        if let date { calMonth = DateUtil.startOfMonth(date) }
        calSelectedDate = date.map(DateUtil.startOfDay)
        openedCase = nil; closeLiveCard()
    }

    func calStep(_ months: Int) { calMonth = DateUtil.startOfMonth(DateUtil.addMonths(calMonth, months)) }

    var isEmpty: Bool { cases.isEmpty }
    var caseCount: Int { cases.count }
    var newBadge: Int { cases.filter { $0.isNew }.count }
    var waitingCount: Int { deadlines.filter { $0.status == .proposed }.count }
    var overdueDeadlineCount: Int {
        deadlines.filter { $0.status == .proposed && $0.date < DateUtil.today }.count
    }
    var monthlyHearingsCount: Int {
        let month = DateUtil.startOfMonth(DateUtil.today)
        return hearings.filter { DateUtil.startOfMonth($0.date) == month }.count
    }
    var unreadFeedCount: Int { feed.filter(\.isUnread).count }
    var weekFeedEntries: [FeedEntry] {
        Self.recentFeedEntries(feed, today: DateUtil.today, days: 7)
    }
    var fullFeedEntries: [FeedEntry] {
        Self.filteredFeedEntries(feed, filter: feedFilter,
                                 unreadOnly: feedUnreadOnly, query: feedQuery)
    }

    // MARK: Отслеживание

    func track(context ctx: MovementContext, movement: CaseMovement?, collections: [String] = []) {
        let snap = movement.map { MovementDerivation.snapshot(from: $0, context: ctx) }
        // Движение с экрана поиска сеет кэш — первое открытие из «Моих дел» мгновенно.
        store.upsert(context: ctx, snapshot: snap,
                     movement: movement.map(MovementCachePolicy.stripped(forPersist:)),
                     collections: collections)
        reload()
    }
    func untrack(_ number: String) {
        guard let rec = recordFor(number: number) else { return }
        store.remove(key: rec.key)
        if openedCase == number { closeCase() }
        reload()
    }
    func isTracked(_ ctx: MovementContext) -> Bool { store.isTracked(key: ctx.key) }
    func isTracked(number: String, displayDomain: String) -> Bool {
        store.isTracked(key: displayDomain + "/" + number)
    }

    private func markSeen(_ rec: TrackedCaseRecord) {
        rec.seenAt = Date(); store.save(); reload()
    }

    func markAllFeedRead() {
        let ids = Set(fullFeedEntries.map(\.id))
        guard !ids.isEmpty else { return }
        readFeedIDs.formUnion(ids)
        saveReadFeedIDs()
        for i in feed.indices where ids.contains(feed[i].id) {
            feed[i].isUnread = false
        }
    }

    private func markFeedEntryRead(_ id: String) {
        guard readFeedIDs.insert(id).inserted else { return }
        saveReadFeedIDs()
        if let i = feed.firstIndex(where: { $0.id == id }) {
            feed[i].isUnread = false
        }
    }

    private func saveReadFeedIDs() {
        UserDefaults.standard.set(Array(readFeedIDs), forKey: Self.readFeedIDsKey)
    }

    // MARK: Импорт из CSV (Файл → «Импортировать дела из CSV…»)

    enum ImportState {
        case running(done: Int, total: Int)
        case finished(ImportSummary)
    }
    @Published var importState: ImportState? = nil
    private var importTask: Task<Void, Never>? = nil

    /// Запуск импорта. Сетевой этап (карточка каждого дела — прямой GET без
    /// капчи) идёт с троттлингом клиента ~1.5 с/запрос; записи создаются одним
    /// батчем в конце, поэтому отмена ничего не оставляет за собой.
    func beginImport(csvText: String) {
        guard importTask == nil else { return }
        let rows = CaseImporter.rows(fromCSV: csvText)
        guard !rows.isEmpty else {
            var s = ImportSummary()
            s.skipped = [(CaseImporter.reasonBadURL, 0)]
            importState = .finished(s)
            return
        }
        importTask = Task { [weak self] in
            await self?.runImport(rows: rows)
            self?.importTask = nil
        }
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        importState = nil
    }

    func dismissImportSummary() {
        if case .finished = importState { importState = nil }
    }

    private func runImport(rows: [ImportedRow]) async {
        var skipped: [String: Int] = [:]
        var seeds: [ImportSeed] = []
        for row in rows {
            switch CaseImporter.classify(row) {
            case .seed(let s):          seeds.append(s)
            case .skipped(let reason):  skipped[reason, default: 0] += 1
            }
        }
        importState = .running(done: 0, total: seeds.count)

        var fetched: [CaseImporter.Fetched] = []
        for (i, seed) in seeds.enumerated() {
            let court = Court(domain: seed.searchDomain, title: seed.courtTitle, level: seed.level)
            let card = try? await client.fetchCard(court: court, caseID: seed.caseID,
                                                   caseUID: seed.caseUID,
                                                   deloID: seed.deloID, new: seed.new)
            if Task.isCancelled { return }
            fetched.append(CaseImporter.Fetched(seed: seed, card: card))
            importState = .running(done: i + 1, total: seeds.count)
        }

        let plan = CaseImporter.plan(fetched)
        let df = DateFormatter()
        df.dateFormat = "dd.MM.yyyy"
        let collection = "Импорт " + df.string(from: Date())
        for rec in plan.records {
            store.upsert(context: rec.context, snapshot: nil, movement: nil,
                         collections: [collection])
        }
        reload()

        var summary = ImportSummary()
        summary.total = rows.count
        summary.cases = plan.records.filter { !$0.isMaterial }.count
        summary.materials = plan.records.filter { $0.isMaterial }.count
        summary.stitched = plan.stitched
        summary.cold = plan.cold
        summary.skipped = skipped.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        importState = .finished(summary)
    }

    // MARK: Живая карточка

    /// Результат фонового обновления: снимок/кэш уже сохранены RefreshCenter,
    /// здесь — перестройка списков и (если это открытое дело) подмена карточки.
    /// reload() навигацию не трогает — открытая карточка не сбрасывается.
    private func applyRefreshed(key: String, movement mv: CaseMovement) {
        reload(notifyNew: true)
        guard openedKey == key else { return }   // карточка закрыта / другое дело
        let keepAct = selectedActID
        liveMovement = mv
        movementFetchedAt = Date()
        loadingMovement = false
        refreshNote = nil
        selectedActID = keepAct.flatMap { id in mv.acts.contains { $0.id == id } ? id : nil }
            ?? mv.acts.first(where: { $0.instanceLevel == .first })?.id
            ?? mv.acts.first?.id
    }

    private func applyRefreshFailed(key: String, error text: String) {
        guard openedKey == key else { return }
        loadingMovement = false
        if liveMovement == nil {
            movementError = text                       // кэша нет — как раньше
        } else {
            refreshNote = "Не удалось обновить: \(text)"  // кэш есть — тихая заметка
        }
    }

    func selectAct(_ id: String) { selectedActID = id }
    var selectedActText: String? { selectedActID.flatMap { liveMovement?.actBodies[$0] } }

    func beginCaptcha(for inst: CaseInstance) {
        guard let url = inst.captchaFormURL else { return }
        let host = url.host
        captcha = SearchModel.CaptchaContext(formURL: url,
                                             uid: liveMovement?.uid ?? "",
                                             instanceID: inst.id,
                                             level: inst.level,
                                             courtTitle: inst.court,
                                             kind: url.host?.lowercased().hasSuffix("msudrf.ru") == true ? .kcaptcha : .sudrfToken,
                                             pendingCaseCount: refreshCenter.captchaPendingCount(forHost: host),
                                             pendingCaseNumbers: refreshCenter.captchaPendingCaseNumbers(forHost: host))
    }

    /// Сохранить решённую пользователем пару captcha/captchaid: последующие
    /// запросы к этому суду пройдут без окна кода. После подхвата карточки
    /// движение перезапрашивается — оставшиеся заглушки-инстанции этого суда
    /// дозагрузятся уже с парой в URL.
    func storeCaptchaPair(host: String, token: CaptchaToken) {
        pendingCaptchaRefresh = true
        Task { [weak self] in
            await CaptchaTokenStore.shared.store(token, domain: host)
            await MainActor.run {
                guard let self else { return }
                self.captcha = nil
                self.refreshCenter.retryPendingCaptcha(host: host)
                self.pendingCaptchaRefresh = false
                self.refreshOpenCase()
            }
        }
    }
    private var pendingCaptchaRefresh = false

    func captchaSessionUnlocked(host: String) {
        pendingCaptchaRefresh = true
        captcha = nil
        refreshCenter.retryPendingCaptcha(host: host)
        pendingCaptchaRefresh = false
        refreshOpenCase()
    }

    /// Принять HTML карточки из окна капчи и заменить заглушку реальной инстанцией
    /// (карточка капчей не защищена — разбирается как обычно).
    func ingestCaptchaCard(html: String) async {
        guard let ctx = captcha, let mv = liveMovement else { return }
        defer { captcha = nil }
        let card: CaseCard
        do { card = try CaseCardParser.parse(html: html) }
        catch { movementError = "Не удалось разобрать карточку: \(error)"; return }

        let domain = ctx.formURL.host ?? ""
        let title = CourtDirectory.court(forDomain: domain)?.title ?? ctx.courtTitle
        let updated = mv.replacingCaptchaStub(domain: domain, courtTitle: title,
                                              level: ctx.level, card: card)
        liveMovement = updated

        // Персистим решённую капчу — инстанция переживает перезапуск, а фоновое
        // обновление не деградирует её обратно в заглушку (правило merge).
        if let key = openedKey, let rec = store.record(forKey: key), let mctx = rec.context {
            rec.movement = MovementCachePolicy.stripped(forPersist: updated)
            rec.snapshot = MovementDerivation.preservingConfirmedDeadlines(
                MovementDerivation.snapshot(from: updated, context: mctx), old: rec.snapshot)
            store.save()
            reload()
        }

        // Пара captcha/captchaid сохранена — перезапрашиваем движение: другие
        // заглушки того же суда дозагрузятся без окон (пара уйдёт в URL поиска).
        if pendingCaptchaRefresh {
            pendingCaptchaRefresh = false
            refreshOpenCase()
        }
    }

    // MARK: Сроки

    func deadline(_ id: String?) -> TrackedDeadline? {
        guard let id else { return nil }
        return deadlines.first { $0.id == id }
    }
    func beginEdit(_ id: String) {
        editingDeadline = id
        draftDate = deadline(id)?.date
    }
    func step(_ days: Int) {
        guard let d = draftDate else { return }
        draftDate = DateUtil.addDays(d, days)
    }
    func confirm(_ id: String) {
        mutateDeadline(id) { $0.statusRaw = DeadlineStatus.confirmed.rawValue }
        editingDeadline = nil; draftDate = nil
    }
    func save(_ id: String) {
        if let nd = draftDate {
            mutateDeadline(id) { $0.dateRef = DateUtil.startOfDay(nd).timeIntervalSinceReferenceDate
                                 $0.statusRaw = DeadlineStatus.confirmed.rawValue }
        }
        editingDeadline = nil; draftDate = nil
    }
    func cancelEdit() { editingDeadline = nil; draftDate = nil }

    private func mutateDeadline(_ id: String, _ change: (inout StoredDeadline) -> Void) {
        let parts = id.split(separator: "#", maxSplits: 1).map(String.init)
        guard parts.count == 2, let rec = store.record(forKey: parts[0]),
              var snap = rec.snapshot,
              let idx = snap.deadlines.firstIndex(where: { $0.kind == parts[1] }) else { return }
        change(&snap.deadlines[idx])
        rec.snapshot = snap
        store.save()
        reload()
    }

    // MARK: Сборка производных наборов из хранилища

    func reload(notifyNew: Bool = false) {
        let recs = store.all()
        let today = DateUtil.today

        var cs: [TrackedCase] = []
        var hs: [TrackedHearing] = []
        var dls: [TrackedDeadline] = []
        var feedItems: [FeedEntry] = []
        let readIDs = readFeedIDs

        for rec in recs {
            let snap = rec.snapshot
            let stage = snap.map { CaseStageKind(rawValue: $0.stageRaw) ?? .first } ?? .first
            cs.append(makeTrackedCase(rec: rec, snap: snap, stage: stage))

            guard let snap else { continue }

            // Заседания (будущие).
            for s in MovementDerivation.futureHearings(snap.sessions, today: today) {
                guard let d = s.date else { continue }
                hs.append(TrackedHearing(recordKey: rec.key, date: d, time: s.time ?? "",
                    caseNumber: rec.caseNumber, parties: snap.partiesShort,
                    court: s.court, room: s.room ?? "", dateLabel: DateUtil.dateLabel(d)))
            }
            // Сроки.
            for dl in snap.deadlines {
                dls.append(TrackedDeadline(id: rec.key + "#" + dl.kind, recordKey: rec.key, what: dl.what,
                    caseNumber: rec.caseNumber, basis: dl.basis, calLabel: dl.calLabel,
                    date: dl.date, status: DeadlineStatus(rawValue: dl.statusRaw) ?? .proposed))
            }
            let client = clientName(rec: rec, snap: snap)
            let unreadByCase = rec.seenAt == nil
            // Лента: события движения за последние 45 дней.
            for s in snap.sessions {
                guard let d = s.date else { continue }
                let diff = DateUtil.daysBetween(d, today)   // d в прошлом → diff>0
                if diff >= 0 && diff <= 45 {
                    let text = s.result ?? s.event
                    let kind = feedKind(for: s)
                    let id = feedID(recordKey: rec.key, kind: kind, date: d,
                                    time: s.time ?? "—", text: text)
                    feedItems.append(FeedEntry(id: id, dayHead: nil, date: d,
                        time: s.time ?? "—", recordKey: rec.key, caseNumber: rec.caseNumber,
                        client: client, kind: kind, text: text, actID: nil,
                        isUnread: unreadByCase && !readIDs.contains(id)))
                }
            }
            // Опубликованные акты берём из полного кэша движения, когда он есть.
            if let mv = rec.movement {
                for act in mv.acts {
                    guard let d = DateUtil.parse(act.date) else { continue }
                    let diff = DateUtil.daysBetween(d, today)
                    guard diff >= 0 && diff <= 45 else { continue }
                    let text = "Опубликован судебный акт: \(act.title)"
                    let id = feedID(recordKey: rec.key, kind: .act, date: d,
                                    time: "—", text: act.id)
                    feedItems.append(FeedEntry(id: id, dayHead: nil, date: d,
                        time: "—", recordKey: rec.key, caseNumber: rec.caseNumber,
                        client: client, kind: .act, text: text, actID: act.id,
                        isUnread: unreadByCase && !readIDs.contains(id)))
                }
            }
        }

        hs.sort { ($0.date, $0.time) < ($1.date, $1.time) }
        dls.sort { $0.date < $1.date }

        cases = cs
        hearings = hs
        deadlines = dls
        feed = buildFeed(feedItems)
        collections = buildCollections(cs)
        stageCounts = buildStageCounts(cs)
        lastOverviewRefreshAt = recs.compactMap(\.movementFetchedAt).max()
        reconcileFeed(notify: notifyNew)
    }

    /// Уведомления о новых записях ленты + бейдж дока. Уведомляем только на
    /// фоновом обновлении (notify: true из applyRefreshed) и только о записях,
    /// которых ещё не было в knownFeedIDs и которые непрочитаны. Бейдж —
    /// число дел с обновлениями — обновляется всегда.
    private func reconcileFeed(notify: Bool) {
        if notify {
            let fresh = feed.filter { $0.isUnread && !knownFeedIDs.contains($0.id) }
            if !fresh.isEmpty { FeedNotifier.shared.notify(newEntries: fresh) }
        }
        let ids = Set(feed.map(\.id))
        if ids != knownFeedIDs {
            knownFeedIDs = ids
            UserDefaults.standard.set(Array(ids), forKey: Self.knownFeedIDsKey)
        }
        FeedNotifier.shared.setBadge(newBadge)
    }

    /// Вид производства строки. Приоритет: точная картотека из контекста
    /// (разрешена при импорте) → разбор по номеру с учётом звена суда → фолбэк
    /// по одному номеру. Домен для звена НЕ используем: эвристика по домену
    /// (`MovementService.courtLevel`) по умолчанию даёт `.subject` и спутала бы
    /// районные дела с делами суда субъекта.
    private func productionType(for rec: TrackedCaseRecord) -> ProductionType {
        if let cart = rec.context?.cartoteka {
            return ProductionType(cartotekaId: cart.id)
        }
        if let level = rec.context?.courtLevel {
            return ProductionType.of(rec.caseNumber, level: level)
        }
        return ProductionType.of(rec.caseNumber)
    }

    private func makeTrackedCase(rec: TrackedCaseRecord, snap: CaseSnapshot?,
                                 stage: CaseStageKind) -> TrackedCase {
        let isNew = rec.seenAt == nil
        let today = DateUtil.today
        let production = productionType(for: rec)
        if let snap {
            // Даты для сортировок: последнее состоявшееся событие и ближайшее
            // будущее (заседание или срок).
            let past = snap.sessions.compactMap(\.date).filter { $0 <= today }.max()
            let nextHearing = MovementDerivation.futureHearings(snap.sessions, today: today)
                .first.flatMap(\.date)
            let nextDeadline = snap.deadlines.map(\.date).filter { $0 >= today }.min()
            let next = [nextHearing, nextDeadline].compactMap { $0 }.min()
            return TrackedCase(
                recordKey: rec.key, caseNumber: rec.caseNumber, collections: rec.collectionNames,
                stage: stage, stageTag: snap.stageTag, subject: snap.category ?? "—",
                court: rec.courtTitle, production: production,
                // Снимки до v20 хранят стороны через «→» и пересчитаются не сразу.
                partiesShort: snap.partiesShort.replacingOccurrences(of: " → ", with: " ⚔ "),
                leadCharges: snap.leadCharges,
                secondPartyLine: snap.secondPartyLine,
                statusText: snap.statusText,
                statusChip: Palette.Chip(rawValue: snap.statusChipRaw) ?? .gray,
                last: snap.lastEvent, next: snap.nextEvent,
                nextChip: Palette.Chip(rawValue: snap.nextChipRaw) ?? .gray,
                isNew: isNew, steps: makeSteps(snap.steps), newDot: isNew,
                lastEventDate: past ?? rec.addedAt, nextEventDate: next)
        }
        // Снимок ещё не собран (трек до загрузки движения).
        let ctx = rec.context
        return TrackedCase(
            recordKey: rec.key, caseNumber: rec.caseNumber, collections: rec.collectionNames,
            stage: .first, stageTag: "—", subject: ctx?.essence ?? "—",
            court: rec.courtTitle, production: production,
            partiesShort: ctx.map { MovementDerivation.partiesShort(
                CaseParties.split(essence: $0.essence).parties ?? CaseParties()) } ?? "—",
            leadCharges: nil,
            secondPartyLine: nil,
            statusText: "Откройте, чтобы загрузить", statusChip: .gray,
            last: "движение ещё не загружено", next: "—", nextChip: .gray,
            isNew: rec.seenAt == nil,
            steps: makeSteps(["active", "todo", "todo"]), newDot: false,
            lastEventDate: rec.addedAt, nextEventDate: nil)
    }

    private func makeSteps(_ raw: [String]) -> [StepState] {
        let labels = ["1-я инст.", "Апелляция", "Кассация"]
        return (0..<3).map { i in
            let k: StepState.Kind = (raw.indices.contains(i) ? raw[i] : "todo") == "done" ? .done
                : (raw.indices.contains(i) && raw[i] == "active" ? .active : .todo)
            return StepState(label: labels[i], kind: k)
        }
    }

    private func clientName(rec: TrackedCaseRecord, snap: CaseSnapshot) -> String {
        if let first = rec.collectionNames.first, !first.isEmpty { return first }
        let parties = snap.partiesShort.replacingOccurrences(of: " → ", with: " ⚔ ")
        return parties.components(separatedBy: " ⚔ ").first?.trimmingCharacters(in: .whitespaces)
            .nilIfEmpty ?? rec.courtTitle
    }

    private func feedKind(for session: StoredSession) -> FeedEntryKind {
        let text = (session.event + " " + (session.result ?? "")).lowercased()
        if !(session.time ?? "").isEmpty
            || text.contains("заседани")
            || text.contains("слушани")
            || text.contains("рассмотрени") {
            return .hearing
        }
        return .movement
    }

    private func feedID(recordKey: String, kind: FeedEntryKind,
                        date: Date, time: String, text: String) -> String {
        "\(recordKey)#feed#\(kind.rawValue)#\(Int(date.timeIntervalSinceReferenceDate))#\(time)#\(text)"
    }

    private func buildFeed(_ items: [FeedEntry]) -> [FeedEntry] {
        var out = items.sorted {
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.time > $1.time
        }
        var lastHead: String? = nil
        for i in out.indices {
            let it = out[i]
            let head = feedDayHead(it.date)
            let show = head != lastHead
            lastHead = head
            out[i].dayHead = show ? head : nil
        }
        return out
    }

    private func feedDayHead(_ d: Date) -> String {
        let diff = DateUtil.daysBetween(d, DateUtil.today)
        if diff == 0 { return "Сегодня" }
        if diff == 1 { return "Вчера" }
        return "\(DateUtil.weekday(d)), \(DateUtil.fmt(d))"
    }

    nonisolated static func hearingBuckets(_ hearings: [TrackedHearing],
                                           today: Date) -> OverviewHearingBuckets {
        let sorted = hearings.sorted { ($0.date, $0.time) < ($1.date, $1.time) }
        let next7 = sorted.filter { h in
            let diff = DateUtil.daysBetween(today, h.date)
            return diff >= 0 && diff <= 7
        }
        let later = sorted.filter { DateUtil.daysBetween(today, $0.date) > 7 }
        return OverviewHearingBuckets(next7Days: next7, later: later,
                                      firstLaterDays: later.first.map { DateUtil.daysBetween(today, $0.date) })
    }

    nonisolated static func pinnedDeadline(_ deadlines: [TrackedDeadline],
                                           today: Date) -> TrackedDeadline? {
        let pending = deadlines.filter { $0.status == .proposed }.sorted { $0.date < $1.date }
        return pending.first { $0.date >= today } ?? pending.first
    }

    nonisolated static func overdueDeadlines(_ deadlines: [TrackedDeadline],
                                             today: Date) -> [TrackedDeadline] {
        deadlines.filter { $0.status == .proposed && $0.date < today }
            .sorted { $0.date < $1.date }
    }

    nonisolated static func remainingPendingDeadlines(_ deadlines: [TrackedDeadline],
                                                      pinned: TrackedDeadline?,
                                                      today: Date) -> [TrackedDeadline] {
        deadlines.filter {
            $0.status == .proposed && $0.id != pinned?.id && $0.date >= today
        }
        .sorted { $0.date < $1.date }
    }

    nonisolated static func recentFeedEntries(_ entries: [FeedEntry],
                                              today: Date, days: Int) -> [FeedEntry] {
        entries.filter { entry in
            let diff = DateUtil.daysBetween(entry.date, today)
            return diff >= 0 && diff < days
        }
    }

    nonisolated static func filteredFeedEntries(_ entries: [FeedEntry],
                                                filter: FeedTypeFilter,
                                                unreadOnly: Bool,
                                                query: String) -> [FeedEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { entry in
            (filter.kind == nil || entry.kind == filter.kind)
            && (!unreadOnly || entry.isUnread)
            && (q.isEmpty || (entry.caseNumber + " " + entry.client + " " + entry.text)
                .lowercased().contains(q))
        }
    }

    /// «Все дела» + подборки со счётчиками. Порядок — как создавались; имена,
    /// встреченные на делах, но неизвестные списку (миграция папок, другой
    /// девайс), впитываются в него — пустая подборка не исчезает.
    private func buildCollections(_ cs: [TrackedCase]) -> [(String, Int)] {
        var known = knownCollections
        var seen = Set(known)
        for c in cs {
            for name in c.collections where !seen.contains(name) {
                seen.insert(name); known.append(name)
            }
        }
        if known != knownCollections { knownCollections = known }
        var out: [(String, Int)] = [("Все дела", cs.count)]
        for name in known {
            out.append((name, cs.filter { $0.collections.contains(name) }.count))
        }
        return out
    }

    /// Подборки, созданные пользователем (включая пустые), в порядке создания.
    private static let collectionsKey = "myCollections"
    private var knownCollections: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.collectionsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: Self.collectionsKey) }
    }
    private func buildStageCounts(_ cs: [TrackedCase]) -> [(CaseStageKind, Int)] {
        let order: [CaseStageKind] = [.first, .appeal, .cassation, .done]
        return order.compactMap { st in
            let n = cs.filter { $0.stage == st }.count
            return n > 0 ? (st, n) : nil
        }
    }

    // MARK: Фильтры «Моих дел»

    /// Таблица «Списком»: подборка ∧ вид производства ∧ стадия ∧ живой запрос,
    /// затем выбранная сортировка. Фильтры комбинируются (И).
    func filteredCases() -> [TrackedCase] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = cases.filter { c in
            (folder == "Все дела" || c.collections.contains(folder))
            && (prodFilter == nil || c.production == prodFilter)
            && (stageFilter == nil || c.stage == stageFilter)
            && (q.isEmpty || Self.matches(c, query: q))
        }
        return Self.sorted(rows, by: sortBy)
    }

    /// Вхождение запроса в номер + стороны + подборки + суд (case-insensitive).
    nonisolated static func matches(_ c: TrackedCase, query q: String) -> Bool {
        (c.caseNumber + " " + c.partiesShort + " "
         + c.collections.joined(separator: " ") + " " + c.court)
            .lowercased().contains(q)
    }

    nonisolated static func sorted(_ rows: [TrackedCase], by sort: CaseSort) -> [TrackedCase] {
        switch sort {
        case .activity:
            return rows.sorted { ($0.lastEventDate ?? .distantPast) > ($1.lastEventDate ?? .distantPast) }
        case .nextEvent:
            return rows.sorted { ($0.nextEventDate ?? .distantFuture) < ($1.nextEventDate ?? .distantFuture) }
        case .number:
            return rows.sorted { $0.caseNumber.compare($1.caseNumber, options: .numeric) == .orderedAscending }
        }
    }

    func casesIn(collection name: String) -> [TrackedCase] {
        cases.filter { $0.collections.contains(name) }
    }
    func casesIn(stage: CaseStageKind) -> [TrackedCase] { cases.filter { $0.stage == stage } }
    func count(prod p: ProductionType) -> Int {
        cases.filter { $0.production == p }.count
    }

    // MARK: Подборки

    /// Создаёт подборку; пустое имя и дубликат игнорируются.
    @discardableResult
    func createCollection(named raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != "Все дела",
              !knownCollections.contains(name) else { return false }
        knownCollections.append(name)
        reload()
        return true
    }

    /// Членство дела в подборке — по ключу записи (номер дела без суда
    /// неоднозначен: одно «2-115/2026» может отслеживаться в двух судах).
    func add(caseKey key: String, to name: String) {
        guard name != "Все дела", let rec = store.record(forKey: key),
              !rec.collectionNames.contains(name) else { return }
        rec.collectionNames.append(name)
        store.save()
        reload()
    }
    func remove(caseKey key: String, from name: String) {
        guard let rec = store.record(forKey: key),
              rec.collectionNames.contains(name) else { return }
        rec.collectionNames.removeAll { $0 == name }
        store.save()
        reload()
    }

    private func recordFor(number: String) -> TrackedCaseRecord? {
        let all = store.all()
        // Фолбэк — точный суффикс ключа («<домен>/<№>»), а не подстрока:
        // иначе «2-32/2026» открывал бы и «12-32/2026».
        return all.first { $0.caseNumber == number }
            ?? all.first { $0.key.hasSuffix("/" + number) }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
