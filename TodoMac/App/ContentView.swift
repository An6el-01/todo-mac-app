import SwiftUI

struct ContentView: View {
    @ObservedObject var model: TodoViewModel
    @State private var newProjectName: String = ""
    @State private var isShowingNewProjectAlert = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            taskList
        }
        .sheet(isPresented: $model.isEditing) {
            TaskEditorView(model: model)
        }
        .alert("New Project", isPresented: $isShowingNewProjectAlert) {
            TextField("Project name", text: $newProjectName)
            Button("Add") {
                model.addProject(name: newProjectName)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a project to group related tasks.")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.beginNewTask()
                } label: {
                    Label("New Task", systemImage: "plus")
                }
            }
        }
    }

    private var sidebar: some View {
        List(selection: $model.selection) {
            Section("Lists") {
                sidebarLabel("Inbox", systemImage: "tray", value: .inbox)
                sidebarLabel("Today", systemImage: "sun.max", value: .today)
                sidebarLabel("Upcoming", systemImage: "calendar", value: .upcoming)
                sidebarLabel("Overdue", systemImage: "clock.badge.exclamationmark", value: .overdue)
            }

            Section("Areas") {
                ForEach(TaskArea.allCases, id: \.self) { area in
                    sidebarLabel(area.displayName,
                                 systemImage: "circle.fill",
                                 value: .area(area))
                }
            }

            Section {
                ForEach(model.projects) { project in
                    sidebarLabel(project.name,
                                 systemImage: "folder",
                                 value: .project(project.id))
                }
            } header: {
                HStack {
                    Text("Projects")
                    Spacer()
                    Button {
                        newProjectName = ""
                        isShowingNewProjectAlert = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("New Project")
                }
            }

            Section {
                sidebarLabel("Completed", systemImage: "checkmark.circle", value: .completed)
            }
        }
    }

    private func sidebarLabel(_ title: String, systemImage: String, value: NavigationSection) -> some View {
        Label(title, systemImage: systemImage)
            .tag(value)
    }

    private var taskList: some View {
        TaskListView(model: model, tasks: model.tasks(for: model.selection))
    }
}

struct TaskListView: View {
    @ObservedObject var model: TodoViewModel
    let tasks: [Task]

    var body: some View {
        Group {
            if tasks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("Nothing here")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(tasks) { task in
                        TaskRow(model: model, task: task)
                    }
                }
            }
        }
        .navigationTitle(title)
    }

    private var title: String {
        guard let section = model.selection else { return "Todos" }
        switch section {
        case .inbox: return "Inbox"
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .overdue: return "Overdue"
        case .area(let area): return area.displayName
        case .project: return "Project"
        case .completed: return "Completed"
        }
    }
}

struct TaskRow: View {
    @ObservedObject var model: TodoViewModel
    let task: Task

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                if task.status == .completed {
                    model.reopen(task)
                } else {
                    model.complete(task)
                }
            } label: {
                Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(task.status == .completed ? .green : .secondary)
            }
            .buttonStyle(.borderless)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .strikethrough(task.status == .completed)
                HStack(spacing: 8) {
                    if let area = task.area {
                        Text(area.rawValue).font(.caption).foregroundStyle(.secondary)
                    }
                    if task.priority != .none {
                        Text(task.priority.rawValue)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(priorityColor.opacity(0.18))
                            .clipShape(Capsule())
                    }
                    if let due = task.dueDate {
                        Text(due).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            model.beginEdit(task)
        }
        .contextMenu {
            Button("Edit…") { model.beginEdit(task) }
            if task.status == .completed {
                Button("Reopen") { model.reopen(task) }
            } else {
                Button("Complete") { model.complete(task) }
            }
            Divider()
            Button("Archive", role: .destructive) { model.archive(task) }
        }
    }

    private var priorityColor: Color {
        switch task.priority {
        case .high: return .red
        case .medium: return .orange
        case .low: return .blue
        case .none: return .secondary
        }
    }
}

struct TaskEditorView: View {
    @ObservedObject var model: TodoViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.editingTaskID == nil ? "New Task" : "Edit Task")
                .font(.headline)

            TextField("Title", text: $model.draftTitle)
                .textFieldStyle(.roundedBorder)
                .font(.title3)

            TextField("Notes", text: $model.draftNotes, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            HStack(spacing: 16) {
                Picker("Status", selection: $model.draftStatus) {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        Text(status.rawValue.replacingOccurrences(of: "_", with: " ")).tag(status)
                    }
                }

                Picker("Priority", selection: $model.draftPriority) {
                    ForEach(TaskPriority.allCases, id: \.self) { priority in
                        Text(priority.rawValue).tag(priority)
                    }
                }
            }

            HStack(spacing: 16) {
                Picker("Area", selection: $model.draftArea) {
                    Text("None").tag(TaskArea?.none)
                    ForEach(TaskArea.allCases, id: \.self) { area in
                        Text(area.displayName).tag(TaskArea?.some(area))
                    }
                }

                Picker("Project", selection: $model.draftProjectID) {
                    Text("None").tag(String?.none)
                    ForEach(model.projects) { project in
                        Text(project.name).tag(String?.some(project.id))
                    }
                }
            }

            HStack(spacing: 16) {
                TextField("Scheduled (YYYY-MM-DD)", text: $model.draftScheduledDate)
                    .textFieldStyle(.roundedBorder)
                TextField("Due (YYYY-MM-DD)", text: $model.draftDueDate)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveDraft()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}