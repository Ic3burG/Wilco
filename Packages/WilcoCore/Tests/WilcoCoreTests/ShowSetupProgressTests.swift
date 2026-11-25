import Testing
@testable import WilcoCore

@Suite("Show setup ticks")
struct ShowSetupProgressTests {
    private func ticked(_ page: SettingsPage, _ show: ShowDocument,
                        connected: Set<String> = [],
                        installed: (SpeechEngine, String) -> Bool = { _, _ in true }) -> Bool {
        ShowSetupProgress.isSetUp(page, show: show, connectedDeviceUIDs: connected, isInstalled: installed)
    }

    @Test func audioNeedsAChannelAndAConnectedDevice() {
        var show = ShowDocument(name: "Show")
        #expect(!ticked(.audio, show))

        show.channels = [ChannelConfig(name: "SM")]
        #expect(ticked(.audio, show))

        show.deviceUID = "X"
        #expect(!ticked(.audio, show, connected: []))
        #expect(ticked(.audio, show, connected: ["X"]))
    }

    @Test func speechNeedsEveryChannelModelInstalled() {
        var show = ShowDocument(name: "Show")
        #expect(!ticked(.speech, show))

        show.channels = [
            ChannelConfig(name: "SM", localeIdentifier: "en-US", engine: .parakeet),
            ChannelConfig(name: "LX", localeIdentifier: "", engine: .longForm),
        ]
        #expect(!ticked(.speech, show, installed: { engine, _ in engine == .parakeet }))

        var asked: [String] = []
        #expect(ticked(.speech, show, installed: { engine, locale in
            asked.append("\(engine.rawValue)|\(locale)")
            return true
        }))
        #expect(asked.contains("longForm|"))
        #expect(asked.contains("parakeet|en-US"))
    }

    @Test func destinationsNeedOneEnabled() {
        var show = ShowDocument(name: "Show")
        show.destinations = [OSCDestination(name: "Console", host: "192.168.1.20", port: 8000, isEnabled: false)]
        #expect(!ticked(.destinations, show))
        show.destinations[0].isEnabled = true
        #expect(ticked(.destinations, show))
    }

    @Test func rulesOrHighlightsCount() {
        var show = ShowDocument(name: "Show")
        #expect(!ticked(.rules, show))

        show.highlights = [HighlightRule(name: "Names", phrases: ["Sam"])]
        #expect(ticked(.rules, show))

        var shared = ShowDocument(name: "Shared")
        shared.destinations = [OSCDestination(name: "Console", host: "192.168.1.20", port: 8000)]
        shared.rules = [AutomationRule(name: "Everything", phrases: [".*"], matchMode: .regularExpression,
                                       actions: [.webhook(urlTemplate: "https://collect.example.com/in", method: "POST", bodyTemplate: "")])]
        let imported = OutboundRules.turningOff(in: shared).show
        #expect(!ticked(.rules, imported))
        #expect(ticked(.destinations, imported))
    }

    @Test func markersAndMacPagesNeverTick() {
        var show = ShowDocument(name: "Show")
        show.channels = [ChannelConfig(name: "SM")]
        show.destinations = [OSCDestination(name: "Console", host: "192.168.1.20", port: 8000)]
        show.highlights = [HighlightRule(name: "Names", phrases: ["Sam"])]
        for page in [SettingsPage.markers, .general, .appearance, .speechModels, .learning] {
            #expect(!ticked(page, show))
        }
    }
}
