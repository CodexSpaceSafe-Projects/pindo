import SwiftUI
import AppKit
import PindoCore

extension Color {
    init(hex: String) {
        let value = UInt64(hex.dropFirst(), radix: 16) ?? 0x9AA9AF
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.deviceRGB) ?? .gray
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }
}

struct ErrorBanner: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let error = model.errorMessage {
            VStack(alignment: .leading, spacing: 7) {
                Text(error).font(.system(size: 11)).textSelection(.enabled)
                HStack {
                    if model.repository.needsRecovery { Button("重试恢复") { model.retryRecovery() } }
                    Button("关闭提示") { model.errorMessage = nil }
                }.font(.system(size: 10))
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 14)
        }
    }
}

struct TaskDisclosure<Content: View>: View {
    let title: String
    let count: Int
    @Binding var expanded: Bool
    let content: Content
    init(title: String, count: Int, expanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title; self.count = count; _expanded = expanded; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    Text("\(title) · \(count)")
                    Spacer(minLength: 0)
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 10).frame(maxWidth: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(expanded ? "收起" : "展开")\(title)").accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded { content }
        }
    }
}

struct TaskPanelView: View {
    @ObservedObject var model: AppModel
    @State private var datePickerOpen = false
    @State private var previousOpen = false
    @State private var pendingOpen = true
    @State private var completedOpen = false
    @FocusState private var entryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Pindo", systemImage: "checklist").font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                if model.noteID == nil {
                    Picker("筛选分组", selection: $model.groupFilter) {
                        Text("全部分组").tag(GroupFilter.all)
                        Text("未分组").tag(GroupFilter.ungrouped)
                        ForEach(model.document.groups) { Text($0.name).tag(GroupFilter.group($0.id)) }
                    }.labelsHidden().frame(maxWidth: 125).controlSize(.mini)
                }
                Button { model.togglePin() } label: {
                    Image(systemName: model.isPinned ? "pin.fill" : "pin").foregroundStyle(model.isPinned ? Color.accentColor : Color.secondary)
                        .frame(width: 25, height: 28).contentShape(Rectangle())
                }.help(model.isPinned ? "取消置顶，失焦后收起" : "固定面板并保持在前台").accessibilityLabel(model.isPinned ? "取消置顶" : "固定在前台")
                Button { model.openSettings() } label: { Image(systemName: "gearshape").frame(width: 25, height: 28).contentShape(Rectangle()) }
                    .help("设置").accessibilityLabel("打开设置")
            }.buttonStyle(.plain).padding(.horizontal, 14).frame(height: 37)
            Divider()
            ErrorBanner(model: model)
            if let id = model.noteID, let task = model.task(id) {
                NoteView(model: model, task: task).id(id)
            } else {
                taskList
                composer
                Divider()
                dateBar
            }
        }.frame(width: 390, height: 610)
            .sheet(isPresented: Binding(get: { model.editingID != nil }, set: { if !$0 { model.editingID = nil } })) {
                if let id = model.editingID, let task = model.task(id) { EditTaskView(model: model, task: task) }
            }
            .onExitCommand { if model.noteID != nil { model.leaveNote() } else { model.dismissList() } }
            .onAppear { completedOpen = model.document.preferences.expandCompleted }
            .onChange(of: model.document.preferences.expandCompleted) { _, value in completedOpen = value }
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                if !model.inProgress.isEmpty {
                    Text("进行中 · \(model.inProgress.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(8)
                    ForEach(model.inProgress) { TaskRow(model: model, task: $0) }
                }
                if model.selectedDay == model.today && !model.previous.isEmpty {
                    TaskDisclosure(title: "之前未完成", count: model.previous.count, expanded: $previousOpen) {
                        ForEach(model.previous) { TaskRow(model: model, task: $0) }
                        Button("将这 \(model.previous.count) 件移到今天") { model.rollover() }.font(.system(size: 11)).buttonStyle(.borderless).padding(8)
                    }
                }
                TaskDisclosure(title: "未完成", count: model.pending.count, expanded: $pendingOpen) {
                    ForEach(model.pending) { TaskRow(model: model, task: $0) }
                    if model.pending.isEmpty {
                        Text("想到一件事，就在下方记下来。").font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 28)
                    }
                }
                if !model.completed.isEmpty {
                    TaskDisclosure(title: "已完成", count: model.completed.count, expanded: $completedOpen) {
                        ForEach(model.completed) { TaskRow(model: model, task: $0) }
                    }
                }
            }.padding(.horizontal, 10).padding(.vertical, 6)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var composer: some View {
        HStack(spacing: 8) {
            TextField("添加一件要做的事…", text: $model.listEntry).textFieldStyle(.plain).focused($entryFocused)
                .onChange(of: model.listEntry) { _, _ in model.scheduleDraftSave() }
                .onSubmit { if model.submitListEntry() { entryFocused = true } }
            Picker("新待办分组", selection: $model.listEntryGroupID) {
                Text("未分组").tag(UUID?.none)
                ForEach(model.document.groups) { Text($0.name).tag(Optional($0.id)) }
            }.labelsHidden().frame(width: 105).controlSize(.small)
            Button { if model.submitListEntry() { entryFocused = true } } label: { Image(systemName: "return").frame(width: 24, height: 25).contentShape(Rectangle()) }
                .buttonStyle(.plain).help("添加待办").accessibilityLabel("添加待办")
                .disabled(model.listEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.font(.system(size: 12)).padding(10)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.07))).padding(.horizontal, 12).padding(.vertical, 9)
    }
    private var dateBar: some View {
        HStack(spacing: 8) {
            Button { model.selectedDay = model.selectedDay.adding(days: -1) } label: { Image(systemName: "chevron.left").frame(width: 24, height: 30) }.accessibilityLabel("前一天")
            Button { datePickerOpen.toggle() } label: {
                HStack(spacing: 5) { Image(systemName: "calendar"); Text(dayTitle); Text(model.selectedDay.date().formatted(.dateTime.month().day())).foregroundStyle(.secondary) }
                    .frame(height: 30).contentShape(Rectangle())
            }.popover(isPresented: $datePickerOpen) { datePicker }
            Button { model.selectedDay = model.selectedDay.adding(days: 1) } label: { Image(systemName: "chevron.right").frame(width: 24, height: 30) }.accessibilityLabel("后一天")
            Spacer(minLength: 0)
            if model.selectedDay != model.today { Button("今天") { model.selectedDay = model.today } }
            Image(systemName: model.saveState == .failed ? "exclamationmark.triangle" : "lock").foregroundStyle(.secondary)
                .help(model.saveState == .failed ? "保存失败" : "仅保存在本机")
        }.font(.system(size: 11)).buttonStyle(.plain).padding(.horizontal, 12).frame(height: 35)
            .background(DayScrollMonitor { model.selectedDay = model.selectedDay.adding(days: $0) })
    }
    private var dayTitle: String {
        if model.selectedDay == model.today { return "今天" }
        if model.selectedDay == model.today.adding(days: -1) { return "昨天" }
        if model.selectedDay == model.today.adding(days: 1) { return "明天" }
        return model.selectedDay.date().formatted(.dateTime.weekday())
    }
    private var datePicker: some View {
        VStack(spacing: 8) {
            HStack {
                Button("今天") { model.selectedDay = model.today; datePickerOpen = false }
                Button("明天") { model.selectedDay = model.today.adding(days: 1); datePickerOpen = false }
            }.buttonStyle(.borderless)
            DatePicker("跳转日期", selection: Binding(get: { model.selectedDay.date() }, set: { model.selectedDay = DayKey($0) }), displayedComponents: .date).datePickerStyle(.graphical)
        }.padding(12).frame(width: 270)
    }
}

struct TaskRow: View {
    @ObservedObject var model: AppModel
    let task: TodoItem
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: model.group(task.groupID)?.colorHex ?? "#9AA9AF")).frame(width: 3, height: 32)
            Button { model.setPhase(task, task.phase == .completed ? .pending : .completed) } label: {
                Image(systemName: task.phase == .completed ? "checkmark.circle.fill" : "circle").font(.system(size: 17)).foregroundStyle(task.phase == .completed ? Color.accentColor : Color.secondary)
            }.buttonStyle(.plain).accessibilityLabel(task.phase == .completed ? "恢复未完成：\(task.title)" : "完成：\(task.title)")
            Button { model.noteID = task.id } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(task.title).font(.system(size: 13)).strikethrough(task.phase == .completed).fixedSize(horizontal: false, vertical: true)
                        if !task.note.isEmpty { Image(systemName: "note.text").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                    Text(model.group(task.groupID)?.name ?? "未分组").font(.system(size: 10)).foregroundStyle(.secondary)
                }.foregroundStyle(task.phase == .completed ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("打开备注：\(task.title)")
            Button { model.editingID = task.id } label: { Image(systemName: "pencil").frame(width: 20, height: 25) }
                .buttonStyle(.borderless).help("修改待办")
        }.padding(.horizontal, 6).padding(.vertical, 8)
            .contextMenu {
                Button("打开备注") { model.noteID = task.id }
                Button("复制内容") { _ = model.copyTask(task) }
                if task.phase == .pending { Button("标记进行中") { model.setPhase(task, .inProgress) } }
                if task.phase == .inProgress { Button("移回未完成") { model.setPhase(task, .pending) } }
                Divider()
                Button("上移") { model.move(task, offset: -1) }; Button("下移") { model.move(task, offset: 1) }
                Button("修改待办") { model.editingID = task.id }
                Button("删除", role: .destructive) { model.delete(task) }
            }
    }
}

struct NoteView: View {
    @ObservedObject var model: AppModel
    let task: TodoItem
    var onBack: (() -> Void)? = nil
    @State private var preview = false
    private var note: Binding<String> { Binding(get: { model.task(task.id)?.note ?? "" }, set: { model.updateNote(task.id, text: $0) }) }
    private func finishEditing() { NSApp.keyWindow?.makeFirstResponder(nil); model.flush() }
    private func back() { finishEditing(); if let onBack { onBack() } else { model.leaveNote() } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) { Label("返回", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                Spacer()
                Picker("备注模式", selection: Binding(get: { preview }, set: { value in finishEditing(); preview = value })) { Text("编辑").tag(false); Text("预览").tag(true) }
                    .pickerStyle(.segmented).frame(width: 120)
            }.font(.system(size: 12)).padding(12)
            Text(task.title).font(.system(size: 16, weight: .semibold)).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 10)
            Divider()
            if preview { MarkdownPreview(source: note.wrappedValue) }
            else { NoteEditor(text: note).id(task.id) }
            Divider()
            HStack {
                Text(model.saveState == .saving ? "保存中…" : model.saveState == .failed ? "未保存" : "已保存")
                Spacer(); Text("Markdown"); Text("\(note.wrappedValue.count) 字")
                Button("清空") { finishEditing(); note.wrappedValue = "" }.buttonStyle(.plain)
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(12)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).onDisappear { model.flush() }
    }
}

struct EditTaskView: View {
    @ObservedObject var model: AppModel
    let task: TodoItem
    @State private var title: String
    @State private var day: Date
    @State private var groupID: UUID?
    var dismiss: (() -> Void)? = nil
    init(model: AppModel, task: TodoItem, dismiss: (() -> Void)? = nil) { self.model = model; self.task = task; self.dismiss = dismiss; _title = State(initialValue: task.title); _day = State(initialValue: task.plannedDay.date()); _groupID = State(initialValue: task.groupID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("修改待办").font(.headline)
            TextField("事项内容", text: $title).onSubmit(save)
            DatePicker("计划日期", selection: $day, displayedComponents: .date)
            Picker("分组", selection: $groupID) { Text("未分组").tag(UUID?.none); ForEach(model.document.groups) { Text($0.name).tag(Optional($0.id)) } }
            HStack { Button("删除", role: .destructive) { model.delete(task); close() }; Spacer(); Button("取消") { close() }.keyboardShortcut(.cancelAction); Button("完成", action: save).keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 340)
    }
    private func close() { if let dismiss { dismiss() } else { model.editingID = nil } }
    private func save() { if model.edit(task.id, title: title, day: DayKey(day), groupID: groupID) { close() } }
}

struct QuickAddView: View {
    @ObservedObject var model: AppModel
    var sizeChanged: (CGFloat) -> Void
    @State private var date = Date()
    @State private var groupID: UUID?
    @State private var showNote = false
    @FocusState private var titleFocused: Bool
    @MainActor init(model: AppModel, sizeChanged: @escaping (CGFloat) -> Void = { _ in }) {
        self.model = model; self.sizeChanged = sizeChanged
        _groupID = State(initialValue: model.document.preferences.defaultGroupID)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Label("Pindo", systemImage: "checklist").fontWeight(.semibold); Text("快速记录待办").foregroundStyle(.secondary); Spacer(); Button("esc") { model.hideQuickAdd() }.buttonStyle(.plain).foregroundStyle(.secondary) }.font(.system(size: 12))
            HStack(spacing: 10) {
                TextField("有什么要做的？", text: $model.quickTitle).font(.system(size: 19)).textFieldStyle(.plain).focused($titleFocused).onSubmit(save).onChange(of: model.quickTitle) { _, _ in model.scheduleDraftSave() }
                Picker("分组", selection: $groupID) { Text("未分组").tag(UUID?.none); ForEach(model.document.groups) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden().frame(width: 110).controlSize(.small)
            }
            HStack {
                DatePicker("日期", selection: $date, displayedComponents: .date).labelsHidden().fixedSize()
                Spacer(); Button(showNote ? "收起备注" : "添加备注") { showNote.toggle() }.font(.system(size: 11))
            }.controlSize(.small)
            if showNote {
                NoteEditor(text: $model.quickNote, accessibilityName: "快速记录备注").font(.system(size: 12)).frame(height: 100).padding(5).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6)).onChange(of: model.quickNote) { _, _ in model.scheduleDraftSave() }
            }
            ErrorBanner(model: model)
            HStack { Text(showNote ? "备注中 ⌘↵ 添加 · Esc 保留草稿" : "Return 添加 · Esc 保留草稿").font(.system(size: 10)).foregroundStyle(.secondary); Spacer(); Button("添加待办", action: save).keyboardShortcut(.return, modifiers: .command).disabled(model.quickTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(20).frame(width: 470).fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.onAppear { sizeChanged(proxy.size.height) }.onChange(of: proxy.size.height) { _, height in sizeChanged(height) }
            })
            .onAppear { titleFocused = true; showNote = !model.quickNote.isEmpty }
            .onChange(of: model.document.groups.map(\.id)) { _, ids in
                if let selected = groupID, !ids.contains(selected) { groupID = model.document.preferences.defaultGroupID }
            }
            .onExitCommand { model.hideQuickAdd() }.onDisappear { model.persistDrafts() }
    }
    private func save() {
        if model.addTask(title: model.quickTitle, note: model.quickNote, day: DayKey(date), groupID: groupID) { model.quickTitle = ""; model.quickNote = ""; model.persistDrafts(); model.hideQuickAdd() }
    }
}
