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
    public func terminate() {
        let pid = terminalView.process.shellPid
        guard pid > 0 else { return }
        killpg(pid, SIGTERM)
        terminalView.process.terminate()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if killpg(pid, 0) == 0 {
                killpg(pid, SIGKILL)
            }
            for _ in 0..<Self.reapAttempts {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) != 0 { return }
                try? await Task.sleep(nanoseconds: Self.reapPollNanoseconds)
            }
        }
    }

    /// Two seconds of polling after the SIGKILL. `waitpid` answers 0 only while the agent is
    /// still alive, so the loop ends as soon as it exits.
    private static let reapAttempts = 40
    private static let reapPollNanoseconds: UInt64 = 50_000_000

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
