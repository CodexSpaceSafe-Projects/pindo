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

struct TaskPanelView: View {
    @ObservedObject var model: AppModel
    @State private var datePickerOpen = false
    @State private var previousOpen = false
    @State private var completedOpen = false
    @State private var showEntry = false
    @FocusState private var entryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { if model.noteID != nil { model.leaveNote() } } label: {
                    Label("Pindo", systemImage: "checklist").font(.system(size: 13, weight: .semibold))
                }.buttonStyle(.plain)
                Spacer()
                Button { if model.noteID != nil { model.leaveNote() } else { entryFocused = true } } label: { Image(systemName: "plus") }
                    .help("新建待办").accessibilityLabel("新建待办")
                Button { if model.noteID != nil { model.leaveNote() } else { model.openSettings() } } label: { Image(systemName: "gearshape") }
                    .help("设置").accessibilityLabel("打开设置")
            }.buttonStyle(.borderless).padding(.horizontal, 18).frame(height: 47)
            ErrorBanner(model: model)
            if let id = model.noteID, let task = model.task(id) {
                NoteView(model: model, task: task)
            } else { taskList }
            Divider()
            HStack {
                Text(model.noteID == nil ? "\(model.inProgress.count) 进行中 · \(model.pending.count) 待开始" : "点击编辑区外返回")
                Spacer()
                Label(model.saveState == .failed ? "未保存" : "仅本机", systemImage: model.saveState == .failed ? "exclamationmark.triangle" : "lock")
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 17).frame(height: 32)
                .contentShape(Rectangle()).onTapGesture { if model.noteID != nil { model.leaveNote() } }
        }.frame(width: 370, height: 610)
            .sheet(isPresented: Binding(get: { model.editingID != nil }, set: { if !$0 { model.editingID = nil } })) {
                if let id = model.editingID, let task = model.task(id) { EditTaskView(model: model, task: task) }
            }
            .onExitCommand { if model.noteID != nil { model.leaveNote() } else { model.dismissList() } }
    }

    private var taskList: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.selectedDay = model.selectedDay.adding(days: -1) } label: { Image(systemName: "chevron.left").frame(width: 28, height: 36) }.accessibilityLabel("前一天")
                Spacer()
                Button { datePickerOpen.toggle() } label: {
                    VStack(spacing: 5) {
                        HStack(spacing: 5) { Text(dayTitle).font(.system(size: 19, weight: .semibold)); Image(systemName: "chevron.down").font(.system(size: 9)) }
                        Text(model.selectedDay.date().formatted(.dateTime.month().day().weekday())).font(.system(size: 10)).foregroundStyle(.secondary)
                    }.padding(4)
                }.popover(isPresented: $datePickerOpen) { datePicker }
                Spacer()
                Button { model.selectedDay = model.selectedDay.adding(days: 1) } label: { Image(systemName: "chevron.right").frame(width: 28, height: 36) }.accessibilityLabel("后一天")
            }.buttonStyle(.plain).padding(.horizontal, 18).padding(.vertical, 9)
                .background(DayScrollMonitor { offset in model.selectedDay = model.selectedDay.adding(days: offset) })
                .gesture(DragGesture(minimumDistance: 45).onEnded { value in
                    if abs(value.translation.width) > abs(value.translation.height) { model.selectedDay = model.selectedDay.adding(days: value.translation.width < 0 ? 1 : -1) }
                })
            HStack {
                Picker("分组", selection: $model.groupFilter) {
                    Text("全部分组").tag(GroupFilter.all)
                    Text("未分组").tag(GroupFilter.ungrouped)
                    ForEach(model.document.groups) { Text($0.name).tag(GroupFilter.group($0.id)) }
                }.labelsHidden().fixedSize().controlSize(.small)
                Spacer()
                if model.selectedDay != model.today { Button("回到今天") { model.selectedDay = model.today }.font(.system(size: 10)).buttonStyle(.borderless) }
            }.padding(.horizontal, 18).padding(.bottom, 9)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if !model.inProgress.isEmpty {
                        sectionTitle("进行中", count: model.inProgress.count, detail: "跨日期保留")
                        ForEach(model.inProgress) { TaskRow(model: model, task: $0) }
                    }
                    if model.selectedDay == model.today && !model.previous.isEmpty {
                        DisclosureGroup(isExpanded: $previousOpen) {
                            ForEach(model.previous) { TaskRow(model: model, task: $0) }
                            Button("将这 \(model.previous.count) 件移到今天") { model.rollover() }.font(.system(size: 11)).buttonStyle(.borderless).padding(.leading, 10)
                        } label: { Text("之前未完成 · \(model.previous.count) 件").font(.system(size: 11)).foregroundStyle(.secondary) }.padding(.horizontal, 8).padding(.vertical, 7)
                    }
                    if !model.pending.isEmpty { sectionTitle("待开始", count: model.pending.count); ForEach(model.pending) { TaskRow(model: model, task: $0) } }
                    if model.inProgress.isEmpty && model.pending.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: "checklist").font(.system(size: 23)).foregroundStyle(.secondary)
                            Text("想到一件事，就记下来。").font(.system(size: 13))
                            Text("挑一条交给 Codex，等待时再继续下一条。").font(.system(size: 10)).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 37)
                    }
                    if !model.completed.isEmpty {
                        DisclosureGroup(isExpanded: $completedOpen) { ForEach(model.completed) { TaskRow(model: model, task: $0) } } label: {
                            Text("已完成 · \(model.completed.count) 件").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(.horizontal, 8).padding(.vertical, 10)
                    }
                }.padding(.horizontal, 11).padding(.vertical, 8)
            }
            HStack(spacing: 8) {
                Image(systemName: "plus").foregroundStyle(.secondary)
                TextField("添加一件要做的事…", text: $model.listEntry).textFieldStyle(.plain).focused($entryFocused)
                    .onChange(of: model.listEntry) { _, _ in model.scheduleDraftSave() }
                    .onSubmit { if model.addTask(title: model.listEntry, day: model.selectedDay, groupID: model.selectedGroup) { model.listEntry = ""; model.persistDrafts() } }
                Text("↵").foregroundStyle(.tertiary)
            }.font(.system(size: 12)).padding(11).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.07))).padding(.horizontal, 16).padding(.bottom, 12)
        }.onAppear { completedOpen = model.document.preferences.expandCompleted }
            .onChange(of: model.document.preferences.expandCompleted) { _, value in completedOpen = value }
    }

    private func sectionTitle(_ title: String, count: Int, detail: String = "") -> some View {
        HStack { Text("\(title) · \(count)"); Spacer(); Text(detail).font(.system(size: 9)) }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.top, 9).padding(.bottom, 4)
    }
    private var dayTitle: String {
        if model.selectedDay == model.today { return "今天" }
        if model.selectedDay == model.today.adding(days: -1) { return "昨天" }
        if model.selectedDay == model.today.adding(days: 1) { return "明天" }
        return model.selectedDay.date().formatted(.dateTime.month().day())
    }
    private var datePicker: some View {
        VStack(spacing: 5) {
            HStack { Button("今天") { model.selectedDay = model.today; datePickerOpen = false }; Button("明天") { model.selectedDay = model.today.adding(days: 1); datePickerOpen = false } }.buttonStyle(.borderless)
            Divider()
            ForEach(-3...3, id: \.self) { offset in
                let day = model.selectedDay.adding(days: offset)
                Button { model.selectedDay = day; datePickerOpen = false } label: {
                    HStack { Text(day == model.today ? "今天" : day.date().formatted(.dateTime.weekday())); Spacer(); Text(day.date().formatted(date: .abbreviated, time: .omitted)) }.font(.system(size: 12)).padding(5)
                }.buttonStyle(.plain)
            }
            Divider()
            DatePicker("跳转日期", selection: Binding(get: { model.selectedDay.date() }, set: { model.selectedDay = DayKey($0); datePickerOpen = false }), displayedComponents: .date).datePickerStyle(.field).font(.system(size: 11))
        }.padding(13).frame(width: 255)
    }
}

struct TaskRow: View {
    @ObservedObject var model: AppModel
    let task: TodoItem
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 2).fill(Color(hex: model.group(task.groupID)?.colorHex ?? "#9AA9AF")).frame(width: 3, height: 38).padding(.vertical, 3)
            Button { model.setPhase(task, task.phase == .completed ? .pending : .completed) } label: {
                Image(systemName: task.phase == .completed ? "checkmark.circle.fill" : "circle").font(.system(size: 17)).foregroundStyle(task.phase == .completed ? Color.accentColor : Color.secondary)
            }.buttonStyle(.plain).help(task.phase == .completed ? "恢复未完成" : "标记完成").accessibilityLabel(task.phase == .completed ? "恢复未完成：\(task.title)" : "完成：\(task.title)").padding(.top, 3)
            Button { model.noteID = task.id } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(task.title).font(.system(size: 13)).strikethrough(task.phase == .completed).foregroundStyle(task.phase == .completed ? Color.secondary : Color.primary).fixedSize(horizontal: false, vertical: true)
                        if !task.note.isEmpty { Image(systemName: "note.text").font(.system(size: 9)).foregroundStyle(.secondary) }
                    }
                    Text((model.group(task.groupID)?.name ?? "未分组") + (task.phase == .inProgress ? " · 进行中" : "")).font(.system(size: 10)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("打开备注：\(task.title)")
            if task.phase != .completed {
                Button { if task.phase == .pending { model.startInCodex(task) } else { model.returnToCodex() } } label: { Image(systemName: task.phase == .pending ? "play.circle" : "arrow.up.forward.app").frame(width: 22, height: 25) }
                    .buttonStyle(.borderless).help(task.phase == .pending ? "复制并切到 Codex" : "返回 Codex 应用").accessibilityLabel(task.phase == .pending ? "复制并切到 Codex：\(task.title)" : "返回 Codex")
            }
            Button { model.editingID = task.id } label: { Image(systemName: "pencil").frame(width: 20, height: 25) }.buttonStyle(.borderless).help("修改待办").accessibilityLabel("修改待办：\(task.title)")
        }.padding(.horizontal, 6).padding(.vertical, 9).fixedSize(horizontal: false, vertical: true)
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { model.noteID = task.id })
            .contextMenu {
                Button("打开备注") { model.noteID = task.id }
                Button("复制任务内容") { _ = model.copyTask(task) }
                if task.phase == .pending { Button("复制并切到 Codex") { model.startInCodex(task) }; Button("仅标记进行中") { model.setPhase(task, .inProgress) } }
                if task.phase == .inProgress { Button("返回 Codex 应用") { model.returnToCodex() }; Button("移回待开始") { model.setPhase(task, .pending) } }
                Divider()
                Button("上移") { model.move(task, offset: -1) }; Button("下移") { model.move(task, offset: 1) }
                Button("修改事项") { model.editingID = task.id }
                Button("删除", role: .destructive) { model.delete(task) }
            }
    }
}

struct NoteView: View {
    @ObservedObject var model: AppModel
    let task: TodoItem
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.leaveNote() } label: { Label("返回待办", systemImage: "chevron.left").frame(maxWidth: .infinity, minHeight: 42, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain).font(.system(size: 14))
                Text(model.saveState == .saving ? "保存中…" : model.saveState == .failed ? "未保存" : "已保存").font(.system(size: 10)).foregroundStyle(.secondary).onTapGesture { model.leaveNote() }
            }.padding(.horizontal, 21)
            VStack(alignment: .leading, spacing: 8) {
                Text("这件事的备注").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(task.title).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                Text((model.group(task.groupID)?.name ?? "未分组") + " · " + task.plannedDay.description).font(.system(size: 10)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 21).padding(.vertical, 13).contentShape(Rectangle()).onTapGesture { model.leaveNote() }
            Divider()
            HStack(spacing: 0) {
                Color.clear.frame(width: 14).contentShape(Rectangle()).onTapGesture { model.leaveNote() }
                VStack(spacing: 0) {
                    TextEditor(text: Binding(get: { model.task(task.id)?.note ?? "" }, set: { model.updateNote(task.id, text: $0) })).font(.system(size: 13)).scrollContentBackground(.hidden).padding(8).accessibilityLabel("待办备注内容")
                    HStack { Text("\(model.task(task.id)?.note.count ?? 0) 字"); Spacer(); Button("清空备注") { model.updateNote(task.id, text: "") } }.font(.system(size: 10)).foregroundStyle(.secondary).buttonStyle(.plain).padding(11)
                }.background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.08))).padding(.vertical, 13)
                Color.clear.frame(width: 14).contentShape(Rectangle()).onTapGesture { model.leaveNote() }
            }
        }.onDisappear { model.flush() }
    }
}

struct EditTaskView: View {
    @ObservedObject var model: AppModel
    let task: TodoItem
    @State private var title: String
    @State private var day: Date
    @State private var groupID: UUID?
    init(model: AppModel, task: TodoItem) { self.model = model; self.task = task; _title = State(initialValue: task.title); _day = State(initialValue: task.plannedDay.date()); _groupID = State(initialValue: task.groupID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("修改待办").font(.headline)
            TextField("事项内容", text: $title).onSubmit(save)
            DatePicker("计划日期", selection: $day, displayedComponents: .date)
            Picker("分组", selection: $groupID) { Text("未分组").tag(UUID?.none); ForEach(model.document.groups) { Text($0.name).tag(Optional($0.id)) } }
            HStack { Button("删除", role: .destructive) { model.delete(task); model.editingID = nil }; Spacer(); Button("取消") { model.editingID = nil }.keyboardShortcut(.cancelAction); Button("完成", action: save).keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 340)
    }
    private func save() { if model.edit(task.id, title: title, day: DayKey(day), groupID: groupID) { model.editingID = nil } }
}

struct QuickAddView: View {
    @ObservedObject var model: AppModel
    var sizeChanged: (CGFloat) -> Void = { _ in }
    @State private var date = Date()
    @State private var groupID: UUID?
    @State private var showNote = false
    @FocusState private var titleFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack { Label("Pindo", systemImage: "checklist").fontWeight(.semibold); Text("快速记录待办").foregroundStyle(.secondary); Spacer(); Button("esc") { model.hideQuickAdd() }.buttonStyle(.plain).foregroundStyle(.secondary) }.font(.system(size: 12))
            TextField("有什么要做的？", text: $model.quickTitle).font(.system(size: 19)).textFieldStyle(.plain).focused($titleFocused).onSubmit(save).onChange(of: model.quickTitle) { _, _ in model.scheduleDraftSave() }
            HStack {
                DatePicker("日期", selection: $date, displayedComponents: .date).labelsHidden().fixedSize()
                Picker("分组", selection: $groupID) { Text("未分组").tag(UUID?.none); ForEach(model.document.groups) { Text($0.name).tag(Optional($0.id)) } }.labelsHidden().frame(maxWidth: 130)
                Spacer(); Button(showNote ? "收起备注" : "添加备注") { showNote.toggle() }.font(.system(size: 11))
            }.controlSize(.small)
            if showNote {
                TextEditor(text: $model.quickNote).font(.system(size: 12)).scrollContentBackground(.hidden).frame(height: 100).padding(5).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6)).onChange(of: model.quickNote) { _, _ in model.scheduleDraftSave() }
            }
            ErrorBanner(model: model)
            HStack { Text(showNote ? "备注中 ⌘↵ 添加 · Esc 保留草稿" : "Return 添加 · Esc 保留草稿").font(.system(size: 10)).foregroundStyle(.secondary); Spacer(); Button("添加待办", action: save).keyboardShortcut(.return, modifiers: .command).disabled(model.quickTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(20).frame(width: 470).fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.onAppear { sizeChanged(proxy.size.height) }.onChange(of: proxy.size.height) { _, height in sizeChanged(height) }
            })
            .onAppear { titleFocused = true; showNote = !model.quickNote.isEmpty }.onExitCommand { model.hideQuickAdd() }.onDisappear { model.persistDrafts() }
    }
    private func save() {
        if model.addTask(title: model.quickTitle, note: model.quickNote, day: DayKey(date), groupID: groupID) { model.quickTitle = ""; model.quickNote = ""; model.persistDrafts(); model.hideQuickAdd() }
    }
}
