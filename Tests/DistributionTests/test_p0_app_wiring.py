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
CG_HELPERS = ROOT / "Crisp" / "Services" / "CGHelpers.swift"
CONTROL_CORE = ROOT / "Sources" / "CrispControlCore"
CONTROL_CLI = ROOT / "Sources" / "CrispControlCLI"
PHYSICAL_CLASSIFIER = CONTROL_CORE / "HardwareBackedPhysicalDisplayClassifier.swift"


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
            "connectionCapabilityForControl",
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

    def test_display_connection_control_never_falls_back_to_last_known_display_id(self):
        physical = PHYSICAL_TOGGLE.read_text()
        control = physical[
            physical.index("func dispatchConnectionChange"):
            physical.index("private func resolveControlDisplayIDs")
        ]
        self.assertIn("resolveControlDisplayIDs", control)
        self.assertIn("finalMatches", control)
        self.assertIn("finalMatches.count == 1", control)
        self.assertLess(control.index("finalMatches"), control.index("setEnabledOutcome"))
        self.assertNotIn("record.displayID", control)
        self.assertNotIn("?? record.displayID", control)

    def test_display_connection_requires_positive_hardware_backing_proof(self):
        physical = PHYSICAL_TOGGLE.read_text()
        host = HOST.read_text()
        classifier = PHYSICAL_CLASSIFIER.read_text()

        for required in (
            '@_silgen_name("CGDisplayIOServicePort")',
            "IOObjectConformsTo",
            '"IODisplayConnect"',
            "HardwareBackedPhysicalDisplayEvidence",
            "func isHardwareBackedPhysicalDisplay",
        ):
            self.assertIn(required, physical)
        self.assertNotIn("ddc", classifier.lower())
        self.assertNotIn("vendor", classifier.lower())

        capability = physical[
            physical.index("func connectionCapabilityForControl"):
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
        self.assertIn("isHardwareBackedPhysicalDisplay", observation)

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
            physical.index("/// Finds the current CGDirectDisplayID")
        ]
        self.assertIn("resolveUniqueCurrentID", reconnect)
        self.assertIn("guard let targetID", reconnect)
        self.assertNotIn("record.displayID", reconnect)
        self.assertNotIn("??", reconnect)
        self.assertIn("verifyBackOnline(uuid: uuid)", reconnect)
        self.assertIn("removeDisconnectedRecord(uuid: uuid)", reconnect)
        self.assertLess(
            reconnect.index("verifyBackOnline(uuid: uuid)"),
            reconnect.index("removeDisconnectedRecord(uuid: uuid)"),
        )
        self.assertNotIn("disconnected.removeAll", reconnect)

    def test_gui_disconnect_requires_fresh_unique_exact_uuid_before_state_or_dispatch(self):
        physical = PHYSICAL_TOGGLE.read_text()
        disconnect = physical[
            physical.index("func disconnect(_ display:"):
            physical.index("private func restorePreparedDisconnect")
        ]

        stable_guard = "guard let exactUUID = stableUUID(for: display.displayID) else {"
        initial_resolution = "resolveUniqueCurrentID(uuid: exactUUID)"
        final_resolution = "resolveUniqueCurrentID(uuid: exactUUID)"
        persistence = "persistPendingControlDisconnectUUIDs(preparedPending)"
        dispatch = "setEnabledOutcome(false, displayID: finalDisplayID)"

        self.assertIn(stable_guard, disconnect)
        self.assertIn("return .failure(.displayNotFound)", disconnect)
        self.assertNotIn("uuid: display.displayUUID", disconnect)
        self.assertIn("uuid: exactUUID", disconnect)
        self.assertEqual(disconnect.count(initial_resolution), 2)
        self.assertIn("initialDisplayID == display.displayID", disconnect)
        self.assertIn("finalDisplayID == display.displayID", disconnect)
        self.assertLess(disconnect.index(stable_guard), disconnect.index(persistence))
        self.assertLess(disconnect.index(initial_resolution), disconnect.index(persistence))
        self.assertLess(disconnect.index(persistence), disconnect.rindex(final_resolution))
        self.assertLess(disconnect.rindex(final_resolution), disconnect.rindex(
            "isHardwareBackedPhysicalDisplay(finalDisplayID)"
        ))
        self.assertLess(
            disconnect.rindex("isHardwareBackedPhysicalDisplay(finalDisplayID)"),
            disconnect.rindex("wouldLeaveNoActiveDisplay(finalDisplayID)"),
        )
        self.assertLess(disconnect.rindex("wouldLeaveNoActiveDisplay(finalDisplayID)"),
                        disconnect.index(dispatch))
        self.assertEqual(disconnect.count(dispatch), 1)

    def test_gui_reconnect_rejects_non_exact_and_uses_stable_only_resolver(self):
        physical = PHYSICAL_TOGGLE.read_text()
        reconnect = physical[
            physical.index("func reconnect(uuid:"):
            physical.index("/// Finds the current CGDirectDisplayID")
        ]
        resolver = physical[
            physical.index("private func resolveUniqueCurrentID(for record:"):
            physical.index("/// Soft-reconnects a display")
        ]
        exact_helper = physical[
            physical.index("private func isExactControlUUID"):
            physical.index("// MARK: - Automation control adapter")
        ]

        exact_guard = "guard isExactControlUUID(uuid) else {"
        self.assertIn(exact_guard, reconnect)
        self.assertIn("ControlRequest.isExactDisplayUUID(value)", exact_helper)
        self.assertLess(reconnect.index(exact_guard), reconnect.index("disconnected.first"))
        self.assertLess(reconnect.index(exact_guard), reconnect.index("setEnabled(true"))
        self.assertIn("resolveUniqueCurrentID(uuid: record.uuid)", resolver)
        self.assertIn("guard isExactControlUUID(uuid) else { return nil }", resolver)
        self.assertIn("stableUUID(for: $0) == uuid", resolver)
        self.assertNotIn("{ uuid(for: $0)", resolver)
        self.assertNotIn("?? record.displayID", resolver)

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
        self.assertGreaterEqual(
            restore.count("PhysicalDisplaySafetyPolicy.authorizesEmergencyRecovery"),
            4,
        )
        self.assertNotIn("physicalActiveDisplayCount() == 0", restore)

    def test_gui_reconnect_and_wake_reapply_reprove_hardware_and_unique_identity(self):
        physical = PHYSICAL_TOGGLE.read_text()
        reconnect = physical[
            physical.index("func reconnect(uuid:"):
            physical.index("/// Finds the current CGDirectDisplayID")
        ]
        wake = physical[
            physical.index("private func uniqueOnlineDisplayIDsByUUID"):
            physical.index("// MARK: - Persistence")
        ]

        self.assertIn("resolveUniqueCurrentID", reconnect)
        self.assertIn("isHardwareBackedPhysicalDisplay(targetID)", reconnect)
        self.assertIn(".hardwareBackingUnproven", reconnect)
        self.assertRegex(
            reconnect,
            r"guard isHardwareBackedPhysicalDisplay\(targetID\) else \{\s*"
            r"return \.failure\(\.hardwareBackingUnproven\)\s*\}\s*"
            r"let result = await setEnabled\(true, displayID: targetID\)",
        )
        self.assertLess(
            reconnect.index("isHardwareBackedPhysicalDisplay(targetID)"),
            reconnect.index("setEnabled(true, displayID: targetID)"),
        )
        self.assertLess(
            reconnect.index("setEnabled(true, displayID: targetID)"),
            reconnect.index("removeDisconnectedRecord(uuid: uuid)"),
        )

        self.assertIn("uniqueOnlineDisplayIDsByUUID", wake)
        self.assertIn("private func revalidatedWakeTarget", wake)
        self.assertIn("stableUUID(for:", wake)
        self.assertIn("PhysicalDisplaySafetyPolicy.uniqueExactUUIDDisplayIDs", wake)
        self.assertNotIn("Dictionary(uniqueKeysWithValues", wake)
        self.assertIn("guard initialDisplayID == freshLiveID", wake)
        self.assertGreaterEqual(wake.count("isHardwareBackedPhysicalDisplay"), 2)
        self.assertIn(
            "guard isHardwareBackedPhysicalDisplay(initialLiveID) else { continue }",
            wake,
        )
        self.assertIn(
            "guard isHardwareBackedPhysicalDisplay(freshLiveID) else { return nil }",
            wake,
        )
        self.assertRegex(
            wake,
            r"guard let freshLiveID = revalidatedWakeTarget\(\s*"
            r"uuid: record\.uuid,\s*initialDisplayID: initialLiveID\s*\) else \{\s*"
            r"try\? confirmDisconnectedRecord\(uuid: record\.uuid\)\s*continue\s*\}",
        )
        final_proof = wake.rindex("isHardwareBackedPhysicalDisplay(freshLiveID)")
        dispatch = wake.index("setEnabledOutcome(false, displayID: freshLiveID)")
        self.assertLess(final_proof, dispatch)
        self.assertNotIn("removeDisconnectedRecord", wake)

    def test_last_known_id_fallback_is_zero_screen_emergency_only(self):
        physical = PHYSICAL_TOGGLE.read_text()
        restore = physical[
            physical.index("func restoreIfNoActiveDisplay()"):
            physical.index("func reapplyOnWake()")
        ]
        emergency_name = "recoverAnyViewableDisplayEmergencyOnly"
        emergency = physical[
            physical.index(f"private func {emergency_name}"):
            physical.index("func reapplyOnWake()")
        ]
        restore_function = restore[:restore.index(f"private func {emergency_name}")]

        self.assertEqual(physical.count(f"{emergency_name}()"), 2)
        self.assertEqual(physical.count("?? record.displayID"), 1)
        self.assertIn("?? record.displayID", emergency)
        recovery_guard = "PhysicalDisplaySafetyPolicy.authorizesEmergencyRecovery"
        self.assertEqual(emergency.count(recovery_guard), 2)
        self.assertNotIn("physicalActiveDisplayCount() == 0", emergency)
        self.assertIn("setEnabled(true", emergency)
        self.assertNotIn("reconnect(uuid:", emergency)
        self.assertNotIn("Result<Void, ToggleError>", emergency)
        self.assertIn(
            "guard await verifyBackOnline(uuid: record.uuid) else { return }",
            emergency,
        )
        self.assertIn("try? removeDisconnectedRecord(uuid: record.uuid)", emergency)
        self.assertEqual(emergency.count("removeDisconnectedRecord(uuid: record.uuid)"), 1)
        self.assertNotIn("confirmDisconnectedRecord", emergency)
        self.assertLess(
            emergency.index("guard await verifyBackOnline(uuid: record.uuid) else { return }"),
            emergency.index("try? removeDisconnectedRecord(uuid: record.uuid)"),
        )
        self.assertLess(
            restore_function.rindex(recovery_guard),
            restore_function.index(f"{emergency_name}()"),
        )

    def test_emergency_recovery_dispatches_only_first_stale_id_per_invocation(self):
        physical = PHYSICAL_TOGGLE.read_text()
        emergency = physical[
            physical.index("private func recoverAnyViewableDisplayEmergencyOnly"):
            physical.index("private func uniqueOnlineDisplayIDsByUUID")
        ]
        dispatch = "let result = await setEnabled(true, displayID: targetID)"
        exact_zero_guard = "PhysicalDisplaySafetyPolicy.authorizesEmergencyRecovery"

        self.assertIn(".sorted { lhs, rhs in", emergency)
        self.assertIn(
            "guard let (record, targetID) = candidates.first else { return }",
            emergency,
        )
        self.assertNotIn("for (record, targetID) in candidates", emergency)
        self.assertEqual(emergency.count(dispatch), 1)
        self.assertLess(emergency.rindex(exact_zero_guard), emergency.index(dispatch))
        self.assertIn("guard case .success = result else { return }", emergency)
        self.assertIn(
            "guard await verifyBackOnline(uuid: record.uuid) else { return }",
            emergency,
        )
        self.assertLess(
            emergency.index("guard case .success = result else { return }"),
            emergency.index("guard await verifyBackOnline(uuid: record.uuid) else { return }"),
        )
        self.assertLess(
            emergency.index("guard await verifyBackOnline(uuid: record.uuid) else { return }"),
            emergency.index("try? removeDisconnectedRecord(uuid: record.uuid)"),
        )

    def test_existing_disconnect_retains_recovery_state_for_indeterminate_windowserver_call(self):
        physical = PHYSICAL_TOGGLE.read_text()
        disconnect = physical[
            physical.index("func disconnect(_ display:"):
            physical.index("func reconnect(uuid:")
        ]
        self.assertIn("persistPendingControlDisconnectUUIDs", disconnect)
        self.assertIn("setEnabledOutcome(false", disconnect)
        self.assertIn("verifyDisconnected", disconnect)
        self.assertIn("outcomeIndeterminate", disconnect)
        self.assertLess(
            disconnect.index("persistPendingControlDisconnectUUIDs"),
            disconnect.index("setEnabledOutcome(false"),
        )

    def test_indeterminate_disconnect_keeps_uuid_scoped_recovery_record(self):
        physical = PHYSICAL_TOGGLE.read_text()
        self.assertIn("controlPendingDisconnectUUIDs", physical)
        self.assertIn("pendingControlDisconnectUUIDs", physical)
        self.assertIn("func confirmDisconnectedRecord", physical)

        inventory = physical[
            physical.index("func disconnectedDisplaysForControl"):
            physical.index("func disconnectForControl")
        ]
        self.assertIn("func disconnectedDisplaysForControl() throws", inventory)
        self.assertIn("pendingControlDisconnectUUIDs", inventory)
        self.assertIn("confirmDisconnectedRecord", inventory)
        self.assertNotIn("observation = nil", inventory)
        self.assertNotIn("?? false", inventory)

        reconcile = physical[
            physical.index("func reconcile()"):
            physical.index("func recoverStrandedSoftReconnect")
        ]
        self.assertIn("pendingControlDisconnectUUIDs", reconcile)
        self.assertIn("!pending.contains", reconcile)

        wake = physical[
            physical.index("func reapplyOnWake"):
            physical.index("// MARK: - Persistence")
        ]
        self.assertIn("pendingControlDisconnectUUIDs", wake)
        self.assertIn("!pending.contains", wake)
        self.assertIn("persistPendingControlDisconnectUUIDs", wake)
        self.assertIn("setEnabledOutcome(false", wake)
        self.assertIn("confirmDisconnectedRecord", wake)

        capability = physical[
            physical.index("func connectionCapabilityForControl"):
            physical.index("func disconnectedDisplaysForControl")
        ]
        self.assertIn("pendingControlDisconnectUUIDs", capability)
        self.assertIn("disconnect outcome is indeterminate", capability)

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
