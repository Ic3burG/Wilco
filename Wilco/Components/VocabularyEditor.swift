import AppKit
import SwiftUI
import WilcoCore

/// One form row standing in for a whole vocabulary list: how many terms there
/// are, the first few, and an Edit button that opens ``VocabularySheet``. A
/// long list stays out of the way of the settings around it.
struct VocabularySummaryRow: View {
    @Binding var terms: [String]
    var title = "Global Vocabulary"
    @State private var editing = false

    var body: some View {
        LabeledContent {
            Button("Edit…") { editing = true }
                .help("Add, remove and search the terms")
        } label: {
            Text(terms.isEmpty ? "No terms" : "^[\(terms.count) term](inflect: true)")
            if !terms.isEmpty { Text(preview).lineLimit(1) }
        }
        .sheet(isPresented: $editing) {
            VocabularySheet(terms: $terms, title: title)
        }
    }

    /// The first terms in the list, then how many more follow.
    private var preview: String {
        let shown = terms.prefix(4).joined(separator: ", ")
        let rest = terms.count - min(terms.count, 4)
        return rest > 0 ? "\(shown) and \(rest) more" : shown
    }
}

/// Edits a vocabulary list as wrapping chips: type a term (or several,
/// separated by commas) and press Return, paste a list from the clipboard,
/// search, sort, and click × on a chip to remove it.
struct VocabularySheet: View {
    @Binding var terms: [String]
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Text("^[\(terms.count) term](inflect: true)").foregroundStyle(.secondary)
                Spacer()
                TextField("Search", text: $search, prompt: Text("Search"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
            }

            HStack {
                TextField("Add a term", text: $draft, prompt: Text("Add a term, or several separated by commas"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                Button("Add", action: commit)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Paste List", systemImage: "doc.on.clipboard", action: pasteList)
                    .help("Add every line of the text on the clipboard as a term")
            }

            ScrollView {
                if visible.isEmpty {
                    Text(terms.isEmpty ? "No terms yet." : "No terms match “\(search)”.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(visible, id: \.self) { TermChip(term: $0, remove: remove) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Text("Applied to every channel. Rule phrases are biased in automatically, so there is no need to repeat them here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sort A–Z") { terms = TermList.sorted(terms) }
                    .disabled(terms.count < 2 || terms == TermList.sorted(terms))
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 440)
    }

    private var visible: [String] { TermList.filter(terms, matching: search) }

    private func commit() {
        terms = TermList.adding(draft, to: terms)
        draft = ""
    }

    private func pasteList() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        terms = TermList.adding(text, to: terms)
    }

    private func remove(_ term: String) {
        terms.removeAll { $0 == term }
    }
}

/// One term as a rounded chip with a remove button.
private struct TermChip: View {
    let term: String
    let remove: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(term)
            Button("Remove \(term)", systemImage: "xmark.circle.fill") { remove(term) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }
}
