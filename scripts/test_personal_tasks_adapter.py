#!/usr/bin/env python3
"""Deterministic tests for the Hermes personal-tasks adapter.

Validates schema/migration, CRUD, query semantics, lifecycle, the CLI JSON
contract, and cache building against a temporary SQLite database (never the
real vault). Runs anywhere Python 3.8+ is available.

Run:

    python3 scripts/test_personal_tasks_adapter.py
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ADAPTERS_DIR = Path.home() / ".hermes" / "state" / "adapters"
sys.path.insert(0, str(ADAPTERS_DIR))

import personal_tasks as pt  # noqa: E402


class AdapterTestCase(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.db_path = Path(self._tmp.name) / "tasks.sqlite"
        self.conn = pt.open_db(self.db_path)
        pt.migrate(self.conn)

    def tearDown(self):
        self.conn.close()
        self._tmp.cleanup()


class SchemaMigrationTests(AdapterTestCase):
    def test_migration_creates_expected_tables(self):
        rows = self.conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
        ).fetchall()
        names = {r["name"] for r in rows}
        for table in ("schema_migrations", "projects", "tasks"):
            self.assertIn(table, names)

    def test_migration_records_version_one(self):
        versions = [
            r["version"]
            for r in self.conn.execute("SELECT version FROM schema_migrations")
        ]
        self.assertEqual(versions, [1])

    def test_migration_is_idempotent(self):
        self.assertEqual(pt.migrate(self.conn), 1)
        self.assertEqual(pt.migrate(self.conn), 1)

    def test_journal_mode_is_wal(self):
        mode = self.conn.execute("PRAGMA journal_mode").fetchone()[0]
        self.assertEqual(mode.lower(), "wal")

    def test_foreign_keys_enforced(self):
        import sqlite3
        with self.assertRaises(sqlite3.IntegrityError):
            self.conn.execute(
                "INSERT INTO tasks (id, title, project_id, created_at, updated_at)"
                " VALUES (?, ?, ?, ?, ?)",
                ("x", "ghost", "no-such-project", pt.now_utc_iso(), pt.now_utc_iso()),
            )


class CRUDTests(AdapterTestCase):
    def test_create_task_defaults(self):
        task = pt.create_task(self.conn, "Write thesis")
        self.assertEqual(task["title"], "Write thesis")
        self.assertEqual(task["status"], "inbox")
        self.assertEqual(task["priority"], "none")
        self.assertIsNone(task["area"])
        self.assertFalse(task["archived"])
        self.assertIsNone(task["completed_at"])

    def test_create_task_rejects_empty_title(self):
        with self.assertRaises(ValueError):
            pt.create_task(self.conn, "   ")

    def test_uuid_stable_across_updates(self):
        task = pt.create_task(self.conn, "Stable")
        updated = pt.update_task(self.conn, task["id"], title="Renamed")
        self.assertEqual(updated["id"], task["id"])
        self.assertEqual(updated["created_at"], task["created_at"])

    def test_ids_are_unique(self):
        a = pt.create_task(self.conn, "A")
        b = pt.create_task(self.conn, "B")
        self.assertNotEqual(a["id"], b["id"])


class QueryTests(AdapterTestCase):
    def _task(self, title, **kw):
        return pt.create_task(self.conn, title, **kw)

    def test_today_overdue_upcoming(self):
        day = "2026-09-21"
        sched_today = self._task("Today", scheduled_date=day)
        overdue = self._task("Overdue", scheduled_date="2026-09-20")
        upcoming = self._task("Upcoming", scheduled_date="2026-10-01")

        today = {t["id"] for t in pt.list_today(self.conn, day)}
        self.assertIn(sched_today["id"], today)
        self.assertNotIn(overdue["id"], today)
        self.assertNotIn(upcoming["id"], today)

        ov = {t["id"] for t in pt.list_overdue(self.conn, day)}
        self.assertIn(overdue["id"], ov)

        up = {t["id"] for t in pt.list_upcoming(self.conn, day)}
        self.assertIn(upcoming["id"], up)

    def test_list_by_project_and_area(self):
        proj = pt.create_project(self.conn, "Thesis")
        in_p = self._task("In project", project_id=proj["id"])
        uni = self._task("University", area="university")

        self.assertIn(
            in_p["id"],
            {t["id"] for t in pt.list_by_project(self.conn, proj["id"])},
        )
        self.assertIn(
            uni["id"],
            {t["id"] for t in pt.list_by_area(self.conn, "university")},
        )

    def test_recently_completed_ordering(self):
        a = self._task("A", status="completed")
        b = self._task("B", status="completed")
        pt.complete_task(self.conn, a["id"], "2026-09-20T10:00:00Z")
        pt.complete_task(self.conn, b["id"], "2026-09-21T10:00:00Z")
        recent = pt.list_recently_completed(self.conn, limit=10)
        self.assertEqual(recent[0]["id"], b["id"])
        self.assertEqual(recent[1]["id"], a["id"])


class LifecycleTests(AdapterTestCase):
    def test_complete_and_reopen(self):
        task = pt.create_task(self.conn, "Done", status="next")
        done = pt.complete_task(self.conn, task["id"], "2026-09-21T12:00:00Z")
        self.assertEqual(done["status"], "completed")
        self.assertEqual(done["completed_at"], "2026-09-21T12:00:00Z")
        reopened = pt.reopen_task(self.conn, task["id"])
        self.assertEqual(reopened["status"], "next")
        self.assertIsNone(reopened["completed_at"])

    def test_archive_and_restore(self):
        task = pt.create_task(self.conn, "Archive me")
        archived = pt.archive_task(self.conn, task["id"])
        self.assertTrue(archived["archived"])
        restored = pt.restore_task(self.conn, task["id"])
        self.assertFalse(restored["archived"])


class CacheTests(unittest.TestCase):
    def test_build_cache_is_fresh_and_structured(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "tasks.sqlite"
            conn = pt.open_db(db_path)
            pt.migrate(conn)
            pt.create_task(conn, "Due today", due_date=pt.today_local())
            conn.close()

            cache = pt.build_cache(db_path=db_path)
            self.assertEqual(cache["status"], "fresh")
            for key in (
                "today", "pending", "overdue", "upcoming",
                "recently_completed", "projects", "areas",
            ):
                self.assertIn(key, cache)
            self.assertEqual(cache["today"][0]["title"], "Due today")
            self.assertEqual(
                set(cache["areas"].keys()),
                set(pt.AREAS),
            )

    def test_build_cache_unavailable_on_bad_path(self):
        cache = pt.build_cache(db_path="/nonexistent-dir-xyz/sub/tasks.sqlite")
        self.assertEqual(cache["status"], "unavailable")


class CLITests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.db_path = Path(self._tmp.name) / "tasks.sqlite"
        self.adapter = ADAPTERS_DIR / "personal_tasks.py"

    def tearDown(self):
        self._tmp.cleanup()

    def _run(self, *argv):
        env = dict(os.environ)
        env["TASKS_DB_PATH"] = str(self.db_path)
        return subprocess.run(
            [sys.executable, str(self.adapter), *argv],
            capture_output=True,
            text=True,
            env=env,
        )

    def test_read_command_returns_json(self):
        r = self._run("list_today")
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads(r.stdout)
        self.assertIsInstance(data, list)

    def test_create_and_complete_via_cli(self):
        r = self._run("create_task", "--title", "From CLI", "--status", "next")
        self.assertEqual(r.returncode, 0, r.stderr)
        created = json.loads(r.stdout)
        self.assertEqual(created["title"], "From CLI")
        self.assertEqual(created["status"], "next")

        r = self._run("complete_task", "--id", created["id"])
        self.assertEqual(r.returncode, 0, r.stderr)
        completed = json.loads(r.stdout)
        self.assertEqual(completed["status"], "completed")

    def test_get_task_roundtrip(self):
        r = self._run("create_task", "--title", "Lookup")
        task = json.loads(r.stdout)
        r = self._run("get_task", "--id", task["id"])
        self.assertEqual(json.loads(r.stdout)["id"], task["id"])

    def test_invalid_area_rejected(self):
        r = self._run("create_task", "--title", "Bad", "--area", "mars")
        self.assertNotEqual(r.returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
