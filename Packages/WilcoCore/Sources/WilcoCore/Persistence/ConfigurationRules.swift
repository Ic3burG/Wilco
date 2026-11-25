import Foundation

/// Decisions about configurations that don't touch the disk or the UI.
public enum ConfigurationRules {
    /// How the working copy relates to the loaded configuration.
    public enum Status: Equatable, Sendable {
        case saved
        case edited
        /// No configuration file backs the working copy (it was deleted).
        case notSaved
    }

    public enum LoadDecision: Equatable, Sendable {
        case refuseWhileCapturing
        case alreadyLoaded
        case askToSaveFirst
        case load
    }

    /// Edited means "differs from the saved file", so undoing a change by
    /// hand clears it.
    public static func status(working: ShowDocument, saved: ShowDocument?) -> Status {
        guard let saved else { return .notSaved }
        return working == saved ? .saved : .edited
    }

    /// Capture comes first: a live show is never switched. Unsaved edits
    /// (including a working copy with no file) ask before they're replaced.
    public static func loadDecision(target: UUID, loaded: UUID?, status: Status, isCapturing: Bool) -> LoadDecision {
        if isCapturing { return .refuseWhileCapturing }
        if target == loaded { return .alreadyLoaded }
        if status != .saved { return .askToSaveFirst }
        return .load
    }

    public enum QuitDecision: Equatable, Sendable {
        case quit
        /// Ask Save / Don't Save / Cancel. `needsName` when no file backs
        /// the working copy, so saving means Save As New.
        case askToSave(needsName: Bool)
    }

    /// Quitting never loses the working copy (it autosaves), only the
    /// chance to write it into the configuration, so it asks just when the
    /// user wants that and there is something unsaved.
    public static func quitDecision(status: Status, asksToSave: Bool) -> QuitDecision {
        guard asksToSave else { return .quit }
        switch status {
        case .saved: return .quit
        case .edited: return .askToSave(needsName: false)
        case .notSaved: return .askToSave(needsName: true)
        }
    }

    /// Why the working copy can't be saved under its current name, if it can't.
    public static func saveNameCheck(name: String, loaded: UUID?, in summaries: [ConfigurationSummary]) -> ConfigurationError? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .emptyName }
        if let other = summaries.first(where: { $0.id != loaded && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return .nameTaken(other.name)
        }
        return nil
    }

    /// The loaded ID if its file is still listed (present and readable),
    /// else nil, so a file deleted behind Wilco's back makes the working
    /// copy "Not Saved" and protects it instead of looking saved.
    public static func stillLoaded(_ id: UUID?, in summaries: [ConfigurationSummary]) -> UUID? {
        guard let id, summaries.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    public static func titleSuffix(_ status: Status) -> String {
        switch status {
        case .saved: ""
        case .edited: " — Edited"
        case .notSaved: " — Not Saved"
        }
    }
}

extension ConfigurationError {
    /// Text for an alert, in the app's plain style.
    public var message: String {
        switch self {
        case .emptyName: "A configuration needs a name."
        case .nameTaken(let name): "Another configuration is already called “\(name)”."
        case .notFound: "That configuration's file is missing."
        }
    }
}
