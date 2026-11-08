import AppKit
import Combine
import UniformTypeIdentifiers
import PindoCore

enum GroupFilter: Hashable { case all, ungrouped, group(UUID) }
enum SaveState { case saved, saving, failed }

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var document: PindoDocument
    @Published var selectedDay = DayKey()
    @Published var groupFilter = GroupFilter.all { didSet { resetListEntryGroup() } }
    @Published var isPinned = false
    @Published var listEntryGroupID: UUID?
    @Published var noteID: UUID?
    @Published var editingID: UUID?
    @Published var notice: PindoNotice?
    @Published private(set) var interfaceLanguage: InterfaceLanguage
    @Published var saveState = SaveState.saved
    @Published var snapshotRecords: [SnapshotRecord] = []
    @Published var snapshotBytes = 0
    @Published private var snapshotFailure: Error?
    @Published var quickTitle: String
    @Published var quickNote: String
    @Published var listEntry: String
    @Published var quickInvocationID = UUID()
    @Published var today = DayKey()
    var openSettings: () -> Void = {}
    var dismissList: () -> Void = {}
    var hideQuickAdd: () -> Void = {}
    var preferencesChanged: (Preferences) -> Void = { _ in }
    var interfaceLanguageChanged: () -> Void = {}
    var configureHotkeys: ((Preferences) throws -> Void)?
    var configureLogin: ((Bool) throws -> Void)?
    var pinChanged: (Bool) -> Void = { _ in }
    var playFeedback: (TaskFeedback) -> Void = { $0.play() }
    var writeClipboard: (String) -> Bool = { text in
        let pasteboard = NSPasteboard.general; pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
    private(set) var repository: PindoRepository
    private let defaults: UserDefaults
    private var noteSave: Task<Void, Never>?
    private var draftSave: Task<Void, Never>?
    private var snapshotTimer: Timer?

    init(directory: URL, defaults: UserDefaults = .standard) throws {
        self.defaults = defaults
        let language = InterfaceLanguage(defaults: defaults)
        interfaceLanguage = language
        repository = try PindoRepository(directory: directory, initialDocument: PindoLocalization(language).initialDocument)
        document = repository.document
        listEntryGroupID = repository.document.preferences.defaultGroupID
        quickTitle = defaults.string(forKey: "quickTitle") ?? ""
        quickNote = defaults.string(forKey: "quickNote") ?? ""
        listEntry = defaults.string(forKey: "listEntry") ?? ""
        refreshSnapshots()
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: SnapshotArchive.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureSnapshot() }
        }
        RunLoop.main.add(snapshotTimer!, forMode: .common)
    }

    var localization: PindoLocalization { PindoLocalization(interfaceLanguage) }
    var errorMessage: String? { notice?.resolve(in: localization) }
    var backupWarning: String? {
        snapshotFailure.map { localization.error($0) } ?? repository.backupWarning.map { localization($0) }
    }

    func setInterfaceLanguage(_ language: InterfaceLanguage) {
        guard interfaceLanguage != language else { return }
        defaults.set(language.rawValue, forKey: InterfaceLanguage.defaultsKey)
        interfaceLanguage = language
        interfaceLanguageChanged()
    }

    func task(_ id: UUID) -> TodoItem? { document.tasks.first { $0.id == id } }
    func group(_ id: UUID?) -> TaskGroup? { document.groups.first { $0.id == id } }
    func matches(_ task: TodoItem) -> Bool {
        switch groupFilter { case .all: return true; case .ungrouped: return task.groupID == nil; case .group(let id): return task.groupID == id }
    }
    private func ordered(_ tasks: [TodoItem]) -> [TodoItem] { tasks.sorted { $0.order == $1.order ? $0.createdAt < $1.createdAt : $0.order < $1.order } }
    var inProgress: [TodoItem] { ordered(document.tasks.filter { $0.phase == .inProgress && matches($0) }) }
    var pending: [TodoItem] { ordered(document.tasks.filter { $0.phase == .pending && $0.plannedDay == selectedDay && matches($0) }) }
    var unfinished: [TodoItem] {
        ordered(document.tasks.filter { matches($0) && ($0.phase == .inProgress || ($0.phase == .pending && $0.plannedDay == selectedDay)) })
    }
    var previous: [TodoItem] { ordered(document.tasks.filter { $0.phase == .pending && $0.plannedDay < today && matches($0) }) }
    var completed: [TodoItem] { ordered(document.tasks.filter { $0.phase == .completed && $0.plannedDay == selectedDay && matches($0) }) }
    var todayCount: Int { document.tasks.filter { $0.plannedDay == today && $0.phase != .completed }.count }
    var selectedGroup: UUID? { if case .group(let id) = groupFilter { return id }; return nil }
    func resetListEntryGroup() {
        switch groupFilter {
        case .all: listEntryGroupID = document.preferences.defaultGroupID
        case .ungrouped: listEntryGroupID = nil
        case .group(let id): listEntryGroupID = id
        }
    }
    func togglePin() { isPinned.toggle(); pinChanged(isPinned) }

    @discardableResult func submitListEntry() -> Bool {
        guard addTask(title: listEntry, day: selectedDay, groupID: listEntryGroupID) else { return false }
        listEntry = ""; persistDrafts(); return true
    }

    @discardableResult func commit(_ change: (inout PindoDocument) throws -> Void) -> Bool {
        noteSave?.cancel()
        do {
            let previousDefault = document.preferences.defaultGroupID
            try repository.update(change)
            document = repository.document; saveState = .saved
            if groupFilter == .all && listEntryGroupID == previousDefault { listEntryGroupID = document.preferences.defaultGroupID }
            if let id = listEntryGroupID, group(id) == nil { resetListEntryGroup() }
            preferencesChanged(document.preferences)
            return true
        } catch { saveState = .failed; notice = .failure(error); return false }
    }

    func updateNote(_ id: UUID, text: String) {
        guard task(id)?.note != text else { return }
        do { try repository.stageNote(taskID: id, text: text); document = repository.document; saveState = .saving }
        catch { notice = .failure(error); return }
        noteSave?.cancel()
        noteSave = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
            self?.flush()
        }
    }
    @discardableResult func flush() -> Bool {
        noteSave?.cancel(); persistDrafts()
        do { try repository.flush(); saveState = .saved; return true }
        catch { saveState = .failed; notice = .failure(error); return false }
    }
    func scheduleDraftSave() {
        draftSave?.cancel(); draftSave = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
            self?.persistDrafts()
        }
    }
    func persistDrafts() {
        draftSave?.cancel()
        defaults.set(quickTitle, forKey: "quickTitle"); defaults.set(quickNote, forKey: "quickNote"); defaults.set(listEntry, forKey: "listEntry")
    }
    func leaveNote() { _ = flush(); noteID = nil }

    @discardableResult func addTask(title: String, note: String = "", day: DayKey, groupID: UUID?) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        let saved = commit { doc in doc.tasks.append(TodoItem(title: title, note: note, plannedDay: day, groupID: groupID, order: (doc.tasks.map(\.order).max() ?? -1) + 1)) }
        if saved { playFeedback(.added) }
        return saved
    }
    func setPhase(_ task: TodoItem, _ phase: TaskPhase) {
        guard let current = self.task(task.id), current.phase != phase else { return }
        if commit({ try $0.setPhase(phase, for: task.id) }), phase == .completed { playFeedback(.completed) }
    }
    func advancePhase(_ task: TodoItem) {
        guard let current = self.task(task.id) else { return }
        setPhase(current, current.phase.next)
    }
    func delete(_ task: TodoItem) { _ = commit { $0.tasks.removeAll { $0.id == task.id } } }
    func edit(_ id: UUID, title: String, day: DayKey, groupID: UUID?) -> Bool {
        commit { doc in
            guard let i = doc.tasks.firstIndex(where: { $0.id == id }) else { throw PindoError.missingTask }
            doc.tasks[i].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            doc.tasks[i].plannedDay = day; doc.tasks[i].groupID = groupID; doc.tasks[i].updatedAt = Date()
        }
    }
    func rollover() {
        let groupID = selectedGroup, onlyUngrouped = groupFilter == .ungrouped
        _ = commit { $0.rollover(to: today, groupID: groupID, ungroupedOnly: onlyUngrouped) }
    }
    func move(_ task: TodoItem, offset: Int) {
        let visible: [TodoItem]
        switch task.phase {
        case .inProgress: visible = unfinished
        case .completed: visible = completed
        case .pending: visible = selectedDay == today && task.plannedDay < today ? previous : unfinished
        }
        move(task, offset: offset, within: visible)
    }
    func move(_ task: TodoItem, offset: Int, within visible: [TodoItem]) {
        guard let i = visible.firstIndex(where: { $0.id == task.id }), visible.indices.contains(i + offset) else { return }
        let other = visible[i + offset]
        _ = commit { doc in
            let all = doc.tasks.sorted { $0.order == $1.order ? $0.createdAt < $1.createdAt : $0.order < $1.order }
            for (index, item) in all.enumerated() { if let n = doc.tasks.firstIndex(where: { $0.id == item.id }) { doc.tasks[n].order = index } }
            guard let a = doc.tasks.firstIndex(where: { $0.id == task.id }), let b = doc.tasks.firstIndex(where: { $0.id == other.id }) else { return }
            let order = doc.tasks[a].order; doc.tasks[a].order = doc.tasks[b].order; doc.tasks[b].order = order
        }
    }

    func copyTask(_ task: TodoItem) -> Bool {
        let text = task.title + (task.note.isEmpty ? "" : "\n\n" + task.note)
        guard writeClipboard(text) else { notice = .text("未能复制待办内容。"); return false }
        return true
    }

    func setPreferences(_ change: (inout Preferences) -> Void) {
        var next = document.preferences; change(&next)
        _ = commit { $0.preferences = next }
    }
    func setHotkeys(quick: HotkeyBinding, list: HotkeyBinding) -> Bool {
        let previous = document.preferences
        var next = previous; next.quickAddHotkey = quick; next.listHotkey = list
        do {
            var validation = document; validation.preferences = next; _ = try validation.validated()
            try configureHotkeys?(next)
            if commit({ $0.preferences = next }) { return true }
            try? configureHotkeys?(previous); return false
        } catch { notice = .failure(error); return false }
    }
    func setLogin(_ enabled: Bool) {
        do {
            try configureLogin?(enabled)
            let previous = document.preferences.launchAtLogin
            if !commit({ $0.preferences.launchAtLogin = enabled }) { try? configureLogin?(previous) }
        } catch { notice = .failure(error, context: "登录启动未能更新：%@") }
    }
    func saveGroup(id: UUID, name: String? = nil, color: String? = nil) {
        _ = commit { doc in
            guard let i = doc.groups.firstIndex(where: { $0.id == id }) else { return }
            if let name { doc.groups[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let color { doc.groups[i].colorHex = color }
        }
    }
    func addGroup(name: String, color: String) { _ = commit { $0.groups.append(TaskGroup(name: name.trimmingCharacters(in: .whitespacesAndNewlines), colorHex: color)) } }
    func removeGroup(_ id: UUID) {
        if commit({ $0.removeGroup(id) }), groupFilter == .group(id) { groupFilter = .all }
    }

    func captureSnapshot() {
        let newToday = DayKey()
        if today != newToday { if selectedDay == today { selectedDay = newToday }; today = newToday }
        guard flush() else { return }
        do { _ = try repository.captureIfChanged(); snapshotFailure = nil }
        catch { snapshotFailure = error }
        refreshSnapshots()
        preferencesChanged(document.preferences)
    }
    func refreshSnapshots() {
        snapshotRecords = repository.archive.records.reversed()
        snapshotBytes = (try? DocumentCodec.encode(repository.archive).count) ?? 0
    }
    func restore(_ id: UUID) {
        guard flush() else { return }
        do {
            let oldLogin = document.preferences.launchAtLogin
            try repository.restore(snapshotID: id)
            document = repository.document; noteID = nil; editingID = nil
            resetListEntryGroup()
            if case .group(let groupID) = groupFilter, group(groupID) == nil { groupFilter = .all }
            preferencesChanged(document.preferences); refreshSnapshots()
            if oldLogin != document.preferences.launchAtLogin { do { try configureLogin?(document.preferences.launchAtLogin) } catch { notice = .failure(error, context: "资料已恢复，但登录启动未更新：%@") } }
        } catch { notice = .failure(error); refreshSnapshots() }
    }
    func retryRecovery() {
        do {
            repository = try PindoRepository(directory: repository.directory, initialDocument: localization.initialDocument)
            snapshotFailure = nil
            let oldLogin = document.preferences.launchAtLogin
            document = repository.document; noteID = nil; editingID = nil; groupFilter = .all; saveState = .saved
            preferencesChanged(document.preferences); refreshSnapshots(); notice = nil
            if oldLogin != document.preferences.launchAtLogin { try configureLogin?(document.preferences.launchAtLogin) }
        } catch { notice = .failure(error) }
    }
    func export(backup: Bool) {
        guard flush() else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = backup ? "Pindo-snapshots.json" : "Pindo-data.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let bytes = try backup ? repository.exportSnapshots() : repository.exportDocument(); try bytes.write(to: url, options: .atomic) }
        catch { notice = .failure(error) }
    }
    func importData() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let l10n = localization
        let alert = NSAlert()
        alert.messageText = l10n("导入并替换当前资料？")
        alert.informativeText = l10n("当前资料会先建立保护快照。")
        alert.addButton(withTitle: l10n("导入"))
        alert.addButton(withTitle: l10n("取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let oldLogin = document.preferences.launchAtLogin
            try repository.importDocument(Data(contentsOf: url)); document = repository.document; noteID = nil; editingID = nil; groupFilter = .all
            preferencesChanged(document.preferences); refreshSnapshots()
            if oldLogin != document.preferences.launchAtLogin { try configureLogin?(document.preferences.launchAtLogin) }
        } catch { notice = .failure(error) }
    }
}
