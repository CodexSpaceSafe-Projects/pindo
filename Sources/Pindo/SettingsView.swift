import SwiftUI
import AppKit
import PindoCore
import ServiceManagement

enum SettingsSection: String, CaseIterable {
    case general = "通用", fonts = "字体", todos = "管理待办", groups = "分组", sync = "云同步", shortcuts = "快捷记录", backup = "备份与恢复"
}

struct SettingsView: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var model: AppModel
    @State private var section = SettingsSection.general
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsSection.allCases, id: \.self) { item in
                    Button { model.flush(); section = item } label: {
                        Text(l10n(item.rawValue)).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 13).padding(.vertical, 11)
                            .background(section == item ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7)).foregroundStyle(section == item ? Color.white : Color.primary)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(12).frame(width: 150).background(.quaternary.opacity(0.3))
            Divider()
            if section == .todos {
                TodoManagementView(model: model)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 19) {
                        Text(l10n(section.rawValue)).font(.system(size: 22, weight: .semibold))
                        ErrorBanner(model: model)
                        switch section {
                        case .general: general
                        case .fonts: FontSettingsView(model: model)
                        case .todos: EmptyView()
                        case .groups: GroupsSettings(model: model)
                        case .sync: SyncSettings(controller: model.cloudSync)
                        case .shortcuts: ShortcutSettings(model: model)
                        case .backup: BackupSettings(model: model)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(27)
                }
            }
        }.frame(minWidth: 690, minHeight: 510)
            .onAppear { FontFamilyCatalog.shared.prepare() }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(l10n("让 Pindo 更适合你的日常使用。")).font(.system(size: 12)).foregroundStyle(.secondary)
            GroupBox {
                VStack(spacing: 14) {
                    HStack { Text(l10n("外观")); Spacer(); Picker(l10n("外观"), selection: Binding(get: { model.document.preferences.appearance }, set: { value in model.setPreferences { $0.appearance = value } })) { Text(l10n("跟随系统")).tag(Appearance.system); Text(l10n("浅色")).tag(Appearance.light); Text(l10n("深色")).tag(Appearance.dark) }.labelsHidden().frame(width: 130) }
                    Divider()
                    HStack {
                        Text(l10n("语言"))
                        Spacer()
                        Picker(l10n("语言"), selection: Binding(get: { model.interfaceLanguage }, set: model.setInterfaceLanguage)) {
                            Text(l10n("跟随系统")).tag(InterfaceLanguage.automatic)
                            Text(verbatim: "English").tag(InterfaceLanguage.english)
                            Text(verbatim: "简体中文").tag(InterfaceLanguage.simplifiedChinese)
                        }.labelsHidden().frame(width: 130)
                    }
                    Divider()
                    Toggle(l10n("登录时启动"), isOn: Binding(get: { model.document.preferences.launchAtLogin }, set: model.setLogin))
                }.padding(9)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(l10n("新待办默认分组"))
                        Spacer()
                        Picker(l10n("新待办默认分组"), selection: Binding(get: { model.document.preferences.defaultGroupID }, set: { value in model.setPreferences { $0.defaultGroupID = value } })) {
                            Text(l10n("未分组")).tag(UUID?.none)
                            ForEach(model.document.groups) { Text($0.name).tag(Optional($0.id)) }
                        }.labelsHidden().frame(width: 130)
                    }
                    Text(l10n("快速记录与“全部分组”下新建的待办使用此分组；在分组清单中添加时，沿用当前分组。")).font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(9)
            }
            GroupBox {
                VStack(spacing: 14) {
                    Toggle(l10n("菜单栏显示今日未完成数量"), isOn: Binding(get: { model.document.preferences.showTodayCount }, set: { value in model.setPreferences { $0.showTodayCount = value } }))
                    Divider()
                    Toggle(l10n("默认展开已完成"), isOn: Binding(get: { model.document.preferences.expandCompleted }, set: { value in model.setPreferences { $0.expandCompleted = value } }))
                }.padding(9)
            }
            Text(l10n("当前内容会自动保存；每 30 秒检查一次，有变化才创建快照。")).font(.system(size: 11)).foregroundStyle(.secondary)
            if SMAppService.mainApp.status == .requiresApproval {
                Text(l10n("登录启动正在等待系统批准。")).font(.system(size: 11)).foregroundStyle(.secondary)
                Button(l10n("打开登录项设置")) { SMAppService.openSystemSettingsLoginItems() }
            }
            Button(l10n("在访达中显示数据文件")) { NSWorkspace.shared.open(model.repository.directory) }
            Button(l10n("退出 Pindo")) { NSApp.terminate(nil) }.padding(.top, 12)
        }.font(.system(size: 12)).toggleStyle(.switch)
    }
}

struct GroupsSettings: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var model: AppModel
    @State private var newName = ""
    @State private var newColor = GroupColorMenu.defaultColor
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(l10n("清单用分组名旁的色点区分分组，颜色选项同时显示色块和名称。")).font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(model.document.groups) { group in GroupSettingsRow(model: model, group: group) }
            HStack {
                GroupColorMenu(colorHex: $newColor, accessibilityName: l10n("新分组颜色")).fixedSize()
                TextField(l10n("新分组名称"), text: $newName).onSubmit(add)
                Button(l10n("添加"), action: add).disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.top, 6)
            Text(l10n("删除分组后，待办及其备注会保留在「未分组」。")).font(.system(size: 11)).foregroundStyle(.secondary)
        }.onDisappear { GroupColorEditor.shared.close() }
    }
    private func add() {
        let before = model.document.groups.count
        model.addGroup(name: newName, color: newColor)
        if model.document.groups.count > before { newName = "" }
    }
}

struct GroupSettingsRow: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var model: AppModel
    let group: TaskGroup
    @State private var name: String
    @FocusState private var focused: Bool
    init(model: AppModel, group: TaskGroup) { self.model = model; self.group = group; _name = State(initialValue: group.name) }
    var body: some View {
        HStack(spacing: 10) {
            GroupColorMenu(colorHex: Binding(get: { model.group(group.id)?.colorHex ?? group.colorHex },
                                            set: { model.saveGroup(id: group.id, color: $0) }),
                           accessibilityName: l10n("%@颜色", group.name)).fixedSize()
            TextField(l10n("分组名称"), text: $name).focused($focused).onSubmit(save)
                .onChange(of: focused) { _, value in if !value { save() } }
                .onChange(of: group.name) { _, value in name = value }
            Button { GroupColorEditor.shared.close(); model.removeGroup(group.id) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help(l10n("删除分组，保留事项"))
        }.padding(10).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
    private func save() { guard name != group.name else { return }; model.saveGroup(id: group.id, name: name); name = model.group(group.id)?.name ?? name }
}

struct ShortcutSettings: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var model: AppModel
    @State private var quick = HotkeyBinding.quickAdd
    @State private var list = HotkeyBinding.showList
    @State private var recording: Int?
    @State private var messageKey = "点击组合键进行录制；需要 Control、Option 或 Command。"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(l10n("随时记录新想法，或唤出待办清单。")).font(.system(size: 12)).foregroundStyle(.secondary)
            recorder(title: l10n("快速记录"), value: $quick, id: 1)
            recorder(title: l10n("唤出待办清单"), value: $list, id: 2)
            Text(l10n(messageKey)).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button(l10n("恢复默认")) { quick = .quickAdd; list = .showList; recording = nil }
                Spacer()
                Button(l10n("保存快捷键")) { recording = nil; if model.setHotkeys(quick: quick, list: list) { messageKey = "快捷键已保存。" } }
            }
            if recording != nil {
                KeyCapture { binding in
                    if let binding {
                        if !binding.isValid { messageKey = "请加入 Control、Option 或 Command。"; return }
                        if recording == 1 { quick = binding } else { list = binding }
                        messageKey = "点击保存后生效。"
                    } else { messageKey = "录制已取消。" }
                    recording = nil
                }.frame(width: 1, height: 1)
            }
        }.onAppear { quick = model.document.preferences.quickAddHotkey; list = model.document.preferences.listHotkey }
    }
    private func recorder(title: String, value: Binding<HotkeyBinding>, id: Int) -> some View {
        GroupBox {
            HStack {
                Toggle(title, isOn: value.enabled).toggleStyle(.switch)
                Spacer()
                Button(recording == id ? l10n("请按下组合键…") : value.wrappedValue.display) { recording = id }
                    .frame(minWidth: 130).disabled(!value.wrappedValue.enabled)
            }.padding(9)
        }
    }
}

struct KeyCapture: NSViewRepresentable {
    let capture: (HotkeyBinding?) -> Void
    func makeNSView(context: Context) -> CaptureView {
        let view = CaptureView(); view.capture = capture
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ view: CaptureView, context: Context) { view.capture = capture }
    final class CaptureView: NSView {
        var capture: ((HotkeyBinding?) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { capture?(nil); return }
            var modifiers: HotkeyModifiers = []
            if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
            if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
            if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
            if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
            let label = event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers ?? "?").uppercased()
            capture?(HotkeyBinding(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label))
        }
    }
}

struct BackupSettings: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var model: AppModel
    @State private var restoreID: UUID?
    @State private var confirmRestore = false
    @State private var confirmImport = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l10n("需要找回误改内容时，再来这里。")).font(.system(size: 12)).foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 9) {
                    HStack { Text(l10n("自动快照")).fontWeight(.medium); Spacer(); Text(l10n("已开启")).foregroundStyle(.secondary) }
                    Text(l10n("每 30 秒检查，有变化才创建快照。")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Divider()
                    Text(l10n("最多 100 份 · 备份总量 30 MB")).font(.system(size: 12))
                    Text(l10n("已保留 %ld 份 · %@", model.snapshotRecords.count, model.snapshotBytes.formatted(.byteCount(style: .decimal).locale(l10n.locale)))).font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(9)
            }
            if let warning = model.backupWarning { Text(warning).font(.system(size: 11)).foregroundStyle(.red) }
            if model.repository.needsRecovery { Button(l10n("重试未完成的恢复")) { model.retryRecovery() } }
            LazyVStack(spacing: 0) {
                ForEach(model.snapshotRecords) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) { Text(l10n.snapshotLabel(record.label)).font(.system(size: 12)); Text(record.date.formatted(Date.FormatStyle(date: .numeric, time: .standard, locale: l10n.locale))).font(.system(size: 10)).foregroundStyle(.secondary) }
                        Spacer()
                        Button(l10n("恢复…")) { restoreID = record.id; confirmRestore = true }.disabled(!model.repository.canRestore)
                    }.padding(12)
                    Divider()
                }
            }.background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            HStack { Button(l10n("导出当前资料")) { model.export(backup: false) }; Button(l10n("导出备份文件")) { model.export(backup: true) }; Spacer(); Button(l10n("导入资料…")) { model.importData() } }
            Text(l10n("恢复前会保护当前资料。当前正文自动保存与快照备份分开处理，30 秒内的中间状态不会逐次保留。")).font(.system(size: 10)).foregroundStyle(.secondary)
        }
            .alert(l10n("恢复这个快照？"), isPresented: $confirmRestore) {
                Button(l10n("取消"), role: .cancel) {}
                Button(l10n("恢复")) { if let restoreID { model.restore(restoreID) } }
            } message: { Text(l10n("将恢复待办、备注、分组和偏好。当前内容会先建立保护快照，恢复后仍能找回。")) }
    }
}
