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
    var onMove: (TodoItem, Int) -> Void = { _, _ in }
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
        // 列宽跟随列表视口，拖动改变缩进或展开子项时不重新计算列宽。
        outline.autoresizesOutlineColumn = false
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.indentationPerLevel = 8
        outline.selectionHighlightStyle = .none
        outline.draggingDestinationFeedbackStyle = .none
        outline.allowsMultipleSelection = false; outline.allowsEmptySelection = true
        outline.focusRingType = .none
        // 行会继承表格底色，由 SwiftUI 容器统一绘制背景，避免重复叠加和缓存旧外观的颜色。
        outline.backgroundColor = .clear
        outline.registerForDraggedTypes([TaskOutlineCoordinator.pasteboardType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        outline.dataSource = context.coordinator; outline.delegate = context.coordinator
        outline.target = context.coordinator; outline.action = #selector(TaskOutlineCoordinator.clicked(_:))
        outline.contextMenuForNode = { [weak coordinator = context.coordinator] node in coordinator?.menu(for: node) }
        outline.onDragExit = { [weak coordinator = context.coordinator] in coordinator?.exitDestination() }
        scroll.documentView = outline; scroll.drawsBackground = false
        // 滚动会把其他行移到指针下，此时不一定有鼠标移动事件。
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(outline, selector: #selector(TaskNativeOutlineView.clipBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
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
        if let outline = nsView.documentView as? TaskNativeOutlineView {
            NotificationCenter.default.removeObserver(outline, name: NSView.boundsDidChangeNotification, object: nsView.contentView)
            outline.delegate = nil
            outline.dataSource = nil
        }
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
    var branchStyle: TaskBranchRowStyle?
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
    private(set) var mouseDownX: CGFloat?
    private let dropOverlay = TaskOutlineDropOverlay()
    private weak var hoveredCell: TaskOutlineCell?
    private lazy var hoverTracking = NSTrackingArea(rect: .zero,
        options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if !trackingAreas.contains(hoverTracking) { addTrackingArea(hoverTracking) }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === hoverTracking { updateHover(at: event.locationInWindow) }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(at: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverTracking { setHoveredCell(nil) }
    }

    @objc func clipBoundsChanged(_ notification: Notification) {
        guard let window, window.isVisible else { setHoveredCell(nil); return }
        updateHover(at: window.mouseLocationOutsideOfEventStream)
    }

    private func updateHover(at windowPoint: NSPoint) {
        let point = convert(windowPoint, from: nil)
        let index = visibleRect.contains(point) ? row(at: point) : -1
        guard index >= 0, frameOfCell(atColumn: 0, row: index).contains(point) else {
            setHoveredCell(nil)
            return
        }
        setHoveredCell(view(atColumn: 0, row: index, makeIfNecessary: false) as? TaskOutlineCell)
    }

    private func setHoveredCell(_ cell: TaskOutlineCell?) {
        guard hoveredCell !== cell else { return }
        hoveredCell?.isHovered = false
        hoveredCell = cell
        cell?.isHovered = true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownX = convert(event.locationInWindow, from: nil).x
        super.mouseDown(with: event)
        mouseDownX = nil
    }

    func showDropFeedback(_ feedback: TaskOutlineDropFeedback?) {
        dropOverlay.update(feedback)
        if feedback != nil, dropOverlay.superview == nil { addSubview(dropOverlay, positioned: .above, relativeTo: nil) }
    }

    func branchRows(containing row: Int) -> ClosedRange<Int>? {
        guard let task = item(atRow: row) as? TaskOutlineNode, task.branchStyle != nil else { return nil }
        var root = task
        while let parent = parent(forItem: root) as? TaskOutlineNode, parent.row != nil { root = parent }
        guard root.branchStyle?.isHeader == true else { return nil }
        var last = root
        while isItemExpanded(last), let child = last.children.last, self.row(forItem: child) >= 0 { last = child }
        let firstRow = self.row(forItem: root), lastRow = self.row(forItem: last)
        guard firstRow >= 0, lastRow >= firstRow else { return nil }
        return firstRow...lastRow
    }

    override func drawBackground(inClipRect clipRect: NSRect) {
        super.drawBackground(inClipRect: clipRect)
        let visible = rows(in: clipRect)
        guard visible.location != NSNotFound else { return }
        var row = visible.location
        while row < min(NSMaxRange(visible), numberOfRows) {
            guard let branch = branchRows(containing: row) else { row += 1; continue }
            let first = rect(ofRow: branch.lowerBound)
            let last = rect(ofRow: branch.upperBound)
            let card = first.union(last).insetBy(dx: 2.5, dy: 1.5)
            let radius = TaskBranchPalette.cornerRadius
            let path = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)
            TaskBranchPalette.card.setFill(); path.fill()
            TaskBranchPalette.line.setStroke(); path.lineWidth = 1; path.stroke()
            if branch.lowerBound < branch.upperBound, card.width > 16 {
                TaskBranchPalette.line.setFill()
                NSBezierPath.fill(NSRect(x: card.minX + 8, y: first.maxY - 1,
                                         width: card.width - 16, height: 1))
            }
            row = branch.upperBound + 1
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

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
    private var lastManagementTasks: [TodoItem]?
    private var lastSelected: Set<UUID> = []
    private var lastGroups: [TaskGroup] = []
    private var lastBatch = false
    private var lastLanguage: InterfaceLanguage?
    private var lastFonts: PindoFontPreferences?
    private var restoringExpansion = false
    private var dragOriginX: CGFloat?
    private(set) var displayedDrop: TaskOutlineDestination?
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
        let document = content.model.document
        let managementTasks = content.management ? document.tasks : nil
        let hiddenRowsMayHaveChanged = lastManagementTasks != managementTasks
        let fonts = content.model.fontPreferences
        let fontsChanged = lastFonts != fonts
        let rowSizingChanged = lastBatch != content.batchMode || fontsChanged
        let refreshAllVisible = lastGroups != content.model.document.groups || lastSelected != content.selectedIDs
            || rowSizingChanged || lastLanguage != content.model.interfaceLanguage
        if content.model.draggedTaskID == nil { dragOriginX = nil }
        if dragOriginX == nil || lastSections != content.sections { exitDestination() }
        let completedPreference = content.model.document.preferences.expandCompleted
        if let old = lastCompletedPreference, old != completedPreference {
            if completedPreference { collapsed.remove("section.completed") } else { collapsed.insert("section.completed") }
            disclosureNeedsRestore = true
        }
        lastCompletedPreference = completedPreference
        guard lastSections != content.sections || refreshAllVisible || disclosureNeedsRestore || hiddenRowsMayHaveChanged else { return }
        let oldRows = cache.compactMapValues { $0.row }, oldLabels = cache.mapValues(\.label)
        let oldStyles = cache.compactMapValues(\.branchStyle)
        lastSections = content.sections; lastSelected = content.selectedIDs
        lastManagementTasks = managementTasks
        lastGroups = content.model.document.groups
        lastBatch = content.batchMode; lastLanguage = content.model.interfaceLanguage
        lastFonts = fonts
        if fontsChanged { heightCache.removeAll(keepingCapacity: true) }
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
        let groupNames = Dictionary(uniqueKeysWithValues: document.groups.map { ($0.id, $0.name) })
        let childrenByParent = Dictionary(grouping: document.tasks, by: \.parentID)
        var descendantCounts: [UUID: (done: Int, total: Int)] = [:]
        func countDescendants(_ id: UUID) -> (done: Int, total: Int) {
            if let counts = descendantCounts[id] { return counts }
            var counts = (done: 0, total: 0)
            for child in childrenByParent[id] ?? [] {
                let childCounts = countDescendants(child.id)
                counts.done += childCounts.done + (child.phase == .completed ? 1 : 0)
                counts.total += childCounts.total + 1
            }
            descendantCounts[id] = counts
            return counts
        }
        func index(_ node: TaskOutlineNode, parent: TodoItem?) {
            children[node.key] = node.children.map(\.key)
            let task = node.row?.task
            if let task {
                let (done, total) = countDescendants(task.id)
                let header = parent == nil && total > 0
                let group = parent == nil || parent?.groupID != task.groupID ? task.groupID.flatMap { groupNames[$0] } : nil
                node.branchStyle = TaskBranchRowStyle(isHeader: header, progress: total > 0 ? "\(done)/\(total)" : nil,
                    groupName: group, notePreview: header ? TaskBranchRowStyle.preview(of: task.note) : nil)
            } else { node.branchStyle = nil }
            for child in node.children { index(child, parent: task) }
        }
        for root in roots { index(root, parent: nil) }
        let next = TaskOutlineStructure(children: children)
        let move = structure?.singleMove(to: next, preferredID: content.model.draggedTaskID?.uuidString ?? lastDragItemID)
        let sameStructure = structure == next
        let textSizeChanges = Set(cache.keys.filter {
            let previous = oldRows[$0]?.task, current = cache[$0]?.row?.task
            return previous?.title != current?.title || previous?.note.isEmpty != current?.note.isEmpty
                || oldStyles[$0] != cache[$0]?.branchStyle
        })
        let changedRows = Set(cache.keys.filter { key in
            guard let old = oldRows[key], let new = cache[key]?.row else { return oldLabels[key] != cache[key]?.label }
            let a = old.task, b = new.task
            return a.title != b.title || a.phase != b.phase || a.note.isEmpty != b.note.isEmpty
                || a.groupID != b.groupID || a.plannedDay != b.plannedDay || old.isContext != new.isContext
                || (old.childCount > 0) != (new.childCount > 0) || oldStyles[key] != cache[key]?.branchStyle
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
        refreshVisibleCells(changed: refreshAllVisible ? nil : changedRows)
        if (!sameStructure && move == nil) || rowSizingChanged { updateRowHeights() }
        else {
            var changed = textSizeChanges
            if let move {
                func invalidate(_ node: TaskOutlineNode) { changed.insert(node.key); node.children.forEach(invalidate) }
                if let item = cache[move.id] { invalidate(item) }
            }
            let rows = changed.compactMap { cache[$0].map { outline.row(forItem: $0) } }.filter { $0 >= 0 }
            if !rows.isEmpty { invalidateHeights(IndexSet(rows)) }
        }
        if content.model.draggedTaskID == nil { lastDragItemID = nil }
        outline.needsDisplay = true
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
    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool { dragOriginX == nil }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? TaskOutlineNode).map { $0.row != nil || $0.isSection || $0.isFooter } ?? false }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? TaskOutlineNode, let row = node.row else { return 36 }
        // 原生展开按钮占用固定宽度，每一层再增加自己的缩进。
        let disclosureGutter: CGFloat = 18
        let indentation = CGFloat(max(0, outlineView.level(forItem: node))) * outlineView.indentationPerLevel
        let width = outlineView.bounds.width - disclosureGutter - indentation
        let hasNote = !row.task.note.isEmpty
        let style = node.branchStyle
        if let cached = heightCache[node.key], cached.title == row.task.title, cached.width == width,
           cached.management == content.management, cached.batch == content.batchMode, cached.hasNote == hasNote, cached.branchStyle == style {
            return cached.height
        }
        let height = TaskOutlineCell.rowHeight(task: row.task, width: width, management: content.management,
                                               batch: content.batchMode, hasNote: hasNote, branchStyle: style, fonts: content.model.fontPreferences)
        heightCache[node.key] = TaskOutlineHeight(title: row.task.title, width: width, management: content.management,
                                                  batch: content.batchMode, hasNote: hasNote, branchStyle: style, height: height)
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

    @objc func clicked(_ sender: TaskNativeOutlineView) {
        let index = sender.clickedRow
        guard content.model.draggedTaskID == nil, index >= 0,
              let node = sender.item(atRow: index) as? TaskOutlineNode else { return }
        if let row = node.row {
            if let x = sender.mouseDownX,
               let cell = sender.view(atColumn: 0, row: index, makeIfNecessary: false) as? TaskOutlineCell,
               x < cell.leadingControl.convert(.zero, to: sender).x {
                if sender.isExpandable(node) { toggleDisclosure(node, in: sender) }
                return
            }
            content.onSelect(row.task)
        } else if node.isSection {
            toggleDisclosure(node, in: sender)
        } else if node.isFooter { content.onFooter() }
    }

    private func toggleDisclosure(_ node: TaskOutlineNode, in outline: NSOutlineView) {
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
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
            if !collapsed.contains(node.key) {
                if !outline.isItemExpanded(node) { outline.expandItem(node) }
                restoreDisclosure(in: node.children)
            } else if outline.isItemExpanded(node) { outline.collapseItem(node) }
        }
    }

    func updateRowHeights() {
        guard let outline else { return }
        invalidateHeights(IndexSet(integersIn: 0..<outline.numberOfRows))
        outline.needsDisplay = true
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
        guard draggedItems.count == 1, let node = draggedItems.first as? TaskOutlineNode, let id = node.row?.id else { return }
        let row = outlineView.row(forItem: node)
        if row >= 0, let cell = outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TaskOutlineCell,
           let image = cell.dragImage() {
            // 从整行生成拖动图像，并用原单元格的位置保持鼠标抓取点。
            let frame = cell.convert(cell.bounds, to: outlineView)
            session.enumerateDraggingItems(options: [], for: outlineView, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
                item.setDraggingFrame(frame, contents: image)
            }
        }
        let startX = outline?.mouseDownX ?? outlineView.convert(outlineView.window?.convertPoint(fromScreen: screenPoint) ?? screenPoint, from: nil).x
        beginDrag(id, atX: startX)
        session.animatesToStartingPositionsOnCancelOrFail = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func beginDrag(_ id: UUID, atX x: CGFloat) {
        exitDestination()
        dragOriginX = content.model.beginTaskDrag(id) ? x : nil
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { cancelDrag() }

    private func ownsDrag(_ info: NSDraggingInfo, in outline: NSOutlineView) -> Bool {
        guard dragOriginX != nil, info.draggingSource as? NSOutlineView === outline,
              let text = info.draggingPasteboard.string(forType: Self.pasteboardType),
              let id = UUID(uuidString: text) else { return false }
        return id == content.model.draggedTaskID
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard ownsDrag(info, in: outlineView),
              let target = indicateDrop(at: outlineView.convert(info.draggingLocation, from: nil)) else { return [] }
        let closed = target.container.map { !outlineView.isItemExpanded($0) } ?? false
        outlineView.setDropItem(target.container, dropChildIndex: closed ? NSOutlineViewDropOnItemIndex : target.index)
        return .move
    }

    /// 垂直位置选择插入边界，横向位移决定层级。始终以当前已保存的行来计算。
    private func destination(at point: NSPoint) -> TaskOutlineDestination? {
        guard let outline, let dragOriginX, let sourceID = content.model.draggedTaskID,
              let source = taskNode(sourceID), let sourceRow = source.row,
              outline.visibleRect.contains(point), outline.numberOfRows > 0 else { return nil }

        // 层级显示更紧凑，改变层级的手势仍需要足够的横向位移。
        let horizontalStep: CGFloat = 20
        let offset = Int(((point.x - dragOriginX) / horizontalStep).rounded(.towardZero))
        let depth = min(max(sourceRow.depth + offset, 0), PindoDocument.maximumTaskDepth - 1)
        let spacing = outline.intercellSpacing.height / 2
        var row = outline.row(at: point)
        if row < 0 {
            row = outline.row(at: NSPoint(x: point.x, y: point.y + spacing + 1))
            if row < 0 { row = outline.row(at: NSPoint(x: point.x, y: point.y - spacing - 1)) }
            if row < 0, point.y >= outline.rect(ofRow: outline.numberOfRows - 1).maxY {
                row = outline.numberOfRows - 1
            }
        }
        guard row >= 0, let hover = outline.item(atRow: row) as? TaskOutlineNode else { return nil }

        let container: TaskOutlineNode?
        let index: Int
        let lineX: CGFloat
        let lineY: CGFloat
        if let hoverRow = hover.row, depth <= hoverRow.depth {
            var anchor = hover
            for _ in depth..<hoverRow.depth {
                guard let parent = outline.parent(forItem: anchor) as? TaskOutlineNode, parent.row != nil else { return nil }
                anchor = parent
            }
            container = outline.parent(forItem: anchor) as? TaskOutlineNode
            let anchorRow = outline.row(forItem: anchor)
            let anchorIndex = outline.childIndex(forItem: anchor)
            guard anchorRow >= 0, anchorIndex >= 0 else { return nil }
            lineX = outline.frameOfCell(atColumn: 0, row: anchorRow).minX
            if anchor === hover && point.y < outline.rect(ofRow: row).midY {
                index = anchorIndex
                lineY = outline.rect(ofRow: anchorRow).minY - spacing
            } else {
                index = anchorIndex + 1
                var tail = anchor
                while outline.isItemExpanded(tail), let child = tail.children.last { tail = child }
                let tailRow = outline.row(forItem: tail)
                guard tailRow >= 0 else { return nil }
                lineY = outline.rect(ofRow: tailRow).maxY + spacing
            }
        } else if let hoverRow = hover.row, depth == hoverRow.depth + 1 {
            container = hover
            index = 0
            lineX = outline.frameOfCell(atColumn: 0, row: row).minX + outline.indentationPerLevel
            lineY = outline.rect(ofRow: row).maxY + spacing
        } else if hover.row == nil, depth == 0 {
            container = hover.isSection ? hover : outline.parent(forItem: hover) as? TaskOutlineNode
            guard let container, container.isSection else { return nil }
            index = hover.isSection ? 0 : outline.childIndex(forItem: hover)
            lineX = outline.frameOfCell(atColumn: 0, row: row).minX + (hover.isSection ? outline.indentationPerLevel : 0)
            lineY = hover.isSection ? outline.rect(ofRow: row).maxY + spacing : outline.rect(ofRow: row).minY - spacing
        } else {
            return nil
        }

        let parent = container?.row?.id
        if depth == sourceRow.depth {
            guard parent == sourceRow.task.parentID else { return nil }
            // 主清单按日期分区，排序不能把事项显示到其他日期分区。
            if depth == 0, (outline.parent(forItem: source) as? TaskOutlineNode) !== container { return nil }
        }

        let siblings = container?.children ?? roots
        guard (0...siblings.count).contains(index) else { return nil }
        let next = siblings.dropFirst(index).lazy.compactMap(\.row).first { $0.id != sourceID }
        let previous = siblings.prefix(index).reversed().lazy.compactMap(\.row).first { $0.id != sourceID }
        let sourceCompleted = sourceRow.task.phase == .completed
        let adjacent = [previous, next].compactMap { $0 }
        let completed = container?.completed ??
            (adjacent.isEmpty || adjacent.contains { ($0.task.phase == .completed) == sourceCompleted } ? sourceCompleted : !sourceCompleted)
        let drop = TaskOutlineDrop(parent: parent, before: next?.id, completed: completed)

        let visible = outline.visibleRect
        let y = min(max(lineY, visible.minY + 1), visible.maxY - 1)
        guard abs(y - lineY) <= spacing + 1 else { return nil }
        let x = max(lineX + 4, visible.minX + 4)
        let line = NSRect(x: x, y: y - 1, width: max(0, visible.maxX - x - 6), height: 2)
        guard !line.isEmpty else { return nil }
        var highlight: NSRect?
        if parent != sourceRow.task.parentID, let container, parent != nil {
            let parentRow = outline.row(forItem: container)
            if parentRow >= 0 {
                let rect = outline.frameOfCell(atColumn: 0, row: parentRow).intersection(visible).insetBy(dx: 1, dy: 1)
                if !rect.isEmpty { highlight = rect }
            }
        }
        let feedback = TaskOutlineDropFeedback(line: line, parent: highlight)
        return TaskOutlineDestination(drop: drop, container: container, index: index, feedback: feedback)
    }

    @discardableResult func indicateDrop(at point: NSPoint) -> TaskOutlineDestination? {
        guard let target = destination(at: point),
              displayedDrop?.drop == target.drop || content.model.canAcceptTaskDrag(parent: target.drop.parent, before: target.drop.before, completed: target.drop.completed) else {
            exitDestination()
            return nil
        }
        displayedDrop = target
        outline?.showDropFeedback(target.feedback)
        return target
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard ownsDrag(info, in: outlineView) else { return false }
        return acceptDrop(at: outlineView.convert(info.draggingLocation, from: nil))
    }

    @discardableResult func acceptDrop(at point: NSPoint) -> Bool {
        // 松手位置需要与屏幕上的标记一致，避免提交刚好还未画出来的落点。
        guard let shown = displayedDrop, let final = destination(at: point), final.drop == shown.drop else {
            cancelDrag()
            return false
        }
        let source = content.model.draggedTaskID
        dragOriginX = nil
        exitDestination()
        let saved = content.model.acceptTaskDrag(parent: shown.drop.parent, before: shown.drop.before, completed: shown.drop.completed)
        if saved {
            lastDragItemID = source?.uuidString
            if let parent = shown.drop.parent { collapsed.remove(parent.uuidString) }
            if let container = shown.container, container.isSection { collapsed.remove(container.key) }
            disclosureNeedsRestore = true
        }
        return saved
    }

    func exitDestination() {
        guard displayedDrop != nil else { return }
        displayedDrop = nil
        outline?.showDropFeedback(nil)
    }

    func cancelDrag() {
        guard dragOriginX != nil else { return }
        dragOriginX = nil
        exitDestination()
        content.model.endTaskDrag()
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
        add("复制事项元数据") { model.copyTaskMetadata(task.id) }
        add("添加子项", enabled: (model.document.taskDepth(task.id) ?? 2) < 2) { content.onAddChild(task) }
        if task.parentID != nil { add("移为主待办") { _ = model.relocateTask(task.id, parent: nil) } }
        menu.addItem(.separator())
        if content.management {
            let parent = outline?.parent(forItem: node) as? TaskOutlineNode
            let siblings = (parent?.children ?? roots).compactMap(\.row)
            let source = siblings.firstIndex { $0.id == task.id && !$0.isContext }
            for (label, offset) in [("上移", -1), ("下移", 1)] {
                let enabled = source.map { index in
                    let target = index + offset
                    return siblings.indices.contains(target) && !siblings[target].isContext
                } ?? false
                add(label, enabled: enabled) { model.move(task, offset: offset, within: siblings.map(\.task)) }
            }
        } else {
            add("上移") { content.onMove(task, -1) }
            add("下移") { content.onMove(task, 1) }
        }
        add("删除待办") { content.onDelete(task) }
        return menu
    }
}

struct TaskOutlineDrop: Equatable { let parent: UUID?; let before: UUID?; let completed: Bool }

struct TaskOutlineDropFeedback: Equatable {
    let line: NSRect
    let parent: NSRect?
}

struct TaskOutlineDestination {
    let drop: TaskOutlineDrop
    let container: TaskOutlineNode?
    let index: Int
    let feedback: TaskOutlineDropFeedback
}

@MainActor private final class TaskOutlineDropOverlay: NSView {
    private var feedback: TaskOutlineDropFeedback?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ feedback: TaskOutlineDropFeedback?) {
        guard self.feedback != feedback else { return }
        self.feedback = feedback
        isHidden = feedback == nil
        if let feedback { frame = feedback.parent.map { $0.union(feedback.line) } ?? feedback.line }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let feedback else { return }
        func local(_ rect: NSRect) -> NSRect { rect.offsetBy(dx: -frame.minX, dy: -frame.minY) }
        let accent = NSColor.controlAccentColor
        if let parent = feedback.parent {
            let rect = local(parent).insetBy(dx: 0.75, dy: 0.75)
            if !rect.isEmpty {
                let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
                accent.withAlphaComponent(0.12).setFill(); path.fill()
                accent.setStroke(); path.lineWidth = 1.5; path.stroke()
            }
        }
        accent.setFill()
        NSBezierPath(roundedRect: local(feedback.line), xRadius: 1, yRadius: 1).fill()
    }
}

private struct TaskOutlineHeight {
    let title: String
    let width: CGFloat
    let management: Bool
    let batch: Bool
    let hasNote: Bool
    let branchStyle: TaskBranchRowStyle?
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
    private static let controlInset: CGFloat = 4
    private static let checkboxSpace: CGFloat = 22
    private static let statusWidth: CGFloat = 23
    private static let titleGap: CGFloat = 1
    private static let trailingInset: CGFloat = 7
    private static let noteWidth: CGFloat = 14

    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let metadata = NSTextField(labelWithString: "")
    let groupLabel = NSTextField(labelWithString: "")
    let progressLabel = NSTextField(labelWithString: "")
    let note = NSImageView()
    let status = TaskOutlineButton(frame: .zero)
    let checkbox = TaskOutlineButton(frame: .zero)
    var leadingControl: NSView { checkbox.isHidden ? status : checkbox }
    private var stripe = NSColor.clear
    private var selected = false
    private var taskRow = false
    private var branchStyle: TaskBranchRowStyle?
    private var subtitleHeight: CGFloat = 0
    fileprivate(set) var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for view in [titleLabel, metadata, groupLabel, progressLabel, note, status, checkbox] { addSubview(view) }
        titleLabel.isEditable = false; titleLabel.isSelectable = false; titleLabel.drawsBackground = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metadata.font = .systemFont(ofSize: 10); metadata.textColor = .secondaryLabelColor
        metadata.lineBreakMode = .byTruncatingTail
        groupLabel.font = TaskBranchRowStyle.groupFont
        groupLabel.textColor = .secondaryLabelColor
        groupLabel.lineBreakMode = .byTruncatingTail
        progressLabel.font = TaskBranchRowStyle.progressFont
        progressLabel.textColor = TaskBranchPalette.accent
        progressLabel.alignment = .center
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
        taskRow = node.row != nil
        branchStyle = node.branchStyle
        subtitleHeight = 0
        selected = false; stripe = .clear; alphaValue = 1
        checkbox.isHidden = true; status.isHidden = true; note.isHidden = true; metadata.isHidden = true
        groupLabel.isHidden = true; progressLabel.isHidden = true
        if let row = node.row {
            let task = row.task
            let color = model.group(task.groupID)?.colorHex ?? "#9AA9AF"
            let rgb = UInt64(color.dropFirst(), radix: 16) ?? 0x9AA9AF
            stripe = NSColor(srgbRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255, alpha: 1)
            let font = Self.titleFont(branchStyle, choice: model.fontPreferences.task)
            let textColor: NSColor = task.phase == .completed ? .secondaryLabelColor : .labelColor
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            if task.phase == .completed { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            titleLabel.attributedStringValue = NSAttributedString(string: task.title, attributes: attributes)
            titleLabel.maximumNumberOfLines = 0
            titleLabel.lineBreakMode = .byWordWrapping
            titleLabel.toolTip = task.title
            status.isHidden = false
            let symbol: String
            let nextAction: String
            switch task.phase {
            case .pending:
                symbol = "circle"; status.contentTintColor = .secondaryLabelColor
                nextAction = "开始执行"
            case .inProgress:
                symbol = "clock"; status.contentTintColor = TaskBranchPalette.inProgress
                nextAction = row.childCount > 0 ? "完成此事项和所有下级" : "标记完成"
            case .completed:
                symbol = "checkmark.circle.fill"; status.contentTintColor = TaskBranchPalette.accent
                nextAction = row.childCount > 0 ? "将此事项和所有下级恢复为待办" : "恢复为未完成"
            }
            let phaseTitle = l10n(task.phase.titleKey)
            status.image = NSImage(systemSymbolName: symbol, accessibilityDescription: phaseTitle)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
            status.isEnabled = !content.batchMode
            status.onPress = { model.advancePhase(task) }
            status.setAccessibilityLabel(l10n("切换待办状态：%@", task.title))
            status.setAccessibilityValue(phaseTitle)
            status.toolTip = "\(phaseTitle) · \(l10n(nextAction))"
            status.setAccessibilityHelp(l10n(nextAction))
            note.isHidden = task.note.isEmpty
            checkbox.isHidden = !content.batchMode
            checkbox.isEnabled = !row.isContext
            checkbox.state = content.selectedIDs.contains(task.id) ? .on : .off
            checkbox.setAccessibilityLabel(l10n("选择待办：%@", task.title))
            checkbox.onPress = { content.onSelect(task) }
            selected = content.batchMode && content.selectedIDs.contains(task.id)
            if let subtitle = Self.subtitle(for: task, management: content.management, style: branchStyle, fonts: model.fontPreferences) {
                metadata.isHidden = false
                metadata.font = subtitle.font
                metadata.stringValue = subtitle.text
                subtitleHeight = Self.singleLineHeight(subtitle.text, font: subtitle.font)
            }
            if let group = branchStyle?.groupName {
                groupLabel.isHidden = false
                groupLabel.stringValue = group
                groupLabel.toolTip = group
            }
            if let progress = branchStyle?.progress {
                let label = l10n("下级完成进度：%@", progress)
                progressLabel.isHidden = false
                progressLabel.stringValue = progress
                progressLabel.toolTip = label
                progressLabel.setAccessibilityLabel(label)
            }
            if row.isContext { alphaValue = 0.65 }
            setAccessibilityLabel(l10n("打开备注：%@", task.title))
            toolTip = l10n("上下拖动排序，左右拖动调整层级")
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

    private static func titleInset(batch: Bool) -> CGFloat {
        controlInset + (batch ? checkboxSpace : 0) + statusWidth + titleGap
    }

    private static func titleFont(_ style: TaskBranchRowStyle?, choice: PindoFontChoice) -> NSFont {
        choice.font(defaultSize: PindoFontPreferences.taskDefaultSize,
                    variant: style?.isHeader == true ? .semibold : .regular)
    }

    private static func subtitle(for task: TodoItem, management: Bool, style: TaskBranchRowStyle?,
                                 fonts: PindoFontPreferences) -> (text: String, font: NSFont)? {
        if let preview = style?.notePreview {
            let text = management ? "\(task.plannedDay.description) · \(preview)" : preview
            return (text, fonts.note.font(defaultSize: PindoFontPreferences.noteDefaultSize, offset: -4))
        }
        return management ? (task.plannedDay.description, .systemFont(ofSize: 10)) : nil
    }

    private static func singleLineHeight(_ text: String, font: NSFont) -> CGFloat {
        max(14, ceil((text as NSString).size(withAttributes: [.font: font]).height))
    }

    private static func titleWidth(rowWidth: CGFloat, batch: Bool, hasNote: Bool, branchStyle: TaskBranchRowStyle?) -> CGFloat {
        let columnWidth = max(branchStyle?.groupWidth ?? 0, hasNote ? noteWidth : 0)
        let progressWidth = branchStyle?.progressWidth ?? 0
        let gap = TaskBranchRowStyle.accessoryGap
        let trailing = trailingInset + columnWidth + progressWidth + (columnWidth > 0 ? gap : 0) + (progressWidth > 0 ? gap : 0)
        return max(0, rowWidth - titleInset(batch: batch) - trailing)
    }

    static func rowHeight(task: TodoItem, width: CGFloat, management: Bool, batch: Bool, hasNote: Bool,
                          branchStyle: TaskBranchRowStyle?, fonts: PindoFontPreferences) -> CGFloat {
        let titleWidth = max(1, titleWidth(rowWidth: width, batch: batch, hasNote: hasNote, branchStyle: branchStyle))
        let font = titleFont(branchStyle, choice: fonts.task)
        let height = ceil((task.title as NSString).boundingRect(with: NSSize(width: titleWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height)
        let header = branchStyle?.isHeader == true
        let extra = subtitle(for: task, management: management, style: branchStyle, fonts: fonts)
            .map { 20 + singleLineHeight($0.text, font: $0.font) } ?? (header ? 16 : 14)
        return max(header ? 54 : 40, height + extra)
    }

    override func layout() {
        super.layout()
        if !taskRow {
            titleLabel.frame = NSRect(x: 3, y: 9, width: max(0, bounds.width - 6), height: 20)
            return
        }
        let batch = !checkbox.isHidden
        if batch { checkbox.frame = NSRect(x: Self.controlInset, y: (bounds.height - 20) / 2, width: 20, height: 20) }
        let statusX = Self.controlInset + (batch ? Self.checkboxSpace : 0)
        status.frame = NSRect(x: statusX, y: (bounds.height - 28) / 2, width: Self.statusWidth, height: 28)
        let x = Self.titleInset(batch: batch)
        let titleWidth = Self.titleWidth(rowWidth: bounds.width, batch: batch, hasNote: !note.isHidden, branchStyle: branchStyle)
        let subtitleSpace = subtitleHeight > 0 ? subtitleHeight + 2 : 0
        let available = bounds.height - (subtitleSpace > 0 ? subtitleSpace + 10 : 8)
        let fitting = ceil(titleLabel.attributedStringValue.boundingRect(with: NSSize(width: max(1, titleWidth), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height)
        let titleHeight = min(available, fitting + 2)
        let titleY = (bounds.height - titleHeight - subtitleSpace) / 2
        titleLabel.frame = NSRect(x: x, y: titleY, width: titleWidth, height: titleHeight)
        metadata.frame = NSRect(x: x, y: titleLabel.frame.maxY + 1, width: titleWidth, height: subtitleHeight)
        let right = bounds.width - Self.trailingInset
        let stacked = !groupLabel.isHidden && !note.isHidden
        let groupY = stacked ? bounds.midY - 16 : bounds.midY - 8
        let noteY = stacked ? bounds.midY + 2 : bounds.midY - Self.noteWidth / 2
        note.frame = NSRect(x: right - Self.noteWidth, y: noteY, width: Self.noteWidth, height: Self.noteWidth)
        if let branchStyle {
            let columnWidth = max(branchStyle.groupWidth, note.isHidden ? 0 : Self.noteWidth)
            if !groupLabel.isHidden {
                groupLabel.frame = NSRect(x: right - branchStyle.groupWidth + 10, y: groupY, width: branchStyle.groupWidth - 10, height: 16)
            }
            if !progressLabel.isHidden {
                let progressRight = right - columnWidth - (columnWidth > 0 ? TaskBranchRowStyle.accessoryGap : 0)
                progressLabel.frame = NSRect(x: progressRight - branchStyle.progressWidth, y: (bounds.height - 18) / 2,
                                             width: branchStyle.progressWidth, height: 18)
            }
        }
    }

    func dragImage() -> NSImage? {
        guard !bounds.isEmpty else { return nil }
        layoutSubtreeIfNeeded()
        guard let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard taskRow else { return }
        let rounded = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
        NSGraphicsContext.saveGraphicsState(); rounded.addClip()
        if selected { NSColor.controlAccentColor.withAlphaComponent(0.1).setFill(); rounded.fill() }
        else if isHovered { NSColor.labelColor.withAlphaComponent(0.045).setFill(); rounded.fill() }
        if !progressLabel.isHidden {
            TaskBranchPalette.accentWash.setFill()
            NSBezierPath(roundedRect: progressLabel.frame, xRadius: 4, yRadius: 4).fill()
        }
        if !groupLabel.isHidden {
            stripe.setFill()
            NSBezierPath(ovalIn: NSRect(x: groupLabel.frame.minX - 10, y: groupLabel.frame.midY - 3, width: 6, height: 6)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

}
