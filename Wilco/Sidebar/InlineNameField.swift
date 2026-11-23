import SwiftUI

/// A sidebar row's name, edited in place: Return or clicking away saves it,
/// Escape keeps the old name. Blank names are ignored by the model.
struct InlineNameField: View {
    let prompt: String
    let name: String
    let onRename: (String) -> Void
    let onEndRename: () -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool
    /// Losing focus commits only once the field has actually had it.
    @State private var hadFocus = false

    var body: some View {
        TextField(prompt, text: $draft)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand(perform: onEndRename)
            .onChange(of: focused) {
                if focused { hadFocus = true } else if hadFocus { commit() }
            }
            .onAppear {
                draft = name
                hadFocus = false
                // A run-loop later: focus set in the same pass as the
                // outline's selection change often doesn't take.
                Task { @MainActor in focused = true }
            }
    }

    private func commit() {
        onRename(draft)
        onEndRename()
    }
}
