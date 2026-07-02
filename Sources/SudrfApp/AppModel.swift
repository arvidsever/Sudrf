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

enum MyCasesMode: String, CaseIterable { case clients, stages, list
    var title: String {
        switch self {
        case .clients: return "По доверителям"
        case .stages:  return "По стадиям"
        case .list:    return "Списком"
        }
    }
}

enum CalMode { case month, agenda }

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
    var what: String
    var caseNumber: String
    var basis: String
    var calLabel: String
    var date: Date
    var status: DeadlineStatus
}

struct TrackedHearing: Identifiable {
    let id = UUID()
    var date: Date
    var time: String
    var caseNumber: String
    var parties: String
    var court: String
    var room: String
    var dateLabel: String
}

struct FeedEntry: Identifiable {
    let id = UUID()
    var dayHead: String?
    var time: String
    var caseNumber: String
    var text: String
    var hasAct: Bool
}

struct StepState { let label: String; let kind: Kind; enum Kind { case done, active, todo } }

struct TrackedCase: Identifiable {
    var id: String { recordKey }
    var recordKey: String
    var caseNumber: String
    var client: String
    var stage: CaseStageKind
    var stageTag: String
    var subject: String
    var court: String
    var partiesShort: String
    var statusText: String
    var statusChip: Palette.Chip
    var last: String
    var next: String
    var nextChip: Palette.Chip
    var isNew: Bool
    var steps: [StepState]
    var newDot: Bool
}

// MARK: - Роутер приложения (навигация + единое состояние мониторинга)

@MainActor
final class AppRouter: ObservableObject {

    // Навигация
    @Published var section: AppSection = .overview
    @Published var openedCase: String? = nil
    @Published var expandedComplaints: Set<String> = []

    // Мои дела
    @Published var myView: MyCasesMode = .clients
    @Published var folder: String = "Все дела"
    @Published var stageFilter: CaseStageKind? = nil

    // Календарь (на реальных датах)
    @Published var calMode: CalMode = .month
    @Published var calMonth: Date = DateUtil.startOfMonth(DateUtil.today)
    @Published var calSelectedDate: Date? = nil

    // Производные наборы (перестраиваются из хранилища в reload())
    @Published var cases: [TrackedCase] = []
    @Published var hearings: [TrackedHearing] = []
    @Published var feed: [FeedEntry] = []
    @Published var deadlines: [TrackedDeadline] = []
    @Published var folders: [(String, Int)] = []
    @Published var stageCounts: [(CaseStageKind, Int)] = []
    @Published var clientNames: [String] = []

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
        refreshCenter.start()
        reload()
    }

    // MARK: Навигация

    func go(_ s: AppSection) { section = s; openedCase = nil; closeLiveCard() }

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
    var newBadge: Int { cases.filter { $0.isNew }.count }
    var waitingCount: Int { deadlines.filter { $0.status == .proposed }.count }

    // MARK: Отслеживание

    func track(context ctx: MovementContext, movement: CaseMovement?, folder: String = "Без папки") {
        let snap = movement.map { MovementDerivation.snapshot(from: $0, context: ctx) }
        // Движение с экрана поиска сеет кэш — первое открытие из «Моих дел» мгновенно.
        store.upsert(context: ctx, snapshot: snap,
                     movement: movement.map(MovementCachePolicy.stripped(forPersist:)),
                     folder: folder)
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

    // MARK: Живая карточка

    /// Результат фонового обновления: снимок/кэш уже сохранены RefreshCenter,
    /// здесь — перестройка списков и (если это открытое дело) подмена карточки.
    /// reload() навигацию не трогает — открытая карточка не сбрасывается.
    private func applyRefreshed(key: String, movement mv: CaseMovement) {
        reload()
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
        captcha = SearchModel.CaptchaContext(formURL: url,
                                             uid: liveMovement?.uid ?? "",
                                             instanceID: inst.id,
                                             level: inst.level,
                                             courtTitle: inst.court)
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

    func reload() {
        let recs = store.all()
        let today = DateUtil.today

        var cs: [TrackedCase] = []
        var hs: [TrackedHearing] = []
        var dls: [TrackedDeadline] = []
        var sessionsForFeed: [(date: Date, time: String, number: String, text: String)] = []

        for rec in recs {
            let snap = rec.snapshot
            let stage = snap.map { CaseStageKind(rawValue: $0.stageRaw) ?? .first } ?? .first
            cs.append(makeTrackedCase(rec: rec, snap: snap, stage: stage))

            guard let snap else { continue }

            // Заседания (будущие).
            for s in MovementDerivation.futureHearings(snap.sessions, today: today) {
                guard let d = s.date else { continue }
                hs.append(TrackedHearing(date: d, time: s.time ?? "",
                    caseNumber: rec.caseNumber, parties: snap.partiesShort,
                    court: s.court, room: s.room ?? "", dateLabel: DateUtil.dateLabel(d)))
            }
            // Сроки.
            for dl in snap.deadlines {
                dls.append(TrackedDeadline(id: rec.key + "#" + dl.kind, what: dl.what,
                    caseNumber: rec.caseNumber, basis: dl.basis, calLabel: dl.calLabel,
                    date: dl.date, status: DeadlineStatus(rawValue: dl.statusRaw) ?? .proposed))
            }
            // Лента: события движения за последний месяц + будущие назначения.
            for s in snap.sessions {
                guard let d = s.date else { continue }
                let diff = DateUtil.daysBetween(d, today)   // d в прошлом → diff>0
                if diff >= 0 && diff <= 45 {
                    sessionsForFeed.append((d, s.time ?? "—", rec.caseNumber,
                                            s.result ?? s.event))
                }
            }
        }

        hs.sort { ($0.date, $0.time) < ($1.date, $1.time) }
        dls.sort { $0.date < $1.date }

        cases = cs
        hearings = hs
        deadlines = dls
        feed = buildFeed(sessionsForFeed)
        folders = buildFolders(cs)
        clientNames = buildClients(cs)
        stageCounts = buildStageCounts(cs)
    }

    private func makeTrackedCase(rec: TrackedCaseRecord, snap: CaseSnapshot?,
                                 stage: CaseStageKind) -> TrackedCase {
        let isNew = rec.seenAt == nil
        if let snap {
            return TrackedCase(
                recordKey: rec.key, caseNumber: rec.caseNumber, client: rec.folderName,
                stage: stage, stageTag: snap.stageTag, subject: snap.category ?? "—",
                court: rec.courtTitle, partiesShort: snap.partiesShort,
                statusText: snap.statusText,
                statusChip: Palette.Chip(rawValue: snap.statusChipRaw) ?? .gray,
                last: snap.lastEvent, next: snap.nextEvent,
                nextChip: Palette.Chip(rawValue: snap.nextChipRaw) ?? .gray,
                isNew: isNew, steps: makeSteps(snap.steps), newDot: isNew)
        }
        // Снимок ещё не собран (трек до загрузки движения).
        let ctx = rec.context
        return TrackedCase(
            recordKey: rec.key, caseNumber: rec.caseNumber, client: rec.folderName,
            stage: .first, stageTag: "—", subject: ctx?.essence ?? "—",
            court: rec.courtTitle,
            partiesShort: ctx.map { MovementDerivation.partiesShort(
                CaseParties.split(essence: $0.essence).parties ?? CaseParties()) } ?? "—",
            statusText: "Откройте, чтобы загрузить", statusChip: .gray,
            last: "движение ещё не загружено", next: "—", nextChip: .gray,
            isNew: rec.seenAt == nil,
            steps: makeSteps(["active", "todo", "todo"]), newDot: false)
    }

    private func makeSteps(_ raw: [String]) -> [StepState] {
        let labels = ["1-я инст.", "Апелляция", "Кассация"]
        return (0..<3).map { i in
            let k: StepState.Kind = (raw.indices.contains(i) ? raw[i] : "todo") == "done" ? .done
                : (raw.indices.contains(i) && raw[i] == "active" ? .active : .todo)
            return StepState(label: labels[i], kind: k)
        }
    }

    private func buildFeed(_ items: [(date: Date, time: String, number: String, text: String)]) -> [FeedEntry] {
        let sorted = items.sorted { ($0.date, $0.time) > ($1.date, $1.time) }.prefix(14)
        var out: [FeedEntry] = []
        var lastHead: String? = nil
        for it in sorted {
            let head = feedDayHead(it.date)
            let show = head != lastHead
            lastHead = head
            out.append(FeedEntry(dayHead: show ? head : nil, time: it.time,
                                 caseNumber: it.number, text: it.text, hasAct: true))
        }
        return out
    }
    private func feedDayHead(_ d: Date) -> String {
        let diff = DateUtil.daysBetween(d, DateUtil.today)
        if diff == 0 { return "Сегодня" }
        if diff == 1 { return "Вчера" }
        return "\(DateUtil.weekday(d)), \(DateUtil.fmt(d))"
    }

    private func buildFolders(_ cs: [TrackedCase]) -> [(String, Int)] {
        var out: [(String, Int)] = [("Все дела", cs.count)]
        for name in buildClients(cs) { out.append((name, cs.filter { $0.client == name }.count)) }
        return out
    }
    private func buildClients(_ cs: [TrackedCase]) -> [String] {
        var seen = Set<String>(); var order: [String] = []
        for c in cs where !seen.contains(c.client) { seen.insert(c.client); order.append(c.client) }
        return order
    }
    private func buildStageCounts(_ cs: [TrackedCase]) -> [(CaseStageKind, Int)] {
        let order: [CaseStageKind] = [.first, .appeal, .cassation, .done]
        return order.compactMap { st in
            let n = cs.filter { $0.stage == st }.count
            return n > 0 ? (st, n) : nil
        }
    }

    // MARK: Фильтры «Моих дел»

    func filteredCases() -> [TrackedCase] {
        cases.filter { c in
            (folder == "Все дела" || c.client == folder)
            && (stageFilter == nil || c.stage == stageFilter)
        }
    }
    func casesIn(client: String) -> [TrackedCase] { cases.filter { $0.client == client } }
    func casesIn(stage: CaseStageKind) -> [TrackedCase] { cases.filter { $0.stage == stage } }

    private func recordFor(number: String) -> TrackedCaseRecord? {
        let all = store.all()
        // Фолбэк — точный суффикс ключа («<домен>/<№>»), а не подстрока:
        // иначе «2-32/2026» открывал бы и «12-32/2026».
        return all.first { $0.caseNumber == number }
            ?? all.first { $0.key.hasSuffix("/" + number) }
    }
}
