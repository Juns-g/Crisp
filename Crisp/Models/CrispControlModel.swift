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
            return (.success(), .init(displayID: id, brightness: value))
        }
    }
}
enum CrispControlCLIModel {
    static let usage = "usage: crispctl displays list | crispctl brightness get <display-id> | "
        + "crispctl brightness set <display-id> <percent> | crispctl help"

    /// The full reference, for a person at a terminal and for an agent that reads it
    /// before acting. Kept in the shared model so the app and the CLI cannot drift.
    static let help = """
        crispctl: control a running Crisp from the command line.

        Crisp must be running on this Mac under the same user. crispctl talks to it
        over a local Unix socket (mode 0600 in the per-user temp dir) and never
        launches the app. Source builds only for now; the DMG and the Homebrew cask
        do not ship crispctl.

        Commands
          crispctl displays list
              Every online display: id, name, brightness (0-100), isBuiltin,
              plus uuid, current resolution, and brightnessBackend metadata.
          crispctl brightness get <display-id>
              Current brightness of one display.
          crispctl brightness set <display-id> <percent>
              Set brightness, 0-100. Same path as the panel slider: hardware (DDC)
              or software dimming as Crisp decided for that display, and it clears
              the active preset. The reply means Crisp accepted the request, not
              that the panel was read back; run brightness get to confirm.
          crispctl help
              This text. Also --help and -h.

        Display ids
          UUID is stable across reconnects and identifies the display. Commands
          still require the numeric runtime id, which can change after an unplug
          or a wake, so run a fresh displays list before acting.

        Output
          One JSON object per call. Success: {"ok":true,...}. Failure:
          {"ok":false,"error":"..."}. Later versions may add fields; ignore
          what you do not know. Crisp's own refusals come back on stdout,
          crispctl's own errors (no socket, bad arguments) go to stderr.
          brightnessBackend is Crisp's current route: builtin, ddc, software,
          or unknown while external DDC availability is undetermined. An HDR
          software-dimming override reports software.

        Exit codes
          0  ok
          1  could not reach Crisp: not running, socket missing, another user,
             or an unreadable reply
          2  bad arguments
          3  Crisp refused the request: unknown display, value out of range
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
    static func classify(_ data: Data, for _: CrispControlRequest.Command) -> ResponseResult {
        guard let response = try? JSONDecoder().decode(CrispControlResponse.self, from: data) else {
            return .invalid
        }
        if response.ok { return .success }
        return response.error != nil ? .serverFailure : .invalid
    }
}
