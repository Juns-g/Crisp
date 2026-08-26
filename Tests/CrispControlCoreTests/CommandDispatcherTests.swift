import XCTest
@testable import CrispControlCore

final class CommandDispatcherTests: XCTestCase {
    func testReadOnlyCommandsReturnDeterministicDisplayData() async throws {
        let service = MockControlService(displays: [.builtin])
        let dispatcher = ControlCommandDispatcher(service: service, appVersion: "1.5.0")

        let version = await dispatcher.handle(ControlRequest(requestID: "v", command: "version"))
        let status = await dispatcher.handle(ControlRequest(requestID: "s", command: "status"))
        let list = await dispatcher.handle(ControlRequest(requestID: "l", command: "displays.list"))
        let get = await dispatcher.handle(request("displays.get", selector: "main"))
        let capabilities = await dispatcher.handle(request("displays.capabilities", selector: "builtin"))
        let brightness = await dispatcher.handle(request("brightness.get", selector: "uuid-built-in"))

        XCTAssertEqual(version.result?["appVersion"], .string("1.5.0"))
        XCTAssertEqual(status.result?["running"], .bool(true))
        XCTAssertEqual(list.result?["displays"]?[0]?["uuid"], .string("uuid-built-in"))
        XCTAssertEqual(get.result?["display"]?["name"], .string("Built-in Display"))
        XCTAssertEqual(capabilities.result?["brightness"]?["backend"], .string("DisplayServices"))
        XCTAssertEqual(brightness.result?["percent"], .number(42))
    }

    func testBrightnessSetWritesThenReadsBackBeforeSuccess() async throws {
        let service = MockControlService(displays: [.builtin], readValues: [42, 50.04])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            request("brightness.set", selector: "builtin", percent: 50)
        )

        XCTAssertTrue(response.ok)
        let writes = await service.writes
        XCTAssertEqual(writes, [50])
        XCTAssertEqual(response.result?["requestedPercent"], .number(50))
        XCTAssertEqual(response.result?["appliedPercent"], .number(50))
        XCTAssertEqual(response.result?["readbackPercent"], .number(50.04))
        XCTAssertEqual(response.result?["verification"], .string("verified"))
        XCTAssertEqual(response.result?["backend"], .string("DisplayServices"))
    }

    func testBrightnessSetRejectsOutOfCapabilityRangeWithoutWriting() async throws {
        let service = MockControlService(displays: [.builtin])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            request("brightness.set", selector: "builtin", percent: 101)
        )

        XCTAssertEqual(response.error?.code, .invalidArguments)
        let writes = await service.writes
        XCTAssertEqual(writes, [])
    }

    func testUnsupportedBrightnessIsAnError() async throws {
        let service = MockControlService(displays: [.unsupportedExternal])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            request("brightness.get", selector: "uuid-external")
        )

        XCTAssertEqual(response.error?.code, .unsupportedCapability)
        XCTAssertEqual(response.error?.details?["reason"], .string("No controllable backend"))
    }

    func testReadOnlyCapabilityRejectsSetWithoutWriting() async throws {
        let service = MockControlService(displays: [.readOnlyExternal])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            request("brightness.set", selector: "uuid-read-only", percent: 30)
        )

        XCTAssertEqual(response.error?.code, .unsupportedCapability)
        let writes = await service.writes
        XCTAssertEqual(writes, [])
    }

    func testAmbiguousSelectorReturnsCandidates() async throws {
        let service = MockControlService(displays: [.deskA, .deskB])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            request("displays.get", selector: "Desk")
        )

        XCTAssertEqual(response.error?.code, .ambiguousSelector)
        XCTAssertEqual(response.error?.details?["candidates"]?[0]?["uuid"], .string("uuid-a"))
        XCTAssertEqual(response.error?.details?["candidates"]?[1]?["uuid"], .string("uuid-b"))
    }

    func testWriteVerificationFailureNeverReturnsSuccess() async throws {
        let service = MockControlService(displays: [.builtin], readValues: [42, 43])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            request("brightness.set", selector: "builtin", percent: 50)
        )

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, .writeVerificationFailed)
        XCTAssertEqual(response.error?.details?["requestedPercent"], .number(50))
        XCTAssertEqual(response.error?.details?["readbackPercent"], .number(43))
    }

    func testUnavailableReadbackIsReportedWithoutFalsePrecision() async throws {
        let service = MockControlService(displays: [.softwareExternal], readValues: [nil])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            request("brightness.set", selector: "uuid-software", percent: 30)
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["verification"], .string("unavailable"))
        XCTAssertEqual(response.result?["readbackPercent"], .null)
        XCTAssertNotNil(response.result?["warnings"])
    }

    func testExtraBrightnessGetSetAndCapabilitiesExposeLiveDynamicTruth() async throws {
        let service = MockControlService(displays: [.boostedBuiltin])
        let dispatcher = ControlCommandDispatcher(service: service, appVersion: "1.5.0")

        let get = await dispatcher.handle(request("extra-brightness.get", selector: "uuid-boosted"))
        let set = await dispatcher.handle(toggleRequest("extra-brightness.set", selector: "uuid-boosted", enabled: true))
        let capabilities = await dispatcher.handle(request("displays.capabilities", selector: "uuid-boosted"))

        XCTAssertEqual(get.result?["enabled"], .bool(true))
        XCTAssertEqual(get.result?["persistedEnabled"], .bool(true))
        XCTAssertEqual(get.result?["maxBrightness"], .number(150))
        XCTAssertEqual(get.result?["headroom"]?["potential"], .number(1.7))
        XCTAssertEqual(set.result?["verification"], .string("app_state_verified"))
        XCTAssertEqual(set.result?["maxBrightness"], .number(150))
        XCTAssertEqual(capabilities.result?["extraBrightness"]?["state"], .string("writable"))
        XCTAssertEqual(capabilities.result?["brightness"]?["hardwareRange"]?["max"], .number(100))
        XCTAssertEqual(capabilities.result?["brightness"]?["logicalRange"]?["max"], .number(150))
        let boostWrites = await service.extraBrightnessWrites
        XCTAssertEqual(boostWrites, [true])
    }

    func testHDRGetSetAndBuiltinUnsupportedAreDistinct() async throws {
        let externalService = MockControlService(displays: [.hdrExternal])
        let externalDispatcher = ControlCommandDispatcher(service: externalService, appVersion: "1.5.0")
        let get = await externalDispatcher.handle(request("hdr.get", selector: "uuid-hdr"))
        let set = await externalDispatcher.handle(toggleRequest("hdr.set", selector: "uuid-hdr", enabled: false))

        XCTAssertEqual(get.result?["enabled"], .bool(true))
        XCTAssertEqual(set.result?["verification"], .string("verified"))
        let externalHDRWrites = await externalService.hdrWrites
        XCTAssertEqual(externalHDRWrites, [false])

        let builtinService = MockControlService(displays: [.boostedBuiltin])
        let unsupported = await ControlCommandDispatcher(service: builtinService, appVersion: "1.5.0").handle(
            toggleRequest("hdr.set", selector: "uuid-boosted", enabled: true)
        )
        XCTAssertEqual(unsupported.error?.code, .unsupportedCapability)
        XCTAssertTrue(unsupported.error?.details?["remediation"] == .string("use Extra Brightness when eligible"))
        let builtinHDRWrites = await builtinService.hdrWrites
        XCTAssertEqual(builtinHDRWrites, [])
    }

    func testExtraBrightnessOffCleansUpAfterLiveEligibilityCollapses() async throws {
        let cleanupDisplay = ControlDisplay(
            uuid: "uuid-stale-boost",
            name: "Stale Boost",
            isMain: true,
            isBuiltin: true,
            brightness: BrightnessCapability(
                state: .writable,
                backend: .displayServices,
                range: ControlRange(min: 0, max: 150, precision: 0.1),
                readback: .authoritative,
                hardwareRange: ControlRange(min: 0, max: 100, precision: 0.1),
                logicalRange: ControlRange(min: 0, max: 150, precision: 0.1)
            ),
            brightnessPercent: 120,
            extraBrightness: .unsupported(
                enabled: true,
                persistedEnabled: true,
                maxBrightness: 150,
                reason: "live EDR eligibility collapsed"
            )
        )
        let service = MockControlService(displays: [cleanupDisplay])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            toggleRequest(
                "extra-brightness.set", selector: "uuid-stale-boost", enabled: false
            )
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["requestedEnabled"], .bool(false))
        XCTAssertEqual(response.result?["persistedEnabled"], .bool(false))
        XCTAssertEqual(response.result?["maxBrightness"], .number(100))
        let writes = await service.extraBrightnessWrites
        XCTAssertEqual(writes, [false])
    }

    func testUnsupportedExtraBrightnessStillRejectsEnableAndUnneededOff() async throws {
        for enabled in [true, false] {
            let service = MockControlService(displays: [.hdrExternal])
            let response = await ControlCommandDispatcher(
                service: service, appVersion: "1.5.0"
            ).handle(toggleRequest(
                "extra-brightness.set", selector: "uuid-hdr", enabled: enabled
            ))

            XCTAssertEqual(response.error?.code, .unsupportedCapability)
            let writes = await service.extraBrightnessWrites
            XCTAssertEqual(writes, [])
        }
    }

    func testReadableButNotWritableHDROffRemainsUnsupported() async throws {
        let display = ControlDisplay(
            uuid: "uuid-readable-hdr",
            name: "Readable HDR",
            isMain: false,
            isBuiltin: false,
            brightness: .unsupported(reason: "not relevant"),
            hdr: HDRCapability(
                state: .readable,
                enabled: true,
                reason: "MonitorPanel setter ABI is unavailable"
            )
        )
        let service = MockControlService(displays: [display])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            toggleRequest("hdr.set", selector: "uuid-readable-hdr", enabled: false)
        )

        XCTAssertEqual(response.error?.code, .unsupportedCapability)
        let writes = await service.hdrWrites
        XCTAssertEqual(writes, [])
    }

    func testBoostedBrightnessSetPreservesLogical150AndReportsHardware100Separately() async throws {
        let service = MockControlService(
            displays: [.boostedBuiltin],
            brightnessStates: [
                BrightnessReadSnapshot(logicalPercent: 120, hardwareReadbackPercent: 100),
                BrightnessReadSnapshot(logicalPercent: 150, hardwareReadbackPercent: 100),
                BrightnessReadSnapshot(logicalPercent: 150, hardwareReadbackPercent: 100)
            ]
        )
        let dispatcher = ControlCommandDispatcher(service: service, appVersion: "1.5.0")
        let response = await dispatcher.handle(request("brightness.set", selector: "uuid-boosted", percent: 150))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["appliedPercent"], .number(150))
        XCTAssertEqual(response.result?["logicalPercent"], .number(150))
        XCTAssertEqual(response.result?["hardwareReadbackPercent"], .number(100))
        XCTAssertEqual(response.result?["verification"], .string("app_state_verified"))
        XCTAssertNotNil(response.result?["warnings"])
    }

    func testBoostedBrightnessGetDoesNotCollapseToPhysicalReadback() async throws {
        let service = MockControlService(
            displays: [.boostedBuiltin],
            brightnessStates: [BrightnessReadSnapshot(logicalPercent: 150, hardwareReadbackPercent: 100)]
        )
        let get = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            request("brightness.get", selector: "uuid-boosted")
        )

        XCTAssertEqual(get.result?["percent"], .number(150))
        XCTAssertEqual(get.result?["logicalPercent"], .number(150))
        XCTAssertEqual(get.result?["hardwareReadbackPercent"], .number(100))
    }

    func testCompatibilityReadDoesNotAliasLogicalBoostToHardwareReadback() async throws {
        let service = LegacyLogicalOnlyControlService(display: .boostedBuiltin, logicalPercent: 150)
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            request("brightness.get", selector: "uuid-boosted")
        )

        XCTAssertEqual(response.result?["logicalPercent"], .number(150))
        XCTAssertEqual(response.result?["hardwareReadbackPercent"], .null)
    }

    func testBoostedSetFailsClosedWhenDynamicMaximumDropsBelowRequest() async throws {
        let service = MockControlService(displays: [.boostedBuiltin])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            request("brightness.set", selector: "uuid-boosted", percent: 150.01)
        )

        XCTAssertEqual(response.error?.code, .invalidArguments)
        let writes = await service.writes
        XCTAssertEqual(writes, [])
    }

    func testOrdinaryBrightnessResponseSchemaRemainsCompatibleAtOrBelow100() async throws {
        let service = MockControlService(displays: [.builtin], readValues: [42, 50])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            request("brightness.set", selector: "builtin", percent: 50)
        )

        XCTAssertEqual(response.result?["requestedPercent"], .number(50))
        XCTAssertEqual(response.result?["appliedPercent"], .number(50))
        XCTAssertEqual(response.result?["readbackPercent"], .number(50))
        XCTAssertEqual(response.result?["logicalPercent"], .number(50))
        XCTAssertEqual(response.result?["hardwareReadbackPercent"], .number(50))
        XCTAssertEqual(response.result?["verification"], .string("verified"))
    }

    func testBrightnessGetAllIsUUIDSortedAndExcludesVirtualDisplays() async throws {
        let service = BatchControlService(displays: [.physicalB, .virtual, .physicalA])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            ControlRequest(requestID: "all", command: "brightness.get-all")
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["displays"]?[0]?["displayUUID"], .string("uuid-a"))
        XCTAssertEqual(response.result?["displays"]?[1]?["displayUUID"], .string("uuid-b"))
        XCTAssertNil(response.result?["displays"]?[2])
        XCTAssertEqual(response.result?["semantics"], .string("same_logical_percent_per_display"))
    }

    func testBrightnessBatchEmptyInventoryIsStructured() async throws {
        let service = BatchControlService(displays: [.virtual])
        for command in ["brightness.get-all", "brightness.set-all"] {
            let arguments: [String: JSONValue] = command.hasSuffix("set-all") ? ["percent": .number(50)] : [:]
            let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
                ControlRequest(requestID: command, command: command, arguments: arguments)
            )
            XCTAssertEqual(response.error?.code, .emptyPhysicalInventory)
        }
    }

    func testBrightnessSetAllPreflightsEveryDisplayBeforeAnyWrite() async throws {
        let service = BatchControlService(displays: [.physicalA, .physicalB])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            ControlRequest(requestID: "preflight", command: "brightness.set-all",
                           arguments: ["percent": .number(125)])
        )

        XCTAssertEqual(response.error?.code, .batchPreflightFailed)
        XCTAssertEqual(response.error?.details?["failedUUIDs"], .array([.string("uuid-b")]))
        XCTAssertEqual(response.error?.details?["outcomes"]?[0]?["displayUUID"], .string("uuid-a"))
        XCTAssertEqual(response.error?.details?["outcomes"]?[0]?["attempted"], .bool(false))
        XCTAssertEqual(response.error?.details?["outcomes"]?[1]?["displayUUID"], .string("uuid-b"))
        XCTAssertEqual(response.error?.details?["outcomes"]?[1]?["attempted"], .bool(false))
        let writes = await service.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testBatchSnapshotDeadlineFailsPreflightWithoutMakingWritesIndeterminate() async throws {
        let service = DelayedSnapshotBatchControlService(displays: [.physicalB, .physicalA])
        let response = await ControlCommandDispatcher(
            service: service, appVersion: "1.5.0", batchExecutionTimeout: 0.03
        ).handle(ControlRequest(
            requestID: "snapshot-deadline", command: "brightness.set-all",
            arguments: ["percent": .number(50)]
        ))

        XCTAssertEqual(response.error?.code, .batchPreflightFailed)
        XCTAssertEqual(response.error?.details?["retrySafe"], .bool(true))
        XCTAssertEqual(response.error?.details?["outcomes"]?[0]?["attempted"], .bool(false))
        XCTAssertEqual(response.error?.details?["outcomes"]?[1]?["attempted"], .bool(false))
        let writes = await service.writes
        XCTAssertTrue(writes.isEmpty)
    }

    func testBatchMonotonicDeadlineStartsBeforeInventoryDiscovery() async throws {
        let clock = ManualMonotonicClock(now: 100)
        let service = AdvancingClockBatchControlService(
            displays: [.physicalA], clock: clock, inventoryAdvance: 6, snapshotAdvance: 0
        )
        let response = await ControlCommandDispatcher(
            service: service,
            appVersion: "1.5.0",
            batchExecutionTimeout: 5,
            batchMonotonicNow: clock.now
        ).handle(ControlRequest(
            requestID: "inventory-budget", command: "brightness.set-all",
            arguments: ["percent": .number(50)]
        ))

        XCTAssertEqual(response.error?.code, .batchPreflightFailed)
        XCTAssertEqual(response.error?.details?["phase"], .string("inventory"))
        XCTAssertEqual(response.error?.details?["retrySafe"], .bool(true))
        let inventoryWrites = await service.writes
        XCTAssertEqual(inventoryWrites, [])
    }

    func testInventoryAndSnapshotsConsumeOneMonotonicBatchBudget() async throws {
        let clock = ManualMonotonicClock(now: 500)
        let service = AdvancingClockBatchControlService(
            displays: [.physicalA], clock: clock, inventoryAdvance: 4, snapshotAdvance: 2
        )
        let response = await ControlCommandDispatcher(
            service: service,
            appVersion: "1.5.0",
            batchExecutionTimeout: 5,
            batchMonotonicNow: clock.now
        ).handle(ControlRequest(
            requestID: "shared-budget", command: "brightness.set-all",
            arguments: ["percent": .number(50)]
        ))

        XCTAssertEqual(response.error?.code, .batchPreflightFailed)
        XCTAssertEqual(response.error?.details?["phase"], .string("snapshot"))
        XCTAssertEqual(response.error?.details?["retrySafe"], .bool(true))
        let snapshotWrites = await service.writes
        XCTAssertEqual(snapshotWrites, [])
    }

    func testFinalBatchMemberCompletingAfterAbsoluteDeadlineIsIndeterminate() async throws {
        let clock = ManualMonotonicClock(now: 700)
        let service = AdvancingClockBatchControlService(
            displays: [.physicalA],
            clock: clock,
            inventoryAdvance: 0,
            snapshotAdvance: 0,
            writeAdvance: 6
        )
        let response = await ControlCommandDispatcher(
            service: service,
            appVersion: "1.5.0",
            batchExecutionTimeout: 5,
            batchMonotonicNow: clock.now
        ).handle(ControlRequest(
            requestID: "final-member-deadline",
            command: "brightness.set-all",
            arguments: ["percent": .number(50)]
        ))

        XCTAssertEqual(response.error?.code, .batchPartialFailure)
        XCTAssertEqual(response.error?.details?["appliedUUIDs"], .array([]))
        XCTAssertEqual(response.error?.details?["indeterminateUUIDs"], .array([.string("uuid-a")]))
        XCTAssertEqual(response.error?.details?["retrySafe"], .bool(false))
        XCTAssertEqual(response.error?.details?["outcomes"]?[0]?["attempted"], .bool(true))
        XCTAssertEqual(response.error?.details?["outcomes"]?[0]?["outcome"], .string("indeterminate"))
    }

    func testExpiredMemberIsIndeterminateAndLaterDisplaysAreNotAttempted() async throws {
        let clock = ManualMonotonicClock(now: 800)
        let service = AdvancingClockBatchControlService(
            displays: [.physicalB, .physicalA],
            clock: clock,
            inventoryAdvance: 0,
            snapshotAdvance: 0,
            writeAdvance: 6
        )
        let response = await ControlCommandDispatcher(
            service: service,
            appVersion: "1.5.0",
            batchExecutionTimeout: 5,
            batchMonotonicNow: clock.now
        ).handle(ControlRequest(
            requestID: "member-deadline",
            command: "brightness.set-all",
            arguments: ["percent": .number(50)]
        ))

        XCTAssertEqual(response.error?.code, .batchPartialFailure)
        XCTAssertEqual(response.error?.details?["indeterminateUUIDs"], .array([.string("uuid-a")]))
        XCTAssertEqual(response.error?.details?["notAttemptedUUIDs"], .array([.string("uuid-b")]))
        let writes = await service.writes
        XCTAssertEqual(writes, ["uuid-a"])
    }

    func testBrightnessSetAllReturnsEverySuccessfulOutcomeInDeterministicOrder() async throws {
        let service = BatchControlService(displays: [.physicalB, .physicalA])
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            ControlRequest(requestID: "success", command: "brightness.set-all",
                           arguments: ["percent": .number(50)])
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["outcomes"]?[0]?["displayUUID"], .string("uuid-a"))
        XCTAssertEqual(response.result?["outcomes"]?[1]?["displayUUID"], .string("uuid-b"))
        XCTAssertEqual(response.result?["appliedUUIDs"], .array([.string("uuid-a"), .string("uuid-b")]))
        let writes = await service.writes
        XCTAssertEqual(writes.map(\.0), ["uuid-a", "uuid-b"])
    }

    func testBrightnessSetAllPartialAndIndeterminateOutcomesNeverSuggestRetry() async throws {
        let service = BatchControlService(
            displays: [.physicalC, .physicalB, .physicalA],
            writeFailures: [
                "uuid-b": .failed("backend rejected write"),
                "uuid-c": .indeterminate("callback cancelled in flight")
            ]
        )
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            ControlRequest(requestID: "partial", command: "brightness.set-all",
                           arguments: ["percent": .number(50)])
        )

        XCTAssertEqual(response.error?.code, .batchPartialFailure)
        XCTAssertEqual(response.error?.details?["retrySafe"], .bool(false))
        XCTAssertEqual(response.error?.details?["appliedUUIDs"], .array([.string("uuid-a")]))
        XCTAssertEqual(response.error?.details?["failedUUIDs"], .array([.string("uuid-b"), .string("uuid-c")]))
        XCTAssertEqual(response.error?.details?["indeterminateUUIDs"], .array([.string("uuid-c")]))
        XCTAssertEqual(response.error?.details?["outcomes"]?[2]?["outcome"], .string("indeterminate"))
        let writes = await service.writes
        XCTAssertEqual(writes.map(\.0), ["uuid-a", "uuid-b", "uuid-c"])
    }

    func testBatchEveryMemberCarriesAttemptVerificationCodeAndRetryTruth() async throws {
        let service = BatchControlService(
            displays: [.physicalC, .physicalB, .physicalA],
            writeFailures: [
                "uuid-b": .failed("backend rejected write"),
                "uuid-c": .indeterminate("callback remains in flight")
            ]
        )
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            ControlRequest(requestID: "member-schema", command: "brightness.set-all",
                           arguments: ["percent": .number(50)])
        )

        let outcomes = response.error?.details?["outcomes"]
        XCTAssertEqual(outcomes?[0]?["attempted"], .bool(true))
        XCTAssertEqual(outcomes?[0]?["verification"], .string("verified"))
        XCTAssertEqual(outcomes?[0]?["code"], .null)
        XCTAssertEqual(outcomes?[0]?["retrySafe"], .bool(false))
        XCTAssertEqual(outcomes?[1]?["attempted"], .bool(true))
        XCTAssertEqual(outcomes?[1]?["verification"], .string("unavailable"))
        XCTAssertEqual(outcomes?[1]?["code"], .string("write_verification_failed"))
        XCTAssertEqual(outcomes?[1]?["retrySafe"], .bool(false))
        XCTAssertEqual(outcomes?[2]?["verification"], .string("unavailable"))
        XCTAssertEqual(outcomes?[2]?["code"], .string("write_outcome_indeterminate"))
        XCTAssertEqual(outcomes?[2]?["retrySafe"], .bool(false))

        let deadlineResponse = await ControlCommandDispatcher(
            service: DelayedBatchControlService(displays: [.physicalC, .physicalB, .physicalA]),
            appVersion: "1.5.0", batchExecutionTimeout: 0.03
        ).handle(ControlRequest(
            requestID: "not-attempted-schema", command: "brightness.set-all",
            arguments: ["percent": .number(50)]
        ))
        XCTAssertEqual(
            deadlineResponse.error?.details?["outcomes"]?[2]?["verification"],
            .string("unavailable")
        )
        XCTAssertEqual(
            deadlineResponse.error?.details?["outcomes"]?[2]?["code"],
            .string("batch_partial_failure")
        )
        XCTAssertEqual(deadlineResponse.error?.details?["outcomes"]?[2]?["retrySafe"], .bool(true))
    }

    func testCancelledBatchDoesNotStartAnotherDisplayWrite() async throws {
        let service = CancellingBatchControlService(displays: [.physicalA, .physicalB])
        let dispatcher = ControlCommandDispatcher(service: service, appVersion: "1.5.0")
        let task = Task {
            await dispatcher.handle(ControlRequest(
                requestID: "cancelled", command: "brightness.set-all",
                arguments: ["percent": .number(50)]
            ))
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let response = await task.value

        let writes = await service.writes
        XCTAssertEqual(writes, ["uuid-a"])
        XCTAssertEqual(response.error?.code, .batchPartialFailure)
        XCTAssertEqual(response.error?.details?["indeterminateUUIDs"], .array([.string("uuid-a")]))
        XCTAssertEqual(response.error?.details?["notAttemptedUUIDs"], .array([.string("uuid-b")]))
        XCTAssertEqual(response.error?.details?["retrySafe"], .bool(false))
        XCTAssertNotEqual(response.error?.code, .internalError)
    }

    func testCancellationAtMemberBoundaryPreservesCompletedMemberTruth() async {
        let service = MockControlService(
            displays: [.physicalA, .physicalB],
            brightnessStates: [
                BrightnessReadSnapshot(logicalPercent: 40, hardwareReadbackPercent: 40),
                BrightnessReadSnapshot(logicalPercent: 45, hardwareReadbackPercent: 45),
                BrightnessReadSnapshot(logicalPercent: 50, hardwareReadbackPercent: 50)
            ]
        )
        let gate = BatchMemberBoundaryGate()
        let dispatcher = ControlCommandDispatcher(
            service: service,
            appVersion: "1.5.0",
            batchMemberBoundary: { index in
                if index == 0 { await gate.pause() }
            }
        )
        let task = Task {
            await dispatcher.handle(ControlRequest(
                requestID: "cancel-boundary",
                command: "brightness.set-all",
                arguments: ["percent": .number(50)]
            ))
        }
        await gate.waitUntilPaused()
        task.cancel()
        await gate.resume()
        let response = await task.value

        XCTAssertEqual(response.error?.code, .batchPartialFailure)
        XCTAssertEqual(response.error?.details?["appliedUUIDs"], .array([.string("uuid-a")]))
        XCTAssertEqual(response.error?.details?["indeterminateUUIDs"], .array([]))
        XCTAssertEqual(response.error?.details?["notAttemptedUUIDs"], .array([.string("uuid-b")]))
        XCTAssertEqual(response.error?.details?["retrySafe"], .bool(false))
        let writes = await service.writes
        XCTAssertEqual(writes, [50])
    }

    func testCancellationDuringBatchInventoryIsSafePreflightNotInternalError() async throws {
        let service = CancellationPhaseBatchControlService(displays: [.physicalA], delayedPhase: .inventory)
        let task = Task {
            await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
                ControlRequest(requestID: "cancel-inventory", command: "brightness.set-all",
                               arguments: ["percent": .number(50)])
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let response = await task.value

        XCTAssertEqual(response.error?.code, .batchPreflightFailed)
        XCTAssertEqual(response.error?.details?["phase"], .string("inventory"))
        XCTAssertEqual(response.error?.details?["cancelled"], .bool(true))
        XCTAssertEqual(response.error?.details?["retrySafe"], .bool(true))
        XCTAssertNotEqual(response.error?.code, .internalError)
        let writes = await service.writes
        XCTAssertEqual(writes, [])
    }

    func testCancellationDuringBatchSnapshotIsSafePreflightNotInternalError() async throws {
        let service = CancellationPhaseBatchControlService(displays: [.physicalA], delayedPhase: .snapshot)
        let task = Task {
            await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
                ControlRequest(requestID: "cancel-snapshot", command: "brightness.set-all",
                               arguments: ["percent": .number(50)])
            )
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let response = await task.value

        XCTAssertEqual(response.error?.code, .batchPreflightFailed)
        XCTAssertEqual(response.error?.details?["phase"], .string("snapshot"))
        XCTAssertEqual(response.error?.details?["cancelled"], .bool(true))
        XCTAssertEqual(response.error?.details?["retrySafe"], .bool(true))
        XCTAssertNotEqual(response.error?.code, .internalError)
        let writes = await service.writes
        XCTAssertEqual(writes, [])
    }

    func testBrightnessCancellationAfterSetterIsIndeterminate() async {
        await assertCancellationAfterSetterIsIndeterminate(
            mutation: .brightness,
            request: request("brightness.set", selector: "uuid-boosted", percent: 80)
        )
    }

    func testExtraBrightnessCancellationAfterSetterIsIndeterminate() async {
        await assertCancellationAfterSetterIsIndeterminate(
            mutation: .extraBrightness,
            request: toggleRequest(
                "extra-brightness.set", selector: "uuid-boosted", enabled: false
            )
        )
    }

    func testHDRCancellationAfterSetterIsIndeterminate() async {
        await assertCancellationAfterSetterIsIndeterminate(
            mutation: .hdr,
            request: toggleRequest("hdr.set", selector: "uuid-hdr", enabled: false)
        )
    }

    func testBatchOwnDeadlinePreservesCompletedAndUnknownMembers() async throws {
        let service = DelayedBatchControlService(displays: [.physicalC, .physicalB, .physicalA])
        let dispatcher = ControlCommandDispatcher(
            service: service, appVersion: "1.5.0", batchExecutionTimeout: 0.03
        )
        let response = await dispatcher.handle(ControlRequest(
            requestID: "deadline", command: "brightness.set-all",
            arguments: ["percent": .number(50)]
        ))

        XCTAssertEqual(response.error?.code, .batchPartialFailure)
        XCTAssertEqual(response.error?.details?["appliedUUIDs"], .array([.string("uuid-a")]))
        XCTAssertEqual(response.error?.details?["indeterminateUUIDs"], .array([.string("uuid-b")]))
        XCTAssertEqual(response.error?.details?["notAttemptedUUIDs"], .array([.string("uuid-c")]))
        XCTAssertEqual(response.error?.details?["outcomes"]?[0]?["attempted"], .bool(true))
        XCTAssertEqual(response.error?.details?["outcomes"]?[1]?["outcome"], .string("indeterminate"))
        XCTAssertEqual(response.error?.details?["outcomes"]?[2]?["outcome"], .string("not_attempted"))
        XCTAssertEqual(response.error?.details?["retrySafe"], .bool(false))
        let writes = await service.writes
        XCTAssertEqual(writes, ["uuid-a", "uuid-b"])
    }

    func testBatchDeadlineIsOverallNotRestartedForEachDisplay() async throws {
        let clock = ManualMonotonicClock(now: 900)
        let service = AdvancingClockBatchControlService(
            displays: [.physicalC, .physicalB, .physicalA],
            clock: clock,
            inventoryAdvance: 0,
            snapshotAdvance: 0,
            writeAdvance: 3
        )
        let response = await ControlCommandDispatcher(
            service: service,
            appVersion: "1.5.0",
            batchExecutionTimeout: 5,
            batchMonotonicNow: clock.now
        ).handle(ControlRequest(
            requestID: "overall-deadline", command: "brightness.set-all",
            arguments: ["percent": .number(50)]
        ))

        XCTAssertEqual(response.error?.code, .batchPartialFailure)
        XCTAssertEqual(response.error?.details?["appliedUUIDs"], .array([.string("uuid-a")]))
        XCTAssertEqual(response.error?.details?["indeterminateUUIDs"], .array([.string("uuid-b")]))
        XCTAssertEqual(response.error?.details?["notAttemptedUUIDs"], .array([.string("uuid-c")]))
    }

    private func request(_ command: String, selector: String, percent: Double? = nil) -> ControlRequest {
        var arguments: [String: JSONValue] = ["selector": .string(selector)]
        if let percent { arguments["percent"] = .number(percent) }
        return ControlRequest(requestID: "req", command: command, arguments: arguments)
    }

    private func toggleRequest(_ command: String, selector: String, enabled: Bool) -> ControlRequest {
        ControlRequest(requestID: "req", command: command, arguments: [
            "selector": .string(selector), "enabled": .bool(enabled)
        ])
    }

    private func assertCancellationAfterSetterIsIndeterminate(
        mutation: PostMutationCancellationControlService.Mutation,
        request: ControlRequest
    ) async {
        let gate = BatchMemberBoundaryGate()
        let service = PostMutationCancellationControlService(mutation: mutation, gate: gate)
        let task = Task {
            await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(request)
        }
        await gate.waitUntilPaused()
        task.cancel()
        await gate.resume()
        let response = await task.value

        XCTAssertEqual(response.error?.code, .writeOutcomeIndeterminate)
        XCTAssertEqual(response.error?.details?["retrySafe"], .bool(false))
        XCTAssertEqual(response.error?.details?["outcome"], .string("unknown"))
        XCTAssertEqual(response.error?.code.exitCode, 5)
        let mutations = await service.mutations
        XCTAssertEqual(mutations, [mutation])
    }
}

final class BrightnessBatchOverrideTests: XCTestCase {
    func testStrictDefaultRejectsUnreadableRestoreSnapshotWithoutWrites() async throws {
        let service = BatchControlService(
            displays: [.physicalB, .physicalA],
            preWriteSnapshotUnavailableUUIDs: ["uuid-b"]
        )
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            ControlRequest(
                requestID: "strict-unreadable", command: "brightness.set-all",
                arguments: ["percent": .number(50)]
            )
        )

        XCTAssertEqual(response.error?.code, .batchPreflightFailed)
        XCTAssertEqual(response.error?.details?["restoreMode"], .string("strict"))
        XCTAssertEqual(
            response.error?.details?["missingRestoreSnapshotUUIDs"], .array([.string("uuid-b")])
        )
        XCTAssertEqual(response.error?.details?["manualRestorationRequired"], .bool(false))
        XCTAssertEqual(response.error?.details?["outcomes"]?[0]?["status"], .string("not_attempted"))
        XCTAssertEqual(response.error?.details?["outcomes"]?[1]?["status"], .string("failed"))
        let writes = await service.writes
        XCTAssertEqual(writes.map(\.0), [])
    }

    func testOverrideReturnsDeterministicPerDisplayStatusesAndManualRestoreTruth() async throws {
        let service = BatchControlService(
            displays: [.physicalE, .physicalC, .physicalA, .physicalD, .physicalB],
            writeFailures: [
                "uuid-c": .failed("backend rejected write"),
                "uuid-d": .indeterminate("callback remains in flight")
            ],
            preWriteSnapshotUnavailableUUIDs: ["uuid-b"]
        )
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            ControlRequest(
                requestID: "override-categories", command: "brightness.set-all",
                arguments: ["percent": .number(50), "allowUnrestorable": .bool(true)]
            )
        )

        XCTAssertEqual(response.error?.code, .batchPartialFailure)
        let details = response.error?.details
        XCTAssertEqual(details?["restoreMode"], .string("allow_unrestorable"))
        XCTAssertEqual(details?["restoreSnapshotsComplete"], .bool(false))
        XCTAssertEqual(details?["missingRestoreSnapshotUUIDs"], .array([.string("uuid-b")]))
        XCTAssertEqual(details?["manualRestorationRequired"], .bool(true))
        XCTAssertEqual(details?["manualRestorationUUIDs"], .array([.string("uuid-b")]))
        XCTAssertEqual(details?["outcomes"]?[0]?["status"], .string("written_verified"))
        XCTAssertEqual(details?["outcomes"]?[1]?["status"], .string("written_verified"))
        XCTAssertEqual(details?["outcomes"]?[1]?["verification"], .string("approximate"))
        XCTAssertEqual(details?["outcomes"]?[1]?["originalPercent"], .null)
        XCTAssertEqual(details?["outcomes"]?[1]?["manualRestorationRequired"], .bool(true))
        XCTAssertNotEqual(details?["outcomes"]?[1]?["warnings"], .array([]))
        XCTAssertEqual(details?["outcomes"]?[2]?["status"], .string("failed"))
        XCTAssertEqual(details?["outcomes"]?[3]?["status"], .string("write_indeterminate"))
        XCTAssertEqual(details?["outcomes"]?[4]?["status"], .string("not_attempted"))
        XCTAssertEqual(details?["outcomes"]?[4]?["attempted"], .bool(false))
        XCTAssertEqual(details?["retrySafe"], .bool(false))
        let writes = await service.writes
        XCTAssertEqual(writes.map(\.0), ["uuid-a", "uuid-b", "uuid-c", "uuid-d"])
    }

    func testOverrideRejectsNilPostWriteReadbackForReadbackCapableDisplay() async throws {
        let service = BatchControlService(
            displays: [.physicalB],
            preWriteSnapshotUnavailableUUIDs: ["uuid-b"],
            postWriteReadbackNilUUIDs: ["uuid-b"]
        )
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            ControlRequest(
                requestID: "override-nil-post-write-readback", command: "brightness.set-all",
                arguments: ["percent": .number(50), "allowUnrestorable": .bool(true)]
            )
        )

        XCTAssertFalse(response.ok)
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, .batchPartialFailure)
        let outcome = response.error?.details?["outcomes"]?[0]
        XCTAssertEqual(outcome?["status"], .string("failed"))
        XCTAssertNotEqual(outcome?["status"], .string("written_unverified"))
        XCTAssertEqual(outcome?["code"], .string("write_verification_failed"))
        XCTAssertEqual(outcome?["manualRestorationRequired"], .bool(true))
        let writes = await service.writes
        XCTAssertEqual(writes.map(\.0), ["uuid-b"])
    }

    func testOverrideRejectsPostWriteReadErrorForReadbackCapableDisplay() async throws {
        let service = BatchControlService(
            displays: [.physicalB],
            preWriteSnapshotUnavailableUUIDs: ["uuid-b"],
            postWriteReadbackFailures: ["uuid-b": "post-write read-back failed"]
        )
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            ControlRequest(
                requestID: "override-failed-post-write-readback", command: "brightness.set-all",
                arguments: ["percent": .number(50), "allowUnrestorable": .bool(true)]
            )
        )

        XCTAssertFalse(response.ok)
        XCTAssertNil(response.result)
        XCTAssertEqual(response.error?.code, .batchPartialFailure)
        let outcome = response.error?.details?["outcomes"]?[0]
        XCTAssertEqual(outcome?["status"], .string("failed"))
        XCTAssertNotEqual(outcome?["status"], .string("written_unverified"))
        XCTAssertEqual(outcome?["code"], .string("internal_error"))
        XCTAssertEqual(outcome?["manualRestorationRequired"], .bool(true))
        let writes = await service.writes
        XCTAssertEqual(writes.map(\.0), ["uuid-b"])
    }

    func testOverridePreservesKnownReadbackUnavailableAsWrittenUnverified() async throws {
        let service = BatchControlService(
            displays: [.softwareExternal],
            preWriteSnapshotUnavailableUUIDs: ["uuid-software"]
        )
        let response = await ControlCommandDispatcher(service: service, appVersion: "1.5.0").handle(
            ControlRequest(
                requestID: "override-known-unverifiable", command: "brightness.set-all",
                arguments: ["percent": .number(50), "allowUnrestorable": .bool(true)]
            )
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["outcomes"]?[0]?["status"], .string("written_unverified"))
        XCTAssertEqual(response.result?["outcomes"]?[0]?["verification"], .string("unavailable"))
        XCTAssertEqual(response.result?["outcomes"]?[0]?["manualRestorationRequired"], .bool(true))
        XCTAssertEqual(response.result?["outcomes"]?[0]?["readbackPercent"], .null)
        let writes = await service.writes
        XCTAssertEqual(writes.map(\.0), ["uuid-software"])
    }
}

private final class ManualMonotonicClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(now: TimeInterval) { value = now }

    func now() -> TimeInterval { lock.withLock { value } }

    func advance(by interval: TimeInterval) {
        lock.withLock { value += interval }
    }
}

private actor AdvancingClockBatchControlService: ControlCommandService {
    let inventory: [ControlDisplay]
    let clock: ManualMonotonicClock
    let inventoryAdvance: TimeInterval
    let snapshotAdvance: TimeInterval
    let writeAdvance: TimeInterval
    var values: [String: Double]
    var writes: [String] = []

    init(
        displays: [ControlDisplay],
        clock: ManualMonotonicClock,
        inventoryAdvance: TimeInterval,
        snapshotAdvance: TimeInterval,
        writeAdvance: TimeInterval = 0
    ) {
        inventory = displays
        self.clock = clock
        self.inventoryAdvance = inventoryAdvance
        self.snapshotAdvance = snapshotAdvance
        self.writeAdvance = writeAdvance
        values = Dictionary(uniqueKeysWithValues: displays.map {
            ($0.uuid, $0.brightnessPercent ?? 42)
        })
    }

    func displays() async throws -> [ControlDisplay] {
        clock.advance(by: inventoryAdvance)
        return inventory
    }

    func readBrightness(displayUUID: String) async throws -> Double? {
        clock.advance(by: snapshotAdvance)
        return values[displayUUID]
    }

    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double {
        writes.append(displayUUID)
        clock.advance(by: writeAdvance)
        values[displayUUID] = percent
        return percent
    }
}

private actor DelayedBatchControlService: ControlCommandService {
    let inventory: [ControlDisplay]
    var values: [String: Double]
    var writes: [String] = []

    init(displays: [ControlDisplay]) {
        inventory = displays
        values = Dictionary(uniqueKeysWithValues: displays.map { ($0.uuid, $0.brightnessPercent ?? 42) })
    }

    func displays() async throws -> [ControlDisplay] { inventory }
    func readBrightness(displayUUID: String) async throws -> Double? { values[displayUUID] }
    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double {
        writes.append(displayUUID)
        if displayUUID == "uuid-b" {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    continuation.resume()
                }
            }
        }
        values[displayUUID] = percent
        return percent
    }
}

private actor DelayedSnapshotBatchControlService: ControlCommandService {
    let inventory: [ControlDisplay]
    var writes: [String] = []

    init(displays: [ControlDisplay]) { inventory = displays }
    func displays() async throws -> [ControlDisplay] { inventory }
    func readBrightness(displayUUID: String) async throws -> Double? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                continuation.resume(returning: 42)
            }
        }
    }
    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double {
        writes.append(displayUUID)
        return percent
    }
}

private actor CancellingBatchControlService: ControlCommandService {
    let inventory: [ControlDisplay]
    var values: [String: Double]
    var writes: [String] = []

    init(displays: [ControlDisplay]) {
        inventory = displays
        values = Dictionary(uniqueKeysWithValues: displays.map { ($0.uuid, $0.brightnessPercent ?? 42) })
    }

    func displays() async throws -> [ControlDisplay] { inventory }
    func readBrightness(displayUUID: String) async throws -> Double? { values[displayUUID] }
    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double {
        writes.append(displayUUID)
        try? await Task.sleep(for: .milliseconds(200))
        values[displayUUID] = percent
        return percent
    }
}

private actor CancellationPhaseBatchControlService: ControlCommandService {
    enum Phase: Equatable { case inventory, snapshot }

    let inventory: [ControlDisplay]
    let delayedPhase: Phase
    var writes: [String] = []

    init(displays: [ControlDisplay], delayedPhase: Phase) {
        inventory = displays
        self.delayedPhase = delayedPhase
    }

    func displays() async throws -> [ControlDisplay] {
        if delayedPhase == .inventory {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return inventory
    }

    func readBrightness(displayUUID: String) async throws -> Double? {
        if delayedPhase == .snapshot {
            try? await Task.sleep(for: .milliseconds(200))
        }
        return inventory.first { $0.uuid == displayUUID }?.brightnessPercent
    }

    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double {
        writes.append(displayUUID)
        return percent
    }
}

private actor BatchControlService: ControlCommandService {
    enum WriteFailure {
        case failed(String)
        case indeterminate(String)
    }

    let inventory: [ControlDisplay]
    let writeFailures: [String: WriteFailure]
    let preWriteSnapshotUnavailableUUIDs: Set<String>
    let postWriteReadbackNilUUIDs: Set<String>
    let postWriteReadbackFailures: [String: String]
    var values: [String: Double]
    var brightnessReadCounts: [String: Int] = [:]
    var writes: [(String, Double)] = []

    init(
        displays: [ControlDisplay],
        writeFailures: [String: WriteFailure] = [:],
        preWriteSnapshotUnavailableUUIDs: Set<String> = [],
        postWriteReadbackNilUUIDs: Set<String> = [],
        postWriteReadbackFailures: [String: String] = [:]
    ) {
        inventory = displays
        self.writeFailures = writeFailures
        self.preWriteSnapshotUnavailableUUIDs = preWriteSnapshotUnavailableUUIDs
        self.postWriteReadbackNilUUIDs = postWriteReadbackNilUUIDs
        self.postWriteReadbackFailures = postWriteReadbackFailures
        values = Dictionary(uniqueKeysWithValues: displays.map { ($0.uuid, $0.brightnessPercent ?? 42) })
    }

    func displays() async throws -> [ControlDisplay] { inventory }

    func readBrightness(displayUUID: String) async throws -> Double? {
        let readCount = brightnessReadCounts[displayUUID, default: 0]
        brightnessReadCounts[displayUUID] = readCount + 1
        if readCount == 0, preWriteSnapshotUnavailableUUIDs.contains(displayUUID) {
            return nil
        }
        if readCount > 0, let message = postWriteReadbackFailures[displayUUID] {
            throw ControlServiceError.readFailed(message)
        }
        if readCount > 0, postWriteReadbackNilUUIDs.contains(displayUUID) {
            return nil
        }
        return values[displayUUID]
    }

    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double {
        writes.append((displayUUID, percent))
        if let failure = writeFailures[displayUUID] {
            switch failure {
            case let .failed(message): throw ControlServiceError.writeFailed(message)
            case let .indeterminate(message): throw ControlServiceError.writeIndeterminate(message)
            }
        }
        values[displayUUID] = percent
        return percent
    }
}

private actor LegacyLogicalOnlyControlService: ControlCommandService {
    let display: ControlDisplay
    let logicalPercent: Double

    init(display: ControlDisplay, logicalPercent: Double) {
        self.display = display
        self.logicalPercent = logicalPercent
    }

    func displays() async throws -> [ControlDisplay] { [display] }
    func readBrightness(displayUUID: String) async throws -> Double? { logicalPercent }
    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double { percent }
}

private actor MockControlService: ControlCommandService {
    let inventory: [ControlDisplay]
    var queuedReads: [Double?]
    var writes: [Double] = []
    var brightnessStates: [BrightnessReadSnapshot]
    var extraBrightnessWrites: [Bool] = []
    var hdrWrites: [Bool] = []

    init(
        displays: [ControlDisplay],
        readValues: [Double?] = [42],
        brightnessStates: [BrightnessReadSnapshot] = []
    ) {
        inventory = displays
        queuedReads = readValues
        self.brightnessStates = brightnessStates
    }

    func displays() async throws -> [ControlDisplay] { inventory }

    func readBrightness(displayUUID: String) async throws -> Double? {
        queuedReads.isEmpty ? inventory.first(where: { $0.uuid == displayUUID })?.brightnessPercent
            : queuedReads.removeFirst()
    }

    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double {
        writes.append(percent)
        return percent
    }

    func readBrightnessState(displayUUID: String) async throws -> BrightnessReadSnapshot? {
        if !brightnessStates.isEmpty { return brightnessStates.removeFirst() }
        return try await readBrightness(displayUUID: displayUUID).map {
            BrightnessReadSnapshot(logicalPercent: $0, hardwareReadbackPercent: $0)
        }
    }

    func setExtraBrightness(displayUUID: String, enabled: Bool) async throws -> ExtraBrightnessSetResult {
        extraBrightnessWrites.append(enabled)
        let existing = inventory.first { $0.uuid == displayUUID }!.extraBrightness
        let capability = if enabled {
            existing
        } else {
            ExtraBrightnessCapability(
                state: existing.state,
                enabled: false,
                persistedEnabled: false,
                maxBrightness: 100,
                headroom: existing.headroom,
                reason: existing.reason,
                remediation: existing.remediation
            )
        }
        return ExtraBrightnessSetResult(capability: capability, verification: .appStateVerified)
    }

    func setHDR(displayUUID: String, enabled: Bool) async throws -> HDRSetResult {
        hdrWrites.append(enabled)
        let capability = HDRCapability(state: .writable, enabled: enabled)
        return HDRSetResult(capability: capability, verification: .verified)
    }
}

private actor BatchMemberBoundaryGate {
    private var paused = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var observerContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        observerContinuation?.resume()
        observerContinuation = nil
        await withCheckedContinuation { pauseContinuation = $0 }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { observerContinuation = $0 }
    }

    func resume() {
        pauseContinuation?.resume()
        pauseContinuation = nil
    }
}

private actor PostMutationCancellationControlService: ControlCommandService {
    enum Mutation: Equatable, Sendable {
        case brightness
        case extraBrightness
        case hdr
    }

    let mutation: Mutation
    let gate: BatchMemberBoundaryGate
    var values = ["uuid-boosted": 120.0, "uuid-hdr": 55.0]
    var mutations: [Mutation] = []

    init(mutation: Mutation, gate: BatchMemberBoundaryGate) {
        self.mutation = mutation
        self.gate = gate
    }

    func displays() async throws -> [ControlDisplay] { [.boostedBuiltin, .hdrExternal] }

    func readBrightness(displayUUID: String) async throws -> Double? { values[displayUUID] }

    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double {
        mutations.append(.brightness)
        await gate.pause()
        values[displayUUID] = percent
        return percent
    }

    func setExtraBrightness(
        displayUUID: String,
        enabled: Bool
    ) async throws -> ExtraBrightnessSetResult {
        mutations.append(.extraBrightness)
        await gate.pause()
        return ExtraBrightnessSetResult(
            capability: ExtraBrightnessCapability(
                state: .writable,
                enabled: enabled,
                persistedEnabled: enabled,
                maxBrightness: enabled ? 150 : 100
            ),
            verification: .appStateVerified
        )
    }

    func setHDR(displayUUID: String, enabled: Bool) async throws -> HDRSetResult {
        mutations.append(.hdr)
        await gate.pause()
        return HDRSetResult(
            capability: HDRCapability(state: .writable, enabled: enabled),
            verification: .verified
        )
    }
}

private extension ControlDisplay {
    static let builtin = ControlDisplay(
        uuid: "uuid-built-in", name: "Built-in Display", isMain: true, isBuiltin: true,
        brightness: BrightnessCapability(
            state: .writable, backend: .displayServices,
            range: ControlRange(min: 0, max: 100, precision: 0.1), readback: .authoritative
        ), brightnessPercent: 42
    )
    static let unsupportedExternal = ControlDisplay(
        uuid: "uuid-external", name: "External", isMain: false, isBuiltin: false,
        brightness: .unsupported(reason: "No controllable backend")
    )
    static let softwareExternal = ControlDisplay(
        uuid: "uuid-software", name: "Software", isMain: false, isBuiltin: false,
        brightness: BrightnessCapability(
            state: .writable, backend: .software,
            range: ControlRange(min: 0, max: 100, precision: 1), readback: .unavailable
        ), brightnessPercent: 42
    )
    static let readOnlyExternal = ControlDisplay(
        uuid: "uuid-read-only", name: "Read only", isMain: false, isBuiltin: false,
        brightness: BrightnessCapability(
            state: .readable, backend: .ddc,
            range: ControlRange(min: 0, max: 100, precision: 1), readback: .approximate
        ), brightnessPercent: 42
    )
    static let deskA = ControlDisplay(
        uuid: "uuid-a", name: "Desk", isMain: false, isBuiltin: false,
        brightness: .unsupported(reason: "none")
    )
    static let deskB = ControlDisplay(
        uuid: "uuid-b", name: "Desk", isMain: false, isBuiltin: false,
        brightness: .unsupported(reason: "none")
    )
    static let boostedBuiltin = ControlDisplay(
        uuid: "uuid-boosted", name: "Built-in XDR", isMain: true, isBuiltin: true,
        brightness: BrightnessCapability(
            state: .writable, backend: .displayServices,
            range: ControlRange(min: 0, max: 150, precision: 0.1), readback: .authoritative,
            hardwareRange: ControlRange(min: 0, max: 100, precision: 0.1),
            logicalRange: ControlRange(min: 0, max: 150, precision: 0.1)
        ), brightnessPercent: 120,
        extraBrightness: ExtraBrightnessCapability(
            state: .writable, enabled: true, persistedEnabled: true, maxBrightness: 150,
            headroom: EDRHeadroomSnapshot(potential: 1.7, current: 1.5)
        ),
        hdr: .unsupported(
            reason: "built-in displays do not expose an HDR preference toggle",
            remediation: "use Extra Brightness when eligible"
        )
    )
    static let hdrExternal = ControlDisplay(
        uuid: "uuid-hdr", name: "HDR External", isMain: false, isBuiltin: false,
        brightness: BrightnessCapability(
            state: .writable, backend: .software,
            range: ControlRange(min: 0, max: 100, precision: 1), readback: .unavailable
        ), brightnessPercent: 55,
        extraBrightness: .unsupported(reason: "boost is off"),
        hdr: HDRCapability(state: .writable, enabled: true)
    )
    static let physicalA = ControlDisplay(
        uuid: "uuid-a", name: "A", isMain: true, isBuiltin: true,
        brightness: BrightnessCapability(
            state: .writable, backend: .displayServices,
            range: ControlRange(min: 0, max: 150, precision: 0.1), readback: .authoritative,
            hardwareRange: ControlRange(min: 0, max: 100, precision: 0.1),
            logicalRange: ControlRange(min: 0, max: 150, precision: 0.1)
        ), brightnessPercent: 40,
        extraBrightness: ExtraBrightnessCapability(
            state: .writable, enabled: true, persistedEnabled: true, maxBrightness: 150
        )
    )
    static let physicalB = ControlDisplay(
        uuid: "uuid-b", name: "B", isMain: false, isBuiltin: false,
        brightness: BrightnessCapability(
            state: .writable, backend: .ddc,
            range: ControlRange(min: 0, max: 100, precision: 1), readback: .approximate
        ), brightnessPercent: 45
    )
    static let physicalC = ControlDisplay(
        uuid: "uuid-c", name: "C", isMain: false, isBuiltin: false,
        brightness: BrightnessCapability(
            state: .writable, backend: .ddc,
            range: ControlRange(min: 0, max: 100, precision: 1), readback: .approximate
        ), brightnessPercent: 50
    )
    static let physicalD = ControlDisplay(
        uuid: "uuid-d", name: "D", isMain: false, isBuiltin: false,
        brightness: BrightnessCapability(
            state: .writable, backend: .ddc,
            range: ControlRange(min: 0, max: 100, precision: 1), readback: .approximate
        ), brightnessPercent: 55
    )
    static let physicalE = ControlDisplay(
        uuid: "uuid-e", name: "E", isMain: false, isBuiltin: false,
        brightness: BrightnessCapability(
            state: .writable, backend: .ddc,
            range: ControlRange(min: 0, max: 100, precision: 1), readback: .approximate
        ), brightnessPercent: 60
    )
    static let virtual = ControlDisplay(
        uuid: "uuid-virtual", name: "Virtual", isMain: false, isBuiltin: false, isVirtual: true,
        brightness: .unsupported(reason: "virtual display")
    )
}
