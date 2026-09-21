import Foundation

// MARK: - Status

enum TaskStatus: String, CaseIterable, Codable {
    case inbox
    case next
    case inProgress = "in_progress"
    case waiting
    case completed

    var isCompleted: Bool { self == .completed }
}

// MARK: - Priority

enum TaskPriority: String, CaseIterable, Codable {
    case none
    case low
    case medium
    case high

    var sortOrder: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        case .none: return 3
        }
    }
}

// MARK: - Area

enum TaskArea: String, CaseIterable, Codable {
    case university
    case career
    case salinas
    case hermes
    case admin
    case personal
    case fitness
    case faith

    var displayName: String {
        switch self {
        case .university: return "University"
        case .career: return "Career"
        case .salinas: return "Salinas Digital"
        case .hermes: return "Hermes"
        case .admin: return "Admin"
        case .personal: return "Personal"
        case .fitness: return "Fitness"
        case .faith: return "Faith"
        }
    }
}

// MARK: - Task

struct Task: Identifiable, Equatable {
    let id: String
    var title: String
    var notes: String?
    var status: TaskStatus
    var priority: TaskPriority
    var area: TaskArea?
    var projectID: String?
    var dueDate: String?
    var scheduledDate: String?
    var estimatedMinutes: Int?
    var archived: Bool
    var completedAt: String?
    var createdAt: String
    var updatedAt: String
}

// MARK: - Project

struct Project: Identifiable, Equatable {
    let id: String
    var name: String
    var color: String?
    var archived: Bool
    var createdAt: String
    var updatedAt: String
}