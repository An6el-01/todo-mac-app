import XCTest
@testable import TodoMac

// View-model level tests for the project create + assign workflow. These
// cover the UI wiring gap that motivated the fix: the repository always had
// project CRUD, but nothing surfaced `addProject` and the task editor's
// project picker was fed by `model.projects`.

@MainActor
final class TodoViewModelTests: XCTestCase {
    private var repo: TaskRepository!
    private var tmpDir: String!
    private var model: TodoViewModel!

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "todomac-vm-\\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true
        )
        repo = try TaskRepository(path: tmpDir + "/tasks.sqlite")
        model = TodoViewModel(repository: repo)
    }

    override func tearDownWithError() throws {
        model = nil
        repo = nil
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    func testAddProjectRejectsBlankName() {
        model.addProject(name: "   ")
        XCTAssertTrue(model.projects.isEmpty)
    }

    func testSaveDraftAssignsProjectToNewTask() throws {
        model.addProject(name: "Thesis")
        let projectID = try XCTUnwrap(model.projects.first?.id)

        model.beginNewTask()
        model.draftTitle = "Write chapter 1"
        model.draftProjectID = projectID
        model.saveDraft()

        let tasks = try repo.listByProject(projectID)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.title, "Write chapter 1")
        XCTAssertEqual(tasks.first?.projectID, projectID)
    }

    func testSaveDraftReassignsProjectOnEdit() throws {
        let projectA = try repo.createProject(name: "A")
        let projectB = try repo.createProject(name: "B")
        model.reload()
        let task = try repo.createTask(title: "Move me", projectID: projectA.id)

        model.beginEdit(task)
        model.draftProjectID = projectB.id
        model.saveDraft()

        let updated = try repo.taskByID(task.id)
        XCTAssertEqual(updated.projectID, projectB.id)
    }

    func testDeleteRemovesTaskAndRefreshesViewModel() throws {
        let task = try repo.createTask(title: "Delete me")
        model.reload()

        model.delete(task)

        XCTAssertFalse(model.tasks.contains(where: { $0.id == task.id }))
        XCTAssertThrowsError(try repo.taskByID(task.id))
    }
}
