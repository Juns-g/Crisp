import XCTest
@testable import CrispControlCore

@MainActor
final class HDRPreferenceAdapterTests: XCTestCase {
    func testMissingManagerOrGetterOrSetterFailsUnsupportedWithoutInvokingSetter() {
        let cases: [HDRAdapterState?] = [
            nil,
            HDRAdapterState(supportsHDR: false, prefersHDR: false, canSet: true, identity: "display"),
            HDRAdapterState(supportsHDR: true, prefersHDR: false, canSet: false, identity: "display")
        ]

        for state in cases {
            let adapter = FakeHDRPreferenceAdapter(state: state)
            XCTAssertNil(HDRPreferenceAdapterDriver.beginSet(
                using: adapter, displayID: 7, requested: true
            ))
            XCTAssertEqual(adapter.setterCalls, 0)
        }
    }

    func testWritableAdapterInvocationCarriesStableIdentity() {
        let adapter = FakeHDRPreferenceAdapter(state: HDRAdapterState(
            supportsHDR: true, prefersHDR: false, canSet: true, identity: "mp-object-a"
        ))

        let identity = HDRPreferenceAdapterDriver.beginSet(
            using: adapter, displayID: 7, requested: true
        )

        XCTAssertEqual(identity, "mp-object-a")
        XCTAssertEqual(adapter.expectedIdentities, ["mp-object-a"])
        XCTAssertEqual(adapter.setterCalls, 1)
    }

    func testMonitorPanelMethodSignaturesAcceptOnlyExpectedABI() {
        XCTAssertTrue(MonitorPanelABISignatureValidator.isCompatible(
            .init(returnType: "@", argumentTypes: ["@", ":"]),
            with: .displaysGetter
        ))
        XCTAssertTrue(MonitorPanelABISignatureValidator.isCompatible(
            .init(returnType: "I", argumentTypes: ["@", ":"]),
            with: .displayIDGetter
        ))
        for boolEncoding in ["B", "c"] {
            XCTAssertTrue(MonitorPanelABISignatureValidator.isCompatible(
                .init(returnType: boolEncoding, argumentTypes: ["@", ":"]),
                with: .boolGetter
            ))
            XCTAssertTrue(MonitorPanelABISignatureValidator.isCompatible(
                .init(returnType: "v", argumentTypes: ["@", ":", boolEncoding]),
                with: .boolSetter
            ))
        }
    }

    func testMonitorPanelSignatureDriftFailsClosedBeforeInvocation() {
        let incompatible: [(ObjectiveCMethodEncoding, MonitorPanelABIMethod)] = [
            (.init(returnType: "v", argumentTypes: ["@", ":"]), .displaysGetter),
            (.init(returnType: "Q", argumentTypes: ["@", ":"]), .displayIDGetter),
            (.init(returnType: "i", argumentTypes: ["@", ":"]), .boolGetter),
            (.init(returnType: "B", argumentTypes: ["@", ":", "B"]), .boolSetter),
            (.init(returnType: "v", argumentTypes: ["@", ":"]), .boolSetter),
            (.init(returnType: "v", argumentTypes: ["@", ":", "i"]), .boolSetter)
        ]

        for (encoding, method) in incompatible {
            XCTAssertFalse(MonitorPanelABISignatureValidator.isCompatible(encoding, with: method))
        }
    }
}

@MainActor
private final class FakeHDRPreferenceAdapter: HDRPreferenceAdapting {
    var state: HDRAdapterState?
    var setterCalls = 0
    var expectedIdentities: [String] = []

    init(state: HDRAdapterState?) { self.state = state }
    func readState(displayID: UInt32) -> HDRAdapterState? { state }
    func setPreference(_ enabled: Bool, displayID: UInt32, expectedIdentity: String) -> Bool {
        setterCalls += 1
        expectedIdentities.append(expectedIdentity)
        return state?.identity == expectedIdentity
    }
}
