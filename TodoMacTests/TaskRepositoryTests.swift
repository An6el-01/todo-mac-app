import XCTest
@testable import TodoMac

// Task & project CRUD + lifecycle tests (completion, reopen, archive).

final class TaskRepositoryTests: XCTestCase {
    private var repo: TaskRepository!
    private var tmpDir: String!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "todomac-crud-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        repo = try TaskRepository(path: tmpDir + "/tasks.sqlite")
    }

    override func tearDownWithError() throws {
        repo = nil
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    func testCreateTaskDefaults() throws {
        let task = try repo.createTask(title: "Write thesis")
        XCTAssertEqual(task.title, "Write thesis")
        XCTAssertEqual(task.status, .inbox)
        XCTAssertEqual(task.priority, .none)
        XCTAssertNil(task.area)
        XCTAssertFalse(task.archived)
        XCTAssertNil(task.completedAt)
    }

    func testCreateTaskRejectsEmptyTitle() {
        XCTAssertThrowsError(try repo.createTask(title: "   "))
    }

    func testCreateTaskWithAllFields() throws {
        let project = try repo.createProject(name: "Thesis")
        let task = try repo.createTask(
            title: "Draft chapter 1",
            notes: "intro + lit review",
            status: .next,
            priority: .high,
            area: .university,
            projectID: project.id,
            dueDate: "2026-10-01",
            scheduledDate: "2026-09-25",
            estimatedMinutes: 90
        )
        XCTAssertEqual(task.status, .next)
        XCTAssertEqual(task.priority, .high)
        XCTAssertEqual(task.area, .university)
        XCTAssertEqual(task.projectID, project.id)
        XCTAssertEqual(task.dueDate, "2026-10-01")
        XCTAssertEqual(task.scheduledDate, "2026-09-25")
        XCTAssertEqual(task.estimatedMinutes, 90)
    }

    func testTaskProjectForeignKeyRejectsMissing() {
        XCTAssertThrowsError(try repo.createTask(title: "Orphan", projectID: "nope"))
    }

    func testUpdateTaskPreservesUnspecifiedFields() throws {
        let task = try repo.createTask(title: "Before", area: .career)
        let updated = try repo.updateTask(id: task.id, title: "After", priority: .medium)
        XCTAssertEqual(updated.title, "After")
        XCTAssertEqual(updated.priority, .medium)
        XCTAssertEqual(updated.area, .career)
        XCTAssertEqual(updated.createdAt, task.createdAt)
    }

    func testGetTaskByIDRoundtrip() throws {
        let created = try repo.createTask(title: "Roundtrip")
        let fetched = try repo.taskByID(created.id)
        XCTAssertEqual(fetched, created)
    }

    func testGetMissingTaskThrows() {
        XCTAssertThrowsError(try repo.taskByID("does-not-exist"))
    }

    func testCompleteTaskSetsStatusAndTimestamp() throws {
        let task = try repo.createTask(title: "Complete me", status: .next)
        let done = try repo.completeTask(id: task.id, at: "2026-09-21T12:00:00Z")
        XCTAssertEqual(done.status, .completed)
        XCTAssertEqual(done.completedAt, "2026-09-21T12:00:00Z")
    }

    func testReopenTaskClearsCompletedAt() throws {
        var task = try repo.createTask(title: "Reopen", status: .completed)
        task = try repo.reopenTask(id: task.id)
        XCTAssertEqual(task.status, .next)
        XCTAssertNil(task.completedAt)
    }

    func testArchiveAndRestore() throws {
        var task = try repo.createTask(title: "Archive me")
        task = try repo.archiveTask(id: task.id)
        XCTAssertTrue(task.archived)
        task = try repo.restoreTask(id: task.id)
        XCTAssertFalse(task.archived)
    }

    func testDeleteTaskPermanentlyRemovesTask() throws {
        let task = try repo.createTask(title: "Delete me")

        try repo.deleteTask(id: task.id)

        XCTAssertThrowsError(try repo.taskByID(task.id))
    }

    func testDeleteMissingTaskThrows() {
        XCTAssertThrowsError(try repo.deleteTask(id: "does-not-exist"))
    }

    func testProjectCreationAndListing() throws {
        _ = try repo.createProject(name: "Thesis")
        _ = try repo.createProject(name: "Freelance")
        let names = try repo.listProjects().map(\.name)
        XCTAssertEqual(names, ["Freelance", "Thesis"]) // NOCASE sort
    }

    func testProjectIDsAreUnique() throws {
        let a = try repo.createProject(name: "A")
        let b = try repo.createProject(name: "B")
        XCTAssertNotEqual(a.id, b.id)
    }
}
