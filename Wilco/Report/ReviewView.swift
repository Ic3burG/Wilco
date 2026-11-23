import SwiftUI
import WilcoCore

/// What went wrong in a session, with one-click fixes to the open show.
struct ReviewView: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: ReportModel
    @State private var showDismissed = false

    var body: some View {
        if let review = model.review {
            let visible = review.findings.filter { !model.dismissed.contains(model.dismissKey($0)) }
            let hidden = review.findings.filter { model.dismissed.contains(model.dismissKey($0)) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(summary(review, findings: visible.count))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if visible.isEmpty {
                        Text(review.findings.isEmpty ? "Nothing to flag in this session." : "Every finding is dismissed.")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                    ForEach(visible) { finding in
                        FindingCard(finding: finding, review: review, model: model)
                    }
                    if !hidden.isEmpty {
                        HStack {
                            Button(showDismissed ? "Hide \(hidden.count) dismissed" : "Show \(hidden.count) dismissed") {
                                showDismissed.toggle()
                            }
                            if showDismissed {
                                Button("Restore all") { model.restoreDismissed(hidden) }
                            }
                        }
                        .buttonStyle(.link)
                        if showDismissed {
                            ForEach(hidden) { finding in
                                FindingCard(finding: finding, review: review, model: model).opacity(0.6)
                            }
                        }
                    }
                    SectionTitle(text: "This show over time").padding(.top, 14)
                    TrendTable(review: review, loading: model.history == nil)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .frame(maxWidth: 820, alignment: .leading)
            }
        } else {
            ProgressView("Reviewing…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summary(_ review: ShowReview, findings: Int) -> String {
        var parts = [elapsedText(review.stats.duration), "\(review.stats.lines.formatted()) lines",
                     findings == 1 ? "1 finding" : "\(findings) findings"]
        if let p90 = review.stats.delayP90 {
            parts.append("9 in 10 lines appeared within \(p90.formatted(.number.precision(.fractionLength(1)))) s")
        }
        return parts.joined(separator: " · ")
    }
}

private struct FindingCard: View {
    let finding: Finding
    let review: ShowReview
    @Bindable var model: ReportModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .padding(.top, 6)
                .accessibilityLabel(severityName)
            VStack(alignment: .leading, spacing: 6) {
                Text(finding.title).font(.headline)
                Text(finding.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if finding.id == "vocabulary" {
                    VocabularyPicker(review: review)
                }
                HStack(spacing: 8) {
                    if finding.id != "vocabulary" {
                        ForEach(finding.fixes, id: \.self) { FixButton(fix: $0.fix, label: $0.label, model: model) }
                    }
                    if !finding.evidence.isEmpty {
                        Button("Show lines") { model.showLines(finding) }
                    }
                    Button("Dismiss") { model.dismiss(finding) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 10))
    }

    private var color: Color {
        switch finding.severity {
        case .problem: .red
        case .warning: .orange
        case .info: .blue
        }
    }

    private var severityName: String {
        switch finding.severity {
        case .problem: "Problem"
        case .warning: "Warning"
        case .info: "Note"
        }
    }
}

/// A fix as a button: done, unavailable for this show, or ready.
private struct FixButton: View {
    @Environment(AppModel.self) private var app
    let fix: ShowFix
    let label: String
    @Bindable var model: ReportModel

    var body: some View {
        if app.document.isApplied(fix) {
            Label("Done", systemImage: "checkmark")
                .font(.callout)
                .foregroundStyle(.green)
                .help(label)
        } else if !app.document.canApply(fix) {
            Button(label) {}
                .disabled(true)
                .help("Open the show this session was recorded with")
        } else {
            Button(label) {
                app.document = app.document.applying(fix)
                model.show = app.document
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// Ticks for each suggested word; channel names heard wrong start ticked.
private struct VocabularyPicker: View {
    @Environment(AppModel.self) private var app
    let review: ShowReview
    @State private var chosen: Set<String> = []
    @State private var chosenFor: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(review.suggestions, id: \.term) { suggestion in
                let known = app.document.isApplied(.addVocabulary([suggestion.term]))
                Toggle(isOn: Binding(
                    get: { known || chosen.contains(suggestion.term) },
                    set: { if $0 { chosen.insert(suggestion.term) } else { chosen.remove(suggestion.term) } }
                )) {
                    HStack(spacing: 6) {
                        Text(suggestion.term).font(.callout.weight(.medium))
                        Text(caption(suggestion)).font(.callout).foregroundStyle(.secondary)
                        if known { Text("in vocabulary").font(.caption).foregroundStyle(.green) }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(known)
            }
            let fix = ShowFix.addVocabulary(review.suggestions.map(\.term).filter { chosen.contains($0) })
            Button(chosen.count == 1 ? "Add 1 to vocabulary" : "Add \(chosen.count) to vocabulary") {
                app.document = app.document.applying(fix)
                chosen = []
            }
            .buttonStyle(.borderedProminent)
            .disabled(chosen.isEmpty || app.document.isApplied(fix))
            .padding(.top, 4)
        }
        .onAppear(perform: resetChoice)
        .onChange(of: review.suggestions.map(\.term)) { resetChoice() }
    }

    private func caption(_ suggestion: VocabularySuggestion) -> String {
        if let heard = suggestion.heardAs { return "heard as “\(heard)” ×\(suggestion.count)" }
        return "×\(suggestion.count)"
    }

    private func resetChoice() {
        let terms = review.suggestions.map(\.term)
        guard terms != chosenFor else { return }
        chosenFor = terms
        chosen = Set(review.suggestions.filter { $0.heardAs != nil }.map(\.term))
            .filter { !app.document.isApplied(.addVocabulary([$0])) }
    }
}

/// This session beside up to four earlier sessions of the same show.
private struct TrendTable: View {
    let review: ShowReview
    let loading: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                ForEach(["Session", "Lines", "Fillers", "Unclear", "Delay (90%)"], id: \.self) {
                    Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            row("This session", lines: review.stats.lines, fillers: review.stats.fillerShare,
                unclear: review.stats.unclearShare, delay: review.stats.delayP90)
                .fontWeight(.semibold)
            ForEach(review.trend) { past in
                row(past.started.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()),
                    lines: past.lines, fillers: past.fillerShare, unclear: past.unclearShare, delay: past.delayP90)
            }
        }
        .font(.callout)
        .monospacedDigit()
        if loading {
            ProgressView("Reading earlier sessions…").controlSize(.small)
        } else if review.trend.isEmpty {
            Text("No earlier sessions of this show yet.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func row(_ name: String, lines: Int, fillers: Double, unclear: Double, delay: Double?) -> some View {
        GridRow {
            Text(name)
            Text(lines.formatted())
            Text(fillers.formatted(.percent.precision(.fractionLength(0))))
            Text(unclear.formatted(.percent.precision(.fractionLength(1))))
            Text(delay.map { "\($0.formatted(.number.precision(.fractionLength(1)))) s" } ?? "—")
        }
    }
}
