import Foundation
import Testing
@testable import WilcoCore

@Suite("Channel editing")
struct ChannelEditingTests {
    @Test func newChannelIsNumberedAndPatchedToLowestFreeInput() {
        var show = ShowDocument()
        for input in [0, 1, 3] {
            show.channels.append(ChannelConfig(name: "In \(input)", deviceChannel: input))
        }
        show.channels.append(ChannelConfig(name: "Unpatched"))

        let added = show.addChannel()

        #expect(added.name == "Channel 5")
        #expect(added.deviceChannel == 2)
        #expect(show.channels.last == added)
    }

    @Test func newChannelTintsCycleSoNeighboursDiffer() {
        var show = ShowDocument()
        let first = show.addChannel()
        let second = show.addChannel()
        #expect(first.tint != second.tint)
    }

    @Test func deletingAChannelRemovesItFromRulesAndHighlights() {
        var show = ShowDocument()
        let keep = show.addChannel()
        let gone = show.addChannel()
        show.rules = [AutomationRule(name: "Go", channelIDs: [keep.id, gone.id])]
        show.highlights = [HighlightRule(name: "Names", channelIDs: [gone.id])]

        show.deleteChannel(id: gone.id)

        #expect(show.channels.map(\.id) == [keep.id])
        #expect(show.rules[0].channelIDs == [keep.id])
        #expect(show.highlights[0].channelIDs.isEmpty)
    }

    @Test func updatingAMissingChannelIsANoOp() {
        var show = ShowDocument()
        let channel = show.addChannel()
        show.deleteChannel(id: channel.id)

        show.updateChannel(id: channel.id) { $0.name = "Ghost" }

        #expect(show.channels.isEmpty)
    }

    @Test func movesChannelsLikeAListReorder() {
        var show = ShowDocument()
        let a = show.addChannel(), b = show.addChannel(), c = show.addChannel()

        show.moveChannels(fromOffsets: IndexSet(integer: 0), toOffset: 3)

        #expect(show.channels.map(\.id) == [b.id, c.id, a.id])
    }
}

@Suite("Sidebar selection")
struct SidebarItemTests {
    @Test func storageValueRoundTrips() {
        let id = UUID()
        for item in [SidebarItem.combined, .matrix, .activity, .channel(id), .group(id)] {
            #expect(SidebarItem(storageValue: item.storageValue) == item)
        }
        #expect(SidebarItem(storageValue: "nonsense") == nil)
    }

    /// The 0.2.0 crash: the inspector outlived the channel it showed.
    @Test func selectionOfDeletedChannelFallsBackToCombined() {
        var show = ShowDocument()
        let channel = show.addChannel()
        let selection = SidebarItem.channel(channel.id)
        #expect(selection.validated(in: show) == selection)

        show.deleteChannel(id: channel.id)

        #expect(selection.validated(in: show) == .combined)
    }

    @Test func selectionOfDeletedGroupFallsBackToCombined() {
        var show = ShowDocument()
        let group = show.addGroup()
        let item = SidebarItem.group(group.id)
        #expect(item.validated(in: show) == item)
        show.deleteGroup(id: group.id)
        #expect(item.validated(in: show) == .combined)
    }

    @Test func channelSelectionSurvivesDeletingItsGroup() {
        var show = ShowDocument()
        let group = show.addGroup()
        let channel = show.addChannel()
        show.assignChannel(channel.id, toGroup: group.id)
        show.deleteGroup(id: group.id)
        #expect(SidebarItem.channel(channel.id).validated(in: show) == .channel(channel.id))
    }

    @Test func groupStorageValueNamesTheGroup() {
        let id = UUID()
        #expect(SidebarItem.group(id).storageValue == "group:\(id.uuidString)")
    }
}

@Suite("Capture restarts")
struct CaptureRestartTests {
    @Test func reorderingChannelsKeepsTheSameInputs() {
        var show = ShowDocument()
        for _ in 0..<3 { show.addChannel() }
        let before = show
        show.moveChannels(fromOffsets: [0], toOffset: 3)
        #expect(show.capturesSameInputs(as: before))
    }

    @Test func changingAGroupKeepsTheSameInputs() {
        var show = ShowDocument()
        let channel = show.addChannel()
        let before = show
        show.updateChannel(id: channel.id) { $0.groupID = UUID() }
        #expect(show.capturesSameInputs(as: before))
    }

    @Test func repatchingAChannelChangesTheInputs() {
        var show = ShowDocument()
        let channel = show.addChannel()
        let before = show
        show.updateChannel(id: channel.id) { $0.deviceChannel = 7 }
        #expect(!show.capturesSameInputs(as: before))
    }

    @Test func translatingSwitchesLanguageToDetectAutomatically() {
        var channel = ChannelConfig(name: "Radio", localeIdentifier: "fr_FR", engine: .whisper)

        channel.setTranslateToEnglish(true)

        #expect(channel.translateToEnglish)
        #expect(channel.localeIdentifier == ChannelConfig.detectLanguageAutomatically)
        #expect(ChannelConfig.detectLanguageAutomatically == "")
    }

    @Test func turningTranslationOffKeepsTheLanguage() {
        var channel = ChannelConfig(name: "Radio", localeIdentifier: "", engine: .whisper, translateToEnglish: true)
        channel.localeIdentifier = "de_DE"  // picked by hand while translating

        channel.setTranslateToEnglish(false)

        #expect(!channel.translateToEnglish)
        #expect(channel.localeIdentifier == "de_DE")
    }
}
