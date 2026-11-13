import SwiftUI
import WilcoCore

// Pieces shared by the main window and the post-show report, so the two read
// as one app.

/// A phrase to pick out of a line, and its colour.
struct TextMark: Equatable {
    var phrase: String
    var color: Color = .yellow
}

/// A rounded filter button: a coloured dot, a name and a count.
struct Chip: View {
    let title: String
    let count: Int?
    let color: Color
    let isOn: Bool
    /// Shown in place of the colour dot, as for a group.
    var symbol: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).imageScale(.small)
                } else {
                    Circle().fill(color).frame(width: 7, height: 7)
                }
                Text(title)
                if let count { Text(count.formatted()).monospacedDigit() }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(isOn ? 0.22 : 0.07), in: .capsule)
            .overlay(Capsule().strokeBorder(color.opacity(isOn ? 0.7 : 0.3), lineWidth: isOn ? 1.5 : 1))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Lays children out left to right, wrapping onto new rows as needed.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width && !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// A line of comms with what matters in it picked out.
struct HighlightedText: View {
    let text: String
    /// Marked strongly: calls and rule phrases, each in its own colour.
    var primary: [TextMark] = []
    /// Marked lightly: the words being searched for.
    var search: [String] = []
    /// Grey the unmarked words, so the marks stand out (as in the report).
    var dimmed = true

    var body: some View {
        Text(attributed)
            .foregroundStyle(dimmed ? .secondary : .primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        var result = AttributedString(text)
        func mark(_ ranges: [Range<String.Index>], style: (inout AttributeContainer) -> Void) {
            var container = AttributeContainer()
            style(&container)
            for range in ranges {
                guard let lower = AttributedString.Index(range.lowerBound, within: result),
                      let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
                result[lower..<upper].mergeAttributes(container)
            }
        }
        for term in search {
            mark(Self.ranges(of: term, in: text)) {
                $0.backgroundColor = Color.accentColor.opacity(0.25)
                $0.foregroundColor = .primary
            }
        }
        for item in primary {
            mark(PhraseLocator.ranges(of: item.phrase, in: text)) {
                $0.backgroundColor = item.color.opacity(0.35)
                $0.foregroundColor = .primary
                // Bold without fixing a size, so the view's font size holds.
                $0.inlinePresentationIntent = .stronglyEmphasized
            }
        }
        return result
    }

    /// Search words match anywhere, as the search itself does.
    private static func ranges(of term: String, in text: String) -> [Range<String.Index>] {
        if term.contains(" ") { return PhraseLocator.ranges(of: term, in: text) }
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        while let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: start..<text.endIndex) {
            ranges.append(range)
            start = range.upperBound
        }
        return ranges
    }
}

/// A big figure over a small caption, as in the report header.
struct StatFigure: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
