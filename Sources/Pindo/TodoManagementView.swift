import SwiftUI
import PindoCore

enum ManagedTaskStatus: String, CaseIterable { case all = "全部状态", unfinished = "未完成", completed = "已完成" }

struct TodoManagementView: View {
    @Environment(\.pindoLocalization) private var l10n
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var status = ManagedTaskStatus.all
    @State private var group = GroupFilter.all
    @State private var noteID: UUID?
    @State private var editingTask: TodoItem?
    @State private var addingParentID: UUID?
    @State private var batchMode = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var pendingDeletion: Set<UUID> = []
    @State private var confirmDeletion = false
    private var tasks: [TodoItem] { model.managedTasks(query: query, status: status, group: group) }
    private var visibleIDs: Set<UUID> { Set(tasks.map(\.id)) }
    private var selectedVisibleIDs: Set<UUID> { selectedIDs.intersection(visibleIDs) }
    private var outline: [TaskOutlineRow] { model.document.taskOutline(matching: visibleIDs) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id = noteID, let task = model.task(id) {
                NoteView(model: model, task: task, onBack: { noteID = nil }).id(id).frame(height: 420)
            } else {
                TextField(l10n("搜索标题或备注"), text: $query).textFieldStyle(.roundedBorder)
                HStack {
                    Picker(l10n("状态"), selection: $status) { ForEach(ManagedTaskStatus.allCases, id: \.self) { Text(l10n($0.rawValue)).tag($0) } }
                    Picker(l10n("分组"), selection: $group) {
                        Text(l10n("全部分组")).tag(GroupFilter.all); Text(l10n("未分组")).tag(GroupFilter.ungrouped)
                        ForEach(model.document.groups) { Text($0.name).tag(GroupFilter.group($0.id)) }
                    }
                }.font(.system(size: 12))
                HStack {
                    Text(l10n("共 %ld 条 · 包含所有日期的待办", tasks.count)).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button(l10n(batchMode ? "结束批量操作" : "批量操作")) { batchMode.toggle(); clearSelection() }
                        .disabled(tasks.isEmpty && !batchMode)
                }
                if batchMode { batchControls }
                taskList
            }
        }.sheet(item: $editingTask) { task in EditTaskView(model: model, task: task, dismiss: { editingTask = nil }) }
            .sheet(isPresented: Binding(get: { addingParentID != nil }, set: { if !$0 { addingParentID = nil } })) {
                if let id = addingParentID, let parent = model.task(id) { AddSubtaskView(model: model, parent: parent) { addingParentID = nil } }
            }
            .onChange(of: model.document.groups.map(\.id)) { _, ids in
                if case .group(let id) = group, !ids.contains(id) { group = .all }
            }
            .onChange(of: query) { _, _ in clearSelection() }
            .onChange(of: status) { _, _ in clearSelection() }
            .onChange(of: group) { _, _ in clearSelection() }
            .onChange(of: tasks.map(\.id)) { _, ids in selectedIDs.formIntersection(Set(ids)) }
            .onChange(of: model.document.tasks.map(\.id)) { _, ids in
                if let id = addingParentID, !ids.contains(id) { addingParentID = nil }
                if let task = editingTask, !ids.contains(task.id) { editingTask = nil }
            }
            .alert(l10n("删除选中的 %ld 条待办？", model.document.descendantIDs(including: pendingDeletion).count), isPresented: $confirmDeletion) {
                Button(l10n("取消"), role: .cancel) { pendingDeletion = [] }
                Button(l10n("删除"), role: .destructive) {
                    let ids = pendingDeletion.intersection(Set(model.document.tasks.map(\.id)))
                    if model.applyBatch(.delete, to: ids) { selectedIDs.subtract(ids) }
                    pendingDeletion = []
                }
            } message: { Text(l10n("将删除这些事项、全部子项及其备注。")) }
    }

    private var batchControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle(l10n("全选当前结果"), isOn: Binding(
                    get: { !visibleIDs.isEmpty && selectedVisibleIDs == visibleIDs },
                    set: { selectedIDs = $0 ? visibleIDs : [] }
                )).toggleStyle(.checkbox).disabled(tasks.isEmpty)
                Spacer()
                Text(l10n("已选择 %ld 条", selectedVisibleIDs.count)).foregroundStyle(.secondary)
                Button(l10n("取消选择")) { clearSelection() }.disabled(selectedVisibleIDs.isEmpty)
            }
            HStack(spacing: 8) {
                Button(l10n("删除"), role: .destructive) { pendingDeletion = selectedVisibleIDs; confirmDeletion = true }
                Button(l10n("标记完成")) { apply(.setPhase(.completed)) }
                Button(l10n("标记未完成")) { apply(.setPhase(.pending)) }
                Menu(l10n("分组")) {
                    Button(l10n("未分组")) { apply(.setGroup(nil)) }
                    ForEach(model.document.groups) { group in Button(group.name) { apply(.setGroup(group.id)) } }
                }.fixedSize()
                Spacer(minLength: 0)
            }.disabled(selectedVisibleIDs.isEmpty)
        }.font(.system(size: 12)).controlSize(.small).padding(12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }

    private var taskList: some View {
        LazyVStack(spacing: 0) {
            ForEach(outline) { row in
                taskRow(row).padding(.leading, CGFloat(row.depth) * 16)
                Divider()
            }
            if tasks.isEmpty { Text(l10n("没有符合条件的待办")).foregroundStyle(.secondary).padding(24) }
        }
    }

    private func taskRow(_ row: TaskOutlineRow) -> some View {
        let task = row.task
        return HStack(spacing: 10) {
            if batchMode {
                Toggle(l10n("选择待办：%@", task.title), isOn: Binding(
                    get: { selectedIDs.contains(task.id) },
                    set: { if $0 { selectedIDs.insert(task.id) } else { selectedIDs.remove(task.id) } }
                )).labelsHidden().toggleStyle(.checkbox).accessibilityLabel(l10n("选择待办：%@", task.title)).disabled(row.isContext)
                TaskStatusIcon(phase: task.phase).frame(width: 25, height: 28).accessibilityHidden(true)
            } else { TaskStatusButton(model: model, task: task) }
            Button {
                if batchMode && !row.isContext {
                    if !selectedIDs.insert(task.id).inserted { selectedIDs.remove(task.id) }
                } else { noteID = task.id }
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(task.title).strikethrough(task.phase == .completed).lineLimit(2)
                    HStack(spacing: 4) {
                        Text("\(task.plannedDay.description) ·").foregroundStyle(.secondary)
                        Text(model.group(task.groupID)?.name ?? l10n("未分组")).foregroundStyle(Color(hex: model.group(task.groupID)?.colorHex ?? "#9AA9AF"))
                    }.font(.system(size: 10))
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.accessibilityLabel(l10n(batchMode ? "选择待办：%@" : "打开备注：%@", task.title))
        }.buttonStyle(.plain).font(.system(size: 12)).padding(.vertical, 12).padding(.leading, 16).padding(.trailing, 8)
            .background(batchMode && selectedIDs.contains(task.id) ? Color.accentColor.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .modifier(GroupStripe(color: Color(hex: model.group(task.groupID)?.colorHex ?? "#9AA9AF")))
            .opacity(row.isContext ? 0.65 : 1)
            .modifier(TaskDragAndDrop(model: model, task: task))
            .contextMenu {
                TaskRowMenu(edit: { editingTask = task }, openNote: { noteID = task.id },
                            move: { model.move(task, offset: $0, within: tasks.filter { $0.plannedDay == task.plannedDay }) },
                            delete: { pendingDeletion = [task.id]; confirmDeletion = true },
                            addChild: { addingParentID = task.id },
                            makeRoot: task.parentID == nil ? nil : { _ = model.relocateTask(task.id, parent: nil) },
                            canAddChild: row.depth < 2)
            }
    }

    private func apply(_ action: TaskBatchAction) {
        let ids = selectedVisibleIDs
        if model.applyBatch(action, to: ids) { selectedIDs.subtract(ids) }
    }

    private func clearSelection() {
        selectedIDs = []; pendingDeletion = []; confirmDeletion = false
    }
}

extension AppModel {
    func managedTasks(query: String, status: ManagedTaskStatus, group: GroupFilter) -> [TodoItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return document.tasks.filter { task in
            if status == .unfinished && task.phase == .completed { return false }
            if status == .completed && task.phase != .completed { return false }
            switch group { case .all: break; case .ungrouped: if task.groupID != nil { return false }; case .group(let id): if task.groupID != id { return false } }
            return text.isEmpty || task.title.localizedCaseInsensitiveContains(text) || task.note.localizedCaseInsensitiveContains(text)
        }.sorted { $0.plannedDay == $1.plannedDay ? $0.order < $1.order : $0.plannedDay > $1.plannedDay }
    }
}
