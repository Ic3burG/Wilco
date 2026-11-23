import Foundation

/// Where Wilco keeps its data: `~/Library/Application Support/Wilco`.
public enum DataLocations {
    public static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Wilco", directoryHint: .isDirectory)
    }

    public static var transcripts: URL { root.appending(path: "Transcripts", directoryHint: .isDirectory) }
    /// Saved show setups, one `‹UUID›.wilco` each.
    public static var configurations: URL { root.appending(path: "Configurations", directoryHint: .isDirectory) }
    /// Named marker sets for the report, one `‹UUID›.json` each.
    public static var markerPresets: URL { root.appending(path: "Presets/Markers", directoryHint: .isDirectory) }
    /// WhisperKit download base; models live under `models/argmaxinc/whisperkit-coreml/<variant>`.
    public static var whisperModels: URL { root.appending(path: "WhisperModels", directoryHint: .isDirectory) }
    /// Parakeet models, one folder per model repository.
    public static var parakeetModels: URL { root.appending(path: "ParakeetModels", directoryHint: .isDirectory) }
    /// The speaker-embedding model used to tell voices apart.
    public static var voiceModels: URL { root.appending(path: "VoiceModels", directoryHint: .isDirectory) }
}
