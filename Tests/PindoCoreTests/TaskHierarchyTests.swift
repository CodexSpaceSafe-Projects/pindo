import XCTest
@testable import PindoCore

final class TaskHierarchyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_491_200)

    private func tree() throws -> PindoDocument {
        var document = PindoDocument()
        let day = try DayKey(year: 2026, month: 11, day: 8)
        let root = TodoItem(title: "主待办", note: "主备注", plannedDay: day, groupID: document.groups[0].id, order: 0, now: now)
        let child = TodoItem(title: "子待办", note: "子备注", plannedDay: day.adding(days: 1), groupID: document.groups[1].id, parentID: root.id, order: 1, now: now)
        let grandchild = TodoItem(title: "孙待办", note: "孙备注", plannedDay: day.adding(days: 2), parentID: child.id, order: 2, now: now)
        let sibling = TodoItem(title: "另一子项", parentID: root.id, order: 3, now: now)
        let other = TodoItem(title: "另一主项", order: 4, now: now)
        for task in [root, child, grandchild, sibling, other] { try document.insertTask(task, now: now) }
        return document
    }

    func testThreeLevelsAreAllowedButCyclesAndDeepSubtreesAreRejectedAtomically() throws {
        var document = try tree()
        let original = document, root = document.tasks[0], child = document.tasks[1], grandchild = document.tasks[2], other = document.tasks[4]
        XCTAssertEqual(document.taskDepth(root.id), 0)
        XCTAssertEqual(document.taskDepth(child.id), 1)
        XCTAssertEqual(document.taskDepth(grandchild.id), 2)
        XCTAssertThrowsError(try document.insertTask(TodoItem(title: "第四层", parentID: grandchild.id)))
        XCTAssertEqual(document, original)
        XCTAssertThrowsError(try document.moveTask(root.id, toParent: child.id))
        XCTAssertThrowsError(try document.moveTask(root.id, toParent: root.id))
        XCTAssertThrowsError(try document.moveTask(root.id, toParent: other.id))
        XCTAssertThrowsError(try document.moveTask(other.id, toParent: grandchild.id))
        XCTAssertEqual(document, original)
        XCTAssertEqual(try document.validated(), original)
    }

    func testMovingACompleteSubtreePreservesContentAndCanPromoteItBackToTheRoot() throws {
        var document = try tree()
        let original = document, root = document.tasks[0], child = document.tasks[1], grandchild = document.tasks[2], other = document.tasks[4]
        try document.moveTask(child.id, toParent: other.id, now: now.addingTimeInterval(60))
        XCTAssertEqual(document.tasks[1].parentID, other.id)
        XCTAssertEqual(document.tasks[2], grandchild)
        XCTAssertEqual(document.tasks[1].note, child.note)
        XCTAssertEqual(document.tasks[1].groupID, child.groupID)
        XCTAssertEqual(document.tasks[1].plannedDay, child.plannedDay)
        XCTAssertEqual(document.descendantIDs(including: [other.id]), [other.id, child.id, grandchild.id])
        XCTAssertEqual(document.tasks[0], original.tasks[0])

        try document.moveTask(child.id, toParent: nil, before: root.id, now: now.addingTimeInterval(120))
        let rows = document.taskOutline(matching: Set(document.tasks.map(\.id)))
        XCTAssertEqual(rows.prefix(2).map(\.id), [child.id, grandchild.id])
        XCTAssertEqual(rows.prefix(2).map(\.depth), [0, 1])
        XCTAssertNil(document.tasks[1].parentID)
        XCTAssertEqual(document.tasks[2].parentID, child.id)
        XCTAssertEqual(try document.validated(), document)
    }

    func testLastChildCompletesAncestorsAndReopeningAChildReopensItsAncestors() throws {
        var document = try tree()
        let grandchild = document.tasks[2].id, sibling = document.tasks[3].id
        try document.setPhase(.completed, for: grandchild, now: now.addingTimeInterval(60))
        XCTAssertEqual(document.tasks[1].phase, .completed)
        XCTAssertEqual(document.tasks[0].phase, .inProgress)
        XCTAssertEqual(document.tasks[0].startedAt, now.addingTimeInterval(60))
        XCTAssertEqual(document.tasks[4].phase, .pending)
        try document.setPhase(.completed, for: sibling, now: now.addingTimeInterval(120))
        XCTAssertEqual(document.tasks[0].phase, .completed)
        XCTAssertEqual(document.tasks[0].completedAt, now.addingTimeInterval(120))
        try document.setPhase(.pending, for: grandchild, now: now.addingTimeInterval(180))
        XCTAssertEqual(document.tasks[1].phase, .pending)
        XCTAssertEqual(document.tasks[0].phase, .inProgress)
        XCTAssertNil(document.tasks[0].completedAt)
        XCTAssertEqual(try document.validated(), document)
    }

    func testCompletingAndReopeningParentAppliesToTheWholeBranch() throws {
        var document = try tree()
        let original = document
        let root = document.tasks[0].id, grandchild = document.tasks[2].id
        let firstCompletion = now.addingTimeInterval(30), completion = now.addingTimeInterval(60)
        try document.setPhase(.completed, for: grandchild, now: firstCompletion)
        try document.setPhase(.completed, for: root, now: completion)
        XCTAssertEqual(document.tasks.prefix(4).map(\.phase), [.completed, .completed, .completed, .completed])
        XCTAssertEqual(document.tasks.prefix(4).map(\.completedAt), [completion, firstCompletion, firstCompletion, completion])

        let reopenedAt = now.addingTimeInterval(90)
        try document.setPhase(.pending, for: root, now: reopenedAt)
        for (task, before) in zip(document.tasks.prefix(4), original.tasks) {
            XCTAssertEqual(task.phase, .pending)
            XCTAssertNil(task.completedAt)
            XCTAssertNil(task.startedAt)
            XCTAssertEqual(task.createdAt, before.createdAt)
            XCTAssertEqual(task.updatedAt, reopenedAt)
            XCTAssertEqual(task.id, before.id)
            XCTAssertEqual(task.title, before.title)
            XCTAssertEqual(task.note, before.note)
            XCTAssertEqual(task.plannedDay, before.plannedDay)
            XCTAssertEqual(task.groupID, before.groupID)
            XCTAssertEqual(task.parentID, before.parentID)
            XCTAssertEqual(task.order, before.order)
        }
        XCTAssertEqual(document.tasks[4], original.tasks[4])
        XCTAssertEqual(try document.validated(), document)
    }

    func testResettingTheOnlyActiveGrandchildReturnsBothAncestorsToPending() throws {
        var document = try tree()
        let grandchild = document.tasks[2].id
        let unaffectedTasks = Array(document.tasks.suffix(2))

        try document.setPhase(.inProgress, for: grandchild, now: now.addingTimeInterval(60))
        XCTAssertEqual(document.tasks.prefix(3).map(\.phase), [.inProgress, .inProgress, .inProgress])

        XCTAssertEqual(try document.applyBatch(.setPhase(.pending), to: [grandchild], now: now.addingTimeInterval(120)), 3)
        XCTAssertEqual(document.tasks.prefix(3).map(\.phase), [.pending, .pending, .pending])
        XCTAssertEqual(Array(document.tasks.suffix(2)), unaffectedTasks)
    }

    func testManualProgressSurvivesReloadAndResettingTheOnlyActiveGrandchild() throws {
        var document = try tree()
        let root = document.tasks[0].id, grandchild = document.tasks[2].id
        try document.setPhase(.inProgress, for: root, now: now.addingTimeInterval(30))
        let manuallyStarted = document.tasks[0]
        XCTAssertTrue(document.tasks.dropFirst().allSatisfy { $0.phase == .pending })
        try document.setPhase(.inProgress, for: grandchild, now: now.addingTimeInterval(60))
        document = try DocumentCodec.decode(PindoDocument.self, from: DocumentCodec.encode(document))

        try document.setPhase(.pending, for: grandchild, now: now.addingTimeInterval(120))
        XCTAssertEqual(document.tasks[0], manuallyStarted)
        XCTAssertEqual(document.tasks.dropFirst().prefix(2).map(\.phase), [.pending, .pending])
    }

    func testEveryChildPhaseCombinationReconcilesParentProgress() throws {
        for first in TaskPhase.allCases {
            for second in TaskPhase.allCases {
                var document = try tree()
                try document.setPhase(first, for: document.tasks[1].id, now: now.addingTimeInterval(30))
                try document.setPhase(second, for: document.tasks[3].id, now: now.addingTimeInterval(60))
                let expected: TaskPhase = first == .completed && second == .completed ? .completed
                    : first != .pending || second != .pending ? .inProgress : .pending
                XCTAssertEqual(document.tasks[0].phase, expected, "\(first), \(second)")
                XCTAssertEqual(document.tasks[0].completedAt != nil, expected == .completed)
                XCTAssertEqual(document.tasks[0].startedAt != nil, expected == .inProgress || first != .pending)
                XCTAssertEqual(try document.validated(), document)
            }
        }
    }

    func testCompletingAnActiveChildPreservesParentStartAndResettingAllChildrenClearsDerivedProgress() throws {
        var document = try tree()
        let grandchild = document.tasks[2].id
        try document.setPhase(.inProgress, for: grandchild, now: now.addingTimeInterval(30))
        let startedParent = document.tasks[0]
        try document.setPhase(.completed, for: grandchild, now: now.addingTimeInterval(60))
        XCTAssertEqual(document.tasks[0], startedParent)
        XCTAssertEqual(document.tasks[1].phase, .completed)
        XCTAssertEqual(document.tasks[3].phase, .pending)

        try document.setPhase(.pending, for: grandchild, now: now.addingTimeInterval(90))
        XCTAssertTrue(document.tasks.allSatisfy { $0.phase == .pending && $0.startedAt == nil && $0.completedAt == nil })
    }

    func testUnchangedIntermediateProgressStillRepairsStaleAncestors() throws {
        var document = try tree()
        let grandchild = document.tasks[2].id
        try document.setPhase(.inProgress, for: grandchild, now: now.addingTimeInterval(30))
        let startedChild = document.tasks[1]
        document.tasks[0].phase = .pending
        document.tasks[0].startedAt = nil
        document.tasks[0].isProgressExplicit = nil

        XCTAssertEqual(try document.applyBatch(.setPhase(.inProgress), to: [grandchild], now: now.addingTimeInterval(60)), 1)
        XCTAssertEqual(document.tasks[0].phase, .inProgress)
        XCTAssertEqual(document.tasks[0].startedAt, now.addingTimeInterval(60))
        XCTAssertEqual(document.tasks[1], startedChild)
    }

    func testAddingFirstPendingChildKeepsLegacyStartedTaskInProgress() throws {
        var document = try tree()
        let index = 4, parent = document.tasks[index].id
        document.tasks[index].phase = .inProgress
        document.tasks[index].startedAt = now

        let child = TodoItem(title: "首个子项", parentID: parent, now: now)
        try document.insertTask(child, now: now.addingTimeInterval(30))
        try document.setPhase(.inProgress, for: child.id, now: now.addingTimeInterval(60))
        try document.setPhase(.pending, for: child.id, now: now.addingTimeInterval(90))
        XCTAssertEqual(document.tasks[index].phase, .inProgress)
        XCTAssertEqual(document.tasks[index].startedAt, now)
        XCTAssertEqual(document.tasks[index].updatedAt, now)
    }

    func testReopeningChildBranchInBatchKeepsCompletedSiblingAndReopensAncestor() throws {
        var document = try tree()
        let root = document.tasks[0].id, child = document.tasks[1].id
        let grandchild = document.tasks[2].id
        try document.setPhase(.completed, for: root, now: now.addingTimeInterval(60))
        let unaffectedTasks = Array(document.tasks.suffix(2))

        let reopenedAt = now.addingTimeInterval(120)
        XCTAssertEqual(try document.applyBatch(.setPhase(.pending), to: [child, grandchild], now: reopenedAt), 3)
        XCTAssertEqual(document.tasks.prefix(3).map(\.phase), [.inProgress, .pending, .pending])
        XCTAssertTrue(document.tasks.prefix(3).allSatisfy { $0.completedAt == nil && $0.updatedAt == reopenedAt })
        XCTAssertEqual(Array(document.tasks.suffix(2)), unaffectedTasks)
    }

    func testMovingAndDeletingTheOnlyActiveChildResetsItsFormerParent() throws {
        var document = try tree()
        let child = document.tasks[1].id, grandchild = document.tasks[2].id
        let sibling = document.tasks[3].id, other = document.tasks[4].id
        try document.setPhase(.completed, for: sibling, now: now.addingTimeInterval(60))
        let completedSibling = document.tasks[3]
        try document.setPhase(.inProgress, for: grandchild, now: now.addingTimeInterval(120))

        try document.moveTask(grandchild, toParent: other, now: now.addingTimeInterval(180))
        XCTAssertEqual(document.tasks.first { $0.id == child }?.phase, .pending)
        XCTAssertEqual(document.tasks.first { $0.id == other }?.phase, .inProgress)

        XCTAssertEqual(try document.applyBatch(.delete, to: [grandchild], now: now.addingTimeInterval(240)), 2)
        XCTAssertEqual(document.tasks.first { $0.id == other }?.phase, .pending)
        XCTAssertEqual(document.tasks[0].phase, .inProgress)
        XCTAssertEqual(document.tasks.first { $0.id == sibling }, completedSibling)
    }

    func testAddingAndMovingUnfinishedChildrenUpdatesCompletedParents() throws {
        var document = try tree()
        let root = document.tasks[0].id, other = document.tasks[4].id
        try document.setPhase(.completed, for: root, now: now)
        let newChild = TodoItem(title: "新子项", parentID: root, order: 10, now: now)
        try document.insertTask(newChild, now: now.addingTimeInterval(60))
        XCTAssertEqual(document.tasks[0].phase, .inProgress)
        XCTAssertNil(document.tasks[0].completedAt)
        try document.moveTask(newChild.id, toParent: other, now: now.addingTimeInterval(120))
        XCTAssertEqual(document.tasks[0].phase, .completed)
        XCTAssertEqual(document.tasks[4].phase, .pending)
        XCTAssertEqual(document.tasks.last?.parentID, other)
    }

    func testBatchUpdatesOverlappingBranchesOnceAndKeepsUnchangedTimestamps() throws {
        var document = try tree()
        let original = document, root = document.tasks[0].id, grandchild = document.tasks[2].id
        let completion = now.addingTimeInterval(60)
        let selected: Set<UUID> = [root, grandchild]
        XCTAssertEqual(try document.applyBatch(.setPhase(.completed), to: selected, now: completion), 4)
        XCTAssertTrue(document.tasks.prefix(4).allSatisfy { $0.phase == .completed && $0.completedAt == completion })
        XCTAssertEqual(document.tasks[4], original.tasks[4])

        let completed = document
        XCTAssertEqual(try document.applyBatch(.setPhase(.completed), to: selected, now: now.addingTimeInterval(120)), 0)
        XCTAssertEqual(document, completed)

        // 旧版本可单独重开父项，保留已完成的后代。
        document.tasks[0].phase = .pending
        document.tasks[0].completedAt = nil
        let reopenedRoot = document.tasks[0]
        XCTAssertEqual(try document.applyBatch(.setPhase(.pending), to: selected, now: now.addingTimeInterval(180)), 3)
        XCTAssertEqual(document.tasks[0], reopenedRoot)
        XCTAssertTrue(document.tasks.dropFirst().prefix(3).allSatisfy { $0.phase == .pending && $0.completedAt == nil })
        XCTAssertEqual(document.tasks[4], original.tasks[4])
    }

    func testDeletingABranchIncludesItsDescendantsAndReconcilesTheRemainingParent() throws {
        var document = try tree()
        let child = document.tasks[1].id, sibling = document.tasks[3].id
        try document.setPhase(.completed, for: sibling, now: now)
        XCTAssertEqual(try document.applyBatch(.delete, to: [child], now: now.addingTimeInterval(60)), 3)
        XCTAssertEqual(document.tasks.map(\.title), ["主待办", "另一子项", "另一主项"])
        XCTAssertEqual(document.tasks[0].phase, .completed)
        XCTAssertEqual(try document.validated(), document)
        let root = document.tasks[0].id
        _ = try document.applyBatch(.delete, to: [root])
        XCTAssertEqual(document.tasks.map(\.title), ["另一主项"])
    }

    func testFilteringRetainsAncestorContextWithoutSelectingUnmatchedParents() throws {
        let document = try tree(), grandchild = document.tasks[2].id
        let rows = document.taskOutline(matching: [grandchild])
        XCTAssertEqual(rows.map { $0.task.title }, ["主待办", "子待办", "孙待办"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2])
        XCTAssertEqual(rows.map(\.isContext), [true, true, false])
        let family = document.taskOutline(matching: [grandchild], expandingFamilies: true)
        XCTAssertEqual(family.map { $0.task.title }, ["主待办", "子待办", "孙待办", "另一子项"])
        XCTAssertEqual(Set(family.map(\.id)).count, family.count)
    }

    func testMalformedParentsCyclesDepthAndPrematureCompletionAreRejected() throws {
        let original = try tree()
        var document = original
        document.tasks[1].parentID = UUID()
        XCTAssertThrowsError(try document.validated())
        document = original; document.tasks[0].parentID = document.tasks[1].id
        XCTAssertThrowsError(try document.validated())
        document = original; document.tasks[4].parentID = document.tasks[2].id
        XCTAssertThrowsError(try document.validated())
        document = original; document.tasks[0].phase = .completed
        XCTAssertThrowsError(try document.validated())
    }

    func testScopedRolloverDoesNotChangeAncestorContextOrUnselectedChildren() throws {
        var document = try tree()
        let original = document, grandchild = document.tasks[2].id
        let day = try DayKey(year: 2026, month: 11, day: 20)
        document.rollover(to: day, taskIDs: [grandchild])
        XCTAssertEqual(document.tasks[2].plannedDay, day)
        XCTAssertEqual(document.tasks[2].parentID, original.tasks[2].parentID)
        for index in [0, 1, 3, 4] { XCTAssertEqual(document.tasks[index], original.tasks[index]) }
    }

    func testLegacyFlatDataAndHierarchySnapshotRestorationAndWriteFailure() throws {
        var flat = PindoDocument()
        flat.tasks = [TodoItem(title: "旧事项", now: now)]
        let data = try DocumentCodec.encode(flat)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("parentID"))
        XCTAssertEqual(try DocumentCodec.decode(PindoDocument.self, from: data).validated(), flat)
        XCTAssertEqual(try PindoDocument.fromSnapshot(flat.snapshotValue()), flat)

        let document = try tree(), io = MemoryStorage()
        let directory = URL(fileURLWithPath: "/tmp/pindo-hierarchy-\(UUID().uuidString)")
        let repository = try PindoRepository(directory: directory, io: io, now: now)
        try repository.update { $0 = document }
        _ = try repository.captureIfChanged(now: now)
        let target = repository.archive.records.last!.id
        try repository.update { try $0.moveTask(document.tasks[1].id, toParent: document.tasks[4].id, now: now.addingTimeInterval(30)) }
        let moved = repository.document, bytes = io.files[repository.dataURL]
        io.failNextWriteTo = repository.dataURL
        XCTAssertThrowsError(try repository.update { try $0.moveTask(document.tasks[1].id, toParent: nil) })
        XCTAssertEqual(repository.document, moved)
        XCTAssertEqual(io.files[repository.dataURL], bytes)
        try repository.restore(snapshotID: target, now: now.addingTimeInterval(60))
        XCTAssertEqual(repository.document, document)
        XCTAssertEqual(try PindoRepository(directory: directory, io: io, now: now).document, document)
    }
}
