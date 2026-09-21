# TodoMac

A compact, dependency-free native SwiftUI task manager for macOS 13+, inspired
by Things 3. It stores tasks in a local SQLite database that is also read and
written by Angel's Hermes personal-productivity state layer.

## Architecture

TodoMac follows the same conventions as the sibling `pomodoro-mac-app`:

- Xcode project (`TodoMac.xcodeproj`) with an app target and an `XCTest` target
- SwiftUI + Foundation/AppKit only, macOS 13.0 deployment target
- No third-party packages; the only non-Foundation import is the system
  `SQLite3` clang module that ships with macOS
- TDD: the `TodoMacTests` suite drives the repository, schema, and query
  semantics

### Layers

| Layer | Location | Responsibility |
| ----- | -------- | -------------- |
| Models | `TodoMac/Core/Models.swift` | `Task`, `Project`, `TaskStatus`, `TaskPriority`, `TaskArea` |
| Schema | `TodoMac/Services/Schema.swift` | Ordered migrations mirroring `schema/schema.sql` |
| SQLite wrapper | `TodoMac/Services/SQLiteConnection.swift` | Dependency-free `SQLite3` C-API wrapper, WAL + foreign keys, short transactions |
| Repository | `TodoMac/Services/TaskRepository.swift` | Task/project CRUD + query operations |
| UI | `TodoMac/App/*.swift` | Sidebar (Inbox, Today, Upcoming, Overdue, Areas, Projects, Completed), task list/editor |

### Shared single source of truth

`schema/schema.sql` is the canonical schema. Three consumers embed/derive the
exact same DDL so they can never silently drift:

1. The native app — `TodoMac/Services/Schema.swift`
2. The Python reference repository + CLI — `scripts/tasks_db.py`
3. The Hermes adapter — `~/.hermes/state/adapters/personal_tasks.py`

`scripts/validate_project.py` asserts these have not drifted, checks project
membership, and verifies the schema contract.

## Database

Authoritative path on Angel's machine:

```
~/hermes-vault/00-Life/Tasks/tasks.sqlite
```

The repository injects the path (default `TaskRepository.defaultPath`), and the
Python reference + adapter accept `--db` / `TASKS_DB_PATH`, so tests never touch
the real vault. On open, the connection enables `PRAGMA foreign_keys = ON`,
`journal_mode = WAL`, and `synchronous = NORMAL`.

### Schema

- `schema_migrations(version, applied_at)` — ordered, short-transaction migrations
- `projects(id, name, color, created_at, updated_at, archived)` — soft archive
- `tasks(id, title, notes, status, priority, area, project_id, due_date, scheduled_date, estimated_minutes, archived, completed_at, created_at, updated_at)`

Conventions:

- IDs are stable UUID strings generated client-side; never regenerated
- `created_at` / `updated_at` / `completed_at` are UTC ISO-8601 timestamps
- `due_date` / `scheduled_date` are `YYYY-MM-DD` date-only strings
- `archived = 1` is a soft delete; V1 never hard-deletes a row
- Enums are `CHECK`-constrained (see below)

V1 statuses: `inbox`, `next`, `in_progress`, `waiting`, `completed`.
V1 priorities: `none`, `low`, `medium`, `high`.
V1 areas: `university`, `career`, `salinas`, `hermes`, `admin`, `personal`, `fitness`, `faith`.

A future migration will add a `pomodoro_sessions` table (see `schema/schema.sql`)
to link focus sessions to tasks; no Pomodoro integration ships in Phase 1.

## Build and test

```sh
# macOS (native)
xcodebuild test -project TodoMac.xcodeproj -scheme TodoMac -destination 'platform=macOS'
```

The XCTest suite covers schema/migration idempotency, DB configuration (WAL,
foreign keys, default path), CRUD, today/pending/overdue/upcoming/project/area/
recently-completed queries, completion/reopen/archive, and UUID stability.

Portable checks (works in WSL/CI without `xcodebuild`):

```sh
python3 scripts/validate_project.py
python3 scripts/test_tasks_db.py
```

## Hermes adapter

`~/.hermes/state/adapters/personal_tasks.py` reads/writes the same SQLite
database. It exposes conceptual operations with JSON output for reads and
explicit mutation commands:

```
python3 personal_tasks.py list_today
python3 personal_tasks.py list_pending
python3 personal_tasks.py list_overdue
python3 personal_tasks.py list_upcoming
python3 personal_tasks.py get_task --id <uuid>
python3 personal_tasks.py list_by_project --id <project-uuid>
python3 personal_tasks.py list_by_area --id university
python3 personal_tasks.py list_recently_completed --limit 20
python3 personal_tasks.py create_task --title "..." [--status next] [--priority high] [--area hermes]
python3 personal_tasks.py update_task --id <uuid> --status in_progress
python3 personal_tasks.py complete_task --id <uuid>
```

Run with no subcommand (the pipeline form) to write the cache:

```
python3 personal_tasks.py            # -> ~/.hermes/state/cache/personal-tasks.json
```

Set `TASKS_DB_PATH` to point at a different database (tests, alternate vaults).

The adapter is registered in the Hermes state pipeline via
`build_state.py` (adapter + cache source), `build_context.py` (executive context
projection), and `health_check.py` (required adapter). It produces a
`personal_tasks` block in `state.json` / `context.json` with `today`, `pending`,
`overdue`, `upcoming`, `recently_completed`, and `projects`/`areas` groupings.

## Limitations

- Native compilation and XCTest must run on macOS; `xcodebuild`/`swift` are not
  available in WSL (exit 127). The portable Python suite validates schema,
  migration, CRUD, and query semantics deterministically off-macOS.
- Phase 1 deliberately does not integrate Pomodoro focus sessions (future
  `pomodoro_sessions` migration path only).
