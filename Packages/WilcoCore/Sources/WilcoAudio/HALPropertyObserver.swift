import CoreAudio
import Dispatch

/// Calls `handler` on `queue` whenever a CoreAudio property changes, until
/// the observer is released.
final class HALPropertyObserver {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock

    init(object: AudioObjectID, address: AudioObjectPropertyAddress, queue: DispatchQueue, handler: @escaping () -> Void) {
        self.object = object
        self.address = address
        self.queue = queue
        block = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(object, &self.address, queue, block)
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }
}
