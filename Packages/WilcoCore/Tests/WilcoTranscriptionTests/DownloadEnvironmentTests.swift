import Foundation
import Testing
@testable import WilcoTranscription

@Suite("Download environment")
struct DownloadEnvironmentTests {
    /// Each of these, when set, moves model downloads to another server or
    /// attaches an account token to them.
    @Test func lockDownClearsEveryOverride() {
        for name in DownloadEnvironment.variables { setenv(name, "https://elsewhere.example", 1) }
        DownloadEnvironment.lockDown()
        for name in DownloadEnvironment.variables {
            #expect(ProcessInfo.processInfo.environment[name] == nil)
        }
    }
}
