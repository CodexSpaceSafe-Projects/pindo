import SwiftUI
import PindoCore

/// A flat menu: placing a Picker inside Menu adds an unwanted submenu on macOS.
struct GroupMenuChoice: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") }
            else { Text(title) }
        }
    }
}

struct GroupSelectionMenu: View {
    @Environment(\.pindoLocalization) private var l10n
    let groups: [TaskGroup]
    @Binding var selection: UUID?
    private var selected: TaskGroup? { groups.first { $0.id == selection } }
    var body: some View {
        Menu {
            GroupMenuChoice(title: l10n("未分组"), selected: selection == nil) { selection = nil }
            ForEach(groups) { group in
                GroupMenuChoice(title: group.name, selected: selection == group.id) { selection = group.id }
            }
        } label: {
            HStack(spacing: 7) {
                Circle().fill(Color(hex: selected?.colorHex ?? "#9AA9AF")).frame(width: 6, height: 6)
                Text(selected?.name ?? l10n("未分组")).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 1)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).frame(width: 130, height: 34)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(.primary.opacity(0.12)))
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(l10n("新待办分组：%@", selected?.name ?? l10n("未分组")))
    }
}

struct GroupStripe: ViewModifier {
    let color: Color
    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 6).padding(.vertical, 9).allowsHitTesting(false)
        }
    }
}
