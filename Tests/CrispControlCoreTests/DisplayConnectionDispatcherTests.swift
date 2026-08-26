import XCTest
@testable import CrispControlCore

final class DisplayConnectionDispatcherTests: XCTestCase {
    private let targetUUID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private let otherUUID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

    func testDisconnectedInventoryIsUUIDSortedAndCarriesConnectionTruth() async throws {
        let service = DisconnectedInventoryService(disconnected: [
            disconnectedDisplay(uuid: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", name: "B"),
            disconnectedDisplay(uuid: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", name: "A")
        ])
        let response = await ControlCommandDispatcher(service: service, appVersion: "test").handle(
            ControlRequest(requestID: "inventory", command: "displays.disconnected")
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(
            response.result?["displays"]?[0]?["uuid"],
            .string("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")
        )
        XCTAssertEqual(response.result?["displays"]?[0]?["name"], .string("A"))
        XCTAssertEqual(response.result?["displays"]?[0]?["width"], .number(2560))
        XCTAssertEqual(response.result?["displays"]?[0]?["height"], .number(1440))
        XCTAssertEqual(response.result?["displays"]?[0]?["connection"]?["state"], .string("writable"))
        XCTAssertEqual(response.result?["displays"]?[0]?["connection"]?["connected"], .bool(false))
        XCTAssertEqual(
            response.result?["displays"]?[0]?["connection"]?["reconnectAllowed"],
            .bool(true)
        )
        XCTAssertEqual(
            response.result?["displays"]?[0]?["connection"]?["platformSupported"],
            .bool(true)
        )
    }

    func testExistingServiceConformerGetsFailClosedConnectionDefaults() async {
        let response = await ControlCommandDispatcher(
            service: LegacyControlService(), appVersion: "test"
        ).handle(ControlRequest(requestID: "legacy", command: "displays.disconnected"))

        XCTAssertEqual(response.result?["displays"], .array([]))
    }

    func testDisplayCapabilitiesIncludesConnectionCapability() async throws {
        let response = await ControlCommandDispatcher(
            service: DisconnectedInventoryService(disconnected: []), appVersion: "test"
        ).handle(ControlRequest(
            requestID: "capability",
            command: "displays.capabilities",
            arguments: ["selector": .string("online-display")]
        ))

        XCTAssertEqual(response.result?["connection"]?["state"], .string("writable"))
        XCTAssertEqual(response.result?["connection"]?["connected"], .bool(true))
        XCTAssertEqual(response.result?["connection"]?["disconnectAllowed"], .bool(true))
    }

    func testDisconnectReResolvesExactUUIDAndReturnsStructuredVerifiedResult() async {
        let target = onlineDisplay(uuid: targetUUID, name: "Duplicate Name")
        let service = ConnectionMutationService(displayInventories: [[target], [target]])
        let response = await ControlCommandDispatcher(service: service, appVersion: "test").handle(
            ControlRequest(
                requestID: "disconnect",
                command: "displays.disconnect",
                arguments: ["uuid": .string(targetUUID)]
            )
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["displayUUID"], .string(targetUUID))
        XCTAssertEqual(response.result?["requestedConnectionState"], .string("disconnected"))
        XCTAssertEqual(response.result?["observedConnectionState"], .string("disconnected"))
        XCTAssertEqual(response.result?["verification"], .string("same_uuid_enumeration"))
        let disconnectCalls = await service.disconnectCalls
        let displayCallCount = await service.displayCallCount
        XCTAssertEqual(disconnectCalls, [targetUUID])
        XCTAssertEqual(displayCallCount, 2)
    }

    func testDisconnectNeverSwitchesToAnotherDisplayWhenTargetDisappears() async {
        let target = onlineDisplay(uuid: targetUUID, name: "Target")
        let other = onlineDisplay(uuid: otherUUID, name: "Target")
        let service = ConnectionMutationService(displayInventories: [[target], [other]])
        let response = await ControlCommandDispatcher(service: service, appVersion: "test").handle(
            ControlRequest(
                requestID: "stale",
                command: "displays.disconnect",
                arguments: ["uuid": .string(targetUUID)]
            )
        )

        XCTAssertEqual(response.error?.code, .selectorNotFound)
        XCTAssertEqual(response.error?.details?["displayUUID"], .string(targetUUID))
        let disconnectCalls = await service.disconnectCalls
        XCTAssertEqual(disconnectCalls, [])
    }

    func testDisconnectRejectsNonUUIDAndLegacySelectorRequestsBeforeInventoryOrMutation() async {
        let invalidArguments: [[String: JSONValue]] = [
            ["uuid": .string("main")],
            ["uuid": .string("builtin")],
            ["uuid": .string("Duplicate")],
            ["selector": .string(targetUUID)],
            ["selector": .string("Duplicate")]
        ]

        for arguments in invalidArguments {
            let service = ConnectionMutationService(displayInventories: [[
                onlineDisplay(uuid: targetUUID, name: "Duplicate"),
                onlineDisplay(uuid: otherUUID, name: "Duplicate")
            ]])
            let response = await ControlCommandDispatcher(service: service, appVersion: "test").handle(
                ControlRequest(
                    requestID: "invalid-disconnect",
                    command: "displays.disconnect",
                    arguments: arguments
                )
            )

            XCTAssertEqual(response.error?.code, .invalidArguments, "\(arguments)")
            let displayCallCount = await service.displayCallCount
            let disconnectCalls = await service.disconnectCalls
            XCTAssertEqual(displayCallCount, 0, "\(arguments)")
            XCTAssertEqual(disconnectCalls, [], "\(arguments)")
        }
    }

    func testReconnectRequiresExactUUIDInFreshDisconnectedInventory() async {
        for requestedUUID in ["main", "Fixture Display", targetUUID.lowercased()] {
            let service = ConnectionMutationService(
                disconnectedInventories: [[disconnectedDisplay(uuid: targetUUID, name: "Fixture Display")]]
            )
            let response = await ControlCommandDispatcher(service: service, appVersion: "test").handle(
                ControlRequest(
                    requestID: "invalid-reconnect",
                    command: "displays.reconnect",
                    arguments: ["uuid": .string(requestedUUID)]
                )
            )
            XCTAssertEqual(
                response.error?.code,
                requestedUUID == targetUUID.lowercased() ? .selectorNotFound : .invalidArguments
            )
            let reconnectCalls = await service.reconnectCalls
            XCTAssertEqual(reconnectCalls, [])
        }

        let absent = ConnectionMutationService(disconnectedInventories: [[]])
        let response = await ControlCommandDispatcher(service: absent, appVersion: "test").handle(
            ControlRequest(
                requestID: "absent",
                command: "displays.reconnect",
                arguments: ["uuid": .string(targetUUID)]
            )
        )
        XCTAssertEqual(response.error?.code, .selectorNotFound)
        let reconnectCalls = await absent.reconnectCalls
        XCTAssertEqual(reconnectCalls, [])
    }

    func testReconnectReturnsStructuredVerifiedResultForFreshExactUUID() async {
        let service = ConnectionMutationService(
            disconnectedInventories: [[disconnectedDisplay(uuid: targetUUID, name: "Target")]]
        )
        let response = await ControlCommandDispatcher(service: service, appVersion: "test").handle(
            ControlRequest(
                requestID: "reconnect",
                command: "displays.reconnect",
                arguments: ["uuid": .string(targetUUID)]
            )
        )

        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.result?["displayUUID"], .string(targetUUID))
        XCTAssertEqual(response.result?["requestedConnectionState"], .string("connected"))
        XCTAssertEqual(response.result?["observedConnectionState"], .string("connected"))
        let reconnectCalls = await service.reconnectCalls
        XCTAssertEqual(reconnectCalls, [targetUUID])
    }

    func testExplicitReconnectDelegatesOrphanCapabilityToServiceAndPreservesIndeterminateTruth() async {
        let service = OrphanReconnectService(
            disconnected: ControlDisconnectedDisplay(
                uuid: targetUUID,
                name: "Orphaned Target",
                width: 2560,
                height: 1440,
                connection: .unsupported(
                    connected: false,
                    platformSupported: true,
                    reason: "a durable reconnect reservation requires authoritative reconciliation"
                )
            )
        )
        let dispatcher = ControlCommandDispatcher(service: service, appVersion: "test")
        let request = ControlRequest(
            requestID: "orphan-reconnect",
            command: "displays.reconnect",
            arguments: ["uuid": .string(targetUUID)]
        )

        let first = await dispatcher.handle(request)

        XCTAssertEqual(first.error?.code, .writeOutcomeIndeterminate)
        XCTAssertEqual(first.error?.code.exitCode, 5)
        XCTAssertEqual(first.error?.details?["retrySafe"], .bool(false))
        XCTAssertEqual(first.error?.details?["mutationDispatched"], .bool(false))
        XCTAssertEqual(first.error?.details?["displayUUID"], .string(targetUUID))
        let callsAfterFirstRequest = await service.reconnectCalls
        XCTAssertEqual(callsAfterFirstRequest, [targetUUID])

        let second = await dispatcher.handle(ControlRequest(
            requestID: "fresh-reconnect",
            command: "displays.reconnect",
            arguments: ["uuid": .string(targetUUID)]
        ))

        XCTAssertTrue(second.ok)
        XCTAssertEqual(second.result?["displayUUID"], .string(targetUUID))
        let callsAfterSecondRequest = await service.reconnectCalls
        XCTAssertEqual(callsAfterSecondRequest, [targetUUID, targetUUID])
    }

    func testReconnectMalformedAbsentAndDuplicateRecordsNeverReachService() async {
        let cases: [(arguments: [String: JSONValue], records: [ControlDisconnectedDisplay])] = [
            (["uuid": .string("main")], [disconnectedDisplay(uuid: targetUUID, name: "Target")]),
            (["uuid": .string(targetUUID)], []),
            (["uuid": .string(targetUUID)], [
                disconnectedDisplay(uuid: targetUUID, name: "First"),
                disconnectedDisplay(uuid: targetUUID, name: "Duplicate")
            ])
        ]

        for testCase in cases {
            let service = ConnectionMutationService(
                disconnectedInventories: [testCase.records]
            )
            let response = await ControlCommandDispatcher(
                service: service,
                appVersion: "test"
            ).handle(ControlRequest(
                requestID: "reconnect-pre-service",
                command: "displays.reconnect",
                arguments: testCase.arguments
            ))

            XCTAssertFalse(response.ok, "\(testCase.arguments)")
            let reconnectCalls = await service.reconnectCalls
            XCTAssertEqual(reconnectCalls, [], "\(testCase.arguments)")
        }
    }

    func testConnectionPreflightAndPostDispatchErrorsRemainDistinct() async {
        let target = onlineDisplay(uuid: targetUUID, name: "Target")
        let preflight = DisplayConnectionMutationError(
            classification: .preflightRejected,
            displayUUID: targetUUID,
            requestedConnectionState: .disconnected,
            message: "last viewable display"
        )
        let preflightService = ConnectionMutationService(
            displayInventories: [[target], [target]], mutationError: preflight
        )
        let preflightResponse = await ControlCommandDispatcher(
            service: preflightService, appVersion: "test"
        ).handle(disconnectRequest())
        XCTAssertEqual(preflightResponse.error?.code, .unsupportedCapability)
        XCTAssertEqual(preflightResponse.error?.details?["phase"], .string("preflight"))
        XCTAssertEqual(preflightResponse.error?.details?["retrySafe"], .bool(true))
        XCTAssertEqual(preflightResponse.error?.details?["mutationDispatched"], .bool(false))

        let definite = DisplayConnectionMutationError(
            classification: .definiteFailure,
            displayUUID: targetUUID,
            requestedConnectionState: .disconnected,
            message: "configuration was rejected before hardware dispatch"
        )
        let definiteService = ConnectionMutationService(
            displayInventories: [[target], [target]], mutationError: definite
        )
        let definiteResponse = await ControlCommandDispatcher(
            service: definiteService, appVersion: "test"
        ).handle(disconnectRequest())
        XCTAssertEqual(definiteResponse.error?.code, .writeVerificationFailed)
        XCTAssertEqual(definiteResponse.error?.details?["phase"], .string("preflight"))
        XCTAssertEqual(definiteResponse.error?.details?["retrySafe"], .bool(true))
        XCTAssertEqual(definiteResponse.error?.details?["mutationDispatched"], .bool(false))

        let unknown = DisplayConnectionMutationError(
            classification: .indeterminate,
            displayUUID: targetUUID,
            requestedConnectionState: .disconnected,
            message: "configuration timed out after dispatch"
        )
        let unknownService = ConnectionMutationService(
            displayInventories: [[target], [target]], mutationError: unknown
        )
        let unknownResponse = await ControlCommandDispatcher(
            service: unknownService, appVersion: "test"
        ).handle(disconnectRequest())
        XCTAssertEqual(unknownResponse.error?.code, .writeOutcomeIndeterminate)
        XCTAssertEqual(unknownResponse.error?.details?["retrySafe"], .bool(false))
        XCTAssertEqual(unknownResponse.error?.details?["command"], .string("displays.disconnect"))
        XCTAssertEqual(unknownResponse.error?.details?["displayUUID"], .string(targetUUID))
        XCTAssertEqual(
            unknownResponse.error?.details?["requestedConnectionState"],
            .string("disconnected")
        )
        XCTAssertEqual(unknownResponse.error?.code.exitCode, 5)
    }

    func testCancellationAfterDispatchIsIndeterminateForDisconnectAndReconnect() async {
        for command in ["displays.disconnect", "displays.reconnect"] {
            let started = MutationStartedSignal()
            let service = ConnectionMutationService(
                displayInventories: [[onlineDisplay(uuid: targetUUID)], [onlineDisplay(uuid: targetUUID)]],
                disconnectedInventories: [[disconnectedDisplay(uuid: targetUUID, name: "Target")]],
                started: started
            )
            let request = command == "displays.disconnect"
                ? disconnectRequest()
                : ControlRequest(
                    requestID: "cancel-reconnect",
                    command: command,
                    arguments: ["uuid": .string(targetUUID)]
                )
            let task = Task {
                await ControlCommandDispatcher(service: service, appVersion: "test").handle(request)
            }
            await started.waitUntilStarted()
            task.cancel()
            let response = await task.value

            XCTAssertEqual(response.error?.code, .writeOutcomeIndeterminate)
            XCTAssertEqual(response.error?.details?["retrySafe"], .bool(false))
            XCTAssertEqual(response.error?.details?["command"], .string(command))
            XCTAssertEqual(response.error?.details?["displayUUID"], .string(targetUUID))
        }
    }

    private func disconnectRequest() -> ControlRequest {
        ControlRequest(
            requestID: "disconnect-error",
            command: "displays.disconnect",
            arguments: ["uuid": .string(targetUUID)]
        )
    }
}

private func disconnectedDisplay(uuid: String, name: String) -> ControlDisconnectedDisplay {
    ControlDisconnectedDisplay(
        uuid: uuid,
        name: name,
        width: 2560,
        height: 1440,
        connection: DisplayConnectionCapability(
            state: .writable,
            connected: false,
            disconnectAllowed: false,
            reconnectAllowed: true,
            platformSupported: true
        )
    )
}

private actor DisconnectedInventoryService: ControlCommandService {
    let disconnected: [ControlDisconnectedDisplay]

    init(disconnected: [ControlDisconnectedDisplay]) { self.disconnected = disconnected }

    func displays() async throws -> [ControlDisplay] {
        [ControlDisplay(
            uuid: "online-display",
            name: "Online Display",
            isMain: true,
            isBuiltin: true,
            brightness: .unsupported(reason: "fixture"),
            connection: DisplayConnectionCapability(
                state: .writable,
                connected: true,
                disconnectAllowed: true,
                reconnectAllowed: false,
                platformSupported: true
            )
        )]
    }

    func disconnectedDisplays() async throws -> [ControlDisconnectedDisplay] { disconnected }
    func readBrightness(displayUUID: String) async throws -> Double? { nil }
    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double { percent }
}

private actor LegacyControlService: ControlCommandService {
    func displays() async throws -> [ControlDisplay] { [] }
    func readBrightness(displayUUID: String) async throws -> Double? { nil }
    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double { percent }
}

private func onlineDisplay(
    uuid: String,
    name: String = "Target",
    connection: DisplayConnectionCapability? = nil
) -> ControlDisplay {
    ControlDisplay(
        uuid: uuid,
        name: name,
        isMain: false,
        isBuiltin: false,
        brightness: .unsupported(reason: "fixture"),
        connection: connection ?? DisplayConnectionCapability(
            state: .writable,
            connected: true,
            disconnectAllowed: true,
            reconnectAllowed: false,
            platformSupported: true
        )
    )
}

private actor ConnectionMutationService: ControlCommandService {
    private var displayInventories: [[ControlDisplay]]
    private var disconnectedInventories: [[ControlDisconnectedDisplay]]
    private let mutationError: DisplayConnectionMutationError?
    private let started: MutationStartedSignal?
    private(set) var displayCallCount = 0
    private(set) var disconnectCalls: [String] = []
    private(set) var reconnectCalls: [String] = []

    init(
        displayInventories: [[ControlDisplay]] = [],
        disconnectedInventories: [[ControlDisconnectedDisplay]] = [],
        mutationError: DisplayConnectionMutationError? = nil,
        started: MutationStartedSignal? = nil
    ) {
        self.displayInventories = displayInventories
        self.disconnectedInventories = disconnectedInventories
        self.mutationError = mutationError
        self.started = started
    }

    func displays() async throws -> [ControlDisplay] {
        displayCallCount += 1
        guard !displayInventories.isEmpty else { return [] }
        if displayInventories.count == 1 { return displayInventories[0] }
        return displayInventories.removeFirst()
    }

    func disconnectedDisplays() async throws -> [ControlDisconnectedDisplay] {
        guard !disconnectedInventories.isEmpty else { return [] }
        if disconnectedInventories.count == 1 { return disconnectedInventories[0] }
        return disconnectedInventories.removeFirst()
    }

    func disconnectDisplay(displayUUID: String) async throws -> DisplayConnectionSetResult {
        disconnectCalls.append(displayUUID)
        try await waitIfRequested()
        if let mutationError { throw mutationError }
        return result(uuid: displayUUID, state: .disconnected)
    }

    func reconnectDisplay(displayUUID: String) async throws -> DisplayConnectionSetResult {
        reconnectCalls.append(displayUUID)
        try await waitIfRequested()
        if let mutationError { throw mutationError }
        return result(uuid: displayUUID, state: .connected)
    }

    func readBrightness(displayUUID: String) async throws -> Double? { nil }
    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double { percent }

    private func waitIfRequested() async throws {
        guard let started else { return }
        await started.markStarted()
        try await Task.sleep(for: .seconds(10))
    }

    private func result(
        uuid: String,
        state: DisplayConnectionState
    ) -> DisplayConnectionSetResult {
        DisplayConnectionSetResult(
            displayUUID: uuid,
            requestedConnectionState: state,
            observedConnectionState: state,
            verification: .sameUUIDEnumeration
        )
    }
}

private actor OrphanReconnectService: ControlCommandService {
    private let disconnected: ControlDisconnectedDisplay
    private(set) var reconnectCalls: [String] = []

    init(disconnected: ControlDisconnectedDisplay) {
        self.disconnected = disconnected
    }

    func displays() async throws -> [ControlDisplay] { [] }

    func disconnectedDisplays() async throws -> [ControlDisconnectedDisplay] {
        [disconnected]
    }

    func reconnectDisplay(displayUUID: String) async throws -> DisplayConnectionSetResult {
        reconnectCalls.append(displayUUID)
        if reconnectCalls.count == 1 {
            throw DisplayConnectionMutationError(
                classification: .indeterminate,
                displayUUID: displayUUID,
                requestedConnectionState: .connected,
                mutationDispatched: false,
                message: "prior reconnect was reconciled without a display write"
            )
        }
        return DisplayConnectionSetResult(
            displayUUID: displayUUID,
            requestedConnectionState: .connected,
            observedConnectionState: .connected,
            verification: .sameUUIDEnumeration
        )
    }

    func readBrightness(displayUUID: String) async throws -> Double? { nil }
    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double { percent }
}

private actor MutationStartedSignal {
    private var started = false

    func markStarted() { started = true }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}
