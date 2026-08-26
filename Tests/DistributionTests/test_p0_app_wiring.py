import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
HOST = ROOT / "Crisp" / "Automation" / "CrispControlHost.swift"
BRIGHTNESS = ROOT / "Crisp" / "Services" / "BrightnessService.swift"
BOOST = ROOT / "Crisp" / "Services" / "BrightnessBoostService.swift"
FIXTURE = ROOT / "Sources" / "CrispControlTestHost" / "main.swift"
ROUNDTRIP = ROOT / "scripts" / "test-crispctl-roundtrip.sh"
PHYSICAL_TOGGLE = ROOT / "Crisp" / "Services" / "PhysicalDisplayToggleService.swift"
PHYSICAL_TOGGLE_VIEW = ROOT / "Crisp" / "Views" / "PhysicalDisplayToggleView.swift"
CG_HELPERS = ROOT / "Crisp" / "Services" / "CGHelpers.swift"
CONTROL_CORE = ROOT / "Sources" / "CrispControlCore"
CONTROL_CLI = ROOT / "Sources" / "CrispControlCLI"
PHYSICAL_CLASSIFIER = CONTROL_CORE / "HardwareBackedPhysicalDisplayClassifier.swift"
DISPLAY_RECOVERY = CONTROL_CORE / "DisplayConnectionRecovery.swift"
DISPLAY_COORDINATOR = CONTROL_CORE / "DisplayConnectionCoordinator.swift"
DISPLAY_PERSISTENCE = CONTROL_CORE / "DisplayConnectionPersistence.swift"
DISPLAY_READ_ONLY = CONTROL_CORE / "DisplayConnectionReadOnlyQueries.swift"
COMMAND_DISPATCHER = CONTROL_CORE / "CommandDispatcher.swift"


class P0AppWiringTests(unittest.TestCase):
    def test_display_connection_control_reuses_physical_toggle_service_only(self):
        host = HOST.read_text()
        physical = PHYSICAL_TOGGLE.read_text()
        helpers = CG_HELPERS.read_text()

        for required in (
            "PhysicalDisplayToggleService.shared",
            "func disconnectedDisplays",
            "func disconnectDisplay",
            "func reconnectDisplay",
            "disconnectForControl",
            "reconnectForControl",
            "connectionCapabilitiesForControl",
        ):
            self.assertIn(required, host)
        self.assertIn("DisplayConnectionMutationCoordinator", physical)
        self.assertIn("DisplayConnectionMutationAdapter", physical)
        self.assertIn("dispatchConnectionChange", physical)
        self.assertIn("runWithTimeoutOutcome", physical)
        self.assertIn("case timedOut", helpers)
        self.assertIn("case cancelled", helpers)

        control_plane = host + "".join(
            path.read_text() for root in (CONTROL_CORE, CONTROL_CLI) for path in root.glob("*.swift")
        )
        self.assertNotIn("SLSConfigureDisplayEnabled", control_plane)
        self.assertNotIn("CGBeginDisplayConfiguration", control_plane)
        self.assertEqual(physical.count("SLSConfigureDisplayEnabled(cfg"), 1)

    def test_display_list_batches_connection_capabilities_before_mapping(self):
        host = HOST.read_text()
        displays = host[
            host.index("func displays() async throws"):
            host.index("func disconnectedDisplays() async throws")
        ]

        self.assertEqual(displays.count("connectionCapabilitiesForControl"), 1)
        self.assertLess(
            displays.index("connectionCapabilitiesForControl"),
            displays.index(".map"),
        )
        self.assertNotIn("connectionCapabilityForControl(", displays)
        self.assertIn("connectionCapabilities[display.displayUUID]", displays)

    def test_explicit_cli_reconnect_delegates_unique_uuid_to_shared_coordinator(self):
        dispatcher = COMMAND_DISPATCHER.read_text()
        host = HOST.read_text()
        reconnect = dispatcher[
            dispatcher.index("private func reconnectDisplay("):
            dispatcher.index("private func requireDisconnectAllowed")
        ]
        app_service = host[
            host.index("func reconnectDisplay(displayUUID:"):
            host.index("func readBrightness(displayUUID:")
        ]

        self.assertIn("service.disconnectedDisplays()", reconnect)
        self.assertIn("matches.count == 1", reconnect)
        self.assertIn("service.reconnectDisplay(displayUUID: uuid)", reconnect)
        self.assertNotIn("requireReconnectAllowed", reconnect)
        self.assertLess(
            reconnect.index("matches.count == 1"),
            reconnect.index("service.reconnectDisplay(displayUUID: uuid)"),
        )
        self.assertIn("reconnectForControl(uuid: displayUUID)", app_service)

    def test_rejected_reconnect_rollback_uses_one_envelope_write_and_no_display_call(self):
        physical = PHYSICAL_TOGGLE.read_text()
        coordinator = DISPLAY_COORDINATOR.read_text()
        persistence = DISPLAY_PERSISTENCE.read_text()
        rollback = physical[
            physical.index("func rollbackRejectedReconnectBeforeDispatch"):
            physical.index("func reconcileOrphanedReconnectAttempt")
        ]
        completion = coordinator[
            coordinator.index("private func requireReconnectDispatchCompletion"):
            coordinator.index("private func cleanAlreadyOnlineRecoveryState")
        ]

        self.assertIn("RejectedReconnectRollback.proposedState", rollback)
        self.assertIn(
            "let snapshot = try connectionStateSnapshot(synchronizePublished: true)",
            rollback,
        )
        self.assertLess(
            rollback.index("defer { liveReconnectReservationUUIDs.remove(uuid) }"),
            rollback.index(
                "let snapshot = try connectionStateSnapshot(synchronizePublished: true)"
            ),
        )
        self.assertIn("persistConnectionState(", rollback)
        self.assertNotIn("setEnabled", rollback)
        self.assertNotIn("dispatchConnectionChange", rollback)
        self.assertEqual(persistence.count("try writeEnvelope(proposedState)"), 1)
        self.assertEqual(persistence.count("try writeEnvelope(quarantineState)"), 1)
        self.assertIn("normal success path remains one write", persistence)
        self.assertNotIn("setEnabled", persistence)
        self.assertIn("rollbackRejectedReconnectBeforeDispatch", completion)
        rejected = completion[
            completion.index("case let .rejectedBeforeDispatch"):
            completion.index("case let .failedAfterDispatch")
        ]
        self.assertNotIn("releaseReconnectReservation", rejected)
        self.assertNotIn("markReconnectIndeterminate", rejected)

    def test_display_connection_fallback_is_persisted_capability_scoped_and_enable_only(self):
        physical = PHYSICAL_TOGGLE.read_text()
        core = "".join(path.read_text() for path in CONTROL_CORE.glob("*.swift"))
        control = physical[
            physical.index("func dispatchConnectionChange"):
            physical.index("private func controlAllDisplayIDs")
        ]
        for required in (
            "DisplayConnectionRecoveryCapability",
            "bootSessionID",
            "loginSessionID",
            "wakeSessionID",
            "topologyFingerprint",
            "case available",
            "case invalidatedByWake",
            "case consumed",
            "case indeterminate",
        ):
            self.assertIn(required, core)
        self.assertIn("consumeRecoveryCapability", physical)
        self.assertIn("case .oneShotRecovery", control)
        self.assertIn("requestedState == .connected", control)
        self.assertIn("request.displayID", control)
        self.assertLess(control.index("case .oneShotRecovery"), control.index("setEnabledOutcome"))
        self.assertNotIn("record.displayID", control)
        self.assertNotIn("?? record.displayID", control)
        self.assertNotIn("SLSGetDisplayForUUID", physical)
        self.assertNotIn("CGDisplayGetDisplayIDFromUUID", physical)

    def test_display_connection_requires_positive_hardware_backing_proof(self):
        physical = PHYSICAL_TOGGLE.read_text()
        host = HOST.read_text()
        classifier = PHYSICAL_CLASSIFIER.read_text()

        for required in (
            '@_silgen_name("CGDisplayIOServicePort")',
            "IOObjectConformsTo",
            '"IODisplayConnect"',
            'IOServiceMatching("IOMobileFramebuffer")',
            '"EDID UUID"',
            '"DisplayAttributes"',
            '"ProductAttributes"',
            '"LegacyManufacturerID"',
            '"ProductID"',
            '"SerialNumber"',
            "CGDisplayVendorNumber",
            "CGDisplayModelNumber",
            "CGDisplaySerialNumber",
            "HardwareBackedPhysicalDisplayEvidence",
            "HardwareDisplayIdentity",
            "HardwareFramebufferIdentityEvidence",
            "func isHardwareBackedPhysicalDisplay",
        ):
            self.assertIn(required, physical)
        self.assertNotIn("ddc", classifier.lower())
        self.assertIn("HardwareFramebufferIdentityMatcher.hasUniqueExactMatch", classifier)
        self.assertIn("framebufferSnapshot.filter(\\.hasEDIDUUID)", classifier)
        self.assertIn("candidates.allSatisfy", classifier)
        self.assertIn("coreGraphicsIdentity:", physical)
        self.assertIn("framebufferSnapshot:", physical)
        self.assertNotIn("hasUniqueFramebufferIdentityMatch: true", physical)
        self.assertNotIn("hasEDIDUUID: true", physical)

        snapshot = physical[
            physical.index("private func framebufferSnapshotForPhysicalProof"):
            physical.index("private func uint32PhysicalProofValue")
        ]
        self.assertIn("while service != 0", snapshot)
        self.assertIn(
            "snapshot.append(framebufferIdentityEvidenceForPhysicalProof(service))",
            snapshot,
        )
        self.assertIn('"EDID UUID" as CFString', snapshot)
        self.assertIn("hasEDIDUUID: edidUUID?.isEmpty == false", snapshot)
        self.assertIn("identity: framebufferIdentityForPhysicalProof(service)", snapshot)
        self.assertNotIn("guard let identity else", snapshot)
        enumeration_loop = snapshot[
            snapshot.index("while service != 0"):
            snapshot.index("return snapshot")
        ]
        self.assertNotIn("return nil", enumeration_loop)

        capability = physical[
            physical.index("func connectionCapabilitiesForControl"):
            physical.index("func disconnectedDisplaysForControl")
        ]
        self.assertIn("unsupportedConnectionCapability", capability)
        self.assertIn("hardwareBackingEvidence", capability)
        self.assertNotIn("guard !isVirtual", capability)

        observation = physical[
            physical.index("func connectionObservation()"):
            physical.index("func retainDisconnectedRecord")
        ]
        self.assertIn("hardwareBackedPhysicalUUIDs", observation)
        self.assertIn("unsafePhysicalMutationUUIDs", observation)
        self.assertIn("virtualUUIDs: unsafePhysicalMutationUUIDs", observation)
        self.assertIn("connectionCandidate", observation)
        self.assertIn("candidate.isHardwareBackedPhysical", observation)

        active_count = physical[
            physical.index("private func physicalActiveDisplayCount"):
            physical.index("private func uuid(for")
        ]
        self.assertIn("isHardwareBackedPhysicalDisplay", active_count)
        self.assertNotIn("!virtual.isVirtualDisplay", active_count)

        control_disconnect = host[
            host.index("func disconnectDisplay(displayUUID:"):
            host.index("func reconnectDisplay(displayUUID:")
        ]
        self.assertIn("disconnectForControl(display)", control_disconnect)
        self.assertNotIn("VirtualDisplayService", control_disconnect)

    def test_existing_reconnect_recovery_drops_record_only_after_uuid_online_truth(self):
        physical = PHYSICAL_TOGGLE.read_text()
        reconnect = physical[
            physical.index("func reconnect(uuid:"):
            physical.index("/// Soft-reconnects a display")
        ]
        self.assertIn("reconnectForControl(uuid: uuid)", reconnect)
        self.assertIn("DisplayConnectionMutationError", reconnect)
        self.assertNotIn("setEnabled", reconnect)
        self.assertNotIn("resolveUniqueCurrentID", reconnect)
        self.assertNotIn("disconnected.removeAll", reconnect)

    def test_gui_disconnect_requires_fresh_unique_exact_uuid_before_state_or_dispatch(self):
        physical = PHYSICAL_TOGGLE.read_text()
        disconnect = physical[
            physical.index("func disconnect(_ display:"):
            physical.index("func reconnect(uuid:")
        ]
        control = physical[
            physical.index("func disconnectForControl"):
            physical.index("func reconnectForControl")
        ]

        self.assertIn("disconnectForControl(display)", disconnect)
        self.assertIn("DisplayConnectionMutationError", disconnect)
        self.assertNotIn("setEnabled", disconnect)
        self.assertIn("displayID: display.displayID", control)
        self.assertIn("DisplayConnectionMutationCoordinator", control)

    def test_gui_reconnect_rejects_non_exact_and_uses_stable_only_resolver(self):
        physical = PHYSICAL_TOGGLE.read_text()
        view = PHYSICAL_TOGGLE_VIEW.read_text()
        reconnect = physical[
            physical.index("func reconnect(uuid:"):
            physical.index("/// Soft-reconnects a display")
        ]

        self.assertIn("reconnectForControl(uuid: uuid)", reconnect)
        self.assertNotIn("setEnabled", reconnect)
        self.assertIn("if case .failure(let error) = result", view)
        self.assertIn("errorMessage", view)
        self.assertNotIn("_ = await service.reconnect", view)

    def test_active_physical_enumeration_failure_cannot_authorize_recovery(self):
        physical = PHYSICAL_TOGGLE.read_text()
        active_count = physical[
            physical.index("private func physicalActiveDisplayCount"):
            physical.index("private func hardwareBackingEvidence")
        ]
        would_leave = physical[
            physical.index("func wouldLeaveNoActiveDisplay"):
            physical.index("/// All display IDs known")
        ]
        restore = physical[
            physical.index("func restoreIfNoActiveDisplay()"):
            physical.index("func reapplyOnWake()")
        ]

        self.assertIn("private func physicalActiveDisplayCount() -> Int?", active_count)
        self.assertGreaterEqual(active_count.count("return nil"), 2)
        self.assertIn("return 0", active_count)
        self.assertIn("PhysicalDisplaySafetyPolicy.shouldRefuseDisconnect", would_leave)
        self.assertNotIn("?? 0", would_leave)
        self.assertNotIn("setEnabled", restore)
        self.assertNotIn("physicalActiveDisplayCount() == 0", restore)

    def test_gui_reconnect_reproves_hardware_and_wake_invalidates_recovery(self):
        physical = PHYSICAL_TOGGLE.read_text()
        dispatch = physical[
            physical.index("func dispatchConnectionChange"):
            physical.index("private func controlAllDisplayIDs")
        ]
        wake = physical[
            physical.index("func reapplyOnWake"):
            physical.index("// MARK: - Persistence")
        ]

        self.assertIn("DisplayConnectionRecoveryResolver", dispatch)
        self.assertIn("authorizesExactDisconnect", dispatch)
        self.assertIn("authorizesConsumedRecoveryDispatch", dispatch)
        self.assertLess(dispatch.index("DisplayConnectionRecoveryResolver"),
                        dispatch.index("setEnabledOutcome"))

        self.assertIn(
            "let snapshot = try? connectionStateSnapshot(synchronizePublished: true)",
            wake,
        )
        self.assertIn("changingState(to: .invalidatedByWake)", wake)
        self.assertIn("quarantiningUUIDs: affectedUUIDs", wake)
        self.assertNotIn("markRecoveryCapabilityIndeterminate", wake)
        self.assertNotIn("pendingControlDisconnectUUIDs", wake)
        self.assertNotIn("setEnabledOutcome", wake)
        self.assertNotIn("SLSConfigureDisplayEnabled", wake)

    def test_wake_continuity_uses_public_mach_sleep_offset_clock(self):
        physical = PHYSICAL_TOGGLE.read_text()
        wake_token = physical[
            physical.index("private func currentWakeSessionID"):
            physical.index("private func sysctlString")
        ]

        self.assertEqual(wake_token.count("mach_continuous_time()"), 2)
        self.assertIn("mach_absolute_time()", wake_token)
        self.assertIn("mach_timebase_info", wake_token)
        self.assertIn("DisplayConnectionMachSleepOffsetToken.make", wake_token)
        self.assertNotIn("kern.waketime", physical)
        self.assertNotIn("IOPMGetLastWakeTime", physical)

    def test_read_only_refresh_never_auto_enables_a_recovery_record(self):
        physical = PHYSICAL_TOGGLE.read_text()
        restore = physical[
            physical.index("func restoreIfNoActiveDisplay()"):
            physical.index("func reapplyOnWake")
        ]
        self.assertNotIn("setEnabled", restore)
        self.assertNotIn("record.displayID", restore)
        self.assertNotIn("recoverAnyViewableDisplayEmergencyOnly", physical)
        self.assertNotIn("?? record.displayID", physical)

    def test_orphan_reconnect_reconciliation_is_explicit_readback_only_and_process_owned(self):
        physical = PHYSICAL_TOGGLE.read_text()
        coordinator = DISPLAY_COORDINATOR.read_text()
        view = PHYSICAL_TOGGLE_VIEW.read_text()

        adapter = physical[
            physical.index("func reserveReconnect"):
            physical.index("func dispatchConnectionChange")
        ]
        orphan = adapter[
            adapter.index("func reconcileOrphanedReconnectAttempt"):
            adapter.index("private func changeRecoveryCapabilityState")
        ]
        explicit_reconnect = coordinator[
            coordinator.index("public func reconnect(uuid:"):
            coordinator.index("private func reconnectDispatchPlan")
        ]
        for required in (
            "liveReconnectReservationUUIDs",
            "DisplayConnectionRecoveryResolver.orphanedReconnectResolution",
            "connectionObservation()",
            "nextReservations.remove(uuid)",
            "persistConnectionState",
        ):
            self.assertIn(required, physical)
        self.assertIn("reconcileOrphanedReconnectAttempt", explicit_reconnect)
        self.assertIn("fresh explicit user decision", explicit_reconnect)
        self.assertNotIn("dispatchConnectionChange", orphan)
        self.assertNotIn("setEnabled", orphan)
        self.assertLess(orphan.index("persistConnectionState"), orphan.index("return .reconciled"))

        read_only_sections = (
            physical[
                physical.index("func disconnectedDisplaysForControl"):
                physical.index("func disconnectForControl")
            ],
            physical[
                physical.index("func reconcile()"):
                physical.index("func recoverStrandedSoftReconnect")
            ],
            physical[physical.index("private func loadDesired"):],
        )
        for section in read_only_sections:
            self.assertNotIn("reconcileOrphanedReconnectAttempt", section)
            self.assertNotIn("dispatchConnectionChange", section)

        gui_reconnect = view[
            view.index("private func reconnect("):
            view.index("private struct DisconnectedDisplayRow")
        ]
        self.assertNotIn("Task.sleep", gui_reconnect)
        self.assertNotIn("errorMessages[record.uuid] = nil", gui_reconnect.split("Task {", 1)[1])

    def test_quarantine_reconciliation_is_explicit_readback_only_and_precedes_dispatch(self):
        physical = PHYSICAL_TOGGLE.read_text()
        coordinator = DISPLAY_COORDINATOR.read_text()
        persistence = DISPLAY_PERSISTENCE.read_text()
        reconnect = coordinator[
            coordinator.index("public func reconnect(uuid:"):
            coordinator.index("private func reconcileQuarantineIfNeeded")
        ]
        quarantine_flow = coordinator[
            coordinator.index("private func reconcileQuarantineIfNeeded"):
            coordinator.index("private func reconnectDispatchPlan")
        ]
        quarantine = physical[
            physical.index("func reconcileQuarantinedReconnectAttempt"):
            physical.index("private func changeRecoveryCapabilityState")
        ]

        self.assertLess(
            reconnect.index("reconcileQuarantineIfNeeded"),
            reconnect.index("DisplayConnectionRecoveryResolver.reconnectResolution"),
        )
        self.assertLess(
            reconnect.index("reconcileQuarantineIfNeeded"),
            reconnect.index("reserveReconnect"),
        )
        self.assertLess(
            reconnect.index("reconcileQuarantineIfNeeded"),
            reconnect.index("dispatchConnectionChange"),
        )
        self.assertIn("reconnectPersistenceUncertainUUIDs.contains(uuid)", quarantine_flow)
        self.assertIn("try await adapter.reconcileQuarantinedReconnectAttempt", quarantine_flow)
        self.assertIn("finishQuarantinedReconnectAttempt", quarantine_flow)
        self.assertIn("mutationDispatched: false", quarantine_flow)
        self.assertIn("explicit user decision is required", quarantine_flow)
        already_online = quarantine_flow[
            quarantine_flow.index("case .alreadyOnline:"):
            quarantine_flow.index("case .liveAttempt:")
        ]
        self.assertIn("adapter.connectionObservation()", already_online)
        self.assertIn(
            "DisplayConnectionRecoveryResolver.uniqueOnlineHardwareCandidate",
            already_online,
        )
        self.assertIn("recoveryStateIsAbsent", already_online)
        self.assertGreaterEqual(already_online.count("try Task.checkCancellation()"), 2)
        self.assertLess(
            already_online.index("try Task.checkCancellation()"),
            already_online.index("adapter.connectionObservation()"),
        )
        self.assertLess(
            already_online.index("recoveryStateIsAbsent"),
            already_online.rindex("try Task.checkCancellation()"),
        )
        self.assertLess(
            already_online.rindex("try Task.checkCancellation()"),
            already_online.index("return success"),
        )
        self.assertLess(
            already_online.index("adapter.connectionObservation()"),
            already_online.index("return success"),
        )
        self.assertLess(
            already_online.index(
                "DisplayConnectionRecoveryResolver.uniqueOnlineHardwareCandidate"
            ),
            already_online.index("return success"),
        )

        self.assertEqual(quarantine.count("connectionStateSnapshot("), 1)
        self.assertEqual(quarantine.count("connectionObservation("), 1)
        self.assertIn("liveQuarantineReconciliationUUIDs", quarantine)
        self.assertIn("snapshot.authority == .durable", quarantine)
        self.assertIn("connectionPersistence.reconcileQuarantinedReconnect", quarantine)
        self.assertIn("result.writeResult.disposition == .committedProposed", quarantine)
        self.assertNotIn("dispatchConnectionChange", quarantine)
        self.assertNotIn("setEnabled", quarantine)
        self.assertNotIn("SLSConfigureDisplayEnabled", quarantine)

        authority = persistence[
            persistence.index("public var authorizesConnectionMutation"):
            persistence.index("public enum ConnectionPersistenceDisposition")
        ]
        self.assertIn(
            "authority == .durable && envelope.reconnectPersistenceUncertainSet.isEmpty",
            authority,
        )

        for section in (
            physical[
                physical.index("func connectionCapabilitiesForControl"):
                physical.index("func disconnectForControl")
            ],
            physical[
                physical.index("func reconcile()"):
                physical.index("func recoverStrandedSoftReconnect")
            ],
            physical[
                physical.index("func reapplyOnWake"):
                physical.index("// MARK: - Persistence")
            ],
        ):
            self.assertNotIn("reconcileQuarantinedReconnectAttempt", section)
            self.assertNotIn("dispatchConnectionChange", section)

    def test_shared_disconnect_retains_recovery_state_for_indeterminate_windowserver_call(self):
        physical = PHYSICAL_TOGGLE.read_text()
        adapter = physical[
            physical.index("func retainDisconnectedRecord"):
            physical.index("private func controlAllDisplayIDs")
        ]
        gui_disconnect = physical[
            physical.index("func disconnect(_ display:"):
            physical.index("func reconnect(uuid:")
        ]
        self.assertIn("persistConnectionState", adapter)
        self.assertIn("markRecoveryCapabilityIndeterminate", adapter)
        self.assertIn("disconnectForControl(display)", gui_disconnect)
        self.assertLess(
            adapter.index("persistConnectionState"),
            adapter.index("func dispatchConnectionChange"),
        )

    def test_indeterminate_disconnect_keeps_uuid_scoped_recovery_record(self):
        physical = PHYSICAL_TOGGLE.read_text()
        self.assertIn("controlPendingDisconnectUUIDs", physical)
        self.assertIn("currentState.pendingSet", physical)
        self.assertIn("func confirmDisconnectedRecord", physical)

        inventory = physical[
            physical.index("func disconnectedDisplaysForControl"):
            physical.index("func disconnectForControl")
        ]
        self.assertIn("func disconnectedDisplaysForControl() throws", inventory)
        self.assertIn("DisplayConnectionReadOnlyQueries.disconnectedDisplays", inventory)
        self.assertNotIn("confirmDisconnectedRecord", inventory)
        self.assertNotIn("removeDisconnectedRecord", inventory)
        self.assertNotIn("persistConnectionState", inventory)

        reconcile = physical[
            physical.index("func reconcile()"):
            physical.index("func recoverStrandedSoftReconnect")
        ]
        self.assertIn("connectionObservation", reconcile)
        self.assertIn("reconcileTopologyMetadata", reconcile)
        self.assertNotIn("setEnabled", reconcile)

        wake = physical[
            physical.index("func reapplyOnWake"):
            physical.index("// MARK: - Persistence")
        ]
        self.assertIn("changingState(to: .invalidatedByWake)", wake)
        self.assertNotIn("markRecoveryCapabilityIndeterminate", wake)
        self.assertNotIn("pendingControlDisconnectUUIDs", wake)
        self.assertNotIn("setEnabledOutcome", wake)

        mark_indeterminate = physical[
            physical.index("func markRecoveryCapabilityIndeterminate"):
            physical.index("func removeDisconnectedRecord")
        ]
        self.assertIn("currentState.pendingSet", mark_indeterminate)
        self.assertIn("persistConnectionState", mark_indeterminate)

        capability = physical[
            physical.index("func connectionCapabilitiesForControl"):
            physical.index("func disconnectedDisplaysForControl")
        ]
        self.assertIn("DisplayConnectionReadOnlyQueries.connectedCapabilities", capability)
        self.assertNotIn("removeDisconnectedRecord", capability)
        self.assertNotIn("persistConnectionState", capability)
        self.assertIn("disconnect outcome is indeterminate", DISPLAY_READ_ONLY.read_text())

    def test_old_records_have_no_fallback_authority_but_online_truth_can_clean_them(self):
        physical = PHYSICAL_TOGGLE.read_text()
        recovery = DISPLAY_RECOVERY.read_text()
        record = recovery[
            recovery.index("struct DisplayConnectionPersistedRecord"):
            recovery.index("struct DisplayConnectionPersistenceEnvelope")
        ]
        reconcile = physical[
            physical.index("func reconcile()"):
            physical.index("func recoverStrandedSoftReconnect")
        ]

        self.assertIn("recoveryCapability", record)
        self.assertIn("DisplayConnectionRecoveryCapability?", record)
        self.assertIn(
            "typealias DisconnectedDisplay = DisplayConnectionPersistedRecord",
            physical,
        )
        self.assertIn("connectionObservation", reconcile)
        self.assertIn("reconcileTopologyMetadata", reconcile)
        self.assertNotIn("setEnabled", reconcile)

    def test_recovery_record_and_pending_marker_use_one_authoritative_envelope(self):
        physical = PHYSICAL_TOGGLE.read_text()
        recovery = DISPLAY_RECOVERY.read_text()
        self.assertIn("struct DisplayConnectionPersistenceEnvelope", recovery)
        self.assertIn(
            "typealias PersistedConnectionState = DisplayConnectionPersistenceEnvelope",
            physical,
        )
        self.assertIn("connectionRecoveryStateKey", physical)
        persistence = physical[
            physical.index("func persistConnectionState"):
            physical.index("func pendingSoftReconnectUUIDs")
        ]
        self.assertIn("connectionPersistence.replace", persistence)
        self.assertIn("oldState: oldSnapshot.envelope", persistence)
        self.assertIn("result.disposition == .committedProposed", persistence)
        boundary = DISPLAY_PERSISTENCE.read_text()
        self.assertIn("func snapshot()", boundary)
        self.assertIn("func replace(", boundary)
        self.assertIn("decodeOneRead()", boundary)

        remove = physical[
            physical.index("func removeDisconnectedRecord"):
            physical.index("func dispatchConnectionChange")
        ]
        self.assertIn("persistConnectionState", remove)
        self.assertNotIn("persistDisconnectedForControl", remove)
        self.assertNotIn("persistPendingControlDisconnectUUIDs", remove)

    def test_automation_host_wires_p0_to_existing_app_services(self):
        text = HOST.read_text()
        for required in (
            "func readBrightnessState",
            "func setExtraBrightness",
            "func setHDR",
            "BrightnessBoostService.shared.isEligible",
            "BrightnessBoostService.shared.isEnabled",
            "boost.setEnabled",
            "BrightnessBoostService.shared.isEligibleForHDRToggle",
            "BrightnessBoostService.shared.isHDREnabled",
            "BrightnessBoostService.shared.setHDRPreference",
            "boost.controlHeadroomSnapshot",
            "VirtualDisplayService.shared.isVirtualDisplay",
        ):
            self.assertIn(required, text)

    def test_extra_brightness_control_does_not_overload_boolean_disable_outcome(self):
        host = HOST.read_text()
        boost = BOOST.read_text()
        setter = host[host.index("func setExtraBrightness"):host.index("func setHDR")]
        self.assertIn("boost.setEnabledForControl", setter)
        self.assertIn("mutationOutcome.resolvedControlResult", setter)
        self.assertNotIn("guard try await boost.setEnabled", setter)
        self.assertIn("func setEnabledForControl", boost)
        self.assertIn("ExtraBrightnessControlMutationOutcome.classify", boost)

    def test_control_brightness_above_100_uses_gui_path_and_preserves_logical_state(self):
        text = BRIGHTNESS.read_text()
        control_write = text[text.index("func writeBrightnessForControl"):]
        self.assertIn("await setBrightness(percent, for: display)", control_write)
        self.assertNotIn("min(100, percent)", control_write)
        control_read = text[text.index("func readBrightnessStateForControl"):]
        self.assertIn("display.brightness > 100", control_read)
        self.assertIn("getInternalBrightness()", control_read)
        self.assertIn("controlBackend(for: display) == .ddc", control_read)
        self.assertIn("readExternalDDCBrightnessForControl", control_read)
        self.assertIn("hardwareReadbackPercent: hardware", control_read)

    def test_headroom_visibility_is_narrow_and_read_only(self):
        text = BOOST.read_text()
        self.assertIn("func controlHeadroomSnapshot", text)
        self.assertIn("EDRHeadroomSnapshot", text)
        self.assertIn("appliedFactorCommits", text)
        self.assertIn("appliedFactor:", text)

    def test_external_applied_factor_is_published_only_after_queue_commit(self):
        boost = BOOST.read_text()
        brightness = BRIGHTNESS.read_text()
        queued = brightness[brightness.index("func setBoostFactor("):]
        self.assertIn("completion: @escaping @Sendable (Bool) -> Void", queued)
        self.assertLess(
            queued.index("setSoftwareBrightness"),
            queued.index("completion(true)"),
        )
        self.assertIn("completion(false)", queued)
        self.assertIn("private func queueExternalFactor", boost)
        self.assertIn("appliedFactorCommits.begin", boost)
        self.assertIn("appliedFactorCommits.complete", boost)
        collapse = boost[boost.index("private func collapseAndDisable"):boost.index("private func finishDisable")]
        sync = boost[boost.index("func syncOverlay"):boost.index("// MARK: - Lifecycle")]
        reapply = boost[boost.index("func reapplyAll"):boost.index("/// Quit:")]
        self.assertIn("queueExternalFactor", collapse)
        self.assertIn("queueExternalFactor", sync)
        self.assertIn("queueExternalFactor", reapply)

    def test_external_boost_queue_rechecks_uuid_before_transfer_table_write(self):
        boost = BOOST.read_text()
        brightness = BRIGHTNESS.read_text()
        self.assertIn("private func queueExternalFactor", boost)
        self.assertGreaterEqual(boost.count("queueExternalFactor("), 4)
        helper = brightness[brightness.index("func setBoostFactor("):]
        self.assertIn("expectedDisplayUUID: String", helper)
        self.assertIn(
            "Self.displayUUIDString(for: displayID) == expectedDisplayUUID",
            helper,
        )
        terminal = brightness[brightness.index("func setBoostFactorForControl"):]
        self.assertIn("expectedDisplayUUID: String", terminal)
        self.assertIn(
            "Self.displayUUIDString(for: displayID) == expectedDisplayUUID",
            terminal,
        )

    def test_external_hdr_live_state_remains_readable_when_toggle_is_not_writable(self):
        boost = BOOST.read_text()
        host = HOST.read_text()
        self.assertIn("func controlHDRState", boost)
        self.assertIn("func readState", boost)
        self.assertIn("monitorPanel.readState", boost)
        self.assertIn("guard let liveState = boost.controlHDRState(for: display)", host)
        self.assertIn("state: .readable", host)
        self.assertIn("enabled: liveState", host)

    def test_extra_brightness_wires_generation_guard_and_awaitable_terminal_disable(self):
        text = BOOST.read_text()
        for required in (
            "BoostTransitionCoordinator",
            "boostTransitions.begin",
            "await collapseAndDisable",
            "boostTransitions.completeDisable",
            "currentDisplayMatches",
            "headroomMaySync",
            "private func restoreIdentityFactor",
            "await BrightnessService.shared.setBoostFactorForControl(",
        ):
            self.assertIn(required, text)
        self.assertGreaterEqual(text.count("await restoreIdentityFactor(for: display)"), 2)
        brightness = BRIGHTNESS.read_text()
        self.assertIn("func setBoostFactorForControl", brightness)
        terminal = brightness[brightness.index("func setBoostFactorForControl"):]
        self.assertIn("withCheckedContinuation", terminal)
        self.assertLess(
            terminal.index("setSoftwareBrightness"),
            terminal.index("continuation.resume(returning: true)"),
        )
        reconfigure = text[text.index("@objc private func screenParametersChanged"):]
        self.assertIn("boostTransitions = BoostTransitionCoordinator()", reconfigure)
        self.assertIn("hdrMutations = HDRMutationCoordinator()", reconfigure)
        self.assertIn("maxAnimators.values.forEach", reconfigure)
        self.assertIn("headroomPollTask?.cancel()", reconfigure)
        self.assertIn("headroomPollTask = nil", reconfigure)
        self.assertIn("headroomLossSince.removeAll()", reconfigure)
        self.assertIn("activeBoostDisplays.removeAll()", reconfigure)
        self.assertIn("fastPollUntil = nil", reconfigure)

    def test_external_boost_waits_for_edr_headroom_after_hdr_readback(self):
        text = BOOST.read_text()
        enable = text[text.index("func setEnabled"):text.index("private func collapseAndDisable")]
        self.assertIn("EDRHeadroomSettlement.wait", enable)
        self.assertIn("transitionAccepts(token, display: display)", enable)
        self.assertIn("controlHDRState(for: display) == true", enable)
        self.assertIn("case let .ready(potentialHeadroom)", enable)
        self.assertIn("case .timedOut, .capabilityLost", enable)
        self.assertIn("case .invalidated", enable)
        self.assertIn("setHDRMode(false, for: display, requiring: token)", enable)
        self.assertIn("requiring boostToken: BoostTransitionToken? = nil", text)
        self.assertIn("guard transitionAccepts(boostToken, display: display)", text)
        self.assertLess(enable.index("await setHDRMode(true"), enable.index("EDRHeadroomSettlement.wait"))
        self.assertLess(enable.index("EDRHeadroomSettlement.wait"), enable.index("sliderMax"))

    def test_command_owned_settlement_does_not_swallow_cancellation(self):
        host = HOST.read_text()
        extra = host[host.index("func setExtraBrightness"):host.index("func setHDR")]
        hdr = host[host.index("func setHDR"):host.index("private func connectedDisplay")]
        for settle in (extra, hdr):
            self.assertNotIn("try? await Task.sleep", settle)
            self.assertIn("try await Task.sleep", settle)

        boost = BOOST.read_text()
        enable = boost[boost.index("func setEnabled"):boost.index("private func collapseAndDisable")]
        self.assertIn("try await EDRHeadroomSettlement.wait", enable)
        self.assertIn("try await Task.sleep", enable)
        self.assertNotIn("try? await Task.sleep", enable)
        self.assertNotIn("!Task.isCancelled", enable)

    def test_extra_brightness_off_can_run_cleanup_after_eligibility_loss(self):
        host = HOST.read_text()
        setter = host[host.index("func setExtraBrightness"):host.index("func setHDR")]
        self.assertIn("needsDisableCleanup(for: display)", setter)
        self.assertIn("!enabled", setter)
        self.assertIn("isEligible(display)", setter)

        boost = BOOST.read_text()
        cleanup = boost[
            boost.index("func needsDisableCleanup"):boost.index("// MARK: - Toggle")
        ]
        for required in (
            "isEnabled(for: display)",
            "display.maxBrightness > 100",
            "display.brightness > 100",
            "activeBoostDisplays.contains",
            "collapsingDisplays.contains",
        ):
            self.assertIn(required, cleanup)

    def test_monitor_panel_access_is_runtime_checked_and_routes_only_after_verified_readback(self):
        text = BOOST.read_text()
        self.assertNotIn('value(forKey: "preferHDRModes")', text)
        self.assertNotIn('value(forKey: "hasHDRModes")', text)
        self.assertNotIn('value(forKey: "displayID")', text)
        self.assertNotIn("methodSignature(for:", text)
        for required in (
            "responds(to: selector)",
            "HDRMutationCoordinator",
            "verifiedRoutingState",
            "let dimmed = controlHDRState(for: display) == true",
            "monitorPanelIdentity",
            "expectedIdentity:",
            "class_getInstanceMethod",
            "method_getNumberOfArguments",
            "method_copyReturnType",
            "method_copyArgumentType",
            "method_getImplementation",
            "MonitorPanelABISignatureValidator.isCompatible",
            ".displaysGetter",
            ".displayIDGetter",
            ".boolGetter",
            ".boolSetter",
        ):
            self.assertIn(required, text)

    def test_hdr_off_requires_terminal_boost_identity_before_monitor_panel_setter(self):
        text = BOOST.read_text()
        hdr = text[text.index("func setHDRPreference"):text.index("private var hdrSupportCache")]
        self.assertIn("let hadBoostState =", hdr)
        self.assertIn("guard try await setEnabled(false, for: display) else { return false }", hdr)
        for required in (
            "currentDisplayMatches(display)",
            "!collapsingDisplays.contains(displayID)",
            "!isEnabled(for: display)",
            "display.brightness <= 100.001",
            "display.maxBrightness <= 100.001",
            "appliedFactorCommits.isCommitted(",
            "factor: 1",
        ):
            self.assertIn(required, hdr)
        self.assertLess(hdr.index("appliedFactorCommits.isCommitted("), hdr.rindex("setHDRMode(false"))

    def test_independent_process_fixture_covers_all_p0_commands_without_hardware(self):
        fixture = FIXTURE.read_text()
        script = ROUNDTRIP.read_text()
        for command in (
            "displays disconnected",
            "displays reconnect",
            "extra-brightness get",
            "extra-brightness set",
            "hdr get",
            "hdr set",
            "brightness get-all",
            "brightness set-all",
        ):
            self.assertIn(command, script)
        for wiring in (
            "func setExtraBrightness",
            "func setHDR",
            "func disconnectedDisplays",
            "func disconnectDisplay",
            "func reconnectDisplay",
            "BrightnessReadSnapshot",
            "Fixture External",
            "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
        ):
            self.assertIn(wiring, fixture)
        self.assertNotIn("DisplayServicesSetBrightness", fixture)
        self.assertNotIn("DDCService", fixture)
        self.assertNotIn("SLSConfigureDisplayEnabled", fixture)
        self.assertNotIn("displays disconnect fixture-external", script)
        self.assertIn('EXTERNAL_UUID="$(jq -er', script)
        self.assertIn(
            "select(.isBuiltin == false and .isVirtual == false)",
            script,
        )
        self.assertIn('displays disconnect "$EXTERNAL_UUID"', script)
        self.assertLess(script.index('LIST="$('), script.index('EXTERNAL_UUID="$(jq -er'))
        self.assertLess(
            script.index('EXTERNAL_UUID="$(jq -er'),
            script.index('displays disconnect "$EXTERNAL_UUID"'),
        )
        self.assertIn('DISCONNECTED_UUID="$(jq -r', script)
        self.assertIn('[ "$DISCONNECTED_UUID" = "$EXTERNAL_UUID" ]', script)
        self.assertIn(".result.displays == []", script)
        self.assertIn("requestedConnectionState == \"disconnected\"", script)
        self.assertIn("requestedConnectionState == \"connected\"", script)

    def test_headless_roundtrip_uses_swiftpm_reported_bin_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            tools = root / "tools"
            bin_path = root / "scratch" / "build" / "arm64-apple-macosx" / "debug"
            tools.mkdir()
            swift_log = root / "swift.log"
            cli_log = root / "cli.log"

            def write_executable(name, source):
                path = tools / name
                path.write_text(source)
                path.chmod(0o755)

            write_executable(
                "swift",
                "#!/bin/bash\n"
                "set -eu\n"
                'printf \'%s\\n\' "$*" >> "$SWIFT_LOG"\n'
                'if [[ " $* " == *" --show-bin-path "* ]]; then\n'
                '  printf \'%s\\n\' "$FAKE_BIN_PATH"\n'
                "  exit 0\n"
                "fi\n"
                'mkdir -p "$FAKE_BIN_PATH"\n'
                'cat > "$FAKE_BIN_PATH/crisp-control-test-host" <<\'HOST\'\n'
                "#!/bin/bash\n"
                "exec python3 - \"$1\" <<'PY'\n"
                "import socket\n"
                "import signal\n"
                "import sys\n"
                "import time\n"
                "signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))\n"
                "sock = socket.socket(socket.AF_UNIX)\n"
                "sock.bind(sys.argv[1])\n"
                "sock.listen()\n"
                "time.sleep(30)\n"
                "PY\n"
                "HOST\n"
                'cat > "$FAKE_BIN_PATH/crispctl" <<\'CLI\'\n'
                "#!/bin/sh\n"
                'printf \'%s\\n\' "$*" >> "$CLI_LOG"\n'
                "printf '{}\\n'\n"
                'case " $* " in\n'
                '  *" brightness set-all "*" --allow-unrestorable "*) ;;\n'
                '  *" brightness set-all "*) exit 4 ;;\n'
                "esac\n"
                "CLI\n"
                'chmod 755 "$FAKE_BIN_PATH/crisp-control-test-host" "$FAKE_BIN_PATH/crispctl"\n',
            )
            write_executable("jq", "#!/bin/sh\nexit 0\n")
            write_executable("stat", "#!/bin/sh\nprintf '600\\n'\n")
            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{tools}:{environment['PATH']}",
                    "FAKE_BIN_PATH": str(bin_path),
                    "SWIFT_LOG": str(swift_log),
                    "CLI_LOG": str(cli_log),
                }
            )

            result = subprocess.run(
                ["/bin/bash", str(ROUNDTRIP), str(root / "scratch")],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                timeout=45,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("CRISPCTL_HEADLESS_ROUNDTRIP_OK", result.stdout)
            self.assertEqual(
                swift_log.read_text().splitlines(),
                [
                    f"build --disable-sandbox --scratch-path {root / 'scratch'}",
                    f"build --disable-sandbox --scratch-path {root / 'scratch'} --show-bin-path",
                ],
            )
            self.assertGreaterEqual(len(cli_log.read_text().splitlines()), 10)


if __name__ == "__main__":
    unittest.main()
