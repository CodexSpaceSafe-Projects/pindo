import Foundation
import XCTest
@testable import PindoCore

final class SyncStateTests: XCTestCase {
    private let actorA = "00000000-0000-4000-8000-000000000101"
    private let actorB = "00000000-0000-4000-8000-000000000102"
    private let now = Date(timeIntervalSinceReferenceDate: 1)

    private func empty() -> PindoDocument {
        var document = PindoDocument(); document.tasks = []; document.groups = []
        return document
    }
    private func base() throws -> (PindoDocument, SyncPayload) {
        var document = empty()
        document.tasks = [TodoItem(title: "Task", note: "Original", plannedDay: try DayKey(year: 2026, month: 11, day: 14), now: now)]
        return (document, try SyncPayload().applyingV3(delta(empty(), document, state: SyncPayload(), actor: actorA, clock: 1)))
    }
    private func delta(_ before: PindoDocument, _ after: PindoDocument, state: SyncPayload, actor: String, clock: Int64) throws -> SyncV3Batch {
        try SyncV3Delta.capture(before: before, after: after, actor: actor, clock: clock, known: Set(state.records.keys)) {
            state.records[$0]?.notes ?? []
        }
    }
    private func document(_ state: SyncPayload) throws -> PindoDocument {
        let projection = try state.projected(); var document = empty()
        document.tasks = projection.tasks; document.groups = projection.groups
        return document
    }

    func testConcurrentFieldsConvergeAcrossOrderAndRepeatedDelivery() throws {
        let (original, state) = try base()
        var left = original, right = original
        left.tasks[0].title = "New title"; right.tasks[0].plannedDay = try DayKey(year: 2026, month: 12, day: 1)
        let a = try delta(original, left, state: state, actor: actorA, clock: 2)
        let b = try delta(original, right, state: state, actor: actorB, clock: 2)
        let x = try state.applyingV3(a).applyingV3(b).applyingV3(a)
        let y = try state.applyingV3(b).applyingV3(a)
        XCTAssertEqual(x, y)
        XCTAssertEqual(try x.projected().tasks[0].title, "New title")
        XCTAssertEqual(try x.projected().tasks[0].plannedDay, right.tasks[0].plannedDay)
    }

    func testConcurrentNotesRemainVisibleUntilAnEditObservesBoth() throws {
        let (original, state) = try base()
        var left = original, right = original
        left.tasks[0].note = "Left"; right.tasks[0].note = "Right"
        let a = try delta(original, left, state: state, actor: actorA, clock: 2)
        let b = try delta(original, right, state: state, actor: actorB, clock: 2)
        let merged = try state.applyingV3(a).applyingV3(b)
        XCTAssertEqual(merged, try state.applyingV3(b).applyingV3(a))
        var projection = try document(merged)
        XCTAssertTrue(projection.tasks[0].note.contains("Left")); XCTAssertTrue(projection.tasks[0].note.contains("Right"))
        let before = projection; projection.tasks[0].note = "Resolved"
        let resolved = try merged.applyingV3(delta(before, projection, state: merged, actor: actorA, clock: 3))
        XCTAssertEqual(try resolved.projected().tasks[0].note, "Resolved")
        XCTAssertEqual(resolved, try resolved.applyingV3(a).applyingV3(b))
    }

    func testDeletingAnItemDoesNotResurrectItFromALaterOfflineEdit() throws {
        let (original, state) = try base()
        var removed = original, edited = original
        removed.tasks = []; edited.tasks[0].title = "Offline title"
        let deletion = try delta(original, removed, state: state, actor: actorA, clock: 2)
        let edit = try delta(original, edited, state: state, actor: actorB, clock: 10)
        XCTAssertTrue(try state.applyingV3(deletion).applyingV3(edit).projected().tasks.isEmpty)
        XCTAssertEqual(try state.applyingV3(deletion).applyingV3(edit), try state.applyingV3(edit).applyingV3(deletion))
    }

    func testLifecycleIsAtomicAndRejectsMissingOrTornValues() throws {
        let (original, state) = try base()
        var changed = original
        try changed.setPhase(.inProgress, for: changed.tasks[0].id, now: now.addingTimeInterval(2))
        let current = try state.applyingV3(delta(original, changed, state: state, actor: actorA, clock: 2))
        let task = try current.projected().tasks[0]
        XCTAssertEqual(task.phase, .inProgress); XCTAssertTrue(task.isProgressExplicit)
        let key = "task:\(task.id.uuidString.lowercased())"
        var null = current; null.records[key]!.fields["lifecycle"]!.value = .null
        XCTAssertThrowsError(try null.validated())
        var torn = current; torn.records[key]!.fields["completedAt"]!.value = .number(100)
        XCTAssertThrowsError(try torn.validated())
        var unsupported = current; unsupported.version = 1
        XCTAssertThrowsError(try unsupported.validated())
        var contradictory = current; contradictory.records[key]!.fields["title"]!.value = .string("Different bytes")
        XCTAssertThrowsError(try current.merging(contradictory))
    }

    func testConcurrentTreeMovesRepairCyclesWithoutRewritingRegisters() throws {
        var original = empty()
        original.tasks = [TodoItem(title: "A", order: 0, now: now), TodoItem(title: "B", order: 1, now: now)]
        let state = try SyncPayload().applyingV3(delta(empty(), original, state: SyncPayload(), actor: actorA, clock: 1))
        var left = original, right = original
        try left.moveTask(left.tasks[0].id, toParent: left.tasks[1].id)
        try right.moveTask(right.tasks[1].id, toParent: right.tasks[0].id)
        let a = try delta(original, left, state: state, actor: actorA, clock: 2)
        let b = try delta(original, right, state: state, actor: actorB, clock: 2)
        let merged = try state.applyingV3(a).applyingV3(b), reverse = try state.applyingV3(b).applyingV3(a)
        XCTAssertEqual(merged, reverse)
        XCTAssertEqual(try document(merged), try document(reverse))
        _ = try document(merged).validated()
        XCTAssertEqual(merged.records.count, 2)
    }

    func testExplicitParentProgressSurvivesAChildBeingReopened() throws {
        var original = empty()
        let parent = TodoItem(title: "Parent", now: now)
        original.tasks = [parent, TodoItem(title: "Child", parentID: parent.id, order: 1, now: now), TodoItem(title: "Other child", parentID: parent.id, order: 2, now: now)]
        try original.setPhase(.inProgress, for: parent.id, now: now.addingTimeInterval(1))
        let state = try SyncPayload().applyingV3(delta(empty(), original, state: SyncPayload(), actor: actorA, clock: 1))
        var changed = original
        try changed.setPhase(.completed, for: changed.tasks[1].id, now: now.addingTimeInterval(2))
        try changed.setPhase(.pending, for: changed.tasks[1].id, now: now.addingTimeInterval(3))
        let result = try state.applyingV3(delta(original, changed, state: state, actor: actorB, clock: 2)).projected()
        XCTAssertEqual(result.tasks.first(where: { $0.id == parent.id })?.phase, .inProgress)
        XCTAssertEqual(result.tasks.first(where: { $0.id == parent.id })?.isProgressExplicit, true)
    }

    func testSharedCurrentPayloadAndProjection() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let state = try DocumentCodec.decode(SyncPayload.self, from: Data(contentsOf: root.appendingPathComponent("sync-vectors/payload.json"))).validated()
        struct Projection: Decodable { var tasks: [TodoItem]; var groups: [TaskGroup] }
        let expected = try DocumentCodec.decode(Projection.self, from: Data(contentsOf: root.appendingPathComponent("sync-vectors/projected.json")))
        let actual = try state.projected()
        XCTAssertEqual(actual.tasks, expected.tasks); XCTAssertEqual(actual.groups, expected.groups)
        XCTAssertEqual(try state.merging(state), state)
    }

    func testDerivedCompletionTimeSurvivesParentAndChildContentEdits() throws {
        var original = empty()
        let parent = TodoItem(title: "Parent", now: now)
        original.tasks = [parent, TodoItem(title: "A", parentID: parent.id, order: 1, now: now), TodoItem(title: "B", parentID: parent.id, order: 2, now: now)]
        let state = try SyncPayload().applyingV3(delta(empty(), original, state: SyncPayload(), actor: actorA, clock: 1))
        var left = original, right = original
        try left.setPhase(.completed, for: left.tasks[1].id, now: now.addingTimeInterval(10))
        try right.setPhase(.completed, for: right.tasks[2].id, now: now.addingTimeInterval(20))
        let completed = try state
            .applyingV3(delta(original, left, state: state, actor: actorA, clock: 2))
            .applyingV3(delta(original, right, state: state, actor: actorB, clock: 2))
        let projected = try document(completed), completion = now.addingTimeInterval(20)
        XCTAssertEqual(projected.tasks[0].phase, .completed)
        XCTAssertEqual(projected.tasks[0].completedAt, completion)

        var parentEdit = projected
        parentEdit.tasks[0].title = "Renamed parent"; parentEdit.tasks[0].updatedAt = now.addingTimeInterval(100)
        let renamed = try completed.applyingV3(delta(projected, parentEdit, state: completed, actor: actorA, clock: 3))
        let afterParent = try document(renamed)
        XCTAssertEqual(afterParent.tasks[0].completedAt, completion)
        XCTAssertEqual(afterParent.tasks[0].updatedAt, now.addingTimeInterval(100))

        var childEdit = afterParent
        childEdit.tasks[1].title = "Renamed child"; childEdit.tasks[1].updatedAt = now.addingTimeInterval(120)
        let afterChild = try renamed.applyingV3(delta(afterParent, childEdit, state: renamed, actor: actorB, clock: 4)).projected()
        XCTAssertEqual(afterChild.tasks[0].completedAt, completion)
        XCTAssertEqual(afterChild.tasks[0].updatedAt, now.addingTimeInterval(120))
    }
}
