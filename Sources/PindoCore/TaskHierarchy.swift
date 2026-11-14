import Foundation

public struct TaskOutlineRow: Identifiable, Equatable, Sendable {
    public let task: TodoItem
    public let depth: Int
    public let childCount: Int
    public let isContext: Bool
    public var id: UUID { task.id }
}

public enum TaskDropPosition: Sendable { case before, inside, after }

private struct TaskTreeIndex {
    let positions: [UUID: Int]
    let children: [UUID?: [Int]]
    let tasks: [TodoItem]

    init(_ tasks: [TodoItem]) {
        self.tasks = tasks
        positions = tasks.indices.reduce(into: [:]) { $0[tasks[$1].id] = $1 }
        var children: [UUID?: [Int]] = [:]
        for index in tasks.indices { children[tasks[index].parentID, default: []].append(index) }
        for parent in Array(children.keys) {
            children[parent]?.sort {
                tasks[$0].order == tasks[$1].order ? tasks[$0].createdAt < tasks[$1].createdAt : tasks[$0].order < tasks[$1].order
            }
        }
        self.children = children
    }

    func ancestors(of id: UUID) -> [UUID] {
        var result: [UUID] = [], seen: Set<UUID> = [id]
        var current = positions[id].flatMap { tasks[$0].parentID }
        while let parent = current, let index = positions[parent], seen.insert(parent).inserted {
            result.append(parent); current = tasks[index].parentID
        }
        return result
    }

    func subtree(_ ids: Set<UUID>) -> Set<UUID> {
        var result = Set(ids.filter { positions[$0] != nil }), queue = Array(ids)
        while let id = queue.popLast() {
            for index in children[id] ?? [] where result.insert(tasks[index].id).inserted { queue.append(tasks[index].id) }
        }
        return result
    }

    func validateMove(_ id: UUID, toParent parent: UUID?) throws {
        guard positions[id] != nil else { throw PindoError.missingTask }
        if let parent, positions[parent] == nil { throw PindoError.missingParent }
        let movedIDs = subtree([id])
        if let parent, movedIDs.contains(parent) { throw PindoError.hierarchyCycle }
        let originalDepth = ancestors(of: id).count
        let height = (movedIDs.map { ancestors(of: $0).count - originalDepth }.max() ?? 0) + 1
        let newDepth = parent.map { ancestors(of: $0).count + 1 } ?? 0
        guard newDepth + height <= PindoDocument.maximumTaskDepth else { throw PindoError.hierarchyDepth }
    }
}

public extension PindoDocument {
    static let maximumTaskDepth = 3

    func childTasks(of id: UUID) -> [TodoItem] {
        let tree = TaskTreeIndex(tasks)
        return (tree.children[id] ?? []).map { tasks[$0] }
    }

    func siblingTasks(of id: UUID) -> [TodoItem] {
        let tree = TaskTreeIndex(tasks)
        guard let index = tree.positions[id] else { return [] }
        return (tree.children[tasks[index].parentID] ?? []).map { tasks[$0] }
    }

    func descendantIDs(including ids: Set<UUID>) -> Set<UUID> { TaskTreeIndex(tasks).subtree(ids) }

    func taskDepth(_ id: UUID) -> Int? {
        let tree = TaskTreeIndex(tasks)
        return tree.positions[id] == nil ? nil : tree.ancestors(of: id).count
    }

    func rootTaskIDs(containing ids: Set<UUID>) -> Set<UUID> {
        let tree = TaskTreeIndex(tasks)
        return Set(ids.filter { tree.positions[$0] != nil }.map { tree.ancestors(of: $0).last ?? $0 })
    }

    /// Filtering retains ancestor context. Main lists can expand whole matching families.
    func taskOutline(matching ids: Set<UUID>, expandingFamilies: Bool = false) -> [TaskOutlineRow] {
        let tree = TaskTreeIndex(tasks)
        var shown = Set(ids.filter { tree.positions[$0] != nil })
        for id in ids { shown.formUnion(tree.ancestors(of: id)) }
        if expandingFamilies { shown = tree.subtree(Set(shown.filter { tree.positions[$0].map { tasks[$0].parentID == nil } ?? false })) }
        var result: [TaskOutlineRow] = []
        func append(_ parent: UUID?, depth: Int) {
            guard depth < Self.maximumTaskDepth else { return }
            for index in tree.children[parent] ?? [] where shown.contains(tasks[index].id) {
                let task = tasks[index]
                result.append(TaskOutlineRow(task: task, depth: depth, childCount: tree.children[task.id]?.count ?? 0, isContext: !ids.contains(task.id)))
                append(task.id, depth: depth + 1)
            }
        }
        append(nil, depth: 0)
        return result
    }

    func validateTaskHierarchy() throws {
        let tree = TaskTreeIndex(tasks)
        for task in tasks {
            var current: UUID? = task.id, seen: Set<UUID> = []
            var depth = 0
            while let id = current {
                guard seen.insert(id).inserted else { throw PindoError.hierarchyCycle }
                guard let index = tree.positions[id] else { throw PindoError.missingParent }
                depth += 1
                guard depth <= Self.maximumTaskDepth else { throw PindoError.hierarchyDepth }
                current = tasks[index].parentID
            }
            if task.phase == .completed, (tree.children[task.id] ?? []).contains(where: { tasks[$0].phase != .completed }) {
                throw PindoError.incompleteChildren
            }
        }
    }

    mutating func insertTask(_ task: TodoItem, now: Date = Date()) throws {
        guard !tasks.contains(where: { $0.id == task.id }) else { throw PindoError.invalidData("存在重复标识") }
        if let parent = task.parentID, !tasks.contains(where: { $0.id == parent }) { throw PindoError.missingParent }
        var next = self
        next.tasks.append(task)
        if let parent = task.parentID {
            next.reconcileParents(startingAt: [parent], previous: TaskTreeIndex(tasks), now: now)
        }
        _ = try next.validated()
        self = next
    }

    func validateTaskMove(_ id: UUID, toParent parent: UUID?) throws {
        try TaskTreeIndex(tasks).validateMove(id, toParent: parent)
    }

    /// Dragging never crosses the completed/unfinished boundary. General tree edits
    /// remain separate: explicitly adding a child can still reopen a completed parent.
    func validateTaskDrag(_ id: UUID, toParent parent: UUID?, before sibling: UUID? = nil, completed: Bool? = nil) throws {
        let tree = TaskTreeIndex(tasks)
        guard let source = tree.positions[id] else { throw PindoError.missingTask }
        let sourceCompleted = tasks[source].phase == .completed
        if let completed, sourceCompleted != completed { throw PindoError.dragCompletionBoundary }
        if let parent {
            guard let target = tree.positions[parent] else { throw PindoError.missingParent }
            // An existing mixed-status family may reorder its children. Nesting under
            // another parent requires that parent's completion class to match.
            if tasks[source].parentID != parent, sourceCompleted != (tasks[target].phase == .completed) {
                throw PindoError.dragCompletionBoundary
            }
        }
        if let sibling {
            guard let target = tree.positions[sibling], tasks[target].parentID == parent else { throw PindoError.missingTask }
            if completed == nil, sourceCompleted != (tasks[target].phase == .completed) { throw PindoError.dragCompletionBoundary }
        }
        try tree.validateMove(id, toParent: parent)
    }

    /// Moves one complete subtree. Dates, groups and notes stay attached to each task.
    mutating func moveTask(_ id: UUID, toParent parent: UUID?, before sibling: UUID? = nil, now: Date = Date()) throws {
        let tree = TaskTreeIndex(tasks)
        try tree.validateMove(id, toParent: parent)
        guard let source = tree.positions[id] else { throw PindoError.missingTask }
        if let sibling {
            guard let index = tree.positions[sibling], tasks[index].parentID == parent else { throw PindoError.missingTask }
            if sibling == id { return }
        }
        var siblings = (tree.children[parent] ?? []).map { tasks[$0].id }.filter { $0 != id }
        let position = sibling.flatMap { siblings.firstIndex(of: $0) } ?? siblings.count
        siblings.insert(id, at: position)
        if tasks[source].parentID == parent, siblings == (tree.children[parent] ?? []).map({ tasks[$0].id }) { return }
        var next = self
        let oldParent = tasks[source].parentID
        next.tasks[source].parentID = parent
        if oldParent != parent { next.tasks[source].updatedAt = now }
        for (order, sibling) in siblings.enumerated() { if let index = tree.positions[sibling] { next.tasks[index].order = order } }
        if oldParent != parent {
            next.reconcileParents(startingAt: Set([oldParent, parent].compactMap { $0 }), previous: tree, now: now)
        }
        _ = try next.validated()
        self = next
    }

    /// 批量删除、完成或重开父项时，将全部后代纳入同一次操作。
    @discardableResult mutating func applyBatch(_ action: TaskBatchAction, to ids: Set<UUID>, now: Date = Date()) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var next = self
        switch action {
        case .delete:
            let tree = TaskTreeIndex(tasks)
            let removed = tree.subtree(ids)
            let parents = Set(tasks.filter { removed.contains($0.id) }.compactMap(\.parentID)).subtracting(removed)
            next.tasks.removeAll { removed.contains($0.id) }
            next.reconcileParents(startingAt: parents, previous: tree, now: now)
        case .setGroup(let group):
            if let group, !groups.contains(where: { $0.id == group }) { throw PindoError.invalidData("事项引用了不存在的分组") }
            for index in next.tasks.indices where ids.contains(next.tasks[index].id) && next.tasks[index].groupID != group {
                next.tasks[index].groupID = group; next.tasks[index].updatedAt = now
            }
        case .setPhase(let phase):
            try next.applyPhase(phase, to: ids, now: now)
        }
        let remaining = Dictionary(uniqueKeysWithValues: next.tasks.map { ($0.id, $0) })
        let changed = tasks.filter { remaining[$0.id] != $0 }.count
        self = next
        return changed
    }
}

private extension PindoDocument {
    mutating func applyPhase(_ phase: TaskPhase, to ids: Set<UUID>, now: Date) throws {
        let tree = TaskTreeIndex(tasks)
        let selectedIDs = ids.intersection(tree.positions.keys)
        let selected = phase == .inProgress ? selectedIDs : tree.subtree(selectedIDs)
        var depths: [UUID: Int] = [:]
        for id in selected {
            let ancestors = tree.ancestors(of: id)
            depths[id] = ancestors.count
            for (offset, parent) in ancestors.enumerated() { depths[parent] = ancestors.count - offset - 1 }
        }
        var dirtyParents: Set<UUID> = []
        for (id, _) in depths.sorted(by: { $0.value > $1.value }) {
            guard let index = tree.positions[id] else { continue }
            if selected.contains(id) {
                // 由下至上应用目标状态，每条事项只写入一次。
                if tasks[index].phase != phase {
                    if phase == .completed, (tree.children[id] ?? []).contains(where: { tasks[$0].phase != .completed }) {
                        throw PindoError.incompleteChildren
                    }
                    setRawPhase(phase, at: index, now: now, explicit: true)
                }
            } else {
                guard dirtyParents.contains(id) else { continue }
                reconcileParent(id, tree: tree, now: now)
            }
            // Even an unchanged phase can sit below a stale ancestor from older data.
            if let parent = tasks[index].parentID { dirtyParents.insert(parent) }
        }
    }

    mutating func setRawPhase(_ phase: TaskPhase, at index: Int, now: Date, explicit: Bool = false) {
        let previous = tasks[index].phase
        tasks[index].phase = phase; tasks[index].updatedAt = now
        tasks[index].completedAt = phase == .completed ? now : nil
        tasks[index].isProgressExplicit = phase == .inProgress ? explicit : nil
        if phase == .inProgress {
            tasks[index].startedAt = now
        } else if phase == .pending || previous != .inProgress {
            // 重开后开始新一轮。直接标记完成也不会沿用上一轮的开始时间。
            tasks[index].startedAt = nil
        }
    }

    @discardableResult mutating func reconcileParent(_ id: UUID, tree: TaskTreeIndex, previous: TaskTreeIndex? = nil, now: Date) -> Bool {
        guard let index = tree.positions[id] else { return false }
        let children = tree.children[id] ?? []
        if tasks[index].phase == .inProgress, tasks[index].isProgressExplicit == nil {
            // 旧资料没有来源标记；原本没有子项进度时，保留父项自己的进行中。
            let oldTree = previous ?? tree
            tasks[index].isProgressExplicit = (oldTree.children[id] ?? []).allSatisfy { oldTree.tasks[$0].phase == .pending }
        }
        let phase: TaskPhase
        if children.isEmpty {
            // 移走或删除最后一个子项，只撤销由子项带来的进行中。
            guard tasks[index].phase == .inProgress, tasks[index].isProgressExplicit != true else { return false }
            phase = .pending
        } else if children.allSatisfy({ tasks[$0].phase == .completed }) { phase = .completed }
        else if children.contains(where: { tasks[$0].phase != .pending }) { phase = .inProgress }
        else { phase = tasks[index].isProgressExplicit == true ? .inProgress : .pending }
        guard tasks[index].phase != phase else { return false }
        setRawPhase(phase, at: index, now: now)
        return true
    }

    mutating func reconcileParents(startingAt ids: Set<UUID>, previous: TaskTreeIndex, now: Date) {
        guard !ids.isEmpty else { return }
        let tree = TaskTreeIndex(tasks)
        var affected = ids
        for id in ids { affected.formUnion(tree.ancestors(of: id)) }
        for id in affected.sorted(by: { tree.ancestors(of: $0).count > tree.ancestors(of: $1).count }) {
            reconcileParent(id, tree: tree, previous: previous, now: now)
        }
    }
}
