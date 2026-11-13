import SwiftUI
import AppKit

struct FontSettingsView: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var model: AppModel
    @ObservedObject private var catalog = FontFamilyCatalog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(l10n("主字体缺少某个字符时，优先使用备用字体。"))
                    .foregroundStyle(.secondary)
                if catalog.options == nil {
                    ProgressView().controlSize(.small).accessibilityLabel(l10n("正在读取字体…"))
                }
            }
            FontSettingsGroup(title: l10n("事项字体"), sample: l10n("整理本周计划 · Review the weekly plan"),
                              defaultSize: PindoFontPreferences.taskDefaultSize, options: catalog.options, choice: choice(\.task))
            FontSettingsGroup(title: l10n("备注字体"), sample: l10n("记录下一步 · Write down the next step"),
                              defaultSize: PindoFontPreferences.noteDefaultSize, options: catalog.options, choice: choice(\.note))
        }
        .font(.system(size: 12))
        .onAppear { catalog.prepare() }
    }

    private func choice(_ key: WritableKeyPath<PindoFontPreferences, PindoFontChoice>) -> Binding<PindoFontChoice> {
        Binding(get: { model.fontPreferences[keyPath: key] }, set: { value in
            var preferences = model.fontPreferences
            preferences[keyPath: key] = value
            model.setFontPreferences(preferences)
        })
    }
}

private struct FontSettingsGroup: View {
    @Environment(\.pindoLocalization) private var l10n
    let title: String
    let sample: String
    let defaultSize: Int
    let options: [FontFamilyOption]?
    @Binding var choice: PindoFontChoice

    private var primaryFamily: Binding<String?> {
        Binding(get: { choice.primaryFamily }, set: { family in
            var updated = choice
            updated.primaryFamily = family
            if updated.fallbackFamily == family { updated.fallbackFamily = nil }
            choice = updated
        })
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                fontPicker(l10n("主字体"), defaultLabel: l10n("系统字体"), selection: primaryFamily)
                fontPicker(l10n("备用字体"), defaultLabel: l10n("跟随系统"),
                           excludedFamily: choice.primaryFamily, selection: $choice.fallbackFamily)
                Stepper(value: Binding(get: { choice.effectiveSize(defaultSize: defaultSize) }, set: { choice.pointSize = $0 }),
                        in: PindoFontChoice.pointSizes) {
                    HStack {
                        Text(l10n("字号"))
                        Spacer()
                        Text(l10n("%ld 磅", choice.effectiveSize(defaultSize: defaultSize))).monospacedDigit()
                    }
                }
                Divider()
                Text(verbatim: sample).font(choice.swiftUIFont(defaultSize: defaultSize))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
        } label: {
            HStack {
                Text(verbatim: title)
                Spacer()
                Button(l10n("恢复默认")) { choice = PindoFontChoice() }
                    .buttonStyle(.borderless)
                    .disabled(choice == PindoFontChoice())
            }
        }
    }

    private func fontPicker(_ label: String, defaultLabel: String, excludedFamily: String? = nil, selection: Binding<String?>) -> some View {
        HStack {
            Text(verbatim: label)
            Spacer()
            FontFamilyPicker(label: label, defaultLabel: defaultLabel, options: options, excludedFamily: excludedFamily,
                             selection: selection)
                .frame(width: 225)
        }
    }
}

struct FontFamilyPicker: NSViewRepresentable {
    @Environment(\.pindoLocalization) private var l10n
    let label: String
    let defaultLabel: String
    let options: [FontFamilyOption]?
    let excludedFamily: String?
    @Binding var selection: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> FontFamilyPopUpButton {
        let button = FontFamilyPopUpButton(frame: .zero, pullsDown: false)
        button.menu?.autoenablesItems = false
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.prepareFontFamilyMenu(_:)),
            name: NSPopUpButton.willPopUpNotification, object: button)
        return button
    }

    func updateNSView(_ button: FontFamilyPopUpButton, context: Context) {
        context.coordinator.update(self, button: button)
    }

    static func dismantleNSView(_ button: FontFamilyPopUpButton, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator, name: NSPopUpButton.willPopUpNotification, object: button)
        coordinator.detach(button)
    }

    @MainActor final class Coordinator: NSObject {
        private var picker: FontFamilyPicker?
        private weak var button: FontFamilyPopUpButton?
        private weak var renderedMenu: NSMenu?
        private var displayedFamily: String?
        private var displayedTitle: String?
        private static let systemFontTag = 1
        private static let familyFontTag = 2

        func update(_ picker: FontFamilyPicker, button: FontFamilyPopUpButton) {
            self.picker = picker; self.button = button
            button.target = self; button.action = #selector(chooseFontFamily(_:))
            button.setAccessibilityLabel(picker.label)
            button.isEnabled = picker.options != nil
            let family = picker.selection
            let title = title(for: family, in: picker)
            guard title != displayedTitle || family != displayedFamily || renderedMenu !== button.menu,
                  let menu = button.menu else { return }
            renderedMenu = menu
            displayedTitle = title
            displayedFamily = family
            menu.removeAllItems()
            addItem(to: menu, title: title, family: family)
            button.selectItem(at: 0)
        }

        // 字体名称由后台读取，只有展开菜单时才创建菜单项。
        @objc func prepareFontFamilyMenu(_ notification: Notification) {
            guard let picker, let options = picker.options,
                  let button, notification.object as AnyObject? === button, button.canSendSettingsAction,
                  let menu = renderedMenu, button.menu === menu else { return }
            menu.removeAllItems()
            addItem(to: menu, title: picker.defaultLabel, family: nil)
            let available = options.filter { $0.id != picker.excludedFamily }
            if let selected = picker.selection, !available.contains(where: { $0.id == selected }) {
                addItem(to: menu, title: title(for: selected, in: picker), family: selected)
            }
            for option in available { addItem(to: menu, title: option.title, family: option.id) }
            button.select(menu.items.first { ($0.representedObject as? String) == picker.selection })
        }

        private func title(for family: String?, in picker: FontFamilyPicker) -> String {
            guard let family else { return picker.defaultLabel }
            guard let options = picker.options else { return family }
            if family != picker.excludedFamily, let option = options.first(where: { $0.id == family }) {
                return option.title
            }
            return picker.l10n("%@（不可用）", family)
        }

        private func addItem(to menu: NSMenu, title: String, family: String?) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = family
            item.tag = family == nil ? Self.systemFontTag : Self.familyFontTag
            menu.addItem(item)
        }

        func detach(_ button: FontFamilyPopUpButton) {
            guard self.button === button else { return }
            button.menu?.cancelTrackingWithoutAnimation()
            button.target = nil; button.action = nil
            picker = nil; self.button = nil; renderedMenu = nil
        }

        @objc func chooseFontFamily(_ sender: NSPopUpButton) {
            guard let picker, let button, sender === button, button.canSendSettingsAction,
                  let menu = renderedMenu, button.menu === menu,
                  let selected = button.selectedItem, menu.items.contains(where: { $0 === selected }) else { return }
            let family: String?
            if selected.tag == Self.systemFontTag, selected.representedObject == nil { family = nil }
            else if selected.tag == Self.familyFontTag, let value = selected.representedObject as? String,
                    picker.options?.contains(where: { $0.id == value && $0.id != picker.excludedFamily }) == true { family = value }
            else { return }
            if picker.selection != family { picker.selection = family }
        }
    }
}
