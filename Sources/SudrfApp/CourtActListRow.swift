import SwiftUI
import SudrfKit

/// Единая строка выбора судебного акта для живого поиска и отслеживаемого дела.
struct CourtActListRow: View {
    let title: String
    let date: String
    let stage: String
    let instanceLevel: CaseInstance.Level
    let selected: Bool
    var onSelect: () -> Void

    init(act: CaseAct, selected: Bool, onSelect: @escaping () -> Void) {
        title = CourtActPresentation.displayTitle(for: act.title)
        date = act.date
        stage = CourtActPresentation.stageLabel(act.instanceLevel)
        instanceLevel = act.instanceLevel
        self.selected = selected
        self.onSelect = onSelect
    }

    init(display: CourtActDisplay, selected: Bool, onSelect: @escaping () -> Void) {
        title = display.title
        date = display.date
        stage = display.stage
        instanceLevel = display.instanceLevel
        self.selected = selected
        self.onSelect = onSelect
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Circle().fill(instanceLevel.tint).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(date.isEmpty ? stage : "\(date) · \(stage)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(selected ? Color.accentColor.opacity(0.13) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(selected ? Color.accentColor.opacity(0.25) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
