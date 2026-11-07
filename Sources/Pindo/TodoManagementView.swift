import SwiftUI
import PindoCore

enum ManagedTaskStatus: String, CaseIterable { case all = "全部状态", unfinished = "未完成", completed = "已完成" }

struct TodoManagementView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var status = ManagedTaskStatus.all
    @State private var group = GroupFilter.all
    @State private var noteID: UUID?
    @State private var editingTask: TodoItem?
    private var tasks: [TodoItem] { model.managedTasks(query: query, status: status, group: group) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id = noteID, let task = model.task(id) {
                NoteView(model: model, task: task, onBack: { noteID = nil }).id(id).frame(height: 420)
            } else {
                TextField("搜索标题或备注", text: $query).textFieldStyle(.roundedBorder)
                HStack {
                    Picker("状态", selection: $status) { ForEach(ManagedTaskStatus.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    Picker("分组", selection: $group) {
                        Text("全部分组").tag(GroupFilter.all); Text("未分组").tag(GroupFilter.ungrouped)
                        ForEach(model.document.groups) { Text($0.name).tag(GroupFilter.group($0.id)) }
                    }
                }.font(.system(size: 12))
                Text("共 \(tasks.count) 条 · 包含所有日期的待办").font(.system(size: 11)).foregroundStyle(.secondary)
                LazyVStack(spacing: 0) {
                    ForEach(tasks) { task in
                        HStack(spacing: 10) {
                            Button { model.setPhase(task, task.phase == .completed ? .pending : .completed) } label: {
                                Image(systemName: task.phase == .completed ? "checkmark.circle.fill" : "circle")
                            }.accessibilityLabel(task.phase == .completed ? "恢复未完成" : "标记完成")
                            Button { noteID = task.id } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(task.title).strikethrough(task.phase == .completed).lineLimit(2)
                                    HStack(spacing: 4) {
                                        Text("\(task.plannedDay.description) ·").foregroundStyle(.secondary)
                                        Text(model.group(task.groupID)?.name ?? "未分组").foregroundStyle(Color(hex: model.group(task.groupID)?.colorHex ?? "#9AA9AF"))
                                    }.font(.system(size: 10))
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            Button { editingTask = task } label: { Image(systemName: "pencil") }.help("修改标题、日期和分组")
                            Button(role: .destructive) { model.delete(task) } label: { Image(systemName: "trash") }.help("删除待办")
                        }.buttonStyle(.plain).font(.system(size: 12)).padding(.vertical, 12).padding(.leading, 16)
                            .modifier(GroupStripe(color: Color(hex: model.group(task.groupID)?.colorHex ?? "#9AA9AF")))
                        Divider()
                    }
                    if tasks.isEmpty { Text("没有符合条件的待办").foregroundStyle(.secondary).padding(24) }
                }
            }
        }.sheet(item: $editingTask) { task in EditTaskView(model: model, task: task, dismiss: { editingTask = nil }) }
            .onChange(of: model.document.groups.map(\.id)) { _, ids in
                if case .group(let id) = group, !ids.contains(id) { group = .all }
            }
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
