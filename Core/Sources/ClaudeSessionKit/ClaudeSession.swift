import AppKit
import Foundation
import Observation
import SwiftTerm

@MainActor
@Observable
public final class ClaudeSession {
    public private(set) var state: ClaudeSessionState = .starting
    public let spec: ClaudeLaunchSpec
    public let terminalView: LocalProcessTerminalView

    private let delegateBridge: DelegateBridge

    public init(spec: ClaudeLaunchSpec) {
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

    /// Applies the light terminal theme. Dark appearance needs no call — the terminal
    /// uses SwiftTerm's defaults. Call before `start()` so Claude detects the background.
    public func applyLightAppearance() {
        ClaudeTerminalTheme.applyLight(to: terminalView)
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
