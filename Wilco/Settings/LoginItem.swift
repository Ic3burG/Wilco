import Observation
import ServiceManagement

/// Settings › General › Open Wilco at login. The system holds the setting,
/// so it is read back each time instead of being kept in Wilco's
/// preferences, and stays right if it is changed in System Settings.
@MainActor
@Observable
final class LoginItem {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var problem: String?

    /// On once asked for, including while macOS waits for approval.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    func set(_ on: Bool) {
        problem = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            problem = "Could not \(on ? "add Wilco to" : "remove Wilco from") Login Items: \(error.localizedDescription)"
        }
        refresh()
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
