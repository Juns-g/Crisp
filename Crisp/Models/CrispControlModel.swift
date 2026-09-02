import Foundation

enum CrispControlSocket {
    static let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("crispctl.sock").path
}
struct CrispControlResolution: Codable, Equatable {
    let logicalWidth: Int
    let logicalHeight: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    let isHiDPI: Bool
}
enum CrispControlBrightnessBackend: String, Codable, Equatable {
    case builtin
    case ddc
    case software
    case unknown
}
struct CrispControlDisplay: Codable, Equatable {
    let id: UInt32
    let name: String
    let brightness: Double
    let isBuiltin: Bool
    let uuid: String?
    let resolution: CrispControlResolution?
    let brightnessBackend: CrispControlBrightnessBackend?

    init(
        id: UInt32,
        name: String,
        brightness: Double,
        isBuiltin: Bool,
        uuid: String? = nil,
        resolution: CrispControlResolution? = nil,
        brightnessBackend: CrispControlBrightnessBackend? = nil
    ) {
        self.id = id
        self.name = name
        self.brightness = brightness
        self.isBuiltin = isBuiltin
        self.uuid = uuid
        self.resolution = resolution
        self.brightnessBackend = brightnessBackend
    }
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
    /// A display as a person typed it: a runtime id or a uuid. Takes precedence over
    /// `display`, which stays for clients that already send the numeric id.
    let selector: String?
    init(command: Command, display: UInt32? = nil, brightness: Double? = nil, selector: String? = nil) {
        self.command = command
        self.display = display
        self.brightness = brightness
        self.selector = selector
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
    let ok: Bool
    let displays: [CrispControlDisplay]?
    let display: CrispControlDisplay?
    let error: String?

    init(
        ok: Bool,
        displays: [CrispControlDisplay]? = nil,
        display: CrispControlDisplay? = nil,
        error: String? = nil
    ) {
        self.ok = ok
        self.displays = displays
        self.display = display
        self.error = error
    }
    static func success() -> Self { Self(ok: true) }
    static func success(displays: [CrispControlDisplay]) -> Self { Self(ok: true, displays: displays) }
    static func success(display: CrispControlDisplay) -> Self { Self(ok: true, display: display) }
    static func failure(_ error: String) -> Self { Self(ok: false, error: error) }
}
struct CrispControlBrightnessChange: Equatable {
    let displayID: UInt32
    let brightness: Double
}
enum CrispControlModel {
    static func brightnessBackend(
        isBuiltin: Bool,
        hdrSoftwareDimming: Bool,
        ddcAvailable: Bool?
    ) -> CrispControlBrightnessBackend {
        if isBuiltin { return .builtin }
        if hdrSoftwareDimming { return .software }
        switch ddcAvailable {
        case true: return .ddc
        case false: return .software
        case nil: return .unknown
        }
    }

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
            guard request.selector != nil || request.display != nil else {
                return (.failure("display is required"), nil)
            }
            guard let display = target(of: request, in: displays) else {
                return (.failure("display not found"), nil)
            }
            return (.success(display: display), nil)
        case .setBrightness:
            guard request.selector != nil || request.display != nil, let value = request.brightness else {
                return (.failure("display and brightness are required"), nil)
            }
            guard (0...100).contains(value) else {
                return (.failure("brightness must be between 0 and 100"), nil)
            }
            guard let display = target(of: request, in: displays) else {
                return (.failure("display not found"), nil)
            }
            return (.success(), .init(displayID: display.id, brightness: value))
        }
    }

    /// Finds a display by the selector a person typed: a runtime id, or a uuid in any
    /// case. Ids win, so a uuid that happens to be all digits still needs the uuid form.
    static func resolve(selector: String, in displays: [CrispControlDisplay]) -> CrispControlDisplay? {
        if let id = UInt32(selector), let match = displays.first(where: { $0.id == id }) {
            return match
        }
        return displays.first { $0.uuid?.caseInsensitiveCompare(selector) == .orderedSame }
    }
    private static func target(
        of request: CrispControlRequest, in displays: [CrispControlDisplay]
    ) -> CrispControlDisplay? {
        if let selector = request.selector { return resolve(selector: selector, in: displays) }
        return request.display.flatMap { id in displays.first { $0.id == id } }
    }
}
enum CrispControlCLIModel {
    static let usage = "usage: crispctl <command> [<args>]; run 'crispctl help' for the commands"

    /// The full reference, for a person at a terminal and for an agent that reads it
    /// before acting. Kept in the shared model so the app and the CLI cannot drift.
    static let help = """
        Usage: crispctl <command> [<args>]

        Control a running Crisp from the command line. Crisp must be running for the
        same user; crispctl talks to it over a local socket and never launches it.

        Commands:
          display list                    Online displays as JSON: id, uuid, name,
                                          resolution, brightness, brightnessBackend
          brightness get <display>        Read brightness, 0-100
          brightness set <display> <pct>  Set brightness, 0-100; clears the active preset
          help                            Show this help (also -h, --help)

        <display> is a runtime id or a uuid from 'display list'. Ids can change after
        an unplug or a wake; uuids do not.

        Output is one JSON object per call: {"ok":true,...} or {"ok":false,"error":"..."}.
        Exit codes: 0 ok, 1 Crisp unreachable, 2 bad arguments, 3 Crisp refused.
        """

    enum ParseResult: Equatable {
        case request(CrispControlRequest)
        case help
        case failure
    }
    enum ResponseResult: Equatable { case success, serverFailure, invalid }
    static func parse(arguments: [String]) -> ParseResult {
        if arguments.isEmpty || arguments == ["help"] || arguments == ["--help"] || arguments == ["-h"] {
            return .help
        }
        if arguments == ["display", "list"] {
            return .request(.init(command: .list))
        }
        if arguments.count == 3, arguments[0...1] == ["brightness", "get"], !arguments[2].isEmpty {
            return .request(.init(command: .getBrightness, selector: arguments[2]))
        }
        if arguments.count == 4, arguments[0...1] == ["brightness", "set"], !arguments[2].isEmpty,
           let value = Double(arguments[3]), value.isFinite, (0...100).contains(value) {
            return .request(.init(command: .setBrightness, brightness: value, selector: arguments[2]))
        }
        return .failure
    }
    static func classify(_ data: Data, for _: CrispControlRequest.Command) -> ResponseResult {
        guard let response = try? JSONDecoder().decode(CrispControlResponse.self, from: data) else {
            return .invalid
        }
        if response.ok { return .success }
        return response.error != nil ? .serverFailure : .invalid
    }
}
