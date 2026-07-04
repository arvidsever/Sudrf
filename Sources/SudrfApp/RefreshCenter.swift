//  RefreshCenter.swift — Sudrf
//  Движок обновления кэша карточек отслеживаемых дел.
//
//  Три режима (все сходятся в refresh(key:)):
//   • периодический обход: start() → каждые ~10 мин проверка, какие дела
//     старше TTL (RefreshSettings), устаревшие обновляются по очереди;
//   • принудительный: refreshAll(force: true) — кнопка «Проверить все»;
//   • точечный: refresh(key:) — при открытии дела (SWR) и кнопка «Обновить».
//
//  Дедупликация по ключу: повторный refresh того же дела возвращает уже
//  идущую задачу. Обход строго последовательный — темп задаёт троттлинг
//  SudrfClient (1.5 с/запрос). Ошибка одного дела не прерывает обход и
//  НИКОГДА не трогает уже сохранённый кэш.

import Foundation
import SudrfKit

@MainActor
final class RefreshCenter: ObservableObject {

    struct WalkProgress: Equatable { var done: Int; var total: Int }

    @Published private(set) var refreshing: Set<String> = []
    @Published private(set) var walkProgress: WalkProgress? = nil
    @Published private(set) var lastErrors: [String: String] = [:]

    /// После успешного обновления записи (ключ, слитая карточка для показа).
    var onRefreshed: ((String, CaseMovement) -> Void)?
    /// При ошибке обновления (ключ, короткий текст).
    var onRefreshFailed: ((String, String) -> Void)?
    /// Ключ открытой сейчас карточки — фоновое обновление не должно гасить
    /// ей бейдж «обновлено» (см. правило seenAt в задаче обновления).
    var openedKey: (() -> String?)?

    private let store: TrackedStore
    private let client: SudrfClient
    private let vsrfClient = VSRFClient()
    private let mosGorSudClient = MosGorSudClient()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var walkTask: Task<Void, Never>? = nil
    /// Поколение обхода: отменённый принудительным перезапуском обход не должен
    /// своим завершением сбросить walkTask/walkProgress нового обхода.
    private var walkGeneration = 0
    private var timerTask: Task<Void, Never>? = nil

    init(store: TrackedStore, client: SudrfClient) {
        self.store = store
        self.client = client
    }

    func isRefreshing(_ key: String) -> Bool { refreshing.contains(key) }

    // MARK: Периодический цикл

    /// Идемпотентный запуск таймера: первый проход ~через 5 с после старта,
    /// далее проверка каждые 10 мин (реально обновляются только устаревшие).
    func start() {
        guard timerTask == nil else { return }
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                self?.refreshAll(force: false)
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    // MARK: Обход всех дел

    /// Последовательно обновляет отслеживаемые дела: force — все подряд,
    /// иначе только те, чей кэш старше TTL. Периодический (не-force) вызов —
    /// no-op, если обход уже идёт; force (кнопка «Проверить все») отменяет
    /// текущий обход и начинает заново.
    func refreshAll(force: Bool) {
        if force {
            walkTask?.cancel()
            walkTask = nil
        } else if walkTask != nil {
            return
        }
        let ttl = RefreshSettings.ttl
        let keys = store.all().filter { rec in
            force || rec.movementFetchedAt.map { Date().timeIntervalSince($0) > ttl } ?? true
        }.map(\.key)
        guard !keys.isEmpty else { return }

        walkGeneration += 1
        let gen = walkGeneration
        walkTask = Task { [weak self] in
            defer {
                if let self, self.walkGeneration == gen {
                    self.walkTask = nil; self.walkProgress = nil
                }
            }
            for (i, key) in keys.enumerated() {
                guard !Task.isCancelled, let self else { return }
                self.walkProgress = WalkProgress(done: i, total: keys.count)
                await self.refresh(key: key)?.value
            }
        }
    }

    // MARK: Обновление одного дела

    /// Запускает (или возвращает уже идущее) обновление дела по ключу записи.
    @discardableResult
    func refresh(key: String) -> Task<Void, Never>? {
        if let existing = tasks[key] { return existing }
        guard store.record(forKey: key) != nil else { return nil }

        refreshing.insert(key)
        let task = Task { [weak self] in
            await self?.performRefresh(key: key)
            self?.refreshing.remove(key)
            self?.tasks[key] = nil
        }
        tasks[key] = task
        return task
    }

    private func performRefresh(key: String) async {
        guard let rec = store.record(forKey: key),
              let ctx = rec.context, let cart = ctx.cartoteka else {
            fail(key, "Не удалось восстановить параметры поиска по делу.")
            return
        }
        let service = ctx.makeService(client: client, vsrf: vsrfClient,
                                      mosgorsud: mosGorSudClient)
        do {
            let mv = try await service.movement(for: ctx.baseResult,
                                                court: ctx.searchCourt, cartoteka: cart)
            // Запись могла быть удалена, пока шёл запрос.
            guard let rec = store.record(forKey: key) else { return }
            let merged = MovementCachePolicy.merge(fresh: mv, cached: rec.movement)
            let newSnap = MovementDerivation.preservingConfirmedDeadlines(
                MovementDerivation.snapshot(from: merged, context: ctx), old: rec.snapshot)
            let changed = rec.snapshot != newSnap
            rec.snapshot = newSnap
            rec.movement = MovementCachePolicy.stripped(forPersist: merged)
            rec.movementFetchedAt = Date()
            // Фон нашёл изменения → бейдж «обновлено» загорается вновь;
            // кроме дела, открытого прямо сейчас (пользователь его и так видит).
            if changed && openedKey?() != key { rec.seenAt = nil }
            store.save()
            lastErrors[key] = nil
            onRefreshed?(key, merged)
        } catch SudrfError.captchaRequired(let url) {
            fail(key, "Форма домашнего суда под капчей — откройте в браузере: \(url.absoluteString)")
        } catch let e as SudrfError {
            fail(key, e.description)
        } catch {
            fail(key, "Не удалось собрать движение дела: \(error.localizedDescription)")
        }
    }

    private func fail(_ key: String, _ text: String) {
        lastErrors[key] = text
        onRefreshFailed?(key, text)
    }
}
