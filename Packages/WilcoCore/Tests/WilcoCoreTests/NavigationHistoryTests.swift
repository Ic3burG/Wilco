import Testing
@testable import WilcoCore

@Suite("Back and forward history")
struct NavigationHistoryTests {
    @Test func startsWithNowhereToGo() {
        let history = NavigationHistory<SettingsPage>()
        #expect(!history.canGoBack)
        #expect(!history.canGoForward)
    }

    @Test func backReturnsThePreviousPageAndForwardUndoesIt() {
        var history = NavigationHistory<SettingsPage>()
        history.visit(from: .audio, to: .speech)
        history.visit(from: .speech, to: .rules)

        #expect(history.goBack(from: .rules) == .speech)
        #expect(history.goBack(from: .speech) == .audio)
        #expect(!history.canGoBack)
        #expect(history.goBack(from: .audio) == nil)

        #expect(history.goForward(from: .audio) == .speech)
        #expect(history.goForward(from: .speech) == .rules)
        #expect(!history.canGoForward)
        #expect(history.goForward(from: .rules) == nil)
    }

    @Test func visitingAfterGoingBackDropsTheForwardPages() {
        var history = NavigationHistory<SettingsPage>()
        history.visit(from: .audio, to: .speech)
        _ = history.goBack(from: .speech)
        #expect(history.canGoForward)

        history.visit(from: .audio, to: .markers)
        #expect(!history.canGoForward)
        #expect(history.goBack(from: .markers) == .audio)
    }

    @Test func reselectingTheSamePageIsNotAVisit() {
        var history = NavigationHistory<SettingsPage>()
        history.visit(from: .audio, to: .audio)
        #expect(!history.canGoBack)
    }

    @Test func keepsOnlyTheMostRecentPages() {
        var history = NavigationHistory<Int>(limit: 3)
        for page in 0..<10 { history.visit(from: page, to: page + 1) }
        #expect(history.goBack(from: 10) == 9)
        #expect(history.goBack(from: 9) == 8)
        #expect(history.goBack(from: 8) == 7)
        #expect(history.goBack(from: 7) == nil)
    }
}
