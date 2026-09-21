import Foundation
import SwiftUI

// Navigation destinations for the sidebar.
enum NavigationSection: Hashable {
    case inbox
    case today
    case upcoming
    case overdue
    case area(TaskArea)
    case project(String)   // project id
    case completed
}

@MainActor
final class TodoViewModel: ObservableObject {
    @Published var tasks: [Task] = []
    @Published var projects: [Project] = []
    @Published var errorMessage: String?
    @Published var selection: NavigationSection? = .inbox

    // Editor state
    @Published var isEditing = false
    @Published var draftTitle: String = ""
    @Published var draftNotes: String = ""
    @Published var draftStatus: TaskStatus = .inbox
    @Published var draftPriority: TaskPriority = .none
    @Published var draftArea: TaskArea?
    @Published var draftProjectID: String?
    @Published var draftDueDate: String = ""
    @Published var draftScheduledDate: String = ""
    @Published var editingTaskID: String?

    private let repository: TaskRepository

    init(repository: TaskRepository? = nil) {
        do {
            self.repository = try repository ?? TaskRepository()
        } catch {
            // Fall back to a repository over an in-memory temp file so the UI
            // still boots when the vault path is unavailable.
            let fd = NSTemporaryDirectory() + "todomac-\(UUID().uuidString).sqlite"
            self.repository = (try? TaskRepository(path: fd))!
            self.errorMessage = error.localizedDescription
        }
        reload()
    }

    func reload() {
        do {
            tasks = try repository.listPending()
            projects = try repository.listProjects()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func tasks(for section: NavigationSection?) -> [Task] {
        guard let section else { return [] }
        do {
            switch section {
            case .inbox:
                return try repository.listInbox()
            case .today:
                return try repository.listToday()
            case .upcoming:
                return try repository.listUpcoming()
            case .overdue:
                return try repository.listOverdue()
            case .project(let id):
                return try repository.listByProject(id)
            case .area(let area):
                return try repository.listByArea(area)
            case .completed:
                return try repository.listRecentlyCompleted(limit: 200)
            }
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    // MARK: - Editor

    func beginNewTask() {
        draftTitle = ""
        draftNotes = ""
        draftStatus = .inbox
        draftPriority = .none
        draftArea = nil
        draftProjectID = nil
        draftDueDate = ""
        draftScheduledDate = ""
        editingTaskID = nil
        isEditing = true
    }

    func beginEdit(_ task: Task) {
        draftTitle = task.title
        draftNotes = task.notes ?? ""
        draftStatus = task.status
        draftPriority = task.priority
        draftArea = task.area
        draftProjectID = task.projectID
        draftDueDate = task.dueDate ?? ""
        draftScheduledDate = task.scheduledDate ?? ""
        editingTaskID = task.id
        isEditing = true
    }

    func saveDraft() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        do {
            let due = draftDueDate.isEmpty ? nil : draftDueDate
            let scheduled = draftScheduledDate.isEmpty ? nil : draftScheduledDate

            if let id = editingTaskID {
                _ = try repository.updateTask(
                    id: id,
                    title: title,
                    notes: draftNotes.isEmpty ? nil : draftNotes,
                    status: draftStatus,
                    priority: draftPriority,
                    area: .some(draftArea),
                    projectID: .some(draftProjectID),
                    dueDate: .some(due),
                    scheduledDate: .some(scheduled)
                )
            } else {
                _ = try repository.createTask(
                    title: title,
                    notes: draftNotes.isEmpty ? nil : draftNotes,
                    status: draftStatus,
                    priority: draftPriority,
                    area: draftArea,
                    projectID: draftProjectID,
                    dueDate: due,
                    scheduledDate: scheduled
                )
            }
            isEditing = false
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Mutations

    func complete(_ task: Task) {
        do {
            _ = try repository.completeTask(id: task.id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reopen(_ task: Task) {
        do {
            _ = try repository.reopenTask(id: task.id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func archive(_ task: Task) {
        do {
            _ = try repository.archiveTask(id: task.id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ task: Task) {
        do {
            try repository.deleteTask(id: task.id)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func addProject(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try repository.createProject(name: trimmed)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
