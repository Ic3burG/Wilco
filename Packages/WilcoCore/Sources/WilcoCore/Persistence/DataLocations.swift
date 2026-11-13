import Foundation

/// Where Wilco keeps its data: `~/Library/Application Support/Wilco`.
public enum DataLocations {
    public static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Wilco", directoryHint: .isDirectory)
    }

    public static var transcripts: URL { root.appending(path: "Transcripts", directoryHint: .isDirectory) }
    /// Saved show setups, one `‹UUID›.wilco` each.
    public static var configurations: URL { root.appending(path: "Configurations", directoryHint: .isDirectory) }
    /// WhisperKit download base; models live under `models/argmaxinc/whisperkit-coreml/<variant>`.
    public static var whisperModels: URL { root.appending(path: "WhisperModels", directoryHint: .isDirectory) }
}
