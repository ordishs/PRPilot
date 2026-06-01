import Foundation

public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol CommandRunner: Sendable {
    func run(executable: String, arguments: [String]) async throws -> CommandResult
}

public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(executable: String, arguments: [String]) async throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        // A GUI-launched app has no controlling terminal, so any git/ssh credential,
        // passphrase, or host-key prompt would block forever. Force non-interactive so
        // such commands fail fast instead of hanging (auth still works via ssh-agent or
        // the macOS keychain, which are non-interactive).
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if environment["GIT_SSH_COMMAND"] == nil {
            environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        }
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        let outputData = try outputPipe.fileHandleForReading.readToEnd() ?? Data()
        let errorData = try errorPipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()

        return CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}
