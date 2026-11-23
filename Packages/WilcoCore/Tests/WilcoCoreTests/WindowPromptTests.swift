import Testing
@testable import WilcoCore

@Suite("Window prompt")
struct WindowPromptTests {
    /// Regression: loading a configuration with unsaved edits did nothing.
    /// The save-first alert opened, its window stopped appearing active, the
    /// alert closed itself and the load request was dropped.
    @Test func staysOpenWhenItsWindowStopsAppearingActive() {
        var prompt = WindowPrompt()
        prompt.requestChanged(isRequested: true, appearsActive: true)
        #expect(prompt.isPresented)

        // The alert takes focus, so the window no longer appears active.
        prompt.requestChanged(isRequested: true, appearsActive: false)
        #expect(prompt.isPresented)
    }

    @Test func onlyTheActiveWindowOpensIt() {
        var active = WindowPrompt()
        var background = WindowPrompt()
        active.requestChanged(isRequested: true, appearsActive: true)
        background.requestChanged(isRequested: true, appearsActive: false)
        #expect(active.isPresented)
        #expect(!background.isPresented)
    }

    @Test func closesWhenTheRequestEnds() {
        var prompt = WindowPrompt()
        prompt.requestChanged(isRequested: true, appearsActive: true)
        prompt.requestChanged(isRequested: false, appearsActive: true)
        #expect(!prompt.isPresented)

        prompt.requestChanged(isRequested: true, appearsActive: true)
        prompt.dismissed()
        #expect(!prompt.isPresented)
    }
}
