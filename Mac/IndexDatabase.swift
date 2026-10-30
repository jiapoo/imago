import Foundation
import ImagoKit
import SQLite3

/// An iPhone's index on the drive: a SQLite database in its `.photobackup`, written a row at a time.
///
/// The index used to be one JSON file, written whole after every change: 13 MB for a big library, so a
/// move, an undo or a few received files each rewrote all of it. Now a save writes only the rows that
/// changed since the last one (see `save`). An index from before is read once from `index.json`, which
/// is kept beside it as `index.json.migrated`.
nonisolated final class IndexDatabase {
    private var db: OpaquePointer?

    /// Opens (or makes) the database at `url`.
    init(url: URL) throws {
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "can't open"
            sqlite3_close(db)
            db = nil
            throw Failure(message: message)
        }
        try execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS resources (
                key TEXT PRIMARY KEY, assetID TEXT NOT NULL, path TEXT NOT NULL,
                sha256 TEXT NOT NULL, size INTEGER NOT NULL, storedAt REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS assets (assetID TEXT PRIMARY KEY, metadata BLOB NOT NULL, sidecar TEXT);
            CREATE TABLE IF NOT EXISTS backups (deviceID TEXT PRIMARY KEY, date REAL NOT NULL);
            """)
    }

    deinit {
        sqlite3_close(db)
    }

    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { "The index couldn't be saved: \(message)" }
    }

    /// Whether the database has been written to at all (a new one is empty until the first save).
    var isEmpty: Bool {
        (try? query("SELECT (SELECT COUNT(*) FROM resources) + (SELECT COUNT(*) FROM assets) + (SELECT COUNT(*) FROM backups)") { sqlite3_column_int64($0, 0) }.first) == 0
    }

    func read() throws -> BackupStore.Index {
        var index = BackupStore.Index()
        for (key, stored) in try query("SELECT key, assetID, path, sha256, size, storedAt FROM resources", { row in
            (Self.text(row, 0), BackupStore.StoredResource(
                assetID: Self.text(row, 1), relativePath: Self.text(row, 2), sha256: Self.text(row, 3),
                size: UInt64(sqlite3_column_int64(row, 4)), storedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 5))
            ))
        }) {
            index.resources[key] = stored
        }
        let decoder = JSONDecoder()
        for (assetID, data, sidecar) in try query("SELECT assetID, metadata, sidecar FROM assets", { row in
            (Self.text(row, 0), Self.blob(row, 1), sqlite3_column_type(row, 2) == SQLITE_NULL ? nil : Self.text(row, 2))
        }) {
            guard let metadata = try? decoder.decode(AssetMetadata.self, from: data) else { continue }
            index.assets[assetID] = BackupStore.AssetRecord(metadata: metadata, sidecar: sidecar)
        }
        for (deviceID, date) in try query("SELECT deviceID, date FROM backups", { row in
            (Self.text(row, 0), Date(timeIntervalSinceReferenceDate: sqlite3_column_double(row, 1)))
        }) {
            index.lastBackupByDevice[deviceID] = date
        }
        return index
    }

    /// Writes what differs between `old` (as last saved) and `new`, in one transaction.
    func save(_ new: BackupStore.Index, over old: BackupStore.Index) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let putResource = try prepare("INSERT OR REPLACE INTO resources (key, assetID, path, sha256, size, storedAt) VALUES (?, ?, ?, ?, ?, ?)")
            defer { sqlite3_finalize(putResource) }
            let dropResource = try prepare("DELETE FROM resources WHERE key = ?")
            defer { sqlite3_finalize(dropResource) }
            for (key, stored) in new.resources where old.resources[key] != stored {
                bind(putResource, [key, stored.assetID, stored.relativePath, stored.sha256])
                sqlite3_bind_int64(putResource, 5, Int64(stored.size))
                sqlite3_bind_double(putResource, 6, stored.storedAt.timeIntervalSinceReferenceDate)
                try step(putResource)
            }
            for key in old.resources.keys where new.resources[key] == nil {
                bind(dropResource, [key])
                try step(dropResource)
            }

            let putAsset = try prepare("INSERT OR REPLACE INTO assets (assetID, metadata, sidecar) VALUES (?, ?, ?)")
            defer { sqlite3_finalize(putAsset) }
            let dropAsset = try prepare("DELETE FROM assets WHERE assetID = ?")
            defer { sqlite3_finalize(dropAsset) }
            let encoder = JSONEncoder()
            for (assetID, record) in new.assets where old.assets[assetID] != record {
                let data = try encoder.encode(record.metadata)
                bind(putAsset, [assetID])
                _ = data.withUnsafeBytes { sqlite3_bind_blob(putAsset, 2, $0.baseAddress, Int32($0.count), Self.transient) }
                if let sidecar = record.sidecar { bind(putAsset, [sidecar], from: 3) } else { sqlite3_bind_null(putAsset, 3) }
                try step(putAsset)
            }
            for assetID in old.assets.keys where new.assets[assetID] == nil {
                bind(dropAsset, [assetID])
                try step(dropAsset)
            }

            let putBackup = try prepare("INSERT OR REPLACE INTO backups (deviceID, date) VALUES (?, ?)")
            defer { sqlite3_finalize(putBackup) }
            let dropBackup = try prepare("DELETE FROM backups WHERE deviceID = ?")
            defer { sqlite3_finalize(dropBackup) }
            for (deviceID, date) in new.lastBackupByDevice where old.lastBackupByDevice[deviceID] != date {
                bind(putBackup, [deviceID])
                sqlite3_bind_double(putBackup, 2, date.timeIntervalSinceReferenceDate)
                try step(putBackup)
            }
            for deviceID in old.lastBackupByDevice.keys where new.lastBackupByDevice[deviceID] == nil {
                bind(dropBackup, [deviceID])
                try step(dropBackup)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: SQLite

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        return statement
    }

    private func bind(_ statement: OpaquePointer?, _ values: [String], from first: Int32 = 1) {
        for (i, value) in values.enumerated() {
            sqlite3_bind_text(statement, first + Int32(i), value, -1, Self.transient)
        }
    }

    private func step(_ statement: OpaquePointer?) throws {
        defer { sqlite3_reset(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure() }
    }

    private func query<T>(_ sql: String, _ row: (OpaquePointer?) -> T) throws -> [T] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(row(statement))
            case SQLITE_DONE: return rows
            default: throw failure()
            }
        }
    }

    private func failure() -> Failure {
        Failure(message: db.map { String(cString: sqlite3_errmsg($0)) } ?? "no database")
    }

    private static func text(_ row: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }

    private static func blob(_ row: OpaquePointer?, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(row, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(row, column)))
    }
}
