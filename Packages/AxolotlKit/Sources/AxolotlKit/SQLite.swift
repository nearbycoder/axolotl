import Foundation
import SQLite3

public enum SQLValue: Hashable, Sendable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public var string: String? { if case .text(let s) = self { return s }; return nil }
    public var int: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        default: return nil
        }
    }
    public var double: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
}

public struct SQLiteError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { "SQLite: \(message)" }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal synchronous SQLite wrapper. Not thread-safe: use from one actor.
public final class SQLiteDB {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    public init(path: String) throws {
        if sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            throw SQLiteError(message: "cannot open \(path)")
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
    }

    deinit {
        for (_, stmt) in statements { sqlite3_finalize(stmt) }
        sqlite3_close_v2(handle)
    }

    private var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    public func exec(_ sql: String) throws {
        if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK { throw SQLiteError(message: errorMessage) }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let stmt = statements[sql] {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            return stmt
        }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) != SQLITE_OK || stmt == nil {
            throw SQLiteError(message: "\(errorMessage) in \(sql)")
        }
        statements[sql] = stmt
        return stmt!
    }

    private func bind(_ stmt: OpaquePointer, _ args: [SQLValue]) {
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), SQLITE_TRANSIENT) }
            }
        }
    }

    public func run(_ sql: String, _ args: [SQLValue] = []) throws {
        let stmt = try prepare(sql)
        bind(stmt, args)
        let rc = sqlite3_step(stmt)
        sqlite3_reset(stmt)
        if rc != SQLITE_DONE && rc != SQLITE_ROW { throw SQLiteError(message: "\(errorMessage) in \(sql)") }
    }

    public func query(_ sql: String, _ args: [SQLValue] = []) throws -> [[SQLValue]] {
        let stmt = try prepare(sql)
        bind(stmt, args)
        var rows: [[SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                sqlite3_reset(stmt)
                throw SQLiteError(message: "\(errorMessage) in \(sql)")
            }
            let n = sqlite3_column_count(stmt)
            var row: [SQLValue] = []
            row.reserveCapacity(Int(n))
            for c in 0..<n {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: row.append(.double(sqlite3_column_double(stmt, c)))
                case SQLITE_TEXT: row.append(.text(String(cString: sqlite3_column_text(stmt, c))))
                case SQLITE_BLOB:
                    let len = Int(sqlite3_column_bytes(stmt, c))
                    if let p = sqlite3_column_blob(stmt, c), len > 0 { row.append(.blob(Data(bytes: p, count: len))) } else { row.append(.blob(Data())) }
                default: row.append(.null)
                }
            }
            rows.append(row)
        }
        sqlite3_reset(stmt)
        return rows
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try exec("COMMIT")
            return result
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }
}
