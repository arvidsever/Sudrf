//  SearchModel.swift — Sudrf · v3 (фильтры · карточки · инспектор · движение)
//  Изменения относительно вашей модели:
//    1. Три независимых поля запроса (№ / ФИО / УИД), комбинация по «И».
//    2. actMissing / hasSearched (капча поиска — встроенный лист CaptchaContext).
//    3. Движение дела («провал» по двойному клику): movement / openMovement /
//       selectAct / exitMovement; сбор вышестоящих инстанций по УИД (MovementService).

import Foundation
import Combine
import SudrfKit

@MainActor
final class SearchModel: ObservableObject {

    // Ввод
    @Published var branch: CourtBranch = .general
    @Published var tier: CourtTier = .district
    @Published var region = "Республика Коми"
    @Published var courts: [CourtOption] = []
    @Published var selectedDomain = ""
    @Published var cartotekaId = "adm"

    /// Суд в пикере — единый вид для всех источников (живой резолвер портала,
    /// встроенный справочник субъектов/АСОЮ/КСОЮ).
    struct CourtOption: Identifiable, Equatable {
        let domain: String
        let title: String
        let level: CourtLevel
        /// Классификационный код (11RS0001) — есть у судов из резолвера.
        var code: String? = nil
        var supportsSearch: Bool = true
        var unsupportedReason: String? = nil
        var id: String { domain }
        var court: Court { Court(domain: domain, title: title, level: level) }
        /// Суд для сетевых запросов: модуль sud_delo работает на синонимичном
        /// «--»-домене (vs--komi, nvs--spb, sankt-peterburgsky--spb…) — на
        /// него и ходим; отображаемый домен остаётся «точечным».
        var searchCourt: Court {
            Court(domain: CourtDirectory.dashVariant(of: domain) ?? domain,
                  title: title, level: level)
        }
    }
    @Published var queryCaseNumber = ""
    @Published var queryName = ""
    @Published var queryUID = ""

    // Вывод
    @Published var results: [CaseSearchResult] = []
    @Published var selectedResultID: String?
    @Published var actText = ""
    @Published var actMissing = false
    @Published var hasSearched = false

    // Состояние
    @Published var status = ""
    @Published var resolving = false
    @Published var searching = false
    @Published var loadingCard = false

    // Движение дела («провал»)
    @Published var movement: CaseMovement?
    @Published var loadingMovement = false
    @Published var selectedActID: String?
    @Published var expandedComplaints: Set<String> = []

    // Капча вышестоящего суда (форма под кодом с картинки)
    @Published var captcha: CaptchaContext?

    struct CaptchaContext: Identifiable {
        enum Kind: Sendable {
            case sudrfToken
            case kcaptcha
        }
        let id = UUID()
        let formURL: URL
        let uid: String
        let instanceID: String
        let level: CaseInstance.Level
        let courtTitle: String
        var kind: Kind = .sudrfToken
        /// № дела для автоподстановки в форму (вместе с УИД).
        var caseNumber: String? = nil
        /// true — контекст БАЗОВОГО поиска (не заглушки инстанции): после
        /// решения кода лист закрывается и runSearch перезапускается сам.
        var rerunSearch: Bool = false
        /// Сколько фоновых обновлений этого же суда сможет продолжить одна
        /// введённая пользователем пара captcha/captchaid.
        var pendingCaseCount: Int = 0
        /// Несколько номеров дел из очереди — для подсказки в листе капчи.
        var pendingCaseNumbers: [String] = []
    }

    var isDrilled: Bool { movement != nil || loadingMovement }
    var selectedActText: String? { selectedActID.flatMap { movement?.actBodies[$0] } }

    /// Картотеки текущего звена (для ВС РФ — пусто: парсинг не подключён).
    var cartoteki: [Cartoteka] {
        guard let level = tier.level else { return [] }
        return CartotekaRegistry.sets(for: level)
    }

    private let resolver = DistrictCourtResolver()
    private let magistrateResolver = MagistrateCourtResolver()
    private let client = SudrfClient()
    private lazy var magistrateClient = MagistrateClient(sudrfClient: client)
    private let vsrfClient = VSRFClient()
    private let mosGorSudClient = MosGorSudClient()
    private var magistrateDistrictCourts: [DistrictCourt] = []

    /// Сервис движения дела. Подбор доменов вышестоящих судов — таблицы
    /// подсудности в MovementContext (единственный источник правды, общий
    /// с перезапросом из мониторинга).
    private func makeMovementService(for court: CourtOption, base: CaseSearchResult? = nil) -> MovementService {
        let provider: any CaseProviding = court.level == .magistrate ? magistrateClient : client
        return MovementService(client: provider,
                               higherCourtDomains: MovementContext.expandedHigherDomains(
                                branch: branch, courtLevel: court.level,
                                courtTitle: court.title, courtCode: court.code,
                                region: region, displayDomain: court.domain),
                               higherCourtTargets: movementTargets(for: court, base: base),
                               vsrf: vsrfClient,
                               mosgorsud: mosGorSudClient)
    }

    var busy: Bool { resolving || searching || loadingCard }
    var selectedCourt: CourtOption? { courts.first { $0.domain == selectedDomain } }
    var selectedResultIndex: Int? {
        get {
            guard let id = selectedResultID else { return nil }
            return results.firstIndex { $0.stableID == id }
        }
        set {
            guard let newValue, results.indices.contains(newValue) else {
                selectedResultID = nil
                return
            }
            selectedResultID = results[newValue].stableID
        }
    }
    var cartoteka: Cartoteka? {
        guard let level = tier.level else { return nil }
        return CartotekaRegistry.find(level: level, id: cartotekaId)
    }

    /// Регион нужен только районным/городским судам — у всех остальных
    /// ступеней список судов выдаётся сразу целиком (для военных — после
    /// однократного общероссийского скана портала с кэшем).
    var regionPickerEnabled: Bool { branch == .general && (tier == .district || tier == .magistrate) }
    var uidSearchEnabled: Bool { tier != .magistrate }

    /// Вызывается при смене ветви/звена: чинит картотеку и перечитывает суды.
    func branchOrTierChanged() {
        if branch == .military && tier == .magistrate { tier = .district }
        if cartoteka == nil { cartotekaId = cartoteki.first?.id ?? "" }
        Task { await resolveCourts() }
    }
    var selectedResult: CaseSearchResult? {
        guard let id = selectedResultID else { return nil }
        return results.first { $0.stableID == id }
    }

    private func currentIndex(for result: CaseSearchResult) -> Int? {
        results.firstIndex { $0.stableID == result.stableID }
    }

    func resolveCourts() async {
        guard tier != .supreme else {
            courts = []; selectedDomain = ""
            status = "Верховный Суд РФ — задел на будущее: у него отдельный портал "
                   + "(vsrf.ru), парсинг ещё не подключён."
            return
        }
        resolving = true; status = "Загружаю суды…"
        defer { resolving = false }
        do {
            let list: [CourtOption]
            switch (branch, tier) {
            case (.general, .magistrate):
                let magistrates = try await magistrateResolver.courts(forRegion: region)
                magistrateDistrictCourts = ((try? await resolver.courts(forRegion: region)) ?? [])
                list = magistrates.map { m in
                    CourtOption(domain: m.domain,
                                title: m.isSupported ? m.title : m.title + " — портал не подключён",
                                level: .magistrate,
                                code: m.code,
                                supportsSearch: m.isSupported,
                                unsupportedReason: "Поиск по отдельным и внешним порталам мировых судей в этом заходе не подключён.")
                }
            case (.general, .district):
                magistrateDistrictCourts = []
                // Единственная ступень с пикером региона. Районные суды Москвы
                // живут не на sudrf.ru, а на едином портале mos-gorsud.ru —
                // добавляется общая опция портала (пустой courtAlias ищет по
                // всем судам города сразу, суд виден в строке выдачи).
                if region.localizedCaseInsensitiveContains("Москва") {
                    // Для Москвы пустой ответ портального резолвера — норма.
                    let resolved = ((try? await resolver.courts(forRegion: region)) ?? [])
                        .filter { !MosGorSudRouting.isMosGorSud(domain: $0.domain) }
                    list = [CourtOption(domain: MosGorSudEndpoint.host,
                                        title: "Все районные суды Москвы (портал mos-gorsud.ru)",
                                        level: .district)]
                         + resolved.map { CourtOption(domain: $0.domain, title: $0.title,
                                                      level: .district, code: $0.code) }
                } else {
                    list = try await resolver.courts(forRegion: region)
                        .map { CourtOption(domain: $0.domain, title: $0.title,
                                           level: .district, code: $0.code) }
                }
            case (.general, .subject):
                magistrateDistrictCourts = []
                // Все суды субъектов из встроенного справочника, без региона.
                // Мосгорсуд поддержан через портал mos-gorsud.ru; прочие суды
                // вне платформы sudrf (Н.Новгород, Пенза, Ульяновск) — нет.
                list = CourtDirectory.subjectCourts.map {
                    let supported = $0.isSudrfPlatform || MosGorSudRouting.isMosGorSud(domain: $0.domain)
                    let suffix = supported ? "" : " — вне платформы sudrf"
                    return CourtOption(domain: $0.domain, title: $0.title + suffix, level: .subject)
                }
            case (.general, .appeal):
                magistrateDistrictCourts = []
                list = CourtDirectory.appealCourts
                    .map { CourtOption(domain: $0.domain, title: $0.title, level: .appeal) }
            case (.general, .cassation):
                magistrateDistrictCourts = []
                list = CourtDirectory.cassationCourts
                    .map { CourtOption(domain: $0.domain, title: $0.title, level: .cassation) }
            case (.military, .district):
                magistrateDistrictCourts = []
                // Все гарнизонные суды страны (включая зарубежные, код 95) —
                // один типовой запрос портала (court_type=GV&court_subj=0).
                list = try await resolver.garrisonCourts()
                    .map { CourtOption(domain: $0.domain, title: $0.title,
                                       level: .district, code: $0.code) }
            case (.military, .subject):
                magistrateDistrictCourts = []
                list = CourtDirectory.okrugMilitaryCourts
                    .map { CourtOption(domain: $0.domain, title: $0.title, level: .subject) }
            case (.military, .appeal):
                magistrateDistrictCourts = []
                let c = CourtDirectory.appellateMilitaryCourt
                list = [CourtOption(domain: c.domain, title: c.title, level: .appeal)]
            case (.military, .cassation):
                magistrateDistrictCourts = []
                let c = CourtDirectory.cassationMilitaryCourt
                list = [CourtOption(domain: c.domain, title: c.title, level: .cassation)]
            case (.military, .magistrate):
                magistrateDistrictCourts = []
                list = []
            case (_, .supreme):
                list = []   // недостижимо: отсечено guard'ом выше
            }
            courts = list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

            // Прежний выбор сохраняем, если он остался в списке; список из
            // одного суда выбираем сразу, иначе оставляем «— выберите —».
            if !courts.contains(where: { $0.domain == selectedDomain }) {
                selectedDomain = courts.count == 1 ? courts[0].domain : ""
            }

            switch (courts.isEmpty, branch) {
            case (false, _):
                status = courts.count == 1 ? "Суд определён." : "Судов в списке: \(courts.count)"
            case (true, .military):
                status = "Гарнизонные суды не загрузились — портал мог не ответить; "
                       + "повторите выбор звена."
            case (true, .general):
                status = (tier == .district || tier == .magistrate) ? "Суды не найдены — проверьте регион."
                                                                    : "Суды не найдены."
            }
        } catch {
            status = "Ошибка загрузки судов: \(error)"
        }
    }

    func runSearch() async {
        guard let selected = selectedCourt else {
            status = "Сначала выберите суд."; return
        }
        guard selected.supportsSearch else {
            status = selected.unsupportedReason ?? "Поиск по этому сайту мирового судьи пока не подключён."
            return
        }
        let court = selected.searchCourt
        let num = queryCaseNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        // Авто-выбор картотеки по индексу номера дела: «2а-…» → КАС, «10-…» →
        // апелляция на мировых, «3/…» → материалы и т.п. Срабатывает, только если
        // текущая картотека номеру заведомо не соответствует, а подходит ровно одна.
        if !num.isEmpty, let level = tier.level, let current = cartoteka,
           !CartotekaRegistry.prefixMatches(current, caseNumber: num) {
            let candidates = CartotekaRegistry.matches(caseNumber: num, level: level)
            if candidates.count == 1, let c = candidates.first { cartotekaId = c.id }
        }
        guard let cart = cartoteka else {
            status = "Сначала выберите картотеку."; return
        }
        let name = queryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let uid = uidSearchEnabled ? queryUID.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard !(num.isEmpty && name.isEmpty && uid.isEmpty) else {
            status = "Заполните хотя бы одно поле запроса."; return
        }

        searching = true; status = "Идёт поиск…"
        results = []; actText = ""; selectedResultIndex = nil
        hasSearched = false; actMissing = false
        defer { searching = false }

        // Суды Москвы — отдельный портал mos-gorsud.ru: свой /search (без капчи,
        // все поля запроса можно передать разом), карточки — по ссылке из выдачи.
        if MosGorSudRouting.isMosGorSud(domain: court.domain) {
            let route = MosGorSudRouting.map(cartoteka: cart)
            do {
                let rows = try await mosGorSudClient.search(
                    courtAlias: nil,
                    uid: uid.isEmpty ? nil : uid,
                    caseNumber: num.isEmpty ? nil : num,
                    participant: name.isEmpty ? nil : name,
                    instance: route.instance,
                    processType: route.processType)
                results = rows.map { r in
                    CaseSearchResult(caseNumber: r.caseNumber,
                                     receiptDate: r.receiptDate,
                                     essence: r.participants ?? r.court,
                                     judge: r.judge,
                                     decisionDate: nil,
                                     result: r.result,
                                     legalForceDate: nil,
                                     caseID: nil, caseUID: nil,
                                     cardURL: r.cardURL)
                }
                hasSearched = true
                status = results.isEmpty
                    ? "Ничего не найдено (учтите ограничения публикации по 262-ФЗ)."
                    : "Найдено: \(results.count) (портал mos-gorsud.ru)"
            } catch let e as SudrfError {
                status = e.description
            } catch {
                status = "Ошибка поиска mos-gorsud: \(error)"
            }
            return
        }

        do {
            if court.level == .magistrate {
                let primary: (SearchField, String) = !num.isEmpty ? (.caseNumber, num) : (.name, name)
                var res = try await magistrateClient.search(court: court, cartoteka: cart,
                                                            field: primary.0, value: primary.1)
                if !num.isEmpty, primary.0 != .caseNumber {
                    res = res.filter { $0.caseNumber.hasPrefix(num) }
                }
                if !name.isEmpty, primary.0 != .name {
                    res = res.filter { ($0.essence ?? "").localizedCaseInsensitiveContains(name) }
                }
                results = res
                hasSearched = true
                let used = [(num, "№ дела"), (name, "ФИО")]
                    .filter { !$0.0.isEmpty }.map(\.1).joined(separator: " + ")
                status = res.isEmpty
                    ? "Ничего не найдено (учтите ограничения публикации по 262-ФЗ)."
                    : "Найдено: \(res.count) (\(used))"
                return
            }
            // Самое селективное поле уходит в сетевой запрос; УИД уникален в
            // масштабах страны, поэтому он приоритетнее № дела. Локально по УИД
            // дофильтровать нельзя: в строках выдачи официального УИД нет, а
            // caseUID там — внутренний GUID ссылки на карточку, не УИД.
            let primary: (SearchField, String) =
                !uid.isEmpty ? (.uid, uid)
                : !num.isEmpty ? (.caseNumber, num)
                : (.name, name)
            var res = try await client.search(court: court, cartoteka: cart,
                                              field: primary.0, value: primary.1)
            // …остальные дофильтровывают выдачу локально (по «И»). № дела в
            // выдаче может идти с дописками («2-7212/2025 ~ М-5922/2025»),
            // поэтому сравнение по префиксу.
            if !num.isEmpty, primary.0 != .caseNumber {
                res = res.filter { $0.caseNumber.hasPrefix(num) }
            }
            if !name.isEmpty, primary.0 != .name {
                res = res.filter { ($0.essence ?? "").localizedCaseInsensitiveContains(name) }
            }
            results = res
            hasSearched = true
            let used = [(num, "№ дела"), (name, "ФИО"), (uid, "УИД")]
                .filter { !$0.0.isEmpty }.map(\.1).joined(separator: " + ")
            status = res.isEmpty
                ? "Ничего не найдено (учтите ограничения публикации по 262-ФЗ)."
                : "Найдено: \(res.count) (\(used))"
        } catch SudrfError.captchaRequired(let formURL) {
            // Код вводится во ВСТРОЕННОМ окне (не в Safari): УИД/№ дела
            // подставляются автоматически, решённая пара перехватывается
            // (CaptchaTokenStore), после чего поиск перезапускается сам.
            hasSearched = true
            captcha = CaptchaContext(formURL: formURL,
                                     uid: uid,
                                     instanceID: "",
                                     level: .first,
                                     courtTitle: selectedCourt?.title ?? court.title,
                                     kind: court.level == .magistrate ? .kcaptcha : .sudrfToken,
                                     caseNumber: num.isEmpty ? nil : num,
                                     rerunSearch: true)
            status = "Требуется код с картинки — введите его в окне, поиск продолжится сам."
        } catch let e as SudrfError {
            status = e.description
        } catch {
            status = "Ошибка поиска: \(error)"
        }
    }

    func resetQueries() {
        queryCaseNumber = ""; queryName = ""; queryUID = ""
        results = []; actText = ""; selectedResultIndex = nil
        hasSearched = false; actMissing = false
        status = courts.isEmpty ? "" : "Судов в списке: \(courts.count)"
    }

    func openCard(_ index: Int) async {
        guard results.indices.contains(index) else { return }
        await openCard(results[index])
    }

    func openCard(_ result: CaseSearchResult) async {
        guard let index = currentIndex(for: result),
              let cart = cartoteka,
              let court = selectedCourt?.searchCourt else { return }
        let r = results[index]

        // Карточка портала mos-gorsud — по ссылке из выдачи (case_id/case_uid
        // у портала нет); тексты актов публикуются вложениями, не инлайном.
        if MosGorSudRouting.isMosGorSud(domain: court.domain) {
            guard let url = r.cardURL else {
                status = "У записи нет ссылки на карточку."; return
            }
            selectedResultID = r.stableID
            loadingCard = true; actText = ""
            defer { loadingCard = false }
            do {
                let card = try await mosGorSudClient.fetchCard(url: url)
                actMissing = card.actLinks.isEmpty
                actText = Self.mosGorSudCardText(card)
            } catch let e as SudrfError {
                actText = ""; status = e.description
            } catch {
                actText = ""; status = "Ошибка карточки mos-gorsud: \(error)"
            }
            return
        }

        if court.level == .magistrate {
            guard let url = r.cardURL else {
                status = "У записи нет ссылки на карточку."; return
            }
            selectedResultID = r.stableID
            loadingCard = true; actText = ""
            defer { loadingCard = false }
            do {
                let card = try await magistrateClient.fetchCard(url: url)
                actMissing = card.actText == nil
                actText = card.actText ?? card.rawText
            } catch let e as SudrfError {
                actText = ""; status = e.description
            } catch {
                actText = ""; status = "Ошибка карточки мирового участка: \(error)"
            }
            return
        }

        selectedResultID = r.stableID
        loadingCard = true; actText = ""
        defer { loadingCard = false }
        do {
            let card: CaseCard
            if let caseID = r.caseID, let caseUID = r.caseUID {
                card = try await client.fetchCard(court: court, caseID: caseID,
                                                  caseUID: caseUID, deloID: cart.deloID,
                                                  new: cart.new)
            } else if let url = r.cardURL {
                // Винтажные суды (напр., Благовещенский) дают в выдаче только
                // `_uid` — карточка открывается по готовой ссылке выдачи.
                card = try await client.fetchCard(url: url)
            } else {
                status = "У записи нет ни идентификаторов, ни ссылки на карточку."
                return
            }
            actMissing = card.actText == nil
            actText = card.actText ?? card.rawText
        } catch let e as SudrfError {
            actText = ""; status = e.description
        } catch {
            actText = ""; status = "Ошибка карточки: \(error)"
        }
    }

    func closeInspector() {
        selectedResultIndex = nil
        actText = ""
        actMissing = false
        exitMovement()
    }

    /// Текстовое представление карточки mos-gorsud для инспектора: сводка полей
    /// и ссылки на акты-вложения; если поля не распознаны — сырой текст страницы.
    static func mosGorSudCardText(_ card: MosGorSudCard) -> String {
        var lines: [String] = []
        if let v = card.caseNumber { lines.append("Дело: \(v)") }
        if let v = card.uid { lines.append("УИД: \(v)") }
        if let v = card.court { lines.append("Суд: \(v)") }
        if let v = card.judge { lines.append("Судья: \(v)") }
        if let v = card.category { lines.append("Категория: \(v)") }
        if let v = card.receiptDate { lines.append("Дата регистрации: \(v)") }
        if let v = card.result { lines.append("Результат: \(v)") }
        if !card.sessions.isEmpty {
            lines.append("")
            lines.append("Заседания:")
            for s in card.sessions {
                let time = s.time.map { " \($0)" } ?? ""
                let res = s.result.map { " — \($0)" } ?? ""
                lines.append("  \(s.date)\(time): \(s.event)\(res)")
            }
        }
        if !card.actLinks.isEmpty {
            lines.append("")
            lines.append("Тексты актов (вложения портала):")
            for u in card.actLinks { lines.append("  \(u.absoluteString)") }
        }
        let summary = lines.joined(separator: "\n")
        return summary.isEmpty ? card.rawText : summary
    }

    // MARK: - Движение дела (двойной клик)

    /// «Провал» в дело: собирает движение по инстанциям (вышестоящие — по УИД).
    /// Уже открывавшиеся в этой сессии дела берутся из кэша в памяти — без сети.
    func openMovement(_ index: Int) async {
        guard results.indices.contains(index) else { return }
        await openMovement(results[index])
    }

    func openMovement(_ result: CaseSearchResult) async {
        guard let index = currentIndex(for: result),
              let cart = cartoteka, let option = selectedCourt else { return }
        let court = option.searchCourt
        let base = results[index]
        selectedResultID = base.stableID

        let cacheKey = option.domain + "/" + base.caseNumber   // = MovementContext.key
        if let hit = MovementMemoryCache.shared.get(cacheKey) {
            movement = hit.movement
            expandedComplaints = []
            selectedActID = hit.movement.acts.first(where: { $0.instanceLevel == .first })?.id
                         ?? hit.movement.acts.first?.id
            loadingMovement = false
            return
        }

        loadingMovement = true; movement = nil; expandedComplaints = []
        defer { loadingMovement = false }
        do {
            let service = makeMovementService(for: option, base: base)
            let mv = try await service.movement(for: base, court: court, cartoteka: cart)
            movement = mv
            selectedActID = mv.acts.first(where: { $0.instanceLevel == .first })?.id ?? mv.acts.first?.id
            MovementMemoryCache.shared.put(cacheKey, mv)
        } catch let e as SudrfError {
            status = e.description
        } catch {
            status = "Не удалось собрать движение дела: \(error)"
        }
    }

    func selectAct(_ id: String) { selectedActID = id }

    func toggleComplaint(_ id: String) {
        if expandedComplaints.contains(id) { expandedComplaints.remove(id) }
        else { expandedComplaints.insert(id) }
    }

    func exitMovement() {
        movement = nil; loadingMovement = false
        selectedActID = nil; expandedComplaints = []
        captcha = nil
    }

    // MARK: - Капча вышестоящего суда

    /// Открыть окно ввода кода для инстанции-заглушки.
    func beginCaptcha(for inst: CaseInstance) {
        guard let url = inst.captchaFormURL else { return }
        captcha = CaptchaContext(formURL: url,
                                 uid: movement?.uid ?? queryUID,
                                 instanceID: inst.id,
                                 level: inst.level,
                                 courtTitle: inst.court,
                                 kind: url.host.map(SudrfHost.isMSudrfHost) == true ? .kcaptcha : .sudrfToken)
    }

    /// Сохранить решённую пользователем пару captcha/captchaid: суд принимает
    /// её повторно GET-параметрами, так что последующие поиски по этому суду
    /// пройдут без окна кода (пока суд не отклонит пару). Если окно открыто из
    /// базового поиска (rerunSearch) — лист закрывается и поиск продолжается сам.
    func storeCaptchaPair(host: String, token: CaptchaToken) {
        let rerun = captcha?.rerunSearch == true
        let movementResult = rerun ? nil : selectedResult
        let movementCacheKey: String? = {
            guard !rerun, let option = selectedCourt, let mv = movement else { return nil }
            return option.domain + "/" + mv.caseNumber
        }()
        Task {
            await CaptchaTokenStore.shared.store(token, domain: host)
            if rerun {
                captcha = nil
                await runSearch()
            } else {
                if let key = movementCacheKey { MovementMemoryCache.shared.remove(key) }
                captcha = nil
                if let result = movementResult {
                    await openMovement(result)
                }
            }
        }
    }

    func captchaSessionUnlocked(host: String) {
        let rerun = captcha?.rerunSearch == true
        let movementResult = rerun ? nil : selectedResult
        let movementCacheKey: String? = {
            guard !rerun, let option = selectedCourt, let mv = movement else { return nil }
            return option.domain + "/" + mv.caseNumber
        }()
        Task {
            if rerun {
                captcha = nil
                await runSearch()
            } else {
                if let key = movementCacheKey { MovementMemoryCache.shared.remove(key) }
                captcha = nil
                if let result = movementResult {
                    await openMovement(result)
                }
            }
        }
    }

    /// Принять HTML карточки, считанной из окна капчи, и заменить заглушку
    /// реальной инстанцией (карточка капчей не защищена — разбирается как обычно).
    func ingestCaptchaCard(html: String) async {
        // Окно базового поиска: пользователь дошёл до карточки раньше, чем
        // сработал перехват пары, — просто перезапускаем поиск.
        if let ctx = captcha, ctx.rerunSearch {
            captcha = nil
            await runSearch()
            return
        }
        guard let ctx = captcha, let mv = movement else { return }
        defer { captcha = nil }
        let card: CaseCard
        do { card = try CaseCardParser.parse(html: html) }
        catch { status = "Не удалось разобрать карточку: \(error)"; return }

        let domain = ctx.formURL.host ?? ""
        let title = CourtDirectory.court(forDomain: domain)?.title ?? ctx.courtTitle
        let updated = mv.replacingCaptchaStub(domain: domain, courtTitle: title,
                                              level: ctx.level, card: card)
        movement = updated
        if let option = selectedCourt {
            MovementMemoryCache.shared.put(option.domain + "/" + mv.caseNumber, updated)
        }
        status = "Инстанция добавлена: \(title)."
    }

    // MARK: - Маршрут движения мировых судей

    private func movementTargets(for option: CourtOption, base: CaseSearchResult?) -> [MovementSearchTarget]? {
        guard option.level == .magistrate,
              let cart = cartoteka ?? CartotekaRegistry.find(level: .magistrate, id: cartotekaId) else {
            return nil
        }
        let number = base?.caseNumber ?? queryCaseNumber
        let appealIDs = magistrateAppealCartotekaIDs(baseID: cart.id, caseNumber: number)
        let ksoyIDs = magistrateCassationCartotekaIDs(baseID: cart.id, caseNumber: number, target: .ksoy)
        let presidiumIDs = magistrateCassationCartotekaIDs(baseID: cart.id, caseNumber: number, target: .presidium)
        let subjectCode = option.code.map(CourtDirectory.normalizedSubjectCode)
            ?? CourtDirectory.subjectNumericCode(forRegion: region)

        var targets: [MovementSearchTarget] = []
        if !appealIDs.isEmpty {
            for d in magistrateDistrictCourts {
                targets.append(MovementSearchTarget(
                    domain: CourtDirectory.dashVariant(of: d.domain) ?? d.domain,
                    courtTitle: d.title,
                    courtLevel: .district,
                    instanceLevel: cart.id == "m" ? .material : .appeal,
                    cartotekaIDs: appealIDs))
            }
        }

        if let subjectCode, !ksoyIDs.isEmpty,
           let ksoy = CourtDirectory.cassationCourt(forSubjectCode: subjectCode) {
            targets.append(MovementSearchTarget(
                domain: ksoy.domain,
                courtTitle: ksoy.title,
                courtLevel: .cassation,
                instanceLevel: .cassation,
                cartotekaIDs: ksoyIDs,
                dateRule: .before2026))
        }
        if let subjectCode, !presidiumIDs.isEmpty,
           let subject = CourtDirectory.subjectCourt(forSubjectCode: subjectCode), subject.isSudrfPlatform {
            targets.append(MovementSearchTarget(
                domain: CourtDirectory.dashVariant(of: subject.domain) ?? subject.domain,
                courtTitle: subject.title,
                courtLevel: .subject,
                instanceLevel: .cassation,
                cartotekaIDs: presidiumIDs,
                dateRule: .from2026))
        }
        return targets.isEmpty ? nil : targets
    }

    private enum MagistrateCassationTarget { case ksoy, presidium }

    private func magistrateAppealCartotekaIDs(baseID: String, caseNumber: String) -> [String] {
        switch baseID {
        case "u1": return ["u2"]
        case "g1":
            return CartotekaRegistry.normalizedNumber(caseNumber).hasPrefix("2а") ? ["p2"] : ["g2"]
        case "adm": return ["admj"]
        case "m": return ["m"]
        default: return []
        }
    }

    private func magistrateCassationCartotekaIDs(baseID: String, caseNumber: String,
                                                 target: MagistrateCassationTarget) -> [String] {
        let isKAS = CartotekaRegistry.normalizedNumber(caseNumber).hasPrefix("2а")
        switch (baseID, target) {
        case ("u1", .ksoy): return ["u3"]
        case ("u1", .presidium): return ["u33"]
        case ("g1", .ksoy): return [isKAS ? "p3" : "g3"]
        case ("g1", .presidium): return [isKAS ? "p33" : "g33"]
        case ("adm", .ksoy): return ["adm3"]
        case ("adm", .presidium): return ["adm33"]
        default: return []
        }
    }

    // MARK: - Контекст для отслеживания

    /// Снимок текущего поискового контекста выбранного дела — чтобы взять дело в
    /// отслеживание (раздел «Мои дела») и потом перезапрашивать его движение.
    /// nil, если суд/картотека/строка выдачи не выбраны.
    func currentContext() -> MovementContext? {
        guard let option = selectedCourt, let cart = cartoteka,
              let level = tier.level, let base = selectedResult else { return nil }
        var ctx = MovementContext(
            branchRaw: branch.rawValue,
            region: region,
            searchDomain: option.searchCourt.domain,
            displayDomain: option.domain,
            courtTitle: option.title,
            courtLevelRaw: option.level.rawValue,
            courtCode: option.code,
            cartotekaId: cart.id,
            cartotekaLevelRaw: level.rawValue,
            caseNumber: base.caseNumber,
            caseID: base.caseID,
            caseUID: base.caseUID,
            essence: base.essence,
            judge: base.judge,
            receiptDate: base.receiptDate,
            decisionDate: base.decisionDate,
            resultText: base.result,
            legalForceDate: base.legalForceDate,
            cardURLString: base.cardURL?.absoluteString)
        ctx.higherCourtTargets = movementTargets(for: option, base: base)
        return ctx
    }
}
