import Foundation
@testable import WilcoCore

/// Channels A, B, C, D and groups [Radios, Stage]:
/// A → Stage, B ungrouped, C → Radios, D → Radios.
struct GroupedShow {
    var show = ShowDocument()
    let a: ChannelConfig, b: ChannelConfig, c: ChannelConfig, d: ChannelConfig
    let radios: ChannelGroup, stage: ChannelGroup

    init() {
        let radios = ChannelGroup(name: "Radios", symbol: "folder")
        let stage = ChannelGroup(name: "Stage", symbol: "folder")
        let a = ChannelConfig(name: "A", deviceChannel: 0, groupID: stage.id)
        let b = ChannelConfig(name: "B", deviceChannel: 1)
        let c = ChannelConfig(name: "C", deviceChannel: 2, groupID: radios.id)
        let d = ChannelConfig(name: "D", deviceChannel: 3, groupID: radios.id)
        show.groups = [radios, stage]
        show.channels = [a, b, c, d]
        (self.a, self.b, self.c, self.d) = (a, b, c, d)
        (self.radios, self.stage) = (radios, stage)
    }
}
