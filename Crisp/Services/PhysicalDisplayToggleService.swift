import Foundation
import CoreGraphics
import ColorSync
import IOKit
#if canImport(CrispControlCore)
import CrispControlCore
#endif

@_silgen_name("CGDisplayIOServicePort")
private func CGDisplayIOServicePortForPhysicalProof(
    _ display: CGDirectDisplayID
) -> io_service_t

/// Disconnects / reconnects REAL (physical) displays on the fly, the way BetterDisplay's
/// "Disconnect Display" works. This is fundamentally different from VirtualDisplayService:
/// there we create/destroy a CGVirtualDisplay object; here we toggle an existing hardware
/// display in/out of the layout via the private SkyLight API `SLSConfigureDisplayEnabled`.
///
/// PLATFORM: Apple Silicon + macOS 13+ ONLY. On Intel the API does not perform a true
/// disconnect. Everything is gated behind `isSupported`.
///
/// KEY QUIRK: once a display is disabled it disappears from `CGGetOnlineDisplayList`
/// (and `CGGetActiveDisplayList`). To reconnect it we must find it again via
/// `SLSGetDisplayList`, which still enumerates disabled displays. Because the disconnected
/// display is also gone from DisplayManager's list, this service keeps its own snapshot
/// (`disconnected`) of what we turned off so the UI can still offer a Reconnect action.
@MainActor
final class PhysicalDisplayToggleService: ObservableObject, DisplayConnectionMutationAdapter {
    static let shared = PhysicalDisplayToggleService()
    private init() {
        loadDesired()
    }

    /// Snapshot of a display we disconnected, kept because a disconnected display no longer
    /// appears in DisplayManager.displays, so we need its metadata to render a Reconnect row.
    struct DisconnectedDisplay: Identifiable, Codable, Sendable, Equatable {
        let uuid: String            // stable identity across CGDirectDisplayID reassignment
        var displayID: CGDirectDisplayID  // last-known ID (all-black emergency recovery only)
        var name: String
        var width: Int
        var height: Int
        var id: String { uuid }
    }

    enum ToggleError: Error, Sendable, CustomStringConvertible {
        case unsupportedPlatform
        case wouldLeaveNoActiveDisplay
        case configurationFailed(CGError)
        case outcomeIndeterminate
        case displayNotFound
        case hardwareBackingUnproven

        var description: String {
            switch self {
            case .unsupportedPlatform:
                return String(localized: "Physical display disconnect requires Apple Silicon (macOS 13+).")
            case .wouldLeaveNoActiveDisplay:
                return String(localized: "Refusing to disconnect: it would leave no active display.")
            case .configurationFailed(let err):
                return String(localized: "Display configuration failed (CGError \(String(err.rawValue))).")
            case .outcomeIndeterminate:
                return String(localized: "Display configuration may still complete; refresh before deciding again.")
            case .displayNotFound:
                return String(localized: "Display not found.")
            case .hardwareBackingUnproven:
                return String(localized: "Display cannot be proven to be hardware-backed physical.")
            }
        }
    }

    private enum ConfigurationTransactionOutcome: Sendable {
        case completed
        case rejectedBeforeDispatch(CGError)
        case failedAfterDispatch(CGError)
        case timedOut
        case cancelled
    }

    private enum ControlEnumerationError: Error {
        case fullListFailed(CGError)
        case onlineListFailed(CGError)
        case activeListFailed(CGError)
        case persistenceFailed
    }

    // MARK: - State

    /// Displays the user has disconnected and can reconnect. Persisted (by UUID) so wake and
    /// relaunch can restore the intended state.
    @Published private(set) var disconnected: [DisconnectedDisplay] = []

    private let desiredKey = "crisp.PhysicalDisconnectedUUIDs"
    /// UUIDs whose automation disconnect was prepared but has not yet been proved offline.
    /// The marker is persisted before dispatch. A timed-out WindowServer call may continue,
    /// so normal reconciliation and wake handling must preserve the recovery record until
    /// fresh enumeration proves that exact UUID is offline.
    private let controlPendingDisconnectUUIDsKey =
        "crisp.PhysicalDisplayToggleService.controlPendingDisconnectUUIDs"
    /// Dead-man markers: the UUIDs of displays a softReconnect is (or was, if the app died)
    /// mid-toggle on. A list, not a single slot: a manual smooth-scaling toggle and the
    /// auto-HiDPI path (autoEnableHiDPIIfNeeded) can blink two different displays at once,
    /// and each needs its own marker. See softReconnect / recoverStrandedSoftReconnect.
    private let softReconnectPendingKey = "crisp.PhysicalDisplayToggleService.softReconnectPending"
    /// UUIDs of displays whose softReconnect is mid-blink right now. Their markers above are
    /// legitimately set for that whole window, and the blink's own removeFlag event fires
    /// refreshDisplays (and thus recoverStrandedSoftReconnect) before the toggle finishes;
    /// this keeps the recovery path and the sweep from re-enabling a display out from under
    /// its own retry loop. Per-display, so concurrent blinks don't mask each other.
    private var softReconnectInFlight: Set<String> = []
    /// Guards against overlapping recovery runs from reconfiguration-callback bursts.
    private var strandedRecoveryInFlight = false
    /// Sleep guard parked by a soft reconnect that has not verifiably recovered.
    private var lingeringSleepGuard: CGVirtualDisplay?
    /// Guards against overlapping all-screens-black recovery attempts.
    private var restoreInFlight = false

    /// Portables enforce Clamshell Sleep the moment no display is active; desktops don't.
    /// Battery presence is the lid-independent laptop test.
    private static let hasBattery: Bool = {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }()

    private func pendingControlDisconnectUUIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: controlPendingDisconnectUUIDsKey) ?? [])
    }

    private func persistPendingControlDisconnectUUIDs(_ pending: Set<String>) throws {
        if pending.isEmpty {
            UserDefaults.standard.removeObject(forKey: controlPendingDisconnectUUIDsKey)
        } else {
            UserDefaults.standard.set(pending.sorted(), forKey: controlPendingDisconnectUUIDsKey)
        }
        guard pendingControlDisconnectUUIDs() == pending else {
            throw ControlEnumerationError.persistenceFailed
        }
    }

    private func pendingSoftReconnectUUIDs() -> [String] {
        UserDefaults.standard.stringArray(forKey: softReconnectPendingKey) ?? []
    }

    private func addPendingSoftReconnect(_ displayUUID: String) {
        var pending = pendingSoftReconnectUUIDs()
        guard !pending.contains(displayUUID) else { return }
        pending.append(displayUUID)
        UserDefaults.standard.set(pending, forKey: softReconnectPendingKey)
    }

    private func removePendingSoftReconnect(_ displayUUID: String) {
        let pending = pendingSoftReconnectUUIDs().filter { $0 != displayUUID }
        if pending.isEmpty {
            UserDefaults.standard.removeObject(forKey: softReconnectPendingKey)
        } else {
            UserDefaults.standard.set(pending, forKey: softReconnectPendingKey)
        }
    }

    // MARK: - Support gate

    /// True only on Apple Silicon. The disconnect API is a no-op / misbehaves on Intel.
    let isSupported: Bool = {
        #if arch(arm64)
        if #available(macOS 13.0, *) { return true }
        return false
        #else
        return false
        #endif
    }()

    // MARK: - Queries

    /// True if the display is currently in our disconnected set.
    func isDisconnected(uuid: String) -> Bool {
        disconnected.contains { $0.uuid == uuid }
    }

    /// True if disconnecting `display` right now would leave no *viewable* screen.
    /// Virtual displays are excluded from the count on purpose: they are headless,
    /// so leaving only a virtual display still blacks out the physical machine.
    func wouldLeaveNoActiveDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        PhysicalDisplaySafetyPolicy.shouldRefuseDisconnect(
            targetIsActive: CGDisplayIsActive(displayID) != 0,
            activePhysicalDisplayCount: physicalActiveDisplayCount()
        )
    }

    /// All display IDs known to the window server, INCLUDING ones disabled via
    /// `SLSConfigureDisplayEnabled` (which `CGGetOnlineDisplayList` omits).
    private func allDisplaysIncludingDisabled() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard SLSGetDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard SLSGetDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// Count only active displays with positive hardware-backed physical proof.
    private func physicalActiveDisplayCount() -> Int? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return nil }
        guard count > 0 else { return 0 }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).filter(isHardwareBackedPhysicalDisplay).count
    }

    private func hardwareBackingEvidence(
        for displayID: CGDirectDisplayID
    ) -> HardwareBackedPhysicalDisplayEvidence {
        let servicePort = CGDisplayIOServicePortForPhysicalProof(displayID)
        let hasIOServicePort = servicePort != 0 && servicePort != MACH_PORT_NULL
        let conformsToDisplayConnect = hasIOServicePort
            && IOObjectConformsTo(servicePort, "IODisplayConnect") != 0
        let isBuiltin = CGDisplayIsBuiltin(displayID) != 0
        let isKnownVirtual = VirtualDisplayService.shared.isVirtualDisplay(displayID)
        let needsFramebufferFallback = !isBuiltin
            && !isKnownVirtual
            && !conformsToDisplayConnect
        let coreGraphicsIdentity = needsFramebufferFallback
            ? HardwareDisplayIdentity(
                vendorID: CGDisplayVendorNumber(displayID),
                productID: CGDisplayModelNumber(displayID),
                serialNumber: CGDisplaySerialNumber(displayID)
            )
            : nil
        let framebufferSnapshot = needsFramebufferFallback
            ? framebufferSnapshotForPhysicalProof()
            : nil
        return HardwareBackedPhysicalDisplayEvidence(
            isBuiltin: isBuiltin,
            isKnownVirtual: isKnownVirtual,
            hasIOServicePort: hasIOServicePort,
            ioServiceConformsToDisplayConnect: conformsToDisplayConnect,
            coreGraphicsIdentity: coreGraphicsIdentity,
            framebufferSnapshot: framebufferSnapshot
        )
    }

    /// Keep every enumerated framebuffer so Core can fail closed over all EDID-backed candidates.
    private func framebufferSnapshotForPhysicalProof(
    ) -> [HardwareFramebufferIdentityEvidence]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOMobileFramebuffer"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var snapshot: [HardwareFramebufferIdentityEvidence] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            snapshot.append(framebufferIdentityEvidenceForPhysicalProof(service))
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return snapshot
    }

    private func framebufferIdentityEvidenceForPhysicalProof(
        _ service: io_service_t
    ) -> HardwareFramebufferIdentityEvidence {
        let edidUUID = IORegistryEntryCreateCFProperty(
            service,
            "EDID UUID" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? String
        return HardwareFramebufferIdentityEvidence(
            hasEDIDUUID: edidUUID?.isEmpty == false,
            identity: framebufferIdentityForPhysicalProof(service)
        )
    }

    private func framebufferIdentityForPhysicalProof(
        _ service: io_service_t
    ) -> HardwareDisplayIdentity? {
        guard let displayAttributes = IORegistryEntryCreateCFProperty(
            service,
            "DisplayAttributes" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? [String: Any],
        let productAttributes = displayAttributes["ProductAttributes"] as? [String: Any]
        else { return nil }

        return HardwareDisplayIdentity(
            vendorID: uint32PhysicalProofValue(productAttributes["LegacyManufacturerID"]),
            productID: uint32PhysicalProofValue(productAttributes["ProductID"]),
            serialNumber: uint32PhysicalProofValue(productAttributes["SerialNumber"])
        )
    }

    private func uint32PhysicalProofValue(_ value: Any?) -> UInt32? {
        guard let number = value as? NSNumber else { return nil }
        let signedValue = number.int64Value
        guard signedValue >= 0, signedValue <= Int64(UInt32.max) else { return nil }
        return UInt32(signedValue)
    }

    func isHardwareBackedPhysicalDisplay(_ displayID: CGDirectDisplayID) -> Bool {
        HardwareBackedPhysicalDisplayClassifier.isHardwareBacked(
            hardwareBackingEvidence(for: displayID)
        )
    }

    private func uuid(for displayID: CGDirectDisplayID) -> String {
        stableUUID(for: displayID) ?? "id-\(displayID)"
    }

    private func stableUUID(for displayID: CGDirectDisplayID) -> String? {
        guard let cf = CGDisplayCreateUUIDFromDisplayID(displayID),
              let value = CFUUIDCreateString(nil, cf.takeRetainedValue()) else { return nil }
        let uuid = value as String
        return isExactControlUUID(uuid) ? uuid : nil
    }

    private func isExactControlUUID(_ value: String) -> Bool {
        ControlRequest.isExactDisplayUUID(value)
    }

}

// MARK: - Automation control adapter

extension PhysicalDisplayToggleService {
    func connectionCapabilityForControl(
        _ display: DisplayInfo
    ) -> DisplayConnectionCapability {
        guard isSupported else {
            return .unsupported(
                connected: true,
                reason: "physical display disconnect requires Apple Silicon and macOS 13 or later",
                remediation: "use a supported Apple Silicon Mac or leave connection changes to the GUI"
            )
        }
        guard isExactControlUUID(display.displayUUID) else {
            return .unsupported(
                connected: true,
                platformSupported: true,
                reason: "a stable display UUID is unavailable",
                remediation: "refresh displays after reconnecting the physical cable"
            )
        }
        if let unsupported = HardwareBackedPhysicalDisplayClassifier
            .unsupportedConnectionCapability(
                for: hardwareBackingEvidence(for: display.displayID),
                connected: true
            ) {
            return unsupported
        }
        guard !pendingControlDisconnectUUIDs().contains(display.displayUUID) else {
            return .unsupported(
                connected: true,
                platformSupported: true,
                reason: "the disconnect outcome is indeterminate and may still change",
                remediation: "refresh the disconnected inventory; never retry the write automatically"
            )
        }
        do {
            let observation = try connectionObservation()
            guard observation.allUUIDs.contains(display.displayUUID),
                  observation.onlineUUIDs.contains(display.displayUUID) else {
                return .unsupported(
                    connected: false,
                    platformSupported: true,
                    reason: "the exact UUID is absent from the fresh online inventory",
                    remediation: "run displays list again and make a fresh decision"
                )
            }
            guard observation.activePhysicalViewableUUIDs.contains(display.displayUUID),
                  observation.activePhysicalViewableUUIDs.count > 1 else {
                return .unsupported(
                    connected: true,
                    platformSupported: true,
                    reason: "disconnect would leave no active physical viewable display",
                    remediation: "connect another physical display before disconnecting this one"
                )
            }
            return DisplayConnectionCapability(
                state: .writable,
                connected: true,
                disconnectAllowed: true,
                reconnectAllowed: false,
                platformSupported: true,
                reason: "another active physical viewable display remains"
            )
        } catch {
            return .unsupported(
                connected: true,
                platformSupported: true,
                reason: "fresh WindowServer enumeration is unavailable",
                remediation: "refresh displays and retry only after capability becomes writable"
            )
        }
    }

    func disconnectedDisplaysForControl() throws -> [ControlDisconnectedDisplay] {
        let fresh = try connectionObservation()
        let initiallyPending = pendingControlDisconnectUUIDs()
        for record in disconnected
        where fresh.onlineUUIDs.contains(record.uuid) && !initiallyPending.contains(record.uuid) {
            try removeDisconnectedRecord(uuid: record.uuid)
        }
        for record in disconnected
        where initiallyPending.contains(record.uuid)
            && fresh.allUUIDs.contains(record.uuid)
            && !fresh.onlineUUIDs.contains(record.uuid) {
            try confirmDisconnectedRecord(uuid: record.uuid)
        }
        let observation = try connectionObservation()

        let pending = pendingControlDisconnectUUIDs()
        return disconnected.compactMap { record in
            guard isExactControlUUID(record.uuid) else { return nil }
            let capability: DisplayConnectionCapability
            if pending.contains(record.uuid) {
                capability = .unsupported(
                    connected: observation.onlineUUIDs.contains(record.uuid),
                    platformSupported: isSupported,
                    reason: "the disconnect outcome is indeterminate and may still change",
                    remediation: "refresh this inventory; never retry the write automatically"
                )
            } else if !isSupported {
                capability = .unsupported(
                    connected: observation.onlineUUIDs.contains(record.uuid),
                    reason: "physical display reconnect requires Apple Silicon and macOS 13 or later",
                    remediation: "use a supported Apple Silicon Mac"
                )
            } else if observation.onlineUUIDs.contains(record.uuid) {
                capability = .unsupported(
                    connected: true,
                    platformSupported: true,
                    reason: "the record is stale because the exact UUID is already online",
                    remediation: "refresh the disconnected inventory"
                )
            } else if !observation.allUUIDs.contains(record.uuid) {
                capability = .unsupported(
                    connected: false,
                    platformSupported: true,
                    reason: "the exact UUID cannot be resolved in the full display list",
                    remediation: "check the cable or wake state, then request a fresh inventory"
                )
            } else if observation.virtualUUIDs.contains(record.uuid) {
                capability = .unsupported(
                    connected: false,
                    platformSupported: true,
                    reason: "virtual displays cannot use physical reconnect",
                    remediation: "manage this display through Crisp's virtual display controls"
                )
            } else {
                capability = DisplayConnectionCapability(
                    state: .writable,
                    connected: false,
                    disconnectAllowed: false,
                    reconnectAllowed: true,
                    platformSupported: true,
                    reason: "exact UUID is present in the full list and intentionally disconnected"
                )
            }
            return ControlDisconnectedDisplay(
                uuid: record.uuid,
                name: record.name,
                width: record.width,
                height: record.height,
                connection: capability
            )
        }.sorted { $0.uuid < $1.uuid }
    }

    func disconnectForControl(_ display: DisplayInfo) async throws
        -> DisplayConnectionSetResult {
        let target = DisplayConnectionTarget(
            uuid: display.displayUUID,
            name: display.name,
            width: display.pixelWidth,
            height: display.pixelHeight,
            isHardwareBackedPhysical: isHardwareBackedPhysicalDisplay(display.displayID)
        )
        return try await DisplayConnectionMutationCoordinator(adapter: self).disconnect(target)
    }

    func reconnectForControl(uuid: String) async throws -> DisplayConnectionSetResult {
        try await DisplayConnectionMutationCoordinator(adapter: self).reconnect(uuid: uuid)
    }

    func connectionObservation() throws -> DisplayConnectionObservation {
        let all = try controlAllDisplayIDs()
        let online = try controlOnlineDisplayIDs()
        let active = try controlActiveDisplayIDs()
        let allUUIDs = Set(all.compactMap(stableUUID(for:)))
        let onlineUUIDs = Set(online.compactMap(stableUUID(for:)))
        let hardwareBackedUUIDs = hardwareBackedPhysicalUUIDs(in: all)
        let unsafePhysicalMutationUUIDs = allUUIDs.subtracting(hardwareBackedUUIDs)
        let activePhysicalViewableUUIDs = Set(active.compactMap { id -> String? in
            guard isHardwareBackedPhysicalDisplay(id),
                  let uuid = stableUUID(for: id),
                  hardwareBackedUUIDs.contains(uuid) else { return nil }
            return uuid
        })
        let intentional = Set(disconnected.compactMap { record in
            isExactControlUUID(record.uuid) ? record.uuid : nil
        })
        return DisplayConnectionObservation(
            platformSupported: isSupported,
            allUUIDs: allUUIDs,
            onlineUUIDs: onlineUUIDs,
            intentionalDisconnectedUUIDs: intentional,
            virtualUUIDs: unsafePhysicalMutationUUIDs,
            activePhysicalViewableUUIDs: activePhysicalViewableUUIDs
        )
    }

    private func hardwareBackedPhysicalUUIDs(
        in displayIDs: [CGDirectDisplayID]
    ) -> Set<String> {
        let identified = displayIDs.compactMap { displayID -> (uuid: String, id: CGDirectDisplayID)? in
            guard let uuid = stableUUID(for: displayID) else { return nil }
            return (uuid, displayID)
        }
        let grouped = Dictionary(grouping: identified, by: \.uuid)
        return Set(grouped.compactMap { uuid, candidates in
            guard candidates.count == 1,
                  let candidate = candidates.first,
                  isHardwareBackedPhysicalDisplay(candidate.id) else { return nil }
            return uuid
        })
    }

    func retainDisconnectedRecord(_ target: DisplayConnectionTarget) throws {
        let matches = try resolveControlDisplayIDs(uuid: target.uuid)
        guard matches.count == 1, let displayID = matches.first else {
            throw ControlEnumerationError.persistenceFailed
        }
        let previousRecords = disconnected
        let previousPending = pendingControlDisconnectUUIDs()
        var nextPending = previousPending
        nextPending.insert(target.uuid)
        try persistPendingControlDisconnectUUIDs(nextPending)
        disconnected.removeAll { $0.uuid == target.uuid }
        disconnected.append(DisconnectedDisplay(
            uuid: target.uuid,
            displayID: displayID,
            name: target.name,
            width: target.width,
            height: target.height
        ))
        do {
            try persistDisconnectedForControl()
        } catch {
            disconnected = previousRecords
            try? persistDisconnectedForControl()
            try? persistPendingControlDisconnectUUIDs(previousPending)
            throw error
        }
    }

    func confirmDisconnectedRecord(uuid: String) throws {
        var pending = pendingControlDisconnectUUIDs()
        guard pending.remove(uuid) != nil else { return }
        try persistPendingControlDisconnectUUIDs(pending)
    }

    func removeDisconnectedRecord(uuid: String) throws {
        let previousRecords = disconnected
        let previousPending = pendingControlDisconnectUUIDs()
        disconnected.removeAll { $0.uuid == uuid }
        var nextPending = previousPending
        nextPending.remove(uuid)
        do {
            try persistDisconnectedForControl()
            try persistPendingControlDisconnectUUIDs(nextPending)
        } catch {
            disconnected = previousRecords
            try? persistDisconnectedForControl()
            try? persistPendingControlDisconnectUUIDs(previousPending)
            throw error
        }
    }

    func dispatchConnectionChange(
        uuid: String,
        requestedState: DisplayConnectionState
    ) async -> DisplayConnectionDispatchOutcome {
        guard isSupported, isExactControlUUID(uuid) else {
            return .rejectedBeforeDispatch("platform support or stable UUID preflight failed")
        }
        let observation: DisplayConnectionObservation
        do {
            observation = try connectionObservation()
        } catch {
            return .rejectedBeforeDispatch("fresh full-list re-resolution failed before mutation")
        }
        if let rejection = connectionPreflightRejection(
            uuid: uuid,
            requestedState: requestedState,
            observation: observation
        ) {
            return .rejectedBeforeDispatch(rejection)
        }

        let finalMatches: [CGDirectDisplayID]
        do {
            finalMatches = try resolveControlDisplayIDs(uuid: uuid)
        } catch {
            return .rejectedBeforeDispatch("final exact-UUID re-resolution failed before mutation")
        }
        guard finalMatches.count == 1, let targetID = finalMatches.first else {
            return .rejectedBeforeDispatch("exact UUID did not resolve to one display before mutation")
        }
        guard !Task.isCancelled else {
            return .rejectedBeforeDispatch("display connection request was cancelled before dispatch")
        }
        switch await setEnabledOutcome(requestedState == .connected, displayID: targetID) {
        case .completed:
            return .completed
        case let .rejectedBeforeDispatch(error):
            return .rejectedBeforeDispatch("display configuration was rejected before dispatch (CGError \(error.rawValue))")
        case let .failedAfterDispatch(error):
            return .failedAfterDispatch("display configuration failed after dispatch (CGError \(error.rawValue))")
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        }
    }

    private func connectionPreflightRejection(
        uuid: String,
        requestedState: DisplayConnectionState,
        observation: DisplayConnectionObservation
    ) -> String? {
        switch requestedState {
        case .disconnected:
            guard observation.onlineUUIDs.contains(uuid) else {
                return "exact UUID disappeared from the online list"
            }
            guard !observation.virtualUUIDs.contains(uuid) else {
                return "virtual displays cannot be physically disconnected"
            }
            guard observation.intentionalDisconnectedUUIDs.contains(uuid) else {
                return "UUID-scoped recovery state was not retained"
            }
            guard observation.activePhysicalViewableUUIDs.contains(uuid),
                  observation.activePhysicalViewableUUIDs.count > 1 else {
                return "disconnect would leave no physical viewable display"
            }
        case .connected:
            guard observation.intentionalDisconnectedUUIDs.contains(uuid) else {
                return "UUID is absent from intentional-disconnected records"
            }
            guard !observation.onlineUUIDs.contains(uuid) else {
                return "exact UUID is already online"
            }
            guard !observation.virtualUUIDs.contains(uuid) else {
                return "virtual displays cannot use physical reconnect"
            }
        }
        return nil
    }

    private func resolveControlDisplayIDs(uuid: String) throws -> [CGDirectDisplayID] {
        try controlAllDisplayIDs().filter { stableUUID(for: $0) == uuid }
    }

    private func controlAllDisplayIDs() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        let countError = SLSGetDisplayList(0, nil, &count)
        guard countError == .success else { throw ControlEnumerationError.fullListFailed(countError) }
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let listError = SLSGetDisplayList(count, &ids, &count)
        guard listError == .success else { throw ControlEnumerationError.fullListFailed(listError) }
        return Array(ids.prefix(Int(count)))
    }

    private func controlOnlineDisplayIDs() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        let countError = CGGetOnlineDisplayList(0, nil, &count)
        guard countError == .success else { throw ControlEnumerationError.onlineListFailed(countError) }
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let listError = CGGetOnlineDisplayList(count, &ids, &count)
        guard listError == .success else { throw ControlEnumerationError.onlineListFailed(listError) }
        return Array(ids.prefix(Int(count)))
    }

    private func controlActiveDisplayIDs() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        let countError = CGGetActiveDisplayList(0, nil, &count)
        guard countError == .success else { throw ControlEnumerationError.activeListFailed(countError) }
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let listError = CGGetActiveDisplayList(count, &ids, &count)
        guard listError == .success else { throw ControlEnumerationError.activeListFailed(listError) }
        return Array(ids.prefix(Int(count)))
    }

    private func persistDisconnectedForControl() throws {
        let data = try JSONEncoder().encode(disconnected)
        UserDefaults.standard.set(data, forKey: desiredKey)
        guard let stored = UserDefaults.standard.data(forKey: desiredKey),
              let decoded = try? JSONDecoder().decode([DisconnectedDisplay].self, from: stored),
              decoded == disconnected else {
            throw ControlEnumerationError.persistenceFailed
        }
    }

}

// MARK: - Disconnect / Reconnect

extension PhysicalDisplayToggleService {
    /// Disconnects a physical display and records a snapshot for later reconnect. Refuses if it
    /// would leave zero active displays, so the user can never black out their only screen.
    @discardableResult
    func disconnect(_ display: DisplayInfo) async -> Result<Void, ToggleError> {
        guard isSupported else { return .failure(.unsupportedPlatform) }
        guard let exactUUID = stableUUID(for: display.displayID) else {
            return .failure(.displayNotFound)
        }
        guard let initialDisplayID = resolveUniqueCurrentID(uuid: exactUUID),
              initialDisplayID == display.displayID else {
            return .failure(.displayNotFound)
        }
        guard isHardwareBackedPhysicalDisplay(initialDisplayID) else {
            return .failure(.hardwareBackingUnproven)
        }
        if wouldLeaveNoActiveDisplay(initialDisplayID) {
            return .failure(.wouldLeaveNoActiveDisplay)
        }

        // Snapshot BEFORE disabling, afterwards the display is gone from the normal APIs.
        let snapshot = DisconnectedDisplay(
            uuid: exactUUID,
            displayID: initialDisplayID,
            name: display.name,
            width: display.pixelWidth,
            height: display.pixelHeight
        )

        let previousRecords = disconnected
        let previousPending = pendingControlDisconnectUUIDs()
        var preparedPending = previousPending
        preparedPending.insert(snapshot.uuid)
        do {
            try persistPendingControlDisconnectUUIDs(preparedPending)
            disconnected.removeAll { $0.uuid == snapshot.uuid }
            disconnected.append(snapshot)
            try persistDisconnectedForControl()
        } catch {
            restorePreparedDisconnect(records: previousRecords, pending: previousPending)
            return .failure(.configurationFailed(.failure))
        }
        guard !Task.isCancelled else {
            restorePreparedDisconnect(records: previousRecords, pending: previousPending)
            return .failure(.configurationFailed(.failure))
        }
        guard let finalDisplayID = resolveUniqueCurrentID(uuid: exactUUID),
              finalDisplayID == display.displayID else {
            restorePreparedDisconnect(records: previousRecords, pending: previousPending)
            return .failure(.displayNotFound)
        }
        guard isHardwareBackedPhysicalDisplay(finalDisplayID) else {
            restorePreparedDisconnect(records: previousRecords, pending: previousPending)
            return .failure(.hardwareBackingUnproven)
        }
        guard !wouldLeaveNoActiveDisplay(finalDisplayID) else {
            restorePreparedDisconnect(records: previousRecords, pending: previousPending)
            return .failure(.wouldLeaveNoActiveDisplay)
        }

        switch await setEnabledOutcome(false, displayID: finalDisplayID) {
        case .completed:
            guard await verifyDisconnected(uuid: snapshot.uuid) else {
                return .failure(.outcomeIndeterminate)
            }
            do {
                try confirmDisconnectedRecord(uuid: snapshot.uuid)
                return .success(())
            } catch {
                return .failure(.outcomeIndeterminate)
            }
        case let .rejectedBeforeDispatch(error):
            restorePreparedDisconnect(records: previousRecords, pending: previousPending)
            return .failure(.configurationFailed(error))
        case .failedAfterDispatch, .timedOut, .cancelled:
            return .failure(.outcomeIndeterminate)
        }
    }

    private func restorePreparedDisconnect(
        records: [DisconnectedDisplay],
        pending: Set<String>
    ) {
        disconnected = records
        try? persistDisconnectedForControl()
        try? persistPendingControlDisconnectUUIDs(pending)
    }

    /// Reconnects a previously disconnected display and drops it from the disconnected set.
    @discardableResult
    func reconnect(uuid: String) async -> Result<Void, ToggleError> {
        guard isSupported else { return .failure(.unsupportedPlatform) }
        guard isExactControlUUID(uuid) else {
            return .failure(.displayNotFound)
        }
        guard let record = disconnected.first(where: { $0.uuid == uuid }) else {
            return .failure(.displayNotFound)
        }
        // The CGDirectDisplayID can be reassigned; re-resolve by UUID against the full list.
        guard let targetID = resolveUniqueCurrentID(for: record) else {
            return .failure(.displayNotFound)
        }
        guard isHardwareBackedPhysicalDisplay(targetID) else {
            return .failure(.hardwareBackingUnproven)
        }
        let result = await setEnabled(true, displayID: targetID)
        guard case .success = result else { return result }
        guard await verifyBackOnline(uuid: uuid) else {
            return .failure(.configurationFailed(.failure))
        }
        do {
            try removeDisconnectedRecord(uuid: uuid)
        } catch {
            return .failure(.configurationFailed(.failure))
        }
        return result
    }

    /// Finds the current CGDirectDisplayID for a disconnected record by matching its UUID
    /// across the full (incl. disabled) display list.
    private func resolveUniqueCurrentID(for record: DisconnectedDisplay) -> CGDirectDisplayID? {
        resolveUniqueCurrentID(uuid: record.uuid)
    }

    private func resolveUniqueCurrentID(uuid: String) -> CGDirectDisplayID? {
        guard isExactControlUUID(uuid) else { return nil }
        let matches = allDisplaysIncludingDisabled().filter { stableUUID(for: $0) == uuid }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    /// Soft-reconnects a display (disable then re-enable its framebuffer) to force macOS to
    /// re-read a freshly written EDID override and re-enumerate its modes. This is what lets
    /// smooth-scaling / HiDPI injection take effect without the user physically unplugging the
    /// cable: IOServiceRequestProbe and SLSDetectDisplays are both too weak (verified no-ops),
    /// but the off→on framebuffer toggle re-reads the override (verified live: an external's
    /// mode count went 149→113 when its override was removed and 113→149 when restored, each
    /// time via this toggle). The screen blanks ~1s. Re-resolves the ID by UUID before
    /// re-enabling since the disconnect can reassign it, and retries the re-enable so a transient
    /// failure can't strand a black screen. Unlike disconnect() it leaves the `disconnected` set
    /// untouched: this is a re-enumeration blip, not a user-visible disconnect.
    ///
    /// Unlike disconnect(), this blinks even the sole active display: refusing just makes
    /// the override a silent no-op until the next reboot or replug (issue #58), which is
    /// worse than a ~1s blank the retry loop below is built to recover from. On portables a
    /// throwaway virtual display is held for the blink's duration so Clamshell Sleep never
    /// fires mid-toggle (see makeBlinkSleepGuard). Two safety nets back the blink up: a
    /// dead-man marker in case the app dies mid-toggle (recoverStrandedSoftReconnect), and a
    /// full disabled-display sweep if every re-enable retry fails outright
    /// (reenableUnintentionallyDisabled). Refuses (false) on Intel, when the portable sleep
    /// guard can't be created, or if the disable/verified re-enable never lands.
    @discardableResult
    func softReconnect(_ display: DisplayInfo) async -> Bool {
        guard isSupported else { return false }
        let blinkUUID = display.displayUUID
        // Two callers can race on the same display (manual toggle + auto-HiDPI on a fresh
        // connect): a second blink mid-blink would double-toggle the framebuffer and try to
        // create a second sleep guard with the same fixed identity, which WindowServer
        // rejects (see VirtualDisplayService.create). First one wins; the caller's settle
        // re-read adopts whatever it produced.
        guard !softReconnectInFlight.contains(blinkUUID) else { return false }
        let startID = display.displayID
        // The re-enumeration can come back on macOS's default mode instead of the one the
        // user was running (refresh-rate reset observed live on a 180Hz panel); capture the
        // exact mode so a verified re-enable can restore it. Must be captured before the
        // sleep guard below exists: the guard's arrival alone knocked this panel from 165Hz
        // to 144Hz (observed live), so capturing after it memorizes the knocked-down mode.
        let previousMode = CGDisplayCopyDisplayMode(startID)
        // A lid-closed portable sleeps the instant its sole active display goes away
        // (Clamshell Sleep; verified live: the blink's disable triggered it mid-toggle, the
        // wake left the display SLS-disabled behind a lying re-enable "success", and a
        // PreventSystemSleep assertion does NOT stop it). A live virtual display keeps the
        // display count above zero, which verifiably does prevent it (probed on the same
        // hardware), so hold a throwaway one for the blink's duration. Lid-open laptops
        // never get here (the built-in keeps the count above one); desktops need no guard
        // (no clamshell rule). Refuse only if the guard can't be created: blinking into a
        // guaranteed mid-toggle sleep is how displays get stranded.
        var sleepGuard: CGVirtualDisplay?
        if Self.hasBattery && wouldLeaveNoActiveDisplay(startID) {
            // Reuse a guard parked by a previous unresolved blink first: the fixed identity
            // can't exist twice, so creating a fresh one alongside it would just fail.
            sleepGuard = lingeringSleepGuard
            lingeringSleepGuard = nil
            if sleepGuard == nil { sleepGuard = await makeBlinkSleepGuard() }
            if sleepGuard == nil { return false }
        }
        // Held (released) at every exit below; releasing it is what removes the display.
        defer { withExtendedLifetime(sleepGuard) {} }
        softReconnectInFlight.insert(blinkUUID)
        defer { softReconnectInFlight.remove(blinkUUID) }
        // Persist before disabling: if the app dies between here and a verified re-enable
        // below (crash, force-quit), the display would otherwise be stuck SLS-disabled with
        // nothing left to bring it back. recoverStrandedSoftReconnect checks this at the next
        // launch. Cleared as soon as the display is verifiably back online, or immediately
        // below if the disable itself never happened.
        addPendingSoftReconnect(blinkUUID)
        guard case .success = await setEnabled(false, displayID: startID) else {
            removePendingSoftReconnect(blinkUUID)
            return false
        }
        // Wait for the framebuffer to actually drop (removeFlag) before re-enabling;
        // the 0.9s ceiling matches the old fixed sleep if the event never comes.
        await ReconfigEvents.shared.next(for: startID, matching: .removeFlag, timeout: 0.9)
        var backOnline = false
        for _ in 0..<3 {
            let targetID = allDisplaysIncludingDisabled().first { uuid(for: $0) == blinkUUID } ?? startID
            // Fire the enable without awaiting its result. The result is untrustworthy in
            // both directions (successes can lie, see verifyBackOnline; failures can mask a
            // display already coming up), and CGCompleteDisplayConfiguration can block ~10s
            // past the display's actual return while the link retrains after an override
            // rebuild (observed live), which would hold the mode restore below hostage
            // behind a blocked call and turn it into a second visible blink ~10s after the
            // toggle. Enumeration is the only proof either way.
            Task { _ = await setEnabled(true, displayID: targetID) }
            // The verify window must outlast a display link handshake (2-4s): re-issuing
            // enable while the display is mid-sync restarts the link and blinks it again.
            if await verifyBackOnline(uuid: blinkUUID, timeout: 4.0) { backOnline = true; break }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if !backOnline {
            // The target never came back under its own re-enables: don't leave any display
            // our own disable may have stranded off. Drop the in-flight claim first: the
            // sweep skips displays with a live claim, which would otherwise make it ignore
            // the very display it's here to rescue.
            softReconnectInFlight.remove(blinkUUID)
            await reenableUnintentionallyDisabled()
            // One longer last look before declaring failure: slow re-enumeration must land
            // in the success epilogue below. Treating it as failure skips the mode restore
            // (refresh-rate reset observed live) and parks the guard, whose later release
            // reshuffles the windows a second time, seconds after the toggle.
            backOnline = await verifyBackOnline(uuid: blinkUUID, timeout: 2.0)
        }
        guard backOnline else {
            // Genuinely still down. The marker stays on purpose so refresh/relaunch keeps
            // retrying, and the sleep guard is parked: releasing it now would hand a
            // lid-closed portable straight to Clamshell Sleep with the display stranded,
            // the exact state the guard exists to prevent. Recovery releases it once every
            // marked display is resolved.
            if sleepGuard != nil { lingeringSleepGuard = sleepGuard }
            return false
        }
        removePendingSoftReconnect(blinkUUID)
        if let previousMode,
           let backID = allDisplaysIncludingDisabled().first(where: { uuid(for: $0) == blinkUUID }) {
            // The blink re-reads override plists, which rebuilds the mode list and renumbers
            // every mode ID (observed live: the same timing went 130 -> 683), so the captured
            // object cannot be applied directly; re-find the equivalent mode in the fresh
            // list by parameters. No match means the mode no longer enumerates (toggling
            // smooth OFF removes the dense mode the user may have been running): macOS's
            // fallback stands, same as pre-fix.
            let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
            let modes = CGDisplayCopyAllDisplayModes(backID, options) as? [CGDisplayMode] ?? []
            if let target = modes.first(where: {
                $0.width == previousMode.width && $0.height == previousMode.height
                    && $0.pixelWidth == previousMode.pixelWidth
                    && $0.pixelHeight == previousMode.pixelHeight
                    && abs($0.refreshRate - previousMode.refreshRate) < 1
            }) {
                // A set issued while the link is still retraining can fail silently; verify
                // it stuck and retry briefly instead of trusting one shot.
                for _ in 0..<4 {
                    if CGDisplayCopyDisplayMode(backID)?.ioDisplayModeID == target.ioDisplayModeID { break }
                    _ = await ResolutionService.applyModeSync(target, on: backID)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
        return true
    }

    /// Runs SLSConfigureDisplayEnabled inside a CG configuration transaction.
    /// `.permanently` is the flag the proven implementations (Lunar BlackOut, screen_tune,
    /// BetterDisplay) use, it commits the change so the disconnect actually takes effect.
    private func setEnabled(_ enabled: Bool, displayID: CGDirectDisplayID) async -> Result<Void, ToggleError> {
        switch await setEnabledOutcome(enabled, displayID: displayID) {
        case .completed:
            return .success(())
        case let .rejectedBeforeDispatch(error):
            return .failure(.configurationFailed(error))
        case .failedAfterDispatch, .timedOut, .cancelled:
            return .failure(.outcomeIndeterminate)
        }
    }

    /// Returns transaction phase truth for automation. Once SLSConfigureDisplayEnabled has
    /// been invoked, every non-success (including a language-level timeout/cancellation) is
    /// potentially in flight and must not be represented as a definite safe failure.
    private func setEnabledOutcome(
        _ enabled: Bool,
        displayID: CGDirectDisplayID
    ) async -> ConfigurationTransactionOutcome {
        let outcome = await CGHelpers.runWithTimeoutOutcome(
            seconds: ControlTimeoutPolicy.displayConfigurationTimeout
        ) {
            var config: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&config) == .success, let cfg = config else {
                return ConfigurationTransactionOutcome.rejectedBeforeDispatch(.failure)
            }
            let setErr = SLSConfigureDisplayEnabled(cfg, displayID, enabled)
            guard setErr == .success else {
                CGCancelDisplayConfiguration(cfg)
                return ConfigurationTransactionOutcome.failedAfterDispatch(setErr)
            }
            let complete = CGCompleteDisplayConfiguration(cfg, .permanently)
            guard complete == .success else {
                CGCancelDisplayConfiguration(cfg)
                return ConfigurationTransactionOutcome.failedAfterDispatch(complete)
            }
            return ConfigurationTransactionOutcome.completed
        }
        switch outcome {
        case let .completed(transaction):
            return transaction
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        }
    }

    /// Safety net for softReconnect's re-enable retries all failing: sweeps every SLS-disabled
    /// display that isn't one we disconnected on purpose (`disconnected`), so a transient
    /// re-enable failure can never leave a screen stuck black. Other apps (Lunar and friends)
    /// disable displays intentionally; those are left alone.
    private func reenableUnintentionallyDisabled() async {
        let onlineSet = onlineDisplayIDs()
        let intentionalUUIDs = Set(disconnected.map { $0.uuid })
        for id in allDisplaysIncludingDisabled() where !onlineSet.contains(id) {
            let displayUUID = uuid(for: id)
            guard !intentionalUUIDs.contains(displayUUID) else { continue }
            // A display mid-blink in a live softReconnect is off on purpose for ~1s; its own
            // retry loop owns bringing it back, and racing it here would reintroduce the
            // recovery-vs-toggle conflict this file just fixed, one display over.
            guard !softReconnectInFlight.contains(displayUUID) else { continue }
            _ = await setEnabled(true, displayID: id)
        }
    }

    /// Display IDs currently online. SLS-disabled displays are omitted here (see
    /// allDisplaysIncludingDisabled), so "online" doubles as the enabled check.
    private func onlineDisplayIDs() -> Set<CGDirectDisplayID> {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Set(ids.prefix(Int(count)))
    }

    /// True once the display with this UUID is back in the online list, polling up to
    /// `timeout` seconds. A successful SLSConfigureDisplayEnabled transaction is NOT proof
    /// of recovery: around sleep transitions it reports success while the display stays
    /// disabled (verified live in clamshell). Only enumeration counts.
    private func verifyBackOnline(uuid displayUUID: String, timeout: TimeInterval = 1.0) async -> Bool {
        for _ in 0..<max(Int(timeout * 10), 1) {
            if let id = allDisplaysIncludingDisabled().first(where: { uuid(for: $0) == displayUUID }),
               onlineDisplayIDs().contains(id) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// Transaction completion is not proof of a disconnect. Require the same UUID to remain
    /// in the full list while disappearing from the online list within a bounded window.
    private func verifyDisconnected(uuid displayUUID: String, timeout: TimeInterval = 1.0) async -> Bool {
        for _ in 0..<max(Int(timeout * 10), 1) {
            let matches = allDisplaysIncludingDisabled().filter { uuid(for: $0) == displayUUID }
            if matches.count == 1, let displayID = matches.first,
               !onlineDisplayIDs().contains(displayID) {
                return true
            }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return false
            }
        }
        return false
    }

    /// Throwaway virtual display held while blinking a portable's sole active display, so
    /// Clamshell Sleep never sees a zero-display moment (see softReconnect). Registered but
    /// deliberately minimal: 1080p, no HiDPI ladder. Stamped with the shared virtual vendor
    /// ID so DisplayManager filters it from the UI like any managed virtual display, and
    /// with a FIXED product/serial so macOS keys its per-display settings (including the
    /// "what to show" choice) on a stable identity instead of re-prompting every blink.
    /// Returns nil unless the display verifiably comes online; a registered-but-offline
    /// guard protects nothing.
    private func makeBlinkSleepGuard() async -> CGVirtualDisplay? {
        let w = 1920, h = 1080
        let ppi = 110.0
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.sizeInMillimeters = CGSize(width: Double(w) / ppi * 25.4,
                                              height: Double(h) / ppi * 25.4)
        descriptor.maxPixelsWide = UInt32(w)
        descriptor.maxPixelsHigh = UInt32(h)
        descriptor.name = "Crisp Blink Guard"
        descriptor.vendorID = VirtualDisplayService.crispVirtualVendorID
        descriptor.productID = 0xB11C
        descriptor.serialNum = 0xB11C
        // DO NOT set queue or color primaries (see VirtualDisplayService.create).
        guard let vd = CGVirtualDisplay(descriptor: descriptor) else { return nil }
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = false
        let mode: CGVirtualDisplayMode = CGVirtualDisplayMode(width: UInt(w), height: UInt(h), refreshRate: 60.0)
        settings.modes = [mode]
        let applied: Bool = await CGHelpers.runWithTimeout(seconds: 10, fallback: false) {
            vd.apply(settings)
        }
        guard applied, vd.displayID != kCGNullDirectDisplay else { return nil }
        for _ in 0..<20 {
            if onlineDisplayIDs().contains(vd.displayID) { return vd }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    // MARK: - Reconcile / Wake restore

    /// Drops records for displays that are back online (e.g. physically re-plugged, or macOS
    /// re-enabled them). Called from DisplayManager.refreshDisplays so the UI stays honest.
    func reconcile() {
        guard !disconnected.isEmpty else { return }
        var onlineCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &onlineCount)
        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
        CGGetOnlineDisplayList(onlineCount, &onlineIDs, &onlineCount)
        let onlineUUIDs = Set(onlineIDs.prefix(Int(onlineCount)).map { uuid(for: $0) })
        let pending = pendingControlDisconnectUUIDs()

        let before = disconnected.count
        disconnected.removeAll { onlineUUIDs.contains($0.uuid) && !pending.contains($0.uuid) }
        if disconnected.count != before { saveDesired() }
    }

    /// Sleep guard parked by a softReconnect whose display never verifiably returned (see
    /// its retry-exhausted path): holding it keeps a lid-closed portable awake so the
    /// marker/recovery cadence can keep retrying instead of the machine sleeping on a
    /// stranded display. Released by recovery once every marked display is resolved, or
    /// adopted by the next blink (the fixed identity can't be created twice).
    /// Recovery for softReconnects that never finished: if the app died (crash, force-quit)
    /// between disabling a display and a successful re-enable, the markers softReconnect
    /// left behind name exactly the stranded displays. Called from
    /// DisplayManager.refreshDisplays; a cheap no-op unless a marker is set. Displays whose
    /// softReconnect is live right now are skipped per-UUID (their reconfig events fire
    /// refreshDisplays before the toggle finishes, and their retry loops must not be raced).
    /// Mirrors softReconnect's recovery ladder (3 re-enable tries, then the sweep), and
    /// clears each marker only once its display is verifiably back online or gone entirely,
    /// so a transient failure here leaves it set for the next refresh or launch to try
    /// again. Only ever re-enables marked displays directly, never any other disabled one
    /// (another app may have disabled those on purpose); the sweep it shares with
    /// softReconnect stays scoped to displays outside the intentional `disconnected` set
    /// and outside any live blink.
    func recoverStrandedSoftReconnect() async {
        // Also runs while only a parked guard is left (markers resolved by another path,
        // e.g. a later lid-open blink): the release at the bottom is its only way out.
        guard isSupported, !strandedRecoveryInFlight,
              !pendingSoftReconnectUUIDs().isEmpty || lingeringSleepGuard != nil
        else { return }
        strandedRecoveryInFlight = true
        defer { strandedRecoveryInFlight = false }
        for markedUUID in pendingSoftReconnectUUIDs() {
            // Re-checked per iteration: a blink can start for a marked display while an
            // earlier iteration was awaiting.
            guard !softReconnectInFlight.contains(markedUUID) else { continue }
            guard let targetID = allDisplaysIncludingDisabled().first(where: { uuid(for: $0) == markedUUID }) else {
                // Display gone entirely (unplugged while stranded): a physical replug brings
                // it back online by itself, so the marker has nothing left to do.
                removePendingSoftReconnect(markedUUID)
                continue
            }
            if onlineDisplayIDs().contains(targetID) {
                // Recovered normally (or a previous sweep already brought it back).
                removePendingSoftReconnect(markedUUID)
                continue
            }
            var recovered = false
            for _ in 0..<3 {
                // The API result alone is never trusted (see verifyBackOnline): a lying
                // "success" here is exactly how a clamshell-sleep interruption erased the
                // marker while the display stayed disabled.
                if case .success = await setEnabled(true, displayID: targetID),
                   await verifyBackOnline(uuid: markedUUID) {
                    recovered = true
                    break
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            if !recovered { await reenableUnintentionallyDisabled() }
            // Clear only if the display verifiably came back; otherwise the marker stays set
            // and the addFlag/refresh cadence (or the next launch) retries.
            if recovered || onlineDisplayIDs().contains(targetID) {
                removePendingSoftReconnect(markedUUID)
            }
        }
        // A parked sleep guard has served its purpose once no marker remains unresolved:
        // every marked display is back online or gone. Until then it stays, keeping a
        // lid-closed portable awake for the next retry.
        if lingeringSleepGuard != nil, pendingSoftReconnectUUIDs().isEmpty {
            lingeringSleepGuard = nil
        }
    }

    /// Called on every display-list refresh. The guard in disconnect() can't stop a physical
    /// unplug: with the internal disabled via Crisp and the external cable pulled, zero active
    /// displays remain and macOS does NOT re-enable the disabled one, every screen stays black.
    /// Re-enable a still-attached disconnected display (built-in first) so the machine always
    /// has a live screen. The settle delay rides out transient empty display lists during
    /// wake/replug storms, so a monitor that comes right back keeps the disconnect intact.
    func restoreIfNoActiveDisplay() {
        guard isSupported, !disconnected.isEmpty, !restoreInFlight else { return }
        guard PhysicalDisplaySafetyPolicy.authorizesEmergencyRecovery(
            activePhysicalDisplayCount: physicalActiveDisplayCount()
        ) else { return }
        restoreInFlight = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            defer { self.restoreInFlight = false }
            guard PhysicalDisplaySafetyPolicy.authorizesEmergencyRecovery(
                activePhysicalDisplayCount: self.physicalActiveDisplayCount()
            ) else { return }
            await self.recoverAnyViewableDisplayEmergencyOnly()
        }
    }

    /// Last-known display IDs are permitted only after the settled zero-viewable-screen guard.
    /// Enabling an ID proves only that some screen may be viewable; it does not prove record
    /// identity. UUID-scoped records are removed only after fresh same-UUID online truth.
    private func recoverAnyViewableDisplayEmergencyOnly() async {
        guard PhysicalDisplaySafetyPolicy.authorizesEmergencyRecovery(
            activePhysicalDisplayCount: physicalActiveDisplayCount()
        ) else { return }
        // In the placeholder-display state SLSGetDisplayList can shrink to just the
        // placeholder. SLS may still honor the last-known ID of attached hardware.
        let candidates = disconnected
            .map { record in (record, resolveUniqueCurrentID(for: record) ?? record.displayID) }
            .sorted { lhs, rhs in
                let lhsIsBuiltin = CGDisplayIsBuiltin(lhs.1) == 1
                let rhsIsBuiltin = CGDisplayIsBuiltin(rhs.1) == 1
                return lhsIsBuiltin == rhsIsBuiltin ? lhs.0.uuid < rhs.0.uuid : lhsIsBuiltin
            }
        guard let (record, targetID) = candidates.first else { return }
        guard PhysicalDisplaySafetyPolicy.authorizesEmergencyRecovery(
            activePhysicalDisplayCount: physicalActiveDisplayCount()
        ) else { return }
        let result = await setEnabled(true, displayID: targetID)
        guard case .success = result else { return }
        guard await verifyBackOnline(uuid: record.uuid) else { return }
        try? removeDisconnectedRecord(uuid: record.uuid)
    }

    private func uniqueOnlineDisplayIDsByUUID() -> [String: CGDirectDisplayID]? {
        var onlineCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &onlineCount) == .success else { return nil }
        guard onlineCount > 0 else { return [:] }
        var onlineIDs = [CGDirectDisplayID](repeating: 0, count: Int(onlineCount))
        guard CGGetOnlineDisplayList(onlineCount, &onlineIDs, &onlineCount) == .success else {
            return nil
        }
        let candidates = onlineIDs.prefix(Int(onlineCount)).map {
            (uuid: stableUUID(for: $0), displayID: $0)
        }
        return PhysicalDisplaySafetyPolicy.uniqueExactUUIDDisplayIDs(candidates)
    }

    private func revalidatedWakeTarget(
        uuid: String,
        initialDisplayID: CGDirectDisplayID
    ) -> CGDirectDisplayID? {
        guard let freshOnlineByUUID = uniqueOnlineDisplayIDsByUUID(),
              let freshLiveID = freshOnlineByUUID[uuid] else { return nil }
        guard initialDisplayID == freshLiveID else { return nil }
        guard !wouldLeaveNoActiveDisplay(freshLiveID) else { return nil }
        guard isHardwareBackedPhysicalDisplay(freshLiveID) else { return nil }
        return freshLiveID
    }

    /// Re-applies disconnect for displays macOS re-enabled after wake-from-sleep. Called from
    /// AppDelegate.onWake after WindowServer settles.
    func reapplyOnWake() async {
        guard isSupported, !disconnected.isEmpty else { return }
        guard let onlineByUUID = uniqueOnlineDisplayIDsByUUID() else { return }
        let pending = pendingControlDisconnectUUIDs()

        for record in disconnected where !pending.contains(record.uuid) {
            // Only re-disconnect ones macOS brought back online, and never the last screen.
            guard let initialLiveID = onlineByUUID[record.uuid] else { continue }
            guard isHardwareBackedPhysicalDisplay(initialLiveID) else { continue }
            guard !wouldLeaveNoActiveDisplay(initialLiveID) else { continue }
            var preparedPending = pendingControlDisconnectUUIDs()
            preparedPending.insert(record.uuid)
            do {
                try persistPendingControlDisconnectUUIDs(preparedPending)
            } catch {
                continue
            }
            guard !Task.isCancelled else {
                try? confirmDisconnectedRecord(uuid: record.uuid)
                return
            }
            guard let freshLiveID = revalidatedWakeTarget(
                uuid: record.uuid,
                initialDisplayID: initialLiveID
            ) else {
                try? confirmDisconnectedRecord(uuid: record.uuid)
                continue
            }
            switch await setEnabledOutcome(false, displayID: freshLiveID) {
            case .completed:
                if await verifyDisconnected(uuid: record.uuid) {
                    try? confirmDisconnectedRecord(uuid: record.uuid)
                }
            case .rejectedBeforeDispatch:
                try? confirmDisconnectedRecord(uuid: record.uuid)
            case .failedAfterDispatch, .timedOut, .cancelled:
                // Keep the marker: no wake retry or reconciliation may erase recovery state.
                break
            }
        }
    }

    // MARK: - Persistence

    private func saveDesired() {
        guard let data = try? JSONEncoder().encode(disconnected) else { return }
        UserDefaults.standard.set(data, forKey: desiredKey)
    }

    private func loadDesired() {
        guard let data = UserDefaults.standard.data(forKey: desiredKey),
              let decoded = try? JSONDecoder().decode([DisconnectedDisplay].self, from: data)
        else { return }
        disconnected = decoded
        // By design we do NOT auto-disconnect on launch, restarting the app must never
        // black out a screen on its own. The loaded list only populates the "Disconnected"
        // UI so the user can reconnect (or ignore) at their choice. Only the sleep/wake path
        // re-applies disconnect, via reapplyOnWake().
    }
}
