import Foundation

/// A prompt that more than one window can show, such as "save changes
/// before loading?". The window that was active when the prompt was asked
/// for shows it, and keeps showing it until the request ends.
///
/// An open alert stops its window appearing active. A prompt that only
/// showed while its window was active would therefore close itself as soon
/// as it opened, and clearing the request with it would make the button
/// that asked do nothing. So this decides once, when the request changes.
public struct WindowPrompt: Equatable, Sendable {
    public private(set) var isPresented = false

    public init() {}

    /// Call when the request starts, changes or ends. `appearsActive` is
    /// whether this window is the active one at that moment.
    public mutating func requestChanged(isRequested: Bool, appearsActive: Bool) {
        isPresented = isRequested && (isPresented || appearsActive)
    }

    /// The user closed the prompt.
    public mutating func dismissed() {
        isPresented = false
    }
}
