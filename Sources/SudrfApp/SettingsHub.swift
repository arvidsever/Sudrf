//  SettingsHub.swift — Sudrf · окно настроек (⌘,)
//
//  Единственная точка, где собраны все постоянные настройки приложения.
//  Раньше они лежали в трёх несвязанных местах: интервал обновления — в шапке
//  «Моих дел», капча — в системном меню, остальное — одной длинной формой без
//  секций. Рабочие контролы (меню «Captcha», значок обновления в панели)
//  остались как быстрые ярлыки, но перестали быть единственным местом, где
//  параметр вообще можно найти.
//
//  Новых состояний здесь не заводится: `CaptchaSettings.shared`,
//  `AISettings.shared`, `RefreshSettings.ttlKey` и `SpotlightPreferenceStore`
//  уже единичные источники правды — окно только показывает их.

import SwiftUI
import CaptchaSolver

struct SettingsHub: View {
    enum Pane: String, CaseIterable, Identifiable {
        case refresh, spotlight, captcha, ai, experimental
        var id: String { rawValue }

        var title: String {
            switch self {
            case .refresh:      return "Обновление"
            case .spotlight:    return "Поиск"
            case .captcha:      return "CAPTCHA"
            case .ai:           return "AI и приватность"
            case .experimental: return "Экспериментальные"
            }
        }
        var symbol: String {
            switch self {
            case .refresh:      return "arrow.clockwise"
            case .spotlight:    return "magnifyingglass"
            case .captcha:      return "checkmark.shield"
            case .ai:           return "sparkles"
            case .experimental: return "flask"
            }
        }
    }

    @State private var selection: Pane? = .refresh

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(184)
        } detail: {
            switch selection ?? .refresh {
            case .refresh:      RefreshSettingsPane()
            case .spotlight:    SpotlightSettingsPane()
            case .captcha:      CaptchaSettingsPane()
            case .ai:           AIPrivacyPane()
            case .experimental: ExperimentalPane()
            }
        }
        .frame(width: 720, height: 470)
    }
}

// MARK: - Обновление

/// Только интервал: «Проверить все сейчас» остаётся в панели «Моих дел».
/// Роутер живёт внутри `RootView`, у сцены настроек его нет, и тащить его
/// сюда ради одной кнопки, которая и так под рукой, незачем.
private struct RefreshSettingsPane: View {
    @AppStorage(RefreshSettings.ttlKey) private var ttlHours = 6

    var body: some View {
        Form {
            Section("Фоновая проверка") {
                Picker("Проверять движение дел", selection: $ttlHours) {
                    ForEach(RefreshSettings.ttlOptions, id: \.self) { h in
                        Text("каждые \(h) ч").tag(h)
                    }
                }
                Text("Отслеживаемые дела обновляются в фоне с этим интервалом и дополнительно при открытии карточки. Проверить всё немедленно можно значком обновления в «Мои дела».")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Обновление")
    }
}

// MARK: - Поиск и Spotlight

private struct SpotlightSettingsPane: View {
    var body: some View {
        Form {
            Section("Системный поиск") {
                SpotlightSettingsToggle()
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Поиск")
    }
}

// MARK: - CAPTCHA

/// Те же два тоггла, что и в меню «Captcha», плюс статус только для чтения.
/// Число попыток (`maxAttempts`) намеренно без контрола — так решено при
/// разработке солвера, чтобы не подталкивать к лишним запросам на сайты судов.
private struct CaptchaSettingsPane: View {
    @StateObject private var settings = CaptchaSettings.shared

    var body: some View {
        Form {
            Section("Распознавание") {
                Toggle("Автоматически решать CAPTCHA", isOn: $settings.autoSolveEnabled)
                Text("Распознавание идёт на устройстве средствами Vision, изображение никуда не отправляется.")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Предобработка изображения", isOn: $settings.preprocessorEnabled)
                Text("Grayscale и двукратное увеличение перед распознаванием. Помогает на повёрнутых и перечёркнутых капчах, но на простых капчах sudrf ухудшает результат — включайте, если солвер возвращает неверный код.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Состояние") {
                LabeledContent("Решено сегодня", value: "\(CaptchaSolverLog.shared.solvedCountToday())")
                LabeledContent("Порог уверенности", value: percent(settings.minConfidence))
                LabeledContent("Солвер", value: "Vision, на устройстве")
            }

            Section {
                Button("Сбросить настройки CAPTCHA") {
                    settings.autoSolveEnabled = true
                    settings.minConfidence = 0.55
                    settings.preprocessorEnabled = false
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("CAPTCHA")
    }

    private func percent(_ value: Double) -> String {
        "\(Int(max(0, min(1, value)) * 100))%"
    }
}
