import AppKit
import SwiftUI
import WilcoCore

/// The sidebar's shape: the top level of folders and loose channels, and
/// each folder's channels. A change here reloads the outline; everything a
/// row shows (names, meters, status) updates inside the row instead.
struct SidebarTree: Equatable {
    var top: [SidebarItem] = []
    var children: [UUID: [SidebarItem]] = [:]

    init() {}

    init(_ show: ShowDocument) {
        top = show.sidebarChildren(of: nil)
        for group in show.groups { children[group.id] = show.sidebarChildren(of: group.id) }
    }
}

extension NSPasteboard.PasteboardType {
    /// Private, so a sidebar row dragged into another app pastes nothing.
    static let wilcoSidebarItem = NSPasteboard.PasteboardType("io.github.ic3burg.wilco.sidebar-item")
}

/// The sidebar as an `NSOutlineView` in source-list style.
///
/// SwiftUI's `List` asserted on drops between rows once folders and loose
/// channels shared a section, and drops on rows can't show an insertion
/// line. The outline gives the native line (indented for "into this
/// folder"), a move cursor, and folders anywhere among channels.
struct SidebarOutline: NSViewRepresentable {
    let model: AppModel
    let look: LookAndFeel
    let tree: SidebarTree
    let selection: SidebarItem
    let collapsed: Set<UUID>

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let outline = SidebarOutlineView()
        let column = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 26
        outline.floatsGroupRows = false
        outline.autoresizesOutlineColumn = false
        outline.dataSource = coordinator
        outline.delegate = coordinator
        outline.registerForDraggedTypes([.wilcoSidebarItem])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.draggingDestinationFeedbackStyle = .sourceList
        let menu = NSMenu()
        menu.delegate = coordinator
        outline.menu = menu
        outline.onDelete = { [weak coordinator] in coordinator?.deleteSelection() }
        coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.look = look
        coordinator.sync(tree: tree, selection: selection, collapsed: collapsed)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        weak var outline: NSOutlineView?
        var model: AppModel!
        var look: LookAndFeel!

        private let showHeader = Node(.header("Show"))
        private let channelsHeader = Node(.header("Channels"))
        private var nodes: [SidebarItem: Node] = [:]
        private var tree: SidebarTree?
        /// Set while this code changes the outline, so delegate callbacks
        /// don't write the change straight back to the model.
        private var isSyncing = false

        final class Node: NSObject {
            enum Kind: Equatable {
                case header(String)
                case item(SidebarItem)
            }
            let kind: Kind
            var children: [Node] = []
            init(_ kind: Kind) { self.kind = kind }

            var item: SidebarItem? {
                if case .item(let item) = kind { return item }
                return nil
            }
        }

        /// One node per item for the outline's lifetime, so reloads keep
        /// expansion and selection stable.
        private func node(_ item: SidebarItem) -> Node {
            if let node = nodes[item] { return node }
            let node = Node(.item(item))
            nodes[item] = node
            return node
        }

        func sync(tree: SidebarTree, selection: SidebarItem, collapsed: Set<UUID>) {
            guard let outline else { return }
            isSyncing = true
            defer { isSyncing = false }

            if tree != self.tree {
                self.tree = tree
                showHeader.children = [SidebarItem.combined, .matrix, .activity].map(node)
                channelsHeader.children = tree.top.map(node)
                for item in tree.top {
                    if case .group(let id) = item {
                        node(item).children = (tree.children[id] ?? []).map(node)
                    }
                }
                outline.reloadData()
                outline.expandItem(showHeader)
                outline.expandItem(channelsHeader)
            }
            for item in tree.top {
                guard case .group(let id) = item else { continue }
                let expand = !collapsed.contains(id)
                if expand != outline.isItemExpanded(node(item)) {
                    expand ? outline.expandItem(node(item)) : outline.collapseItem(node(item))
                }
            }

            let row = outline.row(forItem: nodes[selection])
            if row >= 0, row != outline.selectedRow {
                outline.selectRowIndexes([row], byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            } else if row < 0, outline.selectedRow >= 0 {
                outline.deselectAll(nil)
            }
        }

        // MARK: Data source

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? Node else { return 2 }
            return node.children.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? Node else { return index == 0 ? showHeader : channelsHeader }
            return node.children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? Node else { return false }
            switch node.kind {
            case .header: return true
            case .item(.group): return true  // even empty, so it can be opened to drop into
            case .item: return false
            }
        }

        // MARK: Rows

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            if case .header = (item as? Node)?.kind { return true }
            return false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? Node)?.item != nil
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            let cell = outlineView.makeView(withIdentifier: HostingCell.identifier, owner: nil) as? HostingCell ?? HostingCell()
            switch node.kind {
            case .header(let title):
                cell.show(AnyView(
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                ))
            case .item(let item):
                cell.show(AnyView(SidebarRowContent(item: item).environment(model).environment(look)))
            }
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncing, let outline,
                  let item = (outline.item(atRow: outline.selectedRow) as? Node)?.item else { return }
            model.selection = item
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            setCollapsed(false, notification)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            setCollapsed(true, notification)
        }

        private func setCollapsed(_ collapsed: Bool, _ notification: Notification) {
            guard !isSyncing, case .group(let id)? = (notification.userInfo?["NSObject"] as? Node)?.item else { return }
            if collapsed { look.collapsedGroups.insert(id) } else { look.collapsedGroups.remove(id) }
        }

        // MARK: Drag and drop

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
            guard let item = (item as? Node)?.item, item.isSidebarEntry else { return nil }
            let pasteboardItem = NSPasteboardItem()
            pasteboardItem.setString(item.storageValue, forType: .wilcoSidebarItem)
            return pasteboardItem
        }

        func outlineView(
            _ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
            proposedItem item: Any?, proposedChildIndex index: Int
        ) -> NSDragOperation {
            let items = dragged(info)
            guard !items.isEmpty, let target = resolve(item as? Node, index, dragging: items) else { return [] }
            if target.node !== (item as? Node) || target.index != index {
                outlineView.setDropItem(target.node, dropChildIndex: target.index)
            }
            return model.document.canMoveSidebarItems(items, toParent: target.parent) ? .move : []
        }

        func outlineView(
            _ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
            item: Any?, childIndex index: Int
        ) -> Bool {
            let items = dragged(info)
            guard let target = resolve(item as? Node, index, dragging: items),
                  model.document.canMoveSidebarItems(items, toParent: target.parent) else { return false }
            model.document.moveSidebarItems(items, toParent: target.parent, at: target.index < 0 ? .max : target.index)
            return true
        }

        private func dragged(_ info: any NSDraggingInfo) -> [SidebarItem] {
            (info.draggingPasteboard.pasteboardItems ?? [])
                .compactMap { $0.string(forType: .wilcoSidebarItem) }
                .compactMap(SidebarItem.init(storageValue:))
                .filter(\.isSidebarEntry)
        }

        /// Where a proposed drop really goes: the outline node and index to
        /// show, and the folder (`nil` for the top level) the model moves into.
        /// Index -1 means "onto the node", which only a folder accepts.
        private func resolve(_ node: Node?, _ index: Int, dragging items: [SidebarItem])
            -> (node: Node, index: Int, parent: UUID?)?
        {
            let topLevel = channelsHeader.children
            func topIndex(of node: Node) -> Int { topLevel.firstIndex { $0 === node } ?? topLevel.count }
            let draggingFolders = items.contains { if case .group = $0 { true } else { false } }

            switch node?.kind {
            case nil:
                // Between or around the section headers: the end of the channels.
                return (channelsHeader, topLevel.count, nil)
            case .header:
                guard node === channelsHeader else { return nil }
                return (channelsHeader, index < 0 ? topLevel.count : index, nil)
            case .item(.group(let id)):
                guard let node else { return nil }
                if draggingFolders {
                    // Folders don't nest: onto or into a folder means beside it.
                    return (channelsHeader, topIndex(of: node) + (index < 0 ? 0 : 1), nil)
                }
                return (node, index, id)
            case .item(.channel):
                // Onto a channel: the line goes just above it, in its list.
                guard let node, let outline else { return nil }
                let parent = outline.parent(forItem: node) as? Node ?? channelsHeader
                let position = parent.children.firstIndex { $0 === node } ?? parent.children.count
                if parent === channelsHeader { return (channelsHeader, position, nil) }
                if draggingFolders { return (channelsHeader, topIndex(of: parent), nil) }
                return (parent, position, parent.item.flatMap { if case .group(let id) = $0 { id } else { nil } })
            case .item:
                return nil  // Combined, Matrix, Activity
            }
        }

        // MARK: Context menu and delete

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let outline, outline.clickedRow >= 0,
                  let item = (outline.item(atRow: outline.clickedRow) as? Node)?.item else { return }
            switch item {
            case .group(let id): groupMenu(menu, id)
            case .channel(let id): channelMenu(menu, id)
            default: break
            }
        }

        private func groupMenu(_ menu: NSMenu, _ id: UUID) {
            menu.addItem(ActionItem("Rename") { [model] in model?.groupBeingRenamed = id })
            let icons = NSMenu()
            for symbol in GroupSymbols.all {
                let item = ActionItem("") { [model] in model?.document.setGroupSymbol(id: id, symbol) }
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
                icons.addItem(item)
            }
            let iconItem = NSMenuItem(title: "Change Icon", action: nil, keyEquivalent: "")
            iconItem.submenu = icons
            menu.addItem(iconItem)
            menu.addItem(.separator())
            menu.addItem(ActionItem("Delete Group") { [model] in model?.deleteGroup(id) })
        }

        private func channelMenu(_ menu: NSMenu, _ id: UUID) {
            guard let channel = model.document.channel(id: id) else { return }
            let current = model.document.effectiveGroupID(of: channel)
            let groups = NSMenu()
            let none = ActionItem("None") { [model] in model?.document.assignChannel(id, toGroup: nil) }
            none.state = current == nil ? .on : .off
            groups.addItem(none)
            for group in model.document.groups {
                let item = ActionItem(group.name) { [model] in model?.document.assignChannel(id, toGroup: group.id) }
                item.state = current == group.id ? .on : .off
                groups.addItem(item)
            }
            let move = NSMenuItem(title: "Move to Group", action: nil, keyEquivalent: "")
            move.submenu = groups
            menu.addItem(move)
            menu.addItem(.separator())
            menu.addItem(ActionItem(channel.isMuted ? "Unmute Transcription" : "Mute Transcription") { [model] in
                model?.document.updateChannel(id: id) { $0.isMuted.toggle() }
            })
            menu.addItem(ActionItem("Clear Transcript") { [model] in model?.clearTranscript(channelID: id) })
            menu.addItem(.separator())
            menu.addItem(ActionItem("Delete Channel…") { [model] in model?.requestDeletion(of: id) })
        }

        func deleteSelection() {
            switch model.selection {
            case .channel(let id): model.requestDeletion(of: id)
            case .group(let id): model.deleteGroup(id)
            default: break
            }
        }
    }
}

/// Delete and Forward Delete remove the selected folder or channel.
final class SidebarOutlineView: NSOutlineView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            onDelete?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// A cell showing a SwiftUI view. When its row is selected and emphasised,
/// the content switches to the dark scheme so text reads white on the accent.
final class HostingCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("HostingCell")
    private var content = AnyView(EmptyView())
    private let host = NSHostingView(rootView: AnyView(EmptyView()))

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            host.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            host.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ view: AnyView) {
        content = view
        render()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { render() } }
    }

    /// Leading-aligned: the host spans the cell, and SwiftUI would otherwise
    /// centre rows that have no spacer (headers, Combined, Matrix, Activity).
    private func render() {
        let aligned = content.frame(maxWidth: .infinity, alignment: .leading)
        host.rootView = backgroundStyle == .emphasized
            ? AnyView(aligned.environment(\.colorScheme, .dark))
            : AnyView(aligned)
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
