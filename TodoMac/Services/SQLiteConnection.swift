import Foundation
import SQLite3

// Dependency-free wrapper over the system libsqlite3. Uses the C API exposed
// through the `SQLite3` clang module that ships with macOS, so no third-party
// packages are required.

enum SQLiteError: Error, Equatable {
    case open(String)
    case prepare(String)
    case step(String)
    case bind(String)
}

final class SQLiteConnection {
    private var handle: OpaquePointer?

    let path: String

    init(path: String) throws {
        self.path = path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard openResult == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close(db)
            throw SQLiteError.open(message)
        }
        handle = db

        // Database-level safety & performance settings baked in on every open.
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        if result != SQLITE_OK {
            let message = errorPointer.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorPointer)
            throw SQLiteError.step(message)
        }
    }

    func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "prepare failed"
            throw SQLiteError.prepare(message)
        }
        return Statement(statement: statement)
    }

    /// Wrap a closure in a short transaction, rolling back on error.
    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
}

final class Statement {
    private let statement: OpaquePointer

    fileprivate init(statement: OpaquePointer) {
        self.statement = statement
    }

    deinit {
        sqlite3_finalize(statement)
    }

    @discardableResult
    func bind(_ value: String?, at index: Int32) throws -> Statement {
        if let value {
            guard sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
                throw SQLiteError.bind("bind text at \(index)")
            }
        } else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw SQLiteError.bind("bind null at \(index)")
            }
        }
        return self
    }

    @discardableResult
    func bind(_ value: Int?, at index: Int32) throws -> Statement {
        if let value {
            guard sqlite3_bind_int64(statement, index, Int64(value)) == SQLITE_OK else {
                throw SQLiteError.bind("bind int at \(index)")
            }
        } else {
            guard sqlite3_bind_null(statement, index) == SQLITE_OK else {
                throw SQLiteError.bind("bind null at \(index)")
            }
        }
        return self
    }

    func step() -> Bool {
        sqlite3_step(statement) == SQLITE_ROW
    }

    func run() throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw SQLiteError.step("expected SQLITE_DONE, got \(result)")
        }
    }

    func columnText(_ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    func columnInt(_ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }
}