import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol SyncV3Cryptography: Sendable {
    func sealV3(_ plaintext: Data, context: SyncV3EnvelopeContext) throws -> Data
    func openV3(_ ciphertext: Data, context: SyncV3EnvelopeContext) throws -> Data
    func digestV3(_ bytes: Data) -> String
}
public protocol SyncV3Transport: Sendable {
    func request(method: String, path: String, body: Data?, token: String?) async throws -> Data
}
public struct SyncV3Connection: Codable, Equatable, Sendable {
    public var endpoint: String
    public var serviceID: String
    public var vaultID: String
    public var epoch: String
    public var deviceID: String
    public var token: String
    public var recoveryKey: String
    public var transactionID: String
    public var binding: SyncV3Binding { get throws { try .init(serviceID: serviceID, vaultID: vaultID, epoch: epoch, transactionID: transactionID) } }
    public init(endpoint: String, serviceID: String, vaultID: String, epoch: String, deviceID: String, token: String, recoveryKey: String, transactionID: String = UUID().uuidString.lowercased()) {
        self.endpoint = endpoint; self.serviceID = serviceID; self.vaultID = vaultID; self.epoch = epoch
        self.deviceID = deviceID; self.token = token; self.recoveryKey = recoveryKey; self.transactionID = transactionID
    }
}
public struct SyncV3KeyCheck: Codable, Sendable { public var id: String; public var epoch: String; public var ciphertext: String; public init(id: String, epoch: String, ciphertext: String) { self.id=id;self.epoch=epoch;self.ciphertext=ciphertext } }
public struct SyncV3Info: Codable, Sendable {
    public var version: Int; public var serviceID: String; public var vaultID: String; public var epoch: String
    public var head: Int64; public var gcFloor: Int64; public var checkpointID: String?
    public var checkpointCovered: Int64?; public var logCount: Int?; public var logBytes: Int?; public var recoveryFromEpoch: String?; public var recoveryHead: Int64?; public var recoveryFloor: Int64?; public var keyCheck: SyncV3KeyCheck?
}
public struct SyncV3PendingCheckpoint: Sendable { public var id: String; public var covered: Int64; public var expectedID: String?; public var wire: Data; public var digest: String }
public struct SyncV3SyncResult: Sendable { public var connection: SyncV3Connection; public var hasMore: Bool; public var waitingForCreate: Bool }
private struct V3RemoteCommit: Decodable { var batchID: String; var revision: Int64; var digest: String; var ciphertext: String; var artifactIDs: [String] }
private struct V3Page: Decodable { var epoch: String; var head: Int64; var gcFloor: Int64; var nextCursor: Int64; var hasMore: Bool; var commits: [V3RemoteCommit] }
private struct V3CheckpointEnvelope: Decodable { var id: String; var epoch: String; var covered: Int64; var digest: String; var ciphertext: String; var artifactIDs: [String] }
private struct V3CheckpointResponse: Decodable { var serviceID: String; var vaultID: String; var epoch: String; var sourceEpoch: String; var leaseID: String; var checkpoint: V3CheckpointEnvelope?; var recoveryHead: Int64? }
private struct V3CheckpointPlaintext: Codable { var version = 3; var type = "checkpoint"; var covered: Int64; var payload: SyncPayload }
private struct V3Part: Codable { var objectID: String; var digest: String; var bytes: Int }
private struct V3Manifest: Codable { var version = 3; var type = "chunk-manifest"; var contentType: String; var parts: [V3Part] }
private struct V3CipherEnvelope: Codable { var version = 3; var epoch: String; var ciphertext: String; var artifactIDs: [String] }
private struct V3ReceiptResponse: Decodable { var serviceID: String; var vaultID: String; var epoch: String; var receipt: SyncV3Anchor }

/// The transport never decides whether a write is locally applied. This engine
/// rechecks its owner after every await and commits inbox/projection/cursors in SQL.
public final class SyncV3Engine {
    public let store: SQLiteSyncStore
    public let transport: any SyncV3Transport
    public let cipher: any SyncV3Cryptography
    private let check: () throws -> Void
    private let applied: () throws -> Void
    private var leases: [(String, String)] = []
    private var leaseRenewed: [String: Date] = [:]
    private func renewLease(_ c: SyncV3Connection, id: String?, epoch: String) async throws {
        guard let id, Date().timeIntervalSince(leaseRenewed[id] ?? .distantPast) >= 60 else { return }
        let body: JSONValue = .object(["epoch": .string(epoch), "floor": .number(0)])
        let _: JSONValue = try await call(c, "leases/\(id)", method: "POST", body: DocumentCodec.encode(body))
        leaseRenewed[id] = Date()
    }
    public init(store: SQLiteSyncStore, transport: any SyncV3Transport, cipher: any SyncV3Cryptography,
                check: @escaping () throws -> Void = {}, applied: @escaping () throws -> Void = {}) {
        self.store = store; self.transport = transport; self.cipher = cipher; self.check = check; self.applied = applied
    }
    private func path(_ c: SyncV3Connection, _ suffix: String) -> String { "/v3/vaults/\(c.vaultID)/\(suffix)" }
    private func context(_ c: SyncV3Connection, epoch: String? = nil, kind: SyncV3EnvelopeContext.Kind, id: String, refs: [String] = []) throws -> SyncV3EnvelopeContext {
        .init(identity: try .init(serviceID: c.serviceID, vaultID: c.vaultID), epoch: epoch ?? c.epoch, kind: kind, objectID: id, artifactIDs: refs)
    }
    private func call<T: Decodable>(_ c: SyncV3Connection, _ suffix: String, method: String = "GET", body: Data? = nil, as type: T.Type = T.self) async throws -> T {
        try check(); let data = try await transport.request(method: method, path: path(c, suffix), body: body, token: c.token); try check()
        return try DocumentCodec.decode(type, from: data)
    }
    public func info(_ c: SyncV3Connection) async throws -> SyncV3Info {
        let i: SyncV3Info = try await call(c, "info")
        guard i.version == 3, i.serviceID == c.serviceID, i.vaultID == c.vaultID else { throw SyncV3Error.corruptData }
        try SyncV3.validateCounter(i.head); try SyncV3.validateCounter(i.gcFloor); try SyncV3.validateID(i.epoch)
        guard i.gcFloor <= i.head else { throw SyncV3Error.corruptData }
        if let k = i.keyCheck {
            guard let sealed = Data(base64Encoded: k.ciphertext), try cipher.openV3(sealed, context: context(c, epoch: k.epoch, kind: .checkpoint, id: k.id)) == Data("PindoSync/v3/key-check".utf8) else { throw SyncV3Error.corruptData }
        } else { throw SyncV3Error.corruptData }
        return i
    }
    private func boundDigest(_ c: SyncV3Connection, epoch: String, kind: SyncV3EnvelopeContext.Kind, id: String, refs: [String], sealed: Data) throws -> String {
        var bytes = try context(c, epoch: epoch, kind: kind, id: id, refs: refs).associatedData(); bytes.append(0); bytes.append(sealed); return cipher.digestV3(bytes)
    }
    private func encode(_ plaintext: Data, c: SyncV3Connection, kind: SyncV3EnvelopeContext.Kind, id: String, forceChunks: Bool = false) throws -> (sealed: Data, refs: [String], chunks: [SyncV3Chunk]) {
        guard !plaintext.isEmpty, plaintext.count <= 24 * 1024 * 1024 else { throw SyncV3ApplyError.capacity }
        var content = plaintext, chunks: [SyncV3Chunk] = [], refs: [String] = []
        if forceChunks || plaintext.count > 96 * 1024 {
            var parts: [V3Part] = []
            for offset in stride(from: 0, to: plaintext.count, by: 48 * 1024) {
                let object = UUID().uuidString.lowercased(), part = plaintext.subdata(in: offset..<min(offset + 48 * 1024, plaintext.count))
                let sealed = try cipher.sealV3(part, context: context(c, kind: .chunk, id: object)), digest = cipher.digestV3(sealed)
                chunks.append(.init(objectID: object, digest: digest, ciphertext: sealed)); parts.append(.init(objectID: object, digest: digest, bytes: sealed.count))
            }
            refs = chunks.map(\.digest).sorted(); content = try DocumentCodec.encode(V3Manifest(contentType: kind.rawValue, parts: parts))
        }
        guard refs.count <= 512 else { throw SyncV3ApplyError.capacity }
        return (try cipher.sealV3(content, context: context(c, kind: kind, id: id, refs: refs)), refs, chunks)
    }
    private func decode(_ c: SyncV3Connection, epoch: String, kind: SyncV3EnvelopeContext.Kind, id: String, sealed: Data, refs: [String], lease: String? = nil) async throws -> Data {
        let plaintext = try cipher.openV3(sealed, context: context(c, epoch: epoch, kind: kind, id: id, refs: refs))
        guard !refs.isEmpty else { return plaintext }
        let manifest = try DocumentCodec.decode(V3Manifest.self, from: plaintext)
        guard manifest.version == 3, manifest.type == "chunk-manifest", manifest.contentType == kind.rawValue,
              manifest.parts.count <= 512, manifest.parts.map(\.digest).sorted() == refs, Set(refs).count == refs.count else { throw SyncV3Error.corruptData }
        struct PartResponse: Decodable { var epoch: String; var digest: String; var objectID: String; var bytes: Int; var ciphertext: String }
        var result = Data()
        for part in manifest.parts {
            try await renewLease(c, id: lease, epoch: epoch)
            try SyncV3.validateID(part.objectID)
            let response: PartResponse = try await call(c, "artifacts/\(part.digest)?epoch=\(epoch)" + (lease.map { "&lease=\($0)" } ?? ""))
            guard response.epoch == epoch, response.digest == part.digest, response.objectID == part.objectID, response.bytes == part.bytes,
                  let bytes = Data(base64Encoded: response.ciphertext), bytes.count == part.bytes, bytes.count <= 64 * 1024,
                  cipher.digestV3(bytes) == part.digest else { throw SyncV3Error.corruptData }
            result.append(try cipher.openV3(bytes, context: context(c, epoch: epoch, kind: .chunk, id: part.objectID)))
            guard result.count <= 24 * 1024 * 1024 else { throw SyncV3ApplyError.capacity }
        }
        return result
    }
    private func upload(_ chunks: [SyncV3Chunk], c: SyncV3Connection) async throws {
        for chunk in chunks {
            let body: JSONValue = .object(["epoch": .string(c.epoch), "objectID": .string(chunk.objectID), "ciphertext": .string(chunk.ciphertext.base64EncodedString())])
            let _: JSONValue = try await call(c, "artifacts/\(chunk.digest)", method: "POST", body: DocumentCodec.encode(body))
            struct ReadBack: Decodable { var digest: String; var objectID: String; var ciphertext: String }
            let read: ReadBack = try await call(c, "artifacts/\(chunk.digest)?epoch=\(c.epoch)")
            guard read.digest == chunk.digest, read.objectID == chunk.objectID, Data(base64Encoded: read.ciphertext) == chunk.ciphertext else { throw SyncV3Error.corruptData }
        }
    }
    private func readCheckpoint(_ c: SyncV3Connection, epoch: String) async throws -> (payload: SyncPayload, covered: Int64, response: V3CheckpointResponse) {
        let response: V3CheckpointResponse = try await call(c, "checkpoints?epoch=\(epoch)")
        guard response.serviceID == c.serviceID, response.vaultID == c.vaultID, response.sourceEpoch == epoch else { throw SyncV3Error.corruptData }
        leases.append((response.leaseID, epoch)); leaseRenewed[response.leaseID] = Date()
        guard let cp = response.checkpoint else { return (.init(version: 2), 0, response) }
        guard cp.epoch == epoch, let sealed = Data(base64Encoded: cp.ciphertext), try boundDigest(c, epoch: epoch, kind: .checkpoint, id: cp.id, refs: cp.artifactIDs, sealed: sealed) == cp.digest else { throw SyncV3Error.corruptData }
        let content = try await decode(c, epoch: epoch, kind: .checkpoint, id: cp.id, sealed: sealed, refs: cp.artifactIDs, lease: response.leaseID)
        let checkpoint = try DocumentCodec.decode(V3CheckpointPlaintext.self, from: content)
        guard checkpoint.version == 3, checkpoint.type == "checkpoint", checkpoint.covered == cp.covered else { throw SyncV3Error.corruptData }
        return (try checkpoint.payload.validated(), cp.covered, response)
    }
    private func readPage(_ c: SyncV3Connection, epoch: String, after: Int64, lease: String? = nil) async throws -> (V3Page, [(revision: Int64, id: String, batch: SyncV3Batch)]) {
        try await renewLease(c, id: lease, epoch: epoch)
        let page: V3Page = try await call(c, "pull?epoch=\(epoch)&after=\(after)" + (lease.map { "&lease=\($0)" } ?? ""))
        guard page.epoch == epoch, page.commits.count <= 8 else { throw SyncV3Error.corruptData }
        var entries: [(revision: Int64, id: String, batch: SyncV3Batch)] = [], cursor = after
        for item in page.commits {
            guard item.revision == cursor + 1, let sealed = Data(base64Encoded: item.ciphertext),
                  try boundDigest(c, epoch: epoch, kind: .batch, id: item.batchID, refs: item.artifactIDs, sealed: sealed) == item.digest else { throw SyncV3Error.corruptData }
            let plain = try await decode(c, epoch: epoch, kind: .batch, id: item.batchID, sealed: sealed, refs: item.artifactIDs, lease: lease)
            let batch = try DocumentCodec.decode(SyncV3Batch.self, from: plain)
            guard !item.artifactIDs.isEmpty || max(batch.operations.count,batch.payload?.records.count ?? 0) <= SyncV3.maximumOperations else { throw SyncV3Error.corruptData }
            entries.append((item.revision, item.batchID, batch)); cursor = item.revision
        }
        guard page.nextCursor == cursor, page.head >= cursor, page.hasMore == (cursor < page.head) else { throw SyncV3Error.corruptData }
        return (page, entries)
    }
    private func releaseLeases(_ c: SyncV3Connection) async {
        for (id, epoch) in leases {
            let body: JSONValue = .object(["epoch": .string(epoch), "floor": .number(0)])
            _ = try? await transport.request(method: "DELETE", path: path(c, "leases/\(id)"), body: DocumentCodec.encode(body), token: c.token)
        }
        leases = []; leaseRenewed = [:]
    }
    private func publish(_ c: SyncV3Connection, info: SyncV3Info, initial: (SyncPayload, Int64)? = nil) async throws {
        let binding = try c.binding
        if try store.pendingCheckpoint(binding) == nil {
            let cursor = try store.cursors(binding)
            guard cursor.fetched == cursor.applied else { return }
            let payload = try initial?.0 ?? store.state(binding, layer: "confirmed"), covered = initial?.1 ?? cursor.applied
            let id = UUID().uuidString.lowercased(), plaintext = try DocumentCodec.encode(V3CheckpointPlaintext(covered: covered, payload: payload))
            let frame = try encode(plaintext, c: c, kind: .checkpoint, id: id)
            let object: JSONValue = .object(["epoch": .string(c.epoch), "id": .string(id), "covered": .number(Double(covered)), "expectedID": info.checkpointID.map(JSONValue.string) ?? .null,
                "ciphertext": .string(frame.sealed.base64EncodedString()), "artifactIDs": .array(frame.refs.map(JSONValue.string))])
            try check()
            try store.freezeCheckpoint(binding, pending: .init(id: id, covered: covered, expectedID: info.checkpointID, wire: DocumentCodec.encode(object), digest: boundDigest(c, epoch: c.epoch, kind: .checkpoint, id: id, refs: frame.refs, sealed: frame.sealed)), chunks: frame.chunks)
        }
        guard let pending = try store.pendingCheckpoint(binding) else { return }
        try await upload(store.checkpointChunks(binding), c: c)
        do { let _: JSONValue = try await call(c, "checkpoints", method: "POST", body: pending.wire) }
        catch SyncV3Error.checkpointConflict {
            _ = try await readCheckpoint(c, epoch: c.epoch)
            // A competing publisher may cover a shorter prefix. Discard only this
            // unpublished proposal; next round regenerates with the new CAS pointer.
            try check(); try store.clearCheckpoint(binding); return
        }
        let verified = try await readCheckpoint(c, epoch: c.epoch)
        guard verified.covered >= pending.covered else { throw SyncV3Error.corruptData }
        try check(); try store.clearCheckpoint(binding)
    }
    public func synchronize(_ original: SyncV3Connection) async throws -> SyncV3SyncResult {
        var c = original
        do {
            var remote = try await info(c)
            if remote.epoch != c.epoch {
                let b = try store.rebaseEpoch(c.binding, epoch: remote.epoch)
                c.epoch = b.epoch; c.transactionID = b.transactionID
            }
            if let source = remote.recoveryFromEpoch {
                    var restored = try await readCheckpoint(c, epoch: source), cursor = restored.covered
                    let target = remote.recoveryHead ?? cursor
                    while cursor < target {
                        let page = try await readPage(c, epoch: source, after: cursor, lease: restored.response.leaseID)
                        for entry in page.1 { restored.payload = try restored.payload.applyingV3(entry.batch) }
                        cursor = page.0.nextCursor
                    }
                    try check(); try store.installCheckpoint(c.binding, payload: restored.payload, covered: 0); try applied()
                    try await publish(c, info: remote, initial: (restored.payload, 0))
            }
            remote = try await info(c)
            if let anchor = try store.anchor(c.binding) {
                let receipt: V3ReceiptResponse = try await call(c, "receipts/\(anchor.batchID)?epoch=\(c.epoch)")
                guard receipt.receipt == anchor else { throw SyncV3Error.cursorMismatch }
            }
            for _ in 0..<16 {
                let binding = try c.binding, cursor = try store.cursors(binding)
                guard cursor.fetched <= remote.head else { throw SyncV3Error.cursorMismatch }
                let installedCheckpoint = try store.installedCheckpoint(binding)
                if cursor.fetched < remote.gcFloor || (cursor.fetched == 0 && remote.checkpointID != nil && installedCheckpoint != remote.checkpointID) {
                    let checkpoint = try await readCheckpoint(c, epoch: c.epoch)
                    try check(); try store.installCheckpoint(binding, payload: checkpoint.payload, covered: checkpoint.covered, checkpointID: checkpoint.response.checkpoint?.id); try applied()
                    continue
                }
                if cursor.fetched < remote.head {
                    let page = try await readPage(c, epoch: c.epoch, after: cursor.fetched)
                    try check(); try store.receive(binding, entries: page.1); try applied()
                    remote.head = page.0.head; remote.gcFloor = page.0.gcFloor
                    continue
                }
                let pendingCheckpoint = try store.pendingCheckpoint(binding)
                let needsCheckpoint = remote.checkpointID == nil || ((remote.head - (remote.checkpointCovered ?? 0) >= 500 || (remote.logBytes ?? 0) >= 4 * 1024 * 1024) && remote.head > (remote.checkpointCovered ?? 0)) || pendingCheckpoint != nil
                if cursor.applied == cursor.fetched && needsCheckpoint {
                    try await publish(c, info: remote)
                    await releaseLeases(c)
                    struct GCStatus: Decodable { var hasMore: Bool }
                    for _ in 0..<8 {
                        let gc: GCStatus = try await call(c, "gc", method: "POST", body: DocumentCodec.encode(JSONValue.object(["epoch": .string(c.epoch)])))
                        if !gc.hasMore { break }
                    }
                    remote = try await info(c)
                    continue
                }
                if let first = try store.queue(binding).first {
                    if first.receipt != nil && cursor.fetched == remote.head {
                        await releaseLeases(c)
                        return .init(connection: c, hasMore: false, waitingForCreate: true)
                    }
                    if first.wire == nil {
                        let batch = try DocumentCodec.decode(SyncV3Batch.self, from: first.plaintext)
                        let frame = try encode(first.plaintext, c: c, kind: .batch, id: first.id, forceChunks: max(batch.operations.count,batch.payload?.records.count ?? 0) > SyncV3.maximumOperations)
                        let object: JSONValue = .object(["version": .number(3), "epoch": .string(c.epoch), "batchID": .string(first.id),
                            "ciphertext": .string(frame.sealed.base64EncodedString()), "artifactIDs": .array(frame.refs.map(JSONValue.string))])
                        try check(); try store.freeze(binding, id: first.id, wire: DocumentCodec.encode(object), digest: boundDigest(c, epoch: c.epoch, kind: .batch, id: first.id, refs: frame.refs, sealed: frame.sealed), chunks: frame.chunks)
                    }
                    guard let frozen = try store.queue(binding).first(where: { $0.id == first.id }), let wire = frozen.wire, let digest = frozen.digest else { throw SyncV3Error.corruptData }
                    try await upload(store.chunks(id: frozen.id), c: c)
                    let receipt: V3ReceiptResponse
                    do { receipt = try await call(c, "push", method: "POST", body: wire) }
                    catch {
                        if let known: V3ReceiptResponse = try? await call(c, "receipts/\(frozen.id)?epoch=\(c.epoch)") { receipt = known }
                        else { throw error }
                    }
                    guard receipt.serviceID == c.serviceID, receipt.vaultID == c.vaultID, receipt.epoch == c.epoch,
                          receipt.receipt.batchID == frozen.id, receipt.receipt.digest == digest else { throw SyncV3Error.corruptData }
                    try check(); try store.acknowledge(binding, id: frozen.id, digest: digest, revision: receipt.receipt.revision)
                    remote = try await info(c)
                    // If an ACK arrived after the corresponding page, run the same
                    // atomic cleanup without changing either cursor.
                    try store.receive(binding, entries: []); try applied()
                    continue
                }
                let end = try store.cursors(binding)
                await releaseLeases(c)
                return .init(connection: c, hasMore: false, waitingForCreate: end.applied != end.fetched)
            }
            await releaseLeases(c)
            return .init(connection: c, hasMore: true, waitingForCreate: false)
        } catch { await releaseLeases(c); throw error }
    }
}
