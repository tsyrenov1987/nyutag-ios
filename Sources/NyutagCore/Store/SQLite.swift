// Нютаг. Тонкая обёртка над C-API libsqlite3 из состава ОС: открыть, выполнить, подготовить, привязать, читать.
// Соединение принадлежит одному актору (`Store`); обёртка сама потоков не защищает.

import Foundation
import SQLite3

public struct SQLiteError: Error, Sendable, CustomStringConvertible {
    public let code: Int32
    public let message: String
    public let sql: String?

    public var description: String { "sqlite \(code): \(message)\(sql.map { " [\($0)]" } ?? "")" }
}

public final class SQLite {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    public init(path: String) throws(SQLiteError) {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(path, &db, flags, nil)
        guard code == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "не открылась"
            if let db { sqlite3_close_v2(db) }
            throw SQLiteError(code: code, message: message, sql: nil)
        }
        handle = db
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA foreign_keys=ON")
        try exec("PRAGMA temp_store=MEMORY")
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        if let handle { sqlite3_close_v2(handle) }
    }

    public static func inMemory() throws(SQLiteError) -> SQLite {
        try SQLite(path: ":memory:")
    }

    // MARK: Выполнение

    /// Выполнить SQL без параметров (DDL, PRAGMA, транзакции).
    public func exec(_ sql: String) throws(SQLiteError) {
        var error: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &error)
        guard code == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "ошибка"
            sqlite3_free(error)
            throw SQLiteError(code: code, message: message, sql: sql)
        }
    }

    /// Выполнить запрос с параметрами, без чтения результата.
    public func run(_ sql: String, _ values: Value...) throws(SQLiteError) {
        try run(sql, values)
    }

    public func run(_ sql: String, _ values: [Value]) throws(SQLiteError) {
        let statement = try prepare(sql)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind(values, to: statement, sql: sql)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw error(code, sql) }
    }

    /// Выполнить запрос и собрать строки.
    public func query<T>(_ sql: String, _ values: Value..., row: (Row) throws -> T) throws -> [T] {
        try query(sql, values, row: row)
    }

    public func query<T>(_ sql: String, _ values: [Value], row: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_reset(statement); sqlite3_clear_bindings(statement) }
        try bind(values, to: statement, sql: sql)
        var result: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                result.append(try row(Row(statement: statement)))
            } else if code == SQLITE_DONE {
                return result
            } else {
                throw error(code, sql)
            }
        }
    }

    public func scalar(_ sql: String, _ values: Value...) throws -> Value? {
        try query(sql, values) { $0.value(0) }.first
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

    public var changes: Int { Int(sqlite3_changes(handle)) }
    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }

    // MARK: Внутреннее

    private func prepare(_ sql: String) throws(SQLiteError) -> OpaquePointer {
        if let cached = statements[sql] { return cached }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw error(code, sql) }
        statements[sql] = statement
        return statement
    }

    private func bind(_ values: [Value], to statement: OpaquePointer, sql: String) throws(SQLiteError) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null:
                code = sqlite3_bind_null(statement, index)
            case .integer(let int):
                code = sqlite3_bind_int64(statement, index, int)
            case .real(let double):
                code = sqlite3_bind_double(statement, index, double)
            case .text(let string):
                code = sqlite3_bind_text(statement, index, string, -1, transient)
            case .blob(let data):
                code = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), transient)
                }
            }
            guard code == SQLITE_OK else { throw error(code, sql) }
        }
    }

    private func error(_ code: Int32, _ sql: String) -> SQLiteError {
        SQLiteError(code: code, message: String(cString: sqlite3_errmsg(handle)), sql: sql)
    }

    // MARK: Типы

    public enum Value: Sendable, Equatable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        case blob(Data)

        public var int: Int? {
            if case .integer(let value) = self { return Int(value) }
            return nil
        }

        public var string: String? {
            if case .text(let value) = self { return value }
            return nil
        }

        public var data: Data? {
            if case .blob(let value) = self { return value }
            return nil
        }

        public var double: Double? {
            switch self {
            case .real(let value): return value
            case .integer(let value): return Double(value)
            default: return nil
            }
        }
    }

    /// Строка результата; живёт только внутри замыкания `row`.
    public struct Row {
        let statement: OpaquePointer

        public func value(_ column: Int) -> Value {
            let index = Int32(column)
            switch sqlite3_column_type(statement, index) {
            case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
            case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
            case SQLITE_TEXT: return .text(String(cString: sqlite3_column_text(statement, index)))
            case SQLITE_BLOB:
                let count = Int(sqlite3_column_bytes(statement, index))
                guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
                return .blob(Data(bytes: bytes, count: count))
            default: return .null
            }
        }

        public func string(_ column: Int) -> String? { value(column).string }
        public func int(_ column: Int) -> Int? { value(column).int }
        public func data(_ column: Int) -> Data? { value(column).data }
        public func bool(_ column: Int) -> Bool { (value(column).int ?? 0) != 0 }
    }
}

public extension SQLite.Value {
    init(_ string: String?) { self = string.map { .text($0) } ?? .null }
    init(_ int: Int?) { self = int.map { .integer(Int64($0)) } ?? .null }
    init(_ bool: Bool) { self = .integer(bool ? 1 : 0) }
    init(_ data: Data?) { self = data.map { .blob($0) } ?? .null }
    init(json: JSONValue?) {
        guard let json, let data = try? json.data() else { self = .null; return }
        self = .text(String(decoding: data, as: UTF8.self))
    }

    var json: JSONValue? {
        guard let string else { return nil }
        return try? JSONValue(parsing: string)
    }
}
