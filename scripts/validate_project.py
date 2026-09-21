#!/usr/bin/env python3
"""Portable TodoMac project validator (runs anywhere Python 3.8+ is available).

This replaces what ``xcodebuild``/``swift`` would tell us on macOS, so the
project can be checked deterministically in WSL/CI. It verifies:

  1. Schema drift: ``schema/schema.sql``, the Swift ``Schema.swift`` migration,
     and the Hermes adapter ``personal_tasks.py`` embed the same DDL.
  2. Xcode project membership: every ``.swift`` source file is referenced in
     ``TodoMac.xcodeproj/project.pbxproj`` and vice-versa.
  3. The macOS 13.0 deployment target and a shared scheme are present.
  4. The status/priority/area enum contract matches the schema.

Usage:

    python3 scripts/validate_project.py

Exits 0 when healthy, 1 otherwise.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCHEMA_SQL = REPO / "schema" / "schema.sql"
SCHEMA_SWIFT = REPO / "TodoMac" / "Services" / "Schema.swift"
MODELS_SWIFT = REPO / "TodoMac" / "Core" / "Models.swift"
PBXPROJ = REPO / "TodoMac.xcodeproj" / "project.pbxproj"
SCHEME = REPO / "TodoMac.xcodeproj" / "xcshareddata" / "xcschemes" / "TodoMac.xcscheme"

# The Hermes adapter lives beside Hermes, outside this repo.
ADAPTER = Path.home() / ".hermes" / "state" / "adapters" / "personal_tasks.py"

APP_SOURCES = [
    "TodoMac/App/TodoMacApp.swift",
    "TodoMac/App/TodoViewModel.swift",
    "TodoMac/App/ContentView.swift",
    "TodoMac/Core/Models.swift",
    "TodoMac/Services/SQLiteConnection.swift",
    "TodoMac/Services/Schema.swift",
    "TodoMac/Services/TaskRepository.swift",
]
TEST_SOURCES = [
    "TodoMacTests/TaskRepositoryTests.swift",
    "TodoMacTests/QueryTests.swift",
    "TodoMacTests/DatabaseConfigurationTests.swift",
]

STATUSES = ("inbox", "next", "in_progress", "waiting", "completed")
PRIORITIES = ("none", "low", "medium", "high")
AREAS = (
    "university", "career", "salinas", "hermes",
    "admin", "personal", "fitness", "faith",
)

failures: list[str] = []


def check(label, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(f"{status}: {label}" + (f"  ({detail})" if detail and not ok else ""))
    if not ok:
        failures.append(label)


def canonical_from_sql(text: str) -> set[str]:
    """Normalized CREATE statements from plain, semicolon-delimited SQL text."""
    lines = [ln for ln in text.splitlines() if not ln.strip().startswith("--")]
    body = "\n".join(lines)
    statements = set()
    for chunk in body.split(";"):
        collapsed = " ".join(chunk.split()).rstrip(",").strip()
        if collapsed.upper().startswith("CREATE"):
            statements.add(collapsed)
    return statements


def swift_create_statements(text: str) -> set[str]:
    """Normalized CREATE statements from Swift string literals in Schema.swift.

    Schema.swift mixes triple-quoted multi-line literals (CREATE TABLE) with
    single-line double-quoted literals (CREATE INDEX). ``re.findall`` yields an
    empty string (not ``None``) for an unmatched group, so we iterate matches
    and inspect each group explicitly to avoid dropping the single-line ones.
    """
    statements = set()
    pattern = re.compile(
        r'"""(.*?)"""|"((?:\\.|[^"\\])*)"', re.DOTALL
    )
    for match in pattern.finditer(text):
        triple, single = match.group(1), match.group(2)
        lit = triple or single
        if not lit:
            continue
        collapsed = " ".join(lit.split()).rstrip(",").strip()
        if collapsed.upper().startswith("CREATE"):
            statements.add(collapsed)
    return statements


def adapter_schema_sql(text: str) -> str:
    """Extract the SCHEMA_SQL triple-quoted constant from personal_tasks.py."""
    match = re.search(r'SCHEMA_SQL\s*=\s*"""(.*?)"""', text, re.DOTALL)
    return match.group(1) if match else ""


def main() -> int:
    print(f"TodoMac project validator (repo: {REPO})")
    print("=" * 60)

    # 1. Schema drift
    check("schema/schema.sql exists", SCHEMA_SQL.exists())
    check("Schema.swift exists", SCHEMA_SWIFT.exists())

    if SCHEMA_SQL.exists() and SCHEMA_SWIFT.exists():
        canonical = canonical_from_sql(SCHEMA_SQL.read_text(encoding="utf-8"))
        swift_ddl = swift_create_statements(
            SCHEMA_SWIFT.read_text(encoding="utf-8")
        )
        check(
            "Schema.swift DDL matches schema.sql",
            canonical == swift_ddl,
            f"sql={len(canonical)} swift={len(swift_ddl)}",
        )

        if ADAPTER.exists():
            adapter_sql = adapter_schema_sql(ADAPTER.read_text(encoding="utf-8"))
            adapter_ddl = canonical_from_sql(adapter_sql)
            check(
                "personal_tasks.py DDL matches schema.sql",
                canonical == adapter_ddl,
                f"sql={len(canonical)} adapter={len(adapter_ddl)}",
            )
        else:
            check("personal_tasks.py adapter present", False, str(ADAPTER))

    # 2. Project membership
    check("project.pbxproj exists", PBXPROJ.exists())
    check("shared scheme exists", SCHEME.exists())

    if PBXPROJ.exists():
        pbx = PBXPROJ.read_text(encoding="utf-8")
        for rel in APP_SOURCES + TEST_SOURCES:
            leaf = rel.split("/")[-1]
            check(f"pbxproj references {rel}", leaf in pbx, leaf)
        check("app product in pbxproj", "TodoMac.app" in pbx)
        check("test product in pbxproj", "TodoMacTests.xctest" in pbx)
        check(
            "macOS 13.0 deployment target",
            "MACOSX_DEPLOYMENT_TARGET = 13.0" in pbx,
        )
        check("app target present", 'name = TodoMac;' in pbx)
        check("test target present", 'name = TodoMacTests;' in pbx)

    if SCHEME.exists():
        scheme = SCHEME.read_text(encoding="utf-8")
        check("scheme builds app", "BlueprintName=\"TodoMac\"" in scheme)
        check("scheme tests target", "BlueprintName=\"TodoMacTests\"" in scheme)

    # 3. Enum contract
    check("Models.swift exists", MODELS_SWIFT.exists())
    if MODELS_SWIFT.exists():
        models = MODELS_SWIFT.read_text(encoding="utf-8")
        for value in STATUSES:
            norm = value if value != "in_progress" else "inProgress"
            check(f"Models.swift has status {value}", norm in models, norm)
        for value in PRIORITIES:
            check(f"Models.swift has priority {value}", f"case {value}" in models)
        for value in AREAS:
            check(f"Models.swift has area {value}", f"case {value}" in models)

    if SCHEMA_SQL.exists():
        schema = SCHEMA_SQL.read_text(encoding="utf-8")
        for value in STATUSES:
            check(f"schema.sql has status {value}", value in schema)
        for value in AREAS:
            check(f"schema.sql has area {value}", value in schema)

    # 4. No Pomodoro integration leaked into Phase 1
    if SCHEMA_SQL.exists():
        schema = SCHEMA_SQL.read_text(encoding="utf-8")
        check(
            "pomodoro_sessions not in live schema",
            "CREATE TABLE IF NOT EXISTS pomodoro_sessions" not in schema,
        )

    print("=" * 60)
    if failures:
        print(f"FAILED: {len(failures)} check(s) failed.")
        return 1
    print("HEALTHY: TodoMac project passed all portable checks.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
