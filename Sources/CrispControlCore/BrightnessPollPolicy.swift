import Foundation

public enum BrightnessPollPolicy {
    public static func shouldRefresh(isBuiltin: Bool, autoBrightnessEnabled: Bool) -> Bool {
        isBuiltin || !autoBrightnessEnabled
    }
}

public enum BrightnessHeartbeat {
    public static let manualAdjustmentSuppression: TimeInterval = 3

    @MainActor
    public static func refresh<Display>(
        displays: [Display],
        panelVisible: Bool,
        autoBrightnessEnabled: Bool,
        lastManualAdjustment: Date?,
        now: Date = Date(),
        isBuiltin: @MainActor (Display) -> Bool,
        prepare: @MainActor () -> Void = {},
        refresh: @MainActor (Display) async -> Void
    ) async {
        guard !Task.isCancelled else { return }
        guard panelVisible else { return }
        if let lastManualAdjustment,
           now.timeIntervalSince(lastManualAdjustment) < manualAdjustmentSuppression {
            return
        }
        guard !Task.isCancelled else { return }
        prepare()
        for display in displays where BrightnessPollPolicy.shouldRefresh(
            isBuiltin: isBuiltin(display),
            autoBrightnessEnabled: autoBrightnessEnabled
        ) {
            guard !Task.isCancelled else { return }
            await refresh(display)
        }
    }
}
