-- TodoMac — canonical SQLite schema (Phase 1)
--
-- This file is the single source of truth shared by three consumers:
--   * the native macOS app (TodoMac/Services/Schema.swift)
--   * the Python reference repository (scripts/tasks_db.py)
--   * the Hermes adapter (~/.hermes/state/adapters/personal_tasks.py)
--
-- Each consumer embeds this exact DDL. scripts/validate_project.py and the
-- adapter test-suite assert they have not drifted.
--
-- Conventions:
--   * IDs are stable UUID strings generated client-side (uppercase hex is NOT
--     required; any UUID string is stable and never regenerated).
--   * created_at / updated_at / completed_at are UTC ISO-8601 timestamps
--     (YYYY-MM-DDTHH:MM:SSZ).
--   * scheduled_date / due_date are date-only ISO strings (YYYY-MM-DD) in
--     the user's local timezone.
--   * archived = 1 is a soft delete; V1 CRUD never hard-deletes a row.
--   * messenger status / priority / area are constrained CHECK-enums below.
--
-- Future path (explicitly NOT implemented in Phase 1):
--   A later migration will add:
--     pomodoro_sessions (
--       id                TEXT PRIMARY KEY,
--       task_id           TEXT REFERENCES tasks(id),
--       started_at        TEXT,
--       ended_at          TEXT,
--       duration_minutes  INTEGER,
--       logged_at         TEXT
--     )
--   to link focus sessions back to tasks. No Pomodoro integration ships now.

BEGIN;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version     INTEGER PRIMARY KEY,
    applied_at  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS projects (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    color       TEXT,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL,
    archived    INTEGER NOT NULL DEFAULT 0
);

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
);

CREATE INDEX IF NOT EXISTS idx_tasks_status      ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_scheduled   ON tasks(scheduled_date);
CREATE INDEX IF NOT EXISTS idx_tasks_due         ON tasks(due_date);
CREATE INDEX IF NOT EXISTS idx_tasks_project     ON tasks(project_id);
CREATE INDEX IF NOT EXISTS idx_tasks_area        ON tasks(area);
CREATE INDEX IF NOT EXISTS idx_projects_archived ON projects(archived);

COMMIT;