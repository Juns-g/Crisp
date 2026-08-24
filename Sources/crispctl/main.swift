import Foundation
import CrispControlCLI
import CrispControlCore

if CommandLine.arguments.dropFirst().contains("--help") || CommandLine.arguments.dropFirst().contains("-h") {
    print(crispctlHelp)
    exit(0)
}

let requestID = UUID().uuidString
let response: CLIRunResult
do {
    let invocation = try CLIParser(requestID: { requestID }).parse(Array(CommandLine.arguments.dropFirst()))
    response = CLIRunner(
        transport: UnixSocketClient(path: invocation.socketPath),
        launcher: DefaultCrispAppLauncher()
    ).run(invocation)
} catch {
    response = CLIRunResult(response: .failure(
        requestID: requestID,
        code: .invalidArguments,
        message: (error as? LocalizedError)?.errorDescription ?? "invalid command"
    ))
}

do {
    FileHandle.standardOutput.write(Data(try CLIOutput.jsonLine(response.response).utf8))
} catch {
    FileHandle.standardError.write(Data("crispctl: failed to encode JSON response\n".utf8))
    exit(1)
}
exit(response.exitCode)
