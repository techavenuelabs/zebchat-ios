import Foundation

/// The visitor's unread count and its listeners. Thread-safe; listeners are called on the main thread.
final class UnreadCenter: @unchecked Sendable {
    static let shared = UnreadCenter()

    private let lock = NSLock()
    private var listeners: [ZebChatListenerToken: (Int) -> Void] = [:]
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Registers `listener` and calls it with the current count.
    func add(_ listener: @escaping (Int) -> Void) -> ZebChatListenerToken {
        let token = ZebChatListenerToken(id: UUID())
        lock.lock()
        listeners[token] = listener
        let current = value
        lock.unlock()
        deliver(current, to: [token])
        return token
    }

    func remove(_ token: ZebChatListenerToken) {
        lock.lock()
        listeners[token] = nil
        lock.unlock()
    }

    /// Stores a new count and notifies the listeners when it changed.
    func update(_ newValue: Int) {
        let clamped = max(0, newValue)
        lock.lock()
        guard clamped != value else {
            lock.unlock()
            return
        }
        value = clamped
        let tokens = Array(listeners.keys)
        lock.unlock()
        deliver(clamped, to: tokens)
    }

    private func listener(for token: ZebChatListenerToken) -> ((Int) -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return listeners[token]
    }

    /// Calls each listener on the main thread, unless it was removed in the meantime.
    private func deliver(_ count: Int, to tokens: [ZebChatListenerToken]) {
        DispatchQueue.main.async {
            for token in tokens {
                self.listener(for: token)?(count)
            }
        }
    }
}
