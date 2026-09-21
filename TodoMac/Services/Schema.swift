import Foundation

// Canonical schema + migration metadata. This mirrors
// `schema/schema.sql` exactly — scripts/validate_project.py asserts the two
// have not drifted. Version 1 ships the full initial schema; future migrations
// (e.g. `pomodoro_sessions`) are appended here with a bumped version and are
// applied in short transactions by TaskRepository.migrate().

enum Schema {
    static let schemaVersion = 1

    /// Ordered migrations. Each entry is a version paired with the statements
    /// that take the database from the previous version to this one.
    static let migrations: [(version: Int, statements: [String])] = [
        (version: 1, statements: versionOneStatements),
    ]

    private static let versionOneStatements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version     INTEGER PRIMARY KEY,
            applied_at  TEXT NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS projects (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            color       TEXT,
            created_at  TEXT NOT NULL,
            updated_at  TEXT NOT NULL,
            archived    INTEGER NOT NULL DEFAULT 0
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS tasks (
            id                 TEXT PRIMARY KEY,
            title              TEXT NOT NULL,
            notes              TEXT,
            status             TEXT NOT NULL DEFAULT 'inbox'
                               CHECK (status IN
                                      ('inbox','next','in_progress','waiting','completed')),
            priority           TEXT NOT NULL DEFAULT 'none'
                               CHECK (priority IN ('none','low','medium','high')),
            area               TEXT
                               CHECK (area IS NULL OR area IN
                                      ('university','career','salinas','hermes','admin',
                                       'personal','fitness','faith')),
            project_id         TEXT REFERENCES projects(id),
            due_date           TEXT,
            scheduled_date     TEXT,
            estimated_minutes  INTEGER,
            archived           INTEGER NOT NULL DEFAULT 0,
            completed_at       TEXT,
            created_at         TEXT NOT NULL,
            updated_at         TEXT NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS idx_tasks_status      ON tasks(status)",
        "CREATE INDEX IF NOT EXISTS idx_tasks_scheduled   ON tasks(scheduled_date)",
        "CREATE INDEX IF NOT EXISTS idx_tasks_due         ON tasks(due_date)",
        "CREATE INDEX IF NOT EXISTS idx_tasks_project     ON tasks(project_id)",
        "CREATE INDEX IF NOT EXISTS idx_tasks_area        ON tasks(area)",
        "CREATE INDEX IF NOT EXISTS idx_projects_archived ON projects(archived)",
    ]
}