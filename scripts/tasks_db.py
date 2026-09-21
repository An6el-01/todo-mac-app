#!/usr/bin/env python3
"""TodoMac reference repository + CLI (Python, stdlib only).

This module is a dependency-free mirror of the native Swift repository
(TodoMac/Services/*.swift). It exists so the SQLite schema, migrations, and
query semantics can be validated deterministically on non-macOS hosts (WSL/CI)
via unittest, and so Hermes / scripts can operate on the shared task database
without building the app.

The authoritative database path on Angel's machine is:

    ~/hermes-vault/00-Life/Tasks/tasks.sqlite

The Swift app must implement identical behavior against this same schema.
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import sys
import uuid
from datetime import date, datetime, timezone
from pathlib import Path

DEFAULT_DB_DIR = Path.home() / "hermes-vault" / "00-Life" / "Tasks"
DEFAULT_DB_PATH = DEFAULT_DB_DIR / "tasks.sqlite"

STATUSES = ("inbox", "next", "in_progress", "waiting", "completed")
ACTIVE_STATUSES = ("inbox", "next", "in_progress", "waiting")
PRIORITIES = ("none", "low", "medium", "high")
AREAS = (
    "university",
    "career",
    "salinas",
    "hermes",
    "admin",
    "personal",
    "fitness",
    "faith",
)

# Migration list: (version, sql). Version 1 is the full initial schema read
# from schema/schema.sql so Swift / adapter / reference cannot drift.
_SCHEMA_PATH = Path(__file__).resolve().parent.parent / "schema" / "schema.sql"

if _SCHEMA_PATH.exists():
    _SCHEMA_SQL = _SCHEMA_PATH.read_text(encoding="utf-8")
else:  # pragma: no cover - fallback only
    _SCHEMA_SQL = ""

MIGRATIONS = [
    (1, _SCHEMA_SQL),
]

# Ordering of priority for "highest first" sorts.
_PRIORITY_ORDER = {"high": 0, "medium": 1, "low": 2, "none": 3}


def now_utc_iso() -> str:
    """Current UTC timestamp as YYYY-MM-DDTHH:MM:SSZ."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def new_id() -> str:
    """Generate a stable UUID string id. Never regenerated for existing rows."""
    return str(uuid.uuid4())


def today_local() -> str:
    """Local date string YYYY-MM-DD (system local time)."""
    return date.today().isoformat()


# --------------------------------------------------------------------------- #
# Connection and migration
# --------------------------------------------------------------------------- #


def open_db(path=None) -> sqlite3.Connection:
    """Open (creating if needed) the database with foreign_keys + WAL enabled."""
    db_path = Path(path) if path else DEFAULT_DB_PATH
    db_path.parent.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA journal_mode = WAL")
    conn.execute("PRAGMA synchronous = NORMAL")
    return conn


def migrate(conn: sqlite3.Connection) -> int:
    """Apply any pending migrations in short transactions; return new version."""
    conn.execute(
        "CREATE TABLE IF NOT EXISTS schema_migrations ("
        "version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)"
    )

    current = conn.execute(
        "SELECT COALESCE(MAX(version), 0) FROM schema_migrations"
    ).fetchone()[0]
    applied = 0

    for version, sql in MIGRATIONS:
        if version <= current:
            continue
        if not sql:
            continue
        with conn:  # short transaction per migration
            conn.executescript(sql)
            conn.execute(
                "INSERT OR REPLACE INTO schema_migrations (version, applied_at) "
                "VALUES (?, ?)",
                (version, now_utc_iso()),
            )
        applied += 1

    return current + (applied or 0)


# --------------------------------------------------------------------------- #
# Row normalization
# --------------------------------------------------------------------------- #


def _task_row(row) -> dict:
    return {
        "id": row["id"],
        "title": row["title"],
        "notes": row["notes"],
        "status": row["status"],
        "priority": row["priority"],
        "area": row["area"],
        "project_id": row["project_id"],
        "due_date": row["due_date"],
        "scheduled_date": row["scheduled_date"],
        "estimated_minutes": row["estimated_minutes"],
        "archived": bool(row["archived"]),
        "completed_at": row["completed_at"],
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


def _project_row(row) -> dict:
    return {
        "id": row["id"],
        "name": row["name"],
        "color": row["color"],
        "archived": bool(row["archived"]),
        "created_at": row["created_at"],
        "updated_at": row["updated_at"],
    }


# --------------------------------------------------------------------------- #
# Validation helpers
# --------------------------------------------------------------------------- #


def _validate_enum(value, allowed, label):
    if value is None:
        return value
    if value not in allowed:
        raise ValueError(f"invalid {label}: {value!r}")
    return value


def _validate_date(value, label):
    if value is None:
        return None
    if not isinstance(value, str) or len(value) != 10 or value[4] != "-":
        raise ValueError(f"invalid {label}: {value!r} (expected YYYY-MM-DD)")
    return value


# --------------------------------------------------------------------------- #
# Project CRUD
# --------------------------------------------------------------------------- #


def create_project(conn, name, *, color=None, project_id=None) -> dict:
    if not name or not name.strip():
        raise ValueError("project name is required")
    connect_id = project_id or new_id()
    stamp = now_utc_iso()
    with conn:
        conn.execute(
            "INSERT INTO projects (id, name, color, created_at, updated_at, archived) "
            "VALUES (?, ?, ?, ?, ?, 0)",
            (connect_id, name.strip(), color, stamp, stamp),
        )
    return get_project(conn, connect_id)


def get_project(conn, project_id) -> dict:
    row = conn.execute(
        "SELECT * FROM projects WHERE id = ?", (project_id,)
    ).fetchone()
    if row is None:
        raise KeyError(f"project not found: {project_id}")
    return _project_row(row)


def list_projects(conn, include_archived=False) -> list[dict]:
    sql = "SELECT * FROM projects"
    if not include_archived:
        sql += " WHERE archived = 0"
    sql += " ORDER BY name COLLATE NOCASE"
    return [_project_row(r) for r in conn.execute(sql).fetchall()]


def update_project(conn, project_id, *, name=None, color=None) -> dict:
    existing = get_project(conn, project_id)
    with conn:
        conn.execute(
            "UPDATE projects SET name = ?, color = ?, updated_at = ? WHERE id = ?",
            (
                name if name is not None else existing["name"],
                color if color is not None else existing["color"],
                now_utc_iso(),
                project_id,
            ),
        )
    return get_project(conn, project_id)


def archive_project(conn, project_id) -> dict:
    get_project(conn, project_id)  # ensure exists
    with conn:
        conn.execute(
            "UPDATE projects SET archived = 1, updated_at = ? WHERE id = ?",
            (now_utc_iso(), project_id),
        )
    return get_project(conn, project_id)


# --------------------------------------------------------------------------- #
# Task CRUD
# --------------------------------------------------------------------------- #


def create_task(
    conn,
    title,
    *,
    notes=None,
    status="inbox",
    priority="none",
    area=None,
    project_id=None,
    due_date=None,
    scheduled_date=None,
    estimated_minutes=None,
    task_id=None,
) -> dict:
    if not title or not title.strip():
        raise ValueError("task title is required")

    status = _validate_enum(status, STATUSES, "status")
    priority = _validate_enum(priority, PRIORITIES, "priority")
    area = _validate_enum(area, AREAS, "area")
    due_date = _validate_date(due_date, "due_date")
    scheduled_date = _validate_date(scheduled_date, "scheduled_date")

    if project_id is not None:
        get_project(conn, project_id)  # enforce FK existence explicitly

    connect_id = task_id or new_id()
    stamp = now_utc_iso()
    completed_at = stamp if status == "completed" else None

    with conn:
        conn.execute(
            "INSERT INTO tasks ("
            " id, title, notes, status, priority, area, project_id,"
            " due_date, scheduled_date, estimated_minutes, archived,"
            " completed_at, created_at, updated_at"
            ") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)",
            (
                connect_id,
                title.strip(),
                notes,
                status,
                priority,
                area,
                project_id,
                due_date,
                scheduled_date,
                estimated_minutes,
                completed_at,
                stamp,
                stamp,
            ),
        )
    return get_task(conn, connect_id)


def get_task(conn, task_id) -> dict:
    row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    if row is None:
        raise KeyError(f"task not found: {task_id}")
    return _task_row(row)


def _mutate_task(conn, task_id, fields: dict) -> dict:
    existing = get_task(conn, task_id)
    changed = {}

    mapping = {
        "title": existing["title"],
        "notes": existing["notes"],
        "status": existing["status"],
        "priority": existing["priority"],
        "area": existing["area"],
        "project_id": existing["project_id"],
        "due_date": existing["due_date"],
        "scheduled_date": existing["scheduled_date"],
        "estimated_minutes": existing["estimated_minutes"],
    }

    if "title" in fields:
        title = fields["title"]
        if not title or not title.strip():
            raise ValueError("task title cannot be empty")
        mapping["title"] = title.strip()
        changed["title"] = title.strip()

    if "notes" in fields:
        mapping["notes"] = fields["notes"]
        changed["notes"] = fields["notes"]

    if "status" in fields and fields["status"] is not None:
        mapping["status"] = _validate_enum(fields["status"], STATUSES, "status")
        changed["status"] = mapping["status"]

    if "priority" in fields and fields["priority"] is not None:
        mapping["priority"] = _validate_enum(fields["priority"], PRIORITIES, "priority")
        changed["priority"] = mapping["priority"]

    if "area" in fields and fields["area"] is not None:
        mapping["area"] = _validate_enum(fields["area"], AREAS, "area")
        changed["area"] = mapping["area"]

    if "project_id" in fields and fields["project_id"] is not None:
        if fields["project_id"] != "":
            get_project(conn, fields["project_id"])
            mapping["project_id"] = fields["project_id"]
        else:
            mapping["project_id"] = None
        changed["project_id"] = mapping["project_id"]

    for date_field in ("due_date", "scheduled_date"):
        if date_field in fields:
            mapping[date_field] = _validate_date(fields[date_field], date_field)
            changed[date_field] = mapping[date_field]

    if "estimated_minutes" in fields:
        mapping["estimated_minutes"] = fields["estimated_minutes"]
        changed["estimated_minutes"] = fields["estimated_minutes"]

    with conn:
        conn.execute(
            "UPDATE tasks SET title=?, notes=?, status=?, priority=?, area=?,"
            " project_id=?, due_date=?, scheduled_date=?, estimated_minutes=?,"
            " updated_at=? WHERE id=?",
            (
                mapping["title"],
                mapping["notes"],
                mapping["status"],
                mapping["priority"],
                mapping["area"],
                mapping["project_id"],
                mapping["due_date"],
                mapping["scheduled_date"],
                mapping["estimated_minutes"],
                now_utc_iso(),
                task_id,
            ),
        )
    return get_task(conn, task_id)


def update_task(conn, task_id, **fields) -> dict:
    """Update any supported mutable fields on a task."""
    return _mutate_task(conn, task_id, fields)


def complete_task(conn, task_id, at=None) -> dict:
    stamp = at or now_utc_iso()
    get_task(conn, task_id)
    with conn:
        conn.execute(
            "UPDATE tasks SET status = 'completed', completed_at = ?,"
            " updated_at = ? WHERE id = ?",
            (stamp, now_utc_iso(), task_id),
        )
    return get_task(conn, task_id)


def reopen_task(conn, task_id) -> dict:
    get_task(conn, task_id)
    with conn:
        conn.execute(
            "UPDATE tasks SET status = 'next', completed_at = NULL,"
            " updated_at = ? WHERE id = ?",
            (now_utc_iso(), task_id),
        )
    return get_task(conn, task_id)


def archive_task(conn, task_id) -> dict:
    get_task(conn, task_id)
    with conn:
        conn.execute(
            "UPDATE tasks SET archived = 1, updated_at = ? WHERE id = ?",
            (now_utc_iso(), task_id),
        )
    return get_task(conn, task_id)


def restore_task(conn, task_id) -> dict:
    get_task(conn, task_id)
    with conn:
        conn.execute(
            "UPDATE tasks SET archived = 0, updated_at = ? WHERE id = ?",
            (now_utc_iso(), task_id),
        )
    return get_task(conn, task_id)


# --------------------------------------------------------------------------- #
# Query operations (Active = status != completed AND archived = 0)
# --------------------------------------------------------------------------- #

_ACTIVE = "archived = 0 AND status != 'completed'"
_ORDER = (
    " ORDER BY (status = 'in_progress') DESC,"
    " CASE priority WHEN 'high' THEN 0 WHEN 'medium' THEN 1"
    " WHEN 'low' THEN 2 ELSE 3 END,"
    " created_at ASC"
)


def _query_tasks(conn, where, params=()):
    sql = "SELECT * FROM tasks WHERE " + where + _ORDER
    return [_task_row(r) for r in conn.execute(sql, params).fetchall()]


def list_inbox(conn) -> list[dict]:
    return _query_tasks(conn, "archived = 0 AND status = 'inbox'")


def list_pending(conn) -> list[dict]:
    return _query_tasks(conn, _ACTIVE)


def list_today(conn, day=None) -> list[dict]:
    day = day or today_local()
    return _query_tasks(
        conn,
        _ACTIVE + " AND (scheduled_date = ? OR (scheduled_date IS NULL AND due_date = ?))",
        (day, day),
    )


def list_overdue(conn, day=None) -> list[dict]:
    day = day or today_local()
    return _query_tasks(
        conn,
        _ACTIVE + " AND (scheduled_date < ? OR (scheduled_date IS NULL AND due_date < ?))",
        (day, day),
    )


def list_upcoming(conn, day=None) -> list[dict]:
    day = day or today_local()
    return _query_tasks(
        conn,
        _ACTIVE + " AND (scheduled_date > ? OR (scheduled_date IS NULL AND due_date > ?))",
        (day, day),
    )


def list_by_project(conn, project_id) -> list[dict]:
    return _query_tasks(conn, _ACTIVE + " AND project_id = ?", (project_id,))


def list_by_area(conn, area) -> list[dict]:
    area = _validate_enum(area, AREAS, "area")
    return _query_tasks(conn, _ACTIVE + " AND area = ?", (area,))


def list_recently_completed(conn, limit=20) -> list[dict]:
    if limit is None or limit <= 0:
        limit = 20
    sql = (
        "SELECT * FROM tasks WHERE archived = 0 AND status = 'completed'"
        " ORDER BY completed_at DESC LIMIT ?"
    )
    return [
        _task_row(r) for r in conn.execute(sql, (int(limit),)).fetchall()
    ]


def list_all(conn, include_archived=False) -> list[dict]:
    sql = "SELECT * FROM tasks"
    if not include_archived:
        sql += " WHERE archived = 0"
    sql += " ORDER BY created_at ASC"
    return [_task_row(r) for r in conn.execute(sql).fetchall()]


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #


_COMMANDS = {
    "list_today",
    "list_pending",
    "list_overdue",
    "list_upcoming",
    "list_inbox",
    "get_task",
    "list_by_project",
    "list_by_area",
    "list_recently_completed",
    "list_projects",
    "create_task",
    "update_task",
    "complete_task",
    "reopen_task",
    "archive_task",
    "create_project",
}


def _print_json(obj):
    print(json.dumps(obj, ensure_ascii=False, indent=2))


def _serialize_conn_cli(args):
    with open_db(args.db) as conn:
        migrate(conn)

        cmd = args.command

        if cmd == "list_today":
            return _print_json(list_today(conn, args.day))
        if cmd == "list_pending":
            return _print_json(list_pending(conn))
        if cmd == "list_overdue":
            return _print_json(list_overdue(conn, args.day))
        if cmd == "list_upcoming":
            return _print_json(list_upcoming(conn, args.day))
        if cmd == "list_inbox":
            return _print_json(list_inbox(conn))
        if cmd == "list_projects":
            return _print_json(list_projects(conn))
        if cmd == "list_recently_completed":
            return _print_json(list_recently_completed(conn, args.limit))
        if cmd == "get_task":
            return _print_json(get_task(conn, args.id))
        if cmd == "list_by_project":
            return _print_json(list_by_project(conn, args.id))
        if cmd == "list_by_area":
            return _print_json(list_by_area(conn, args.id))
        if cmd == "create_task":
            return _print_json(
                create_task(
                    conn,
                    args.title,
                    notes=args.notes,
                    status=args.status,
                    priority=args.priority,
                    area=args.area,
                    project_id=args.project_id,
                    due_date=args.due_date,
                    scheduled_date=args.scheduled_date,
                    estimated_minutes=args.estimated_minutes,
                )
            )
        if cmd == "create_project":
            return _print_json(create_project(conn, args.title, color=args.color))
        if cmd == "update_task":
            fields = {}
            for key in (
                "title", "notes", "status", "priority", "area", "project_id",
                "due_date", "scheduled_date", "estimated_minutes",
            ):
                val = getattr(args, key, None)
                if val is not None:
                    fields[key] = val
            return _print_json(update_task(conn, args.id, **fields))
        if cmd == "complete_task":
            return _print_json(complete_task(conn, args.id))
        if cmd == "reopen_task":
            return _print_json(reopen_task(conn, args.id))
        if cmd == "archive_task":
            return _print_json(archive_task(conn, args.id))
        raise SystemExit(f"unknown command: {cmd}")


def build_parser():
    parser = argparse.ArgumentParser(description="TodoMac task database CLI")
    parser.add_argument("command", choices=sorted(_COMMANDS))
    parser.add_argument("--db", default=None, help="override database path")
    parser.add_argument("--id", default=None)
    parser.add_argument("--day", default=None, help="reference day YYYY-MM-DD")
    parser.add_argument("--title", default=None)
    parser.add_argument("--notes", default=None)
    parser.add_argument("--status", default=None)
    parser.add_argument("--priority", default=None)
    parser.add_argument("--area", default=None)
    parser.add_argument("--project_id", default=None)
    parser.add_argument("--due_date", default=None)
    parser.add_argument("--scheduled_date", default=None)
    parser.add_argument("--estimated_minutes", type=int, default=None)
    parser.add_argument("--color", default=None)
    parser.add_argument("--limit", type=int, default=20)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    return _serialize_conn_cli(args)


if __name__ == "__main__":
    main()