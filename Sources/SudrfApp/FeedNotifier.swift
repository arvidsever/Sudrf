//  FeedNotifier.swift — Sudrf · v33
//  Нативные уведомления macOS о новых событиях ленты + счётчик на иконке дока.
//
//  Кто вызывает: авторизацию поднимает AppDelegate (configure), новые записи ленты
//  отдаёт AppRouter.reconcileFeed после ФОНОВОГО обновления, бейдж дока обновляется
//  на каждом reload() (число дел с обновлениями). Клик по уведомлению открывает дело
//  через onOpen (проставляет AppRouter).

import Foundation
import AppKit
import UserNotifications

@MainActor
final class FeedNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = FeedNotifier()

    /// Открыть дело по recordKey (проставляет AppRouter). Вызывается по клику
    /// на уведомление.
    var onOpen: ((String) -> Void)?

    private var authorized = false
    /// Голый SwiftPM-бинарник запускается без бандла — UNUserNotificationCenter.current()
    /// там падает. Работаем только когда есть настоящий .app (bundle id ru.sudrf.app).
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    private override init() { super.init() }

    /// Однократно при старте: делегат + запрос разрешения (первый запуск покажет
    /// системный prompt).
    func configure() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    /// По одному уведомлению на новую запись ленты. Ограничиваем пачку, чтобы
    /// большой обход не завалил Центр уведомлений; хвост опускаем молча.
    func notify(newEntries entries: [FeedEntry]) {
        guard available, authorized, !entries.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        for entry in entries.prefix(10) {
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
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Показывать баннер даже когда приложение активно (мониторинг часто открыт).
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Клик по уведомлению — поднять окно и открыть дело.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        if let key = response.notification.request.content.userInfo["recordKey"] as? String {
            onOpen?(key)
        }
    }
}
