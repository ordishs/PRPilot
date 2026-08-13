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
                state = .failedToLaunch("claude not found at \(spec.executable)")
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

    public func terminate() {
        let pid = terminalView.process.shellPid
        guard pid > 0 else { return }
        kill(pid, SIGTERM)
        let process = terminalView.process
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if process?.running == true {
                kill(pid, SIGKILL)
            }
        }
    }

    private func makeShellCommand() -> String {
        let escapedCwd = shellEscape(spec.cwd)
        let escapedExec = shellEscape(spec.executable)
        let escapedArgs = spec.arguments.map(shellEscape).joined(separator: " ")
        let argsSuffix = escapedArgs.isEmpty ? "" : " " + escapedArgs
        let env = spec.environment.trimmingCharacters(in: .whitespacesAndNewlines)
        let envPrefix = env.isEmpty ? "" : "env " + env + " "
        let extra = spec.extraArgs.trimmingCharacters(in: .whitespacesAndNewlines)
        let extraPrefix = extra.isEmpty ? "" : " " + extra
        return "cd \(escapedCwd) && exec \(envPrefix)\(escapedExec)\(extraPrefix)\(argsSuffix)"
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
