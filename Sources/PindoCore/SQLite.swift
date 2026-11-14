import Foundation
import CSQLite

/// All mutations use SQLite transactions with synchronous FULL and a bounded
/// busy timeout. Bindings are copied; no caller-owned pointers escape a call.
public final class SQLiteDatabase {
    public let url: URL
    private var db: OpaquePointer?
    private let lock = NSRecursiveLock()
    private var depth = 0
    public var beforeCommit: (() throws -> Void)?
    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw PindoError.invalidData("无法打开本机数据库") }
        sqlite3_busy_timeout(db, 5000)
        try execute("PRAGMA journal_mode=WAL"); try execute("PRAGMA synchronous=FULL"); try execute("PRAGMA foreign_keys=ON")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    deinit { sqlite3_close_v2(db) }
    public enum Value { case text(String), bytes(Data), integer(Int64), null }
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let level = depth
        try execute(level == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT pindo_\(level)")
        depth += 1; defer { depth -= 1 }
        do {
            let value = try body()
            if level == 0 { try beforeCommit?() }
            try execute(level == 0 ? "COMMIT" : "RELEASE SAVEPOINT pindo_\(level)")
            return value
        } catch {
            if level == 0 { try? execute("ROLLBACK") }
            else { try? execute("ROLLBACK TO SAVEPOINT pindo_\(level)"); try? execute("RELEASE SAVEPOINT pindo_\(level)") }
            throw error
        }
    }

    public func execute(_ sql: String, _ values: [Value] = []) throws {
        _ = try query(sql, values)
    }
    public func query(_ sql: String, _ values: [Value] = []) throws -> [[String: Data]] {
        lock.lock(); defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let i = Int32(index + 1); let status: Int32
            switch value {
            case .null: status = sqlite3_bind_null(statement, i)
            case .text(let text): status = text.withCString { sqlite3_bind_text(statement, i, $0, -1, transient) }
            case .integer(let n): status = sqlite3_bind_int64(statement, i, n)
            case .bytes(let data): status = data.withUnsafeBytes { sqlite3_bind_blob(statement, i, $0.baseAddress, Int32($0.count), transient) }
            }
            guard status == SQLITE_OK else { throw failure() }
        }
        var rows: [[String: Data]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw failure() }
            var row: [String: Data] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                let key = String(cString: sqlite3_column_name(statement, i))
                if sqlite3_column_type(statement, i) == SQLITE_NULL { continue }
                if sqlite3_column_type(statement, i) == SQLITE_BLOB {
                    let count = Int(sqlite3_column_bytes(statement, i))
                    row[key] = count == 0 ? Data() : Data(bytes: sqlite3_column_blob(statement, i)!, count: count)
                } else if let p = sqlite3_column_text(statement, i) { row[key] = Data(String(cString: p).utf8) }
            }
            rows.append(row)
        }
    }
    public func string(_ sql: String, _ values: [Value] = []) throws -> String? {
        try query(sql, values).first?.values.first.flatMap { String(data: $0, encoding: .utf8) }
    }
    private func failure() -> PindoError { .invalidData("本机数据库提交失败（\(sqlite3_extended_errcode(db))）；原资料与待上传内容已保留") }
}
