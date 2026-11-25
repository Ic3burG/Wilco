import Foundation
import Observation
import WilcoCore
import WilcoTranscription

/// Which speech models the current show's channels can use right now, for
/// the Speech tick in the Settings sidebar. Checked off the main thread,
/// the same way Speech Models checks them.
@MainActor @Observable
final class SetupStatus {
    private var installed: Set<String> = []

    func isInstalled(_ engine: SpeechEngine, _ locale: String) -> Bool {
        installed.contains(Self.key(engine, locale))
    }

    func refresh(for show: ShowDocument, installer: ModelInstaller) async {
        let whisper = WhisperModel(rawValue: show.whisperModel) ?? .base
        let whisperStore = installer.whisperStore
        let parakeetStore = installer.parakeetStore
        let (whisperOnDisk, parakeetOnDisk) = await Task.detached {
            (whisperStore.sizeOnDisk(of: whisper) != nil, parakeetStore.isInstalled())
        }.value

        var found = Set<String>()
        var seen = Set<String>()
        for channel in show.channels {
            let key = Self.key(channel.engine, channel.localeIdentifier)
            guard seen.insert(key).inserted else { continue }
            let ready: Bool
            switch channel.engine {
            case .whisper: ready = whisperOnDisk
            case .parakeet: ready = parakeetOnDisk
            case .longForm, .dictation:
                // An empty identifier means the Mac's own language.
                let locale = channel.localeIdentifier.isEmpty ? Locale.current.identifier : channel.localeIdentifier
                ready = await SpeechAssets.status(engine: channel.engine, localeIdentifier: locale) == .installed
            }
            if ready { found.insert(key) }
        }
        installed = found
    }

    private static func key(_ engine: SpeechEngine, _ locale: String) -> String {
        "\(engine.rawValue)|\(locale)"
    }
}
