// Safety-critical display recovery is intentionally kept beside its persistence adapter.
// swiftlint:disable file_length
import Foundation
import CoreGraphics
import ColorSync
import IOKit
import Security
import Darwin
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
/// KEY QUIRK: once a display is disabled it can lose its UUID even though `SLSGetDisplayList`
/// retains an ID. This service keeps UUID-scoped UI metadata plus a bounded, one-shot recovery
/// capability; exact UUID resolution always takes priority when it is available.
@MainActor
final class PhysicalDisplayToggleService: ObservableObject, DisplayConnectionMutationAdapter {
    private static let connectionRecoveryStateKey =
        "crisp.PhysicalDisplayToggleService.connectionRecoveryState.v1"
    static let shared = PhysicalDisplayToggleService()

    private let connectionPersistence: DisplayConnectionPersistenceBoundary
    private init() {
        let key = Self.connectionRecoveryStateKey
        connectionPersistence = DisplayConnectionPersistenceBoundary(
            read: { UserDefaults.standard.data(forKey: key) },
            write: { UserDefaults.standard.set($0, forKey: key) }
        )
        loadDesired()
    }

    /// Snapshot of a display we disconnected, kept because a disconnected display no longer
    /// appears in DisplayManager.displays, so we need its metadata to render a Reconnect row.
    typealias DisconnectedDisplay = DisplayConnectionPersistedRecord
    private typealias PersistedConnectionState = DisplayConnectionPersistenceEnvelope
    enum ToggleError: Error, Sendable, CustomStringConvertible {
        case unsupportedPlatform, wouldLeaveNoActiveDisplay, outcomeIndeterminate
        case displayNotFound, hardwareBackingUnproven
        case configurationFailed(CGError)
        case mutationFailed(String)

        var description: String {
            switch self {
            case .unsupportedPlatform: return String(localized: "Physical display disconnect requires Apple Silicon (macOS 13+).")
            case .wouldLeaveNoActiveDisplay: return String(localized: "Refusing to disconnect: it would leave no active display.")
            case .configurationFailed(let err): return String(localized: "Display configuration failed (CGError \(String(err.rawValue))).")
            case .outcomeIndeterminate:
                return String(localized: "Display configuration may still complete; refresh before deciding again.")
            case .displayNotFound: return String(localized: "Display not found.")
            case .hardwareBackingUnproven: return String(localized: "Display cannot be proven to be hardware-backed physical.")
            case let .mutationFailed(message): return message
            }
        }
    }

    private enum ConfigurationTransactionOutcome: Sendable {
        case completed, timedOut, cancelled
        case rejectedBeforeDispatch(CGError)
        case failedAfterDispatch(CGError)
    }

    private enum ControlEnumerationError: Error {
        case fullListFailed(CGError), onlineListFailed(CGError), activeListFailed(CGError)
        case persistenceFailed
    }

    // MARK: - State

    /// Displays the user has disconnected and can reconnect. Persisted (by UUID) so wake and
    /// relaunch can restore the intended state.
    @Published private(set) var disconnected: [DisconnectedDisplay] = []

    /// Process-local ownership for explicit reconnects. The durable reservation below records
    /// crash uncertainty; only this set proves that the current process still has a live owner.
    private var liveReconnectReservationUUIDs: Set<String> = []
    /// Quarantine reconciliation is explicit and read-back-only, but still single-flight so an
    /// overlapping GUI/CLI request cannot observe its metadata transition and dispatch a write.
    private var liveQuarantineReconciliationUUIDs: Set<String> = []

    // Legacy keys are migration-only once the authoritative envelope exists.
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

    private func connectionStateSnapshot(
        synchronizePublished: Bool = false
    ) throws -> DisplayConnectionPersistenceSnapshot {
        do {
            let snapshot = try connectionPersistence.snapshot()
            if synchronizePublished {
                connectionPersistence.adoptPublishedRecords(from: snapshot)
                disconnected = connectionPersistence.publishedRecords
            }
            return snapshot
        } catch {
            throw ControlEnumerationError.persistenceFailed
        }
    }

    @discardableResult
    private func persistConnectionState(
        _ proposedState: PersistedConnectionState,
        replacing oldSnapshot: DisplayConnectionPersistenceSnapshot,
        quarantiningUUIDs: Set<String>
    ) throws -> PersistedConnectionState {
        let result: DisplayConnectionPersistenceWriteResult
        do {
            result = try connectionPersistence.replace(
                oldState: oldSnapshot.envelope,
                proposedState: proposedState,
                quarantiningUUIDs: quarantiningUUIDs
            )
        } catch {
            throw ControlEnumerationError.persistenceFailed
        }
        disconnected = connectionPersistence.publishedRecords
        guard result.disposition == .committedProposed else {
            throw ControlEnumerationError.persistenceFailed
        }
        return result.snapshot.envelope
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
        return HardwareBackedPhysicalDisplayEvidence(
            isBuiltin: isBuiltin,
            isKnownVirtual: isKnownVirtual,
            hasIOServicePort: hasIOServicePort,
            ioServiceConformsToDisplayConnect: conformsToDisplayConnect,
            coreGraphicsIdentity: needsFramebufferFallback
                ? hardwareIdentity(for: displayID)
                : nil,
            framebufferSnapshot: needsFramebufferFallback
                ? framebufferSnapshotForPhysicalProof()
                : nil
        )
    }

    private func hardwareBackingEvidence(
        for displayID: CGDirectDisplayID,
        framebufferSnapshot: [HardwareFramebufferIdentityEvidence]?
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
        return HardwareBackedPhysicalDisplayEvidence(
            isBuiltin: isBuiltin,
            isKnownVirtual: isKnownVirtual,
            hasIOServicePort: hasIOServicePort,
            ioServiceConformsToDisplayConnect: conformsToDisplayConnect,
            coreGraphicsIdentity: needsFramebufferFallback
                ? hardwareIdentity(for: displayID)
                : nil,
            framebufferSnapshot: needsFramebufferFallback ? framebufferSnapshot : nil
        )
    }

    private func hardwareIdentity(for displayID: CGDirectDisplayID) -> HardwareDisplayIdentity {
        HardwareDisplayIdentity(
            vendorID: CGDisplayVendorNumber(displayID),
            productID: CGDisplayModelNumber(displayID),
            serialNumber: CGDisplaySerialNumber(displayID)
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
        var registryEntryID: UInt64 = 0
        let hasRegistryEntryID = IORegistryEntryGetRegistryEntryID(
            service,
            &registryEntryID
        ) == KERN_SUCCESS
        return HardwareFramebufferIdentityEvidence(
            registryEntryID: hasRegistryEntryID ? registryEntryID : nil,
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

    private func connectionCandidate(
        displayID: CGDirectDisplayID,
        onlineIDs: Set<CGDirectDisplayID>,
        framebufferSnapshot: [HardwareFramebufferIdentityEvidence]?,
        retainedRecords: [DisconnectedDisplay]
    ) -> DisplayConnectionCandidate {
        let evidence = hardwareBackingEvidence(
            for: displayID,
            framebufferSnapshot: framebufferSnapshot
        )
        let isHardwareBacked = HardwareBackedPhysicalDisplayClassifier.isHardwareBacked(evidence)
        let stableUUID = stableUUID(for: displayID)
        let directRecoveryProof = recoveryHardwareProof(
            for: displayID,
            isHardwareBacked: isHardwareBacked,
            framebufferSnapshot: framebufferSnapshot
        )
        return DisplayConnectionCandidate(
            displayID: displayID,
            stableUUID: stableUUID,
            isOnline: onlineIDs.contains(displayID),
            isHardwareBackedPhysical: isHardwareBacked,
            recoveryHardwareProof: directRecoveryProof ?? (stableUUID == nil
                ? retainedRecoveryHardwareProof(
                    for: displayID,
                    framebufferSnapshot: framebufferSnapshot,
                    retainedRecords: retainedRecords
                )
                : nil)
        )
    }

    private func retainedRecoveryHardwareProof(
        for displayID: CGDirectDisplayID,
        framebufferSnapshot: [HardwareFramebufferIdentityEvidence]?,
        retainedRecords: [DisconnectedDisplay]
    ) -> DisplayConnectionRecoveryHardwareProof? {
        let claims = retainedRecords.compactMap(\.recoveryCapability).filter {
            $0.displayID == displayID
        }
        guard claims.count == 1, let proof = claims.first?.hardwareProof else { return nil }
        return DisplayConnectionRecoveryProofBinder.isDirectlyBound(
            retainedProof: proof,
            currentIsBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
            currentIdentity: hardwareIdentity(for: displayID),
            framebufferSnapshot: framebufferSnapshot
        ) ? proof : nil
    }

    private func recoveryHardwareProof(
        for displayID: CGDirectDisplayID,
        isHardwareBacked: Bool,
        framebufferSnapshot: [HardwareFramebufferIdentityEvidence]?
    ) -> DisplayConnectionRecoveryHardwareProof? {
        guard isHardwareBacked else { return nil }
        if CGDisplayIsBuiltin(displayID) != 0 {
            return DisplayConnectionRecoveryHardwareProof(isBuiltIn: true, identity: nil)
        }
        let identity = hardwareIdentity(for: displayID)
        guard HardwareFramebufferIdentityMatcher.hasUniqueExactMatch(
            target: identity,
            framebufferSnapshot: framebufferSnapshot
        ) else { return nil }
        return DisplayConnectionRecoveryHardwareProof(isBuiltIn: false, identity: identity)
    }

    private func currentBootSessionID() -> String? {
        guard let value = sysctlString("kern.bootsessionuuid"),
              UUID(uuidString: value) != nil else { return nil }
        return value.uppercased()
    }

    private func currentLoginSessionID() -> String? {
        var sessionID: SecuritySessionId = 0
        var attributes = SessionAttributeBits(rawValue: 0)
        guard SessionGetInfo(
            callerSecuritySession,
            &sessionID,
            &attributes
        ) == errSecSuccess, sessionID != 0 else { return nil }
        return String(sessionID)
    }

    private func currentWakeSessionID() -> String? {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS else { return nil }
        let continuousBefore = mach_continuous_time()
        let absolute = mach_absolute_time()
        let continuousAfter = mach_continuous_time()
        return DisplayConnectionMachSleepOffsetToken.make(
            continuousBeforeTicks: continuousBefore,
            absoluteTicks: absolute,
            continuousAfterTicks: continuousAfter,
            timebaseNumerator: timebase.numer, timebaseDenominator: timebase.denom
        )
    }

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

// MARK: - Automation control adapter

extension PhysicalDisplayToggleService {
    func connectionCapabilitiesForControl(
        _ displays: [DisplayInfo]
    ) -> [String: DisplayConnectionCapability] {
        let subjects = displays.map { display in
            DisplayConnectionCapabilitySubject(
                uuid: display.displayUUID,
                staticUnsupportedCapability: staticUnsupportedConnectionCapability(for: display)
            )
        }
        return DisplayConnectionReadOnlyQueries.connectedCapabilities(
            subjects: subjects,
            loadSnapshot: { try connectionStateSnapshot() },
            buildObservation: { snapshot in
                try connectionObservation(persistenceSnapshot: snapshot)
            }
        )
    }

    private func staticUnsupportedConnectionCapability(
        for display: DisplayInfo
    ) -> DisplayConnectionCapability? {
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
        return nil
    }

    func disconnectedDisplaysForControl() throws -> [ControlDisconnectedDisplay] {
        let snapshot = try connectionStateSnapshot()
        let observation = try connectionObservation(persistenceSnapshot: snapshot)
        return DisplayConnectionReadOnlyQueries.disconnectedDisplays(
            persistenceSnapshot: snapshot,
            observation: observation
        )
    }

    func disconnectForControl(_ display: DisplayInfo) async throws
        -> DisplayConnectionSetResult {
        let target = DisplayConnectionTarget(
            uuid: display.displayUUID,
            displayID: display.displayID,
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
        let persistenceSnapshot = try connectionStateSnapshot(synchronizePublished: true)
        return try connectionObservation(persistenceSnapshot: persistenceSnapshot)
    }

    private func connectionObservation(
        persistenceSnapshot: DisplayConnectionPersistenceSnapshot
    ) throws -> DisplayConnectionObservation {
        let records = persistenceSnapshot.envelope.records
        guard records.allSatisfy({ isExactControlUUID($0.uuid) }) else {
            throw ControlEnumerationError.persistenceFailed
        }
        let all = try controlAllDisplayIDs()
        let online = try controlOnlineDisplayIDs()
        let active = try controlActiveDisplayIDs()
        let onlineIDs = Set(online)
        let framebufferSnapshot = framebufferSnapshotForPhysicalProof()
        let candidates = all.map {
            connectionCandidate(
                displayID: $0,
                onlineIDs: onlineIDs,
                framebufferSnapshot: framebufferSnapshot,
                retainedRecords: records
            )
        }
        let allUUIDs = Set(candidates.compactMap(\.stableUUID))
        let onlineUUIDs = Set(candidates.compactMap { candidate in
            candidate.isOnline ? candidate.stableUUID : nil
        })
        let hardwareBackedUUIDs = hardwareBackedPhysicalUUIDs(in: candidates)
        let unsafePhysicalMutationUUIDs = allUUIDs.subtracting(hardwareBackedUUIDs)
        let activePhysicalViewableUUIDs = Set(active.compactMap { id -> String? in
            let matches = candidates.filter { $0.displayID == id }
            guard matches.count == 1, let candidate = matches.first,
                  candidate.isHardwareBackedPhysical,
                  let uuid = candidate.stableUUID,
                  hardwareBackedUUIDs.contains(uuid) else { return nil }
            return uuid
        })
        return DisplayConnectionObservation(
            persistenceSnapshot: persistenceSnapshot,
            platformSupported: isSupported,
            allUUIDs: allUUIDs,
            onlineUUIDs: onlineUUIDs,
            virtualUUIDs: unsafePhysicalMutationUUIDs,
            activePhysicalViewableUUIDs: activePhysicalViewableUUIDs,
            candidates: candidates,
            bootSessionID: currentBootSessionID(),
            loginSessionID: currentLoginSessionID(),
            wakeSessionID: currentWakeSessionID(),
            topologyFingerprint: DisplayConnectionTopologyFingerprint.make(
                displayIDs: all,
                framebufferSnapshot: framebufferSnapshot
            )
        )
    }

    private func hardwareBackedPhysicalUUIDs(
        in candidates: [DisplayConnectionCandidate]
    ) -> Set<String> {
        let identified = candidates.compactMap { candidate -> (String, Bool)? in
            guard let uuid = candidate.stableUUID else { return nil }
            return (uuid, candidate.isHardwareBackedPhysical)
        }
        let grouped = Dictionary(grouping: identified, by: \.0)
        return Set(grouped.compactMap { uuid, matches in
            guard matches.count == 1, matches[0].1 else { return nil }
            return uuid
        })
    }

    func retainDisconnectedRecord(
        _ target: DisplayConnectionTarget
    ) throws -> DisplayConnectionRecoveryCapability? {
        let snapshot = try connectionStateSnapshot(synchronizePublished: true)
        guard snapshot.authorizesConnectionMutation else {
            throw ControlEnumerationError.persistenceFailed
        }
        let currentState = snapshot.envelope
        let observation = try connectionObservation(persistenceSnapshot: snapshot)
        let matches = observation.candidates.filter { $0.stableUUID == target.uuid }
        guard matches.count == 1, let candidate = matches.first,
              candidate.isOnline,
              candidate.isHardwareBackedPhysical,
              target.displayID == nil || target.displayID == candidate.displayID else {
            throw ControlEnumerationError.persistenceFailed
        }
        let recoveryCapability: DisplayConnectionRecoveryCapability?
        if let proof = candidate.recoveryHardwareProof,
           let bootSessionID = observation.bootSessionID,
           let loginSessionID = observation.loginSessionID,
           let wakeSessionID = observation.wakeSessionID,
           let topologyFingerprint = observation.topologyFingerprint {
            recoveryCapability = DisplayConnectionRecoveryCapability(
                uuid: target.uuid,
                displayID: candidate.displayID,
                hardwareProof: proof,
                bootSessionID: bootSessionID,
                loginSessionID: loginSessionID,
                wakeSessionID: wakeSessionID,
                topologyFingerprint: topologyFingerprint,
                state: .prepared
            )
        } else {
            recoveryCapability = nil
        }
        var nextPending = currentState.pendingSet
        nextPending.insert(target.uuid)
        var nextRecords = currentState.records.filter { $0.uuid != target.uuid }
        nextRecords.append(DisconnectedDisplay(
            uuid: target.uuid,
            displayID: candidate.displayID,
            name: target.name,
            width: target.width,
            height: target.height,
            recoveryCapability: recoveryCapability
        ))
        try persistConnectionState(
            PersistedConnectionState(
                records: nextRecords,
                pendingUUIDs: nextPending,
                reconnectReservationUUIDs: currentState.reconnectReservationSet,
                reconnectPersistenceUncertainUUIDs:
                    currentState.reconnectPersistenceUncertainSet
            ),
            replacing: snapshot,
            quarantiningUUIDs: [target.uuid]
        )
        return recoveryCapability
    }
    func confirmDisconnectedRecord(uuid: String) throws {
        let snapshot = try connectionStateSnapshot(synchronizePublished: true)
        guard snapshot.authorizesConnectionMutation else {
            throw ControlEnumerationError.persistenceFailed
        }
        let currentState = snapshot.envelope
        var nextRecords = currentState.records
        var nextPending = currentState.pendingSet
        let removedPending = nextPending.remove(uuid) != nil
        if let index = nextRecords.firstIndex(where: { $0.uuid == uuid }),
           let capability = nextRecords[index].recoveryCapability,
           capability.state == .prepared {
            nextRecords[index].recoveryCapability = capability.changingState(to: .available)
        }
        guard removedPending || nextRecords != currentState.records else { return }
        try persistConnectionState(
            PersistedConnectionState(
                records: nextRecords,
                pendingUUIDs: nextPending,
                reconnectReservationUUIDs: currentState.reconnectReservationSet,
                reconnectPersistenceUncertainUUIDs:
                    currentState.reconnectPersistenceUncertainSet
            ),
            replacing: snapshot,
            quarantiningUUIDs: [uuid]
        )
    }
    func consumeRecoveryCapability(
        _ capability: DisplayConnectionRecoveryCapability
    ) throws -> DisplayConnectionRecoveryCapability {
        let snapshot = try connectionStateSnapshot(synchronizePublished: true)
        guard snapshot.authorizesConnectionMutation else {
            throw ControlEnumerationError.persistenceFailed
        }
        let currentState = snapshot.envelope
        let matches = currentState.records.indices.filter {
            currentState.records[$0].uuid == capability.uuid
                && currentState.records[$0].recoveryCapability == capability
        }
        guard matches.count == 1, let index = matches.first,
              capability.state == .available else {
            throw ControlEnumerationError.persistenceFailed
        }
        let consumed = capability.changingState(to: .consumed)
        var nextRecords = currentState.records
        nextRecords[index].recoveryCapability = consumed
        try persistConnectionState(
            PersistedConnectionState(
                records: nextRecords,
                pendingUUIDs: currentState.pendingSet,
                reconnectReservationUUIDs: currentState.reconnectReservationSet,
                reconnectPersistenceUncertainUUIDs:
                    currentState.reconnectPersistenceUncertainSet
            ),
            replacing: snapshot,
            quarantiningUUIDs: [capability.uuid]
        )
        return consumed
    }
    private func updateReconnectReservation(uuid: String, adding: Bool) throws {
        let snapshot = try connectionStateSnapshot(synchronizePublished: true)
        guard snapshot.authorizesConnectionMutation else {
            throw ControlEnumerationError.persistenceFailed
        }
        let currentState = snapshot.envelope
        guard currentState.records.filter({ $0.uuid == uuid }).count == 1 else {
            throw ControlEnumerationError.persistenceFailed
        }
        var reservations = currentState.reconnectReservationSet
        let changed = adding
            ? reservations.insert(uuid).inserted
            : reservations.remove(uuid) != nil
        guard changed else { throw ControlEnumerationError.persistenceFailed }
        try persistConnectionState(
            PersistedConnectionState(
                records: currentState.records,
                pendingUUIDs: currentState.pendingSet,
                reconnectReservationUUIDs: reservations,
                reconnectPersistenceUncertainUUIDs:
                    currentState.reconnectPersistenceUncertainSet
            ),
            replacing: snapshot,
            quarantiningUUIDs: [uuid]
        )
    }
    func reserveReconnect(uuid: String) throws {
        guard !liveReconnectReservationUUIDs.contains(uuid) else {
            throw ControlEnumerationError.persistenceFailed
        }
        liveReconnectReservationUUIDs.insert(uuid)
        do {
            try updateReconnectReservation(uuid: uuid, adding: true)
        } catch {
            liveReconnectReservationUUIDs.remove(uuid)
            throw error
        }
    }
    func releaseReconnectReservation(uuid: String) throws {
        guard liveReconnectReservationUUIDs.contains(uuid) else {
            throw ControlEnumerationError.persistenceFailed
        }
        try updateReconnectReservation(uuid: uuid, adding: false)
        liveReconnectReservationUUIDs.remove(uuid)
    }
    func rollbackRejectedReconnectBeforeDispatch(
        uuid: String,
        consumedRecoveryCapability: DisplayConnectionRecoveryCapability?
    ) throws {
        guard liveReconnectReservationUUIDs.contains(uuid) else {
            throw ControlEnumerationError.persistenceFailed
        }
        defer { liveReconnectReservationUUIDs.remove(uuid) }
        let snapshot = try connectionStateSnapshot(synchronizePublished: true)
        guard snapshot.authorizesConnectionMutation else {
            throw ControlEnumerationError.persistenceFailed
        }
        let rolledBack = try RejectedReconnectRollback.proposedState(
            uuid: uuid,
            consumedRecoveryCapability: consumedRecoveryCapability,
            currentState: snapshot.envelope
        )
        try persistConnectionState(
            rolledBack,
            replacing: snapshot,
            quarantiningUUIDs: [uuid]
        )
    }
    func reconcileOrphanedReconnectAttempt(
        uuid: String
    ) throws -> DisplayReconnectOrphanReconciliation {
        let snapshot = try connectionStateSnapshot(synchronizePublished: true)
        guard snapshot.authority == .durable else { return .unavailable }
        let currentState = snapshot.envelope
        guard currentState.reconnectReservationSet.contains(uuid) else { return .unavailable }
        guard !liveReconnectReservationUUIDs.contains(uuid) else { return .liveAttempt }
        let observation = try connectionObservation(persistenceSnapshot: snapshot)
        if DisplayConnectionRecoveryResolver.uniqueOnlineHardwareCandidate(
            uuid: uuid,
            observation: observation
        ) != nil {
            return .alreadyOnline
        }
        let resolution = DisplayConnectionRecoveryResolver.orphanedReconnectResolution(
            uuid: uuid,
            observation: observation
        )
        var nextRecords = currentState.records
        switch resolution {
        case .exactUUID:
            if let index = nextRecords.firstIndex(where: { $0.uuid == uuid }),
               let capability = nextRecords[index].recoveryCapability,
               [.consumed, .indeterminate].contains(capability.state) {
                if DisplayConnectionRecoveryResolver
                    .restorableRecoveryCapabilityForExactOrphan(
                        uuid: uuid,
                        observation: observation
                    ) == capability {
                    nextRecords[index].recoveryCapability = capability.changingState(to: .available)
                } else {
                    // Exact UUID authority is sufficient for the next explicit request. Drop an
                    // unsafe fallback rather than reviving it without direct continuity proof.
                    nextRecords[index].recoveryCapability = nil
                }
            }
        case let .oneShotRecovery(capability):
            let matches = nextRecords.indices.filter {
                nextRecords[$0].uuid == uuid
                    && nextRecords[$0].recoveryCapability == capability
            }
            guard matches.count == 1, let index = matches.first else { return .unavailable }
            nextRecords[index].recoveryCapability = capability.changingState(to: .available)
        case .alreadyOnline, .unavailable:
            return .unavailable
        }
        var nextReservations = currentState.reconnectReservationSet
        guard nextReservations.remove(uuid) != nil else { return .unavailable }
        var nextUncertain = currentState.reconnectPersistenceUncertainSet
        nextUncertain.remove(uuid)
        try persistConnectionState(
            PersistedConnectionState(
                records: nextRecords,
                pendingUUIDs: currentState.pendingSet,
                reconnectReservationUUIDs: nextReservations,
                reconnectPersistenceUncertainUUIDs: nextUncertain
            ),
            replacing: snapshot,
            quarantiningUUIDs: [uuid]
        )
        return .reconciled
    }
    func reconcileQuarantinedReconnectAttempt(
        uuid: String
    ) async throws -> DisplayReconnectQuarantineReconciliation {
        guard !liveReconnectReservationUUIDs.contains(uuid),
              !liveQuarantineReconciliationUUIDs.contains(uuid) else {
            return .liveAttempt
        }
        liveQuarantineReconciliationUUIDs.insert(uuid)

        let snapshot = try connectionStateSnapshot(synchronizePublished: true)
        guard snapshot.authority == .durable,
              snapshot.envelope.reconnectPersistenceUncertainSet.contains(uuid) else {
            return .unavailable
        }
        let observation = try connectionObservation(persistenceSnapshot: snapshot)
        guard let result = try connectionPersistence.reconcileQuarantinedReconnect(
            uuid: uuid,
            snapshot: snapshot,
            observation: observation
        ) else { return .unavailable }
        disconnected = connectionPersistence.publishedRecords
        guard result.writeResult.disposition == .committedProposed else {
            throw ControlEnumerationError.persistenceFailed
        }
        switch result.kind {
        case .reconciledOffline:
            return .reconciled
        case .alreadyOnline:
            return .alreadyOnline
        }
    }
    func finishQuarantinedReconnectAttempt(uuid: String) {
        liveQuarantineReconciliationUUIDs.remove(uuid)
    }
    private func changeRecoveryCapabilityState(
        uuid: String,
        allowedStates: Set<DisplayConnectionRecoveryCapabilityState>,
        to state: DisplayConnectionRecoveryCapabilityState
    ) throws {
        let snapshot = try connectionStateSnapshot(synchronizePublished: true)
        guard snapshot.authorizesConnectionMutation else {
            throw ControlEnumerationError.persistenceFailed
        }
        let currentState = snapshot.envelope
        guard let index = currentState.records.firstIndex(where: { $0.uuid == uuid }),
              let capability = currentState.records[index].recoveryCapability,
              allowedStates.contains(capability.state), capability.state != state else { return }
        var nextRecords = currentState.records
        nextRecords[index].recoveryCapability = capability.changingState(to: state)
        try persistConnectionState(
            PersistedConnectionState(
                records: nextRecords,
                pendingUUIDs: currentState.pendingSet,
                reconnectReservationUUIDs: currentState.reconnectReservationSet,
                reconnectPersistenceUncertainUUIDs:
                    currentState.reconnectPersistenceUncertainSet
            ),
            replacing: snapshot,
            quarantiningUUIDs: [uuid]
        )
    }
    func markReconnectAttemptIndeterminate(uuid: String) throws {
        defer { liveReconnectReservationUUIDs.remove(uuid) }
        try changeRecoveryCapabilityState(
            uuid: uuid,
            allowedStates: [.prepared, .available, .invalidatedByWake, .consumed],
            to: .indeterminate
        )
    }
    func markRecoveryCapabilityIndeterminate(uuid: String) throws {
        let snapshot = try connectionStateSnapshot(synchronizePublished: true)
        guard snapshot.authorizesConnectionMutation else {
            throw ControlEnumerationError.persistenceFailed
        }
        let currentState = snapshot.envelope
        guard let index = currentState.records.firstIndex(where: { $0.uuid == uuid }) else {
            return
        }
        var nextRecords = currentState.records
        if let capability = nextRecords[index].recoveryCapability {
            nextRecords[index].recoveryCapability = capability.changingState(to: .indeterminate)
        }
        var nextPending = currentState.pendingSet
        nextPending.insert(uuid)
        try persistConnectionState(
            PersistedConnectionState(
                records: nextRecords,
                pendingUUIDs: nextPending,
                reconnectReservationUUIDs: currentState.reconnectReservationSet,
                reconnectPersistenceUncertainUUIDs:
                    currentState.reconnectPersistenceUncertainSet
            ),
            replacing: snapshot,
            quarantiningUUIDs: [uuid]
        )
    }

    func removeDisconnectedRecord(uuid: String) throws {
        let snapshot = try connectionStateSnapshot(synchronizePublished: true)
        guard snapshot.authority == .durable else {
            throw ControlEnumerationError.persistenceFailed
        }
        let currentState = snapshot.envelope
        let nextRecords = currentState.records.filter { $0.uuid != uuid }
        var nextPending = currentState.pendingSet
        nextPending.remove(uuid)
        var nextReservations = currentState.reconnectReservationSet
        nextReservations.remove(uuid)
        var nextUncertain = currentState.reconnectPersistenceUncertainSet
        nextUncertain.remove(uuid)
        try persistConnectionState(
            PersistedConnectionState(
                records: nextRecords,
                pendingUUIDs: nextPending,
                reconnectReservationUUIDs: nextReservations,
                reconnectPersistenceUncertainUUIDs: nextUncertain
            ),
            replacing: snapshot,
            quarantiningUUIDs: [uuid]
        )
        liveReconnectReservationUUIDs.remove(uuid)
    }

    func dispatchConnectionChange(
        _ request: DisplayConnectionDispatchRequest
    ) async -> DisplayConnectionDispatchOutcome {
        guard isSupported, isExactControlUUID(request.uuid), request.displayID != 0 else {
            return .rejectedBeforeDispatch("platform support or stable UUID preflight failed")
        }
        let observation: DisplayConnectionObservation
        do {
            observation = try connectionObservation()
        } catch {
            return .rejectedBeforeDispatch("fresh full-list re-resolution failed before mutation")
        }
        switch request.authorization {
        case .exactUUID:
            let authorized: Bool
            switch request.requestedState {
            case .disconnected:
                authorized = DisplayConnectionRecoveryResolver.authorizesExactDisconnect(
                    uuid: request.uuid,
                    displayID: request.displayID,
                    observation: observation
                )
            case .connected:
                authorized = DisplayConnectionRecoveryResolver.authorizesReservedExactReconnect(
                    uuid: request.uuid,
                    displayID: request.displayID,
                    observation: observation
                )
            }
            guard authorized else {
                return .rejectedBeforeDispatch(
                    "fresh exact-UUID and hardware preflight rejected the mutation"
                )
            }
        case .oneShotRecovery:
            guard request.requestedState == .connected,
                  DisplayConnectionRecoveryResolver.authorizesConsumedRecoveryDispatch(
                    uuid: request.uuid,
                    displayID: request.displayID,
                    observation: observation
                  ) else {
                return .rejectedBeforeDispatch(
                    "consumed recovery capability failed final continuity validation"
                )
            }
        }
        guard !Task.isCancelled else {
            return .rejectedBeforeDispatch("display connection request was cancelled before dispatch")
        }
        switch await setEnabledOutcome(
            request.requestedState == .connected,
            displayID: request.displayID
        ) {
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

}

// MARK: - Disconnect / Reconnect

extension PhysicalDisplayToggleService {
    /// Disconnects a physical display and records a snapshot for later reconnect. Refuses if it
    /// would leave zero active displays, so the user can never black out their only screen.
    @discardableResult
    func disconnect(_ display: DisplayInfo) async -> Result<Void, ToggleError> {
        do {
            _ = try await disconnectForControl(display)
            return .success(())
        } catch let error as DisplayConnectionMutationError {
            return .failure(.mutationFailed(error.message))
        } catch {
            return .failure(.configurationFailed(.failure))
        }
    }

    /// Reconnects a previously disconnected display and drops it from the disconnected set.
    @discardableResult
    func reconnect(uuid: String) async -> Result<Void, ToggleError> {
        do {
            _ = try await reconnectForControl(uuid: uuid)
            return .success(())
        } catch let error as DisplayConnectionMutationError {
            return .failure(.mutationFailed(error.message))
        } catch {
            return .failure(.configurationFailed(.failure))
        }
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
    /// re-enabled them), and confirms pending records only from fresh offline truth. Called from
    /// DisplayManager.refreshDisplays; this topology-event path changes metadata but never a
    /// display's enabled state.
    func reconcile() {
        guard let snapshot = try? connectionStateSnapshot(synchronizePublished: true),
              !snapshot.envelope.records.isEmpty else { return }
        let observation = try? connectionObservation(persistenceSnapshot: snapshot)
        do {
            guard let result = try connectionPersistence.reconcileTopologyMetadata(
                snapshot: snapshot,
                observation: observation
            ) else { return }
            disconnected = connectionPersistence.publishedRecords
            let remainingUUIDs = Set(result.snapshot.envelope.records.map(\.uuid))
            liveReconnectReservationUUIDs.formIntersection(remainingUUIDs)
        } catch {
            disconnected = connectionPersistence.publishedRecords
        }
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

    /// Kept for call-site compatibility only. Topology-event metadata reconciliation belongs to
    /// `reconcile()`; CLI inventory queries are pure reads, and reconnect stays user initiated.
    func restoreIfNoActiveDisplay() {
        // Intentionally empty. Kept as a call-site-compatible safety boundary.
    }

    /// Wake is a hard continuity boundary for persisted display-ID fallback capabilities. It
    /// never writes display state or invents a pending mutation; fresh exact UUID authority stays.
    func reapplyOnWake() async {
        guard isSupported,
              let snapshot = try? connectionStateSnapshot(synchronizePublished: true),
              snapshot.authorizesConnectionMutation else { return }
        let currentState = snapshot.envelope
        var records = currentState.records
        var affectedUUIDs: Set<String> = []
        for index in records.indices {
            guard let capability = records[index].recoveryCapability,
                  [.prepared, .available].contains(capability.state) else { continue }
            records[index].recoveryCapability = capability.changingState(to: .invalidatedByWake)
            affectedUUIDs.insert(records[index].uuid)
        }
        guard !affectedUUIDs.isEmpty else { return }
        _ = try? persistConnectionState(
            PersistedConnectionState(
                records: records,
                pendingUUIDs: currentState.pendingSet,
                reconnectReservationUUIDs: currentState.reconnectReservationSet,
                reconnectPersistenceUncertainUUIDs:
                    currentState.reconnectPersistenceUncertainSet
            ),
            replacing: snapshot,
            quarantiningUUIDs: affectedUUIDs
        )
    }

    // MARK: - Persistence

    private func loadDesired() {
        do {
            let snapshot = try connectionPersistence.snapshot()
            connectionPersistence.adoptPublishedRecords(from: snapshot)
            disconnected = connectionPersistence.publishedRecords
            return
        } catch let error as DisplayConnectionPersistenceError where error == .corrupt {
            // Corrupt authoritative bytes are retained and every connection mutation fails closed.
            return
        } catch {
            // A missing authoritative value is the only state eligible for legacy migration.
        }

        let defaults = UserDefaults.standard
        let legacyRecords: [DisconnectedDisplay]
        if let data = defaults.data(forKey: desiredKey) {
            guard let decoded = try? JSONDecoder().decode(
                [DisconnectedDisplay].self,
                from: data
            ), decoded.allSatisfy({ isExactControlUUID($0.uuid) }),
            Set(decoded.map(\.uuid)).count == decoded.count else { return }
            legacyRecords = decoded
        } else {
            legacyRecords = []
        }
        let recordUUIDs = Set(legacyRecords.map(\.uuid))
        let legacyPending = Set(
            defaults.stringArray(forKey: controlPendingDisconnectUUIDsKey) ?? []
        ).intersection(recordUUIDs)
        let empty = PersistedConnectionState(
            records: [],
            pendingUUIDs: [],
            reconnectReservationUUIDs: []
        )
        let migrated = PersistedConnectionState(
            records: legacyRecords,
            pendingUUIDs: legacyPending,
            reconnectReservationUUIDs: []
        )
        guard let result = try? connectionPersistence.replace(
            oldState: empty,
            proposedState: migrated,
            quarantiningUUIDs: recordUUIDs
        ) else { return }
        connectionPersistence.adoptPublishedRecords(from: result.snapshot)
        disconnected = connectionPersistence.publishedRecords
        if result.disposition == .committedProposed {
            defaults.removeObject(forKey: desiredKey)
            defaults.removeObject(forKey: controlPendingDisconnectUUIDsKey)
        }
        // Relaunch only restores UI/recovery metadata. No display write occurs until a user
        // explicitly requests reconnect through the shared coordinator.
    }
}
