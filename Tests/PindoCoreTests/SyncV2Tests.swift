import XCTest
@testable import PindoCore

final class SyncV2Tests: XCTestCase {
    private let actorA = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let actorB = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let itemID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private var key: String { "task:\(itemID.uuidString.lowercased())" }

    private func initial() -> PindoDocument {
        var document = PindoDocument(); document.groups = []
        document.tasks = [TodoItem(id: itemID, title: "Task", plannedDay: try! DayKey(year: 2026, month: 11, day: 14), now: Date(timeIntervalSinceReferenceDate: 0))]
        return document
    }
    private func pair(version: Int) throws -> (SyncReplica, SyncReplica, PindoDocument, PindoDocument) {
        let document = initial()
        var a = SyncReplica(deviceID: actorA, version: version), b = SyncReplica(deviceID: actorB, version: version)
        try a.capture(tasks: document.tasks, groups: document.groups)
        _ = try b.merge(a.payload)
        return (a, b, document, document)
    }
    private func phase(_ phase: TaskPhase, in document: inout PindoDocument, replica: inout SyncReplica, at time: Double) throws {
        try document.setPhase(phase, for: itemID, now: Date(timeIntervalSinceReferenceDate: time))
        try replica.capture(tasks: document.tasks, groups: document.groups)
    }

    func testUpgradeIsAJoinHomomorphismAndPreservesLegacyRegisters() throws {
        var (a, b, aDocument, bDocument) = try pair(version: 1)
        try phase(.completed, in: &aDocument, replica: &a, at: 10)
        try phase(.inProgress, in: &bDocument, replica: &b, at: 20)
        try phase(.pending, in: &bDocument, replica: &b, at: 30)
        let mergedLegacy = try a.payload.merging(b.payload)
        let upgradedJoin = try mergedLegacy.upgraded()
        XCTAssertEqual(upgradedJoin, try a.payload.upgraded().merging(b.payload.upgraded()))
        XCTAssertEqual(upgradedJoin, try b.payload.upgraded().merging(a.payload.upgraded()))
        for (field, register) in mergedLegacy.records[key]!.fields {
            XCTAssertEqual(upgradedJoin.records[key]!.fields[field], register)
        }
        XCTAssertEqual(upgradedJoin.records[key]!.fields["lifecycle"]?.value, .null)
        let projected = try upgradedJoin.projected().tasks[0]
        XCTAssertEqual(projected.phase, .pending)
        XCTAssertNil(projected.startedAt); XCTAssertNil(projected.completedAt)
        XCTAssertEqual(projected.isProgressExplicit, false)
    }

    func testNewLifecycleEventsMirrorAllThreeFieldsEvenWhenNullDidNotChange() throws {
        var (a, b, aDocument, bDocument) = try pair(version: 2)
        try phase(.completed, in: &aDocument, replica: &a, at: 10)
        try phase(.inProgress, in: &bDocument, replica: &b, at: 20)
        try phase(.pending, in: &bDocument, replica: &b, at: 30)
        let fields = try XCTUnwrap(b.payload.records[key]?.fields)
        let event = try XCTUnwrap(fields["lifecycle"])
        for name in ["phase", "startedAt", "completedAt"] { XCTAssertEqual(fields[name]?.stamp, event.stamp) }
        XCTAssertEqual(fields["completedAt"]?.value, .null)
        let merged = try a.payload.merging(b.payload)
        XCTAssertEqual(merged, try b.payload.merging(a.payload))
        let projected = try merged.projected().tasks[0]
        XCTAssertEqual(projected.phase, .pending)
        XCTAssertNil(projected.startedAt); XCTAssertNil(projected.completedAt)
        XCTAssertEqual(try merged.merging(merged), merged)
    }

    func testLegacyTimestampChangesCannotReviveAnOldPhase() throws {
        var (a, _, document, _) = try pair(version: 2)
        try phase(.inProgress, in: &document, replica: &a, at: 10)
        try phase(.pending, in: &document, replica: &a, at: 20)
        var legacy = try pair(version: 1).0.payload
        let stamp = SyncStamp(counter: 9, deviceID: actorB.uuidString.lowercased())
        legacy.seen[stamp.deviceID] = stamp.counter
        legacy.records[key]!.fields["startedAt"] = SyncRegister(value: .number(99), stamp: stamp)
        legacy.records[key]!.fields["completedAt"] = SyncRegister(value: .number(100), stamp: stamp)
        let combined = try a.payload.merging(legacy)
        XCTAssertEqual(combined.records[key]!.fields["lifecycle"], a.payload.records[key]!.fields["lifecycle"])
        let projected = try combined.projected().tasks[0]
        XCTAssertEqual(projected.phase, .pending)
        XCTAssertNil(projected.startedAt); XCTAssertNil(projected.completedAt)
    }

    func testNewLegacyPhaseWinsUntilANewerAtomicLifecycleArrives() throws {
        var (a, _, document, _) = try pair(version: 2)
        try phase(.completed, in: &document, replica: &a, at: 10)
        var legacy = try pair(version: 1).0.payload
        let stamp = SyncStamp(counter: 5, deviceID: actorB.uuidString.lowercased())
        legacy.seen[stamp.deviceID] = stamp.counter
        for (name, value) in ["phase": JSONValue.string("inProgress"), "startedAt": .number(30), "completedAt": .null, "updatedAt": .number(30)] {
            legacy.records[key]!.fields[name] = SyncRegister(value: value, stamp: stamp)
        }
        let incoming = try a.merge(legacy)
        document.tasks = incoming.tasks; document.groups = incoming.groups
        XCTAssertEqual(document.tasks[0].phase, .inProgress)
        XCTAssertEqual(document.tasks[0].startedAt, Date(timeIntervalSinceReferenceDate: 30))
        try phase(.pending, in: &document, replica: &a, at: 40)
        legacy.seen[stamp.deviceID] = 9
        legacy.records[key]!.fields["completedAt"] = SyncRegister(value: .number(100), stamp: SyncStamp(counter: 9, deviceID: stamp.deviceID))
        let result = try a.merge(legacy)
        XCTAssertEqual(result.tasks[0].phase, .pending)
        XCTAssertNil(result.tasks[0].startedAt); XCTAssertNil(result.tasks[0].completedAt)
    }

    func testExplicitParentProgressSurvivesAnotherDeviceStartingAndReopeningItsChild() throws {
        var document = initial()
        let child = TodoItem(title: "Child", plannedDay: document.tasks[0].plannedDay, parentID: itemID, now: Date(timeIntervalSinceReferenceDate: 0))
        document.tasks.append(child)
        var a = SyncReplica(deviceID: actorA, version: 2), b = SyncReplica(deviceID: actorB, version: 2)
        try a.capture(tasks: document.tasks, groups: document.groups)
        try phase(.inProgress, in: &document, replica: &a, at: 10)
        let projection = try b.merge(a.payload)
        var remote = PindoDocument(); remote.tasks = projection.tasks; remote.groups = projection.groups
        try remote.setPhase(.inProgress, for: child.id, now: Date(timeIntervalSinceReferenceDate: 20))
        try b.capture(tasks: remote.tasks, groups: remote.groups)
        try remote.setPhase(.pending, for: child.id, now: Date(timeIntervalSinceReferenceDate: 30))
        try b.capture(tasks: remote.tasks, groups: remote.groups)
        let result = try a.merge(b.payload)
        let parent = try XCTUnwrap(result.tasks.first { $0.id == itemID })
        XCTAssertEqual(parent.phase, .inProgress); XCTAssertEqual(parent.isProgressExplicit, true)
        XCTAssertEqual(parent.startedAt, Date(timeIntervalSinceReferenceDate: 10))
        XCTAssertEqual(result.tasks.first { $0.id == child.id }?.phase, .pending)
    }

    func testAFormerDerivedParentWithNoRemainingChildrenReturnsToPending() throws {
        var document = initial()
        document.tasks[0].phase = .inProgress; document.tasks[0].startedAt = Date(timeIntervalSinceReferenceDate: 10)
        document.tasks[0].isProgressExplicit = false
        var replica = SyncReplica(deviceID: actorA, version: 2)
        try replica.capture(tasks: document.tasks, groups: document.groups)
        let item = try replica.payload.projected().tasks[0]
        XCTAssertEqual(item.phase, .pending); XCTAssertNil(item.startedAt)
        XCTAssertEqual(item.isProgressExplicit, false)
    }

    func testLifecycleValidationRejectsTornMirrorsAndMalformedEvents() throws {
        let payload = try pair(version: 2).0.payload
        var torn = payload
        torn.records[key]!.fields["completedAt"]!.value = .number(4)
        XCTAssertThrowsError(try torn.validated())
        var malformed = payload
        malformed.records[key]!.fields["lifecycle"]!.value = .object(["phase": .string("pending")])
        XCTAssertThrowsError(try malformed.validated())
        var contradictory = payload
        contradictory.records[key]!.fields["lifecycle"]!.value = .object([
            "phase": .string("inProgress"), "startedAt": .number(0), "completedAt": .null, "isProgressExplicit": .bool(true)
        ])
        // Distinct same-stamp atomic events never silently pick an arbitrary value.
        XCTAssertThrowsError(try payload.merging(contradictory))
    }

    func testActorRotationRetainsHistoryAndAllocatesOnlyFutureStamps() throws {
        var replica = try pair(version: 2).0
        let before = replica.payload
        try replica.rotateActor(actorB)
        XCTAssertEqual(replica.payload, before); XCTAssertEqual(replica.clock, 1)
        var document = initial(); document.tasks[0].title = "A new process edit"
        try replica.capture(tasks: document.tasks, groups: document.groups)
        XCTAssertEqual(replica.payload.records[key]?.fields["title"]?.stamp, SyncStamp(counter: 2, deviceID: actorB.uuidString.lowercased()))
        XCTAssertEqual(replica.payload.seen[actorA.uuidString.lowercased()], 1)
        XCTAssertThrowsError(try replica.rotateActor(actorA))
    }

    func testSharedKotlinV2UpgradeAndProjectionFixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func data(_ name: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent("sync-vectors/\(name).json")) }
        let legacy = try DocumentCodec.decode(SyncPayload.self, from: data("payload-v1"))
        let upgraded = try DocumentCodec.decode(SyncPayload.self, from: data("payload-v2-upgraded"))
        XCTAssertEqual(try legacy.upgraded(), upgraded)
        let payload = try DocumentCodec.decode(SyncPayload.self, from: data("payload-v2")).validated()
        let projection = try payload.projected()
        struct Projection: Decodable { let tasks: [TodoItem]; let groups: [TaskGroup] }
        let expected = try DocumentCodec.decode(Projection.self, from: data("projected-v2"))
        XCTAssertEqual(projection.tasks, expected.tasks)
        XCTAssertEqual(projection.groups, expected.groups)
        XCTAssertEqual(try payload.merging(payload), payload)
    }

    func testSwiftProducesTheSameV2OfflineTraceAsKotlin() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func fixture(_ name: String) throws -> SyncPayload {
            try DocumentCodec.decode(SyncPayload.self, from: Data(contentsOf: root.appendingPathComponent("sync-vectors/\(name).json")))
        }
        let legacy = try fixture("payload-v1")
        var a = SyncReplica(deviceID: UUID(uuidString: "00000000-0000-4000-8000-000000000101")!, version: 2)
        var b = SyncReplica(deviceID: UUID(uuidString: "00000000-0000-4000-8000-000000000102")!, version: 2)
        var first = try a.merge(legacy), second = try b.merge(legacy)
        first.tasks[0].isProgressExplicit = true
        first.tasks[0].updatedAt = Date(timeIntervalSinceReferenceDate: 50)
        first.tasks[0].title = "显式进行中 / Explicit parent"
        first.tasks[0].note = "Mac 离线备注\n保留中文 👩‍💻"
        try a.capture(tasks: first.tasks, groups: first.groups)
        second.tasks[0].note = "Android 离线备注\n另一个版本 ✅"
        second.tasks[0].updatedAt = Date(timeIntervalSinceReferenceDate: 55)
        second.tasks[1].phase = .pending; second.tasks[1].isProgressExplicit = false
        second.tasks[1].startedAt = nil; second.tasks[1].completedAt = nil
        second.tasks[1].updatedAt = Date(timeIntervalSinceReferenceDate: 55)
        try b.capture(tasks: second.tasks, groups: second.groups)
        var replica = SyncReplica(deviceID: UUID(uuidString: "00000000-0000-4000-8000-000000000103")!, version: 2)
        _ = try replica.merge(b.payload); _ = try replica.merge(a.payload)
        XCTAssertEqual(replica.payload, try fixture("payload-v2"))
        XCTAssertEqual(try DocumentCodec.decode(SyncReplica.self, from: DocumentCodec.encode(replica)).validated(), replica)
    }

    func testThreeOfflineActorsConvergeAcrossPartitionsPermutationsAndDuplicateDelivery() throws {
        let actors = [actorA, actorB, UUID(uuidString: "00000000-0000-4000-8000-000000000003")!]
        var replicas = actors.map { SyncReplica(deviceID: $0, version: 2) }
        let document = initial()
        try replicas[0].capture(tasks: document.tasks, groups: document.groups)
        _ = try replicas[1].merge(replicas[0].payload); _ = try replicas[2].merge(replicas[0].payload)
        var random: UInt64 = 0x5eed
        func next() -> UInt64 { random = random &* 6364136223846793005 &+ 1442695040888963407; return random }
        for step in 0..<120 {
            let actor = Int(next() % 3)
            if step.isMultiple(of: 4) {
                let source = (actor + 1 + Int(next() % 2)) % 3
                let snapshot = replicas[source].payload
                _ = try replicas[actor].merge(snapshot)
                if step.isMultiple(of: 8) { _ = try replicas[actor].merge(snapshot) }
            }
            let projected = try replicas[actor].payload.projected()
            var current = PindoDocument(); current.tasks = projected.tasks; current.groups = projected.groups
            switch next() % 5 {
            case 0: current.tasks[0].title = "Actor \(actor), title \(step)"
            case 1: current.tasks[0].note = "离线备注 \(actor)/\(step) 👩‍💻 e\u{301}"
            case 2: try current.setPhase(current.tasks[0].phase.next, for: itemID, now: Date(timeIntervalSinceReferenceDate: Double(step + 1)))
            case 3: current.tasks[0].plannedDay = try DayKey(year: 2026, month: 11, day: Int(next() % 28) + 1)
            default: current.tasks[0].order = Int(next() % 10)
            }
            try replicas[actor].capture(tasks: current.tasks, groups: current.groups)
        }
        let payloads = replicas.map(\.payload)
        let expected = try payloads[0].merging(payloads[1]).merging(payloads[2])
        for order in [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]] {
            var actual = SyncPayload(version: 2)
            for index in order { actual = try actual.merging(payloads[index]) }
            XCTAssertEqual(actual, expected)
            XCTAssertEqual(try actual.merging(actual), actual)
        }
        XCTAssertEqual(try payloads[0].merging(payloads[1].merging(payloads[2])), expected)
    }
}
