import Foundation

/// File names for saved shows.
public enum ShowFile {
    public static let fileExtension = "wilco"

    /// The autosaved working copy in ``DataLocations/root``.
    public static let currentName = "Current.\(fileExtension)"
}
