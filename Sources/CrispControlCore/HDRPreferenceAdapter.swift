import Foundation

public struct ObjectiveCMethodEncoding: Equatable, Sendable {
    public let returnType: String
    public let argumentTypes: [String]

    public init(returnType: String, argumentTypes: [String]) {
        self.returnType = returnType
        self.argumentTypes = argumentTypes
    }
}

public enum MonitorPanelABIMethod: Equatable, Sendable {
    case displaysGetter
    case displayIDGetter
    case boolGetter
    case boolSetter
}

public enum MonitorPanelABISignatureValidator {
    public static func isCompatible(
        _ encoding: ObjectiveCMethodEncoding,
        with method: MonitorPanelABIMethod
    ) -> Bool {
        let returnType = normalized(encoding.returnType)
        let arguments = encoding.argumentTypes.map(normalized)
        guard arguments.count >= 2, arguments[0] == "@", arguments[1] == ":" else {
            return false
        }
        switch method {
        case .displaysGetter:
            return arguments.count == 2 && returnType == "@"
        case .displayIDGetter:
            return arguments.count == 2 && returnType == "I"
        case .boolGetter:
            return arguments.count == 2 && isBoolean(returnType)
        case .boolSetter:
            return arguments.count == 3 && returnType == "v" && isBoolean(arguments[2])
        }
    }

    private static func isBoolean(_ encoding: String) -> Bool {
        encoding == "B" || encoding == "c"
    }

    private static func normalized(_ encoding: String) -> String {
        let qualifiers = CharacterSet(charactersIn: "rnNoORV")
        let trimmed = encoding.drop(while: { character in
            character.unicodeScalars.allSatisfy { qualifiers.contains($0) }
        })
        guard let first = trimmed.first else { return "" }
        return first == "@" ? "@" : String(first)
    }
}

public struct HDRAdapterState: Equatable, Sendable {
    public let supportsHDR: Bool
    public let prefersHDR: Bool
    public let canSet: Bool
    public let identity: String

    public init(supportsHDR: Bool, prefersHDR: Bool, canSet: Bool, identity: String) {
        self.supportsHDR = supportsHDR
        self.prefersHDR = prefersHDR
        self.canSet = canSet
        self.identity = identity
    }
}

@MainActor
public protocol HDRPreferenceAdapting: AnyObject {
    func readState(displayID: UInt32) -> HDRAdapterState?
    func setPreference(_ enabled: Bool, displayID: UInt32, expectedIdentity: String) -> Bool
}

public enum HDRPreferenceAdapterDriver {
    /// Returns the stable adapter-object identity only after capability checks
    /// and one setter invocation. Nil is fail-closed and never invokes a
    /// setter when the manager/getters/setter are unavailable.
    @MainActor
    public static func beginSet(
        using adapter: any HDRPreferenceAdapting,
        displayID: UInt32,
        requested: Bool
    ) -> String? {
        guard let state = adapter.readState(displayID: displayID),
              state.supportsHDR, state.canSet,
              adapter.setPreference(
                  requested, displayID: displayID, expectedIdentity: state.identity
              ) else { return nil }
        return state.identity
    }
}
