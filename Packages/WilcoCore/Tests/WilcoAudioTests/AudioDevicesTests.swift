import Foundation
import Testing
@testable import WilcoAudio

/// Reads real hardware, so results depend on the Mac. Enumeration needs no
/// microphone permission.
@Suite("Audio devices")
struct AudioDevicesTests {
    @Test func everyListedDeviceHasNamedInputs() {
        for device in AudioDevices.inputDevices() {
            #expect(device.inputChannels > 0)
            #expect(device.channelNames.count == device.inputChannels)
            #expect(!device.id.isEmpty)
        }
    }

    @Test func defaultInputIsListed() {
        guard let uid = AudioDevices.defaultInputUID() else { return }
        #expect(AudioDevices.inputDevices().contains { $0.id == uid })
    }

    @Test func statusCodesReadAsFourCharacters() {
        #expect(OSStatus(bitPattern: 0x2164_6576).fourCharacterCode == "'!dev'")
        #expect(OSStatus(-50).fourCharacterCode == String(UInt32(bitPattern: -50)))
    }
}
