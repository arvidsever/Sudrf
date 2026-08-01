import SwiftUI
import SudrfKit

/// Единая строка выбора судебного акта для живого поиска и отслеживаемого дела.
struct CourtActListRow: View {
    let act: CaseAct
    let selected: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Circle().fill(act.instanceLevel.tint).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(act.title)
                        .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(act.date) · \(act.courtShort)")
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
