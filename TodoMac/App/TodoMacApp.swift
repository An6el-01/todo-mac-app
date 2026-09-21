import SwiftUI

@main
struct TodoMacApp: App {
    @StateObject private var model = TodoViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task") {
                    model.beginNewTask()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
    }
}