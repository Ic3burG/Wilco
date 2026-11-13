import Foundation
import Testing
@testable import WilcoCore

@Suite("Channel groups")
struct ChannelGroupTests {
    // MARK: Order

    /// An older show has no stored sidebar order.
    @Test func withoutStoredOrderFoldersComeFirst() {
        let f = GroupedShow()
        #expect(f.show.sidebarOrder == nil)
        #expect(f.show.sidebarChildren(of: nil) == [.group(f.radios.id), .group(f.stage.id), .channel(f.b.id)])
        #expect(f.show.channelsInDisplayOrder.map(\.name) == ["C", "D", "A", "B"])
    }

    @Test func storedOrderInterleavesFoldersAndChannels() {
        var f = GroupedShow()
        f.show.sidebarOrder = [.channel(f.b.id), .group(f.stage.id), .group(f.radios.id)]
        #expect(f.show.channelsInDisplayOrder.map(\.name) == ["B", "A", "C", "D"])
    }

    @Test func staleOrderEntriesAreDroppedAndMissingItemsAppended() {
        var f = GroupedShow()
        // C is grouped, so it can't be top level; the UUIDs name nothing.
        f.show.sidebarOrder = [.channel(UUID()), .group(f.stage.id), .channel(f.c.id), .group(UUID())]
        #expect(f.show.sidebarChildren(of: nil) == [.group(f.stage.id), .group(f.radios.id), .channel(f.b.id)])
    }

    @Test func folderChildrenAreItsChannels() {
        let f = GroupedShow()
        #expect(f.show.sidebarChildren(of: f.radios.id) == [.channel(f.c.id), .channel(f.d.id)])
    }

    @Test func newChannelAppearsAtTheEnd() {
        var f = GroupedShow()
        let added = f.show.addChannel()
        #expect(f.show.sidebarChildren(of: nil).last == .channel(added.id))
    }

    // MARK: Moving (what an outline drop hands over: a parent and a child index)

    @Test func folderCanMoveBetweenChannels() {
        var f = GroupedShow()
        f.show.moveSidebarItems([.group(f.radios.id)], toParent: nil, at: 3)
        #expect(f.show.sidebarChildren(of: nil) == [.group(f.stage.id), .channel(f.b.id), .group(f.radios.id)])
        #expect(f.show.channelsInDisplayOrder.map(\.name) == ["A", "B", "C", "D"])
        #expect(f.show.channels.map(\.id) == f.show.channelsInDisplayOrder.map(\.id))
        #expect(f.show.groups.map(\.name) == ["Stage", "Radios"])
    }

    @Test func channelMovedOutOfAFolderToATopLevelPosition() {
        var f = GroupedShow()
        f.show.moveSidebarItems([.channel(f.c.id)], toParent: nil, at: 1)
        #expect(f.show.sidebarChildren(of: nil) == [.group(f.radios.id), .channel(f.c.id), .group(f.stage.id), .channel(f.b.id)])
        #expect(f.show.channels(inGroup: f.radios.id).map(\.name) == ["D"])
        #expect(f.show.channel(id: f.c.id)?.groupID == nil)
    }

    @Test func channelMovedIntoAFolderAtAnIndex() {
        var f = GroupedShow()
        f.show.moveSidebarItems([.channel(f.b.id)], toParent: f.radios.id, at: 1)
        #expect(f.show.channels(inGroup: f.radios.id).map(\.name) == ["C", "B", "D"])
        #expect(!f.show.sidebarChildren(of: nil).contains(.channel(f.b.id)))
    }

    /// Indexes count the list as shown, dragged rows included, as NSOutlineView does.
    @Test func reorderingWithinAFolder() {
        var f = GroupedShow()
        f.show.moveSidebarItems([.channel(f.c.id)], toParent: f.radios.id, at: 2)
        #expect(f.show.channels(inGroup: f.radios.id).map(\.name) == ["D", "C"])
    }

    @Test func droppingOntoAFolderAppends() {
        var f = GroupedShow()
        f.show.moveSidebarItems([.channel(f.b.id)], toParent: f.radios.id, at: .max)
        #expect(f.show.channels(inGroup: f.radios.id).map(\.name) == ["C", "D", "B"])
    }

    @Test func foldersCannotGoInsideFolders() {
        var f = GroupedShow()
        #expect(!f.show.canMoveSidebarItems([.group(f.stage.id)], toParent: f.radios.id))
        let before = f.show
        f.show.moveSidebarItems([.group(f.stage.id)], toParent: f.radios.id, at: 0)
        #expect(f.show == before)
    }

    @Test func unknownItemsOrMissingFoldersAreRefused() {
        let f = GroupedShow()
        #expect(!f.show.canMoveSidebarItems([.channel(UUID())], toParent: nil))
        #expect(!f.show.canMoveSidebarItems([.channel(f.b.id)], toParent: UUID()))
        #expect(!f.show.canMoveSidebarItems([.combined], toParent: nil))
        #expect(!f.show.canMoveSidebarItems([], toParent: nil))
        #expect(f.show.canMoveSidebarItems([.channel(f.b.id), .group(f.stage.id)], toParent: nil))
    }

    // MARK: Assigning and deleting

    @Test func assigningMovesChannelToEndOfGroup() {
        var f = GroupedShow()
        f.show.assignChannel(f.b.id, toGroup: f.radios.id)
        #expect(f.show.channels(inGroup: f.radios.id).map(\.name) == ["C", "D", "B"])
        #expect(f.show.channels.map(\.id) == f.show.channelsInDisplayOrder.map(\.id))
    }

    @Test func ungroupingPutsTheChannelAtTheEnd() {
        var f = GroupedShow()
        f.show.assignChannel(f.c.id, toGroup: nil)
        #expect(f.show.sidebarChildren(of: nil).last == .channel(f.c.id))
    }

    @Test func assigningToMissingGroupDoesNothing() {
        var f = GroupedShow()
        let before = f.show
        f.show.assignChannel(f.b.id, toGroup: UUID())
        #expect(f.show == before)
    }

    @Test func deletingAGroupPutsItsChannelsInItsPlace() {
        var f = GroupedShow()
        f.show.deleteGroup(id: f.radios.id)
        #expect(f.show.groups.map(\.name) == ["Stage"])
        #expect(f.show.sidebarChildren(of: nil) == [.channel(f.c.id), .channel(f.d.id), .group(f.stage.id), .channel(f.b.id)])
        #expect(f.show.channels.count == 4)
    }

    @Test func danglingGroupIDShowsAsUngrouped() {
        var f = GroupedShow()
        f.show.channels[1].groupID = UUID()  // as a hand-edited file could
        #expect(f.show.effectiveGroupID(of: f.show.channels[1]) == nil)
        #expect(f.show.channelsInDisplayOrder.count == 4)
        #expect(f.show.channels(inGroup: nil).map(\.name) == ["B"])
    }

    @Test func groupEditsClearDanglingGroupIDs() {
        var f = GroupedShow()
        f.show.channels[1].groupID = UUID()
        f.show.renameGroup(id: f.stage.id, to: "Deck")
        #expect(f.show.channel(id: f.b.id)?.groupID == nil)
    }

    // MARK: Group properties

    @Test func renameIgnoresBlankNames() {
        var f = GroupedShow()
        f.show.renameGroup(id: f.radios.id, to: "  ")
        #expect(f.show.group(id: f.radios.id)?.name == "Radios")
        f.show.renameGroup(id: f.radios.id, to: " Comms ")
        #expect(f.show.group(id: f.radios.id)?.name == "Comms")
    }

    @Test func settingSymbolChangesOnlyThatGroup() {
        var f = GroupedShow()
        f.show.setGroupSymbol(id: f.radios.id, "antenna.radiowaves.left.and.right")
        #expect(f.show.group(id: f.radios.id)?.symbol == "antenna.radiowaves.left.and.right")
        #expect(f.show.group(id: f.stage.id)?.symbol == "folder")
    }

    @Test func newGroupDefaultsAndGoesAtTheEnd() {
        var f = GroupedShow()
        let group = f.show.addGroup()
        #expect(group.name == "New Group")
        #expect(group.symbol == "folder")
        #expect(f.show.sidebarChildren(of: nil).last == .group(group.id))
    }

    // MARK: File format

    @Test func showWithGroupsAndOrderRoundTrips() throws {
        var f = GroupedShow()
        f.show.moveSidebarItems([.group(f.radios.id)], toParent: nil, at: 3)
        let data = try WilcoJSON.encoder().encode(f.show)
        #expect(try WilcoJSON.decoder().decode(ShowDocument.self, from: data) == f.show)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"group:\(f.radios.id.uuidString)\""))
    }

    /// An entry this build can't read (a newer file, say) must not fail the show.
    @Test func unreadableOrderEntriesAreSkipped() throws {
        let f = GroupedShow()
        var object = try #require(JSONSerialization.jsonObject(with: WilcoJSON.encoder().encode(f.show)) as? [String: Any])
        object["sidebarOrder"] = ["nonsense", "combined", "channel:\(f.b.id.uuidString)"]
        let decoded = try WilcoJSON.decoder().decode(ShowDocument.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.sidebarOrder == [.channel(f.b.id)])
    }
}
