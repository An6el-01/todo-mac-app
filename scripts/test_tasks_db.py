#!/usr/bin/env python3
"""Deterministic unit tests for the TodoMac reference repository.

Runs on any host with Python 3.8+ and the stdlib sqlite3 module. This mirrors
the Swift XCTest suite (TodoMacTests/*) so schema, migrations, CRUD, and query
semantics can be validated without macOS / Xcode.

Run:
    python3 scripts/test_tasks_db.py
"""

import os
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import tasks_db as db  # noqa: E402


class TaskDBTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.db_path = Path(self._tmp.name) / "tasks.sqlite"
        self.conn = db.open_db(self.db_path)
        db.migrate(self.conn)

    def tearDown(self):
        self.conn.close()
        self._tmp.cleanup()


class SchemaMigrationTests(TaskDBTestCase):
    def test_migration_creates_expected_tables(self):
        rows = self.conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        ).fetchall()
        names = {r["name"] for r in rows}
        self.assertIn("schema_migrations", names)
        self.assertIn("projects", names)
        self.assertIn("tasks", names)

    def test_migration_records_version_one(self):
        versions = [
            r["version"]
            for r in self.conn.execute("SELECT version FROM schema_migrations")
        ]
        self.assertEqual(versions, [1])

    def test_migration_is_idempotent(self):
        version_before = db.migrate(self.conn)
        version_after = db.migrate(self.conn)
        self.assertEqual(version_before, version_after)
        self.assertEqual(version_after, 1)

    def test_empty_database_migrates_to_current(self):
        # A brand-new connection with no tables migrates cleanly.
        fresh = tempfile.NamedTemporaryFile(suffix=".sqlite", delete=False)
        fresh.close()
        conn = db.open_db(fresh.name)
        try:
            version = db.migrate(conn)
            self.assertEqual(version, 1)
        finally:
            conn.close()
            os.unlink(fresh.name)


class DatabaseConfigurationTests(TaskDBTestCase):
    def test_journal_mode_is_wal(self):
        mode = self.conn.execute("PRAGMA journal_mode").fetchone()[0]
        self.assertEqual(mode.lower(), "wal")

    def test_foreign_keys_enforced(self):
        with self.assertRaises(sqlite3.IntegrityError):
            self.conn.execute(
                "INSERT INTO tasks (id, title, project_id, created_at, updated_at)"
                " VALUES (?, ?, ?, ?, ?)",
                ("x", "ghost", "no-such-project", db.now_utc_iso(), db.now_utc_iso()),
            )

    def test_database_directory_created(self):
        nested = Path(self._tmp.name) / "a" / "b" / "tasks.sqlite"
        conn = db.open_db(nested)
        conn.close()
        self.assertTrue(nested.exists())


class CRUDTests(TaskDBTestCase):
    def test_create_task_defaults(self):
        task = db.create_task(self.conn, "Write thesis")
        self.assertEqual(task["title"], "Write thesis")
        self.assertEqual(task["status"], "inbox")
        self.assertEqual(task["priority"], "none")
        self.assertIsNone(task["area"])
        self.assertFalse(task["archived"])
        self.assertIsNone(task["completed_at"])
        self.assertIsNotNone(task["id"])
        self.assertIsNotNone(task["created_at"])
        self.assertIsNotNone(task["updated_at"])

    def test_create_task_rejects_empty_title(self):
        with self.assertRaises(ValueError):
            db.create_task(self.conn, "   ")

    def test_create_task_rejects_invalid_status(self):
        with self.assertRaises(ValueError):
            db.create_task(self.conn, "Task", status="bogus")

    def test_create_task_rejects_invalid_priority(self):
        with self.assertRaises(ValueError):
            db.create_task(self.conn, "Task", priority="urgent")

    def test_create_task_rejects_invalid_area(self):
        with self.assertRaises(ValueError):
            db.create_task(self.conn, "Task", area="mars")

    def test_create_task_rejects_invalid_due_date(self):
        with self.assertRaises(ValueError):
            db.create_task(self.conn, "Task", due_date="not-a-date")

    def test_can_create_with_all_fields(self):
        proj = db.create_project(self.conn, "Thesis")
        task = db.create_task(
            self.conn,
            "Draft chapter 1",
            notes="intro + lit review",
            status="next",
            priority="high",
            area="university",
            project_id=proj["id"],
            due_date="2026-10-01",
            scheduled_date="2026-09-25",
            estimated_minutes=90,
        )
        self.assertEqual(task["area"], "university")
        self.assertEqual(task["priority"], "high")
        self.assertEqual(task["status"], "next")
        self.assertEqual(task["project_id"], proj["id"])
        self.assertEqual(task["due_date"], "2026-10-01")
        self.assertEqual(task["estimated_minutes"], 90)

    def test_update_task_fields(self):
        task = db.create_task(self.conn, "Old title")
        updated = db.update_task(
            self.conn,
            task["id"],
            title="New title",
            status="in_progress",
            priority="medium",
            notes="some notes",
        )
        self.assertEqual(updated["title"], "New title")
        self.assertEqual(updated["status"], "in_progress")
        self.assertEqual(updated["priority"], "medium")
        self.assertEqual(updated["notes"], "some notes")
        # Unspecified fields preserved.
        self.assertEqual(updated["area"], task["area"])

    def test_get_task_roundtrip(self):
        task = db.create_task(self.conn, "Roundtrip")
        fetched = db.get_task(self.conn, task["id"])
        self.assertEqual(fetched, task)

    def test_get_task_missing_raises(self):
        with self.assertRaises(KeyError):
            db.get_task(self.conn, "does-not-exist")

    def test_uuid_stable_across_updates(self):
        task = db.create_task(self.conn, "Stable")
        original_id = task["id"]
        updated = db.update_task(self.conn, original_id, title="Renamed")
        self.assertEqual(updated["id"], original_id)
        # created_at never changes on update.
        self.assertEqual(updated["created_at"], task["created_at"])

    def test_ids_are_unique(self):
        a = db.create_task(self.conn, "A")
        b = db.create_task(self.conn, "B")
        self.assertNotEqual(a["id"], b["id"])

    def test_explicit_task_id_is_respected(self):
        task = db.create_task(self.conn, "Custom id", task_id="fixed-id-123")
        self.assertEqual(task["id"], "fixed-id-123")


class ProjectCRUDTests(TaskDBTestCase):
    def test_create_and_list_projects(self):
        db.create_project(self.conn, "Thesis")
        db.create_project(self.conn, "Freelance")
        names = [p["name"] for p in db.list_projects(self.conn)]
        self.assertEqual(names, ["Freelance", "Thesis"])  # NOCASE sort

    def test_archive_project_hides_from_default_list(self):
        p = db.create_project(self.conn, "Old project")
        db.archive_project(self.conn, p["id"])
        self.assertNotIn(p["id"], {x["id"] for x in db.list_projects(self.conn)})
        self.assertIn(
            p["id"],
            {x["id"] for x in db.list_projects(self.conn, include_archived=True)},
        )

    def test_task_project_foreign_key_rejects_missing(self):
        with self.assertRaises(KeyError):
            db.create_task(self.conn, "Orphan", project_id="nope")


class QueryTests(TaskDBTestCase):
    def _task(self, title, **kw):
        return db.create_task(self.conn, title, **kw)

    def test_pending_excludes_completed_and_archived(self):
        active = self._task("active", status="next")
        done = self._task("done", status="completed")
        archived = self._task("archived", status="next")
        db.archive_task(self.conn, archived["id"])
        pending = {t["id"] for t in db.list_pending(self.conn)}
        self.assertIn(active["id"], pending)
        self.assertNotIn(done["id"], pending)
        self.assertNotIn(archived["id"], pending)

    def test_today_matches_scheduled_and_unscheduled_due(self):
        day = "2026-09-21"
        scheduled_today = self._task("Sched today", scheduled_date=day)
        due_today = self._task("Due today", due_date=day)
        future = self._task("Future", scheduled_date="2026-10-01")
        past = self._task("Past", scheduled_date="2026-09-01")
        today = {t["id"] for t in db.list_today(self.conn, day)}
        self.assertIn(scheduled_today["id"], today)
        self.assertIn(due_today["id"], today)
        self.assertNotIn(future["id"], today)
        self.assertNotIn(past["id"], today)

    def test_overdue(self):
        day = "2026-09-21"
        overdue_sched = self._task("Overdue sched", scheduled_date="2026-09-20")
        overdue_due = self._task("Overdue due", due_date="2026-09-19")
        today = self._task("Today", scheduled_date="2026-09-21")
        future = self._task("Future", scheduled_date="2026-10-01")
        overdue = {t["id"] for t in db.list_overdue(self.conn, day)}
        self.assertIn(overdue_sched["id"], overdue)
        self.assertIn(overdue_due["id"], overdue)
        self.assertNotIn(today["id"], overdue)
        self.assertNotIn(future["id"], overdue)

    def test_upcoming(self):
        day = "2026-09-21"
        future = self._task("Future", scheduled_date="2026-10-01")
        future_due = self._task("Future due", due_date="2026-12-01")
        past = self._task("Past", scheduled_date="2026-09-01")
        upcoming = {t["id"] for t in db.list_upcoming(self.conn, day)}
        self.assertIn(future["id"], upcoming)
        self.assertIn(future_due["id"], upcoming)
        self.assertNotIn(past["id"], upcoming)

    def test_completed_excluded_from_active_queries(self):
        done = self._task("Done", status="completed")
        done["completed_at"] and None
        self.assertNotIn(
            done["id"], {t["id"] for t in db.list_pending(self.conn)}
        )

    def test_list_by_project(self):
        p = db.create_project(self.conn, "Thesis")
        in_p = self._task("In project", project_id=p["id"])
        out = self._task("Not in project")
        ids = {t["id"] for t in db.list_by_project(self.conn, p["id"])}
        self.assertIn(in_p["id"], ids)
        self.assertNotIn(out["id"], ids)

    def test_list_by_area(self):
        uni = self._task("University task", area="university")
        other = self._task("Career task", area="career")
        ids = {t["id"] for t in db.list_by_area(self.conn, "university")}
        self.assertIn(uni["id"], ids)
        self.assertNotIn(other["id"], ids)

    def test_list_recently_completed_order_and_limit(self):
        a = self._task("A", status="completed")
        b = self._task("B", status="completed")
        # complete explicitly to stamp completed_at
        db.complete_task(self.conn, a["id"], "2026-09-20T10:00:00Z")
        db.complete_task(self.conn, b["id"], "2026-09-21T10:00:00Z")
        recent = db.list_recently_completed(self.conn, limit=10)
        self.assertEqual(recent[0]["id"], b["id"])  # newest first
        self.assertEqual(recent[1]["id"], a["id"])

    def test_inbox_query(self):
        inbox = self._task("In inbox", status="inbox")
        nxt = self._task("Next", status="next")
        ids = {t["id"] for t in db.list_inbox(self.conn)}
        self.assertIn(inbox["id"], ids)
        self.assertNotIn(nxt["id"], ids)


class LifecycleTests(TaskDBTestCase):
    def test_complete_task_sets_status_and_timestamp(self):
        task = db.create_task(self.conn, "To complete", status="next")
        done = db.complete_task(self.conn, task["id"], "2026-09-21T12:00:00Z")
        self.assertEqual(done["status"], "completed")
        self.assertEqual(done["completed_at"], "2026-09-21T12:00:00Z")

    def test_reopen_task_clears_completed_and_returns_to_next(self):
        task = db.create_task(self.conn, "Reopen me", status="completed")
        reopened = db.reopen_task(self.conn, task["id"])
        self.assertEqual(reopened["status"], "next")
        self.assertIsNone(reopened["completed_at"])

    def test_archive_and_restore(self):
        task = db.create_task(self.conn, "Archive me")
        archived = db.archive_task(self.conn, task["id"])
        self.assertTrue(archived["archived"])
        restored = db.restore_task(self.conn, task["id"])
        self.assertFalse(restored["archived"])


if __name__ == "__main__":
    unittest.main(verbosity=2)