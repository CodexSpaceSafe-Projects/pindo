import XCTest
@testable import PindoCore

final class TaskDragTests: XCTestCase {
    func testCompletedAndUnfinishedDestinationsAreIsolatedIncludingEmptyRegions() throws {
        var document = PindoDocument()
        let pending = TodoItem(title: "待办"), running = TodoItem(title: "进行中"), done = TodoItem(title: "已完成")
        for task in [pending, running, done] { try document.insertTask(task) }
        try document.setPhase(.inProgress, for: running.id)
        try document.setPhase(.completed, for: done.id)
        let unchanged = document
        for (source, parent) in [(pending.id, done.id), (running.id, done.id), (done.id, pending.id), (done.id, running.id)] {
            XCTAssertThrowsError(try document.validateTaskDrag(source, toParent: parent)) { error in
                guard case PindoError.dragCompletionBoundary = error else { return XCTFail("Wrong rejection: \(error)") }
            }
        }
        XCTAssertThrowsError(try document.validateTaskDrag(pending.id, toParent: nil, completed: true))
        XCTAssertThrowsError(try document.validateTaskDrag(done.id, toParent: nil, completed: false))
        XCTAssertThrowsError(try document.validateTaskDrag(pending.id, toParent: nil, before: done.id))
        XCTAssertNoThrow(try document.validateTaskDrag(pending.id, toParent: running.id, completed: false))
        XCTAssertNoThrow(try document.validateTaskDrag(running.id, toParent: pending.id, completed: false))
        XCTAssertNoThrow(try document.validateTaskDrag(done.id, toParent: nil, completed: true))
        XCTAssertEqual(document, unchanged)
    }

    func testExistingMixedFamilyCanReorderCompletedChildrenButCannotNestUnderAnotherUnfinishedParent() throws {
        var document = PindoDocument()
        let parent = TodoItem(title: "父项"), other = TodoItem(title: "另一父项")
        try document.insertTask(parent); try document.insertTask(other)
        let a = TodoItem(title: "已完成 A", parentID: parent.id), b = TodoItem(title: "已完成 B", parentID: parent.id), pending = TodoItem(title: "未完成", parentID: parent.id)
        for child in [a, b, pending] { try document.insertTask(child) }
        try document.setPhase(.completed, for: a.id); try document.setPhase(.completed, for: b.id)
        XCTAssertNoThrow(try document.validateTaskDrag(b.id, toParent: parent.id, before: a.id, completed: true))
        XCTAssertThrowsError(try document.validateTaskDrag(b.id, toParent: other.id, completed: true))
        XCTAssertNoThrow(try document.validateTaskDrag(b.id, toParent: nil, completed: true))
        XCTAssertEqual(document.tasks.first { $0.id == parent.id }?.phase, .pending)
    }

    func testSingleSubtreeTransitionHandlesReorderReparentAndReverseWithStableIDs() {
        let root = TaskOutlineStructure.root
        let old = TaskOutlineStructure(children: [root: ["A", "B", "C"], "A": ["child"], "child": ["grandchild"], "grandchild": [], "B": [], "C": []])
        var reordered = old.children; reordered[root] = ["B", "C", "A"]
        let next = TaskOutlineStructure(children: reordered)
        let forward = old.singleMove(to: next, preferredID: "A")
        XCTAssertEqual(forward?.id, "A"); XCTAssertEqual(forward?.oldIndex, 0); XCTAssertEqual(forward?.newIndex, 2)
        XCTAssertEqual(next.singleMove(to: old, preferredID: "A")?.newIndex, 0)
        var reparented = old.children; reparented[root] = ["A", "B"]; reparented["B"] = ["C"]
        let nested = TaskOutlineStructure(children: reparented)
        XCTAssertEqual(old.singleMove(to: nested, preferredID: "C")?.newParent, "B")
        XCTAssertEqual(nested.singleMove(to: old, preferredID: "C")?.newParent, root)
        XCTAssertNil(old.singleMove(to: old, preferredID: "A"))
        var complex = old.children; complex["B"] = ["new"]; complex["new"] = []
        XCTAssertNil(old.singleMove(to: TaskOutlineStructure(children: complex), preferredID: "A"))
    }

    func testEveryInsertionBoundaryInLargeTreeProducesOneMoveRatherThanReload() {
        let ids = (0..<1_000).map { "task\($0)" }, root = TaskOutlineStructure.root
        var children = Dictionary(uniqueKeysWithValues: ids.map { ($0, [String]()) })
        children[root] = ids
        let old = TaskOutlineStructure(children: children)
        for from in [0, 1, 499, 998, 999] {
            for to in [0, 1, 499, 998, 999] where from != to {
                var reordered = children, order = ids
                let moved = order.remove(at: from); order.insert(moved, at: to); reordered[root] = order
                let operation = old.singleMove(to: TaskOutlineStructure(children: reordered), preferredID: moved)
                XCTAssertEqual(operation?.id, moved)
                XCTAssertEqual(operation?.oldIndex, from); XCTAssertEqual(operation?.newIndex, to)
            }
        }
    }
}
