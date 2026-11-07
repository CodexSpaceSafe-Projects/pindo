import SwiftUI
import AppKit
import PindoCore
import ServiceManagement

enum SettingsSection: String, CaseIterable { case general = "通用", todos = "管理待办", groups = "分组", shortcuts = "快捷记录", backup = "备份与恢复" }

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var section = SettingsSection.general
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(SettingsSection.allCases, id: \.self) { item in
                    Button { model.flush(); section = item } label: {
                        Text(item.rawValue).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 13).padding(.vertical, 11)
                            .background(section == item ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7)).foregroundStyle(section == item ? Color.white : Color.primary)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(12).frame(width: 150).background(.quaternary.opacity(0.3))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    Text(section.rawValue).font(.system(size: 22, weight: .semibold))
                    ErrorBanner(model: model)
                    switch section {
                    case .general: general
                    case .todos: TodoManagementView(model: model)
                    case .groups: GroupsSettings(model: model)
                    case .shortcuts: ShortcutSettings(model: model)
                    case .backup: BackupSettings(model: model)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(27)
            }
        }.frame(minWidth: 690, minHeight: 510)
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("让 Pindo 更适合你的日常使用。").font(.system(size: 12)).foregroundStyle(.secondary)
            GroupBox {
                VStack(spacing: 14) {
                    HStack { Text("外观"); Spacer(); Picker("外观", selection: Binding(get: { model.document.preferences.appearance }, set: { value in model.setPreferences { $0.appearance = value } })) { Text("跟随系统").tag(Appearance.system); Text("浅色").tag(Appearance.light); Text("深色").tag(Appearance.dark) }.labelsHidden().frame(width: 130) }
                    Divider()
                    Toggle("登录时启动", isOn: Binding(get: { model.document.preferences.launchAtLogin }, set: model.setLogin))
                }.padding(9)
            }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("新待办默认分组")
                        Spacer()
                        Picker("新待办默认分组", selection: Binding(get: { model.document.preferences.defaultGroupID }, set: { value in model.setPreferences { $0.defaultGroupID = value } })) {
                            Text("未分组").tag(UUID?.none)
                            ForEach(model.document.groups) { Text($0.name).tag(Optional($0.id)) }
                        }.labelsHidden().frame(width: 130)
                    }
                    Text("快速记录与“全部分组”下新建的待办使用此分组；在分组清单中添加时，沿用当前分组。").font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(9)
            }
            GroupBox {
                VStack(spacing: 14) {
                    Toggle("菜单栏显示今日未完成数量", isOn: Binding(get: { model.document.preferences.showTodayCount }, set: { value in model.setPreferences { $0.showTodayCount = value } }))
                    Divider()
                    Toggle("默认展开已完成", isOn: Binding(get: { model.document.preferences.expandCompleted }, set: { value in model.setPreferences { $0.expandCompleted = value } }))
                }.padding(9)
            }
            Text("当前内容会自动保存；每 30 秒检查一次，有变化才创建快照。").font(.system(size: 11)).foregroundStyle(.secondary)
            if SMAppService.mainApp.status == .requiresApproval {
                Text("登录启动正在等待系统批准。").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
            }
            Button("在访达中显示数据文件") { NSWorkspace.shared.open(model.repository.directory) }
            Button("退出 Pindo") { NSApp.terminate(nil) }.padding(.top, 12)
        }.font(.system(size: 12)).toggleStyle(.switch)
    }
}

struct GroupsSettings: View {
    @ObservedObject var model: AppModel
    @State private var newName = ""
    @State private var newColor = Color(hex: "#86A49C")
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("每条待办左侧用 3px 色条区分分组。").font(.system(size: 12)).foregroundStyle(.secondary)
            ForEach(model.document.groups) { group in GroupSettingsRow(model: model, group: group) }
            HStack {
                ColorPicker("新分组颜色", selection: $newColor, supportsOpacity: false).labelsHidden().fixedSize()
                TextField("新分组名称", text: $newName).onSubmit(add)
                Button("添加", action: add).disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.top, 6)
            Text("删除分组后，待办及其备注会保留在「未分组」。").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private func add() {
        let before = model.document.groups.count
        model.addGroup(name: newName, color: newColor.hexString)
        if model.document.groups.count > before { newName = "" }
    }
}

struct GroupSettingsRow: View {
    @ObservedObject var model: AppModel
    let group: TaskGroup
    @State private var name: String
    @FocusState private var focused: Bool
    init(model: AppModel, group: TaskGroup) { self.model = model; self.group = group; _name = State(initialValue: group.name) }
    var body: some View {
        HStack(spacing: 10) {
            ColorPicker("\(group.name)颜色", selection: Binding(get: { Color(hex: group.colorHex) }, set: { model.saveGroup(id: group.id, color: $0.hexString) }), supportsOpacity: false).labelsHidden().fixedSize()
            TextField("分组名称", text: $name).focused($focused).onSubmit(save)
                .onChange(of: focused) { _, value in if !value { save() } }
                .onChange(of: group.name) { _, value in name = value }
            Button { model.removeGroup(group.id) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("删除分组，保留事项")
        }.padding(10).background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }
    private func save() { guard name != group.name else { return }; model.saveGroup(id: group.id, name: name); name = model.group(group.id)?.name ?? name }
}

struct ShortcutSettings: View {
    @ObservedObject var model: AppModel
    @State private var quick = HotkeyBinding.quickAdd
    @State private var list = HotkeyBinding.showList
    @State private var recording: Int?
    @State private var message = "点击组合键进行录制；需要 Control、Option 或 Command。"
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("随时记录新想法，或唤出待办清单。").font(.system(size: 12)).foregroundStyle(.secondary)
            recorder(title: "快速记录", value: $quick, id: 1)
            recorder(title: "唤出待办清单", value: $list, id: 2)
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("恢复默认") { quick = .quickAdd; list = .showList; recording = nil }
                Spacer()
                Button("保存快捷键") { recording = nil; if model.setHotkeys(quick: quick, list: list) { message = "快捷键已保存。" } }
            }
            if recording != nil {
                KeyCapture { binding in
                    if let binding {
                        if !binding.isValid { message = "请加入 Control、Option 或 Command。"; return }
                        if recording == 1 { quick = binding } else { list = binding }
                        message = "点击保存后生效。"
                    } else { message = "录制已取消。" }
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
                Button(recording == id ? "请按下组合键…" : value.wrappedValue.display) { recording = id }
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
    @ObservedObject var model: AppModel
    @State private var restoreID: UUID?
    @State private var confirmRestore = false
    @State private var confirmImport = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("需要找回误改内容时，再来这里。").font(.system(size: 12)).foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 9) {
                    HStack { Text("自动快照").fontWeight(.medium); Spacer(); Text("已开启").foregroundStyle(.secondary) }
                    Text("每 30 秒检查，有变化才创建快照。").font(.system(size: 11)).foregroundStyle(.secondary)
                    Divider()
                    Text("最多 100 份 · 备份总量 30 MB").font(.system(size: 12))
                    Text("已保留 \(model.snapshotRecords.count) 份 · \(ByteCountFormatter.string(fromByteCount: Int64(model.snapshotBytes), countStyle: .decimal))").font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(9)
            }
            if let warning = model.backupWarning { Text(warning).font(.system(size: 11)).foregroundStyle(.red) }
            if model.repository.needsRecovery { Button("重试未完成的恢复") { model.retryRecovery() } }
            VStack(spacing: 0) {
                ForEach(model.snapshotRecords) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) { Text(record.label).font(.system(size: 12)); Text(record.date.formatted(date: .numeric, time: .standard)).font(.system(size: 10)).foregroundStyle(.secondary) }
                        Spacer()
                        Button("恢复…") { restoreID = record.id; confirmRestore = true }.disabled(!model.repository.canRestore)
                    }.padding(12)
                    Divider()
                }
            }.background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            HStack { Button("导出当前资料") { model.export(backup: false) }; Button("导出备份文件") { model.export(backup: true) }; Spacer(); Button("导入资料…") { model.importData() } }
            Text("恢复前会保护当前资料。当前正文自动保存与快照备份分开处理，30 秒内的中间状态不会逐次保留。").font(.system(size: 10)).foregroundStyle(.secondary)
        }.onAppear { model.refreshSnapshots() }
            .alert("恢复这个快照？", isPresented: $confirmRestore) {
                Button("取消", role: .cancel) {}
                Button("恢复") { if let restoreID { model.restore(restoreID) } }
            } message: { Text("将恢复待办、备注、分组和偏好。当前内容会先建立保护快照，恢复后仍能找回。") }
    }
}
