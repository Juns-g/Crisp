import Foundation

enum CGOperationOutcome<Value: Sendable>: Sendable {
    case completed(Value)
    case timedOut
    case cancelled
}

/// Shared utilities for wrapping blocking CoreGraphics calls.
enum CGHelpers {

    /// Runs a blocking operation on a background thread with a timeout.
    ///
    /// The operation is dispatched to a `.userInitiated` global queue. If it
    /// completes within `seconds`, its return value is forwarded. If the
    /// deadline fires first, `fallback` is returned instead.
    ///
    /// This is useful for any CoreGraphics / WindowServer IPC call that can
    /// hang indefinitely (e.g. `CGCompleteDisplayConfiguration`,
    /// `CGVirtualDisplay.apply(_:)`).
    ///
    /// - Parameters:
    ///   - seconds:   Maximum time to wait before returning `fallback`.
    ///   - fallback:  Value returned on timeout.
    ///   - operation: The blocking work to execute off-thread.
    /// - Returns: The operation's result, or `fallback` on timeout.
    static func runWithTimeout<T: Sendable>(
        seconds: Double,
        fallback: T,
        operation: @escaping @Sendable () -> T
    ) async -> T {
        switch await runWithTimeoutOutcome(seconds: seconds, operation: operation) {
        case let .completed(value): value
        case .timedOut, .cancelled: fallback
        }
    }

    /// Unlike the compatibility wrapper above, this preserves whether the language-level
    /// wait timed out or was cancelled. The queued blocking operation is intentionally not
    /// described as cancelled: Dispatch/WindowServer work may continue after either event.
    static func runWithTimeoutOutcome<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () -> T
    ) async -> CGOperationOutcome<T> {
        guard !Task.isCancelled else { return .cancelled }
        let race = CGOperationRace<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)
                DispatchQueue.global(qos: .userInitiated).async {
                    race.resolve(.completed(operation()))
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + max(0, seconds)) {
                    race.resolve(.timedOut)
                }
            }
        } onCancel: {
            race.resolve(.cancelled)
        }
    }
}

private final class CGOperationRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: CGOperationOutcome<Value>?
    private var continuation: CheckedContinuation<CGOperationOutcome<Value>, Never>?

    func install(_ continuation: CheckedContinuation<CGOperationOutcome<Value>, Never>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(returning: outcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ outcome: CGOperationOutcome<Value>) {
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return
        }
        self.outcome = outcome
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: outcome)
    }
}
