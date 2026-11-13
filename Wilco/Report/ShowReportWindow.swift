import SwiftUI
import UniformTypeIdentifiers
import WilcoCore

/// Search and break down this session, or any earlier one.
struct ShowReportWindow: View {
    @Environment(AppModel.self) private var app
    @State private var model = ReportModel()

    var body: some View {
        NavigationSplitView {
            SessionList(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            ReportDetail(model: model)
        }
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            model.show = app.document
            model.refresh()
        }
    }
}

// MARK: - Sessions

private struct SessionList: View {
    @Bindable var model: ReportModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.sessionsByDay, id: \.day) { group in
                Section(group.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) {
                    ForEach(group.sessions) { session in
                        VStack(alignment: .leading, spacing: 1) {
                            Text((session.started ?? session.modified).formatted(date: .omitted, time: .standard))
                                .font(.headline)
                                .monospacedDigit()
                            Text(session.byteSize.formatted(.byteCount(style: .file)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(session.id)
                    }
                }
            }
        }
        .overlay {
            if model.sessions.isEmpty {
                ContentUnavailableView("No Sessions", systemImage: "doc.text",
                                       description: Text("Sessions appear here after a capture in which something was transcribed."))
            }
        }
    }
}

// MARK: - Detail

private struct ReportDetail: View {
    @Bindable var model: ReportModel
    @State private var exportFormat: ExportFormat?

    var body: some View {
        content
            .navigationTitle("Post-Show")
            .navigationSubtitle(subtitle)
            .searchable(text: $model.searchText, placement: .toolbar, prompt: Text(#"Search words, or "an exact phrase""#))
            .onChange(of: model.searchText) {
                if !model.searchText.isEmpty && model.tab == .channels { model.tab = .log }
            }
            .toolbar { toolbar }
            .fileExporter(
                isPresented: Binding(get: { exportFormat != nil }, set: { if !$0 { exportFormat = nil } }),
                document: exportDocument,
                contentType: exportFormat?.contentType ?? .plainText,
                defaultFilename: exportFilename
            ) { _ in exportFormat = nil }
    }

    @ViewBuilder
    private var content: some View {
        if let report = model.report {
            VStack(alignment: .leading, spacing: 0) {
                ReportHeader(report: report)
                ChipFilters(model: model, report: report)
                Divider()
                switch model.tab {
                case .runOfShow: RunOfShowView(model: model)
                case .log: ChatLogView(model: model)
                case .channels: ChannelsBreakdown(model: model, report: report)
                }
            }
        } else if model.isLoading {
            ProgressView("Building report…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.error {
            ContentUnavailableView("No Report", systemImage: "doc.text.magnifyingglass", description: Text(error))
        } else {
            ContentUnavailableView("Nothing Selected", systemImage: "chart.bar.doc.horizontal",
                                   description: Text("Choose a session to break it down."))
        }
    }

    private var subtitle: String {
        model.selection?.deletingPathExtension().lastPathComponent ?? ""
    }

    private var exportDocument: ExportDocument? {
        guard let report = model.report, let exportFormat else { return nil }
        return ExportDocument(data: exportFormat.render(report))
    }

    private var exportFilename: String? {
        guard let report = model.report, let exportFormat else { return nil }
        return "\(report.showName) \(subtitle).\(exportFormat.fileExtension)"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("View", selection: $model.tab) {
                ForEach(ReportModel.Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(model.report == nil)
        }
        ToolbarItem {
            Menu("More", systemImage: "ellipsis.circle") {
                Button("Export Report as HTML…") { exportFormat = .html }
                Button("Export Subtitles (SRT)…") { exportFormat = .srt }
                Button("Export Subtitles (WebVTT)…") { exportFormat = .vtt }
                Divider()
                Button("Reveal Session File in Finder") {
                    if let url = model.selection { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button("Refresh Sessions", action: model.refresh)
            }
            .disabled(model.report == nil && model.sessions.isEmpty)
        }
    }
}

private struct ReportHeader: View {
    let report: ShowReport

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(report.showName).font(.title2.weight(.semibold))
            Text(report.sessionStart.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year().hour().minute()))
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer(minLength: 24)
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                StatFigure(value: Duration.seconds(report.duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)), caption: "duration")
                StatFigure(value: report.totalMessages.formatted(), caption: "messages")
                StatFigure(value: report.markers.count.formatted(), caption: "markers")
                StatFigure(value: report.channels.count.formatted(), caption: "channels")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }
}

// MARK: - Filter chips

private struct ChipFilters: View {
    @Bindable var model: ReportModel
    let report: ShowReport

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FlowLayout(spacing: 8) {
                Chip(title: "All channels", count: nil, color: .gray, isOn: model.channelFilter.isEmpty) {
                    model.channelFilter = []
                }
                ForEach(report.groups) { group in
                    Chip(title: group.name, count: nil, color: .gray, isOn: group.isOn(in: model.channelFilter), symbol: group.symbol) {
                        model.toggleGroup(group)
                    }
                    .help("All channels in \(group.name)")
                }
                ForEach(report.channels.filter { $0.messages > 0 }) { channel in
                    Chip(title: channel.name, count: channel.messages, color: channel.tint.color,
                         isOn: model.channelFilter.contains(channel.id)) {
                        model.toggleChannel(channel.id)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            if model.tab == .runOfShow {
                Divider()
                FlowLayout(spacing: 8) {
                    Chip(title: "Everything", count: report.markers.count, color: .gray, isOn: model.categoryFilter == nil) {
                        model.categoryFilter = nil
                    }
                    ForEach(ShowReport.MarkerCategory.allCases, id: \.self) { category in
                        let count = report.markers.count { $0.category == category }
                        if count > 0 {
                            Chip(title: category.title, count: count, color: category.color, isOn: model.categoryFilter == category) {
                                model.categoryFilter = model.categoryFilter == category ? nil : category
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
    }
}

// MARK: - Rows

/// Column widths shared by the run of show and chat log so they line up.
private enum Columns {
    static let time: CGFloat = 120
    static let marker: CGFloat = 250
    static let channel: CGFloat = 130
}

private struct TimeCell: View {
    let date: Date
    let elapsed: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(date.formatted(date: .omitted, time: .standard)).fontWeight(.semibold).monospacedDigit()
            Text(elapsedText(elapsed)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(width: Columns.time, alignment: .leading)
    }
}

// MARK: - Run of show

private struct RunOfShowView: View {
    @Bindable var model: ReportModel

    var body: some View {
        let markers = model.filteredMarkers
        if markers.isEmpty {
            ContentUnavailableView(
                "No Moments", systemImage: "flag",
                description: Text(model.searchText.isEmpty
                    ? "No run-of-show moments of these kinds were detected."
                    : "No moments match the search.")
            )
        } else {
            let searchTerms = model.query.highlightTerms
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(markers) { marker in
                        MarkerRow(marker: marker, searchTerms: searchTerms)
                            .contentShape(.rect)
                            .onTapGesture(count: 2) { model.showInContext(marker) }
                            .contextMenu {
                                Button("Show in Chat Log") { model.showInContext(marker) }
                                Button("Copy Line") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(marker.text, forType: .string)
                                }
                            }
                            .help("Double-click to see this line in the chat log")
                        Divider().padding(.leading, 20)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct MarkerRow: View {
    let marker: ShowReport.Marker
    let searchTerms: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            TimeCell(date: marker.date, elapsed: marker.elapsed)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(marker.category.color).frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(marker.label).fontWeight(.semibold)
                if marker.repeats > 1 {
                    Text("×\(marker.repeats)").font(.caption).foregroundStyle(.secondary)
                        .help("Called \(marker.repeats) times within a minute")
                }
            }
            .frame(width: Columns.marker, alignment: .leading)
            Text(marker.channelName)
                .font(.callout.weight(.medium))
                .foregroundStyle(marker.tint.color)
                .lineLimit(1)
                .frame(width: Columns.channel, alignment: .leading)
            HighlightedText(text: marker.text, primary: [TextMark(phrase: marker.matched)], search: searchTerms)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Chat log

private struct ChatLogView: View {
    @Bindable var model: ReportModel

    var body: some View {
        let messages = model.filteredMessages
        if messages.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            let searchTerms = model.query.highlightTerms
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(messages) { message in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                TimeCell(date: message.date, elapsed: message.elapsed)
                                Text(message.channelName)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(message.tint.color)
                                    .lineLimit(1)
                                    .frame(width: Columns.channel, alignment: .leading)
                                HighlightedText(text: message.text, search: searchTerms)
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(message.id == model.focusedMessage ? Color.yellow.opacity(0.18) : .clear)
                            .id(message.id)
                            Divider().padding(.leading, 20)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !model.searchText.isEmpty || !model.channelFilter.isEmpty {
                        Text("\(messages.count.formatted()) lines")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: .capsule)
                            .padding(12)
                    }
                }
                .onAppear { scroll(proxy) }
                .onChange(of: model.focusedMessage) { scroll(proxy) }
            }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let id = model.focusedMessage else { return }
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
    }
}

// MARK: - Channels

private struct ChannelsBreakdown: View {
    @Bindable var model: ReportModel
    let report: ShowReport

    private var channels: [ShowReport.Channel] {
        model.channelFilter.isEmpty ? report.channels : report.channels.filter { model.channelFilter.contains($0.id) }
    }

    var body: some View {
        let busiest = report.channels.map(\.messages).max() ?? 1
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "Messages per channel")
                ForEach(channels) { channel in
                    ChannelStatRow(channel: channel, busiest: busiest)
                }
                SectionTitle(text: "Traffic").padding(.top, 18)
                Text("One column per \(Duration.seconds(report.bucketSeconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TrafficHeatmap(report: report, channels: channels)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }
}

private struct ChannelStatRow: View {
    let channel: ShowReport.Channel
    /// The most messages any channel had, which fills the bar.
    let busiest: Int

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Label {
                Text(channel.name).font(.headline).lineLimit(1)
            } icon: {
                Image(systemName: channel.symbol).foregroundStyle(channel.tint.color)
            }
            .frame(width: 200, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                ShareBar(fraction: Double(channel.messages) / Double(max(busiest, 1)), color: channel.tint.color)
                    .padding(.top, 5)
                Text(details)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 6) {
                    ForEach(channel.topTerms, id: \.word) { term in
                        HStack(spacing: 4) {
                            Text(term.word)
                            Text(term.count.formatted()).foregroundStyle(channel.tint.color).monospacedDigit()
                        }
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 5))
                    }
                }
            }

            VStack(alignment: .trailing, spacing: 0) {
                Text(channel.messages.formatted()).font(.title3.weight(.semibold)).monospacedDigit()
                Text(channel.share.formatted(.percent.precision(.fractionLength(1))))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var details: String {
        var parts = ["\(channel.words.formatted()) words"]
        if let mean = channel.meanConfidence {
            parts.append("\(mean.formatted(.percent.precision(.fractionLength(0)))) mean confidence")
            parts.append("\(channel.unclear) unclear")
        }
        if let start = channel.busiestStart {
            parts.append("busiest \(elapsedText(start))")
            parts.append("\(channel.busiestCount) in \(Int(ShowReport.busiestWindow / 60)) min")
        }
        return parts.joined(separator: " · ")
    }
}

/// A rounded bar on a faint track.
private struct ShareBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(height: 8)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule().fill(color)
                        .frame(width: max(8, geometry.size.width * min(max(fraction, 0), 1)))
                }
            }
    }
}

/// One row of columns per channel: taller and stronger where it was busier.
private struct TrafficHeatmap: View {
    let report: ShowReport
    let channels: [ShowReport.Channel]

    private static let labelWidth: CGFloat = 150
    private static let rowHeight: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(channels) { channel in
                HStack(alignment: .bottom, spacing: 12) {
                    Text(channel.name)
                        .font(.callout)
                        .lineLimit(1)
                        .frame(width: Self.labelWidth, alignment: .trailing)
                        .padding(.bottom, 4)
                    Columns(counts: report.buckets.map { $0.counts[channel.id] ?? 0 }, color: channel.tint.color)
                        .frame(height: Self.rowHeight)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(channel.name): busiest \(channel.busiestStart.map(elapsedText) ?? "never")")
            }
            HStack(spacing: 12) {
                Color.clear.frame(width: Self.labelWidth, height: 1)
                Axis(duration: Double(report.buckets.count) * report.bucketSeconds)
            }
        }
    }

    private struct Columns: View {
        let counts: [Int]
        let color: Color

        var body: some View {
            Canvas { context, size in
                guard !counts.isEmpty else { return }
                let peak = Double(counts.max() ?? 0)
                let slot = size.width / CGFloat(counts.count)
                let gap = min(2, slot * 0.15)
                context.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(color.opacity(0.12)))
                for (index, count) in counts.enumerated() where count > 0 && peak > 0 {
                    let ratio = Double(count) / peak
                    let height = max(4, (size.height - 2) * (0.3 + 0.7 * ratio))
                    let rect = CGRect(x: CGFloat(index) * slot, y: size.height - height, width: slot - gap, height: height)
                    context.fill(Path(rect), with: .color(color.opacity(0.4 + 0.6 * ratio)))
                }
            }
        }
    }

    private struct Axis: View {
        let duration: Double

        var body: some View {
            GeometryReader { geometry in
                let ticks = 6
                ZStack(alignment: .topLeading) {
                    ForEach(0..<ticks, id: \.self) { tick in
                        Text(elapsedText(duration * Double(tick) / Double(ticks)))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                            .offset(x: geometry.size.width * CGFloat(tick) / CGFloat(ticks))
                    }
                }
            }
            .frame(height: 14)
        }
    }
}

// MARK: - Export

private enum ExportFormat {
    case html, srt, vtt

    var fileExtension: String {
        switch self {
        case .html: "html"
        case .srt: "srt"
        case .vtt: "vtt"
        }
    }

    var contentType: UTType {
        switch self {
        case .html: .html
        case .srt: UTType(filenameExtension: "srt") ?? .plainText
        case .vtt: UTType(filenameExtension: "vtt") ?? .plainText
        }
    }

    func render(_ report: ShowReport) -> Data {
        switch self {
        case .html: Data(ShowReportHTML.render(report).utf8)
        case .srt: Data(SubtitleExport.render(report, format: .srt).utf8)
        case .vtt: Data(SubtitleExport.render(report, format: .vtt).utf8)
        }
    }
}

private struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.html, .plainText]
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

extension ShowReport.MarkerCategory {
    var color: Color { tint.color }
}

private func elapsedText(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
}
