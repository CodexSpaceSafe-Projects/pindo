import AppKit
import SwiftUI
import QuartzCore
import PindoCore

struct TaskOutlineSection: Equatable {
    let id: String
    var title: String? = nil
    var count = 0
    var initiallyExpanded = true
    var rows: [TaskOutlineRow]
    var emptyText: String? = nil
    var footer: String? = nil
    var completed: Bool? = nil
}

/// A native tree owns mouse tracking, disclosure controls and the dragging session.
/// In particular, the title is not a Button that can consume the drag's mouseDown.
struct TaskOutlineList: NSViewRepresentable {
    @ObservedObject var model: AppModel
    var sections: [TaskOutlineSection]
    var management = false
    var batchMode = false
    var selectedIDs: Set<UUID> = []
    var onSelect: (TodoItem) -> Void
    var onSelectNote: (TodoItem) -> Void
    var onEdit: (TodoItem) -> Void
    var onAddChild: (TodoItem) -> Void
    var onDelete: (TodoItem) -> Void
    var onMove: (TodoItem, Int) -> Void
    var onFooter: () -> Void = {}

    func makeCoordinator() -> TaskOutlineCoordinator { TaskOutlineCoordinator(self) }

    func makeNSView(context: Context) -> TaskOutlineScrollView {
        let scroll = TaskOutlineScrollView()
        let outline = TaskNativeOutlineView()
        outline.autoresizingMask = [.width]
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("task"))
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.headerView = nil; outline.style = .plain
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.indentationPerLevel = 16
        outline.selectionHighlightStyle = .none
        outline.allowsMultipleSelection = false; outline.allowsEmptySelection = true
        outline.focusRingType = .none
        outline.backgroundColor = .textBackgroundColor.withAlphaComponent(0.45)
        outline.registerForDraggedTypes([TaskOutlineCoordinator.pasteboardType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        outline.dataSource = context.coordinator; outline.delegate = context.coordinator
        outline.target = context.coordinator; outline.action = #selector(TaskOutlineCoordinator.clicked(_:))
        outline.contextMenuForNode = { [weak coordinator = context.coordinator] node in coordinator?.menu(for: node) }
        outline.onDragExit = { [weak coordinator = context.coordinator] in coordinator?.exitDestination() }
        scroll.documentView = outline; scroll.drawsBackground = false
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        context.coordinator.outline = outline; context.coordinator.scroll = scroll
        scroll.onWidthChange = { [weak coordinator = context.coordinator] in coordinator?.updateRowHeights() }
        context.coordinator.update(self)
        return scroll
    }

    func updateNSView(_ nsView: TaskOutlineScrollView, context: Context) { context.coordinator.update(self) }

    static func dismantleNSView(_ nsView: TaskOutlineScrollView, coordinator: TaskOutlineCoordinator) {
        coordinator.cancelDrag()
        nsView.onWidthChange = nil
        (nsView.documentView as? NSOutlineView)?.delegate = nil
        (nsView.documentView as? NSOutlineView)?.dataSource = nil
    }
}

@MainActor final class TaskOutlineNode: NSObject {
    let key: String
    var row: TaskOutlineRow?
    var label = ""
    var isSection = false
    var isFooter = false
    var completed: Bool?
    var children: [TaskOutlineNode] = []
    init(_ key: String) { self.key = key }
}

@MainActor final class TaskOutlineScrollView: NSScrollView {
    var onWidthChange: (() -> Void)?
    private var previousWidth: CGFloat = 0
    override func layout() {
        super.layout()
        if abs(contentSize.width - previousWidth) > 0.5 {
            previousWidth = contentSize.width
            onWidthChange?()
        }
    }
}

@MainActor final class TaskNativeOutlineView: NSOutlineView {
    var contextMenuForNode: ((TaskOutlineNode) -> NSMenu?)?
    var onDragExit: (() -> Void)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        var ancestor: NSView? = hit
        while let view = ancestor, view !== self {
            // Status and batch checkboxes remain real controls. Passive labels go to
            // NSOutlineView, which distinguishes a click from the native drag threshold.
            if view is TaskOutlineButton { return hit }
            if view is TaskOutlineCell { return self }
            ancestor = view.superview
        }
        return hit // Includes AppKit's own disclosure triangle.
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let node = item(atRow: row) as? TaskOutlineNode else { return nil }
        return contextMenuForNode?(node)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender)
        onDragExit?()
    }
}

@MainActor final class TaskOutlineCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let pasteboardType = NSPasteboard.PasteboardType("com.pindo.task-id")
    private(set) var content: TaskOutlineList
    weak var outline: TaskNativeOutlineView?
    weak var scroll: TaskOutlineScrollView?
    private var cache: [String: TaskOutlineNode] = [:]
    private(set) var roots: [TaskOutlineNode] = []
    private var collapsed: Set<String> = []
    private var knownSections: Set<String> = []
    private var lastSections: [TaskOutlineSection]?
    private var lastSelected: Set<UUID> = []
    private var lastGroups: [TaskGroup] = []
    private var lastBatch = false
    private var lastLanguage: InterfaceLanguage?
    private var lastPreviewID: UUID?
    private var restoringExpansion = false
    private var collapsedBeforeDrag: Set<String>?
    private var pendingPreview: DispatchWorkItem?
    private var proposal: TaskOutlineDrop?
    private var proposalReadyAt: TimeInterval = 0
    private var previewScheduledAt: TimeInterval = 0
    private var lastPreviewAt: TimeInterval = 0
    private var dragGeneration = 0
    private var lastDragItemID: String?
    private var structure: TaskOutlineStructure?
    private var disclosureNeedsRestore = false
    private var heightCache: [String: TaskOutlineHeight] = [:]
    private var lastCompletedPreference: Bool?
    private var menuActions: [TaskOutlineMenuAction] = []

    init(_ content: TaskOutlineList) { self.content = content }

    private func node(_ key: String) -> TaskOutlineNode {
        if let node = cache[key] { return node }
        let node = TaskOutlineNode(key); cache[key] = node; return node
    }

    func taskNode(_ id: UUID) -> TaskOutlineNode? { cache[id.uuidString] }

    func update(_ content: TaskOutlineList) {
        self.content = content
        guard let outline else { return }
        let previousPreviewID = lastPreviewID
        let previewID = content.model.taskDragPreview == nil ? nil : content.model.draggedTaskID
        let rowSizingChanged = lastBatch != content.batchMode
        let refreshAllVisible = lastGroups != content.model.document.groups || lastSelected != content.selectedIDs || lastBatch != content.batchMode || lastLanguage != content.model.interfaceLanguage
        let completedPreference = content.model.document.preferences.expandCompleted
        if let old = lastCompletedPreference, old != completedPreference {
            if completedPreference { collapsed.remove("section.completed") } else { collapsed.insert("section.completed") }
        }
        lastCompletedPreference = completedPreference
        if content.model.draggedTaskID == nil, let original = collapsedBeforeDrag {
            collapsed = original
            collapsedBeforeDrag = nil
            pendingPreview?.cancel(); pendingPreview = nil; proposal = nil
            disclosureNeedsRestore = true
        }
        guard lastSections != content.sections || refreshAllVisible || lastPreviewID != previewID || disclosureNeedsRestore else { return }
        let oldRows = cache.compactMapValues { $0.row }, oldLabels = cache.mapValues(\.label)
        lastSections = content.sections; lastSelected = content.selectedIDs
        lastGroups = content.model.document.groups
        lastBatch = content.batchMode; lastLanguage = content.model.interfaceLanguage; lastPreviewID = previewID
        for node in cache.values { node.children = [] }
        roots = []
        var used: Set<String> = []
        for section in content.sections {
            let header = node("section." + section.id)
            header.isSection = true; header.label = (section.title ?? "") + "  \(section.count)"
            header.completed = section.completed
            used.insert(header.key)
            if knownSections.insert(header.key).inserted, !section.initiallyExpanded { collapsed.insert(header.key) }
            for row in section.rows {
                let item = node(row.id.uuidString); item.row = row; used.insert(item.key)
            }
            let shown = Set(section.rows.map(\.id))
            for row in section.rows {
                let item = node(row.id.uuidString)
                if let parent = row.task.parentID, shown.contains(parent) { node(parent.uuidString).children.append(item) }
                else { header.children.append(item) }
            }
            if section.rows.isEmpty, let text = section.emptyText {
                let empty = node("empty." + section.id); empty.label = text; header.children.append(empty); used.insert(empty.key)
            }
            if let text = section.footer {
                let footer = node("footer." + section.id); footer.label = text; footer.isFooter = true
                header.children.append(footer); used.insert(footer.key)
            }
            if section.title == nil { roots.append(contentsOf: header.children) } else { roots.append(header) }
        }
        var children: [String: [String]] = [TaskOutlineStructure.root: roots.map(\.key)]
        func index(_ nodes: [TaskOutlineNode]) {
            for node in nodes { children[node.key] = node.children.map(\.key); index(node.children) }
        }
        index(roots)
        let next = TaskOutlineStructure(children: children)
        let move = structure?.singleMove(to: next, preferredID: content.model.draggedTaskID?.uuidString ?? lastDragItemID)
        let sameStructure = structure == next
        let titleChanges = Set(cache.keys.filter { oldRows[$0]?.task.title != cache[$0]?.row?.task.title })
        let changedRows = Set(cache.keys.filter { key in
            guard let old = oldRows[key], let new = cache[key]?.row else { return oldLabels[key] != cache[key]?.label }
            let a = old.task, b = new.task
            return a.title != b.title || a.phase != b.phase || a.note.isEmpty != b.note.isEmpty || a.groupID != b.groupID || a.plannedDay != b.plannedDay || old.isContext != new.isContext
        })
        restoringExpansion = true
        if let move {
            // Preserve cells, disclosure and the clip position. Native item moves
            // animate the whole branch; unrelated rows are never reconstructed.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                outline.beginUpdates()
                outline.moveItem(at: move.oldIndex, inParent: cache[move.oldParent], to: move.newIndex, inParent: cache[move.newParent])
                outline.endUpdates()
            }
            for key in Set([move.oldParent, move.newParent]) {
                if let parent = cache[key] { outline.reloadItem(parent, reloadChildren: false) }
            }
            restoreDisclosure(in: roots)
        } else if !sameStructure {
            let origin = scroll?.contentView.bounds.origin ?? .zero
            outline.reloadData()
            restoreDisclosure(in: roots)
            if let scroll { scroll.contentView.scroll(to: origin); scroll.reflectScrolledClipView(scroll.contentView) }
        } else if disclosureNeedsRestore {
            restoreDisclosure(in: roots)
        }
        restoringExpansion = false
        structure = next; disclosureNeedsRestore = false
        cache = cache.filter { used.contains($0.key) }
        heightCache = heightCache.filter { used.contains($0.key) }
        let previewKeys = Set([previousPreviewID?.uuidString, previewID?.uuidString].compactMap { $0 })
        refreshVisibleCells(changed: refreshAllVisible ? nil : changedRows.union(previewKeys))
        if (!sameStructure && move == nil) || rowSizingChanged { updateRowHeights() }
        else {
            var changed = titleChanges
            if let move {
                func invalidate(_ node: TaskOutlineNode) { changed.insert(node.key); node.children.forEach(invalidate) }
                if let item = cache[move.id] { invalidate(item) }
            }
            let rows = changed.compactMap { cache[$0].map { outline.row(forItem: $0) } }.filter { $0 >= 0 }
            if !rows.isEmpty { invalidateHeights(IndexSet(rows)) }
        }
        if content.model.draggedTaskID == nil { lastDragItemID = nil }
    }

    private func refreshVisibleCells(changed: Set<String>?) {
        guard let outline else { return }
        let visible = outline.rows(in: outline.visibleRect)
        guard visible.location != NSNotFound else { return }
        for row in visible.location..<min(NSMaxRange(visible), outline.numberOfRows) {
            guard let node = outline.item(atRow: row) as? TaskOutlineNode,
                  changed == nil || changed!.contains(node.key),
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? TaskOutlineCell else { continue }
            cell.configure(node: node, content: content)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? TaskOutlineNode)?.children.count ?? roots.count }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? TaskOutlineNode)?.children ?? roots)[index] }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? TaskOutlineNode)?.children.isEmpty == false }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? TaskOutlineNode).map { $0.row != nil || $0.isSection || $0.isFooter } ?? false }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? TaskOutlineNode, let row = node.row else { return 36 }
        let width = outlineView.bounds.width - CGFloat(outlineView.level(forItem: node) + 1) * 16
        if let cached = heightCache[node.key], cached.title == row.task.title, cached.width == width, cached.management == content.management, cached.batch == content.batchMode { return cached.height }
        let height = TaskOutlineCell.rowHeight(title: row.task.title, width: width, management: content.management, batch: content.batchMode)
        heightCache[node.key] = TaskOutlineHeight(title: row.task.title, width: width, management: content.management, batch: content.batchMode, height: height)
        return height
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? TaskOutlineNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("TaskOutlineCell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? TaskOutlineCell) ?? TaskOutlineCell()
        cell.identifier = identifier
        cell.configure(node: node, content: content)
        return cell
    }

    @objc func clicked(_ sender: NSOutlineView) {
        guard content.model.draggedTaskID == nil, sender.clickedRow >= 0, let node = sender.item(atRow: sender.clickedRow) as? TaskOutlineNode else { return }
        if let row = node.row { content.onSelect(row.task) }
        else if node.isSection {
            if sender.isItemExpanded(node) { sender.collapseItem(node) } else { sender.expandItem(node) }
        } else if node.isFooter { content.onFooter() }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) { expansionChanged(notification, expanded: false) }
    func outlineViewItemDidExpand(_ notification: Notification) { expansionChanged(notification, expanded: true) }
    func outlineViewItemWillCollapse(_ notification: Notification) { rememberDisclosure(notification, expanded: false) }
    func outlineViewItemWillExpand(_ notification: Notification) { rememberDisclosure(notification, expanded: true) }

    private func rememberDisclosure(_ notification: Notification, expanded: Bool) {
        guard !restoringExpansion, content.model.draggedTaskID == nil,
              let node = notification.userInfo?["NSObject"] as? TaskOutlineNode else { return }
        // Collapsing a branch can also notify for its hidden descendants. Those
        // notifications are not separate user choices to close each child branch.
        var ancestor = outline?.parent(forItem: node) as? TaskOutlineNode
        while let parent = ancestor {
            if collapsed.contains(parent.key) { return }
            ancestor = outline?.parent(forItem: parent) as? TaskOutlineNode
        }
        if expanded { collapsed.remove(node.key) } else { collapsed.insert(node.key) }
    }

    private func expansionChanged(_ notification: Notification, expanded: Bool) {
        guard !restoringExpansion, let node = notification.userInfo?["NSObject"] as? TaskOutlineNode else { return }
        rememberDisclosure(notification, expanded: expanded)
        // AppKit can discard hidden descendants' expansion bits on reload. Reapply
        // our disclosure state when revealing a branch, outside its delegate stack.
        DispatchQueue.main.async { [weak self, weak node] in
            guard let self, let node, let outline = self.outline else { return }
            if expanded, outline.isItemExpanded(node), self.content.model.draggedTaskID == nil {
                self.restoringExpansion = true
                self.restoreDisclosure(in: node.children)
                self.restoringExpansion = false
            }
            self.updateRowHeights()
        }
    }

    private func restoreDisclosure(in nodes: [TaskOutlineNode]) {
        guard let outline else { return }
        for node in nodes where !node.children.isEmpty {
            let isPreviewParent = proposal?.parent?.uuidString == node.key && content.model.taskDragPreview != nil
            if !collapsed.contains(node.key) || isPreviewParent {
                if !outline.isItemExpanded(node) { outline.expandItem(node) }
                restoreDisclosure(in: node.children)
            } else if outline.isItemExpanded(node) { outline.collapseItem(node) }
        }
    }

    func updateRowHeights() {
        guard let outline else { return }
        invalidateHeights(IndexSet(integersIn: 0..<outline.numberOfRows))
    }

    private func invalidateHeights(_ rows: IndexSet) {
        // Height notifications otherwise create their own competing default animation.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            outline?.noteHeightOfRows(withIndexesChanged: rows)
        }
    }

    // Same native pasteboard/validate/accept separation as FSNotes' SidebarOutlineView.
    // This implementation is independent and uses Pindo's validated subtree operations.
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard !content.batchMode, let row = (item as? TaskOutlineNode)?.row else { return nil }
        let writer = NSPasteboardItem()
        writer.setString(row.id.uuidString, forType: Self.pasteboardType)
        return writer
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        guard draggedItems.count == 1, let id = (draggedItems.first as? TaskOutlineNode)?.row?.id else { return }
        beginDrag(id)
        session.animatesToStartingPositionsOnCancelOrFail = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func beginDrag(_ id: UUID) {
        dragGeneration += 1; lastDragItemID = id.uuidString; lastPreviewAt = 0
        collapsedBeforeDrag = collapsed
        _ = content.model.beginTaskDrag(id)
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { cancelDrag() }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard info.draggingSource as? NSOutlineView === outlineView,
              let text = info.draggingPasteboard.string(forType: Self.pasteboardType),
              UUID(uuidString: text) == content.model.draggedTaskID else { return [] }
        return validate(item: item as? TaskOutlineNode, index: index) ? .move : []
    }

    /// A child index is an insertion boundary in the *currently displayed* tree.
    /// Convert it to a stable sibling ID before projecting onto the unchanged base.
    func drop(item: TaskOutlineNode?, index: Int) -> TaskOutlineDrop? {
        guard let source = content.model.draggedTaskID, let sourceTask = content.model.task(source) else { return nil }
        if item?.row?.id == source { return proposal } // Cursor now overlaps the projected row.
        if let row = item?.row {
            let children = item!.children.compactMap(\.row)
            let before = index < 0 ? nil : children.dropFirst(index).first { $0.id != source }?.id
            let completed = index < 0 ? content.model.task(row.id)?.phase == .completed : insertionClass(children, index: index, source: sourceTask)
            return TaskOutlineDrop(parent: row.id, before: before, completed: completed)
        }
        guard item?.isSection == true || (item == nil && content.management) else { return nil }
        let children = (item?.children ?? roots).compactMap(\.row)
        let completed = item?.completed ?? insertionClass(children, index: index, source: sourceTask)
        return TaskOutlineDrop(parent: nil, before: index < 0 ? nil : children.dropFirst(index).first { $0.id != source }?.id, completed: completed)
    }

    private func insertionClass(_ rows: [TaskOutlineRow], index: Int, source: TodoItem) -> Bool {
        let isCompleted = source.phase == .completed
        let boundary = index < 0 ? rows.count : min(index, rows.count)
        let adjacent = [rows.prefix(boundary).last { $0.id != source.id }, rows.dropFirst(boundary).first { $0.id != source.id }].compactMap { $0 }
        // A line between the two classes belongs to either adjoining region. Lines
        // surrounded by the opposite class are forbidden, including in management.
        return adjacent.isEmpty || adjacent.contains { (content.model.task($0.id)?.phase == .completed) == isCompleted } ? isCompleted : !isCompleted
    }

    @discardableResult func validate(item: TaskOutlineNode?, index: Int) -> Bool {
        guard let next = drop(item: item, index: index) else { exitDestination(); return false }
        if proposal == next { return true }
        guard content.model.canPreviewTaskDrag(parent: next.parent, before: next.before, completed: next.completed) else { exitDestination(); return false }
        if proposal != next {
            proposal = next
            let currentParent = content.model.draggedTaskID.flatMap { content.model.task($0)?.parentID }
            let nestsUnderNewParent = index < 0 && next.parent != nil && next.parent != currentParent
            proposalReadyAt = ProcessInfo.processInfo.systemUptime + (nestsUnderNewParent ? 0.18 : 0)
            schedulePreview()
        }
        return true
    }

    private func schedulePreview() {
        let now = ProcessInfo.processInfo.systemUptime
        let deadline = max(proposalReadyAt, lastPreviewAt + 1.0 / 30.0)
        if pendingPreview != nil {
            if deadline >= previewScheduledAt { return }
            pendingPreview?.cancel()
        }
        let generation = dragGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.dragGeneration == generation else { return }
            self.pendingPreview = nil
            guard let next = self.proposal else { return }
            if ProcessInfo.processInfo.systemUptime + 0.001 < self.proposalReadyAt { self.schedulePreview(); return }
            self.lastPreviewAt = ProcessInfo.processInfo.systemUptime
            _ = self.content.model.previewTaskDrag(parent: next.parent, before: next.before, completed: next.completed)
        }
        pendingPreview = work; previewScheduledAt = deadline
        // One pending frame consumes the latest target. Continuous movement cannot
        // starve the preview, unlike cancel-and-restart debouncing on every event.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - now), execute: work)
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard info.draggingSource as? NSOutlineView === outlineView,
              let text = info.draggingPasteboard.string(forType: Self.pasteboardType),
              UUID(uuidString: text) == content.model.draggedTaskID else { return false }
        return accept(item: item as? TaskOutlineNode, index: index)
    }

    @discardableResult func accept(item: TaskOutlineNode?, index: Int) -> Bool {
        pendingPreview?.cancel(); pendingPreview = nil
        guard let next = drop(item: item, index: index) else { cancelDrag(); return false }
        let saved = content.model.acceptTaskDrag(parent: next.parent, before: next.before, completed: next.completed)
        if saved, let parent = next.parent { collapsedBeforeDrag?.remove(parent.uuidString) }
        restoreExpansionAfterDrag()
        proposal = nil
        return saved
    }

    func exitDestination() {
        dragGeneration += 1
        pendingPreview?.cancel(); pendingPreview = nil; proposal = nil
        // Never publish from a synchronous AppKit validation callback.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.proposal == nil else { return }
            self.content.model.clearTaskDragPreview()
        }
    }

    func cancelDrag() {
        dragGeneration += 1
        pendingPreview?.cancel(); pendingPreview = nil; proposal = nil
        content.model.endTaskDrag(); restoreExpansionAfterDrag()
    }

    private func restoreExpansionAfterDrag() {
        if let original = collapsedBeforeDrag { collapsed = original; collapsedBeforeDrag = nil }
        disclosureNeedsRestore = true
    }

    func menu(for node: TaskOutlineNode) -> NSMenu? {
        guard let task = node.row?.task else { return nil }
        let content = self.content, model = content.model, l10n = model.localization, menu = NSMenu()
        menuActions = []
        func add(_ key: String, enabled: Bool = true, _ action: @escaping () -> Void) {
            let target = TaskOutlineMenuAction(action); menuActions.append(target)
            let item = NSMenuItem(title: l10n(key), action: #selector(TaskOutlineMenuAction.run), keyEquivalent: "")
            item.target = target; item.isEnabled = enabled; menu.addItem(item)
        }
        menu.autoenablesItems = false
        add("修改待办") { content.onEdit(task) }
        add("打开备注") { model.endTaskDrag(); content.onSelectNote(task) }
        add("添加子项", enabled: (model.document.taskDepth(task.id) ?? 2) < 2) { content.onAddChild(task) }
        if task.parentID != nil { add("移为主待办") { _ = model.relocateTask(task.id, parent: nil) } }
        menu.addItem(.separator())
        add("上移") { content.onMove(task, -1) }
        add("下移") { content.onMove(task, 1) }
        add("删除待办") { content.onDelete(task) }
        return menu
    }
}

struct TaskOutlineDrop: Equatable { let parent: UUID?; let before: UUID?; let completed: Bool }
private struct TaskOutlineHeight {
    let title: String
    let width: CGFloat
    let management: Bool
    let batch: Bool
    let height: CGFloat
}

@MainActor final class TaskOutlineMenuAction: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}

@MainActor final class TaskOutlineButton: NSButton {
    var onPress: () -> Void = {}
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); target = self; action = #selector(pressed) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func pressed() { onPress() }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor final class TaskOutlineCell: NSTableCellView {
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let metadata = NSTextField(labelWithString: "")
    let note = NSImageView()
    let status = TaskOutlineButton(frame: .zero)
    let checkbox = TaskOutlineButton(frame: .zero)
    private var stripe = NSColor.clear
    private var selected = false
    private var preview = false
    private var management = false
    private var taskRow = false
    private var hovered = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [titleLabel, metadata, note, status, checkbox] { addSubview(view) }
        titleLabel.isEditable = false; titleLabel.isSelectable = false; titleLabel.drawsBackground = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metadata.font = .systemFont(ofSize: 10); metadata.textColor = .secondaryLabelColor
        note.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)
        note.contentTintColor = .secondaryLabelColor
        status.isBordered = false; status.imagePosition = .imageOnly
        checkbox.setButtonType(.switch); checkbox.title = ""
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func configure(node: TaskOutlineNode, content: TaskOutlineList) {
        let model = content.model, l10n = model.localization
        management = content.management; taskRow = node.row != nil
        selected = false; preview = false; stripe = .clear; alphaValue = 1
        checkbox.isHidden = true; status.isHidden = true; note.isHidden = true; metadata.isHidden = true
        if let row = node.row {
            let task = row.task
            let color = model.group(task.groupID)?.colorHex ?? "#9AA9AF"
            let rgb = UInt64(color.dropFirst(), radix: 16) ?? 0x9AA9AF
            stripe = NSColor(srgbRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1)
            let font = NSFont.systemFont(ofSize: 15)
            let textColor: NSColor = task.phase == .completed ? .secondaryLabelColor : .labelColor
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            if task.phase == .completed { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            titleLabel.attributedStringValue = NSAttributedString(string: task.title, attributes: attributes)
            titleLabel.maximumNumberOfLines = management ? 2 : 0
            titleLabel.lineBreakMode = .byWordWrapping
            titleLabel.toolTip = task.title
            status.isHidden = false; status.image = Self.statusImage(task.phase)
            status.isEnabled = !content.batchMode
            status.onPress = { model.advancePhase(task) }
            status.setAccessibilityLabel(l10n("切换待办状态：%@", task.title))
            status.setAccessibilityValue(l10n(task.phase == .pending ? "未完成" : task.phase == .inProgress ? "进行中" : "已完成"))
            note.isHidden = task.note.isEmpty
            checkbox.isHidden = !content.batchMode
            checkbox.isEnabled = !row.isContext
            checkbox.state = content.selectedIDs.contains(task.id) ? .on : .off
            checkbox.setAccessibilityLabel(l10n("选择待办：%@", task.title))
            checkbox.onPress = { content.onSelect(task) }
            selected = content.batchMode && content.selectedIDs.contains(task.id)
            preview = model.draggedTaskID == task.id && model.taskDragPreview != nil
            if management {
                metadata.isHidden = false
                metadata.stringValue = "\(task.plannedDay.description) · \(model.group(task.groupID)?.name ?? l10n("未分组"))"
            }
            if management && row.isContext { alphaValue = 0.65 }
            setAccessibilityLabel(l10n("打开备注：%@", task.title))
            toolTip = l10n("拖动排序，放到事项上可作为子项")
        } else {
            titleLabel.stringValue = node.label
            titleLabel.font = .systemFont(ofSize: 11, weight: node.isSection ? .medium : .regular)
            titleLabel.textColor = node.isFooter ? .controlAccentColor : .secondaryLabelColor
            titleLabel.maximumNumberOfLines = 1
            setAccessibilityLabel(node.label)
            toolTip = nil
        }
        needsLayout = true; needsDisplay = true
    }

    static func rowHeight(title: String, width: CGFloat, management: Bool, batch: Bool) -> CGFloat {
        let titleWidth = max(50, width - 80 - (batch ? 22 : 0))
        let height = ceil((title as NSString).boundingRect(with: NSSize(width: titleWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 15)]).height)
        return management ? max(52, min(38, height) + 23) : max(34, height + 10)
    }

    override func layout() {
        super.layout()
        if !taskRow {
            titleLabel.frame = NSRect(x: 3, y: 9, width: max(0, bounds.width - 6), height: 20)
            return
        }
        var x: CGFloat = 14
        if !checkbox.isHidden { checkbox.frame = NSRect(x: x, y: (bounds.height - 20) / 2, width: 20, height: 20); x += 24 }
        status.frame = NSRect(x: x, y: (bounds.height - 28) / 2, width: 25, height: 28); x += 33
        let right: CGFloat = 26
        let titleWidth = max(0, bounds.width - x - right)
        let available = management ? bounds.height - 23 : bounds.height - 8
        let fitting = ceil(titleLabel.attributedStringValue.boundingRect(with: NSSize(width: max(1, titleWidth), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        let titleHeight = min(available, fitting + 2)
        titleLabel.frame = NSRect(x: x, y: management ? 5 : (bounds.height - titleHeight) / 2, width: titleWidth, height: titleHeight)
        metadata.frame = NSRect(x: x, y: bounds.height - 17, width: titleWidth, height: 14)
        note.frame = NSRect(x: bounds.width - 21, y: (bounds.height - 14) / 2, width: 14, height: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard taskRow else { return }
        let rounded = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
        NSGraphicsContext.saveGraphicsState(); rounded.addClip()
        if selected || preview { NSColor.controlAccentColor.withAlphaComponent(0.1).setFill(); rounded.fill() }
        else if hovered { NSColor.labelColor.withAlphaComponent(0.045).setFill(); rounded.fill() }
        stripe.setFill(); NSRect(x: 0, y: 0, width: 5, height: bounds.height).fill()
        NSGraphicsContext.restoreGraphicsState()
        if preview { NSColor.controlAccentColor.setStroke(); rounded.lineWidth = 1.5; rounded.stroke() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    static func statusImage(_ phase: TaskPhase) -> NSImage {
        if let image = statusImages[phase] { return image }
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { rect in
            let circle = NSRect(x: 1, y: 1, width: 18, height: 18)
            if phase == .completed {
                NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))?
                    .withSymbolConfiguration(.init(paletteColors: [.systemGreen]))?.draw(in: rect)
            } else {
                if phase == .inProgress, let context = NSGraphicsContext.current?.cgContext {
                    context.addPath(InProgressHalf().path(in: circle).cgPath)
                    context.setFillColor(NSColor.systemGreen.cgColor); context.fillPath()
                }
                NSColor.secondaryLabelColor.setStroke()
                let border = NSBezierPath(ovalIn: circle); border.lineWidth = 1; border.stroke()
            }
            return true
        }
        image.isTemplate = false
        statusImages[phase] = image
        return image
    }
    private static var statusImages: [TaskPhase: NSImage] = [:]
}
