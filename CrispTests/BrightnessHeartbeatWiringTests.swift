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

    private enum CommentRemovalMode {
        case code
        case string
        case lineComment
        case blockComment
        case multilineString
    }

    private struct CommentRemovalState {
        var result: [Character] = []
        var index = 0
        var mode: CommentRemovalMode = .code
        var blockDepth = 0
    }

    private static func removingComments(from source: String) -> String {
        let chars = Array(source)
        var state = CommentRemovalState()
        while state.index < chars.count {
            let character = chars[state.index]
            let hasNext = state.index + 1 < chars.count
            let next = hasNext ? chars[state.index + 1] : "\0"
            let third = state.index + 2 < chars.count ? chars[state.index + 2] : "\0"
            switch state.mode {
            case .code:
                consumeCode(character, next: next, third: third, state: &state)
            case .string:
                consumeString(character, hasNext: hasNext, state: &state)
            case .lineComment:
                consumeLineComment(character, state: &state)
            case .blockComment:
                consumeBlockComment(character, next: next, state: &state)
            case .multilineString:
                consumeMultilineString(character, next: next, third: third, state: &state)
            }
        }
        return String(state.result)
    }

    private static func consumeCode(
        _ character: Character,
        next: Character,
        third: Character,
        state: inout CommentRemovalState
    ) {
        if character == "\"", next == "\"", third == "\"" {
            state.mode = .multilineString
            state.result.append(contentsOf: [" ", " ", " "])
            state.index += 3
        } else if character == "\"" {
            state.mode = .string
            state.result.append(" ")
            state.index += 1
        } else if character == "/", next == "/" {
            state.mode = .lineComment
            state.result.append(contentsOf: [" ", " "])
            state.index += 2
        } else if character == "/", next == "*" {
            state.mode = .blockComment
            state.blockDepth = 1
            state.result.append(contentsOf: [" ", " "])
            state.index += 2
        } else {
            state.result.append(character)
            state.index += 1
        }
    }

    private static func consumeString(
        _ character: Character,
        hasNext: Bool,
        state: inout CommentRemovalState
    ) {
        if character == "\\", hasNext {
            state.result.append(contentsOf: [" ", " "])
            state.index += 2
        } else {
            state.result.append(character == "\n" ? "\n" : " ")
            if character == "\"" { state.mode = .code }
            state.index += 1
        }
    }

    private static func consumeLineComment(
        _ character: Character,
        state: inout CommentRemovalState
    ) {
        state.result.append(character == "\n" ? "\n" : " ")
        if character == "\n" { state.mode = .code }
        state.index += 1
    }

    private static func consumeBlockComment(
        _ character: Character,
        next: Character,
        state: inout CommentRemovalState
    ) {
        if character == "/", next == "*" {
            state.blockDepth += 1
            state.result.append(contentsOf: [" ", " "])
            state.index += 2
        } else if character == "*", next == "/" {
            state.blockDepth -= 1
            state.result.append(contentsOf: [" ", " "])
            state.index += 2
            if state.blockDepth == 0 { state.mode = .code }
        } else {
            state.result.append(character == "\n" ? "\n" : " ")
            state.index += 1
        }
    }

    private static func consumeMultilineString(
        _ character: Character,
        next: Character,
        third: Character,
        state: inout CommentRemovalState
    ) {
        if character == "\"", next == "\"", third == "\"" {
            state.result.append(contentsOf: [" ", " ", " "])
            state.index += 3
            state.mode = .code
        } else {
            state.result.append(character == "\n" ? "\n" : " ")
            state.index += 1
        }
    }
}
