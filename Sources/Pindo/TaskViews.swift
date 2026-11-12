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

struct TaskPanelView: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var model: AppModel
    @State private var datePickerOpen = false
    @State private var addingParentID: UUID?
    @State private var deletingTask: TodoItem?

    var body: some View {
        let noteTask = model.noteID.flatMap(model.task)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(nsColor: TaskBranchPalette.paper))
                        .frame(width: 24, height: 24)
                        .background(Color(nsColor: TaskBranchPalette.accent), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityHidden(true)
                    Text("Pindo").font(.system(size: 17, weight: .semibold))
                }
                Spacer(minLength: 0)
                Button { model.togglePin() } label: {
                    Image(systemName: model.isPinned ? "pin.fill" : "pin")
                        .foregroundStyle(model.isPinned ? Color(nsColor: TaskBranchPalette.accent) : Color.secondary)
                        .frame(width: 30, height: 30)
                        .background(model.isPinned ? Color(nsColor: TaskBranchPalette.accentWash) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }.help(model.isPinned ? l10n("取消置顶，失焦后收起") : l10n("固定面板并保持在前台")).accessibilityLabel(model.isPinned ? l10n("取消置顶") : l10n("固定在前台"))
                Button { model.openSettings() } label: { Image(systemName: "gearshape").foregroundStyle(.secondary).frame(width: 30, height: 30).contentShape(Rectangle()) }
                    .help(l10n("设置")).accessibilityLabel(l10n("打开设置"))
            }.buttonStyle(.plain).padding(.horizontal, 18).frame(height: 48)
                .background(Color(nsColor: TaskBranchPalette.toolbar))
            Divider()
            ErrorBanner(model: model)
            ZStack {
                // 打开备注时保留原清单，返回时直接显示原来的滚动位置。
                VStack(spacing: 0) {
                    taskList
                    TaskComposer(model: model)
                    Divider()
                    dateBar
                }.opacity(noteTask == nil ? 1 : 0)
                    .allowsHitTesting(noteTask == nil)
                    .disabled(noteTask != nil)
                    .accessibilityHidden(noteTask != nil)
                if let noteTask {
                    NoteView(model: model, task: noteTask).id(noteTask.id)
                }
            }
        }.frame(minWidth: 360, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
            .background(Color(nsColor: TaskBranchPalette.paper))
            .sheet(isPresented: Binding(get: { model.editingID != nil }, set: { if !$0 { model.editingID = nil } })) {
                if let id = model.editingID, let task = model.task(id) { EditTaskView(model: model, task: task) }
            }
            .sheet(isPresented: Binding(get: { addingParentID != nil }, set: { if !$0 { addingParentID = nil } })) {
                if let id = addingParentID, let parent = model.task(id) { AddSubtaskView(model: model, parent: parent) { addingParentID = nil } }
            }
            .onChange(of: model.document.tasks.map(\.id)) { _, ids in
                if let id = addingParentID, !ids.contains(id) { addingParentID = nil }
            }
            .onExitCommand { if model.noteID != nil { model.leaveNote() } else { model.dismissList() } }
            .onDisappear { model.endTaskDrag() }
            .onChange(of: model.selectedDay) { _, _ in model.endTaskDrag() }
            .onChange(of: model.groupFilter) { _, _ in model.endTaskDrag() }
            .alert(l10n("删除此事项及全部子项？"), isPresented: Binding(get: { deletingTask != nil }, set: { if !$0 { deletingTask = nil } })) {
                Button(l10n("取消"), role: .cancel) { deletingTask = nil }
                Button(l10n("删除"), role: .destructive) { if let task = deletingTask { model.delete(task) }; deletingTask = nil }
            } message: { Text(l10n("将删除 %ld 条待办及其备注。", deletingTask.map { model.document.descendantIDs(including: [$0.id]).count } ?? 0)) }
    }

    private var taskList: some View {
        let sections = model.outlineSections
        let overdueIDs = Set(sections.previous.map(\.id)).intersection(Set(model.previous.map(\.id)))
        var groups: [TaskOutlineSection] = []
        if model.selectedDay == model.today && !sections.previous.isEmpty {
            groups.append(TaskOutlineSection(id: "previous", title: l10n("之前未完成"), count: overdueIDs.count, initiallyExpanded: false,
                                             rows: sections.previous, footer: l10n("将这 %ld 件移到今天", overdueIDs.count), completed: false))
        }
        groups.append(TaskOutlineSection(id: "unfinished", title: l10n("未完成"), count: sections.unfinished.filter { $0.task.phase != .completed }.count,
                                         rows: sections.unfinished, emptyText: l10n("想到一件事，就在下方记下来。"), completed: false))
        if !sections.completed.isEmpty {
            groups.append(TaskOutlineSection(id: "completed", title: l10n("已完成"), count: sections.completed.count,
                                             initiallyExpanded: model.document.preferences.expandCompleted, rows: sections.completed, completed: true))
        }
        return VStack(spacing: 0) {
            dayOverview
            TaskOutlineList(model: model, sections: groups,
                            onSelect: { model.noteID = $0.id }, onSelectNote: { model.noteID = $0.id }, onEdit: { model.editingID = $0.id },
                            onAddChild: { addingParentID = $0.id },
                            onDelete: { task in
                                if model.document.descendantIDs(including: [task.id]).count > 1 { deletingTask = task } else { model.delete(task) }
                            }, onMove: { model.move($0, offset: $1) }, onFooter: { model.rollover(taskIDs: overdueIDs) })
        }.overlay(alignment: .bottom) {
            if model.draggedTaskID != nil {
                Text(l10n("上下拖动排序，左右拖动调整层级")).font(.system(size: 11)).foregroundStyle(.secondary).padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7)).padding(6).allowsHitTesting(false)
            }
        }.padding(.horizontal, 12).padding(.bottom, 4).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var dayOverview: some View {
        let date = model.selectedDay.date()
        let day = model.selectedDay
        let tasks = model.document.tasks.filter { $0.plannedDay == day && model.matches($0) }
        let counts = DayTaskCount.grouped(tasks)[day] ?? DayTaskCount()
        let total = counts.unfinished + counts.completed
        let accent = Color(nsColor: TaskBranchPalette.accent)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(dayTitle).font(.system(size: 21, weight: .semibold)).accessibilityAddTraits(.isHeader)
                Text(date.formatted(.dateTime.month().day().weekday(.abbreviated).locale(l10n.locale)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text(l10n("已完成 %ld / %ld", counts.completed, total))
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: TaskBranchPalette.line))
                    Capsule().fill(accent)
                        .frame(width: total == 0 ? 0 : 76 * CGFloat(counts.completed) / CGFloat(total))
                }.frame(width: 76, height: 3).accessibilityHidden(true)
            }
        }.padding(.horizontal, 5).padding(.top, 12).padding(.bottom, 5)
    }
    private var dateBar: some View {
        HStack(spacing: 3) {
            Button { model.selectedDay = model.selectedDay.adding(days: -1) } label: { Image(systemName: "chevron.left").frame(width: 22, height: 32) }.accessibilityLabel(l10n("前一天"))
            Button { datePickerOpen.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "calendar").foregroundStyle(Color(nsColor: TaskBranchPalette.accent))
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
        }.font(.system(size: 11)).buttonStyle(.plain).padding(.horizontal, 12).frame(height: 44)
            .background(Color(nsColor: TaskBranchPalette.toolbar))
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
            Button { if model.submitListEntry() { entryFocused = true } } label: {
                Image(systemName: "return").font(.system(size: 13)).frame(width: 24, height: 25).contentShape(Rectangle())
            }
                .buttonStyle(.plain).help(l10n("添加待办")).accessibilityLabel(l10n("添加待办"))
                .disabled(model.listEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.font(model.fontPreferences.task.swiftUIFont(defaultSize: 13)).padding(12)
            .background {
                RoundedRectangle(cornerRadius: 11).fill(Color(nsColor: .textBackgroundColor).opacity(0.75))
                    .contentShape(RoundedRectangle(cornerRadius: 11))
                    .onTapGesture { entryFocused = true }
            }
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(.primary.opacity(0.08)).allowsHitTesting(false))
            .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

struct NoteView: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var model: AppModel
    let task: TodoItem
    var onBack: (() -> Void)? = nil
    private var note: Binding<String> { Binding(get: { model.task(task.id)?.note ?? "" }, set: { model.updateNote(task.id, text: $0) }) }
    private func back() {
        if let onBack {
            model.flush()
            onBack()
        } else {
            model.leaveNote()
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title).font(model.fontPreferences.task.swiftUIFont(defaultSize: 20, variant: .semibold)).lineLimit(2)
                Text("\(model.group(task.groupID)?.name ?? l10n("未分组")) · \(task.plannedDay.date().formatted(.dateTime.month().day().locale(l10n.locale)))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            NoteEditor(text: note, fontChoice: model.fontPreferences.note, onOutsideClick: back).id(task.id)
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
    @State private var confirmDelete = false
    var dismiss: (() -> Void)? = nil
    init(model: AppModel, task: TodoItem, dismiss: (() -> Void)? = nil) { self.model = model; self.task = task; self.dismiss = dismiss; _title = State(initialValue: task.title); _day = State(initialValue: task.plannedDay.date()); _groupID = State(initialValue: task.groupID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(l10n("修改待办")).font(.headline)
            TextField(l10n("事项内容"), text: $title)
                .font(model.fontPreferences.task.swiftUIFont(defaultSize: 13)).onSubmit(save)
            DatePicker(l10n("计划日期"), selection: $day, displayedComponents: .date)
            Picker(l10n("分组"), selection: $groupID) { Text(l10n("未分组")).tag(UUID?.none); ForEach(model.document.groups) { Text($0.name).tag(Optional($0.id)) } }
            if let metadata = model.metadata(for: task.id) {
                TaskMetadataView(metadata: metadata) { model.copyTaskMetadata(task.id) }
            }
            HStack { Button(l10n("删除"), role: .destructive) { if model.document.descendantIDs(including: [task.id]).count > 1 { confirmDelete = true } else { model.delete(task); close() } }; Spacer(); Button(l10n("取消")) { close() }.keyboardShortcut(.cancelAction); Button(l10n("完成"), action: save).keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24).frame(width: 340)
            .alert(l10n("删除此事项及全部子项？"), isPresented: $confirmDelete) {
                Button(l10n("取消"), role: .cancel) {}
                Button(l10n("删除"), role: .destructive) { model.delete(task); close() }
            } message: { Text(l10n("将删除 %ld 条待办及其备注。", model.document.descendantIDs(including: [task.id]).count)) }
    }
    private func close() { if let dismiss { dismiss() } else { model.editingID = nil } }
    private func save() { if model.edit(task.id, title: title, day: DayKey(day), groupID: groupID) { close() } }
}

struct AddSubtaskView: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var model: AppModel
    let parent: TodoItem
    let close: () -> Void
    @State private var title = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l10n("添加子项")).font(.headline)
            Text(parent.title).font(model.fontPreferences.task.swiftUIFont(defaultSize: 13)).foregroundStyle(.secondary).lineLimit(2)
            TextField(l10n("事项内容"), text: $title)
                .font(model.fontPreferences.task.swiftUIFont(defaultSize: 13)).focused($focused).onSubmit(save)
            ErrorBanner(model: model)
            HStack {
                Button(l10n("取消"), action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button(l10n("添加"), action: save).keyboardShortcut(.defaultAction).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 340).onAppear { focused = true }
    }
    private func save() {
        guard let current = model.task(parent.id) else { model.notice = .failure(PindoError.missingParent); return }
        if model.addTask(title: title, day: current.plannedDay, groupID: current.groupID, parentID: current.id) { close() }
    }
}
