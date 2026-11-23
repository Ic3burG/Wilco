import Foundation

/// Editing helpers for a list of vocabulary terms, such as the show's global
/// vocabulary. Terms are compared ignoring case, so "Pyro" and "pyro" count
/// as one.
public enum TermList {
    /// `terms` with every new term in `input` appended in order. Input may be
    /// one term or a pasted list separated by new lines or commas; blanks and
    /// terms already present are skipped.
    public static func adding(_ input: String, to terms: [String]) -> [String] {
        var result = terms
        var seen = Set(terms.map { $0.lowercased() })
        let pieces = input.split(whereSeparator: { $0.isNewline || $0 == "," })
        for piece in pieces {
            let term = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { continue }
            result.append(term)
        }
        return result
    }

    /// Terms containing `query`, ignoring case. A blank query matches all.
    public static func filter(_ terms: [String], matching query: String) -> [String] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return terms }
        return terms.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    /// Terms in alphabetical order, ignoring case.
    public static func sorted(_ terms: [String]) -> [String] {
        terms.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
