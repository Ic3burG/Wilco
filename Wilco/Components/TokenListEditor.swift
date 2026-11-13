import SwiftUI

/// Edits a list of words or phrases: type and press Return to add, click × to remove.
struct TokenListEditor: View {
    @Binding var tokens: [String]
    let prompt: String
    @State private var draft = ""

    var body: some View {
        ForEach(tokens, id: \.self) { token in
            HStack {
                Text(token)
                Spacer()
                Button("Remove \(token)", systemImage: "xmark.circle.fill") {
                    tokens.removeAll { $0 == token }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
        TextField(prompt, text: $draft)
            .onSubmit(commit)
    }

    private func commit() {
        let token = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !token.isEmpty, !tokens.contains(where: { $0.caseInsensitiveCompare(token) == .orderedSame }) else { return }
        tokens.append(token)
    }
}
