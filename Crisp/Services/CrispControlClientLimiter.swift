import Dispatch

final class CrispControlClientLimiter: @unchecked Sendable {
    private let slots: DispatchSemaphore

    init(limit: Int) {
        precondition(limit > 0)
        slots = DispatchSemaphore(value: limit)
    }

    func acquire() -> Bool {
        slots.wait(timeout: .now()) == .success
    }

    func release() {
        slots.signal()
    }
}
