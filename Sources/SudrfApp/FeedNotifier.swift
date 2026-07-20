//  FeedNotifier.swift — Sudrf · v33
//  Нативные уведомления macOS о новых событиях ленты + счётчик на иконке дока.
//
//  Кто вызывает: AppDelegate оставляет только lifecycle hook (configure);
//  авторизация поднимается лениво, когда реально есть новое уведомление.
//  Новые записи ленты отдаёт AppRouter.reconcileFeed после ФОНОВОГО обновления,
//  бейдж дока обновляется на каждом reload() (число дел с обновлениями).
//  Клик по уведомлению открывает дело через onOpen (проставляет AppRouter).

import Foundation
import AppKit
import UserNotifications

@MainActor
final class FeedNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = FeedNotifier()

    /// Открыть дело по recordKey (проставляет AppRouter). Вызывается по клику
    /// на уведомление.
    var onOpen: ((String) -> Void)?

    private enum AuthorizationState {
        case unknown, requesting, granted, denied
    }

    private var authorizationState: AuthorizationState = .unknown
    private var pendingBatches: [[FeedEntry]] = []
    private var lastBadgeLabel: String? = nil
    /// Голый SwiftPM-бинарник запускается без бандла — UNUserNotificationCenter.current()
    /// там падает. Работаем только когда есть настоящий .app (bundle id ru.sudrf.app).
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    private override init() { super.init() }

    /// Lifecycle hook из AppDelegate. Не трогаем UNUserNotificationCenter на
    /// старте: macOS 26 иногда шумит в консоль системными donation/shortcut
    /// сообщениями даже до первого реального уведомления.
    func configure() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// По одному уведомлению на новую запись ленты. Ограничиваем пачку, чтобы
    /// большой обход не завалил Центр уведомлений; хвост опускаем молча.
    func notify(newEntries entries: [FeedEntry]) {
        guard available, !entries.isEmpty else { return }
        let batch = Array(entries.prefix(10))
        switch authorizationState {
        case .granted:
            deliver(batch)
        case .denied:
            return
        case .requesting:
            pendingBatches.append(batch)
        case .unknown:
            pendingBatches.append(batch)
            requestAuthorization()
        }
    }

    private func requestAuthorization() {
        authorizationState = .requesting
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.authorizationState = granted ? .granted : .denied
                let batches = self.pendingBatches
                self.pendingBatches.removeAll()
                guard granted else { return }
                for batch in batches {
                    self.deliver(batch)
                }
            }
        }
    }

    private func deliver(_ entries: [FeedEntry]) {
        let center = UNUserNotificationCenter.current()
        for entry in entries {
            let content = UNMutableNotificationContent()
            content.title = entry.client.isEmpty ? "Дело \(entry.caseNumber)" : entry.client
            content.subtitle = entry.caseNumber
            content.body = entry.text
            content.sound = .default
            content.userInfo = ["recordKey": entry.recordKey]
            // id записи стабилен (ключ+вид+дата+время+текст) → повторная подача
            // того же id не создаёт дубль.
            let req = UNNotificationRequest(identifier: entry.id, content: content, trigger: nil)
            center.add(req)
        }
    }

    /// Счётчик на иконке дока: число или снять бейдж при нуле.
    func setBadge(_ count: Int) {
        let label = count > 0 ? String(count) : nil
        guard label != lastBadgeLabel else { return }
        lastBadgeLabel = label
        // `NSApp` равен nil в SwiftPM-тестах (нет бандла приложения) —
        // молча пропускаем, иначе force-unwrap упадёт.
        guard available, let app = NSApp else { return }
        app.dockTile.badgeLabel = label
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Показывать баннер даже когда приложение активно (мониторинг часто открыт).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Клик по уведомлению — поднять окно и открыть дело.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if let key = response.notification.request.content.userInfo["recordKey"] as? String {
            await MainActor.run { onOpen?(key) }
        }
    }
}
