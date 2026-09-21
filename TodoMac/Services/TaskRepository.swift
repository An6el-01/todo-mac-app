import Foundation
import SQLite3

// Repository over the shared SQLite database. Mirrors scripts/tasks_db.py so
// schema, migrations, and query semantics stay identical between the native
// app and the Hermes adapter.

enum RepositoryError: Error, Equatable {
    case validation(String)
    case notFound(String)
}

final class TaskRepository {
    private let db: SQLiteConnection

    static let defaultPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("hermes-vault")
            .appendingPathComponent("00-Life")
            .appendingPathComponent("Tasks")
            .appendingPathComponent("tasks.sqlite")
            .path
    }()

    init(path: String = TaskRepository.defaultPath) throws {
        db = try SQLiteConnection(path: path)
        try migrate()
    }

    // MARK: - Timestamps

    static func nowStamp() -> String {
        Self.formatter.string(from: Date())
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func newID() -> String {
        UUID().uuidString
    }

    static func todayLocal() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f.string(from: Date())
    }

    // MARK: - Migration

    func migrate() throws {
        try db.execute(
            "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)"
        )

        let current = try currentSchemaVersion()

        for migration in Schema.migrations where migration.version > current {
            try db.transaction {
                for statement in migration.statements {
                    try db.execute(statement)
                }
                let insert = try db.prepare(
                    "INSERT OR REPLACE INTO schema_migrations (version, applied_at) VALUES (?, ?)"
                )
                try insert.bind(migration.version, at: 1)
                    .bind(Self.nowStamp(), at: 2)
                    .run()
            }
        }
    }

    private func currentSchemaVersion() throws -> Int {
        let stmt = try db.prepare("SELECT COALESCE(MAX(version), 0) FROM schema_migrations")
        _ = stmt.step()
        return stmt.columnInt(0) ?? 0
    }

    // MARK: - Row mapping

    private static func task(from statement: Statement) -> Task {
        let statusRaw = statement.columnText(3) ?? "inbox"
        let priorityRaw = statement.columnText(4) ?? "none"
        let areaRaw = statement.columnText(5)

        return Task(
            id: statement.columnText(0) ?? "",
            title: statement.columnText(1) ?? "",
            notes: statement.columnText(2),
            status: TaskStatus(rawValue: statusRaw) ?? .inbox,
            priority: TaskPriority(rawValue: priorityRaw) ?? .none,
            area: areaRaw.flatMap(TaskArea.init(rawValue:)),
            projectID: statement.columnText(6),
            dueDate: statement.columnText(7),
            scheduledDate: statement.columnText(8),
            estimatedMinutes: statement.columnInt(9),
            archived: (statement.columnInt(10) ?? 0) != 0,
            completedAt: statement.columnText(11),
            createdAt: statement.columnText(12) ?? "",
            updatedAt: statement.columnText(13) ?? ""
        )
    }

    private static let taskSelect =
        "SELECT id, title, notes, status, priority, area, project_id, due_date, "
        + "scheduled_date, estimated_minutes, archived, completed_at, created_at, updated_at "
        + "FROM tasks"

    private static func project(from statement: Statement) -> Project {
        Project(
            id: statement.columnText(0) ?? "",
            name: statement.columnText(1) ?? "",
            color: statement.columnText(2),
            archived: (statement.columnInt(3) ?? 0) != 0,
            createdAt: statement.columnText(4) ?? "",
            updatedAt: statement.columnText(5) ?? ""
        )
    }

    // MARK: - Project CRUD

    func createProject(name: String, color: String? = nil, id: String? = nil) throws -> Project {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RepositoryError.validation("project name is required") }
        let projectID = id ?? Self.newID()
        let stamp = Self.nowStamp()
        let stmt = try db.prepare(
            "INSERT INTO projects (id, name, color, created_at, updated_at, archived) VALUES (?, ?, ?, ?, ?, 0)"
        )
        try stmt.bind(projectID, at: 1)
            .bind(trimmed, at: 2)
            .bind(color, at: 3)
            .bind(stamp, at: 4)
            .bind(stamp, at: 5)
            .run()
        return try projectByID(projectID)
    }

    func projectByID(_ id: String) throws -> Project {
        let stmt = try db.prepare("SELECT id, name, color, archived, created_at, updated_at FROM projects WHERE id = ?")
        try stmt.bind(id, at: 1)
        guard stmt.step() else { throw RepositoryError.notFound("project not found: \(id)") }
        return Self.project(from: stmt)
    }

    func listProjects(includeArchived: Bool = false) throws -> [Project] {
        var sql = "SELECT id, name, color, archived, created_at, updated_at FROM projects"
        if !includeArchived { sql += " WHERE archived = 0" }
        sql += " ORDER BY name COLLATE NOCASE"
        let stmt = try db.prepare(sql)
        var result: [Project] = []
        while stmt.step() { result.append(Self.project(from: stmt)) }
        return result
    }

    // MARK: - Task CRUD

    func createTask(
        title: String,
        notes: String? = nil,
        status: TaskStatus = .inbox,
        priority: TaskPriority = .none,
        area: TaskArea? = nil,
        projectID: String? = nil,
        dueDate: String? = nil,
        scheduledDate: String? = nil,
        estimatedMinutes: Int? = nil,
        id: String? = nil
    ) throws -> Task {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RepositoryError.validation("task title is required") }

        if let projectID { _ = try projectByID(projectID) }

        let taskID = id ?? Self.newID()
        let stamp = Self.nowStamp()
        let completedAt = status == .completed ? stamp : nil

        let stmt = try db.prepare(
            "INSERT INTO tasks (id, title, notes, status, priority, area, project_id, due_date, scheduled_date, estimated_minutes, archived, completed_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)"
        )
        try stmt.bind(taskID, at: 1)
            .bind(trimmed, at: 2)
            .bind(notes, at: 3)
            .bind(status.rawValue, at: 4)
            .bind(priority.rawValue, at: 5)
            .bind(area?.rawValue, at: 6)
            .bind(projectID, at: 7)
            .bind(dueDate, at: 8)
            .bind(scheduledDate, at: 9)
            .bind(estimatedMinutes, at: 10)
            .bind(completedAt, at: 11)
            .bind(stamp, at: 12)
            .bind(stamp, at: 13)
            .run()

        return try taskByID(taskID)
    }

    func taskByID(_ id: String) throws -> Task {
        let stmt = try db.prepare(Self.taskSelect + " WHERE id = ?")
        try stmt.bind(id, at: 1)
        guard stmt.step() else { throw RepositoryError.notFound("task not found: \(id)") }
        return Self.task(from: stmt)
    }

    func updateTask(
        id: String,
        title: String? = nil,
        notes: String? = nil,
        status: TaskStatus? = nil,
        priority: TaskPriority? = nil,
        area: TaskArea?? = nil,
        projectID: String?? = nil,
        dueDate: String?? = nil,
        scheduledDate: String?? = nil,
        estimatedMinutes: Int?? = nil
    ) throws -> Task {
        let existing = try taskByID(id)

        let newTitle = title.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? existing.title
        guard !newTitle.isEmpty else { throw RepositoryError.validation("task title cannot be empty") }

        let newNotes = notes ?? existing.notes
        let newStatus = status ?? existing.status
        let newPriority = priority ?? existing.priority
        let newArea = area ?? existing.area
        let newProjectID = projectID ?? existing.projectID
        let newDueDate = dueDate ?? existing.dueDate
        let newScheduledDate = scheduledDate ?? existing.scheduledDate
        let newEstimated = estimatedMinutes ?? existing.estimatedMinutes

        if let newProjectID, !newProjectID.isEmpty {
            _ = try projectByID(newProjectID)
        }

        let stmt = try db.prepare(
            "UPDATE tasks SET title = ?, notes = ?, status = ?, priority = ?, area = ?, "
            + "project_id = ?, due_date = ?, scheduled_date = ?, estimated_minutes = ?, updated_at = ? "
            + "WHERE id = ?"
        )
        try stmt.bind(newTitle, at: 1)
            .bind(newNotes, at: 2)
            .bind(newStatus.rawValue, at: 3)
            .bind(newPriority.rawValue, at: 4)
            .bind(newArea?.rawValue, at: 5)
            .bind(newProjectID, at: 6)
            .bind(newDueDate, at: 7)
            .bind(newScheduledDate, at: 8)
            .bind(newEstimated, at: 9)
            .bind(Self.nowStamp(), at: 10)
            .bind(id, at: 11)
            .run()

        return try taskByID(id)
    }

    func completeTask(id: String, at: String? = nil) throws -> Task {
        _ = try taskByID(id)
        let stamp = at ?? Self.nowStamp()
        let stmt = try db.prepare("UPDATE tasks SET status = 'completed', completed_at = ?, updated_at = ? WHERE id = ?")
        try stmt.bind(stamp, at: 1).bind(Self.nowStamp(), at: 2).bind(id, at: 3).run()
        return try taskByID(id)
    }

    func reopenTask(id: String) throws -> Task {
        _ = try taskByID(id)
        let stmt = try db.prepare("UPDATE tasks SET status = 'next', completed_at = NULL, updated_at = ? WHERE id = ?")
        try stmt.bind(Self.nowStamp(), at: 1).bind(id, at: 2).run()
        return try taskByID(id)
    }

    func archiveTask(id: String) throws -> Task {
        _ = try taskByID(id)
        let stmt = try db.prepare("UPDATE tasks SET archived = 1, updated_at = ? WHERE id = ?")
        try stmt.bind(Self.nowStamp(), at: 1).bind(id, at: 2).run()
        return try taskByID(id)
    }

    func restoreTask(id: String) throws -> Task {
        _ = try taskByID(id)
        let stmt = try db.prepare("UPDATE tasks SET archived = 0, updated_at = ? WHERE id = ?")
        try stmt.bind(Self.nowStamp(), at: 1).bind(id, at: 2).run()
        return try taskByID(id)
    }

    func deleteTask(id: String) throws {
        _ = try taskByID(id)
        let stmt = try db.prepare("DELETE FROM tasks WHERE id = ?")
        try stmt.bind(id, at: 1).run()
    }

    // MARK: - Queries

    private static let activeWhere = "archived = 0 AND status != 'completed'"
    private static let taskOrder =
        "ORDER BY (status = 'in_progress') DESC, "
        + "CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1 WHEN 'low' THEN 2 ELSE 3 END, "
        + "created_at ASC"

    private func queryTasks(predicate: String, params: [String?] = []) throws -> [Task] {
        let stmt = try db.prepare(Self.taskSelect + " WHERE " + predicate + " " + Self.taskOrder)
        for (offset, value) in params.enumerated() {
            try stmt.bind(value, at: Int32(offset + 1))
        }
        var result: [Task] = []
        while stmt.step() { result.append(Self.task(from: stmt)) }
        return result
    }

    func listInbox() throws -> [Task] {
        try queryTasks(predicate: "archived = 0 AND status = 'inbox'")
    }

    func listPending() throws -> [Task] {
        try queryTasks(predicate: Self.activeWhere)
    }

    func listToday(day: String? = nil) throws -> [Task] {
        let day = day ?? Self.todayLocal()
        return try queryTasks(
            predicate: Self.activeWhere + " AND (scheduled_date = ? OR (scheduled_date IS NULL AND due_date = ?))",
            params: [day, day]
        )
    }

    func listOverdue(day: String? = nil) throws -> [Task] {
        let day = day ?? Self.todayLocal()
        return try queryTasks(
            predicate: Self.activeWhere + " AND (scheduled_date < ? OR (scheduled_date IS NULL AND due_date < ?))",
            params: [day, day]
        )
    }

    func listUpcoming(day: String? = nil) throws -> [Task] {
        let day = day ?? Self.todayLocal()
        return try queryTasks(
            predicate: Self.activeWhere + " AND (scheduled_date > ? OR (scheduled_date IS NULL AND due_date > ?))",
            params: [day, day]
        )
    }

    func listByProject(_ projectID: String) throws -> [Task] {
        try queryTasks(predicate: Self.activeWhere + " AND project_id = ?", params: [projectID])
    }

    func listByArea(_ area: TaskArea) throws -> [Task] {
        try queryTasks(predicate: Self.activeWhere + " AND area = ?", params: [area.rawValue])
    }

    func listRecentlyCompleted(limit: Int = 20) throws -> [Task] {
        let safeLimit = max(limit, 1)
        let stmt = try db.prepare(
            "SELECT id, title, notes, status, priority, area, project_id, due_date, scheduled_date, estimated_minutes, archived, completed_at, created_at, updated_at FROM tasks WHERE archived = 0 AND status = 'completed' ORDER BY completed_at DESC LIMIT ?"
        )
        try stmt.bind(safeLimit, at: 1)
        var result: [Task] = []
        while stmt.step() { result.append(Self.task(from: stmt)) }
        return result
    }
}
