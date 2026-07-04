//  CaseMovementView.swift — Sudrf · v5 «Liquid Glass · Участники» (macOS 26)
//  Вид «движение дела» (вариант B3): блоки по инстанциям, судья в шапке блока,
//  частные жалобы — чип «обжаловано · ЧЖ» с раскрытием на месте.
//
//  v5 (по согласованному макету «Доработки Liquid Glass»):
//   • Шапка дела: категория + таблица участников (Истцы | Ответчики | Третьи
//     лица) с вертикальными разделителями и символами ролей (⚔ / щит / силуэт).
//     При >3 лиц в роли колонка сворачивается: 3 имени + «ещё N — показать
//     всех»; раскрытие даёт поиск и внутреннюю прокрутку ФИКСИРОВАННОЙ высоты —
//     шапка не «бесконечная» даже на групповом иске с 200+ истцами.
//   • Шапка лежит в safe-area поверх списка: блоки уходят под неё и мягко
//     растворяются (scroll edge effect, .soft).
//   • Тонированное стекло: шапки блоков — .glassEffect(.regular.tint(цвет
//     инстанции)), чипы «по УИД» / «обжаловано · ЧЖ» и бейдж силы — стеклянные
//     капсулы с белым текстом (вместо плоских заливок .opacity(0.12)).

import SwiftUI
import SudrfKit

// Цвет инстанции (как в прототипе).
extension CaseInstance.Level {
    var tint: Color {
        switch self {
        case .first:       return Color(red: 0.04, green: 0.48, blue: 1.0)   // синий
        case .appeal:      return Color(red: 0.37, green: 0.36, blue: 0.90)  // индиго
        case .cassation:   return Color(red: 0.11, green: 0.56, blue: 0.62)  // бирюзовый
        case .vsCassation: return Color(red: 0.72, green: 0.20, blue: 0.30)  // тёмно-красный (ВС РФ)
        case .supervisory: return Color(red: 0.55, green: 0.40, blue: 0.20)
        case .material:    return Color(red: 0.45, green: 0.45, blue: 0.50)  // серый — не инстанция пересмотра
        }
    }
}

struct CaseMovementView: View {
    let movement: CaseMovement
    @Binding var expanded: Set<String>
    var backTitle: String = "Выдача"
    var onBack: () -> Void
    var onSolveCaptcha: (CaseInstance) -> Void = { _ in }
    /// Отслеживание (раздел «Мои дела»): кнопка показывается, только если задан
    /// onTrack (из поиска). Из самой карточки мониторинга — не передаётся.
    var isTracked: Bool = false
    var onTrack: (() -> Void)? = nil
    /// Кэш и фоновое обновление (мониторинг): когда карточка получена с портала,
    /// идёт ли обновление, тихая ошибка фона, принудительный перезапрос.
    /// Из поиска не передаются — там карточка всегда живая.
    var lastUpdated: Date? = nil
    var isRefreshing: Bool = false
    var refreshNote: String? = nil
    var onRefresh: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                // Инстанции пересмотра — как раньше; материалы (13-…, 3/…, 15-…) —
                // отдельной секцией в конце: они идут в рамках дела, но инстанциями
                // не являются.
                ForEach(movement.instances.filter { $0.level != .material }) { inst in
                    InstanceBlock(instance: inst, complaints: movement.complaints,
                                  expanded: $expanded, onSolveCaptcha: onSolveCaptcha)
                }
                let materials = movement.instances.filter { $0.level == .material }
                if !materials.isEmpty {
                    Text("Материалы")
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 6)
                    ForEach(materials) { inst in
                        InstanceBlock(instance: inst, complaints: movement.complaints,
                                      expanded: $expanded, onSolveCaptcha: onSolveCaptcha)
                    }
                }
                Text("Чип «обжаловано · ЧЖ» — частная жалоба на определение; "
                   + "клик раскрывает её движение на месте.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .padding(16)
        }
        // Шапка — поверх списка: блоки растворяются под ней (.soft), а не
        // срезаются по жёсткой кромке.
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Color(nsColor: .sudrfContent))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    onBack()
                } label: {
                    Label(backTitle, systemImage: "chevron.left")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                if let onTrack {
                    if isTracked {
                        Button {} label: {
                            Label("Отслеживается", systemImage: "checkmark.circle.fill")
                        }
                        .buttonStyle(.glass).controlSize(.small).disabled(true)
                    } else {
                        Button { onTrack() } label: {
                            Label("Отслеживать", systemImage: "bell.badge")
                        }
                        .buttonStyle(.glassProminent).controlSize(.small)
                    }
                }
                if let onRefresh {
                    Button { onRefresh() } label: {
                        if isRefreshing {
                            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
                        } else {
                            Label("Обновить", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.glass).controlSize(.small)
                    .disabled(isRefreshing)
                    Text(freshnessLabel)
                        .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            if let refreshNote {
                Text(refreshNote)
                    .font(.caption2).foregroundStyle(.orange).lineLimit(1)
            }
            HStack(spacing: 8) {
                Text("Дело № \(movement.caseNumber) · движение")
                    .font(.system(size: 14.5, weight: .bold))
                ForceBadge(inForce: movement.inForce)
            }
            Text(movement.uid.isEmpty
                 ? "УИД в карточке не указан — вышестоящие инстанции не подтянуты"
                 : "УИД \(movement.uid) · вышестоящие инстанции подтянуты по УИД")
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            if movement.category != nil || !movement.parties.isEmpty {
                PartiesCard(category: movement.category, parties: movement.parties)
                    .padding(.top, 4)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 8, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// «обновляется…» / «обновлено 5 мин назад» / «обновлено только что».
    private var freshnessLabel: String {
        if isRefreshing { return "обновляется…" }
        guard let lastUpdated else { return "ещё не обновлялось" }
        let sec = Date().timeIntervalSince(lastUpdated)
        if sec < 60 { return "обновлено только что" }
        let fmt = RelativeDateTimeFormatter()
        fmt.locale = Locale(identifier: "ru_RU")
        fmt.unitsStyle = .short
        return "обновлено " + fmt.localizedString(for: lastUpdated, relativeTo: Date())
    }
}

// MARK: - Категория и участники дела (шапка, по варианту A из макета)

private struct PartiesCard: View {
    let category: String?
    let parties: CaseParties

    @State private var expandedList = false
    @State private var query = ""

    /// Свёрнутая колонка показывает не больше стольких имён.
    private static let clamp = 3
    /// Высота прокручиваемого списка в раскрытом виде — шапка фиксирована.
    private static let listHeight: CGFloat = 150

    private var columns: [PartyColumn] { parties.displayColumns }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let category {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Категория")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(category)
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(2)
                }
                if !columns.isEmpty { Divider() }
            }
            if !columns.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(columns) { col in
                        columnView(col)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if col.id != columns.last?.id { Divider() }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)   // разделители — по контенту
            }
            if expandedList {
                Button("Свернуть") { expandedList = false; query = "" }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }
        .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06)))
    }

    @ViewBuilder
    private func columnView(_ col: PartyColumn) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Заголовок роли может быть длинным («АДМИНИСТРАТИВНЫЙ ОТВЕТЧИК»,
            // «СТОРОНА ОБВИНЕНИЯ») — разрешаем перенос, иконка держится верхней.
            HStack(alignment: .top, spacing: 5) {
                icon(col.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(col.heading())
                    .font(.system(size: 10, weight: .bold)).kerning(0.5)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(.secondary)

            if expandedList && col.members.count > Self.clamp {
                // Раскрыто: поиск + список с внутренней прокруткой. При 200+
                // истцах группового иска листать бессмысленно — нужен поиск.
                TextField("Поиск по участникам…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(filtered(col.members).enumerated()), id: \.offset) { _, m in
                            memberText(m)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Self.listHeight)
            } else {
                ForEach(Array(visibleMembers(col).enumerated()), id: \.offset) { _, m in
                    memberText(m)
                }
                if !expandedList && col.members.count > Self.clamp {
                    Button {
                        expandedList = true; query = ""
                    } label: {
                        Text("ещё \(col.members.count - Self.clamp) — показать всех")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 1)
                }
            }
        }
    }

    /// Иконка стороны: атакующая сторона — текстовый глиф «⚔», остальные — SF Symbol.
    @ViewBuilder
    private func icon(_ kind: PartyIcon) -> some View {
        switch kind {
        case .plaintiff: Text("\u{2694}\u{FE0E}")
        case .shield:    Image(systemName: "shield")
        case .scales:    Image(systemName: "building.columns")
        case .person:    Image(systemName: "person")
        }
    }

    // Длинные наименования органов («Начальник ОСП по г. Сыктывкару №1 УФССП…»)
    // переносятся по словам внутри колонки, а не обрезаются «…». Под именем —
    // процессуальная под-роль («защитник», «потерпевшая», «подсудимый · …»).
    private func memberText(_ m: PartyMember) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(m.name)
                .font(.system(size: 12))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let sub = m.sub, !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func visibleMembers(_ col: PartyColumn) -> [PartyMember] {
        expandedList ? col.members : Array(col.members.prefix(Self.clamp))
    }

    private func filtered(_ members: [PartyMember]) -> [PartyMember] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return members }
        return members.filter {
            $0.name.localizedCaseInsensitiveContains(q)
            || ($0.sub?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }
}

// MARK: - Блок инстанции

private struct InstanceBlock: View {
    let instance: CaseInstance
    let complaints: [String: PrivateComplaint]
    @Binding var expanded: Set<String>
    var onSolveCaptcha: (CaseInstance) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if instance.captchaFormURL != nil {
                captchaPrompt
            }
            ForEach(instance.sessions) { s in
                SessionRow(session: s, color: instance.level.tint,
                           complaint: s.complaintID.flatMap { complaints[$0] },
                           expanded: $expanded)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // Заглушка: форма суда под капчей — автопоиск невозможен, нужен ручной ввод кода.
    private var captchaPrompt: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield").foregroundStyle(instance.level.tint)
            Text("Форма суда защищена кодом с картинки — автопоиск невозможен.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button { onSolveCaptcha(instance) } label: {
                Text("Ввести код").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.glassProminent).controlSize(.small)
        }
        .padding(.horizontal, 13).padding(.vertical, 7)
        .overlay(Divider(), alignment: .top)
    }

    // Двухстрочная шапка: суд + № + «по УИД»; ниже — судья слева, результат
    // справа. Подложка — ТОНИРОВАННОЕ СТЕКЛО цвета инстанции (§6 макета)
    // вместо плоского градиента: блик и глубина согласуются с панелями окна.
    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle().fill(instance.level.tint).frame(width: 8, height: 8)
                    .shadow(color: instance.level.tint.opacity(0.55), radius: 3)
                Text(instance.court).font(.system(size: 12.5, weight: .bold)).lineLimit(1)
                Text("№ \(instance.caseNumber)").font(.caption).foregroundStyle(.secondary)
                if instance.foundByUID { TinyChip(text: "по УИД", color: instance.level.tint) }
                if let note = instance.note {
                    TinyChip(text: note, color: Color(red: 0.72, green: 0.20, blue: 0.30))
                }
                // Акт-вложение (mos-gorsud публикует тексты файлами, не инлайном).
                if let actURL = instance.actURL {
                    Link(destination: actURL) {
                        TinyChip(text: "акт (файл)", color: instance.level.tint)
                    }
                }
                Spacer(minLength: 4)
            }
            HStack(spacing: 8) {
                if let j = instance.judge {
                    Text("судья \(j)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let r = instance.result {
                    Text(r).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.leading, 16)
        }
        .padding(EdgeInsets(top: 8, leading: 13, bottom: 7, trailing: 13))
        .background {
            Color.clear
                .glassEffect(.regular.tint(instance.level.tint.opacity(0.32)), in: .rect)
        }
    }
}

// MARK: - Строка заседания + частная жалоба

private struct SessionRow: View {
    let session: CaseSession
    let color: Color
    let complaint: PrivateComplaint?
    @Binding var expanded: Set<String>

    private var isOpen: Bool { complaint.map { expanded.contains($0.id) } ?? false }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(session.date).font(.system(size: 11.5, weight: .semibold))
                    .frame(width: 70, alignment: .leading)
                Text([session.time, session.room].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .frame(width: 62, alignment: .leading)
                Text(session.event).font(.system(size: 12)).lineLimit(1)
                if let c = complaint {
                    Button {
                        if isOpen { expanded.remove(c.id) } else { expanded.insert(c.id) }
                    } label: {
                        TinyChip(text: "обжаловано · ЧЖ \(isOpen ? "▾" : "▸")", color: color)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 8)
                if let r = session.result {
                    Text(r).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).frame(maxWidth: 200, alignment: .trailing)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 5)
            .background(isOpen ? Color.primary.opacity(0.02) : Color.clear)
            .overlay(Divider().opacity(0.6), alignment: .top)

            if let c = complaint, isOpen {
                ComplaintRows(complaint: c, color: color)
            }
        }
    }
}

private struct ComplaintRows: View {
    let complaint: PrivateComplaint
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(complaint.label).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary).lineLimit(1)
                TinyChip(text: "№ \(complaint.caseNumber)\(complaint.foundByUID ? " · по УИД" : "")",
                         color: color)
            }
            .padding(.leading, 93).padding(.trailing, 13).padding(.top, 3)
            ForEach(complaint.rows) { r in
                HStack(spacing: 8) {
                    Text(r.date).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    Text(r.event).font(.system(size: 11)).foregroundStyle(.secondary)
                    if let res = r.result {
                        Text("— \(res)").font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 93).padding(.trailing, 13)
            }
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.02))
    }
}

// MARK: - Общее

/// Чип-капсула из тонированного стекла (§6 макета): белый текст на стекле
/// цвета инстанции — вместо прежней плоской заливки color.opacity(0.12).
private struct TinyChip: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .glassEffect(.regular.tint(color.opacity(0.85)), in: .capsule)
            .lineLimit(1)
    }
}
