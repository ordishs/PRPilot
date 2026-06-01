import Testing
import Foundation
import CommandSupport

@Test func processRunnerCapturesStdoutAndZeroExit() async throws {
    let runner = ProcessCommandRunner()
    let result = try await runner.run(executable: "/bin/echo", arguments: ["hello"])
    #expect(result.exitCode == 0)
    #expect(result.standardOutput == "hello\n")
}

@Test func processRunnerReportsNonZeroExit() async throws {
    let runner = ProcessCommandRunner()
    let result = try await runner.run(executable: "/usr/bin/false", arguments: [])
    #expect(result.exitCode == 1)
}

@Test func processRunnerForcesNonInteractiveGit() async throws {
    let runner = ProcessCommandRunner()
    let prompt = try await runner.run(executable: "/bin/sh", arguments: ["-c", "printf %s \"$GIT_TERMINAL_PROMPT\""])
    #expect(prompt.standardOutput == "0")
    let ssh = try await runner.run(executable: "/bin/sh", arguments: ["-c", "printf %s \"$GIT_SSH_COMMAND\""])
    #expect(ssh.standardOutput.contains("BatchMode=yes"))
}
