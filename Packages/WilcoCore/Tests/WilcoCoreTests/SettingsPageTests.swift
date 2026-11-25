import Testing
@testable import WilcoCore

@Suite("Settings pages and search")
struct SettingsPageTests {
    @Test func showPagesComeInSetupOrderThenMacPages() {
        #expect(SettingsPage.allCases.filter { $0.area == .show }
            == [.audio, .speech, .destinations, .rules, .markers])
        #expect(SettingsPage.allCases.filter { $0.area == .mac }
            == [.general, .appearance, .speechModels, .learning])
    }

    @Test func unknownStoredPageFallsBackToAudio() {
        #expect(SettingsPage.restored(from: nil) == .audio)
        #expect(SettingsPage.restored(from: "languages") == .audio)
        #expect(SettingsPage.restored(from: "speechModels") == .speechModels)
    }

    @Test func everyPageHasAnIndexEntry() {
        #expect(Set(SettingsIndex.entries.map(\.page)) == Set(SettingsPage.allCases))
    }

    @Test func searchMatchesWordPrefixesIgnoringCaseAndAccents() {
        #expect(SettingsIndex.search("voc").contains { $0.title == "Vocabulary" && $0.page == .speech })
        #expect(SettingsIndex.search("VOCAB").contains { $0.title == "Vocabulary" })
        #expect(SettingsIndex.search("voíce").contains { $0.page == .speech })
        #expect(SettingsIndex.search("osc").contains { $0.page == .destinations })
        #expect(SettingsIndex.search("text size").map(\.page) == [.appearance])
    }

    @Test func blankOrUnmatchedQueriesFindNothing() {
        #expect(SettingsIndex.search("").isEmpty)
        #expect(SettingsIndex.search("   ").isEmpty)
        #expect(SettingsIndex.search("›").isEmpty)
        #expect(SettingsIndex.search("zzqx").isEmpty)
    }
}
