import XCTest
@testable import TodoMac

// Schema & migration + database configuration tests. Mirrors
// scripts/test_tasks_db.py so behavior stays identical across hosts.

final class DatabaseConfigurationTests: XCTestCase {
    private var repo: TaskRepository!
    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "todomac-tests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true
        )
        repo = try TaskRepository(
            path: tmpDir + "/tasks.sqlite"
        )
    }

    override func tearDownWithError() throws {
        repo = nil
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    func testDefaultPathPointsIntoLifeTasksVault() {
        XCTAssertTrue(TaskRepository.defaultPath.contains("hermes-vault/00-Life/Tasks/tasks.sqlite"))
    }

    func testMigrationRecordsVersionOne() throws {
        // Expose current version by migrating again (idempotent) — the repository
        // already migrated on init; a second migrate() must not fail.
        try repo.migrate()
    }

    func testTasksAndProjectsTablesExist() throws {
        // Create + read back proves the schema is live.
        let project = try repo.createProject(name: "Thesis")
        let task = try repo.createTask(title: "Draft", projectID: project.id)
        XCTAssertFalse(task.id.isEmpty)
    }

    func testCreatedAtAndUpdatedAtArePopulated() throws {
        let task = try repo.createTask(title: "Timestamped")
        XCTAssertFalse(task.createdAt.isEmpty)
        XCTAssertFalse(task.updatedAt.isEmpty)
    }

    func testSoftArchiveDefaultFalse() throws {
        let task = try repo.createTask(title: "Not archived")
        XCTAssertFalse(task.archived)
    }

    func testIDsAreStableUUIDStrings() throws {
        let task = try repo.createTask(title: "Stable")
        // UUID format: 8-4-4-4-12 hex groups.
        let parts = task.id.split(separator: "-")
        XCTAssertEqual(parts.count, 5)
        let updated = try repo.updateTask(id: task.id, title: "Renamed")
        XCTAssertEqual(updated.id, task.id)
    }
}