import Testing
import Foundation
import PRPilotModels
@testable import AgentKit

/// The exact shell command PR Pilot hands to `/bin/zsh -l -c`. These assertions exist because
/// the whole launch hinges on this one string: pi exited 127 without drawing anything until the
/// PATH prefix was added, and the space in a PR Pilot worktree path must stay quoted.
@MainActor
private func command(
    kind: AgentKind,
    executable: String,
    cwd: String = "/tmp/wt",
    arguments: [String] = [],
    environment: String = "",
    extraArgs: String = ""
) -> String {
    let spec = AgentLaunchSpec(
        executable: executable,
        cwd: cwd,
        arguments: arguments,
        environment: environment,
        extraArgs: extraArgs,
        prependExecutableDirectoryToPath: AgentBackends.backend(for: kind).prependsExecutableDirectoryToPath,
        kind: kind
    )
    return AgentSession(spec: spec).makeShellCommand()
}

@Test @MainActor func piLaunchPrependsItsBinDirectoryToPath() {
    let cmd = command(kind: .pi, executable: "/Users/me/.nvm/versions/node/v24.14.1/bin/pi")
    #expect(cmd == "cd '/tmp/wt' && export PATH='/Users/me/.nvm/versions/node/v24.14.1/bin':$PATH && exec '/Users/me/.nvm/versions/node/v24.14.1/bin/pi'")
}

/// Claude Code is a native binary. Prepending would change the PATH its child processes see,
/// so its command must stay byte-for-byte what it always was.
@Test @MainActor func claudeCodeLaunchDoesNotTouchPath() {
    let cmd = command(kind: .claudeCode, executable: "/Users/me/.local/bin/claude")
    #expect(cmd == "cd '/tmp/wt' && exec '/Users/me/.local/bin/claude'")
    #expect(!cmd.contains("PATH"))
}

/// PR Pilot's managed worktrees live under "Application Support", so an unquoted path would
/// split into two words and the launch would fail.
@Test @MainActor func worktreePathWithASpaceStaysQuoted() {
    let worktree = "/Users/me/Library/Application Support/PRPilot/worktrees.noindex/wt"
    let cmd = command(kind: .pi, executable: "/opt/node/bin/pi", cwd: worktree)
    #expect(cmd.hasPrefix("cd '\(worktree)' &&"))
}

@Test @MainActor func piLaunchKeepsArgumentsEnvironmentAndExtraArgsInOrder() {
    let cmd = command(
        kind: .pi,
        executable: "/opt/node/bin/pi",
        arguments: ["--session-id", "sid", "Review the pull request."],
        environment: "PI_ONLY=1",
        extraArgs: "--provider anthropic"
    )
    #expect(cmd == "cd '/tmp/wt' && export PATH='/opt/node/bin':$PATH && exec env PI_ONLY=1 '/opt/node/bin/pi' --provider anthropic '--session-id' 'sid' 'Review the pull request.'")
}

/// An executable with no directory component leaves PATH alone rather than prepending an
/// empty entry, which would put the working directory on PATH.
@Test @MainActor func aBareExecutableNameDoesNotPrependAnEmptyPathEntry() {
    let spec = AgentLaunchSpec(
        executable: "pi",
        cwd: "/tmp/wt",
        arguments: [],
        prependExecutableDirectoryToPath: true,
        kind: .pi
    )
    let cmd = AgentSession(spec: spec).makeShellCommand()
    #expect(cmd == "cd '/tmp/wt' && exec 'pi'")
}

@Test @MainActor func aRootLevelExecutableDoesNotPrependRootToPath() {
    let spec = AgentLaunchSpec(
        executable: "/pi",
        cwd: "/tmp/wt",
        arguments: [],
        prependExecutableDirectoryToPath: true,
        kind: .pi
    )
    let cmd = AgentSession(spec: spec).makeShellCommand()
    #expect(cmd == "cd '/tmp/wt' && exec '/pi'")
}

@Test @MainActor func aFailedLaunchNamesTheAgentThatWasNotFound() {
    let pi = AgentLaunchSpec(executable: "/nope/pi", cwd: "/tmp", arguments: [], kind: .pi)
    #expect(pi.executableName == "pi")
    let claude = AgentLaunchSpec(executable: "/nope/claude", cwd: "/tmp", arguments: [], kind: .claudeCode)
    #expect(claude.executableName == "claude")
}
