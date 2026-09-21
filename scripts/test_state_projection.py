#!/usr/bin/env python3
"""Deterministic test of the Hermes state projection for personal_tasks.

Runs ``build_state.py`` and ``build_context.py`` against a temporary HOME with
stub adapters (so the projection is exercised without the real vault, Kanban,
Calendar, or Gmail) and the real ``personal_tasks.py`` adapter over a temporary
SQLite database. Verifies that ``state.json`` and ``context.json`` expose a
``personal_tasks`` block projected from the shared task database.

Run:

    python3 scripts/test_state_projection.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
STATE_SRC = Path.home() / ".hermes" / "state"

STUB_CACHES = {
    "local-vault.json": {
        "current_season": {"status": "fresh", "text": "season"},
        "adaptive_pace": {"status": "fresh", "text": "pace"},
        "open_loops": {"status": "fresh", "active": [], "waiting_on": [], "needs_clarity": []},
        "recent_journal": None,
    },
    "kanban.json": {"status": "fresh", "active_tasks": []},
    "calendar.json": {"status": "fresh", "events": []},
    "gmail-attention.json": {"status": "fresh", "messages": []},
}

NOOP_STUB = "#!/usr/bin/env python3\nprint('stub adapter ok')\n"


class StateProjectionTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.home = Path(self._tmp.name)
        self.state_dir = self.home / ".hermes" / "state"
        self.adapters_dir = self.state_dir / "adapters"
        self.cache_dir = self.state_dir / "cache"
        self.adapters_dir.mkdir(parents=True, exist_ok=True)
        self.cache_dir.mkdir(parents=True, exist_ok=True)

        # Stub the pre-existing adapters so the projection runs without the
        # real vault/Kanban/Calendar/Gmail. Cache files are pre-written; the
        # stubs only need to exit 0 (build_state.py runs them, then re-reads).
        for name in ("local_vault", "kanban", "calendar", "gmail_attention"):
            (self.adapters_dir / f"{name}.py").write_text(NOOP_STUB)
        for fname, data in STUB_CACHES.items():
            (self.cache_dir / fname).write_text(json.dumps(data))

        # The real adapter is exercised (it builds personal-tasks.json itself).
        shutil.copy(
            STATE_SRC / "adapters" / "personal_tasks.py",
            self.adapters_dir / "personal_tasks.py",
        )

        # Seed the shared task database the adapter will read.
        self.db_path = self.home / "hermes-vault" / "00-Life" / "Tasks" / "tasks.sqlite"
        self.db_path.parent.mkdir(parents=True, exist_ok=True)

        self.env = dict(os.environ)
        self.env["HOME"] = str(self.home)
        self.env["TASKS_DB_PATH"] = str(self.db_path)

    def tearDown(self):
        self._tmp.cleanup()

    def _seed(self):
        import sys as _sys
        _sys.path.insert(0, str(STATE_SRC / "adapters"))
        import personal_tasks as pt
        conn = pt.open_db(self.db_path)
        pt.migrate(conn)
        pt.create_task(conn, "Ship Phase 1", status="next", area="hermes")
        pt.create_task(conn, "Pay rent", due_date=pt.today_local(), area="admin")
        conn.close()

    def _run(self, script, *args):
        return subprocess.run(
            [sys.executable, str(STATE_SRC / script), *args],
            capture_output=True,
            text=True,
            env=self.env,
        )

    def test_state_projection_includes_personal_tasks(self):
        self._seed()
        result = self._run("build_state.py")
        self.assertEqual(result.returncode, 0, result.stderr)

        state = json.loads((self.state_dir / "state.json").read_text())
        self.assertEqual(state["status"], "fresh")
        self.assertIn("personal_tasks", state)
        pt = state["personal_tasks"]
        self.assertEqual(pt["status"], "fresh")
        self.assertEqual(len(pt["pending"]), 2)
        self.assertEqual(len(pt["today"]), 1)
        titles = {t["title"] for t in pt["pending"]}
        self.assertIn("Ship Phase 1", titles)
        self.assertIn("Pay rent", titles)

        # Adapter run recorded.
        runs = {r["name"]: r for r in state["adapter_runs"]}
        self.assertIn("personal_tasks", runs)
        self.assertTrue(runs["personal_tasks"]["ok"])

    def test_context_projection_includes_personal_tasks(self):
        self._seed()
        r1 = self._run("build_state.py")
        self.assertEqual(r1.returncode, 0, r1.stderr)
        r2 = self._run("build_context.py")
        self.assertEqual(r2.returncode, 0, r2.stderr)

        context = json.loads((self.state_dir / "context.json").read_text())
        self.assertIn("personal_tasks", context)
        pt = context["personal_tasks"]
        self.assertEqual(pt["status"], "fresh")
        self.assertEqual(len(pt["pending"]), 2)
        self.assertEqual(len(pt["today"]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
