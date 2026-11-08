import SwiftUI
import AppKit
import PindoCore

extension Color {
    init(hex: String) {
        let value = UInt64(hex.dropFirst(), radix: 16) ?? 0x9AA9AF
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct ErrorBanner: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var model: AppModel
    var body: some View {
        if let error = model.errorMessage {
            VStack(alignment: .leading, spacing: 7) {
                Text(error).font(.system(size: 11)).textSelection(.enabled)
                HStack {
                    if model.repository.needsRecovery { Button(l10n("重试恢复")) { model.retryRecovery() } }
                    Button(l10n("关闭提示")) { model.notice = nil }
                }.font(.system(size: 10))
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 14)
        }
    }
}

struct TaskDisclosure<Content: View>: View {
    @Environment(\.pindoLocalization) private var l10n
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
                    Text(title)
                    Text("\(count)").font(.system(size: 10, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                    Spacer(minLength: 0)
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 10).frame(maxWidth: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(l10n(expanded ? "收起%@" : "展开%@", title)).accessibilityValue(expanded ? l10n("已展开") : l10n("已收起"))
            if expanded { content }
        }
    }
}

struct TaskPanelView: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var model: AppModel
    @State private var datePickerOpen = false
    @State private var previousOpen = false
    @State private var pendingOpen = true
    @State private var completedOpen = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "checklist").font(.system(size: 20, weight: .medium)).foregroundStyle(Color.accentColor)
                    Text("Pindo").font(.system(size: 17, weight: .semibold))
                }
                Spacer(minLength: 0)
                Button { model.togglePin() } label: {
                    Image(systemName: model.isPinned ? "pin.fill" : "pin").foregroundStyle(model.isPinned ? Color.accentColor : Color.secondary)
                        .frame(width: 30, height: 30).background(model.isPinned ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
                }.help(model.isPinned ? l10n("取消置顶，失焦后收起") : l10n("固定面板并保持在前台")).accessibilityLabel(model.isPinned ? l10n("取消置顶") : l10n("固定在前台"))
                Button { model.openSettings() } label: { Image(systemName: "gearshape").foregroundStyle(.secondary).frame(width: 30, height: 30).contentShape(Rectangle()) }
                    .help(l10n("设置")).accessibilityLabel(l10n("打开设置"))
            }.buttonStyle(.plain).padding(.horizontal, 18).frame(height: 54)
            Divider()
            ErrorBanner(model: model)
            if let id = model.noteID, let task = model.task(id) {
                NoteView(model: model, task: task).id(id)
            } else {
                taskList
                TaskComposer(model: model)
                Divider()
                dateBar
            }
        }.frame(minWidth: 360, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
            .sheet(isPresented: Binding(get: { model.editingID != nil }, set: { if !$0 { model.editingID = nil } })) {
                if let id = model.editingID, let task = model.task(id) { EditTaskView(model: model, task: task) }
            }
            .onExitCommand { if model.noteID != nil { model.leaveNote() } else { model.dismissList() } }
            .onAppear { completedOpen = model.document.preferences.expandCompleted }
            .onChange(of: model.document.preferences.expandCompleted) { _, value in completedOpen = value }
    }

    private var taskList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if !model.inProgress.isEmpty {
                    Text(l10n("进行中 · %ld", model.inProgress.count)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(8)
                    ForEach(model.inProgress) { TaskRow(model: model, task: $0) }
                }
                if model.selectedDay == model.today && !model.previous.isEmpty {
                    TaskDisclosure(title: l10n("之前未完成"), count: model.previous.count, expanded: $previousOpen) {
                        ForEach(model.previous) { TaskRow(model: model, task: $0) }
                        Button(l10n("将这 %ld 件移到今天", model.previous.count)) { model.rollover() }.font(.system(size: 11)).buttonStyle(.borderless).padding(8)
                    }
                }
                TaskDisclosure(title: l10n("未完成"), count: model.pending.count, expanded: $pendingOpen) {
                    ForEach(model.pending) { TaskRow(model: model, task: $0) }
                    if model.pending.isEmpty {
                        Text(l10n("想到一件事，就在下方记下来。")).font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 28)
                    }
                }
                if !model.completed.isEmpty {
                    TaskDisclosure(title: l10n("已完成"), count: model.completed.count, expanded: $completedOpen) {
                        ForEach(model.completed) { TaskRow(model: model, task: $0) }
                    }
                }
            }.padding(.horizontal, 12).padding(.vertical, 8)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(nsColor: .textBackgroundColor).opacity(0.45))
    }
    private var dateBar: some View {
        HStack(spacing: 3) {
            Button { model.selectedDay = model.selectedDay.adding(days: -1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 32) }.accessibilityLabel(l10n("前一天"))
            Button { datePickerOpen.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "calendar").foregroundStyle(Color.accentColor)
                    Text(model.selectedDay.date().formatted(.dateTime.month().day().locale(l10n.locale)))
                    Text(dayTitle).foregroundStyle(.secondary)
                }.lineLimit(1).frame(height: 32).contentShape(Rectangle())
            }.popover(isPresented: $datePickerOpen) { TaskCalendarView(model: model) { datePickerOpen = false } }
            Button { model.selectedDay = model.selectedDay.adding(days: 1) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 32) }.accessibilityLabel(l10n("后一天"))
            Spacer(minLength: 8)
            Menu {
                GroupMenuChoice(title: l10n("全部分组"), selected: model.groupFilter == .all) { model.groupFilter = .all }
                GroupMenuChoice(title: l10n("未分组"), selected: model.groupFilter == .ungrouped) { model.groupFilter = .ungrouped }
                ForEach(model.document.groups) { group in
                    GroupMenuChoice(title: group.name, selected: model.groupFilter == .group(group.id)) { model.groupFilter = .group(group.id) }
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text(groupTitle).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }.padding(.horizontal, 10).frame(height: 30)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(.primary.opacity(0.12)))
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 155)
                .help(l10n("筛选待办分组")).accessibilityLabel(l10n("筛选分组：%@", groupTitle))
        }.font(.system(size: 11)).buttonStyle(.plain).padding(.horizontal, 12).frame(height: 50)
            .background(DayScrollMonitor { model.selectedDay = model.selectedDay.adding(days: $0) })
    }
    private var dayTitle: String {
        if model.selectedDay == model.today { return l10n("今天") }
        if model.selectedDay == model.today.adding(days: -1) { return l10n("昨天") }
        if model.selectedDay == model.today.adding(days: 1) { return l10n("明天") }
        return model.selectedDay.date().formatted(.dateTime.weekday().locale(l10n.locale))
    }
    private var groupTitle: String {
        switch model.groupFilter {
        case .all: return l10n("全部分组")
        case .ungrouped: return l10n("未分组")
        case .group(let id): return model.group(id)?.name ?? l10n("全部分组")
        }
    }
}

struct TaskComposer: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var model: AppModel
    @FocusState private var entryFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField(l10n("添加一件要做的事…"), text: $model.listEntry).textFieldStyle(.plain).focused($entryFocused)
                .onChange(of: model.listEntry) { _, _ in model.scheduleDraftSave() }
                .onSubmit { if model.submitListEntry() { entryFocused = true } }
            GroupSelectionMenu(groups: model.document.groups, selection: $model.listEntryGroupID)
            Button { if model.submitListEntry() { entryFocused = true } } label: { Image(systemName: "return").frame(width: 24, height: 25).contentShape(Rectangle()) }
                .buttonStyle(.plain).help(l10n("添加待办")).accessibilityLabel(l10n("添加待办"))
                .disabled(model.listEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.font(.system(size: 13)).padding(12)
            .background {
                ComposerFocusTarget { entryFocused = true }
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.75))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            }
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(.primary.opacity(0.08)).allowsHitTesting(false))
            .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

/// Empty composer space is an input target, not a draggable panel background.
struct ComposerFocusTarget: NSViewRepresentable {
    let focus: () -> Void
    func makeNSView(context: Context) -> FocusView {
        let view = FocusView(); view.focus = focus; return view
    }
    func updateNSView(_ view: FocusView, context: Context) { view.focus = focus }

    final class FocusView: NSView {
        var focus: (() -> Void)?
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.makeKey()
            focus?()
        }
    }
}

struct TaskRow: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var model: AppModel
    let task: TodoItem
    @State private var hovered = false
    private var groupColor: Color { Color(hex: model.group(task.groupID)?.colorHex ?? "#9AA9AF") }
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Button { model.setPhase(task, task.phase == .completed ? .pending : .completed) } label: {
                Image(systemName: task.phase == .completed ? "checkmark.circle.fill" : "circle").font(.system(size: 19, weight: .light)).foregroundStyle(task.phase == .completed ? Color.green : Color.secondary)
                    .frame(width: 25, height: 28)
            }.buttonStyle(.plain).accessibilityLabel(task.phase == .completed ? l10n("恢复未完成：%@", task.title) : l10n("完成：%@", task.title))
            Button { model.noteID = task.id } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(task.title).font(.system(size: 15)).strikethrough(task.phase == .completed).fixedSize(horizontal: false, vertical: true)
                    if !task.note.isEmpty { Image(systemName: "note.text").font(.system(size: 9)).foregroundStyle(.secondary) }
                }.foregroundStyle(task.phase == .completed ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(l10n("打开备注：%@", task.title)).accessibilityValue(model.group(task.groupID)?.name ?? l10n("未分组"))
            Button { model.editingID = task.id } label: { Image(systemName: "pencil").frame(width: 20, height: 28) }
                .buttonStyle(.borderless).help(l10n("修改待办"))
        }.padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 4)
            .background(hovered ? Color.primary.opacity(0.045) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .modifier(GroupStripe(color: groupColor))
            .onHover { hovered = $0 }
            .contextMenu {
                Button(l10n("打开备注")) { model.noteID = task.id }
                Button(l10n("复制内容")) { _ = model.copyTask(task) }
                if task.phase == .pending { Button(l10n("标记进行中")) { model.setPhase(task, .inProgress) } }
                if task.phase == .inProgress { Button(l10n("移回未完成")) { model.setPhase(task, .pending) } }
                Divider()
                Button(l10n("上移")) { model.move(task, offset: -1) }; Button(l10n("下移")) { model.move(task, offset: 1) }
                Button(l10n("修改待办")) { model.editingID = task.id }
                Button(l10n("删除"), role: .destructive) { model.delete(task) }
            }
    }
}

struct NoteView: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var model: AppModel
    let task: TodoItem
    var onBack: (() -> Void)? = nil
    private var note: Binding<String> { Binding(get: { model.task(task.id)?.note ?? "" }, set: { model.updateNote(task.id, text: $0) }) }
    private func finishEditing() { model.flush() }
    private func back() { finishEditing(); if let onBack { onBack() } else { model.leaveNote() } }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title).font(.system(size: 20, weight: .semibold)).lineLimit(2)
                Text("\(model.group(task.groupID)?.name ?? l10n("未分组")) · \(task.plannedDay.date().formatted(.dateTime.month().day().locale(l10n.locale)))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            NoteEditor(text: note, onOutsideClick: back).id(task.id)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.primary.opacity(0.06)))
                .padding(.horizontal, 14)
            HStack {
                Text(model.saveState == .saving ? l10n("保存中…") : model.saveState == .failed ? l10n("未保存") : l10n("已保存"))
                Spacer(); Text(l10n("点击编辑区外返回 · Esc")); Text(l10n("%ld 字", note.wrappedValue.count))
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(16)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).onDisappear { model.flush() }
    }
}

struct EditTaskView: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var model: AppModel
    let task: TodoItem
    @State private var title: String
    @State private var day: Date
    @State private var groupID: UUID?
    var dismiss: (() -> Void)? = nil
    init(model: AppModel, task: TodoItem, dismiss: (() -> Void)? = nil) { self.model = model; self.task = task; self.dismiss = dismiss; _title = State(initialValue: task.title); _day = State(initialValue: task.plannedDay.date()); _groupID = State(initialValue: task.groupID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(l10n("修改待办")).font(.headline)
            TextField(l10n("事项内容"), text: $title).onSubmit(save)
            DatePicker(l10n("计划日期"), selection: $day, displayedComponents: .date)
            Picker(l10n("分组"), selection: $groupID) { Text(l10n("未分组")).tag(UUID?.none); ForEach(model.document.groups) { Text($0.name).tag(Optional($0.id)) } }
            HStack { Button(l10n("删除"), role: .destructive) { model.delete(task); close() }; Spacer(); Button(l10n("取消")) { close() }.keyboardShortcut(.cancelAction); Button(l10n("完成"), action: save).keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 340)
    }
    private func close() { if let dismiss { dismiss() } else { model.editingID = nil } }
    private func save() { if model.edit(task.id, title: title, day: DayKey(day), groupID: groupID) { close() } }
}

struct QuickAddView: View {
    @Environment(\.pindoLocalization) private var l10n
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
            HStack { Label("Pindo", systemImage: "checklist").fontWeight(.semibold); Text(l10n("快速记录待办")).foregroundStyle(.secondary); Spacer(); Button("esc") { model.hideQuickAdd() }.buttonStyle(.plain).foregroundStyle(.secondary) }.font(.system(size: 12))
            HStack(spacing: 10) {
                TextField(l10n("有什么要做的？"), text: $model.quickTitle).font(.system(size: 19)).textFieldStyle(.plain).focused($titleFocused).onSubmit(save).onChange(of: model.quickTitle) { _, _ in model.scheduleDraftSave() }
                GroupSelectionMenu(groups: model.document.groups, selection: $groupID)
            }
            HStack {
                DatePicker(l10n("日期"), selection: $date, displayedComponents: .date).labelsHidden().fixedSize()
                Spacer(); Button(showNote ? l10n("收起备注") : l10n("添加备注")) { showNote.toggle() }.font(.system(size: 11))
            }.controlSize(.small)
            if showNote {
                NoteEditor(text: $model.quickNote, accessibilityName: l10n("快速记录备注")).font(.system(size: 12)).frame(height: 100).padding(5).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6)).onChange(of: model.quickNote) { _, _ in model.scheduleDraftSave() }
            }
            ErrorBanner(model: model)
            HStack { Text(showNote ? l10n("备注中 ⌘↵ 添加 · Esc 保留草稿") : l10n("Return 添加 · Esc 保留草稿")).font(.system(size: 10)).foregroundStyle(.secondary); Spacer(); Button(l10n("添加待办"), action: save).keyboardShortcut(.return, modifiers: .command).disabled(model.quickTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
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
