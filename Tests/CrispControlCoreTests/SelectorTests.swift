import XCTest
@testable import CrispControlCore

final class SelectorTests: XCTestCase {
    private let displays = [
        ControlDisplay(uuid: "uuid-a", name: "Studio", isMain: true, isBuiltin: true,
                       brightness: .writableDisplayServices),
        ControlDisplay(uuid: "uuid-b", name: "Desk", isMain: false, isBuiltin: false,
                       brightness: .writableDDC),
        ControlDisplay(uuid: "uuid-c", name: "Desk", isMain: false, isBuiltin: false,
                       brightness: .unsupported(reason: "No DDC channel"))
    ]

    func testStableUUIDAndAliasesResolveExactly() throws {
        XCTAssertEqual(try DisplaySelector.resolve("uuid-b", in: displays).uuid, "uuid-b")
        XCTAssertEqual(try DisplaySelector.resolve("main", in: displays).uuid, "uuid-a")
        XCTAssertEqual(try DisplaySelector.resolve("builtin", in: displays).uuid, "uuid-a")
    }

    func testNamesAreCaseInsensitive() throws {
        XCTAssertEqual(try DisplaySelector.resolve("studio", in: displays).uuid, "uuid-a")
    }

    func testAmbiguousNameReturnsCandidatesWithoutPicking() {
        XCTAssertThrowsError(try DisplaySelector.resolve("Desk", in: displays)) { error in
            guard case let SelectorError.ambiguous(candidates) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(candidates.map(\.uuid), ["uuid-b", "uuid-c"])
        }
    }

    func testMissingAliasDoesNotFallbackToArbitraryDisplay() {
        let externalOnly = displays.filter { !$0.isBuiltin }
        XCTAssertThrowsError(try DisplaySelector.resolve("builtin", in: externalOnly)) { error in
            guard case SelectorError.notFound = error else { return XCTFail("unexpected error: \(error)") }
        }
    }
}

private extension BrightnessCapability {
    static let writableDisplayServices = BrightnessCapability(
        state: .writable, backend: .displayServices,
        range: ControlRange(min: 0, max: 100, precision: 0.1), readback: .authoritative
    )
    static let writableDDC = BrightnessCapability(
        state: .writable, backend: .ddc,
        range: ControlRange(min: 0, max: 100, precision: 1), readback: .approximate
    )
}
