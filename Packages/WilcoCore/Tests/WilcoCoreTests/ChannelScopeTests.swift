import Foundation
import Testing
@testable import WilcoCore

@Suite("Channel scope")
struct ChannelScopeTests {
    @Test func groupScopeIncludesOnlyItsChannels() {
        let f = GroupedShow()
        let scope = ChannelScope.group(f.radios.id)
        #expect(scope.includes(f.c.id, in: f.show, narrowedTo: []))
        #expect(scope.includes(f.d.id, in: f.show, narrowedTo: []))
        #expect(!scope.includes(f.a.id, in: f.show, narrowedTo: []))
        #expect(scope.channels(in: f.show).map(\.name) == ["C", "D"])
    }

    @Test func groupChipsNarrowWithinTheGroup() {
        let f = GroupedShow()
        let scope = ChannelScope.group(f.radios.id)
        #expect(scope.includes(f.c.id, in: f.show, narrowedTo: [f.c.id]))
        #expect(!scope.includes(f.d.id, in: f.show, narrowedTo: [f.c.id]))
    }

    @Test func chipsOutsideTheGroupDoNotWidenIt() {
        let f = GroupedShow()
        #expect(!ChannelScope.group(f.radios.id).includes(f.a.id, in: f.show, narrowedTo: [f.a.id]))
    }

    @Test func emptyGroupHasNoChannels() {
        var f = GroupedShow()
        let empty = f.show.addGroup()
        #expect(ChannelScope.group(empty.id).channels(in: f.show).isEmpty)
        #expect(!ChannelScope.group(empty.id).includes(f.a.id, in: f.show, narrowedTo: []))
    }

    @Test func missingGroupHasNoChannels() {
        let f = GroupedShow()
        #expect(ChannelScope.group(UUID()).channels(in: f.show).isEmpty)
    }

    @Test func channelScopeIgnoresChips() {
        let f = GroupedShow()
        let scope = ChannelScope.channel(f.a.id)
        #expect(scope.includes(f.a.id, in: f.show, narrowedTo: [f.b.id]))
        #expect(!scope.includes(f.b.id, in: f.show, narrowedTo: [f.b.id]))
        #expect(scope.channels(in: f.show).map(\.name) == ["A"])
    }

    @Test func channellessMarkersShowInAllAndGroupButNotChannel() {
        let f = GroupedShow()
        #expect(ChannelScope.all.includes(nil, in: f.show, narrowedTo: [f.a.id]))
        #expect(ChannelScope.group(f.radios.id).includes(nil, in: f.show, narrowedTo: []))
        #expect(!ChannelScope.channel(f.a.id).includes(nil, in: f.show, narrowedTo: []))
    }

    @Test func allScopeFollowsDisplayOrderAndChips() {
        let f = GroupedShow()
        #expect(ChannelScope.all.channels(in: f.show).map(\.id) == f.show.channelsInDisplayOrder.map(\.id))
        #expect(ChannelScope.all.includes(f.a.id, in: f.show, narrowedTo: []))
        #expect(!ChannelScope.all.includes(f.a.id, in: f.show, narrowedTo: [f.b.id]))
    }

    /// A chip left on for a channel that has since left the group (or been
    /// deleted) must not blank the view.
    @Test func chipsForChannelsOutOfScopeAreIgnored() {
        let f = GroupedShow()
        #expect(ChannelScope.group(f.radios.id).includes(f.c.id, in: f.show, narrowedTo: [f.a.id]))
        #expect(ChannelScope.all.includes(f.a.id, in: f.show, narrowedTo: [UUID()]))
    }

    /// Review finding: per-line `includes` was too slow for long shows. The
    /// resolved filter must agree with it everywhere.
    @Test func resolvedFilterAgreesWithIncludes() {
        var f = GroupedShow()
        let empty = f.show.addGroup()
        let scopes: [ChannelScope] = [.all, .channel(f.a.id), .group(f.radios.id), .group(empty.id), .group(UUID())]
        let chipSets: [Set<UUID>] = [[], [f.c.id], [f.a.id], [UUID()], [f.c.id, f.a.id]]
        let ids: [UUID?] = [nil, f.a.id, f.b.id, f.c.id, f.d.id, UUID()]
        for scope in scopes {
            for chips in chipSets {
                let filter = scope.filter(in: f.show, narrowedTo: chips)
                for id in ids {
                    #expect(filter.includes(id) == scope.includes(id, in: f.show, narrowedTo: chips),
                            "\(scope) chips \(chips) id \(String(describing: id))")
                }
            }
        }
    }
}
