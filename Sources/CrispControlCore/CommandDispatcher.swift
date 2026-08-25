import Foundation

public protocol ControlCommandService: Sendable {
    func displays() async throws -> [ControlDisplay]
    func readBrightness(displayUUID: String) async throws -> Double?
    func writeBrightness(displayUUID: String, percent: Double) async throws -> Double
    func readBrightnessState(displayUUID: String) async throws -> BrightnessReadSnapshot?
    func setExtraBrightness(displayUUID: String, enabled: Bool) async throws -> ExtraBrightnessSetResult
    func setHDR(displayUUID: String, enabled: Bool) async throws -> HDRSetResult
}

public extension ControlCommandService {
    func readBrightnessState(displayUUID: String) async throws -> BrightnessReadSnapshot? {
        try await readBrightness(displayUUID: displayUUID).map {
            BrightnessReadSnapshot(logicalPercent: $0, hardwareReadbackPercent: nil)
        }
    }

    func setExtraBrightness(displayUUID: String, enabled: Bool) async throws -> ExtraBrightnessSetResult {
        throw ControlServiceError.unsupported("Extra Brightness control is unavailable")
    }

    func setHDR(displayUUID: String, enabled: Bool) async throws -> HDRSetResult {
        throw ControlServiceError.unsupported("HDR control is unavailable")
    }
}

public enum ControlServiceError: Error, Sendable {
    case unsupported(String)
    case readFailed(String)
    case writeFailed(String)
    case writeIndeterminate(String)
}

public struct ControlCommandDispatcher: Sendable {
    private let service: any ControlCommandService
    private let appVersion: String
    private let batchExecutionTimeout: TimeInterval
    private let batchMonotonicNow: @Sendable () -> TimeInterval
    private let batchMemberBoundary: @Sendable (Int) async -> Void

    public init(
        service: any ControlCommandService,
        appVersion: String,
        batchExecutionTimeout: TimeInterval = 10,
        batchMonotonicNow: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        batchMemberBoundary: @escaping @Sendable (Int) async -> Void = { _ in }
    ) {
        self.service = service
        self.appVersion = appVersion
        self.batchExecutionTimeout = batchExecutionTimeout
        self.batchMonotonicNow = batchMonotonicNow
        self.batchMemberBoundary = batchMemberBoundary
    }

    public func handle(_ request: ControlRequest) async -> ControlResponse {
        do {
            let result = try await execute(request)
            return .success(requestID: request.requestID, result: result)
        } catch let failure as CommandFailure {
            return .failure(requestID: request.requestID, code: failure.code,
                            message: failure.message, details: failure.details)
        } catch let error as ControlServiceError {
            switch error {
            case let .unsupported(message):
                return .failure(requestID: request.requestID, code: .unsupportedCapability, message: message)
            case let .readFailed(message):
                return .failure(requestID: request.requestID, code: .internalError, message: message)
            case let .writeFailed(message):
                return .failure(requestID: request.requestID, code: .writeVerificationFailed, message: message)
            case let .writeIndeterminate(message):
                return .failure(
                    requestID: request.requestID, code: .writeOutcomeIndeterminate, message: message,
                    details: .object(["retrySafe": .bool(false), "outcome": .string("unknown")])
                )
            }
        } catch is CancellationError {
            if request.isMutating {
                let timeoutResponse = ControlResponse.timeout(for: request)
                return .failure(
                    requestID: request.requestID,
                    code: .writeOutcomeIndeterminate,
                    message: "control write wait ended after cancellation; the underlying outcome is unknown",
                    details: timeoutResponse.error?.details
                )
            }
            return .failure(
                requestID: request.requestID,
                code: .timeout,
                message: "control read was cancelled before completion",
                details: .object(["cancelled": .bool(true), "retrySafe": .bool(true)])
            )
        } catch {
            return .failure(requestID: request.requestID, code: .internalError,
                            message: "Crisp could not complete the command")
        }
    }

    private func execute(_ request: ControlRequest) async throws -> JSONValue {
        switch request.command {
        case "version":
            return .object([
                "appVersion": .string(appVersion),
                "protocolVersion": .number(Double(crispControlProtocolVersion))
            ])
        case "status":
            return .object(["running": .bool(true), "appVersion": .string(appVersion)])
        case "displays.list":
            return .object(["displays": try jsonValue(await service.displays())])
        case "displays.get":
            return .object(["display": try jsonValue(await selectedDisplay(for: request))])
        case "displays.capabilities":
            let display = try await selectedDisplay(for: request)
            return .object([
                "displayUUID": .string(display.uuid),
                "brightness": try jsonValue(display.brightness),
                "extraBrightness": try jsonValue(display.extraBrightness),
                "hdr": try jsonValue(display.hdr)
            ])
        case "brightness.get":
            let display = try await selectedDisplay(for: request)
            try requireSupported(display.brightness)
            guard let snapshot = try await service.readBrightnessState(displayUUID: display.uuid) else {
                throw CommandFailure(code: .unsupportedCapability,
                                     message: "brightness read-back is unavailable",
                                     details: .object(["displayUUID": .string(display.uuid)]))
            }
            return .object([
                "displayUUID": .string(display.uuid),
                "percent": .number(snapshot.logicalPercent),
                "logicalPercent": .number(snapshot.logicalPercent),
                "hardwareReadbackPercent": snapshot.hardwareReadbackPercent.map(JSONValue.number) ?? .null,
                "backend": .string(display.brightness.backend.rawValue),
                "readback": .string(display.brightness.readback.rawValue)
            ])
        case "brightness.set":
            return try await setBrightness(request)
        case "brightness.get-all":
            return try await getAllBrightness()
        case "brightness.set-all":
            return try await setAllBrightness(request)
        case "extra-brightness.get":
            let display = try await selectedDisplay(for: request)
            try requireSupported(display.extraBrightness.state, capability: display.extraBrightness,
                                 defaultMessage: "Extra Brightness is unsupported")
            return try capabilityResult(displayUUID: display.uuid, capability: display.extraBrightness)
        case "extra-brightness.set":
            return try await setExtraBrightness(request)
        case "hdr.get":
            let display = try await selectedDisplay(for: request)
            try requireSupported(display.hdr.state, capability: display.hdr,
                                 defaultMessage: "HDR is unsupported")
            return try capabilityResult(displayUUID: display.uuid, capability: display.hdr)
        case "hdr.set":
            return try await setHDR(request)
        default:
            throw CommandFailure(code: .invalidArguments, message: "unknown command: \(request.command)")
        }
    }

    private func selectedDisplay(for request: ControlRequest) async throws -> ControlDisplay {
        guard case let .string(selector)? = request.arguments["selector"], !selector.isEmpty else {
            throw CommandFailure(code: .invalidArguments, message: "a display selector is required")
        }
        do {
            return try DisplaySelector.resolve(selector, in: await service.displays())
        } catch let error as SelectorError {
            switch error {
            case .notFound:
                throw CommandFailure(code: .selectorNotFound, message: "display selector did not match",
                                     details: .object(["selector": .string(selector)]))
            case let .ambiguous(candidates):
                throw CommandFailure(code: .ambiguousSelector, message: "display selector is ambiguous",
                                     details: .object(["candidates": try jsonValue(candidates)]))
            }
        }
    }

    private func setBrightness(_ request: ControlRequest) async throws -> JSONValue {
        let display = try await selectedDisplay(for: request)
        let capability = display.brightness
        guard capability.state == .writable else {
            var details: [String: JSONValue] = ["state": .string(capability.state.rawValue)]
            if let reason = capability.reason { details["reason"] = .string(reason) }
            if let remediation = capability.remediation { details["remediation"] = .string(remediation) }
            throw CommandFailure(code: .unsupportedCapability,
                                 message: "brightness is not writable",
                                 details: .object(details))
        }
        guard case let .number(requested)? = request.arguments["percent"], requested.isFinite else {
            throw CommandFailure(code: .invalidArguments, message: "brightness percent must be a number")
        }
        guard requested >= capability.range.min, requested <= capability.range.max else {
            throw CommandFailure(
                code: .invalidArguments,
                message: "brightness percent is outside the supported range",
                details: .object([
                    "min": .number(capability.range.min),
                    "max": .number(capability.range.max),
                    "received": .number(requested)
                ])
            )
        }

        return try await performBrightnessSet(display: display, requested: requested)
    }

    private func performBrightnessSet(
        display: ControlDisplay,
        requested: Double,
        originalSnapshot: BrightnessReadSnapshot? = nil
    ) async throws -> JSONValue {
        let capability = display.brightness
        let original = if let originalSnapshot {
            originalSnapshot
        } else {
            try await service.readBrightnessState(displayUUID: display.uuid)
        }
        let applied = try await service.writeBrightness(displayUUID: display.uuid, percent: requested)
        try Task.checkCancellation()
        let readback: BrightnessReadSnapshot?
        let verification: String
        var warnings: [JSONValue] = []

        if capability.readback == .unavailable {
            if requested > capability.hardwareRange.max {
                readback = try await service.readBrightnessState(displayUUID: display.uuid)
            } else {
                readback = nil
            }
            if requested > capability.hardwareRange.max, let readback {
                let tolerance = max(capability.logicalRange.precision * 2, 0.25)
                guard abs(readback.logicalPercent - applied) <= tolerance else {
                    throw CommandFailure(code: .writeVerificationFailed,
                                         message: "committed app brightness did not match the applied value")
                }
                verification = "app_state_verified"
                warnings.append(.string(
                    "logical EDR state is verified in Crisp; "
                        + "no independent hardware-authoritative EDR read-back is available"
                ))
            } else {
                verification = "unavailable"
                warnings.append(.string("backend does not provide read-back; applied value is not independently verified"))
            }
        } else {
            readback = try await service.readBrightnessState(displayUUID: display.uuid)
            guard let readback else {
                throw CommandFailure(code: .writeVerificationFailed,
                                     message: "brightness write completed but read-back failed")
            }
            let tolerance = max(capability.range.precision * 2, 0.25)
            guard abs(readback.logicalPercent - applied) <= tolerance else {
                throw CommandFailure(
                    code: .writeVerificationFailed,
                    message: "brightness read-back did not match the applied value",
                    details: .object([
                        "requestedPercent": .number(requested),
                        "appliedPercent": .number(applied),
                        "readbackPercent": .number(readback.logicalPercent),
                        "tolerance": .number(tolerance)
                    ])
                )
            }
            if requested > capability.hardwareRange.max {
                verification = "app_state_verified"
                warnings.append(.string("logical EDR state is verified in Crisp; hardware read-back covers only 0...100"))
            } else {
                verification = capability.readback == .authoritative ? "verified" : "approximate"
            }
        }
        try Task.checkCancellation()

        return .object([
            "displayUUID": .string(display.uuid),
            "requestedPercent": .number(requested),
            "originalPercent": original.map { .number($0.logicalPercent) } ?? .null,
            "appliedPercent": .number(applied),
            "readbackPercent": readback.map { .number($0.logicalPercent) } ?? .null,
            "logicalPercent": readback.map { .number($0.logicalPercent) } ?? .number(applied),
            "hardwareReadbackPercent": readback?.hardwareReadbackPercent.map(JSONValue.number) ?? .null,
            "verification": .string(verification),
            "backend": .string(capability.backend.rawValue),
            "warnings": .array(warnings)
        ])
    }

    private func physicalDisplays() async throws -> [ControlDisplay] {
        let displays = try await service.displays().filter { !$0.isVirtual }.sorted { $0.uuid < $1.uuid }
        guard !displays.isEmpty else {
            throw CommandFailure(
                code: .emptyPhysicalInventory,
                message: "no connected non-virtual physical displays were found"
            )
        }
        return displays
    }

    private func getAllBrightness() async throws -> JSONValue {
        let displays = try await physicalDisplays()
        var results: [JSONValue] = []
        for display in displays {
            do {
                try requireSupported(display.brightness)
                guard let snapshot = try await service.readBrightnessState(displayUUID: display.uuid) else {
                    throw CommandFailure(code: .unsupportedCapability,
                                         message: "brightness read-back is unavailable")
                }
                results.append(.object([
                    "displayUUID": .string(display.uuid),
                    "ok": .bool(true),
                    "percent": .number(snapshot.logicalPercent),
                    "logicalPercent": .number(snapshot.logicalPercent),
                    "hardwareReadbackPercent": snapshot.hardwareReadbackPercent.map(JSONValue.number) ?? .null,
                    "brightness": try jsonValue(display.brightness),
                    "extraBrightness": try jsonValue(display.extraBrightness),
                    "hdr": try jsonValue(display.hdr)
                ]))
            } catch let failure as CommandFailure {
                results.append(batchReadFailure(displayUUID: display.uuid, failure: failure))
            } catch {
                results.append(batchReadFailure(
                    displayUUID: display.uuid,
                    failure: CommandFailure(code: .internalError, message: "brightness read failed")
                ))
            }
        }
        return .object([
            "semantics": .string("same_logical_percent_per_display"),
            "displays": .array(results)
        ])
    }

    private func batchReadFailure(displayUUID: String, failure: CommandFailure) -> JSONValue {
        var error: [String: JSONValue] = [
            "code": .string(failure.code.rawValue),
            "message": .string(failure.message)
        ]
        if let details = failure.details { error["details"] = details }
        return .object([
            "displayUUID": .string(displayUUID), "ok": .bool(false), "error": .object(error)
        ])
    }

    private func setAllBrightness(_ request: ControlRequest) async throws -> JSONValue {
        guard case let .number(requested)? = request.arguments["percent"], requested.isFinite else {
            throw CommandFailure(code: .invalidArguments, message: "brightness percent must be a number")
        }
        let commandDeadline = BatchDeadline(
            timeout: batchExecutionTimeout, now: batchMonotonicNow
        )
        let displays = try await batchDisplays(deadline: commandDeadline)
        let snapshots = try await batchSnapshots(
            displays: displays,
            requested: requested,
            deadline: commandDeadline
        )

        let execution = await executeBatch(
            displays: displays,
            snapshots: snapshots,
            requested: requested,
            deadline: commandDeadline
        )
        return try execution.response(requested: requested)
    }

    private func batchPreflightDeadlineFailure(
        phase: String,
        reason: String,
        cancelled: Bool = false
    ) -> CommandFailure {
        CommandFailure(
            code: .batchPreflightFailed,
            message: "batch brightness preflight failed; no writes were attempted",
            details: .object([
                "retrySafe": .bool(true),
                "phase": .string(phase),
                "reason": .string(reason),
                "cancelled": .bool(cancelled)
            ])
        )
    }

    private func performBatchInventory(timeout: TimeInterval) async -> BatchInventoryOutcome {
        let race = BatchInventoryRace()
        let operation = Task {
            do {
                await race.resolve(.success(try await service.displays()))
            } catch is CancellationError {
                await race.resolve(.cancelled("display inventory wait was cancelled"))
            } catch {
                await race.resolve(.failed("display inventory failed"))
            }
        }
        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await race.resolve(.timedOut("display inventory exceeded the batch deadline"))
        }
        let outcome = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            deadline.cancel()
            Task {
                await race.resolve(.cancelled("display inventory wait was cancelled"))
                operation.cancel()
            }
        }
        deadline.cancel()
        if case .timedOut = outcome { operation.cancel() }
        return outcome
    }

    private func performBatchMember(
        display: ControlDisplay,
        requested: Double,
        originalSnapshot: BrightnessReadSnapshot?,
        timeout: TimeInterval
    ) async -> BatchMemberOutcome {
        let race = BatchMemberRace()
        let operation = Task {
            let outcome: BatchMemberOutcome
            do {
                outcome = .success(try await performBrightnessSet(
                    display: display, requested: requested, originalSnapshot: originalSnapshot
                ))
            } catch let error as ControlServiceError {
                switch error {
                case let .writeIndeterminate(message): outcome = .indeterminate(message)
                case let .writeFailed(message): outcome = .failed(.writeVerificationFailed, message)
                case let .readFailed(message): outcome = .failed(.internalError, message)
                case let .unsupported(message): outcome = .failed(.unsupportedCapability, message)
                }
            } catch let failure as CommandFailure {
                outcome = .failed(failure.code, failure.message)
            } catch is CancellationError {
                outcome = .indeterminate("batch member wait was cancelled; the write outcome is unknown")
            } catch {
                outcome = .failed(.internalError, "brightness write failed")
            }
            await race.resolve(outcome)
        }
        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await race.resolve(.indeterminate("batch member exceeded its bounded execution deadline"))
        }
        let outcome = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            deadline.cancel()
            Task {
                await race.resolve(.indeterminate(
                    "batch member wait was cancelled; the write outcome is unknown"
                ))
                operation.cancel()
            }
        }
        deadline.cancel()
        if case .indeterminate = outcome { operation.cancel() }
        return outcome
    }

    private func performBatchSnapshot(
        displayUUID: String,
        timeout: TimeInterval
    ) async -> BatchSnapshotOutcome {
        let race = BatchSnapshotRace()
        let operation = Task {
            do {
                guard let snapshot = try await service.readBrightnessState(displayUUID: displayUUID) else {
                    await race.resolve(.failed("brightness snapshot unavailable"))
                    return
                }
                await race.resolve(.success(snapshot))
            } catch is CancellationError {
                await race.resolve(.cancelled("brightness snapshot wait was cancelled"))
            } catch {
                await race.resolve(.failed("brightness snapshot failed"))
            }
        }
        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await race.resolve(.timedOut("brightness snapshot exceeded the batch deadline"))
        }
        let outcome = await withTaskCancellationHandler {
            await race.wait()
        } onCancel: {
            deadline.cancel()
            Task {
                await race.resolve(.cancelled("brightness snapshot wait was cancelled"))
                operation.cancel()
            }
        }
        deadline.cancel()
        if case .timedOut = outcome { operation.cancel() }
        return outcome
    }

    private func setExtraBrightness(_ request: ControlRequest) async throws -> JSONValue {
        let display = try await selectedDisplay(for: request)
        let enabled = try requestedEnabled(request)
        if enabled || !display.needsExtraBrightnessDisableCleanup {
            try requireWritable(display.extraBrightness.state, capability: display.extraBrightness,
                                message: "Extra Brightness is not writable")
        }
        let result = try await service.setExtraBrightness(displayUUID: display.uuid, enabled: enabled)
        try Task.checkCancellation()
        return try setCapabilityResult(displayUUID: display.uuid, requestedEnabled: enabled,
                                       capability: result.capability, verification: result.verification,
                                       warnings: result.warnings)
    }

    private func setHDR(_ request: ControlRequest) async throws -> JSONValue {
        let display = try await selectedDisplay(for: request)
        try requireWritable(display.hdr.state, capability: display.hdr, message: "HDR is not writable")
        let enabled = try requestedEnabled(request)
        let result = try await service.setHDR(displayUUID: display.uuid, enabled: enabled)
        try Task.checkCancellation()
        return try setCapabilityResult(displayUUID: display.uuid, requestedEnabled: enabled,
                                       capability: result.capability, verification: result.verification,
                                       warnings: result.warnings)
    }

    private func requestedEnabled(_ request: ControlRequest) throws -> Bool {
        guard case let .bool(enabled)? = request.arguments["enabled"] else {
            throw CommandFailure(code: .invalidArguments, message: "state must be on or off")
        }
        return enabled
    }

    private func capabilityResult<T: Encodable>(displayUUID: String, capability: T) throws -> JSONValue {
        guard case var .object(fields) = try jsonValue(capability) else { return .null }
        fields["displayUUID"] = .string(displayUUID)
        return .object(fields)
    }

    private func setCapabilityResult<T: Encodable>(
        displayUUID: String,
        requestedEnabled: Bool,
        capability: T,
        verification: AppStateVerificationQuality,
        warnings: [String]
    ) throws -> JSONValue {
        guard case var .object(fields) = try capabilityResult(displayUUID: displayUUID, capability: capability) else {
            return .null
        }
        fields["requestedEnabled"] = .bool(requestedEnabled)
        fields["verification"] = .string(verification.rawValue)
        fields["warnings"] = .array(warnings.map(JSONValue.string))
        return .object(fields)
    }

    private func requireWritable<T: Encodable>(
        _ state: CapabilityState, capability: T, message: String
    ) throws {
        guard state == .writable else {
            throw CommandFailure(code: .unsupportedCapability, message: message,
                                 details: try jsonValue(capability))
        }
    }

    private func requireSupported<T: Encodable>(
        _ state: CapabilityState, capability: T, defaultMessage: String
    ) throws {
        guard state == .readable || state == .writable else {
            throw CommandFailure(code: .unsupportedCapability, message: defaultMessage,
                                 details: try jsonValue(capability))
        }
    }

    private func requireSupported(_ capability: BrightnessCapability) throws {
        guard capability.state == .readable || capability.state == .writable else {
            var details: [String: JSONValue] = ["state": .string(capability.state.rawValue)]
            if let reason = capability.reason { details["reason"] = .string(reason) }
            if let remediation = capability.remediation { details["remediation"] = .string(remediation) }
            throw CommandFailure(code: .unsupportedCapability,
                                 message: capability.reason ?? "brightness is unsupported",
                                 details: .object(details))
        }
    }
}

private extension ControlCommandDispatcher {
    func batchDisplays(deadline: BatchDeadline) async throws -> [ControlDisplay] {
        let displays: [ControlDisplay]
        switch await performBatchInventory(timeout: deadline.remaining) {
        case let .success(inventory):
            displays = inventory.filter { !$0.isVirtual }.sorted { $0.uuid < $1.uuid }
        case let .failed(reason), let .timedOut(reason):
            throw batchPreflightDeadlineFailure(phase: "inventory", reason: reason)
        case let .cancelled(reason):
            throw batchPreflightDeadlineFailure(
                phase: "inventory",
                reason: reason,
                cancelled: true
            )
        }
        guard !displays.isEmpty else {
            throw CommandFailure(
                code: .emptyPhysicalInventory,
                message: "no connected non-virtual physical displays were found"
            )
        }
        guard deadline.remaining > 0 else {
            throw batchPreflightDeadlineFailure(
                phase: "inventory",
                reason: "batch inventory deadline elapsed"
            )
        }
        return displays
    }

    func batchSnapshots(
        displays: [ControlDisplay],
        requested: Double,
        deadline: BatchDeadline
    ) async throws -> [String: BrightnessReadSnapshot] {
        var preflight = BatchPreflightAccumulator()
        for display in displays {
            guard display.brightness.accepts(requested) else {
                preflight.rejectCapability(display: display, requested: requested)
                continue
            }
            let remaining = deadline.remaining
            guard remaining > 0 else {
                preflight.reject(display: display, reason: "batch snapshot deadline elapsed")
                continue
            }
            let snapshot = await performBatchSnapshot(displayUUID: display.uuid, timeout: remaining)
            preflight.record(snapshot, display: display, beforeDeadline: deadline.remaining > 0)
        }
        if let failure = preflight.failure(displays: displays) { throw failure }
        return preflight.snapshots
    }

    func executeBatch(
        displays: [ControlDisplay],
        snapshots: [String: BrightnessReadSnapshot],
        requested: Double,
        deadline: BatchDeadline
    ) async -> BatchExecutionAccumulator {
        var execution = BatchExecutionAccumulator()
        for (index, display) in displays.enumerated() {
            if Task.isCancelled {
                execution.appendNotAttempted(
                    displays.dropFirst(index),
                    message: "batch execution wait was cancelled before this member"
                )
                break
            }
            let remaining = deadline.remaining
            if remaining <= 0 {
                execution.appendNotAttempted(
                    displays.dropFirst(index),
                    message: "batch execution deadline elapsed before this member"
                )
                break
            }
            let member = await performBatchMember(
                display: display,
                requested: requested,
                originalSnapshot: snapshots[display.uuid],
                timeout: remaining
            )
            let classifiedMember: BatchMemberOutcome = if deadline.isExpired {
                .indeterminate(
                    "batch member completed after the absolute execution deadline; "
                        + "the write outcome is unknown"
                )
            } else {
                member
            }
            if execution.record(classifiedMember, display: display) {
                execution.appendNotAttempted(
                    displays.dropFirst(index + 1),
                    message: "batch stopped after an indeterminate member"
                )
                break
            }
            await batchMemberBoundary(index)
        }
        return execution
    }
}

private extension BrightnessCapability {
    func accepts(_ requested: Double) -> Bool {
        state == .writable && requested >= logicalRange.min && requested <= logicalRange.max
    }
}

private extension ControlDisplay {
    var needsExtraBrightnessDisableCleanup: Bool {
        extraBrightness.persistedEnabled
            || extraBrightness.enabled == true
            || extraBrightness.maxBrightness > 100
            || (brightnessPercent ?? 0) > 100
    }
}

private struct BatchPreflightAccumulator {
    var snapshots: [String: BrightnessReadSnapshot] = [:]
    private var failures: [JSONValue] = []
    private var failedUUIDs: [JSONValue] = []
    private var failedUUIDSet: Set<String> = []
    private var cancelled = false

    mutating func rejectCapability(display: ControlDisplay, requested: Double) {
        reject(display: display, details: [
            "displayUUID": .string(display.uuid),
            "state": .string(display.brightness.state.rawValue),
            "min": .number(display.brightness.logicalRange.min),
            "max": .number(display.brightness.logicalRange.max),
            "received": .number(requested)
        ])
    }

    mutating func reject(display: ControlDisplay, reason: String, cancelled: Bool = false) {
        var details: [String: JSONValue] = [
            "displayUUID": .string(display.uuid),
            "reason": .string(reason)
        ]
        if cancelled { details["cancelled"] = .bool(true) }
        reject(display: display, details: details)
        self.cancelled = self.cancelled || cancelled
    }

    mutating func record(
        _ outcome: BatchSnapshotOutcome,
        display: ControlDisplay,
        beforeDeadline: Bool
    ) {
        switch outcome {
        case let .success(snapshot) where beforeDeadline:
            snapshots[display.uuid] = snapshot
        case .success:
            reject(display: display, reason: "batch snapshot deadline elapsed")
        case let .failed(reason), let .timedOut(reason):
            reject(display: display, reason: reason)
        case let .cancelled(reason):
            reject(display: display, reason: reason, cancelled: true)
        }
    }

    func failure(displays: [ControlDisplay]) -> CommandFailure? {
        guard !failures.isEmpty else { return nil }
        let outcomes = displays.map { display in
            JSONValue.object([
                "displayUUID": .string(display.uuid),
                "ok": .bool(false),
                "attempted": .bool(false),
                "outcome": .string(failedUUIDSet.contains(display.uuid) ? "preflight_failed" : "not_attempted"),
                "verification": .string("unavailable"),
                "code": .string(ControlErrorCode.batchPreflightFailed.rawValue),
                "retrySafe": .bool(true)
            ])
        }
        return CommandFailure(
            code: .batchPreflightFailed,
            message: "batch brightness preflight failed; no writes were attempted",
            details: .object([
                "retrySafe": .bool(true),
                "phase": .string("snapshot"),
                "cancelled": .bool(cancelled),
                "failedUUIDs": .array(failedUUIDs),
                "failures": .array(failures),
                "outcomes": .array(outcomes)
            ])
        )
    }

    private mutating func reject(display: ControlDisplay, details: [String: JSONValue]) {
        failedUUIDs.append(.string(display.uuid))
        failedUUIDSet.insert(display.uuid)
        failures.append(.object(details))
    }
}

private struct BatchExecutionAccumulator {
    private var outcomes: [JSONValue] = []
    private var appliedUUIDs: [JSONValue] = []
    private var failedUUIDs: [JSONValue] = []
    private var indeterminateUUIDs: [JSONValue] = []
    private var notAttemptedUUIDs: [JSONValue] = []

    /// Returns true when later members must not be attempted.
    mutating func record(_ member: BatchMemberOutcome, display: ControlDisplay) -> Bool {
        switch member {
        case let .success(value):
            guard case var .object(fields) = value else { return false }
            fields["ok"] = .bool(true)
            fields["attempted"] = .bool(true)
            fields["outcome"] = .string("applied")
            fields["code"] = .null
            fields["retrySafe"] = .bool(false)
            outcomes.append(.object(fields))
            appliedUUIDs.append(.string(display.uuid))
            return false
        case let .failed(code, message):
            failedUUIDs.append(.string(display.uuid))
            outcomes.append(failedOutcome(display: display, code: code, message: message))
            return false
        case let .indeterminate(message):
            failedUUIDs.append(.string(display.uuid))
            indeterminateUUIDs.append(.string(display.uuid))
            outcomes.append(failedOutcome(
                display: display,
                code: .writeOutcomeIndeterminate,
                message: message,
                outcome: "indeterminate"
            ))
            return true
        }
    }

    mutating func appendNotAttempted(
        _ displays: ArraySlice<ControlDisplay>,
        message: String
    ) {
        for display in displays {
            notAttemptedUUIDs.append(.string(display.uuid))
            outcomes.append(.object([
                "displayUUID": .string(display.uuid),
                "ok": .bool(false),
                "attempted": .bool(false),
                "outcome": .string("not_attempted"),
                "verification": .string("unavailable"),
                "code": .string(ControlErrorCode.batchPartialFailure.rawValue),
                "message": .string(message),
                "retrySafe": .bool(true)
            ]))
        }
    }

    func response(requested: Double) throws -> JSONValue {
        let summary: [String: JSONValue] = [
            "semantics": .string("same_logical_percent_per_display"),
            "requestedPercent": .number(requested),
            "outcomes": .array(outcomes),
            "appliedUUIDs": .array(appliedUUIDs),
            "failedUUIDs": .array(failedUUIDs),
            "indeterminateUUIDs": .array(indeterminateUUIDs),
            "notAttemptedUUIDs": .array(notAttemptedUUIDs),
            "retrySafe": .bool(false)
        ]
        guard failedUUIDs.isEmpty, notAttemptedUUIDs.isEmpty else {
            throw CommandFailure(
                code: .batchPartialFailure,
                message: "batch brightness write partially failed; "
                    + "successful and indeterminate members must not be retried",
                details: .object(summary)
            )
        }
        return .object(summary)
    }

    private func failedOutcome(
        display: ControlDisplay,
        code: ControlErrorCode,
        message: String,
        outcome: String = "failed"
    ) -> JSONValue {
        .object([
            "displayUUID": .string(display.uuid),
            "ok": .bool(false),
            "attempted": .bool(true),
            "outcome": .string(outcome),
            "verification": .string("unavailable"),
            "code": .string(code.rawValue),
            "message": .string(message),
            "retrySafe": .bool(false)
        ])
    }
}

private struct CommandFailure: Error {
    let code: ControlErrorCode
    let message: String
    let details: JSONValue?

    init(code: ControlErrorCode, message: String, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }
}

private struct BatchDeadline: Sendable {
    private let expiresAt: TimeInterval
    private let now: @Sendable () -> TimeInterval

    init(timeout: TimeInterval, now: @escaping @Sendable () -> TimeInterval) {
        self.now = now
        expiresAt = now() + max(0, timeout)
    }

    var remaining: TimeInterval { max(0, expiresAt - now()) }
    var isExpired: Bool { now() >= expiresAt }
}

private enum BatchInventoryOutcome: Sendable {
    case success([ControlDisplay])
    case failed(String)
    case timedOut(String)
    case cancelled(String)
}

private actor BatchInventoryRace {
    private var outcome: BatchInventoryOutcome?
    private var continuation: CheckedContinuation<BatchInventoryOutcome, Never>?

    func wait() async -> BatchInventoryOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ value: BatchInventoryOutcome) {
        guard outcome == nil else { return }
        outcome = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private enum BatchMemberOutcome: Sendable {
    case success(JSONValue)
    case failed(ControlErrorCode, String)
    case indeterminate(String)
}

private actor BatchMemberRace {
    private var outcome: BatchMemberOutcome?
    private var continuation: CheckedContinuation<BatchMemberOutcome, Never>?

    func wait() async -> BatchMemberOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ value: BatchMemberOutcome) {
        guard outcome == nil else { return }
        outcome = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private enum BatchSnapshotOutcome: Sendable {
    case success(BrightnessReadSnapshot)
    case failed(String)
    case timedOut(String)
    case cancelled(String)
}

private actor BatchSnapshotRace {
    private var outcome: BatchSnapshotOutcome?
    private var continuation: CheckedContinuation<BatchSnapshotOutcome, Never>?

    func wait() async -> BatchSnapshotOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ value: BatchSnapshotOutcome) {
        guard outcome == nil else { return }
        outcome = value
        continuation?.resume(returning: value)
        continuation = nil
    }
}

private func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
    try ControlJSON.decoder.decode(JSONValue.self, from: ControlJSON.encoder.encode(value))
}
