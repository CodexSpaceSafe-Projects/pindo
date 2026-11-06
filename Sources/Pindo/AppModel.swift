import AppKit
import Combine
import UniformTypeIdentifiers
import PindoCore

enum GroupFilter: Hashable { case all, ungrouped, group(UUID) }
enum SaveState { case saved, saving, failed }

@MainActor final class AppModel: ObservableObject {
    @Published private(set) var document: PindoDocument
    @Published var selectedDay = DayKey()
    @Published var groupFilter = GroupFilter.all
    @Published var noteID: UUID?
    @Published var editingID: UUID?
    @Published var errorMessage: String?
    @Published var saveState = SaveState.saved
    @Published var snapshotRecords: [SnapshotRecord] = []
    @Published var snapshotBytes = 0
    @Published var backupWarning: String?
    @Published var quickTitle: String
    @Published var quickNote: String
    @Published var listEntry: String
    @Published var quickInvocationID = UUID()
    @Published var today = DayKey()
    var openSettings: () -> Void = {}
    var hideList: () -> Void = {}
    var dismissList: () -> Void = {}
    var hideQuickAdd: () -> Void = {}
    var preferencesChanged: (Preferences) -> Void = { _ in }
    var configureHotkeys: ((Preferences) throws -> Void)?
    var configureLogin: ((Bool) throws -> Void)?
    var writeClipboard: (String) -> Bool = { text in
        let pasteboard = NSPasteboard.general; pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
    var codexApplicationURL: () -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") }
    var launchCodex: (URL, @escaping (Error?) -> Void) -> Void = { url, completion in
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in completion(error) }
    }
    private(set) var repository: PindoRepository
    private var noteSave: Task<Void, Never>?
    private var draftSave: Task<Void, Never>?
    private var snapshotTimer: Timer?

    init(directory: URL) throws {
        repository = try PindoRepository(directory: directory)
        document = repository.document
        quickTitle = UserDefaults.standard.string(forKey: "quickTitle") ?? ""
        quickNote = UserDefaults.standard.string(forKey: "quickNote") ?? ""
        listEntry = UserDefaults.standard.string(forKey: "listEntry") ?? ""
        refreshSnapshots()
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: SnapshotArchive.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureSnapshot() }
        }
        RunLoop.main.add(snapshotTimer!, forMode: .common)
    }

    func task(_ id: UUID) -> TodoItem? { document.tasks.first { $0.id == id } }
    func group(_ id: UUID?) -> TaskGroup? { document.groups.first { $0.id == id } }
    func matches(_ task: TodoItem) -> Bool {
        switch groupFilter { case .all: return true; case .ungrouped: return task.groupID == nil; case .group(let id): return task.groupID == id }
    }
    private func ordered(_ tasks: [TodoItem]) -> [TodoItem] { tasks.sorted { $0.order == $1.order ? $0.createdAt < $1.createdAt : $0.order < $1.order } }
    var inProgress: [TodoItem] { ordered(document.tasks.filter { $0.phase == .inProgress && matches($0) }) }
    var pending: [TodoItem] { ordered(document.tasks.filter { $0.phase == .pending && $0.plannedDay == selectedDay && matches($0) }) }
    var previous: [TodoItem] { ordered(document.tasks.filter { $0.phase == .pending && $0.plannedDay < today && matches($0) }) }
    var completed: [TodoItem] { ordered(document.tasks.filter { $0.phase == .completed && $0.plannedDay == selectedDay && matches($0) }) }
    var todayCount: Int { document.tasks.filter { $0.plannedDay == today && $0.phase != .completed }.count }
    var selectedGroup: UUID? { if case .group(let id) = groupFilter { return id }; return nil }

    @discardableResult func commit(_ change: (inout PindoDocument) throws -> Void) -> Bool {
        noteSave?.cancel()
        do {
            try repository.update(change)
            document = repository.document; saveState = .saved
            preferencesChanged(document.preferences)
            return true
        } catch { saveState = .failed; errorMessage = error.localizedDescription; return false }
    }

    func updateNote(_ id: UUID, text: String) {
        guard task(id)?.note != text else { return }
        do { try repository.stageNote(taskID: id, text: text); document = repository.document; saveState = .saving }
        catch { errorMessage = error.localizedDescription; return }
        noteSave?.cancel()
        noteSave = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
            self?.flush()
        }
    }
    @discardableResult func flush() -> Bool {
        noteSave?.cancel(); persistDrafts()
        do { try repository.flush(); saveState = .saved; return true }
        catch { saveState = .failed; errorMessage = error.localizedDescription; return false }
    }
    func scheduleDraftSave() {
        draftSave?.cancel(); draftSave = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
            self?.persistDrafts()
        }
    }
    func persistDrafts() {
        draftSave?.cancel()
        let defaults = UserDefaults.standard
        defaults.set(quickTitle, forKey: "quickTitle"); defaults.set(quickNote, forKey: "quickNote"); defaults.set(listEntry, forKey: "listEntry")
    }
    func leaveNote() { _ = flush(); noteID = nil }

    @discardableResult func addTask(title: String, note: String = "", day: DayKey, groupID: UUID?) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        return commit { doc in doc.tasks.append(TodoItem(title: title, note: note, plannedDay: day, groupID: groupID, order: (doc.tasks.map(\.order).max() ?? -1) + 1)) }
    }
    func setPhase(_ task: TodoItem, _ phase: TaskPhase) { _ = commit { try $0.setPhase(phase, for: task.id) } }
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
        case .inProgress: visible = inProgress
        case .completed: visible = completed
        case .pending: visible = selectedDay == today && task.plannedDay < today ? previous : pending
        }
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
        guard writeClipboard(task.handoffText) else { errorMessage = "未能复制任务，事项状态未改变。"; return false }
        return true
    }
    func startInCodex(_ task: TodoItem) {
        guard copyTask(task) else { return }
        guard let appURL = codexApplicationURL() else {
            errorMessage = "内容已复制，但未找到 Codex 桌面应用。事项状态未改变。"; return
        }
        guard commit({ try $0.setPhase(.inProgress, for: task.id) }) else { return }
        hideList(); hideQuickAdd()
        activateCodex(at: appURL)
    }
    func returnToCodex() {
        guard let url = codexApplicationURL() else { errorMessage = "未找到 Codex 桌面应用。"; return }
        hideList(); hideQuickAdd(); activateCodex(at: url)
    }
    private func activateCodex(at url: URL) {
        launchCodex(url) { [weak self] error in
            if let error { Task { @MainActor in self?.errorMessage = "任务内容已复制，未能打开 Codex：\(error.localizedDescription)" } }
        }
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
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func setLogin(_ enabled: Bool) {
        do {
            try configureLogin?(enabled)
            let previous = document.preferences.launchAtLogin
            if !commit({ $0.preferences.launchAtLogin = enabled }) { try? configureLogin?(previous) }
        } catch { errorMessage = "登录启动未能更新：\(error.localizedDescription)" }
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
        do { _ = try repository.captureIfChanged() }
        catch { backupWarning = error.localizedDescription }
        refreshSnapshots()
        preferencesChanged(document.preferences)
    }
    func refreshSnapshots() {
        snapshotRecords = repository.archive.records.reversed()
        snapshotBytes = (try? DocumentCodec.encode(repository.archive).count) ?? 0
        backupWarning = repository.backupWarning
    }
    func restore(_ id: UUID) {
        guard flush() else { return }
        do {
            let oldLogin = document.preferences.launchAtLogin
            try repository.restore(snapshotID: id)
            document = repository.document; noteID = nil; editingID = nil
            if case .group(let groupID) = groupFilter, group(groupID) == nil { groupFilter = .all }
            preferencesChanged(document.preferences); refreshSnapshots()
            if oldLogin != document.preferences.launchAtLogin { do { try configureLogin?(document.preferences.launchAtLogin) } catch { errorMessage = "资料已恢复，但登录启动未更新：\(error.localizedDescription)" } }
        } catch { errorMessage = error.localizedDescription; refreshSnapshots() }
    }
    func retryRecovery() {
        do {
            repository = try PindoRepository(directory: repository.directory)
            let oldLogin = document.preferences.launchAtLogin
            document = repository.document; noteID = nil; editingID = nil; groupFilter = .all; saveState = .saved
            preferencesChanged(document.preferences); refreshSnapshots(); errorMessage = nil
            if oldLogin != document.preferences.launchAtLogin { try configureLogin?(document.preferences.launchAtLogin) }
        } catch { errorMessage = error.localizedDescription }
    }
    func export(backup: Bool) {
        guard flush() else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = backup ? "Pindo-snapshots.json" : "Pindo-data.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let bytes = try backup ? repository.exportSnapshots() : repository.exportDocument(); try bytes.write(to: url, options: .atomic) }
        catch { errorMessage = error.localizedDescription }
    }
    func importData() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert(); alert.messageText = "导入并替换当前资料？"; alert.informativeText = "当前资料会先建立保护快照。"; alert.addButton(withTitle: "导入"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let oldLogin = document.preferences.launchAtLogin
            try repository.importDocument(Data(contentsOf: url)); document = repository.document; noteID = nil; editingID = nil; groupFilter = .all
            preferencesChanged(document.preferences); refreshSnapshots()
            if oldLogin != document.preferences.launchAtLogin { try configureLogin?(document.preferences.launchAtLogin) }
        } catch { errorMessage = error.localizedDescription }
    }
}
