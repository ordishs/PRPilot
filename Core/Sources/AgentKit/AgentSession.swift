import AppKit
import Foundation
import Observation
import SwiftTerm

@MainActor
@Observable
public final class AgentSession {
    public private(set) var state: AgentSessionState = .starting
    public let spec: AgentLaunchSpec
    public let terminalView: LocalProcessTerminalView

    private let delegateBridge: DelegateBridge
    @ObservationIgnored nonisolated(unsafe) private var shiftReturnMonitor: Any?

    public init(spec: AgentLaunchSpec) {
        self.spec = spec
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        self.terminalView = view
        let bridge = DelegateBridge()
        self.delegateBridge = bridge
        view.processDelegate = bridge
        bridge.onExit = { [weak self] code in
            Task { @MainActor [weak self] in
                self?.state = .exited(code: code)
            }
        }
        installShiftReturnMonitor()
    }

    deinit {
        if let shiftReturnMonitor {
            NSEvent.removeMonitor(shiftReturnMonitor)
        }
    }

    /// SwiftTerm sends a bare CR for both Return and Shift+Return when the Kitty keyboard
    /// protocol is inactive, so Claude submits instead of inserting a newline. Intercept
    /// Shift+Return for this session's terminal and emit ESC+CR — the meta-return sequence
    /// Option+Return produces — which Claude treats as a newline. Left untouched when the
    /// Kitty protocol is negotiated, so SwiftTerm's own encoding wins.
    private func installShiftReturnMonitor() {
        shiftReturnMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isShiftReturn = event.modifierFlags.contains(.shift)
                && (event.keyCode == 36 || event.keyCode == 76)
            guard isShiftReturn else { return event }
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                let view = self.terminalView
                guard view.window?.firstResponder === view,
                      view.terminal.keyboardEnhancementFlags.isEmpty
                else { return false }
                view.send([0x1b, 0x0d])
                return true
            }
            return consumed ? nil : event
        }
    }

    public func start() {
        if spec.executable.hasPrefix("/") {
            guard FileManager.default.isExecutableFile(atPath: spec.executable) else {
                state = .failedToLaunch("\(spec.executableName) not found at \(spec.executable)")
                return
            }
        }
        state = .starting
        let shellCommand = makeShellCommand()
        terminalView.startProcess(
            executable: "/bin/zsh",
            args: ["-l", "-c", shellCommand],
            environment: nil,
            execName: nil
        )
        state = .running
    }

    /// Applies the light or dark terminal theme to this session's terminal view. Updates
    /// a running terminal's chrome immediately; call before `start()` so Claude detects
    /// the background on launch.
    public func applyAppearance(isDark: Bool) {
        AgentTerminalTheme.apply(isDark: isDark, to: terminalView)
    }

    public func restart() {
        terminate()
        start()
    }

    /// Signals the agent's whole process group, not just the agent, and closes the pty.
    ///
    /// `forkpty` makes the child a session leader, so the agent and the MCP servers it spawns
    /// share one process group. Signalling the agent alone leaves those servers alive, holding
    /// the slave side open, so the master never reaches EOF. `LocalProcess.terminate()` then
    /// closes the DispatchIO channel, which closes the master. Without both halves the pty
    /// stays allocated for the life of the app, and the machine runs out of ptys at
    /// `kern.tty.ptmx_max`.
    ///
    /// Closing the terminal also cancels the SwiftTerm process monitor whose handler calls
    /// `waitpid`, so this reaps the agent itself. Otherwise every terminated session leaves a
    /// zombie in the process table for as long as the app runs.
    /// Fire-and-forget termination, for callers that are not shutting the app down.
    ///
    /// Quitting must use `terminateAndWait` instead. The detached task here cannot finish once
    /// AppKit starts tearing the process down, so on quit the escalation never runs.
    public func terminate() {
        guard let termination = signalTree() else { return }
        Task { @MainActor in await waitForTree(termination) }
    }

    /// Terminates the agent and everything it started, and returns only once they are gone.
    ///
    /// `killpg` alone misses part of the tree. Claude Code puts each Bash tool command in a new
    /// process group, so a `go test` or a load generator the agent started does not receive the
    /// group signal. Those processes are still descendants, so the tree walk finds them. One
    /// escaped `while true` loop costs a core until the machine reboots.
    ///
    /// The tree is captured before anything is signalled. Killing the agent reparents its
    /// children to `launchd`, which erases the links a later walk would need.
    public func terminateAndWait() async {
        guard let termination = signalTree() else { return }
        await waitForTree(termination)
    }

    /// The pids one `terminate` is responsible for, captured while the links still exist.
    private struct Termination {
        let pid: pid_t
        var strays: [pid_t]
    }

    /// Signals the whole tree and closes the pty, all before returning.
    ///
    /// This half stays synchronous because `restart` terminates and starts again in the same turn.
    /// Deferring it would let the new agent take the terminal first, and the teardown would then
    /// read the replacement's pid out of the session and kill the agent it just started.
    private func signalTree() -> Termination? {
        let pid = terminalView.process.shellPid
        guard pid > 0 else { return nil }
        let strays = ProcessTree.descendants(of: pid)

        killpg(pid, SIGTERM)
        for stray in strays { kill(stray, SIGTERM) }
        terminalView.process.terminate()
        return Termination(pid: pid, strays: strays)
    }

    /// Waits out the grace period, escalates to `SIGKILL`, and reaps. Works only from the pids it
    /// was handed, so it stays correct after the session has moved on to another agent.
    private func waitForTree(_ termination: Termination) async {
        var strays = termination.strays
        let pid = termination.pid
        if await settled(pid: pid, strays: strays, within: Self.graceNanoseconds) { return }

        strays += ProcessTree.descendants(of: pid).filter { !strays.contains($0) }
        killpg(pid, SIGKILL)
        for stray in strays where kill(stray, 0) == 0 { kill(stray, SIGKILL) }

        _ = await settled(pid: pid, strays: strays, within: Self.escalationNanoseconds)
    }

    /// Polls until the agent is reaped and no descendant is left alive, or the budget runs out.
    ///
    /// The agent is this process's child, so `waitpid` both detects its exit and reaps it —
    /// closing the terminal cancels the SwiftTerm monitor that would otherwise do so, and an
    /// unreaped agent stays in the process table as a zombie for the life of the app. Descendants
    /// are not our children, so aliveness is all we can ask about them.
    private func settled(pid: pid_t, strays: [pid_t], within budget: UInt64) async -> Bool {
        var waited: UInt64 = 0
        while true {
            var status: Int32 = 0
            let agentGone = waitpid(pid, &status, WNOHANG) != 0
            if agentGone, !strays.contains(where: { kill($0, 0) == 0 }) { return true }
            if waited >= budget { return false }
            try? await Task.sleep(nanoseconds: Self.pollNanoseconds)
            waited += Self.pollNanoseconds
        }
    }

    /// Half a second to exit on `SIGTERM`, then two more to die on `SIGKILL`. The polls end each
    /// wait as soon as the tree is clear, so a well-behaved agent costs nothing near these bounds.
    private static let graceNanoseconds: UInt64 = 500_000_000
    private static let escalationNanoseconds: UInt64 = 2_000_000_000
    private static let pollNanoseconds: UInt64 = 25_000_000

    /// Internal rather than private so the launch command can be asserted directly. The
    /// PATH prefix it builds is what makes an interpreted agent launch at all.
    func makeShellCommand() -> String {
        let escapedCwd = shellEscape(spec.cwd)
        let escapedExec = shellEscape(spec.executable)
        let escapedArgs = spec.arguments.map(shellEscape).joined(separator: " ")
        let argsSuffix = escapedArgs.isEmpty ? "" : " " + escapedArgs
        let env = spec.environment.trimmingCharacters(in: .whitespacesAndNewlines)
        let envPrefix = env.isEmpty ? "" : "env " + env + " "
        let extra = spec.extraArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        let extraPrefix = extra.isEmpty ? "" : " " + extra
        return "cd \(escapedCwd) && \(pathPrefix())exec \(envPrefix)\(escapedExec)\(extraPrefix)\(argsSuffix)"
    }

    /// An agent that is an interpreted script cannot rely on the login shell to find its
    /// interpreter: `zsh -l` reads `.zprofile` but not `.zshrc`, and version managers such as
    /// nvm set their PATH in `.zshrc`. pi ships as a node script with an `env node` shebang, so
    /// without this it exits 127 before drawing anything. Its own bin directory holds the
    /// sibling `node`, which is why prepending that directory is enough.
    private func pathPrefix() -> String {
        guard spec.prependExecutableDirectoryToPath else { return "" }
        let binDir = (spec.executable as NSString).deletingLastPathComponent
        guard !binDir.isEmpty, binDir != "/" else { return "" }
        return "export PATH=\(shellEscape(binDir)):$PATH && "
    }

    private func shellEscape(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private final class DelegateBridge: NSObject, LocalProcessTerminalViewDelegate {
    nonisolated(unsafe) var onExit: (@Sendable (Int32) -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onExit?(exitCode ?? -1)
    }
}
