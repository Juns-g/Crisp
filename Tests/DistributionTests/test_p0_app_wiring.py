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


class P0AppWiringTests(unittest.TestCase):
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
            "BrightnessReadSnapshot",
            "fixture-external",
        ):
            self.assertIn(wiring, fixture)
        self.assertNotIn("DisplayServicesSetBrightness", fixture)
        self.assertNotIn("DDCService", fixture)

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
