import XCTest

final class BrightnessHeartbeatWiringTests: XCTestCase {
    func testAppDelegateWiresBothRefreshPathsAndCloseCancellation() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent("Crisp/App/AppDelegate.swift"),
            encoding: .utf8
        )

        let clickRefresh = try SwiftSource.functionBody(named: "refreshExternalState", in: source)
        let timerHeartbeat = try SwiftSource.functionBody(named: "pollExternalState", in: source)
        let closePanel = try SwiftSource.functionBody(named: "closePanel", in: source)

        XCTAssertTrue(clickRefresh.contains("brightnessHeartbeatController.schedule("))
        XCTAssertTrue(timerHeartbeat.contains("brightnessHeartbeatController.schedule("))
        XCTAssertTrue(closePanel.contains("brightnessHeartbeatController.cancel()"))
    }

    func testFunctionBodyExtractionDoesNotAcceptWiringFromSiblingOrComment() throws {
        let fixture = """
        private func clickRefresh() {
            controller.schedule()
        }
        private func timerHeartbeat() {
            // controller.schedule()
            noop()
        }
        private func stringOnlyHeartbeat() {
            let marker = "controller.schedule()"
            consume(marker)
        }
        """

        let clickRefresh = try SwiftSource.functionBody(named: "clickRefresh", in: fixture)
        let timerHeartbeat = try SwiftSource.functionBody(named: "timerHeartbeat", in: fixture)
        let stringOnlyHeartbeat = try SwiftSource.functionBody(named: "stringOnlyHeartbeat", in: fixture)
        XCTAssertTrue(clickRefresh.contains("controller.schedule()"))
        XCTAssertFalse(timerHeartbeat.contains("controller.schedule()"))
        XCTAssertFalse(stringOnlyHeartbeat.contains("controller.schedule()"))
    }
}

private enum SwiftSource {
    enum ParseError: Error {
        case functionNotFound(String)
        case malformedBody(String)
    }

    static func functionBody(named name: String, in source: String) throws -> String {
        let uncommented = removingComments(from: source)
        let signature = "func \(name)("
        guard let signatureRange = uncommented.range(of: signature) else {
            throw ParseError.functionNotFound(name)
        }
        let chars = Array(uncommented)
        let signatureOffset = uncommented.distance(
            from: uncommented.startIndex,
            to: signatureRange.lowerBound
        )
        guard let openBrace = chars[signatureOffset...].firstIndex(of: "{") else {
            throw ParseError.malformedBody(name)
        }

        var depth = 0
        var inString = false
        var escaped = false
        var bodyStart = openBrace + 1
        for index in openBrace..<chars.count {
            let character = chars[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
                if depth == 1 { bodyStart = index + 1 }
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(chars[bodyStart..<index]) }
            }
        }
        throw ParseError.malformedBody(name)
    }

    private static func removingComments(from source: String) -> String {
        let chars = Array(source)
        var result: [Character] = []
        var index = 0
        // 0 code, 1 string, 2 line comment, 3 block comment, 4 multiline string
        var mode = 0
        var blockDepth = 0
        while index < chars.count {
            let character = chars[index]
            let next = index + 1 < chars.count ? chars[index + 1] : "\0"
            let third = index + 2 < chars.count ? chars[index + 2] : "\0"
            switch mode {
            case 0:
                if character == "\"", next == "\"", third == "\"" {
                    mode = 4
                    result.append(contentsOf: [" ", " ", " "])
                    index += 3
                } else if character == "\"" {
                    mode = 1
                    result.append(" ")
                    index += 1
                } else if character == "/", next == "/" {
                    mode = 2
                    result.append(contentsOf: [" ", " "])
                    index += 2
                } else if character == "/", next == "*" {
                    mode = 3
                    blockDepth = 1
                    result.append(contentsOf: [" ", " "])
                    index += 2
                } else {
                    result.append(character)
                    index += 1
                }
            case 1:
                if character == "\\", index + 1 < chars.count {
                    result.append(contentsOf: [" ", " "])
                    index += 2
                } else {
                    result.append(character == "\n" ? "\n" : " ")
                    if character == "\"" { mode = 0 }
                    index += 1
                }
            case 2:
                result.append(character == "\n" ? "\n" : " ")
                if character == "\n" { mode = 0 }
                index += 1
            case 3:
                if character == "/", next == "*" {
                    blockDepth += 1
                    result.append(contentsOf: [" ", " "])
                    index += 2
                } else if character == "*", next == "/" {
                    blockDepth -= 1
                    result.append(contentsOf: [" ", " "])
                    index += 2
                    if blockDepth == 0 { mode = 0 }
                } else {
                    result.append(character == "\n" ? "\n" : " ")
                    index += 1
                }
            default:
                if character == "\"", next == "\"", third == "\"" {
                    result.append(contentsOf: [" ", " ", " "])
                    index += 3
                    mode = 0
                } else {
                    result.append(character == "\n" ? "\n" : " ")
                    index += 1
                }
            }
        }
        return String(result)
    }
}
