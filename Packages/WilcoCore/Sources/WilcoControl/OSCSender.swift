import Foundation
import Network
import WilcoCore

/// Sends OSC to destinations, keeping one connection per destination open
/// between sends. A connection is rebuilt when its destination's address or
/// transport changes, or after it fails.
public actor OSCSender {
    public struct SendError: LocalizedError {
        public let errorDescription: String?
    }

    private struct Open {
        var destination: OSCDestination
        var connection: NWConnection
    }

    private var open: [OSCDestination.ID: Open] = [:]
    private let queue = DispatchQueue(label: "io.github.ic3burg.wilco.osc")
    /// A send that has not completed by then is reported as failed; an
    /// unreachable TCP console otherwise leaves it waiting indefinitely.
    private let timeout: Duration

    public init(timeout: Duration = .seconds(2)) {
        self.timeout = timeout
    }

    public func send(_ message: OSCMessage, to destination: OSCDestination) async throws {
        let connection = connection(for: destination)
        let packet = OSCFraming.frame(message.encoded(), for: destination.transport)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    // Cancelling a task doesn't resume its continuation, and
                    // the group can't return until this child does. Cancelling
                    // the connection completes the pending send, which does.
                    try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                            connection.send(content: packet, completion: .contentProcessed { error in
                                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                            })
                        }
                    } onCancel: {
                        connection.cancel()
                    }
                }
                group.addTask { [timeout] in
                    try await Task.sleep(for: timeout)
                    throw SendError(errorDescription: "No response from \(destination.host):\(destination.port)")
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            close(destination.id)
            throw error
        }
    }

    /// Closes connections to destinations no longer in the show.
    public func keepOnly(_ destinations: [OSCDestination]) {
        let ids = Set(destinations.map(\.id))
        for id in open.keys where !ids.contains(id) { close(id) }
    }

    public func closeAll() {
        for id in open.keys { close(id) }
    }

    private func connection(for destination: OSCDestination) -> NWConnection {
        if let existing = open[destination.id] {
            let same = existing.destination.host == destination.host
                && existing.destination.port == destination.port
                && existing.destination.transport == destination.transport
            if same, existing.connection.state != .cancelled { return existing.connection }
            close(destination.id)
        }
        let parameters: NWParameters = destination.transport == .udp ? .udp : .tcp
        let connection = NWConnection(
            host: NWEndpoint.Host(destination.host),
            port: NWEndpoint.Port(rawValue: destination.port) ?? .any,
            using: parameters
        )
        let id = destination.id
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                Task { await self?.close(id) }
            }
        }
        connection.start(queue: queue)
        open[destination.id] = Open(destination: destination, connection: connection)
        return connection
    }

    private func close(_ id: OSCDestination.ID) {
        open.removeValue(forKey: id)?.connection.cancel()
    }
}
