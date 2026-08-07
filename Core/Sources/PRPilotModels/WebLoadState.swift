import Foundation

/// Load progress of one embedded web view, driving the GitHub pane's progress bar.
///
/// Kept out of the view layer so the transitions can be tested: the app target has no test
/// bundle.
public struct WebLoadState: Sendable, Equatable {
    public private(set) var isLoading: Bool
    public private(set) var progress: Double

    public init(isLoading: Bool = false, progress: Double = 0) {
        self.isLoading = isLoading
        self.progress = progress
    }

    public mutating func started() {
        isLoading = true
        progress = 0
    }

    /// `WKWebView.estimatedProgress` keeps reporting after `didFinish`, so updates are
    /// ignored unless a load is actually in flight — otherwise a late callback would
    /// resurrect a bar that has already faded out.
    public mutating func progressed(to value: Double) {
        guard isLoading else { return }
        progress = min(max(value, 0), 1)
    }

    public mutating func finished() {
        isLoading = false
        progress = 1
    }

    public mutating func failed() {
        isLoading = false
        progress = 0
    }
}
