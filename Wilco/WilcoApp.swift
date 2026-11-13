import SwiftUI
import WilcoCore

@main
struct WilcoApp: App {
    @State private var look = LookAndFeel()
    @State private var model = AppModel()
    @State private var updater = Updater()

    var body: some Scene {
        Window("Wilco", id: "main") {
            MainWindowView()
                .environment(model)
                .environment(look)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.stopCapture()
                    model.saveNow()
                }
        }
        Window("Configurations", id: ConfigurationsWindow.windowID) {
            ConfigurationsWindow()
                .environment(model)
                .environment(look)
        }
        Window("Show Report", id: ShowReportCommand.windowID) {
            ShowReportWindow()
                .environment(model)
                .environment(look)
        }
        Settings {
            SettingsView()
                .environment(model)
                .environment(look)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updater)
            }
            CommandGroup(after: .sidebar) {
                ShowReportCommand()
                Divider()
                Picker("Appearance", selection: Binding(get: { look.theme }, set: { look.theme = $0 })) {
                    ForEach(AppTheme.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Divider()
                Button("Larger Text") { look.adjustFontSize(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Smaller Text") { look.adjustFontSize(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Default Text Size", action: look.resetFontSize)
                    .keyboardShortcut("0", modifiers: .command)
            }
            CommandGroup(replacing: .newItem) {
                Button("Add Channel", action: model.addChannel)
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Group", action: model.addGroup)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            ConfigurationCommands(model: model)
        }
    }
}
