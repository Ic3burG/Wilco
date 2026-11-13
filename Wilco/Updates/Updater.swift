import Sparkle
import SwiftUI

/// Wraps Sparkle's standard updater.
///
/// Sparkle refuses to install an update it cannot verify, so the updater only
/// starts once `SUPublicEDKey` is present in Info.plist. Until release signing
/// is set up, "Check for Updates…" stays disabled instead of failing at launch.
@MainActor
@Observable
final class Updater {
    private let controller: SPUStandardUpdaterController?
    private(set) var canCheckForUpdates = false
    private var observation: NSKeyValueObservation?

    init() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        guard let key, !key.isEmpty else {
            controller = nil
            return
        }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        // Sparkle changes `canCheckForUpdates` on the main thread.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}

struct CheckForUpdatesButton: View {
    let updater: Updater

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
    }
}
