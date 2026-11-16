import SwiftUI

/// Edits a list of words or phrases: type and press Return (or click +) to
/// add, click × to remove. The field's label is hidden so, in a grouped form,
/// the prompt shows as placeholder text inside the field rather than as a
/// row title beside an empty box.
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
        HStack {
            TextField(prompt, text: $draft, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
            Button("Add", systemImage: "plus.circle.fill", action: commit)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func commit() {
        let token = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        guard !token.isEmpty, !tokens.contains(where: { $0.caseInsensitiveCompare(token) == .orderedSame }) else { return }
        tokens.append(token)
    }
}
