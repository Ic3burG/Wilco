import SwiftUI
import WilcoCore

/// One column per channel, side by side. Columns can be resized by their
/// right edge, collapsed to a narrow strip (one click on the column's icon),
/// and given their own text size; all of it is remembered per channel. The
/// toolbar fits, resets and expands them all at once.
struct ChannelMatrixView: View {
    @Environment(AppModel.self) private var model
    @Environment(LookAndFeel.self) private var look

    var body: some View {
        if model.document.channels.isEmpty {
            ContentUnavailableView("No Channels", systemImage: "rectangle.split.3x1",
                                   description: Text("Add a channel to see it here."))
        } else {
            GeometryReader { geometry in
                let columns = model.document.matrixColumns(look.matrixMode)
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(columns) { column in
                            MatrixColumnView(column: column, level: level(of: column))
                            Divider()
                        }
                    }
                    .animation(look.animation, value: columns.map(\.id))
                }
                .toolbar {
                    ToolbarItemGroup {
                        @Bindable var look = look
                        Picker("Show", selection: $look.matrixMode) {
                            Text("Channels").tag(MatrixMode.channels)
                            Text("Groups").tag(MatrixMode.groups)
                        }
                        .pickerStyle(.segmented)
                        .help("One column per channel, or per group")
                        Button("Fit Columns to Window", systemImage: "arrow.left.and.right.square") {
                            withAnimation(look.animation) {
                                look.matrix.fit(columns.map(\.id), into: geometry.size.width - Double(columns.count))
                            }
                        }
                        .help("Share the window's width among the open columns")
                        Button("Reset Column Widths", systemImage: "arrow.uturn.backward.square") {
                            withAnimation(look.animation) { look.matrix.resetWidths() }
                        }
                        .help("Put every column back to the standard width")
                        .disabled(!look.matrix.hasCustomWidths)
                        Button("Reset Column Text Sizes", systemImage: "textformat.size") {
                            look.matrix.resetFontSizes()
                        }
                        .help("Columns follow the transcript text size again (View ▸ Larger/Smaller Text)")
                        .disabled(!look.matrix.hasCustomFontSizes)
                        Button("Expand All Columns", systemImage: "rectangle.expand.vertical") {
                            withAnimation(look.animation) { look.matrix.expandAll() }
                        }
                        .help("Open every collapsed column")
                        .disabled(!look.matrix.hasCollapsedColumns)
                    }
                }
            }
        }
    }

    private func level(of column: MatrixColumn) -> Float? {
        switch column {
        case .channel(let channel): model.meters[channel.id]
        case .group(let group, _): model.document.channels(inGroup: group.id).compactMap { model.meters[$0.id] }.max()
        }
    }
}

private struct MatrixColumnView: View {
    @Environment(LookAndFeel.self) private var look
    let column: MatrixColumn
    /// The channel's meter, or a group's loudest channel; nil when not captured.
    let level: Float?
    /// Width while a resize drag is in progress.
    @State private var dragStartWidth: Double?

    var body: some View {
        let collapsed = look.matrix.isCollapsed(column.id)
        Group {
            if collapsed {
                collapsedStrip
            } else {
                VStack(spacing: 0) {
                    header
                    TranscriptView(scope: column.scope, compact: true, fontSize: fontSize)
                }
            }
        }
        .frame(width: look.matrix.displayWidth(for: column.id))
        .frame(maxHeight: .infinity)
        .background(.background)
        .overlay(alignment: .trailing) {
            if !collapsed { resizeHandle }
        }
    }

    private var title: String {
        switch column {
        case .channel(let channel): channel.name
        case .group(let group, _): group.name
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch column {
        case .channel(let channel): Image(systemName: channel.symbol).foregroundStyle(channel.tint.color)
        case .group(let group, _): Image(systemName: group.symbol)
        }
    }

    private var fontSize: Double {
        look.matrix.fontSize(for: column.id, default: look.appearance.fontSize)
    }

    private var header: some View {
        HStack {
            Button(action: collapse) { icon.contentShape(.rect) }
                .buttonStyle(.plain)
                .help("Collapse \(title)")
            Text(title).fontWeight(.semibold).lineLimit(1)
            if case .group(_, let count) = column {
                Text(count == 1 ? "1 channel" : "\(count) channels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if let level {
                LevelMeter(level: level).frame(width: 40, height: 4)
            }
            Menu {
                Button("Larger Text") { look.matrix.setFontSize(fontSize + 1, for: column.id) }
                Button("Smaller Text") { look.matrix.setFontSize(fontSize - 1, for: column.id) }
                Divider()
                Button("Collapse Column", action: collapse)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Column options")
        }
        .padding(8)
        .background(.bar)
    }

    private func collapse() {
        withAnimation(look.animation) { look.matrix.setCollapsed(true, for: column.id) }
    }

    /// A narrow strip with the channel's name running down it; click to expand.
    private var collapsedStrip: some View {
        Button {
            withAnimation(look.animation) { look.matrix.setCollapsed(false, for: column.id) }
        } label: {
            VStack(spacing: 8) {
                icon
                Text(title)
                    .fontWeight(.semibold)
                    .fixedSize()
                    .rotationEffect(.degrees(90))
                    .frame(width: 20)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 40)
                if let level {
                    LevelMeter(level: level).frame(width: 4, height: 30).rotationEffect(.degrees(-90))
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Expand \(title)")
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(.rect)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        let start = dragStartWidth ?? look.matrix.width(for: column.id)
                        dragStartWidth = start
                        look.matrix.setWidth(start + drag.translation.width, for: column.id)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .onTapGesture(count: 2) {
                withAnimation(look.animation) { look.matrix.setWidth(MatrixLayout.defaultWidth, for: column.id) }
            }
            .help("Drag to resize; double-click to reset")
    }
}
