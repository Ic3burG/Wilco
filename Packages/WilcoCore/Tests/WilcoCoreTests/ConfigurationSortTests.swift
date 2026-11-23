import Foundation
import Testing
@testable import WilcoCore

@Suite("Configuration sort")
struct ConfigurationSortTests {
    private let list = [
        ConfigurationSummary(id: UUID(), name: "Show 10", channelCount: 4, savedAt: Date(timeIntervalSince1970: 300), createdAt: Date(timeIntervalSince1970: 30)),
        ConfigurationSummary(id: UUID(), name: "arena", channelCount: 8, savedAt: Date(timeIntervalSince1970: 100), createdAt: Date(timeIntervalSince1970: 50)),
        ConfigurationSummary(id: UUID(), name: "Show 2", channelCount: 4, savedAt: Date(timeIntervalSince1970: 200), createdAt: Date(timeIntervalSince1970: 10)),
    ]

    private func names(_ order: [KeyPathComparator<ConfigurationSummary>]) -> [String] {
        ConfigurationSummary.sorted(list, using: order).map(\.name)
    }

    @Test func nameSortsLikeFinder() {
        #expect(names([ConfigurationSummary.nameOrder]) == ["arena", "Show 2", "Show 10"])
        var reverse = ConfigurationSummary.nameOrder
        reverse.order = .reverse
        #expect(names([reverse]) == ["Show 10", "Show 2", "arena"])
    }

    @Test func channelTiesFallBackToName() {
        #expect(names([KeyPathComparator(\.channelCount)]) == ["Show 2", "Show 10", "arena"])
        #expect(names([KeyPathComparator(\.channelCount, order: .reverse)]) == ["arena", "Show 2", "Show 10"])
    }

    @Test func savedSortsByDate() {
        #expect(names([KeyPathComparator(\.savedAt)]) == ["arena", "Show 2", "Show 10"])
        #expect(names([KeyPathComparator(\.savedAt, order: .reverse)]) == ["Show 10", "Show 2", "arena"])
    }

    @Test func createdSortsByCreationNotSave() {
        #expect(names([KeyPathComparator(\.createdAt)]) == ["Show 2", "Show 10", "arena"])
    }

    @Test func emptyOrderIsByName() {
        #expect(names([]) == ["arena", "Show 2", "Show 10"])
    }
}
