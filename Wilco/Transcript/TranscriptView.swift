import SwiftUI
import WilcoCore

/// Settled lines and cue markers in time order, plus any words still being
/// heard, laid out per Look & Feel in the post-show report's style, for
/// every channel, one channel or one sidebar group.
struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    @Environment(LookAndFeel.self) private var look
    let scope: ChannelScope
    /// Matrix columns: no header, tighter rows.
    var compact = false
    /// Overrides the transcript text size (matrix columns have their own).
    var fontSize: Double?

    private enum Item: Identifiable {
        case line(TranscriptSegment)
        case marker(CueMarker)
        case volatile(ChannelConfig, String)

        var id: AnyHashable {
            switch self {
            case .line(let segment): segment.id
            case .marker(let marker): marker.id
            case .volatile(let channel, _): "volatile-\(channel.id)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !compact {
                LiveHeader(scope: scope)
                Divider()
            }
            transcript
        }
    }

    @ViewBuilder
    private var transcript: some View {
        let appearance = look.appearance
        let settled = settledItems
        let inProgress = volatileItems
        // Words in progress sit at the live end: after the newest line, or
        // above it when newest is first.
        let items = appearance.newestFirst
            ? inProgress + appearance.ordered(settled)
            : settled + inProgress
        let liveEdge = appearance.newestFirst ? Self.top : Self.bottom

        if items.isEmpty {
            emptyState.frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 1).id(Self.top)
                        ForEach(items) { item in
                            row(item, appearance: appearance)
                            Divider().padding(.leading, compact ? 10 : 20)
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .animation(look.animation, value: items.map(\.id))
                }
                .defaultScrollAnchor(appearance.newestFirst ? .top : .bottom)
                .onChange(of: items.map(\.id)) {
                    guard appearance.followLive else { return }
                    withAnimation(look.animation) { proxy.scrollTo(liveEdge, anchor: appearance.newestFirst ? .top : .bottom) }
                }
                .onChange(of: inProgress.map(\.id)) {
                    guard appearance.followLive else { return }
                    proxy.scrollTo(liveEdge, anchor: appearance.newestFirst ? .top : .bottom)
                }
            }
        }
    }

    private static let top = "top"
    private static let bottom = "bottom"

    @ViewBuilder
    private func row(_ item: Item, appearance: TranscriptAppearance) -> some View {
        let size = fontSize ?? appearance.fontSize
        switch item {
        case .line(let segment):
            TranscriptRow(
                channel: model.document.channel(id: segment.channelID), date: segment.timestamp,
                offset: segment.sessionOffset, text: segment.text, highlights: segment.highlights,
                confidence: segment.confidence, showsChannel: scope.showsChannelNames,
                showsTimecode: appearance.showTimecode, isVolatile: false, fontSize: size, compact: compact
            )
        case .marker(let marker):
            MarkerRow(
                marker: marker, channel: marker.channelID.flatMap { model.document.channel(id: $0) },
                showsChannel: scope.showsChannelNames, showsTimecode: appearance.showTimecode, fontSize: size, compact: compact
            )
        case .volatile(let channel, let text):
            TranscriptRow(
                channel: channel, date: nil, offset: nil, text: text, highlights: [], confidence: nil,
                showsChannel: scope.showsChannelNames, showsTimecode: appearance.showTimecode,
                isVolatile: true, fontSize: size, compact: compact
            )
        }
    }

    /// Lines and markers, oldest first.
    private var settledItems: [Item] {
        let filter = scope.filter(in: model.document, narrowedTo: model.chipFilters[scope] ?? [])
        let segments = if case .channel(let id) = scope { model.timeline.segments(for: id) } else { model.timeline.segments }
        let lines = segments
            .filter { filter.includes($0.channelID) }
            .map { (date: $0.timestamp, item: Item.line($0)) }
        let markers = model.markers
            .filter { filter.includes($0.channelID) }
            .map { (date: $0.date, item: Item.marker($0)) }
        guard !markers.isEmpty else { return lines.map(\.item) }
        // Stable, so lines with equal times keep their order.
        return (lines + markers).enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element.item)
    }

    /// Words in progress, in sidebar channel order.
    private var volatileItems: [Item] {
        let filter = scope.filter(in: model.document, narrowedTo: model.chipFilters[scope] ?? [])
        return scope.channels(in: model.document).compactMap { channel in
            guard filter.includes(channel.id),
                  let text = model.timeline.volatile[channel.id] else { return nil }
            return .volatile(channel, text)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isCapturing {
            ContentUnavailableView("Listening", systemImage: "waveform",
                                   description: Text("Lines appear here as they are heard."))
        } else {
            ContentUnavailableView("Not Capturing", systemImage: "waveform.slash",
                                   description: Text("Start capture to transcribe your comms channels."))
        }
    }
}

private extension ChannelScope {
    /// Rows name their channel unless the view is one channel's.
    var showsChannelNames: Bool {
        if case .channel = self { return false }
        return true
    }
}

// MARK: - Header

/// The show, channel or group and this session's totals, with channel chips
/// in the Combined and group views: the post-show report's header, live.
private struct LiveHeader: View {
    @Environment(AppModel.self) private var model
    let scope: ChannelScope

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                title
                status
                Spacer(minLength: 24)
                // Ticks once a second so the duration counts up while live.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(alignment: .firstTextBaseline, spacing: 18) {
                        StatFigure(value: duration(at: context.date), caption: "duration")
                        StatFigure(value: segments.count.formatted(), caption: "messages")
                        if case .channel = scope {
                            StatFigure(value: words.formatted(), caption: "words")
                            StatFigure(value: unclear.formatted(), caption: "unclear")
                                .help("Lines recognised with less than \(ShowReport.unclearBelow.formatted(.percent)) confidence")
                        } else {
                            StatFigure(value: model.markers.count.formatted(), caption: "markers")
                            StatFigure(value: Set(segments.map(\.channelID)).count.formatted(), caption: "channels")
                        }
                    }
                }
            }
            if scope.showsChannelNames && !scope.channels(in: model.document).isEmpty {
                chips
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var title: some View {
        if case .channel(let id) = scope, let channel = model.document.channel(id: id) {
            Label {
                Text(channel.name)
            } icon: {
                Image(systemName: channel.symbol).foregroundStyle(channel.tint.color)
            }
            .font(.title2.weight(.semibold))
        } else if case .group(let id) = scope, let group = model.document.group(id: id) {
            Label(group.name, systemImage: group.symbol)
                .font(.title2.weight(.semibold))
        } else {
            Text(model.document.name).font(.title2.weight(.semibold))
        }
    }

    @ViewBuilder
    private var status: some View {
        if let start = model.sessionStart {
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("Live since \(start.formatted(date: .omitted, time: .shortened))")
            }
            .font(.title3)
            .foregroundStyle(.secondary)
        } else {
            Text(segments.isEmpty ? "Not capturing" : "Stopped")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var chips: some View {
        let channels = scope.channels(in: model.document)
        let inScope = Set(channels.map(\.id))
        let on = (model.chipFilters[scope] ?? []).intersection(inScope)
        return FlowLayout(spacing: 8) {
            Chip(title: "All channels", count: nil, color: .gray, isOn: on.isEmpty) {
                model.chipFilters[scope] = []
            }
            ForEach(channels) { channel in
                Chip(title: channel.name, count: lineCounts[channel.id] ?? 0, color: channel.tint.color,
                     isOn: on.contains(channel.id)) {
                    var chips = on
                    if chips.contains(channel.id) { chips.remove(channel.id) } else { chips.insert(channel.id) }
                    model.chipFilters[scope] = chips
                }
            }
        }
    }

    /// Everything in scope, ignoring chips: the header counts the whole view.
    private var segments: [TranscriptSegment] {
        switch scope {
        case .channel(let id): return model.timeline.segments(for: id)
        case .all: return model.timeline.segments
        case .group:
            let filter = scope.filter(in: model.document, narrowedTo: [])
            return model.timeline.segments.filter { filter.includes($0.channelID) }
        }
    }

    private var lineCounts: [UUID: Int] {
        model.timeline.segments.reduce(into: [:]) { $0[$1.channelID, default: 0] += 1 }
    }

    private var words: Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }

    private var unclear: Int {
        segments.count { ($0.confidence ?? 1) < ShowReport.unclearBelow }
    }

    private func duration(at now: Date) -> String {
        let seconds = model.sessionStart.map { now.timeIntervalSince($0) } ?? (segments.last?.sessionOffset ?? 0)
        if seconds < 3600 { return sessionTimecode(seconds).replacing(/^0:/, with: "") }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

// MARK: - Rows

/// Clock time over time since the session started, as in the report.
private struct TimeColumn: View {
    let date: Date?
    let offset: Double?
    let fontSize: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(date?.formatted(date: .omitted, time: .standard) ?? "now")
                .fontWeight(.semibold)
                .foregroundStyle(date == nil ? .secondary : .primary)
            if let offset {
                Text(sessionTimecode(offset))
                    .font(.system(size: fontSize * 0.8))
                    .foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .frame(width: fontSize * 7.4, alignment: .leading)
    }
}

struct TranscriptRow: View {
    let channel: ChannelConfig?
    /// When the line was heard; nil for words still in progress.
    let date: Date?
    /// Seconds since the session started; nil for words still in progress.
    let offset: Double?
    let text: String
    let highlights: [SegmentHighlight]
    let confidence: Double?
    let showsChannel: Bool
    let showsTimecode: Bool
    let isVolatile: Bool
    let fontSize: Double
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if showsTimecode {
                TimeColumn(date: date, offset: offset, fontSize: fontSize)
            }
            if showsChannel {
                Text(channel?.name ?? "Removed channel")
                    .font(.system(size: fontSize * 0.92, weight: .medium))
                    .foregroundStyle(channel?.tint.color ?? .secondary)
                    .frame(width: fontSize * 8.5, alignment: .leading)
                    .lineLimit(1)
            }
            HighlightedText(
                text: text,
                primary: highlights.filter { !$0.phrase.isEmpty }.map { TextMark(phrase: $0.phrase, color: $0.tint.color) },
                dimmed: isVolatile || isUnsure
            )
            .italic(isVolatile)
        }
        .font(.system(size: fontSize))
        .padding(.horizontal, compact ? 10 : 20)
        .padding(.vertical, compact ? 5 : 8)
        .help(isUnsure ? "Low recognition confidence" : "")
    }

    private var isUnsure: Bool { (confidence ?? 1) < 0.4 }
}

/// A cue point an automation rule marked: a dot, the label, and the rule.
private struct MarkerRow: View {
    let marker: CueMarker
    let channel: ChannelConfig?
    let showsChannel: Bool
    let showsTimecode: Bool
    let fontSize: Double
    let compact: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if showsTimecode {
                TimeColumn(date: marker.date, offset: marker.sessionOffset, fontSize: fontSize)
            }
            if showsChannel {
                Text(channel?.name ?? "")
                    .font(.system(size: fontSize * 0.92, weight: .medium))
                    .foregroundStyle(channel?.tint.color ?? .secondary)
                    .frame(width: fontSize * 8.5, alignment: .leading)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(.orange).frame(width: fontSize * 0.6, height: fontSize * 0.6)
                Text(marker.label).fontWeight(.semibold)
                Text(marker.ruleName).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: fontSize))
        .padding(.horizontal, compact ? 10 : 20)
        .padding(.vertical, compact ? 5 : 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cue point \(marker.label), from \(marker.ruleName)")
    }
}

/// `H:MM:SS` since the session started.
func sessionTimecode(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.down)))
    return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
}
