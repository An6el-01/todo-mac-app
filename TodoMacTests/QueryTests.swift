import XCTest
@testable import TodoMac

// Query semantics tests: today, pending, overdue, upcoming, project, area,
// recently completed, inbox.

final class QueryTests: XCTestCase {
    private var repo: TaskRepository!
    private var tmpDir: String!
    private let day = "2026-09-21"

    override func setUpWithError() throws {
        tmpDir = NSTemporaryDirectory() + "todomac-query-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        repo = try TaskRepository(path: tmpDir + "/tasks.sqlite")
    }

    override func tearDownWithError() throws {
        repo = nil
        try? FileManager.default.removeItem(atPath: tmpDir)
    }

    @discardableResult
    private func task(_ title: String) throws -> Task {
        try repo.createTask(title: title)
    }

    func testPendingExcludesCompletedAndArchived() throws {
        let active = try task("active")
        let done = try repo.createTask(title: "done", status: .completed)
        var archived = try task("archived")
        archived = try repo.archiveTask(id: archived.id)

        let pending = try repo.listPending().map(\.id)
        XCTAssertTrue(pending.contains(active.id))
        XCTAssertFalse(pending.contains(done.id))
        XCTAssertFalse(pending.contains(archived.id))
    }

    func testTodayMatchesScheduledAndUnscheduledDue() throws {
        let scheduledToday = try repo.createTask(title: "Sched today", scheduledDate: day)
        let dueToday = try repo.createTask(title: "Due today", dueDate: day)
        let future = try repo.createTask(title: "Future", scheduledDate: "2026-10-01")
        let past = try repo.createTask(title: "Past", scheduledDate: "2026-09-01")

        let today = try repo.listToday(day: day).map(\.id)
        XCTAssertTrue(today.contains(scheduledToday.id))
        XCTAssertTrue(today.contains(dueToday.id))
        XCTAssertFalse(today.contains(future.id))
        XCTAssertFalse(today.contains(past.id))
    }

    func testOverdue() throws {
        let overdueSched = try repo.createTask(title: "Overdue sched", scheduledDate: "2026-09-20")
        let overdueDue = try repo.createTask(title: "Overdue due", dueDate: "2026-09-19")
        let today = try repo.createTask(title: "Today", scheduledDate: "2026-09-21")
        let future = try repo.createTask(title: "Future", scheduledDate: "2026-10-01")

        let overdue = try repo.listOverdue(day: day).map(\.id)
        XCTAssertTrue(overdue.contains(overdueSched.id))
        XCTAssertTrue(overdue.contains(overdueDue.id))
        XCTAssertFalse(overdue.contains(today.id))
        XCTAssertFalse(overdue.contains(future.id))
    }

    func testUpcoming() throws {
        let future = try repo.createTask(title: "Future", scheduledDate: "2026-10-01")
        let futureDue = try repo.createTask(title: "Future due", dueDate: "2026-12-01")
        let past = try repo.createTask(title: "Past", scheduledDate: "2026-09-01")

        let upcoming = try repo.listUpcoming(day: day).map(\.id)
        XCTAssertTrue(upcoming.contains(future.id))
        XCTAssertTrue(upcoming.contains(futureDue.id))
        XCTAssertFalse(upcoming.contains(past.id))
    }

    func testListByProject() throws {
        let project = try repo.createProject(name: "Thesis")
        let inProject = try repo.createTask(title: "In project", projectID: project.id)
        let out = try repo.createTask(title: "Not in project")

        let ids = try repo.listByProject(project.id).map(\.id)
        XCTAssertTrue(ids.contains(inProject.id))
        XCTAssertFalse(ids.contains(out.id))
    }

    func testListByArea() throws {
        let university = try repo.createTask(title: "University", area: .university)
        let career = try repo.createTask(title: "Career", area: .career)

        let ids = try repo.listByArea(.university).map(\.id)
        XCTAssertTrue(ids.contains(university.id))
        XCTAssertFalse(ids.contains(career.id))
    }

    func testListInbox() throws {
        let inbox = try repo.createTask(title: "In inbox", status: .inbox)
        let next = try repo.createTask(title: "Next", status: .next)

        let ids = try repo.listInbox().map(\.id)
        XCTAssertTrue(ids.contains(inbox.id))
        XCTAssertFalse(ids.contains(next.id))
    }

    func testRecentlyCompletedOrdering() throws {
        let a = try repo.createTask(title: "A", status: .completed)
        let b = try repo.createTask(title: "B", status: .completed)
        _ = try repo.completeTask(id: a.id, at: "2026-09-20T10:00:00Z")
        _ = try repo.completeTask(id: b.id, at: "2026-09-21T10:00:00Z")

        let recent = try repo.listRecentlyCompleted(limit: 10)
        XCTAssertEqual(recent.first?.id, b.id)
        XCTAssertEqual(recent[1].id, a.id)
    }
}