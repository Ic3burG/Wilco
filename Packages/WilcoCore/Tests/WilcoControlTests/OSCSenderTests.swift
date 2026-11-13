import Foundation
import Network
import Synchronization
import Testing
@testable import WilcoControl
import WilcoCore

/// Sends real packets to a listener on this Mac.
@Suite("OSC sender")
struct OSCSenderTests {
    /// Collects everything received on a localhost port.
    private final class Receiver: Sendable {
        let listener: NWListener
        let received = Mutex(Data())
        private let queue = DispatchQueue(label: "test.osc.receiver")

        init(udp: Bool) throws {
            listener = try NWListener(using: udp ? .udp : .tcp, on: .any)
            listener.newConnectionHandler = { [self] connection in
                connection.start(queue: queue)
                receive(on: connection)
            }
        }

        private func receive(on connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, _, error in
                if let data { received.withLock { $0.append(data) } }
                if error == nil { receive(on: connection) }
            }
        }

        func start() async throws -> UInt16 {
            listener.start(queue: queue)
            for _ in 0..<100 {
                if let port = listener.port?.rawValue, port != 0 { return port }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CancellationError()
        }

        func bytes(atLeast count: Int) async throws -> [UInt8] {
            for _ in 0..<200 {
                let data = received.withLock { $0 }
                if data.count >= count { return [UInt8](data) }
                try await Task.sleep(for: .milliseconds(10))
            }
            return [UInt8](received.withLock { $0 })
        }
    }

    private let message = OSCMessage(address: "/wilco/go", arguments: [.string("Stage")])

    @Test func sendsOverUDP() async throws {
        let receiver = try Receiver(udp: true)
        let port = try await receiver.start()
        let sender = OSCSender()

        try await sender.send(message, to: OSCDestination(name: "Test", host: "127.0.0.1", port: port, transport: .udp))

        let expected = [UInt8](message.encoded())
        #expect(try await receiver.bytes(atLeast: expected.count) == expected)
        await sender.closeAll()
    }

    @Test func sendsSLIPFramedOverTCP() async throws {
        let receiver = try Receiver(udp: false)
        let port = try await receiver.start()
        let sender = OSCSender()
        let destination = OSCDestination(name: "Test", host: "127.0.0.1", port: port, transport: .tcpSLIP)

        try await sender.send(message, to: destination)
        try await sender.send(message, to: destination)

        let frame = [UInt8](OSCFraming.frame(message.encoded(), for: .tcpSLIP))
        #expect(try await receiver.bytes(atLeast: frame.count * 2) == frame + frame)
        await sender.closeAll()
    }

    @Test func unreachableTCPDestinationReportsAnError() async {
        let sender = OSCSender(timeout: .milliseconds(500))
        // Port 1 on localhost: nothing listens there.
        let destination = OSCDestination(name: "Nobody", host: "127.0.0.1", port: 1, transport: .tcpLengthPrefixed)
        await #expect(throws: (any Error).self) {
            try await sender.send(message, to: destination)
        }
    }

    /// 192.0.2.1 is reserved for documentation and never answers, so the
    /// connection sits waiting rather than being refused: the timeout has
    /// to end the send itself.
    @Test(.timeLimit(.minutes(1)))
    func silentTCPDestinationTimesOut() async {
        let sender = OSCSender(timeout: .milliseconds(500))
        let destination = OSCDestination(name: "Silent", host: "192.0.2.1", port: 3_032, transport: .tcpLengthPrefixed)
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            try await sender.send(message, to: destination)
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}

@Suite("MIDI output")
struct MIDIOutputTests {
    @Test func listsDestinationsWithNames() {
        for destination in MIDIOutput.destinations() {
            #expect(!destination.name.isEmpty)
        }
    }

    @Test func unknownDestinationIsAnError() {
        #expect(throws: (any Error).self) {
            try MIDIOutput().send(.noteOn(channel: 1, note: 60, velocity: 100), to: 0x7FFF_FFF0)
        }
    }
}
