import Foundation
import os

/// SDK logging. Never log tokens, visitor keys, push tokens or user details.
enum Log {
    private static let logger = Logger(subsystem: "com.zebchat.sdk", category: "ZebChat")

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    /// `message` is ours; `detail` came from elsewhere (e.g. the chat page) and is redacted in
    /// release logs.
    static func error(_ message: String, detail: String) {
        logger.error("\(message, privacy: .public): \(detail, privacy: .private)")
    }
}

/// ISO 8601 dates as the API writes them (`Date.toISOString()`, with or without fractions).
enum ISODate {
    static func parse(_ text: String) -> Date? {
        let withFractions = ISO8601DateFormatter()
        withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractions.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

/// Checks on values decoded by `JSONSerialization`, mirroring the guards in
/// `packages/types/src/mobile.ts` (JavaScript string lengths are UTF-16 code units).
enum JSONValue {
    /// A non-empty string of at most `max` UTF-16 code units.
    static func text(_ value: Any?, max: Int) -> String? {
        guard let string = value as? String, !string.isEmpty, string.utf16.count <= max else { return nil }
        return string
    }

    /// An ISO 8601 date string (at most 40 characters).
    static func isoDate(_ value: Any?) -> String? {
        guard let string = text(value, max: 40), ISODate.parse(string) != nil else { return nil }
        return string
    }

    /// A JSON integer (`Number.isInteger`); booleans are rejected even though they bridge to NSNumber.
    static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double.rounded() == double, abs(double) <= 9_007_199_254_740_991 else {
            return nil
        }
        return Int(double)
    }

    static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

/// Runs async operations one at a time, in the order they were enqueued. Every state change of a
/// `ZebChatClient` goes through one of these, so the session logic never interleaves.
final class SerialTaskQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    @discardableResult
    func enqueue<T: Sendable>(_ operation: @escaping @Sendable () async -> T) -> Task<T, Never> {
        lock.lock()
        defer { lock.unlock() }
        let previous = tail
        let task = Task<T, Never> {
            if let previous {
                await previous.value
            }
            return await operation()
        }
        tail = Task {
            _ = await task.value
        }
        return task
    }
}

/// A value guarded by a lock, readable and writable from any thread.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    @discardableResult
    func update<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
