import Foundation

@MainActor
public final class BrightnessHeartbeatController {
    private var operation: Task<Void, Never>?

    public init() {}

    public var isRefreshing: Bool { operation != nil }

    @discardableResult
    public func schedule<Display>(
        displays: [Display],
        panelVisible: Bool,
        autoBrightnessEnabled: Bool,
        lastManualAdjustment: Date?,
        now: Date = Date(),
        isBuiltin: @escaping @MainActor (Display) -> Bool,
        prepare: @escaping @MainActor () -> Void,
        refresh: @escaping @MainActor (Display) async -> Void
    ) -> Bool {
        guard operation == nil else { return false }
        let task = Task { @MainActor [weak self] in
            defer { self?.operation = nil }
            guard !Task.isCancelled else { return }
            await BrightnessHeartbeat.refresh(
                displays: displays,
                panelVisible: panelVisible,
                autoBrightnessEnabled: autoBrightnessEnabled,
                lastManualAdjustment: lastManualAdjustment,
                now: now,
                isBuiltin: isBuiltin,
                prepare: prepare,
                refresh: refresh
            )
        }
        operation = task
        return true
    }

    public func cancel() {
        // Keep the task occupying the single-flight slot until it actually
        // returns. Callback-backed display reads may not honor cancellation;
        // allowing a replacement task immediately would reintroduce stale
        // completion ordering on a quick close/reopen.
        operation?.cancel()
    }

    public func waitUntilIdle() async {
        let current = operation
        await current?.value
    }
}
