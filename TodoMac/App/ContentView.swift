import SwiftUI

struct ContentView: View {
    @ObservedObject var model: TodoViewModel

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
    @State private var isShowingDeleteConfirmation = false

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
            Button("Archive") { model.archive(task) }
            Button("Delete…", role: .destructive) {
                isShowingDeleteConfirmation = true
            }
        }
        .confirmationDialog(
            "Delete \"\(task.title)\"?",
            isPresented: $isShowingDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) {
                model.delete(task)
            }
        } message: {
            Text("This action cannot be undone.")
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
    @State private var isShowingDueDatePicker = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: model.editingTaskID == nil ? "plus.circle.fill" : "pencil.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.editingTaskID == nil ? "New Task" : "Edit Task")
                        .font(.title2.weight(.semibold))
                    Text(model.editingTaskID == nil ? "Capture what needs to get done." : "Update the task details below.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("Task")
                    TextField("What needs to be done?", text: $model.draftTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(.body)
                        .controlSize(.large)
                }

                VStack(alignment: .leading, spacing: 7) {
                    fieldLabel("Notes")
                    TextField("Add details or context…", text: $model.draftNotes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...5)
                }
            }
            .padding(16)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))

            VStack(spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        fieldLabel("Status")
                        Picker("Status", selection: $model.draftStatus) {
                            ForEach(TaskStatus.allCases, id: \.self) { status in
                                Text(status.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .tag(status)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        fieldLabel("Priority")
                        Picker("Priority", selection: $model.draftPriority) {
                            ForEach(TaskPriority.allCases, id: \.self) { priority in
                                Text(priority.rawValue.capitalized).tag(priority)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }
                }

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 7) {
                        fieldLabel("Area")
                        Picker("Area", selection: $model.draftArea) {
                            Text("None").tag(TaskArea?.none)
                            ForEach(TaskArea.allCases, id: \.self) { area in
                                Text(area.displayName).tag(TaskArea?.some(area))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        fieldLabel("Due Date")

                        Button {
                            isShowingDueDatePicker = true
                        } label: {
                            HStack(spacing: 10) {
                                Text(dueDateLabel)
                                    .lineLimit(1)
                                    .foregroundStyle(model.draftDueDate.isEmpty ? .secondary : .primary)

                                Spacer()

                                Image(systemName: "calendar")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 32)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(isShowingDueDatePicker ? Color.accentColor : Color.secondary.opacity(0.18), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $isShowingDueDatePicker, arrowEdge: .bottom) {
                            VStack(spacing: 12) {
                                HStack {
                                    Text("Choose a due date")
                                        .font(.headline)

                                    Spacer()

                                    Button {
                                        isShowingDueDatePicker = false
                                    } label: {
                                        Image(systemName: "xmark")
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Close")
                                }

                                DatePicker(
                                    "Due Date",
                                    selection: dueDate,
                                    displayedComponents: .date
                                )
                                .labelsHidden()
                                .datePickerStyle(.graphical)
                                .frame(width: 280)

                                Divider()

                                HStack {
                                    Spacer()
                                    Button("Cancel") {
                                        isShowingDueDatePicker = false
                                    }
                                }
                            }
                            .padding(16)
                        }
                    }
                }
            }
            .controlSize(.large)
            .padding(.top, 18)

            Divider()
                .padding(.vertical, 18)

            HStack {
                Text("Press ⌘↩ to save")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

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
        .padding(24)
        .frame(width: 520)
    }

    private func fieldLabel(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private var dueDate: Binding<Date> {
        Binding(
            get: {
                parsedDate(model.draftDueDate) ?? Date()
            },
            set: { newDate in
                model.draftDueDate = formattedDate(newDate)
                isShowingDueDatePicker = false
            }
        )
    }

    private var dueDateLabel: String {
        guard let date = parsedDate(model.draftDueDate) else {
            return "Pick a date"
        }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func parsedDate(_ value: String) -> Date? {
        dateFormatter.date(from: value)
    }

    private func formattedDate(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
