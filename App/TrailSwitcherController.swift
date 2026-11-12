import AppKit
import Observation
import SwiftUI
import PRPilotModels
import AppCore

@MainActor
@Observable
final class TrailSwitcherController {
    private(set) var switcher = TrailSwitcher()

    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private let onCommit: (String) -> Void
    @ObservationIgnored nonisolated(unsafe) private var monitor: Any?

    private static let tabKeyCode: UInt16 = 48
    private static let escapeKeyCode: UInt16 = 53

    init(model: AppModel, onCommit: @escaping (String) -> Void) {
        self.model = model
        self.onCommit = onCommit
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func start() {
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }

            return consumed ? nil : event
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }

        monitor = nil
        cancel()
    }

    func cancel() {
        feed(.escape)
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.type {
        case .keyDown:
            let isSwitchChord = event.keyCode == Self.tabKeyCode
                && flags.contains(.control)
                && !flags.contains(.command)
                && !flags.contains(.option)

            if isSwitchChord {
                feed(flags.contains(.shift) ? .shiftTab : .tab)
                return true
            }

            if event.keyCode == Self.escapeKeyCode, switcher.isOpen {
                feed(.escape)
                return true
            }

            return false

        case .flagsChanged:
            if switcher.isOpen, !flags.contains(.control) {
                feed(.controlReleased)
            }

            return false

        default:
            return false
        }
    }

    private func feed(_ key: TrailSwitcher.Key) {
        let outcome = switcher.handle(key, trail: model.recentItems.map(\.id))

        if case .commit(let itemID) = outcome {
            onCommit(itemID)
        }
    }
}

struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        WindowReportingView(onWindow: onWindow)
    }

    func updateNSView(_ view: NSView, context: Context) {}

    private final class WindowReportingView: NSView {
        let onWindow: (NSWindow?) -> Void

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow(window)
        }
    }
}
