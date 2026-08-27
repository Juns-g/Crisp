import Foundation

enum CrispControlSocket {
    static let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("crispctl.sock").path
}
struct CrispControlDisplay: Codable, Equatable {
    let id: UInt32
    let name: String
    let brightness: Double
    let isBuiltin: Bool
}
struct CrispControlRequest: Codable, Equatable {
    enum Command: String, Codable {
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
enum CrispControlFrame {
    enum Result: Equatable {
        case incomplete
        case frame(Data)
        case failure(String)
    }

    static func parse(_ data: Data, maximumBytes: Int, endOfStream: Bool) -> Result {
        if let newline = data.firstIndex(of: 0x0A) {
            guard newline < maximumBytes else { return .failure("frame too large") }
            return .frame(Data(data[...newline]))
        }
        guard data.count < maximumBytes else { return .failure("frame too large") }
        return endOfStream ? .failure("frame must end with newline") : .incomplete
    }
}
struct CrispControlResponse: Codable, Equatable {
    enum Status: String, Codable { case accepted }
    enum Execution: String, Codable { case queued }
    enum Verification: String, Codable { case unverified }

    let ok: Bool
    let status: Status?
    let execution: Execution?
    let verification: Verification?
    let displays: [CrispControlDisplay]?
    let display: CrispControlDisplay?
    let error: String?

    init(
        ok: Bool,
        status: Status? = nil,
        execution: Execution? = nil,
        verification: Verification? = nil,
        displays: [CrispControlDisplay]? = nil,
        display: CrispControlDisplay? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.status = status
        self.execution = execution
        self.verification = verification
        self.displays = displays
        self.display = display
        self.error = error
    }
    static func success(displays: [CrispControlDisplay]) -> Self { Self(ok: true, displays: displays) }
    static func success(display: CrispControlDisplay) -> Self { Self(ok: true, display: display) }
    static func acceptedUnverified() -> Self {
        Self(ok: true, status: .accepted, execution: .queued, verification: .unverified)
    }
    static func failure(_ error: String) -> Self { Self(ok: false, error: error) }
}
struct CrispControlBrightnessChange: Equatable {
    let displayID: UInt32
    let brightness: Double
}
enum CrispControlModel {
    static func encode<T: Encodable>(_ value: T, sorted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        if sorted { encoder.outputFormatting = .sortedKeys }
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }
    static func encode(_ response: CrispControlResponse) -> Data {
        (try? encode(response, sorted: false))
            ?? Data(#"{"ok":false,"error":"response encoding failed"}"#.utf8) + Data([0x0A])
    }
    static func handle(
        _ data: Data,
        displays: [CrispControlDisplay]
    ) -> (response: CrispControlResponse, brightnessChange: CrispControlBrightnessChange?) {
        guard let request = try? JSONDecoder().decode(CrispControlRequest.self, from: data) else {
            return (.failure("invalid request"), nil)
        }
        switch request.command {
        case .list:
            return (.success(displays: displays), nil)
        case .getBrightness:
            guard let id = request.display else { return (.failure("display is required"), nil) }
            guard let display = displays.first(where: { $0.id == id }) else {
                return (.failure("display not found"), nil)
            }
            return (.success(display: display), nil)
        case .setBrightness:
            guard let id = request.display, let value = request.brightness else {
                return (.failure("display and brightness are required"), nil)
            }
            guard (0...100).contains(value) else {
                return (.failure("brightness must be between 0 and 100"), nil)
            }
            guard displays.contains(where: { $0.id == id }) else {
                return (.failure("display not found"), nil)
            }
            return (.acceptedUnverified(), .init(displayID: id, brightness: value))
        }
    }
}
enum CrispControlCLIModel {
    static let usage = "usage: crispctl displays list | crispctl brightness get <display-id> | "
        + "crispctl brightness set <display-id> <percent>"

    enum ParseResult: Equatable {
        case request(CrispControlRequest)
        case failure
    }
    enum ResponseResult: Equatable { case success, serverFailure, invalid }
    static func parse(arguments: [String]) -> ParseResult {
        if arguments == ["displays", "list"] {
            return .request(.init(command: .list))
        }
        if arguments.count == 3, arguments[0...1] == ["brightness", "get"],
           let id = UInt32(arguments[2]) {
            return .request(.init(command: .getBrightness, display: id))
        }
        if arguments.count == 4, arguments[0...1] == ["brightness", "set"],
           let id = UInt32(arguments[2]), let value = Double(arguments[3]),
           value.isFinite, (0...100).contains(value) {
            return .request(.init(command: .setBrightness, display: id, brightness: value))
        }
        return .failure
    }
    static func classify(_ data: Data, for command: CrispControlRequest.Command) -> ResponseResult {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let response = try? JSONDecoder().decode(CrispControlResponse.self, from: data)
        else { return .invalid }
        let keys = Set(object.keys)
        if !response.ok {
            return keys == ["ok", "error"] && response.error != nil ? .serverFailure : .invalid
        }
        switch command {
        case .list:
            return keys == ["ok", "displays"] && response.displays != nil ? .success : .invalid
        case .getBrightness:
            return keys == ["ok", "display"] && response.display != nil ? .success : .invalid
        case .setBrightness:
            let honest = response.status == .accepted
                && response.execution == .queued
                && response.verification == .unverified
            return keys == ["ok", "status", "execution", "verification"] && honest ? .success : .invalid
        }
    }
}
