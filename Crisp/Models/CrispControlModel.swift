import Foundation

struct CrispControlDisplay: Codable, Equatable {
    let id: UInt32
    let name: String
    let brightness: Double
    let isBuiltin: Bool
}

/// Unversioned request shape:
/// `{"command":"list"}`
/// `{"command":"getBrightness","display":1}`
/// `{"command":"setBrightness","display":1,"brightness":50}`
struct CrispControlRequest: Decodable, Equatable {
    enum Command: String, Decodable {
        case list
        case getBrightness
        case setBrightness
    }

    let command: Command
    let display: UInt32?
    let brightness: Double?

    init(command: Command, display: UInt32? = nil, brightness: Double? = nil) {
        self.command = command
        self.display = display
        self.brightness = brightness
    }
}

enum CrispControlRequestFrame {
    enum Result: Equatable {
        case incomplete
        case request(Data)
        case failure(String)
    }

    static func parse(_ data: Data, maximumBytes: Int, endOfStream: Bool) -> Result {
        if let newline = data.firstIndex(of: 0x0A) {
            guard newline <= maximumBytes else {
                return .failure("request too large")
            }
            return .request(Data(data[..<newline]))
        }
        guard data.count <= maximumBytes else {
            return .failure("request too large")
        }
        return endOfStream ? .failure("request must end with newline") : .incomplete
    }
}

/// A set response reports only request acceptance and queued, unverified execution.
/// It does not claim application, read-back, verification, or automatic retry.
struct CrispControlResponse: Encodable, Equatable {
    enum Status: String, Encodable {
        case accepted
    }

    enum Execution: String, Encodable {
        case queued
    }

    enum Verification: String, Encodable {
        case unverified
    }

    let ok: Bool
    let status: Status?
    let execution: Execution?
    let verification: Verification?
    let displays: [CrispControlDisplay]?
    let display: CrispControlDisplay?
    let error: String?

    static func success(displays: [CrispControlDisplay]) -> Self {
        Self(
            ok: true,
            status: nil,
            execution: nil,
            verification: nil,
            displays: displays,
            display: nil,
            error: nil
        )
    }

    static func success(display: CrispControlDisplay) -> Self {
        Self(
            ok: true,
            status: nil,
            execution: nil,
            verification: nil,
            displays: nil,
            display: display,
            error: nil
        )
    }

    static func acceptedUnverified() -> Self {
        Self(
            ok: true,
            status: .accepted,
            execution: .queued,
            verification: .unverified,
            displays: nil,
            display: nil,
            error: nil
        )
    }

    static func failure(_ error: String) -> Self {
        Self(
            ok: false,
            status: nil,
            execution: nil,
            verification: nil,
            displays: nil,
            display: nil,
            error: error
        )
    }
}

struct CrispControlBrightnessChange: Equatable {
    let displayID: UInt32
    let brightness: Double
}

enum CrispControlModel {
    static func encode(_ response: CrispControlResponse) -> Data {
        var data = (try? JSONEncoder().encode(response))
            ?? Data(#"{"ok":false,"error":"response encoding failed"}"#.utf8)
        data.append(0x0A)
        return data
    }

    static func handle(
        _ data: Data,
        displays: [CrispControlDisplay]
    ) -> (response: CrispControlResponse, brightnessChange: CrispControlBrightnessChange?) {
        guard let request = try? JSONDecoder().decode(CrispControlRequest.self, from: data) else {
            return (.failure("invalid request"), nil)
        }
        return handle(request, displays: displays)
    }

    static func handle(
        _ request: CrispControlRequest,
        displays: [CrispControlDisplay]
    ) -> (response: CrispControlResponse, brightnessChange: CrispControlBrightnessChange?) {
        switch request.command {
        case .list:
            return (.success(displays: displays), nil)
        case .getBrightness:
            guard let displayID = request.display else {
                return (.failure("display is required"), nil)
            }
            guard let display = displays.first(where: { $0.id == displayID }) else {
                return (.failure("display not found"), nil)
            }
            return (.success(display: display), nil)
        case .setBrightness:
            guard let displayID = request.display, let brightness = request.brightness else {
                return (.failure("display and brightness are required"), nil)
            }
            guard (0...100).contains(brightness) else {
                return (.failure("brightness must be between 0 and 100"), nil)
            }
            guard displays.contains(where: { $0.id == displayID }) else {
                return (.failure("display not found"), nil)
            }
            return (
                .acceptedUnverified(),
                CrispControlBrightnessChange(displayID: displayID, brightness: brightness)
            )
        }
    }
}
